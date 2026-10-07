#import "renderer.h"
#import <QuartzCore/QuartzCore.h>

#include <math.h>
#include <stdio.h>
#include <string.h>

typedef struct {
    float resolution[2];
    float time;
    float frame;
} Uniforms;

typedef struct __attribute__((aligned(16))) {
    float resolution[2];
    float time;
    float frame;
    float cameraPos[4];
    float cameraTarget[4];
    uint32_t sampleIndex;
    uint32_t frameSeed;
    float exposure;
    uint32_t samplesPerFrame;
} PTUniforms;

typedef struct {
    float px, py, pz;
    float tx, ty, tz;
} Shot;

static const Shot kShots[] = {
    {  0.00f, 1.35f, 2.35f,  0.00f, 0.85f, -0.50f },
    { -0.95f, 1.30f, 2.05f,  0.25f, 0.80f, -0.80f },
    {  0.95f, 1.30f, 2.05f, -0.25f, 0.80f, -0.80f },
    {  0.00f, 0.80f, 1.90f,  0.00f, 1.10f, -1.00f },
};
static const NSInteger kShotCount = 4;
static const double kShotDuration = 6.0;

static NSError *MakeError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"mac-demo-lab"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

static float AcesTonemap(float x) {
    return (x * (2.51f * x + 0.03f)) / (x * (2.43f * x + 0.59f) + 0.14f);
}

@implementation Renderer {
    RendererMode _mode;
    id<MTLDevice> _device;
    id<MTLCommandQueue> _queue;
    id<MTLRenderPipelineState> _rasterPipeline;
    id<MTLComputePipelineState> _computePipeline;
    id<MTLTexture> _accumTexture;
    double _startTime;
    NSUInteger _frameIndex;
    NSUInteger _sampleIndex;
    NSInteger _currentShot;
}

- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                            pixelFormat:(MTLPixelFormat)pixelFormat
                           shaderSource:(NSString *)source
                                   mode:(RendererMode)mode
                                  error:(NSError **)error
{
    self = [super init];
    if (!self) {
        return nil;
    }

    _mode = mode;
    _fixedShot = -1;
    _currentShot = -1;
    _samplesPerFrame = 4;
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

    if (mode == RendererModeSDF) {
        if (![self buildRasterPipelineWithLibrary:library
                                         vertexFn:@"vs_fullscreen"
                                       fragmentFn:@"fs_scene"
                                      pixelFormat:pixelFormat
                                            error:error]) {
            return nil;
        }
    } else {
        id<MTLFunction> computeFunction = [library newFunctionWithName:@"cs_pathtrace"];
        if (!computeFunction) {
            if (error) {
                *error = MakeError(2, @"entry point cs_pathtrace not found");
            }
            return nil;
        }
        NSError *computeError = nil;
        _computePipeline = [device newComputePipelineStateWithFunction:computeFunction
                                                                 error:&computeError];
        if (!_computePipeline) {
            if (error) {
                *error = computeError ?: MakeError(3, @"could not create compute pipeline");
            }
            return nil;
        }
        if (![self buildRasterPipelineWithLibrary:library
                                         vertexFn:@"vs_fullscreen"
                                       fragmentFn:@"fs_display"
                                      pixelFormat:pixelFormat
                                            error:error]) {
            return nil;
        }
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

- (BOOL)buildRasterPipelineWithLibrary:(id<MTLLibrary>)library
                              vertexFn:(NSString *)vertexName
                            fragmentFn:(NSString *)fragmentName
                           pixelFormat:(MTLPixelFormat)pixelFormat
                                 error:(NSError **)error
{
    id<MTLFunction> vertexFunction = [library newFunctionWithName:vertexName];
    id<MTLFunction> fragmentFunction = [library newFunctionWithName:fragmentName];
    if (!vertexFunction || !fragmentFunction) {
        if (error) {
            *error = MakeError(5, [NSString stringWithFormat:@"entry points %@ / %@ not found",
                                   vertexName, fragmentName]);
        }
        return NO;
    }

    MTLRenderPipelineDescriptor *descriptor = [[MTLRenderPipelineDescriptor alloc] init];
    descriptor.label = @"intro pipeline";
    descriptor.vertexFunction = vertexFunction;
    descriptor.fragmentFunction = fragmentFunction;
    descriptor.colorAttachments[0].pixelFormat = pixelFormat;

    NSError *pipelineError = nil;
    _rasterPipeline = [_device newRenderPipelineStateWithDescriptor:descriptor error:&pipelineError];
    if (!_rasterPipeline) {
        if (error) {
            *error = pipelineError ?: MakeError(6, @"could not create render pipeline");
        }
        return NO;
    }
    return YES;
}

- (NSUInteger)accumulatedSamples {
    return _sampleIndex * _samplesPerFrame;
}

#pragma mark - SDF mode

- (void)encodeSDFFrameWithCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
                    renderPassDescriptor:(MTLRenderPassDescriptor *)pass
{
    id<MTLTexture> texture = pass.colorAttachments[0].texture;
    Uniforms uniforms = {
        .resolution = { (float)texture.width, (float)texture.height },
        .time = (float)(CACurrentMediaTime() - _startTime),
        .frame = (float)_frameIndex,
    };

    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:_rasterPipeline];
    [encoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:0];
    [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];

    _frameIndex++;
}

#pragma mark - Path tracer mode

- (BOOL)ensureAccumTextureForWidth:(NSUInteger)width height:(NSUInteger)height {
    if (_accumTexture && _accumTexture.width == width && _accumTexture.height == height) {
        return YES;
    }
    MTLTextureDescriptor *descriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                                           width:width
                                                          height:height
                                                       mipmapped:NO];
    descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    descriptor.storageMode = MTLStorageModeShared;
    _accumTexture = [_device newTextureWithDescriptor:descriptor];
    _sampleIndex = 0;
    return _accumTexture != nil;
}

- (PTUniforms)nextPTUniformsForWidth:(NSUInteger)width height:(NSUInteger)height {
    PTUniforms u;
    memset(&u, 0, sizeof(u));

    double now = CACurrentMediaTime() - _startTime;
    NSInteger shot = _fixedShot >= 0 ? _fixedShot : (NSInteger)(now / kShotDuration) % kShotCount;
    if (shot != _currentShot) {
        _currentShot = shot;
        _sampleIndex = 0;
    }

    const Shot *s = &kShots[shot];
    u.resolution[0] = (float)width;
    u.resolution[1] = (float)height;
    u.time = (float)now;
    u.frame = (float)_frameIndex;
    u.cameraPos[0] = s->px;
    u.cameraPos[1] = s->py;
    u.cameraPos[2] = s->pz;
    u.cameraTarget[0] = s->tx;
    u.cameraTarget[1] = s->ty;
    u.cameraTarget[2] = s->tz;
    u.sampleIndex = (uint32_t)_sampleIndex++;
    u.frameSeed = (uint32_t)_frameIndex;
    u.exposure = 1.0f;
    u.samplesPerFrame = (uint32_t)MAX(_samplesPerFrame, 1);

    _frameIndex++;
    return u;
}

- (void)encodePathTracerFrameWithCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
                           renderPassDescriptor:(MTLRenderPassDescriptor *)pass
{
    id<MTLTexture> target = pass.colorAttachments[0].texture;
    if (![self ensureAccumTextureForWidth:target.width height:target.height]) {
        return;
    }

    PTUniforms uniforms = [self nextPTUniformsForWidth:target.width height:target.height];

    id<MTLComputeCommandEncoder> compute = [commandBuffer computeCommandEncoder];
    [compute setComputePipelineState:_computePipeline];
    [compute setTexture:_accumTexture atIndex:0];
    [compute setBytes:&uniforms length:sizeof(uniforms) atIndex:0];
    MTLSize threadsPerGroup = MTLSizeMake(8, 8, 1);
    MTLSize groups = MTLSizeMake((target.width + 7) / 8, (target.height + 7) / 8, 1);
    [compute dispatchThreadgroups:groups threadsPerThreadgroup:threadsPerGroup];
    [compute endEncoding];

    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:_rasterPipeline];
    [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
    [encoder setFragmentTexture:_accumTexture atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
}

#pragma mark - Frame entry points

- (void)encodeFrameWithCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
                 renderPassDescriptor:(MTLRenderPassDescriptor *)pass
{
    if (_mode == RendererModeSDF) {
        [self encodeSDFFrameWithCommandBuffer:commandBuffer renderPassDescriptor:pass];
    } else {
        [self encodePathTracerFrameWithCommandBuffer:commandBuffer renderPassDescriptor:pass];
    }
}

- (void)drawInView:(MTKView *)view {
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

- (BOOL)renderOffscreenFrames:(NSUInteger)count error:(NSError **)error {
    MTLTextureDescriptor *textureDescriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                           width:1280
                                                          height:720
                                                       mipmapped:NO];
    textureDescriptor.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> texture = [_device newTextureWithDescriptor:textureDescriptor];
    if (!texture) {
        if (error) {
            *error = MakeError(7, @"could not create offscreen texture");
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

- (BOOL)writeSnapshotToPath:(NSString *)path error:(NSError **)error {
    if (!_accumTexture) {
        if (error) {
            *error = MakeError(8, @"no accumulated frame to write (path tracer did not run)");
        }
        return NO;
    }

    NSUInteger width = _accumTexture.width;
    NSUInteger height = _accumTexture.height;
    NSUInteger bytesPerRow = width * 4 * sizeof(float);
    NSMutableData *raw = [NSMutableData dataWithLength:bytesPerRow * height];
    [_accumTexture getBytes:raw.mutableBytes
                bytesPerRow:bytesPerRow
                 fromRegion:MTLRegionMake2D(0, 0, width, height)
                mipmapLevel:0];

    FILE *file = fopen(path.fileSystemRepresentation, "wb");
    if (!file) {
        if (error) {
            *error = MakeError(9, [NSString stringWithFormat:@"could not open %@", path]);
        }
        return NO;
    }

    fprintf(file, "P6\n%lu %lu\n255\n", (unsigned long)width, (unsigned long)height);
    const float *pixels = (const float *)raw.bytes;
    for (NSUInteger y = 0; y < height; y++) {
        for (NSUInteger x = 0; x < width; x++) {
            const float *pixel = pixels + (y * width + x) * 4;
            for (int channel = 0; channel < 3; channel++) {
                float value = AcesTonemap(pixel[channel]);
                value = powf(fmaxf(value, 0.0f), 1.0f / 2.2f);
                unsigned char byte = (unsigned char)(fminf(value, 1.0f) * 255.0f + 0.5f);
                fputc(byte, file);
            }
        }
    }
    fclose(file);
    return YES;
}

@end
