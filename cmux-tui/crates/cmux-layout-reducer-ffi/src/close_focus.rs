//! The close successor rules' C ABI (`cmux_close_focus_*`): the tab a pane
//! selects after its selected tab closed, the workspace a window shows after
//! its shown workspace left, and the live opener relations of a strip
//! (`cmux_focus_core::close_focus`). One call per close, no handle and no
//! JSON. Ids are the caller's own `u32`s (the app numbers its tab or
//! workspace ids for the call); `CMUX_FOCUS_NONE` means none. The rules
//! compare ids only by identity, so any numbering gives the same answer.

use crate::focus::NONE;
use cmux_focus_core::close_focus;
use std::collections::{HashMap, HashSet};
use std::panic::{AssertUnwindSafe, catch_unwind};

/// `ptr` points to `count` readable ids, or `count` is 0.
unsafe fn ids<'a>(ptr: *const u32, count: usize) -> Option<&'a [u32]> {
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

/// The tab to select after `selected` (`CMUX_FOCUS_NONE`: none was) closed:
/// `old` is the strip order before the close, `surviving` the tabs left,
/// `shown` the surviving tabs that are not hidden, and the opener relations
/// are `opener_children[i]` opened by `opener_parents[i]`. Returns the tab,
/// or `CMUX_FOCUS_NONE` when none is left (or an array is null).
///
/// # Safety
///
/// Each pointer points to its count of readable ids (or its count is 0);
/// both opener arrays hold `opener_count` ids.
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments, reason = "a flat C signature: each array with its count")]
pub unsafe extern "C" fn cmux_close_focus_tab(
    selected: u32,
    old: *const u32,
    old_count: usize,
    surviving: *const u32,
    surviving_count: usize,
    shown: *const u32,
    shown_count: usize,
    opener_children: *const u32,
    opener_parents: *const u32,
    opener_count: usize,
) -> u32 {
    // SAFETY: the caller's contract.
    let arrays = unsafe {
        (
            ids(old, old_count),
            ids(surviving, surviving_count),
            ids(shown, shown_count),
            ids(opener_children, opener_count),
            ids(opener_parents, opener_count),
        )
    };
    let (Some(old), Some(surviving), Some(shown), Some(children), Some(parents)) = arrays else {
        return NONE;
    };
    catch_unwind(AssertUnwindSafe(|| {
        let shown: HashSet<u32> = shown.iter().copied().collect();
        let opener: HashMap<u32, u32> =
            children.iter().copied().zip(parents.iter().copied()).collect();
        close_focus::tab(id(selected).as_ref(), old, surviving, &shown, &opener).unwrap_or(NONE)
    }))
    .unwrap_or(NONE)
}

/// The workspace to show after `shown` (`CMUX_FOCUS_NONE`: none was) left:
/// `old` the order before, `surviving` the workspaces the window still
/// lists, and `order_count` row orders, most preferred first, flattened into
/// `orders` (order `i` holds `order_lengths[i]` ids). Returns the workspace,
/// or `CMUX_FOCUS_NONE` when none is left (or an array is null or short).
///
/// # Safety
///
/// Each pointer points to its count of readable ids (or its count is 0);
/// `order_lengths` holds `order_count` lengths and `orders` their sum.
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments, reason = "a flat C signature: each array with its count")]
pub unsafe extern "C" fn cmux_close_focus_workspace(
    shown: u32,
    old: *const u32,
    old_count: usize,
    surviving: *const u32,
    surviving_count: usize,
    orders: *const u32,
    order_lengths: *const u32,
    order_count: usize,
) -> u32 {
    // SAFETY: the caller's contract.
    let arrays = unsafe {
        (ids(old, old_count), ids(surviving, surviving_count), ids(order_lengths, order_count))
    };
    let (Some(old), Some(surviving), Some(lengths)) = arrays else { return NONE };
    let total = lengths.iter().try_fold(0usize, |sum, len| sum.checked_add(*len as usize));
    let Some(total) = total else { return NONE };
    // SAFETY: the caller's contract (`orders` holds the lengths' sum).
    let Some(flat) = (unsafe { ids(orders, total) }) else { return NONE };
    catch_unwind(AssertUnwindSafe(|| {
        let mut rest = flat;
        let mut split = Vec::with_capacity(lengths.len());
        for len in lengths {
            let (order, tail) = rest.split_at(*len as usize);
            split.push(order.to_vec());
            rest = tail;
        }
        close_focus::workspace(id(shown).as_ref(), old, surviving, &split).unwrap_or(NONE)
    }))
    .unwrap_or(NONE)
}

/// The opener relations among `order` (`children[i]` opened by
/// `parents[i]`, possibly naming tabs that are gone), as Chrome's
/// `FixOpeners` keeps them: writes the opener of `order[i]` to
/// `parent_out[i]`, `CMUX_FOCUS_NONE` for none. Returns 0, or -1 for a null
/// pointer and -4 when the rule panicked (nothing written).
///
/// # Safety
///
/// `children` and `parents` hold `count` ids, `order` holds `order_count`
/// ids and `parent_out` has room for `order_count` ids (each may be null
/// when its count is 0).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_close_focus_live_openers(
    children: *const u32,
    parents: *const u32,
    count: usize,
    order: *const u32,
    order_count: usize,
    parent_out: *mut u32,
) -> i32 {
    // SAFETY: the caller's contract.
    let arrays = unsafe { (ids(children, count), ids(parents, count), ids(order, order_count)) };
    let (Some(children), Some(parents), Some(order)) = arrays else { return crate::ERR_NULL };
    if order_count > 0 && parent_out.is_null() {
        return crate::ERR_NULL;
    }
    let result = catch_unwind(AssertUnwindSafe(|| {
        let opener: HashMap<u32, u32> =
            children.iter().copied().zip(parents.iter().copied()).collect();
        let live = close_focus::live_openers(&opener, order);
        order.iter().map(|tab| live.get(tab).copied().unwrap_or(NONE)).collect::<Vec<u32>>()
    }));
    let Ok(parents_of) = result else { return crate::ERR_PANIC };
    if order_count > 0 {
        // SAFETY: `parent_out` has room for `order_count` ids.
        let out = unsafe { std::slice::from_raw_parts_mut(parent_out, order_count) };
        out.copy_from_slice(&parents_of);
    }
    crate::OK
}
