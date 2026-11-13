//! The sidebar's drop rules as a handle per drag (`cmux_sidebar_drag_*`).
//!
//! A drag move used to cross with every row and section as JSON
//! (`cmux_layout_reducer_json` ops `resolve_drag`, `tab_drop`, `tab_refusal`),
//! so each move cost the main thread time in proportion to the rows the
//! sidebar holds. Now the rows and sections cross once, when the drag's base
//! layout is made (`cmux_sidebar_drag_new` for a workspace or group drag,
//! `cmux_sidebar_tab_drag_new` for a tab dragged in from a pane). Each move
//! then crosses with numbers only. A reply that equals the handle's last one
//! answers [`SAME`] and writes nothing, so the app decodes only a change of
//! target. `cmux_sidebar_base_y` converts a displayed y with no JSON at all.

use crate::{ERR_INVALID, ERR_NULL, ERR_PANIC, OK, input, write_output};
use cmux_layout_reducer::{sidebar_drag, sidebar_drop};
use std::panic::{AssertUnwindSafe, catch_unwind};

/// The reply equals the handle's last reply for the same question: the
/// output is untouched and the caller keeps what it decoded last time.
pub const SAME: i32 = 1;

/// The last JSON reply a handle wrote for one question, so an unchanged
/// reply is neither encoded into the caller's buffer nor decoded again.
#[derive(Default)]
struct Last(Option<Vec<u8>>);

impl Last {
    /// Writes `bytes` unless they equal the last reply written. A reply too
    /// large for `capacity` is not remembered, so the retry writes it.
    unsafe fn write(
        &mut self,
        bytes: Vec<u8>,
        output: *mut u8,
        capacity: usize,
        output_len: *mut usize,
    ) -> i32 {
        if self.0.as_deref() == Some(bytes.as_slice()) {
            return SAME;
        }
        // SAFETY: forwarded from the C caller's contract.
        let code = unsafe { write_output(&bytes, output, capacity, output_len) };
        if code == OK {
            self.0 = Some(bytes);
        }
        code
    }
}

/// A workspace or group drag's drop rules (a `sidebar_drop::Request`; its
/// `y` is set per move).
pub struct Drag {
    request: sidebar_drop::Request,
    last: Last,
}

/// A tab drag's drop rules (a `sidebar_drop::TabRequest`; its `y` is set per
/// move).
pub struct TabDrag {
    request: sidebar_drop::TabRequest,
    drop: Last,
    whole_rows: Last,
    refusal: Last,
}

fn gap(has_gap: u8, gap_y: f64) -> Option<f64> {
    (has_gap != 0).then_some(gap_y)
}

fn parse<T: serde::de::DeserializeOwned>(request: *const u8, request_len: usize) -> Option<T> {
    // SAFETY: forwarded from the C caller's contract.
    let bytes = unsafe { input(request, request_len) }?;
    catch_unwind(|| serde_json::from_slice(bytes).ok()).ok().flatten()
}

fn reply(result: std::thread::Result<Result<i32, i32>>) -> i32 {
    match result {
        Ok(Ok(code) | Err(code)) => code,
        Err(_) => ERR_PANIC,
    }
}

/// A drag handle for a workspace or group drag, from the JSON of a
/// `sidebar_drop::Request` (the `resolve` request; `y` may be left out).
/// Null for a null or invalid request. Free it with `cmux_sidebar_drag_free`.
///
/// # Safety
///
/// `request` points to `request_len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_sidebar_drag_new(
    request: *const u8,
    request_len: usize,
) -> *mut Drag {
    match parse(request, request_len) {
        Some(request) => Box::into_raw(Box::new(Drag { request, last: Last::default() })),
        None => std::ptr::null_mut(),
    }
}

/// # Safety
///
/// `drag` is null or a pointer from `cmux_sidebar_drag_new` not freed yet.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_sidebar_drag_free(drag: *mut Drag) {
    if !drag.is_null() {
        // SAFETY: the pointer came from Box::into_raw and is freed once.
        drop(unsafe { Box::from_raw(drag) });
    }
}

/// One drag move: the card's centre and leading edge and the open gap, in
/// displayed coordinates. Writes the JSON of `sidebar_drag::resolve_drag`'s
/// reply (`null`, or `{target, probe}`), or answers [`SAME`].
///
/// # Safety
///
/// `drag` is a live handle, `output` points to `output_capacity` writable
/// bytes and `output_len` is writable.
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn cmux_sidebar_drag_resolve(
    drag: *mut Drag,
    centre_y: f64,
    leading_y: f64,
    has_gap: u8,
    gap_y: f64,
    gap_height: f64,
    output: *mut u8,
    output_capacity: usize,
    output_len: *mut usize,
) -> i32 {
    // SAFETY: a live handle from cmux_sidebar_drag_new, used on one thread.
    let Some(drag) = (unsafe { drag.as_mut() }) else { return ERR_NULL };
    reply(catch_unwind(AssertUnwindSafe(|| {
        let resolved = sidebar_drag::resolve_drag_in(
            &mut drag.request,
            centre_y,
            leading_y,
            gap(has_gap, gap_y),
            gap_height,
        );
        let bytes = serde_json::to_vec(&resolved).map_err(|_| ERR_INVALID)?;
        // SAFETY: forwarded from this function's contract.
        Ok(unsafe { drag.last.write(bytes, output, output_capacity, output_len) })
    })))
}

/// A drag handle for a tab dragged in from a pane, from the JSON of a
/// `sidebar_drop::TabRequest` (the `tab_drop` request). Null for a null or
/// invalid request. Free it with `cmux_sidebar_tab_drag_free`.
///
/// # Safety
///
/// `request` points to `request_len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_sidebar_tab_drag_new(
    request: *const u8,
    request_len: usize,
) -> *mut TabDrag {
    match parse(request, request_len) {
        Some(request) => Box::into_raw(Box::new(TabDrag {
            request,
            drop: Last::default(),
            whole_rows: Last::default(),
            refusal: Last::default(),
        })),
        None => std::ptr::null_mut(),
    }
}

/// # Safety
///
/// `drag` is null or a pointer from `cmux_sidebar_tab_drag_new` not freed yet.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_sidebar_tab_drag_free(drag: *mut TabDrag) {
    if !drag.is_null() {
        // SAFETY: the pointer came from Box::into_raw and is freed once.
        drop(unsafe { Box::from_raw(drag) });
    }
}

/// The tab drop at base-layout `y`. `whole_rows` non-zero: a workspace row
/// takes the tab over its whole height. Writes the JSON of
/// `sidebar_drop::resolve_tab_drop`'s reply, or answers [`SAME`] (each
/// `whole_rows` value keeps its own last reply).
///
/// # Safety
///
/// `drag` is a live handle, `output` points to `output_capacity` writable
/// bytes and `output_len` is writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_sidebar_tab_drag_drop(
    drag: *mut TabDrag,
    y: f64,
    whole_rows: u8,
    output: *mut u8,
    output_capacity: usize,
    output_len: *mut usize,
) -> i32 {
    // SAFETY: a live handle from cmux_sidebar_tab_drag_new, used on one thread.
    let Some(drag) = (unsafe { drag.as_mut() }) else { return ERR_NULL };
    reply(catch_unwind(AssertUnwindSafe(|| {
        let band = (drag.request.tab_into_start, drag.request.tab_into_end);
        drag.request.y = y;
        if whole_rows != 0 {
            (drag.request.tab_into_start, drag.request.tab_into_end) = (0.0, 1.0);
        }
        let resolved = sidebar_drop::resolve_tab_drop(&drag.request);
        (drag.request.tab_into_start, drag.request.tab_into_end) = band;
        let bytes = serde_json::to_vec(&resolved).map_err(|_| ERR_INVALID)?;
        let last = if whole_rows != 0 { &mut drag.whole_rows } else { &mut drag.drop };
        // SAFETY: forwarded from this function's contract.
        Ok(unsafe { last.write(bytes, output, output_capacity, output_len) })
    })))
}

/// Why no tab drop is possible at base-layout `y`. Writes the JSON of
/// `sidebar_drop::tab_drop_refusal`'s reply, or answers [`SAME`].
///
/// # Safety
///
/// `drag` is a live handle, `output` points to `output_capacity` writable
/// bytes and `output_len` is writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_sidebar_tab_drag_refusal(
    drag: *mut TabDrag,
    y: f64,
    output: *mut u8,
    output_capacity: usize,
    output_len: *mut usize,
) -> i32 {
    // SAFETY: a live handle from cmux_sidebar_tab_drag_new, used on one thread.
    let Some(drag) = (unsafe { drag.as_mut() }) else { return ERR_NULL };
    reply(catch_unwind(AssertUnwindSafe(|| {
        drag.request.y = y;
        let refusal = sidebar_drop::tab_drop_refusal(&drag.request);
        let bytes = serde_json::to_vec(&refusal).map_err(|_| ERR_INVALID)?;
        // SAFETY: forwarded from this function's contract.
        Ok(unsafe { drag.refusal.write(bytes, output, output_capacity, output_len) })
    })))
}

/// A displayed y in base-layout coordinates (`sidebar_drop::base_y`): writes
/// it to `base_y` and answers 1, or answers 0 when `display_y` is inside the
/// open gap (`has_gap` non-zero: the gap at `gap_y`, `gap_height` tall).
///
/// # Safety
///
/// `base_y` is writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_sidebar_base_y(
    display_y: f64,
    has_gap: u8,
    gap_y: f64,
    gap_height: f64,
    base_y: *mut f64,
) -> u8 {
    let Some(y) = sidebar_drop::base_y(display_y, gap(has_gap, gap_y), gap_height) else {
        return 0;
    };
    if base_y.is_null() {
        return 0;
    }
    // SAFETY: checked non-null; writable by the caller's contract.
    unsafe { *base_y = y };
    1
}
