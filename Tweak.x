// Tweak.x - MediaPlaybackUtils v1.4.3 (FIXED)

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "_MPUMediaBufferAdapter.h"

#define MPU_PREFS_ID CFSTR("com.proximacore.mediaplaybackutils")

static BOOL _enabled = YES;
static NSString *_url = @"http://192.168.1.44:8888/live/stream/index.m3u8";
static _MPUMediaBufferAdapter *_reader = nil;
static CVPixelBufferRef _lastBuffer = NULL;
static id _v_lock = nil;
static CIContext *_v_ciContext = nil;

// ========================================
// PREFS
// ========================================

static void _v_loadPrefs(void) {
    CFPreferencesAppSynchronize(MPU_PREFS_ID);
    CFPropertyListRef en = CFPreferencesCopyAppValue(CFSTR("enabled"), MPU_PREFS_ID);
    if (en) {
        if (CFGetTypeID(en) == CFBooleanGetTypeID())
            _enabled = CFBooleanGetValue((CFBooleanRef)en);
        CFRelease(en);
    }
    CFPropertyListRef u = CFPreferencesCopyAppValue(CFSTR("rtspURL"), MPU_PREFS_ID);
    if (u) {
        if (CFGetTypeID(u) == CFStringGetTypeID()) {
            NSString *s = (__bridge NSString *)u;
            if (s.length > 0) _url = [s copy];
        }
        CFRelease(u);
    }
}

static void _v_prefsChanged(CFNotificationCenterRef c, void *o, CFStringRef n,
                             const void *obj, CFDictionaryRef i) {
    _v_loadPrefs();
    NSLog(@"[MPU] Preferences reloaded: enabled=%d url=%@", _enabled, _url);
}

// ========================================
// STREAM INIT
// ========================================

static void _v_init(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURL *u = [NSURL URLWithString:_url];
        if (!u) return;
        _reader = [[_MPUMediaBufferAdapter alloc] initWithURL:u];
        _reader.pixelBufferCallback = ^(CVPixelBufferRef buffer) {
            if (!buffer) return;
            @synchronized(_v_lock) {
                if (_lastBuffer) CVPixelBufferRelease(_lastBuffer);
                _lastBuffer = CVPixelBufferRetain(buffer);
            }
        };
        [_reader startStreaming];
        NSLog(@"[MPU] Stream started: %@", _url);
    });
}

// ========================================
// HELPER: создать CMSampleBuffer из _lastBuffer
// ========================================

static CMSampleBufferRef _v_makeReplacementSampleBuffer(CMSampleBufferRef original) {
    CVPixelBufferRef src = NULL;
    @synchronized(_v_lock) {
        if (_lastBuffer) src = CVPixelBufferRetain(_lastBuffer);
    }
    if (!src) return NULL;

    CMVideoFormatDescriptionRef fmt = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, src, &fmt) != noErr || !fmt) {
        CVPixelBufferRelease(src);
        return NULL;
    }

    CMSampleTimingInfo timing;
    if (original && CMSampleBufferGetSampleTimingInfo(original, 0, &timing) == noErr) {
        // keep original timing
    } else {
        timing.duration = CMTimeMake(1, 30);
        timing.presentationTimeStamp = CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000000);
        timing.decodeTimeStamp = kCMTimeInvalid;
    }

    CMSampleBufferRef out = NULL;
    OSStatus s = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, src, fmt, &timing, &out);
    CFRelease(fmt);
    CVPixelBufferRelease(src);
    return (s == noErr) ? out : NULL;
}

// ========================================
// 1. ПЕРЕХВАТ ДЕЛЕГАТА ВИДЕО-ВЫВОДА
//    FIX: если _lastBuffer ещё NULL — ждём, не пропускаем оригинал
// ========================================

%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate
                          queue:(dispatch_queue_t)queue {
    if (!_enabled || !delegate) {
        %orig;
        return;
    }

    _v_init();

    static NSMutableSet *swizzledClassNames = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ swizzledClassNames = [NSMutableSet new]; });

    Class cls = object_getClass(delegate);
    NSString *clsName = NSStringFromClass(cls);
    SEL sel = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);

    @synchronized(swizzledClassNames) {
        if (![swizzledClassNames containsObject:clsName]) {
            Method m = class_getInstanceMethod(cls, sel);
            if (m) {
                const char *types = method_getTypeEncoding(m);
                __block IMP origIMP = method_getImplementation(m);

                IMP newIMP = imp_implementationWithBlock(^(id self_,
                                                           AVCaptureOutput *output,
                                                           CMSampleBufferRef sb,
                                                           AVCaptureConnection *conn) {
                    if (!_enabled) {
                        ((void(*)(id,SEL,AVCaptureOutput*,CMSampleBufferRef,AVCaptureConnection*))origIMP)
                            (self_, sel, output, sb, conn);
                        return;
                    }

                    CMSampleBufferRef replacement = _v_makeReplacementSampleBuffer(sb);

                    if (replacement) {
                        // ИСПРАВЛЕНИЕ: используем подменный буфер
                        ((void(*)(id,SEL,AVCaptureOutput*,CMSampleBufferRef,AVCaptureConnection*))origIMP)
                            (self_, sel, output, replacement, conn);
                        CFRelease(replacement);
                    }
                    // ИСПРАВЛЕНИЕ: если буфера ещё нет — просто пропускаем кадр,
                    // НЕ пропускаем оригинал (иначе реальная линза пройдёт)
                    // Можно раскомментировать следующие строки если нужен fallback:
                    // else {
                    //     ((void(*)(id,SEL,AVCaptureOutput*,CMSampleBufferRef,AVCaptureConnection*))origIMP)
                    //         (self_, sel, output, sb, conn);
                    // }
                });

                if (!class_addMethod(cls, sel, newIMP, types)) {
                    origIMP = class_replaceMethod(cls, sel, newIMP, types);
                }
                [swizzledClassNames addObject:clsName];
                NSLog(@"[MPU] Swizzled delegate class: %@", clsName);
            }
        }
    }

    %orig;
}

%end

// ========================================
// 2. ПЕРЕХВАТ ФОТО-ЗАХВАТА
//    FIX: хукаем делегат AVCapturePhotoOutput напрямую
// ========================================

// ИСПРАВЛЕНИЕ: правильный метод захвата фото — через делегат output,
// а не через AVCapturePhoto (который вызывается уже ПОСЛЕ захвата).
// Хукаем captureOutput:didFinishProcessingPhoto:error:

%hook AVCapturePhotoOutput

- (void)capturePhotoWithSettings:(AVCapturePhotoSettings *)settings
                        delegate:(id<AVCapturePhotoCaptureDelegate>)delegate {
    if (!_enabled || !delegate) {
        %orig;
        return;
    }

    _v_init();

    Class cls = object_getClass(delegate);
    SEL sel = @selector(captureOutput:didFinishProcessingPhoto:error:);
    Method m = class_getInstanceMethod(cls, sel);

    if (m) {
        static NSMutableSet *swizzledPhoto = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ swizzledPhoto = [NSMutableSet new]; });

        NSString *clsName = NSStringFromClass(cls);
        @synchronized(swizzledPhoto) {
            if (![swizzledPhoto containsObject:clsName]) {
                const char *types = method_getTypeEncoding(m);
                __block IMP origIMP = method_getImplementation(m);

                IMP newIMP = imp_implementationWithBlock(^(id self_,
                                                           AVCapturePhotoOutput *output,
                                                           AVCapturePhoto *photo,
                                                           NSError *error) {
                    if (!_enabled || !_lastBuffer) {
                        ((void(*)(id,SEL,AVCapturePhotoOutput*,AVCapturePhoto*,NSError*))origIMP)
                            (self_, sel, output, photo, error);
                        return;
                    }

                    // Создаём JPEG из нашего _lastBuffer
                    CVPixelBufferRef src = NULL;
                    @synchronized(_v_lock) {
                        if (_lastBuffer) src = CVPixelBufferRetain(_lastBuffer);
                    }

                    if (!src) {
                        ((void(*)(id,SEL,AVCapturePhotoOutput*,AVCapturePhoto*,NSError*))origIMP)
                            (self_, sel, output, photo, error);
                        return;
                    }

                    // Сохраняем в фото-библиотеку напрямую из нашего буфера
                    CIImage *ci = [CIImage imageWithCVPixelBuffer:src];
                    CVPixelBufferRelease(src);

                    CGImageRef cg = [_v_ciContext createCGImage:ci fromRect:ci.extent];
                    if (cg) {
                        UIImage *img = [UIImage imageWithCGImage:cg];
                        CGImageRelease(cg);
                        UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil);
                        NSLog(@"[MPU] Virtual photo saved to album");
                        // НЕ вызываем origIMP — подменяем полностью
                    } else {
                        // Fallback если CIContext упал
                        ((void(*)(id,SEL,AVCapturePhotoOutput*,AVCapturePhoto*,NSError*))origIMP)
                            (self_, sel, output, photo, error);
                    }
                });

                if (!class_addMethod(cls, sel, newIMP, types)) {
                    origIMP = class_replaceMethod(cls, sel, newIMP, types);
                }
                [swizzledPhoto addObject:clsName];
                NSLog(@"[MPU] Swizzled photo delegate: %@", clsName);
            }
        }
    }

    %orig;
}

%end

// ========================================
// 3. ПРЕДПРОСМОТР КАМЕРЫ (визуальная подмена)
//    FIX: CADisplayLink для реального обновления каждый кадр
// ========================================

static void _v_updateOverlay(CALayer *overlay) {
    if (!overlay || !_enabled) return;
    CVPixelBufferRef buf = NULL;
    @synchronized(_v_lock) {
        if (_lastBuffer) buf = CVPixelBufferRetain(_lastBuffer);
    }
    if (!buf) return;

    IOSurfaceRef surf = CVPixelBufferGetIOSurface(buf);
    if (surf) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        overlay.contents = (__bridge id)surf;
        overlay.hidden = NO;
        overlay.opacity = 1.0;
        [CATransaction commit];
    }
    CVPixelBufferRelease(buf);
}

// Хелпер-объект для CADisplayLink
@interface _MPUDisplayLinkTarget : NSObject
@property (nonatomic, weak) CALayer *overlay;
- (void)tick:(CADisplayLink *)link;
@end

@implementation _MPUDisplayLinkTarget
- (void)tick:(CADisplayLink *)link {
    _v_updateOverlay(self.overlay);
}
@end

%hook AVCaptureVideoPreviewLayer

- (void)layoutSublayers {
    %orig;
    if (!_enabled) return;
    _v_init();

    CALayer *overlay = objc_getAssociatedObject(self, "_v_overlay");
    if (!overlay) {
        overlay = [CALayer layer];
        overlay.contentsGravity = kCAGravityResizeAspectFill;
        overlay.zPosition = 999999;
        overlay.backgroundColor = [UIColor blackColor].CGColor;
        overlay.opaque = YES;
        [self addSublayer:overlay];
        objc_setAssociatedObject(self, "_v_overlay", overlay,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        // ИСПРАВЛЕНИЕ: CADisplayLink для обновления каждый кадр (60fps)
        _MPUDisplayLinkTarget *target = [_MPUDisplayLinkTarget new];
        target.overlay = overlay;
        CADisplayLink *link = [CADisplayLink displayLinkWithTarget:target
                                                          selector:@selector(tick:)];
        link.preferredFramesPerSecond = 30;
        [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        objc_setAssociatedObject(overlay, "_v_displayLink", link,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(overlay, "_v_target", target,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSLog(@"[MPU] Preview overlay + DisplayLink created");
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    overlay.frame = self.bounds;
    [CATransaction commit];
}

%end

// ========================================
// 4. ПРОГРЕВ СТРИМА
// ========================================

%hook AVCaptureDevice

+ (AVCaptureDevice *)defaultDeviceWithMediaType:(AVMediaType)mediaType {
    if (_enabled && [mediaType isEqualToString:AVMediaTypeVideo]) _v_init();
    return %orig;
}

+ (AVCaptureDevice *)defaultDeviceWithDeviceType:(AVCaptureDeviceType)deviceType
                                       mediaType:(AVMediaType)mediaType
                                        position:(AVCaptureDevicePosition)position {
    if (_enabled && [mediaType isEqualToString:AVMediaTypeVideo]) _v_init();
    return %orig;
}

%end

// ========================================
// ИНИЦИАЛИЗАЦИЯ
// ========================================

%ctor {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if (!bid) return;
        if ([bid hasPrefix:@"com.apple.springboard"]) return;
        if ([bid hasPrefix:@"com.apple.WebKit"]) return;
        if ([bid hasPrefix:@"com.apple.mediaserverd"]) return;
        if ([bid hasPrefix:@"com.apple.assetsd"]) return;
        if ([bid hasPrefix:@"com.apple.coremedia"]) return;
        if ([bid hasPrefix:@"com.apple.avconferenced"]) return;
        if ([bid hasPrefix:@"com.apple.cameracaptured"]) return;

        NSString *path = [[NSBundle mainBundle] bundlePath];
        if ([path hasPrefix:@"/usr/"]) return;
        if ([path hasPrefix:@"/System/Library/PrivateFrameworks/"]) return;
        if ([path hasPrefix:@"/System/Library/Frameworks/"]) return;

        _v_lock = [NSObject new];
        _v_ciContext = [CIContext contextWithOptions:@{
            kCIContextUseSoftwareRenderer: @NO,
            kCIContextWorkingColorSpace: (__bridge id)CGColorSpaceCreateDeviceRGB()
        }];

        _v_loadPrefs();

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL, _v_prefsChanged,
            CFSTR("com.proximacore.mediaplaybackutils/prefsChanged"),
            NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

        if (_enabled) {
            NSLog(@"[MPU] Tweak v1.4.3 enabled for: %@ url=%@", bid, _url);
            %init;
        } else {
            NSLog(@"[MPU] Tweak disabled for: %@", bid);
        }
    }
}
