// Tweak.x - MediaPlaybackUtils v1.4.2 (FIXED)

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

// ФИХ 1: убрали dispatch_once — теперь можно реинициализировать при смене URL
static void _v_init_stream(void) {
    NSURL *u = [NSURL URLWithString:_url];
    if (!u) return;

    // Останавливаем старый ридер если есть
    if (_reader) {
        [_reader stopStreaming];
        _reader = nil;
    }

    _reader = [[_MPUMediaBufferAdapter alloc] initWithURL:u];
    _reader.pixelBufferCallback = ^(CVPixelBufferRef buffer) {
        if (!buffer) return;
        @synchronized(_v_lock) {
            if (_lastBuffer) CVPixelBufferRelease(_lastBuffer);
            _lastBuffer = CVPixelBufferRetain(buffer);
        }
    };
    [_reader startStreaming];
    NSLog(@"[MPU] Stream (re)initialized: %@", _url);
}

static void _v_init(void) {
    static BOOL started = NO;
    if (!started) {
        started = YES;
        _v_init_stream();
    }
}

static void _v_loadPrefs(void) {
    NSString *oldUrl = [_url copy];

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

    // ФИХ 1: если URL изменился — переподключаемся без выхода из приложения
    if (![oldUrl isEqualToString:_url] && _reader) {
        NSLog(@"[MPU] URL changed, reinitializing stream...");
        _v_init_stream();
    }
}

static void _v_prefsChanged(CFNotificationCenterRef center, void *observer,
                             CFStringRef name, const void *object,
                             CFDictionaryRef userInfo) {
    _v_loadPrefs();
    NSLog(@"[MPU] Preferences reloaded: enabled=%d url=%@", _enabled, _url);
}

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
                    CMSampleBufferRef replacement = NULL;
                    if (_enabled) {
                        replacement = _v_makeReplacementSampleBuffer(sb);
                    }
                    CMSampleBufferRef toUse = replacement ? replacement : sb;
                    ((void(*)(id, SEL, AVCaptureOutput *, CMSampleBufferRef, AVCaptureConnection *))origIMP)
                        (self_, sel, output, toUse, conn);
                    if (replacement) CFRelease(replacement);
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
// 2. ФИХ ФОТО — перехватываем на уровне AVCapturePhotoOutput
// ========================================

%hook AVCapturePhotoOutput

// Перехватываем момент когда система хочет захватить фото
// и подменяем делегат для получения результата
- (void)capturePhotoWithSettings:(AVCapturePhotoSettings *)settings
                        delegate:(id<AVCapturePhotoCaptureDelegate>)delegate {
    if (!_enabled) {
        %orig;
        return;
    }

    // Swizzle делегат фото чтобы подменить результат
    Class cls = object_getClass(delegate);
    SEL sel = @selector(captureOutput:didFinishProcessingPhoto:error:);

    static NSMutableSet *swizzledPhotoClasses = nil;
    static dispatch_once_t oncePhoto;
    dispatch_once(&oncePhoto, ^{ swizzledPhotoClasses = [NSMutableSet new]; });

    NSString *clsName = NSStringFromClass(cls);

    @synchronized(swizzledPhotoClasses) {
        if (![swizzledPhotoClasses containsObject:clsName]) {
            Method m = class_getInstanceMethod(cls, sel);
            if (m) {
                const char *types = method_getTypeEncoding(m);
                __block IMP origIMP = method_getImplementation(m);

                IMP newIMP = imp_implementationWithBlock(^(id self_,
                                                           AVCapturePhotoOutput *output,
                                                           AVCapturePhoto *photo,
                                                           NSError *error) {
                    // Подменяем photo прокси-объектом
                    if (_enabled && !error) {
                        // Вызываем оригинал — но photo уже будет с подменённым pixelBuffer
                        // (хук на AVCapturePhoto ниже сработает)
                    }
                    ((void(*)(id, SEL, AVCapturePhotoOutput *, AVCapturePhoto *, NSError *))origIMP)
                        (self_, sel, output, photo, error);
                });

                if (!class_addMethod(cls, sel, newIMP, types)) {
                    origIMP = class_replaceMethod(cls, sel, newIMP, types);
                }
                [swizzledPhotoClasses addObject:clsName];
                NSLog(@"[MPU] Swizzled photo delegate class: %@", clsName);
            }
        }
    }

    %orig;
}

%end

// ========================================
// 2b. ПЕРЕХВАТ AVCapturePhoto (пиксель-буфер и JPEG)
// ========================================

%hook AVCapturePhoto

- (CVPixelBufferRef)pixelBuffer {
    @synchronized(_v_lock) {
        if (_enabled && _lastBuffer) {
            NSLog(@"[MPU] Returning virtual buffer for photo");
            return (CVPixelBufferRef)CFAutorelease(CFRetain(_lastBuffer));
        }
    }
    return %orig;
}

- (NSData *)fileDataRepresentation {
    @synchronized(_v_lock) {
        if (_enabled && _lastBuffer) {
            // ФИХ 2: создаём JPEG из нашего стрим-буфера
            CIImage *ci = [CIImage imageWithCVPixelBuffer:_lastBuffer];
            if (!ci) return %orig;

            CGImageRef cg = [_v_ciContext createCGImage:ci fromRect:ci.extent];
            if (!cg) return %orig;

            NSData *d = UIImageJPEGRepresentation([UIImage imageWithCGImage:cg], 0.95);
            CGImageRelease(cg);

            if (d) {
                NSLog(@"[MPU] Returning virtual photo JPEG (%lu bytes)", (unsigned long)d.length);
                return d;
            }
        }
    }
    return %orig;
}

// ФИХ 2: дополнительно перехватываем CGImageRepresentation
- (CGImageRef)CGImageRepresentation {
    @synchronized(_v_lock) {
        if (_enabled && _lastBuffer) {
            CIImage *ci = [CIImage imageWithCVPixelBuffer:_lastBuffer];
            if (!ci) return %orig;
            CGImageRef cg = [_v_ciContext createCGImage:ci fromRect:ci.extent];
            if (cg) {
                NSLog(@"[MPU] Returning virtual CGImage for photo");
                return (CGImageRef)CFAutorelease(cg);
            }
        }
    }
    return %orig;
}

%end

// ========================================
// 3. ПЕРЕХВАТ ПРЕДПРОСМОТРА КАМЕРЫ
// ========================================

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
        objc_setAssociatedObject(self, "_v_overlay", overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    overlay.frame = self.bounds;
    overlay.hidden = NO;
    overlay.opacity = 1.0;
    @synchronized(_v_lock) {
        if (_lastBuffer) {
            IOSurfaceRef surf = CVPixelBufferGetIOSurface(_lastBuffer);
            if (surf) {
                overlay.contents = (__bridge id)surf;
            }
        }
    }
    [CATransaction commit];
}

%end

// ========================================
// 4. ПРОГРЕВ ПРИ СОЗДАНИИ УСТРОЙСТВА
// ========================================

%hook AVCaptureDevice

+ (AVCaptureDevice *)defaultDeviceWithMediaType:(AVMediaType)mediaType {
    if (_enabled && [mediaType isEqualToString:AVMediaTypeVideo]) {
        _v_init();
    }
    return %orig;
}

+ (AVCaptureDevice *)defaultDeviceWithDeviceType:(AVCaptureDeviceType)deviceType
                                       mediaType:(AVMediaType)mediaType
                                        position:(AVCaptureDevicePosition)position {
    if (_enabled && [mediaType isEqualToString:AVMediaTypeVideo]) {
        _v_init();
    }
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
        _v_ciContext = [CIContext contextWithOptions:nil];

        _v_loadPrefs();

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL, _v_prefsChanged,
            CFSTR("com.proximacore.mediaplaybackutils/prefsChanged"),
            NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

        if (_enabled) {
            NSLog(@"[MPU] Tweak enabled for: %@ (url=%@)", bid, _url);
            %init;
        } else {
            NSLog(@"[MPU] Tweak disabled for: %@", bid);
        }
    }
}
