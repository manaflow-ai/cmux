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
#import <errno.h>
#import <fcntl.h>
#import <objc/runtime.h>
#import <sys/stat.h>
#import <unistd.h>

static int CmuxAppHostReceiptFD = -1;

__attribute__((noreturn)) static void CmuxFailAppHostProcessReceipt(NSString *reason) {
    fprintf(stderr, "FAIL: app-host process receipt: %s\n", reason.UTF8String);
    abort();
}

static BOOL CmuxWriteAll(int descriptor, NSData *data) {
    const uint8_t *bytes = data.bytes;
    NSUInteger offset = 0;
    while (offset < data.length) {
        ssize_t written = write(descriptor, bytes + offset, data.length - offset);
        if (written > 0) {
            offset += (NSUInteger)written;
        } else if (written < 0 && errno == EINTR) {
            continue;
        } else {
            return NO;
        }
    }
    return YES;
}

static void CmuxDiscardTemporaryAppHostReceipt(int descriptor, NSURL *temporaryURL) {
    int savedErrno = errno;
    close(descriptor);
    unlink(temporaryURL.fileSystemRepresentation);
    errno = savedErrno;
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
    NSURL *receiptURL = [directoryURL URLByAppendingPathComponent:
                         [NSString stringWithFormat:@"app-host-%d.receipt", pid]
                                            isDirectory:NO];
    int descriptor = -1;
    NSURL *temporaryURL = nil;
    for (NSUInteger attempt = 0; attempt < 8; attempt++) {
        NSString *temporaryName = [NSString stringWithFormat:
                                   @".app-host-%d-%@.receipt.tmp",
                                   pid, NSUUID.UUID.UUIDString.lowercaseString];
        temporaryURL = [directoryURL URLByAppendingPathComponent:temporaryName
                                                      isDirectory:NO];
        descriptor = open(temporaryURL.fileSystemRepresentation,
                          O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                          S_IRUSR | S_IWUSR);
        if (descriptor >= 0) {
            break;
        }
        if (errno != EEXIST) {
            CmuxFailAppHostProcessReceipt(@"temporary receipt file could not be opened safely");
        }
    }
    if (descriptor < 0 || temporaryURL == nil) {
        CmuxFailAppHostProcessReceipt(@"a unique temporary receipt file could not be created");
    }
    if (fchmod(descriptor, S_IRUSR | S_IWUSR) != 0) {
        CmuxDiscardTemporaryAppHostReceipt(descriptor, temporaryURL);
        CmuxFailAppHostProcessReceipt(@"receipt permissions could not be restricted");
    }
    NSString *receipt = [NSString stringWithFormat:
                         @"version=2\nkey=%@\npid=%d\nexecutable=%@\nreceipt_fd=%d\n",
                         appHostKey, pid, executablePath, descriptor];
    NSData *receiptData = [receipt dataUsingEncoding:NSUTF8StringEncoding];
    if (!CmuxWriteAll(descriptor, receiptData) || fsync(descriptor) != 0) {
        CmuxDiscardTemporaryAppHostReceipt(descriptor, temporaryURL);
        CmuxFailAppHostProcessReceipt(@"receipt contents could not be persisted");
    }
    if (rename(temporaryURL.fileSystemRepresentation,
               receiptURL.fileSystemRepresentation) != 0) {
        CmuxDiscardTemporaryAppHostReceipt(descriptor, temporaryURL);
        CmuxFailAppHostProcessReceipt(@"receipt file could not be published atomically");
    }
    CmuxAppHostReceiptFD = descriptor;
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
