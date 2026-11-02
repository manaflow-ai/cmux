//! The C ABI of the host budget (`include/cmux_host_budget_ffi.h`, Swift module
//! `CCmuxHostBudgetFFI`), linked into the macOS app through cmux-app-ffi: the host CPU/RAM budget's verdict from
//! this process's own meter, a verdict judged again with the memory pressure
//! the dispatch source reports, and the tracker that turns verdicts into the
//! level the app shows. The formula lives once, in this crate, which acpmux's
//! daemon also uses; the app keeps only the dispatch source, its
//! timer and the views.
//!
//! Verdicts cross as UTF-8 JSON (pointer and length in, a NUL-terminated
//! string out that `cmux_host_budget_string_free` frees), in the shape of
//! acpmux's `host_pressure`. The app calls these about once per 15 s and on
//! each memory pressure event, never per frame or per key. No call panics
//! across the boundary: a panic or a bad input gives null (or -2).

use crate::{Level, Tracker, json};
use std::ffi::{CString, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};

/// Bumped on any change to a type or function in the header.
const ABI_VERSION: u32 = 1;

/// What a tracker or level call returns for an input that is not a verdict.
const NOT_A_VERDICT: i32 = -2;

/// What `cmux_host_pressure_tracker_feed` returns when the level stayed.
const UNCHANGED: i32 = -1;

/// The ABI version this library implements.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_host_budget_ffi_abi_version() -> u32 {
    ABI_VERSION
}

/// The input bytes as UTF-8; `None` for a null pointer or bad UTF-8.
///
/// # Safety
///
/// `bytes` is null or points to `len` readable bytes.
unsafe fn text<'a>(bytes: *const u8, len: usize) -> Option<&'a str> {
    if bytes.is_null() {
        return None;
    }
    // SAFETY: the caller passes `len` readable bytes at `bytes`.
    let slice = unsafe { std::slice::from_raw_parts(bytes, len) };
    std::str::from_utf8(slice).ok()
}

/// A JSON call's answer as a new C string; null for none or a panic.
fn answer(call: impl FnOnce() -> Option<String>) -> *mut c_char {
    match catch_unwind(AssertUnwindSafe(call)) {
        Ok(Some(text)) => CString::new(text).map_or(std::ptr::null_mut(), CString::into_raw),
        _ => std::ptr::null_mut(),
    }
}

/// This Mac's verdict now, from the process's one meter. Blocking (sysctl,
/// host_statistics64, the override file): call it off the main thread. Null
/// while another read is in flight.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_host_budget_local_verdict_json() -> *mut c_char {
    answer(json::local_verdict)
}

/// `verdict` judged again with memory pressure `level` (1 normal, 2 warn,
/// 4 critical: `DISPATCH_MEMORYPRESSURE_*`); null when it is not a verdict.
///
/// # Safety
///
/// `verdict` is null or points to `verdict_len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_host_budget_with_pressure_json(
    verdict: *const u8,
    verdict_len: usize,
    level: u32,
) -> *mut c_char {
    // SAFETY: forwarded from the caller's contract.
    let Some(verdict) = (unsafe { text(verdict, verdict_len) }) else {
        return std::ptr::null_mut();
    };
    answer(|| json::verdict_with_pressure(verdict, level))
}

/// The verdict for given numbers with the built-in formula
/// (`{"host", "sample", "swap_mb_per_min"}`); null for a bad input.
///
/// # Safety
///
/// `input` is null or points to `input_len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_host_budget_judge_json(
    input: *const u8,
    input_len: usize,
) -> *mut c_char {
    // SAFETY: forwarded from the caller's contract.
    let Some(input) = (unsafe { text(input, input_len) }) else {
        return std::ptr::null_mut();
    };
    answer(|| json::judge(input))
}

/// Frees a string a `cmux_host_budget_*_json` call returned.
///
/// # Safety
///
/// `text` is null or a string from a `cmux_host_budget_*_json` call that was
/// not freed yet.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_host_budget_string_free(text: *mut c_char) {
    if !text.is_null() {
        // SAFETY: the pointer came from CString::into_raw and is freed once.
        drop(unsafe { CString::from_raw(text) });
    }
}

/// The level `verdict` alone calls for while the app shows `holding`
/// (0 normal, 1 warning, 2 critical); -2 when it is not a verdict or
/// `holding` is not a level.
///
/// # Safety
///
/// `verdict` is null or points to `verdict_len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_host_pressure_level_for(
    verdict: *const u8,
    verdict_len: usize,
    holding: i32,
) -> i32 {
    // SAFETY: forwarded from the caller's contract.
    let Some(verdict) = (unsafe { text(verdict, verdict_len) }) else { return NOT_A_VERDICT };
    let Some(holding) = Level::from_code(holding) else { return NOT_A_VERDICT };
    catch_unwind(|| json::level_of(verdict, holding))
        .ok()
        .flatten()
        .map_or(NOT_A_VERDICT, Level::code)
}

/// A tracker at normal that falls after `calm_samples` (at least 1) calm
/// verdicts. Free it with `cmux_host_pressure_tracker_free`.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_host_pressure_tracker_new(calm_samples: u32) -> *mut Tracker {
    Box::into_raw(Box::new(Tracker::new(calm_samples)))
}

/// # Safety
///
/// `tracker` is null or a pointer from `cmux_host_pressure_tracker_new` that
/// was not freed yet.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_host_pressure_tracker_free(tracker: *mut Tracker) {
    if !tracker.is_null() {
        // SAFETY: the pointer came from Box::into_raw and is freed once.
        drop(unsafe { Box::from_raw(tracker) });
    }
}

/// The tracker's level (0 normal, 1 warning, 2 critical); -2 for null.
///
/// # Safety
///
/// `tracker` is null or a live pointer from `cmux_host_pressure_tracker_new`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_host_pressure_tracker_level(tracker: *const Tracker) -> i32 {
    // SAFETY: null or a live tracker, by the caller's contract.
    unsafe { tracker.as_ref() }.map_or(NOT_A_VERDICT, |t| t.level().code())
}

/// Feeds one verdict: the new level when it changed (0, 1, 2), -1 when it
/// did not, -2 when the input is not a verdict (the tracker is unchanged).
///
/// # Safety
///
/// `tracker` is null or a live pointer from `cmux_host_pressure_tracker_new`,
/// used by one thread at a time; `verdict` is null or points to `verdict_len`
/// readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_host_pressure_tracker_feed(
    tracker: *mut Tracker,
    verdict: *const u8,
    verdict_len: usize,
) -> i32 {
    // SAFETY: null or a live tracker used by one thread, by the caller's contract.
    let Some(tracker) = (unsafe { tracker.as_mut() }) else { return NOT_A_VERDICT };
    // SAFETY: forwarded from the caller's contract.
    let Some(verdict) = (unsafe { text(verdict, verdict_len) }) else { return NOT_A_VERDICT };
    match catch_unwind(AssertUnwindSafe(|| json::feed(tracker, verdict))) {
        Ok(Some(Some(level))) => level.code(),
        Ok(Some(None)) => UNCHANGED,
        _ => NOT_A_VERDICT,
    }
}

#[cfg(test)]
#[path = "ffi_tests.rs"]
mod tests;
