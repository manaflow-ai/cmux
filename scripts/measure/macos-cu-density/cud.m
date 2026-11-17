// cud: dense computer-use desktops in one macOS GUI session (scripts/measure/macos-cu-density.sh).
//
// One binary, three uses:
//   - the agent app: CudAgent.app runs it as `cud agent ID X Y W H BALLAST_MB`, a window with one
//     button whose click changes the window title ("cud-agent ID: N"), one text field, a 10 Hz timer
//     (its tick count is the App Nap probe) and BALLAST_MB of touched heap (half random, half text, so
//     the compressor sees data like an app's, about 2x compressible);
//   - the measurement: `cud bench OUT NS BALLAST_MB LOOP_S` runs every stage below for each agent
//     count in NS (a comma list, 1,4,8,16,32), in this session, and writes OUT/results.jsonl;
//   - a driver API one slot at a time, for a prototype: JSON in argv, one JSON line out.
//       cud slot lease ID [X Y W H]   start agent ID (open -n, no activation): {"slot","pid","wid"}
//       cud act PID [ROUTE]           click its button, wait for the title: {"ok","ms","route"}
//                                     ROUTE ax-press (default), ax-setvalue, cg-pid, stamped-cg
//       cud shot PID OUT.png          ScreenCaptureKit capture of its window: {"ok","ms","w","h"}
//       cud suspend PID [bg]          SIGSTOP (bg: taskpolicy -b instead): {"ok","ms"}
//       cud resume PID [bg]           SIGCONT (bg: taskpolicy -B): {"ok","ms"}
//       cud mem PID                   {"footprint","resident"} bytes (proc_pid_rusage)
//       cud slot release PID          terminate it
//   - N concurrent GUI test jobs with cross-job checks: `cud jobs OUT NS SECONDS BALLAST_MB MODES`
//     (one virtual display per job, or one window per job on one big display; see jobs_round);
//   - helpers: `cud vdisplay MAX W H` (virtual displays until one fails), `cud hog MB` (memory
//     pressure), `cud grants`.
//
// Stages of `bench`, per N (a stage that cannot run says why; nothing is left out of the JSON):
//   vdisplay  CGVirtualDisplay (private CoreGraphics API) 1280x800 displays until one fails, cap 64
//   launch    N agents on one big virtual display (5120x2880, tiled 640x400), else the main display
//   capture   SCScreenshotManager per-window capture: sequential latency, then all N at once
//   input     against a frontmost witness app: AXPress, AX set value, CGEventPostToPid (plain and
//             with Cua Driver's field stamps), delivered = the agent's title changed; focus steals
//   appnap    the agent's timer rate visible-in-background, hidden, under taskpolicy -b
//   evict     (N=1) a stopped agent with 1 GB ballast under memory pressure from `cud hog`:
//             resident and footprint before/after, compressor pages, then resume to acted click
//   loop      N agents at ~10% awake: SIGCONT, act, act, SIGSTOP, think exp(9x awake); resume to
//             acted click p50/p99, failures, host cores busy, summed footprint
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <dlfcn.h>
#import <libproc.h>
#import <mach/mach.h>
#import <mach/mach_time.h>
#import <pthread.h>
#import <signal.h>
#import <sys/sysctl.h>

// ---------------------------------------------------------------- private CoreGraphics
@interface CGVirtualDisplayDescriptor : NSObject
@property(retain, nonatomic) dispatch_queue_t queue;
@property(retain, nonatomic) NSString *name;
@property(nonatomic) unsigned int maxPixelsHigh;
@property(nonatomic) unsigned int maxPixelsWide;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) unsigned int productID;
@property(nonatomic) unsigned int vendorID;
@property(nonatomic) unsigned int serialNum;
@end
@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)rate;
@end
@interface CGVirtualDisplaySettings : NSObject
@property(retain, nonatomic) NSArray *modes;
@property(nonatomic) unsigned int hiDPI;
@end
@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property(readonly, nonatomic) unsigned int displayID;
@end

typedef void (*SetWindowLocationFn)(CGEventRef, CGPoint);
typedef void (*SetIntegerFieldFn)(CGEventRef, uint32_t, int64_t);

// ---------------------------------------------------------------- small helpers
static double now_s(void) {
  static mach_timebase_info_data_t tb;
  if (tb.denom == 0) mach_timebase_info(&tb);
  return (double)mach_absolute_time() * tb.numer / tb.denom / 1e9;
}
static void sleep_s(double s) { if (s > 0) usleep((useconds_t)(s * 1e6)); }
static void spin(double s) { [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:s]]; }

static FILE *results_file;
static NSString *json(id obj) {
  NSData *d = nil;
  @try {
    d = [NSJSONSerialization dataWithJSONObject:obj options:NSJSONWritingSortedKeys error:nil];
  } @catch (NSException *e) {  // a NaN or infinity: say so instead of losing the row
    d = [NSJSONSerialization dataWithJSONObject:@{@"unencodable": [obj description] ?: @"?"} options:0 error:nil];
  }
  return d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : @"{}";
}
static void emit(NSDictionary *obj) {
  NSString *line = json(obj);
  printf("%s\n", line.UTF8String);
  fflush(stdout);
  if (results_file) { fprintf(results_file, "%s\n", line.UTF8String); fflush(results_file); }
}
static id nn(id v) { return v ? v : [NSNull null]; }

static NSDictionary *pct(NSArray<NSNumber *> *xs) {
  if (xs.count == 0) return @{@"n": @0, @"p50": [NSNull null], @"p99": [NSNull null], @"max": [NSNull null]};
  NSArray *s = [xs sortedArrayUsingSelector:@selector(compare:)];
  double (^at)(double) = ^double(double q) {
    NSUInteger i = (NSUInteger)llround(q * (double)(s.count - 1));
    return [s[i] doubleValue];
  };
  double sum = 0;
  for (NSNumber *x in s) sum += x.doubleValue;
  return @{@"n": @(s.count), @"p50": @(round(at(0.50) * 1000) / 1000), @"p90": @(round(at(0.90) * 1000) / 1000),
           @"p99": @(round(at(0.99) * 1000) / 1000), @"max": @(round([s.lastObject doubleValue] * 1000) / 1000),
           @"mean": @(round(sum / s.count * 1000) / 1000)};
}

static NSDictionary *mem_of(pid_t pid) {
  struct rusage_info_v4 ri;
  if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&ri) != 0) return @{@"footprint": [NSNull null], @"resident": [NSNull null]};
  return @{@"footprint": @(ri.ri_phys_footprint), @"resident": @(ri.ri_resident_size)};
}
static double cpu_s_of(pid_t pid) {
  struct rusage_info_v4 ri;
  if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&ri) != 0) return 0;
  static mach_timebase_info_data_t tb;
  if (tb.denom == 0) mach_timebase_info(&tb);
  return (double)(ri.ri_user_time + ri.ri_system_time) * tb.numer / tb.denom / 1e9;
}

static NSDictionary *vmstat(void) {
  vm_statistics64_data_t v;
  mach_msg_type_number_t c = HOST_VM_INFO64_COUNT;
  if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&v, &c) != KERN_SUCCESS) return @{};
  uint64_t pg = vm_kernel_page_size;
  struct xsw_usage sw = {0};
  size_t sl = sizeof(sw);
  sysctlbyname("vm.swapusage", &sw, &sl, NULL, 0);
  return @{@"compressor_bytes": @((uint64_t)v.compressor_page_count * pg),
           @"stored_in_compressor_bytes": @((uint64_t)v.total_uncompressed_pages_in_compressor * pg),
           @"free_bytes": @((uint64_t)v.free_count * pg), @"swapouts": @(v.swapouts), @"swapins": @(v.swapins),
           @"compressions": @(v.compressions), @"decompressions": @(v.decompressions),
           @"swap_used_bytes": @(sw.xsu_used)};
}

static void cpu_ticks(uint64_t *busy, uint64_t *total) {
  host_cpu_load_info_data_t l;
  mach_msg_type_number_t c = HOST_CPU_LOAD_INFO_COUNT;
  *busy = *total = 0;
  if (host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, (host_info_t)&l, &c) != KERN_SUCCESS) return;
  *busy = l.cpu_ticks[CPU_STATE_USER] + l.cpu_ticks[CPU_STATE_SYSTEM] + l.cpu_ticks[CPU_STATE_NICE];
  *total = *busy + l.cpu_ticks[CPU_STATE_IDLE];
}
static int ncpu(void) { int n = 0; size_t l = sizeof(n); sysctlbyname("hw.ncpu", &n, &l, NULL, 0); return n; }

static int run_cmd(NSString *path, NSArray *args) {
  NSTask *t = [NSTask new];
  t.launchPath = path;
  t.arguments = args;
  t.standardOutput = [NSFileHandle fileHandleWithNullDevice];
  t.standardError = [NSFileHandle fileHandleWithNullDevice];
  @try { [t launch]; } @catch (NSException *e) { return -1; }
  [t waitUntilExit];
  return t.terminationStatus;
}

// ---------------------------------------------------------------- the agent app
@interface CudAgent : NSObject <NSApplicationDelegate>
@property(strong) NSWindow *window;
@property(strong) NSButton *button;
@property(strong) NSTextField *field;
@property int agentId;
@property long clicks;
@property NSRect frameTopLeft;
@property int hue;                    // job colour index (jobs stage), -1 for none
@property(strong) NSTextField *keys;  // every key event the app received, in order (jobs stage)
@property(strong) NSMutableString *keyLog;
@end

static volatile long agent_ticks;

// Job colours: 16 hues 22.5 degrees apart at saturation and brightness 0.85 (sRGB). Neighbours
// differ by at least ~70 in one channel, so a pixel is attributed to one job or to none.
#define JOB_HUES 16
static void job_rgb(int i, double rgb[3]) {
  double h = (double)(i % JOB_HUES) / JOB_HUES * 6.0, s = 0.85, v = 0.85;
  int k = (int)h;
  double f = h - k, p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f));
  double r[6][3] = {{v, t, p}, {q, v, p}, {p, v, t}, {p, q, v}, {t, p, v}, {v, p, q}};
  for (int c = 0; c < 3; c++) rgb[c] = r[k % 6][c];
}
static char *ballast;
static size_t ballast_bytes;

@implementation CudAgent
- (void)applicationDidFinishLaunching:(NSNotification *)n {
  NSRect f = self.frameTopLeft;
  CGFloat primaryH = NSScreen.screens.count ? NSScreen.screens[0].frame.size.height : 1080;
  NSRect cocoa = NSMakeRect(f.origin.x, primaryH - f.origin.y - f.size.height, f.size.width, f.size.height);
  self.window = [[NSWindow alloc] initWithContentRect:cocoa
                                            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                              backing:NSBackingStoreBuffered
                                                defer:NO];
  self.window.releasedWhenClosed = NO;
  self.window.title = [NSString stringWithFormat:@"cud-agent %d: 0", self.agentId];
  NSView *v = self.window.contentView;
  self.button = [NSButton buttonWithTitle:@"Act" target:self action:@selector(act:)];
  self.button.frame = NSMakeRect(20, 20, 200, 48);
  self.button.accessibilityIdentifier = @"cud-act";
  [v addSubview:self.button];
  self.field = [NSTextField textFieldWithString:@""];
  self.field.frame = NSMakeRect(20, 90, 400, 28);
  self.field.accessibilityIdentifier = @"cud-field";
  [v addSubview:self.field];
  NSTextField *label = [NSTextField labelWithString:[NSString stringWithFormat:@"agent %d, %zu MB ballast", self.agentId, ballast_bytes >> 20]];
  label.frame = NSMakeRect(20, 140, 400, 24);
  [v addSubview:label];
  // Jobs stage: a job colour fills the window, so a capture shows whose pixels it holds, and every
  // key event that reaches the app (a local monitor: dispatched to this app, key window or not) is
  // appended to a label whose AX value the driver reads.
  if (self.hue >= 0) {
    double rgb[3];
    job_rgb(self.hue, rgb);
    v.wantsLayer = YES;
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGFloat comps[4] = {rgb[0], rgb[1], rgb[2], 1};
    CGColorRef c = CGColorCreate(srgb, comps);
    v.layer.backgroundColor = c;
    CGColorRelease(c);
    CGColorSpaceRelease(srgb);
  }
  self.keyLog = [NSMutableString string];
  self.keys = [NSTextField labelWithString:@""];
  self.keys.frame = NSMakeRect(20, 180, 580, 24);
  self.keys.accessibilityIdentifier = @"cud-keys";
  [v addSubview:self.keys];
  __weak CudAgent *weakSelf = self;
  [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *e) {
    CudAgent *me = weakSelf;
    if (me && e.characters.length) {
      [me.keyLog appendString:e.characters];
      me.keys.stringValue = me.keyLog;
    }
    return nil;  // consumed: the log is the only place a key lands
  }];
  // setFrame: after creation, so a window on a virtual display is not constrained back to the main one.
  [self.window setFrame:[self.window frameRectForContentRect:cocoa] display:YES];
  [self.window orderFront:nil];
  NSTimer *t = [NSTimer timerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *_) { agent_ticks++; }];
  t.tolerance = 0;
  [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
}
- (void)act:(id)sender {
  self.clicks++;
  self.window.title = [NSString stringWithFormat:@"cud-agent %d: %ld", self.agentId, self.clicks];
  self.button.title = [NSString stringWithFormat:@"clicked %ld", self.clicks];
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)a { return YES; }
@end

static void fill_ballast(size_t mb) {
  ballast_bytes = mb << 20;
  if (!ballast_bytes) return;
  ballast = malloc(ballast_bytes);
  uint64_t x = 0x9E3779B97F4A7C15ull ^ (uint64_t)getpid();
  static const char text[] = "the quick brown fox computes a click on a background window; ";
  for (size_t p = 0; p < ballast_bytes; p += 4096) {
    uint64_t *w = (uint64_t *)(ballast + p);
    for (int i = 0; i < 256; i++) { x ^= x << 13; x ^= x >> 7; x ^= x << 17; w[i] = x; }  // 2 KB random
    for (int i = 2048; i < 4096; i++) ballast[p + i] = text[i % (sizeof(text) - 1)];      // 2 KB text
  }
}

static int agent_main(int argc, const char **argv) {
  // cud agent ID X Y W H BALLAST_MB
  int aid = argc > 2 ? atoi(argv[2]) : 0;
  NSRect fr = NSMakeRect(argc > 3 ? atof(argv[3]) : 100, argc > 4 ? atof(argv[4]) : 100, argc > 5 ? atof(argv[5]) : 640,
                         argc > 6 ? atof(argv[6]) : 400);
  fill_ballast(argc > 7 ? (size_t)atol(argv[7]) : 0);
  int hue = argc > 8 ? atoi(argv[8]) : -1;
  NSString *dir = @"/tmp/cud";
  [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
  // SIGUSR1: write the tick count; SIGUSR2: touch every ballast page and write how long it took.
  // Both on a global queue, so a napped main thread does not delay the answer.
  signal(SIGUSR1, SIG_IGN);
  signal(SIGUSR2, SIG_IGN);
  dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
  dispatch_source_t s1 = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGUSR1, 0, q);
  dispatch_source_set_event_handler(s1, ^{
    NSString *p = [NSString stringWithFormat:@"%@/ticks-%d", dir, aid];
    [[NSString stringWithFormat:@"%ld %.6f\n", agent_ticks, now_s()] writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
  });
  dispatch_resume(s1);
  dispatch_source_t s2 = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGUSR2, 0, q);
  dispatch_source_set_event_handler(s2, ^{
    double t = now_s();
    volatile uint64_t sum = 0;
    for (size_t p = 0; p < ballast_bytes; p += 4096) sum += (uint8_t)ballast[p];
    NSString *path = [NSString stringWithFormat:@"%@/touch-%d", dir, aid];
    [[NSString stringWithFormat:@"%.6f %llu\n", now_s() - t, (unsigned long long)sum] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
  });
  dispatch_resume(s2);
  [NSApplication sharedApplication];
  [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
  CudAgent *d = [CudAgent new];
  d.agentId = aid;
  d.frameTopLeft = fr;
  d.hue = hue;
  NSApp.delegate = d;
  [NSApp run];
  return 0;
}

// ---------------------------------------------------------------- virtual displays
static NSMutableArray *held_displays;

static CGVirtualDisplay *make_display(int i, unsigned w, unsigned h, NSString **err) {
  Class D = NSClassFromString(@"CGVirtualDisplayDescriptor");
  if (!D) { *err = @"CGVirtualDisplayDescriptor class missing"; return nil; }
  CGVirtualDisplayDescriptor *d = [D new];
  d.queue = dispatch_get_main_queue();
  d.name = [NSString stringWithFormat:@"cud-%d", i];
  d.maxPixelsWide = w;
  d.maxPixelsHigh = h;
  d.sizeInMillimeters = CGSizeMake(w * 0.25, h * 0.25);
  d.productID = 0xC0D0 + i;
  d.vendorID = 0xC0D;
  d.serialNum = 1000 + i;
  CGVirtualDisplay *v = [[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:d];
  if (!v) { *err = @"initWithDescriptor returned nil"; return nil; }
  CGVirtualDisplaySettings *s = [NSClassFromString(@"CGVirtualDisplaySettings") new];
  s.hiDPI = 0;
  s.modes = @[ [[NSClassFromString(@"CGVirtualDisplayMode") alloc] initWithWidth:w height:h refreshRate:30] ];
  if (![v applySettings:s]) { *err = @"applySettings returned NO"; return nil; }
  if (v.displayID == 0) { *err = @"displayID 0"; return nil; }
  return v;
}
static uint32_t online_displays(void) {
  uint32_t n = 0;
  CGGetOnlineDisplayList(0, NULL, &n);
  return n;
}

static NSDictionary *vdisplay_cap(int max, unsigned w, unsigned h) {
  uint32_t before = online_displays();
  NSMutableArray *made = [NSMutableArray array];
  NSMutableArray *times = [NSMutableArray array];
  NSString *why = nil;
  for (int i = 0; i < max; i++) {
    double t = now_s();
    NSString *err = nil;
    CGVirtualDisplay *v = make_display(i, w, h, &err);
    if (!v) { why = [NSString stringWithFormat:@"display %d: %@", i, err]; break; }
    [made addObject:v];
    [times addObject:@(now_s() - t)];
    spin(0.05);
  }
  spin(1.0);
  uint32_t during = online_displays();
  NSUInteger count = made.count;
  [made removeAllObjects];
  spin(2.0);
  uint32_t after = online_displays();
  return @{@"created": @(count), @"limit_tried": @(max), @"size": [NSString stringWithFormat:@"%ux%u", w, h],
           @"stopped_because": nn(why), @"online_before": @(before), @"online_during": @(during),
           @"online_after_release": @(after), @"create_s": pct(times)};
}

// ---------------------------------------------------------------- agents as seen by the driver
@interface Agent : NSObject
@property int aid;
@property pid_t pid;
@property(strong) NSRunningApplication *app;
@property AXUIElementRef ax;
@property AXUIElementRef window;
@property AXUIElementRef button;
@property AXUIElementRef field;
@property CGWindowID wid;
@property CGRect frame;  // top-left global points
@end
@implementation Agent
@end

static NSString *ax_string(AXUIElementRef e, CFStringRef attr) {
  CFTypeRef v = NULL;
  if (!e || AXUIElementCopyAttributeValue(e, attr, &v) != kAXErrorSuccess || !v) return nil;
  NSString *s = CFGetTypeID(v) == CFStringGetTypeID() ? [(__bridge NSString *)v copy] : nil;
  CFRelease(v);
  return s;
}
static AXUIElementRef ax_find(AXUIElementRef root, NSString *role, NSString *ident, int depth) {
  if (!root || depth > 6) return NULL;
  CFTypeRef kids = NULL;
  if (AXUIElementCopyAttributeValue(root, kAXChildrenAttribute, &kids) != kAXErrorSuccess || !kids) return NULL;
  AXUIElementRef found = NULL;
  for (CFIndex i = 0; !found && i < CFArrayGetCount(kids); i++) {
    AXUIElementRef k = (AXUIElementRef)CFArrayGetValueAtIndex(kids, i);
    NSString *r = ax_string(k, kAXRoleAttribute);
    NSString *idv = ax_string(k, CFSTR("AXIdentifier"));
    if ([r isEqualToString:role] && (!ident || [idv isEqualToString:ident])) { found = (AXUIElementRef)CFRetain(k); break; }
    found = ax_find(k, role, ident, depth + 1);
  }
  CFRelease(kids);
  return found;
}
static CGRect ax_frame(AXUIElementRef e) {
  CFTypeRef p = NULL, s = NULL;
  CGPoint pt = CGPointZero;
  CGSize sz = CGSizeZero;
  if (AXUIElementCopyAttributeValue(e, kAXPositionAttribute, &p) == kAXErrorSuccess && p) { AXValueGetValue(p, kAXValueCGPointType, &pt); CFRelease(p); }
  if (AXUIElementCopyAttributeValue(e, kAXSizeAttribute, &s) == kAXErrorSuccess && s) { AXValueGetValue(s, kAXValueCGSizeType, &sz); CFRelease(s); }
  return CGRectMake(pt.x, pt.y, sz.width, sz.height);
}
static CGWindowID window_of_pid(pid_t pid) {
  CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionAll | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
  CGWindowID best = 0;
  double area = 0;
  for (NSDictionary *w in (__bridge NSArray *)list) {
    if ([w[(id)kCGWindowOwnerPID] intValue] != pid || [w[(id)kCGWindowLayer] intValue] != 0) continue;
    CGRect r;
    CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)w[(id)kCGWindowBounds], &r);
    if (r.size.width * r.size.height > area) { area = r.size.width * r.size.height; best = [w[(id)kCGWindowNumber] unsignedIntValue]; }
  }
  if (list) CFRelease(list);
  return best;
}
static BOOL agent_resolve(Agent *a, double timeout) {
  double end = now_s() + timeout;
  if (!a.ax) {
    a.ax = AXUIElementCreateApplication(a.pid);
    AXUIElementSetMessagingTimeout(a.ax, 2.0);
  }
  while (now_s() < end) {
    CFTypeRef wins = NULL;
    if (AXUIElementCopyAttributeValue(a.ax, kAXWindowsAttribute, &wins) == kAXErrorSuccess && wins && CFArrayGetCount(wins) > 0) {
      a.window = (AXUIElementRef)CFRetain(CFArrayGetValueAtIndex(wins, 0));
      CFRelease(wins);
      a.button = ax_find(a.window, @"AXButton", @"cud-act", 0);
      a.field = ax_find(a.window, @"AXTextField", @"cud-field", 0);
      a.frame = ax_frame(a.window);
      a.wid = window_of_pid(a.pid);
      if (a.button) return YES;
    } else if (wins) CFRelease(wins);
    sleep_s(0.02);
  }
  return NO;
}

static NSString *app_path;  // CudAgent.app

static Agent *launch_agent_hue(int aid, CGRect f, size_t ballast_mb, BOOL activate, int hue, NSString **err) {
  NSWorkspaceOpenConfiguration *c = [NSWorkspaceOpenConfiguration configuration];
  c.createsNewApplicationInstance = YES;
  c.activates = activate;
  c.addsToRecentItems = NO;
  c.arguments = @[ @"agent", @(aid).stringValue, @(f.origin.x).stringValue, @(f.origin.y).stringValue, @(f.size.width).stringValue,
                   @(f.size.height).stringValue, @(ballast_mb).stringValue, @(hue).stringValue ];
  __block NSRunningApplication *ra = nil;
  __block NSError *e = nil;
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  [[NSWorkspace sharedWorkspace] openApplicationAtURL:[NSURL fileURLWithPath:app_path] configuration:c
                                    completionHandler:^(NSRunningApplication *app, NSError *error) {
                                      ra = app;
                                      e = error;
                                      dispatch_semaphore_signal(sem);
                                    }];
  while (dispatch_semaphore_wait(sem, DISPATCH_TIME_NOW)) spin(0.01);
  if (!ra) { *err = e ? e.localizedDescription : @"no app"; return nil; }
  Agent *a = [Agent new];
  a.aid = aid;
  a.app = ra;
  a.pid = ra.processIdentifier;
  return a;
}
static Agent *launch_agent(int aid, CGRect f, size_t ballast_mb, BOOL activate, NSString **err) {
  return launch_agent_hue(aid, f, ballast_mb, activate, -1, err);
}

static pid_t focused_pid(void) {
  AXUIElementRef sys = AXUIElementCreateSystemWide();
  CFTypeRef app = NULL;
  pid_t pid = 0;
  if (AXUIElementCopyAttributeValue(sys, kAXFocusedApplicationAttribute, &app) == kAXErrorSuccess && app) {
    AXUIElementGetPid((AXUIElementRef)app, &pid);
    CFRelease(app);
  }
  CFRelease(sys);
  return pid;
}

// ---------------------------------------------------------------- acting
static SetWindowLocationFn set_window_location;
static SetIntegerFieldFn set_integer_field;

static void post_click(Agent *a, BOOL stamped) {
  CGRect b = ax_frame(a.button);
  CGPoint p = CGPointMake(CGRectGetMidX(b), CGRectGetMidY(b));
  CGPoint local = CGPointMake(p.x - a.frame.origin.x, p.y - a.frame.origin.y);
  int64_t group = arc4random_uniform(INT32_MAX) + 1;
  CGEventType types[3] = {kCGEventMouseMoved, kCGEventLeftMouseDown, kCGEventLeftMouseUp};
  for (int i = stamped ? 0 : 1; i < 3; i++) {
    CGEventRef e = CGEventCreateMouseEvent(NULL, types[i], p, kCGMouseButtonLeft);
    if (!e) continue;
    if (stamped && set_integer_field) {
      if (set_window_location) set_window_location(e, local);
      int64_t click = types[i] == kCGEventMouseMoved ? 0 : 1, sub = types[i] == kCGEventMouseMoved ? 0 : 3;
      uint32_t f[8] = {1, 3, 7, 51, 58, 91, 92, 40};
      int64_t v[8] = {click, 0, sub, a.wid, group, a.wid, a.wid, a.pid};
      for (int k = 0; k < 8; k++) set_integer_field(e, f[k], v[k]);
    }
    CGEventPostToPid(a.pid, e);
    CFRelease(e);
    usleep(15000);
  }
}

// One act through ROUTE: returns seconds until the agent's window title changed (or <0 when it did not).
static double act(Agent *a, NSString *route, double timeout) {
  NSString *before = ax_string(a.window, kAXTitleAttribute);
  double t = now_s();
  if ([route isEqualToString:@"ax-setvalue"]) {
    NSString *val = [NSString stringWithFormat:@"v%u", arc4random()];
    if (AXUIElementSetAttributeValue(a.field, kAXValueAttribute, (__bridge CFTypeRef)val) != kAXErrorSuccess) return -1;
    while (now_s() - t < timeout) {
      if ([ax_string(a.field, kAXValueAttribute) isEqualToString:val]) return now_s() - t;
      usleep(1000);
    }
    return -1;
  }
  if ([route isEqualToString:@"ax-press"]) {
    if (AXUIElementPerformAction(a.button, kAXPressAction) != kAXErrorSuccess) return -1;
  } else if ([route isEqualToString:@"cg-pid"]) {
    post_click(a, NO);
  } else if ([route isEqualToString:@"stamped-cg"]) {
    post_click(a, YES);
  } else return -1;
  while (now_s() - t < timeout) {
    NSString *after = ax_string(a.window, kAXTitleAttribute);
    if (after && before && ![after isEqualToString:before]) return now_s() - t;
    usleep(1000);
  }
  return -1;
}

// ---------------------------------------------------------------- capture
static SCShareableContent *shareable(double *secs, NSString **err) {
  __block SCShareableContent *sc = nil;
  __block NSError *e = nil;
  double t = now_s();
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  [SCShareableContent getShareableContentExcludingDesktopWindows:YES onScreenWindowsOnly:NO
                                               completionHandler:^(SCShareableContent *c, NSError *error) {
                                                 sc = c;
                                                 e = error;
                                                 dispatch_semaphore_signal(sem);
                                               }];
  if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC))) { *err = @"timeout"; return nil; }
  if (secs) *secs = now_s() - t;
  if (!sc && err) *err = e ? e.localizedDescription : @"no content";
  return sc;
}
static SCWindow *sc_window(SCShareableContent *sc, pid_t pid) {
  SCWindow *best = nil;
  for (SCWindow *w in sc.windows)
    if (w.owningApplication.processID == pid && w.windowLayer == 0 && (!best || w.frame.size.width > best.frame.size.width)) best = w;
  return best;
}
// Starts one capture; done(ok, secs, image) on a global queue.
static void capture_async(SCWindow *w, void (^done)(BOOL, double, CGImageRef)) {
  SCContentFilter *f = [[SCContentFilter alloc] initWithDesktopIndependentWindow:w];
  SCStreamConfiguration *c = [SCStreamConfiguration new];
  c.width = (size_t)MAX(64, w.frame.size.width * f.pointPixelScale);
  c.height = (size_t)MAX(64, w.frame.size.height * f.pointPixelScale);
  c.showsCursor = NO;
  double t = now_s();
  [SCScreenshotManager captureImageWithFilter:f configuration:c completionHandler:^(CGImageRef im, NSError *e) {
    done(im != NULL, now_s() - t, im);
  }];
}
static double capture_sync(SCWindow *w, CGImageRef *out) {
  __block double secs = -1;
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  capture_async(w, ^(BOOL ok, double s, CGImageRef im) {
    if (ok) secs = s;
    if (ok && out) *out = CGImageRetain(im);
    dispatch_semaphore_signal(sem);
  });
  if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC))) return -1;
  return secs;
}

// ---------------------------------------------------------------- stages
static NSDictionary *grants(void) {
  return @{@"accessibility": @(AXIsProcessTrusted()), @"screen_recording": @(CGPreflightScreenCaptureAccess()),
           @"post_event": @(CGPreflightPostEventAccess())};
}

static NSArray<Agent *> *stage_launch(int n, size_t ballast_mb, NSMutableDictionary *row, CGRect *canvas_out) {
  // One big virtual display for all agents' windows when it can be made, else the main display.
  NSString *err = nil;
  CGRect canvas = CGDisplayBounds(CGMainDisplayID());
  NSString *where = @"main display";
  if (!held_displays) held_displays = [NSMutableArray array];
  if (held_displays.count == 0) {
    CGVirtualDisplay *v = make_display(99, 5120, 2880, &err);
    if (v) {
      [held_displays addObject:v];
      spin(1.5);
    } else row[@"big_display_error"] = err;
  }
  if (held_displays.count) {
    CGVirtualDisplay *v = held_displays[0];
    CGRect b = CGDisplayBounds(v.displayID);
    if (b.size.width >= 1280) { canvas = b; where = [NSString stringWithFormat:@"virtual display %u %.0fx%.0f", v.displayID, b.size.width, b.size.height]; }
  }
  *canvas_out = canvas;
  row[@"canvas"] = where;
  NSMutableArray *agents = [NSMutableArray array];
  NSMutableArray *launch = [NSMutableArray array], *ready = [NSMutableArray array];
  int cols = MAX(1, (int)(canvas.size.width / 640));
  int failed = 0;
  NSString *firstErr = nil;
  for (int i = 0; i < n; i++) {
    int slot = i % (cols * MAX(1, (int)(canvas.size.height / 400)));
    CGRect f = CGRectMake(canvas.origin.x + (slot % cols) * 640, canvas.origin.y + (slot / cols) * 400 + 30, 620, 360);
    double t = now_s();
    Agent *a = launch_agent(i, f, ballast_mb, NO, &err);
    if (!a) { failed++; firstErr = firstErr ?: err; continue; }
    [launch addObject:@(now_s() - t)];
    if (!agent_resolve(a, 20)) { failed++; firstErr = firstErr ?: @"no AX window/button in 20 s"; [a.app forceTerminate]; continue; }
    [ready addObject:@(now_s() - t)];
    [agents addObject:a];
  }
  spin(1.0);
  uint64_t fp = 0, rs = 0;
  NSMutableArray *fps = [NSMutableArray array];
  for (Agent *a in agents) {
    NSDictionary *m = mem_of(a.pid);
    fp += [m[@"footprint"] unsignedLongLongValue];
    rs += [m[@"resident"] unsignedLongLongValue];
    [fps addObject:@([m[@"footprint"] doubleValue] / 1048576.0)];
  }
  row[@"launch"] = @{@"agents": @(agents.count), @"failed": @(failed), @"first_error": nn(firstErr), @"open_s": pct(launch),
                      @"to_ax_ready_s": pct(ready), @"footprint_mb_each": pct(fps), @"footprint_total_mb": @(fp >> 20),
                      @"resident_total_mb": @(rs >> 20), @"ballast_mb": @(ballast_mb)};
  return agents;
}

static void stage_capture(NSArray<Agent *> *agents, int rounds, NSMutableDictionary *row) {
  if (!CGPreflightScreenCaptureAccess()) { row[@"capture"] = @{@"skipped": @"Screen Recording not granted"}; return; }
  double listS = 0;
  NSString *err = nil;
  SCShareableContent *sc = shareable(&listS, &err);
  if (!sc) { row[@"capture"] = @{@"skipped": [@"SCShareableContent: " stringByAppendingString:err ?: @"?"]}; return; }
  NSMutableArray *wins = [NSMutableArray array];
  for (Agent *a in agents) { SCWindow *w = sc_window(sc, a.pid); if (w) [wins addObject:w]; }
  NSMutableArray *seq = [NSMutableArray array];
  int fails = 0;
  for (int r = 0; r < rounds; r++)
    for (SCWindow *w in wins) { double s = capture_sync(w, NULL); if (s < 0) fails++; else [seq addObject:@(s)]; }
  // All at once: every agent asks for its screenshot in the same instant.
  NSMutableArray *conc = [NSMutableArray array], *roundS = [NSMutableArray array];
  __block int cfails = 0;
  for (int r = 0; r < rounds; r++) {
    dispatch_group_t g = dispatch_group_create();
    NSObject *lock = [NSObject new];
    double t = now_s();
    for (SCWindow *w in wins) {
      dispatch_group_enter(g);
      capture_async(w, ^(BOOL ok, double s, CGImageRef im) {
        @synchronized(lock) { if (ok) [conc addObject:@(s)]; else cfails++; }
        dispatch_group_leave(g);
      });
    }
    dispatch_group_wait(g, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));
    [roundS addObject:@(now_s() - t)];
  }
  double totalRound = 0;
  for (NSNumber *x in roundS) totalRound += x.doubleValue;
  row[@"capture"] = @{@"windows_found": @(wins.count), @"list_s": @(listS), @"sequential_s": pct(seq), @"sequential_failed": @(fails),
                       @"all_at_once_s": pct(conc), @"all_at_once_failed": @(cfails), @"all_at_once_round_s": pct(roundS),
                       @"per_agent_fps_all_at_once": @(totalRound > 0 ? rounds / totalRound : 0),
                       @"captures_per_s_all_at_once": @(totalRound > 0 ? (double)conc.count / totalRound : 0)};
}

static void stage_input(NSArray<Agent *> *agents, Agent *witness, int reps, NSMutableDictionary *row) {
  if (!AXIsProcessTrusted()) { row[@"input"] = @{@"skipped": @"Accessibility not granted"}; return; }
  NSMutableDictionary *out = [NSMutableDictionary dictionary];
  for (NSString *route in @[ @"ax-press", @"ax-setvalue", @"cg-pid", @"stamped-cg" ]) {
    NSMutableArray *lat = [NSMutableArray array];
    int ok = 0, n = 0, steals = 0;
    for (int r = 0; r < reps; r++)
      for (Agent *a in agents) {
        if (witness) { [witness.app activateWithOptions:0]; }
        pid_t front0 = focused_pid();
        double s = act(a, route, 1.0);
        n++;
        if (s >= 0) { ok++; [lat addObject:@(s)]; }
        pid_t front1 = focused_pid();
        if (front1 != front0 || front1 == a.pid) steals++;
      }
    out[route] = @{@"n": @(n), @"delivered": @(ok), @"delivered_rate": @(n ? (double)ok / n : 0), @"latency_s": pct(lat), @"focus_changes": @(steals)};
  }
  out[@"witness_frontmost"] = @(witness && focused_pid() == witness.pid);
  row[@"input"] = out;
}

static double tick_rate(Agent *a, double secs) {
  NSString *p = [NSString stringWithFormat:@"/tmp/cud/ticks-%d", a.aid];
  long t0 = -1, t1 = -1;
  double w0 = 0, w1 = 0;
  for (int k = 0; k < 2; k++) {
    [[NSFileManager defaultManager] removeItemAtPath:p error:nil];
    kill(a.pid, SIGUSR1);
    for (int i = 0; i < 200; i++) {
      NSString *s = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
      if (s.length) {
        NSArray *f = [s componentsSeparatedByString:@" "];
        if (k == 0) { t0 = [f[0] longLongValue]; w0 = [f[1] doubleValue]; } else { t1 = [f[0] longLongValue]; w1 = [f[1] doubleValue]; }
        break;
      }
      usleep(10000);
    }
    if (k == 0) sleep_s(secs);
  }
  return (t0 >= 0 && t1 >= 0 && w1 > w0) ? (t1 - t0) / (w1 - w0) : -1;
}

static void stage_appnap(Agent *a, Agent *witness, NSMutableDictionary *row) {
  if (witness) [witness.app activateWithOptions:0];
  spin(0.5);
  double visible = tick_rate(a, 5);
  [a.app hide];
  spin(2.0);
  double hidden = tick_rate(a, 10);
  [a.app unhide];
  spin(0.5);
  int tp = run_cmd(@"/usr/sbin/taskpolicy", @[ @"-b", @"-p", @(a.pid).stringValue ]);
  double bg = tick_rate(a, 5);
  NSMutableArray *lat = [NSMutableArray array];
  for (int i = 0; i < 10; i++) { double s = act(a, @"ax-press", 2.0); if (s >= 0) [lat addObject:@(s)]; }
  int tpB = run_cmd(@"/usr/sbin/taskpolicy", @[ @"-B", @"-p", @(a.pid).stringValue ]);
  NSMutableArray *lat0 = [NSMutableArray array];
  for (int i = 0; i < 10; i++) { double s = act(a, @"ax-press", 2.0); if (s >= 0) [lat0 addObject:@(s)]; }
  row[@"appnap"] = @{@"timer_hz_nominal": @10, @"timer_hz_visible_background": @(visible), @"timer_hz_hidden": @(hidden),
                      @"timer_hz_taskpolicy_b": @(bg), @"taskpolicy_b_exit": @(tp), @"taskpolicy_B_exit": @(tpB),
                      @"ax_press_s_under_taskpolicy_b": pct(lat), @"ax_press_s_after": pct(lat0)};
}

static NSString *self_path;

static void stage_evict(NSMutableDictionary *row, Agent *witness) {
  // One agent with 1 GB of ballast, stopped, then the guest under memory pressure from `cud hog`.
  NSString *err = nil;
  CGRect canvas = CGDisplayBounds(CGMainDisplayID());
  if (held_displays.count) canvas = CGDisplayBounds([(CGVirtualDisplay *)held_displays[0] displayID]);
  Agent *a = launch_agent(500, CGRectMake(canvas.origin.x + 40, canvas.origin.y + 60, 620, 360), 1024, NO, &err);
  if (!a || !agent_resolve(a, 30)) { row[@"evict"] = @{@"skipped": [@"agent did not start: " stringByAppendingString:err ?: @"no AX"]}; if (a) [a.app forceTerminate]; return; }
  spin(2.0);
  NSDictionary *m0 = mem_of(a.pid), *v0 = vmstat();
  double t = now_s();
  kill(a.pid, SIGSTOP);
  double stopS = now_s() - t;
  NSDictionary *m1 = mem_of(a.pid);
  uint64_t memsize = 0;
  size_t l = sizeof(memsize);
  sysctlbyname("hw.memsize", &memsize, &l, NULL, 0);
  // The hog grows 256 MB at a time to at most memsize - 1.5 GB, and stops early once the stopped
  // agent kept less than 30% resident.
  NSTask *hog = [NSTask new];
  hog.launchPath = self_path;
  hog.arguments = @[ @"hog", @((memsize >> 20) - 1536).stringValue ];
  hog.standardOutput = [NSFileHandle fileHandleWithNullDevice];
  [hog launch];
  double hs = now_s();
  NSMutableArray *trace = [NSMutableArray array];
  double r0 = [m1[@"resident"] doubleValue];
  while (now_s() - hs < 120 && hog.isRunning) {
    sleep_s(2.0);
    NSDictionary *m = mem_of(a.pid), *v = vmstat();
    [trace addObject:@{@"t": @(round((now_s() - hs) * 10) / 10), @"agent_resident_mb": @([m[@"resident"] unsignedLongLongValue] >> 20),
                       @"agent_footprint_mb": @([m[@"footprint"] unsignedLongLongValue] >> 20), @"hog_mb": @([mem_of(hog.processIdentifier)[@"resident"] unsignedLongLongValue] >> 20),
                       @"compressor_mb": @([v[@"compressor_bytes"] unsignedLongLongValue] >> 20),
                       @"stored_mb": @([v[@"stored_in_compressor_bytes"] unsignedLongLongValue] >> 20),
                       @"swap_used_mb": @([v[@"swap_used_bytes"] unsignedLongLongValue] >> 20)}];
    if ([m[@"resident"] doubleValue] < 0.3 * r0) break;
  }
  NSDictionary *m2 = mem_of(a.pid), *v2 = vmstat();
  [hog terminate];
  [hog waitUntilExit];
  spin(2.0);
  NSDictionary *m3 = mem_of(a.pid);
  // Resume: SIGCONT, then the first acted click (the UI's pages), then touching all ballast.
  t = now_s();
  kill(a.pid, SIGCONT);
  double firstAct = act(a, @"ax-press", 10.0);
  double resumeToAct = firstAct >= 0 ? now_s() - t : -1;
  NSString *tp = @"/tmp/cud/touch-500";
  [[NSFileManager defaultManager] removeItemAtPath:tp error:nil];
  double tt = now_s();
  kill(a.pid, SIGUSR2);
  double touchS = -1;
  while (now_s() - tt < 60) {
    NSString *s = [NSString stringWithContentsOfFile:tp encoding:NSUTF8StringEncoding error:nil];
    if (s.length) { touchS = [[s componentsSeparatedByString:@" "][0] doubleValue]; break; }
    usleep(20000);
  }
  NSDictionary *m4 = mem_of(a.pid), *v4 = vmstat();
  [a.app forceTerminate];
  row[@"evict"] = @{@"ballast_mb": @1024, @"sigstop_s": @(stopS), @"running": m0, @"stopped": m1, @"under_pressure": m2,
                     @"after_pressure_released": m3, @"after_resume_and_touch": m4, @"vm_before": v0, @"vm_at_pressure": v2,
                     @"vm_after": v4, @"trace": trace, @"resume_to_acted_click_s": @(resumeToAct),
                     @"touch_all_ballast_after_resume_s": @(touchS)};
}

// Agents at ~10% awake: each its own thread.
static void stage_loop(NSArray<Agent *> *agents, double seconds, NSMutableDictionary *row) {
  if (!AXIsProcessTrusted()) { row[@"loop"] = @{@"skipped": @"Accessibility not granted"}; return; }
  NSMutableArray *resume = [NSMutableArray array], *awakeS = [NSMutableArray array], *suspendS = [NSMutableArray array];
  __block int fails = 0, cycles = 0;
  NSObject *lock = [NSObject new];
  for (Agent *a in agents) kill(a.pid, SIGSTOP);
  sleep_s(1.0);
  uint64_t b0, t0, b1, t1;
  cpu_ticks(&b0, &t0);
  double cpu0 = 0;
  for (Agent *a in agents) cpu0 += cpu_s_of(a.pid);
  double start = now_s(), end = start + seconds;
  NSMutableArray *samples = [NSMutableArray array];
  dispatch_group_t g = dispatch_group_create();
  for (Agent *a in agents) {
    dispatch_group_enter(g);
    [NSThread detachNewThreadWithBlock:^{
      sleep_s(drand48() * 2.0);  // staggered wake: never all at t=0
      double meanThink = 1.0;
      while (now_s() < end) {
        double t = now_s();
        kill(a.pid, SIGCONT);
        double s1 = act(a, @"ax-press", 5.0);
        double r = s1 >= 0 ? now_s() - t : -1;
        double s2 = s1 >= 0 ? act(a, @"ax-press", 5.0) : -1;
        double awake = now_s() - t;
        double ts = now_s();
        kill(a.pid, SIGSTOP);
        double sus = now_s() - ts;
        @synchronized(lock) {
          cycles++;
          if (r < 0 || s2 < 0) fails++;
          if (r >= 0) [resume addObject:@(r)];
          [awakeS addObject:@(awake)];
          [suspendS addObject:@(sus)];
        }
        meanThink = MAX(0.2, 9.0 * awake);
        sleep_s(-log(1.0 - drand48()) * meanThink);
      }
      kill(a.pid, SIGCONT);
      dispatch_group_leave(g);
    }];
  }
  while (dispatch_group_wait(g, DISPATCH_TIME_NOW)) {
    sleep_s(5.0);
    uint64_t fp = 0, rs = 0;
    for (Agent *a in agents) { NSDictionary *m = mem_of(a.pid); fp += [m[@"footprint"] unsignedLongLongValue]; rs += [m[@"resident"] unsignedLongLongValue]; }
    [samples addObject:@{@"footprint_mb": @(fp >> 20), @"resident_mb": @(rs >> 20)}];
  }
  double wall = now_s() - start;
  cpu_ticks(&b1, &t1);
  double cpu1 = 0;
  for (Agent *a in agents) cpu1 += cpu_s_of(a.pid);
  double hostBusy = (t1 > t0) ? (double)(b1 - b0) / (double)(t1 - t0) * ncpu() : 0;
  double awakeTotal = 0;
  for (NSNumber *x in awakeS) awakeTotal += x.doubleValue;
  NSMutableArray *fpS = [NSMutableArray array];
  for (NSDictionary *s in samples) [fpS addObject:s[@"footprint_mb"]];
  row[@"loop"] = @{@"agents": @(agents.count), @"seconds": @(wall), @"cycles": @(cycles), @"failed_cycles": @(fails),
                    @"resume_to_acted_click_s": pct(resume), @"awake_s": pct(awakeS), @"sigstop_s": pct(suspendS),
                    @"awake_fraction": @(agents.count && wall > 0 ? awakeTotal / (agents.count * wall) : 0),
                    @"host_cores_busy": @(hostBusy), @"agents_cpu_cores": @((cpu1 - cpu0) / wall),
                    @"footprint_total_mb": pct(fpS), @"ncpu": @(ncpu())};
}

// ---------------------------------------------------------------- jobs: N concurrent GUI test jobs
// `cud jobs OUT NS SECONDS BALLAST_MB MODES` (cmuxterm-hq docs/research/gui-ci-partitioning/virtual-display.md).
// Each job is one agent app (its own process and window, filled with its own colour) driven by its own
// thread, all N at once for SECONDS. MODES is a comma list:
//   display  one 1280x800 CGVirtualDisplay per job, the job's window alone on it
//   window   one 5120x2880 virtual display, every job's window on it, overlapping its neighbours
// Each job loops: AXPress (no focus), AX set value of its field to a job token, a key event to its
// pid carrying a job token (CGEventPostToPid), a stamped CGEventPostToPid click, a ScreenCaptureKit
// capture of its window (and, in display mode, of its display), and every 4th round a raw pixel
// click (CGEventPost at the HID tap after raising the window), which holds the session's one
// console-input token (a mutex here) from raise to the title change.
// Cross-job checks at the end, per job: the app's click count is never above the clicks its own job
// sent; its key log holds only its own job's tokens; its field holds its own value; no capture holds
// another job's colour (window capture: above 0.2% of pixels; display capture: above 0.5%).
static pthread_mutex_t console_token = PTHREAD_MUTEX_INITIALIZER;

static void post_keys(Agent *a, NSString *text) {
  UniChar buf[20];
  NSUInteger n = MIN(text.length, (NSUInteger)20);
  [text getCharacters:buf range:NSMakeRange(0, n)];
  for (int down = 1; down >= 0; down--) {
    CGEventRef e = CGEventCreateKeyboardEvent(NULL, 0, down);
    if (!e) continue;
    CGEventKeyboardSetUnicodeString(e, n, buf);
    CGEventPostToPid(a.pid, e);
    CFRelease(e);
  }
}

static void hid_click(Agent *a) {
  CGRect b = ax_frame(a.button);
  CGPoint p = CGPointMake(CGRectGetMidX(b), CGRectGetMidY(b));
  CGEventType types[3] = {kCGEventMouseMoved, kCGEventLeftMouseDown, kCGEventLeftMouseUp};
  for (int i = 0; i < 3; i++) {
    CGEventRef e = CGEventCreateMouseEvent(NULL, types[i], p, kCGMouseButtonLeft);
    if (!e) continue;
    CGEventPost(kCGHIDEventTap, e);
    CFRelease(e);
    usleep(10000);
  }
}

// Fractions of sampled pixels that are this job's colour and another job's colour, and which job.
static NSDictionary *classify(CGImageRef im, int own, int njobs) {
  size_t w = CGImageGetWidth(im) / 4, h = CGImageGetHeight(im) / 4;
  if (w < 4 || h < 4) return @{@"own": @0, @"foreign": @0, @"foreign_job": @(-1)};
  CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  uint8_t *px = calloc(w * h, 4);
  CGContextRef ctx = CGBitmapContextCreate(px, w, h, 8, w * 4, srgb, kCGImageAlphaPremultipliedLast);
  CGContextSetInterpolationQuality(ctx, kCGInterpolationNone);
  CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), im);
  int nh = MIN(njobs, JOB_HUES);
  double pal[JOB_HUES][3];
  for (int j = 0; j < nh; j++) { job_rgb(j, pal[j]); for (int c = 0; c < 3; c++) pal[j][c] *= 255; }
  long ownN = 0, foreignN = 0;
  long per[JOB_HUES] = {0};
  for (size_t i = 0; i < w * h; i++) {
    uint8_t *q = px + i * 4;
    int best = -1;
    double bd = 35 * 35;
    for (int j = 0; j < nh; j++) {
      double d = 0;
      for (int c = 0; c < 3; c++) d += (q[c] - pal[j][c]) * (q[c] - pal[j][c]);
      if (d < bd) { bd = d; best = j; }
    }
    if (best < 0) continue;
    if (best == own % JOB_HUES) ownN++;
    else { foreignN++; per[best]++; }
  }
  int fj = -1;
  for (int j = 0; j < nh; j++) if (per[j] && (fj < 0 || per[j] > per[fj])) fj = j;
  CGContextRelease(ctx);
  CGColorSpaceRelease(srgb);
  free(px);
  double total = (double)(w * h);
  return @{@"own": @(ownN / total), @"foreign": @(foreignN / total), @"foreign_job": @(fj)};
}

static double capture_filter_sync(SCContentFilter *f, size_t pw, size_t ph, CGImageRef *out) {
  SCStreamConfiguration *c = [SCStreamConfiguration new];
  c.width = pw;
  c.height = ph;
  c.showsCursor = NO;
  __block double secs = -1;
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  double t = now_s();
  [SCScreenshotManager captureImageWithFilter:f configuration:c completionHandler:^(CGImageRef im, NSError *e) {
    if (im) { secs = now_s() - t; if (out) *out = CGImageRetain(im); }
    dispatch_semaphore_signal(sem);
  }];
  if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC))) return -1;
  return secs;
}

@interface Job : NSObject
@property int jid;
@property(strong) Agent *agent;
@property CGDirectDisplayID display;
@property(strong) SCWindow *scWindow;
@property(strong) SCDisplay *scDisplay;
@property(strong) NSMutableDictionary<NSString *, NSMutableArray *> *lat;  // route -> seconds
@property(strong) NSMutableDictionary<NSString *, NSNumber *> *sent;       // route -> count
@property(strong) NSMutableDictionary<NSString *, NSNumber *> *ok;         // route -> delivered
@property(strong) NSMutableArray *tokenWait, *tokenHold, *raises;
@property long clicksSent;
@property double captureWindowForeignMax, captureDisplayForeignMax, captureWindowOwnMin;
@property int captureWindowLeaks, captureDisplayLeaks, captureWindowForeignJob, captureDisplayForeignJob;
@property(strong) NSString *lastValue;
@end
@implementation Job
@end

static void job_note(Job *j, NSString *route, double s) {
  @synchronized(j) {
    j.sent[route] = @(j.sent[route].intValue + 1);
    if (s >= 0) {
      j.ok[route] = @(j.ok[route].intValue + 1);
      if (!j.lat[route]) j.lat[route] = [NSMutableArray array];
      [j.lat[route] addObject:@(s)];
    }
  }
}

static NSString *ax_value(AXUIElementRef e) { return ax_string(e, kAXValueAttribute); }

static void job_run(Job *j, double end, int njobs, BOOL displayCapture, NSArray *excludedApps) {
  Agent *a = j.agent;
  AXUIElementRef keysEl = ax_find(a.window, @"AXStaticText", @"cud-keys", 0);
  SCContentFilter *wf = j.scWindow ? [[SCContentFilter alloc] initWithDesktopIndependentWindow:j.scWindow] : nil;
  SCContentFilter *df = (displayCapture && j.scDisplay)
                            ? [[SCContentFilter alloc] initWithDisplay:j.scDisplay excludingApplications:excludedApps exceptingWindows:@[]]
                            : nil;
  j.captureWindowOwnMin = 1;
  for (int seq = 1; now_s() < end; seq++) {
    j.clicksSent++;
    job_note(j, @"ax-press", act(a, @"ax-press", 1.0));

    NSString *val = [NSString stringWithFormat:@"j%d-%d", j.jid, seq];
    double t = now_s(), s = -1;
    if (a.field && AXUIElementSetAttributeValue(a.field, kAXValueAttribute, (__bridge CFTypeRef)val) == kAXErrorSuccess)
      while (now_s() - t < 1.0) { if ([ax_value(a.field) isEqualToString:val]) { s = now_s() - t; break; } usleep(1000); }
    if (s >= 0) j.lastValue = val;
    job_note(j, @"ax-setvalue", s);

    NSString *tok = [NSString stringWithFormat:@"<%d.%d>", j.jid, seq];
    t = now_s();
    s = -1;
    post_keys(a, tok);
    if (keysEl)
      while (now_s() - t < 1.0) { if ([ax_value(keysEl) containsString:tok]) { s = now_s() - t; break; } usleep(1000); }
    job_note(j, @"cg-key", s);

    j.clicksSent++;
    job_note(j, @"stamped-cg", act(a, @"stamped-cg", 1.0));

    if (wf) {
      CGImageRef im = NULL;
      size_t pw = (size_t)MAX(64, j.scWindow.frame.size.width * wf.pointPixelScale), ph = (size_t)MAX(64, j.scWindow.frame.size.height * wf.pointPixelScale);
      s = capture_filter_sync(wf, pw, ph, &im);
      job_note(j, @"capture-window", s);
      if (im) {
        NSDictionary *c = classify(im, j.jid, njobs);
        double fr = [c[@"foreign"] doubleValue];
        if (fr > j.captureWindowForeignMax) { j.captureWindowForeignMax = fr; j.captureWindowForeignJob = [c[@"foreign_job"] intValue]; }
        j.captureWindowOwnMin = MIN(j.captureWindowOwnMin, [c[@"own"] doubleValue]);
        if (fr > 0.002) j.captureWindowLeaks++;
        CGImageRelease(im);
      }
    }
    if (df) {
      CGImageRef im = NULL;
      s = capture_filter_sync(df, (size_t)j.scDisplay.width, (size_t)j.scDisplay.height, &im);
      job_note(j, @"capture-display", s);
      if (im) {
        NSDictionary *c = classify(im, j.jid, njobs);
        double fr = [c[@"foreign"] doubleValue];
        if (fr > j.captureDisplayForeignMax) { j.captureDisplayForeignMax = fr; j.captureDisplayForeignJob = [c[@"foreign_job"] intValue]; }
        if (fr > 0.005) j.captureDisplayLeaks++;
        CGImageRelease(im);
      }
    }

    if (seq % 4 == 0) {
      // A raw pixel click: the one cursor and key window are the session's, so it holds the token.
      double tw = now_s();
      pthread_mutex_lock(&console_token);
      double th = now_s();
      AXUIElementSetAttributeValue(a.ax, kAXFrontmostAttribute, kCFBooleanTrue);
      AXUIElementPerformAction(a.window, kAXRaiseAction);
      [a.app activateWithOptions:NSApplicationActivateIgnoringOtherApps];
      for (int i = 0; i < 50 && focused_pid() != a.pid; i++) usleep(2000);
      double raised = now_s() - th;
      NSString *before = ax_string(a.window, kAXTitleAttribute);
      j.clicksSent++;
      hid_click(a);
      s = -1;
      while (now_s() - th < 1.5) {
        NSString *after = ax_string(a.window, kAXTitleAttribute);
        if (after && before && ![after isEqualToString:before]) { s = now_s() - th; break; }
        usleep(1000);
      }
      pthread_mutex_unlock(&console_token);
      double hold = now_s() - th;
      @synchronized(j) {
        [j.tokenWait addObject:@(th - tw)];
        [j.tokenHold addObject:@(hold)];
        [j.raises addObject:@(raised)];
      }
      job_note(j, @"hid-click", s);
    }
  }
  if (keysEl) CFRelease(keysEl);
}

static NSDictionary *job_checks(Job *j) {
  Agent *a = j.agent;
  NSString *title = ax_string(a.window, kAXTitleAttribute) ?: @"";
  NSRange r = [title rangeOfString:@": " options:NSBackwardsSearch];
  long clicks = r.location == NSNotFound ? -1 : [[title substringFromIndex:r.location + 2] longLongValue];
  AXUIElementRef keysEl = ax_find(a.window, @"AXStaticText", @"cud-keys", 0);
  NSString *keys = keysEl ? (ax_value(keysEl) ?: @"") : @"";
  if (keysEl) CFRelease(keysEl);
  NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"<(\\d+)\\.\\d+>" options:0 error:nil];
  __block int own = 0, foreign = 0;
  __block NSUInteger covered = 0;
  [re enumerateMatchesInString:keys options:0 range:NSMakeRange(0, keys.length)
                    usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags f, BOOL *stop) {
                      covered += m.range.length;
                      if ([[keys substringWithRange:[m rangeAtIndex:1]] intValue] == j.jid) own++; else foreign++;
                    }];
  NSString *field = ax_value(a.field) ?: @"";
  NSString *prefix = [NSString stringWithFormat:@"j%d-", j.jid];
  BOOL fieldOwn = field.length == 0 || [field hasPrefix:prefix];
  return @{@"job": @(j.jid), @"clicks_seen": @(clicks), @"clicks_sent": @(j.clicksSent),
           @"click_leak_in": @(clicks > j.clicksSent), @"keys_own": @(own), @"keys_foreign": @(foreign),
           @"keys_garbage_chars": @(keys.length - covered), @"field_own": @(fieldOwn),
           @"capture_window_foreign_max": @(j.captureWindowForeignMax), @"capture_window_foreign_job": @(j.captureWindowForeignJob),
           @"capture_window_own_min": @(j.captureWindowOwnMin), @"capture_window_leaks": @(j.captureWindowLeaks),
           @"capture_display_foreign_max": @(j.captureDisplayForeignMax), @"capture_display_foreign_job": @(j.captureDisplayForeignJob),
           @"capture_display_leaks": @(j.captureDisplayLeaks)};
}

static NSDictionary *jobs_round(NSString *mode, int n, double seconds, size_t ballast_mb) {
  NSMutableDictionary *row = [NSMutableDictionary dictionaryWithDictionary:@{@"stage": @"jobs", @"mode": mode, @"n": @(n)}];
  if (!AXIsProcessTrusted()) { row[@"skipped"] = @"Accessibility not granted"; return row; }
  BOOL perDisplay = [mode isEqualToString:@"display"];
  NSMutableArray *displays = [NSMutableArray array];
  NSMutableArray<Job *> *jobs = [NSMutableArray array];
  NSString *err = nil, *firstErr = nil;
  double t0 = now_s();
  CGRect big = CGRectNull;
  if (perDisplay) {
    for (int i = 0; i < n; i++) {
      CGVirtualDisplay *v = make_display(200 + i, 1280, 800, &err);
      if (!v) { firstErr = firstErr ?: [NSString stringWithFormat:@"display %d: %@", i, err]; break; }
      [displays addObject:v];
      spin(0.05);
    }
  } else {
    CGVirtualDisplay *v = make_display(150, 5120, 2880, &err);
    if (v) [displays addObject:v]; else firstErr = [@"big display: " stringByAppendingString:err ?: @"?"];
  }
  spin(1.5);
  row[@"displays_made"] = @(displays.count);
  row[@"displays_s"] = @(now_s() - t0);
  if (!perDisplay && displays.count) big = CGDisplayBounds([(CGVirtualDisplay *)displays[0] displayID]);
  int cols = CGRectIsNull(big) ? 1 : MAX(1, (int)((big.size.width - 620) / 400) + 1);
  NSMutableArray *ready = [NSMutableArray array];
  for (int i = 0; i < n; i++) {
    CGRect f;
    CGDirectDisplayID did = 0;
    if (perDisplay) {
      if ((NSUInteger)i >= displays.count) break;
      did = [(CGVirtualDisplay *)displays[i] displayID];
      CGRect b = CGDisplayBounds(did);
      f = CGRectMake(b.origin.x + 40, b.origin.y + 60, 620, 360);
    } else {
      if (CGRectIsNull(big)) break;
      did = [(CGVirtualDisplay *)displays[0] displayID];
      f = CGRectMake(big.origin.x + (i % cols) * 400, big.origin.y + 30 + (i / cols) * 300, 620, 360);  // overlaps its neighbours
    }
    double t = now_s();
    Agent *a = launch_agent_hue(i, f, ballast_mb, NO, i, &err);
    if (!a) { firstErr = firstErr ?: err; continue; }
    if (!agent_resolve(a, 20) || !a.field) { firstErr = firstErr ?: @"no AX window/button/field in 20 s"; [a.app forceTerminate]; continue; }
    [ready addObject:@(now_s() - t)];
    Job *j = [Job new];
    j.jid = i;
    j.agent = a;
    j.display = did;
    j.lat = [NSMutableDictionary dictionary];
    j.sent = [NSMutableDictionary dictionary];
    j.ok = [NSMutableDictionary dictionary];
    j.tokenWait = [NSMutableArray array];
    j.tokenHold = [NSMutableArray array];
    j.raises = [NSMutableArray array];
    j.captureWindowForeignJob = j.captureDisplayForeignJob = -1;
    [jobs addObject:j];
  }
  spin(1.0);
  // Capture targets, once: the job's window and its display.
  NSArray *excluded = @[];
  BOOL canCapture = CGPreflightScreenCaptureAccess();
  if (canCapture) {
    double ls = 0;
    SCShareableContent *sc = shareable(&ls, &err);
    row[@"shareable_s"] = @(ls);
    NSMutableArray *ex = [NSMutableArray array];
    for (SCRunningApplication *app in sc.applications)
      if ([@[ @"com.apple.dock", @"com.apple.wallpaper.agent", @"com.apple.WindowManager", @"com.apple.controlcenter" ] containsObject:app.bundleIdentifier ?: @""])
        [ex addObject:app];
    excluded = ex;
    for (Job *j in jobs) {
      j.scWindow = sc_window(sc, j.agent.pid);
      for (SCDisplay *d in sc.displays) if (d.displayID == j.display) j.scDisplay = d;
    }
  } else row[@"capture_skipped"] = @"Screen Recording not granted";
  row[@"up"] = @(jobs.count);
  row[@"to_ax_ready_s"] = pct(ready);
  row[@"first_error"] = nn(firstErr);
  // All jobs at once.
  uint64_t b0, tt0, b1, tt1;
  cpu_ticks(&b0, &tt0);
  double start = now_s(), end = start + seconds;
  dispatch_group_t g = dispatch_group_create();
  for (Job *j in jobs) {
    dispatch_group_enter(g);
    [NSThread detachNewThreadWithBlock:^{
      job_run(j, end, n, perDisplay, excluded);
      dispatch_group_leave(g);
    }];
  }
  while (dispatch_group_wait(g, DISPATCH_TIME_NOW)) spin(0.2);
  double wall = now_s() - start;
  cpu_ticks(&b1, &tt1);
  spin(1.0);
  // Merge.
  NSMutableDictionary *routes = [NSMutableDictionary dictionary];
  NSMutableArray *checks = [NSMutableArray array];
  NSMutableArray *tw = [NSMutableArray array], *th = [NSMutableArray array], *rz = [NSMutableArray array];
  long actions = 0;
  uint64_t fp = 0;
  int clickLeaks = 0, keyLeaks = 0, fieldLeaks = 0, capWinLeakJobs = 0, capDispLeakJobs = 0;
  double capWinForeignMax = 0, capDispForeignMax = 0;
  for (NSString *route in @[ @"ax-press", @"ax-setvalue", @"cg-key", @"stamped-cg", @"hid-click", @"capture-window", @"capture-display" ]) {
    NSMutableArray *lat = [NSMutableArray array];
    long sent = 0, ok = 0;
    for (Job *j in jobs) { sent += j.sent[route].intValue; ok += j.ok[route].intValue; if (j.lat[route]) [lat addObjectsFromArray:j.lat[route]]; }
    actions += sent;
    if (sent) routes[route] = @{@"n": @(sent), @"delivered": @(ok), @"delivered_rate": @((double)ok / sent), @"latency_s": pct(lat)};
  }
  for (Job *j in jobs) {
    NSDictionary *c = job_checks(j);
    [checks addObject:c];
    clickLeaks += [c[@"click_leak_in"] boolValue];
    keyLeaks += [c[@"keys_foreign"] intValue] > 0;
    fieldLeaks += ![c[@"field_own"] boolValue];
    capWinLeakJobs += j.captureWindowLeaks > 0;
    capDispLeakJobs += j.captureDisplayLeaks > 0;
    capWinForeignMax = MAX(capWinForeignMax, j.captureWindowForeignMax);
    capDispForeignMax = MAX(capDispForeignMax, j.captureDisplayForeignMax);
    [tw addObjectsFromArray:j.tokenWait];
    [th addObjectsFromArray:j.tokenHold];
    [rz addObjectsFromArray:j.raises];
    fp += [mem_of(j.agent.pid)[@"footprint"] unsignedLongLongValue];
  }
  row[@"seconds"] = @(wall);
  row[@"routes"] = routes;
  row[@"token"] = @{@"wait_s": pct(tw), @"hold_s": pct(th), @"raise_s": pct(rz),
                    @"held_fraction": @(wall > 0 ? [[th valueForKeyPath:@"@sum.self"] doubleValue] / wall : 0)};
  row[@"actions_per_s_per_job"] = @(jobs.count && wall > 0 ? actions / wall / jobs.count : 0);
  row[@"host_cores_busy"] = @(tt1 > tt0 ? (double)(b1 - b0) / (double)(tt1 - tt0) * ncpu() : 0);
  row[@"ncpu"] = @(ncpu());
  row[@"footprint_total_mb"] = @(fp >> 20);
  row[@"leaks"] = @{@"click_jobs": @(clickLeaks), @"key_jobs": @(keyLeaks), @"field_jobs": @(fieldLeaks),
                    @"capture_window_jobs": @(capWinLeakJobs), @"capture_window_foreign_max": @(capWinForeignMax),
                    @"capture_display_jobs": @(capDispLeakJobs), @"capture_display_foreign_max": @(capDispForeignMax)};
  BOOL up = (int)jobs.count == n;
  BOOL noLeak = clickLeaks + keyLeaks + fieldLeaks + capWinLeakJobs + capDispLeakJobs == 0;
  row[@"isolated"] = @(up && noLeak && canCapture);
  row[@"checks"] = checks;
  for (Job *j in jobs) [j.agent.app forceTerminate];
  [displays removeAllObjects];
  spin(2.0);
  return row;
}

static int jobs_main(int argc, const char **argv) {
  // cud jobs OUT NS SECONDS BALLAST_MB MODES
  NSString *out = argc > 2 ? @(argv[2]) : @"/tmp/cud-out";
  NSString *nsArg = argc > 3 ? @(argv[3]) : @"1,2,4,8,16";
  double seconds = argc > 4 ? atof(argv[4]) : 30;
  size_t ballast = argc > 5 ? (size_t)atol(argv[5]) : 0;
  NSString *modes = argc > 6 ? @(argv[6]) : @"display,window";
  [[NSFileManager defaultManager] createDirectoryAtPath:out withIntermediateDirectories:YES attributes:nil error:nil];
  results_file = fopen([out stringByAppendingPathComponent:@"results.jsonl"].UTF8String, "a");
  [NSApplication sharedApplication];
  [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
  emit(@{@"stage": @"jobs-host", @"ncpu": @(ncpu()), @"grants": grants(), @"displays_online": @(online_displays())});
  for (NSString *mode in [modes componentsSeparatedByString:@","]) {
    for (NSString *ns in [nsArg componentsSeparatedByString:@","]) {
      int n = ns.intValue;
      if (n <= 0) continue;
      NSDictionary *row = jobs_round(mode, n, seconds, ballast);
      emit(row);
      if (row[@"skipped"] || [row[@"up"] intValue] * 2 < n) break;  // most jobs did not come up: larger N will not either
    }
  }
  if (results_file) fclose(results_file);
  return 0;
}

static int bench_main(int argc, const char **argv) {
  // cud bench OUT NS BALLAST_MB LOOP_S
  NSString *out = argc > 2 ? @(argv[2]) : @"/tmp/cud-out";
  NSString *nsArg = argc > 3 ? @(argv[3]) : @"1,4,8,16,32";
  size_t ballast = argc > 4 ? (size_t)atol(argv[4]) : 64;
  double loopS = argc > 5 ? atof(argv[5]) : 60;
  [[NSFileManager defaultManager] createDirectoryAtPath:out withIntermediateDirectories:YES attributes:nil error:nil];
  results_file = fopen([out stringByAppendingPathComponent:@"results.jsonl"].UTF8String, "a");
  [NSApplication sharedApplication];
  [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
  uint64_t memsize = 0;
  size_t l = sizeof(memsize);
  sysctlbyname("hw.memsize", &memsize, &l, NULL, 0);
  NSOperatingSystemVersion v = NSProcessInfo.processInfo.operatingSystemVersion;
  emit(@{@"stage": @"host", @"macos": [NSString stringWithFormat:@"%ld.%ld.%ld", v.majorVersion, v.minorVersion, v.patchVersion],
         @"ncpu": @(ncpu()), @"memsize_gb": @(memsize >> 30), @"grants": grants(), @"displays_online": @(online_displays()),
         @"main_display": NSStringFromRect(NSRectFromCGRect(CGDisplayBounds(CGMainDisplayID())))});
  emit(@{@"stage": @"vdisplay", @"result": vdisplay_cap(64, 1280, 800)});
  CGRect canvas;
  NSString *err = nil;
  for (NSString *ns in [nsArg componentsSeparatedByString:@","]) {
    int n = ns.intValue;
    if (n <= 0) continue;
    NSMutableDictionary *row = [NSMutableDictionary dictionaryWithDictionary:@{@"stage": @"agents", @"n": @(n)}];
    double t = now_s();
    NSArray<Agent *> *agents = stage_launch(n, ballast, row, &canvas);
    // The witness is the app at the keyboard: frontmost and key, on the main display.
    Agent *w = launch_agent(999, CGRectMake(60, 60, 500, 300), 0, YES, &err);
    if (w) { agent_resolve(w, 20); [w.app activateWithOptions:0]; spin(1.0); }
    if (agents.count < (NSUInteger)n) row[@"broke"] = [NSString stringWithFormat:@"%lu of %d agents came up", (unsigned long)agents.count, n];
    if (agents.count) {
      stage_capture(agents, n <= 8 ? 10 : 5, row);
      stage_input(agents, w, n <= 8 ? 5 : 2, row);
      stage_appnap(agents[0], w, row);
      stage_loop(agents, loopS, row);
    }
    for (Agent *a in agents) { kill(a.pid, SIGCONT); [a.app forceTerminate]; }
    if (w) [w.app forceTerminate];
    spin(2.0);
    row[@"stage_s"] = @(now_s() - t);
    emit(row);
    if (agents.count * 2 < (NSUInteger)n) break;  // most agents failed: larger N will not run either
  }
  NSMutableDictionary *ev = [NSMutableDictionary dictionaryWithDictionary:@{@"stage": @"evict"}];
  stage_evict(ev, nil);
  emit(ev);
  [held_displays removeAllObjects];
  if (results_file) fclose(results_file);
  return 0;
}

// ---------------------------------------------------------------- helpers and the slot API
static int hog_main(int argc, const char **argv) {
  size_t max = argc > 2 ? (size_t)atol(argv[2]) : 1024;
  NSMutableArray *chunks = [NSMutableArray array];
  uint64_t x = 88172645463325252ull;
  for (size_t got = 0; got + 256 <= max; got += 256) {
    char *p = malloc(256 << 20);
    if (!p) break;
    for (size_t i = 0; i < (256u << 20); i += 8) { x ^= x << 13; x ^= x >> 7; x ^= x << 17; *(uint64_t *)(p + i) = x; }
    [chunks addObject:[NSValue valueWithPointer:p]];
    printf("%zu\n", got + 256);
    fflush(stdout);
    usleep(200000);
  }
  pause();
  return 0;
}

static Agent *agent_for_pid(pid_t pid) {
  Agent *a = [Agent new];
  a.pid = pid;
  a.app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
  return agent_resolve(a, 5) ? a : nil;
}

int main(int argc, const char **argv) {
  @autoreleasepool {
    srand48(getpid());
    void *sl = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW);
    (void)sl;
    set_window_location = (SetWindowLocationFn)dlsym(RTLD_DEFAULT, "CGEventSetWindowLocation");
    set_integer_field = (SetIntegerFieldFn)dlsym(RTLD_DEFAULT, "SLEventSetIntegerValueField");
    if (!set_integer_field) set_integer_field = (SetIntegerFieldFn)dlsym(RTLD_DEFAULT, "CGEventSetIntegerValueField");
    char buf[PROC_PIDPATHINFO_MAXSIZE];
    self_path = proc_pidpath(getpid(), buf, sizeof(buf)) > 0 ? @(buf) : @(argv[0]);
    // CudAgent.app sits next to the cud binary, or this binary is inside it.
    NSString *dir = self_path.stringByDeletingLastPathComponent;
    app_path = [dir hasSuffix:@".app/Contents/MacOS"] ? dir.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent
                                                      : [dir stringByAppendingPathComponent:@"CudAgent.app"];
    NSString *cmd = argc > 1 ? @(argv[1]) : @"";
    if ([cmd isEqualToString:@"agent"]) return agent_main(argc, argv);
    if ([cmd isEqualToString:@"bench"]) return bench_main(argc, argv);
    if ([cmd isEqualToString:@"jobs"]) return jobs_main(argc, argv);
    if ([cmd isEqualToString:@"hog"]) return hog_main(argc, argv);
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    if ([cmd isEqualToString:@"grants"]) { emit(grants()); return 0; }
    if ([cmd isEqualToString:@"vdisplay"]) {
      emit(vdisplay_cap(argc > 2 ? atoi(argv[2]) : 16, argc > 3 ? atoi(argv[3]) : 1280, argc > 4 ? atoi(argv[4]) : 800));
      return 0;
    }
    if ([cmd isEqualToString:@"slot"] && argc > 2 && !strcmp(argv[2], "lease")) {
      int aid = argc > 3 ? atoi(argv[3]) : 0;
      CGRect f = CGRectMake(argc > 4 ? atof(argv[4]) : 80 + 30 * (aid % 20), argc > 5 ? atof(argv[5]) : 80 + 30 * (aid % 20),
                            argc > 6 ? atof(argv[6]) : 620, argc > 7 ? atof(argv[7]) : 360);
      NSString *err = nil;
      double t = now_s();
      Agent *a = launch_agent(aid, f, 0, NO, &err);
      BOOL ok = a && agent_resolve(a, 20);
      emit(@{@"ok": @(ok), @"slot": @(aid), @"pid": @(a ? a.pid : 0), @"wid": @(ok ? a.wid : 0), @"s": @(now_s() - t), @"error": nn(err)});
      return ok ? 0 : 1;
    }
    if ([cmd isEqualToString:@"slot"] && argc > 3 && !strcmp(argv[2], "release")) {
      pid_t pid = atoi(argv[3]);
      kill(pid, SIGCONT);
      BOOL ok = [[NSRunningApplication runningApplicationWithProcessIdentifier:pid] forceTerminate];
      emit(@{@"ok": @(ok), @"pid": @(pid)});
      return ok ? 0 : 1;
    }
    if (([cmd isEqualToString:@"suspend"] || [cmd isEqualToString:@"resume"]) && argc > 2) {
      pid_t pid = atoi(argv[2]);
      BOOL bg = argc > 3 && !strcmp(argv[3], "bg");
      BOOL sus = [cmd isEqualToString:@"suspend"];
      double t = now_s();
      BOOL ok = bg ? run_cmd(@"/usr/sbin/taskpolicy", @[ sus ? @"-b" : @"-B", @"-p", @(pid).stringValue ]) == 0 : kill(pid, sus ? SIGSTOP : SIGCONT) == 0;
      emit(@{@"ok": @(ok), @"pid": @(pid), @"ms": @((now_s() - t) * 1000), @"how": bg ? @"taskpolicy" : @"signal"});
      return ok ? 0 : 1;
    }
    if ([cmd isEqualToString:@"mem"] && argc > 2) { emit(mem_of(atoi(argv[2]))); return 0; }
    if ([cmd isEqualToString:@"act"] && argc > 2) {
      Agent *a = agent_for_pid(atoi(argv[2]));
      NSString *route = argc > 3 ? @(argv[3]) : @"ax-press";
      double s = a ? act(a, route, 2.0) : -1;
      emit(@{@"ok": @(s >= 0), @"ms": @(s >= 0 ? s * 1000 : -1), @"route": route, @"title": nn(a ? ax_string(a.window, kAXTitleAttribute) : nil)});
      return s >= 0 ? 0 : 1;
    }
    if ([cmd isEqualToString:@"shot"] && argc > 3) {
      pid_t pid = atoi(argv[2]);
      NSString *err = nil;
      SCShareableContent *sc = shareable(NULL, &err);
      SCWindow *w = sc ? sc_window(sc, pid) : nil;
      CGImageRef im = NULL;
      double s = w ? capture_sync(w, &im) : -1;
      if (im) {
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:im];
        [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@(argv[3]) atomically:YES];
      }
      emit(@{@"ok": @(im != NULL), @"ms": @(s * 1000), @"w": @(im ? CGImageGetWidth(im) : 0), @"h": @(im ? CGImageGetHeight(im) : 0), @"error": nn(err)});
      if (im) CGImageRelease(im);
      return im ? 0 : 1;
    }
    fprintf(stderr, "usage: cud agent|bench|jobs|hog|grants|vdisplay|slot lease|slot release|act|shot|suspend|resume|mem (see the header of cud.m)\n");
    return 2;
  }
}
