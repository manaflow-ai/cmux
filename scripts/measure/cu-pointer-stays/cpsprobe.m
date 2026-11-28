// The person's side of cu-pointer-stays (guest.sh, cps.py): a target window that logs every mouse
// event it receives, the real pointer parked where "the person" left it, and the pointer sampled
// every 10 ms while computer use acts.
//   cpsprobe target LOG         a regular app, window "CPS Target" (800x600) with a "CPS Button";
//                               one line per event to LOG: "<unix s> <kind> <x> <y>" (window points)
//                               or "<unix s> button" when the button's action runs
//   cpsprobe park X Y           warps the real pointer to X,Y (global points, top-left origin)
//   cpsprobe pos                prints the real pointer as {"x":..,"y":..}
//   cpsprobe screen             prints the main display's bounds in points as {"w":..,"h":..}
//   cpsprobe sample X Y STOP    samples CGEventGetLocation(CGEventCreate(NULL)) every 10 ms until the
//                               file STOP exists, then prints the farthest sample from X,Y as JSON
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <math.h>
#include <stdio.h>
#include <unistd.h>

static FILE *logf_;
static void logline(NSString *s) {
  fprintf(logf_, "%.3f %s\n", [[NSDate date] timeIntervalSince1970], s.UTF8String);
  fflush(logf_);
}

@interface CPSView : NSView
@end
@implementation CPSView
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (void)drawRect:(NSRect)r {
  [[NSColor colorWithCalibratedRed:0.93 green:0.95 blue:1 alpha:1] setFill];
  NSRectFill(r);
}
- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  for (NSTrackingArea *a in self.trackingAreas) [self removeTrackingArea:a];
  [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:self.bounds
                                                     options:NSTrackingMouseMoved | NSTrackingActiveAlways | NSTrackingInVisibleRect
                                                       owner:self
                                                    userInfo:nil]];
}
@end

@interface CPSTarget : NSObject <NSApplicationDelegate>
@property(strong) NSWindow *window;
@end
@implementation CPSTarget
- (void)pressed:(id)sender { logline(@"button"); }
- (void)applicationDidFinishLaunching:(NSNotification *)n {
  NSRect frame = NSMakeRect(200, 200, 800, 600);
  self.window = [[NSWindow alloc] initWithContentRect:frame
                                            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                              backing:NSBackingStoreBuffered
                                                defer:NO];
  self.window.title = @"CPS Target";
  self.window.acceptsMouseMovedEvents = YES;
  self.window.releasedWhenClosed = NO;
  CPSView *view = [[CPSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
  NSButton *button = [NSButton buttonWithTitle:@"CPS Button" target:self action:@selector(pressed:)];
  button.frame = NSMakeRect(20, 20, 160, 32);
  [view addSubview:button];
  self.window.contentView = view;
  [self.window makeKeyAndOrderFront:nil];
  [NSApp activateIgnoringOtherApps:YES];
  NSEventMask mask = NSEventMaskLeftMouseDown | NSEventMaskLeftMouseUp | NSEventMaskLeftMouseDragged |
                     NSEventMaskRightMouseDown | NSEventMaskRightMouseUp | NSEventMaskMouseMoved |
                     NSEventMaskScrollWheel | NSEventMaskOtherMouseDown | NSEventMaskOtherMouseUp;
  [NSEvent addLocalMonitorForEventsMatchingMask:mask
                                        handler:^NSEvent *(NSEvent *e) {
                                          NSString *kind = @"other";
                                          switch (e.type) {
                                            case NSEventTypeLeftMouseDown: kind = @"down"; break;
                                            case NSEventTypeLeftMouseUp: kind = @"up"; break;
                                            case NSEventTypeLeftMouseDragged: kind = @"dragged"; break;
                                            case NSEventTypeRightMouseDown: kind = @"rdown"; break;
                                            case NSEventTypeRightMouseUp: kind = @"rup"; break;
                                            case NSEventTypeMouseMoved: kind = @"moved"; break;
                                            case NSEventTypeScrollWheel: kind = @"scroll"; break;
                                            default: break;
                                          }
                                          NSPoint p = e.locationInWindow;
                                          logline([NSString stringWithFormat:@"%@ %.1f %.1f", kind, p.x, p.y]);
                                          return e;
                                        }];
  logline(@"ready");
}
@end

static CGPoint now_pos(void) {
  CGEventRef e = CGEventCreate(NULL);
  CGPoint p = CGEventGetLocation(e);
  CFRelease(e);
  return p;
}

int main(int argc, const char **argv) {
  @autoreleasepool {
    if (argc < 2) { fprintf(stderr, "usage: cpsprobe target LOG | park X Y | pos | screen | sample X Y STOP\n"); return 2; }
    NSString *cmd = @(argv[1]);
    if ([cmd isEqualToString:@"target"] && argc == 3) {
      logf_ = fopen(argv[2], "a");
      if (!logf_) return 1;
      NSApplication *app = [NSApplication sharedApplication];
      app.activationPolicy = NSApplicationActivationPolicyRegular;
      CPSTarget *delegate = [CPSTarget new];
      app.delegate = delegate;
      [app run];
      return 0;
    }
    if ([cmd isEqualToString:@"park"] && argc == 4) {
      CGPoint p = CGPointMake(atof(argv[2]), atof(argv[3]));
      CGError err = CGWarpMouseCursorPosition(p);
      CGAssociateMouseAndMouseCursorPosition(true);
      usleep(50000);
      CGPoint q = now_pos();
      printf("{\"warp_err\":%d,\"x\":%.2f,\"y\":%.2f}\n", err, q.x, q.y);
      return err == kCGErrorSuccess ? 0 : 1;
    }
    if ([cmd isEqualToString:@"screen"]) {
      CGRect r = CGDisplayBounds(CGMainDisplayID());
      printf("{\"w\":%.1f,\"h\":%.1f}\n", r.size.width, r.size.height);
      return 0;
    }
    if ([cmd isEqualToString:@"pos"]) {
      CGPoint q = now_pos();
      printf("{\"x\":%.2f,\"y\":%.2f}\n", q.x, q.y);
      return 0;
    }
    if ([cmd isEqualToString:@"sample"] && argc == 5) {
      double x0 = atof(argv[2]), y0 = atof(argv[3]);
      const char *stop = argv[4];
      double max = 0, mx = x0, my = y0;
      long n = 0, moved = 0;
      CGPoint first = now_pos(), last = first;
      for (;;) {
        CGPoint p = now_pos();
        double d = hypot(p.x - x0, p.y - y0);
        if (d > max) { max = d; mx = p.x; my = p.y; }
        if (d > 1) moved++;
        last = p;
        n++;
        if (access(stop, F_OK) == 0) break;
        usleep(10000);
      }
      printf("{\"max_pt\":%.2f,\"max_at\":[%.1f,%.1f],\"samples\":%ld,\"samples_moved\":%ld,"
             "\"first\":[%.1f,%.1f],\"last\":[%.1f,%.1f]}\n",
             max, mx, my, n, moved, first.x, first.y, last.x, last.y);
      return 0;
    }
    fprintf(stderr, "cpsprobe: unknown command\n");
    return 2;
  }
}
