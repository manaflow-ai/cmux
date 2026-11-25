//! The C ABI (include/cmux_layout_cache.h). Values cross as JSON strings: a handful of calls per
//! launch and per settled layout change, never per frame, so a small surface beats a struct per
//! type. Every returned string is freed with `cmux_layout_cache_string_free`. Nothing panics
//! across the boundary: each body runs under `catch_unwind` and a panic reads as the call's
//! failure value.
use std::ffi::{CStr, CString, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::Path;

use serde::Serialize;

use crate::model::{LayoutCache, PaneNode, Rect, RowHeight, TabSlot};
use crate::reconcile::{IdRect, LiveTree, reconcile, reconcile_rows, reconcile_strip, shift_score};
use crate::store::{WriteCoalescer, cache_path, read, write};
use crate::swap::{ShellKind, swap_wait_ms};
use crate::usable::{NowState, usable};

/// `cmux_layout_cache_write`'s and `_coalescer_write`'s failures.
pub const BAD_INPUT: i32 = -1;
pub const IO_FAILED: i32 = -2;

fn guard<T>(fallback: T, f: impl FnOnce() -> T) -> T {
    catch_unwind(AssertUnwindSafe(f)).unwrap_or(fallback)
}

unsafe fn c_str<'a>(p: *const c_char) -> Option<&'a str> {
    if p.is_null() { None } else { unsafe { CStr::from_ptr(p) }.to_str().ok() }
}

fn c_string(s: String) -> *mut c_char {
    CString::new(s).map_or(std::ptr::null_mut(), CString::into_raw)
}

fn json_out<T: Serialize>(v: &T) -> *mut c_char {
    serde_json::to_string(v).map_or(std::ptr::null_mut(), c_string)
}

fn parse<T: serde::de::DeserializeOwned>(s: Option<&str>) -> Option<T> {
    serde_json::from_str(s?).ok()
}

/// Frees a string this ABI returned. Null does nothing.
///
/// # Safety
/// `s` is null or a pointer a `cmux_layout_cache_*` function returned, not yet freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_layout_cache_string_free(s: *mut c_char) {
    if !s.is_null() {
        guard((), || drop(unsafe { CString::from_raw(s) }));
    }
}

/// `<state_dir>/layout-cache/v1.json`, or null for a null or non-UTF-8 argument.
///
/// # Safety
/// `state_dir` is null or a NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_layout_cache_path(state_dir: *const c_char) -> *mut c_char {
    let Some(dir) = (unsafe { c_str(state_dir) }) else { return std::ptr::null_mut() };
    guard(std::ptr::null_mut(), || {
        cache_path(Path::new(dir)).to_str().map_or(std::ptr::null_mut(), |p| c_string(p.to_owned()))
    })
}

/// The cache at `path` as JSON (`LayoutCache`), or null when missing, over 512 KiB, another
/// version or not a cache.
///
/// # Safety
/// `path` is null or a NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_layout_cache_read(path: *const c_char) -> *mut c_char {
    let Some(path) = (unsafe { c_str(path) }) else { return std::ptr::null_mut() };
    guard(std::ptr::null_mut(), || {
        read(Path::new(path)).map_or(std::ptr::null_mut(), |c| json_out(&c))
    })
}

fn parse_cache(json: Option<&str>) -> Option<LayoutCache> {
    LayoutCache::from_json(json?)
}

/// Writes `json` (a `LayoutCache`) to `path` atomically. 0 written, -1 not a version-1 cache
/// (or a bad argument), -2 the write failed (the old file is untouched).
///
/// # Safety
/// Both arguments are null or NUL-terminated strings.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_layout_cache_write(path: *const c_char, json: *const c_char) -> i32 {
    let (path, json) = (unsafe { c_str(path) }, unsafe { c_str(json) });
    guard(BAD_INPUT, || {
        let (Some(path), Some(cache)) = (path, parse_cache(json)) else { return BAD_INPUT };
        if write(Path::new(path), &cache).is_ok() { 0 } else { IO_FAILED }
    })
}

/// Which parts of `cache_json` this launch may apply (`Usable` as JSON) given `now_json`
/// (`NowState`: `build_key`, `displays`, `now_ms`). Null for bad input.
///
/// # Safety
/// Both arguments are null or NUL-terminated strings.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_layout_cache_usable(
    cache_json: *const c_char,
    now_json: *const c_char,
) -> *mut c_char {
    let (cache, now) = (unsafe { c_str(cache_json) }, unsafe { c_str(now_json) });
    guard(std::ptr::null_mut(), || {
        let (Some(cache), Some(now)) = (parse_cache(cache), parse::<NowState>(now)) else {
            return std::ptr::null_mut();
        };
        json_out(&usable(&cache, &now))
    })
}

/// Fits a cached split tree (`PaneNode`) to the live one (`LiveTree`); `Applied` as JSON. Null
/// for bad input or a malformed cached tree.
///
/// # Safety
/// Both arguments are null or NUL-terminated strings.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_layout_cache_reconcile(
    cached_node_json: *const c_char,
    live_json: *const c_char,
) -> *mut c_char {
    let (cached, live) = (unsafe { c_str(cached_node_json) }, unsafe { c_str(live_json) });
    guard(std::ptr::null_mut(), || {
        let (Some(cached), Some(live)) = (parse::<PaneNode>(cached), parse::<LiveTree>(live))
        else {
            return std::ptr::null_mut();
        };
        if !cached.is_well_formed() {
            return std::ptr::null_mut();
        }
        json_out(&reconcile(&cached, &live))
    })
}

/// The tab strip for the live tab ids (`live_ids_json`, a JSON array of strings, in order) from
/// the cached one (`cached_json`, `[{id, x, width}]`); `StripApplied` as JSON, or null.
///
/// # Safety
/// Both strings are null or NUL-terminated.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_layout_cache_reconcile_strip(
    cached_json: *const c_char,
    live_ids_json: *const c_char,
    default_width: f64,
) -> *mut c_char {
    let (cached, live) = (unsafe { c_str(cached_json) }, unsafe { c_str(live_ids_json) });
    guard(std::ptr::null_mut(), || {
        let (Some(cached), Some(live)) =
            (parse::<Vec<TabSlot>>(cached), parse::<Vec<String>>(live))
        else {
            return std::ptr::null_mut();
        };
        json_out(&reconcile_strip(&cached, &live, default_width))
    })
}

/// Sidebar row heights for the live row ids from the cached ones (`[{id, height}]`);
/// `RowsApplied` as JSON, or null.
///
/// # Safety
/// Both strings are null or NUL-terminated.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_layout_cache_reconcile_rows(
    cached_json: *const c_char,
    live_ids_json: *const c_char,
    default_height: f64,
) -> *mut c_char {
    let (cached, live) = (unsafe { c_str(cached_json) }, unsafe { c_str(live_ids_json) });
    guard(std::ptr::null_mut(), || {
        let (Some(cached), Some(live)) =
            (parse::<Vec<RowHeight>>(cached), parse::<Vec<String>>(live))
        else {
            return std::ptr::null_mut();
        };
        json_out(&reconcile_rows(&cached, &live, default_height))
    })
}

/// The layout shift between two sets of `[{id, x, y, width, height}]` in `viewport_json`
/// (`{x, y, width, height}`); 0 when nothing moved, -1 for bad input.
///
/// # Safety
/// The three arguments are null or NUL-terminated strings.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_layout_cache_shift_score(
    before_json: *const c_char,
    after_json: *const c_char,
    viewport_json: *const c_char,
) -> f64 {
    let (b, a, v) = (unsafe { c_str(before_json) }, unsafe { c_str(after_json) }, unsafe {
        c_str(viewport_json)
    });
    guard(-1.0, || {
        let (Some(b), Some(a), Some(v)) =
            (parse::<Vec<IdRect>>(b), parse::<Vec<IdRect>>(a), parse::<Rect>(v))
        else {
            return -1.0;
        };
        shift_score(&b, &a, &v)
    })
}

/// How many ms more the real launch window waits under stage 0; 0 swaps now. `kind`: 0 image,
/// 1 plain, 2 bare (anything else reads as plain). Now when `ready >= visible`; never more than
/// the kind's bound (400, 150, 1500 ms) minus `elapsed_ms` since stage 0 showed.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_layout_cache_swap_wait_ms(
    kind: u8,
    visible: u32,
    ready: u32,
    elapsed_ms: u64,
) -> u64 {
    swap_wait_ms(ShellKind::from_u8(kind), visible, ready, elapsed_ms)
}

/// The write coalescer, opaque to C. One thread at a time (the app's main thread).
pub struct CmuxLayoutCacheCoalescer(WriteCoalescer);

/// A new coalescer; free it with `cmux_layout_cache_coalescer_free`.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_layout_cache_coalescer_new() -> *mut CmuxLayoutCacheCoalescer {
    Box::into_raw(Box::new(CmuxLayoutCacheCoalescer(WriteCoalescer::new())))
}

/// # Safety
/// `c` is null or a coalescer from `cmux_layout_cache_coalescer_new`, not yet freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_layout_cache_coalescer_free(c: *mut CmuxLayoutCacheCoalescer) {
    if !c.is_null() {
        guard((), || drop(unsafe { Box::from_raw(c) }));
    }
}

unsafe fn coalescer<'a>(c: *mut CmuxLayoutCacheCoalescer) -> Option<&'a mut WriteCoalescer> {
    if c.is_null() { None } else { Some(unsafe { &mut (*c).0 }) }
}

/// A layout changed at `now_ms` (the app's monotonic clock).
///
/// # Safety
/// `c` is null or a live coalescer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_layout_cache_coalescer_note(
    c: *mut CmuxLayoutCacheCoalescer,
    now_ms: u64,
) {
    if let Some(c) = unsafe { coalescer(c) } {
        guard((), || c.note_change(now_ms));
    }
}

/// Whether the pending change should be written now (250 ms after the last change, at most 2 s
/// after the first).
///
/// # Safety
/// `c` is null or a live coalescer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_layout_cache_coalescer_due(
    c: *mut CmuxLayoutCacheCoalescer,
    now_ms: u64,
) -> bool {
    unsafe { coalescer(c) }.is_some_and(|c| guard(false, || c.due(now_ms)))
}

/// When the pending change becomes due, for the app's one timer; -1 when nothing is pending.
///
/// # Safety
/// `c` is null or a live coalescer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_layout_cache_coalescer_next_due_ms(
    c: *mut CmuxLayoutCacheCoalescer,
) -> i64 {
    unsafe { coalescer(c) }
        .and_then(|c| guard(None, || c.next_due_ms()))
        .map_or(-1, |at| i64::try_from(at).unwrap_or(i64::MAX))
}

/// At quit: whether a change is pending, whatever the clock says.
///
/// # Safety
/// `c` is null or a live coalescer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_layout_cache_coalescer_flush_now(
    c: *mut CmuxLayoutCacheCoalescer,
) -> bool {
    unsafe { coalescer(c) }.is_some_and(|c| guard(false, || c.flush_now()))
}

/// Writes `json` (a `LayoutCache`) to `path` unless its content equals the last write
/// (`written_at_ms` aside). 1 written, 0 unchanged (nothing pending now), -1 bad input, -2 the
/// write failed (still pending; the old file untouched).
///
/// # Safety
/// `c` is null or a live coalescer; `path` and `json` are null or NUL-terminated strings.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_layout_cache_coalescer_write(
    c: *mut CmuxLayoutCacheCoalescer,
    path: *const c_char,
    json: *const c_char,
) -> i32 {
    let (Some(c), path, json) =
        (unsafe { coalescer(c) }, unsafe { c_str(path) }, unsafe { c_str(json) })
    else {
        return BAD_INPUT;
    };
    guard(BAD_INPUT, || {
        let (Some(path), Some(cache)) = (path, parse_cache(json)) else { return BAD_INPUT };
        match c.write(Path::new(path), &cache) {
            Ok(true) => 1,
            Ok(false) => 0,
            Err(_) => IO_FAILED,
        }
    })
}

/// Records that `json` reached disk by another route (`cmux_layout_cache_write`): the pending
/// change clears and the same content later skips its write. False for bad input.
///
/// # Safety
/// `c` is null or a live coalescer; `json` is null or a NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_layout_cache_coalescer_wrote(
    c: *mut CmuxLayoutCacheCoalescer,
    json: *const c_char,
) -> bool {
    let (Some(c), json) = (unsafe { coalescer(c) }, unsafe { c_str(json) }) else { return false };
    guard(false, || {
        let Some(cache) = parse_cache(json) else { return false };
        c.wrote(&cache);
        true
    })
}

#[cfg(test)]
#[path = "ffi_tests.rs"]
mod tests;
