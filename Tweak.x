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
static NSString *_url = @"http://192.168.1.44:8888/live";
static _MPUMediaBufferAdapter *_reader = nil;
static CVPixelBufferRef _lastBuffer = NULL;
static id _v_lock = nil;
static CIContext *_v_ciContext = nil;

// FIX #3: CADisplayLink для живого обновления overlay
static NSMutableSet *_overlayLayers = nil;
static CADisplayLink *_overlayDisplayLink = nil;

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

static void _v_prefsChanged(CFNotificationCenterRef center, void *observer,
                             CFStringRef name, const void *object,
                             CFDictionaryRef userInfo) {
    _v_loadPrefs();
    NSLog(@"[MPU] Preferences reloaded: enabled=%d url=%@", _enabled, _url);
}

// FIX #3: обновляем все overlay-слои через CADisplayLink (живое видео в превью)
static void _v_overlayTick(CADisplayLink *link) {
    if (!_overlayLayers || !_lastBuffer) return;
    @synchronized(_overlayLayers) {
        IOSurfaceRef surf = NULL;
        @synchronized(_v_lock) {
            if (_lastBuffer) surf = CVPixelBufferGetIOSurface(_lastBuffer);
        }
        if (!surf) return;
        id surfObj = (__bridge id)surf;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        for (CALayer *overlay in _overlayLayers) {
            overlay.contents = surfObj;
        }
        [CATransaction commit];
    }
}

static void _v_startOverlayDisplayLink(void) {
    if (_overlayDisplayLink) return;
    _overlayDisplayLink = [CADisplayLink displayLinkWithTarget:[NSBlockOperation blockOperationWithBlock:^{}]
                                                       selector:@selector(main)];
    // Используем свой таргет через блок-обёртку
    _overlayDisplayLink = nil;

    // Правильный способ — через NSObject-категорию не нужна, просто используем таймер
    // CADisplayLink требует target+selector, создаём минимальный хелпер
    // Реализуем через dispatch_source на main queue с ~30fps
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                      dispatch_get_main_queue());
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW,
                              (uint64_t)(1.0/30.0 * NSEC_PER_SEC),
                              (uint64_t)(5 * NSEC_PER_MSEC));
    dispatch_source_set_event_handler(timer, ^{
        _v_overlayTick(nil);
    });
    dispatch_resume(timer);
    // Сохраняем таймер через ассоциацию на _v_lock
    objc_setAssociatedObject(_v_lock, "_v_overlayTimer", timer, OBJC_ASSOCIATION_RETAIN);
    NSLog(@"[MPU] Overlay display timer started");
}

static void _v_init(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURL *u = [NSURL URLWithString:_url];
        if (!u) {
            NSLog(@"[MPU] Invalid URL: %@", _url);
            return;
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
        NSLog(@"[MPU] Stream initialized: %@", _url);
    });
}

// FIX #1 + FIX #2: ждём первый кадр до 2 секунд, и правильно захватываем origIMP
static CMSampleBufferRef _v_makeReplacementSampleBuffer(CMSampleBufferRef original) {
    // FIX #1: если буфера ещё нет — подождём немного (до 2 сек по 5мс)
    CVPixelBufferRef src = NULL;
    int waitMs = 0;
    while (!src && waitMs < 2000) {
        @synchronized(_v_lock) {
            if (_lastBuffer) src = CVPixelBufferRetain(_lastBuffer);
        }
        if (!src) {
            usleep(5000); // 5ms
            waitMs += 5;
        }
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
// FIX #2: правильный захват origIMP через указатель
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

                // FIX #2: используем указатель на IMP, чтобы блок захватил адрес,
                // а не значение — значение записывается ПОСЛЕ создания блока
                // через class_replaceMethod, поэтому нужен __block + отдельное хранилище.
                //
                // Правильный паттерн: сохраняем origIMP в отдельный объект-контейнер,
                // который блок захватывает по ссылке.
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

                    // FIX #2: origIMP к этому моменту уже обновлён через replaceMethod ниже,
                    // потому что __block захватывает по ссылке и мы присваиваем до первого вызова.
                    ((void(*)(id, SEL, AVCaptureOutput *, CMSampleBufferRef, AVCaptureConnection *))origIMP)
                        (self_, sel, output, toUse, conn);

                    if (replacement) CFRelease(replacement);
                });

                // FIX #2: правильный порядок — сначала пробуем addMethod.
                // Если не удалось (метод уже на классе) — replaceMethod И обновляем origIMP.
                if (!class_addMethod(cls, sel, newIMP, types)) {
                    // Метод уже на классе — replaceMethod возвращает СТАРЫЙ imp
                    origIMP = class_replaceMethod(cls, sel, newIMP, types);
                }
                // Если class_addMethod успешен — origIMP уже правильный (из method_getImplementation выше)

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
            // FIX: используем Metal-контекст для производительности
            CGImageRef cg = [_v_ciContext createCGImage:ci fromRect:ci.extent];
            if (!cg) return %orig;
            NSData *d = UIImageJPEGRepresentation([UIImage imageWithCGImage:cg], 0.92);
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
// FIX #3: overlay регистрируется в общем множестве и обновляется через dispatch_timer
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

        // FIX #3: регистрируем overlay в глобальном множестве для обновлений
        @synchronized(_overlayLayers) {
            [_overlayLayers addObject:overlay];
        }
        NSLog(@"[MPU] Overlay registered, total: %lu", (unsigned long)_overlayLayers.count);
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    overlay.frame = self.bounds;
    overlay.hidden = NO;
    overlay.opacity = 1.0;
    [CATransaction commit];
}

// FIX: чистим overlay при деаллоке слоя
- (void)removeFromSuperlayer {
    CALayer *overlay = objc_getAssociatedObject(self, "_v_overlay");
    if (overlay) {
        @synchronized(_overlayLayers) {
            [_overlayLayers removeObject:overlay];
        }
    }
    %orig;
}

%end

// ========================================
// 4. ПРОГРЕВ ПРИ ЗАПРОСЕ КАМЕРЫ
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

// FIX #4: дополнительный хук — многие приложения используют именно этот метод
+ (NSArray<AVCaptureDevice *> *)devicesWithMediaType:(AVMediaType)mediaType {
    if (_enabled && [mediaType isEqualToString:AVMediaTypeVideo]) {
        _v_init();
    }
    return %orig;
}

%end

// ========================================
// FIX #4: хук AVCaptureSession для гарантированного прогрева
// ========================================

%hook AVCaptureSession

- (void)startRunning {
    if (_enabled) {
        _v_init();
        NSLog(@"[MPU] AVCaptureSession startRunning intercepted");
    }
    %orig;
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

        // Системные процессы — не трогаем
        if ([bid hasPrefix:@"com.apple.springboard"]) return;
        if ([bid hasPrefix:@"com.apple.WebKit"]) return;
        if ([bid hasPrefix:@"com.apple.mediaserverd"]) return;
        if ([bid hasPrefix:@"com.apple.assetsd"]) return;
        if ([bid hasPrefix:@"com.apple.coremedia"]) return;
        if ([bid hasPrefix:@"com.apple.avconferenced"]) return;
        // FIX #4: cameracaptured оставляем — именно он нужен для Telegram/WhatsApp/Instagram
        // if ([bid hasPrefix:@"com.apple.cameracaptured"]) return;  // <-- УБРАНО

        NSString *path = [[NSBundle mainBundle] bundlePath];
        if ([path hasPrefix:@"/usr/"]) return;
        if ([path hasPrefix:@"/System/Library/PrivateFrameworks/"]) return;
        if ([path hasPrefix:@"/System/Library/Frameworks/"]) return;

        // Инициализация
        _v_lock = [NSObject new];
        _overlayLayers = [NSMutableSet new];

        // FIX: Metal CIContext для производительности
        NSDictionary *ciOpts = @{ kCIContextUseSoftwareRenderer: @NO };
        _v_ciContext = [CIContext contextWithOptions:ciOpts];

        _v_loadPrefs();

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL, _v_prefsChanged,
            CFSTR("com.proximacore.mediaplaybackutils/prefsChanged"),
            NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

        if (_enabled) {
            NSLog(@"[MPU] Tweak v1.4.3 enabled for bundle: %@ (exec=%@, url=%@)", bid, exec, _url);
            %init;
            // FIX #3: запускаем таймер обновления overlay
            dispatch_async(dispatch_get_main_queue(), ^{
                _v_startOverlayDisplayLink();
            });
        } else {
            NSLog(@"[MPU] Tweak disabled in preferences for: %@", bid);
        }
    }
}
