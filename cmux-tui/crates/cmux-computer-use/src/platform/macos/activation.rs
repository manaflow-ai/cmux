//! A background app's menu commands and key chords, made available without
//! activating it.
//!
//! An app that is not active has no key window, so every menu item that acts
//! on one (Edit > Select All, File > Save, Safari's View > Zoom In, Finder's
//! View > as Icons) validates as disabled, pressing it through accessibility
//! does nothing, and a posted chord never reaches its menu key equivalents.
//! Measured in a macOS 26.6 guest: all four read `AXEnabled` 0 while their
//! app was behind the person's.
//!
//! The window server tells an app it became active, and which of its windows
//! is key, with event records it posts to the app's process. Posting the
//! same records to the target's process only (`SLPSPostEventRecordTo`) makes
//! that app treat the window as its key window: its menus validate against
//! it (about 0.9 s later, when AppKit next updates them) and a posted chord
//! is routed as in the foreground (the window's views, then the menus), while
//! the window server's front app, key window and stacking are untouched.
//! Both records are needed: the focus record alone or the make-key pair
//! alone left the items disabled for 5 s. When the last scope on the app
//! ends, the app is told it lost focus again (the defocus record, naming a
//! window of the app that still exists), unless it became the front app.
//!
//! Gated: the records are undocumented (layout from cua-driver's
//! `skylight.rs`, MIT, read as a reference) and the make-key pair uses the
//! mouse-down/up record kinds, so the scope runs only on the macOS majors it
//! was verified on live ([`VERIFIED_MAJORS`]) and never when
//! `CMUX_CU_BG_ACTIVATE=0`. Off, disabled background menu items are refused
//! with the reason and chords keep the background rule. It is not used for
//! mouse presses: a press that lands in the window makes AppKit order it
//! above the person's.

use std::collections::HashMap;
use std::ffi::c_void;
use std::sync::{Mutex, OnceLock};
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

/// The macOS majors the scope was verified on live (front app, key window,
/// z-order sampled every 1 ms; Safari, TextEdit, Finder, a Chromium window).
/// macOS 27 could not be verified (no 27 guest with the test rig): off there.
pub(super) const VERIFIED_MAJORS: std::ops::RangeInclusive<u32> = 26..=26;

/// The environment variable that turns the scope off (`0`).
pub(super) const OFF_ENV: &str = "CMUX_CU_BG_ACTIVATE";

/// Whether the scope may run: a verified macOS major and not switched off.
/// Pure, for tests.
pub(super) fn gate(os_version: &str, env: Option<&str>) -> bool {
    if env.is_some_and(|v| v.trim() == "0") {
        return false;
    }
    os_version
        .split('.')
        .next()
        .and_then(|m| m.trim().parse::<u32>().ok())
        .is_some_and(|m| VERIFIED_MAJORS.contains(&m))
}

fn enabled() -> bool {
    static ON: OnceLock<bool> = OnceLock::new();
    *ON.get_or_init(|| {
        gate(
            &super::sys::sysctl_string(c"kern.osproductversion").unwrap_or_default(),
            std::env::var(OFF_ENV).ok().as_deref(),
        )
    })
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
fn psn_of(c: &Calls, window: u32) -> Option<[u32; 2]> {
    let mut owner = 0u32;
    let mut psn = [0u32; 2];
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

fn post(c: &Calls, psn: &[u32; 2], r: &[u8; 0xF8]) -> bool {
    // SAFETY: a live PSN and a 248-byte record, as the call takes them.
    unsafe { (c.post)(psn.as_ptr().cast(), r.as_ptr()) == 0 }
}

/// Open scopes per app (pid): only the first enters, only the last hands
/// back, so two sessions on one app never defocus under each other.
fn open_scopes() -> &'static Mutex<HashMap<i32, usize>> {
    static M: OnceLock<Mutex<HashMap<i32, usize>>> = OnceLock::new();
    M.get_or_init(|| Mutex::new(HashMap::new()))
}

fn lock_scopes() -> std::sync::MutexGuard<'static, HashMap<i32, usize>> {
    open_scopes().lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

/// What entering does for a pid (pure, for tests): a scope already open on
/// it only joins; the person's front app is never entered.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Entry {
    Refuse,
    Join,
    Post,
}

pub(super) fn entry(open: usize, target_is_front: bool) -> Entry {
    if target_is_front {
        Entry::Refuse
    } else if open > 0 {
        Entry::Join
    } else {
        Entry::Post
    }
}

/// What ending a scope does (pure, for tests).
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum HandBack {
    /// Another scope on the app is still open.
    StillOpen,
    /// The app became the front app meanwhile: it keeps its focus.
    TargetIsFront,
    /// The app has no window left to name.
    NoWindow,
    /// Tell the app it lost focus, naming this window.
    Post(u32),
}

pub(super) fn hand_back(
    open_after: usize,
    target_is_front: bool,
    window_exists: bool,
    window: u32,
    other_window: Option<u32>,
) -> HandBack {
    if open_after > 0 {
        HandBack::StillOpen
    } else if target_is_front {
        HandBack::TargetIsFront
    } else if window_exists {
        HandBack::Post(window)
    } else {
        other_window.map_or(HandBack::NoWindow, HandBack::Post)
    }
}

/// How a scope ended, for the result.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum Ended {
    Fine,
    /// The defocus record could not be posted (twice).
    HandBackFailed,
}

/// `window` is its app's key window as far as the app knows, until
/// [`KeyInApp::end`] (or drop).
pub(super) struct KeyInApp {
    window: u32,
    pid: i32,
    ended: bool,
}

impl KeyInApp {
    /// Enters the scope for `window` of `pid`: posts the focus record and
    /// the make-key pair to the window's owner, each only while `pid` is not
    /// the front app (read right before every post). `None` when the scope
    /// is off ([`gate`]), the private calls or the window's owner are
    /// missing, `pid` is in front, or a post failed (then what was posted is
    /// handed back).
    pub(super) fn enter(window: u32, pid: i32) -> Option<KeyInApp> {
        if !enabled() {
            return None;
        }
        let c = calls()?;
        let front = || super::frontmost_pid() == Some(pid);
        let mut open = lock_scopes();
        let count = open.get(&pid).copied().unwrap_or(0);
        match entry(count, front()) {
            Entry::Refuse => return None,
            Entry::Join => {
                open.insert(pid, count + 1);
                return Some(KeyInApp { window, pid, ended: false });
            }
            Entry::Post => {}
        }
        let psn = psn_of(c, window)?;
        open.insert(pid, 1);
        let scope = KeyInApp { window, pid, ended: false };
        drop(open);
        for (kind, dir) in
            [(RECORD_FOCUS, FOCUS_IN), (RECORD_MAKE_KEY_DOWN, 0), (RECORD_MAKE_KEY_UP, 0)]
        {
            if front() || !post(c, &psn, &record(kind, window, dir)) {
                return None; // the drop hands back (or skips: front)
            }
        }
        Some(scope)
    }

    /// Ends the scope; the last one on the app hands it back.
    pub(super) fn end(mut self) -> Ended {
        self.finish()
    }

    fn finish(&mut self) -> Ended {
        if self.ended {
            return Ended::Fine;
        }
        self.ended = true;
        let mut open = lock_scopes();
        let after = open.get(&self.pid).copied().unwrap_or(1).saturating_sub(1);
        if after == 0 {
            open.remove(&self.pid);
        } else {
            open.insert(self.pid, after);
        }
        let exists = super::cgwindows::by_id(self.window).is_some_and(|w| w.pid == self.pid);
        let other = || {
            super::cgwindows::on_screen()
                .into_iter()
                .find(|w| w.pid == self.pid && w.layer == 0)
                .map(|w| w.id)
        };
        let plan = hand_back(
            after,
            super::frontmost_pid() == Some(self.pid),
            exists,
            self.window,
            if exists { None } else { other() },
        );
        let HandBack::Post(name) = plan else { return Ended::Fine };
        let Some(c) = calls() else { return Ended::HandBackFailed };
        for _ in 0..2 {
            // Re-read right before posting: the app may have come to front.
            if super::frontmost_pid() == Some(self.pid) {
                return Ended::Fine;
            }
            if psn_of(c, name).is_some_and(|psn| post(c, &psn, &record(RECORD_FOCUS, name, FOCUS_OUT)))
            {
                return Ended::Fine;
            }
        }
        eprintln!(
            "cmux computer use: could not hand window {name} of pid {} back (defocus record)",
            self.pid
        );
        Ended::HandBackFailed
    }
}

impl Drop for KeyInApp {
    fn drop(&mut self) {
        self.finish();
    }
}

/// The note a result gets when the hand-back failed.
pub(super) const HAND_BACK_FAILED: &str = "the target app could not be told that its window is no longer key (the hand-back record failed twice); it may draw that window as active until it is next used";

/// How long a menu item may take to validate after [`KeyInApp::enter`]
/// (measured: about 0.9 s on macOS 26.6). The scope is ended as soon as it
/// validates.
pub(super) const VALIDATE_WAIT: Duration = Duration::from_millis(1200);
const POLL: Duration = Duration::from_millis(20);

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
        std::thread::sleep(POLL);
    }
}
