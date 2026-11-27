//! C ABI of the screen viewer core (`include/cmux_screen_kit.h`), behind the `c-abi` feature: the Mac's
//! app library exports it through cmux-rd-ffi, iOS's through
//! cmux-mobile-ffi. Stateful parts are opaque handles (no threads, panics
//! caught, a panic poisons only that handle); math is plain values.
//! Strings are UTF-8 pointer and length; nothing here keeps a caller's pointer.

use std::panic::{AssertUnwindSafe, catch_unwind};

use super::cursor::{CursorCache, CursorGeometry, CursorPlacement};
use super::framing::CameraFraming;
use super::hint::HintPose;
use super::reconnect::{self, SessionPhase};
use super::trackpad::{ClickSnap, PointerAcceleration, TrackpadAction, TrackpadGesture};
use super::viewport::{self, Insets, ScrollQuantizer};
use super::{Point, Rect, Size};

pub const CMUX_SCREEN_OK: i32 = 0;
pub const CMUX_SCREEN_ERR_NULL: i32 = -1;
pub const CMUX_SCREEN_ERR_INVALID: i32 = -2;
pub const CMUX_SCREEN_ERR_PANIC: i32 = -3;
/// The caller's buffer is too small; the length needed was written.
pub const CMUX_SCREEN_ERR_BUFFER: i32 = -4;

/// A trackpad action's kind (`CmuxScreenTrackpadAction.kind`).
pub const CMUX_SCREEN_TRACKPAD_MOVE: u32 = 0;
pub const CMUX_SCREEN_TRACKPAD_PRESS: u32 = 1;
pub const CMUX_SCREEN_TRACKPAD_RELEASE: u32 = 2;
/// The most actions one trackpad call returns (a second tap's release, press, release).
pub const CMUX_SCREEN_TRACKPAD_MAX_ACTIONS: usize = 3;

/// One trackpad action; `dx`, `dy`, `dt` only for a move.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct CmuxScreenTrackpadAction {
    pub kind: u32,
    pub dx: f64,
    pub dy: f64,
    pub dt: f64,
}

impl From<TrackpadAction> for CmuxScreenTrackpadAction {
    fn from(action: TrackpadAction) -> Self {
        match action {
            TrackpadAction::Move { dx, dy, dt } => {
                Self { kind: CMUX_SCREEN_TRACKPAD_MOVE, dx, dy, dt }
            }
            TrackpadAction::Press => Self { kind: CMUX_SCREEN_TRACKPAD_PRESS, ..Self::default() },
            TrackpadAction::Release => {
                Self { kind: CMUX_SCREEN_TRACKPAD_RELEASE, ..Self::default() }
            }
        }
    }
}

/// A handle's poison flag around its value.
pub struct Handle<T> {
    inner: T,
    poisoned: bool,
}

pub type CmuxScreenTrackpad = Handle<TrackpadGesture>;
pub type CmuxScreenClickSnap = Handle<ClickSnap>;
pub type CmuxScreenCursorCache = Handle<CursorCache>;

fn new_handle<T>(inner: T) -> *mut Handle<T> {
    catch_unwind(AssertUnwindSafe(|| Box::into_raw(Box::new(Handle { inner, poisoned: false }))))
        .unwrap_or(std::ptr::null_mut())
}

/// # Safety
/// `ptr` is NULL or a live handle from its `_new` not yet freed.
unsafe fn free_handle<T>(ptr: *mut Handle<T>) {
    if ptr.is_null() {
        return;
    }
    // SAFETY: guaranteed by the caller; the box is dropped exactly once.
    let owned = unsafe { Box::from_raw(ptr) };
    let _ = catch_unwind(AssertUnwindSafe(move || drop(owned)));
}

/// Runs `f` on a live handle; NULL, a poisoned handle and panics map to codes.
///
/// # Safety
/// `ptr` is NULL or a live handle that no other call uses at the same time.
unsafe fn with<T>(ptr: *mut Handle<T>, f: impl FnOnce(&mut T) -> i32) -> i32 {
    // SAFETY: guaranteed by the caller.
    let Some(handle) = (unsafe { ptr.as_mut() }) else { return CMUX_SCREEN_ERR_NULL };
    if handle.poisoned {
        return CMUX_SCREEN_ERR_PANIC;
    }
    match catch_unwind(AssertUnwindSafe(|| f(&mut handle.inner))) {
        Ok(code) => code,
        Err(_) => {
            // SAFETY: as above; the closure's borrow ended when it unwound.
            if let Some(handle) = unsafe { ptr.as_mut() } {
                handle.poisoned = true;
            }
            CMUX_SCREEN_ERR_PANIC
        }
    }
}

/// # Safety
/// `ptr` is NULL or valid for `len` bytes.
unsafe fn str_in<'a>(ptr: *const u8, len: usize) -> Option<&'a str> {
    if len == 0 {
        return Some("");
    }
    if ptr.is_null() {
        return None;
    }
    // SAFETY: guaranteed by the caller.
    std::str::from_utf8(unsafe { std::slice::from_raw_parts(ptr, len) }).ok()
}

/// # Safety
/// `out` is NULL or writable.
unsafe fn put<T>(out: *mut T, value: T) {
    // SAFETY: guaranteed by the caller.
    if let Some(out) = unsafe { out.as_mut() } {
        *out = value;
    }
}

// MARK: Trackpad gesture

/// Creates a trackpad gesture with the default timings; NULL only when allocation fails.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_screen_trackpad_new() -> *mut CmuxScreenTrackpad {
    new_handle(TrackpadGesture::new())
}

/// # Safety
/// `trackpad` is NULL or a pointer from [`cmux_screen_trackpad_new`] not yet freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screen_trackpad_free(trackpad: *mut CmuxScreenTrackpad) {
    // SAFETY: guaranteed by the caller.
    unsafe { free_handle(trackpad) }
}

/// The trackpad call (`CMUX_SCREEN_TRACKPAD_*` below) that produced actions.
fn trackpad_call(
    trackpad: *mut CmuxScreenTrackpad,
    out: *mut CmuxScreenTrackpadAction,
    out_count: *mut usize,
    f: impl FnOnce(&mut TrackpadGesture) -> Vec<TrackpadAction>,
) -> i32 {
    if out.is_null() || out_count.is_null() {
        return CMUX_SCREEN_ERR_NULL;
    }
    // SAFETY: the exported callers pass their own caller's guarantee through.
    unsafe {
        with(trackpad, |gesture| {
            let actions = f(gesture);
            debug_assert!(actions.len() <= CMUX_SCREEN_TRACKPAD_MAX_ACTIONS);
            let count = actions.len().min(CMUX_SCREEN_TRACKPAD_MAX_ACTIONS);
            for (index, action) in actions.into_iter().take(count).enumerate() {
                *out.add(index) = action.into();
            }
            *out_count = count;
            CMUX_SCREEN_OK
        })
    }
}

/// A finger touched down at `time` (seconds). Writes up to
/// `CMUX_SCREEN_TRACKPAD_MAX_ACTIONS` actions to `out` and their count to `out_count`.
///
/// # Safety
/// `trackpad` is a live handle; `out` holds `CMUX_SCREEN_TRACKPAD_MAX_ACTIONS` actions;
/// `out_count` is writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screen_trackpad_touch_down(
    trackpad: *mut CmuxScreenTrackpad,
    time: f64,
    out: *mut CmuxScreenTrackpadAction,
    out_count: *mut usize,
) -> i32 {
    trackpad_call(trackpad, out, out_count, |g| g.touch_down(time))
}

/// The finger moved by `dx`, `dy` points at `time`.
///
/// # Safety
/// As [`cmux_screen_trackpad_touch_down`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screen_trackpad_touch_moved(
    trackpad: *mut CmuxScreenTrackpad,
    dx: f64,
    dy: f64,
    time: f64,
    out: *mut CmuxScreenTrackpadAction,
    out_count: *mut usize,
) -> i32 {
    trackpad_call(trackpad, out, out_count, |g| g.touch_moved(dx, dy, time))
}

/// The finger lifted at `time`.
///
/// # Safety
/// As [`cmux_screen_trackpad_touch_down`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screen_trackpad_touch_up(
    trackpad: *mut CmuxScreenTrackpad,
    time: f64,
    out: *mut CmuxScreenTrackpadAction,
    out_count: *mut usize,
) -> i32 {
    trackpad_call(trackpad, out, out_count, |g| g.touch_up(time))
}

/// The touch ended without a gesture: a held button releases.
///
/// # Safety
/// As [`cmux_screen_trackpad_touch_down`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screen_trackpad_cancel(
    trackpad: *mut CmuxScreenTrackpad,
    out: *mut CmuxScreenTrackpadAction,
    out_count: *mut usize,
) -> i32 {
    trackpad_call(trackpad, out, out_count, TrackpadGesture::cancel)
}

/// Time passed to `time`: a long press, or a tap's window ending.
///
/// # Safety
/// As [`cmux_screen_trackpad_touch_down`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screen_trackpad_advance(
    trackpad: *mut CmuxScreenTrackpad,
    time: f64,
    out: *mut CmuxScreenTrackpadAction,
    out_count: *mut usize,
) -> i32 {
    trackpad_call(trackpad, out, out_count, |g| g.advance(time))
}

/// Whether the button is down (`out_held`) and when to call advance next
/// (`out_has_deadline`, `out_deadline`).
///
/// # Safety
/// `trackpad` is a live handle; the outputs are NULL or writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screen_trackpad_state(
    trackpad: *mut CmuxScreenTrackpad,
    out_held: *mut bool,
    out_has_deadline: *mut bool,
    out_deadline: *mut f64,
) -> i32 {
    // SAFETY: guaranteed by the caller.
    unsafe {
        with(trackpad, |g| {
            put(out_held, g.button_held());
            let deadline = g.deadline();
            put(out_has_deadline, deadline.is_some());
            put(out_deadline, deadline.unwrap_or(0.0));
            CMUX_SCREEN_OK
        })
    }
}

/// The gesture's timings (seconds) and slop (points); a negative or
/// non-finite value is `CMUX_SCREEN_ERR_INVALID`.
///
/// # Safety
/// `trackpad` is a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screen_trackpad_set_timings(
    trackpad: *mut CmuxScreenTrackpad,
    tap_duration: f64,
    slop: f64,
    long_press_duration: f64,
    drag_window: f64,
) -> i32 {
    let values = [tap_duration, slop, long_press_duration, drag_window];
    if values.iter().any(|v| !v.is_finite() || *v < 0.0) {
        return CMUX_SCREEN_ERR_INVALID;
    }
    // SAFETY: guaranteed by the caller.
    unsafe {
        with(trackpad, |g| {
            g.tap_duration = tap_duration;
            g.slop = slop;
            g.long_press_duration = long_press_duration;
            g.drag_window = drag_window;
            CMUX_SCREEN_OK
        })
    }
}

// MARK: Pointer acceleration and click snap

/// The default pointer acceleration.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_screen_acceleration_default() -> PointerAcceleration {
    PointerAcceleration::default()
}

#[unsafe(no_mangle)]
pub extern "C" fn cmux_screen_acceleration_gain(
    acceleration: PointerAcceleration,
    speed: f64,
) -> f64 {
    acceleration.gain(speed)
}

/// The cursor's travel in framebuffer pixels (as a point) for a finger's travel.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_screen_acceleration_delta(
    acceleration: PointerAcceleration,
    dx: f64,
    dy: f64,
    dt: f64,
    pixels_per_point: f64,
) -> Point {
    let (x, y) = acceleration.delta(dx, dy, dt, pixels_per_point);
    Point::new(x, y)
}

#[unsafe(no_mangle)]
pub extern "C" fn cmux_screen_click_snap_new() -> *mut CmuxScreenClickSnap {
    new_handle(ClickSnap::new())
}

/// # Safety
/// `snap` is NULL or a pointer from [`cmux_screen_click_snap_new`] not yet freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screen_click_snap_free(snap: *mut CmuxScreenClickSnap) {
    // SAFETY: guaranteed by the caller.
    unsafe { free_handle(snap) }
}

/// Where a tap at `point` (at `time`) clicks, to `out`.
///
/// # Safety
/// `snap` is a live handle; `out` is writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screen_click_snap_point(
    snap: *mut CmuxScreenClickSnap,
    point: Point,
    time: f64,
    radius: f64,
    out: *mut Point,
) -> i32 {
    if out.is_null() {
        return CMUX_SCREEN_ERR_NULL;
    }
    // SAFETY: guaranteed by the caller.
    unsafe {
        with(snap, |s| {
            *out = s.point(point, time, radius);
            CMUX_SCREEN_OK
        })
    }
}

// MARK: Framing and viewport

#[unsafe(no_mangle)]
pub extern "C" fn cmux_screen_framing(crop: Rect, display: Rect, view: Size) -> CameraFraming {
    CameraFraming::new(crop, display, view)
}

#[unsafe(no_mangle)]
pub extern "C" fn cmux_screen_framing_visible(
    framing: CameraFraming,
    display: Rect,
    view: Size,
) -> Rect {
    framing.visible(display, view)
}

#[unsafe(no_mangle)]
pub extern "C" fn cmux_screen_fit_scale(rect: Rect, view: Size) -> f64 {
    viewport::fit_scale(rect, view)
}

#[unsafe(no_mangle)]
pub extern "C" fn cmux_screen_centered_offset(rect: Rect, scale: f64, view: Size) -> Point {
    viewport::centered_offset(rect, scale, view)
}

#[unsafe(no_mangle)]
pub extern "C" fn cmux_screen_maximum_zoom(fit: f64) -> f64 {
    viewport::maximum_zoom(fit)
}

#[unsafe(no_mangle)]
pub extern "C" fn cmux_screen_same_zoom(a: f64, b: f64) -> bool {
    viewport::same_zoom(a, b)
}

#[unsafe(no_mangle)]
pub extern "C" fn cmux_screen_clamped_offset(
    offset: Point,
    focus: Rect,
    scale: f64,
    view: Size,
    allow_horizontal: bool,
) -> Point {
    viewport::clamped_offset(offset, focus, scale, view, allow_horizontal)
}

#[unsafe(no_mangle)]
pub extern "C" fn cmux_screen_page_target(
    page: usize,
    count: usize,
    velocity_x: f64,
    moved: f64,
    view_width: f64,
) -> usize {
    viewport::page_target(page, count, velocity_x, moved, view_width)
}

/// The page a display list opens on.
///
/// # Safety
/// `screens` is NULL (with `count` 0) or holds `count` rects.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screen_initial_page(screens: *const Rect, count: usize) -> usize {
    if screens.is_null() || count == 0 {
        return 0;
    }
    // SAFETY: guaranteed by the caller.
    viewport::initial_page(unsafe { std::slice::from_raw_parts(screens, count) })
}

#[unsafe(no_mangle)]
pub extern "C" fn cmux_screen_content_insets(
    centres_any: bool,
    view: Size,
    content: Size,
) -> Insets {
    viewport::content_insets(centres_any, view, content)
}

/// Adds a scroll stroke to `quantizer` and writes the whole pixels or clicks to `out_x`, `out_y`.
///
/// # Safety
/// `quantizer`, `out_x` and `out_y` are writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screen_scroll_quantize(
    quantizer: *mut ScrollQuantizer,
    translation: Point,
    pixels: bool,
    pixels_per_point: f64,
    out_x: *mut i64,
    out_y: *mut i64,
) -> i32 {
    // SAFETY: guaranteed by the caller.
    let Some(quantizer) = (unsafe { quantizer.as_mut() }) else { return CMUX_SCREEN_ERR_NULL };
    if out_x.is_null() || out_y.is_null() {
        return CMUX_SCREEN_ERR_NULL;
    }
    let (x, y) = quantizer.scroll(translation, pixels, pixels_per_point);
    // SAFETY: checked non-NULL; writable by the caller's guarantee.
    unsafe {
        *out_x = x;
        *out_y = y;
    }
    CMUX_SCREEN_OK
}

#[unsafe(no_mangle)]
pub extern "C" fn cmux_screen_pixels_per_point(zoom: f64) -> f64 {
    viewport::pixels_per_point(zoom)
}

#[unsafe(no_mangle)]
pub extern "C" fn cmux_screen_clamp_to_rect(point: Point, rect: Rect) -> Point {
    viewport::clamp_to_rect(point, rect)
}

#[unsafe(no_mangle)]
pub extern "C" fn cmux_screen_follow_cursor(offset: Point, cursor: Point, view: Size) -> Point {
    viewport::follow_cursor(offset, cursor, view)
}

#[unsafe(no_mangle)]
pub extern "C" fn cmux_screen_clamp_to_content(
    offset: Point,
    insets: Insets,
    content: Size,
    view: Size,
) -> Point {
    viewport::clamp_to_content(offset, insets, content, view)
}

/// The stream's content size; `has_display` false: no display size known.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_screen_stream_layout_size(
    video: Size,
    has_display: bool,
    display: Size,
) -> Size {
    viewport::stream_layout_size(video, has_display.then_some(display))
}

#[unsafe(no_mangle)]
pub extern "C" fn cmux_screen_demand_long_edge(frame: Size, zoom: f64, display_scale: f64) -> i64 {
    viewport::demand_long_edge(frame, zoom, display_scale)
}

#[unsafe(no_mangle)]
pub extern "C" fn cmux_screen_normalized(point: Point, frame: Size) -> Point {
    viewport::normalized(point, frame)
}

#[unsafe(no_mangle)]
pub extern "C" fn cmux_screen_clamp_to_frame(point: Point, frame: Size) -> Point {
    viewport::clamp_to_frame(point, frame)
}

// MARK: Cursor

#[unsafe(no_mangle)]
pub extern "C" fn cmux_screen_cursor_placement(
    geometry: CursorGeometry,
    pointer: Point,
    frame: Size,
) -> CursorPlacement {
    geometry.placement(pointer, frame)
}

#[unsafe(no_mangle)]
pub extern "C" fn cmux_screen_cursor_cache_new() -> *mut CmuxScreenCursorCache {
    new_handle(CursorCache::new())
}

/// # Safety
/// `cache` is NULL or a pointer from [`cmux_screen_cursor_cache_new`] not yet freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screen_cursor_cache_free(cache: *mut CmuxScreenCursorCache) {
    // SAFETY: guaranteed by the caller.
    unsafe { free_handle(cache) }
}

/// Adds a shape from the host. `out_current`: it is now the current shape.
/// An evicted shape's id is copied to `evicted` (capacity `evicted_cap`)
/// with its length in `out_evicted_len` (0: none); a short buffer is
/// `CMUX_SCREEN_ERR_BUFFER` with the length written (the add still happened).
///
/// # Safety
/// `cache` is a live handle; `id` holds `id_len` bytes; `evicted` holds
/// `evicted_cap` bytes or is NULL with 0; the other outputs are writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screen_cursor_cache_add(
    cache: *mut CmuxScreenCursorCache,
    id: *const u8,
    id_len: usize,
    geometry: CursorGeometry,
    out_current: *mut bool,
    evicted: *mut u8,
    evicted_cap: usize,
    out_evicted_len: *mut usize,
) -> i32 {
    // SAFETY: guaranteed by the caller.
    let Some(id) = (unsafe { str_in(id, id_len) }) else { return CMUX_SCREEN_ERR_INVALID };
    if out_current.is_null() || out_evicted_len.is_null() {
        return CMUX_SCREEN_ERR_NULL;
    }
    // SAFETY: guaranteed by the caller.
    unsafe {
        with(cache, |c| {
            let added = c.add(id, geometry);
            *out_current = added.became_current;
            let gone = added.evicted.unwrap_or_default();
            *out_evicted_len = gone.len();
            if gone.len() > evicted_cap || (!gone.is_empty() && evicted.is_null()) {
                return CMUX_SCREEN_ERR_BUFFER;
            }
            std::ptr::copy_nonoverlapping(gone.as_ptr(), evicted, gone.len());
            CMUX_SCREEN_OK
        })
    }
}

/// The telepointers named `id` (`id` NULL: a host that sends no shapes, no
/// change). `out_changed`: the current shape changed.
///
/// # Safety
/// `cache` is a live handle; `id` is NULL or holds `id_len` bytes; `out_changed` is writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screen_cursor_cache_select(
    cache: *mut CmuxScreenCursorCache,
    id: *const u8,
    id_len: usize,
    out_changed: *mut bool,
) -> i32 {
    let named = if id.is_null() {
        None
    } else {
        // SAFETY: guaranteed by the caller.
        let Some(id) = (unsafe { str_in(id, id_len) }) else { return CMUX_SCREEN_ERR_INVALID };
        Some(id)
    };
    if out_changed.is_null() {
        return CMUX_SCREEN_ERR_NULL;
    }
    // SAFETY: guaranteed by the caller.
    unsafe {
        with(cache, |c| {
            *out_changed = c.select(named);
            CMUX_SCREEN_OK
        })
    }
}

/// The current shape: its id copied to `out_id` (capacity `id_cap`, length
/// in `out_id_len`) and its geometry; `out_has` false when there is none.
///
/// # Safety
/// `cache` is a live handle; `out_id` holds `id_cap` bytes or is NULL with 0;
/// the other outputs are writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screen_cursor_cache_current(
    cache: *mut CmuxScreenCursorCache,
    out_has: *mut bool,
    out_id: *mut u8,
    id_cap: usize,
    out_id_len: *mut usize,
    out_geometry: *mut CursorGeometry,
) -> i32 {
    if out_has.is_null() || out_id_len.is_null() || out_geometry.is_null() {
        return CMUX_SCREEN_ERR_NULL;
    }
    // SAFETY: guaranteed by the caller.
    unsafe {
        with(cache, |c| {
            let Some((id, geometry)) = c.current() else {
                *out_has = false;
                *out_id_len = 0;
                return CMUX_SCREEN_OK;
            };
            *out_has = true;
            *out_geometry = *geometry;
            *out_id_len = id.len();
            if id.len() > id_cap || (!id.is_empty() && out_id.is_null()) {
                return CMUX_SCREEN_ERR_BUFFER;
            }
            std::ptr::copy_nonoverlapping(id.as_ptr(), out_id, id.len());
            CMUX_SCREEN_OK
        })
    }
}

/// A new stream: the shapes start over.
///
/// # Safety
/// `cache` is a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screen_cursor_cache_reset(cache: *mut CmuxScreenCursorCache) -> i32 {
    // SAFETY: guaranteed by the caller.
    unsafe {
        with(cache, |c| {
            c.reset();
            CMUX_SCREEN_OK
        })
    }
}

// MARK: Session policy and hint

#[unsafe(no_mangle)]
pub extern "C" fn cmux_screen_reconnect_gives_up(attempts: i64, limit: i64, elapsed: f64) -> bool {
    reconnect::gives_up(attempts, limit, elapsed)
}

#[unsafe(no_mangle)]
pub extern "C" fn cmux_screen_reconnect_attempt_timeout(elapsed: f64) -> f64 {
    reconnect::attempt_timeout(elapsed)
}

#[unsafe(no_mangle)]
pub extern "C" fn cmux_screen_reconnect_backoff_delay(attempt: i64) -> f64 {
    reconnect::backoff_delay(attempt)
}

#[unsafe(no_mangle)]
pub extern "C" fn cmux_screen_reconnect_deadline() -> f64 {
    reconnect::RECONNECT_DEADLINE
}

#[unsafe(no_mangle)]
pub extern "C" fn cmux_screen_notice_delay() -> f64 {
    reconnect::RECONNECT_NOTICE_DELAY
}

fn phase(raw: u32) -> Option<SessionPhase> {
    Some(match raw {
        0 => SessionPhase::Idle,
        1 => SessionPhase::Connecting,
        2 => SessionPhase::Connected,
        3 => SessionPhase::Failed,
        4 => SessionPhase::Ended,
        _ => return None,
    })
}

/// `phase` is a `CmuxScreenPhase` (0 idle, 1 connecting, 2 connected, 3 failed, 4 ended).
#[unsafe(no_mangle)]
pub extern "C" fn cmux_screen_connecting_notice_shown(
    phase_raw: u32,
    reconnecting: bool,
    reconnect_notice_due: bool,
    connect_notice_due: bool,
) -> bool {
    phase(phase_raw).is_some_and(|p| {
        reconnect::connecting_notice_shown(
            p,
            reconnecting,
            reconnect_notice_due,
            connect_notice_due,
        )
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn cmux_screen_keeps_live_layout(phase_raw: u32, reconnecting: bool) -> bool {
    phase(phase_raw).is_some_and(|p| reconnect::keeps_live_layout(p, reconnecting))
}

/// A VNC encoding's name, copied to `out` (capacity `cap`) with its length in `out_len`.
///
/// # Safety
/// `out` holds `cap` bytes or is NULL with 0; `out_len` is writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screen_encoding_name(
    raw: i32,
    out: *mut u8,
    cap: usize,
    out_len: *mut usize,
) -> i32 {
    if out_len.is_null() {
        return CMUX_SCREEN_ERR_NULL;
    }
    let name = reconnect::encoding_name(raw);
    // SAFETY: checked non-NULL; writable by the caller's guarantee.
    unsafe { *out_len = name.len() };
    if name.len() > cap || out.is_null() {
        return CMUX_SCREEN_ERR_BUFFER;
    }
    // SAFETY: `out` holds `cap` >= `name.len()` bytes.
    unsafe { std::ptr::copy_nonoverlapping(name.as_ptr(), out, name.len()) };
    CMUX_SCREEN_OK
}

/// The trackpad hint's pose at `progress`; `animated` false: the still hand.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_screen_hint_pose(animated: bool, progress: f64) -> HintPose {
    HintPose::at(animated.then_some(progress))
}

#[cfg(test)]
#[path = "ffi_tests.rs"]
mod tests;
