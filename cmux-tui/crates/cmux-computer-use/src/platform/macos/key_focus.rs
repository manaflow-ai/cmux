//! The person's keyboard while a background app's menu is open.
//!
//! An app that is not active and opens a menu (a pop-up, a menu button, a
//! context menu) takes key focus for it: AppKit's menu tracking calls
//! `SLPSStealKeyFocusReturningID`, the window server tells the app that held
//! key focus (the person's frontmost app) that it lost it, and routes the
//! keyboard to the menu until it closes. No app is activated and no window
//! moves, yet the person's typing goes to the menu (measured in a guest: a key
//! typed into the frontmost TextEdit while a System Settings pop-up was open
//! never arrived). Codex Computer Use keeps the person's typing in their app
//! with the menu open (same guest, same pop-up), so this guard does too.
//!
//! While a call opens a menu, a per-process event tap
//! (`CGEventTapCreateForPid`, public) sits on the person's app. When that app
//! is told it lost key focus (event type 21, subtype `0x4000`) to another
//! process (field 73), the tap drops the notice, so the person's window never
//! resigns key, and once the menu shows releases the theft: the window
//! server's theft ids come from one counter that only the thief learns, so a
//! steal on this process's own connection takes the next id, is released, and
//! then the newest live theft below it is released (`SLPSReleaseKeyFocusWithID`).
//! A second tap on the menu's process drops the "lost key focus" notice this
//! process's own steal sends it, or AppKit would end the menu. The menu stays
//! open and works through accessibility; the keyboard is the person's again.
//!
//! The two SkyLight calls are private (looked up at run time; without them
//! nothing is released and the menu keeps the keyboard, as before). There is
//! no public call that gives key focus back without closing the menu. The
//! technique is cua-driver's (MIT, `key_focus_guard.rs`, read as a reference).

use std::collections::HashMap;
use std::ffi::c_void;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use super::sys::symbol;

/// The window server's focus notices are this event type.
const FOCUS_NOTICE: u32 = 21;
const FIELD_SUBTYPE: u32 = 64;
const FIELD_THIEF_PID: u32 = 73;
const LOST_KEY_FOCUS: i64 = 0x4000;
const TAP_DISABLED_BY_TIMEOUT: u32 = 0xFFFF_FFFE;
const TAP_DISABLED_BY_USER_INPUT: u32 = 0xFFFF_FFFF;
/// How long after a call arms the guard a theft counts as the call's menu.
const ARMED_FOR: Duration = Duration::from_millis(2500);
/// How long the release waits for the menu window before it releases anyway.
const MENU_WAIT: Duration = Duration::from_millis(1000);
/// How long the menu's tap drops this process's own notice.
const LOOKUP_FOR: Duration = Duration::from_millis(500);
/// Older ids tried when another app stole key focus in between.
const ID_SLACK: i32 = 4;
/// The options cua-driver passes to its own steal (one that only takes the
/// next theft id; this process shows no menu).
const OWN_STEAL_OPTIONS: u32 = 0xC80;

type TapCallback = extern "C" fn(*mut c_void, u32, *mut c_void, *mut c_void) -> *mut c_void;

#[link(name = "ApplicationServices", kind = "framework")]
unsafe extern "C" {
    fn CGEventTapCreateForPid(
        pid: i32,
        place: u32,
        options: u32,
        events_of_interest: u64,
        callback: TapCallback,
        user_info: *mut c_void,
    ) -> *mut c_void;
    fn CGEventTapEnable(tap: *mut c_void, enable: bool);
    fn CGEventGetIntegerValueField(event: *mut c_void, field: u32) -> i64;
}

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFMachPortCreateRunLoopSource(
        alloc: *const c_void,
        port: *mut c_void,
        order: isize,
    ) -> *mut c_void;
    fn CFMachPortInvalidate(port: *mut c_void);
    fn CFRunLoopGetCurrent() -> *mut c_void;
    fn CFRunLoopAddSource(rl: *mut c_void, source: *mut c_void, mode: *const c_void);
    fn CFRunLoopRun();
    fn CFRunLoopStop(rl: *mut c_void);
    fn CFRelease(cf: *const c_void);
    static kCFRunLoopCommonModes: *const c_void;
}

type StealFn = unsafe extern "C" fn(u32, u32, *mut i32) -> i32;
type ReleaseFn = unsafe extern "C" fn(i32) -> i32;
type ConnectionFn = unsafe extern "C" fn() -> u32;

struct SkyLight {
    steal: StealFn,
    release: ReleaseFn,
    connection: ConnectionFn,
}

/// The private SkyLight calls, when this macOS has them.
fn skylight() -> Option<&'static SkyLight> {
    static S: OnceLock<Option<SkyLight>> = OnceLock::new();
    S.get_or_init(|| {
        // SAFETY: dlopen of a system framework path; it stays loaded.
        unsafe {
            libc::dlopen(
                c"/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight".as_ptr(),
                libc::RTLD_LAZY,
            )
        };
        let steal = symbol(c"SLPSStealKeyFocusReturningID")?;
        let release = symbol(c"SLPSReleaseKeyFocusWithID")?;
        let connection = symbol(c"SLSMainConnectionID")?;
        // SAFETY: these symbols have these signatures (cua-driver's
        // `skylight.rs`; macOS 12 through 26).
        Some(unsafe {
            SkyLight {
                steal: std::mem::transmute::<*mut c_void, StealFn>(steal),
                release: std::mem::transmute::<*mut c_void, ReleaseFn>(release),
                connection: std::mem::transmute::<*mut c_void, ConnectionFn>(connection),
            }
        })
    })
    .as_ref()
}

/// An installed tap: its port and the run loop of its thread.
struct Tap {
    port: usize,
    run_loop: usize,
}

#[derive(Default)]
struct State {
    /// The tap on the person's app, and that app's pid.
    front: Option<(i32, Tap)>,
    /// Taps on the processes whose menus took key focus.
    menus: HashMap<i32, Tap>,
    armed_until: Option<Instant>,
    lookup_until: Option<Instant>,
    released: u64,
    missed: u64,
}

fn state() -> std::sync::MutexGuard<'static, State> {
    static S: OnceLock<Mutex<State>> = OnceLock::new();
    S.get_or_init(Mutex::default).lock().unwrap_or_else(|e| e.into_inner())
}

/// What the tap on the person's app does with one event. Pure, for tests.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Notice {
    Pass,
    /// Another process's menu took key focus while a call was opening one:
    /// drop the notice and give the keyboard back.
    ReleaseAndDrop(i32),
}

pub(super) fn classify(
    event_type: u32,
    subtype: i64,
    thief: i64,
    front: i32,
    own: i32,
    armed: bool,
) -> Notice {
    if !armed || event_type != FOCUS_NOTICE || subtype != LOST_KEY_FOCUS {
        return Notice::Pass;
    }
    match i32::try_from(thief) {
        Ok(pid) if pid > 0 && pid != front && pid != own => Notice::ReleaseAndDrop(pid),
        _ => Notice::Pass,
    }
}

/// Whether the menu's tap drops one event: this process's own theft notice
/// while it looks up the menu's theft id. Pure, for tests.
pub(super) fn drops_own_notice(
    event_type: u32,
    subtype: i64,
    thief: i64,
    own: i32,
    in_lookup: bool,
) -> bool {
    in_lookup && event_type == FOCUS_NOTICE && subtype == LOST_KEY_FOCUS && thief == i64::from(own)
}

/// The newest live theft below `own` (released when `release` returns 0).
pub(super) fn release_below(own: i32, mut release: impl FnMut(i32) -> i32) -> Option<i32> {
    (1..=ID_SLACK + 1).map(|back| own.wrapping_sub(back)).find(|&id| id > 0 && release(id) == 0)
}

fn reenable(event_type: u32, port: Option<usize>) -> bool {
    if event_type == TAP_DISABLED_BY_TIMEOUT || event_type == TAP_DISABLED_BY_USER_INPUT {
        if let Some(port) = port {
            // SAFETY: a live tap port this module created.
            unsafe { CGEventTapEnable(port as *mut c_void, true) };
        }
        return true;
    }
    false
}

extern "C" fn front_tap(
    _proxy: *mut c_void,
    event_type: u32,
    event: *mut c_void,
    _info: *mut c_void,
) -> *mut c_void {
    let (front, armed, port) = {
        let st = state();
        let armed = st.armed_until.is_some_and(|t| Instant::now() < t);
        (st.front.as_ref().map_or(0, |f| f.0), armed, st.front.as_ref().map(|f| f.1.port))
    };
    if reenable(event_type, port) || event.is_null() {
        return event;
    }
    // SAFETY: a live event handed to this tap.
    let (subtype, thief) = unsafe {
        (
            CGEventGetIntegerValueField(event, FIELD_SUBTYPE),
            CGEventGetIntegerValueField(event, FIELD_THIEF_PID),
        )
    };
    match classify(event_type, subtype, thief, front, std::process::id() as i32, armed) {
        Notice::Pass => event,
        Notice::ReleaseAndDrop(thief) => {
            // The release waits for the menu window: released earlier, the
            // window server orders the menu's window group (and the target's
            // window) to the front.
            let spawned = std::thread::Builder::new()
                .name("cu-key-focus-release".into())
                .spawn(move || release_theft(thief));
            if spawned.is_ok() { std::ptr::null_mut() } else { event }
        }
    }
}

extern "C" fn menu_tap(
    _proxy: *mut c_void,
    event_type: u32,
    event: *mut c_void,
    _info: *mut c_void,
) -> *mut c_void {
    let (in_lookup, ports) = {
        let st = state();
        let ports: Vec<usize> = st.menus.values().map(|t| t.port).collect();
        (st.lookup_until.is_some_and(|t| Instant::now() < t), ports)
    };
    if event_type == TAP_DISABLED_BY_TIMEOUT || event_type == TAP_DISABLED_BY_USER_INPUT {
        for port in ports {
            reenable(event_type, Some(port));
        }
        return event;
    }
    if event.is_null() {
        return event;
    }
    // SAFETY: a live event handed to this tap.
    let (subtype, thief) = unsafe {
        (
            CGEventGetIntegerValueField(event, FIELD_SUBTYPE),
            CGEventGetIntegerValueField(event, FIELD_THIEF_PID),
        )
    };
    if drops_own_notice(event_type, subtype, thief, std::process::id() as i32, in_lookup) {
        std::ptr::null_mut()
    } else {
        event
    }
}

/// Gives the keyboard back from `thief`'s menu to the person's app.
fn release_theft(thief: i32) {
    let start = Instant::now();
    while start.elapsed() < MENU_WAIT
        && !super::cgwindows::on_screen().iter().any(|w| w.pid == thief && w.layer >= 101)
    {
        std::thread::sleep(Duration::from_millis(2));
    }
    let tapped = state().menus.contains_key(&thief);
    if !tapped && let Some(tap) = spawn_tap(thief, menu_tap) {
        let mut st = state();
        st.menus.insert(thief, tap);
        // A few menu owners at most; the oldest ones go.
        while st.menus.len() > 8 {
            let Some(old) = st.menus.keys().copied().find(|p| *p != thief) else { break };
            if let Some(t) = st.menus.remove(&old) {
                stop_tap(t);
            }
        }
    }
    let ok = skylight().is_some_and(|sl| {
        state().lookup_until = Some(Instant::now() + LOOKUP_FOR);
        let mut own = 0i32;
        // SAFETY: the SkyLight calls with their signatures; `own` is a
        // live out pointer.
        let err = unsafe { (sl.steal)((sl.connection)(), OWN_STEAL_OPTIONS, &mut own) };
        if err != 0 || own == 0 {
            return false;
        }
        // SAFETY: releasing theft ids is a plain call with an integer.
        unsafe { (sl.release)(own) };
        release_below(own, |id| unsafe { (sl.release)(id) }).is_some()
    });
    let mut st = state();
    if ok { st.released += 1 } else { st.missed += 1 }
}

/// A focus-notice tap on `pid`, on a thread of its own with a run loop.
fn spawn_tap(pid: i32, callback: TapCallback) -> Option<Tap> {
    let (tx, rx) = std::sync::mpsc::channel::<Option<(usize, usize)>>();
    let spawned = std::thread::Builder::new().name("cu-key-focus-tap".into()).spawn(move || {
        // SAFETY: plain CoreGraphics/CoreFoundation calls; every object
        // created here is released here when the run loop stops.
        unsafe {
            let port = CGEventTapCreateForPid(
                pid,
                0,
                0,
                1u64 << FOCUS_NOTICE,
                callback,
                std::ptr::null_mut(),
            );
            if port.is_null() {
                let _ = tx.send(None);
                return;
            }
            let source = CFMachPortCreateRunLoopSource(std::ptr::null(), port, 0);
            if source.is_null() {
                CFMachPortInvalidate(port);
                CFRelease(port);
                let _ = tx.send(None);
                return;
            }
            let run_loop = CFRunLoopGetCurrent();
            CFRunLoopAddSource(run_loop, source, kCFRunLoopCommonModes);
            CGEventTapEnable(port, true);
            let _ = tx.send(Some((port as usize, run_loop as usize)));
            CFRunLoopRun();
            CFMachPortInvalidate(port);
            CFRelease(source);
            CFRelease(port);
        }
    });
    if spawned.is_err() {
        return None;
    }
    match rx.recv_timeout(Duration::from_secs(2)) {
        Ok(Some((port, run_loop))) => Some(Tap { port, run_loop }),
        _ => None,
    }
}

fn stop_tap(tap: Tap) {
    // SAFETY: the run loop of a tap thread this module started; stopping it
    // ends that thread, which releases the tap.
    unsafe { CFRunLoopStop(tap.run_loop as *mut c_void) };
}

/// Arms the guard for a call about to open a menu of an app other than the
/// person's (`front_pid`, where their keys go): a theft in the next moments
/// is released. False when no tap could be placed (the menu then keeps the
/// keyboard while it is open, as without the guard).
pub(super) fn arm(front_pid: i32) -> bool {
    if skylight().is_none() {
        return false;
    }
    let placed = state().front.as_ref().is_some_and(|f| f.0 == front_pid);
    if !placed {
        let Some(tap) = spawn_tap(front_pid, front_tap) else { return false };
        if let Some((_, old)) = state().front.replace((front_pid, tap)) {
            stop_tap(old);
        }
    }
    state().armed_until = Some(Instant::now() + ARMED_FOR);
    true
}

/// Releases and thefts that could not be released, so far.
pub(super) fn counts() -> (u64, u64) {
    let st = state();
    (st.released, st.missed)
}

/// Waits up to `limit` for a release or a miss after `before` (from
/// [`counts`]): true when the keyboard went back to the person.
pub(super) fn released_since(before: (u64, u64), limit: Duration) -> bool {
    let start = Instant::now();
    loop {
        let now = counts();
        if now.0 > before.0 {
            return true;
        }
        if now.1 > before.1 || start.elapsed() >= limit {
            return false;
        }
        std::thread::sleep(Duration::from_millis(5));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const OWN: i32 = 500;
    const FRONT: i32 = 388;

    #[test]
    fn only_another_apps_theft_while_armed_is_released() {
        assert_eq!(classify(21, 0x4000, 986, FRONT, OWN, true), Notice::ReleaseAndDrop(986));
        // Not armed: no call is opening a menu; the person's own switches pass.
        assert_eq!(classify(21, 0x4000, 986, FRONT, OWN, false), Notice::Pass);
        // The person's app itself, or this process: pass.
        assert_eq!(classify(21, 0x4000, i64::from(FRONT), FRONT, OWN, true), Notice::Pass);
        assert_eq!(classify(21, 0x4000, i64::from(OWN), FRONT, OWN, true), Notice::Pass);
        // Other notices (focus returned, another type) pass.
        assert_eq!(classify(21, 0x8000, 986, FRONT, OWN, true), Notice::Pass);
        assert_eq!(classify(13, 0x4000, 986, FRONT, OWN, true), Notice::Pass);
        assert_eq!(classify(21, 0x4000, i64::MAX, FRONT, OWN, true), Notice::Pass);
        assert_eq!(classify(21, 0x4000, 0, FRONT, OWN, true), Notice::Pass);
    }

    #[test]
    fn the_menus_tap_drops_only_this_processs_notice_during_the_lookup() {
        assert!(drops_own_notice(21, 0x4000, i64::from(OWN), OWN, true));
        assert!(!drops_own_notice(21, 0x4000, i64::from(OWN), OWN, false));
        assert!(!drops_own_notice(21, 0x4000, 42, OWN, true));
        assert!(!drops_own_notice(21, 0x8000, i64::from(OWN), OWN, true));
    }

    #[test]
    fn the_menus_theft_is_the_newest_live_id_below_this_processs() {
        // Ids 131 (the menu's) is live; 132 is this process's own.
        assert_eq!(release_below(132, |id| if id == 131 { 0 } else { -1 }), Some(131));
        // Another app stole in between: the menu's is two below.
        assert_eq!(release_below(132, |id| if id == 130 { 0 } else { -1 }), Some(130));
        // Nothing live within the slack.
        assert_eq!(release_below(132, |_| -1), None);
        // Never id 0 or below.
        assert_eq!(release_below(2, |_| 0), Some(1));
        assert_eq!(release_below(1, |_| 0), None);
    }
}
