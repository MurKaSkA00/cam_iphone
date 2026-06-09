// AntifraudHooks.x - MediaPlaybackUtils v1.4.2

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>

// FIX: используем строку напрямую вместо extern-константы kOverlayLayerKey
static const char * const kOverlayKey = "_v_overlay";

static NSString *(*orig_NSStringFromClass)(Class) = NULL;
static NSString *hook_NSStringFromClass(Class cls) {
    NSString *r = orig_NSStringFromClass(cls);
    if (!r) return r;
    if ([r hasSuffix:@"_MPU"]) {
        return [r substringToIndex:r.length - 4];
    }
    return r;
}

static id (*orig_objc_getAssociatedObject)(id, const void *) = NULL;
static id hook_objc_getAssociatedObject(id object, const void *key) {
    if (key && strcmp((const char *)key, kOverlayKey) == 0) return nil;
    return orig_objc_getAssociatedObject(object, key);
}

%hook AVCaptureVideoPreviewLayer

- (NSArray<CALayer *> *)sublayers {
    NSArray<CALayer *> *orig = %orig;
    if (!orig) return orig;

    CALayer *overlay = nil;
    if (orig_objc_getAssociatedObject) {
        overlay = (CALayer *)orig_objc_getAssociatedObject(self, kOverlayKey);
    }
    if (!overlay) return orig;

    NSMutableArray *clean = [orig mutableCopy];
    [clean removeObject:overlay];
    return clean;
}

%end

%ctor {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if (!bid) return;
        if ([bid hasPrefix:@"com.apple."]) return;

        MSHookFunction((void *)NSStringFromClass,
                       (void *)hook_NSStringFromClass,
                       (void **)&orig_NSStringFromClass);

        MSHookFunction((void *)objc_getAssociatedObject,
                       (void *)hook_objc_getAssociatedObject,
                       (void **)&orig_objc_getAssociatedObject);

        %init;
        NSLog(@"[MPU/AntiIntrospect] Installed for %@", bid);
    }
}
