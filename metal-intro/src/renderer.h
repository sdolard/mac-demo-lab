#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, RendererMode) {
    RendererModePathTracer = 0,
    RendererModeSDF = 1,
};

@interface Renderer : NSObject

/// Fixed camera shot for offscreen capture; -1 follows the timed shot list.
@property (nonatomic) NSInteger fixedShot;

/// Path tracer samples per dispatch.
@property (nonatomic) NSUInteger samplesPerFrame;

/// Number of samples accumulated in the current path-traced frame.
@property (nonatomic, readonly) NSUInteger accumulatedSamples;

- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                            pixelFormat:(MTLPixelFormat)pixelFormat
                           shaderSource:(NSString *)source
                                   mode:(RendererMode)mode
                                  error:(NSError **)error;

- (void)drawInView:(MTKView *)view;
- (BOOL)renderOffscreenFrames:(NSUInteger)count error:(NSError **)error;
- (BOOL)writeSnapshotToPath:(NSString *)path error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
