// FrameProcessor.h - MediaPlaybackUtils v1.4.2
#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>

NS_ASSUME_NONNULL_BEGIN

@interface _MPUFrameProcessor : NSObject

+ (instancetype)sharedProcessor;

- (CVPixelBufferRef _Nullable)processBuffer:(CVPixelBufferRef)src CF_RETURNS_RETAINED;
- (CMSampleTimingInfo)jitteredTimingFromTiming:(CMSampleTimingInfo)t;

@end

NS_ASSUME_NONNULL_END
