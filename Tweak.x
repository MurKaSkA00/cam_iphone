// Tweak.x - MediaPlaybackUtils v1.4.2

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "_MPUMediaBufferAdapter.h"

#define MPU_PREFS_ID CFSTR("com.proximacore.mediaplaybackutils")

static BOOL _enabled = YES;
// ИСПРАВЛЕНИЕ: убрали инициализацию строкой @"http://..." на уровне файла.
// Компилятор разбирал "http:" как метку (label) языка C, а "//..." — как комментарий,
// из-за чего переменная _url фактически не объявлялась → 9 ошибок "undeclared identifier".
// Теперь значение по умолчанию выставляется внутри _v_loadPrefs(), где это безопасно.
static NSString *_url = nil;

static _MPUMediaBufferAdapter *_reader = nil;
static CVPixelBufferRef _lastBuffer = NULL;
static id _v_lock = nil;
static CIContext *_v_ciContext = nil;

static void _v_loadPrefs(void) {
    // Rootless-safe: использует CFPreferences вместо хардкод-пути
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

    // ИСПРАВЛЕНИЕ: дефолтный URL теперь здесь — внутри функции строковый литерал
    // с "http://" парсится корректно и не путается с C-меткой.
    if (!_url) _url = @"http://192.168.1.44:8888/live/stream/index.m3u8";
}

static void _v_prefsChanged(CFNotificationCenterRef center, void *observer,
                             CFStringRef name, const void *object,
                             CFDictionaryRef userInfo) {
    CFPreferencesAppSynchronize(MPU_PREFS_ID);
    NSString *oldURL = [_url copy];
    _v_loadPrefs();
    NSLog(@"[MPU] Preferences reloaded: enabled=%d url=%@", _enabled, _url);

    // Если URL изменился и стрим уже запущен — перезапускаем
    if (_v_lock && _reader && ![oldURL isEqualToString:_url]) {
        NSLog(@"[MPU] URL changed, restarting stream...");
        [_reader stopStreaming];
        _reader = nil;
        // _v_init() использует dispatch_once, поэтому сбрасываем через пересоздание адаптера напрямую
        NSURL *newU = [NSURL URLWithString:_url];
        if (newU) {
            _reader = [[_MPUMediaBufferAdapter alloc] initWithURL:newU];
            _reader.pixelBufferCallback = ^(CVPixelBufferRef buffer) {
                if (!buffer) return;
                @synchronized(_v_lock) {
                    if (_lastBuffer) CVPixelBufferRelease(_lastBuffer);
                    _lastBuffer = CVPixelBufferRetain(buffer);
                }
            };
            [_reader startStreaming];
            NSLog(@"[MPU] Stream restarted with new URL: %@", _url);
        }
    }
}

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
        NSLog(@"[MPU] Stream initialized and started: %@", _url);
    });
}

// Создаём новый CMSampleBuffer из _lastBuffer с таймингом оригинала (или дефолтным).
// Возвращает retained буфер — вызывающий обязан освободить, либо NULL.
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
        // используем тайминг оригинального буфера
    } else {
        timing.duration               = CMTimeMake(1, 30);
        timing.presentationTimeStamp  = CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000000);
        timing.decodeTimeStamp        = kCMTimeInvalid;
    }

    CMSampleBufferRef out = NULL;
    OSStatus s = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, src, fmt, &timing, &out);
    CFRelease(fmt);
    CVPixelBufferRelease(src);
    return (s == noErr) ? out : NULL;
}

// ========================================
// 1. ПЕРЕХВАТ ДЕЛЕГАТА ВИДЕО-ВЫВОДА (правильный swizzling)
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

                // Безопасно: добавляем override на cls. Если метод УЖЕ на cls (не inherited) —
                // используем class_replaceMethod, чтобы НЕ мутировать суперкласс.
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
// ========================================

%hook AVCapturePhoto

- (CVPixelBufferRef)pixelBuffer {
    @synchronized(_v_lock) {
        if (_enabled && _lastBuffer) {
            NSLog(@"[MPU] Returning virtual buffer for photo");
            // Getter-семантика: возвращаем autoreleased, чтобы избежать утечки
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
// 3. ПЕРЕХВАТ ПРЕДПРОСМОТРА КАМЕРЫ (визуальная подмена)
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
        overlay.zPosition       = 999999;
        overlay.backgroundColor = [UIColor blackColor].CGColor;
        overlay.opaque          = YES;
        [self addSublayer:overlay];
        objc_setAssociatedObject(self, "_v_overlay", overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    overlay.frame   = self.bounds;
    overlay.hidden  = NO;
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
// 4. ПРОГРЕВ: перехват создания устройства камеры
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
        NSString *bid  = [[NSBundle mainBundle] bundleIdentifier];
        NSString *exec = [[NSBundle mainBundle] executablePath].lastPathComponent ?: @"";

        // Не активируем в SpringBoard и системных демонах
        if (!bid) return;
        if ([bid hasPrefix:@"com.apple.springboard"])    return;
        if ([bid hasPrefix:@"com.apple.WebKit"])         return;
        if ([bid hasPrefix:@"com.apple.mediaserverd"])   return;
        if ([bid hasPrefix:@"com.apple.assetsd"])        return;
        if ([bid hasPrefix:@"com.apple.coremedia"])      return;
        if ([bid hasPrefix:@"com.apple.avconferenced"])  return;
        if ([bid hasPrefix:@"com.apple.cameracaptured"]) return;

        NSString *path = [[NSBundle mainBundle] bundlePath];
        if ([path hasPrefix:@"/usr/"])                                  return;
        if ([path hasPrefix:@"/System/Library/PrivateFrameworks/"])     return;
        if ([path hasPrefix:@"/System/Library/Frameworks/"])            return;

        // Инициализируем lock и CIContext ДО любых хуков
        _v_lock     = [NSObject new];
        _v_ciContext = [CIContext contextWithOptions:nil];

        // Читаем prefs через CFPreferences (rootless-safe)
        // _url получает дефолтное значение здесь же, если не задан в настройках
        _v_loadPrefs();

        // Подписываемся на изменения prefs (live update без перезапуска приложения)
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL, _v_prefsChanged,
            CFSTR("com.proximacore.mediaplaybackutils/prefsChanged"),
            NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

        if (_enabled) {
            NSLog(@"[MPU] Tweak enabled for bundle: %@ (exec=%@, url=%@)", bid, exec, _url);
            %init;
        } else {
            NSLog(@"[MPU] Tweak disabled in preferences for: %@", bid);
        }
    }
}
