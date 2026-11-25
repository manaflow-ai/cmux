//! The C ABI of the sidebar's per-project caps and its "Needs you" section
//! (`cmux_layout_reducer::sidebar_caps`, Leo 2026-11-10). The sidebar passes
//! a project's member count and only its active members, and gets the member
//! indices to draw and the tail row ("Show N more", "Show less"); the work is
//! the rows drawn, never the hidden ones.

use crate::{ERR_BUFFER, ERR_NULL, OK};
use cmux_layout_reducer::sidebar_caps::{self, Active, ProjectCaps, Tail};
use std::slice;

/// One active member (`CmuxSidebarActive`): its index and its `flag` bits.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct CmuxSidebarActive {
    pub index: u32,
    pub flags: u8,
    pub reserved: [u8; 3],
}

/// `CmuxSidebarCaps`: the cap (0 All), the rows revealed, and two booleans (0 false).
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct CmuxSidebarCaps {
    pub cap: u32,
    pub revealed: u32,
    pub floats: u8,
    pub include_working: u8,
    pub reserved: [u8; 2],
}

pub const TAIL_NONE: u8 = 0;
pub const TAIL_SHOW_MORE: u8 = 1;
pub const TAIL_SHOW_LESS: u8 = 2;

/// `CmuxSidebarProjectTail`: the tail row, the rows written (or needed), and
/// how many rows floated.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct CmuxSidebarProjectTail {
    pub kind: u8,
    pub reserved: [u8; 3],
    pub hidden: u32,
    pub next: u32,
    pub floated: u32,
    pub rows: u32,
    /// What one press of the tail row stores as the project's revealed count.
    pub revealed_after_press: u32,
}

unsafe fn actives(ptr: *const CmuxSidebarActive, len: usize) -> Option<Vec<Active>> {
    if len == 0 {
        return Some(Vec::new());
    }
    if ptr.is_null() {
        return None;
    }
    // SAFETY: the caller passes a readable array of `len` entries for this call.
    let entries = unsafe { slice::from_raw_parts(ptr, len) };
    Some(entries.iter().map(|e| Active { index: e.index, flags: e.flags }).collect())
}

unsafe fn write(rows: &[u32], out: *mut u32, capacity: usize) -> i32 {
    if rows.len() > capacity {
        return ERR_BUFFER;
    }
    if rows.is_empty() {
        return OK;
    }
    if out.is_null() {
        return ERR_NULL;
    }
    // SAFETY: the caller provides at least `capacity` writable entries.
    unsafe { std::ptr::copy_nonoverlapping(rows.as_ptr(), out, rows.len()) };
    OK
}

/// A project's drawn member indices into `out` and its tail into `tail`.
/// `active` is ascending by index. Returns OK, ERR_NULL for a null `caps` or
/// `tail` (or a null array with a non-zero length), or ERR_BUFFER when
/// `out_capacity` is short: `tail.rows` then holds the count needed.
///
/// # Safety
/// Every non-null pointer must be valid for its length for this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_sidebar_project_rows(
    count: u32,
    active: *const CmuxSidebarActive,
    active_len: usize,
    caps: *const CmuxSidebarCaps,
    out: *mut u32,
    out_capacity: usize,
    tail: *mut CmuxSidebarProjectTail,
) -> i32 {
    if caps.is_null() || tail.is_null() {
        return ERR_NULL;
    }
    let Some(active) = (unsafe { actives(active, active_len) }) else { return ERR_NULL };
    // SAFETY: checked non-null; the caller owns it for this call.
    let c = unsafe { *caps };
    let caps = ProjectCaps {
        cap: c.cap,
        revealed: c.revealed,
        floats: c.floats != 0,
        include_working: c.include_working != 0,
    };
    let projected = sidebar_caps::project_rows(count, &active, &caps);
    let (kind, hidden, next) = match projected.tail {
        Tail::None => (TAIL_NONE, 0, 0),
        Tail::ShowMore { hidden, next } => (TAIL_SHOW_MORE, hidden, next),
        Tail::ShowLess => (TAIL_SHOW_LESS, 0, 0),
    };
    let answer = CmuxSidebarProjectTail {
        kind,
        reserved: [0; 3],
        hidden,
        next,
        floated: projected.floated,
        rows: projected.rows.len() as u32,
        revealed_after_press: sidebar_caps::after_press(projected.tail, &caps),
    };
    // SAFETY: checked non-null and writable.
    unsafe { *tail = answer };
    unsafe { write(&projected.rows, out, out_capacity) }
}

/// The "Needs you" section's rows (drawn places) into `out`, at most `limit`
/// (0: three), and the rows past it into `more`. `rows` are the sidebar's
/// active rows in drawn order. Returns OK, ERR_NULL or ERR_BUFFER
/// (`out_len` then holds the count needed).
///
/// # Safety
/// Every non-null pointer must be valid for its length for this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_sidebar_needs_you(
    rows: *const CmuxSidebarActive,
    rows_len: usize,
    include_working: u8,
    limit: u32,
    out: *mut u32,
    out_capacity: usize,
    out_len: *mut usize,
    more: *mut u32,
) -> i32 {
    if out_len.is_null() || more.is_null() {
        return ERR_NULL;
    }
    let Some(rows) = (unsafe { actives(rows, rows_len) }) else { return ERR_NULL };
    let answer = sidebar_caps::needs_you(&rows, include_working != 0, limit);
    // SAFETY: checked non-null and writable.
    unsafe {
        *out_len = answer.rows.len();
        *more = answer.more;
    }
    unsafe { write(&answer.rows, out, out_capacity) }
}
