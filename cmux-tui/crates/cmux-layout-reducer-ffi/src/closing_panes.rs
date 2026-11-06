//! The springing-close rules' C ABI (`cmux_closing_panes_*`, cmux-layout-reducer `closing_panes`): which panes border a
//! closing pane and the gaps it keeps (`begin`), the panes nothing moves over (`settle`), where every closing pane
//! shows this frame (`rects`, per display frame during a close), the strip's carries and a row column's stop, and a
//! taken-back close (`remove`). One handle per screen (`cmux_closing_panes_new`) owns the closing panes; panes, scroll
//! areas and row columns are numbers the caller hands out (0: none). Typed structs in, typed answers out, no JSON. A
//! call allocates nothing once the handle's buffers have grown to the screen's size (it reuses them per frame).
//!
//! Return codes: `begin` and `remove` return 1 when they answer (the pane starts closing; the pane was closing) and 0
//! when they do not, with nothing written. 1 and 0 are answers, not `CMUX_LAYOUT_REDUCER_OK` (also 0): a caller checks
//! for 1. `settle` and `rects` return `CMUX_LAYOUT_REDUCER_OK` and write a list that borrows the handle's buffer, valid
//! until the next call on the same handle. Every call returns `ERR_NULL` (a null pointer where the call reads or
//! writes), `ERR_INVALID` (an unknown handle kind) or `ERR_PANIC` with nothing written.
//!
//! Safety, for every call: `closing` is a live handle from `cmux_closing_panes_new`, used by one thread at a time;
//! each input array holds `count` initialized elements; an `out` pointer is valid for one write of its type and does
//! not overlap any input array or the handle.

use crate::{ERR_INVALID, ERR_NULL, ERR_PANIC, OK};
use cmux_layout_reducer::closing_panes::{
    ClosingPanes, Edges, FrameFact, HandleFact, HandleKind, PaneFact, Placed, RowTravel,
};
use std::panic::{AssertUnwindSafe, catch_unwind};

pub const HANDLE_SPLIT: u8 = 0;
pub const HANDLE_COLUMN_EDGE: u8 = 1;
pub const HANDLE_ROW_EDGE: u8 = 2;

/// A rect's sides (`CmuxClosingEdges`).
pub type CmuxClosingEdges = Edges;
/// A rect: `x`, `y`, `width`, `height` (`CmuxClosingRect`).
pub type CmuxClosingRect = Placed;

/// One pane of the layout a close left (`CmuxClosingPane`). `area`, `row_column`: 0 for none; `scrolls`: 0 or 1.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct CmuxClosingPane {
    pub id: u64,
    pub area: u64,
    pub row_column: u64,
    pub edges: Edges,
    pub scrolls: u8,
    pub reserved: [u8; 7],
}

/// One resize handle of that layout (`CmuxClosingHandle`): `kind` is `CMUX_CLOSING_HANDLE_*`; flags are 0 or 1.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct CmuxClosingHandle {
    pub hit: Edges,
    pub mid_x: f64,
    pub mid_y: f64,
    /// A split's scroll area (0: none).
    pub area: u64,
    /// A row edge's column.
    pub column: u64,
    pub kind: u8,
    /// Its axis is horizontal (side by side).
    pub horizontal: u8,
    /// The new layout has it.
    pub kept: u8,
    /// A split of the fixed (unscrolled) part.
    pub fixed_split: u8,
    /// A column edge of a dock.
    pub docked: u8,
    pub reserved: [u8; 3],
}

/// A live pane's frame this frame (`CmuxClosingFrame`): `moving` is 1 while its spring moves.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct CmuxClosingFrame {
    pub id: u64,
    pub now: Edges,
    pub target: Edges,
    pub vx: f64,
    pub vy: f64,
    pub vw: f64,
    pub vh: f64,
    pub moving: u8,
    pub reserved: [u8; 7],
}

/// Where a row column's scroll is and rests (`CmuxClosingRow`).
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct CmuxClosingRow {
    pub column: u64,
    pub now: f64,
    pub target: f64,
}

/// A closing pane's frame this frame (`CmuxClosingPlaced`).
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct CmuxClosingPlaced {
    pub pane: u64,
    pub rect: Placed,
}

/// Where a taken-back close starts and its sides' velocities (`CmuxClosingTaken`).
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct CmuxClosingTaken {
    pub rect: Placed,
    pub vx: f64,
    pub vw: f64,
    pub vy: f64,
    pub vh: f64,
}

/// A list that borrows the handle's buffer (`CmuxClosingIds`, `CmuxClosingPlacedList`).
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CmuxClosingIds {
    pub ids: *const u64,
    pub count: usize,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CmuxClosingPlacedList {
    pub placed: *const CmuxClosingPlaced,
    pub count: usize,
}

/// One screen's closing panes and the buffers its calls reuse.
#[derive(Default)]
pub struct CmuxClosingPanes {
    rules: ClosingPanes,
    panes: Vec<PaneFact>,
    handles: Vec<HandleFact>,
    frames: Vec<FrameFact>,
    rows: Vec<RowTravel>,
    still: Vec<u64>,
    placed: Vec<CmuxClosingPlaced>,
}

impl CmuxClosingPanes {
    fn read_frames(&mut self, frames: &[CmuxClosingFrame]) {
        self.frames.clear();
        self.frames.extend(frames.iter().map(|f| FrameFact {
            id: f.id,
            now: f.now,
            target: f.target,
            moving: f.moving != 0,
            vx: f.vx,
            vy: f.vy,
            vw: f.vw,
            vh: f.vh,
        }));
    }

    fn read_rows(&mut self, rows: &[CmuxClosingRow]) {
        self.rows.clear();
        self.rows.extend(rows.iter().map(|r| RowTravel {
            column: r.column,
            now: r.now,
            target: r.target,
        }));
    }
}

/// `count` elements at `ptr`, or none when `count` is 0; `None` for a null pointer with elements.
unsafe fn slice<'a, T>(ptr: *const T, count: usize) -> Option<&'a [T]> {
    if count == 0 {
        return Some(&[]);
    }
    if ptr.is_null() {
        return None;
    }
    // SAFETY: the caller passes `count` initialized elements at `ptr` (module Safety).
    Some(unsafe { std::slice::from_raw_parts(ptr, count) })
}

/// A new handle for one screen's closing panes; free it with `cmux_closing_panes_free`.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_closing_panes_new() -> *mut CmuxClosingPanes {
    Box::into_raw(Box::default())
}

/// Frees a handle (null: nothing).
///
/// # Safety
/// `closing` came from `cmux_closing_panes_new` and is freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_closing_panes_free(closing: *mut CmuxClosingPanes) {
    if !closing.is_null() {
        // SAFETY: the pointer came from Box::into_raw and is freed once.
        drop(unsafe { Box::from_raw(closing) });
    }
}

/// Starts `pane` closing: `shown` is where it shows in the new layout's coordinates, `panes` the layout it left (the
/// order its sides list their neighbours in), `handles` that layout's handles, `max_gap` the widest gap between two
/// neighbours, `view_shift` the strip's view shift before the camera moves (read only when `has_view_shift` is 1).
/// Returns 1 (it starts closing) or 0 (it was not in that layout).
///
/// # Safety
/// See the module.
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn cmux_closing_panes_begin(
    closing: *mut CmuxClosingPanes,
    pane: u64,
    shown: *const CmuxClosingEdges,
    panes: *const CmuxClosingPane,
    pane_count: usize,
    handles: *const CmuxClosingHandle,
    handle_count: usize,
    max_gap: f64,
    has_view_shift: u8,
    view_shift: f64,
) -> i32 {
    if closing.is_null() || shown.is_null() {
        return ERR_NULL;
    }
    // SAFETY: module Safety.
    let (Some(panes), Some(handles)) =
        (unsafe { slice(panes, pane_count) }, unsafe { slice(handles, handle_count) })
    else {
        return ERR_NULL;
    };
    // SAFETY: non-null and live (module Safety).
    let (closing, shown) = unsafe { (&mut *closing, *shown) };
    catch_unwind(AssertUnwindSafe(|| {
        closing.handles.clear();
        for h in handles {
            let kind = match h.kind {
                HANDLE_SPLIT => HandleKind::Split,
                HANDLE_COLUMN_EDGE => HandleKind::ColumnEdge,
                HANDLE_ROW_EDGE => HandleKind::RowEdge,
                _ => return ERR_INVALID,
            };
            closing.handles.push(HandleFact {
                kind,
                horizontal: h.horizontal != 0,
                hit: h.hit,
                mid_x: h.mid_x,
                mid_y: h.mid_y,
                kept: h.kept != 0,
                fixed_split: h.fixed_split != 0,
                area: h.area,
                docked: h.docked != 0,
                column: h.column,
            });
        }
        closing.panes.clear();
        closing.panes.extend(panes.iter().map(|p| PaneFact {
            id: p.id,
            edges: p.edges,
            scrolls: p.scrolls != 0,
            area: p.area,
            row_column: p.row_column,
        }));
        let view_shift = (has_view_shift != 0).then_some(view_shift);
        let CmuxClosingPanes { rules, panes, handles, .. } = closing;
        i32::from(rules.begin(
            pane,
            shown,
            panes.as_slice(),
            handles.as_slice(),
            max_gap,
            view_shift,
        ))
    }))
    .unwrap_or(ERR_PANIC)
}

/// The change's cameras are set: the panes it began closing take their row column's scroll travel. Writes the panes
/// nothing moves over (ascending) to `out`; returns `OK`.
///
/// # Safety
/// See the module.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_closing_panes_settle(
    closing: *mut CmuxClosingPanes,
    frames: *const CmuxClosingFrame,
    frame_count: usize,
    rows: *const CmuxClosingRow,
    row_count: usize,
    out: *mut CmuxClosingIds,
) -> i32 {
    if closing.is_null() || out.is_null() {
        return ERR_NULL;
    }
    // SAFETY: module Safety.
    let (Some(frames), Some(rows)) =
        (unsafe { slice(frames, frame_count) }, unsafe { slice(rows, row_count) })
    else {
        return ERR_NULL;
    };
    // SAFETY: non-null and live (module Safety).
    let closing = unsafe { &mut *closing };
    let answer = catch_unwind(AssertUnwindSafe(|| {
        closing.read_frames(frames);
        closing.read_rows(rows);
        let still = closing.rules.settle(&closing.frames, &closing.rows);
        closing.still.clear();
        closing.still.extend(still);
        CmuxClosingIds { ids: closing.still.as_ptr(), count: closing.still.len() }
    }));
    match answer {
        Ok(list) => {
            // SAFETY: `out` is valid for one write and overlaps nothing (module Safety).
            unsafe { out.write(list) };
            OK
        }
        Err(_) => ERR_PANIC,
    }
}

/// Where every closing pane shows this frame, in the order they were placed: writes the list to `out`; returns `OK`.
/// Per display frame during a close: no allocation once the buffers have grown.
///
/// # Safety
/// See the module.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_closing_panes_rects(
    closing: *mut CmuxClosingPanes,
    frames: *const CmuxClosingFrame,
    frame_count: usize,
    rows: *const CmuxClosingRow,
    row_count: usize,
    out: *mut CmuxClosingPlacedList,
) -> i32 {
    if closing.is_null() || out.is_null() {
        return ERR_NULL;
    }
    // SAFETY: module Safety.
    let (Some(frames), Some(rows)) =
        (unsafe { slice(frames, frame_count) }, unsafe { slice(rows, row_count) })
    else {
        return ERR_NULL;
    };
    // SAFETY: non-null and live (module Safety).
    let closing = unsafe { &mut *closing };
    let answer = catch_unwind(AssertUnwindSafe(|| {
        closing.read_frames(frames);
        closing.read_rows(rows);
        let CmuxClosingPanes { rules, frames, rows, placed, .. } = closing;
        placed.clear();
        placed.extend(
            rules
                .rects(frames.as_slice(), rows.as_slice())
                .iter()
                .map(|&(pane, rect)| CmuxClosingPlaced { pane, rect }),
        );
        CmuxClosingPlacedList { placed: placed.as_ptr(), count: placed.len() }
    }));
    match answer {
        Ok(list) => {
            // SAFETY: `out` is valid for one write and overlaps nothing (module Safety).
            unsafe { out.write(list) };
            OK
        }
        Err(_) => ERR_PANIC,
    }
}

/// A new layout carried the strip by `drift`; `view_shift` (read only when `has_view_shift` is 1) is the new layout's
/// view shift. Returns `OK`.
///
/// # Safety
/// See the module.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_closing_panes_carry(
    closing: *mut CmuxClosingPanes,
    drift: f64,
    has_view_shift: u8,
    view_shift: f64,
) -> i32 {
    if closing.is_null() {
        return ERR_NULL;
    }
    // SAFETY: non-null and live (module Safety).
    let closing = unsafe { &mut *closing };
    let view_shift = (has_view_shift != 0).then_some(view_shift);
    catch_unwind(AssertUnwindSafe(|| closing.rules.carry(drift, view_shift)))
        .map_or(ERR_PANIC, |()| OK)
}

/// The camera took its place for the new layout (`strip_shift`: the strip's view shift now). Returns `OK`.
///
/// # Safety
/// See the module.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_closing_panes_settle_carried(
    closing: *mut CmuxClosingPanes,
    strip_shift: f64,
) -> i32 {
    if closing.is_null() {
        return ERR_NULL;
    }
    // SAFETY: non-null and live (module Safety).
    let closing = unsafe { &mut *closing };
    catch_unwind(AssertUnwindSafe(|| closing.rules.settle_carried(strip_shift)))
        .map_or(ERR_PANIC, |()| OK)
}

/// A row column stopped scrolling: its closing panes keep where they show (`delta`: its offset). Returns `OK`.
///
/// # Safety
/// See the module.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_closing_panes_shift_y(
    closing: *mut CmuxClosingPanes,
    column: u64,
    delta: f64,
) -> i32 {
    if closing.is_null() {
        return ERR_NULL;
    }
    // SAFETY: non-null and live (module Safety).
    let closing = unsafe { &mut *closing };
    catch_unwind(AssertUnwindSafe(|| closing.rules.shift_y(column, delta)))
        .map_or(ERR_PANIC, |()| OK)
}

/// Takes `pane` out (its close was taken back): returns 1 and writes where it shows now with its sides' velocities to
/// `out`, or 0 (it was not closing) with nothing written.
///
/// # Safety
/// See the module.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_closing_panes_remove(
    closing: *mut CmuxClosingPanes,
    pane: u64,
    frames: *const CmuxClosingFrame,
    frame_count: usize,
    out: *mut CmuxClosingTaken,
) -> i32 {
    if closing.is_null() || out.is_null() {
        return ERR_NULL;
    }
    // SAFETY: module Safety.
    let Some(frames) = (unsafe { slice(frames, frame_count) }) else { return ERR_NULL };
    // SAFETY: non-null and live (module Safety).
    let closing = unsafe { &mut *closing };
    let answer = catch_unwind(AssertUnwindSafe(|| {
        closing.read_frames(frames);
        closing.rules.remove(pane, &closing.frames)
    }));
    match answer {
        Ok(Some(t)) => {
            let taken = CmuxClosingTaken { rect: t.rect, vx: t.vx, vw: t.vw, vy: t.vy, vh: t.vh };
            // SAFETY: `out` is valid for one write and overlaps nothing (module Safety).
            unsafe { out.write(taken) };
            1
        }
        Ok(None) => 0,
        Err(_) => ERR_PANIC,
    }
}

/// Drops a pane whose host went. Returns `OK`.
///
/// # Safety
/// See the module.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_closing_panes_drop(closing: *mut CmuxClosingPanes, pane: u64) -> i32 {
    if closing.is_null() {
        return ERR_NULL;
    }
    // SAFETY: non-null and live (module Safety).
    let closing = unsafe { &mut *closing };
    catch_unwind(AssertUnwindSafe(|| closing.rules.drop_pane(pane))).map_or(ERR_PANIC, |()| OK)
}

/// 1 while panes the last change began closing wait for its cameras, else 0 (also for a null handle).
///
/// # Safety
/// See the module.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_closing_panes_has_awaiting(closing: *const CmuxClosingPanes) -> u8 {
    // SAFETY: null or live (module Safety).
    unsafe { closing.as_ref() }.map_or(0, |c| u8::from(c.rules.has_awaiting()))
}

/// The hash of the handle's whole state (`ClosingPanes::state_hash`; 0 for a null handle): the corpus tests compare it
/// after each call, so a difference in any side, travel or carry shows even where an answer does not.
///
/// # Safety
/// See the module.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_closing_panes_state_hash(closing: *const CmuxClosingPanes) -> u64 {
    // SAFETY: null or live (module Safety).
    unsafe { closing.as_ref() }
        .map_or(0, |c| catch_unwind(AssertUnwindSafe(|| c.rules.state_hash())).unwrap_or(0))
}
