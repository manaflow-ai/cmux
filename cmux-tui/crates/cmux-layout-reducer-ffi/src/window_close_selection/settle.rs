//! The settle after a selection repair, by question and answer
//! (`cmux_window_close_selection_settle_questions`, `_settle`): Rust says
//! which workspaces and windows it must know about, the app answers with
//! plain arrays, Rust decides who leaves the state.

use super::{WindowCloseSelection, slice, with};
use crate::focus::NONE;
use cmux_focus_core::close_selection::windows::SettleFacts;

/// The answers for `window`: `workspaces[i]` is listed now by window
/// `owners[i]` (`CMUX_FOCUS_NONE`: by none) and `claimed[i]` is nonzero when
/// it is a create its window waits for; `windows[j]` is registered when
/// `exists[j]` is nonzero. A question with no answer reads as: listed by
/// none, not claimed, not registered.
#[repr(C)]
pub struct CmuxWindowCloseSettle {
    pub window: u32,
    pub workspaces: *const u32,
    pub owners: *const u32,
    pub claimed: *const u8,
    pub workspace_count: usize,
    pub windows: *const u32,
    pub exists: *const u8,
    pub window_count: usize,
}

/// Copies the first `capacity` of `ids` to `out` (nothing for a null `out`).
///
/// # Safety
///
/// `out` is null or points to `capacity` writable ids.
unsafe fn write(ids: &[u32], out: *mut u32, capacity: usize) {
    if out.is_null() {
        return;
    }
    let count = ids.len().min(capacity);
    // SAFETY: `out` holds `capacity` writable ids and `count` is at most that.
    let out = unsafe { std::slice::from_raw_parts_mut(out, count) };
    for (slot, id) in out.iter_mut().zip(ids) {
        *slot = *id;
    }
}

/// After the repair of `window`: the workspaces and the windows the settle
/// must know about. Writes the first `capacity` workspace ids to
/// `workspaces` and the first `capacity` window ids to `windows`, never past
/// `capacity`; writes the full number of window ids to `*window_count` and
/// returns the full number of workspace ids. Both zero: the settle is done,
/// make no second call. A number above `capacity`: the arrays hold a part
/// only; call again with arrays of at least the larger number (the state
/// did not change). With nothing held (always, with no relation and no
/// create waited for): returns 0 with `*window_count` 0, in O(1), with no
/// allocation, no write to the arrays and no walk of members.
///
/// # Safety
///
/// `handle` is null or a live handle used by one thread; `workspaces` and
/// `windows` are each null or point to `capacity` writable ids;
/// `window_count` is null or points to a writable `size_t`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_window_close_selection_settle_questions(
    handle: *mut WindowCloseSelection,
    window: u32,
    workspaces: *mut u32,
    windows: *mut u32,
    capacity: usize,
    window_count: *mut usize,
) -> usize {
    // SAFETY: the caller's contract.
    let questions = unsafe {
        with(handle, None, |state| {
            (window != NONE && state.has_questions()).then(|| state.settle_questions(&window))
        })
    };
    let none: &[u32] = &[];
    let (asked, others) = questions.as_ref().map_or((none, none), |questions| {
        (questions.workspaces.as_slice(), questions.windows.as_slice())
    });
    // SAFETY: the caller's contract.
    unsafe {
        write(asked, workspaces, capacity);
        write(others, windows, capacity);
        if let Some(count) = window_count.as_mut() {
            *count = others.len();
        }
    }
    asked.len()
}

/// Ends what the answers say is gone: a workspace of `answers.window` that
/// no window lists (and that is no create its window waits for) or that
/// another window lists, and every workspace of a window that is not
/// registered. With nothing held the arrays are not read. A null `answers`
/// or a null array with a nonzero count changes nothing.
///
/// # Safety
///
/// `handle` is null or a live handle used by one thread; `answers` is null
/// or points to a readable struct; `workspaces`, `owners` and `claimed` each
/// hold `workspace_count` values and `windows` and `exists` each
/// `window_count` (or the count is 0).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_window_close_selection_settle(
    handle: *mut WindowCloseSelection,
    answers: *const CmuxWindowCloseSettle,
) {
    // SAFETY: the caller's contract.
    let Some(answers) = (unsafe { answers.as_ref() }) else { return };
    let window = answers.window;
    if window == NONE {
        return;
    }
    // SAFETY: the caller's contract. No element is read here.
    let arrays = unsafe {
        (
            slice(answers.workspaces, answers.workspace_count),
            slice(answers.owners, answers.workspace_count),
            slice(answers.claimed, answers.workspace_count),
            slice(answers.windows, answers.window_count),
            slice(answers.exists, answers.window_count),
        )
    };
    let (Some(workspaces), Some(owners), Some(claimed), Some(windows), Some(exists)) = arrays
    else {
        return;
    };
    // SAFETY: the caller's contract.
    unsafe {
        with(handle, (), |state| {
            if !state.has_questions() {
                return;
            }
            let mut facts = SettleFacts::default();
            for ((workspace, owner), claim) in workspaces.iter().zip(owners).zip(claimed) {
                if *owner != NONE {
                    facts.owner.insert(*workspace, *owner);
                }
                if *claim != 0 {
                    facts.claimed.insert(*workspace);
                }
            }
            for (other, registered) in windows.iter().zip(exists) {
                if *registered != 0 {
                    facts.existing.insert(*other);
                }
            }
            state.settle(&window, &facts);
        });
    }
}
