#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface Renderer : NSObject

- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                            pixelFormat:(MTLPixelFormat)pixelFormat
                           shaderSource:(NSString *)source
                                  error:(NSError **)error;

- (void)drawInView:(MTKView *)view;
- (BOOL)renderOffscreenFrames:(NSUInteger)count error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
