#import "renderer.h"
#import <QuartzCore/QuartzCore.h>

typedef struct {
    float resolution[2];
    float time;
    float frame;
} Uniforms;

static NSError *MakeError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"mac-demo-lab"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

@implementation Renderer {
    id<MTLDevice> _device;
    id<MTLCommandQueue> _queue;
    id<MTLRenderPipelineState> _pipeline;
    double _startTime;
    NSUInteger _frameIndex;
}

- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                            pixelFormat:(MTLPixelFormat)pixelFormat
                           shaderSource:(NSString *)source
                                  error:(NSError **)error
{
    self = [super init];
    if (!self) {
        return nil;
    }

    _device = device;
    _startTime = CACurrentMediaTime();

    NSError *libraryError = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&libraryError];
    if (!library) {
        if (error) {
            *error = libraryError ?: MakeError(1, @"could not compile Metal shader");
        }
        return nil;
    }

    id<MTLFunction> vertexFunction = [library newFunctionWithName:@"vs_fullscreen"];
    id<MTLFunction> fragmentFunction = [library newFunctionWithName:@"fs_scene"];
    if (!vertexFunction || !fragmentFunction) {
        if (error) {
            *error = MakeError(2, @"entry points vs_fullscreen / fs_scene not found");
        }
        return nil;
    }

    MTLRenderPipelineDescriptor *descriptor = [[MTLRenderPipelineDescriptor alloc] init];
    descriptor.label = @"intro pipeline";
    descriptor.vertexFunction = vertexFunction;
    descriptor.fragmentFunction = fragmentFunction;
    descriptor.colorAttachments[0].pixelFormat = pixelFormat;

    NSError *pipelineError = nil;
    _pipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:&pipelineError];
    if (!_pipeline) {
        if (error) {
            *error = pipelineError ?: MakeError(3, @"could not create render pipeline");
        }
        return nil;
    }

    _queue = [device newCommandQueue];
    if (!_queue) {
        if (error) {
            *error = MakeError(4, @"could not create command queue");
        }
        return nil;
    }

    return self;
}

- (void)encodeFrameWithCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
                  renderPassDescriptor:(MTLRenderPassDescriptor *)pass
{
    id<MTLTexture> texture = pass.colorAttachments[0].texture;
    Uniforms uniforms = {
        .resolution = { (float)texture.width, (float)texture.height },
        .time = (float)(CACurrentMediaTime() - _startTime),
        .frame = (float)_frameIndex,
    };

    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:_pipeline];
    [encoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:0];
    [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];

    _frameIndex++;
}

- (void)drawInView:(MTKView *)view
{
    id<CAMetalDrawable> drawable = view.currentDrawable;
    MTLRenderPassDescriptor *pass = view.currentRenderPassDescriptor;
    if (!drawable || !pass) {
        return;
    }

    id<MTLCommandBuffer> commandBuffer = [_queue commandBuffer];
    [self encodeFrameWithCommandBuffer:commandBuffer renderPassDescriptor:pass];
    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];
}

- (BOOL)renderOffscreenFrames:(NSUInteger)count error:(NSError **)error
{
    MTLTextureDescriptor *textureDescriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                           width:1280
                                                          height:720
                                                       mipmapped:NO];
    textureDescriptor.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> texture = [_device newTextureWithDescriptor:textureDescriptor];
    if (!texture) {
        if (error) {
            *error = MakeError(5, @"could not create offscreen texture");
        }
        return NO;
    }

    for (NSUInteger i = 0; i < count; i++) {
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = texture;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);

        id<MTLCommandBuffer> commandBuffer = [_queue commandBuffer];
        [self encodeFrameWithCommandBuffer:commandBuffer renderPassDescriptor:pass];
        [commandBuffer commit];
        [commandBuffer waitUntilCompleted];

        if (commandBuffer.error) {
            if (error) {
                *error = commandBuffer.error;
            }
            return NO;
        }
    }

    return YES;
}

@end
