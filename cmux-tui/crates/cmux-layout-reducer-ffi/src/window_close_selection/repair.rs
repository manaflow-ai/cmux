//! The pick after a close and the selection repair around it
//! (`cmux_window_close_selection_kept`, `_pick`, `_repair_begin`,
//! `_repair_end`).

use super::{State, WindowCloseSelection, id, slice, with};
use crate::focus::NONE;
use cmux_focus_core::close_selection::windows::{RepairStart, kept};
use std::panic::{AssertUnwindSafe, catch_unwind};

/// One close: `shown` left the window. `previous`: its members before;
/// `members`: its members now; `order_count` row orders before the close,
/// most preferred first (the rows as drawn, then the model's), flattened
/// into `orders` (order `i` holds `order_lengths[i]` ids).
#[repr(C)]
pub struct CmuxWindowClosePick {
    pub shown: u32,
    pub previous: *const u32,
    pub previous_count: usize,
    pub members: *const u32,
    pub member_count: usize,
    pub orders: *const u32,
    pub order_lengths: *const u32,
    pub order_count: usize,
}

/// One selection repair: the window showed `shown` (`CMUX_FOCUS_NONE`:
/// nothing) and will show `pick`. `gesture` nonzero: the caller says a person
/// asked, in this turn, for the selection of a `preferred` workspace.
/// `pressed` nonzero: the repair runs at the press of a close that hid rows
/// and that can still be cancelled or refused; zero for every other repair.
/// `members`: the window's members now; `preferred`: the workspaces just
/// moved in.
#[repr(C)]
pub struct CmuxWindowCloseRepair {
    pub shown: u32,
    pub pick: u32,
    pub gesture: u8,
    pub pressed: u8,
    pub members: *const u32,
    pub member_count: usize,
    pub preferred: *const u32,
    pub preferred_count: usize,
}

/// The selection that needs no pick: the first of `preferred` that is a
/// member, else `current` when it is a member, else `CMUX_FOCUS_NONE` (also
/// for a null array): then call `cmux_window_close_selection_pick`. Pure: no
/// handle, no allocation; it reads `members` once for `current` and once
/// for each of `preferred`.
///
/// # Safety
///
/// `members` points to `member_count` and `preferred` to `preferred_count`
/// readable ids (or the count is 0).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_window_close_selection_kept(
    current: u32,
    members: *const u32,
    member_count: usize,
    preferred: *const u32,
    preferred_count: usize,
) -> u32 {
    // SAFETY: the caller's contract.
    let arrays = unsafe { (slice(members, member_count), slice(preferred, preferred_count)) };
    let (Some(members), Some(preferred)) = arrays else { return NONE };
    kept(id(current).as_ref(), members, preferred).unwrap_or(NONE)
}

/// The row orders of `close`, split.
///
/// # Safety
///
/// `close.order_lengths` holds `close.order_count` lengths and
/// `close.orders` their sum (or the count is 0).
unsafe fn orders(close: &CmuxWindowClosePick) -> Option<Vec<Vec<u32>>> {
    // SAFETY: the caller's contract.
    let lengths = unsafe { slice(close.order_lengths, close.order_count) }?;
    let total = lengths.iter().try_fold(0usize, |sum, len| sum.checked_add(*len as usize))?;
    // SAFETY: the caller's contract (`orders` holds the lengths' sum).
    let mut rest = unsafe { slice(close.orders, total) }?;
    let mut split = Vec::with_capacity(lengths.len());
    for len in lengths {
        let (order, tail) = rest.split_at_checked(*len as usize)?;
        split.push(order.to_vec());
        rest = tail;
    }
    Some(split)
}

/// The workspace the window shows after `close.shown` left it: a workspace
/// it opened, one its opener opened, its opener, else the next row below as
/// drawn, and the row above only for the last row. A close of several
/// workspaces in one gesture is this same call (`members` holds the
/// survivors); there is no batch flag. A `shown` that is a member stays.
/// Returns `CMUX_FOCUS_NONE` when no member is left (or `close` or an array
/// is null). A null handle picks by position. Call it before
/// `cmux_window_close_selection_left` for the closed workspaces.
///
/// # Safety
///
/// `handle` is null or a live handle used by one thread; `close` is null or
/// points to a readable struct whose pointers each point to their count of
/// readable ids (or the count is 0); `order_lengths` holds `order_count`
/// lengths and `orders` their sum.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_window_close_selection_pick(
    handle: *mut WindowCloseSelection,
    close: *const CmuxWindowClosePick,
) -> u32 {
    // SAFETY: the caller's contract.
    let Some(close) = (unsafe { close.as_ref() }) else { return NONE };
    // SAFETY: the caller's contract.
    let arrays = unsafe {
        (
            slice(close.previous, close.previous_count),
            slice(close.members, close.member_count),
            orders(close),
        )
    };
    let (Some(previous), Some(members), Some(orders)) = arrays else { return NONE };
    let shown = id(close.shown);
    let pick = |state: &State<u32, u32>| {
        state.pick(shown.as_ref(), previous, members, &orders).unwrap_or(NONE)
    };
    if handle.is_null() {
        return catch_unwind(AssertUnwindSafe(|| pick(&State::new()))).unwrap_or(NONE);
    }
    // SAFETY: the caller's contract.
    unsafe { with(handle, NONE, |state| pick(state)) }
}

/// A selection repair starts: call it when `repair.pick` differs from
/// `repair.shown`, select the pick (the window reports it through
/// `cmux_window_close_selection_shown`), then call
/// `cmux_window_close_selection_repair_end`. The selection is the close's,
/// not a person's, unless `gesture` is set and `pick` is one of `preferred`.
/// A null `repair` or a null array starts a repair with no member and no
/// preferred workspace, so each begin has its end.
///
/// # Safety
///
/// `handle` is null or a live handle used by one thread; `repair` is null or
/// points to a readable struct whose pointers each point to their count of
/// readable ids (or the count is 0).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_window_close_selection_repair_begin(
    handle: *mut WindowCloseSelection,
    repair: *const CmuxWindowCloseRepair,
) {
    // SAFETY: the caller's contract.
    let repair = unsafe { repair.as_ref() };
    let shown = repair.and_then(|repair| id(repair.shown));
    let pick = repair.and_then(|repair| id(repair.pick));
    // SAFETY: the caller's contract.
    let members = repair.and_then(|repair| unsafe { slice(repair.members, repair.member_count) });
    // SAFETY: the caller's contract.
    let preferred =
        repair.and_then(|repair| unsafe { slice(repair.preferred, repair.preferred_count) });
    let start = RepairStart {
        shown: shown.as_ref(),
        pick: pick.as_ref(),
        gesture: repair.is_some_and(|repair| repair.gesture != 0),
        pressed: repair.is_some_and(|repair| repair.pressed != 0),
        members: members.unwrap_or(&[]),
        preferred: preferred.unwrap_or(&[]),
    };
    // SAFETY: the caller's contract.
    unsafe { with(handle, (), |state| state.repair_begin(&start)) }
}

/// The innermost selection repair ended. With none running it changes
/// nothing.
///
/// # Safety
///
/// `handle` is null or a live handle used by one thread.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_window_close_selection_repair_end(handle: *mut WindowCloseSelection) {
    // SAFETY: the caller's contract.
    unsafe { with(handle, (), |state| state.repair_end()) }
}
