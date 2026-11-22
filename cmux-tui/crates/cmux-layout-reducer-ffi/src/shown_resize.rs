//! The keyboard resize rules' C ABI (`cmux_shown_resize_*`, cmux-layout-reducer `shown_resize`): which split ratios,
//! column widths and dock widths show as different layouts, the width trade of a key press between two strip
//! columns, and the row heights of a key press on a row edge. The app's `ShownResizeRange` gathers the values from
//! its placed geometry and calls one of these per key press: no handle, no JSON, no allocation.
//!
//! Each call returns 1 and writes its answer, 0 when there is none (the press moves nothing), or
//! `CMUX_LAYOUT_REDUCER_ERR_NULL` / `ERR_PANIC` with nothing written.

use crate::{ERR_NULL, ERR_PANIC};
use cmux_layout_reducer::shown_resize::{self, Bounds, DockSide, RowInput, TradeInput};
use std::panic::{AssertUnwindSafe, catch_unwind};

/// A range of shares (`CmuxShownResizeBounds`).
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct CmuxShownResizeBounds {
    pub lower: f64,
    pub upper: f64,
}

/// One placed dock (`CmuxShownResizeDock`): flags are 0 or 1.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct CmuxShownResizeDock {
    pub width: f64,
    pub is_target: u8,
    pub is_band: u8,
    pub is_docked: u8,
    pub reserved: [u8; 5],
}

/// What a trade reads (`CmuxShownResizeTrade`); `strip_offset` counts only when `has_strip_offset` is 1.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct CmuxShownResizeTrade {
    pub strip_width: f64,
    pub gap: f64,
    pub scale: f64,
    pub delta: f64,
    pub left_min_x: f64,
    pub left_max_x: f64,
    pub left_width: f64,
    pub right_min_x: f64,
    pub right_max_x: f64,
    pub right_width: f64,
    pub left_minimum_width: f64,
    pub right_minimum_width: f64,
    pub left_fraction: f64,
    pub right_fraction: f64,
    pub strip_offset: f64,
    pub uncovered_min_x: f64,
    pub uncovered_max_x: f64,
    pub strip_min_x: f64,
    pub is_columns: u8,
    pub has_strip_offset: u8,
    pub reserved: [u8; 6],
}

/// A trade's divider move and its two candidate width pairs, in the order to try them (`CmuxShownResizeTradeAnswer`).
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct CmuxShownResizeTradeAnswer {
    pub move_points: f64,
    pub first_left: f64,
    pub first_right: f64,
    pub second_left: f64,
    pub second_right: f64,
}

/// What a row press reads (`CmuxShownResizeRows`): `heights` and `minimum_heights` hold `count` values each.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CmuxShownResizeRows {
    pub heights: *const i64,
    pub minimum_heights: *const f64,
    pub count: usize,
    pub pane_row: usize,
    pub column_height: f64,
    pub gap: f64,
    pub scale: f64,
    pub delta: f64,
    pub rows_enabled: u8,
    pub reserved: [u8; 7],
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

/// Writes `answer` to `out`: 1 for a range, 0 for none.
fn write_bounds(answer: Option<Bounds>, out: &mut CmuxShownResizeBounds) -> i32 {
    match answer {
        Some(bounds) => {
            *out = CmuxShownResizeBounds { lower: bounds.lower, upper: bounds.upper };
            1
        }
        None => 0,
    }
}

/// The split ratios of a divider that place it somewhere new (`container` and `divider` are the extents along its
/// axis); 0 when there is no room for both minimums.
///
/// # Safety
///
/// `out` is null or points to a writable `CmuxShownResizeBounds`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_shown_resize_ratio(
    container: f64,
    divider: f64,
    minimum_a: f64,
    minimum_b: f64,
    out: *mut CmuxShownResizeBounds,
) -> i32 {
    // SAFETY: the caller's contract.
    let Some(out) = (unsafe { out.as_mut() }) else { return ERR_NULL };
    catch_unwind(AssertUnwindSafe(|| {
        write_bounds(shown_resize::ratio(container, divider, minimum_a, minimum_b), out)
    }))
    .unwrap_or(ERR_PANIC)
}

/// The width shares a scrolling strip column shows as different widths; 0 for a docked column or no strip.
///
/// # Safety
///
/// `out` is null or points to a writable `CmuxShownResizeBounds`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_shown_resize_column_width(
    is_columns: u8,
    is_docked: u8,
    strip_width: f64,
    minimum_width: f64,
    gap: f64,
    out: *mut CmuxShownResizeBounds,
) -> i32 {
    // SAFETY: the caller's contract.
    let Some(out) = (unsafe { out.as_mut() }) else { return ERR_NULL };
    catch_unwind(AssertUnwindSafe(|| {
        let answer = shown_resize::column_width(
            is_columns != 0,
            is_docked != 0,
            strip_width,
            minimum_width,
            gap,
        );
        write_bounds(answer, out)
    }))
    .unwrap_or(ERR_PANIC)
}

/// The width shares of the target side dock among `docks` (every placed dock, in the screen's order); 0 when the
/// target is not a placed side dock.
///
/// # Safety
///
/// `docks` points to `count` readable docks (or `count` is 0); `out` is null or points to a writable
/// `CmuxShownResizeBounds`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_shown_resize_dock_width(
    docks: *const CmuxShownResizeDock,
    count: usize,
    viewport_width: f64,
    gap: f64,
    minimum_width: f64,
    out: *mut CmuxShownResizeBounds,
) -> i32 {
    // SAFETY: the caller's contract.
    let (docks, out) = unsafe { (slice(docks, count), out.as_mut()) };
    let (Some(docks), Some(out)) = (docks, out) else { return ERR_NULL };
    catch_unwind(AssertUnwindSafe(|| {
        let sides = docks.iter().map(|dock| DockSide {
            is_target: dock.is_target != 0,
            is_band: dock.is_band != 0,
            is_docked: dock.is_docked != 0,
            width: dock.width,
        });
        write_bounds(shown_resize::dock_width(sides, viewport_width, gap, minimum_width), out)
    }))
    .unwrap_or(ERR_PANIC)
}

/// The width trade of a key press between two neighbor strip columns: 1 with the move and the two width pairs to
/// try, 0 when the press would move nothing.
///
/// # Safety
///
/// `input` is null or points to a readable `CmuxShownResizeTrade`; `out` is null or points to a writable
/// `CmuxShownResizeTradeAnswer`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_shown_resize_trade(
    input: *const CmuxShownResizeTrade,
    out: *mut CmuxShownResizeTradeAnswer,
) -> i32 {
    // SAFETY: the caller's contract.
    let (input, out) = unsafe { (input.as_ref(), out.as_mut()) };
    let (Some(input), Some(out)) = (input, out) else { return ERR_NULL };
    catch_unwind(AssertUnwindSafe(|| {
        let rule = TradeInput {
            is_columns: input.is_columns != 0,
            strip_width: input.strip_width,
            gap: input.gap,
            scale: input.scale,
            delta: input.delta,
            left_min_x: input.left_min_x,
            left_max_x: input.left_max_x,
            left_width: input.left_width,
            right_min_x: input.right_min_x,
            right_max_x: input.right_max_x,
            right_width: input.right_width,
            left_minimum_width: input.left_minimum_width,
            right_minimum_width: input.right_minimum_width,
            left_fraction: input.left_fraction,
            right_fraction: input.right_fraction,
            strip_offset: (input.has_strip_offset != 0).then_some(input.strip_offset),
            uncovered_min_x: input.uncovered_min_x,
            uncovered_max_x: input.uncovered_max_x,
            strip_min_x: input.strip_min_x,
        };
        match shown_resize::trade(&rule) {
            Some(answer) => {
                *out = CmuxShownResizeTradeAnswer {
                    move_points: answer.move_points,
                    first_left: answer.first.0,
                    first_right: answer.first.1,
                    second_left: answer.second.0,
                    second_right: answer.second.1,
                };
                1
            }
            None => 0,
        }
    }))
    .unwrap_or(ERR_PANIC)
}

/// Every row height of a column after a key press on the row edge next to `pane_row`: 1 with `out_count` (the row
/// count) heights written to `out`, 0 when the press would move nothing or the counts do not match.
///
/// # Safety
///
/// `input` is null or points to a readable `CmuxShownResizeRows` whose arrays hold `count` values each (or `count`
/// is 0); `out` points to `out_count` writable values (or `out_count` is 0).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_shown_resize_row_heights(
    input: *const CmuxShownResizeRows,
    out: *mut i64,
    out_count: usize,
) -> i32 {
    // SAFETY: the caller's contract.
    let Some(input) = (unsafe { input.as_ref() }) else { return ERR_NULL };
    // SAFETY: the caller's contract.
    let (heights, minimums) =
        unsafe { (slice(input.heights, input.count), slice(input.minimum_heights, input.count)) };
    let (Some(heights), Some(minimum_heights)) = (heights, minimums) else { return ERR_NULL };
    let out: &mut [i64] = if out_count == 0 {
        &mut []
    } else if out.is_null() {
        return ERR_NULL;
    } else {
        // SAFETY: the caller's contract: `out` holds `out_count` writable values.
        unsafe { std::slice::from_raw_parts_mut(out, out_count) }
    };
    catch_unwind(AssertUnwindSafe(|| {
        let rule = RowInput {
            heights,
            minimum_heights,
            pane_row: input.pane_row,
            rows_enabled: input.rows_enabled != 0,
            column_height: input.column_height,
            gap: input.gap,
            scale: input.scale,
            delta: input.delta,
        };
        i32::from(shown_resize::row_heights(&rule, out))
    }))
    .unwrap_or(ERR_PANIC)
}
