//! An app's accessibility signals while an action runs and settles
//! ([`crate::desktop::Signals`]): an AXObserver on the application element,
//! on its own thread and run loop mode, for the notifications that say the app
//! changed something (a value, a title, a selection, focus, a window or sheet,
//! a menu). Each signal is counted in the target window or elsewhere (another
//! window, a menu, a popover, the app itself), so an effect outside the
//! window's pixels and elements is seen too.

use std::ffi::c_void;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use super::ax::Ax;
use super::sys::*;
use crate::desktop::{Signals, Watch};

/// The notifications watched, registered on the application element (which
/// delivers them for every element of the app).
const NOTIFICATIONS: &[&str] = &[
    "AXValueChanged",
    "AXTitleChanged",
    "AXSelectedTextChanged",
    "AXSelectedRowsChanged",
    "AXSelectedChildrenChanged",
    "AXSelectedCellsChanged",
    "AXFocusedUIElementChanged",
    "AXFocusedWindowChanged",
    "AXWindowCreated",
    "AXSheetCreated",
    "AXDrawerCreated",
    "AXMenuOpened",
    "AXMenuClosed",
    "AXMenuItemSelected",
    "AXCreated",
    "AXUIElementDestroyed",
    "AXRowCountChanged",
    "AXLayoutChanged",
];

/// What the callback writes to (its refcon).
struct Sink {
    signals: Arc<Mutex<Signals>>,
    target: u32,
    start: Instant,
}

unsafe extern "C" fn on_signal(
    _observer: CFTypeRef,
    element: CFTypeRef,
    notification: CFTypeRef,
    refcon: *mut c_void,
) {
    if refcon.is_null() {
        return;
    }
    // SAFETY: refcon is the Sink the watching thread owns for as long as the
    // observer is registered.
    let sink = unsafe { &*(refcon as *const Sink) };
    let name = Cf::retained(notification).and_then(|c| c.as_string()).unwrap_or_default();
    // The element's window: the element itself when it is one, else its
    // AXWindow (menus, the app and elements already gone have none).
    let window = Cf::retained(element).and_then(Ax::from_cf).and_then(|el| {
        el.set_timeout(0.1);
        el.window_id().or_else(|| el.element("AXWindow").and_then(|w| w.window_id()))
    });
    let mut s = sink.signals.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    if window == Some(sink.target) {
        s.in_window += 1;
    } else {
        s.elsewhere += 1;
    }
    *s.kinds.entry(name).or_insert(0) += 1;
    s.last_ms = Some(sink.start.elapsed().as_millis() as u64);
}

/// A running watch (see the module notes).
pub(super) struct AxWatch {
    signals: Arc<Mutex<Signals>>,
    stop: Arc<AtomicBool>,
    listening: bool,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl AxWatch {
    /// Starts watching `pid`'s app; signals from window `target` count as in
    /// the window. Returns once the observer is registered (or failed).
    pub(super) fn start(pid: i32, target: u32) -> AxWatch {
        let signals = Arc::new(Mutex::new(Signals::default()));
        let stop = Arc::new(AtomicBool::new(false));
        let (ready_tx, ready_rx) = std::sync::mpsc::channel::<bool>();
        let (sig, stp) = (signals.clone(), stop.clone());
        let thread = std::thread::Builder::new()
            .name("cu-ax-watch".into())
            .spawn(move || run(pid, target, sig, stp, ready_tx))
            .ok();
        let listening =
            thread.is_some() && ready_rx.recv_timeout(Duration::from_millis(500)).unwrap_or(false);
        AxWatch { signals, stop, listening, thread }
    }
}

fn run(
    pid: i32,
    target: u32,
    signals: Arc<Mutex<Signals>>,
    stop: Arc<AtomicBool>,
    ready: std::sync::mpsc::Sender<bool>,
) {
    let sink = Box::new(Sink { signals, target, start: Instant::now() });
    let refcon = &*sink as *const Sink as *mut c_void;
    let (Some(app), Some(mode)) = (Ax::application(pid), Cf::string("com.cmuxterm.cu.watch"))
    else {
        let _ = ready.send(false);
        return;
    };
    app.set_timeout(0.25);
    let mut raw: CFTypeRef = std::ptr::null();
    // SAFETY: out-parameter; a +1 observer on success.
    if unsafe { AXObserverCreate(pid, on_signal, &mut raw) } != AX_OK {
        let _ = ready.send(false);
        return;
    }
    let Some(observer) = Cf::created(raw) else {
        let _ = ready.send(false);
        return;
    };
    let names: Vec<Cf> = NOTIFICATIONS.iter().filter_map(|n| Cf::string(n)).collect();
    let mut added = Vec::new();
    for note in &names {
        // SAFETY: live observer, element and string; refcon outlives the
        // registration (removed below before the sink is dropped).
        if unsafe { AXObserverAddNotification(observer.ptr(), app.ptr(), note.ptr(), refcon) }
            == AX_OK
        {
            added.push(note);
        }
    }
    // SAFETY: a borrowed source of the live observer.
    let source = unsafe { AXObserverGetRunLoopSource(observer.ptr()) };
    // SAFETY: this thread's run loop (borrowed).
    let run_loop = unsafe { CFRunLoopGetCurrent() };
    let ok = !added.is_empty() && !source.is_null();
    if ok {
        // SAFETY: live run loop, source and mode.
        unsafe { CFRunLoopAddSource(run_loop, source, mode.ptr()) };
    }
    let _ = ready.send(ok);
    while ok && !stop.load(Ordering::Acquire) {
        // SAFETY: runs this thread's loop in the private mode for a slice.
        unsafe { CFRunLoopRunInMode(mode.ptr(), 0.05, 0) };
    }
    if ok {
        // SAFETY: as above.
        unsafe { CFRunLoopRemoveSource(run_loop, source, mode.ptr()) };
    }
    for note in added {
        // SAFETY: as above.
        unsafe { AXObserverRemoveNotification(observer.ptr(), app.ptr(), note.ptr()) };
    }
    drop(observer);
    drop(sink);
}

impl Watch for AxWatch {
    fn signals(&self) -> Signals {
        self.signals.lock().unwrap_or_else(std::sync::PoisonError::into_inner).clone()
    }
    fn listening(&self) -> bool {
        self.listening
    }
}

impl Drop for AxWatch {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}
