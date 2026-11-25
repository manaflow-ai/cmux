//! The C ABI of the screen stream's rules for the macOS and iPhone apps
//! (`include/cmux_screen_stream.h`, Swift module `CCmuxScreenStreamFFI`), linked into the app
//! through cmux-app-ffi.
//!
//! - `cmux_screen_stream_call`: one stateless JSON op (`crate::ops::call`).
//! - Handles for the stateful rules: the viewer's demand, the image assembler, the cursor shape
//!   delivery and the source monitor, each `_new` / `_free`.
//! - Scalars for the per-event rules: `pixel`, the reconnect bounds.
//!
//! Every function may run on any thread; a handle is used by one thread at a time (the app holds
//! it under its own lock). None unwinds across the boundary. A reply buffer belongs to the
//! caller, who frees it with `cmux_screen_stream_bytes_free`.

use crate::cursor::CursorShapeDelivery;
use crate::demand::ViewerDemand;
use crate::ops::{OpError, call};
use crate::paste::{Assembler, ChunkAnswer, take_chunk};
use crate::quality::{self, Rect};
use crate::session;
use crate::source::SourceMonitor;
use crate::wire::{ScreenInput, SourceState};
use serde_json::{Map, Value, json};
use std::ffi::{CStr, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};

/// Bumped on any change to a type, a function or an op.
pub const CMUX_SCREEN_STREAM_ABI_VERSION: u32 = 1;
pub const CMUX_SCREEN_STREAM_OK: i32 = 0;
/// A null pointer where one is required.
pub const CMUX_SCREEN_STREAM_ERR_NULL: i32 = -1;
/// Not UTF-8, or not the JSON the op takes.
pub const CMUX_SCREEN_STREAM_ERR_INVALID: i32 = -2;
/// The op is not one of `crate::ops::call`'s.
pub const CMUX_SCREEN_STREAM_ERR_UNKNOWN_OP: i32 = -3;
/// A panic inside, caught.
pub const CMUX_SCREEN_STREAM_ERR_PANIC: i32 = -4;
/// The answer for "none" where an integer is returned (no cap, no report).
pub const CMUX_SCREEN_STREAM_NONE: i64 = -1;

/// A reply buffer owned by the caller (JSON or bytes). `ptr` is null when `len` is 0.
#[repr(C)]
pub struct CmuxScreenStreamBytes {
    pub ptr: *mut u8,
    pub len: usize,
}

impl CmuxScreenStreamBytes {
    fn empty() -> Self {
        Self { ptr: std::ptr::null_mut(), len: 0 }
    }

    fn from_vec(bytes: Vec<u8>) -> Self {
        if bytes.is_empty() {
            return Self::empty();
        }
        let boxed = bytes.into_boxed_slice();
        let len = boxed.len();
        Self { ptr: Box::into_raw(boxed).cast::<u8>(), len }
    }
}

/// A rectangle in points (a display's frame).
#[repr(C)]
#[derive(Clone, Copy)]
pub struct CmuxScreenStreamRect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

/// One viewer's demanded picture size (`crate::demand::ViewerDemand`).
pub struct CmuxScreenStreamDemand {
    inner: ViewerDemand,
}

/// One session's image paste assembler, and the last whole image it took.
pub struct CmuxScreenStreamAssembler {
    inner: Assembler,
    image: Option<Vec<u8>>,
}

/// One session's cursor shape delivery.
pub struct CmuxScreenStreamCursor {
    inner: CursorShapeDelivery,
}

/// One session's source state monitor.
pub struct CmuxScreenStreamSource {
    inner: SourceMonitor,
}

fn guard<T>(fallback: T, body: impl FnOnce() -> T) -> T {
    catch_unwind(AssertUnwindSafe(body)).unwrap_or(fallback)
}

/// # Safety
/// `ptr` is readable for `len` bytes (or `len` is 0).
unsafe fn slice<'a>(ptr: *const u8, len: usize) -> Option<&'a [u8]> {
    if len == 0 {
        return Some(&[]);
    }
    if ptr.is_null() {
        return None;
    }
    // SAFETY: the caller's pointer is readable for `len` bytes.
    Some(unsafe { std::slice::from_raw_parts(ptr, len) })
}

fn none_or(value: Option<i64>) -> i64 {
    value.unwrap_or(CMUX_SCREEN_STREAM_NONE)
}

/// `CMUX_SCREEN_STREAM_ABI_VERSION`.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_screen_stream_abi_version() -> u32 {
    CMUX_SCREEN_STREAM_ABI_VERSION
}

/// Frees a reply buffer. A null `ptr` is ignored.
///
/// # Safety
/// `bytes` came from this library and is freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screen_stream_bytes_free(bytes: CmuxScreenStreamBytes) {
    if bytes.ptr.is_null() {
        return;
    }
    // SAFETY: built by `from_vec` from a boxed slice of `len` bytes.
    drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(bytes.ptr, bytes.len)) });
}

/// Runs one stateless JSON op: `op` (NUL-terminated) on `request` (a JSON object, UTF-8; empty
/// means `{}`); `*out` gets the reply's JSON.
///
/// # Safety
/// `op` is a NUL-terminated string; `request` with its length is readable; `out` is writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screen_stream_call(
    op: *const c_char,
    request_ptr: *const u8,
    request_len: usize,
    out: *mut CmuxScreenStreamBytes,
) -> i32 {
    if op.is_null() || out.is_null() {
        return CMUX_SCREEN_STREAM_ERR_NULL;
    }
    // SAFETY: the caller's request pointer and length.
    let Some(bytes) = (unsafe { slice(request_ptr, request_len) }) else {
        return CMUX_SCREEN_STREAM_ERR_NULL;
    };
    guard(CMUX_SCREEN_STREAM_ERR_PANIC, || {
        // SAFETY: a NUL-terminated string from the caller.
        let Ok(op) = unsafe { CStr::from_ptr(op) }.to_str() else {
            return CMUX_SCREEN_STREAM_ERR_INVALID;
        };
        let request = if bytes.is_empty() {
            Value::Object(Map::new())
        } else {
            match serde_json::from_slice::<Value>(bytes) {
                Ok(value @ Value::Object(_)) => value,
                _ => return CMUX_SCREEN_STREAM_ERR_INVALID,
            }
        };
        let reply = match call(op, &request) {
            Ok(reply) => reply,
            Err(OpError::Unknown) => return CMUX_SCREEN_STREAM_ERR_UNKNOWN_OP,
            Err(OpError::Invalid) => return CMUX_SCREEN_STREAM_ERR_INVALID,
        };
        let Ok(bytes) = serde_json::to_vec(&reply) else { return CMUX_SCREEN_STREAM_ERR_INVALID };
        // SAFETY: `out` checked non-null and writable.
        unsafe { *out = CmuxScreenStreamBytes::from_vec(bytes) };
        CMUX_SCREEN_STREAM_OK
    })
}

/// A viewer's pointer fraction as a pixel on a display axis from `origin`, `length` long; a
/// negative `fraction_present` or a non-finite fraction goes to the origin; never traps.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_screen_stream_pixel(
    fraction: f64,
    fraction_present: bool,
    origin: f64,
    length: f64,
) -> i64 {
    guard(0, || quality::pixel(fraction_present.then_some(fraction), origin, length))
}

/// One reconnect attempt's timeout in seconds after `elapsed` seconds of trying.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_screen_stream_attempt_timeout(elapsed: f64) -> f64 {
    guard(1.0, || session::attempt_timeout(elapsed))
}

/// Whether reconnecting stops (after `limit` tries, or past the deadline).
#[unsafe(no_mangle)]
pub extern "C" fn cmux_screen_stream_gives_up(attempts: i64, limit: i64, elapsed: f64) -> bool {
    guard(true, || session::gives_up(attempts, limit, elapsed))
}

/// The seconds a dropped stream keeps reconnecting.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_screen_stream_reconnect_deadline() -> f64 {
    session::RECONNECT_DEADLINE
}

/// A new viewer demand (full size). Free it with `cmux_screen_stream_demand_free`.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_screen_stream_demand_new() -> *mut CmuxScreenStreamDemand {
    Box::into_raw(Box::new(CmuxScreenStreamDemand { inner: ViewerDemand::new() }))
}

/// Frees a demand; null does nothing.
///
/// # Safety
/// `demand` is null or from `cmux_screen_stream_demand_new`, freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screen_stream_demand_free(demand: *mut CmuxScreenStreamDemand) {
    if !demand.is_null() {
        // SAFETY: from `Box::into_raw` in `cmux_screen_stream_demand_new`, freed once.
        drop(unsafe { Box::from_raw(demand) });
    }
}

/// Takes one viewer report at `now` (seconds, monotonic); whether the cap changed.
///
/// # Safety
/// `demand` is null or a live handle, used by one thread at a time.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screen_stream_demand_report(
    demand: *mut CmuxScreenStreamDemand,
    long_edge: i64,
    display_long_edge: i64,
    pinch: bool,
    now: f64,
) -> bool {
    if demand.is_null() {
        return false;
    }
    // SAFETY: a live handle, one thread at a time.
    let demand = unsafe { &mut (*demand).inner };
    guard(false, || demand.report(long_edge, display_long_edge, pinch, now))
}

/// The long edge the host captures at; `CMUX_SCREEN_STREAM_NONE`: the display's own size.
///
/// # Safety
/// `demand` is null or a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screen_stream_demand_cap(
    demand: *const CmuxScreenStreamDemand,
) -> i64 {
    if demand.is_null() {
        return CMUX_SCREEN_STREAM_NONE;
    }
    // SAFETY: a live handle.
    none_or(unsafe { &(*demand).inner }.cap())
}

/// A new image assembler. Free it with `cmux_screen_stream_assembler_free`.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_screen_stream_assembler_new() -> *mut CmuxScreenStreamAssembler {
    Box::into_raw(Box::new(CmuxScreenStreamAssembler { inner: Assembler::new(), image: None }))
}

/// Frees an assembler; null does nothing.
///
/// # Safety
/// `assembler` is null or from `cmux_screen_stream_assembler_new`, freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screen_stream_assembler_free(
    assembler: *mut CmuxScreenStreamAssembler,
) {
    if !assembler.is_null() {
        // SAFETY: from `Box::into_raw` in `cmux_screen_stream_assembler_new`, freed once.
        drop(unsafe { Box::from_raw(assembler) });
    }
}

/// Takes one `paste-image` message (its JSON text). `*out` gets `{"wait":true}`, `{"answer":
/// TEXT}` (send it), or `{"paste":{"type","id"}}`: the whole image, its bytes from
/// `cmux_screen_stream_assembler_image`; paste it, then send the `paste_image` answer.
/// `backend_capabilities` is the backend's comma list.
///
/// # Safety
/// `assembler` is a live handle used by one thread at a time; the byte ranges are readable; `out`
/// is writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screen_stream_assembler_take(
    assembler: *mut CmuxScreenStreamAssembler,
    input_ptr: *const u8,
    input_len: usize,
    view_only: bool,
    capabilities_ptr: *const u8,
    capabilities_len: usize,
    out: *mut CmuxScreenStreamBytes,
) -> i32 {
    if assembler.is_null() || out.is_null() {
        return CMUX_SCREEN_STREAM_ERR_NULL;
    }
    // SAFETY: the caller's byte ranges.
    let (Some(input), Some(capabilities)) = (unsafe { slice(input_ptr, input_len) }, unsafe {
        slice(capabilities_ptr, capabilities_len)
    }) else {
        return CMUX_SCREEN_STREAM_ERR_NULL;
    };
    // SAFETY: a live handle, one thread at a time.
    let assembler = unsafe { &mut *assembler };
    guard(CMUX_SCREEN_STREAM_ERR_PANIC, || {
        let Some(input) = ScreenInput::decode(input) else { return CMUX_SCREEN_STREAM_ERR_INVALID };
        let Ok(capabilities) = std::str::from_utf8(capabilities) else {
            return CMUX_SCREEN_STREAM_ERR_INVALID;
        };
        let capabilities: Vec<String> = capabilities.split(',').map(str::to_owned).collect();
        let reply = match take_chunk(&mut assembler.inner, &input, view_only, &capabilities) {
            ChunkAnswer::Wait => json!({ "wait": true }),
            ChunkAnswer::Answer(message) => json!({ "answer": message.encode() }),
            ChunkAnswer::Paste { data, image_type, id } => {
                assembler.image = Some(data);
                json!({ "paste": { "type": image_type, "id": id } })
            }
        };
        let Ok(bytes) = serde_json::to_vec(&reply) else { return CMUX_SCREEN_STREAM_ERR_INVALID };
        // SAFETY: `out` checked non-null and writable.
        unsafe { *out = CmuxScreenStreamBytes::from_vec(bytes) };
        CMUX_SCREEN_STREAM_OK
    })
}

/// The whole image the last `take` completed, handed to the caller once (empty after).
///
/// # Safety
/// `assembler` is null or a live handle used by one thread at a time.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screen_stream_assembler_image(
    assembler: *mut CmuxScreenStreamAssembler,
) -> CmuxScreenStreamBytes {
    if assembler.is_null() {
        return CmuxScreenStreamBytes::empty();
    }
    // SAFETY: a live handle, one thread at a time.
    let assembler = unsafe { &mut *assembler };
    guard(CmuxScreenStreamBytes::empty(), || {
        assembler
            .image
            .take()
            .map_or_else(CmuxScreenStreamBytes::empty, CmuxScreenStreamBytes::from_vec)
    })
}

/// A new cursor shape delivery. Free it with `cmux_screen_stream_cursor_free`.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_screen_stream_cursor_new() -> *mut CmuxScreenStreamCursor {
    Box::into_raw(Box::new(CmuxScreenStreamCursor { inner: CursorShapeDelivery::new() }))
}

/// Frees a cursor shape delivery; null does nothing.
///
/// # Safety
/// `cursor` is null or from `cmux_screen_stream_cursor_new`, freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screen_stream_cursor_free(cursor: *mut CmuxScreenStreamCursor) {
    if !cursor.is_null() {
        // SAFETY: from `Box::into_raw` in `cmux_screen_stream_cursor_new`, freed once.
        drop(unsafe { Box::from_raw(cursor) });
    }
}

/// One tick's read: the shape now as its JSON object (with its `id`; empty: none known) on
/// `display`. `*out` gets the message text to send now (empty: none); then call
/// `cmux_screen_stream_cursor_finish`.
///
/// # Safety
/// `cursor` is a live handle used by one thread at a time; the shape range is readable; `out` is
/// writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screen_stream_cursor_prepare(
    cursor: *mut CmuxScreenStreamCursor,
    shape_ptr: *const u8,
    shape_len: usize,
    display: CmuxScreenStreamRect,
    out: *mut CmuxScreenStreamBytes,
) -> i32 {
    if cursor.is_null() || out.is_null() {
        return CMUX_SCREEN_STREAM_ERR_NULL;
    }
    // SAFETY: the caller's byte range.
    let Some(shape) = (unsafe { slice(shape_ptr, shape_len) }) else {
        return CMUX_SCREEN_STREAM_ERR_NULL;
    };
    // SAFETY: a live handle, one thread at a time.
    let cursor = unsafe { &mut (*cursor).inner };
    guard(CMUX_SCREEN_STREAM_ERR_PANIC, || {
        let read = if shape.is_empty() {
            None
        } else {
            match serde_json::from_slice::<Value>(shape) {
                Ok(value) => match value.get("id").and_then(Value::as_str) {
                    Some(id) => Some((id.to_owned(), value)),
                    None => return CMUX_SCREEN_STREAM_ERR_INVALID,
                },
                Err(_) => return CMUX_SCREEN_STREAM_ERR_INVALID,
            }
        };
        let display = Rect { x: display.x, y: display.y, w: display.w, h: display.h };
        let text = cursor.prepare(read.as_ref().map(|(id, value)| (id.as_str(), value)), display);
        let bytes = text.map(|t| t.as_bytes().to_vec()).unwrap_or_default();
        // SAFETY: `out` checked non-null and writable.
        unsafe { *out = CmuxScreenStreamBytes::from_vec(bytes) };
        CMUX_SCREEN_STREAM_OK
    })
}

/// Whether the link took the text `prepare` gave; returns the cursor shape's id now (empty:
/// none).
///
/// # Safety
/// `cursor` is null or a live handle used by one thread at a time.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screen_stream_cursor_finish(
    cursor: *mut CmuxScreenStreamCursor,
    delivered: bool,
) -> CmuxScreenStreamBytes {
    if cursor.is_null() {
        return CmuxScreenStreamBytes::empty();
    }
    // SAFETY: a live handle, one thread at a time.
    let cursor = unsafe { &mut (*cursor).inner };
    guard(CmuxScreenStreamBytes::empty(), || {
        CmuxScreenStreamBytes::from_vec(
            cursor.finish(delivered).map(|s| s.as_bytes().to_vec()).unwrap_or_default(),
        )
    })
}

/// A new source monitor. Free it with `cmux_screen_stream_source_free`.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_screen_stream_source_new() -> *mut CmuxScreenStreamSource {
    Box::into_raw(Box::new(CmuxScreenStreamSource { inner: SourceMonitor::new() }))
}

/// Frees a source monitor; null does nothing.
///
/// # Safety
/// `source` is null or from `cmux_screen_stream_source_new`, freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screen_stream_source_free(source: *mut CmuxScreenStreamSource) {
    if !source.is_null() {
        // SAFETY: from `Box::into_raw` in `cmux_screen_stream_source_new`, freed once.
        drop(unsafe { Box::from_raw(source) });
    }
}

/// Takes one reading (`locked`, `asleep`); the state to report (0 live, 1 locked, 2 asleep), or
/// `CMUX_SCREEN_STREAM_NONE` when it did not change or the monitor stopped.
///
/// # Safety
/// `source` is null or a live handle used by one thread at a time.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screen_stream_source_check(
    source: *mut CmuxScreenStreamSource,
    locked: bool,
    asleep: bool,
) -> i64 {
    if source.is_null() {
        return CMUX_SCREEN_STREAM_NONE;
    }
    // SAFETY: a live handle, one thread at a time.
    let source = unsafe { &mut (*source).inner };
    guard(CMUX_SCREEN_STREAM_NONE, || {
        none_or(source.check(SourceState::from_flags(locked, asleep)).map(|s| s as i64))
    })
}

/// The state the last check read (0 live, 1 locked, 2 asleep); `CMUX_SCREEN_STREAM_NONE` before
/// the first.
///
/// # Safety
/// `source` is null or a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screen_stream_source_state(
    source: *const CmuxScreenStreamSource,
) -> i64 {
    if source.is_null() {
        return CMUX_SCREEN_STREAM_NONE;
    }
    // SAFETY: a live handle.
    none_or(unsafe { &(*source).inner }.state().map(|s| s as i64))
}

/// Stops a source monitor: later checks report nothing.
///
/// # Safety
/// `source` is null or a live handle used by one thread at a time.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screen_stream_source_stop(source: *mut CmuxScreenStreamSource) {
    if !source.is_null() {
        // SAFETY: a live handle, one thread at a time.
        unsafe { &mut (*source).inner }.stop();
    }
}
