//! The app's one input handle (`cmux_input_*`, R-INPUT stage S2): `cmux-focus-core`'s input router, which owns
//! every window's focus. The `cmux_input_focus_*` calls are the window focus handle's (`cmux_focus_*`) with a window
//! id: the same requests and the same reply bytes, because each window's focus is the same
//! [`cmux_focus_core::window::WindowFocus`] and its reply is written by the same [`FocusReply`]. A focus event goes
//! through the router (`InputRouter::send_focus`, a topology `InputRouter::set_focus_topology`), so the router sees
//! every focus change; the event, the topology and the effects are not copied on the way. The router's other effects
//! (keys, sessions, sinks) wait for stage S3, which routes keys through this handle.

use crate::focus::{
    CmuxFocusEvent, CmuxFocusReply, CmuxFocusStrings, CmuxFocusTopology, FocusReply, bytes,
    decode_event, decode_topology,
};
use cmux_focus_core::close_aim::Press;
use cmux_focus_core::event::FocusEvent;
use cmux_focus_core::input::{InputEffect, InputEvent, InputRouter, LaneLimit};
use cmux_focus_core::state::CloseFocusPolicy;
use cmux_focus_core::topology::Topology;
use std::collections::HashMap;
use std::ffi::{CString, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::Arc;

/// One open window: its id as the router keeps it, and its reply buffers. The buffers are boxed: the windows' map moves
/// its entries when it grows, and a reply the app holds for this window must stay where it is until the next call for
/// this window (one allocation per window open, none per event).
struct InputWindow {
    id: Arc<str>,
    out: Box<FocusReply>,
}

/// The input router and each open window's reply.
pub struct Input {
    router: InputRouter,
    windows: HashMap<String, InputWindow>,
}

impl Input {
    /// A handle with no window; a key lane holds at most what `memory` bytes of physical memory allow
    /// (`LaneLimit::for_memory`).
    pub fn new(memory: u64) -> Input {
        Input { router: InputRouter::new(LaneLimit::for_memory(memory)), windows: HashMap::new() }
    }

    /// Opens `window` (a second open of an open window changes nothing); its first reply, as `cmux_focus_new`'s.
    pub fn window_open(&mut self, window: &str) -> Option<&CmuxFocusReply> {
        if !self.windows.contains_key(window) {
            let id: Arc<str> = Arc::from(window);
            self.router.handle(&InputEvent::WindowOpened { window: id.clone() });
            let out = Box::new(FocusReply::new(self.router.focus(window)?));
            self.windows.insert(window.to_owned(), InputWindow { id, out });
        }
        Some(self.windows.get(window)?.out.reply())
    }

    /// Closes `window`; its replies are gone.
    pub fn window_close(&mut self, window: &str) {
        if let Some(closed) = self.windows.remove(window) {
            self.router.handle(&InputEvent::WindowClosed { window: closed.id });
        }
    }

    /// The router (tests and the stage S3 key path read it).
    pub fn router(&self) -> &InputRouter {
        &self.router
    }

    /// Reduces `event` in `window`'s focus through the router; none for a window that is not open.
    pub fn focus_send(&mut self, window: &str, event: &FocusEvent) -> Option<&CmuxFocusReply> {
        self.router.send_focus(window, event);
        self.write_reply(window)
    }

    /// A topology report for `window` (an equal topology changes nothing), as `cmux_focus_set_topology`: the
    /// topology fast path, which never asks to return to the address bar.
    pub fn focus_set_topology(
        &mut self,
        window: &str,
        topology: Topology,
    ) -> Option<&CmuxFocusReply> {
        self.router.set_focus_topology(window, topology);
        self.write_reply(window)
    }

    /// Writes `window`'s reply from the router's last effects: the window's reduction and its focus effects in order.
    fn write_reply(&mut self, window: &str) -> Option<&CmuxFocusReply> {
        let open = self.windows.get_mut(window)?;
        let effects = self.router.effects();
        let reduction = effects.iter().find_map(|effect| match effect {
            InputEffect::FocusReduced { window: of, reduction } if **of == *window => {
                Some(*reduction)
            }
            _ => None,
        })?;
        let focus = effects.iter().filter_map(|effect| match effect {
            InputEffect::Focus { window: of, effect } if **of == *window => Some(effect),
            _ => None,
        });
        open.out.finish(reduction.ran, self.router.focus(window)?, focus);
        open.out.set_omnibar(reduction.omnibar_return, reduction.returns_to_omnibar);
        Some(open.out.reply())
    }

    /// `window`'s current state as a reply (`changed` 1, no effects).
    pub fn focus_current(&mut self, window: &str) -> Option<&CmuxFocusReply> {
        let state = self.router.focus(window)?;
        Some(self.windows.get_mut(window)?.out.current(state))
    }

    /// A request for `window` that did not decode: `ok` 0.
    pub fn focus_fail(&mut self, window: &str) -> Option<&CmuxFocusReply> {
        Some(self.windows.get_mut(window)?.out.fail())
    }

    /// A reduction for `window` panicked part way: re-derive and report the state with `ok` 0.
    fn focus_recover(&mut self, window: &str) -> Option<&CmuxFocusReply> {
        self.router.rederive_focus(window);
        let state = self.router.focus(window)?;
        Some(self.windows.get_mut(window)?.out.recovered(state))
    }

    pub fn focus_set_close_focus(&mut self, window: &str, policy: CloseFocusPolicy) {
        self.router.set_close_focus(window, policy);
    }

    pub fn focus_pane_moved(&mut self, window: &str, from: Option<&str>) -> u64 {
        self.router.pane_moved(window, from)
    }

    pub fn focus_frame_presented(&mut self, window: &str, serial: u64, time: f64) {
        self.router.frame_presented(window, serial, time);
    }

    pub fn focus_pane_emptied(&mut self, window: &str, pane: &str, press: Press) {
        self.router.pane_emptied(window, pane, press);
    }

    pub fn focus_aims_at_emptied_pane(&mut self, window: &str, press: Press) -> bool {
        self.router.aims_at_emptied_pane(window, press)
    }

    /// The focus history of `workspace` (none: the shown one) in `window`, newest first.
    pub fn focus_recent_panes(
        &mut self,
        window: &str,
        workspace: Option<&str>,
    ) -> Option<&CmuxFocusStrings> {
        let state = self.router.focus(window)?;
        Some(self.windows.get_mut(window)?.out.recent_panes(state, workspace))
    }

    /// The last focused pane of each workspace of `window`, as workspace, pane pairs.
    pub fn focus_remembered(&mut self, window: &str) -> Option<&CmuxFocusStrings> {
        let state = self.router.focus(window)?;
        Some(self.windows.get_mut(window)?.out.remembered(state))
    }

    /// `window`'s whole focus state as JSON (journal checkpoints, `debug.focus`).
    pub fn focus_export(&self, window: &str) -> Option<String> {
        Some(self.router.focus(window)?.export().to_string())
    }

    /// Replaces `window`'s focus with an exported state (journal replay); false when it does not decode.
    pub fn focus_import(&mut self, window: &str, json: &[u8]) -> bool {
        if !self.windows.contains_key(window) || !self.router.import_focus(window, json) {
            return false;
        }
        match (self.router.focus(window), self.windows.get_mut(window)) {
            (Some(state), Some(open)) => {
                open.out.reset(state);
                true
            }
            _ => false,
        }
    }
}

// MARK: C ABI

/// `len` bytes at `ptr` as UTF-8.
///
/// # Safety
///
/// `ptr` points to `len` readable bytes, or `len` is 0.
unsafe fn text<'a>(ptr: *const u8, len: usize) -> Option<&'a str> {
    // SAFETY: the caller's contract.
    std::str::from_utf8(unsafe { bytes(ptr, len) }?).ok()
}

/// A new input handle (one per app). `memory` is the machine's physical memory in bytes (it bounds the key lanes).
/// Free it with `cmux_input_free`.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_input_new(memory: u64) -> *mut Input {
    Box::into_raw(Box::new(Input::new(memory)))
}

/// # Safety
///
/// `input` is null or a live handle from `cmux_input_new`, freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_input_free(input: *mut Input) {
    if !input.is_null() {
        // SAFETY: the pointer came from Box::into_raw and is freed once.
        drop(unsafe { Box::from_raw(input) });
    }
}

/// Opens a window (`window` is its id, UTF-8). The reply is its focus's first one (as `cmux_focus_new`'s
/// `cmux_focus_current`); valid until the next `cmux_input_*` call for that window. Null for a null handle or bad
/// bytes.
///
/// # Safety
///
/// `input` is null or a live handle used by one thread; `window` points to `window_len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_input_window_open(
    input: *mut Input,
    window: *const u8,
    window_len: usize,
) -> *const CmuxFocusReply {
    if input.is_null() {
        return std::ptr::null();
    }
    // SAFETY: a live handle used by one thread; the caller's contract for the bytes.
    let (input, Some(window)) = (unsafe { &mut *input }, unsafe { text(window, window_len) })
    else {
        return std::ptr::null();
    };
    catch_unwind(AssertUnwindSafe(|| reply(input.window_open(window)))).unwrap_or(std::ptr::null())
}

/// Closes a window.
///
/// # Safety
///
/// As `cmux_input_window_open`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_input_window_close(
    input: *mut Input,
    window: *const u8,
    window_len: usize,
) {
    if input.is_null() {
        return;
    }
    // SAFETY: a live handle used by one thread; the caller's contract for the bytes.
    let (input, Some(window)) = (unsafe { &mut *input }, unsafe { text(window, window_len) })
    else {
        return;
    };
    let _ = catch_unwind(AssertUnwindSafe(|| input.window_close(window)));
}

/// `cmux_focus_send` for one window. Null for a null handle or event, bad bytes or a window that is not open.
///
/// # Safety
///
/// As `cmux_input_window_open` for `window`, and as `cmux_focus_send` for `event` and `strings`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_input_focus_send(
    input: *mut Input,
    window: *const u8,
    window_len: usize,
    event: *const CmuxFocusEvent,
    strings: *const u8,
    strings_len: usize,
) -> *const CmuxFocusReply {
    if input.is_null() || event.is_null() {
        return std::ptr::null();
    }
    // SAFETY: a live handle used by one thread; a readable event; the caller's contract for the bytes.
    let (input, event) = unsafe { (&mut *input, &*event) };
    let Some(window) = (unsafe { text(window, window_len) }) else { return std::ptr::null() };
    if !input.windows.contains_key(window) {
        return std::ptr::null();
    }
    let Some(strings) = (unsafe { bytes(strings, strings_len) }) else {
        return reply(input.focus_fail(window));
    };
    let result = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: the caller's contract.
        let event = unsafe { decode_event(event, strings) }?;
        input.focus_send(window, &event).map(|_| ()).ok_or(())
    }));
    match result {
        Ok(Ok(())) => reply(input.windows.get(window).map(|open| open.out.reply())),
        Ok(Err(())) => reply(input.focus_fail(window)),
        Err(_) => reply(input.focus_recover(window)),
    }
}

/// `cmux_focus_set_topology` for one window.
///
/// # Safety
///
/// As `cmux_input_focus_send`; every array of `topology` holds its count of items.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_input_focus_set_topology(
    input: *mut Input,
    window: *const u8,
    window_len: usize,
    topology: *const CmuxFocusTopology,
    strings: *const u8,
    strings_len: usize,
) -> *const CmuxFocusReply {
    if input.is_null() || topology.is_null() {
        return std::ptr::null();
    }
    // SAFETY: a live handle used by one thread; a readable topology; the caller's contract for the bytes.
    let (input, topology) = unsafe { (&mut *input, &*topology) };
    let Some(window) = (unsafe { text(window, window_len) }) else { return std::ptr::null() };
    if !input.windows.contains_key(window) {
        return std::ptr::null();
    }
    let Some(strings) = (unsafe { bytes(strings, strings_len) }) else {
        return reply(input.focus_fail(window));
    };
    let result = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: the caller's contract.
        let topology = unsafe { decode_topology(topology, strings) }?;
        input.focus_set_topology(window, topology).map(|_| ()).ok_or(())
    }));
    match result {
        Ok(Ok(())) => reply(input.windows.get(window).map(|open| open.out.reply())),
        Ok(Err(())) => reply(input.focus_fail(window)),
        Err(_) => reply(input.focus_recover(window)),
    }
}

/// `cmux_focus_current` for one window.
///
/// # Safety
///
/// As `cmux_input_window_open`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_input_focus_current(
    input: *mut Input,
    window: *const u8,
    window_len: usize,
) -> *const CmuxFocusReply {
    if input.is_null() {
        return std::ptr::null();
    }
    // SAFETY: a live handle used by one thread; the caller's contract for the bytes.
    let (input, Some(window)) = (unsafe { &mut *input }, unsafe { text(window, window_len) })
    else {
        return std::ptr::null();
    };
    reply(input.focus_current(window))
}

/// `cmux_focus_set_close_focus` for one window.
///
/// # Safety
///
/// As `cmux_input_window_open`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_input_focus_set_close_focus(
    input: *mut Input,
    window: *const u8,
    window_len: usize,
    policy: u8,
) {
    if input.is_null() {
        return;
    }
    // SAFETY: a live handle used by one thread; the caller's contract for the bytes.
    let (input, Some(window)) = (unsafe { &mut *input }, unsafe { text(window, window_len) })
    else {
        return;
    };
    let policy =
        if policy == 1 { CloseFocusPolicy::MostRecent } else { CloseFocusPolicy::PreviousNeighbor };
    input.focus_set_close_focus(window, policy);
}

/// `cmux_focus_recent_panes` for one window.
///
/// # Safety
///
/// As `cmux_input_window_open`; `workspace` points to `workspace_len` readable bytes (or the length is 0).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_input_focus_recent_panes(
    input: *mut Input,
    window: *const u8,
    window_len: usize,
    workspace: *const u8,
    workspace_len: usize,
    has_workspace: u8,
) -> *const CmuxFocusStrings {
    if input.is_null() {
        return std::ptr::null();
    }
    // SAFETY: a live handle used by one thread; the caller's contract for the bytes.
    let (input, Some(window)) = (unsafe { &mut *input }, unsafe { text(window, window_len) })
    else {
        return std::ptr::null();
    };
    let workspace = if has_workspace == 0 {
        None
    } else {
        // SAFETY: the caller's contract.
        match unsafe { text(workspace, workspace_len) } {
            Some(text) => Some(text),
            None => return std::ptr::null(),
        }
    };
    input
        .focus_recent_panes(window, workspace)
        .map_or(std::ptr::null(), |list| list as *const CmuxFocusStrings)
}

/// `cmux_focus_remembered` for one window.
///
/// # Safety
///
/// As `cmux_input_window_open`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_input_focus_remembered(
    input: *mut Input,
    window: *const u8,
    window_len: usize,
) -> *const CmuxFocusStrings {
    if input.is_null() {
        return std::ptr::null();
    }
    // SAFETY: a live handle used by one thread; the caller's contract for the bytes.
    let (input, Some(window)) = (unsafe { &mut *input }, unsafe { text(window, window_len) })
    else {
        return std::ptr::null();
    };
    input.focus_remembered(window).map_or(std::ptr::null(), |list| list as *const CmuxFocusStrings)
}

/// `cmux_focus_pane_moved` for one window (0 for a window that is not open or bad bytes).
///
/// # Safety
///
/// As `cmux_input_window_open`; `from` points to `from_len` readable bytes (or the length is 0).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_input_focus_pane_moved(
    input: *mut Input,
    window: *const u8,
    window_len: usize,
    from: *const u8,
    from_len: usize,
    has_from: u8,
) -> u64 {
    if input.is_null() {
        return 0;
    }
    // SAFETY: a live handle used by one thread; the caller's contract for the bytes.
    let (input, Some(window)) = (unsafe { &mut *input }, unsafe { text(window, window_len) })
    else {
        return 0;
    };
    let from = if has_from == 0 {
        None
    } else {
        // SAFETY: the caller's contract.
        match unsafe { text(from, from_len) } {
            Some(text) => Some(text),
            None => return 0,
        }
    };
    catch_unwind(AssertUnwindSafe(|| input.focus_pane_moved(window, from))).unwrap_or(0)
}

/// `cmux_focus_frame_presented` for one window.
///
/// # Safety
///
/// As `cmux_input_window_open`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_input_focus_frame_presented(
    input: *mut Input,
    window: *const u8,
    window_len: usize,
    serial: u64,
    time: f64,
) {
    if input.is_null() {
        return;
    }
    // SAFETY: a live handle used by one thread; the caller's contract for the bytes.
    let (input, Some(window)) = (unsafe { &mut *input }, unsafe { text(window, window_len) })
    else {
        return;
    };
    input.focus_frame_presented(window, serial, time);
}

/// `cmux_focus_pane_emptied` for one window.
///
/// # Safety
///
/// As `cmux_input_window_open`; `pane` points to `pane_len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_input_focus_pane_emptied(
    input: *mut Input,
    window: *const u8,
    window_len: usize,
    pane: *const u8,
    pane_len: usize,
    time: f64,
    is_key: u8,
    is_repeat: u8,
) {
    if input.is_null() {
        return;
    }
    // SAFETY: a live handle used by one thread; the caller's contract for the bytes.
    let (input, Some(window), Some(pane)) =
        (unsafe { &mut *input }, unsafe { text(window, window_len) }, unsafe {
            text(pane, pane_len)
        })
    else {
        return;
    };
    let press = Press { time, is_key: is_key != 0, is_repeat: is_repeat != 0 };
    let _ = catch_unwind(AssertUnwindSafe(|| input.focus_pane_emptied(window, pane, press)));
}

/// `cmux_focus_aims_at_emptied_pane` for one window.
///
/// # Safety
///
/// As `cmux_input_window_open`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_input_focus_aims_at_emptied_pane(
    input: *mut Input,
    window: *const u8,
    window_len: usize,
    time: f64,
    is_key: u8,
    is_repeat: u8,
) -> u8 {
    if input.is_null() {
        return 0;
    }
    // SAFETY: a live handle used by one thread; the caller's contract for the bytes.
    let (input, Some(window)) = (unsafe { &mut *input }, unsafe { text(window, window_len) })
    else {
        return 0;
    };
    let press = Press { time, is_key: is_key != 0, is_repeat: is_repeat != 0 };
    catch_unwind(AssertUnwindSafe(|| u8::from(input.focus_aims_at_emptied_pane(window, press))))
        .unwrap_or(0)
}

/// `cmux_focus_export_json` for one window. Free it with `cmux_focus_string_free`.
///
/// # Safety
///
/// As `cmux_input_window_open`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_input_focus_export_json(
    input: *mut Input,
    window: *const u8,
    window_len: usize,
) -> *mut c_char {
    if input.is_null() {
        return std::ptr::null_mut();
    }
    // SAFETY: a live handle used by one thread; the caller's contract for the bytes.
    let (input, Some(window)) = (unsafe { &*input }, unsafe { text(window, window_len) }) else {
        return std::ptr::null_mut();
    };
    input
        .focus_export(window)
        .and_then(|text| CString::new(text).ok())
        .map_or(std::ptr::null_mut(), CString::into_raw)
}

/// `cmux_focus_import_json` for one window: 0 when it decoded, -2 when not (the state is kept).
///
/// # Safety
///
/// As `cmux_input_window_open`; `json` points to `json_len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_input_focus_import_json(
    input: *mut Input,
    window: *const u8,
    window_len: usize,
    json: *const u8,
    json_len: usize,
) -> i32 {
    if input.is_null() {
        return crate::ERR_NULL;
    }
    // SAFETY: a live handle used by one thread; the caller's contract for the bytes.
    let (input, Some(window), Some(json)) =
        (unsafe { &mut *input }, unsafe { text(window, window_len) }, unsafe {
            bytes(json, json_len)
        })
    else {
        return crate::ERR_NULL;
    };
    match catch_unwind(AssertUnwindSafe(|| input.focus_import(window, json))) {
        Ok(true) => crate::OK,
        _ => crate::ERR_INVALID,
    }
}

fn reply(reply: Option<&CmuxFocusReply>) -> *const CmuxFocusReply {
    reply.map_or(std::ptr::null(), |reply| reply as *const CmuxFocusReply)
}
