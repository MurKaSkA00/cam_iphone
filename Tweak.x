// Tweak.x - MediaPlaybackUtils v1.5.2
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "_MPUMediaBufferAdapter.h"
#import "MPUKeys.h"

// Определение ключа (объявлен в MPUKeys.h, используется и в AntifraudHooks.x)
const void *kOverlayLayerKey = &kOverlayLayerKey;

#define MPU_PREFS_ID CFSTR("com.proximacore.mediaplaybackutils")

static BOOL _enabled = YES;
static NSString *_url = @"http://192.168.1.44:8888/live/stream/index.m3u8";
static _MPUMediaBufferAdapter *_reader = nil;
static CVPixelBufferRef _lastBuffer = NULL;
static BOOL _streamReady = NO;
static id _v_lock = nil;
static CIContext *_v_ciContext = nil;
static NSMutableDictionary *_origIMPs = nil;

// ========================================
// СПИСОК ПРОЦЕССОВ БЕЗ КАМЕРЫ — НЕ ИНЖЕКТИРУЕМ
// ========================================

static BOOL _v_shouldSkipBundle(NSString *bid) {
    if (!bid) return YES;

    static NSArray *excluded = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        excluded = @[
            // Apple системные процессы
            @"com.apple.springboard",
            @"com.apple.WebKit",
            @"com.apple.mediaserverd",
            @"com.apple.assetsd",
            @"com.apple.coremedia",
            @"com.apple.avconferenced",
            @"com.apple.cameracaptured",
            @"com.apple.backboardd",
            @"com.apple.lsd",
            @"com.apple.trustd",
            // Пакетные менеджеры и файловые менеджеры
            @"com.tigisoftware.Filza",
            @"org.coolstar.SileoStore",
            @"com.craigcomstock.sileo",
            @"com.silverhammer.sileo",
            @"xyz.willy.Zebra",
            @"org.thebigboss.cydia",
            @"com.saurik.Cydia",
            @"com.majd.Installer",
            @"co.dynastic.wsim",
            // Наш твик
            @"com.proximacore.mediaplaybackutils",
        ];
    });

    for (NSString *ex in excluded) {
        if ([bid isEqualToString:ex] ||
            [bid hasPrefix:[ex stringByAppendingString:@"."]])
            return YES;
    }

    NSString *path = [[NSBundle mainBundle] bundlePath];
    if ([path hasPrefix:@"/usr/"]) return YES;
    if ([path hasPrefix:@"/System/Library/"]) return YES;
    if ([path hasPrefix:@"/Library/PreferenceBundles/"]) return YES;

    return NO;
}

// ========================================
// PREFS
// ========================================

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

// ========================================
// ИНИЦИАЛИЗАЦИЯ СТРИМА
// ========================================

static void _v_init(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSLog(@"[MPU] _v_init called, url=%@", _url);
        NSURL *u = [NSURL URLWithString:_url];
        if (!u) {
            NSLog(@"[MPU] ERROR: Invalid URL: %@", _url);
            return;
        }
        _reader = [[_MPUMediaBufferAdapter alloc] initWithURL:u];
        if (!_reader) {
            NSLog(@"[MPU] ERROR: Failed to create adapter");
            return;
        }
        _reader.pixelBufferCallback = ^(CVPixelBufferRef buffer) {
            if (!buffer) return;
            @synchronized(_v_lock) {
                if (_lastBuffer) CVPixelBufferRelease(_lastBuffer);
                _lastBuffer = CVPixelBufferRetain(buffer);
                if (!_streamReady) {
                    _streamReady = YES;
                    NSLog(@"[MPU] First frame received! Stream is READY.");
                }
            }
        };
        [_reader startStreaming];
        NSLog(@"[MPU] Adapter startStreaming called");
    });
}

// ========================================
// ПОСТРОЕНИЕ CMSampleBuffer ИЗ СТРИМА
// ========================================

static CMSampleBufferRef _v_makeReplacementSampleBuffer(CMSampleBufferRef original) {
    CVPixelBufferRef src = NULL;
    @synchronized(_v_lock) {
        if (_lastBuffer && _streamReady)
            src = CVPixelBufferRetain(_lastBuffer);
    }
    if (!src) return NULL;

    CVPixelBufferRef finalSrc = src;

    // Масштабируем под размер оригинального буфера
    if (original) {
        CVImageBufferRef origImg = CMSampleBufferGetImageBuffer(original);
        if (origImg) {
            size_t origW = CVPixelBufferGetWidth(origImg);
            size_t origH = CVPixelBufferGetHeight(origImg);
            size_t srcW  = CVPixelBufferGetWidth(src);
            size_t srcH  = CVPixelBufferGetHeight(src);
            if (origW > 0 && origH > 0 && (origW != srcW || origH != srcH)) {
                CIImage *ci = [CIImage imageWithCVPixelBuffer:src];
                CGFloat sx = (CGFloat)origW / srcW;
                CGFloat sy = (CGFloat)origH / srcH;
                ci = [ci imageByApplyingTransform:CGAffineTransformMakeScale(sx, sy)];
                NSDictionary *opts = @{
                    (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
                    (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)
                };
                CVPixelBufferRef scaled = NULL;
                CVPixelBufferCreate(kCFAllocatorDefault, origW, origH,
                    kCVPixelFormatType_32BGRA,
                    (__bridge CFDictionaryRef)opts, &scaled);
                if (scaled) {
                    [_v_ciContext render:ci toCVPixelBuffer:scaled];
                    CVPixelBufferRelease(src);
                    finalSrc = scaled;
                }
            }
        }
    }

    CMVideoFormatDescriptionRef fmt = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(
            kCFAllocatorDefault, finalSrc, &fmt) != noErr || !fmt) {
        CVPixelBufferRelease(finalSrc);
        return NULL;
    }

    CMSampleTimingInfo timing;
    if (original && CMSampleBufferGetSampleTimingInfo(original, 0, &timing) == noErr) {
        // используем тайминг оригинала
    } else {
        timing.duration = CMTimeMake(1, 30);
        timing.presentationTimeStamp =
            CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000000);
        timing.decodeTimeStamp = kCMTimeInvalid;
    }

    CMSampleBufferRef out = NULL;
    OSStatus st = CMSampleBufferCreateReadyWithImageBuffer(
        kCFAllocatorDefault, finalSrc, fmt, &timing, &out);
    CFRelease(fmt);
    CVPixelBufferRelease(finalSrc);

    if (st != noErr) {
        NSLog(@"[MPU] CMSampleBufferCreate failed: %d", (int)st);
        return NULL;
    }
    return out;
}

// ========================================
// СВИЗЛИНГ ДЕЛЕГАТА
// ========================================

static void _v_swizzleDelegate(id delegate) {
    if (!delegate) return;

    Class cls = object_getClass(delegate);
    NSString *clsName = NSStringFromClass(cls);
    SEL sel = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);

    @synchronized(_origIMPs) {
        if (_origIMPs[clsName]) return;

        Method m = class_getInstanceMethod(cls, sel);
        if (!m) {
            NSLog(@"[MPU] Delegate %@ has no captureOutput:didOutputSampleBuffer:", clsName);
            return;
        }

        IMP origIMP = method_getImplementation(m);
        const char *types = method_getTypeEncoding(m);

        _origIMPs[clsName] = [NSValue valueWithPointer:origIMP];

        IMP newIMP = imp_implementationWithBlock(
            ^(id self_, AVCaptureOutput *output,
              CMSampleBufferRef sb, AVCaptureConnection *conn) {

            NSString *name = NSStringFromClass(object_getClass(self_));
            IMP orig = (IMP)[_origIMPs[name] pointerValue];
            if (!orig) return;

            CMSampleBufferRef replacement = NULL;
            if (_enabled && _streamReady)
                replacement = _v_makeReplacementSampleBuffer(sb);

            CMSampleBufferRef toUse = replacement ? replacement : sb;
            ((void(*)(id,SEL,AVCaptureOutput*,CMSampleBufferRef,AVCaptureConnection*))
                orig)(self_, sel, output, toUse, conn);

            if (replacement) CFRelease(replacement);
        });

        BOOL added = class_addMethod(cls, sel, newIMP, types);
        if (!added) {
            IMP replaced = class_replaceMethod(cls, sel, newIMP, types);
            _origIMPs[clsName] = [NSValue valueWithPointer:replaced];
        }

        NSLog(@"[MPU] Swizzled: %@ (added=%d)", clsName, added);
    }
}

// ========================================
// ХУКИ
// ========================================

%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate
                          queue:(dispatch_queue_t)queue {
    NSLog(@"[MPU] setSampleBufferDelegate: %@",
          NSStringFromClass(object_getClass(delegate)));
    if (_enabled && delegate) {
        _v_init();
        _v_swizzleDelegate(delegate);
    }
    %orig;
}

%end

%hook AVCaptureSession

- (void)startRunning {
    NSLog(@"[MPU] AVCaptureSession startRunning");
    if (_enabled) _v_init();
    %orig;
    if (_enabled) {
        for (AVCaptureOutput *output in self.outputs) {
            if ([output isKindOfClass:[AVCaptureVideoDataOutput class]]) {
                AVCaptureVideoDataOutput *vdo = (AVCaptureVideoDataOutput *)output;
                id del = vdo.sampleBufferDelegate;
                if (del) {
                    NSLog(@"[MPU] Found delegate in startRunning: %@",
                          NSStringFromClass(object_getClass(del)));
                    _v_swizzleDelegate(del);
                }
            }
        }
    }
}

%end

// ========================================
// ПРЕВЬЮ СЛОЙ
// ========================================

%hook AVCaptureVideoPreviewLayer

- (void)layoutSublayers {
    %orig;
    if (!_enabled) return;
    _v_init();

    CALayer *overlay = objc_getAssociatedObject(self, kOverlayLayerKey);
    if (!overlay) {
        overlay = [CALayer layer];
        overlay.contentsGravity = kCAGravityResizeAspectFill;
        overlay.zPosition = 999999;
        overlay.backgroundColor = [UIColor blackColor].CGColor;
        [self addSublayer:overlay];
        objc_setAssociatedObject(self, kOverlayLayerKey,
            overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSLog(@"[MPU] Preview overlay created");
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

- (void)display {
    %orig;
    if (!_enabled) return;
    CALayer *overlay = objc_getAssociatedObject(self, kOverlayLayerKey);
    if (!overlay) return;
    @synchronized(_v_lock) {
        if (_lastBuffer) {
            IOSurfaceRef surf = CVPixelBufferGetIOSurface(_lastBuffer);
            if (surf) {
                [CATransaction begin];
                [CATransaction setDisableActions:YES];
                overlay.contents = (__bridge id)surf;
                [CATransaction commit];
            }
        }
    }
}

%end

// ========================================
// ФОТО — полноценная подмена
// ========================================

%hook AVCapturePhoto

- (CVPixelBufferRef)pixelBuffer {
    @synchronized(_v_lock) {
        if (_enabled && _lastBuffer && _streamReady)
            return (CVPixelBufferRef)CFAutorelease(CFRetain(_lastBuffer));
    }
    return %orig;
}

- (NSData *)fileDataRepresentation {
    @synchronized(_v_lock) {
        if (_enabled && _lastBuffer && _streamReady) {
            CIImage *ci = [CIImage imageWithCVPixelBuffer:_lastBuffer];
            CGImageRef cg = [_v_ciContext createCGImage:ci fromRect:ci.extent];
            if (!cg) return %orig;
            NSData *d = UIImageJPEGRepresentation(
                [UIImage imageWithCGImage:cg], 1.0);
            CGImageRelease(cg);
            NSLog(@"[MPU] Photo replaced with stream frame");
            return d;
        }
    }
    return %orig;
}

%end

// ========================================
// ПРОГРЕВ СТРИМА
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
        if (_v_shouldSkipBundle(bid)) return;

        _v_lock      = [NSObject new];
        _v_ciContext = [CIContext contextWithOptions:@{
            kCIContextUseSoftwareRenderer: @NO
        }];
        _origIMPs    = [NSMutableDictionary new];

        _v_loadPrefs();

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL, _v_prefsChanged,
            CFSTR("com.proximacore.mediaplaybackutils/prefsChanged"),
            NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

        if (_enabled) {
            NSLog(@"[MPU] v1.5.2 loaded -> %@", bid);
            %init;
        } else {
            NSLog(@"[MPU] Disabled -> %@", bid);
        }
    }
}
