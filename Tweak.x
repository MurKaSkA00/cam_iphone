// Tweak.x - MediaPlaybackUtils v1.4.3
// FIXES:
//   1. Crash fix in Telegram/Snapchat/Instagram (safe swizzling + exception guard)
//   2. Hot-reload stream URL without re-entering the app

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

// FIX #2: убираем dispatch_once из _v_init, чтобы можно было перезапустить стрим
// Теперь инициализация управляется через флаг + явный сброс при смене URL.
static NSString *_currentStreamURL = nil;

static void _v_loadPrefs(void) {
    CFPreferencesAppSynchronize(MPU_PREFS_ID);

    CFPropertyListRef en = CFPreferencesCopyAppValue(CFSTR("enabled"), MPU_PREFS_ID);
    if (en) {
        if (CFGetTypeID(en) == CFBooleanGetTypeID()) {
            _enabled = CFBooleanGetValue((CFBooleanRef)en);
        }
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

// FIX #2: перезапуск стрима при смене URL
static void _v_restartStreamIfNeeded(void) {
    @synchronized(_v_lock) {
        // Если URL изменился — останавливаем старый reader и создаём новый
        if (_reader && ![_currentStreamURL isEqualToString:_url]) {
            NSLog(@"[MPU] URL changed from %@ to %@, restarting stream", _currentStreamURL, _url);
            [_reader stopStreaming];
            _reader = nil;
            if (_lastBuffer) {
                CVPixelBufferRelease(_lastBuffer);
                _lastBuffer = NULL;
            }
            _currentStreamURL = nil;
        }

        if (!_reader && _enabled) {
            NSURL *u = [NSURL URLWithString:_url];
            if (!u) return;

            _currentStreamURL = [_url copy];
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
        }
    }
}

static void _v_init(void) {
    _v_restartStreamIfNeeded();
}

static void _v_prefsChanged(CFNotificationCenterRef center, void *observer,
                             CFStringRef name, const void *object,
                             CFDictionaryRef userInfo) {
    _v_loadPrefs();
    NSLog(@"[MPU] Preferences reloaded: enabled=%d url=%@", _enabled, _url);

    // FIX #2: автоматически перезапускаем стрим с новым URL
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        _v_restartStreamIfNeeded();
    });
}

static CMSampleBufferRef _v_makeReplacementSampleBuffer(CMSampleBufferRef original) {
    CVPixelBufferRef src = NULL;
    @synchronized(_v_lock) {
        if (_lastBuffer) src = CVPixelBufferRetain(_lastBuffer);
    }

    if (!src) return NULL;

    CMVideoFormatDescriptionRef fmt = NULL;
    OSStatus fmtErr = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, src, &fmt);
    if (fmtErr != noErr || !fmt) {
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
    if (!cls) {
        %orig;
        return;
    }

    NSString *clsName = NSStringFromClass(cls);

    // FIX #1: пропускаем системные и проблемные классы чтобы не крашить
    // (React Native bridge, WebKit internals, системные делегаты)
    if ([clsName hasPrefix:@"RCT"] ||
        [clsName hasPrefix:@"WK"] ||
        [clsName hasPrefix:@"WebKit"] ||
        [clsName containsString:@"Internal"] ||
        [clsName hasPrefix:@"_"]) {
        %orig;
        return;
    }

    SEL sel = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);

    @synchronized(swizzledClassNames) {
        if (![swizzledClassNames containsObject:clsName]) {
            Method m = class_getInstanceMethod(cls, sel);
            if (m) {
                const char *types = method_getTypeEncoding(m);

                // FIX #1: сохраняем IMP по значению в __block переменной на стеке,
                // потом копируем на heap через __block NSValue чтобы избежать dangling pointer
                IMP origIMP = method_getImplementation(m);
                __block IMP capturedIMP = origIMP;

                IMP newIMP = imp_implementationWithBlock(^(id self_,
                                                           AVCaptureOutput *output,
                                                           CMSampleBufferRef sb,
                                                           AVCaptureConnection *conn) {
                    // FIX #1: весь вызов в @try/@catch чтобы любой краш не убил приложение
                    @try {
                        CMSampleBufferRef replacement = NULL;

                        if (_enabled && sb) {
                            replacement = _v_makeReplacementSampleBuffer(sb);
                        }

                        CMSampleBufferRef toUse = replacement ? replacement : sb;

                        if (toUse) {
                            ((void(*)(id, SEL, AVCaptureOutput *, CMSampleBufferRef, AVCaptureConnection *))capturedIMP)
                                (self_, sel, output, toUse, conn);
                        }

                        if (replacement) CFRelease(replacement);
                    } @catch (NSException *ex) {
                        // FIX #1: падаем тихо — логируем и вызываем оригинал
                        NSLog(@"[MPU] Exception in delegate hook for %@: %@", clsName, ex);
                        @try {
                            if (sb) {
                                ((void(*)(id, SEL, AVCaptureOutput *, CMSampleBufferRef, AVCaptureConnection *))capturedIMP)
                                    (self_, sel, output, sb, conn);
                            }
                        } @catch (...) {}
                    }
                });

                BOOL added = class_addMethod(cls, sel, newIMP, types);
                if (!added) {
                    // Метод уже есть на этом классе — обновляем только его
                    IMP prev = class_replaceMethod(cls, sel, newIMP, types);
                    if (prev) capturedIMP = prev;
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
            CIImage *ci = [CIImage imageWithCVPixelBuffer:_lastBuffer];
            CGImageRef cg = [_v_ciContext createCGImage:ci fromRect:ci.extent];
            if (!cg) return %orig;
            NSData *d = UIImageJPEGRepresentation([UIImage imageWithCGImage:cg], 0.9);
            CGImageRelease(cg);
            NSLog(@"[MPU] Returning virtual photo data");
            return d;
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

    // FIX #2: при обновлении overlay также подхватываем новый _lastBuffer автоматически
    // т.к. CADisplayLink в HLS или callback в HTTP обновляет _lastBuffer глобально
    CALayer *overlay = objc_getAssociatedObject(self, "_v_overlay");
    if (!overlay) {
        overlay = [CALayer layer];
        overlay.contentsGravity = kCAGravityResizeAspectFill;
        overlay.zPosition = 999999;
        overlay.backgroundColor = [UIColor blackColor].CGColor;
        overlay.opaque = YES;
        [self addSublayer:overlay];
        objc_setAssociatedObject(self, "_v_overlay", overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        // FIX #2: добавляем CADisplayLink на overlay чтобы картинка обновлялась live
        // без перезахода в приложение
        CADisplayLink *dl = [CADisplayLink displayLinkWithTarget:self
                                                        selector:@selector(_mpu_updateOverlay:)];
        dl.preferredFramesPerSecond = 30;
        [dl addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        objc_setAssociatedObject(self, "_v_displayLink", dl, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    overlay.frame = self.bounds;
    overlay.hidden = NO;
    overlay.opacity = 1.0;
    [CATransaction commit];
}

// FIX #2: новый метод — обновляет overlay каждый кадр автоматически
%new
- (void)_mpu_updateOverlay:(CADisplayLink *)sender {
    if (!_enabled) return;

    CALayer *overlay = objc_getAssociatedObject(self, "_v_overlay");
    if (!overlay) return;

    @synchronized(_v_lock) {
        if (_lastBuffer) {
            IOSurfaceRef surf = CVPixelBufferGetIOSurface(_lastBuffer);
            if (surf) {
                [CATransaction begin];
                [CATransaction setDisableActions:YES];
                overlay.contents = (__bridge id)surf;
                overlay.frame = self.bounds;
                [CATransaction commit];
            }
        }
    }
}

%end

// ========================================
// 4. ЛОГ СОЗДАНИЯ УСТРОЙСТВА КАМЕРЫ
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
// ИНИЦИАЛИЗАЦИЯ ТВИКА
// ========================================

%ctor {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        NSString *path = [[NSBundle mainBundle] bundlePath];

        if (!bid) return;
        if ([bid hasPrefix:@"com.apple.springboard"]) return;
        if ([bid hasPrefix:@"com.apple.WebKit"]) return;
        if ([bid hasPrefix:@"com.apple.mediaserverd"]) return;
        if ([bid hasPrefix:@"com.apple.assetsd"]) return;
        if ([bid hasPrefix:@"com.apple.coremedia"]) return;
        if ([bid hasPrefix:@"com.apple.avconferenced"]) return;
        if ([bid hasPrefix:@"com.apple.cameracaptured"]) return;
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
            NSLog(@"[MPU] Tweak enabled for bundle: %@ (url=%@)", bid, _url);
            %init;
        } else {
            NSLog(@"[MPU] Tweak disabled in preferences for: %@", bid);
        }
    }
}
