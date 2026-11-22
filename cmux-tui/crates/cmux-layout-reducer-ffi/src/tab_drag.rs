//! Pure tab-drag rules exposed through the app FFI.
//!
//! The tab strip still owns the drag gesture and its string/UUID models.  It
//! passes the resulting integer ids and facts to these small pure decisions.
//! Index conversion uses temporary vectors, while reveal is scalar-only.
//! The numeric outcome values are part of the C ABI and deliberately mirror
//! `TabDragOutcome` in the NEXT app; keep the match explicit when that enum
//! grows.

use std::slice;

pub const DROP_REVEAL_NONE: u8 = 0;
pub const DROP_REVEAL_FOCUSES_TAB: u8 = 1;
pub const DROP_REVEAL_SHOWS_WORKSPACE: u8 = 2;
pub const DROP_REVEAL_MAKES_KEY: u8 = 4;

/// `TabDragOutcome` values consumed by `cmux_drop_reveal_decide`.
pub const OUTCOME_CANCEL: u8 = 0;
pub const OUTCOME_STRIP: u8 = 1;
pub const OUTCOME_NEW_SPLIT: u8 = 2;
pub const OUTCOME_NEW_COLUMN: u8 = 3;
pub const OUTCOME_NEW_DOCK: u8 = 4;
pub const OUTCOME_NEW_WORKSPACE: u8 = 5;
pub const OUTCOME_WORKSPACE: u8 = 6;
pub const OUTCOME_TEAR_OFF: u8 = 7;
pub const OUTCOME_MOVE_WINDOW: u8 = 8;
pub const OUTCOME_MOVE_WORKSPACE_TO_NEW_WINDOW: u8 = 9;
pub const OUTCOME_MOVE_WORKSPACE: u8 = 10;

pub const EDGE_LEFT: u8 = 0;
pub const EDGE_RIGHT: u8 = 1;
pub const EDGE_TOP: u8 = 2;
pub const EDGE_BOTTOM: u8 = 3;
pub const EDGE_NONE: u8 = u8::MAX;

pub const ZONE_LEFT: u8 = 0;
pub const ZONE_RIGHT: u8 = 1;
pub const ZONE_TOP: u8 = 2;
pub const ZONE_BOTTOM: u8 = 3;
pub const ZONE_CENTER: u8 = 4;
pub const ZONE_NONE: u8 = u8::MAX;

pub const AXIS_HORIZONTAL: u8 = 0;
pub const AXIS_VERTICAL: u8 = 1;
pub const AXIS_NONE: u8 = u8::MAX;

fn clamp_index(index: i64, len: usize) -> usize {
    if index <= 0 {
        return 0;
    }
    // Compare before converting to usize.  Swift's Int is wider than a
    // 32-bit tab id on some hosts, and an arbitrary caller value must still
    // clamp to the end without wrapping.
    if (index as u128) >= (len as u128) { len } else { index as usize }
}

fn as_i64(value: usize) -> i64 {
    value.min(i64::MAX as usize) as i64
}

unsafe fn ids<'a>(ptr: *const u32, len: usize) -> Option<&'a [u32]> {
    if len == 0 {
        return Some(&[]);
    }
    if ptr.is_null() {
        return None;
    }
    // SAFETY: callers pass a readable array of `len` ids; this is the same
    // pointer contract used by the other typed app-FFI calls.
    Some(unsafe { slice::from_raw_parts(ptr, len) })
}

/// Convert a final (post-move) index to the daemon's pre-move wire index.
/// `has_current_index` is zero for a cross-pane move.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_tab_move_wire_index(
    final_index: i64,
    has_current_index: u8,
    current_index: i64,
) -> i64 {
    if has_current_index != 0 && final_index > current_index {
        final_index.saturating_add(1)
    } else {
        final_index.max(0)
    }
}

/// Convert a strip display index to the destination pane's daemon index.
/// Returns `-1` when a non-empty array pointer is null.
///
/// `display` and `pane` contain caller-owned UInt32 ids.  The moving id is
/// removed from both lists before applying the same insertion and lookup
/// rules as `TabMoveIndex.paneFinalIndex`.
///
/// # Safety
///
/// Each non-empty pointer must reference a readable array of the corresponding
/// length for the duration of this call. A null pointer is valid only with a
/// zero length.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_tab_move_pane_final_index(
    display: *const u32,
    display_len: usize,
    moving: u32,
    display_index: i64,
    pane: *const u32,
    pane_len: usize,
) -> i64 {
    let Some(display) = (unsafe { ids(display, display_len) }) else { return -1 };
    let Some(pane) = (unsafe { ids(pane, pane_len) }) else { return -1 };

    let mut shown: Vec<u32> = display.iter().copied().filter(|id| *id != moving).collect();
    let insertion = clamp_index(display_index, shown.len());
    shown.insert(insertion, moving);
    let others: Vec<u32> = pane.iter().copied().filter(|id| *id != moving).collect();

    let moving_index = shown.iter().position(|id| *id == moving).unwrap_or(shown.len());
    for candidate in shown.iter().skip(moving_index.saturating_add(1)) {
        if let Some(index) = others.iter().position(|id| id == candidate) {
            return as_i64(index);
        }
    }
    as_i64(others.len())
}

/// Convert a strip display index to the position inside a tab group.
/// Returns `-1` when a non-empty array pointer is null.
///
/// # Safety
///
/// Each non-empty pointer must reference a readable array of the corresponding
/// length for the duration of this call. A null pointer is valid only with a
/// zero length.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_tab_move_group_index(
    display: *const u32,
    display_len: usize,
    members: *const u32,
    members_len: usize,
    moving: u32,
    display_index: i64,
) -> i64 {
    let Some(display) = (unsafe { ids(display, display_len) }) else { return -1 };
    let Some(members) = (unsafe { ids(members, members_len) }) else { return -1 };
    let shown: Vec<u32> = display.iter().copied().filter(|id| *id != moving).collect();
    let prefix_len = clamp_index(display_index, shown.len());
    as_i64(shown[..prefix_len].iter().filter(|id| members.contains(id)).count())
}

/// Decide the client-side reveal after a tab move.
///
/// The boolean arguments are `uint8_t` for a stable C ABI (zero is false,
/// any non-zero value is true).  A zero result means no reveal.  Otherwise
/// the result is the OR of `CMUX_DROP_REVEAL_*` flags.
#[allow(clippy::too_many_arguments, reason = "flat C ABI preserves the Swift policy inputs")]
#[unsafe(no_mangle)]
pub extern "C" fn cmux_drop_reveal_decide(
    outcome: u8,
    landed: u8,
    user_initiated: u8,
    focus_requested: u8,
    files_away: u8,
    crosses_windows: u8,
    app_active: u8,
    no_activate: u8,
    landing_on_active_space: u8,
) -> u8 {
    if landed == 0 || files_away != 0 || (user_initiated == 0 && focus_requested == 0) {
        return DROP_REVEAL_NONE;
    }

    let (shows_workspace, new_window) = match outcome {
        OUTCOME_CANCEL
        | OUTCOME_MOVE_WINDOW
        | OUTCOME_MOVE_WORKSPACE_TO_NEW_WINDOW
        | OUTCOME_MOVE_WORKSPACE => return DROP_REVEAL_NONE,
        OUTCOME_STRIP | OUTCOME_NEW_SPLIT | OUTCOME_NEW_COLUMN | OUTCOME_NEW_DOCK => (false, false),
        OUTCOME_NEW_WORKSPACE | OUTCOME_WORKSPACE => (true, false),
        OUTCOME_TEAR_OFF => (true, true),
        _ => return DROP_REVEAL_NONE,
    };

    let keyable = app_active != 0 && no_activate == 0 && landing_on_active_space != 0;
    let mut flags = DROP_REVEAL_FOCUSES_TAB;
    if shows_workspace {
        flags |= DROP_REVEAL_SHOWS_WORKSPACE;
    }
    if (new_window || crosses_windows != 0) && keyable {
        flags |= DROP_REVEAL_MAKES_KEY;
    }
    flags
}

/// Map the layout's pane drop zone to the drag edge, with center represented
/// by `EDGE_NONE` because it is a join rather than a split edge.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_pane_drop_zone_edge(zone: u8) -> u8 {
    match zone {
        ZONE_LEFT => EDGE_LEFT,
        ZONE_RIGHT => EDGE_RIGHT,
        ZONE_TOP => EDGE_TOP,
        ZONE_BOTTOM => EDGE_BOTTOM,
        _ => EDGE_NONE,
    }
}

/// Map the drag edge to the daemon's pane edge.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_tab_drop_edge_pane_edge(edge: u8) -> u8 {
    match edge {
        EDGE_LEFT | EDGE_RIGHT | EDGE_TOP | EDGE_BOTTOM => edge,
        _ => EDGE_NONE,
    }
}

/// Return the edge on the far side of a pane split.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_pane_edge_opposite(edge: u8) -> u8 {
    match edge {
        EDGE_LEFT => EDGE_RIGHT,
        EDGE_RIGHT => EDGE_LEFT,
        EDGE_TOP => EDGE_BOTTOM,
        EDGE_BOTTOM => EDGE_TOP,
        _ => EDGE_NONE,
    }
}

/// Map a pane edge back to the layout's drop zone.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_pane_edge_drop_zone(edge: u8) -> u8 {
    match edge {
        EDGE_LEFT => ZONE_LEFT,
        EDGE_RIGHT => ZONE_RIGHT,
        EDGE_TOP => ZONE_TOP,
        EDGE_BOTTOM => ZONE_BOTTOM,
        _ => ZONE_NONE,
    }
}

/// Return the axis divided by a split at this pane edge.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_pane_edge_split_axis(edge: u8) -> u8 {
    match edge {
        EDGE_LEFT | EDGE_RIGHT => AXIS_HORIZONTAL,
        EDGE_TOP | EDGE_BOTTOM => AXIS_VERTICAL,
        _ => AXIS_NONE,
    }
}
