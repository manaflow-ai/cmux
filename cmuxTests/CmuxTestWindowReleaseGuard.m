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
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <sys/stat.h>
#import <unistd.h>

static void CmuxFailAppHostProcessReceipt(NSString *reason) {
    fprintf(stderr, "FAIL: app-host process receipt: %s\n", reason.UTF8String);
    abort();
}

static void CmuxWriteAppHostProcessReceipt(void) {
    NSDictionary<NSString *, NSString *> *environment = NSProcessInfo.processInfo.environment;
    if (![environment[@"CMUX_APP_HOST_ISOLATION_REQUIRED"] isEqualToString:@"1"]) {
        return;
    }

    NSString *receiptDirectory = environment[@"CMUX_APP_HOST_RECEIPT_DIR"];
    NSString *appHostKey = environment[@"CMUX_APP_HOST_KEY"];
    if (receiptDirectory.length == 0 || appHostKey.length != 12) {
        CmuxFailAppHostProcessReceipt(@"required identity is incomplete");
    }
    NSCharacterSet *nonHex = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet];
    if ([appHostKey rangeOfCharacterFromSet:nonHex].location != NSNotFound) {
        CmuxFailAppHostProcessReceipt(@"run key is malformed");
    }

    NSURL *executableURL = NSBundle.mainBundle.executableURL.URLByResolvingSymlinksInPath;
    NSString *executablePath = executableURL.path;
    if (executablePath.length == 0 ||
        [executablePath rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound) {
        CmuxFailAppHostProcessReceipt(@"executable path is unavailable");
    }

    NSURL *directoryURL = [NSURL fileURLWithPath:receiptDirectory isDirectory:YES];
    NSNumber *isDirectory = nil;
    NSError *error = nil;
    if (![directoryURL getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:&error] ||
        !isDirectory.boolValue) {
        CmuxFailAppHostProcessReceipt(@"receipt directory is unavailable");
    }

    pid_t pid = getpid();
    NSString *receipt = [NSString stringWithFormat:
                         @"version=1\nkey=%@\npid=%d\nexecutable=%@\n",
                         appHostKey, pid, executablePath];
    NSData *receiptData = [receipt dataUsingEncoding:NSUTF8StringEncoding];
    NSURL *receiptURL = [directoryURL URLByAppendingPathComponent:
                         [NSString stringWithFormat:@"app-host-%d.receipt", pid]
                                            isDirectory:NO];
    if (![receiptData writeToURL:receiptURL options:NSDataWritingAtomic error:&error]) {
        CmuxFailAppHostProcessReceipt(error.localizedDescription ?: @"atomic write failed");
    }
    if (chmod(receiptURL.fileSystemRepresentation, S_IRUSR | S_IWUSR) != 0) {
        CmuxFailAppHostProcessReceipt(@"receipt permissions could not be restricted");
    }
}

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
    CmuxWriteAppHostProcessReceipt();
    CmuxSwizzleWindowInitializer(@selector(initWithContentRect:styleMask:backing:defer:));
    CmuxSwizzleWindowInitializer(@selector(initWithContentRect:styleMask:backing:defer:screen:));
}
