#import <Cocoa/Cocoa.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>

#include <math.h>
#include <stdio.h>
#include <string.h>

#import "renderer.h"
#import "synth.h"
#import "shader_source.h"
#import "pathtracer_source.h"

static const char *SourceForMode(RendererMode mode) {
    return mode == RendererModeSDF ? kShaderSource : kPathTracerSource;
}

static const char *NameForMode(RendererMode mode) {
    return mode == RendererModeSDF ? "sdf" : "pt";
}

@interface DemoView : MTKView
@end

@implementation DemoView

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (void)keyDown:(NSEvent *)event {
    NSString *chars = event.charactersIgnoringModifiers;
    if ([chars isEqualToString:@"\x1b"]) {
        [NSApp terminate:nil];
    } else if ([chars isEqualToString:@"f"]) {
        [self.window toggleFullScreen:nil];
    } else if ([chars isEqualToString:@"p"]) {
        self.paused = !self.paused;
    } else {
        [super keyDown:event];
    }
}

@end

@interface AppDelegate : NSObject <NSApplicationDelegate, MTKViewDelegate>
@property (strong, nonatomic) NSWindow *window;
@property (strong, nonatomic) DemoView *view;
@property (strong, nonatomic) Renderer *renderer;
@property (nonatomic) BOOL startFullscreen;
@property (nonatomic) RendererMode mode;
@property (nonatomic) NSUInteger samplesPerFrame;
@property (nonatomic) double renderScale;
@property (nonatomic) BOOL denoiseEnabled;
@property (nonatomic) BOOL continuousMotion;
@property (nonatomic) NSUInteger fpsFrames;
@property (nonatomic) NSTimeInterval fpsWindowStart;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    NSRect frame = NSMakeRect(0, 0, 1280, 720);

    self.window = [[NSWindow alloc] initWithContentRect:frame
                                             styleMask:(NSWindowStyleMaskTitled |
                                                        NSWindowStyleMaskClosable |
                                                        NSWindowStyleMaskMiniaturizable |
                                                        NSWindowStyleMaskResizable)
                                               backing:NSBackingStoreBuffered
                                                 defer:NO];
    self.window.title = [NSString stringWithFormat:@"mac-demo-lab (%s)", NameForMode(self.mode)];
    self.fpsWindowStart = CACurrentMediaTime();

    self.view = [[DemoView alloc] initWithFrame:frame device:device];
    self.view.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    self.view.preferredFramesPerSecond = 60;
    self.view.enableSetNeedsDisplay = NO;
    self.view.paused = NO;
    self.view.clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);

    NSError *error = nil;
    self.renderer = [[Renderer alloc] initWithDevice:device
                                         pixelFormat:self.view.colorPixelFormat
                                        shaderSource:[NSString stringWithUTF8String:SourceForMode(self.mode)]
                                                mode:self.mode
                                               error:&error];
    if (!self.renderer) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Metal setup failed";
        alert.informativeText = error.localizedDescription ?: @"unknown error";
        [alert runModal];
        [NSApp terminate:nil];
        return;
    }

    if (self.samplesPerFrame > 0) {
        self.renderer.samplesPerFrame = self.samplesPerFrame;
    }
    if (self.renderScale > 0.0) {
        self.renderer.renderScale = self.renderScale;
    }
    self.renderer.denoiseEnabled = self.denoiseEnabled;
    self.renderer.continuousMotion = self.continuousMotion;

    self.view.delegate = self;
    self.window.contentView = self.view;
    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
    [self.window makeFirstResponder:self.view];
    [NSApp activateIgnoringOtherApps:YES];

    if (self.startFullscreen) {
        [self.window toggleFullScreen:nil];
    }
}

- (void)drawInMTKView:(MTKView *)view {
    [self.renderer drawInView:view];

    self.fpsFrames++;
    NSTimeInterval now = CACurrentMediaTime();
    NSTimeInterval elapsed = now - self.fpsWindowStart;
    if (elapsed >= 0.5) {
        double fps = self.fpsFrames / elapsed;
        self.window.title = [NSString stringWithFormat:@"mac-demo-lab (%s, %s) - %.1f fps",
                             NameForMode(self.mode),
                             self.denoiseEnabled ? "denoise" : "raw",
                             fps];
        self.fpsFrames = 0;
        self.fpsWindowStart = now;
    }
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    (void)view;
    (void)size;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender;
    return YES;
}

@end

static NSMenu *MakeMainMenu(void) {
    NSMenu *menu = [[NSMenu alloc] init];
    NSMenuItem *appItem = [[NSMenuItem alloc] init];
    [menu addItem:appItem];
    NSMenu *appMenu = [[NSMenu alloc] init];
    [appMenu addItemWithTitle:@"Quit mac-demo-lab" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;
    return menu;
}

static int RunAudioRender(NSString *path) {
    Synth synth;
    synth.renderTrack();

    const float *data = synth.interleaved();
    size_t frames = synth.frameCount();
    double peak = 0.0;
    double sumSquares = 0.0;
    for (size_t i = 0; i < frames * 2; ++i) {
        double v = fabs((double)data[i]);
        if (v > peak) {
            peak = v;
        }
        sumSquares += v * v;
    }
    double rms = sqrt(sumSquares / (double)(frames * 2));

    if (!WriteWavPcm16(path.fileSystemRepresentation, data, frames, Synth::kSampleRate)) {
        fprintf(stderr, "could not write %s\n", path.UTF8String);
        return 1;
    }
    printf("audio: %s (%.1f s, peak %.3f, rms %.3f)\n", path.UTF8String,
           (double)frames / Synth::kSampleRate, peak, rms);
    return 0;
}

static int RunOffscreen(RendererMode mode, NSUInteger frames, NSString *shotPath, NSUInteger spp,
                        BOOL denoise, BOOL move, NSUInteger width, NSUInteger height,
                        double scale) {
    if (shotPath && mode != RendererModePathTracer) {
        fprintf(stderr, "--shot is only supported with --mode pt\n");
        return 2;
    }

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        fprintf(stderr, "no Metal device\n");
        return 1;
    }

    NSError *error = nil;
    Renderer *renderer = [[Renderer alloc] initWithDevice:device
                                              pixelFormat:MTLPixelFormatBGRA8Unorm
                                             shaderSource:[NSString stringWithUTF8String:SourceForMode(mode)]
                                                     mode:mode
                                                    error:&error];
    if (!renderer) {
        fprintf(stderr, "setup failed: %s\n", error.localizedDescription.UTF8String);
        return 1;
    }

    if (spp > 0) {
        renderer.samplesPerFrame = spp;
    }
    if (scale > 0.0) {
        renderer.renderScale = scale;
    }
    renderer.denoiseEnabled = denoise;
    renderer.continuousMotion = move;

    if (shotPath) {
        renderer.fixedShot = 0;
    }

    double startTime = CACurrentMediaTime();
    if (![renderer renderOffscreenFrames:frames width:width height:height error:&error]) {
        fprintf(stderr, "offscreen render failed: %s\n", error.localizedDescription.UTF8String);
        return 1;
    }
    double elapsed = CACurrentMediaTime() - startTime;
    double fps = elapsed > 0 ? frames / elapsed : 0;

    if (shotPath) {
        if (![renderer writeSnapshotToPath:shotPath error:&error]) {
            fprintf(stderr, "snapshot failed: %s\n", error.localizedDescription.UTF8String);
            return 1;
        }
        printf("shot: %s (%lu frames, %lu spp, mode %s, denoise %s, %s, %.1f fps)\n",
               shotPath.UTF8String, (unsigned long)frames, (unsigned long)renderer.samplesPerFrame,
               NameForMode(mode), denoise ? "on" : "off", move ? "moving" : "static", fps);
    } else {
        printf("SMOKE OK - %s, mode %s, %lu frames offscreen (%.1f fps)\n",
               device.name.UTF8String, NameForMode(mode), (unsigned long)frames, fps);
    }
    return 0;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        RendererMode mode = RendererModePathTracer;
        BOOL smoke = NO;
        BOOL fullscreen = NO;
        NSUInteger smokeFrames = 8;
        NSString *shotPath = nil;
        NSUInteger shotFrames = 240;
        NSUInteger spp = 0;
        BOOL denoise = YES;
        BOOL move = NO;
        NSUInteger width = 1280;
        NSUInteger height = 720;
        double scale = 0.0;
        NSString *audioPath = nil;

        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--smoke") == 0) {
                smoke = YES;
                if (i + 1 < argc && argv[i + 1][0] != '-') {
                    smokeFrames = (NSUInteger)atoi(argv[++i]);
                }
            } else if (strcmp(argv[i], "--shot") == 0 && i + 1 < argc) {
                shotPath = [NSString stringWithUTF8String:argv[++i]];
                if (i + 1 < argc && argv[i + 1][0] != '-') {
                    shotFrames = (NSUInteger)atoi(argv[++i]);
                }
            } else if (strcmp(argv[i], "--mode") == 0 && i + 1 < argc) {
                const char *name = argv[++i];
                if (strcmp(name, "sdf") == 0) {
                    mode = RendererModeSDF;
                } else if (strcmp(name, "pt") == 0 || strcmp(name, "pathtracer") == 0) {
                    mode = RendererModePathTracer;
                } else {
                    fprintf(stderr, "unknown mode: %s (expected sdf or pt)\n", name);
                    return 2;
                }
            } else if (strcmp(argv[i], "--spp") == 0 && i + 1 < argc) {
                spp = (NSUInteger)atoi(argv[++i]);
            } else if (strcmp(argv[i], "--no-denoise") == 0) {
                denoise = NO;
            } else if (strcmp(argv[i], "--move") == 0) {
                move = YES;
            } else if (strcmp(argv[i], "--size") == 0 && i + 1 < argc) {
                unsigned int w = 0;
                unsigned int h = 0;
                if (sscanf(argv[++i], "%ux%u", &w, &h) != 2 || w == 0 || h == 0) {
                    fprintf(stderr, "invalid size (expected WxH, e.g. 2560x1440)\n");
                    return 2;
                }
                width = w;
                height = h;
            } else if (strcmp(argv[i], "--scale") == 0 && i + 1 < argc) {
                scale = atof(argv[++i]);
                if (scale <= 0.0 || scale > 1.0) {
                    fprintf(stderr, "invalid scale (expected > 0 and <= 1, e.g. 0.5)\n");
                    return 2;
                }
            } else if (strcmp(argv[i], "--render-audio") == 0 && i + 1 < argc) {
                audioPath = [NSString stringWithUTF8String:argv[++i]];
            } else if (strcmp(argv[i], "--fullscreen") == 0) {
                fullscreen = YES;
            } else if (strcmp(argv[i], "--help") == 0) {
                printf("usage: demo [--mode sdf|pt] [--smoke [frames]] "
                       "[--shot FILE [frames]] [--size WxH] [--scale S] [--spp N] "
                       "[--no-denoise] [--move] [--render-audio FILE] [--fullscreen]\n");
                return 0;
            } else {
                fprintf(stderr, "unknown argument: %s\n", argv[i]);
                return 2;
            }
        }

        if (audioPath) {
            return RunAudioRender(audioPath);
        }

        if (shotPath) {
            return RunOffscreen(mode, shotFrames, shotPath, spp, denoise, move, width, height, scale);
        }
        if (smoke) {
            return RunOffscreen(mode, smokeFrames, nil, spp, denoise, move, width, height, scale);
        }

        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];

        AppDelegate *delegate = [[AppDelegate alloc] init];
        delegate.startFullscreen = fullscreen;
        delegate.mode = mode;
        delegate.samplesPerFrame = spp > 0 ? spp : 8;
        delegate.renderScale = scale > 0.0 ? scale : 0.5;
        delegate.denoiseEnabled = denoise;
        delegate.continuousMotion = move;
        app.delegate = delegate;
        app.mainMenu = MakeMainMenu();
        [app run];
    }
    return 0;
}
