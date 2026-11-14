//! A background app's disabled menu items, validated without activating it.
//!
//! An app that is not active has no key window, so every menu item that acts
//! on one (Edit > Select All, File > Save, Safari's View > Zoom In, Finder's
//! View > as Icons) validates as disabled and pressing it through
//! accessibility does nothing. Measured in a macOS 26.6 guest: all four read
//! `AXEnabled` 0 while their app was behind the person's.
//!
//! The window server tells an app it became active, and which of its windows
//! is key, with event records it posts to the app's process. Posting the
//! same records to the target's process only (`SLPSPostEventRecordTo`) makes
//! the app treat that window as its key window, and its menus validate
//! against it (about 0.9 s later), while the window server's front app, key
//! window and stacking are untouched. Both records are needed: the focus
//! record alone or the make-key pair alone left the items disabled for 5 s.
//!
//! The scope is as small as it can be: it is open only while one menu item
//! validates and is pressed through accessibility, at most [`SCOPE_BOUND`].
//! Nothing is typed and no key is posted inside it (keys posted to an app
//! that thinks it is active reach its views, input methods and panels). When
//! the last scope on the app ends, the app is told it lost focus again (the
//! defocus record, to the process saved at entry, naming the window or any
//! other window of the app), unless it became the front app.
//!
//! Gated: the records are undocumented (layout from cua-driver's
//! `skylight.rs`, MIT, read as a reference) and the make-key pair uses the
//! mouse-down/up record kinds, so the scope runs only on the macOS majors it
//! was verified on live ([`VERIFIED_MAJORS`]) and never when
//! `CMUX_CU_BG_ACTIVATE=0`. Off, disabled background menu items are refused
//! with the reason.

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
/// menu bar owner, panels, input source and z-order sampled at the finest
/// interval the probe allows; Safari, TextEdit, Finder, VS Code).
pub(super) const VERIFIED_MAJORS: std::ops::RangeInclusive<u32> = 26..=26;

/// The environment variable that turns the scope off (`0`).
pub(super) const OFF_ENV: &str = "CMUX_CU_BG_ACTIVATE";

/// The longest a scope is open: validation plus one press, a hung app
/// included (AX calls on the target are bounded inside it).
pub(super) const SCOPE_BOUND: Duration = Duration::from_millis(1500);
/// How long a menu item may take to validate (measured about 0.9 s).
pub(super) const VALIDATE_WAIT: Duration = Duration::from_millis(1200);
/// AX messaging timeout on the target while a scope is open.
pub(super) const AX_TIMEOUT_IN_SCOPE: f32 = 0.25;
const POLL: Duration = Duration::from_millis(20);

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
pub(super) const RECORD_FOCUS: u8 = 0x0D;
pub(super) const RECORD_MAKE_KEY_DOWN: u8 = 0x01;
pub(super) const RECORD_MAKE_KEY_UP: u8 = 0x02;
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

/// A process serial number.
pub(super) type Psn = [u32; 2];

/// What the scope needs from the system, so its lifecycle is tested with a
/// fake ([`Real`] in production).
pub(super) trait ScopeOs {
    fn front_pid(&self) -> Option<i32>;
    /// The owner of `window`'s process serial number.
    fn psn_of(&self, window: u32) -> Option<Psn>;
    fn post(&self, psn: &Psn, record: &[u8; 0xF8]) -> bool;
    /// Whether `window` still exists and is `pid`'s.
    fn window_exists(&self, window: u32, pid: i32) -> bool;
    /// Any window of `pid` the window server knows, on screen or not.
    fn any_window(&self, pid: i32) -> Option<u32>;
    /// The stop epoch ([`crate::stop::epoch`]): a change ends waits.
    fn stop_epoch(&self) -> u64;
}

/// The system's calls.
pub(super) struct Real;

impl ScopeOs for Real {
    fn front_pid(&self) -> Option<i32> {
        super::frontmost_pid()
    }
    fn psn_of(&self, window: u32) -> Option<Psn> {
        let c = calls()?;
        let mut owner = 0u32;
        let mut psn: Psn = [0; 2];
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
    fn post(&self, psn: &Psn, record: &[u8; 0xF8]) -> bool {
        let Some(c) = calls() else { return false };
        // SAFETY: a live PSN and a 248-byte record, as the call takes them.
        unsafe { (c.post)(psn.as_ptr().cast(), record.as_ptr()) == 0 }
    }
    fn window_exists(&self, window: u32, pid: i32) -> bool {
        super::cgwindows::by_id(window).is_some_and(|w| w.pid == pid)
    }
    fn any_window(&self, pid: i32) -> Option<u32> {
        super::cgwindows::all().into_iter().find(|w| w.pid == pid && w.layer == 0).map(|w| w.id)
    }
    fn stop_epoch(&self) -> u64 {
        crate::stop::epoch()
    }
}

/// Open scopes per app: the window they made key and how many share it.
/// The map's lock is held only to read or update it.
pub(super) struct Registry {
    open: Mutex<HashMap<i32, (u32, usize)>>,
    /// Held while records are posted, so a joiner returns only after the
    /// first scope's records went out, and a hand-back never races an entry.
    posting: Mutex<()>,
}

impl Registry {
    pub(super) fn new() -> Registry {
        Registry { open: Mutex::new(HashMap::new()), posting: Mutex::new(()) }
    }
    fn map(&self) -> std::sync::MutexGuard<'_, HashMap<i32, (u32, usize)>> {
        self.open.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }
    fn posting(&self) -> std::sync::MutexGuard<'_, ()> {
        self.posting.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}

fn registry() -> &'static Registry {
    static R: OnceLock<Registry> = OnceLock::new();
    R.get_or_init(Registry::new)
}

/// What entering does for a pid (pure, for tests): the person's front app
/// is never entered; a scope open on the same window is joined; one open on
/// another window of the app refuses (two windows cannot both be key).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Entry {
    Refuse,
    Join,
    Post,
}

pub(super) fn entry(open: Option<(u32, usize)>, window: u32, target_is_front: bool) -> Entry {
    match open {
        _ if target_is_front => Entry::Refuse,
        Some((w, n)) if n > 0 && w == window => Entry::Join,
        Some((_, n)) if n > 0 => Entry::Refuse,
        _ => Entry::Post,
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
    /// The defocus record could not be posted (twice), or the app had no
    /// window left to name.
    HandBackFailed,
}

/// `window` is its app's key window as far as the app knows, until
/// [`KeyInApp::end`] (or drop).
pub(super) struct KeyInApp<'a, O: ScopeOs = Real> {
    os: &'a O,
    registry: &'a Registry,
    window: u32,
    pid: i32,
    psn: Psn,
    opened: Instant,
    epoch: u64,
    ended: bool,
}

impl KeyInApp<'static, Real> {
    /// Enters the scope with the system's calls; `None` when it is off
    /// ([`gate`]) or [`KeyInApp::enter_with`] refuses.
    pub(super) fn enter(window: u32, pid: i32) -> Option<KeyInApp<'static, Real>> {
        static OS: Real = Real;
        if !enabled() || calls().is_none() {
            return None;
        }
        KeyInApp::enter_with(&OS, registry(), window, pid)
    }
}

impl<'a, O: ScopeOs> KeyInApp<'a, O> {
    /// Enters the scope for `window` of `pid`: posts the focus record and
    /// the make-key pair to the window's owner, each only while `pid` is not
    /// the front app (read right before every post). `None` when `pid` is in
    /// front, a scope on another window of the app is open, the owner is
    /// unknown, or a post failed or the person switched to the app (then
    /// what was posted is handed back).
    pub(super) fn enter_with(
        os: &'a O,
        registry: &'a Registry,
        window: u32,
        pid: i32,
    ) -> Option<KeyInApp<'a, O>> {
        let front = || os.front_pid() == Some(pid);
        let posting = registry.posting();
        let open = registry.map().get(&pid).copied();
        match entry(open, window, front()) {
            Entry::Refuse => return None,
            Entry::Join => {
                let psn = os.psn_of(window)?;
                if let Some(e) = registry.map().get_mut(&pid) {
                    e.1 += 1;
                }
                drop(posting);
                return Some(KeyInApp {
                    os,
                    registry,
                    window,
                    pid,
                    psn,
                    opened: Instant::now(),
                    epoch: os.stop_epoch(),
                    ended: false,
                });
            }
            Entry::Post => {}
        }
        let psn = os.psn_of(window)?;
        registry.map().insert(pid, (window, 1));
        let scope = KeyInApp {
            os,
            registry,
            window,
            pid,
            psn,
            opened: Instant::now(),
            epoch: os.stop_epoch(),
            ended: false,
        };
        for (kind, dir) in
            [(RECORD_FOCUS, FOCUS_IN), (RECORD_MAKE_KEY_DOWN, 0), (RECORD_MAKE_KEY_UP, 0)]
        {
            if front() || !os.post(&psn, &record(kind, window, dir)) {
                drop(posting);
                return None; // the drop hands back (or skips: front)
            }
        }
        drop(posting);
        Some(scope)
    }

    /// Whether the scope may still act: not past [`SCOPE_BOUND`], not
    /// stopped, and the app is not the person's front app.
    pub(super) fn live(&self) -> bool {
        self.opened.elapsed() < SCOPE_BOUND
            && self.os.stop_epoch() == self.epoch
            && self.os.front_pid() != Some(self.pid)
    }

    /// Polls `ready` until it holds, at most `budget` and never past the
    /// scope's bound; the deadline is checked before every poll, and a stop
    /// or the person switching to the app ends it. Whether it held.
    pub(super) fn wait_until(&self, budget: Duration, ready: &dyn Fn() -> bool) -> bool {
        let start = Instant::now();
        loop {
            if start.elapsed() >= budget || !self.live() {
                return false;
            }
            if ready() {
                return true;
            }
            std::thread::sleep(POLL);
        }
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
        let posting = self.registry.posting();
        let after = {
            let mut map = self.registry.map();
            let after = map.get(&self.pid).map_or(0, |e| e.1.saturating_sub(1));
            if after == 0 {
                map.remove(&self.pid);
            } else if let Some(e) = map.get_mut(&self.pid) {
                e.1 = after;
            }
            after
        };
        let exists = self.os.window_exists(self.window, self.pid);
        let plan = hand_back(
            after,
            self.os.front_pid() == Some(self.pid),
            exists,
            self.window,
            if exists { None } else { self.os.any_window(self.pid) },
        );
        let name = match plan {
            HandBack::StillOpen | HandBack::TargetIsFront => return Ended::Fine,
            HandBack::NoWindow => return Ended::HandBackFailed,
            HandBack::Post(name) => name,
        };
        for _ in 0..2 {
            // Read again right before posting: the app may have come to front.
            if self.os.front_pid() == Some(self.pid) {
                return Ended::Fine;
            }
            if self.os.post(&self.psn, &record(RECORD_FOCUS, name, FOCUS_OUT)) {
                return Ended::Fine;
            }
        }
        drop(posting);
        eprintln!(
            "cmux computer use: could not hand window {name} of pid {} back (defocus record)",
            self.pid
        );
        Ended::HandBackFailed
    }
}

impl<O: ScopeOs> Drop for KeyInApp<'_, O> {
    fn drop(&mut self) {
        self.finish();
    }
}

/// The note a result gets when the hand-back failed.
pub(super) const HAND_BACK_FAILED: &str = "the target app could not be told that its window is no longer key (the hand-back failed); it may draw that window as active until it is next used";

/// Appends `add` to `note` (never replaces what is there).
pub(super) fn append_note(note: &mut String, add: &str) {
    if note.is_empty() {
        note.push_str(add);
    } else if !note.contains(add) {
        note.push_str("; ");
        note.push_str(add);
    }
}
