//  CmuxTestWindowReleaseGuard.m
//
//  App-host unit tests create hundreds of NSWindows in Swift and close them in
//  test teardown. AppKit's default for code-created windows is
//  releasedWhenClosed == YES, so under ARC every close() sends an extra
//  release. The window then deallocates while still sitting in the test's
//  autorelease pool, and XCTest's post-test pool drain (XCTMemoryChecker)
//  crashes the shared app host with EXC_BAD_ACCESS in objc_release. On CI this
//  surfaced as dozens of silent "Restarting after unexpected exit" host
//  relaunches per shard, and cascading failures for whichever suite ran next.
//
//  This constructor runs when the test bundle loads and swizzles NSWindow's
//  designated initializers so every window created in the test process
//  defaults to releasedWhenClosed == NO, which is the only correct value for
//  ARC-managed windows. Nothing in cmux sets releasedWhenClosed = YES
//  deliberately; production code already sets NO defensively at 13 call sites.
//  Known tradeoff: AppKit-internal self-releasing windows leak instead of
//  freeing in the test process, which is harmless there.
//  Guarded by AppHostWindowReleaseGuardTests.

#import <AppKit/AppKit.h>
#import <objc/runtime.h>

static void CmuxSwizzleWindowInitializer(SEL selector) {
    Method method = class_getInstanceMethod([NSWindow class], selector);
    if (method == NULL) {
        return;
    }
    IMP original = method_getImplementation(method);
    id block;
    if (selector == @selector(initWithContentRect:styleMask:backing:defer:screen:)) {
        block = ^NSWindow *(NSWindow *self, NSRect rect, NSWindowStyleMask style,
                            NSBackingStoreType backing, BOOL defer, NSScreen *screen) {
            typedef NSWindow *(*Init)(NSWindow *, SEL, NSRect, NSWindowStyleMask,
                                      NSBackingStoreType, BOOL, NSScreen *);
            NSWindow *window = ((Init)original)(self, selector, rect, style, backing, defer, screen);
            window.releasedWhenClosed = NO;
            window.animationBehavior = NSWindowAnimationBehaviorNone;
            return window;
        };
    } else {
        block = ^NSWindow *(NSWindow *self, NSRect rect, NSWindowStyleMask style,
                            NSBackingStoreType backing, BOOL defer) {
            typedef NSWindow *(*Init)(NSWindow *, SEL, NSRect, NSWindowStyleMask,
                                      NSBackingStoreType, BOOL);
            NSWindow *window = ((Init)original)(self, selector, rect, style, backing, defer);
            window.releasedWhenClosed = NO;
            window.animationBehavior = NSWindowAnimationBehaviorNone;
            return window;
        };
    }
    method_setImplementation(method, imp_implementationWithBlock(block));
}

__attribute__((constructor)) static void CmuxInstallTestWindowReleaseGuard(void) {
    CmuxSwizzleWindowInitializer(@selector(initWithContentRect:styleMask:backing:defer:));
    CmuxSwizzleWindowInitializer(@selector(initWithContentRect:styleMask:backing:defer:screen:));
}
