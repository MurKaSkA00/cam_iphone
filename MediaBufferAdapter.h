// MediaBufferAdapter.h - MediaPlaybackUtils v1.4.2
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^_MPUFrameCallback)(UIImage *frame);
typedef void (^_MPUPixelBufferCallback)(CVPixelBufferRef buffer);
typedef void (^_MPUErrorCallback)(NSError *error);

@interface _MPUMediaBufferAdapter : NSObject <NSURLSessionDataDelegate>

@property (nonatomic, strong, readonly) NSURL          *streamURL;
@property (nonatomic, assign, readonly) BOOL            isConnecting;
@property (nonatomic, assign, readonly) NSUInteger      frameCount;
@property (nonatomic, assign, readonly) CFAbsoluteTime  lastFrameTime;

@property (nonatomic, copy, nullable) _MPUFrameCallback        frameCallback;
@property (nonatomic, copy, nullable) _MPUPixelBufferCallback  pixelBufferCallback;
@property (nonatomic, copy, nullable) _MPUErrorCallback        errorCallback;

- (instancetype)initWithURL:(NSURL *)url;
- (void)startStreaming;
- (void)stopStreaming;

@end

NS_ASSUME_NONNULL_END
