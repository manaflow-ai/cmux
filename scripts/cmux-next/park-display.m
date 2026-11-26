// park-display: hold a virtual display that no person looks at, so a side instance's windows open there instead of
// on the person's screens (side-instance.sh launch, the default "parked" placement).
//
//   park-display [--pid-file FILE] [--ready-file FILE] [--hold SECONDS] [--size WxH] [--window]
//
// Makes a HiDPI virtual display (WxH points, default 1440x900, backed by twice the pixels, as on a Retina Mac) and
// arranges it so it touches the other displays at one corner only: below and right of all of them, sharing
// PARK_OVERLAP points of edge with the bottom-right display (macOS keeps every display contiguous, so it cannot be
// fully apart). The person's displays, their windows and the menu bar stay where they were; the arrangement is
// for this login session only and the display goes away when this process exits.
//
// Prints one line once the display exists and AppKit lists it:
//   ready display=ID screen=INDEX frame=X,Y,W,H
// (on stdout, and into --ready-file when given: side-instance.sh starts it with `open`, so it runs in the console
// session even from ssh, and reads the line from the file). INDEX is its place in NSScreen.screens, what the app reads in CMUX_NEXT_TEST_WINDOW_SCREEN (TestWindowPlacement).
// Every window an app opens under CMUX_NEXT_NO_ACTIVATE=1 plus that index opens on this display, never key, never
// activating the app. A window there still draws, so `screencapture -l WINDOW`, CGWindowListCreateImage and
// window-based recording see it (docs/cmux-next/hot-reload.md, "Background by default").
//
// It exits (and the display goes) when: SIGTERM/SIGINT; --hold seconds pass (default 12 h); or --pid-file names a
// pid that is gone, or the file was there and is removed (side-instance.sh stop removes NAME/pid).
// --window: open a 400x300 test window on the display and print "window ID" (the live check in
// tests/test_side_instance_parked_launch.py's docstring).
//
// Private API (CGVirtualDisplay), as scripts/ci/frame-pacing/vdisplay.m and hq's pr_capture/hidpi_display.m use it.
// Build: clang -fobjc-arc -framework AppKit -framework CoreGraphics park-display.m -o park-display
#import <AppKit/AppKit.h>
#include <signal.h>

@interface CGVirtualDisplayDescriptor : NSObject
@property (retain, nonatomic) dispatch_queue_t queue;
@property (retain, nonatomic) NSString *name;
@property (nonatomic) unsigned int maxPixelsWide, maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int productID, vendorID, serialNum;
@property (nonatomic) CGPoint redPrimary, greenPrimary, bluePrimary, whitePoint;
@end
@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end
@interface CGVirtualDisplaySettings : NSObject
@property (retain, nonatomic) NSArray *modes;
@property (nonatomic) unsigned int hiDPI;
@end
@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property (readonly, nonatomic) CGDirectDisplayID displayID;
@end

static const int PARK_OVERLAP = 8;  // points of edge shared with the person's bottom-right display
static volatile sig_atomic_t stop = 0;
static void on_signal(int sig) { (void)sig; stop = 1; }

// Puts DISPLAY below and right of every other active display, sharing PARK_OVERLAP points of edge.
static CGError park(CGDirectDisplayID display) {
  CGDirectDisplayID ids[32];
  uint32_t count = 0;
  if (CGGetActiveDisplayList(32, ids, &count) != kCGErrorSuccess) return kCGErrorFailure;
  CGFloat maxX = 0, maxY = 0;
  BOOL any = NO;
  for (uint32_t i = 0; i < count; i++) {
    if (ids[i] == display || CGDisplayMirrorsDisplay(ids[i]) != kCGNullDirectDisplay) continue;
    CGRect b = CGDisplayBounds(ids[i]);
    if (!any || CGRectGetMaxX(b) > maxX) maxX = CGRectGetMaxX(b);
    if (!any || CGRectGetMaxY(b) > maxY) maxY = CGRectGetMaxY(b);
    any = YES;
  }
  if (!any) return kCGErrorSuccess;
  CGDisplayConfigRef config;
  if (CGBeginDisplayConfiguration(&config) != kCGErrorSuccess) return kCGErrorFailure;
  CGConfigureDisplayOrigin(config, display, (int32_t)(maxX - PARK_OVERLAP), (int32_t)maxY);
  return CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
}

static NSInteger screenIndex(CGDirectDisplayID display, NSScreen **found) {
  NSArray<NSScreen *> *screens = [NSScreen screens];
  for (NSUInteger i = 0; i < screens.count; i++) {
    NSNumber *number = screens[i].deviceDescription[@"NSScreenNumber"];
    if (number.unsignedIntValue == display) { if (found) *found = screens[i]; return (NSInteger)i; }
  }
  return -1;
}

// Says why on stderr and, when side-instance.sh waits on a ready file, there too ("failed REASON"), so the launch
// falls back at once instead of waiting out its whole ready bound (15 s per try on a Mac where it fails).
static int failed(NSString *readyFile, NSString *why) {
  fprintf(stderr, "park-display: %s\n", why.UTF8String);
  if (readyFile) [[NSString stringWithFormat:@"failed %@\n", why] writeToFile:readyFile atomically:YES
                                                                     encoding:NSUTF8StringEncoding error:nil];
  return 1;
}

static BOOL pidFileSaysGone(NSString *path, BOOL *seen) {
  if (!path) return NO;
  NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
  if (!text) return *seen;  // removed after it was there: the copy was stopped
  *seen = YES;
  int pid = [[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] intValue];
  return pid > 0 && kill(pid, 0) != 0 && errno == ESRCH;
}

int main(int argc, char **argv) {
  @autoreleasepool {
    NSString *pidFile = nil, *readyFile = nil;
    double hold = 12 * 3600;
    unsigned int width = 1440, height = 900;
    BOOL testWindow = NO;
    for (int i = 1; i < argc; i++) {
      if (strcmp(argv[i], "--pid-file") == 0 && i + 1 < argc) pidFile = @(argv[++i]);
      else if (strcmp(argv[i], "--ready-file") == 0 && i + 1 < argc) readyFile = @(argv[++i]);
      else if (strcmp(argv[i], "--hold") == 0 && i + 1 < argc) hold = atof(argv[++i]);
      else if (strcmp(argv[i], "--size") == 0 && i + 1 < argc) {
        if (sscanf(argv[++i], "%ux%u", &width, &height) != 2 || width < 640 || height < 480 || width > 3000 ||
            height > 2000) { fprintf(stderr, "park-display: --size WxH within 640x480..3000x2000\n"); return 2; }
      } else if (strcmp(argv[i], "--window") == 0) testWindow = YES;
      else { fprintf(stderr, "usage: park-display [--pid-file FILE] [--ready-file FILE] [--hold SECONDS] [--size WxH] [--window]\n"); return 2; }
    }
    signal(SIGTERM, on_signal);
    signal(SIGINT, on_signal);
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];

    CGVirtualDisplayDescriptor *descriptor = [CGVirtualDisplayDescriptor new];
    descriptor.queue = dispatch_get_main_queue();
    descriptor.name = @"cmux parked windows";
    descriptor.maxPixelsWide = width * 2;
    descriptor.maxPixelsHigh = height * 2;
    descriptor.sizeInMillimeters = CGSizeMake(width * 25.4 / 110.0, height * 25.4 / 110.0);
    descriptor.productID = 0xC3A7;
    descriptor.vendorID = 0xC3A7;
    descriptor.serialNum = (unsigned int)getpid();
    // sRGB primaries: without them the display may get no modes (as Chromium's virtual display helper sets them).
    descriptor.redPrimary = CGPointMake(0.64, 0.33);
    descriptor.greenPrimary = CGPointMake(0.30, 0.60);
    descriptor.bluePrimary = CGPointMake(0.15, 0.06);
    descriptor.whitePoint = CGPointMake(0.3127, 0.3290);
    CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:descriptor];
    if (!display || display.displayID == 0) return failed(readyFile, @"no virtual display");
    CGVirtualDisplaySettings *settings = [CGVirtualDisplaySettings new];
    settings.hiDPI = 1;
    settings.modes = @[[[CGVirtualDisplayMode alloc] initWithWidth:width height:height refreshRate:60]];
    if (![display applySettings:settings]) return failed(readyFile, @"the display took no mode");

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
    NSScreen *screen = nil;
    NSInteger index = -1;
    BOOL parked = NO;
    while (!stop && [deadline timeIntervalSinceNow] > 0) {
      [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
      if (!parked && CGDisplayIsActive(display.displayID)) {
        CGError error = park(display.displayID);
        if (error != kCGErrorSuccess) return failed(readyFile, [NSString stringWithFormat:@"arranging the display failed (%d)", error]);
        parked = YES;
      }
      // AppKit lists the display before it hears of the new arrangement; wait until its frame is the parked one.
      if (parked && (index = screenIndex(display.displayID, &screen)) >= 0 &&
          (int)NSMinX(screen.frame) == (int)CGDisplayBounds(display.displayID).origin.x) break;
      index = -1;
    }
    if (index < 0) return failed(readyFile, @"AppKit never listed the display where it was parked");
    CGRect b = CGDisplayBounds(display.displayID);
    NSMutableString *ready = [NSMutableString stringWithFormat:@"ready display=%u screen=%ld frame=%d,%d,%d,%d\n",
        display.displayID, (long)index, (int)b.origin.x, (int)b.origin.y, (int)b.size.width, (int)b.size.height];
    if (testWindow) {
      NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 300)
                                                     styleMask:NSWindowStyleMaskTitled
                                                       backing:NSBackingStoreBuffered defer:NO screen:screen];
      [window setFrameOrigin:NSMakePoint(NSMidX(screen.frame) - 200, NSMidY(screen.frame) - 150)];
      window.backgroundColor = NSColor.systemTealColor;
      window.title = @"park-display test";
      [window orderFrontRegardless];
      [ready appendFormat:@"window %ld\n", (long)window.windowNumber];
    }
    fputs(ready.UTF8String, stdout);
    fflush(stdout);
    if (readyFile && ![ready writeToFile:readyFile atomically:YES encoding:NSUTF8StringEncoding error:nil]) {
      fprintf(stderr, "park-display: could not write %s\n", readyFile.UTF8String);
      return 1;
    }

    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:hold];
    BOOL seen = NO;
    while (!stop && [end timeIntervalSinceNow] > 0) {
      [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:1]];
      if (pidFileSaysGone(pidFile, &seen)) break;
    }
    (void)display;
  }
  return 0;
}
