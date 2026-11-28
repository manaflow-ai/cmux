//! The C ABI of the auth coordinator for the macOS app
//! (`include/cmux_auth_coordinator.h`, Swift module `CCmuxAuthCoordinatorFFI`),
//! linked into the app through cmux-app-ffi. The reducer runs in the app's
//! process, as on iOS (which has no daemon), over the JSON wire of
//! [`crate::wire`].
//!
//! - `cmux_auth_coordinator_new` / `cmux_auth_coordinator_free`: one
//!   coordinator per app, primed from a JSON config.
//! - `cmux_auth_coordinator_feed`: one JSON event.
//! - `cmux_auth_coordinator_take_effects`: the queued effects as a JSON array.
//! - `cmux_auth_coordinator_snapshot`: what it publishes, as a JSON object.
//!
//! Every function may run on any thread; a handle is used by one thread at a
//! time (the app holds it under its own lock). None unwinds across the
//! boundary. A reply buffer belongs to the caller, who frees it with
//! `cmux_auth_coordinator_bytes_free`.

use std::panic::{AssertUnwindSafe, catch_unwind};

use crate::wire::Session;

/// Bumped on any change to a type, a function or the JSON wire.
pub const CMUX_AUTH_COORDINATOR_ABI_VERSION: u32 = 1;
pub const CMUX_AUTH_COORDINATOR_OK: i32 = 0;
/// A null pointer where one is required.
pub const CMUX_AUTH_COORDINATOR_ERR_NULL: i32 = -1;
/// Not the JSON the call takes; nothing changed.
pub const CMUX_AUTH_COORDINATOR_ERR_INVALID: i32 = -2;
/// A panic inside, caught.
pub const CMUX_AUTH_COORDINATOR_ERR_PANIC: i32 = -4;

/// A reply buffer owned by the caller (JSON, UTF-8). `ptr` is null when
/// `len` is 0.
#[repr(C)]
pub struct CmuxAuthCoordinatorBytes {
    pub ptr: *mut u8,
    pub len: usize,
}

impl CmuxAuthCoordinatorBytes {
    fn from_vec(bytes: Vec<u8>) -> Self {
        if bytes.is_empty() {
            return Self { ptr: std::ptr::null_mut(), len: 0 };
        }
        let boxed = bytes.into_boxed_slice();
        let len = boxed.len();
        Self { ptr: Box::into_raw(boxed).cast::<u8>(), len }
    }
}

/// One coordinator and its queued effects.
pub struct CmuxAuthCoordinator {
    session: Session,
}

/// The caller's bytes, or `None` for a null pointer with a nonzero length.
///
/// # Safety
///
/// `ptr` is null or readable for `len` bytes.
unsafe fn input<'a>(ptr: *const u8, len: usize) -> Option<&'a [u8]> {
    if len == 0 {
        return Some(&[]);
    }
    if ptr.is_null() {
        return None;
    }
    // SAFETY: the caller's pointer is readable for `len` bytes.
    Some(unsafe { std::slice::from_raw_parts(ptr, len) })
}

/// `CMUX_AUTH_COORDINATOR_ABI_VERSION`.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_auth_coordinator_abi_version() -> u32 {
    CMUX_AUTH_COORDINATOR_ABI_VERSION
}

/// A new coordinator, primed from `config` (JSON `{launch?, persisted?,
/// jitterSeed?}`, UTF-8; empty means `{}`). `*out` gets the handle, freed
/// with `cmux_auth_coordinator_free`; the priming effects wait for
/// `cmux_auth_coordinator_take_effects`. On an error `*out` is null.
///
/// # Safety
///
/// `config` with its length is readable; `out` is writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_auth_coordinator_new(
    config_ptr: *const u8,
    config_len: usize,
    out: *mut *mut CmuxAuthCoordinator,
) -> i32 {
    if out.is_null() {
        return CMUX_AUTH_COORDINATOR_ERR_NULL;
    }
    // SAFETY: `out` checked non-null and writable.
    unsafe { *out = std::ptr::null_mut() };
    // SAFETY: the caller's pointer and length.
    let Some(config) = (unsafe { input(config_ptr, config_len) }) else {
        return CMUX_AUTH_COORDINATOR_ERR_NULL;
    };
    let body = catch_unwind(AssertUnwindSafe(|| {
        let Ok(session) = Session::from_json(config) else {
            return CMUX_AUTH_COORDINATOR_ERR_INVALID;
        };
        let handle = Box::into_raw(Box::new(CmuxAuthCoordinator { session }));
        // SAFETY: `out` checked non-null and writable.
        unsafe { *out = handle };
        CMUX_AUTH_COORDINATOR_OK
    }));
    body.unwrap_or(CMUX_AUTH_COORDINATOR_ERR_PANIC)
}

/// Frees a coordinator. Null is ignored.
///
/// # Safety
///
/// `coordinator` is null or a live handle, not used afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_auth_coordinator_free(coordinator: *mut CmuxAuthCoordinator) {
    if !coordinator.is_null() {
        // SAFETY: from `cmux_auth_coordinator_new`, freed once.
        drop(unsafe { Box::from_raw(coordinator) });
    }
}

/// Frees a reply buffer. A null `ptr` is ignored.
///
/// # Safety
///
/// `bytes` came from this library and is freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_auth_coordinator_bytes_free(bytes: CmuxAuthCoordinatorBytes) {
    if bytes.ptr.is_null() {
        return;
    }
    // SAFETY: built by `from_vec` from a boxed slice of `len` bytes.
    drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(bytes.ptr, bytes.len)) });
}

/// Applies one event (JSON, UTF-8) and queues its effects. A refused event
/// changes nothing.
///
/// # Safety
///
/// `coordinator` is a live handle used by one thread at a time; `event` with
/// its length is readable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_auth_coordinator_feed(
    coordinator: *mut CmuxAuthCoordinator,
    event_ptr: *const u8,
    event_len: usize,
) -> i32 {
    if coordinator.is_null() {
        return CMUX_AUTH_COORDINATOR_ERR_NULL;
    }
    // SAFETY: the caller's pointer and length.
    let Some(event) = (unsafe { input(event_ptr, event_len) }) else {
        return CMUX_AUTH_COORDINATOR_ERR_NULL;
    };
    let body = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: a live handle, one thread at a time.
        let session = unsafe { &mut (*coordinator).session };
        match session.feed_json(event) {
            Ok(()) => CMUX_AUTH_COORDINATOR_OK,
            Err(_) => CMUX_AUTH_COORDINATOR_ERR_INVALID,
        }
    }));
    body.unwrap_or(CMUX_AUTH_COORDINATOR_ERR_PANIC)
}

/// `*out` gets the queued effects as a JSON array, oldest first (`[]` when
/// none); the queue is left empty.
///
/// # Safety
///
/// `coordinator` is a live handle used by one thread at a time; `out` is
/// writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_auth_coordinator_take_effects(
    coordinator: *mut CmuxAuthCoordinator,
    out: *mut CmuxAuthCoordinatorBytes,
) -> i32 {
    if coordinator.is_null() || out.is_null() {
        return CMUX_AUTH_COORDINATOR_ERR_NULL;
    }
    let body = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: a live handle, one thread at a time.
        let session = unsafe { &mut (*coordinator).session };
        let bytes = session.take_effects_json();
        // SAFETY: `out` checked non-null and writable.
        unsafe { *out = CmuxAuthCoordinatorBytes::from_vec(bytes) };
        CMUX_AUTH_COORDINATOR_OK
    }));
    body.unwrap_or(CMUX_AUTH_COORDINATOR_ERR_PANIC)
}

/// `*out` gets what the coordinator publishes now, as a JSON object.
///
/// # Safety
///
/// `coordinator` is a live handle used by one thread at a time; `out` is
/// writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_auth_coordinator_snapshot(
    coordinator: *mut CmuxAuthCoordinator,
    out: *mut CmuxAuthCoordinatorBytes,
) -> i32 {
    if coordinator.is_null() || out.is_null() {
        return CMUX_AUTH_COORDINATOR_ERR_NULL;
    }
    let body = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: a live handle, one thread at a time.
        let session = unsafe { &(*coordinator).session };
        let bytes = session.snapshot_json();
        // SAFETY: `out` checked non-null and writable.
        unsafe { *out = CmuxAuthCoordinatorBytes::from_vec(bytes) };
        CMUX_AUTH_COORDINATOR_OK
    }));
    body.unwrap_or(CMUX_AUTH_COORDINATOR_ERR_PANIC)
}
