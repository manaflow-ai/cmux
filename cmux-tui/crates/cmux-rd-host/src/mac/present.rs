//! `cmux-rd bench --present window` (macOS): shows every decoded frame in an on-screen window
//! and sends the keys typed into that window to the host, so `cmux-rd observe` can time a key
//! press to the frame the viewer Mac's compositor shows (screen-stream-eval's `rd-present`).
//!
//! This is not the cmux app's Mac Screen pane. It is the bench viewer (the same `cmux.rd/1`
//! transport and the VideoToolbox decode the pane uses) presenting the way the pane's layer
//! presenter does (`LayerContentsPresenter`, its fallback): the decoded IOSurface becomes a
//! layer's contents with no copy, and the window server converts colour. The pane's default
//! presenter draws with Metal instead; the frame reaches the compositor the same way.
//!
//! Everything runs on the bench's own thread, which is the process's main thread: the bench
//! loop pumps AppKit's event queue between network waits (`take_keys`), and each frame commits
//! and flushes its own Core Animation transaction, so nothing waits for a run loop turn.

use super::sys::{self, cg, cv, msg, sel, send_id, CGPoint, CGRect, CGSize, Id, Sel};
use crate::Res;
use cmux_encode::framework;
use std::ffi::CStr;

framework! {
    mod appkit = "/System/Library/Frameworks/AppKit.framework/AppKit" {
        ref NSAppKitVersionNumber: f64;
    }
}

framework! {
    mod quartz = "/System/Library/Frameworks/QuartzCore.framework/QuartzCore" {
        static kCAGravityResize: sys::CFStringRef;
    }
}

framework! {
    mod foundation_modes = "/System/Library/Frameworks/Foundation.framework/Foundation" {
        static NSDefaultRunLoopMode: Id;
    }
}

/// NSEventTypeKeyDown and NSEventTypeKeyUp.
const KEY_DOWN: u64 = 10;
const KEY_UP: u64 = 11;
/// NSWindowStyleMaskTitled | Closable | Miniaturizable.
const STYLE: u64 = 1 | 2 | 4;
/// NSBackingStoreBuffered.
const BUFFERED: u64 = 2;
/// The title bar and menu bar the window leaves room for, in points.
const CHROME_PT: f64 = 64.0;

fn class(name: &CStr) -> Res<Id> {
    let class = sys::class(name);
    if class.is_null() {
        return Err(format!("--present window: no class {}", name.to_string_lossy()).into());
    }
    Ok(class)
}

/// `[receiver name:flag]` for a BOOL argument.
fn send_bool(receiver: Id, name: &CStr, flag: bool) {
    // SAFETY: a one-BOOL-argument method returning nothing.
    unsafe { msg::<unsafe extern "C" fn(Id, Sel, u8)>()(receiver, sel(name), u8::from(flag)) }
}

/// `[receiver name]` for a method returning nothing.
fn send_void(receiver: Id, name: &CStr) {
    // SAFETY: a no-argument method returning nothing.
    unsafe { msg::<unsafe extern "C" fn(Id, Sel)>()(receiver, sel(name)) }
}

/// `[receiver name:object]`.
fn send_obj(receiver: Id, name: &CStr, object: Id) {
    // SAFETY: a one-object-argument method returning nothing.
    unsafe { msg::<unsafe extern "C" fn(Id, Sel, Id)>()(receiver, sel(name), object) }
}

pub struct Presenter {
    app: Id,
    window: Id,
    layer: Id,
    /// The content view's size in points.
    content: CGSize,
    frame_pixels: (usize, usize),
    /// The picture on screen, held so its buffer is not reused while the layer shows it.
    shown: Option<crate::vtdecode::Picture>,
    pub presented: u64,
}

impl Presenter {
    /// Opens the window on the main display, frontmost, with the keyboard focus. `title` names
    /// it for the harness, which finds it by owner pid.
    pub fn open(title: &str) -> Res<Self> {
        sys::load()?;
        appkit::available()?;
        quartz::available()?;
        foundation_modes::available()?;
        // SAFETY: AppKit calls with their documented signatures, on the main thread (the
        // bench runs on the process's main thread).
        unsafe {
            let app = send_id(class(c"NSApplication")?, c"sharedApplication");
            // NSApplicationActivationPolicyRegular: a normal app with windows and focus.
            msg::<unsafe extern "C" fn(Id, Sel, i64) -> u8>()(app, sel(c"setActivationPolicy:"), 0);
            send_void(app, c"finishLaunching");
            let display = cg::CGDisplayBounds(cg::CGMainDisplayID());
            let content = CGSize {
                width: display.size.width,
                height: (display.size.height - CHROME_PT).max(200.0),
            };
            let rect = CGRect { origin: CGPoint::new(0.0, 0.0), size: content };
            let window = send_id(class(c"NSWindow")?, c"alloc");
            let window = msg::<unsafe extern "C" fn(Id, Sel, CGRect, u64, u64, u8) -> Id>()(
                window,
                sel(c"initWithContentRect:styleMask:backing:defer:"),
                rect,
                STYLE,
                BUFFERED,
                0,
            );
            if window.is_null() {
                return Err("--present window: NSWindow did not open".into());
            }
            send_bool(window, c"setReleasedWhenClosed:", false);
            let text = std::ffi::CString::new(title)?;
            let title = msg::<unsafe extern "C" fn(Id, Sel, *const i8) -> Id>()(
                class(c"NSString")?,
                sel(c"stringWithUTF8String:"),
                text.as_ptr(),
            );
            send_obj(window, c"setTitle:", title);
            let black = send_id(class(c"NSColor")?, c"blackColor");
            send_obj(window, c"setBackgroundColor:", black);
            let view = send_id(window, c"contentView");
            send_bool(view, c"setWantsLayer:", true);
            let root = send_id(view, c"layer");
            let layer = send_id(class(c"CALayer")?, c"layer");
            // Retained: the layer outlives this autorelease scope.
            send_id(layer, c"retain");
            send_obj(layer, c"setContentsGravity:", quartz::kCAGravityResize() as Id);
            send_obj(root, c"addSublayer:", layer);
            send_obj(window, c"makeKeyAndOrderFront:", std::ptr::null_mut());
            send_bool(app, c"activateIgnoringOtherApps:", true);
            let mut presenter = Self {
                app,
                window,
                layer,
                content,
                frame_pixels: (0, 0),
                shown: None,
                presented: 0,
            };
            // Let the window server map the window before the first frame.
            presenter.take_keys();
            Ok(presenter)
        }
    }

    /// The window's CGWindowID (`windowNumber`).
    pub fn window_number(&self) -> i64 {
        // SAFETY: -windowNumber returns NSInteger.
        unsafe { msg::<unsafe extern "C" fn(Id, Sel) -> i64>()(self.window, sel(c"windowNumber")) }
    }

    /// Shows `picture` and commits it to the window server before returning.
    pub fn show(&mut self, picture: &crate::vtdecode::Picture) {
        let size = picture.size();
        // SAFETY: Core Animation calls with their documented signatures on the main thread;
        // the IOSurface belongs to the retained pixel buffer kept in `shown`.
        unsafe {
            let transaction = sys::class(c"CATransaction");
            send_void(transaction, c"begin");
            send_bool(transaction, c"setDisableActions:", true);
            if size != self.frame_pixels {
                self.frame_pixels = size;
                // Fit the stream into the content view, keeping its aspect (the pane's `.fit`).
                let (w, h) = (size.0 as f64, size.1 as f64);
                let scale = (self.content.width / w).min(self.content.height / h);
                let fitted = CGSize { width: w * scale, height: h * scale };
                let frame = CGRect {
                    origin: CGPoint::new(
                        (self.content.width - fitted.width) / 2.0,
                        (self.content.height - fitted.height) / 2.0,
                    ),
                    size: fitted,
                };
                msg::<unsafe extern "C" fn(Id, Sel, CGRect)>()(
                    self.layer,
                    sel(c"setFrame:"),
                    frame,
                );
            }
            let surface = cv::CVPixelBufferGetIOSurface(picture.pixel_buffer());
            send_obj(self.layer, c"setContents:", surface as Id);
            send_void(transaction, c"commit");
            send_void(transaction, c"flush");
        }
        self.shown = Some(picture.clone());
        self.presented += 1;
    }

    /// Drains AppKit's event queue: key presses and releases on the window come back as
    /// (macOS virtual key code, down); every other event goes to AppKit as usual.
    pub fn take_keys(&mut self) -> Vec<(u16, bool)> {
        let mut keys = Vec::new();
        // SAFETY: NSApplication event calls with their documented signatures, main thread.
        unsafe {
            let past = send_id(sys::class(c"NSDate"), c"distantPast");
            loop {
                let event = msg::<unsafe extern "C" fn(Id, Sel, u64, Id, Id, u8) -> Id>()(
                    self.app,
                    sel(c"nextEventMatchingMask:untilDate:inMode:dequeue:"),
                    u64::MAX,
                    past,
                    foundation_modes::NSDefaultRunLoopMode(),
                    1,
                );
                if event.is_null() {
                    break;
                }
                let kind = msg::<unsafe extern "C" fn(Id, Sel) -> u64>()(event, sel(c"type"));
                if kind == KEY_DOWN || kind == KEY_UP {
                    let repeat = kind == KEY_DOWN
                        && msg::<unsafe extern "C" fn(Id, Sel) -> u8>()(event, sel(c"isARepeat"))
                            != 0;
                    if !repeat {
                        let code =
                            msg::<unsafe extern "C" fn(Id, Sel) -> u16>()(event, sel(c"keyCode"));
                        keys.push((code, kind == KEY_DOWN));
                    }
                    // Not passed on: the window has no text view, and AppKit would beep.
                    continue;
                }
                send_obj(self.app, c"sendEvent:", event);
            }
        }
        keys
    }
}

impl Drop for Presenter {
    fn drop(&mut self) {
        // SAFETY: objects this presenter created and retained, on the main thread.
        unsafe {
            send_void(self.window, c"close");
            sys::release(self.window);
            sys::release(self.layer);
        }
    }
}

/// A macOS virtual key code to its HID usage: the inverse of the host's `keys::key_code`.
pub fn key_to_hid(code: u16) -> Option<u32> {
    (0x04..=0xe7u32)
        .map(|id| 0x0007_0000 | id)
        .find(|&usage| super::keys::key_code(usage) == Some(code))
}
