// Tweak.x - MediaPlaybackUtils v1.4.2 (FIXED v2)

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

// FIX 1: serial queue для управления стримом — исключает race condition
static dispatch_queue_t _streamQueue = nil;
static BOOL _streamStarted = NO;

static void _v_init_stream_on_queue(void) {
    // Должна вызываться ТОЛЬКО из _streamQueue
    if (_reader) {
        [_reader stopStreaming];
        _reader = nil;
        // Даём время на async-остановку AVPlayer (stopHLSStream внутри делает dispatch_async main)
        // Ждём через семафор чтобы main queue успел обработать остановку
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_main_queue(), ^{
            dispatch_semaphore_signal(sem);
        });
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)));
    }

    @synchronized(_v_lock) {
        if (_lastBuffer) {
            CVPixelBufferRelease(_lastBuffer);
            _lastBuffer = NULL;
        }
    }

    NSURL *u = [NSURL URLWithString:_url];
    if (!u) { NSLog(@"[MPU] Bad URL: %@", _url); return; }

    _reader = [[_MPUMediaBufferAdapter alloc] initWithURL:u];
    _reader.pixelBufferCallback = ^(CVPixelBufferRef buffer) {
        if (!buffer) return;
        @synchronized(_v_lock) {
            if (_lastBuffer) CVPixelBufferRelease(_lastBuffer);
            _lastBuffer = CVPixelBufferRetain(buffer);
        }
    };
    [_reader startStreaming];
    _streamStarted = YES;
    NSLog(@"[MPU] Stream started: %@", _url);
}

static void _v_init(void) {
    dispatch_async(_streamQueue, ^{
        if (!_streamStarted) {
            _v_init_stream_on_queue();
        }
    });
}

static void _v_reinit(void) {
    dispatch_async(_streamQueue, ^{
        NSLog(@"[MPU] Reinitializing stream with new URL: %@", _url);
        _streamStarted = NO;
        _v_init_stream_on_queue();
    });
}

static void _v_loadPrefs(void) {
    CFPreferencesAppSynchronize(MPU_PREFS_ID);

    CFPropertyListRef en = CFPreferencesCopyAppValue(CFSTR("enabled"), MPU_PREFS_ID);
    if (en) {
        if (CFGetTypeID(en) == CFBooleanGetTypeID())
            _enabled = CFBooleanGetValue((CFBooleanRef)en);
        CFRelease(en);
    }

    NSString *oldUrl = [_url copy];
    CFPropertyListRef u = CFPreferencesCopyAppValue(CFSTR("rtspURL"), MPU_PREFS_ID);
    if (u) {
        if (CFGetTypeID(u) == CFStringGetTypeID()) {
            NSString *s = (__bridge NSString *)u;
            if (s.length > 0) _url = [s copy];
        }
        CFRelease(u);
    }

    // FIX 1: URL сменился — реинициализируем стрим через serial queue
    if (![oldUrl isEqualToString:_url]) {
        NSLog(@"[MPU] URL changed: %@ -> %@", oldUrl, _url);
        _v_reinit();
    }
}

static void _v_prefsChanged(CFNotificationCenterRef c, void *o,
                             CFStringRef n, const void *obj,
                             CFDictionaryRef ui) {
    _v_loadPrefs();
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

// Вспомогательная функция: рендер нашего буфера в CGContext (для превью)
static void _v_drawLastBufferInContext(CGContextRef ctx, CGRect rect) {
    CVPixelBufferRef src = NULL;
    @synchronized(_v_lock) {
        if (_lastBuffer) src = CVPixelBufferRetain(_lastBuffer);
    }
    if (!src) return;

    CIImage *ci = [CIImage imageWithCVPixelBuffer:src];
    CVPixelBufferRelease(src);
    if (!ci) return;

    CGImageRef cg = [_v_ciContext createCGImage:ci fromRect:ci.extent];
    if (!cg) return;

    // Флипаем координаты (CoreGraphics Y-ось снизу, CALayer — сверху)
    CGContextSaveGState(ctx);
    CGContextTranslateCTM(ctx, 0, rect.size.height);
    CGContextScaleCTM(ctx, 1.0, -1.0);
    CGContextDrawImage(ctx, rect, cg);
    CGContextRestoreGState(ctx);
    CGImageRelease(cg);
}

// ========================================
// 1. ПЕРЕХВАТ ДЕЛЕГАТА ВИДЕО-ВЫВОДА
// ========================================

%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate
                          queue:(dispatch_queue_t)queue {
    if (!_enabled || !delegate) { %orig; return; }

    _v_init();

    static NSMutableSet *swizzled = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ swizzled = [NSMutableSet new]; });

    Class cls = object_getClass(delegate);
    NSString *clsName = NSStringFromClass(cls);
    SEL sel = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);

    @synchronized(swizzled) {
        if (![swizzled containsObject:clsName]) {
            Method m = class_getInstanceMethod(cls, sel);
            if (m) {
                const char *types = method_getTypeEncoding(m);
                __block IMP origIMP = method_getImplementation(m);
                IMP newIMP = imp_implementationWithBlock(^(id self_,
                                                           AVCaptureOutput *output,
                                                           CMSampleBufferRef sb,
                                                           AVCaptureConnection *conn) {
                    CMSampleBufferRef rep = _enabled ? _v_makeReplacementSampleBuffer(sb) : NULL;
                    ((void(*)(id,SEL,AVCaptureOutput*,CMSampleBufferRef,AVCaptureConnection*))origIMP)
                        (self_, sel, output, rep ? rep : sb, conn);
                    if (rep) CFRelease(rep);
                });
                if (!class_addMethod(cls, sel, newIMP, types))
                    origIMP = class_replaceMethod(cls, sel, newIMP, types);
                [swizzled addObject:clsName];
                NSLog(@"[MPU] Swizzled video delegate: %@", clsName);
            }
        }
    }
    %orig;
}

%end

// ========================================
// 2. ПЕРЕХВАТ ФОТО — AVCapturePhoto
// ========================================

%hook AVCapturePhoto

- (CVPixelBufferRef)pixelBuffer {
    @synchronized(_v_lock) {
        if (_enabled && _lastBuffer)
            return (CVPixelBufferRef)CFAutorelease(CFRetain(_lastBuffer));
    }
    return %orig;
}

- (CGImageRef)CGImageRepresentation {
    @synchronized(_v_lock) {
        if (_enabled && _lastBuffer) {
            CIImage *ci = [CIImage imageWithCVPixelBuffer:_lastBuffer];
            if (ci) {
                CGImageRef cg = [_v_ciContext createCGImage:ci fromRect:ci.extent];
                if (cg) return (CGImageRef)CFAutorelease(cg);
            }
        }
    }
    return %orig;
}

- (NSData *)fileDataRepresentation {
    @synchronized(_v_lock) {
        if (_enabled && _lastBuffer) {
            CIImage *ci = [CIImage imageWithCVPixelBuffer:_lastBuffer];
            if (!ci) return %orig;
            CGImageRef cg = [_v_ciContext createCGImage:ci fromRect:ci.extent];
            if (!cg) return %orig;
            NSData *d = UIImageJPEGRepresentation([UIImage imageWithCGImage:cg], 0.95);
            CGImageRelease(cg);
            if (d) return d;
        }
    }
    return %orig;
}

%end

// ========================================
// 3. ПРЕДПРОСМОТР КАМЕРЫ — overlay
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

// FIX 2: Camera.app снимает snapshot слоя для превью-миниатюры через renderInContext:
// Перехватываем и рисуем наш буфер вместо реального превью
- (void)renderInContext:(CGContextRef)ctx {
    if (!_enabled) { %orig; return; }

    CGRect bounds = self.bounds;
    // Сначала заливаем чёрным (перекрываем реальную камеру)
    CGContextSetFillColorWithColor(ctx, [UIColor blackColor].CGColor);
    CGContextFillRect(ctx, bounds);

    // Рисуем наш стрим-буфер
    _v_drawLastBufferInContext(ctx, bounds);
    NSLog(@"[MPU] renderInContext intercepted for preview thumbnail");
}

%end

// ========================================
// FIX 2: Превью-миниатюра — перехват snapshot UIView
// Camera.app использует [view snapshotViewAfterScreenUpdates:] или
// [layer renderInContext:] на UIView.layer для создания миниатюры.
// Хукаем UIView чтобы перехватить этот момент.
// ========================================

%hook UIView

- (UIView *)snapshotViewAfterScreenUpdates:(BOOL)afterUpdates {
    UIView *result = %orig;
    if (!_enabled || !_lastBuffer) return result;

    // Проверяем — содержит ли эта view AVCaptureVideoPreviewLayer где-то в иерархии?
    BOOL hasPreviewLayer = NO;
    UIView *v = self;
    while (v) {
        if ([v.layer isKindOfClass:[AVCaptureVideoPreviewLayer class]]) {
            hasPreviewLayer = YES;
            break;
        }
        // Проверяем sublayers
        for (CALayer *l in v.layer.sublayers) {
            if ([l isKindOfClass:[AVCaptureVideoPreviewLayer class]]) {
                hasPreviewLayer = YES;
                break;
            }
        }
        if (hasPreviewLayer) break;
        v = v.superview;
    }

    if (!hasPreviewLayer) return result;

    // Создаём UIView с нашим изображением вместо snapshot реальной камеры
    CVPixelBufferRef src = NULL;
    @synchronized(_v_lock) {
        if (_lastBuffer) src = CVPixelBufferRetain(_lastBuffer);
    }
    if (!src) return result;

    CIImage *ci = [CIImage imageWithCVPixelBuffer:src];
    CVPixelBufferRelease(src);
    if (!ci) return result;

    CGImageRef cg = [_v_ciContext createCGImage:ci fromRect:ci.extent];
    if (!cg) return result;

    UIImageView *fakeSnapshot = [[UIImageView alloc] initWithFrame:self.bounds];
    fakeSnapshot.image = [UIImage imageWithCGImage:cg];
    fakeSnapshot.contentMode = UIViewContentModeScaleAspectFill;
    fakeSnapshot.clipsToBounds = YES;
    CGImageRelease(cg);

    NSLog(@"[MPU] Replaced snapshotView for camera preview thumbnail");
    return fakeSnapshot;
}

%end

// ========================================
// 4. ПРОГРЕВ
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
        _v_ciContext = [CIContext contextWithOptions:nil];

        // FIX 1: создаём serial queue для управления стримом
        _streamQueue = dispatch_queue_create("com.proximacore.mpu.stream", DISPATCH_QUEUE_SERIAL);

        _v_loadPrefs();

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL, _v_prefsChanged,
            CFSTR("com.proximacore.mediaplaybackutils/prefsChanged"),
            NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

        if (_enabled) {
            NSLog(@"[MPU] Enabled for: %@ url=%@", bid, _url);
            %init;
        }
    }
}
