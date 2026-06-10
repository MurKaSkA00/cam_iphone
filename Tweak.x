// Tweak.x - MediaPlaybackUtils v1.4.3 (fixed)

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

static void _v_loadPrefs(void) {
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

// FIX: forward declaration — объявляем до первого использования в _v_prefsChanged
static void _v_startStream(void);

static void _v_prefsChanged(CFNotificationCenterRef center, void *observer,
                             CFStringRef name, const void *object,
                             CFDictionaryRef userInfo) {
    CFPreferencesAppSynchronize(MPU_PREFS_ID);
    NSString *oldURL = [_url copy];
    _v_loadPrefs();
    NSLog(@"[MPU] Preferences reloaded: enabled=%d url=%@", _enabled, _url);
    // Перезапускаем стрим если URL изменился
    if (![oldURL isEqualToString:_url]) {
        NSLog(@"[MPU] URL changed, restarting stream...");
        _v_startStream();
    }
}

static void _v_startStream(void) {
    NSURL *u = [NSURL URLWithString:_url];
    if (!u) {
        NSLog(@"[MPU] Invalid stream URL: %@", _url);
        return;
    }
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
    NSLog(@"[MPU] Stream started: %@", _url);
}

static void _v_init(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        _v_startStream();
    });
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
// 2. ПЕРЕХВАТ ФОТО-ЗАХВАТА
// FIX: ждём буфер до 500мс если стрим ещё не прогрелся
// ========================================

%hook AVCapturePhoto

- (CVPixelBufferRef)pixelBuffer {
    // Ждём буфер если ещё не пришёл
    if (_enabled && !_lastBuffer) {
        for (int i = 0; i < 50; i++) {
            [NSThread sleepForTimeInterval:0.01];
            @synchronized(_v_lock) {
                if (_lastBuffer) break;
            }
        }
    }

    @synchronized(_v_lock) {
        if (_enabled && _lastBuffer) {
            NSLog(@"[MPU] Returning virtual buffer for photo");
            return (CVPixelBufferRef)CFAutorelease(CFRetain(_lastBuffer));
        }
    }
    return %orig;
}

- (NSData *)fileDataRepresentation {
    // Ждём буфер если ещё не пришёл
    if (_enabled && !_lastBuffer) {
        for (int i = 0; i < 50; i++) {
            [NSThread sleepForTimeInterval:0.01];
            @synchronized(_v_lock) {
                if (_lastBuffer) break;
            }
        }
    }

    CVPixelBufferRef snapBuffer = NULL;
    @synchronized(_v_lock) {
        if (_enabled && _lastBuffer) {
            snapBuffer = CVPixelBufferRetain(_lastBuffer);
        }
    }

    if (snapBuffer) {
        CIImage *ci = [CIImage imageWithCVPixelBuffer:snapBuffer];
        // FIX: используем глобальный _v_ciContext, он точно инициализирован в %ctor
        CGImageRef cg = [_v_ciContext createCGImage:ci fromRect:ci.extent];
        CVPixelBufferRelease(snapBuffer);
        if (!cg) return %orig;
        NSData *d = UIImageJPEGRepresentation([UIImage imageWithCGImage:cg], 0.9);
        CGImageRelease(cg);
        NSLog(@"[MPU] Returning virtual photo data");
        return d;
    }

    return %orig;
}

%end

// ========================================
// 3. ПЕРЕХВАТ ПРЕДПРОСМОТРА КАМЕРЫ
// FIX: CADisplayLink для постоянного live-обновления вместо разового layoutSublayers
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

        // FIX: запускаем CADisplayLink для постоянного обновления кадров из стрима
        CADisplayLink *link = [CADisplayLink displayLinkWithTarget:self
                                                          selector:@selector(_v_updateOverlayFrame:)];
        link.preferredFramesPerSecond = 30;
        [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        objc_setAssociatedObject(self, "_v_displayLink", link, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        NSLog(@"[MPU] CADisplayLink started for preview layer");
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    overlay.frame = self.bounds;
    overlay.hidden = NO;
    overlay.opacity = 1.0;
    [CATransaction commit];
}

// FIX: новый метод — вызывается CADisplayLink каждый кадр
%new
- (void)_v_updateOverlayFrame:(CADisplayLink *)link {
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
                overlay.hidden = NO;
                [CATransaction commit];
            }
        }
    }
}

%end

// ========================================
// 4. ПРОГРЕВ СТРИМА ПРИ СОЗДАНИИ УСТРОЙСТВА
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
        NSString *exec = [[NSBundle mainBundle] executablePath].lastPathComponent ?: @"";

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

        // FIX: инициализируем lock и CIContext ДО чего-либо ещё
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
            NSLog(@"[MPU] Tweak enabled for bundle: %@ (exec=%@, url=%@)", bid, exec, _url);
            %init;

            // FIX: прогреваем стрим сразу при инъекции твика, не ждём первого вызова камеры
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                _v_init();
            });
        } else {
            NSLog(@"[MPU] Tweak disabled in preferences for: %@", bid);
        }
    }
}
