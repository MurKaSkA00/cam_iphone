// FrameProcessor.h - MediaPlaybackUtils v1.4.2 (fixed)

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>

NS_ASSUME_NONNULL_BEGIN

@interface _MPUFrameProcessor : NSObject

+ (instancetype)sharedProcessor;

/// Конвертирует CVPixelBuffer в BGRA + IOSurface-backed буфер.
/// Если буфер уже в нужном формате — просто retain.
/// Возвращает retained буфер (caller должен CVPixelBufferRelease).
- (CVPixelBufferRef)processBuffer:(CVPixelBufferRef)src CF_RETURNS_RETAINED;

@end

NS_ASSUME_NONNULL_END
