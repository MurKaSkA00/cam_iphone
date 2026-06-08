// AntifraudHooks.x - MediaPlaybackUtils v1.4.6

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>

extern const void *kOverlayLayerKey;

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
<<<КОНЕЦ AntifraudHooks.x>>>

📄 Файл 3 — MediaPlaybackUtils.plist
<<<НАЧАЛО MediaPlaybackUtils.plist>>>

<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Filter</key>
  <dict>
    <key>Classes</key>
    <array>
      <string>AVCaptureSession</string>
      <string>AVCaptureVideoDataOutput</string>
      <string>AVCapturePhotoOutput</string>
      <string>AVSampleBufferDisplayLayer</string>
      <string>AVCaptureVideoPreviewLayer</string>
    </array>
    <key>Mode</key>
    <string>Any</string>
  </dict>
</dict>
</plist>
<<<КОНЕЦ MediaPlaybackUtils.plist>>>

📄 Файл 4 — MediaBufferAdapter.m
<<<НАЧАЛО MediaBufferAdapter.m>>>

// MediaBufferAdapter.m - MediaPlaybackUtils v1.4.6
// Auto-detects MJPEG vs HLS by Content-Type header

#import "_MPUMediaBufferAdapter.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <ImageIO/ImageIO.h>
#import <MobileCoreServices/MobileCoreServices.h>

@interface _MPUMediaBufferAdapter ()
@property (nonatomic, strong) NSURLSession          *session;
@property (nonatomic, strong) NSURLSessionDataTask  *task;
@property (nonatomic, strong) NSMutableData         *imageData;
@property (nonatomic, assign) NSUInteger             parseCursor;
@property (nonatomic, assign) BOOL                   isRunning;
@property (nonatomic, assign) BOOL                   reconnectScheduled;
@property (nonatomic, strong) AVPlayer               *hlsPlayer;
@property (nonatomic, strong) AVPlayerItem           *hlsPlayerItem;
@property (nonatomic, strong) AVPlayerItemVideoOutput *videoOutput;
@property (nonatomic, strong) CADisplayLink          *displayLink;
@property (nonatomic, assign) BOOL                   isHLS;
@property (nonatomic, strong) CIContext              *ciContext;
@property (nonatomic, assign, readwrite) BOOL         isConnecting;
@end

@implementation _MPUMediaBufferAdapter

- (instancetype)initWithURL:(NSURL *)url {
    self = [super init];
    if (self) {
        _streamURL          = url;
        _isConnecting       = NO;
        _frameCount         = 0;
        _lastFrameTime      = 0;
        _parseCursor        = 0;
        _reconnectScheduled = NO;
        _ciContext          = [CIContext contextWithOptions:nil];

        NSString *path = url.path.lowercaseString ?: @"";
        _isHLS = [path hasSuffix:@".m3u8"];

        NSLog(@"[MPUAdapter] Initialized with URL: %@, initial-type: %@",
              url, _isHLS ? @"HLS" : @"HTTP");
    }
    return self;
}

- (void)startStreaming {
    if (_isRunning) {
        NSLog(@"[MPUAdapter] Already streaming");
        return;
    }
    _isRunning    = YES;
    _isConnecting = YES;
    NSLog(@"[MPUAdapter] Starting %@ stream...", _isHLS ? @"HLS" : @"HTTP");
    if (_isHLS) {
        [self startHLSStream];
    } else {
        [self startHTTPStream];
    }
}

- (void)stopStreaming {
    NSLog(@"[MPUAdapter] Stopping stream...");
    _isRunning    = NO;
    _isConnecting = NO;
    if (_isHLS) {
        [self stopHLSStream];
    } else {
        [self stopHTTPStream];
    }
}

- (void)startHLSStream {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.hlsPlayerItem = [AVPlayerItem playerItemWithURL:self.streamURL];
        self.hlsPlayer     = [AVPlayer playerWithPlayerItem:self.hlsPlayerItem];
        self.hlsPlayer.automaticallyWaitsToMinimizeStalling = NO;
        self.hlsPlayer.muted = YES;

        NSDictionary *pba = @{
            (id)kCVPixelBufferPixelFormatTypeKey:     @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
        };
        self.videoOutput = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:pba];
        [self.hlsPlayerItem addOutput:self.videoOutput];
        [self.hlsPlayer play];

        self.displayLink = [CADisplayLink displayLinkWithTarget:self
                                                       selector:@selector(displayLinkCallback:)];
        self.displayLink.preferredFramesPerSecond = 30;
        [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];

        self.isConnecting = NO;
        NSLog(@"[MPUAdapter] HLS player started");

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(playerItemDidReachEnd:)
                                                     name:AVPlayerItemDidPlayToEndTimeNotification
                                                   object:self.hlsPlayerItem];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(playerItemFailed:)
                                                     name:AVPlayerItemFailedToPlayToEndTimeNotification
                                                   object:self.hlsPlayerItem];
    });
}

- (void)displayLinkCallback:(CADisplayLink *)sender {
    if (!self.isRunning) return;
    CMTime currentTime = [self.hlsPlayer currentTime];
    if (![self.videoOutput hasNewPixelBufferForItemTime:currentTime]) return;

    CVPixelBufferRef pixelBuffer = [self.videoOutput copyPixelBufferForItemTime:currentTime
                                                             itemTimeForDisplay:nil];
    if (!pixelBuffer) return;

    self->_frameCount++;
    self->_lastFrameTime = CFAbsoluteTimeGetCurrent();

    if (self.pixelBufferCallback) {
        self.pixelBufferCallback(pixelBuffer);
        CVPixelBufferRelease(pixelBuffer);
        return;
    }
    if (self.frameCallback) {
        CIImage    *ciImage  = [CIImage imageWithCVPixelBuffer:pixelBuffer];
        CGImageRef  cgImage  = [self.ciContext createCGImage:ciImage fromRect:ciImage.extent];
        UIImage    *image    = cgImage ? [UIImage imageWithCGImage:cgImage] : nil;
        if (cgImage) CGImageRelease(cgImage);
        CVPixelBufferRelease(pixelBuffer);
        if (image) self.frameCallback(image);
    } else {
        CVPixelBufferRelease(pixelBuffer);
    }
}

- (void)playerItemDidReachEnd:(NSNotification *)n {
    NSLog(@"[MPUAdapter] HLS stream ended, restarting...");
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.hlsPlayer seekToTime:kCMTimeZero];
        [self.hlsPlayer play];
    });
}

- (void)playerItemFailed:(NSNotification *)n {
    NSLog(@"[MPUAdapter] HLS item failed, hard-restart in 2s");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!self.isRunning) return;
        [self stopHLSStream];
        [self startHLSStream];
    });
}

- (void)stopHLSStream {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] removeObserver:self];
        [self.displayLink invalidate];
        self.displayLink  = nil;
        [self.hlsPlayer pause];
        self.hlsPlayer     = nil;
        self.hlsPlayerItem = nil;
        self.videoOutput   = nil;
    });
}

- (void)startHTTPStream {
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.timeoutIntervalForRequest  = 30.0;
    config.timeoutIntervalForResource = 0;
    config.HTTPMaximumConnectionsPerHost = 1;

    self.session    = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];
    self.imageData  = [NSMutableData data];
    self.parseCursor = 0;

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:self.streamURL];
    [request setValue:@"multipart/x-mixed-replace, application/vnd.apple.mpegurl, */*"
   forHTTPHeaderField:@"Accept"];

    self.task = [self.session dataTaskWithRequest:request];
    [self.task resume];
    NSLog(@"[MPUAdapter] HTTP stream task started");
}

- (void)stopHTTPStream {
    [self.task cancel];
    self.task = nil;
    [self.session invalidateAndCancel];
    self.session      = nil;
    self.imageData    = nil;
    self.parseCursor  = 0;
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))ch {
    self.isConnecting = NO;

    NSString *ctype = nil;
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        ctype = [http.allHeaderFields[@"Content-Type"] lowercaseString];
    }
    NSLog(@"[MPUAdapter] HTTP connected, Content-Type: %@", ctype ?: @"(none)");

    if (ctype && ([ctype containsString:@"mpegurl"] ||
                  [ctype containsString:@"x-mpegurl"] ||
                  [ctype containsString:@"vnd.apple.mpegurl"])) {
        NSLog(@"[MPUAdapter] HLS detected via Content-Type, switching player");
        ch(NSURLSessionResponseCancel);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self stopHTTPStream];
            self.isHLS = YES;
            if (self.isRunning) [self startHLSStream];
        });
        return;
    }

    ch(NSURLSessionResponseAllow);
}

- (CVPixelBufferRef)pixelBufferFromJPEGData:(NSData *)jpegData CF_RETURNS_RETAINED {
    CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)jpegData, NULL);
    if (!src) return NULL;

    CGImageRef cg = CGImageSourceCreateImageAtIndex(src, 0, NULL);
    CFRelease(src);
    if (!cg) return NULL;

    size_t w = CGImageGetWidth(cg);
    size_t h = CGImageGetHeight(cg);

    NSDictionary *opts = @{
        (id)kCVPixelBufferCGImageCompatibilityKey:         @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey:           @{}
    };

    CVPixelBufferRef pb = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                            (__bridge CFDictionaryRef)opts, &pb) != kCVReturnSuccess || !pb) {
        CGImageRelease(cg);
        return NULL;
    }

    CVPixelBufferLockBaseAddress(pb, 0);
    void   *base = CVPixelBufferGetBaseAddress(pb);
    size_t  bpr  = CVPixelBufferGetBytesPerRow(pb);

    CGColorSpaceRef cs  = CGColorSpaceCreateDeviceRGB();
    CGContextRef    ctx = CGBitmapContextCreate(base, w, h, 8, bpr, cs,
                                                kCGImageAlphaPremultipliedFirst |
                                                kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);
    if (ctx) {
        CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg);
        CGContextRelease(ctx);
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
    CGImageRelease(cg);
    return pb;
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
    if (!self.isRunning) return;

    [self.imageData appendData:data];

    static const unsigned char SOI[2] = {0xFF, 0xD8};
    static const unsigned char EOI[2] = {0xFF, 0xD9};
    NSData *startMarker = [NSData dataWithBytesNoCopy:(void *)SOI length:2 freeWhenDone:NO];
    NSData *endMarker   = [NSData dataWithBytesNoCopy:(void *)EOI length:2 freeWhenDone:NO];

    while (YES) {
        NSUInteger len = self.imageData.length;
        if (self.parseCursor >= len) break;

        NSRange searchRange = NSMakeRange(self.parseCursor, len - self.parseCursor);
        NSRange sRange = [self.imageData rangeOfData:startMarker options:0 range:searchRange];
        if (sRange.location == NSNotFound) {
            if (len > 1)
                [self.imageData replaceBytesInRange:NSMakeRange(0, len - 1) withBytes:NULL length:0];
            self.parseCursor = 0;
            break;
        }

        NSRange afterSOI = NSMakeRange(sRange.location + 2, len - (sRange.location + 2));
        NSRange eRange   = [self.imageData rangeOfData:endMarker options:0 range:afterSOI];
        if (eRange.location == NSNotFound) {
            self.parseCursor = sRange.location;
            break;
        }

        NSRange imgRange = NSMakeRange(sRange.location, eRange.location + 2 - sRange.location);
        NSData *jpeg = [self.imageData subdataWithRange:imgRange];

        if (self.pixelBufferCallback) {
            CVPixelBufferRef pb = [self pixelBufferFromJPEGData:jpeg];
            if (pb) {
                self->_frameCount++;
                self->_lastFrameTime = CFAbsoluteTimeGetCurrent();
                self.pixelBufferCallback(pb);
                CVPixelBufferRelease(pb);
            }
        } else if (self.frameCallback) {
            UIImage *image = [UIImage imageWithData:jpeg];
            if (image) {
                self->_frameCount++;
                self->_lastFrameTime = CFAbsoluteTimeGetCurrent();
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.frameCallback(image);
                });
            }
        }

        [self.imageData replaceBytesInRange:NSMakeRange(0, eRange.location + 2)
                                  withBytes:NULL length:0];
        self.parseCursor = 0;
    }

    if (self.imageData.length > 16 * 1024 * 1024) {
        [self.imageData setLength:0];
        self.parseCursor = 0;
        NSLog(@"[MPUAdapter] Buffer overflow (>16MB), cleared");
    }
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    if (error) {
        NSLog(@"[MPUAdapter] HTTP stream error: %@", error.localizedDescription);

        if (self.errorCallback) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.errorCallback(error);
            });
        }

        if (self.isRunning && !self.reconnectScheduled) {
            self.reconnectScheduled = YES;
            NSLog(@"[MPUAdapter] Reconnecting in 3s...");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                self.reconnectScheduled = NO;
                if (self.isRunning) {
                    [self stopHTTPStream];
                    [self startHTTPStream];
                }
            });
        }
    } else {
        NSLog(@"[MPUAdapter] HTTP stream ended normally");
    }
}

- (void)dealloc {
    [self stopStreaming];
}

@end
