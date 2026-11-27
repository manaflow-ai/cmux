//! Sharing one macOS window: the windows a viewer may pick (ScreenCaptureKit's shareable
//! windows: on screen, the normal layer, titled, not cmux's own), a window's frame in global
//! points read from the window server, the pixel size its stream gets, and a watcher that
//! reads the frame again while it is shared. ScreenCaptureKit captures the window itself
//! (`SCContentFilter initWithDesktopIndependentWindow:`), so a window over it never shows and a
//! move needs no new capture; only the pointer mapping follows the move. A resize or a close
//! ends the session with its reason, as on Linux (`x11_window.rs`).

use super::capture::{fit, native_size, Bounds};
use super::sys::{self, cf, cg, msg, sel, CGPoint, CGRect, Id, Sel};
use std::sync::mpsc::{sync_channel, RecvTimeoutError, SyncSender};
use std::thread::JoinHandle;
use std::time::Duration;

/// How often a shared window's frame is read again.
const WATCH_EVERY: Duration = Duration::from_millis(100);
/// Frames closer than this, in points, are the same (the window server reports whole points,
/// a scaled display halves).
const SAME_POINTS: f64 = 0.5;
/// Bundle identifiers of cmux's own apps; their windows are never offered.
const OWN_BUNDLE_PREFIX: &str = "com.cmuxterm.";

/// One window a viewer may pick: its CGWindowID, title, and the size its stream gets.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WindowInfo {
    pub id: u32,
    pub title: String,
    pub size: (u32, u32),
}

/// What the lister read about one of ScreenCaptureKit's shareable windows.
#[derive(Clone, Debug, PartialEq)]
pub struct Candidate {
    pub id: u32,
    pub title: Option<String>,
    /// The window server's layer; 0 is the normal layer (not the menu bar, Dock or overlays).
    pub layer: i64,
    pub on_screen: bool,
    pub pid: i32,
    pub bundle: Option<String>,
}

/// Whether a viewer may pick `c`: on screen, the normal layer, titled, and not one of this
/// process's or cmux's own windows (`own_pids`: this process and its parent, the app that ran it).
pub fn offered(c: &Candidate, own_pids: &[i32]) -> bool {
    c.on_screen
        && c.layer == 0
        && c.title.as_deref().is_some_and(|t| !t.trim().is_empty())
        && !own_pids.contains(&c.pid)
        && !c.bundle.as_deref().is_some_and(|b| b.starts_with(OWN_BUNDLE_PREFIX))
}

/// A window's frame as the window server reports it.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Frame {
    /// Global points, top left origin (CGEvent coordinates).
    pub bounds: Bounds,
    /// False while it is minimized, hidden or on another Space.
    pub on_screen: bool,
}

/// The pixel size a window of `bounds` streams at on a display of `scale` pixels per point,
/// fitted to the decoder and `max_width`; None below 2x2 pixels.
pub fn pixel_size(bounds: Bounds, scale: f64, max_width: Option<u32>) -> Option<(u32, u32)> {
    let w = (bounds.width * scale).round();
    let h = (bounds.height * scale).round();
    if !w.is_finite() || !h.is_finite() || w < 2.0 || h < 2.0 {
        return None;
    }
    let size = fit(w as u32, h as u32, max_width);
    (size.0 >= 2 && size.1 >= 2).then_some(size)
}

/// What a shared window's frame, read again, means for the session.
#[derive(Clone, Debug, PartialEq)]
pub enum Change {
    Same,
    /// Moved (same size): the pointer maps through the new frame.
    Moved(Bounds),
    /// Another size, in points: a session's picture size is fixed when it starts.
    Resized {
        from: (u32, u32),
        to: (u32, u32),
    },
    /// The window server no longer knows the window.
    Closed,
}

/// `now` against the frame the share started with (`start`, whose size is the stream's) and
/// the last one seen (`last`).
pub fn follow(start: Bounds, last: Bounds, now: Option<Frame>) -> Change {
    let Some(now) = now else { return Change::Closed };
    let b = now.bounds;
    if (b.width - start.width).abs() > SAME_POINTS || (b.height - start.height).abs() > SAME_POINTS
    {
        let points = |b: Bounds| (b.width.round() as u32, b.height.round() as u32);
        return Change::Resized { from: points(start), to: points(b) };
    }
    if (b.x - last.x).abs() > SAME_POINTS || (b.y - last.y).abs() > SAME_POINTS {
        return Change::Moved(Bounds { width: start.width, height: start.height, ..b });
    }
    Change::Same
}

/// The session-ending sentence for a change, or None when the session goes on.
pub fn end_reason(id: u32, change: &Change) -> Option<String> {
    match change {
        Change::Closed => Some(format!("the shared window {id} was closed")),
        Change::Resized { from, to } => Some(format!(
            "the shared window {id} was resized from {}x{} to {}x{} points; share it again \
             (a session's picture size is fixed when it starts)",
            from.0, from.1, to.0, to.1
        )),
        Change::Same | Change::Moved(_) => None,
    }
}

/// The window server's frame of window `id`; None when it no longer exists.
pub fn frame(id: u32) -> Option<Frame> {
    // SAFETY: CGWindowListCopyWindowInfo returns a +1 array (or NULL) released below; its
    // dictionaries and values are borrowed from it until then.
    unsafe {
        let list = cg::CGWindowListCopyWindowInfo(sys::WINDOW_LIST_INCLUDING_WINDOW, id);
        if list.is_null() {
            return None;
        }
        let mut found = None;
        if cf::CFArrayGetCount(list) > 0 {
            let info = cf::CFArrayGetValueAtIndex(list, 0);
            let bounds = cf::CFDictionaryGetValue(info, cg::kCGWindowBounds());
            let mut rect = CGRect::default();
            if !bounds.is_null()
                && cg::CGRectMakeWithDictionaryRepresentation(bounds, &raw mut rect) != 0
            {
                let on_screen = cf::CFDictionaryGetValue(info, cg::kCGWindowIsOnscreen());
                found = Some(Frame {
                    bounds: Bounds {
                        x: rect.origin.x,
                        y: rect.origin.y,
                        width: rect.size.width,
                        height: rect.size.height,
                    },
                    on_screen: !on_screen.is_null() && cf::CFBooleanGetValue(on_screen) != 0,
                });
            }
        }
        cf::CFRelease(list);
        found
    }
}

/// Pixels per point of the display under the middle of `bounds` (the main display when no
/// display is there): its native pixel width over its width in points.
pub fn display_scale(bounds: Bounds) -> f64 {
    let middle = CGPoint::new(bounds.x + bounds.width / 2.0, bounds.y + bounds.height / 2.0);
    let mut display = 0u32;
    let mut count = 0u32;
    // SAFETY: room for one display id and the count.
    let found = unsafe { cg::CGGetDisplaysWithPoint(middle, 1, &raw mut display, &raw mut count) };
    if found != 0 || count == 0 {
        // SAFETY: CGMainDisplayID has no preconditions.
        display = unsafe { cg::CGMainDisplayID() };
    }
    // SAFETY: a display id.
    let points = unsafe { cg::CGDisplayBounds(display) }.size.width;
    let pixels = f64::from(native_size(display).0);
    if points >= 1.0 && pixels >= 1.0 {
        pixels / points
    } else {
        1.0
    }
}

/// This process and the app that started it: their windows are never offered.
fn own_pids() -> [i32; 2] {
    // SAFETY: getpid and getppid have no preconditions.
    unsafe { [libc::getpid(), libc::getppid()] }
}

/// The SCWindow objects of a shareable content object, borrowed from it.
pub fn content_windows(content: Id) -> Vec<Id> {
    let list = sys::send_id(content, c"windows");
    if list.is_null() {
        return Vec::new();
    }
    // SAFETY: -[NSArray count] and -objectAtIndex: below count.
    unsafe {
        let count = msg::<unsafe extern "C" fn(Id, Sel) -> usize>()(list, sel(c"count"));
        (0..count)
            .map(|i| {
                msg::<unsafe extern "C" fn(Id, Sel, usize) -> Id>()(list, sel(c"objectAtIndex:"), i)
            })
            .filter(|w| !w.is_null())
            .collect()
    }
}

/// An SCWindow's CGWindowID.
pub fn window_id(window: Id) -> u32 {
    // SAFETY: -[SCWindow windowID] returns a CGWindowID.
    unsafe { msg::<unsafe extern "C" fn(Id, Sel) -> u32>()(window, sel(c"windowID")) }
}

fn candidate(window: Id) -> Candidate {
    // SAFETY: SCWindow's windowLayer (NSInteger) and onScreen (BOOL) getters, and
    // SCRunningApplication's processID (pid_t).
    unsafe {
        let layer =
            msg::<unsafe extern "C" fn(Id, Sel) -> isize>()(window, sel(c"windowLayer")) as i64;
        let on_screen = msg::<unsafe extern "C" fn(Id, Sel) -> bool>()(window, sel(c"isOnScreen"));
        let title = sys::send_id(window, c"title");
        let app = sys::send_id(window, c"owningApplication");
        let (pid, bundle) = if app.is_null() {
            (0, None)
        } else {
            let pid = msg::<unsafe extern "C" fn(Id, Sel) -> i32>()(app, sel(c"processID"));
            let bundle = sys::send_id(app, c"bundleIdentifier");
            (pid, (!bundle.is_null()).then(|| sys::string(bundle)))
        };
        Candidate {
            id: window_id(window),
            title: (!title.is_null()).then(|| sys::string(title)),
            layer,
            on_screen,
            pid,
            bundle,
        }
    }
}

/// The windows a viewer may pick, front to back (ScreenCaptureKit's order), with the size each
/// one streams at (no `max_width`, as the display list reports displays).
pub fn list() -> crate::Res<Vec<WindowInfo>> {
    let content = super::capture::shareable_content()?;
    let own = own_pids();
    let windows = {
        let _pool = sys::AutoreleasePool::new();
        content_windows(content)
            .into_iter()
            .map(candidate)
            .filter(|c| offered(c, &own))
            .filter_map(|c| {
                let frame = frame(c.id)?;
                let size = pixel_size(frame.bounds, display_scale(frame.bounds), None)?;
                Some(WindowInfo { id: c.id, title: c.title.unwrap_or_default(), size })
            })
            .collect()
    };
    sys::release(content);
    Ok(windows)
}

/// Reads a shared window's frame every [`WATCH_EVERY`] and reports each change other than
/// [`Change::Same`]; after a close or resize it stops. Dropping it stops the thread.
pub struct Watch {
    stop: Option<SyncSender<()>>,
    thread: Option<JoinHandle<()>>,
}

impl Watch {
    pub fn start(id: u32, start: Bounds, mut report: impl FnMut(Change) + Send + 'static) -> Self {
        let (stop, stopped) = sync_channel::<()>(1);
        let thread = std::thread::Builder::new()
            .name("cmux-rd-window-watch".into())
            .spawn(move || {
                let mut last = start;
                loop {
                    match stopped.recv_timeout(WATCH_EVERY) {
                        Err(RecvTimeoutError::Timeout) => {}
                        _ => return,
                    }
                    let change = follow(start, last, frame(id));
                    match change {
                        Change::Same => continue,
                        Change::Moved(b) => last = b,
                        Change::Resized { .. } | Change::Closed => {
                            report(change);
                            return;
                        }
                    }
                    report(change);
                }
            })
            .ok();
        Self { stop: Some(stop), thread }
    }
}

impl Drop for Watch {
    fn drop(&mut self) {
        drop(self.stop.take());
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

/// `[[SCContentFilter alloc] initWithDesktopIndependentWindow:window]`, +1 (or nil).
pub fn window_filter(window: Id) -> Id {
    // SAFETY: alloc then the documented initializer taking one SCWindow.
    unsafe {
        msg::<unsafe extern "C" fn(Id, Sel, Id) -> Id>()(
            sys::send_id(sys::class(c"SCContentFilter"), c"alloc"),
            sel(c"initWithDesktopIndependentWindow:"),
            window,
        )
    }
}

/// Whether `object` answers `selector` (a newer macOS's property).
pub fn responds(object: Id, selector: &std::ffi::CStr) -> bool {
    // SAFETY: -[NSObject respondsToSelector:].
    unsafe {
        msg::<unsafe extern "C" fn(Id, Sel, Sel) -> bool>()(
            object,
            sel(c"respondsToSelector:"),
            sel(selector),
        )
    }
}

/// The window a session shares: the setup's `window` (serve, `--window ID`), else
/// `--display window:ID` (the screen stream eval's rd-window target), else none (a display).
pub fn session_window(window: Option<u32>, display: &str) -> crate::Res<Option<u32>> {
    Ok(match (window, display.strip_prefix("window:")) {
        (Some(id), _) => Some(id),
        (None, Some(id)) => Some(crate::host::parse_window_id(id)?),
        (None, None) => None,
    })
}

#[cfg(test)]
#[path = "window_tests.rs"]
mod tests;
