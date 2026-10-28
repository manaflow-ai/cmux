// vdisplay: hold a virtual display at a chosen refresh rate until killed (or HOLD seconds).
// Usage: VDisplay HZ HOLD_SECONDS [main], or VDisplay probe. A copy of cmuxterm-hq's
// build-fleet/mini-ops/vdisplay.m (`fleet vdisplay`); keep the two in step (this copy adds `main` and
// `probe`, 2026-10-23).
// `probe` creates no display: it prints "main DISPLAY_ID p50_ms" for the current main display (its measured
// CVDisplayLink interval, 0 when it does not tick) and exits. scripts/measure/split-spring.sh runs it after a
// VDISPLAY-FALLBACK, so the report still says which refresh the real display measured at.
// `main` makes the virtual display the main display (origin 0,0; every other display moves right of
// it, keeping its place relative to the others) for this process only (kCGConfigureForAppOnly):
// the old arrangement comes back when it exits. Without it, a host with any other display keeps
// that one as main, and apps open there.
// Prints "ready DISPLAY_ID p50_ms main=MAIN_ID" once CVDisplayLink ticks on it, so callers can
// check the rate and the main display before measuring anything. Uses the private
// CGVirtualDisplay API (as BetterDisplay and DeskPad do); the display goes away when this
// process exits.
#import <AppKit/AppKit.h>
#import <CoreVideo/CoreVideo.h>
#include <mach/mach_time.h>

@interface CGVirtualDisplayDescriptor : NSObject
@property (retain, nonatomic) dispatch_queue_t queue;
@property (retain, nonatomic) NSString *name;
@property (nonatomic) unsigned int maxPixelsWide, maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int productID, vendorID, serialNum;
@property (copy, nonatomic) void (^terminationHandler)(id, id);
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

static uint64_t stamps[1000];
static volatile int ticks = 0;
static CVReturn tick(CVDisplayLinkRef link, const CVTimeStamp *now, const CVTimeStamp *out, CVOptionFlags in, CVOptionFlags *flags, void *context) {
  if (ticks < 1000) stamps[ticks++] = now->hostTime;
  return kCVReturnSuccess;
}
/// Moves DISPLAY to the origin (the main display) and every other online display to its right.
static CGError makeMain(CGDirectDisplayID display) {
  CGDirectDisplayID ids[32];
  uint32_t count = 0;
  CGError error = CGGetOnlineDisplayList(32, ids, &count);
  if (error != kCGErrorSuccess) return error;
  CGFloat width = CGDisplayBounds(display).size.width, minX = CGFLOAT_MAX;
  for (uint32_t i = 0; i < count; i++)
    if (ids[i] != display) minX = MIN(minX, CGDisplayBounds(ids[i]).origin.x);
  CGDisplayConfigRef config;
  if ((error = CGBeginDisplayConfiguration(&config)) != kCGErrorSuccess) return error;
  CGConfigureDisplayOrigin(config, display, 0, 0);
  for (uint32_t i = 0; i < count; i++) {
    if (ids[i] == display) continue;
    CGRect bounds = CGDisplayBounds(ids[i]);
    CGConfigureDisplayOrigin(config, ids[i], (int32_t)(bounds.origin.x - minX + width), (int32_t)bounds.origin.y);
  }
  return CGCompleteDisplayConfiguration(config, kCGConfigureForAppOnly);
}

/// Whether AppKit's screen list has DISPLAY yet.
static NSScreen *screenFor(CGDirectDisplayID display) {
  for (NSScreen *screen in [NSScreen screens])
    if ([screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue] == display) return screen;
  return nil;
}

/// Runs the main run loop until AppKit has handled a screen change (NSApplicationDidChangeScreenParametersNotification)
/// and, when WANT is set, until DISPLAY is in [NSScreen screens] and AppKit's main screen. AppKit refreshes its
/// screen list only on the main run loop: an NSThread sleep before the read left the new display out of
/// [NSScreen screens], so "visible=0x0" (2026-10-25: cmux9s, cmuxs-Mac-mini, cmux20-bench). Bounded by SECONDS.
static void waitForScreens(CGDirectDisplayID display, BOOL wantMain, NSTimeInterval seconds) {
  __block BOOL changed = NO;
  id token = [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidChangeScreenParametersNotification
                                                                object:nil queue:nil usingBlock:^(NSNotification *note) { changed = YES; }];
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
  while ([deadline timeIntervalSinceNow] > 0) {
    [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    NSScreen *screen = screenFor(display);
    if (changed && screen && (!wantMain || [NSScreen screens].firstObject == screen)) break;
  }
  [[NSNotificationCenter defaultCenter] removeObserver:token];
  if (!screenFor(display)) fprintf(stderr, "vdisplay: AppKit did not list display %u within %.0f s\n", display, seconds);
}

static int compare(const void *a, const void *b) { double x = *(const double *)a, y = *(const double *)b; return x < y ? -1 : x > y; }

/// Median CVDisplayLink interval on DISPLAY over one second, in ms (0 when it does not tick).
static double medianInterval(CGDirectDisplayID display) {
  CVDisplayLinkRef link;
  if (CVDisplayLinkCreateWithCGDisplay(display, &link) != kCVReturnSuccess) return 0;
  ticks = 0;
  CVDisplayLinkSetOutputCallback(link, tick, NULL);
  CVDisplayLinkStart(link);
  [NSThread sleepForTimeInterval:1.0];
  CVDisplayLinkStop(link);
  CVDisplayLinkRelease(link);
  int count = ticks - 1;
  if (count < 2) return 0;
  mach_timebase_info_data_t base; mach_timebase_info(&base);
  double intervals[1000];
  for (int i = 0; i < count; i++) intervals[i] = (double)(stamps[i + 1] - stamps[i]) * base.numer / base.denom / 1e6;
  qsort(intervals, count, sizeof(double), compare);
  return intervals[count / 2];
}

int main(int argc, char **argv) {
  @autoreleasepool {
    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc > 1 && strcmp(argv[1], "probe") == 0) {
      CGDirectDisplayID mainID = CGMainDisplayID();
      printf("main %u %.2f\n", mainID, medianInterval(mainID));
      return 0;
    }
    double hz = argc > 1 ? atof(argv[1]) : 120;
    double hold = argc > 2 ? atof(argv[2]) : 1800;
    BOOL wantMain = argc > 3 && strcmp(argv[3], "main") == 0;
    // argv[4] WIDTHxHEIGHT (default 1920x1080). The measure scripts ask for 1920x1200: under the Dock and the
    // menu bar a 1080-pixel display leaves about 965 pt, and AppKit clamps a 1600 x 1000 STRESS window to it.
    unsigned int width = 1920, height = 1080;
    if (argc > 4 && (sscanf(argv[4], "%ux%u", &width, &height) != 2 || width < 640 || height < 480 || width > 3840 || height > 2400)) {
      printf("error: size %s is not WIDTHxHEIGHT within 640x480..3840x2400\n", argv[4]);
      return 2;
    }
    [NSApplication sharedApplication];
    CGVirtualDisplayDescriptor *descriptor = [CGVirtualDisplayDescriptor new];
    descriptor.queue = dispatch_get_main_queue();
    descriptor.name = [NSString stringWithFormat:@"mini-ops %.0f Hz", hz];
    descriptor.maxPixelsWide = width;
    descriptor.maxPixelsHigh = height;
    descriptor.sizeInMillimeters = CGSizeMake(600, 600.0 * height / width);  // about 81 dpi, as 1920x1080 at 600 x 340
    descriptor.productID = 0x6d6f; descriptor.vendorID = 0x6d6f; descriptor.serialNum = 1;
    CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:descriptor];
    if (!display) { printf("error: CGVirtualDisplay unavailable\n"); return 1; }
    CGVirtualDisplaySettings *settings = [CGVirtualDisplaySettings new];
    settings.hiDPI = 0;
    settings.modes = @[[[CGVirtualDisplayMode alloc] initWithWidth:width height:height refreshRate:hz]];
    if (![display applySettings:settings]) { printf("error: applySettings failed\n"); return 1; }
    waitForScreens(display.displayID, NO, 5.0);
    if (wantMain && CGMainDisplayID() != display.displayID) {
      CGError error = makeMain(display.displayID);
      if (error != kCGErrorSuccess) fprintf(stderr, "vdisplay: could not make display %u main (CGError %d)\n", display.displayID, error);
      else waitForScreens(display.displayID, YES, 5.0);
    }
    // The visible frame (points, under the menu bar and the Dock) of the virtual display: what a window may fill.
    NSScreen *screen = screenFor(display.displayID);
    NSRect visible = screen ? screen.visibleFrame : NSZeroRect;
    printf("ready %u %.2f main=%u size=%ux%u visible=%.0fx%.0f\n", display.displayID, medianInterval(display.displayID),
           CGMainDisplayID(), width, height, visible.size.width, visible.size.height);
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:hold]];
  }
  return 0;
}
