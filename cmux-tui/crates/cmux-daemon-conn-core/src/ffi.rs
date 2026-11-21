//! The C ABI of the connection rules for the macOS app
//! (`include/cmux_daemon_conn.h`, Swift module `CCmuxDaemonConnFFI`), linked
//! into the app through cmux-app-ffi.
//!
//! - The retry pacer and the heartbeat are `#[repr(C)]` values the app keeps
//!   inline; each step is one call on a pointer to it.
//! - The request-latency probe is a handle ([`CmuxDaemonLatency`]) recorded
//!   into from any thread, lock-free, once per daemon request.
//! - A command scope is a handle ([`CmuxDaemonScope`]) with JSON ops.
//! - Every other rule is a JSON op of [`cmux_daemon_conn_call`].
//!
//! No function unwinds across the boundary ([`ERR_PANIC`]). A reply buffer
//! ([`CmuxDaemonConnBytes`]) belongs to the caller, who frees it with
//! [`cmux_daemon_conn_bytes_free`].

use crate::heartbeat::{CmuxHeartbeat, CmuxHeartbeatStep};
use crate::latency::{self, Latency, Outcome};
use crate::ops::{self, OpError};
use crate::retry::{CmuxRetryPacer, CmuxRetryPolicy, Preset, WakeCause};
use crate::scope::Scope;
use serde_json::Value;
use std::ffi::{CStr, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::Mutex;

/// Bumped on any change to a type, a function or an op in the header.
pub const ABI_VERSION: u32 = 1;
pub const OK: i32 = 0;
pub const ERR_NULL: i32 = -1;
pub const ERR_INVALID: i32 = -2;
pub const ERR_UNKNOWN_OP: i32 = -3;
pub const ERR_PANIC: i32 = -4;

/// A reply buffer owned by the caller: free it with
/// `cmux_daemon_conn_bytes_free`. `ptr` is NULL when `len` is 0.
#[repr(C)]
#[derive(Debug)]
pub struct CmuxDaemonConnBytes {
    pub ptr: *mut u8,
    pub len: usize,
}

impl CmuxDaemonConnBytes {
    const EMPTY: Self = Self { ptr: std::ptr::null_mut(), len: 0 };

    fn from_vec(bytes: Vec<u8>) -> Self {
        if bytes.is_empty() {
            return Self::EMPTY;
        }
        let boxed = bytes.into_boxed_slice();
        let len = boxed.len();
        Self { ptr: Box::into_raw(boxed).cast::<u8>(), len }
    }
}

/// A request-latency probe (one per local daemon service).
pub struct CmuxDaemonLatency {
    latency: Latency,
}

/// One app action's command scope.
pub struct CmuxDaemonScope {
    scope: Mutex<Scope>,
}

/// A probe's totals besides the bucket counts.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct CmuxDaemonLatencyTotals {
    pub errors: u64,
    pub timeouts: u64,
    pub max_us: u64,
}

fn guarded(body: impl FnOnce() -> i32) -> i32 {
    catch_unwind(AssertUnwindSafe(body)).unwrap_or(ERR_PANIC)
}

unsafe fn request_value(ptr: *const u8, len: usize) -> Result<Value, i32> {
    if len == 0 {
        return Ok(Value::Object(serde_json::Map::new()));
    }
    if ptr.is_null() {
        return Err(ERR_NULL);
    }
    // SAFETY: the C caller guarantees `len` readable bytes at `ptr`.
    let bytes = unsafe { std::slice::from_raw_parts(ptr, len) };
    serde_json::from_slice(bytes).map_err(|_| ERR_INVALID)
}

unsafe fn op_name<'a>(op: *const c_char) -> Result<&'a str, i32> {
    if op.is_null() {
        return Err(ERR_NULL);
    }
    // SAFETY: a NUL-terminated C string from the caller.
    unsafe { CStr::from_ptr(op) }.to_str().map_err(|_| ERR_INVALID)
}

unsafe fn give(out: *mut CmuxDaemonConnBytes, result: Result<Value, OpError>) -> i32 {
    match result {
        Ok(value) => {
            let Ok(bytes) = serde_json::to_vec(&value) else { return ERR_INVALID };
            // SAFETY: `out` is writable (checked non-null by every caller).
            unsafe { *out = CmuxDaemonConnBytes::from_vec(bytes) };
            OK
        }
        Err(OpError::Invalid(_)) => ERR_INVALID,
        Err(OpError::Unknown) => ERR_UNKNOWN_OP,
    }
}

/// `ABI_VERSION`.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_daemon_conn_abi_version() -> u32 {
    ABI_VERSION
}

/// Frees a reply buffer.
///
/// # Safety
/// `bytes` came from this library and is freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_daemon_conn_bytes_free(bytes: CmuxDaemonConnBytes) {
    if !bytes.ptr.is_null() {
        let slice = std::ptr::slice_from_raw_parts_mut(bytes.ptr, bytes.len);
        // SAFETY: `ptr` and `len` are a boxed slice this library gave out.
        drop(unsafe { Box::from_raw(slice) });
    }
}

/// One JSON op (request: a JSON object, or empty for {}). Codes: 0 OK, -1 a
/// null pointer, -2 invalid input, -3 an unknown op, -4 a panic (caught). On
/// any code but 0 nothing is written to `*out`.
///
/// # Safety
/// `op` is NULL or a NUL-terminated string; `request` has `request_len` readable bytes (or `request_len` is 0); `out` is NULL or writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_daemon_conn_call(
    op: *const c_char,
    request: *const u8,
    request_len: usize,
    out: *mut CmuxDaemonConnBytes,
) -> i32 {
    if out.is_null() {
        return ERR_NULL;
    }
    guarded(|| {
        // SAFETY: the caller's pointer rules.
        let (op, request) = match unsafe { (op_name(op), request_value(request, request_len)) } {
            (Ok(op), Ok(request)) => (op, request),
            (Err(code), _) | (_, Err(code)) => return code,
        };
        // SAFETY: `out` checked non-null.
        unsafe { give(out, ops::call(op, &request)) }
    })
}

// ---- Retry pacing ----

/// A named policy: 0 reconnect, 1 first connect, 2 local reconnect, 3 local
/// first connect, 4 resync. -2 for another code.
///
/// # Safety
/// `out` is NULL or writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_retry_policy_preset(preset: u32, out: *mut CmuxRetryPolicy) -> i32 {
    if out.is_null() {
        return ERR_NULL;
    }
    let Some(preset) = Preset::from_code(preset) else { return ERR_INVALID };
    // SAFETY: `out` checked non-null.
    unsafe { *out = preset.policy() };
    OK
}

/// A policy with its values corrected (an `initial_ns` of 0 is 100 ms; the
/// maximum is at least the initial).
#[unsafe(no_mangle)]
pub extern "C" fn cmux_retry_policy_new(
    initial_ns: u64,
    maximum_ns: u64,
    timed_retries: i64,
    socket_retries: i64,
    keeps_trying: bool,
) -> CmuxRetryPolicy {
    CmuxRetryPolicy::new(initial_ns, maximum_ns, timed_retries, socket_retries, keeps_trying)
}

/// The longest spacing after a busy refusal, nanoseconds.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_retry_busy_cap_ns() -> u64 {
    crate::retry::BUSY_RETRY_CAP_NS
}

/// A fresh pacer for `policy`.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_retry_pacer_new(policy: CmuxRetryPolicy) -> CmuxRetryPacer {
    CmuxRetryPacer::new(policy)
}

fn with_pacer<T>(
    pacer: *mut CmuxRetryPacer,
    fallback: T,
    body: impl FnOnce(&mut CmuxRetryPacer) -> T,
) -> T {
    // SAFETY: a pointer to a pacer the caller owns and does not share during the call.
    match unsafe { pacer.as_mut() } {
        Some(pacer) => body(pacer),
        None => fallback,
    }
}

fn spacing(delay: Option<u64>) -> i64 {
    delay.map_or(-1, |ns| i64::try_from(ns).unwrap_or(i64::MAX))
}

/// Notes one failure; the spacing before the next attempt in nanoseconds, or
/// -1 when the budget is spent (wait for an event only). `random`: a draw
/// in 0..<1 for the jitter.
///
/// # Safety
/// `pacer` is NULL or points to a pacer the caller does not share during the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_retry_pacer_failed(pacer: *mut CmuxRetryPacer, random: f64) -> i64 {
    with_pacer(pacer, -1, |p| spacing(p.failed(random)))
}

/// Notes a failure while the socket (`device`, `inode`) exists; as `failed`.
///
/// # Safety
/// `pacer` is NULL or points to a pacer the caller does not share during the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_retry_pacer_failed_at(
    pacer: *mut CmuxRetryPacer,
    device: u64,
    inode: u64,
    random: f64,
) -> i64 {
    with_pacer(pacer, -1, |p| spacing(p.failed_at(device, inode, random)))
}

/// Notes a failure while the socket is missing.
///
/// # Safety
/// `pacer` is NULL or points to a pacer the caller does not share during the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_retry_pacer_failed_while_missing(pacer: *mut CmuxRetryPacer) {
    with_pacer(pacer, (), CmuxRetryPacer::failed_while_missing);
}

/// The attempt was refused at the daemon's connection limit.
///
/// # Safety
/// `pacer` is NULL or points to a pacer the caller does not share during the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_retry_pacer_refused_busy(pacer: *mut CmuxRetryPacer) {
    with_pacer(pacer, (), CmuxRetryPacer::refused_busy);
}

/// After a success that stayed healthy.
///
/// # Safety
/// `pacer` is NULL or points to a pacer the caller does not share during the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_retry_pacer_reset(pacer: *mut CmuxRetryPacer) {
    with_pacer(pacer, (), CmuxRetryPacer::reset);
}

/// What woke the wait: 0 event, 1 socket, 2 timer, 3 cancelled.
///
/// # Safety
/// `pacer` is NULL or points to a pacer the caller does not share during the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_retry_pacer_woke(pacer: *mut CmuxRetryPacer, cause: u32) {
    let Some(cause) = WakeCause::from_code(cause) else { return };
    with_pacer(pacer, (), |p| p.woke(cause));
}

/// The timed-retry budget is spent.
///
/// # Safety
/// `pacer` is NULL or points to a pacer the caller does not share during the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_retry_pacer_is_exhausted(pacer: *const CmuxRetryPacer) -> bool {
    // SAFETY: a readable pacer, or NULL.
    unsafe { pacer.as_ref() }.is_some_and(CmuxRetryPacer::is_exhausted)
}

/// The next wait arms no timer.
///
/// # Safety
/// `pacer` is NULL or points to a pacer the caller does not share during the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_retry_pacer_waits_for_event_only(
    pacer: *const CmuxRetryPacer,
) -> bool {
    // SAFETY: a readable pacer, or NULL.
    unsafe { pacer.as_ref() }.is_some_and(CmuxRetryPacer::waits_for_event_only)
}

/// A socket change may wake the next wait.
///
/// # Safety
/// `pacer` is NULL or points to a pacer the caller does not share during the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_retry_pacer_wakes_on_socket(pacer: *const CmuxRetryPacer) -> bool {
    // SAFETY: a readable pacer, or NULL.
    unsafe { pacer.as_ref() }.is_some_and(CmuxRetryPacer::wakes_on_socket)
}

// ---- Heartbeat ----

/// A heartbeat that answers, at run 0.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_heartbeat_new() -> CmuxHeartbeat {
    CmuxHeartbeat::default()
}

/// Starts a run; returns its number. `*tell`: tell the observer true.
///
/// # Safety
/// `beat` (and `tell`) is NULL or points to memory the caller holds under its lock.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_heartbeat_start(beat: *mut CmuxHeartbeat, tell: *mut bool) -> u64 {
    // SAFETY: a heartbeat the caller holds under its lock.
    let Some(beat) = (unsafe { beat.as_mut() }) else { return 0 };
    let (run, told) = beat.start();
    // SAFETY: a writable bool, or NULL.
    if let Some(tell) = unsafe { tell.as_mut() } {
        *tell = told;
    }
    run
}

/// Ends the run; whether to tell the observer true.
///
/// # Safety
/// `beat` (and `tell`) is NULL or points to memory the caller holds under its lock.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_heartbeat_stop(beat: *mut CmuxHeartbeat) -> bool {
    // SAFETY: a heartbeat the caller holds under its lock.
    unsafe { beat.as_mut() }.is_some_and(CmuxHeartbeat::stop)
}

/// One ask of `run` ended. `action`: 0 the run is over, 1 close the
/// transport, 2 schedule the next ask; tell the observer `answering` when
/// `tell`.
///
/// # Safety
/// `beat` (and `tell`) is NULL or points to memory the caller holds under its lock.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_heartbeat_tick(
    beat: *mut CmuxHeartbeat,
    run: u64,
    answered: bool,
    misses: i64,
    peer_alive: bool,
) -> CmuxHeartbeatStep {
    // SAFETY: a heartbeat the caller holds under its lock.
    match unsafe { beat.as_mut() } {
        Some(beat) => beat.tick(run, answered, misses, peer_alive),
        None => {
            CmuxHeartbeatStep { action: crate::heartbeat::STEP_STALE, tell: false, answering: true }
        }
    }
}

// ---- Request latency ----

#[unsafe(no_mangle)]
pub extern "C" fn cmux_daemon_latency_new() -> *mut CmuxDaemonLatency {
    Box::into_raw(Box::new(CmuxDaemonLatency { latency: Latency::default() }))
}

/// NULL is ignored. No call may use the handle afterwards.
///
/// # Safety
/// `probe` is NULL or a handle from `cmux_daemon_latency_new`, freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_daemon_latency_free(probe: *mut CmuxDaemonLatency) {
    if !probe.is_null() {
        // SAFETY: a handle from `cmux_daemon_latency_new`, handed back once.
        drop(unsafe { Box::from_raw(probe) });
    }
}

/// Records one request (`outcome`: 0 reply, 1 error, 2 timed out). Lock-free.
///
/// # Safety
/// `probe` is NULL or a live handle; `counts` has `counts_len` writable u64s; `totals` is NULL or writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_daemon_latency_record(
    probe: *const CmuxDaemonLatency,
    nanoseconds: u64,
    outcome: u32,
) {
    // perf-hot: 1us daemon-request (every app request to the daemon)
    // SAFETY: a live handle, or NULL.
    if let Some(probe) = unsafe { probe.as_ref() } {
        probe.latency.record(nanoseconds, Outcome::from_code(outcome));
    }
}

/// The number of buckets (the overflow bucket last).
#[unsafe(no_mangle)]
pub extern "C" fn cmux_daemon_latency_bucket_count() -> usize {
    latency::BUCKET_COUNT
}

/// Reads the probe: up to `counts_len` bucket counts into `counts`, and the
/// totals into `*totals`. Returns the number of counts written.
///
/// # Safety
/// `probe` is NULL or a live handle; `counts` has `counts_len` writable u64s; `totals` is NULL or writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_daemon_latency_snapshot(
    probe: *const CmuxDaemonLatency,
    counts: *mut u64,
    counts_len: usize,
    totals: *mut CmuxDaemonLatencyTotals,
) -> usize {
    // SAFETY: a live handle, or NULL.
    let Some(probe) = (unsafe { probe.as_ref() }) else { return 0 };
    let snapshot = probe.latency.snapshot();
    // SAFETY: a writable totals struct, or NULL.
    if let Some(totals) = unsafe { totals.as_mut() } {
        *totals = CmuxDaemonLatencyTotals {
            errors: snapshot.errors,
            timeouts: snapshot.timeouts,
            max_us: snapshot.max_us,
        };
    }
    if counts.is_null() {
        return 0;
    }
    let written = counts_len.min(snapshot.counts.len());
    // SAFETY: the caller guarantees `counts_len` writable u64s at `counts`.
    let out = unsafe { std::slice::from_raw_parts_mut(counts, written) };
    for (slot, count) in out.iter_mut().zip(snapshot.counts.iter()) {
        *slot = *count;
    }
    written
}

// ---- Command scope ----

/// A scope; `key` (UTF-8, `key_len` bytes) is the idempotency key, NULL or
/// empty for none. NULL when the key is not UTF-8.
///
/// # Safety
/// `key` is NULL or has `key_len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_daemon_scope_new(
    key: *const u8,
    key_len: usize,
) -> *mut CmuxDaemonScope {
    let key = if key.is_null() || key_len == 0 {
        None
    } else {
        // SAFETY: the caller guarantees `key_len` readable bytes at `key`.
        match std::str::from_utf8(unsafe { std::slice::from_raw_parts(key, key_len) }) {
            Ok(key) => Some(key),
            Err(_) => return std::ptr::null_mut(),
        }
    };
    Box::into_raw(Box::new(CmuxDaemonScope { scope: Mutex::new(Scope::new(key)) }))
}

/// NULL is ignored. No call may use the handle afterwards.
///
/// # Safety
/// `scope` is NULL or a handle from `cmux_daemon_scope_new`, freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_daemon_scope_free(scope: *mut CmuxDaemonScope) {
    if !scope.is_null() {
        // SAFETY: a handle from `cmux_daemon_scope_new`, handed back once.
        drop(unsafe { Box::from_raw(scope) });
    }
}

/// One JSON op on a scope (codes as `cmux_daemon_conn_call`). Thread-safe.
///
/// # Safety
/// `scope` is NULL or a live handle; the other pointers as `cmux_daemon_conn_call`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_daemon_scope_call(
    scope: *const CmuxDaemonScope,
    op: *const c_char,
    request: *const u8,
    request_len: usize,
    out: *mut CmuxDaemonConnBytes,
) -> i32 {
    if out.is_null() || scope.is_null() {
        return ERR_NULL;
    }
    guarded(|| {
        // SAFETY: the caller's pointer rules.
        let (op, request) = match unsafe { (op_name(op), request_value(request, request_len)) } {
            (Ok(op), Ok(request)) => (op, request),
            (Err(code), _) | (_, Err(code)) => return code,
        };
        // SAFETY: a live handle.
        let handle = unsafe { &*scope };
        let mut scope = match handle.scope.lock() {
            Ok(scope) => scope,
            Err(poisoned) => poisoned.into_inner(),
        };
        let result = ops::scope_call(&mut scope, op, &request);
        drop(scope);
        // SAFETY: `out` checked non-null.
        unsafe { give(out, result) }
    })
}
