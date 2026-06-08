// Tweak.x - MediaPlaybackUtils v1.4.9

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
static NSMutableSet *_overlayLayers = nil;
static BOOL _overlayTimerStarted = NO;

static const void *kOverlayTimerKey = &kOverlayTimerKey;
static const void *kOverlayLayerKey = &kOverlayLayerKey;

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

static void _v_updateOverlays(void) {
    if (!_overlayLayers || !_v_lock) return;

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
        @synchronized(_overlayLayers) {
            for (CALayer *overlay in _overlayLayers) {
                overlay.contents = surfObj;
            }
        }
        [CATransaction commit];
    } else {
        CIImage *ci = [CIImage imageWithCVPixelBuffer:buf];
        CGImageRef cg = [_v_ciContext createCGImage:ci fromRect:ci.extent];
        if (cg) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            @synchronized(_overlayLayers) {
                for (CALayer *overlay in _overlayLayers) {
                    overlay.contents = (__bridge id)cg;
                }
            }
            [CATransaction commit];
            CGImageRelease(cg);
        }
    }

    CVPixelBufferRelease(buf);
}

static void _v_startOverlayTimer(void) {
    if (_overlayTimerStarted) return;
    _overlayTimerStarted = YES;

    dispatch_source_t timer = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer,
        DISPATCH_TIME_NOW,
        (uint64_t)(1.0/30.0 * NSEC_PER_SEC),
        (uint64_t)(5 * NSEC_PER_MSEC));
    dispatch_source_set_event_handler(timer, ^{
        _v_updateOverlays();
    });
    dispatch_resume(timer);

    objc_setAssociatedObject(_v_lock, kOverlayTimerKey,
                             timer, OBJC_ASSOCIATION_RETAIN);
    NSLog(@"[MPU] Overlay timer started at 30fps");
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

static CMSampleBufferRef _v_makeReplacementSampleBuffer(CMSampleBufferRef original) {
    CVPixelBufferRef src = NULL;
    @synchronized(_v_lock) {
        if (_lastBuffer) src = CVPixelBufferRetain(_lastBuffer);
    }
    if (!src) return NULL;

    CMVideoFormatDescriptionRef fmt = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(
            kCFAllocatorDefault, src, &fmt) != noErr || !fmt) {
        CVPixelBufferRelease(src);
        return NULL;
    }

    CMSampleTimingInfo timing;
    if (original && CMSampleBufferGetSampleTimingInfo(original, 0, &timing) == noErr) {
    } else {
        timing.duration = CMTimeMake(1, 30);
        timing.presentationTimeStamp =
            CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000000);
        timing.decodeTimeStamp = kCMTimeInvalid;
    }

    CMSampleBufferRef out = NULL;
    OSStatus s = CMSampleBufferCreateReadyWithImageBuffer(
        kCFAllocatorDefault, src, fmt, &timing, &out);
    CFRelease(fmt);
    CVPixelBufferRelease(src);
    return (s == noErr) ? out : NULL;
}

%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate
                          queue:(dispatch_queue_t)queue {
    if (!_enabled || !delegate) { %orig; return; }

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

                IMP newIMP = imp_implementationWithBlock(
                    ^(id self_, AVCaptureOutput *output,
                      CMSampleBufferRef sb, AVCaptureConnection *conn) {
                        CMSampleBufferRef replacement = NULL;
                        if (_enabled) {
                            replacement = _v_makeReplacementSampleBuffer(sb);
                        }
                        CMSampleBufferRef toUse = replacement ? replacement : sb;
                        ((void(*)(id, SEL, AVCaptureOutput *,
                                  CMSampleBufferRef, AVCaptureConnection *))origIMP)
                            (self_, sel, output, toUse, conn);
                        if (replacement) CFRelease(replacement);
                    });

                if (!class_addMethod(cls, sel, newIMP, types)) {
                    origIMP = class_replaceMethod(cls, sel, newIMP, types);
                }
                [swizzledClassNames addObject:clsName];
                NSLog(@"[MPU] Swizzled: %@", clsName);
            }
        }
    }
    %orig;
}

%end

%hook AVCapturePhoto

- (CVPixelBufferRef)pixelBuffer {
    @synchronized(_v_lock) {
        if (_enabled && _lastBuffer)
            return (CVPixelBufferRef)CFAutorelease(CFRetain(_lastBuffer));
    }
    return %orig;
}

- (NSData *)fileDataRepresentation {
    CVPixelBufferRef buf = NULL;
    @synchronized(_v_lock) {
        if (_enabled && _lastBuffer) buf = CVPixelBufferRetain(_lastBuffer);
    }
    if (!buf) return %orig;
    CIImage *ci = [CIImage imageWithCVPixelBuffer:buf];
    CGImageRef cg = [_v_ciContext createCGImage:ci fromRect:ci.extent];
    CVPixelBufferRelease(buf);
    if (!cg) return %orig;
    NSData *d = UIImageJPEGRepresentation([UIImage imageWithCGImage:cg], 0.92);
    CGImageRelease(cg);
    return d;
}

%end

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
        overlay.opaque = YES;
        [self addSublayer:overlay];
        objc_setAssociatedObject(self, kOverlayLayerKey, overlay,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        @synchronized(_overlayLayers) {
            [_overlayLayers addObject:overlay];
        }
        NSLog(@"[MPU] Overlay added, total: %lu",
              (unsigned long)_overlayLayers.count);
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    overlay.frame = self.bounds;
    overlay.hidden = NO;
    overlay.opacity = 1.0;
    [CATransaction commit];
}

- (void)removeFromSuperlayer {
    CALayer *overlay = objc_getAssociatedObject(self, kOverlayLayerKey);
    if (overlay) {
        @synchronized(_overlayLayers) {
            [_overlayLayers removeObject:overlay];
        }
    }
    %orig;
}

%end

%hook AVCaptureSession
- (void)startRunning {
    if (_enabled) { _v_init(); }
    %orig;
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

+ (NSArray<AVCaptureDevice *> *)devicesWithMediaType:(AVMediaType)mediaType {
    if (_enabled && [mediaType isEqualToString:AVMediaTypeVideo]) _v_init();
    return %orig;
}

%end

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
        NSString *path = [[NSBundle mainBundle] bundlePath];
        if ([path hasPrefix:@"/usr/"]) return;
        if ([path hasPrefix:@"/System/Library/PrivateFrameworks/"]) return;
        if ([path hasPrefix:@"/System/Library/Frameworks/"]) return;

        _v_lock = [NSObject new];
        _overlayLayers = [NSMutableSet new];
        _v_ciContext = [CIContext contextWithOptions:
            @{ kCIContextUseSoftwareRenderer: @NO }];

        _v_loadPrefs();

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL, _v_prefsChanged,
            CFSTR("com.proximacore.mediaplaybackutils/prefsChanged"),
            NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

        if (_enabled) {
            NSLog(@"[MPU] v1.4.5 enabled: %@", bid);
            %init;
            dispatch_async(dispatch_get_main_queue(), ^{
                _v_startOverlayTimer();
            });
        }
    }
}
