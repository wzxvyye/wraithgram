#import <WGCallFrameBridge/WGCallFrameBridge.h>

#import <os/lock.h>

static os_unfair_lock ggCallFrameLock = OS_UNFAIR_LOCK_INIT;
static WGCallFrameProcessorBlock ggCallFrameProcessor = nil;

@implementation WGCallFrameBridge

+ (void)setProcessor:(WGCallFrameProcessorBlock _Nullable)processor {
    WGCallFrameProcessorBlock copied = [processor copy];
    os_unfair_lock_lock(&ggCallFrameLock);
    ggCallFrameProcessor = copied;
    os_unfair_lock_unlock(&ggCallFrameLock);
}

+ (BOOL)hasProcessor {
    os_unfair_lock_lock(&ggCallFrameLock);
    BOOL result = ggCallFrameProcessor != nil;
    os_unfair_lock_unlock(&ggCallFrameLock);
    return result;
}

+ (CVPixelBufferRef _Nullable)copyProcessedPixelBuffer:(CVPixelBufferRef)pixelBuffer isFrontCamera:(BOOL)isFrontCamera rotation:(int)rotation {
    os_unfair_lock_lock(&ggCallFrameLock);
    WGCallFrameProcessorBlock processor = ggCallFrameProcessor;
    os_unfair_lock_unlock(&ggCallFrameLock);
    if (processor == nil) {
        return NULL;
    }
    CVPixelBufferRef result = processor(pixelBuffer, isFrontCamera, rotation);
    if (result == NULL) {
        return NULL;
    }
    if (CVPixelBufferGetWidth(result) != CVPixelBufferGetWidth(pixelBuffer) || CVPixelBufferGetHeight(result) != CVPixelBufferGetHeight(pixelBuffer) || CVPixelBufferGetPixelFormatType(result) != CVPixelBufferGetPixelFormatType(pixelBuffer)) {
        CVPixelBufferRelease(result);
        return NULL;
    }
    return result;
}

@end
