// Tweak.x - MediaPlaybackUtils v1.4.2 [FIXED]
// Исправления:
//   1. Захват origIMP в блок — теперь через указатель, нет риска crash/рекурсии
//   2. GPU CIContext-рендер вынесен за пределы @synchronized(_v_lock)
//   3. AVCaptureVideoPreviewLayer обновляется через CADisplayLink, а не только в layoutSublayers
//   4. Лог при невалидном URL вместо тихого игнорирования

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "_MPUMediaBufferAdapter.h"

#define MPU_PREFS_ID CFSTR("com.proximacore.mediaplaybackutils")

static BOOL              _enabled     = YES;
static NSString         *_url         = @"http://192.168.1.44:8888/live";
static _MPUMediaBufferAdapter *_reader = nil;
static CVPixelBufferRef  _lastBuffer  = NULL;
static id                _v_lock      = nil;
static CIContext        *_v_ciContext = nil;

// CADisplayLink для обновления preview-overlay каждый кадр
static CADisplayLink    *_v_displayLink = nil;
// Все overlay-слои по всем AVCaptureVideoPreviewLayer-инстансам
static NSHashTable      *_v_overlays   = nil;

// ----------------------------------------
// Preferences
// ----------------------------------------

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
    NSLog(@"[MPU] Preferences reloaded: enabled=%d url=%@", _enabled, _url);
}

// ----------------------------------------
// CADisplayLink callback — обновляем все overlay слои каждый кадр
// ----------------------------------------

static void _v_displayLinkTick(CADisplayLink *dl) {
    CVPixelBufferRef buf = NULL;
    @synchronized(_v_lock) {
        if (_lastBuffer) buf = CVPixelBufferRetain(_lastBuffer);
    }
    if (!buf) return;

    IOSurfaceRef surf = CVPixelBufferGetIOSurface(buf);
    if (surf) {
        id surfObj = (__bridge id)surf;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        @synchronized(_v_overlays) {
            for (CALayer *overlay in _v_overlays) {
                overlay.contents = surfObj;
            }
        }
        [CATransaction commit];
    }
    CVPixelBufferRelease(buf);
}

// ----------------------------------------
// Инициализация стрима
// ----------------------------------------

static void _v_init(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // [FIX #4] Явный лог при невалидном URL
        NSURL *u = [NSURL URLWithString:_url];
        if (!u) {
            NSLog(@"[MPU] ERROR: Invalid stream URL: '%@' — tweak will not work!", _url);
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
        NSLog(@"[MPU] Stream initialized and started: %@", _url);

        // [FIX #3] Запускаем CADisplayLink на main run loop для обновления overlay
        _v_overlays    = [NSHashTable weakObjectsHashTable];
        _v_displayLink = [CADisplayLink displayLinkWithTarget:[NSBlockOperation blockOperationWithBlock:^{}]
                                                     selector:@selector(main)];
        // Переопределяем через category-less approach — используем NSObject target
        // Вместо этого создаём через обёртку:
        // CADisplayLink напрямую не принимает блок, используем вспомогательный объект
    });
}

// Вспомогательный класс-таргет для CADisplayLink
@interface _MPUDisplayLinkTarget : NSObject
@end
@implementation _MPUDisplayLinkTarget
- (void)tick:(CADisplayLink *)dl { _v_displayLinkTick(dl); }
@end

static void _v_startDisplayLink(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        _v_overlays = [NSHashTable weakObjectsHashTable];
        dispatch_async(dispatch_get_main_queue(), ^{
            _MPUDisplayLinkTarget *target = [_MPUDisplayLinkTarget new];
            // Держим target живым через ассоциацию с AppDelegate или статику
            static _MPUDisplayLinkTarget *_keepAlive __attribute__((unused));
            _keepAlive = target;

            _v_displayLink = [CADisplayLink displayLinkWithTarget:target selector:@selector(tick:)];
            _v_displayLink.preferredFramesPerSecond = 30;
            [_v_displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        });
    });
}

// ----------------------------------------
// Построение replacement CMSampleBuffer
// ----------------------------------------

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
        // используем оригинальный тайминг
    } else {
        timing.duration             = CMTimeMake(1, 30);
        timing.presentationTimeStamp = CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000000);
        timing.decodeTimeStamp      = kCMTimeInvalid;
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
    _v_startDisplayLink();

    static NSMutableSet *swizzledClassNames = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ swizzledClassNames = [NSMutableSet new]; });

    Class cls     = object_getClass(delegate);
    NSString *clsName = NSStringFromClass(cls);
    SEL sel       = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);

    @synchronized(swizzledClassNames) {
        if (![swizzledClassNames containsObject:clsName]) {
            Method m = class_getInstanceMethod(cls, sel);
            if (m) {
                const char *types = method_getTypeEncoding(m);

                // [FIX #1] origIMP хранится в отдельной heap-переменной, доступной блоку по указателю.
                // Это гарантирует, что блок всегда вызывает актуальный original IMP.
                __block IMP *origIMPPtr = (IMP *)malloc(sizeof(IMP));
                *origIMPPtr = method_getImplementation(m);

                IMP newIMP = imp_implementationWithBlock(^(id self_,
                                                           AVCaptureOutput *output,
                                                           CMSampleBufferRef sb,
                                                           AVCaptureConnection *conn) {
                    CMSampleBufferRef replacement = NULL;
                    if (_enabled) {
                        replacement = _v_makeReplacementSampleBuffer(sb);
                    }
                    CMSampleBufferRef toUse = replacement ? replacement : sb;
                    ((void(*)(id, SEL, AVCaptureOutput *, CMSampleBufferRef, AVCaptureConnection *))(*origIMPPtr))
                        (self_, sel, output, toUse, conn);
                    if (replacement) CFRelease(replacement);
                });

                if (!class_addMethod(cls, sel, newIMP, types)) {
                    // Метод уже определён прямо на cls — заменяем и получаем старый IMP
                    *origIMPPtr = class_replaceMethod(cls, sel, newIMP, types);
                } else {
                    // Метод добавлен на cls; origIMP — реализация из суперкласса (уже записана выше)
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
    if (!_enabled) return %orig;

    // [FIX #2] Копируем буфер под локом, рендерим CIImage — за его пределами.
    CVPixelBufferRef localBuffer = NULL;
    @synchronized(_v_lock) {
        if (_lastBuffer) localBuffer = CVPixelBufferRetain(_lastBuffer);
    }
    if (!localBuffer) return %orig;

    CIImage *ci  = [CIImage imageWithCVPixelBuffer:localBuffer];
    CVPixelBufferRelease(localBuffer);

    CGImageRef cg = [_v_ciContext createCGImage:ci fromRect:ci.extent];
    if (!cg) return %orig;

    NSData *d = UIImageJPEGRepresentation([UIImage imageWithCGImage:cg], 0.9);
    CGImageRelease(cg);
    NSLog(@"[MPU] Returning virtual photo data");
    return d;
}

%end

// ========================================
// 3. ПЕРЕХВАТ ПРЕДПРОСМОТРА КАМЕРЫ
// [FIX #3] layout создаёт overlay, а обновление картинки — через CADisplayLink (см. _v_displayLinkTick)
// ========================================

%hook AVCaptureVideoPreviewLayer

- (void)layoutSublayers {
    %orig;
    if (!_enabled) return;

    _v_init();
    _v_startDisplayLink();

    CALayer *overlay = objc_getAssociatedObject(self, "_v_overlay");
    if (!overlay) {
        overlay = [CALayer layer];
        overlay.contentsGravity  = kCAGravityResizeAspectFill;
        overlay.zPosition        = 999999;
        overlay.backgroundColor  = [UIColor blackColor].CGColor;
        overlay.opaque           = YES;
        [self addSublayer:overlay];
        objc_setAssociatedObject(self, "_v_overlay", overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        // Регистрируем overlay в глобальной таблице для CADisplayLink
        @synchronized(_v_overlays) {
            [_v_overlays addObject:overlay];
        }
        NSLog(@"[MPU] PreviewLayer overlay created and registered");
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    overlay.frame  = self.bounds;
    overlay.hidden = NO;
    overlay.opacity = 1.0;
    [CATransaction commit];
}

%end

// ========================================
// 4. ЛОГ СОЗДАНИЯ УСТРОЙСТВА КАМЕРЫ (прогрев)
// ========================================

%hook AVCaptureDevice

+ (AVCaptureDevice *)defaultDeviceWithMediaType:(AVMediaType)mediaType {
    if (_enabled && [mediaType isEqualToString:AVMediaTypeVideo]) {
        _v_init();
        _v_startDisplayLink();
    }
    return %orig;
}

+ (AVCaptureDevice *)defaultDeviceWithDeviceType:(AVCaptureDeviceType)deviceType
                                       mediaType:(AVMediaType)mediaType
                                        position:(AVCaptureDevicePosition)position {
    if (_enabled && [mediaType isEqualToString:AVMediaTypeVideo]) {
        _v_init();
        _v_startDisplayLink();
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
        NSString *path = [[NSBundle mainBundle] bundlePath];

        if (!bid) return;
        if ([bid hasPrefix:@"com.apple.springboard"])              return;
        if ([bid hasPrefix:@"com.apple.WebKit"])                   return;
        if ([bid hasPrefix:@"com.apple.mediaserverd"])             return;
        if ([bid hasPrefix:@"com.apple.assetsd"])                  return;
        if ([bid hasPrefix:@"com.apple.coremedia"])                return;
        if ([bid hasPrefix:@"com.apple.avconferenced"])            return;
        if ([bid hasPrefix:@"com.apple.cameracaptured"])           return;
        if ([path hasPrefix:@"/usr/"])                             return;
        if ([path hasPrefix:@"/System/Library/PrivateFrameworks/"]) return;
        if ([path hasPrefix:@"/System/Library/Frameworks/"])       return;

        _v_lock      = [NSObject new];
        _v_ciContext = [CIContext contextWithOptions:nil];

        _v_loadPrefs();

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL, _v_prefsChanged,
            CFSTR("com.proximacore.mediaplaybackutils/prefsChanged"),
            NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

        NSString *exec = [[NSBundle mainBundle] executablePath].lastPathComponent ?: @"";
        if (_enabled) {
            NSLog(@"[MPU] Tweak enabled for bundle: %@ (exec=%@, url=%@)", bid, exec, _url);
            %init;
        } else {
            NSLog(@"[MPU] Tweak disabled in preferences for: %@", bid);
        }
    }
}
