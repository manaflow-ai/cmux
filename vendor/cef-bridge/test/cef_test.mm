// Minimal standalone CEF test: creates an NSWindow with a CEF browser view.
// Build: see Makefile target 'test'
// Run: ./cef_test (from within a .app bundle with CEF framework)

#import <Cocoa/Cocoa.h>
#include "../cef_bridge.h"
#include <stdio.h>

static void on_title(cef_bridge_browser_t b, const char* title, void* ud) {
    printf("[CEF] title: %s\n", title);
    NSWindow* win = (__bridge NSWindow*)ud;
    dispatch_async(dispatch_get_main_queue(), ^{
        [win setTitle:[NSString stringWithUTF8String:title]];
    });
}

static void on_url(cef_bridge_browser_t b, const char* url, void* ud) {
    printf("[CEF] url: %s\n", url);
}

static void on_loading(cef_bridge_browser_t b, bool loading, bool back, bool fwd, void* ud) {
    printf("[CEF] loading=%d canGoBack=%d canGoForward=%d\n", loading, back, fwd);
}

int main(int argc, char* argv[]) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

        // Create window
        NSRect frame = NSMakeRect(100, 100, 1024, 768);
        NSWindow* window = [[NSWindow alloc]
            initWithContentRect:frame
            styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable)
            backing:NSBackingStoreBuffered
            defer:NO];
        [window setTitle:@"CEF Test"];
        NSView* contentView = [window contentView];
        [contentView setWantsLayer:YES];

        // Initialize CEF
        NSString* fwDir = [[[NSBundle mainBundle] privateFrameworksPath] stringByDeletingLastPathComponent];
        // Fallback: look for framework next to the binary
        if (![[NSFileManager defaultManager] fileExistsAtPath:
              [fwDir stringByAppendingPathComponent:@"Chromium Embedded Framework.framework"]]) {
            fwDir = [[[[NSProcessInfo processInfo] arguments][0]
                       stringByDeletingLastPathComponent]
                       stringByAppendingPathComponent:@"../Frameworks"];
        }
        NSString* helperPath = @""; // No helper for this test
        NSString* cachePath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"cef-test-cache"];

        printf("[CEF] Framework dir: %s\n", [fwDir UTF8String]);
        printf("[CEF] Cache: %s\n", [cachePath UTF8String]);

        int result = cef_bridge_initialize([fwDir UTF8String], [helperPath UTF8String], [cachePath UTF8String]);
        printf("[CEF] Initialize result: %d\n", result);

        if (result != 0) {
            printf("[CEF] FAILED to initialize. Exiting.\n");
            return 1;
        }

        // Create browser
        cef_bridge_client_callbacks cbs = {};
        cbs.user_data = (__bridge void*)window;
        cbs.on_title_change = on_title;
        cbs.on_url_change = on_url;
        cbs.on_loading_state_change = on_loading;

        NSRect bounds = [contentView bounds];
        cef_bridge_browser_t browser = cef_bridge_browser_create(
            NULL, "https://www.google.com",
            (__bridge void*)contentView,
            (int)bounds.size.width, (int)bounds.size.height,
            &cbs);

        printf("[CEF] Browser created: %p\n", browser);
        printf("[CEF] Content view subviews: %lu\n", (unsigned long)[[contentView subviews] count]);
        for (NSView* sub in [contentView subviews]) {
            printf("[CEF]   subview: %s frame=%.0f,%.0f,%.0f,%.0f\n",
                   [NSStringFromClass([sub class]) UTF8String],
                   sub.frame.origin.x, sub.frame.origin.y,
                   sub.frame.size.width, sub.frame.size.height);
        }

        [window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];

        // Pump CEF message loop via timer
        [NSTimer scheduledTimerWithTimeInterval:1.0/60.0 repeats:YES block:^(NSTimer* t) {
            cef_bridge_do_message_loop_work();
        }];

        // After 3 seconds, print view hierarchy and screenshot
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            printf("\n[CEF] === After 3s ===\n");
            printf("[CEF] Content view subviews: %lu\n", (unsigned long)[[contentView subviews] count]);
            for (NSView* sub in [contentView subviews]) {
                printf("[CEF]   subview: %s frame=%.0f,%.0f,%.0f,%.0f hidden=%d\n",
                       [NSStringFromClass([sub class]) UTF8String],
                       sub.frame.origin.x, sub.frame.origin.y,
                       sub.frame.size.width, sub.frame.size.height,
                       sub.isHidden);
                for (NSView* subsub in [sub subviews]) {
                    printf("[CEF]     subsubview: %s frame=%.0f,%.0f,%.0f,%.0f\n",
                           [NSStringFromClass([subsub class]) UTF8String],
                           subsub.frame.origin.x, subsub.frame.origin.y,
                           subsub.frame.size.width, subsub.frame.size.height);
                }
            }

            // Take screenshot
            NSBitmapImageRep* rep = [contentView bitmapImageRepForCachingDisplayInRect:[contentView bounds]];
            [contentView cacheDisplayInRect:[contentView bounds] toBitmapImageRep:rep];
            NSData* png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
            [png writeToFile:@"/tmp/cef-test-screenshot.png" atomically:YES];
            printf("[CEF] Screenshot saved to /tmp/cef-test-screenshot.png\n");
        });

        [NSApp run];
    }
    return 0;
}
