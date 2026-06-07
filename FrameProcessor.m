// FrameProcessor.m - MediaPlaybackUtils v1.4.2 [FIXED]
// Исправления:
//   1. processBuffer: теперь корректно обрабатывает планарные YUV-форматы (420f/420v),
//      которые реально возвращает камера iPhone. Вместо прямого memcpy используется
//      CGBitmapContext для конвертации через CGImage (без зависимости от VideoToolbox).

#import "FrameProcessor.h"
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
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

    OSType fmt  = CVPixelBufferGetPixelFormatType(src);
    IOSurfaceRef surf = CVPixelBufferGetIOSurface(src);

    // Уже нужный формат с IOSurface — возвращаем as-is (retain)
    if (fmt == kCVPixelFormatType_32BGRA && surf != NULL) {
        return (CVPixelBufferRef)CFRetain(src);
    }

    size_t w = CVPixelBufferGetWidth(src);
    size_t h = CVPixelBufferGetHeight(src);

    // Параметры выходного буфера
    NSDictionary *attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey:             @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferIOSurfacePropertiesKey:         @{},
        (id)kCVPixelBufferCGImageCompatibilityKey:        @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
        (id)kCVPixelBufferWidthKey:                       @(w),
        (id)kCVPixelBufferHeightKey:                      @(h),
    };

    CVPixelBufferRef dst = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                            (__bridge CFDictionaryRef)attrs, &dst) != kCVReturnSuccess || !dst) {
        return NULL;
    }

    // [FIX #6] Для планарных форматов (420f / 420v / BiPlanar) прямой memcpy
    // работает только для первой плоскости (Y), цветность теряется.
    // Используем CIImage + CGBitmapContext — правильная конвертация YUV→BGRA на GPU.
    BOOL isPlanar = CVPixelBufferIsPlanar(src);

    if (isPlanar || fmt != kCVPixelFormatType_32BGRA) {
        // Конвертация через CIImage (поддерживает 420f, 420v, 422, 444 и т.д.)
        CIImage *ci  = [CIImage imageWithCVPixelBuffer:src];
        CIContext *ctx = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @NO}];

        CVPixelBufferLockBaseAddress(dst, 0);
        void   *dstBase = CVPixelBufferGetBaseAddress(dst);
        size_t  dstBpr  = CVPixelBufferGetBytesPerRow(dst);

        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef    cg = CGBitmapContextCreate(dstBase, w, h, 8, dstBpr, cs,
                                                   kCGImageAlphaPremultipliedFirst |
                                                   kCGBitmapByteOrder32Little);
        CGColorSpaceRelease(cs);

        if (cg) {
            CGImageRef cgImg = [ctx createCGImage:ci fromRect:ci.extent];
            if (cgImg) {
                CGContextDrawImage(cg, CGRectMake(0, 0, w, h), cgImg);
                CGImageRelease(cgImg);
            }
            CGContextRelease(cg);
        }

        CVPixelBufferUnlockBaseAddress(dst, 0);
    } else {
        // Оба буфера 32BGRA, packed — быстрый путь: построчный memcpy
        CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferLockBaseAddress(dst, 0);

        void   *srcBase = CVPixelBufferGetBaseAddress(src);
        void   *dstBase = CVPixelBufferGetBaseAddress(dst);
        size_t  srcBpr  = CVPixelBufferGetBytesPerRow(src);
        size_t  dstBpr  = CVPixelBufferGetBytesPerRow(dst);

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
    }

    return dst;
}

- (CMSampleTimingInfo)jitteredTimingFromTiming:(CMSampleTimingInfo)t {
    int32_t jitter_us = (int32_t)(arc4random_uniform(1001)) - 500;
    CMTime jitter     = CMTimeMake(jitter_us, 1000000);
    t.presentationTimeStamp = CMTimeAdd(t.presentationTimeStamp, jitter);
    return t;
}

@end
