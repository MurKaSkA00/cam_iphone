// AntifraudHooks.x - MediaPlaybackUtils v1.5.2
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import "MPUKeys.h"

static NSString *(*orig_NSStringFromClass)(Class) = NULL;
static NSString *hook_NSStringFromClass(Class cls) {
    NSString *r = orig_NSStringFromClass(cls);
    if (!r) return r;
    if ([r hasSuffix:@"_MPU"]) {
        return [r substringToIndex:r.length - 4];
    }
    return r;
}

%hook AVCaptureVideoPreviewLayer

- (NSArray<CALayer *> *)sublayers {
    NSArray<CALayer *> *orig = %orig;
    if (!orig) return orig;
    CALayer *overlay = objc_getAssociatedObject(self, kOverlayLayerKey);
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
        if ([bid hasPrefix:@"com.apple.springboard"]) return;

        MSHookFunction((void *)NSStringFromClass,
                       (void *)hook_NSStringFromClass,
                       (void **)&orig_NSStringFromClass);
        %init;
        NSLog(@"[MPU/AntiIntrospect] Installed for %@", bid);
    }
}
