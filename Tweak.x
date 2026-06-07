// Tweak.x - MediaPlaybackUtils v1.5.0
// Покрывает ВСЕ пути AVFoundation:
//   1. AVCaptureVideoDataOutput  (делегат sampleBuffer)
//   2. AVCapturePhotoOutput      (фото через didFinishProcessingPhoto)
//   3. AVCaptureVideoPreviewLayer (визуальное превью)
//   4. AVSampleBufferDisplayLayer (альтернативное превью - Zoom, Teams и т.д.)
//   5. AVCaptureSession          (прогрев как можно раньше)
//   6. UIImagePickerController   (системный picker - нативная камера iOS)

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "_MPUMediaBufferAdapter.h"

// FrameProcessor forward — объявляем только то, что нам нужно,
// чтобы не зависеть от порядка компиляции .h при Logos-preprocessing
@interface _MPUFrameProcessor : NSObject
+ (instancetype)sharedProcessor;
- (CVPixelBufferRef _Nullable)processBuffer:(CVPixelBufferRef)src CF_RETURNS_RETAINED;
- (CMSampleTimingInfo)jitteredTimingFromTiming:(CMSampleTimingInfo)t;
@end

#define MPU_PREFS_ID CFSTR("com.proximacore.mediaplaybackutils")

// ============================================================
// ГЛОБАЛЬНОЕ СОСТОЯНИЕ
// ============================================================

static BOOL            _enabled     = YES;
static NSString       *_url         = @"http://192.168.1.44:8888/live";
static _MPUMediaBufferAdapter *_reader = nil;
static CVPixelBufferRef _lastBuffer  = NULL;
static id              _v_lock       = nil;
// CIContext per-thread — избегаем краша от non-thread-safe single instance
static NSString *const kCIContextKey = @"MPU_CIContext";

static CIContext *_v_ciContextForCurrentThread(void) {
    NSMutableDictionary *td = [NSThread currentThread].threadDictionary;
    CIContext *ctx = td[kCIContextKey];
    if (!ctx) {
        ctx = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @NO}];
        td[kCIContextKey] = ctx;
    }
    return ctx;
}

// ============================================================
// PREFERENCES
// ============================================================

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
    NSLog(@"[MPU] Prefs reloaded: enabled=%d url=%@", _enabled, _url);
}

// ============================================================
// ИНИЦИАЛИЗАЦИЯ СТРИМА
// ============================================================

static void _v_init(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURL *u = [NSURL URLWithString:_url];
        if (!u) return;

        _reader = [[_MPUMediaBufferAdapter alloc] initWithURL:u];
        _reader.pixelBufferCallback = ^(CVPixelBufferRef buffer) {
            if (!buffer) return;
            // Конвертируем через FrameProcessor в BGRA+IOSurface
            CVPixelBufferRef processed = [[_MPUFrameProcessor sharedProcessor] processBuffer:buffer];
            if (!processed) return;
            @synchronized(_v_lock) {
                if (_lastBuffer) CVPixelBufferRelease(_lastBuffer);
                _lastBuffer = CVPixelBufferRetain(processed);
            }
            CVPixelBufferRelease(processed);
        };

        [_reader startStreaming];
        NSLog(@"[MPU] Stream started: %@", _url);
    });
}

// ============================================================
// ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
// ============================================================

// Строит CMSampleBuffer из _lastBuffer с timing из оригинала (или текущим временем)
static CMSampleBufferRef _v_makeReplacementSampleBuffer(CMSampleBufferRef original) CF_RETURNS_RETAINED {
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
        // Добавляем небольшой jitter чтобы timestamps не были идентичными
        timing = [[_MPUFrameProcessor sharedProcessor] jitteredTimingFromTiming:timing];
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

// Рендерит _lastBuffer в JPEG NSData (для фото-хуков)
static NSData *_v_makeJPEGData(void) {
    CVPixelBufferRef src = NULL;
    @synchronized(_v_lock) {
        if (_lastBuffer) src = CVPixelBufferRetain(_lastBuffer);
    }
    if (!src) return nil;

    CIImage *ci = [CIImage imageWithCVPixelBuffer:src];
    CVPixelBufferRelease(src);

    CIContext *ctx = _v_ciContextForCurrentThread();
    CGImageRef cg  = [ctx createCGImage:ci fromRect:ci.extent];
    if (!cg) return nil;

    NSData *d = UIImageJPEGRepresentation([UIImage imageWithCGImage:cg], 0.92);
    CGImageRelease(cg);
    return d;
}

// Обновляет overlay на любом CALayer (превью)
static void _v_updateOverlay(CALayer *hostLayer) {
    if (!_enabled) return;

    CALayer *overlay = objc_getAssociatedObject(hostLayer, "_v_overlay");
    if (!overlay) {
        overlay = [CALayer layer];
        overlay.contentsGravity = kCAGravityResizeAspectFill;
        overlay.zPosition       = 999999;
        overlay.backgroundColor = [UIColor blackColor].CGColor;
        overlay.opaque          = YES;
        overlay.actions         = @{@"contents": [NSNull null],
                                    @"frame":    [NSNull null]};
        [hostLayer addSublayer:overlay];
        objc_setAssociatedObject(hostLayer, "_v_overlay", overlay,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    overlay.frame  = hostLayer.bounds;
    overlay.hidden = NO;

    @synchronized(_v_lock) {
        if (_lastBuffer) {
            IOSurfaceRef surf = CVPixelBufferGetIOSurface(_lastBuffer);
            if (surf) overlay.contents = (__bridge id)surf;
        }
    }
    [CATransaction commit];
}

// ============================================================
// 1. ПЕРЕХВАТ AVCaptureVideoDataOutput — делегат sampleBuffer
// ============================================================

%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate
                          queue:(dispatch_queue_t)queue {
    if (!_enabled || !delegate) { %orig; return; }
    _v_init();

    static NSMutableSet *swizzled;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ swizzled = [NSMutableSet new]; });

    Class cls   = object_getClass(delegate);
    NSString *n = NSStringFromClass(cls);
    SEL sel     = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);

    @synchronized(swizzled) {
        if (![swizzled containsObject:n]) {
            Method m = class_getInstanceMethod(cls, sel);
            if (m) {
                const char *types = method_getTypeEncoding(m);
                __block IMP origIMP = method_getImplementation(m);

                IMP newIMP = imp_implementationWithBlock(
                    ^(id self_, AVCaptureOutput *output,
                      CMSampleBufferRef sb, AVCaptureConnection *conn) {

                    CMSampleBufferRef rep = _enabled ? _v_makeReplacementSampleBuffer(sb) : NULL;
                    CMSampleBufferRef use = rep ? rep : sb;

                    ((void(*)(id,SEL,AVCaptureOutput*,CMSampleBufferRef,AVCaptureConnection*))
                     origIMP)(self_, sel, output, use, conn);

                    if (rep) CFRelease(rep);
                });

                if (!class_addMethod(cls, sel, newIMP, types))
                    origIMP = class_replaceMethod(cls, sel, newIMP, types);

                [swizzled addObject:n];
                NSLog(@"[MPU] Swizzled VideoDataOutput delegate: %@", n);
            }
        }
    }
    %orig;
}

%end

// ============================================================
// 2. ПЕРЕХВАТ AVCapturePhotoOutput — фото (PhotoKit pipeline)
// ============================================================

// Хукаем делегатный метод через AVCapturePhotoCaptureDelegate
// Так как протокол — не класс, нужно перехватить на уровне AVCapturePhotoOutput

%hook AVCapturePhotoOutput

- (void)capturePhotoWithSettings:(AVCapturePhotoSettings *)settings
                        delegate:(id<AVCapturePhotoCaptureDelegate>)delegate {
    if (!_enabled || !delegate) { %orig; return; }
    _v_init();

    // Свизлим метод didFinishProcessingPhoto на классе делегата
    SEL sel = @selector(captureOutput:didFinishProcessingPhoto:error:);
    Class cls = object_getClass(delegate);
    NSString *clsName = NSStringFromClass(cls);

    static NSMutableSet *swizzledPhoto;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ swizzledPhoto = [NSMutableSet new]; });

    @synchronized(swizzledPhoto) {
        if (![swizzledPhoto containsObject:clsName]) {
            Method m = class_getInstanceMethod(cls, sel);
            if (m) {
                const char *types = method_getTypeEncoding(m);
                __block IMP origIMP = method_getImplementation(m);

                IMP newIMP = imp_implementationWithBlock(
                    ^(id self_, AVCaptureOutput *output,
                      AVCapturePhoto *photo, NSError *error) {

                    // Вызываем оригинал — но AVCapturePhoto.pixelBuffer уже перехвачен ниже
                    ((void(*)(id,SEL,AVCaptureOutput*,AVCapturePhoto*,NSError*))
                     origIMP)(self_, sel, output, photo, error);
                });

                if (!class_addMethod(cls, sel, newIMP, types))
                    origIMP = class_replaceMethod(cls, sel, newIMP, types);

                [swizzledPhoto addObject:clsName];
                NSLog(@"[MPU] Swizzled PhotoOutput delegate: %@", clsName);
            }
        }
    }
    %orig;
}

%end

// Перехватываем данные самого объекта AVCapturePhoto
%hook AVCapturePhoto

- (CVPixelBufferRef)pixelBuffer {
    if (!_enabled) return %orig;
    @synchronized(_v_lock) {
        if (_lastBuffer)
            return (CVPixelBufferRef)CFAutorelease(CFRetain(_lastBuffer));
    }
    return %orig;
}

- (NSData *)fileDataRepresentation {
    if (!_enabled) return %orig;
    NSData *d = _v_makeJPEGData();
    return d ?: %orig;
}

- (NSData *)fileDataRepresentationWithCustomizer:(id)customizer {
    if (!_enabled) return %orig;
    NSData *d = _v_makeJPEGData();
    return d ?: %orig;
}

%end

// ============================================================
// 3. ПРЕВЬЮ — AVCaptureVideoPreviewLayer (стандартный путь)
// ============================================================

%hook AVCaptureVideoPreviewLayer

- (void)layoutSublayers {
    %orig;
    if (!_enabled) return;
    _v_init();
    _v_updateOverlay(self);
}

- (void)setBounds:(CGRect)bounds {
    %orig;
    CALayer *ov = objc_getAssociatedObject(self, "_v_overlay");
    if (ov) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        ov.frame = self.bounds;
        [CATransaction commit];
    }
}

%end

// ============================================================
// 4. ПРЕВЬЮ — AVSampleBufferDisplayLayer
//    Используется Zoom, Teams, WhatsApp, FaceTime-подобными приложениями
// ============================================================

%hook AVSampleBufferDisplayLayer

- (void)enqueueSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (!_enabled) { %orig; return; }
    _v_init();

    // Обновляем overlay на этом слое
    _v_updateOverlay(self);

    // И подменяем сам sampleBuffer (на случай если слой всё же рендерит через буфер)
    CMSampleBufferRef rep = _v_makeReplacementSampleBuffer(sampleBuffer);
    if (rep) {
        %orig(rep);
        CFRelease(rep);
    } else {
        %orig;
    }
}

- (void)layoutSublayers {
    %orig;
    if (_enabled) _v_updateOverlay(self);
}

%end

// ============================================================
// 5. UIImagePickerController — системный picker (нативная камера)
//    Перехватываем делегат imagePickerController:didFinishPickingMediaWithInfo:
// ============================================================

%hook UIImagePickerController

- (void)setDelegate:(id<UIImagePickerControllerDelegate, UINavigationControllerDelegate>)delegate {
    if (!_enabled || !delegate) { %orig; return; }

    SEL sel = @selector(imagePickerController:didFinishPickingMediaWithInfo:);
    Class cls = object_getClass(delegate);
    NSString *clsName = NSStringFromClass(cls);

    static NSMutableSet *swizzledPicker;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ swizzledPicker = [NSMutableSet new]; });

    @synchronized(swizzledPicker) {
        if (![swizzledPicker containsObject:clsName]) {
            Method m = class_getInstanceMethod(cls, sel);
            if (m) {
                const char *types = method_getTypeEncoding(m);
                __block IMP origIMP = method_getImplementation(m);

                IMP newIMP = imp_implementationWithBlock(
                    ^(id self_, UIImagePickerController *picker,
                      NSDictionary<UIImagePickerControllerInfoKey, id> *info) {

                    NSMutableDictionary *mod = [info mutableCopy];

                    // Подменяем UIImage если есть буфер
                    @synchronized(_v_lock) {
                        if (_lastBuffer) {
                            CIImage *ci  = [CIImage imageWithCVPixelBuffer:_lastBuffer];
                            CIContext *ctx = _v_ciContextForCurrentThread();
                            CGImageRef cg = [ctx createCGImage:ci fromRect:ci.extent];
                            if (cg) {
                                UIImage *fakeImg = [UIImage imageWithCGImage:cg];
                                CGImageRelease(cg);
                                if (fakeImg) {
                                    mod[UIImagePickerControllerOriginalImage] = fakeImg;
                                    mod[UIImagePickerControllerEditedImage]   = fakeImg;
                                }
                            }
                        }
                    }

                    ((void(*)(id,SEL,UIImagePickerController*,NSDictionary*))
                     origIMP)(self_, sel, picker, mod);
                });

                if (!class_addMethod(cls, sel, newIMP, types))
                    origIMP = class_replaceMethod(cls, sel, newIMP, types);

                [swizzledPicker addObject:clsName];
                NSLog(@"[MPU] Swizzled ImagePickerController delegate: %@", clsName);
            }
        }
    }
    %orig;
}

%end

// ============================================================
// 6. AVCaptureDevice — прогрев стрима как можно раньше
// ============================================================

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

// ============================================================
// 7. AVCaptureSession — прогрев при startRunning
// ============================================================

%hook AVCaptureSession

- (void)startRunning {
    if (_enabled) _v_init();
    %orig;
}

%end

// ============================================================
// ИНИЦИАЛИЗАЦИЯ ТВИКА
// ============================================================

%ctor {
    @autoreleasepool {
        NSString *bid  = [[NSBundle mainBundle] bundleIdentifier];
        NSString *path = [[NSBundle mainBundle] bundlePath];

        if (!bid) return;

        // Исключаем системные процессы
        NSArray *excluded = @[
            @"com.apple.springboard",
            @"com.apple.WebKit",
            @"com.apple.mediaserverd",
            @"com.apple.assetsd",
            @"com.apple.coremedia",
            @"com.apple.avconferenced",
            @"com.apple.cameracaptured",
            @"com.apple.voicememosd",
        ];
        for (NSString *prefix in excluded) {
            if ([bid hasPrefix:prefix]) return;
        }

        // Системные пути без UI
        if ([path hasPrefix:@"/usr/"]
            || [path hasPrefix:@"/System/Library/PrivateFrameworks/"]
            || [path hasPrefix:@"/System/Library/Frameworks/"]) return;

        // Инициализируем lock ДО хуков
        _v_lock = [NSObject new];

        // Читаем prefs
        _v_loadPrefs();

        // Живое обновление prefs
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL, _v_prefsChanged,
            CFSTR("com.proximacore.mediaplaybackutils/prefsChanged"),
            NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

        if (_enabled) {
            %init;
            NSLog(@"[MPU] v1.5.0 active for: %@", bid);
        } else {
            NSLog(@"[MPU] Disabled for: %@", bid);
        }
    }
}
