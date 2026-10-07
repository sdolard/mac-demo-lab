#import "renderer.h"
#import <QuartzCore/QuartzCore.h>
#import <simd/simd.h>

#include <math.h>
#include <stdio.h>
#include <string.h>

typedef struct {
    float resolution[2];
    float time;
    float frame;
} SDFUniforms;

typedef struct __attribute__((aligned(16))) {
    simd_float2 resolution;
    simd_float2 outputResolution;
    float time;
    float frame;
    simd_float4 cameraPos;
    simd_float4 cameraTarget;
    simd_float4 prevCameraPos;
    simd_float4 prevCameraTarget;
    uint32_t frameSeed;
    uint32_t samplesPerFrame;
    uint32_t resetHistory;
    uint32_t filterStep;
    float exposure;
    float pad0;
    float pad1;
    float pad2;
} PTUniforms;

typedef struct {
    float px, py, pz;
    float tx, ty, tz;
} CameraPose;

static const CameraPose kShots[] = {
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

@implementation Renderer {
    RendererMode _mode;
    id<MTLDevice> _device;
    id<MTLCommandQueue> _queue;
    id<MTLRenderPipelineState> _rasterPipeline;
    id<MTLComputePipelineState> _tracePipeline;
    id<MTLComputePipelineState> _temporalPipeline;
    id<MTLComputePipelineState> _atrousPipeline;

    id<MTLTexture> _radiance;
    id<MTLTexture> _gA;
    id<MTLTexture> _gB;
    id<MTLTexture> _gCur;
    id<MTLTexture> _gPrev;
    id<MTLTexture> _histA;
    id<MTLTexture> _histB;
    id<MTLTexture> _histCur;
    id<MTLTexture> _histPrev;
    id<MTLTexture> _moments;
    id<MTLTexture> _guide;
    id<MTLTexture> _filtA;
    id<MTLTexture> _filtB;
    id<MTLTexture> _displayTexture;
    NSUInteger _bufferWidth;
    NSUInteger _bufferHeight;
    NSUInteger _outputWidth;
    NSUInteger _outputHeight;

    BOOL _hasPrevCamera;
    CameraPose _prevCamera;
    NSInteger _currentShot;
    NSUInteger _ptFrameCount;

    double _startTime;
    NSUInteger _frameIndex;
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
    _samplesPerFrame = 2;
    _denoiseEnabled = YES;
    _continuousMotion = NO;
    _renderScale = 1.0;
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
        NSError *pipelineError = nil;
        _tracePipeline = [self newComputePipelineWithLibrary:library name:@"cs_pathtrace" error:&pipelineError];
        _temporalPipeline = [self newComputePipelineWithLibrary:library name:@"cs_temporal" error:&pipelineError];
        _atrousPipeline = [self newComputePipelineWithLibrary:library name:@"cs_atrous" error:&pipelineError];
        if (!_tracePipeline || !_temporalPipeline || !_atrousPipeline) {
            if (error) {
                *error = pipelineError ?: MakeError(2, @"could not create compute pipelines");
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
            *error = MakeError(3, @"could not create command queue");
        }
        return nil;
    }

    return self;
}

- (id<MTLComputePipelineState>)newComputePipelineWithLibrary:(id<MTLLibrary>)library
                                                        name:(NSString *)name
                                                       error:(NSError **)error
{
    id<MTLFunction> function = [library newFunctionWithName:name];
    if (!function) {
        if (error) {
            *error = MakeError(4, [NSString stringWithFormat:@"entry point %@ not found", name]);
        }
        return nil;
    }
    NSError *pipelineError = nil;
    id<MTLComputePipelineState> pipeline = [_device newComputePipelineStateWithFunction:function
                                                                                  error:&pipelineError];
    if (!pipeline && error) {
        *error = pipelineError ?: MakeError(5, [NSString stringWithFormat:@"could not create %@", name]);
    }
    return pipeline;
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
            *error = MakeError(6, [NSString stringWithFormat:@"entry points %@ / %@ not found",
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
            *error = pipelineError ?: MakeError(7, @"could not create render pipeline");
        }
        return NO;
    }
    return YES;
}

#pragma mark - SDF mode

- (void)encodeSDFFrameWithCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
                    renderPassDescriptor:(MTLRenderPassDescriptor *)pass
{
    id<MTLTexture> texture = pass.colorAttachments[0].texture;
    SDFUniforms uniforms = {
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

- (BOOL)ensurePathTracerBuffersForWidth:(NSUInteger)width height:(NSUInteger)height {
    if (_radiance && _bufferWidth == width && _bufferHeight == height) {
        return YES;
    }

    _bufferWidth = width;
    _bufferHeight = height;

    MTLTextureDescriptor *descriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                                           width:width
                                                          height:height
                                                       mipmapped:NO];
    descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    descriptor.storageMode = MTLStorageModePrivate;

    _radiance = [_device newTextureWithDescriptor:descriptor];
    _gA = [_device newTextureWithDescriptor:descriptor];
    _gB = [_device newTextureWithDescriptor:descriptor];
    _histA = [_device newTextureWithDescriptor:descriptor];
    _histB = [_device newTextureWithDescriptor:descriptor];
    _moments = [_device newTextureWithDescriptor:descriptor];
    _guide = [_device newTextureWithDescriptor:descriptor];
    _filtA = [_device newTextureWithDescriptor:descriptor];
    _filtB = [_device newTextureWithDescriptor:descriptor];

    if (!_radiance || !_gA || !_gB || !_histA || !_histB || !_moments || !_guide ||
        !_filtA || !_filtB) {
        return NO;
    }

    _gCur = _gA;
    _gPrev = _gB;
    _histCur = _histA;
    _histPrev = _histB;
    _displayTexture = _radiance;
    _hasPrevCamera = NO;
    return YES;
}

- (CameraPose)cameraPoseForTime:(double)now shotChanged:(BOOL *)shotChanged {
    if (_continuousMotion) {
        double a = now * 0.35;
        CameraPose pose;
        pose.px = (float)(1.25 * sin(a * 0.6));
        pose.py = (float)(1.15 + 0.20 * sin(a * 0.45));
        pose.pz = (float)(2.05 + 0.30 * cos(a * 0.5));
        pose.tx = (float)(0.20 * sin(a * 0.35));
        pose.ty = (float)(0.80 + 0.10 * sin(a * 0.55));
        pose.tz = -0.60f;
        return pose;
    }

    NSInteger shot = _fixedShot >= 0 ? _fixedShot : (NSInteger)(now / kShotDuration) % kShotCount;
    if (shot != _currentShot) {
        _currentShot = shot;
        *shotChanged = YES;
    }
    return kShots[shot];
}

- (PTUniforms)nextPTUniformsForWidth:(NSUInteger)width
                              height:(NSUInteger)height
                       outputWidth:(NSUInteger)outputWidth
                      outputHeight:(NSUInteger)outputHeight {
    PTUniforms u;
    memset(&u, 0, sizeof(u));

    double now = CACurrentMediaTime() - _startTime;
    BOOL shotChanged = NO;
    CameraPose pose = [self cameraPoseForTime:now shotChanged:&shotChanged];
    BOOL firstFrame = !_hasPrevCamera;
    CameraPose prev = firstFrame ? pose : _prevCamera;

    u.resolution[0] = (float)width;
    u.resolution[1] = (float)height;
    u.outputResolution[0] = (float)outputWidth;
    u.outputResolution[1] = (float)outputHeight;
    u.time = (float)now;
    u.frame = (float)_ptFrameCount;
    u.cameraPos[0] = pose.px;
    u.cameraPos[1] = pose.py;
    u.cameraPos[2] = pose.pz;
    u.cameraTarget[0] = pose.tx;
    u.cameraTarget[1] = pose.ty;
    u.cameraTarget[2] = pose.tz;
    u.prevCameraPos[0] = prev.px;
    u.prevCameraPos[1] = prev.py;
    u.prevCameraPos[2] = prev.pz;
    u.prevCameraTarget[0] = prev.tx;
    u.prevCameraTarget[1] = prev.ty;
    u.prevCameraTarget[2] = prev.tz;
    u.frameSeed = (uint32_t)_ptFrameCount;
    u.samplesPerFrame = (uint32_t)MAX(_samplesPerFrame, 1);
    u.resetHistory = (firstFrame || shotChanged) ? 1 : 0;
    u.exposure = 1.0f;

    _prevCamera = pose;
    _hasPrevCamera = YES;
    _ptFrameCount++;
    return u;
}

- (void)encodePathTracerFrameWithCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
                          renderPassDescriptor:(MTLRenderPassDescriptor *)pass
{
    id<MTLTexture> target = pass.colorAttachments[0].texture;
    NSUInteger renderWidth = (NSUInteger)lround((double)target.width * _renderScale);
    NSUInteger renderHeight = (NSUInteger)lround((double)target.height * _renderScale);
    renderWidth = MAX(renderWidth, 1);
    renderHeight = MAX(renderHeight, 1);
    if (![self ensurePathTracerBuffersForWidth:renderWidth height:renderHeight]) {
        return;
    }

    _outputWidth = target.width;
    _outputHeight = target.height;

    PTUniforms uniforms = [self nextPTUniformsForWidth:renderWidth
                                                height:renderHeight
                                           outputWidth:target.width
                                          outputHeight:target.height];
    MTLSize threadsPerGroup = MTLSizeMake(8, 8, 1);
    MTLSize groups = MTLSizeMake((renderWidth + 7) / 8, (renderHeight + 7) / 8, 1);

    id<MTLComputeCommandEncoder> compute = [commandBuffer computeCommandEncoder];

    [compute setComputePipelineState:_tracePipeline];
    [compute setTexture:_radiance atIndex:0];
    [compute setTexture:_gCur atIndex:1];
    [compute setTexture:_guide atIndex:2];
    [compute setBytes:&uniforms length:sizeof(uniforms) atIndex:0];
    [compute dispatchThreadgroups:groups threadsPerThreadgroup:threadsPerGroup];
    [compute memoryBarrierWithScope:MTLBarrierScopeTextures];

    if (_denoiseEnabled) {
        [compute setComputePipelineState:_temporalPipeline];
        [compute setTexture:_radiance atIndex:0];
        [compute setTexture:_gCur atIndex:1];
        [compute setTexture:_gPrev atIndex:2];
        [compute setTexture:_histCur atIndex:3];
        [compute setTexture:_moments atIndex:4];
        [compute setTexture:_histPrev atIndex:5];
        [compute setBytes:&uniforms length:sizeof(uniforms) atIndex:0];
        [compute dispatchThreadgroups:groups threadsPerThreadgroup:threadsPerGroup];
        [compute memoryBarrierWithScope:MTLBarrierScopeTextures];

        [compute setComputePipelineState:_atrousPipeline];
        id<MTLTexture> destination[2] = { _filtA, _filtB };
        id<MTLTexture> source = _histPrev;
        for (int iteration = 0; iteration < 3; iteration++) {
            uniforms.filterStep = (uint32_t)(1 << iteration);
            [compute setTexture:source atIndex:0];
            [compute setTexture:_gCur atIndex:1];
            [compute setTexture:_moments atIndex:2];
            [compute setTexture:destination[iteration % 2] atIndex:3];
            [compute setTexture:_guide atIndex:4];
            [compute setBytes:&uniforms length:sizeof(uniforms) atIndex:0];
            [compute dispatchThreadgroups:groups threadsPerThreadgroup:threadsPerGroup];
            [compute memoryBarrierWithScope:MTLBarrierScopeTextures];
            source = destination[iteration % 2];
        }
        _displayTexture = source;

        id<MTLTexture> swap = _histCur;
        _histCur = _histPrev;
        _histPrev = swap;
    } else {
        _displayTexture = _radiance;
    }

    id<MTLTexture> gSwap = _gCur;
    _gCur = _gPrev;
    _gPrev = gSwap;

    [compute endEncoding];

    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:_rasterPipeline];
    [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
    [encoder setFragmentTexture:_displayTexture atIndex:0];
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

- (BOOL)renderOffscreenFrames:(NSUInteger)count
                        width:(NSUInteger)width
                       height:(NSUInteger)height
                        error:(NSError **)error {
    MTLTextureDescriptor *textureDescriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                           width:width
                                                          height:height
                                                       mipmapped:NO];
    textureDescriptor.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> texture = [_device newTextureWithDescriptor:textureDescriptor];
    if (!texture) {
        if (error) {
            *error = MakeError(8, @"could not create offscreen texture");
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
    if (_mode != RendererModePathTracer || !_displayTexture) {
        if (error) {
            *error = MakeError(9, @"no frame to write (path tracer did not run)");
        }
        return NO;
    }

    NSUInteger width = _outputWidth > 0 ? _outputWidth : _displayTexture.width;
    NSUInteger height = _outputHeight > 0 ? _outputHeight : _displayTexture.height;

    MTLTextureDescriptor *descriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                           width:width
                                                          height:height
                                                       mipmapped:NO];
    descriptor.usage = MTLTextureUsageRenderTarget;
    descriptor.storageMode = MTLStorageModeShared;
    id<MTLTexture> target = [_device newTextureWithDescriptor:descriptor];
    if (!target) {
        if (error) {
            *error = MakeError(10, @"could not create readback texture");
        }
        return NO;
    }

    PTUniforms uniforms;
    memset(&uniforms, 0, sizeof(uniforms));
    uniforms.resolution[0] = (float)_displayTexture.width;
    uniforms.resolution[1] = (float)_displayTexture.height;
    uniforms.outputResolution[0] = (float)width;
    uniforms.outputResolution[1] = (float)height;
    uniforms.exposure = 1.0f;

    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);

    id<MTLCommandBuffer> commandBuffer = [_queue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:_rasterPipeline];
    [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
    [encoder setFragmentTexture:_displayTexture atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];

    if (commandBuffer.error) {
        if (error) {
            *error = commandBuffer.error;
        }
        return NO;
    }

    NSUInteger bytesPerRow = width * 4;
    NSMutableData *raw = [NSMutableData dataWithLength:bytesPerRow * height];
    [target getBytes:raw.mutableBytes
         bytesPerRow:bytesPerRow
          fromRegion:MTLRegionMake2D(0, 0, width, height)
         mipmapLevel:0];

    FILE *file = fopen(path.fileSystemRepresentation, "wb");
    if (!file) {
        if (error) {
            *error = MakeError(11, [NSString stringWithFormat:@"could not open %@", path]);
        }
        return NO;
    }

    fprintf(file, "P6\n%lu %lu\n255\n", (unsigned long)width, (unsigned long)height);
    const unsigned char *pixels = (const unsigned char *)raw.bytes;
    for (NSUInteger y = 0; y < height; y++) {
        const unsigned char *row = pixels + y * bytesPerRow;
        for (NSUInteger x = 0; x < width; x++) {
            const unsigned char *pixel = row + x * 4;
            fputc(pixel[2], file);
            fputc(pixel[1], file);
            fputc(pixel[0], file);
        }
    }
    fclose(file);
    return YES;
}

@end
