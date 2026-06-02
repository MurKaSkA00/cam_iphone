// FrameProcessor.m - MediaPlaybackUtils v1.4.2
#import "FrameProcessor.h"
#import <stdlib.h>
#import <string.h>

@implementation _MPUFrameProcessor

+ (instancetype)sharedProcessor {
    static _MPUFrameProcessor *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [_MPUFrameProcessor new]; });
    return inst;
}

- (CVPixelBufferRef)processBuffer:(CVPixelBufferRef)src {
    if (!src) return NULL;

    OSType fmt = CVPixelBufferGetPixelFormatType(src);
    IOSurfaceRef surf = CVPixelBufferGetIOSurface(src);

    if (fmt == kCVPixelFormatType_32BGRA && surf != NULL) {
        return (CVPixelBufferRef)CFRetain(src);
    }

    size_t w = CVPixelBufferGetWidth(src);
    size_t h = CVPixelBufferGetHeight(src);

    NSDictionary *attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
        (id)kCVPixelBufferWidthKey: @(w),
        (id)kCVPixelBufferHeightKey: @(h),
    };

    CVPixelBufferRef dst = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                            (__bridge CFDictionaryRef)attrs, &dst) != kCVReturnSuccess || !dst) {
        return NULL;
    }

    CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(dst, 0);

    void *srcBase = CVPixelBufferGetBaseAddress(src);
    void *dstBase = CVPixelBufferGetBaseAddress(dst);
    size_t srcBpr = CVPixelBufferGetBytesPerRow(src);
    size_t dstBpr = CVPixelBufferGetBytesPerRow(dst);

    if (srcBase && dstBase) {
        size_t copyBpr = (srcBpr < dstBpr) ? srcBpr : dstBpr;
        for (size_t row = 0; row < h; row++) {
            memcpy((uint8_t *)dstBase + row * dstBpr,
                   (uint8_t *)srcBase + row * srcBpr,
                   copyBpr);
        }
    }

    CVPixelBufferUnlockBaseAddress(dst, 0);
    CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);

    return dst;
}

- (CMSampleTimingInfo)jitteredTimingFromTiming:(CMSampleTimingInfo)t {
    int32_t jitter_us = (int32_t)(arc4random_uniform(1001)) - 500;
    CMTime jitter = CMTimeMake(jitter_us, 1000000);
    t.presentationTimeStamp = CMTimeAdd(t.presentationTimeStamp, jitter);
    return t;
}

@end
