#import <Cocoa/Cocoa.h>
#import <MetalKit/MetalKit.h>

#include <stdio.h>
#include <string.h>

#import "renderer.h"
#import "shader_source.h"

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
    self.window.title = @"mac-demo-lab";

    self.view = [[DemoView alloc] initWithFrame:frame device:device];
    self.view.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    self.view.preferredFramesPerSecond = 60;
    self.view.enableSetNeedsDisplay = NO;
    self.view.paused = NO;
    self.view.clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);

    NSError *error = nil;
    self.renderer = [[Renderer alloc] initWithDevice:device
                                         pixelFormat:self.view.colorPixelFormat
                                        shaderSource:[NSString stringWithUTF8String:kShaderSource]
                                               error:&error];
    if (!self.renderer) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Metal setup failed";
        alert.informativeText = error.localizedDescription ?: @"unknown error";
        [alert runModal];
        [NSApp terminate:nil];
        return;
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

static int RunSmoke(NSUInteger frames) {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        fprintf(stderr, "no Metal device\n");
        return 1;
    }

    NSError *error = nil;
    Renderer *renderer = [[Renderer alloc] initWithDevice:device
                                              pixelFormat:MTLPixelFormatBGRA8Unorm
                                             shaderSource:[NSString stringWithUTF8String:kShaderSource]
                                                    error:&error];
    if (!renderer) {
        fprintf(stderr, "setup failed: %s\n", error.localizedDescription.UTF8String);
        return 1;
    }

    if (![renderer renderOffscreenFrames:frames error:&error]) {
        fprintf(stderr, "offscreen render failed: %s\n", error.localizedDescription.UTF8String);
        return 1;
    }

    printf("SMOKE OK - %s, %lu frames offscreen\n", device.name.UTF8String, (unsigned long)frames);
    return 0;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        BOOL smoke = NO;
        BOOL fullscreen = NO;
        NSUInteger smokeFrames = 8;

        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--smoke") == 0) {
                smoke = YES;
                if (i + 1 < argc && argv[i + 1][0] != '-') {
                    smokeFrames = (NSUInteger)atoi(argv[++i]);
                }
            } else if (strcmp(argv[i], "--fullscreen") == 0) {
                fullscreen = YES;
            } else if (strcmp(argv[i], "--help") == 0) {
                printf("usage: demo [--smoke [frames]] [--fullscreen]\n");
                return 0;
            }
        }

        if (smoke) {
            return RunSmoke(smokeFrames);
        }

        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];

        AppDelegate *delegate = [[AppDelegate alloc] init];
        delegate.startFullscreen = fullscreen;
        app.delegate = delegate;
        app.mainMenu = MakeMainMenu();
        [app run];
    }
    return 0;
}
