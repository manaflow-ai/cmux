// vdisplay: hold a virtual display at a chosen refresh rate until killed (or HOLD seconds).
// Usage: VDisplay HZ HOLD_SECONDS [main|-] [WIDTHxHEIGHT] [hidpi|hidpi-points], or VDisplay probe. `hidpi` makes a
// backing-scale-2 display of WIDTHxHEIGHT points (twice the pixels): the Liquid Glass Parity matrix's 2x
// cells on a host whose own screen is 1x (scripts/measure/glass-parity.sh). A copy of cmuxterm-hq's
// build-fleet/mini-ops/vdisplay.m (`fleet vdisplay`); keep the two in step (this copy adds `main` and
// `probe`, 2026-10-23).
// `probe` creates no display: it prints "main DISPLAY_ID p50_ms" for the current main display (its measured
// CVDisplayLink interval, 0 when it does not tick) and exits. scripts/measure/split-spring.sh runs it after a
// VDISPLAY-FALLBACK, so the report still says which refresh the real display measured at.
// `main` makes the virtual display the main display (origin 0,0; every other display moves right of
// it, keeping its place relative to the others) for this process only (kCGConfigureForAppOnly):
// the old arrangement comes back when it exits. Without it, a host with any other display keeps
// that one as main, and apps open there.
// Prints "ready DISPLAY_ID p50_ms main=MAIN_ID ... drawn=MS maxfps=N" once CVDisplayLink ticks on it, so callers can
// check the rate and the main display before measuring anything. Uses the private
// CGVirtualDisplay API (as BetterDisplay and DeskPad do); the display goes away when this
// process exits.
// Then, when this Mac's acpmux share host has a hub device, prints "screen URL": the link that opens this
// display live, view-only, in cmux on Leo's Mac or iPhone (`acpmux share-host link --display ID`, Rust). The
// label is $CMUX_SCREEN_NAME, else "vdisplay"; $CMUX_ACPMUX names the acpmux to ask. No line when none answers.
#import <AppKit/AppKit.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>  // CADisplayLink: messages and a struct only, so no QuartzCore link flag
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

/// A view that repaints on every CADisplayLink callback and keeps the callbacks' timestamps.
@interface DrawnProbeView : NSView
@property (nonatomic) NSMutableArray<NSNumber *> *times;
@end
@implementation DrawnProbeView
- (void)step:(CADisplayLink *)link {
  [self.times addObject:@(link.timestamp)];
  self.layer.backgroundColor = (self.times.count & 1) ? NSColor.darkGrayColor.CGColor : NSColor.grayColor.CGColor;
}
@end

/// The median interval (ms) at which a window on SCREEN is drawn, over one second: a CADisplayLink of a view that
/// repaints every frame, asking for up to 240 fps. Unlike the CVDisplayLink interval (the mode's nominal rate, a
/// timer), this is the cadence WindowServer gives views on that display, which WebKit's and Chromium's frames
/// follow: on aws-m4pro-7 the CVDisplayLink of a "120 Hz" virtual display ticked at 8.33 ms while both engines'
/// pages drew at 16.7 ms (step 1f3cd183). 0 when it cannot be measured (before macOS 14 or no callbacks).
static double drawnInterval(NSScreen *screen) {
  if (!screen) return 0;
  if (@available(macOS 14.0, *)) {
    NSRect frame = NSMakeRect(NSMaxX(screen.frame) - 48, NSMinY(screen.frame), 48, 48);
    NSWindow *window = [[NSWindow alloc] initWithContentRect:frame styleMask:NSWindowStyleMaskBorderless
                                                     backing:NSBackingStoreBuffered defer:NO screen:screen];
    window.releasedWhenClosed = NO;
    window.level = NSStatusWindowLevel;
    DrawnProbeView *view = [[DrawnProbeView alloc] initWithFrame:NSMakeRect(0, 0, 48, 48)];
    view.wantsLayer = YES;
    view.times = [NSMutableArray array];
    window.contentView = view;
    [window setFrame:frame display:YES];
    [window orderFrontRegardless];
    CADisplayLink *link = [view displayLinkWithTarget:view selector:@selector(step:)];
    link.preferredFrameRateRange = (CAFrameRateRange){30, 240, 240};
    [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.2]];
    [link invalidate];
    [window orderOut:nil];
    [window close];
    NSArray<NSNumber *> *times = view.times;
    int count = (int)MIN(times.count, (NSUInteger)1001) - 1;
    if (count < 2) return 0;
    double intervals[1000];
    for (int i = 0; i < count; i++) intervals[i] = ([times[i + 1] doubleValue] - [times[i] doubleValue]) * 1000;
    qsort(intervals, count, sizeof(double), compare);
    return intervals[count / 2];
  }
  return 0;
}

// The acpmux to ask for a screen link: $CMUX_ACPMUX, else the one on PATH, else an installed cmux's.
static NSString *acpmuxPath(void) {
  NSFileManager *files = NSFileManager.defaultManager;
  NSString *named = NSProcessInfo.processInfo.environment[@"CMUX_ACPMUX"];
  if (named.length) return [files isExecutableFileAtPath:named] ? named : nil;
  for (NSString *dir in [NSProcessInfo.processInfo.environment[@"PATH"] componentsSeparatedByString:@":"]) {
    NSString *path = [dir stringByAppendingPathComponent:@"acpmux"];
    if (dir.length && [files isExecutableFileAtPath:path]) return path;
  }
  for (NSString *app in @[@"cmux NIGHTLY", @"cmux", @"cmux RC"]) {
    NSString *path = [NSString stringWithFormat:@"/Applications/%@.app/Contents/Resources/bin/acpmux", app];
    if ([files isExecutableFileAtPath:path]) return path;
  }
  return nil;
}

// Prints "screen URL" for the display, or nothing; gives up after 5 s so a slow daemon never holds a run.
static void printScreenLink(CGDirectDisplayID display) {
  NSString *acpmux = acpmuxPath();
  if (!acpmux) return;
  NSString *name = NSProcessInfo.processInfo.environment[@"CMUX_SCREEN_NAME"] ?: @"vdisplay";
  NSTask *task = [NSTask new];
  task.executableURL = [NSURL fileURLWithPath:acpmux];
  task.arguments = @[@"share-host", @"link", @"--display", [NSString stringWithFormat:@"%u", display], @"--name", name];
  NSPipe *pipe = [NSPipe pipe];
  task.standardOutput = pipe;
  task.standardError = [NSFileHandle fileHandleWithNullDevice];
  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  task.terminationHandler = ^(NSTask *t) { dispatch_semaphore_signal(done); };
  if (![task launchAndReturnError:nil]) return;
  if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC))) {
    [task terminate];
    return;
  }
  if (task.terminationStatus != 0) return;
  NSString *out = [[NSString alloc] initWithData:[pipe.fileHandleForReading readDataToEndOfFile] encoding:NSUTF8StringEncoding];
  NSString *web = [[out componentsSeparatedByString:@"\n"] firstObject];
  if ([web hasPrefix:@"https://"]) printf("screen %s\n", web.UTF8String);
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
    // `hidpi-points` lists the 2x mode by its point size only (WIDTHxHEIGHT; the pixel size is twice that), the
    // form DeskPad gives; `hidpi` lists the pixel size and the point size (scripts/measure/vdisplay-hidpi-probe.sh
    // measures which a host takes).
    BOOL hidpi = argc > 5 && strncmp(argv[5], "hidpi", 5) == 0;
    BOOL pointModes = argc > 5 && strcmp(argv[5], "hidpi-points") == 0;
    unsigned int factor = hidpi ? 2 : 1;
    [NSApplication sharedApplication];
    CGVirtualDisplayDescriptor *descriptor = [CGVirtualDisplayDescriptor new];
    descriptor.queue = dispatch_get_main_queue();
    descriptor.name = [NSString stringWithFormat:@"mini-ops %.0f Hz", hz];
    descriptor.maxPixelsWide = width * factor;
    descriptor.maxPixelsHigh = height * factor;
    descriptor.sizeInMillimeters = CGSizeMake(600, 600.0 * height / width);  // about 81 dpi, as 1920x1080 at 600 x 340
    descriptor.productID = 0x6d6f; descriptor.vendorID = 0x6d6f; descriptor.serialNum = 1;
    CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:descriptor];
    if (!display) { printf("error: CGVirtualDisplay unavailable\n"); return 1; }
    CGVirtualDisplaySettings *settings = [CGVirtualDisplaySettings new];
    settings.hiDPI = hidpi ? 1 : 0;
    // HiDPI: the mode list holds the pixel size too, and the display is switched to the mode of WIDTHxHEIGHT points
    // at twice the pixels (macOS starts it at its 1x mode of the largest size).
    settings.modes = pointModes
      ? @[[[CGVirtualDisplayMode alloc] initWithWidth:width height:height refreshRate:hz]]
      : hidpi
      ? @[[[CGVirtualDisplayMode alloc] initWithWidth:width * 2 height:height * 2 refreshRate:hz],
          [[CGVirtualDisplayMode alloc] initWithWidth:width height:height refreshRate:hz]]
      : @[[[CGVirtualDisplayMode alloc] initWithWidth:width height:height refreshRate:hz]];
    if (![display applySettings:settings]) { printf("error: applySettings failed\n"); return 1; }
    // A HiDPI display (twice the pixels) comes online slower: fleet step 368e35ec listed it after more than 5 s.
    waitForScreens(display.displayID, NO, hidpi ? 20.0 : 5.0);
    if (hidpi) {
      // The display's mode list fills in after AppKit lists it, a beat later on a busy host (fleet step b44f5987: no
      // 2x mode on the first read, and the display stayed 1x): read it for up to 15 s, and say what it offered if no
      // mode is WIDTHxHEIGHT points at twice the pixels.
      NSDictionary *options = @{(__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES};
      CGDisplayModeRef picked = NULL;
      NSMutableString *offered = [NSMutableString string];
      for (int attempt = 0; attempt < 150 && !picked; attempt++) {
        if (attempt) [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        CFArrayRef modes = CGDisplayCopyAllDisplayModes(display.displayID, (__bridge CFDictionaryRef)options);
        [offered setString:@""];
        for (CFIndex i = 0; modes && i < CFArrayGetCount(modes); i++) {
          CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
          [offered appendFormat:@" %zux%zu@%zux%zu", CGDisplayModeGetWidth(mode), CGDisplayModeGetHeight(mode),
                                CGDisplayModeGetPixelWidth(mode), CGDisplayModeGetPixelHeight(mode)];
          if (!picked && CGDisplayModeGetWidth(mode) == width && CGDisplayModeGetHeight(mode) == height
              && CGDisplayModeGetPixelWidth(mode) == width * 2) picked = CGDisplayModeRetain(mode);
        }
        if (modes) CFRelease(modes);
      }
      CGDisplayConfigRef config;
      if (!picked) fprintf(stderr, "vdisplay: no %ux%u mode at 2x pixels; modes (points@pixels):%s\n", width, height, offered.UTF8String);
      else if (CGBeginDisplayConfiguration(&config) == kCGErrorSuccess) {
        CGConfigureDisplayWithDisplayMode(config, display.displayID, picked, NULL);
        CGError error = CGCompleteDisplayConfiguration(config, kCGConfigureForAppOnly);
        if (error != kCGErrorSuccess) fprintf(stderr, "vdisplay: could not switch to the 2x mode (CGError %d)\n", error);
      }
      if (picked) CGDisplayModeRelease(picked);
      waitForScreens(display.displayID, NO, 5.0);
    }
    if (wantMain && CGMainDisplayID() != display.displayID) {
      CGError error = makeMain(display.displayID);
      if (error != kCGErrorSuccess) fprintf(stderr, "vdisplay: could not make display %u main (CGError %d)\n", display.displayID, error);
      else waitForScreens(display.displayID, YES, 5.0);
    }
    // The visible frame (points, under the menu bar and the Dock) of the virtual display: what a window may fill.
    NSScreen *screen = screenFor(display.displayID);
    NSRect visible = screen ? screen.visibleFrame : NSZeroRect;
    // drawn= is the cadence a view on the display really gets and maxfps= what AppKit says the display does (the
    // pages' own frame pacing reads maximumFramesPerSecond); both after the fields split-spring.sh parses.
    double ticked = medianInterval(display.displayID);
    printf("ready %u %.2f main=%u size=%ux%u visible=%.0fx%.0f scale=%.0f drawn=%.2f maxfps=%ld\n", display.displayID, ticked,
           CGMainDisplayID(), width, height, visible.size.width, visible.size.height,
           screen ? screen.backingScaleFactor : 0, drawnInterval(screen),
           (long)(screen ? screen.maximumFramesPerSecond : 0));
    printScreenLink(display.displayID);
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:hold]];
  }
  return 0;
}
