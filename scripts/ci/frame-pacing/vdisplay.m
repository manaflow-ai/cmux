// vdisplay: hold a virtual display at a chosen refresh rate until killed (or HOLD seconds).
// Usage: VDisplay HZ HOLD_SECONDS. A copy of cmuxterm-hq's build-fleet/mini-ops/vdisplay.m
// (`fleet vdisplay`); keep the two in step.
// Prints "ready DISPLAY_ID p50_ms" once CVDisplayLink ticks on it, so callers can check
// the rate before measuring anything. Uses the private CGVirtualDisplay API (as
// BetterDisplay and DeskPad do); the display goes away when this process exits.
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
    double hz = argc > 1 ? atof(argv[1]) : 120;
    double hold = argc > 2 ? atof(argv[2]) : 1800;
    [NSApplication sharedApplication];
    CGVirtualDisplayDescriptor *descriptor = [CGVirtualDisplayDescriptor new];
    descriptor.queue = dispatch_get_main_queue();
    descriptor.name = [NSString stringWithFormat:@"mini-ops %.0f Hz", hz];
    descriptor.maxPixelsWide = 1920;
    descriptor.maxPixelsHigh = 1080;
    descriptor.sizeInMillimeters = CGSizeMake(600, 340);
    descriptor.productID = 0x6d6f; descriptor.vendorID = 0x6d6f; descriptor.serialNum = 1;
    CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:descriptor];
    if (!display) { printf("error: CGVirtualDisplay unavailable\n"); return 1; }
    CGVirtualDisplaySettings *settings = [CGVirtualDisplaySettings new];
    settings.hiDPI = 0;
    settings.modes = @[[[CGVirtualDisplayMode alloc] initWithWidth:1920 height:1080 refreshRate:hz]];
    if (![display applySettings:settings]) { printf("error: applySettings failed\n"); return 1; }
    [NSThread sleepForTimeInterval:1.0];
    printf("ready %u %.2f main=%u\n", display.displayID, medianInterval(display.displayID), CGMainDisplayID());
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:hold]];
  }
  return 0;
}
