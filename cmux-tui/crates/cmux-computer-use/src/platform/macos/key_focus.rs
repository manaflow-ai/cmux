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
// Longer than a call's own wait for its menu (menus::OPEN_WAIT, 1.5 s).
const MENU_WAIT: Duration = Duration::from_millis(2000);
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
    fn CFRunLoopRun();
    fn CFRunLoopStop(rl: *mut c_void);
    fn CFRelease(cf: *const c_void);
    fn CFRetain(cf: *const c_void) -> *const c_void;
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
/// The macOS major versions these SkyLight signatures are known for
/// (cua-driver's `skylight.rs`): 12 through 26.
const TESTED_MAJORS: std::ops::RangeInclusive<u32> = 12..=26;

/// Whether `version` ("26.7", "27.0") is a macOS major the private calls
/// were checked on. On any other, the guard never arms and a menu holds the
/// keyboard while it shows, as Codex Computer Use's does.
pub(super) fn tested_os(version: &str) -> bool {
    version
        .split('.')
        .next()
        .and_then(|m| m.trim().parse::<u32>().ok())
        .is_some_and(|m| TESTED_MAJORS.contains(&m))
}

fn skylight() -> Option<&'static SkyLight> {
    static S: OnceLock<Option<SkyLight>> = OnceLock::new();
    S.get_or_init(|| {
        if !tested_os(&super::sys::sysctl_string(c"kern.osproductversion").unwrap_or_default()) {
            return None;
        }
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
    /// The app whose menu the armed call opens.
    target: i32,
    /// The menu windows (layer 101) on screen when the call armed.
    menus_before: Vec<u32>,
    /// The deny list, for a helper process that takes key focus.
    guard: Option<std::sync::Arc<dyn crate::desktop::MenuGuard>>,
    /// The target's window, which a helper's menu window must overlap.
    target_frame: Option<crate::desktop::Rect>,
    /// The armed call's theft, recorded when its notice is dropped. It has
    /// one owner: whoever commits to releasing it takes it (the release
    /// thread once the menu shows, or disarm when the call never saw its
    /// menu), and only the taker releases.
    theft: Option<Theft>,
    /// The call during which another app took the keyboard from the menu's
    /// owner (a lost-key notice to it from a process other than this one):
    /// the newest theft is then not the call's, so nothing is released.
    stolen_since: u64,
    /// The armed call's number (each arm is a new call): a release thread
    /// or a theft of an earlier call is ignored.
    generation: u64,
    /// The call that saw its own menu open (menu_opened): its release
    /// thread gives the keyboard back at once.
    menu_seen: u64,
    /// Whether the call is still armed (between arm and disarm).
    live: bool,
    /// What the handoff did last for the armed call, for the result's note
    /// when the keyboard was not given back.
    note: &'static str,
    lookup_until: Option<Instant>,
    /// Releases and misses of the armed call only (reset at arm), so a late
    /// give-back of an earlier call never reads as this call's.
    released: u64,
    missed: u64,
}

/// A theft the armed call may give back.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct Theft {
    pub thief: i32,
    /// The person's app the keyboard goes back to.
    pub front: i32,
    pub generation: u64,
    pub is_target: bool,
}

/// Takes the recorded theft when it is `thief`'s of call `generation`, so
/// only one party ever releases it. Pure, for tests.
pub(super) fn take_theft(slot: &mut Option<Theft>, thief: i32, generation: u64) -> Option<Theft> {
    if slot.is_some_and(|t| t.thief == thief && t.generation == generation) {
        slot.take()
    } else {
        None
    }
}

/// Whether a menu-layer window shows the call's menu: the thief's own, or a
/// new one (not there when the call armed) over the target's window (a
/// context menu's window need not be the thief's, but the person's Control
/// Center or Wi-Fi menu elsewhere is never taken for it). Pure, for tests.
pub(super) fn counts_as_call_menu(
    window: (i32, i64, u32, crate::desktop::Rect),
    thief: i32,
    before: &[u32],
    target_frame: Option<crate::desktop::Rect>,
) -> bool {
    let (pid, layer, id, frame) = window;
    layer == MENU_LAYER
        && (pid == thief
            || (!before.contains(&id)
                && target_frame.is_none_or(|f| super::menus::overlaps(&frame, &f))))
}

/// Why a release by id may not run: release_below takes the newest live
/// theft, which is the call's only when nothing else took the keyboard
/// since, and only the tap on the menu's owner can tell. Pure, for tests.
pub(super) fn release_blocked(stolen_since: bool, tap_placed: bool) -> Option<&'static str> {
    if !tap_placed {
        Some("no tap on the menu's owner could be placed")
    } else if stolen_since {
        Some("another app took the keyboard since")
    } else {
        None
    }
}

/// Held across a release's last liveness check and its SkyLight calls, and
/// by disarm, so a call cannot end in between.
fn release_lock() -> std::sync::MutexGuard<'static, ()> {
    static L: OnceLock<Mutex<()>> = OnceLock::new();
    L.get_or_init(Mutex::default).lock().unwrap_or_else(|e| e.into_inner())
}

/// Counts a release (or a miss) for call `generation`, if it is current.
fn bump(st: &mut State, generation: u64, released: bool) {
    if st.generation == generation {
        if released {
            st.released += 1;
        } else {
            st.missed += 1;
        }
    }
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

/// `menu_owner(pid)` says whether `pid` may own the armed call's menu: the
/// target app, or a helper process that is not a regular app (a System
/// Settings pane's extension draws its menus). A regular app other than the
/// target taking key focus is the person switching apps: it passes.
pub(super) fn classify(
    event_type: u32,
    subtype: i64,
    thief: i64,
    front: i32,
    own: i32,
    armed: bool,
    menu_owner: impl Fn(i32) -> bool,
) -> Notice {
    if !armed || event_type != FOCUS_NOTICE || subtype != LOST_KEY_FOCUS {
        return Notice::Pass;
    }
    match i32::try_from(thief) {
        Ok(pid) if pid > 0 && pid != front && pid != own && menu_owner(pid) => {
            Notice::ReleaseAndDrop(pid)
        }
        _ => Notice::Pass,
    }
}

/// The window layer of pop-up and context menus (`NSPopUpMenuWindowLevel`).
const MENU_LAYER: i64 = 101;

/// Whether `pid` may own the menu of a call on `target` (see [`classify`]):
/// the target itself, or a helper process (not a regular app: a System
/// Settings pane's extension) that shows a menu window it did not show
/// when the call armed. A launcher panel (Spotlight, Alfred, Raycast: also
/// not regular apps) shows no new menu-layer window, so the person's
/// notice passes and their keyboard stays where they put it.
fn may_own_menu(
    pid: i32,
    target: i32,
    before: &[u32],
    guard: Option<&dyn crate::desktop::MenuGuard>,
    target_frame: Option<crate::desktop::Rect>,
) -> bool {
    // The target's theft is the call's: its notice is dropped at once, and
    // the release thread gives the keyboard back whether or not a menu
    // window shows (a panel of its own that took key focus goes back too).
    if pid == target {
        return true;
    }
    let helper = match super::workspace::app_for_pid(pid) {
        // A denied menu-bar app's menu is never the call's.
        Some(app) => {
            !app.is_regular() && !guard.is_some_and(|g| g.app_blocked(&app.id(), &app.name))
        }
        None => !guard.is_some_and(|g| g.denies_any()),
    };
    // A helper's counts only once it shows a new menu-layer window over the
    // target's window (a launcher panel shows none).
    helper
        && super::cgwindows::on_screen().iter().any(|w| {
            new_menu_window(w.pid, w.layer, w.id, pid, before)
                && target_frame.is_none_or(|f| super::menus::overlaps(&w.frame, &f))
        })
}

/// What the release thread does once it has waited for the menu window.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum ReleasePlan {
    /// Give the keyboard back now (the menu shows).
    Now,
    /// The target's notice was dropped but no menu showed: its keyboard goes
    /// back when the call ends (disarm), not on a timer (a release before a
    /// slow menu shows would bring the target's window above the person's).
    AtDisarm,
    /// Nothing of the call's to give back.
    Miss,
}

/// Pure, for tests: only while the person's app is still in front; a
/// helper's only once its menu shows.
pub(super) fn release_plan(
    menu_shown: bool,
    thief_is_target: bool,
    person_front: bool,
) -> ReleasePlan {
    match (person_front, menu_shown, thief_is_target) {
        (false, _, _) => ReleasePlan::Miss,
        (true, true, _) => ReleasePlan::Now,
        (true, false, true) => ReleasePlan::AtDisarm,
        (true, false, false) => ReleasePlan::Miss,
    }
}

/// Whether the call's end gives the target's theft back: when the call
/// never saw its menu (a menu that was seen and closed ends its theft
/// itself), the theft is the target's, and the person's app is still in
/// front. Pure, for tests.
pub(super) fn gives_back_at_disarm(
    menu_seen: bool,
    thief_is_target: bool,
    still_front: bool,
) -> bool {
    !menu_seen && thief_is_target && still_front
}

/// Whether a window (owner, layer, id) is a menu window `pid` shows that
/// was not there when the call armed. Pure, for tests.
pub(super) fn new_menu_window(owner: i32, layer: i64, id: u32, pid: i32, before: &[u32]) -> bool {
    owner == pid && layer == MENU_LAYER && !before.contains(&id)
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
    let (front, armed, port, target, before, guard, frame, generation) = {
        let st = state();
        let armed = st.armed_until.is_some_and(|t| Instant::now() < t);
        let front = st.front.as_ref();
        let before = if armed { st.menus_before.clone() } else { Vec::new() };
        let guard = st.guard.clone();
        let port = front.map(|f| f.1.port);
        let frame = st.target_frame;
        (front.map_or(0, |f| f.0), armed, port, st.target, before, guard, frame, st.generation)
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
    let owner = |pid| may_own_menu(pid, target, &before, guard.as_deref(), frame);
    match classify(event_type, subtype, thief, front, std::process::id() as i32, armed, owner) {
        Notice::Pass => event,
        Notice::ReleaseAndDrop(thief) => {
            {
                let mut st = state();
                set_note(&mut st, generation, "the theft was seen; the release had not run yet");
                if st.generation == generation && st.theft.is_none() {
                    st.theft = Some(Theft { thief, front, generation, is_target: thief == target });
                }
            }
            // The release waits for the menu window: released earlier, the
            // window server orders the menu's window group (and the target's
            // window) to the front.
            let spawned = std::thread::Builder::new()
                .name("cu-key-focus-release".into())
                .spawn(move || release_theft(thief, front, thief == target, generation));
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
    let own = std::process::id() as i32;
    if drops_own_notice(event_type, subtype, thief, own, in_lookup) {
        return std::ptr::null_mut();
    }
    // Another app took the keyboard from the menu's owner while the call is
    // live (Spotlight, a menu-bar menu): the newest theft is not the call's.
    if event_type == FOCUS_NOTICE
        && subtype == LOST_KEY_FOCUS
        && thief > 0
        && thief != i64::from(own)
    {
        let mut st = state();
        if st.live && thief != i64::from(st.target) {
            st.stolen_since = st.generation;
        }
    }
    event
}

/// Records what the handoff did, for the call numbered `generation` only (a
/// stale thread never overwrites a later call's reason).
fn set_note(st: &mut State, generation: u64, note: &'static str) {
    if st.generation == generation {
        st.note = note;
    }
}

/// What a release thread of call `generation` may still do. Pure, for tests.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum CallState {
    /// Its call is still armed.
    Live,
    /// Its call ended (its menu was listed and closed, left open, or never
    /// showed): it gives nothing back by id any more (release_below would
    /// take the newest theft, perhaps a launcher the person opened since).
    Ended,
    /// A later call armed since.
    Stale,
}

pub(super) fn call_state(current: u64, live: bool, generation: u64) -> CallState {
    if current != generation {
        CallState::Stale
    } else if live {
        CallState::Live
    } else {
        CallState::Ended
    }
}

/// Gives the keyboard back from `thief`'s menu to the person's app, once
/// the menu shows or the call sees it open (or, for the target, when the
/// call disarms), for the call numbered `generation` only.
fn release_theft(thief: i32, front: i32, thief_is_target: bool, generation: u64) {
    // The tap on the menu's owner goes in first: it keeps this process's own
    // steal from closing the menu, and it hears another app take the
    // keyboard since (then nothing is released by id).
    place_menu_tap(thief);
    let start = Instant::now();
    let (before, target_frame) = {
        let st = state();
        (st.menus_before.clone(), st.target_frame)
    };
    let seen = || state().menu_seen == generation;
    let menu_shows = || {
        seen()
            || super::cgwindows::on_screen().iter().any(|w| {
                counts_as_call_menu((w.pid, w.layer, w.id, w.frame), thief, &before, target_frame)
            })
    };
    let current = || {
        let st = state();
        call_state(st.generation, st.live, generation)
    };
    while start.elapsed() < MENU_WAIT && current() == CallState::Live && !menu_shows() {
        std::thread::sleep(Duration::from_millis(2));
    }
    // An ended call's theft is disarm's (it gave a target theft back if it
    // never saw its menu); a later call's is not this thread's.
    if current() != CallState::Live {
        return;
    }
    let person_front = super::frontmost_pid() == Some(front);
    match release_plan(menu_shows(), thief_is_target, person_front) {
        ReleasePlan::Now => {
            // Commit: take the theft, so disarm never releases it again.
            let taken = take_theft(&mut state().theft, thief, generation);
            if taken.is_some() {
                let _release = release_lock();
                give_back_locked(thief, generation, false);
            }
        }
        // The call's end gives it back (disarm takes the recorded theft).
        ReleasePlan::AtDisarm => {
            set_note(&mut state(), generation, "no new menu window seen after the theft");
        }
        ReleasePlan::Miss => {
            let mut st = state();
            bump(&mut st, generation, false);
            let why = if person_front {
                "a helper's theft with no menu window over the target"
            } else {
                "the person's app was no longer in front"
            };
            set_note(&mut st, generation, why);
        }
    }
}

/// Places the focus-notice tap on a menu's owner, once.
fn place_menu_tap(thief: i32) {
    if state().menus.contains_key(&thief) {
        return;
    }
    let Some(tap) = spawn_tap(thief, menu_tap) else { return };
    let mut st = state();
    // Another release may have placed one meanwhile: keep the first.
    match st.menus.entry(thief) {
        std::collections::hash_map::Entry::Occupied(_) => stop_tap(tap),
        std::collections::hash_map::Entry::Vacant(slot) => {
            slot.insert(tap);
        }
    }
    // A few menu owners at most; the others go.
    while st.menus.len() > 8 {
        let Some(old) = st.menus.keys().copied().find(|p| *p != thief) else { break };
        if let Some(t) = st.menus.remove(&old) {
            stop_tap(t);
        }
    }
}

/// Releases `thief`'s key focus to the person's app (SkyLight), for the
/// call numbered `generation`, with the release lock held by the caller,
/// who took the theft: only while that call is live (except the deliberate
/// give-back as it ends, `at_disarm`), only with the tap on the owner in
/// place, and never once another app took the keyboard since (the newest
/// theft is then not the call's).
fn give_back_locked(thief: i32, generation: u64, at_disarm: bool) {
    {
        let mut st = state();
        if !at_disarm && call_state(st.generation, st.live, generation) != CallState::Live {
            return;
        }
        let stolen = st.stolen_since == generation;
        if let Some(why) = release_blocked(stolen, st.menus.contains_key(&thief)) {
            bump(&mut st, generation, false);
            set_note(&mut st, generation, why);
            return;
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
    bump(&mut st, generation, ok);
    if ok {
        set_note(&mut st, generation, "released");
    } else {
        set_note(&mut st, generation, "the SkyLight release found no theft to release");
    }
}

/// The call saw its menu open: its release thread gives the keyboard back
/// at once (it need not recognize the menu window itself).
pub(super) fn menu_opened() {
    let mut st = state();
    st.menu_seen = st.generation;
}

/// What the handoff did last for the armed call (for a result's note).
pub(super) fn note() -> &'static str {
    state().note
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
            // sys.rs declares these two for the whole crate.
            let run_loop = super::sys::CFRunLoopGetCurrent() as *mut c_void;
            super::sys::CFRunLoopAddSource(run_loop, source, kCFRunLoopCommonModes);
            CGEventTapEnable(port, true);
            // Retained for the Tap that holds it; released in stop_tap.
            CFRetain(run_loop);
            if tx.send(Some((port as usize, run_loop as usize))).is_err() {
                // The caller gave up waiting: nothing holds this tap.
                CFRelease(run_loop);
                CFMachPortInvalidate(port);
                CFRelease(source);
                CFRelease(port);
                return;
            }
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
    unsafe {
        CFRunLoopStop(tap.run_loop as *mut c_void);
        CFRelease(tap.run_loop as *const c_void);
    }
}

/// Arms the guard for a call about to open a menu of an app other than the
/// person's (`front_pid`, where their keys go): a theft in the next moments
/// is released. False when no tap could be placed (the menu then keeps the
/// keyboard while it is open, as without the guard).
pub(super) fn arm(
    front_pid: i32,
    target_pid: i32,
    target_frame: crate::desktop::Rect,
    guard: Option<std::sync::Arc<dyn crate::desktop::MenuGuard>>,
) -> bool {
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
    let before: Vec<u32> = super::cgwindows::on_screen()
        .into_iter()
        .filter(|w| w.layer == MENU_LAYER)
        .map(|w| w.id)
        .collect();
    let mut st = state();
    st.armed_until = Some(Instant::now() + ARMED_FOR);
    st.target = target_pid;
    st.menus_before = before;
    st.guard = guard;
    st.target_frame = Some(target_frame);
    st.generation += 1;
    st.live = true;
    st.theft = None;
    st.released = 0;
    st.missed = 0;
    st.note = "no lost-key notice from the person's app";
    true
}

/// Ends the armed window when the call that armed it returns.
pub(super) fn disarm() {
    let _release = release_lock();
    let (generation, theft, seen) = {
        let mut st = state();
        st.armed_until = None;
        st.live = false;
        let generation = st.generation;
        // Disarm takes whatever theft the release thread did not.
        let theft = st.theft.take().filter(|t| t.generation == generation);
        (generation, theft, st.menu_seen == generation)
    };
    // A target theft whose menu the call never saw (one that shows late, a
    // panel or list off the menu layer) goes back now, as the call ends:
    // its outcome is in. A menu that was seen and closed ended its theft.
    if let Some(t) = theft {
        let still_front = super::frontmost_pid() == Some(t.front);
        if gives_back_at_disarm(seen, t.is_target, still_front) {
            give_back_locked(t.thief, generation, true);
        } else if !seen {
            let mut st = state();
            bump(&mut st, generation, false);
            let why = if still_front {
                "a helper's theft with no menu window over the target"
            } else {
                "the person's app was no longer in front"
            };
            set_note(&mut st, generation, why);
        }
    }
}

/// Releases and thefts that could not be released, for the armed call.
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
    fn only_the_menus_theft_while_armed_is_released() {
        let owner = |pid: i32| pid == 986;
        let c = |ty, sub, thief: i64, armed| classify(ty, sub, thief, FRONT, OWN, armed, owner);
        assert_eq!(c(21, 0x4000, 986, true), Notice::ReleaseAndDrop(986));
        // Not armed: no call is opening a menu.
        assert_eq!(c(21, 0x4000, 986, false), Notice::Pass);
        // The person switching to another regular app passes.
        assert_eq!(c(21, 0x4000, 777, true), Notice::Pass);
        // The person's app itself, or this process: pass.
        assert_eq!(c(21, 0x4000, i64::from(FRONT), true), Notice::Pass);
        assert_eq!(c(21, 0x4000, i64::from(OWN), true), Notice::Pass);
        // Other notices (focus returned, another type) pass.
        assert_eq!(c(21, 0x8000, 986, true), Notice::Pass);
        assert_eq!(c(13, 0x4000, 986, true), Notice::Pass);
        assert_eq!(c(21, 0x4000, i64::MAX, true), Notice::Pass);
        assert_eq!(c(21, 0x4000, 0, true), Notice::Pass);
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
