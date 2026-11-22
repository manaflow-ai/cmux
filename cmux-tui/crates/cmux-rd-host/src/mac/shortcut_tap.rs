//! The session event tap of `cmux-screen-sharing __shortcut-tap` (src/shortcut_tap.rs): created
//! once at start (macOS refuses it without the helper's Accessibility), enabled only while the app
//! holds, and run on this process's main run loop. The callback decides from [`Policy`] alone and
//! never blocks: a taken key goes to a writer thread, which writes it to stdout. A stdin thread
//! applies the app's lines and enables or disables the tap; its end of file ends the run loop, and
//! with it the process. Both threads belong to one `std::thread::scope`, joined before `run` returns.

use crate::shortcut_tap::{key_line, parse_control, Key, Policy};
use cmux_encode::framework;
use std::ffi::c_void;
use std::io::{BufRead, Write};
use std::sync::atomic::{AtomicBool, AtomicPtr, Ordering};
use std::sync::mpsc::{self, Sender};
use std::sync::Mutex;

type CFTypeRef = *const c_void;
type CGEventRef = *mut c_void;

/// kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault (an active filter).
const SESSION_TAP: u32 = 1;
const HEAD_INSERT: u32 = 0;
const OPTION_DEFAULT: u32 = 0;
/// CGEventType values.
const KEY_DOWN: u32 = 10;
const KEY_UP: u32 = 11;
const TAP_DISABLED_BY_TIMEOUT: u32 = 0xFFFF_FFFE;
const TAP_DISABLED_BY_USER_INPUT: u32 = 0xFFFF_FFFF;
/// CGEventField values.
const FIELD_AUTOREPEAT: u32 = 8;
const FIELD_KEYCODE: u32 = 9;
/// The longest one run loop turn waits before it checks whether stdin ended.
const RUN_TURN_S: f64 = 1.0;

type TapCallback = unsafe extern "C" fn(*mut c_void, u32, CGEventRef, *mut c_void) -> CGEventRef;

framework! {
    mod cg = "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics" {
        fn CGEventTapCreate(tap: u32, place: u32, options: u32, mask: u64, callback: TapCallback, info: *mut c_void) -> CFTypeRef;
        fn CGEventTapEnable(tap: CFTypeRef, enable: bool);
        fn CGEventGetIntegerValueField(event: CGEventRef, field: u32) -> i64;
        fn CGEventGetFlags(event: CGEventRef) -> u64;
    }
}

framework! {
    mod cf = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation" {
        static kCFRunLoopCommonModes: CFTypeRef;
        static kCFRunLoopDefaultMode: CFTypeRef;
        fn CFMachPortCreateRunLoopSource(allocator: CFTypeRef, port: CFTypeRef, order: isize) -> CFTypeRef;
        fn CFRunLoopGetCurrent() -> CFTypeRef;
        fn CFRunLoopAddSource(run_loop: CFTypeRef, source: CFTypeRef, mode: CFTypeRef);
        fn CFRunLoopRunInMode(mode: CFTypeRef, seconds: f64, return_after_source_handled: u8) -> i32;
    }
}

/// What the callback and the stdin thread share; leaked for the process's life.
struct Shared {
    policy: Mutex<Policy>,
    /// The tap's mach port (set once, before the run loop starts).
    port: AtomicPtr<c_void>,
    /// Taken keys to the writer thread; None once stdin ended (the writer then ends).
    keys: Mutex<Option<Sender<Key>>>,
    /// Stdin ended: the run loop stops.
    done: AtomicBool,
}

impl Shared {
    fn enable(&self, on: bool) {
        let port = self.port.load(Ordering::Acquire);
        if !port.is_null() {
            // SAFETY: the tap's live mach port, never released (the process ends with it).
            unsafe { cg::CGEventTapEnable(port, on) };
        }
    }
}

unsafe extern "C" fn callback(
    _proxy: *mut c_void,
    kind: u32,
    event: CGEventRef,
    info: *mut c_void,
) -> CGEventRef {
    // SAFETY: `info` is the leaked `Shared` this tap was created with.
    let shared = unsafe { &*(info as *const Shared) };
    match kind {
        TAP_DISABLED_BY_TIMEOUT | TAP_DISABLED_BY_USER_INPUT => {
            // macOS turned the tap off: on again while the app holds.
            let holding = shared.policy.lock().map(|p| p.holding()).unwrap_or(false);
            if holding {
                shared.enable(true);
            }
            return event;
        }
        KEY_DOWN | KEY_UP => {}
        _ => return event,
    }
    // SAFETY: a live keyboard event macOS handed to this callback.
    let key = unsafe {
        Key {
            key_code: cg::CGEventGetIntegerValueField(event, FIELD_KEYCODE) as u16,
            modifiers: cg::CGEventGetFlags(event),
            down: kind == KEY_DOWN,
            repeat: cg::CGEventGetIntegerValueField(event, FIELD_AUTOREPEAT) != 0,
        }
    };
    let taken = shared.policy.lock().map(|mut p| p.key(key)).unwrap_or(false);
    if !taken {
        return event;
    }
    if let Some(keys) = shared.keys.lock().ok().as_ref().and_then(|keys| keys.as_ref()) {
        let _ = keys.send(Key { modifiers: key.modifiers & crate::shortcut_tap::MODIFIERS, ..key });
    }
    std::ptr::null_mut()
}

fn say(line: &str) {
    let mut out = std::io::stdout().lock();
    let _ = out.write_all(line.as_bytes()).and_then(|()| out.flush());
}

pub(crate) fn run() -> i32 {
    if let Err(e) = cg::available().and_then(|()| cf::available()) {
        say(&format!("{}\n", serde_json::json!({ "error": e })));
        return 1;
    }
    let (sender, receiver) = mpsc::channel::<Key>();
    let shared: &'static Shared = Box::leak(Box::new(Shared {
        policy: Mutex::new(Policy::default()),
        port: AtomicPtr::new(std::ptr::null_mut()),
        keys: Mutex::new(Some(sender)),
        done: AtomicBool::new(false),
    }));
    let mask = (1u64 << KEY_DOWN) | (1u64 << KEY_UP);
    // SAFETY: resolved above; `shared` lives for the process.
    let port = unsafe {
        cg::CGEventTapCreate(
            SESSION_TAP,
            HEAD_INSERT,
            OPTION_DEFAULT,
            mask,
            callback,
            shared as *const Shared as *mut c_void,
        )
    };
    if port.is_null() {
        say(&format!(
            "{}\n",
            serde_json::json!({ "error": "macOS refused the event tap: this helper has no Accessibility" })
        ));
        return 1;
    }
    shared.port.store(port as *mut c_void, Ordering::Release);
    // Disabled until the app holds: a disabled tap costs nothing on other keys.
    shared.enable(false);
    // SAFETY: the port is live; the source and the run loop are this thread's.
    let added = unsafe {
        let source = cf::CFMachPortCreateRunLoopSource(std::ptr::null(), port, 0);
        if !source.is_null() {
            cf::CFRunLoopAddSource(cf::CFRunLoopGetCurrent(), source, cf::kCFRunLoopCommonModes());
        }
        !source.is_null()
    };
    if !added {
        say("{\"error\":\"the event tap has no run loop source\"}\n");
        return 1;
    }
    // Before any key line can be written: the app reads this first.
    say("{\"ready\":true}\n");
    // Both threads are this scope's: it joins them before `run` returns.
    std::thread::scope(|scope| {
        // Taken keys to stdout, off the tap's thread so a slow reader never stalls a keystroke.
        // It ends when the stdin thread drops the sender, or when stdout is gone.
        scope.spawn(move || {
            let mut out = std::io::stdout();
            for key in receiver {
                if out.write_all(key_line(key).as_bytes()).and_then(|()| out.flush()).is_err() {
                    break;
                }
            }
        });
        // The app's lines; its end of file (the app stopped it, or ended) ends the tap.
        scope.spawn(move || {
            for line in std::io::stdin().lock().lines() {
                let Ok(line) = line else { break };
                let Some(control) = parse_control(&line) else {
                    eprintln!("cmux-screen-sharing __shortcut-tap: ignored line");
                    continue;
                };
                let enabled = shared.policy.lock().map(|mut p| p.control(control)).unwrap_or(false);
                shared.enable(enabled);
            }
            shared.enable(false);
            if let Ok(mut keys) = shared.keys.lock() {
                keys.take();
            }
            shared.done.store(true, Ordering::Release);
        });
        // The tap's run loop, on this thread, until stdin ended. Each turn returns within
        // RUN_TURN_S, so the end is seen even when it came before the loop started.
        while !shared.done.load(Ordering::Acquire) {
            // SAFETY: this thread's run loop, in the default mode (the tap's source is in the
            // common modes, which include it).
            unsafe { cf::CFRunLoopRunInMode(cf::kCFRunLoopDefaultMode(), RUN_TURN_S, 0) };
        }
    });
    0
}
