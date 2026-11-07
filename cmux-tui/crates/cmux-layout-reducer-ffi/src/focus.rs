//! The window focus machine's C ABI (`cmux_focus_*`): one handle per window
//! owns `cmux-focus-core`'s state. The app sends small typed events and a
//! topology only when it changed, and reads a typed reply the handle owns:
//! no JSON and no copy of the whole state per event, no output buffer per
//! call. JSON is only for the input journal (checkpoints, replay).
//!
//! Strings in a request are `CmuxFocusStr` ranges into the call's string
//! bytes; in a reply, ranges into the reply's `strings`. An absent string
//! has `offset == CMUX_FOCUS_NONE`. The enum values are the header's
//! `CMUX_FOCUS_*` constants.
//!
//! The handle also keeps the window's two focus memories beside the state:
//! the per-tab address bar focus (`OmnibarFocusMemory`, noted on every
//! reduction; the reply's `omnibar_return` and `returns_to_omnibar`), and
//! the pane a Close Tab press is aimed at after a close emptied a pane
//! (`PaneCloseAim`, `cmux_focus_pane_moved` and its siblings).

mod codec;
mod reply;

pub(crate) use codec::{decode_event, decode_topology};
pub use reply::FocusReply;

use cmux_focus_core::close_aim::Press;
use cmux_focus_core::event::{FocusEffect, FocusEvent};
use cmux_focus_core::state::{CloseFocusPolicy, FocusState};
use cmux_focus_core::topology::Topology;
use cmux_focus_core::window::WindowFocus;
use std::ffi::{CString, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};

pub const NONE: u32 = u32::MAX;

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CmuxFocusStr {
    pub offset: u32,
    pub len: u32,
}

impl CmuxFocusStr {
    pub const ABSENT: CmuxFocusStr = CmuxFocusStr { offset: NONE, len: 0 };
}

#[repr(C)]
pub struct CmuxFocusEvent {
    pub kind: u8,
    pub source: u8,
    pub target: u8,
    pub target_keyboard: u8,
    pub value: u8,
    pub reserved: [u8; 3],
    pub list_count: u32,
    pub reserved2: u32,
    pub generation: u64,
    pub a: CmuxFocusStr,
    pub b: CmuxFocusStr,
    pub c: CmuxFocusStr,
    pub list: *const CmuxFocusStr,
}

#[repr(C)]
pub struct CmuxFocusTab {
    pub id: CmuxFocusStr,
    pub surface: CmuxFocusStr,
    pub kind: u32,
    pub reserved: u32,
}

#[repr(C)]
pub struct CmuxFocusPane {
    pub id: CmuxFocusStr,
    pub selected: CmuxFocusStr,
    pub tab_start: u32,
    pub tab_count: u32,
}

#[repr(C)]
pub struct CmuxFocusColumn {
    pub id: CmuxFocusStr,
    pub screen: u32,
    pub pane_start: u32,
    pub pane_count: u32,
    pub reserved: u32,
}

#[repr(C)]
pub struct CmuxFocusTopology {
    pub workspace: CmuxFocusStr,
    pub panes: *const CmuxFocusPane,
    pub tabs: *const CmuxFocusTab,
    pub columns: *const CmuxFocusColumn,
    pub column_panes: *const CmuxFocusStr,
    pub pane_count: u32,
    pub tab_count: u32,
    pub column_count: u32,
    pub column_pane_count: u32,
    pub screen_count: u32,
    pub reserved: u32,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct CmuxFocusResolved {
    pub kind: u8,
    pub overlay: u8,
    pub reserved: [u8; 6],
    pub pane: CmuxFocusStr,
    pub tab: CmuxFocusStr,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct CmuxFocusEffect {
    pub kind: u8,
    pub context: u8,
    pub active: u8,
    pub reserved: [u8; 5],
    pub pane: CmuxFocusStr,
    pub tab: CmuxFocusStr,
    pub resolved: CmuxFocusResolved,
}

#[repr(C)]
pub struct CmuxFocusReply {
    pub ok: u8,
    pub changed: u8,
    pub window_key: u8,
    pub app_active: u8,
    pub sidebar_hidden: u8,
    pub target: u8,
    pub target_keyboard: u8,
    pub context: u8,
    pub browser_focus_mode_active: u8,
    pub dragging: u8,
    pub has_expectation: u8,
    pub expectation_key: u8,
    pub expectation_target: u8,
    pub expectation_target_keyboard: u8,
    /// 1: this reduction brought back a tab whose address bar had the
    /// keyboard; queue the return event (`focusTarget(addressBar,
    /// programmatic)`) after this event's effects.
    pub omnibar_return: u8,
    /// 1: this event is the queued return event: its address bar focus
    /// brings the edit back as it was instead of selecting all.
    pub returns_to_omnibar: u8,
    pub generation: u64,
    pub expectation_generation: u64,
    pub pane: CmuxFocusStr,
    pub workspace: CmuxFocusStr,
    pub expectation_id: CmuxFocusStr,
    pub expectation_away_from: CmuxFocusStr,
    pub resolved: CmuxFocusResolved,
    pub underlying: CmuxFocusResolved,
    pub overlays: *const u8,
    pub effects: *const CmuxFocusEffect,
    pub strings: *const u8,
    pub overlay_count: u32,
    pub effect_count: u32,
    pub strings_len: u32,
    pub reserved2: u32,
    /// The tab a key typed now is for (`FocusState::typing_tab`).
    pub typing_tab: CmuxFocusStr,
}

#[repr(C)]
pub struct CmuxFocusStrings {
    pub items: *const CmuxFocusStr,
    pub bytes: *const u8,
    pub count: u32,
    pub bytes_len: u32,
}

/// One window's focus machine ([`WindowFocus`], the type the input router
/// holds per window too) and the reply it last wrote.
pub struct Focus {
    window: WindowFocus,
    effects: Vec<FocusEffect>,
    out: FocusReply,
}

impl Focus {
    pub fn new() -> Focus {
        let window = WindowFocus::new();
        let out = FocusReply::new(window.state());
        Focus { window, effects: Vec::new(), out }
    }

    pub fn state(&self) -> &FocusState {
        self.window.state()
    }

    /// The reply the last call wrote.
    pub fn reply(&self) -> &CmuxFocusReply {
        self.out.reply()
    }

    /// Reduces `event`; the reply says whether the focus changed, and what
    /// the address bar memory asks for.
    pub fn send(&mut self, event: &FocusEvent) -> &CmuxFocusReply {
        let reduction = self.window.send(event, &mut self.effects);
        self.out.finish(reduction.ran, self.window.state(), &self.effects);
        self.out.set_omnibar(reduction.omnibar_return, reduction.returns_to_omnibar);
        self.out.reply()
    }

    /// A topology report; an equal topology returns at once.
    pub fn set_topology(&mut self, topology: Topology) -> &CmuxFocusReply {
        let reduction = self.window.set_topology(topology, &mut self.effects);
        self.out.finish(reduction.ran, self.window.state(), &self.effects);
        self.out.set_omnibar(reduction.omnibar_return, false);
        self.out.reply()
    }

    /// The focused pane moved from `from` to the pane the state focuses now.
    /// Returns the move's serial, for [`Focus::frame_presented`].
    pub fn pane_moved(&mut self, from: Option<&str>) -> u64 {
        self.window.pane_moved(from)
    }

    /// The frame that shows move `serial` was presented at `time` (seconds
    /// of system uptime).
    pub fn frame_presented(&mut self, serial: u64, time: f64) {
        self.window.frame_presented(serial, time);
    }

    /// `press` closed the last tab of `pane`.
    pub fn pane_emptied(&mut self, pane: &str, press: Press) {
        self.window.pane_emptied(pane, press);
    }

    /// Whether `press` is aimed at a pane a close emptied, not at the
    /// focused pane: it closes nothing, and the app shows why.
    pub fn aims_at_emptied_pane(&mut self, press: Press) -> bool {
        self.window.aims_at_emptied_pane(press)
    }

    pub fn set_close_focus(&mut self, policy: CloseFocusPolicy) {
        self.window.set_close_focus(policy);
    }

    /// Replaces the state with a journal checkpoint.
    pub fn import(&mut self, json: &[u8]) -> bool {
        if !self.window.import(json) {
            return false;
        }
        self.effects.clear();
        self.out.reset(self.window.state());
        true
    }

    /// The current reply (no event): after `import`, or on creation.
    pub fn current(&mut self) -> &CmuxFocusReply {
        self.effects.clear();
        self.out.current(self.window.state())
    }

    /// A reduction panicked part way: the state may have changed. Re-derive
    /// it (the fast paths read `derived`) and report it as it is now, with
    /// `ok` 0 and no effects.
    fn recover(&mut self) -> &CmuxFocusReply {
        self.window.rederive();
        self.effects.clear();
        self.out.recovered(self.window.state())
    }

    pub fn fail(&mut self) -> &CmuxFocusReply {
        self.out.fail()
    }

    /// The focus history of `workspace` (none: the shown one), newest first.
    pub fn recent_panes(&mut self, workspace: Option<&str>) -> &CmuxFocusStrings {
        self.out.recent_panes(self.window.state(), workspace)
    }

    /// The last focused pane of each workspace: workspace, pane, workspace,
    /// pane, ... (a window record save; not per event).
    pub fn remembered(&mut self) -> &CmuxFocusStrings {
        self.out.remembered(self.window.state())
    }
}

impl Default for Focus {
    fn default() -> Self {
        Focus::new()
    }
}

// MARK: C ABI

/// # Safety
///
/// `ptr` points to `len` readable bytes, or `len` is 0.
pub(crate) unsafe fn bytes<'a>(ptr: *const u8, len: usize) -> Option<&'a [u8]> {
    if len == 0 {
        return Some(&[]);
    }
    if ptr.is_null() {
        return None;
    }
    // SAFETY: guaranteed by the C caller.
    Some(unsafe { std::slice::from_raw_parts(ptr, len) })
}

/// A new focus machine (one per window). Free it with `cmux_focus_free`.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_focus_new() -> *mut Focus {
    Box::into_raw(Box::new(Focus::new()))
}

/// # Safety
///
/// `focus` is null or a live handle from `cmux_focus_new`, freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_focus_free(focus: *mut Focus) {
    if !focus.is_null() {
        // SAFETY: the pointer came from Box::into_raw and is freed once.
        drop(unsafe { Box::from_raw(focus) });
    }
}

/// Reduces one event. The reply stays valid until the next `cmux_focus_*`
/// call on the same handle. Null for a null handle or event.
///
/// # Safety
///
/// `focus` is a live handle used by one thread, `event` is readable, its
/// `list` points to `list_count` items, and `strings` points to
/// `strings_len` readable bytes (or the length is 0).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_focus_send(
    focus: *mut Focus,
    event: *const CmuxFocusEvent,
    strings: *const u8,
    strings_len: usize,
) -> *const CmuxFocusReply {
    if focus.is_null() || event.is_null() {
        return std::ptr::null();
    }
    // SAFETY: a live handle, used by one thread; a readable event.
    let (focus, event) = unsafe { (&mut *focus, &*event) };
    let Some(strings) = (unsafe { bytes(strings, strings_len) }) else { return focus.fail() };
    let result = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: the caller's contract.
        let event = unsafe { decode_event(event, strings) }?;
        focus.send(&event);
        Ok::<(), ()>(())
    }));
    match result {
        Ok(Ok(())) => focus.reply(),
        Ok(Err(())) => focus.fail(),
        Err(_) => focus.recover(),
    }
}

/// Reports the shown workspace's topology. A topology equal to the current
/// one changes nothing (reply `changed` 0, no effects).
///
/// # Safety
///
/// As `cmux_focus_send`; every array of `topology` holds its count of items.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_focus_set_topology(
    focus: *mut Focus,
    topology: *const CmuxFocusTopology,
    strings: *const u8,
    strings_len: usize,
) -> *const CmuxFocusReply {
    if focus.is_null() || topology.is_null() {
        return std::ptr::null();
    }
    // SAFETY: a live handle, used by one thread; a readable topology.
    let (focus, topology) = unsafe { (&mut *focus, &*topology) };
    let Some(strings) = (unsafe { bytes(strings, strings_len) }) else { return focus.fail() };
    let result = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: the caller's contract.
        let topology = unsafe { decode_topology(topology, strings) }?;
        focus.set_topology(topology);
        Ok::<(), ()>(())
    }));
    match result {
        Ok(Ok(())) => focus.reply(),
        Ok(Err(())) => focus.fail(),
        Err(_) => focus.recover(),
    }
}

/// The current state as a reply (`changed` 1, no effects).
///
/// # Safety
///
/// `focus` is null or a live handle used by one thread.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_focus_current(focus: *mut Focus) -> *const CmuxFocusReply {
    if focus.is_null() {
        return std::ptr::null();
    }
    // SAFETY: a live handle used by one thread.
    unsafe { &mut *focus }.current()
}

/// `layout.closeFocus`: 0 previous neighbor, 1 most recent.
///
/// # Safety
///
/// `focus` is null or a live handle used by one thread.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_focus_set_close_focus(focus: *mut Focus, policy: u8) {
    if focus.is_null() {
        return;
    }
    let policy =
        if policy == 1 { CloseFocusPolicy::MostRecent } else { CloseFocusPolicy::PreviousNeighbor };
    // SAFETY: a live handle used by one thread.
    unsafe { &mut *focus }.set_close_focus(policy);
}

/// 1 when `event` moves focus or selection on purpose (`FocusEvent::changes_view`),
/// 0 when not or when it does not decode.
///
/// # Safety
///
/// As `cmux_focus_send` for `event` and `strings`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_focus_changes_view(
    event: *const CmuxFocusEvent,
    strings: *const u8,
    strings_len: usize,
) -> u8 {
    if event.is_null() {
        return 0;
    }
    let Some(strings) = (unsafe { bytes(strings, strings_len) }) else { return 0 };
    catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: the caller's contract.
        unsafe { decode_event(&*event, strings) }.map_or(0, |e| u8::from(e.changes_view()))
    }))
    .unwrap_or(0)
}

/// The focus history of `workspace` (`has_workspace` 0: the shown one),
/// newest first. Valid until the next `cmux_focus_*` call on the handle.
///
/// # Safety
///
/// `focus` is a live handle used by one thread; `workspace` points to
/// `workspace_len` readable bytes (or the length is 0).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_focus_recent_panes(
    focus: *mut Focus,
    workspace: *const u8,
    workspace_len: usize,
    has_workspace: u8,
) -> *const CmuxFocusStrings {
    if focus.is_null() {
        return std::ptr::null();
    }
    // SAFETY: a live handle used by one thread.
    let focus = unsafe { &mut *focus };
    let workspace = if has_workspace == 0 {
        None
    } else {
        match unsafe { bytes(workspace, workspace_len) }.map(std::str::from_utf8) {
            Some(Ok(text)) => Some(text.to_owned()),
            _ => return std::ptr::null(),
        }
    };
    focus.recent_panes(workspace.as_deref())
}

/// The last focused pane of each workspace, as workspace, pane pairs.
/// Valid until the next `cmux_focus_*` call on the handle.
///
/// # Safety
///
/// `focus` is null or a live handle used by one thread.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_focus_remembered(focus: *mut Focus) -> *const CmuxFocusStrings {
    if focus.is_null() {
        return std::ptr::null();
    }
    // SAFETY: a live handle used by one thread.
    unsafe { &mut *focus }.remembered()
}

/// The focused pane moved from `from` (`has_from` 0: no pane had it) to the
/// pane the state focuses now. Returns the move's serial for
/// `cmux_focus_frame_presented`; 0 for a null handle or bad bytes.
///
/// # Safety
///
/// `focus` is null or a live handle used by one thread; `from` points to
/// `from_len` readable bytes (or the length is 0).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_focus_pane_moved(
    focus: *mut Focus,
    from: *const u8,
    from_len: usize,
    has_from: u8,
) -> u64 {
    if focus.is_null() {
        return 0;
    }
    // SAFETY: a live handle used by one thread.
    let focus = unsafe { &mut *focus };
    let from = if has_from == 0 {
        None
    } else {
        match unsafe { bytes(from, from_len) }.map(std::str::from_utf8) {
            Some(Ok(text)) => Some(text),
            _ => return 0,
        }
    };
    catch_unwind(AssertUnwindSafe(|| focus.pane_moved(from))).unwrap_or(0)
}

/// The frame that shows move `serial` was presented at `time` (seconds of
/// system uptime); a stamp for an older move, or a second one, changes
/// nothing.
///
/// # Safety
///
/// `focus` is null or a live handle used by one thread.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_focus_frame_presented(focus: *mut Focus, serial: u64, time: f64) {
    if focus.is_null() {
        return;
    }
    // SAFETY: a live handle used by one thread.
    unsafe { &mut *focus }.frame_presented(serial, time);
}

/// The press at `time` (`is_key` 1: a key-down; `is_repeat` 1: an
/// auto-repeat) closed the last tab of `pane`.
///
/// # Safety
///
/// `focus` is null or a live handle used by one thread; `pane` points to
/// `pane_len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_focus_pane_emptied(
    focus: *mut Focus,
    pane: *const u8,
    pane_len: usize,
    time: f64,
    is_key: u8,
    is_repeat: u8,
) {
    if focus.is_null() {
        return;
    }
    // SAFETY: a live handle used by one thread.
    let focus = unsafe { &mut *focus };
    let Some(Ok(pane)) = (unsafe { bytes(pane, pane_len) }).map(std::str::from_utf8) else {
        return;
    };
    let press = Press { time, is_key: is_key != 0, is_repeat: is_repeat != 0 };
    let _ = catch_unwind(AssertUnwindSafe(|| focus.pane_emptied(pane, press)));
}

/// 1 when the Close Tab press at `time` is aimed at a pane a close emptied,
/// not at the focused pane (it closes nothing; the app shows why), else 0.
///
/// # Safety
///
/// `focus` is null or a live handle used by one thread.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_focus_aims_at_emptied_pane(
    focus: *mut Focus,
    time: f64,
    is_key: u8,
    is_repeat: u8,
) -> u8 {
    if focus.is_null() {
        return 0;
    }
    // SAFETY: a live handle used by one thread.
    let focus = unsafe { &mut *focus };
    let press = Press { time, is_key: is_key != 0, is_repeat: is_repeat != 0 };
    catch_unwind(AssertUnwindSafe(|| u8::from(focus.aims_at_emptied_pane(press)))).unwrap_or(0)
}

/// The whole state as JSON (journal checkpoints, `debug.focus`). Free it
/// with `cmux_focus_string_free`. Not for the per-event path.
///
/// # Safety
///
/// `focus` is null or a live handle used by one thread.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_focus_export_json(focus: *mut Focus) -> *mut c_char {
    if focus.is_null() {
        return std::ptr::null_mut();
    }
    // SAFETY: a live handle used by one thread.
    let text = unsafe { &*focus }.state().export().to_string();
    CString::new(text).map_or(std::ptr::null_mut(), CString::into_raw)
}

/// Replaces the state with an exported one (journal replay). 0 when it
/// decoded, -2 when not (the state is kept).
///
/// # Safety
///
/// `focus` is a live handle used by one thread; `json` points to `json_len`
/// readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_focus_import_json(
    focus: *mut Focus,
    json: *const u8,
    json_len: usize,
) -> i32 {
    if focus.is_null() {
        return crate::ERR_NULL;
    }
    let Some(json) = (unsafe { bytes(json, json_len) }) else { return crate::ERR_NULL };
    // SAFETY: a live handle used by one thread.
    let focus = unsafe { &mut *focus };
    match catch_unwind(AssertUnwindSafe(|| focus.import(json))) {
        Ok(true) => crate::OK,
        _ => crate::ERR_INVALID,
    }
}

/// Frees a string from `cmux_focus_export_json`.
///
/// # Safety
///
/// `text` is null or a string from `cmux_focus_export_json`, freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_focus_string_free(text: *mut c_char) {
    if !text.is_null() {
        // SAFETY: the pointer came from CString::into_raw and is freed once.
        drop(unsafe { CString::from_raw(text) });
    }
}
