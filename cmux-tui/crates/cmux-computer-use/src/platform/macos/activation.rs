//! A background app's menu commands, made available without activating it.
//!
//! An app that is not active has no key window, so every menu item that acts
//! on one (Edit > Select All, File > Save, Safari's View > Zoom In, Finder's
//! View > as Icons) validates as disabled, and pressing it through
//! accessibility does nothing. Measured in a macOS 26.6 guest: all four read
//! `AXEnabled` 0 while their app was behind the person's.
//!
//! The same scope carries background input that only a key window takes: a
//! mouse press in TextEdit's text view (an inactive app's window answers it
//! by asking to activate and drops it) and a key chord, which AppKit then
//! routes as in the foreground (the window's views, then the menus).
//!
//! The window server tells an app it became active, and which of its windows
//! is key, with event records it posts to the app's process. Posting the
//! same records to the target's process only (`SLPSPostEventRecordTo`) makes
//! that app treat the window as its key window: its menus validate against
//! it (about 0.9 s later, when AppKit next updates them) while the window
//! server's front app, key window and stacking are untouched, so the person's
//! keys still go to their own app and nothing is raised. Both records are
//! needed: the focus record alone or the make-key pair alone left the items
//! disabled for 5 s. When the call is done the target is told it lost focus
//! again (the defocus record, to its process only).
//!
//! The calls are private (looked up at run time); without them nothing is
//! posted and a disabled item stays disabled, which the caller reports. The
//! record layout is cua-driver's (MIT, `skylight.rs`, read as a reference).

use std::ffi::c_void;
use std::sync::OnceLock;
use std::time::{Duration, Instant};

use super::sys::symbol;

type PostRecordFn = unsafe extern "C" fn(*const c_void, *const u8) -> i32;
type ConnectionFn = unsafe extern "C" fn() -> u32;
type WindowOwnerFn = unsafe extern "C" fn(u32, u32, *mut u32) -> i32;
type ConnectionPsnFn = unsafe extern "C" fn(u32, *mut c_void) -> i32;

struct Calls {
    post: PostRecordFn,
    connection: ConnectionFn,
    owner: WindowOwnerFn,
    psn: ConnectionPsnFn,
}

fn calls() -> Option<&'static Calls> {
    static C: OnceLock<Option<Calls>> = OnceLock::new();
    C.get_or_init(|| {
        // SAFETY: dlopen of a system framework path; it stays loaded.
        unsafe {
            libc::dlopen(
                c"/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight".as_ptr(),
                libc::RTLD_LAZY,
            )
        };
        let post = symbol(c"SLPSPostEventRecordTo")?;
        let connection = symbol(c"SLSMainConnectionID")?;
        let owner = symbol(c"SLSGetWindowOwner")?;
        let psn = symbol(c"SLSGetConnectionPSN")?;
        // SAFETY: these symbols have these signatures (cua-driver's
        // `skylight.rs`, yabai).
        Some(unsafe {
            Calls {
                post: std::mem::transmute::<*mut c_void, PostRecordFn>(post),
                connection: std::mem::transmute::<*mut c_void, ConnectionFn>(connection),
                owner: std::mem::transmute::<*mut c_void, WindowOwnerFn>(owner),
                psn: std::mem::transmute::<*mut c_void, ConnectionPsnFn>(psn),
            }
        })
    })
    .as_ref()
}

/// The record kinds and the focus record's direction byte.
const RECORD_FOCUS: u8 = 0x0D;
const RECORD_MAKE_KEY_DOWN: u8 = 0x01;
const RECORD_MAKE_KEY_UP: u8 = 0x02;
pub(super) const FOCUS_IN: u8 = 0x01;
pub(super) const FOCUS_OUT: u8 = 0x02;

/// A 248-byte window server event record for `window` (pure, for tests).
/// Focus records carry the direction at 0x8A; the make-key pair carries a
/// flag at 0x3A and a filled mask at 0x20..0x30.
pub(super) fn record(kind: u8, window: u32, direction: u8) -> [u8; 0xF8] {
    let mut r = [0u8; 0xF8];
    r[0x04] = 0xF8;
    r[0x08] = kind;
    r[0x3C..0x40].copy_from_slice(&window.to_le_bytes());
    if kind == RECORD_FOCUS {
        r[0x8A] = direction;
    } else {
        r[0x3A] = 0x10;
        r[0x20..0x30].fill(0xFF);
    }
    r
}

/// The process serial number of the window's owner.
fn psn_of(c: &Calls, window: u32) -> Option<[u8; 8]> {
    let mut owner = 0u32;
    let mut psn = [0u8; 8];
    // SAFETY: the calls with their signatures and live out-pointers.
    unsafe {
        if (c.owner)((c.connection)(), window, &mut owner) != 0 || owner == 0 {
            return None;
        }
        if (c.psn)(owner, psn.as_mut_ptr().cast()) != 0 {
            return None;
        }
    }
    Some(psn)
}

fn post(c: &Calls, psn: &[u8; 8], r: &[u8; 0xF8]) -> bool {
    // SAFETY: a live PSN and a 248-byte record, as the call takes them.
    unsafe { (c.post)(psn.as_ptr().cast(), r.as_ptr()) == 0 }
}

/// `window` is its app's key window as far as the app knows, until dropped
/// (then the app is told it lost focus). Only the window's own process gets
/// a record.
pub(super) struct KeyInApp {
    window: u32,
    psn: [u8; 8],
}

impl KeyInApp {
    /// Posts the focus record and the make-key pair for `window` to its
    /// owner. `None` when the private calls or the window's owner are
    /// missing, or a post failed (then nothing is left to undo but the focus
    /// record, which is undone).
    pub(super) fn enter(window: u32) -> Option<KeyInApp> {
        let c = calls()?;
        let psn = psn_of(c, window)?;
        let scope = KeyInApp { window, psn };
        let ok = post(c, &psn, &record(RECORD_FOCUS, window, FOCUS_IN))
            && post(c, &psn, &record(RECORD_MAKE_KEY_DOWN, window, 0))
            && post(c, &psn, &record(RECORD_MAKE_KEY_UP, window, 0));
        ok.then_some(scope)
    }
}

/// Before the app is told it lost focus: input posted in the scope goes
/// through another queue and must be handled first.
const HAND_BACK_AFTER: Duration = Duration::from_millis(60);

impl Drop for KeyInApp {
    fn drop(&mut self) {
        std::thread::sleep(HAND_BACK_AFTER);
        if let Some(c) = calls() {
            post(c, &self.psn, &record(RECORD_FOCUS, self.window, FOCUS_OUT));
        }
    }
}

/// How long a menu item may take to validate after [`KeyInApp::enter`]
/// (measured: about 0.9 s on macOS 26.6).
pub(super) const VALIDATE_WAIT: Duration = Duration::from_millis(1800);
const VALIDATE_POLL: Duration = Duration::from_millis(40);

/// Polls `ready` until it holds or `budget` passes; whether it held.
pub(super) fn wait_until(budget: Duration, ready: &dyn Fn() -> bool) -> bool {
    let start = Instant::now();
    loop {
        if ready() {
            return true;
        }
        if start.elapsed() >= budget {
            return false;
        }
        std::thread::sleep(VALIDATE_POLL);
    }
}
