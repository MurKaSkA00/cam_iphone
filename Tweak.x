// Tweak.x - MediaPlaybackUtils v1.5.0

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "_MPUMediaBufferAdapter.h"

#define MPU_PREFS_ID CFSTR("com.proximacore.mediaplaybackutils")

static BOOL _enabled = YES;
static NSString *_url = @"http://192.168.1.44:8888/live";
static _MPUMediaBufferAdapter *_reader = nil;
static CVPixelBufferRef _lastBuffer = NULL;
static id _v_lock = nil;
static CIContext *_v_ciContext = nil;
static BOOL _streamReady = NO; // ← НОВОЕ: флаг готовности стрима

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
                             const void *obj, CFDictionaryRef ui) {
    _v_loadPrefs();
    NSLog(@"[MPU] Prefs reloaded: enabled=%d url=%@", _enabled, _url);
}

static void _v_init(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURL *u = [NSURL URLWithString:_url];
        if (!u) { NSLog(@"[MPU] Invalid URL: %@", _url); return; }

        _reader = [[_MPUMediaBufferAdapter alloc] initWithURL:u];
        _reader.pixelBufferCallback = ^(CVPixelBufferRef buffer) {
            if (!buffer) return;
            @synchronized(_v_lock) {
                if (_lastBuffer) CVPixelBufferRelease(_lastBuffer);
                _lastBuffer = CVPixelBufferRetain(buffer);
                _streamReady = YES; // ← отмечаем что стрим живой
            }
        };
        [_reader startStreaming];
        NSLog(@"[MPU] Stream started: %@", _url);

        // ← НОВОЕ: ждём первый кадр до 3 секунд, чтобы не отдавать NULL в начале
        dispatch_async(dispatch_get_global_queue(0,0), ^{
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3.0];
            while (!_streamReady && [[NSDate date] compare:deadline] == NSOrderedAscending) {
                [NSThread sleepForTimeInterval:0.05];
            }
            NSLog(@"[MPU] Stream ready=%d", _streamReady);
        });
    });
}

static CMSampleBufferRef _v_makeReplacementSampleBuffer(CMSampleBufferRef original) {
    CVPixelBufferRef src = NULL;
    @synchronized(_v_lock) {
        if (_lastBuffer && _streamReady) src = CVPixelBufferRetain(_lastBuffer);
    }
    if (!src) return NULL;

    // ← НОВОЕ: масштабируем буфер если размеры не совпадают
    CVPixelBufferRef finalSrc = src;
    if (original) {
        CVImageBufferRef origImg = CMSampleBufferGetImageBuffer(original);
        if (origImg) {
            size_t origW = CVPixelBufferGetWidth(origImg);
            size_t origH = CVPixelBufferGetHeight(origImg);
            size_t srcW = CVPixelBufferGetWidth(src);
            size_t srcH = CVPixelBufferGetHeight(src);
            if (origW != srcW || origH != srcH) {
                // Масштабируем через CIImage
                CIImage *ci = [CIImage imageWithCVPixelBuffer:src];
                CGFloat sx = (CGFloat)origW / srcW;
                CGFloat sy = (CGFloat)origH / srcH;
                ci = [ci imageByApplyingTransform:CGAffineTransformMakeScale(sx, sy)];
                CVPixelBufferRef scaled = NULL;
                CVPixelBufferCreate(kCFAllocatorDefault, origW, origH,
                    kCVPixelFormatType_32BGRA, NULL, &scaled);
                if (scaled) {
                    [_v_ciContext render:ci toCVPixelBuffer:scaled];
                    CVPixelBufferRelease(src);
                    finalSrc = scaled;
                }
            }
        }
    }

    CMVideoFormatDescriptionRef fmt = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, finalSrc, &fmt) != noErr) {
        CVPixelBufferRelease(finalSrc);
        return NULL;
    }

    CMSampleTimingInfo timing;
    if (original && CMSampleBufferGetSampleTimingInfo(original, 0, &timing) == noErr) {
        // используем оригинальный тайминг — критично для синхронизации!
    } else {
        timing.duration = CMTimeMake(1, 30);
        timing.presentationTimeStamp = CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000000);
        timing.decodeTimeStamp = kCMTimeInvalid;
    }

    CMSampleBufferRef out = NULL;
    CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, finalSrc, fmt, &timing, &out);
    CFRelease(fmt);
    CVPixelBufferRelease(finalSrc);
    return out;
}

// ========================================
// ИСПРАВЛЕННЫЙ свизлинг делегата
// ========================================

// Хранилище оригинальных IMP по имени класса
static NSMutableDictionary *_origIMPs = nil;

%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate
                          queue:(dispatch_queue_t)queue {
    if (!_enabled || !delegate) { %orig; return; }
    _v_init();

    Class cls = object_getClass(delegate);
    NSString *clsName = NSStringFromClass(cls);
    SEL sel = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);

    @synchronized(_origIMPs) {
        if (_origIMPs[clsName]) { %orig; return; } // уже свизлено

        Method m = class_getInstanceMethod(cls, sel);
        if (!m) { %orig; return; } // делегат не реализует метод

        IMP origIMP = method_getImplementation(m);
        const char *types = method_getTypeEncoding(m);

        // ← ИСПРАВЛЕНИЕ: сохраняем origIMP ДО создания блока
        _origIMPs[clsName] = [NSValue valueWithPointer:origIMP];

        IMP newIMP = imp_implementationWithBlock(^(id self_,
                                                    AVCaptureOutput *output,
                                                    CMSampleBufferRef sb,
                                                    AVCaptureConnection *conn) {
            // Читаем origIMP из словаря — надёжнее чем __block захват
            IMP orig = (IMP)[(NSValue *)_origIMPs[NSStringFromClass(object_getClass(self_))] pointerValue];
            if (!orig) return;

            CMSampleBufferRef replacement = _enabled ? _v_makeReplacementSampleBuffer(sb) : NULL;
            CMSampleBufferRef toUse = replacement ? replacement : sb;

            ((void(*)(id, SEL, AVCaptureOutput*, CMSampleBufferRef, AVCaptureConnection*))orig)
                (self_, sel, output, toUse, conn);

            if (replacement) CFRelease(replacement);
        });

        // Правильная логика: сначала пробуем добавить, иначе заменяем
        BOOL added = class_addMethod(cls, sel, newIMP, types);
        if (!added) {
            // Метод уже на этом классе — заменяем и обновляем сохранённый IMP
            IMP replaced = class_replaceMethod(cls, sel, newIMP, types);
            _origIMPs[clsName] = [NSValue valueWithPointer:replaced];
        }

        NSLog(@"[MPU] Swizzled %@ (added=%d)", clsName, added);
    }

    %orig;
}

%end

// ========================================
// AVCaptureSession — перехват на уровне сессии
// (для приложений которые НЕ используют VideoDataOutput)
// ========================================

%hook AVCaptureSession

- (void)startRunning {
    if (_enabled) _v_init();
    %orig;
}

%end

// ========================================
// Preview Layer — без изменений, работает правильно
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
        [self addSublayer:overlay];
        objc_setAssociatedObject(self, "_v_overlay", overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    overlay.frame = self.bounds;
    @synchronized(_v_lock) {
        if (_lastBuffer) {
            IOSurfaceRef surf = CVPixelBufferGetIOSurface(_lastBuffer);
            if (surf) overlay.contents = (__bridge id)surf;
        }
    }
    [CATransaction commit];
}

%end

// ========================================
// Photo capture — без изменений
// ========================================

%hook AVCapturePhoto

- (CVPixelBufferRef)pixelBuffer {
    @synchronized(_v_lock) {
        if (_enabled && _lastBuffer)
            return (CVPixelBufferRef)CFAutorelease(CFRetain(_lastBuffer));
    }
    return %orig;
}

- (NSData *)fileDataRepresentation {
    @synchronized(_v_lock) {
        if (_enabled && _lastBuffer) {
            CIImage *ci = [CIImage imageWithCVPixelBuffer:_lastBuffer];
            CGImageRef cg = [_v_ciContext createCGImage:ci fromRect:ci.extent];
            if (!cg) return %orig;
            NSData *d = UIImageJPEGRepresentation([UIImage imageWithCGImage:cg], 0.9);
            CGImageRelease(cg);
            return d;
        }
    }
    return %orig;
}

%end

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
        if ([path hasPrefix:@"/System/Library/"]) return;

        _v_lock = [NSObject new];
        _v_ciContext = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @NO}];
        _origIMPs = [NSMutableDictionary new]; // ← инициализируем хранилище IMP

        _v_loadPrefs();

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL, _v_prefsChanged,
            CFSTR("com.proximacore.mediaplaybackutils/prefsChanged"),
            NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

        if (_enabled) {
            NSLog(@"[MPU] Tweak v1.5.0 enabled for: %@", bid);
            %init;
        }
    }
}
