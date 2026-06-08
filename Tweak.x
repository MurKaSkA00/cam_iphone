// Tweak.x - MediaPlaybackUtils v1.4.3
// ПАТЧ: Добавлен хук AVCaptureDeviceInput + AVCaptureSession
// чтобы все приложения всегда использовали только основную (широкоугольную) линзу.

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

// ─────────────────────────────────────────────
// Кэш "основной" камеры (ищем один раз)
// ─────────────────────────────────────────────
static AVCaptureDevice *_wideDevice = nil;

/// Возвращает основную широкоугольную тыловую камеру.
/// Ищет сначала по буквальному типу, потом по дефолту.
static AVCaptureDevice *_v_getWideDevice(void) {
    if (_wideDevice) return _wideDevice;

    // iOS 13+ — пробуем точный тип
    if (@available(iOS 13.0, *)) {
        AVCaptureDevice *d = [AVCaptureDevice
            defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera
                              mediaType:AVMediaTypeVideo
                               position:AVCaptureDevicePositionBack];
        if (d) { _wideDevice = d; return d; }
    }

    // Фолбэк — системный дефолт
    AVCaptureDevice *d = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    _wideDevice = d;
    return d;
}

// ─────────────────────────────────────────────
// PREFERENCES
// ─────────────────────────────────────────────
static void _v_loadPrefs(void) {
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
    CFPreferencesAppSynchronize(MPU_PREFS_ID);
    _v_loadPrefs();
    // Сбрасываем кэш устройства — вдруг сменили URL и хотят переинициализацию
    _wideDevice = nil;
    NSLog(@"[MPU] Preferences reloaded: enabled=%d url=%@", _enabled, _url);
}

// ─────────────────────────────────────────────
// STREAM INIT
// ─────────────────────────────────────────────
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
        NSLog(@"[MPU] Stream initialized: %@", _url);
    });
}

// ─────────────────────────────────────────────
// SAMPLE BUFFER REPLACEMENT
// ─────────────────────────────────────────────
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
// 0. НОВЫЙ ХУК: AVCaptureDeviceInput
//    Принудительно подменяем любую видео-камеру
//    на основную широкоугольную линзу.
// ========================================
%hook AVCaptureDeviceInput

+ (instancetype)deviceInputWithDevice:(AVCaptureDevice *)device
                                error:(NSError **)outError {
    if (_enabled && [device.mediaType isEqualToString:AVMediaTypeVideo]) {
        AVCaptureDevice *wide = _v_getWideDevice();
        if (wide && wide != device) {
            NSLog(@"[MPU] Redirecting device '%@' → wide '%@'",
                  device.localizedName, wide.localizedName);
            device = wide;
        }
    }
    return %orig(device, outError);
}

- (instancetype)initWithDevice:(AVCaptureDevice *)device
                         error:(NSError **)outError {
    if (_enabled && [device.mediaType isEqualToString:AVMediaTypeVideo]) {
        AVCaptureDevice *wide = _v_getWideDevice();
        if (wide && wide != device) {
            NSLog(@"[MPU] initWithDevice redirect '%@' → wide '%@'",
                  device.localizedName, wide.localizedName);
            device = wide;
        }
    }
    return %orig(device, outError);
}

%end

// ========================================
// 0b. НОВЫЙ ХУК: AVCaptureSession
//     Блокируем добавление input'а с нежелательной камерой.
//     Работает как второй рубеж защиты.
// ========================================
%hook AVCaptureSession

- (void)addInput:(AVCaptureInput *)input {
    if (_enabled && [input isKindOfClass:[AVCaptureDeviceInput class]]) {
        AVCaptureDeviceInput *di = (AVCaptureDeviceInput *)input;
        AVCaptureDevice *dev = di.device;

        if ([dev.mediaType isEqualToString:AVMediaTypeVideo]) {
            AVCaptureDevice *wide = _v_getWideDevice();

            // Если это НЕ наша основная камера — подменяем input
            if (wide && dev != wide) {
                NSError *err = nil;
                AVCaptureDeviceInput *wideInput = [AVCaptureDeviceInput
                    deviceInputWithDevice:wide error:&err];
                if (wideInput && !err) {
                    NSLog(@"[MPU] addInput: replaced '%@' with wide camera", dev.localizedName);
                    // Проверяем, нет ли уже такого input'а в сессии
                    for (AVCaptureInput *existing in self.inputs) {
                        if ([existing isKindOfClass:[AVCaptureDeviceInput class]]) {
                            AVCaptureDeviceInput *ei = (AVCaptureDeviceInput *)existing;
                            if (ei.device == wide) {
                                NSLog(@"[MPU] addInput: wide already added, skipping");
                                return; // уже есть — не добавляем дубликат
                            }
                        }
                    }
                    %orig(wideInput);
                    return;
                }
            }
        }
    }
    %orig;
}

// Также блокируем переключение зума/камеры через videoZoomFactor напрямую
// (некоторые приложения так переключают линзы)
- (BOOL)canAddInput:(AVCaptureInput *)input {
    if (_enabled && [input isKindOfClass:[AVCaptureDeviceInput class]]) {
        AVCaptureDeviceInput *di = (AVCaptureDeviceInput *)input;
        AVCaptureDevice *dev = di.device;
        AVCaptureDevice *wide = _v_getWideDevice();

        // Разрешаем добавлять только широкоугольную или не-видео input
        if ([dev.mediaType isEqualToString:AVMediaTypeVideo] && wide && dev != wide) {
            NSLog(@"[MPU] canAddInput: blocked non-wide camera '%@'", dev.localizedName);
            return NO;
        }
    }
    return %orig;
}

%end

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
            if (surf) overlay.contents = (__bridge id)surf;
        }
    }
    [CATransaction commit];
}

%end

// ========================================
// 4. ПРОГРЕВ КАМЕРЫ
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

        // Если приложение запрашивает НЕ широкоугольную тыловую камеру —
        // возвращаем нашу основную. Это работает для getDevice-запросов
        // (в дополнение к хуку AVCaptureDeviceInput выше).
        if (position == AVCaptureDevicePositionBack) {
            NSString *dt = deviceType;
            BOOL isWide = [dt isEqualToString:AVCaptureDeviceTypeBuiltInWideAngleCamera];
            if (!isWide) {
                AVCaptureDevice *wide = _v_getWideDevice();
                if (wide) {
                    NSLog(@"[MPU] defaultDeviceWithDeviceType: redirecting '%@' → wide", deviceType);
                    return wide;
                }
            }
        }
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

        _v_lock = [NSObject new];
        _v_ciContext = [CIContext contextWithOptions:nil];

        _v_loadPrefs();

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL, _v_prefsChanged,
            CFSTR("com.proximacore.mediaplaybackutils/prefsChanged"),
            NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

        if (_enabled) {
            NSLog(@"[MPU] v1.4.3 enabled for bundle: %@ (exec=%@, url=%@)", bid, exec, _url);
            %init;
        } else {
            NSLog(@"[MPU] Tweak disabled in preferences for: %@", bid);
        }
    }
}
