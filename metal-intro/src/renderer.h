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

/// SVGF-style spatiotemporal denoiser (default on in path tracer mode).
@property (nonatomic) BOOL denoiseEnabled;

/// Continuous camera motion instead of hard shot cuts.
@property (nonatomic) BOOL continuousMotion;

/// Path tracer render scale relative to the output (1.0 = native, 0.5 = half res upscaled).
@property (nonatomic) double renderScale;

- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                            pixelFormat:(MTLPixelFormat)pixelFormat
                           shaderSource:(NSString *)source
                                   mode:(RendererMode)mode
                                  error:(NSError **)error;

- (void)drawInView:(MTKView *)view;
- (BOOL)renderOffscreenFrames:(NSUInteger)count
                        width:(NSUInteger)width
                       height:(NSUInteger)height
                        error:(NSError **)error;
- (BOOL)writeSnapshotToPath:(NSString *)path error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
