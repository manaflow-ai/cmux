//! The agent cursor of the Rust worker on macOS (the Screen Sharing
//! helper's `__computer-use-worker`; cmux Remote's Swift worker draws its
//! own, `AgentCursorOverlay.swift`): a cmux-blue arrow in a borderless,
//! click-through, non-activating panel above every window, on every Space.
//! The process never activates (accessory policy, `orderFrontRegardless`),
//! so drawing takes no focus from the person.
//!
//! AppKit runs on the main thread, so the worker that draws must start
//! through [`run_with_app`]: the main thread runs the application and the
//! worker runs on its own thread. Without it (tests, a worker not on the
//! main thread) [`cursor_overlay`] is [`NoCursor`]. Events go to a glide
//! thread ([`crate::cursor_draw`] decides where and when), which hands each
//! frame's panel origin to the main queue.

use std::cell::RefCell;
use std::ffi::c_void;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::time::{Duration, Instant};

use objc2::encode::{Encode, Encoding};
use objc2::msg_send;
use objc2::rc::{Allocated, Retained, autoreleasepool};
use objc2::runtime::{AnyClass, AnyObject, Bool};

use super::sys::{CFRelease, CFTypeRef, CGDisplayBounds, CGMainDisplayID};
use crate::cursor::{CMUX_BLUE, CursorEvent, CursorSink, NoCursor, OUTLINE};
use crate::cursor_draw::{Draw, Track, glide};
use crate::desktop::Point;

/// The panel's side, in points.
pub const SIZE: f64 = 24.0;
/// The arrow's tip inside the panel (points from its top-left).
const TIP: Point = Point { x: 1.0, y: 1.0 };
const GLIDE: Duration = Duration::from_millis(180);
const FRAME: Duration = Duration::from_millis(16);
/// Pixels per point the arrow is drawn at (sharp on Retina, scaled on 1x).
const SCALE: f64 = 2.0;

/// The classic pointer outline in a 24-point box, y down, tip at (1, 1)
/// (the Linux overlay's arrow).
const ARROW: [(f64, f64); 7] =
    [(1.0, 1.0), (1.0, 19.0), (6.0, 14.5), (9.5, 22.0), (13.0, 20.5), (9.5, 13.5), (16.0, 13.5)];

static APP_RUNNING: AtomicBool = AtomicBool::new(false);

unsafe extern "C" {
    fn pthread_main_np() -> i32;
    static _dispatch_main_q: u8;
    fn dispatch_async_f(
        queue: *const c_void,
        context: *mut c_void,
        work: extern "C" fn(*mut c_void),
    );
}

#[link(name = "CoreGraphics", kind = "framework")]
unsafe extern "C" {
    fn CGColorSpaceCreateDeviceRGB() -> CFTypeRef;
    fn CGBitmapContextCreate(
        data: *mut c_void,
        width: usize,
        height: usize,
        bits_per_component: usize,
        bytes_per_row: usize,
        space: CFTypeRef,
        bitmap_info: u32,
    ) -> CFTypeRef;
    fn CGBitmapContextCreateImage(context: CFTypeRef) -> CFTypeRef;
    fn CGContextScaleCTM(context: CFTypeRef, sx: f64, sy: f64);
    fn CGContextBeginPath(context: CFTypeRef);
    fn CGContextMoveToPoint(context: CFTypeRef, x: f64, y: f64);
    fn CGContextAddLineToPoint(context: CFTypeRef, x: f64, y: f64);
    fn CGContextClosePath(context: CFTypeRef);
    fn CGContextSetRGBFillColor(context: CFTypeRef, r: f64, g: f64, b: f64, a: f64);
    fn CGContextSetRGBStrokeColor(context: CFTypeRef, r: f64, g: f64, b: f64, a: f64);
    fn CGContextSetLineWidth(context: CFTypeRef, width: f64);
    fn CGContextSetLineJoin(context: CFTypeRef, join: i32);
    fn CGContextDrawPath(context: CFTypeRef, mode: i32);
}

#[link(name = "QuartzCore", kind = "framework")]
unsafe extern "C" {}

/// NSPoint / CGPoint, for messages.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
struct NsPoint {
    x: f64,
    y: f64,
}

/// NSSize / CGSize, for messages.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
struct NsSize {
    width: f64,
    height: f64,
}

/// NSRect / CGRect, for messages.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
struct NsRect {
    origin: NsPoint,
    size: NsSize,
}

// SAFETY: the layouts above are CoreGraphics' (two doubles; a point and a size).
unsafe impl Encode for NsPoint {
    const ENCODING: Encoding = Encoding::Struct("CGPoint", &[f64::ENCODING, f64::ENCODING]);
}
// SAFETY: as above.
unsafe impl Encode for NsSize {
    const ENCODING: Encoding = Encoding::Struct("CGSize", &[f64::ENCODING, f64::ENCODING]);
}
// SAFETY: as above.
unsafe impl Encode for NsRect {
    const ENCODING: Encoding = Encoding::Struct("CGRect", &[NsPoint::ENCODING, NsSize::ENCODING]);
}

fn is_main_thread() -> bool {
    // SAFETY: plain libc call.
    unsafe { pthread_main_np() != 0 }
}

/// Runs `work` (the worker) with AppKit on the main thread, so the agent
/// cursor can be drawn, and returns `work`'s code once it returns: the
/// worker thread stops the application, and the main thread hands the code
/// back to its caller. Off the main thread it just runs `work`, with no
/// cursor.
pub fn run_with_app(work: impl FnOnce() -> i32 + Send + 'static) -> i32 {
    if !is_main_thread() {
        return work();
    }
    let Some(app) = shared_application() else {
        return work();
    };
    APP_RUNNING.store(true, Ordering::SeqCst);
    // A worker that panics still stops the application (the guard's drop), with code 101.
    WORKER_CODE.store(101, Ordering::SeqCst);
    let started = std::thread::Builder::new().name("cmux-cu-worker".into()).spawn(move || {
        let _stop = StopAppOnDrop;
        WORKER_CODE.store(work(), Ordering::SeqCst);
    });
    if started.is_err() {
        APP_RUNNING.store(false, Ordering::SeqCst);
        return 1;
    }
    // SAFETY: -[NSApplication run] on the main thread; it returns after `stop_app`.
    unsafe {
        let _: () = msg_send![&*app, run];
    }
    APP_RUNNING.store(false, Ordering::SeqCst);
    WORKER_CODE.load(Ordering::SeqCst)
}

static WORKER_CODE: AtomicI32 = AtomicI32::new(0);

/// Stops the application when the worker thread ends, however it ends.
struct StopAppOnDrop;

impl Drop for StopAppOnDrop {
    fn drop(&mut self) {
        // SAFETY: the main queue runs `stop_app` once, with no context.
        unsafe {
            dispatch_async_f((&raw const _dispatch_main_q).cast(), std::ptr::null_mut(), stop_app);
        }
    }
}

/// On the main queue: `-[NSApp stop:]`, then an application-defined event so
/// `run` sees the stop now (it checks after each event).
extern "C" fn stop_app(_: *mut c_void) {
    let Some(cls) = AnyClass::get(c"NSApplication") else { return };
    let Some(event_cls) = AnyClass::get(c"NSEvent") else { return };
    autoreleasepool(|_| {
        // SAFETY: AppKit on the main queue; the event is NSEventTypeApplicationDefined (15),
        // posted at the head of the queue.
        unsafe {
            let app: Option<Retained<AnyObject>> = msg_send![cls, sharedApplication];
            let Some(app) = app else { return };
            let none: *const AnyObject = std::ptr::null();
            let _: () = msg_send![&*app, stop: none];
            let event: Option<Retained<AnyObject>> = msg_send![
                event_cls,
                otherEventWithType: 15usize,
                location: NsPoint { x: 0.0, y: 0.0 },
                modifierFlags: 0usize,
                timestamp: 0.0f64,
                windowNumber: 0isize,
                context: none,
                subtype: 0i16,
                data1: 0isize,
                data2: 0isize
            ];
            if let Some(event) = event {
                let _: () = msg_send![&*app, postEvent: &*event, atStart: Bool::YES];
            }
        }
    });
}

/// `NSApplication.shared` with the accessory policy: no Dock icon, no menu
/// bar, never activated by us.
fn shared_application() -> Option<Retained<AnyObject>> {
    let cls = AnyClass::get(c"NSApplication")?;
    // SAFETY: +[NSApplication sharedApplication] and -setActivationPolicy: on the main thread.
    unsafe {
        let app: Option<Retained<AnyObject>> = msg_send![cls, sharedApplication];
        let app = app?;
        // NSApplicationActivationPolicyAccessory.
        let _: Bool = msg_send![&*app, setActivationPolicy: 1isize];
        Some(app)
    }
}

/// The macOS agent cursor, when AppKit runs ([`run_with_app`]).
pub fn cursor_overlay() -> Arc<dyn CursorSink> {
    if !APP_RUNNING.load(Ordering::SeqCst) {
        return Arc::new(NoCursor);
    }
    let (tx, rx) = mpsc::channel();
    match std::thread::Builder::new().name("cmux-cu-cursor".into()).spawn(move || glide_loop(rx)) {
        Ok(_) => Arc::new(Overlay(tx)),
        Err(_) => Arc::new(NoCursor),
    }
}

struct Overlay(Sender<CursorEvent>);

impl CursorSink for Overlay {
    fn show(&self, event: CursorEvent) {
        let _ = self.0.send(event);
    }
}

/// One change to the panel, run on the main queue.
#[derive(Clone, Copy, Debug, PartialEq)]
enum Op {
    /// Put the tip at this point (global desktop points, top-left origin) and show it.
    Show(Point),
    Hide,
}

/// Follows the events: a new point starts a glide from where the tip is now;
/// frames step it until it arrives.
fn glide_loop(rx: Receiver<CursorEvent>) {
    let mut track = Track::default();
    let mut tip: Option<Point> = None;
    let mut glide_from = Point::default();
    let mut glide_to: Option<(Point, Instant)> = None;
    loop {
        let wait = if glide_to.is_some() { FRAME } else { Duration::from_secs(3600) };
        match rx.recv_timeout(wait) {
            Ok(event) => match track.apply(&event) {
                Draw::Glide(at) => match tip {
                    // First show: appear at the point, no glide from nowhere.
                    None => {
                        tip = Some(at);
                        on_main(Op::Show(at));
                    }
                    Some(now) => {
                        glide_from = now;
                        glide_to = Some((at, Instant::now()));
                    }
                },
                Draw::Hide => {
                    tip = None;
                    glide_to = None;
                    on_main(Op::Hide);
                }
                Draw::Nothing => {}
            },
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => {
                on_main(Op::Hide);
                return;
            }
        }
        if let Some((to, start)) = glide_to {
            let t = start.elapsed().as_secs_f64() / GLIDE.as_secs_f64();
            let at = glide(glide_from, to, t);
            tip = Some(at);
            on_main(Op::Show(at));
            if t >= 1.0 {
                glide_to = None;
            }
        }
    }
}

fn on_main(op: Op) {
    extern "C" fn run(context: *mut c_void) {
        // SAFETY: the Box this was made from in on_main, run once.
        let op = unsafe { Box::from_raw(context.cast::<Op>()) };
        autoreleasepool(|_| apply(*op));
    }
    let context = Box::into_raw(Box::new(op)).cast::<c_void>();
    // SAFETY: the main queue lives for the process; `run` takes ownership of `context`.
    unsafe {
        dispatch_async_f((&raw const _dispatch_main_q).cast(), context, run);
    }
}

thread_local! {
    /// The panel (main thread only).
    static PANEL: RefCell<Option<Retained<AnyObject>>> = const { RefCell::new(None) };
}

/// The panel's origin (AppKit: bottom-left of the primary screen, y up) that
/// puts the arrow's tip at `tip` (global desktop points, y down).
fn panel_origin(tip: Point, primary_height: f64) -> (f64, f64) {
    (tip.x - TIP.x, primary_height - tip.y - (SIZE - TIP.y))
}

fn apply(op: Op) {
    PANEL.with(|cell| {
        let mut panel = cell.borrow_mut();
        match op {
            Op::Hide => {
                if let Some(p) = panel.as_deref() {
                    // SAFETY: -[NSWindow orderOut:] on the main thread.
                    unsafe {
                        let _: () = msg_send![p, orderOut: None::<&AnyObject>];
                    }
                }
            }
            Op::Show(tip) => {
                if panel.is_none() {
                    *panel = make_panel();
                }
                let Some(p) = panel.as_deref() else { return };
                // SAFETY: CGMainDisplayID and CGDisplayBounds are plain calls.
                let primary = unsafe { CGDisplayBounds(CGMainDisplayID()) }.size.height;
                let (x, y) = panel_origin(tip, primary);
                // SAFETY: -setFrameOrigin: and -orderFrontRegardless on the main thread; the
                // latter shows the panel without activating this app.
                unsafe {
                    let _: () = msg_send![p, setFrameOrigin: NsPoint { x, y }];
                    let _: () = msg_send![p, orderFrontRegardless];
                }
            }
        }
    });
}

fn make_panel() -> Option<Retained<AnyObject>> {
    let panel_class = AnyClass::get(c"NSPanel")?;
    let color_class = AnyClass::get(c"NSColor")?;
    let rect =
        NsRect { origin: NsPoint { x: 0.0, y: 0.0 }, size: NsSize { width: SIZE, height: SIZE } };
    // Borderless (0) | NSWindowStyleMaskNonactivatingPanel (1 << 7).
    let style: usize = 1 << 7;
    // SAFETY: NSPanel creation and setup with documented selectors, on the main thread.
    unsafe {
        let alloc: Allocated<AnyObject> = msg_send![panel_class, alloc];
        let panel: Option<Retained<AnyObject>> = msg_send![
            alloc,
            initWithContentRect: rect,
            styleMask: style,
            backing: 2usize,
            defer: Bool::NO
        ];
        let panel = panel?;
        let clear: Option<Retained<AnyObject>> = msg_send![color_class, clearColor];
        let _: () = msg_send![&*panel, setOpaque: Bool::NO];
        if let Some(clear) = clear.as_deref() {
            let _: () = msg_send![&*panel, setBackgroundColor: clear];
        }
        let _: () = msg_send![&*panel, setIgnoresMouseEvents: Bool::YES];
        let _: () = msg_send![&*panel, setHasShadow: Bool::NO];
        let _: () = msg_send![&*panel, setHidesOnDeactivate: Bool::NO];
        let _: () = msg_send![&*panel, setReleasedWhenClosed: Bool::NO];
        let _: () = msg_send![&*panel, setCanHide: Bool::NO];
        // NSScreenSaverWindowLevel: above menus and full-screen apps.
        let _: () = msg_send![&*panel, setLevel: 1000isize];
        // canJoinAllSpaces | stationary | ignoresCycle | fullScreenAuxiliary.
        let _: () = msg_send![&*panel, setCollectionBehavior: (1usize | 16 | 64 | 256)];
        let view: Option<Retained<AnyObject>> = msg_send![&*panel, contentView];
        if let Some(view) = view.as_deref() {
            let _: () = msg_send![view, setWantsLayer: Bool::YES];
            let layer: Option<Retained<AnyObject>> = msg_send![view, layer];
            if let (Some(layer), Some(image)) = (layer.as_deref(), arrow_image()) {
                // A CGImage is a CF object, which -setContents: takes as an id.
                let _: () = msg_send![layer, setContents: &*image.cast::<AnyObject>()];
                let _: () = msg_send![layer, setContentsScale: SCALE];
                CFRelease(image);
            }
        }
        Some(panel)
    }
}

/// The arrow as a +1 CGImage: cmux blue, a white outline.
fn arrow_image() -> Option<CFTypeRef> {
    let px = (SIZE * SCALE) as usize;
    // SAFETY: a fresh bitmap context we own and release; every call gets it live.
    unsafe {
        let space = CGColorSpaceCreateDeviceRGB();
        // kCGImageAlphaPremultipliedLast.
        let ctx = CGBitmapContextCreate(std::ptr::null_mut(), px, px, 8, 0, space, 1);
        CFRelease(space);
        if ctx.is_null() {
            return None;
        }
        CGContextScaleCTM(ctx, SCALE, SCALE);
        CGContextBeginPath(ctx);
        for (i, &(x, y)) in ARROW.iter().enumerate() {
            // The context is y up; ARROW is y down.
            let (x, y) = (x, SIZE - y);
            if i == 0 {
                CGContextMoveToPoint(ctx, x, y);
            } else {
                CGContextAddLineToPoint(ctx, x, y);
            }
        }
        CGContextClosePath(ctx);
        let [r, g, b] = CMUX_BLUE.map(|c| f64::from(c) / 255.0);
        CGContextSetRGBFillColor(ctx, r, g, b, 1.0);
        let [r, g, b] = OUTLINE.map(|c| f64::from(c) / 255.0);
        CGContextSetRGBStrokeColor(ctx, r, g, b, 1.0);
        CGContextSetLineWidth(ctx, 1.5);
        // kCGLineJoinRound.
        CGContextSetLineJoin(ctx, 1);
        // kCGPathFillStroke.
        CGContextDrawPath(ctx, 3);
        let image = CGBitmapContextCreateImage(ctx);
        CFRelease(ctx);
        (!image.is_null()).then_some(image)
    }
}

#[cfg(test)]
pub(super) fn tip_origin_for_tests(tip: Point, primary_height: f64) -> (f64, f64) {
    panel_origin(tip, primary_height)
}
