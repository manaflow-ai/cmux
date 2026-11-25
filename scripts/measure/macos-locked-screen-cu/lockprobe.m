// lockprobe: what macOS lets a background process do to other apps' windows while the
// console session is screen-locked. Experiment tool for ask-3cf710da4e; not product code.
//
// Build: clang -fobjc-arc -framework Foundation -framework AppKit -framework CoreGraphics \
//   -framework ScreenCaptureKit -framework ApplicationServices -framework IOKit lockprobe.m -o lockprobe
// Every subcommand prints one JSON line.
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#include <dlfcn.h>

// CoreGraphics' virtual display classes (private; the same declarations DeskPad and
// BetterDisplay use).
@class CGVirtualDisplay;
@interface CGVirtualDisplayDescriptor : NSObject
@property (retain, nonatomic) dispatch_queue_t queue;
@property (retain, nonatomic) NSString *name;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int serialNum;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int vendorID;
@property (copy, nonatomic) void (^terminationHandler)(id, CGVirtualDisplay *);
@end
@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end
@interface CGVirtualDisplaySettings : NSObject
@property (retain, nonatomic) NSArray<CGVirtualDisplayMode *> *modes;
@property (nonatomic) unsigned int hiDPI;
@end
@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property (readonly, nonatomic) unsigned int displayID;
@end

static void out(NSDictionary *d) {
    NSData *j = [NSJSONSerialization dataWithJSONObject:d options:NSJSONWritingSortedKeys error:nil];
    printf("%s\n", [[NSString alloc] initWithData:j encoding:NSUTF8StringEncoding].UTF8String);
    fflush(stdout);
}

static NSDictionary *sessionState(void) {
    NSMutableDictionary *r = [NSMutableDictionary dictionary];
    CFDictionaryRef s = CGSessionCopyCurrentDictionary();
    if (s) {
        NSDictionary *d = (__bridge_transfer NSDictionary *)s;
        r[@"locked"] = d[@"CGSSessionScreenIsLocked"] ?: @NO;
        r[@"on_console"] = d[@"kCGSSessionOnConsoleKey"] ?: @NO;
        r[@"user"] = d[@"kCGSSessionUserNameKey"] ?: @"";
    } else {
        r[@"session"] = @"none";
    }
    uint32_t n = 0; CGDirectDisplayID ids[16];
    CGGetOnlineDisplayList(16, ids, &n);
    NSMutableArray *ds = [NSMutableArray array];
    for (uint32_t i = 0; i < n; i++) {
        CGRect b = CGDisplayBounds(ids[i]);
        [ds addObject:@{@"id": @(ids[i]), @"asleep": @(CGDisplayIsAsleep(ids[i])),
                        @"main": @(CGDisplayIsMain(ids[i])), @"active": @(CGDisplayIsActive(ids[i])),
                        @"bounds": NSStringFromRect(NSRectFromCGRect(b))}];
    }
    r[@"displays"] = ds;
    r[@"screen_capture_preflight"] = @(CGPreflightScreenCaptureAccess());
    r[@"ax_trusted"] = @(AXIsProcessTrusted());
    return r;
}

static BOOL writePNG(CGImageRef img, NSString *path) {
    if (!img) return NO;
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:img];
    return [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
}

// Fraction of sampled pixels that are not near-black and the number of distinct colors: a
// redacted or blank capture reads ~0 and ~1.
static NSDictionary *pixelStats(CGImageRef img) {
    if (!img) return @{};
    size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:img];
    NSMutableSet *colors = [NSMutableSet set];
    int lit = 0, total = 0;
    for (size_t y = 0; y < h; y += MAX(1, h / 40)) for (size_t x = 0; x < w; x += MAX(1, w / 40)) {
        NSColor *c = [[rep colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
        int r = (int)(c.redComponent * 255), g = (int)(c.greenComponent * 255), b = (int)(c.blueComponent * 255);
        [colors addObject:@((r >> 3) << 10 | (g >> 3) << 5 | (b >> 3))];
        if (r + g + b > 60) lit++;
        total++;
    }
    return @{@"w": @(w), @"h": @(h), @"lit": @(total ? (double)lit / total : 0), @"colors": @(colors.count)};
}

// A capture counts only when it was written and is not blank: a redacted picture (the
// black result of a capture macOS withholds) has almost no lit pixels or colors. A lock-screen or
// wallpaper picture still counts: read the PNG before calling a display capture working.
static BOOL hasContent(NSDictionary *stats) {
    return [stats[@"lit"] doubleValue] > 0.05 && [stats[@"colors"] intValue] > 2;
}

static NSArray *windowsOf(pid_t pid) {
    NSArray *all = (__bridge_transfer NSArray *)CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID);
    NSMutableArray *r = [NSMutableArray array];
    for (NSDictionary *w in all) {
        if (pid && [w[(id)kCGWindowOwnerPID] intValue] != pid) continue;
        if ([w[(id)kCGWindowLayer] intValue] != 0 && pid) continue;
        [r addObject:@{@"id": w[(id)kCGWindowNumber], @"pid": w[(id)kCGWindowOwnerPID],
                       @"owner": w[(id)kCGWindowOwnerName] ?: @"", @"name": w[(id)kCGWindowName] ?: @"",
                       @"layer": w[(id)kCGWindowLayer], @"onscreen": w[(id)kCGWindowIsOnscreen] ?: @NO,
                       @"bounds": w[(id)kCGWindowBounds] ?: @{}}];
    }
    return r;
}

static int cmdCaptureCG(CGWindowID wid, NSString *path) {
    typedef CGImageRef (*Fn)(CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption);
    Fn fn = (Fn)dlsym(RTLD_DEFAULT, "CGWindowListCreateImage");
    if (!fn) { out(@{@"cmd": @"capture-cg", @"error": @"CGWindowListCreateImage unavailable"}); return 1; }
    CGImageRef img = fn(CGRectNull, kCGWindowListOptionIncludingWindow, wid,
                        kCGWindowImageBoundsIgnoreFraming | kCGWindowImageBestResolution);
    BOOL wrote = writePNG(img, path);
    NSDictionary *stats = pixelStats(img);
    BOOL ok = wrote && hasContent(stats);
    out(@{@"cmd": @"capture-cg", @"window": @(wid), @"ok": @(ok), @"wrote": @(wrote), @"stats": stats, @"session": sessionState()});
    if (img) CGImageRelease(img);
    return ok ? 0 : 1;
}

// SkyLight's backing-store capture, Cua Driver's off-Space route.
static int cmdCaptureHW(CGWindowID wid, NSString *path) {
    void *sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
    int (*mainConn)(void) = sky ? dlsym(sky, "SLSMainConnectionID") : NULL;
    CFArrayRef (*cap)(int, uint32_t *, int, uint32_t) = sky ? dlsym(sky, "SLSHWCaptureWindowList") : NULL;
    if (!mainConn || !cap) { out(@{@"cmd": @"capture-hw", @"error": @"SkyLight symbols missing"}); return 1; }
    uint32_t w = wid;
    CFArrayRef arr = cap(mainConn(), &w, 1, (1 << 11) | (1 << 8));
    CGImageRef img = (arr && CFArrayGetCount(arr) > 0) ? (CGImageRef)CFArrayGetValueAtIndex(arr, 0) : NULL;
    BOOL wrote = writePNG(img, path);
    NSDictionary *stats = pixelStats(img);
    BOOL ok = wrote && hasContent(stats);
    out(@{@"cmd": @"capture-hw", @"window": @(wid), @"ok": @(ok), @"wrote": @(wrote), @"stats": stats, @"session": sessionState()});
    if (arr) CFRelease(arr);
    return ok ? 0 : 1;
}

static int cmdCaptureSCK(CGWindowID wid, NSString *path, BOOL display) {
    __block SCShareableContent *content = nil; __block NSError *err = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [SCShareableContent getShareableContentExcludingDesktopWindows:NO onScreenWindowsOnly:NO
                                                 completionHandler:^(SCShareableContent *c, NSError *e) {
        content = c; err = e; dispatch_semaphore_signal(sem);
    }];
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC))) {
        out(@{@"cmd": @"capture-sck", @"error": @"shareable content timed out", @"session": sessionState()}); return 1;
    }
    if (!content) { out(@{@"cmd": @"capture-sck", @"error": err.description ?: @"no content", @"session": sessionState()}); return 1; }
    SCContentFilter *filter = nil; CGSize size = CGSizeMake(800, 600);
    if (display) {
        for (SCDisplay *d in content.displays) if (d.displayID == wid) {
            filter = [[SCContentFilter alloc] initWithDisplay:d excludingWindows:@[]];
            size = CGSizeMake(d.width, d.height);
        }
    } else {
        for (SCWindow *w in content.windows) if (w.windowID == wid) {
            filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:w];
            size = w.frame.size;
        }
    }
    if (!filter) {
        out(@{@"cmd": @"capture-sck", @"error": @"target not in shareable content", @"windows": @(content.windows.count),
              @"displays": @(content.displays.count), @"session": sessionState()});
        return 1;
    }
    SCStreamConfiguration *cfg = [SCStreamConfiguration new];
    cfg.width = (size_t)size.width * 2; cfg.height = (size_t)size.height * 2; cfg.showsCursor = NO;
    __block CGImageRef img = NULL;
    [SCScreenshotManager captureImageWithFilter:filter configuration:cfg completionHandler:^(CGImageRef i, NSError *e) {
        if (i) img = CGImageRetain(i);
        err = e; dispatch_semaphore_signal(sem);
    }];
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC))) {
        out(@{@"cmd": @"capture-sck", @"error": @"capture timed out", @"session": sessionState()}); return 1;
    }
    BOOL wrote = writePNG(img, path);
    NSDictionary *stats = pixelStats(img);
    BOOL ok = wrote && hasContent(stats);
    out(@{@"cmd": display ? @"capture-sck-display" : @"capture-sck", @"target": @(wid), @"ok": @(ok), @"wrote": @(wrote),
          @"error": err.description ?: @"", @"stats": stats, @"session": sessionState()});
    if (img) CGImageRelease(img);
    return ok ? 0 : 1;
}

static void postKeys(pid_t pid, NSString *text) {
    CGEventSourceRef src = CGEventSourceCreate(kCGEventSourceStatePrivate);
    for (NSUInteger i = 0; i < text.length; i++) {
        UniChar ch = [text characterAtIndex:i];
        CGEventRef down = CGEventCreateKeyboardEvent(src, 0, true), up = CGEventCreateKeyboardEvent(src, 0, false);
        CGEventKeyboardSetUnicodeString(down, 1, &ch); CGEventKeyboardSetUnicodeString(up, 1, &ch);
        CGEventPostToPid(pid, down); usleep(8000); CGEventPostToPid(pid, up); usleep(8000);
        CFRelease(down); CFRelease(up);
    }
    if (src) CFRelease(src);
}

static void postHIDKeys(NSString *text) {
    for (NSUInteger i = 0; i < text.length; i++) {
        UniChar ch = [text characterAtIndex:i];
        CGEventRef down = CGEventCreateKeyboardEvent(NULL, 0, true), up = CGEventCreateKeyboardEvent(NULL, 0, false);
        CGEventKeyboardSetUnicodeString(down, 1, &ch); CGEventKeyboardSetUnicodeString(up, 1, &ch);
        CGEventPost(kCGHIDEventTap, down); usleep(8000); CGEventPost(kCGHIDEventTap, up); usleep(8000);
        CFRelease(down); CFRelease(up);
    }
}

// The text of the app's first text area / focused element, through Accessibility.
static NSString *axText(pid_t pid, AXError *errOut) {
    AXUIElementRef app = AXUIElementCreateApplication(pid);
    CFTypeRef win = NULL, val = NULL;
    AXError e = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute, &win);
    if (e != kAXErrorSuccess) {
        CFArrayRef wins = NULL;
        e = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, (CFTypeRef *)&wins);
        if (e == kAXErrorSuccess && wins && CFArrayGetCount(wins) > 0) { win = CFRetain(CFArrayGetValueAtIndex(wins, 0)); }
        if (wins) CFRelease(wins);
    }
    NSString *found = nil;
    if (win) {
        NSMutableArray *queue = [NSMutableArray arrayWithObject:(__bridge id)win];
        for (int n = 0; queue.count && n < 400 && !found; n++) {
            id held = queue[0];  // keeps the element alive after it leaves the queue
            [queue removeObjectAtIndex:0];
            AXUIElementRef el = (__bridge AXUIElementRef)held;
            CFTypeRef role = NULL;
            AXUIElementCopyAttributeValue(el, kAXRoleAttribute, &role);
            if (role && [(__bridge NSString *)role isEqualToString:(__bridge NSString *)kAXTextAreaRole]) {
                if (AXUIElementCopyAttributeValue(el, kAXValueAttribute, &val) == kAXErrorSuccess && val)
                    found = [(__bridge NSString *)val copy];
            }
            if (role) CFRelease(role);
            CFArrayRef kids = NULL;
            if (AXUIElementCopyAttributeValue(el, kAXChildrenAttribute, (CFTypeRef *)&kids) == kAXErrorSuccess && kids) {
                [queue addObjectsFromArray:(__bridge NSArray *)kids]; CFRelease(kids);
            }
        }
        CFRelease(win);
    }
    if (val) CFRelease(val);
    CFRelease(app);
    if (errOut) *errOut = e;
    return found;
}

static int cmdMoveWindow(pid_t pid, double x, double y) {
    AXUIElementRef app = AXUIElementCreateApplication(pid);
    CFArrayRef wins = NULL;
    AXError e = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, (CFTypeRef *)&wins);
    AXError se = kAXErrorFailure;
    if (e == kAXErrorSuccess && wins && CFArrayGetCount(wins) > 0) {
        CGPoint p = CGPointMake(x, y);
        AXValueRef v = AXValueCreate(kAXValueTypeCGPoint, &p);
        se = AXUIElementSetAttributeValue(CFArrayGetValueAtIndex(wins, 0), kAXPositionAttribute, v);
        CFRelease(v);
    }
    if (wins) CFRelease(wins);
    CFRelease(app);
    out(@{@"cmd": @"move-window", @"pid": @(pid), @"copy_err": @(e), @"set_err": @(se), @"windows": windowsOf(pid)});
    return se == kAXErrorSuccess ? 0 : 1;
}

// Holds a virtual display (and optionally a display-sleep assertion) until killed or `secs` pass.
static int cmdVDisplay(int secs, BOOL assertion) {
    Class descC = NSClassFromString(@"CGVirtualDisplayDescriptor");
    if (!descC) { out(@{@"cmd": @"vdisplay", @"error": @"CGVirtualDisplayDescriptor missing"}); return 1; }
    CGVirtualDisplayDescriptor *desc = [descC new];
    desc.queue = dispatch_get_main_queue();
    desc.name = @"cmux agent display";
    desc.maxPixelsWide = 1920; desc.maxPixelsHigh = 1200;
    desc.sizeInMillimeters = CGSizeMake(520, 325);
    desc.productID = 0xC0DE; desc.vendorID = 0xC0DE; desc.serialNum = 1;
    desc.terminationHandler = ^(id a, CGVirtualDisplay *d) { out(@{@"cmd": @"vdisplay", @"event": @"terminated"}); };
    CGVirtualDisplay *display = [[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:desc];
    CGVirtualDisplaySettings *settings = [NSClassFromString(@"CGVirtualDisplaySettings") new];
    settings.hiDPI = 0;
    settings.modes = @[[[NSClassFromString(@"CGVirtualDisplayMode") alloc] initWithWidth:1920 height:1200 refreshRate:60]];
    BOOL applied = [display applySettings:settings];
    IOPMAssertionID aid = 0; IOReturn ar = -1;
    if (assertion) ar = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleDisplaySleep, kIOPMAssertionLevelOn,
                                                   CFSTR("cmux lockprobe"), &aid);
    usleep(1500000);
    out(@{@"cmd": @"vdisplay", @"display_id": @(display.displayID), @"applied": @(applied), @"assertion": @(ar),
          @"pid": @(getpid()), @"session": sessionState()});
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:secs]];
    return 0;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "usage: lockprobe state|lock|windows [pid]|capture-cg WID PNG|capture-sck WID PNG|"
                                        "capture-sck-display DID PNG|type PID TEXT|type-hid TEXT|ax-text PID|"
                                        "move-window PID X Y|vdisplay SECS [assert]\n"); return 2; }
        NSString *cmd = @(argv[1]);
        if ([cmd isEqualToString:@"state"]) { out(sessionState()); return 0; }
        if ([cmd isEqualToString:@"lock"] || [cmd isEqualToString:@"switch-out"]) {
            // lock: the screen lock. switch-out: fast user switching to the login window, which takes
            // this session off the console, the state a second (background) login session is in.
            const char *sym = [cmd isEqualToString:@"lock"] ? "SACLockScreenImmediate" : "SACSwitchToLoginWindow";
            void *h = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY);
            int (*fn)(void) = h ? dlsym(h, sym) : NULL;
            if (!fn) { out(@{@"cmd": cmd, @"error": [NSString stringWithFormat:@"%s missing", sym]}); return 1; }
            int rc = fn(); usleep(3000000);
            out(@{@"cmd": cmd, @"rc": @(rc), @"session": sessionState()}); return 0;
        }
        if ([cmd isEqualToString:@"wid"] && argc > 2 && atoi(argv[2]) > 0) {
            // The app's on-screen normal window whose title holds argv[3] (any title without it), bare.
            NSString *want = argc > 3 ? @(argv[3]) : @"";
            for (NSDictionary *w in windowsOf(atoi(argv[2])))
                if ([w[@"layer"] intValue] == 0 && [w[@"onscreen"] boolValue]
                    && (!want.length || [w[@"name"] rangeOfString:want].location != NSNotFound)) {
                    printf("%s\n", [w[@"id"] description].UTF8String); return 0;
                }
            printf("0\n"); return 1;
        }
        if ([cmd isEqualToString:@"main-display"]) { printf("%u\n", CGMainDisplayID()); return 0; }
        if ([cmd isEqualToString:@"display-x"] && argc > 2) {  // the left edge of display ID, bare
            printf("%d\n", (int)CGDisplayBounds((CGDirectDisplayID)atoi(argv[2])).origin.x); return 0;
        }
        if ([cmd isEqualToString:@"mcp-result"] && argc > 3) {
            // One JSON-RPC tools/call response: its text, isError, and its first image written to argv[3].
            NSData *data = [NSData dataWithContentsOfFile:@(argv[2])];
            NSDictionary *resp = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            NSDictionary *result = [resp isKindOfClass:NSDictionary.class] ? resp[@"result"] : nil;
            NSMutableString *text = [NSMutableString string]; BOOL wrote = NO; NSDictionary *stats = @{};
            for (NSDictionary *c in result[@"content"] ?: @[]) {
                if ([c[@"type"] isEqualToString:@"text"]) [text appendString:c[@"text"] ?: @""];
                if ([c[@"type"] isEqualToString:@"image"] && !wrote) {
                    NSData *png = [[NSData alloc] initWithBase64EncodedString:c[@"data"] ?: @"" options:0];
                    wrote = [png writeToFile:@(argv[3]) atomically:YES];
                    NSBitmapImageRep *rep = png ? [NSBitmapImageRep imageRepWithData:png] : nil;
                    if (rep.CGImage) stats = pixelStats(rep.CGImage);
                }
            }
            out(@{@"cmd": @"mcp-result", @"is_error": result[@"isError"] ?: @NO, @"rpc_error": resp[@"error"] ?: [NSNull null],
                  @"text": text.length > 600 ? [text substringToIndex:600] : text, @"image": @(wrote), @"stats": stats,
                  @"session": sessionState()});
            return 0;
        }
        if ([cmd isEqualToString:@"windows"]) {
            out(@{@"cmd": @"windows", @"windows": windowsOf(argc > 2 ? atoi(argv[2]) : 0)}); return 0;
        }
        if ([cmd isEqualToString:@"capture-cg"] && argc > 3) return cmdCaptureCG((CGWindowID)atoi(argv[2]), @(argv[3]));
        if ([cmd isEqualToString:@"capture-hw"] && argc > 3) return cmdCaptureHW((CGWindowID)atoi(argv[2]), @(argv[3]));
        if ([cmd isEqualToString:@"capture-sck"] && argc > 3) return cmdCaptureSCK((CGWindowID)atoi(argv[2]), @(argv[3]), NO);
        if ([cmd isEqualToString:@"capture-sck-display"] && argc > 3) return cmdCaptureSCK((CGWindowID)atoi(argv[2]), @(argv[3]), YES);
        if ([cmd isEqualToString:@"type"] && argc > 3) {
            pid_t pid = atoi(argv[2]);
            AXError e0; NSString *before = axText(pid, &e0);
            postKeys(pid, @(argv[3])); usleep(500000);
            AXError e1; NSString *after = axText(pid, &e1);
            out(@{@"cmd": @"type", @"route": @"CGEventPostToPid", @"before": before ?: [NSNull null],
                  @"after": after ?: [NSNull null], @"ax_err": @(e1), @"session": sessionState()});
            return 0;
        }
        if ([cmd isEqualToString:@"type-hid"] && argc > 3) {
            pid_t pid = atoi(argv[2]);
            AXError e0; NSString *before = axText(pid, &e0);
            postHIDKeys(@(argv[3])); usleep(500000);
            AXError e1; NSString *after = axText(pid, &e1);
            out(@{@"cmd": @"type-hid", @"route": @"CGEventPost(HID)", @"before": before ?: [NSNull null],
                  @"after": after ?: [NSNull null], @"session": sessionState()});
            return 0;
        }
        if ([cmd isEqualToString:@"ax-text"] && argc > 2) {
            AXError e; NSString *t = axText(atoi(argv[2]), &e);
            out(@{@"cmd": @"ax-text", @"text": t ?: [NSNull null], @"ax_err": @(e), @"session": sessionState()}); return 0;
        }
        if ([cmd isEqualToString:@"ax-set"] && argc > 3) {
            // AXValue write on the first text area: the no-event input route.
            AXUIElementRef app = AXUIElementCreateApplication(atoi(argv[2]));
            CFTypeRef el = NULL;
            AXError e = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute, &el);
            AXError se = el ? AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute, (__bridge CFStringRef)@(argv[3])) : e;
            AXError e1; NSString *t = axText(atoi(argv[2]), &e1);
            out(@{@"cmd": @"ax-set", @"focused_err": @(e), @"set_err": @(se), @"after": t ?: [NSNull null], @"session": sessionState()});
            if (el) CFRelease(el);
            CFRelease(app);
            return 0;
        }
        if ([cmd isEqualToString:@"move-window"] && argc > 4) return cmdMoveWindow(atoi(argv[2]), atof(argv[3]), atof(argv[4]));
        if ([cmd isEqualToString:@"vdisplay"] && argc > 2) return cmdVDisplay(atoi(argv[2]), argc > 3);
        fprintf(stderr, "unknown command\n");
        return 2;
    }
}
