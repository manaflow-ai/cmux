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
//! was verified on live ([`VERIFIED`]: 26.6+ and 27.0+) and never when
//! `CMUX_CU_BG_ACTIVATE=0` (in the worker's environment, or set for the user
//! with `launchctl setenv CMUX_CU_BG_ACTIVATE 0` and then a cmux restart).
//! Off, disabled background menu items are refused with the reason.

use std::collections::HashMap;
use std::ffi::c_void;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use super::input::Route;
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

/// The macOS versions the scope was verified on live (front app, key
/// window, menu bar owner, the target's windows and panels, input source,
/// cursor and z-order sampled every 1 ms with the person typing; Safari,
/// TextEdit, Finder, VS Code): 26.6, 27.0.1 and 27.2 guests. On each, the
/// focus record plus the make-key pair validated the menus in 0.8-0.9 s and
/// either alone did not within 5 s; nothing the person sees changed. Per
/// major, the first verified version (major, minor, patch): earlier ones run
/// with the scope off. 27.0 itself (build 26A425, a fleet Mac): the same
/// records enabled TextEdit's Format > Make Rich Text in 1.03-1.05 s on four
/// runs, the front app stayed the same, and the item read disabled again
/// after the focus-out record; with 27.0 gated off, every background menu
/// command that needs a key window was refused there.
pub(super) const VERIFIED: &[(u32, u32, u32)] = &[(26, 6, 0), (27, 0, 0)];

/// The environment variable that sets the scope: `0` off, `1` on; unset,
/// [`DEFAULT_ON`].
pub(super) const OFF_ENV: &str = "CMUX_CU_BG_ACTIVATE";

/// Whether the scope runs when no switch says otherwise. Making a
/// background app's window key (the scope's window-server records) makes
/// AppKit in that app post "did become active" for the scope's length
/// (the window server's front app and the person's key window never
/// change). `false`: menu items and chords that enable only with a key
/// window are refused in a background app instead.
pub(super) const DEFAULT_ON: bool = true;

/// Which apps the scope may prime. `Any`: every app (today's behaviour).
/// `NotDenied`: never the apps in [`PRIME_DENY`] (browsers, whose pages get
/// a window `focus` event while the scope is open, and messaging and mail
/// apps, which may mark what they show as read when they become active).
pub(super) const PRIME_APPS: PrimeApps = PrimeApps::Any;

/// See [`PRIME_APPS`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[allow(dead_code)] // the variant not chosen in PRIME_APPS
pub(super) enum PrimeApps {
    Any,
    NotDenied,
}

/// Bundle id prefixes never primed under [`PrimeApps::NotDenied`] (any
/// case; a prefix also covers its betas, canaries and nightlies). The cmux
/// app hosts the cmux browser, so all of cmux is on it.
pub(super) const PRIME_DENY: &[&str] = &[
    // Browsers.
    "com.apple.Safari",
    "com.google.Chrome",
    "company.thebrowser.",
    "org.mozilla.firefox",
    "com.microsoft.edgemac",
    "com.brave.Browser",
    "com.cmuxterm.",
    // Messaging and mail.
    "com.apple.MobileSMS",
    "com.apple.mail",
    "com.tinyspeck.slackmacgap",
    "com.hnc.Discord",
    "net.whatsapp.WhatsApp",
    "desktop.WhatsApp",
    "ru.keepcoder.Telegram",
    "org.telegram.desktop",
    "com.microsoft.teams",
    "com.microsoft.Outlook",
    // More browsers and messaging and mail apps.
    "org.mozilla.nightly",
    "org.chromium.Chromium",
    "com.operasoftware.Opera",
    "com.vivaldi.Vivaldi",
    "com.kagi.kagimacOS",
    "app.zen-browser.",
    "com.duckduckgo.macos.browser",
    "org.whispersystems.signal-desktop",
    "com.facebook.archon",
    "com.tencent.xinWeChat",
    "org.mozilla.thunderbird",
    "com.readdle.",
    "com.mimestream.Mimestream",
];

/// Whether the scope may prime the app with `bundle_id` under `apps`. An
/// app whose bundle id cannot be read is never primed under `NotDenied`.
pub(super) fn may_prime(apps: PrimeApps, bundle_id: Option<&str>) -> bool {
    match apps {
        PrimeApps::Any => true,
        PrimeApps::NotDenied => bundle_id.is_some_and(|id| {
            let id = id.to_ascii_lowercase();
            !PRIME_DENY.iter().any(|p| id.starts_with(&p.to_ascii_lowercase()))
        }),
    }
}

/// The longest a scope is open: validation plus one press, a hung app
/// included (AX calls on the target are bounded inside it).
pub(super) const SCOPE_BOUND: Duration = Duration::from_millis(1500);
/// How long a menu item may take to validate (measured about 0.9 s).
pub(super) const VALIDATE_WAIT: Duration = Duration::from_millis(1200);
/// AX messaging timeout on the target while a scope is open.
pub(super) const AX_TIMEOUT_IN_SCOPE: f32 = 0.25;
const POLL: Duration = Duration::from_millis(20);

/// Whether the scope may run (pure, for tests): a verified macOS major at
/// or past its first verified version, and no off switch says `0`. `switches` are
/// the values found (the worker's environment, the user's launchd
/// environment); any `0` turns it off.
pub(super) fn gate(os_version: &str, switches: &[&str]) -> bool {
    gate_with(DEFAULT_ON, os_version, switches)
}

/// [`gate`] with the default given: any `0` turns it off; with the default
/// off, a `1` turns it on.
pub(super) fn gate_with(default_on: bool, os_version: &str, switches: &[&str]) -> bool {
    if switches.iter().any(|v| v.trim() == "0") {
        return false;
    }
    if !default_on && !switches.iter().any(|v| v.trim() == "1") {
        return false;
    }
    let mut parts = os_version.split('.').map(|p| p.trim().parse::<u32>().ok());
    let Some(Some(major)) = parts.next() else { return false };
    let minor = parts.next().flatten().unwrap_or(0);
    let patch = parts.next().flatten().unwrap_or(0);
    VERIFIED.iter().any(|&(m, min, pat)| m == major && (minor, patch) >= (min, pat))
}

/// The off switch's values: the worker's own environment and the user's
/// launchd environment (`launchctl setenv CMUX_CU_BG_ACTIVATE 0` in a
/// Terminal, then a cmux restart). cmux Remote starts the Computer Use worker
/// with a fixed environment, so a variable set only for the app does not
/// reach it; the launchd one does. Read once, at first use.
fn off_switches() -> Vec<String> {
    let mut out = Vec::new();
    if let Ok(v) = std::env::var(OFF_ENV) {
        out.push(v);
    }
    if let Ok(o) = std::process::Command::new("/bin/launchctl").args(["getenv", OFF_ENV]).output() {
        let v = String::from_utf8_lossy(&o.stdout).trim().to_string();
        if !v.is_empty() {
            out.push(v);
        }
    }
    out
}

fn enabled() -> bool {
    static ON: OnceLock<bool> = OnceLock::new();
    *ON.get_or_init(|| {
        let switches = off_switches();
        gate(
            &super::sys::sysctl_string(c"kern.osproductversion").unwrap_or_default(),
            &switches.iter().map(String::as_str).collect::<Vec<_>>(),
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
    /// The clock the scope's bound is measured with.
    fn now(&self) -> Instant {
        Instant::now()
    }
}

/// The system's calls.
pub(super) struct Real;

impl ScopeOs for Real {
    // Both readings of the front app, agreed (a non-activating panel over
    // the target makes them disagree: None, and every check fails closed).
    fn front_pid(&self) -> Option<i32> {
        super::roles::agreed_front(super::active_pid(), super::frontmost_pid())
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
/// Per process: one Computer Use worker serves every session of a cmux app,
/// so sessions never defocus under each other; two cmux apps (a release and
/// a tagged build) driving the same target app at once are not coordinated
/// (a shared lock per target pid would need a cleanup story for crashed
/// holders; not done).
pub(super) struct Registry {
    /// pid -> (the window made key, scopes sharing it, when the first one
    /// entered: joiners never extend past one bound from then).
    open: Mutex<HashMap<i32, (u32, usize, Instant)>>,
    /// pid -> until when input stays refused after a failed hand-back.
    held: Mutex<HashMap<i32, Instant>>,
    /// The pids whose lock is taken: entering a scope, handing it back and
    /// posting input to an app each hold its pid's lock, so a joiner returns
    /// only after the first scope's records went out, a hand-back never
    /// races an entry, and no input is posted while a scope can open. Per
    /// pid: a paced drag in one app never blocks another app's scope.
    busy: Mutex<std::collections::HashSet<i32>>,
    freed: std::sync::Condvar,
    /// pid -> scope entries waiting for its lock: input yields to them, so a
    /// long typing loop cannot keep a scope from entering between chunks.
    entering: Mutex<HashMap<i32, usize>>,
}

/// One pid's lock ([`Registry::lock_pid`]); released when dropped.
pub(super) struct PidLock<'a> {
    registry: &'a Registry,
    pid: i32,
}

impl Drop for PidLock<'_> {
    fn drop(&mut self) {
        let mut busy = self.registry.busy.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        busy.remove(&self.pid);
        drop(busy);
        self.registry.freed.notify_all();
    }
}

impl Registry {
    pub(super) fn new() -> Registry {
        Registry {
            open: Mutex::new(HashMap::new()),
            held: Mutex::new(HashMap::new()),
            busy: Mutex::new(std::collections::HashSet::new()),
            freed: std::sync::Condvar::new(),
            entering: Mutex::new(HashMap::new()),
        }
    }
    fn map(&self) -> std::sync::MutexGuard<'_, HashMap<i32, (u32, usize, Instant)>> {
        self.open.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }
    /// Takes `pid`'s lock, waiting while another thread holds it.
    pub(super) fn lock_pid(&self, pid: i32) -> PidLock<'_> {
        let mut busy = self.busy.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        while busy.contains(&pid) {
            busy = self.freed.wait(busy).unwrap_or_else(std::sync::PoisonError::into_inner);
        }
        busy.insert(pid);
        PidLock { registry: self, pid }
    }

    /// Takes `pid`'s lock for a scope entry, ahead of input waiting for it.
    pub(super) fn lock_pid_for_entry(&self, pid: i32) -> PidLock<'_> {
        *self
            .entering
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .entry(pid)
            .or_insert(0) += 1;
        let lock = self.lock_pid(pid);
        let mut entering = self.entering.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some(n) = entering.get_mut(&pid) {
            *n -= 1;
            if *n == 0 {
                entering.remove(&pid);
            }
        }
        lock
    }

    /// Whether a scope entry is waiting for `pid`'s lock.
    fn entry_waiting(&self, pid: i32) -> bool {
        self.entering.lock().unwrap_or_else(std::sync::PoisonError::into_inner).contains_key(&pid)
    }

    /// [`Self::entry_waiting`] for tests.
    #[cfg(test)]
    pub(super) fn entry_waiting_for_test(&self, pid: i32) -> bool {
        self.entry_waiting(pid)
    }

    /// Whether `pid`'s lock is held right now (tests).
    #[cfg(test)]
    pub(super) fn pid_locked(&self, pid: i32) -> bool {
        self.busy.lock().unwrap_or_else(std::sync::PoisonError::into_inner).contains(&pid)
    }

    /// Whether input to the app with `pid` must wait: a scope is open on it
    /// (any session's), or its hand-back failed a moment ago.
    pub(super) fn is_open(&self, pid: i32) -> bool {
        if self.map().get(&pid).is_some_and(|e| e.1 > 0) {
            return true;
        }
        let mut held = self.held.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        match held.get(&pid) {
            Some(until) if Instant::now() < *until => true,
            Some(_) => {
                held.remove(&pid);
                false
            }
            None => false,
        }
    }

    /// Keeps input to `pid` refused for [`HAND_BACK_HOLD`]: its hand-back
    /// failed, so it may still take itself for the active app.
    fn hold(&self, pid: i32) {
        self.held
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert(pid, Instant::now() + HAND_BACK_HOLD);
    }

    /// Runs `post` with a [`Posting`] for `pid` (the only way to post input
    /// to an app's process) while no scope is open on it and none can open:
    /// the check and the post happen under `pid`'s lock, which entering a
    /// scope takes. While one is open the lock is let go and the check
    /// repeats, at most `bound`; `None` when it stayed open (nothing posted).
    pub(super) fn post_unprimed<T>(
        &self,
        pid: i32,
        window: u32,
        bound: Duration,
        post: impl FnOnce(&Posting) -> T,
    ) -> Option<T> {
        let start = Instant::now();
        loop {
            // A scope entry waiting for this app goes first (fairness).
            if !self.entry_waiting(pid) {
                let _lock = self.lock_pid(pid);
                if !self.is_open(pid) {
                    return Some(post(&Posting { route: Route::Pid { pid, window } }));
                }
            }
            if start.elapsed() >= bound {
                return None;
            }
            std::thread::sleep(POLL);
        }
    }
}

/// Permission to post input on one route: for an app's process (a pid
/// route) only [`Registry::post_unprimed`] makes one, so no input reaches an
/// app while it is primed; the system-wide route needs none.
/// `input`'s posting functions take one instead of a route.
pub(super) struct Posting {
    route: Route,
}

impl Posting {
    /// The system-wide (HID) route, for foreground input.
    pub(super) fn hid() -> Posting {
        Posting { route: Route::Hid }
    }
    pub(super) fn route(&self) -> Route {
        self.route
    }
}

/// Runs `post` on `route`: a pid route only while the app is not primed
/// ([`Registry::post_unprimed`], waiting at most [`WAIT_BOUND`]); the HID
/// route at once.
pub(super) fn post_unprimed<T>(route: Route, post: impl FnOnce(&Posting) -> T) -> Option<T> {
    match route {
        Route::Pid { pid, window } => registry().post_unprimed(pid, window, WAIT_BOUND, post),
        Route::Hid => Some(post(&Posting::hid())),
    }
}

/// How long input waits for a scope on its app to end: the scope's bound
/// plus a margin for its last AX call and hand-back.
pub(super) const WAIT_BOUND: Duration = Duration::from_millis(1500 + 750);

/// How long input stays refused after a failed hand-back.
pub(super) const HAND_BACK_HOLD: Duration = Duration::from_millis(2000);

/// The refusal when a scope stayed open on the app.
pub(super) const PRIMED_KEYS_REFUSAL: &str = "another Computer Use call kept making a menu item of this app available for over 2 s; no input is sent to the app meanwhile, so nothing was sent";

pub(super) fn registry() -> &'static Registry {
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
        if PRIME_APPS != PrimeApps::Any {
            let bundle = super::workspace::app_for_pid(pid).and_then(|a| a.bundle_id);
            if !may_prime(PRIME_APPS, bundle.as_deref()) {
                return None;
            }
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
        // Fail closed on entry: an unreadable front app counts as the target.
        let front = || os.front_pid().is_none_or(|p| p == pid);
        let posting = registry.lock_pid_for_entry(pid);
        let open = registry.map().get(&pid).copied();
        match entry(open.map(|e| (e.0, e.1)), window, front()) {
            Entry::Refuse => return None,
            Entry::Join => {
                let psn = os.psn_of(window)?;
                let first = open.map_or_else(|| os.now(), |e| e.2);
                if let Some(e) = registry.map().get_mut(&pid) {
                    e.1 += 1;
                }
                drop(posting);
                // A joiner shares the first scope's deadline: no extension.
                return Some(KeyInApp {
                    os,
                    registry,
                    window,
                    pid,
                    psn,
                    opened: first,
                    epoch: os.stop_epoch(),
                    ended: false,
                });
            }
            Entry::Post => {}
        }
        let psn = os.psn_of(window)?;
        registry.map().insert(pid, (window, 1, os.now()));
        let scope = KeyInApp {
            os,
            registry,
            window,
            pid,
            psn,
            opened: os.now(),
            epoch: os.stop_epoch(),
            ended: false,
        };
        let mut scope = scope;
        for (i, (kind, dir)) in
            [(RECORD_FOCUS, FOCUS_IN), (RECORD_MAKE_KEY_DOWN, 0), (RECORD_MAKE_KEY_UP, 0)]
                .into_iter()
                .enumerate()
        {
            if front() || !os.post(&psn, &record(kind, window, dir)) {
                if i == 0 {
                    // Nothing was posted: nothing to hand back, no hold.
                    scope.abandon();
                } else {
                    // Handed back (or skipped: the app is in front) before
                    // the lock is let go, so no other scope sees it half
                    // entered.
                    scope.finish_locked();
                }
                drop(posting);
                return None;
            }
        }
        drop(posting);
        Some(scope)
    }

    /// Whether the scope may still act: not past [`SCOPE_BOUND`], not
    /// stopped, and the app is not the person's front app.
    pub(super) fn live(&self) -> bool {
        self.os.now().saturating_duration_since(self.opened) < SCOPE_BOUND
            && self.os.stop_epoch() == self.epoch
            // Fail closed: an unreadable front app counts as the target.
            && self.os.front_pid().is_some_and(|p| p != self.pid)
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
        let posting = self.registry.lock_pid(self.pid);
        let ended = self.finish_locked();
        drop(posting);
        ended
    }

    /// Ends a scope that posted nothing (its first record failed): the
    /// registry entry goes, nothing is handed back, no hold, no report.
    fn abandon(&mut self) {
        self.ended = true;
        let mut map = self.registry.map();
        if let Some(e) = map.get_mut(&self.pid) {
            e.1 = e.1.saturating_sub(1);
            if e.1 == 0 {
                map.remove(&self.pid);
            }
        }
    }

    /// [`Self::finish`] with the posting lock already held by the caller.
    fn finish_locked(&mut self) -> Ended {
        if self.ended {
            return Ended::Fine;
        }
        self.ended = true;
        let after = {
            let mut map = self.registry.map();
            let after = map.get(&self.pid).map_or(0, |e| e.1.saturating_sub(1));
            if after > 0
                && let Some(e) = map.get_mut(&self.pid)
            {
                e.1 = after;
            }
            after
        };
        // The last scope's entry goes only after its focus-out post (on every
        // return below): until then the app counts as primed.
        let _remove = (after == 0).then(|| RemoveOnDrop { registry: self.registry, pid: self.pid });
        // Fail closed: with the front app unreadable nothing is posted (it
        // could be the target, now in the person's hands); input waits.
        if after == 0 && self.os.front_pid().is_none() {
            return self.failed();
        }
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
            HandBack::NoWindow => return self.failed(),
            HandBack::Post(name) => name,
        };
        for _ in 0..2 {
            // Read again right before posting: the app may have come to front
            // (unreadable: fail closed, no post).
            match self.os.front_pid() {
                Some(p) if p == self.pid => return Ended::Fine,
                None => return self.failed(),
                Some(_) => {}
            }
            if self.os.post(&self.psn, &record(RECORD_FOCUS, name, FOCUS_OUT)) {
                return Ended::Fine;
            }
        }
        eprintln!(
            "cmux computer use: could not hand window {name} of pid {} back (defocus record)",
            self.pid
        );
        self.failed()
    }

    /// A failed hand-back: the app may still take itself for the active app,
    /// so input to it waits a moment, and the call's result says so (the
    /// flag is read by the action that owned the scope, whatever path ended
    /// it: an explicit end or a drop on an early return).
    fn failed(&self) -> Ended {
        self.registry.hold(self.pid);
        HAND_BACK_FAILED_IN_CALL.with(|f| f.set(true));
        Ended::HandBackFailed
    }
}

thread_local! {
    /// A hand-back failed on this thread since the last [`take_hand_back_failed`].
    static HAND_BACK_FAILED_IN_CALL: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

/// Whether a hand-back failed on this thread since the last call (and
/// clears it): an action adds [`HAND_BACK_FAILED`] to its result.
pub(super) fn take_hand_back_failed() -> bool {
    HAND_BACK_FAILED_IN_CALL.with(|f| f.replace(false))
}

impl<O: ScopeOs> Drop for KeyInApp<'_, O> {
    fn drop(&mut self) {
        self.finish();
    }
}

/// Removes a pid's entry from the registry when dropped.
struct RemoveOnDrop<'a> {
    registry: &'a Registry,
    pid: i32,
}

impl Drop for RemoveOnDrop<'_> {
    fn drop(&mut self) {
        self.registry.map().remove(&self.pid);
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
