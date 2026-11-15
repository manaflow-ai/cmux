// PROBE COMMIT ONLY (never lands): why a 120 Hz CGVirtualDisplay draws pages at 60 Hz on the measure Macs.
// split-spring.sh runs `VDisplay HZ HOLD main SIZE`; this copy answers "error: probe" at once so split-spring falls
// back and runs `VDisplay probe`, whose one "main ..." line the step log prints in full. The probe dumps the
// CGVirtualDisplay SPI of this macOS, every online display, and for each variant of a virtual display: the mode's
// refresh, NSScreen.maximumFramesPerSecond, the CVDisplayLink interval, and the CADisplayLink interval of a window
// drawn on that display every frame (what the compositor actually gives a view).
#import <AppKit/AppKit.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
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

static NSMutableString *outLine;
static void say(NSString *format, ...) {
  va_list args; va_start(args, format);
  [outLine appendString:[[NSString alloc] initWithFormat:format arguments:args]];
  va_end(args);
}

static int compare(const void *a, const void *b) { double x = *(const double *)a, y = *(const double *)b; return x < y ? -1 : x > y; }
static double median(double *xs, int n) { if (n < 1) return 0; qsort(xs, n, sizeof(double), compare); return xs[n / 2]; }

static uint64_t stamps[2000];
static volatile int ticks = 0;
static CVReturn tick(CVDisplayLinkRef link, const CVTimeStamp *now, const CVTimeStamp *out, CVOptionFlags in, CVOptionFlags *flags, void *context) {
  if (ticks < 2000) stamps[ticks++] = now->hostTime;
  return kCVReturnSuccess;
}
static double cvInterval(CGDirectDisplayID display) {
  CVDisplayLinkRef link;
  if (CVDisplayLinkCreateWithCGDisplay(display, &link) != kCVReturnSuccess) return -1;
  ticks = 0;
  CVDisplayLinkSetOutputCallback(link, tick, NULL);
  CVDisplayLinkStart(link);
  [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];
  CVDisplayLinkStop(link);
  CVTime nominal = CVDisplayLinkGetNominalOutputVideoRefreshPeriod(link);
  CVDisplayLinkRelease(link);
  say(@" cvnominal=%.2f", nominal.timeScale ? 1000.0 * nominal.timeValue / nominal.timeScale : -1);
  int n = ticks - 1;
  mach_timebase_info_data_t base; mach_timebase_info(&base);
  double xs[2000];
  for (int i = 0; i < n; i++) xs[i] = (double)(stamps[i + 1] - stamps[i]) * base.numer / base.denom / 1e6;
  return median(xs, n);
}

// A view that changes its layer's color on every CADisplayLink callback and records the callbacks' timestamps.
@interface Painter : NSView
@property (nonatomic) NSMutableArray<NSNumber *> *times;
@property (nonatomic) NSMutableArray<NSNumber *> *targets;
@property (nonatomic) int frameCount;
@end
@implementation Painter
- (void)step:(CADisplayLink *)link {
  [self.times addObject:@(link.timestamp)];
  [self.targets addObject:@(link.targetTimestamp - link.timestamp)];
  self.frameCount++;
  self.layer.backgroundColor = (self.frameCount & 1) ? NSColor.redColor.CGColor : NSColor.blueColor.CGColor;
}
@end

static NSScreen *screenFor(CGDirectDisplayID display) {
  for (NSScreen *screen in [NSScreen screens])
    if ([screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue] == display) return screen;
  return nil;
}

static void spin(NSTimeInterval seconds) { [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]]; }

static void waitForScreen(CGDirectDisplayID display, BOOL present, NSTimeInterval seconds) {
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
  while ([deadline timeIntervalSinceNow] > 0) {
    spin(0.05);
    if ((screenFor(display) != nil) == present) break;
  }
}

/// The CADisplayLink interval (median, ms) of a window drawn every frame on DISPLAY, and the link's target duration.
static void caInterval(CGDirectDisplayID display, double *interval, double *target, int *count) {
  *interval = -1; *target = -1; *count = 0;
  NSScreen *screen = screenFor(display);
  if (!screen) return;
  if (@available(macOS 14.0, *)) {
    NSRect frame = NSMakeRect(NSMinX(screen.frame) + 100, NSMinY(screen.frame) + 100, 300, 300);
    NSWindow *window = [[NSWindow alloc] initWithContentRect:frame styleMask:NSWindowStyleMaskBorderless
                                                     backing:NSBackingStoreBuffered defer:NO screen:screen];
    window.level = NSStatusWindowLevel;
    window.releasedWhenClosed = NO;
    Painter *view = [[Painter alloc] initWithFrame:NSMakeRect(0, 0, 300, 300)];
    view.wantsLayer = YES;
    view.times = [NSMutableArray array];
    view.targets = [NSMutableArray array];
    window.contentView = view;
    [window setFrame:frame display:YES];
    [window orderFrontRegardless];
    spin(0.3);
    CADisplayLink *link = [view displayLinkWithTarget:view selector:@selector(step:)];
    link.preferredFrameRateRange = (CAFrameRateRange){30, 240, 240};
    [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    spin(1.2);
    [link invalidate];
    [window orderOut:nil];
    NSArray<NSNumber *> *times = view.times;
    int n = (int)times.count - 1;
    double xs[4000], ts[4000];
    for (int i = 0; i < n && i < 4000; i++) xs[i] = ([times[i + 1] doubleValue] - [times[i] doubleValue]) * 1000;
    for (int i = 0; i < (int)view.targets.count && i < 4000; i++) ts[i] = [view.targets[i] doubleValue] * 1000;
    *count = n;
    *interval = median(xs, MIN(n, 4000));
    *target = median(ts, MIN((int)view.targets.count, 4000));
    [window close];
  }
}

static double modeRefresh(CGDirectDisplayID display) {
  CGDisplayModeRef mode = CGDisplayCopyDisplayMode(display);
  if (!mode) return -1;
  double hz = CGDisplayModeGetRefreshRate(mode);
  CGDisplayModeRelease(mode);
  return hz;
}

static NSString *allModes(CGDirectDisplayID display) {
  NSMutableArray *out = [NSMutableArray array];
  NSDictionary *options = @{(__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES};
  CFArrayRef modes = CGDisplayCopyAllDisplayModes(display, (__bridge CFDictionaryRef)options);
  for (CFIndex i = 0; modes && i < CFArrayGetCount(modes) && out.count < 12; i++) {
    CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
    [out addObject:[NSString stringWithFormat:@"%zux%zu@%.0f", CGDisplayModeGetPixelWidth(m), CGDisplayModeGetPixelHeight(m), CGDisplayModeGetRefreshRate(m)]];
  }
  if (modes) CFRelease(modes);
  return [out componentsJoinedByString:@","];
}

static void measureDisplay(NSString *label, CGDirectDisplayID display) {
  NSScreen *screen = screenFor(display);
  double ca, target; int count;
  double cv = cvInterval(display);
  caInterval(display, &ca, &target, &count);
  NSInteger maxFPS = screen ? screen.maximumFramesPerSecond : -1;
  NSTimeInterval minUpdate = screen ? screen.minimumRefreshInterval : -1, maxUpdate = screen ? screen.maximumRefreshInterval : -1;
  say(@" | %@ id=%u mode_hz=%.2f maxfps=%ld refresh_int=%.2f-%.2f cv_ms=%.2f ca_ms=%.2f ca_target_ms=%.2f ca_n=%d main=%d modes=%@",
      label, display, modeRefresh(display), (long)maxFPS, minUpdate * 1000, maxUpdate * 1000, cv, ca, target, count,
      CGMainDisplayID() == display, allModes(display));
}

static NSString *dumpClass(NSString *name) {
  Class cls = NSClassFromString(name);
  if (!cls) return [NSString stringWithFormat:@"%@:missing", name];
  NSMutableArray *names = [NSMutableArray array];
  unsigned int n = 0;
  objc_property_t *props = class_copyPropertyList(cls, &n);
  for (unsigned int i = 0; i < n; i++) [names addObject:[NSString stringWithFormat:@"p.%s", property_getName(props[i])]];
  free(props);
  Method *methods = class_copyMethodList(cls, &n);
  for (unsigned int i = 0; i < n; i++) {
    NSString *sel = NSStringFromSelector(method_getName(methods[i]));
    if (![sel hasPrefix:@"."] && ![sel hasPrefix:@"set"] && ![sel isEqualToString:@"dealloc"]) [names addObject:sel];
  }
  free(methods);
  return [NSString stringWithFormat:@"%@{%@}", name, [names componentsJoinedByString:@" "]];
}

typedef struct { const char *label; unsigned int w, h; double hz; double hz2; unsigned int hiDPI; BOOL main; } Variant;

static void runVariant(Variant v, unsigned int serial) {
  CGVirtualDisplayDescriptor *descriptor = [CGVirtualDisplayDescriptor new];
  descriptor.queue = dispatch_get_main_queue();
  descriptor.name = [NSString stringWithFormat:@"probe %s", v.label];
  unsigned int scale = v.hiDPI ? 2 : 1;
  descriptor.maxPixelsWide = v.w * scale;
  descriptor.maxPixelsHigh = v.h * scale;
  descriptor.sizeInMillimeters = CGSizeMake(600, 600.0 * v.h / v.w);
  descriptor.productID = 0x6d70; descriptor.vendorID = 0x6d6f; descriptor.serialNum = serial;
  CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:descriptor];
  if (!display) { say(@" | %s no-display", v.label); return; }
  CGVirtualDisplaySettings *settings = [CGVirtualDisplaySettings new];
  settings.hiDPI = v.hiDPI;
  NSMutableArray *modes = [NSMutableArray arrayWithObject:[[CGVirtualDisplayMode alloc] initWithWidth:v.w height:v.h refreshRate:v.hz]];
  if (v.hz2 > 0) [modes addObject:[[CGVirtualDisplayMode alloc] initWithWidth:v.w height:v.h refreshRate:v.hz2]];
  settings.modes = modes;
  if (![display applySettings:settings]) { say(@" | %s apply-failed", v.label); return; }
  CGDirectDisplayID did = display.displayID;
  waitForScreen(did, YES, 5);
  if (v.main) {
    CGDisplayConfigRef config;
    if (CGBeginDisplayConfiguration(&config) == kCGErrorSuccess) {
      CGConfigureDisplayOrigin(config, did, 0, 0);
      CGDirectDisplayID ids[32]; uint32_t count = 0;
      CGGetOnlineDisplayList(32, ids, &count);
      int32_t x = (int32_t)CGDisplayBounds(did).size.width;
      for (uint32_t i = 0; i < count; i++) if (ids[i] != did) { CGConfigureDisplayOrigin(config, ids[i], x, 0); x += (int32_t)CGDisplayBounds(ids[i]).size.width; }
      CGCompleteDisplayConfiguration(config, kCGConfigureForAppOnly);
      spin(1.5);
    }
  }
  measureDisplay([NSString stringWithUTF8String:v.label], did);
  // Every other display while this one is up (a host display may change its rate when a virtual display is main).
  if (v.main) {
    CGDirectDisplayID ids[32]; uint32_t count = 0;
    CGGetOnlineDisplayList(32, ids, &count);
    for (uint32_t i = 0; i < count; i++) if (ids[i] != did) say(@" [other did=%u mode_hz=%.2f maxfps=%ld]", ids[i], modeRefresh(ids[i]), (long)(screenFor(ids[i]) ? screenFor(ids[i]).maximumFramesPerSecond : -1));
  }
  display = nil;
  waitForScreen(did, NO, 5);
  spin(0.5);
}

int main(int argc, char **argv) {
  @autoreleasepool {
    setvbuf(stdout, NULL, _IONBF, 0);
    if (!(argc > 1 && strcmp(argv[1], "probe") == 0)) {
      printf("error: probe commit (VDisplay probe measures the variants)\n");
      return 1;
    }
    outLine = [NSMutableString string];
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [NSApp finishLaunching];
    CGDirectDisplayID mainID = CGMainDisplayID();
    double mainCV = cvInterval(mainID);
    NSString *mainNominal = [outLine copy];
    outLine = [NSMutableString stringWithFormat:@"main %u %.2f PROBE%@ macos=%@", mainID, mainCV, mainNominal,
                                                [[NSProcessInfo processInfo] operatingSystemVersionString]];
    say(@" lowpower=%d", [[NSProcessInfo processInfo] isLowPowerModeEnabled]);
    for (NSString *name in @[@"CGVirtualDisplayDescriptor", @"CGVirtualDisplaySettings", @"CGVirtualDisplayMode", @"CGVirtualDisplay"])
      say(@" | %@", dumpClass(name));
    CGDirectDisplayID ids[32]; uint32_t count = 0;
    CGGetOnlineDisplayList(32, ids, &count);
    for (uint32_t i = 0; i < count; i++) measureDisplay([NSString stringWithFormat:@"host%u", i], ids[i]);
    Variant variants[] = {
      {"v120", 1920, 1200, 120, 0, 0, NO},
      {"v120main", 1920, 1200, 120, 0, 0, YES},
      {"v120+60main", 1920, 1200, 120, 60, 0, YES},
      {"v60+120main", 1920, 1200, 60, 120, 0, YES},
      {"v120hidpi", 960, 600, 120, 0, 1, YES},
      {"v240main", 1920, 1200, 240, 0, 0, YES},
      {"v60main", 1920, 1200, 60, 0, 0, YES},
    };
    for (unsigned int i = 0; i < sizeof(variants) / sizeof(variants[0]); i++) runVariant(variants[i], 100 + i);
    printf("%s\n", outLine.UTF8String);
  }
  return 0;
}
