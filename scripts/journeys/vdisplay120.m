// A virtual display at HZ (default 120) for a whole-host video lease (handoff resize-videos/KIT.md), from hq
// build-fleet/mini-ops/vdisplay.m (1x) and pr_capture/hidpi_display.m (2x). The minis' own displays are 60 Hz.
//
//   VD HZ SCALE WIDTH HEIGHT HOLD   make the display (SCALE 1: WIDTHxHEIGHT pixels; 2: WIDTHxHEIGHT points backed by
//                                   twice the pixels, a Retina laptop's density), print
//                                   "ready <id> <median CVDisplayLink interval ms>", keep it HOLD s, then exit
//                                   (the display goes with the process).
//   VD check                        a fresh process's view: "main <id> mode <w>x<h> pixels <pw>x<ph> refresh <hz>
//                                   interval <median ms over 1 s> displays <n>"
// Private API (CGVirtualDisplay), as Chromium's and hq's helpers use it. Started with `open` from the lease, so it
// runs in the console session; the lease's finally kills it by its path.
#import <AppKit/AppKit.h>
#import <CoreVideo/CoreVideo.h>
#include <mach/mach_time.h>

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end
@interface CGVirtualDisplaySettings : NSObject
@property (retain, nonatomic) NSArray *modes;
@property (nonatomic) unsigned int hiDPI;
@end
@interface CGVirtualDisplayDescriptor : NSObject
@property (retain, nonatomic) dispatch_queue_t queue;
@property (retain, nonatomic) NSString *name;
@property (nonatomic) unsigned int maxPixelsWide, maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int productID, vendorID, serialNum;
@property (nonatomic) CGPoint redPrimary, greenPrimary, bluePrimary, whitePoint;
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

static int check(void) {
  CGDirectDisplayID main = CGMainDisplayID();
  CGDisplayModeRef mode = CGDisplayCopyDisplayMode(main);
  uint32_t n = 0;
  CGGetActiveDisplayList(0, NULL, &n);
  printf("main %u mode %zux%zu pixels %zux%zu refresh %.2f interval %.3f displays %u\n", main,
         mode ? CGDisplayModeGetWidth(mode) : 0, mode ? CGDisplayModeGetHeight(mode) : 0,
         mode ? CGDisplayModeGetPixelWidth(mode) : 0, mode ? CGDisplayModeGetPixelHeight(mode) : 0,
         mode ? CGDisplayModeGetRefreshRate(mode) : 0, medianInterval(main), n);
  if (mode) CGDisplayModeRelease(mode);
  return 0;
}

int main(int argc, char **argv) {
  @autoreleasepool {
    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc > 1 && strcmp(argv[1], "check") == 0) return check();
    double hz = argc > 1 ? atof(argv[1]) : 120;
    int scale = argc > 2 ? atoi(argv[2]) : 1;
    // 0 or no size: 1920x1080 at 1x; 1512x982 points at 2x (a 14-inch MacBook Pro's default, 3024x1964 pixels).
    unsigned int width = argc > 3 ? (unsigned int)atoi(argv[3]) : 0;
    unsigned int height = argc > 4 ? (unsigned int)atoi(argv[4]) : 0;
    if (width == 0) width = scale == 2 ? 1512 : 1920;
    if (height == 0) height = scale == 2 ? 982 : 1080;
    double hold = argc > 5 ? atof(argv[5]) : 900;
    if (hz < 1 || hz > 240 || (scale != 1 && scale != 2) || width < 640 || width > 3840 || height < 480 || height > 2400) {
      printf("error: arguments out of range\n");
      return 1;
    }
    [NSApplication sharedApplication];
    CGVirtualDisplayDescriptor *descriptor = [CGVirtualDisplayDescriptor new];
    descriptor.queue = dispatch_get_main_queue();
    descriptor.name = [NSString stringWithFormat:@"resize-videos %.0f Hz %dx", hz, scale];
    descriptor.maxPixelsWide = scale * width;
    descriptor.maxPixelsHigh = scale * height;
    descriptor.sizeInMillimeters = scale == 2 ? CGSizeMake(width * 25.4 / 127, height * 25.4 / 127)
                                              : CGSizeMake(width * 25.4 / 92, height * 25.4 / 92);
    descriptor.redPrimary = CGPointMake(0.6797, 0.3203);
    descriptor.greenPrimary = CGPointMake(0.2559, 0.6983);
    descriptor.bluePrimary = CGPointMake(0.1494, 0.0557);
    descriptor.whitePoint = CGPointMake(0.3125, 0.3291);
    descriptor.productID = 0x7276; descriptor.vendorID = 0x7276; descriptor.serialNum = (unsigned int)(scale * 1000 + hz);
    CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:descriptor];
    if (!display) { printf("error: CGVirtualDisplay unavailable\n"); return 1; }
    CGVirtualDisplaySettings *settings = [CGVirtualDisplaySettings new];
    settings.hiDPI = scale == 2 ? 1 : 0;
    settings.modes = @[[[CGVirtualDisplayMode alloc] initWithWidth:width height:height refreshRate:hz]];
    if (![display applySettings:settings]) { printf("error: applySettings failed\n"); return 1; }
    [NSThread sleepForTimeInterval:1.0];
    printf("ready %u %.3f\n", display.displayID, medianInterval(display.displayID));
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:hold]];
  }
  return 0;
}
