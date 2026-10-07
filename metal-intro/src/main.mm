#import <Cocoa/Cocoa.h>
#import <MetalKit/MetalKit.h>

#include <stdio.h>
#include <string.h>

#import "renderer.h"
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

static int RunOffscreen(RendererMode mode, NSUInteger frames, NSString *shotPath, NSUInteger spp) {
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
    } else if (shotPath) {
        renderer.samplesPerFrame = 16;
    }

    if (shotPath) {
        renderer.fixedShot = 0;
    }

    if (![renderer renderOffscreenFrames:frames error:&error]) {
        fprintf(stderr, "offscreen render failed: %s\n", error.localizedDescription.UTF8String);
        return 1;
    }

    if (shotPath) {
        if (![renderer writeSnapshotToPath:shotPath error:&error]) {
            fprintf(stderr, "snapshot failed: %s\n", error.localizedDescription.UTF8String);
            return 1;
        }
        printf("shot: %s (%lu frames, %lu samples, mode %s)\n", shotPath.UTF8String,
               (unsigned long)frames, (unsigned long)renderer.accumulatedSamples,
               NameForMode(mode));
    } else {
        printf("SMOKE OK - %s, mode %s, %lu frames offscreen\n",
               device.name.UTF8String, NameForMode(mode), (unsigned long)frames);
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
            } else if (strcmp(argv[i], "--fullscreen") == 0) {
                fullscreen = YES;
            } else if (strcmp(argv[i], "--help") == 0) {
                printf("usage: demo [--mode sdf|pt] [--smoke [frames]] "
                       "[--shot FILE [frames]] [--spp N] [--fullscreen]\n");
                return 0;
            } else {
                fprintf(stderr, "unknown argument: %s\n", argv[i]);
                return 2;
            }
        }

        if (shotPath) {
            return RunOffscreen(mode, shotFrames, shotPath, spp);
        }
        if (smoke) {
            return RunOffscreen(mode, smokeFrames, nil, spp);
        }

        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];

        AppDelegate *delegate = [[AppDelegate alloc] init];
        delegate.startFullscreen = fullscreen;
        delegate.mode = mode;
        delegate.samplesPerFrame = spp;
        app.delegate = delegate;
        app.mainMenu = MakeMainMenu();
        [app run];
    }
    return 0;
}
