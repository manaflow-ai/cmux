//! The one close-selection rule's C ABI (`cmux_close_selection_*`): the
//! opener relations of tabs or of workspaces, and the item selected after a
//! close (`cmux_focus_core::close_selection::Openers`). One handle holds the
//! relations of every strip of one kind (every pane's tabs, or every
//! window's workspaces); each call names its strip by its items. Ids are the
//! caller's own `u32`s, stable for the handle's life; `CMUX_FOCUS_NONE`
//! means none. A handle is used by one thread.

use crate::focus::NONE;
use cmux_focus_core::close_selection::{OpenerKind, Openers};
use std::collections::{HashMap, HashSet};
use std::panic::{AssertUnwindSafe, catch_unwind};

/// A person made the item in the foreground (`OpenerKind::Quick`).
pub const QUICK: u8 = 0;
/// A link, or an action inside the opener, made the item (`OpenerKind::Task`).
pub const TASK: u8 = 1;

/// The opener relations behind one `cmux_close_selection_new` handle.
#[derive(Default)]
pub struct CloseSelection {
    openers: Openers<u32>,
}

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

/// Runs `work` on the handle's relations; `fallback` for a null handle or a
/// rule that panicked.
unsafe fn with<R>(
    handle: *mut CloseSelection,
    fallback: R,
    work: impl FnOnce(&mut Openers<u32>) -> R,
) -> R {
    // SAFETY: the caller's contract (null, or a live handle used by one thread).
    let Some(state) = (unsafe { handle.as_mut() }) else { return fallback };
    match catch_unwind(AssertUnwindSafe(|| work(&mut state.openers))) {
        Ok(result) => result,
        Err(_) => {
            // A rule that panicked may have left half a change: no relation
            // is better than a wrong one (the pick is then positional).
            state.openers = Openers::new();
            fallback
        }
    }
}

/// New opener relations (one for the app's tabs, one for its workspaces).
/// Free with `cmux_close_selection_free`.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_close_selection_new() -> *mut CloseSelection {
    Box::into_raw(Box::default())
}

/// # Safety
///
/// `handle` is null or a live handle from `cmux_close_selection_new`, freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_close_selection_free(handle: *mut CloseSelection) {
    if !handle.is_null() {
        // SAFETY: the pointer came from Box::into_raw and is freed once.
        drop(unsafe { Box::from_raw(handle) });
    }
}

/// `item` was made while `opener` (`CMUX_FOCUS_NONE`: none) was the selected
/// item of `strip`. `kind`: `CMUX_CLOSE_SELECTION_QUICK` (a person's new
/// item) or `CMUX_CLOSE_SELECTION_TASK` (a link's or a tab action's);
/// `foreground` nonzero: the new item is selected. Report nothing for an item
/// automation, a restore, a move or a drag made.
///
/// # Safety
///
/// `handle` is null or a live handle used by one thread; `strip` points to
/// `strip_count` readable ids (or the count is 0).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_close_selection_made(
    handle: *mut CloseSelection,
    item: u32,
    opener: u32,
    kind: u8,
    foreground: u8,
    strip: *const u32,
    strip_count: usize,
) {
    // SAFETY: the caller's contract.
    let Some(strip) = (unsafe { ids(strip, strip_count) }) else { return };
    if item == NONE {
        return;
    }
    let kind = if kind == TASK { OpenerKind::Task } else { OpenerKind::Quick };
    // SAFETY: the caller's contract.
    unsafe {
        with(handle, (), |openers| {
            openers.made(&item, id(opener).as_ref(), kind, foreground != 0, strip);
        });
    }
}

/// The selection of `strip` moved from `old` (`CMUX_FOCUS_NONE`: none) to
/// `new_item`. `gesture` nonzero: a person chose it (a click, a shortcut, the
/// palette, the switcher); zero for a close's own selection and automation.
/// While `cmux_close_selection_has_relations` is zero the call changes
/// nothing and may be left out (`strip` is not read).
///
/// # Safety
///
/// `handle` is null or a live handle used by one thread; `strip` points to
/// `strip_count` readable ids (or the count is 0).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_close_selection_selected(
    handle: *mut CloseSelection,
    old: u32,
    new_item: u32,
    gesture: u8,
    strip: *const u32,
    strip_count: usize,
) {
    // SAFETY: the caller's contract.
    let Some(strip) = (unsafe { ids(strip, strip_count) }) else { return };
    if new_item == NONE {
        return;
    }
    // SAFETY: the caller's contract.
    unsafe {
        with(handle, (), |openers| {
            openers.selected(id(old).as_ref(), &new_item, gesture != 0, strip);
        });
    }
}

/// A typed navigation (not a link click) in `tab` of `strip`.
///
/// # Safety
///
/// `handle` is null or a live handle used by one thread; `strip` points to
/// `strip_count` readable ids (or the count is 0).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_close_selection_typed_navigation(
    handle: *mut CloseSelection,
    tab: u32,
    strip: *const u32,
    strip_count: usize,
) {
    // SAFETY: the caller's contract.
    let Some(strip) = (unsafe { ids(strip, strip_count) }) else { return };
    if tab == NONE {
        return;
    }
    // SAFETY: the caller's contract.
    unsafe { with(handle, (), |openers| openers.typed_navigation(&tab, strip)) }
}

/// Any other navigation committed in `tab` (a link click, a redirect): its
/// next typed navigation is no longer a just-made tab's first.
///
/// # Safety
///
/// `handle` is null or a live handle used by one thread.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_close_selection_navigated(handle: *mut CloseSelection, tab: u32) {
    if tab == NONE {
        return;
    }
    // SAFETY: the caller's contract.
    unsafe { with(handle, (), |openers| openers.navigated(&tab)) }
}

/// `item` left its strip (closed, or moved): its children take its opener.
/// Call it after the pick for a close, for every item that closes.
///
/// # Safety
///
/// `handle` is null or a live handle used by one thread.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_close_selection_left(handle: *mut CloseSelection, item: u32) {
    if item == NONE {
        return;
    }
    // SAFETY: the caller's contract.
    unsafe { with(handle, (), |openers| openers.left(&item)) }
}

/// Forgets every relation of the items of `strip`.
///
/// # Safety
///
/// `handle` is null or a live handle used by one thread; `strip` points to
/// `strip_count` readable ids (or the count is 0).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_close_selection_forget_all(
    handle: *mut CloseSelection,
    strip: *const u32,
    strip_count: usize,
) {
    // SAFETY: the caller's contract.
    let Some(strip) = (unsafe { ids(strip, strip_count) }) else { return };
    // SAFETY: the caller's contract.
    unsafe { with(handle, (), |openers| openers.forget_all(strip)) }
}

/// Nonzero while the handle holds an opener relation, in any strip. While
/// it is zero a selection change needs no call and a pick is positional.
///
/// # Safety
///
/// `handle` is null or a live handle used by one thread.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_close_selection_has_relations(handle: *mut CloseSelection) -> u8 {
    // SAFETY: the caller's contract.
    unsafe { with(handle, 0, |openers| u8::from(openers.has_relations())) }
}

/// The live opener of `item`, or `CMUX_FOCUS_NONE`.
///
/// # Safety
///
/// `handle` is null or a live handle used by one thread.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_close_selection_opener(
    handle: *mut CloseSelection,
    item: u32,
) -> u32 {
    // SAFETY: the caller's contract.
    unsafe {
        with(handle, NONE, |openers| openers.opener(&item).map_or(NONE, |(opener, _)| *opener))
    }
}

/// The tab a pane selects after `selected` (`CMUX_FOCUS_NONE`: none was)
/// closed: `old` is the strip before the close, `surviving` the tabs left,
/// `shown` the surviving tabs that are not hidden, and `group_tabs[i]` is in
/// group `group_ids[i]`. Call it before `cmux_close_selection_left` for the
/// closed tabs. Returns the tab, or `CMUX_FOCUS_NONE` when none is left (or
/// an array is null). A null handle picks with no relations.
///
/// # Safety
///
/// `handle` is null or a live handle used by one thread; each pointer points
/// to its count of readable ids (or its count is 0); both group arrays hold
/// `group_count` ids.
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments, reason = "a flat C signature: each array with its count")]
pub unsafe extern "C" fn cmux_close_selection_tab(
    handle: *mut CloseSelection,
    selected: u32,
    old: *const u32,
    old_count: usize,
    surviving: *const u32,
    surviving_count: usize,
    shown: *const u32,
    shown_count: usize,
    group_tabs: *const u32,
    group_ids: *const u32,
    group_count: usize,
) -> u32 {
    // SAFETY: the caller's contract.
    let arrays = unsafe {
        (
            ids(old, old_count),
            ids(surviving, surviving_count),
            ids(shown, shown_count),
            ids(group_tabs, group_count),
            ids(group_ids, group_count),
        )
    };
    let (Some(old), Some(surviving), Some(shown), Some(tabs), Some(groups)) = arrays else {
        return NONE;
    };
    let pick = |openers: &Openers<u32>| {
        let shown: HashSet<u32> = shown.iter().copied().collect();
        let group: HashMap<u32, u32> = tabs.iter().copied().zip(groups.iter().copied()).collect();
        openers.successor(id(selected).as_ref(), old, surviving, &shown, &group).unwrap_or(NONE)
    };
    if handle.is_null() {
        return catch_unwind(AssertUnwindSafe(|| pick(&Openers::new()))).unwrap_or(NONE);
    }
    // SAFETY: the caller's contract.
    unsafe { with(handle, NONE, |openers| pick(openers)) }
}

/// The workspace a window shows after `shown` (`CMUX_FOCUS_NONE`: none was)
/// left: `old` the window's members before, `surviving` its members now,
/// `order_count` row orders, most preferred first, flattened into `orders`
/// (order `i` holds `order_lengths[i]` ids), and `group_rows[i]` is in
/// section or group `group_ids[i]`. Call it before
/// `cmux_close_selection_left` for the closed workspaces. Returns the
/// workspace, or `CMUX_FOCUS_NONE` when none is left (or an array is null).
/// A null handle picks with no relations.
///
/// # Safety
///
/// `handle` is null or a live handle used by one thread; each pointer points
/// to its count of readable ids (or its count is 0); `order_lengths` holds
/// `order_count` lengths and `orders` their sum; both group arrays hold
/// `group_count` ids.
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments, reason = "a flat C signature: each array with its count")]
pub unsafe extern "C" fn cmux_close_selection_workspace(
    handle: *mut CloseSelection,
    shown: u32,
    old: *const u32,
    old_count: usize,
    surviving: *const u32,
    surviving_count: usize,
    orders: *const u32,
    order_lengths: *const u32,
    order_count: usize,
    group_rows: *const u32,
    group_ids: *const u32,
    group_count: usize,
) -> u32 {
    // SAFETY: the caller's contract.
    let arrays = unsafe {
        (
            ids(old, old_count),
            ids(surviving, surviving_count),
            ids(order_lengths, order_count),
            ids(group_rows, group_count),
            ids(group_ids, group_count),
        )
    };
    let (Some(old), Some(surviving), Some(lengths), Some(rows), Some(groups)) = arrays else {
        return NONE;
    };
    let total = lengths.iter().try_fold(0usize, |sum, len| sum.checked_add(*len as usize));
    let Some(total) = total else { return NONE };
    // SAFETY: the caller's contract (`orders` holds the lengths' sum).
    let Some(flat) = (unsafe { ids(orders, total) }) else { return NONE };
    let pick = |openers: &Openers<u32>| {
        let mut rest = flat;
        let mut split = Vec::with_capacity(lengths.len());
        for len in lengths {
            let (order, tail) = rest.split_at(*len as usize);
            split.push(order.to_vec());
            rest = tail;
        }
        let group: HashMap<u32, u32> = rows.iter().copied().zip(groups.iter().copied()).collect();
        openers
            .successor_in_orders(id(shown).as_ref(), old, surviving, &split, &group)
            .unwrap_or(NONE)
    };
    if handle.is_null() {
        return catch_unwind(AssertUnwindSafe(|| pick(&Openers::new()))).unwrap_or(NONE);
    }
    // SAFETY: the caller's contract.
    unsafe { with(handle, NONE, |openers| pick(openers)) }
}

/// The item a background child of `opener` goes after in `order`: the last
/// of the run of its descendants that follows it, else `opener` (also for a
/// null handle or a null array); a `pinned` item never ends the run.
///
/// # Safety
///
/// `handle` is null or a live handle used by one thread; `order` points to
/// `order_count` and `pinned` to `pinned_count` readable ids (or the count
/// is 0).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_close_selection_slot(
    handle: *mut CloseSelection,
    opener: u32,
    order: *const u32,
    order_count: usize,
    pinned: *const u32,
    pinned_count: usize,
) -> u32 {
    // SAFETY: the caller's contract.
    let arrays = unsafe { (ids(order, order_count), ids(pinned, pinned_count)) };
    let (Some(order), Some(pinned)) = arrays else { return opener };
    // SAFETY: the caller's contract.
    unsafe {
        with(handle, opener, |openers| {
            let pinned: HashSet<u32> = pinned.iter().copied().collect();
            openers.slot(&opener, order, &pinned)
        })
    }
}
