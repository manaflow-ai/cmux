//! The C ABI of the cookie sync for the macOS app
//! (`include/cmux_cookie_sync.h`, Swift module `CCmuxCookieSyncFFI`),
//! linked into the app through cmux-app-ffi.
//!
//! - `cmux_cookie_sync_new`: starts the sync's thread on a JSON config; it
//!   calls the app back with one JSON report per scan.
//! - `cmux_cookie_sync_commit`: the app imported the last reported change.
//! - `cmux_cookie_sync_free`: stops the thread and waits for it.
//!
//! None unwinds across the boundary.

use crate::engine::{Config, CookieSync, Report};
use std::ffi::c_void;
use std::panic::{AssertUnwindSafe, catch_unwind};

/// Bumped on any change to a type, a function, the config or a report.
pub const CMUX_COOKIE_SYNC_ABI_VERSION: u32 = 1;

/// A running cookie sync.
pub struct CmuxCookieSync {
    sync: CookieSync,
}

/// Called on the sync's own thread with one report's JSON (UTF-8, `len`
/// bytes, valid only during the call), `ctx` as given to
/// `cmux_cookie_sync_new`. Reports, by `kind`:
/// `{"kind":"changed","source","generation","changed":[domain],"removed":[domain],"rows","hosts","scan_ms","cpu_ms","reason"}`,
/// `{"kind":"scanned","source","rows","hosts","scan_ms","cpu_ms","reason"}`,
/// `{"kind":"gone","source"}`, `{"kind":"failed","source","reason"}`;
/// `reason` of a scan is `launch`, `watch` or `baseline`; `cpu_ms` may be null.
pub type CmuxCookieSyncCallback =
    Option<unsafe extern "C" fn(ctx: *mut c_void, json: *const u8, len: usize)>;

/// The app's callback and context, moved to the sync's thread.
struct Callback {
    call: unsafe extern "C" fn(*mut c_void, *const u8, usize),
    ctx: *mut c_void,
}

// SAFETY: the caller of `cmux_cookie_sync_new` promises the callback may be
// called from another thread with `ctx` until `cmux_cookie_sync_free` returns.
unsafe impl Send for Callback {}

impl Callback {
    fn report(&self, report: &Report) {
        let Ok(json) = serde_json::to_vec(report) else { return };
        // SAFETY: the callback's contract (above); the bytes outlive the call.
        unsafe { (self.call)(self.ctx, json.as_ptr(), json.len()) };
    }
}

/// `CMUX_COOKIE_SYNC_ABI_VERSION`.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_cookie_sync_abi_version() -> u32 {
    CMUX_COOKIE_SYNC_ABI_VERSION
}

/// Starts a cookie sync on `config` (JSON `{"state_dir", "debounce_ms"?:
/// 2000, "min_interval_ms"?: 30000, "sources": [{"id", "database"}]}`, absolute
/// paths, unique ids). Its thread checks every source at once (a source with
/// no saved baseline takes its current cookies as the baseline), then scans
/// a source after its database changes, and calls `callback` with each
/// report. Null on an invalid config, a null callback or no thread.
///
/// # Safety
///
/// `config` with its length is readable. `callback` may be called from the
/// sync's thread with `ctx` until `cmux_cookie_sync_free` returns; it must not
/// call `cmux_cookie_sync_free` itself.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_cookie_sync_new(
    config_ptr: *const u8,
    config_len: usize,
    callback: CmuxCookieSyncCallback,
    ctx: *mut c_void,
) -> *mut CmuxCookieSync {
    let Some(call) = callback else { return std::ptr::null_mut() };
    if config_ptr.is_null() || config_len == 0 {
        return std::ptr::null_mut();
    }
    // SAFETY: the caller's pointer is readable for `config_len` bytes.
    let bytes = unsafe { std::slice::from_raw_parts(config_ptr, config_len) };
    let started = catch_unwind(AssertUnwindSafe(|| {
        let config = Config::parse(bytes)?;
        let callback = Callback { call, ctx };
        CookieSync::start(config, Box::new(move |report: &Report| callback.report(report))).ok()
    }));
    match started {
        Ok(Some(sync)) => Box::into_raw(Box::new(CmuxCookieSync { sync })),
        _ => std::ptr::null_mut(),
    }
}

/// The app imported the `changed` report of source `source_id` (UTF-8) with
/// `generation` (the report's own): its cookies become that source's saved
/// baseline. False when the id is unknown, the report is not the source's
/// latest (commit the later one, which holds its domains too), a later scan
/// found nothing changed, or the baseline could not be saved (the change is
/// then reported again on the next scan or launch).
///
/// # Safety
///
/// `sync` is null or a live handle; `source_id` with its length is readable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_cookie_sync_commit(
    sync: *const CmuxCookieSync,
    source_id_ptr: *const u8,
    source_id_len: usize,
    generation: u64,
) -> bool {
    if sync.is_null() || source_id_ptr.is_null() {
        return false;
    }
    // SAFETY: a live handle; the id is readable for its length.
    let (sync, id) = unsafe { (&*sync, std::slice::from_raw_parts(source_id_ptr, source_id_len)) };
    let Ok(id) = std::str::from_utf8(id) else { return false };
    catch_unwind(AssertUnwindSafe(|| sync.sync.commit(id, generation))).unwrap_or(false)
}

/// Stops the sync's thread, waits for it (at most the scan in progress) and
/// frees the handle. Null is ignored.
///
/// # Safety
///
/// `sync` is null or a live handle, not used afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_cookie_sync_free(sync: *mut CmuxCookieSync) {
    if sync.is_null() {
        return;
    }
    // SAFETY: a live handle from `cmux_cookie_sync_new`, freed once.
    let sync = unsafe { Box::from_raw(sync) };
    let _ = catch_unwind(AssertUnwindSafe(|| drop(sync)));
}
