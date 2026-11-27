//! The C ABI of the close-selection state of every window's workspaces
//! (`cmux_window_close_selection_*`;
//! `cmux_focus_core::close_selection::windows::WindowCloseSelection`). Rust
//! holds the state and takes every decision: the creates a window waits for,
//! the window of each opener relation, the repairs that run, when a relation
//! ends, and the pick after a close. The app reports facts and applies the
//! pick. Workspace ids and window ids are the caller's own `u32`s (two
//! separate numberings); `CMUX_FOCUS_NONE` means none. One handle, used by
//! one thread.
//!
//! Cost: while `cmux_window_close_selection_holds_ids` is zero, every call
//! but the pick is O(1), allocates nothing and reads no array.

use crate::focus::NONE;
use cmux_focus_core::close_selection::OpenerKind;
use cmux_focus_core::close_selection::windows::{
    CreateFacts, WindowCloseSelection as State, create_relation,
};
use std::panic::{AssertUnwindSafe, catch_unwind};

mod repair;
mod settle;

pub use repair::{
    CmuxWindowClosePick, CmuxWindowCloseRepair, cmux_window_close_selection_kept,
    cmux_window_close_selection_pick, cmux_window_close_selection_repair_begin,
    cmux_window_close_selection_repair_end,
};
pub use settle::{
    CmuxWindowCloseSettle, cmux_window_close_selection_settle,
    cmux_window_close_selection_settle_questions,
};

/// The create starts no relation.
pub const RELATION_NONE: u8 = 0;
/// The quick look-up (`OpenerKind::Quick`).
pub const RELATION_QUICK: u8 = 1;
/// A relation that lasts as a link tab's (`OpenerKind::Task`).
pub const RELATION_TASK: u8 = 2;

/// The state behind one `cmux_window_close_selection_new` handle.
#[derive(Default)]
pub struct WindowCloseSelection {
    state: State<u32, u32>,
}

/// `ptr` points to `count` readable values, or `count` is 0.
unsafe fn slice<'a, T>(ptr: *const T, count: usize) -> Option<&'a [T]> {
    if count == 0 {
        return Some(&[]);
    }
    if ptr.is_null() {
        return None;
    }
    // SAFETY: guaranteed by the C caller.
    Some(unsafe { std::slice::from_raw_parts(ptr, count) })
}

fn id(value: u32) -> Option<u32> {
    (value != NONE).then_some(value)
}

/// Runs `work` on the handle's state; `fallback` for a null handle or a rule
/// that panicked.
unsafe fn with<R>(
    handle: *mut WindowCloseSelection,
    fallback: R,
    work: impl FnOnce(&mut State<u32, u32>) -> R,
) -> R {
    // SAFETY: the caller's contract (null, or a live handle used by one thread).
    let Some(holder) = (unsafe { handle.as_mut() }) else { return fallback };
    match catch_unwind(AssertUnwindSafe(|| work(&mut holder.state))) {
        Ok(result) => result,
        Err(_) => {
            // A rule that panicked may have left half a change: no relation
            // is better than a wrong one (the pick is then positional).
            holder.state = State::new();
            fallback
        }
    }
}

/// The relation a create into a window starts: `RELATION_NONE` unless the
/// create opens the New Tab page in a run that is the person's action and
/// may change the view; then `RELATION_TASK` when the placement setting puts
/// the row after the current one, else `RELATION_QUICK`. Each fact: nonzero
/// is true. Pure: no handle.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_window_close_selection_relation(
    opens_new_tab_page: u8,
    persons_action: u8,
    may_change_view: u8,
    after_current: u8,
) -> u8 {
    let facts = CreateFacts {
        opens_new_tab_page: opens_new_tab_page != 0,
        persons_action: persons_action != 0,
        may_change_view: may_change_view != 0,
        after_current: after_current != 0,
    };
    match create_relation(facts) {
        None => RELATION_NONE,
        Some(OpenerKind::Quick) => RELATION_QUICK,
        Some(OpenerKind::Task) => RELATION_TASK,
    }
}

/// The state of every window's workspaces (one for the app). Free with
/// `cmux_window_close_selection_free`.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_window_close_selection_new() -> *mut WindowCloseSelection {
    Box::into_raw(Box::default())
}

/// # Safety
///
/// `handle` is null or a live handle from `cmux_window_close_selection_new`,
/// freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_window_close_selection_free(handle: *mut WindowCloseSelection) {
    if !handle.is_null() {
        // SAFETY: the pointer came from Box::into_raw and is freed once.
        drop(unsafe { Box::from_raw(handle) });
    }
}

/// Nonzero while no opener relation is held (also for a null handle): every
/// pick is by position. O(1).
///
/// # Safety
///
/// `handle` is null or a live handle used by one thread.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_window_close_selection_is_empty(
    handle: *mut WindowCloseSelection,
) -> u8 {
    // SAFETY: the caller's contract.
    unsafe { with(handle, 1, |state| u8::from(state.is_empty())) }
}

/// Nonzero while the handle holds any workspace or window id (a create it
/// waits for, a relation, a repair that runs). While zero, `_shown`, `_left`,
/// `_renamed` and `_settle` change nothing and may be left out, and the
/// caller may forget its numbering. O(1).
///
/// # Safety
///
/// `handle` is null or a live handle used by one thread.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_window_close_selection_holds_ids(
    handle: *mut WindowCloseSelection,
) -> u8 {
    // SAFETY: the caller's contract.
    unsafe { with(handle, 0, |state| u8::from(state.holds_ids())) }
}

/// A create of `workspace` into `window` starts `relation` (the result of
/// `cmux_window_close_selection_relation`; `RELATION_NONE` or an unknown
/// value changes nothing). Call it before the window can show the workspace.
///
/// # Safety
///
/// `handle` is null or a live handle used by one thread.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_window_close_selection_expect(
    handle: *mut WindowCloseSelection,
    workspace: u32,
    window: u32,
    relation: u8,
) {
    let kind = match relation {
        RELATION_QUICK => OpenerKind::Quick,
        RELATION_TASK => OpenerKind::Task,
        _ => return,
    };
    if workspace == NONE || window == NONE {
        return;
    }
    // SAFETY: the caller's contract.
    unsafe { with(handle, (), |state| state.expect_create(&workspace, &window, kind)) }
}

/// `window` now shows `new_workspace`; it showed `old` (`CMUX_FOCUS_NONE`:
/// nothing) before. `gesture` nonzero: the code running at the change is a
/// person's own action. Inside a repair the change is never a gesture. With
/// nothing held: a few emptiness checks, no allocation.
///
/// # Safety
///
/// `handle` is null or a live handle used by one thread.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_window_close_selection_shown(
    handle: *mut WindowCloseSelection,
    new_workspace: u32,
    old: u32,
    window: u32,
    gesture: u8,
) {
    if new_workspace == NONE || window == NONE {
        return;
    }
    // SAFETY: the caller's contract.
    unsafe {
        with(handle, (), |state| {
            state.shown(&new_workspace, id(old).as_ref(), &window, gesture != 0);
        });
    }
}

/// `workspace` closed or left its window. Call it after the pick for the
/// close.
///
/// # Safety
///
/// `handle` is null or a live handle used by one thread.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_window_close_selection_left(
    handle: *mut WindowCloseSelection,
    workspace: u32,
) {
    if workspace == NONE {
        return;
    }
    // SAFETY: the caller's contract.
    unsafe { with(handle, (), |state| state.left(&workspace)) }
}

/// Window `old_window` took the identity `new_window`: its creates and
/// relations follow it.
///
/// # Safety
///
/// `handle` is null or a live handle used by one thread.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_window_close_selection_renamed(
    handle: *mut WindowCloseSelection,
    old_window: u32,
    new_window: u32,
) {
    if old_window == NONE || new_window == NONE {
        return;
    }
    // SAFETY: the caller's contract.
    unsafe { with(handle, (), |state| state.renamed(&old_window, &new_window)) }
}
