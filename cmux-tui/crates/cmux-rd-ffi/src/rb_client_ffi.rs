//! C ABI of the remote browser tab client reducer (`CmuxRbClient`,
//! `cmux_remote_browser::client`). JSON in, JSON out, in the shapes of
//! `schemas/remote-tab/client.json`. Same rules as the rd handles: no I/O,
//! no threads, panics caught, a panic poisons only that client, and the
//! outcome bytes stay valid until the next call on the same client. One
//! client per rb session: the viewer makes a new one for each `rb.open`.

use std::panic::{AssertUnwindSafe, catch_unwind};

use cmux_remote_browser::client::{Client, ClientInput};
use serde_json::json;

use crate::{CMUX_RD_ERR_INVALID, CMUX_RD_ERR_NULL, CMUX_RD_ERR_PANIC, CMUX_RD_OK, bytes_in};

/// The opaque client handle (`CmuxRbClient`).
#[derive(Debug, Default)]
pub struct CmuxRbClient {
    inner: Client,
    outcome: Vec<u8>,
    poisoned: bool,
}

/// Creates a client; NULL only when allocation fails.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_rb_client_new() -> *mut CmuxRbClient {
    catch_unwind(|| Box::into_raw(Box::<CmuxRbClient>::default())).unwrap_or(std::ptr::null_mut())
}

/// Frees a client; NULL is ignored.
///
/// # Safety
/// `client` is NULL or came from [`cmux_rb_client_new`] and is not used again.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rb_client_free(client: *mut CmuxRbClient) {
    if client.is_null() {
        return;
    }
    // SAFETY: guaranteed by the caller; the box is dropped exactly once.
    let owned = unsafe { Box::from_raw(client) };
    let _ = catch_unwind(AssertUnwindSafe(move || drop(owned)));
}

/// Applies one client input (JSON). On `CMUX_RD_OK`, `*outcome` points at the
/// outcome JSON (`{"effects", "note", "reject"}`) until the next call on this
/// client. `CMUX_RD_ERR_INVALID` when `json` is not a client input; the state
/// does not change.
///
/// # Safety
/// `client` is NULL or valid and not used concurrently; `json` is readable for
/// `json_len` bytes; `outcome` and `outcome_len` are NULL or writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rb_client_apply(
    client: *mut CmuxRbClient,
    json: *const u8,
    json_len: usize,
    outcome: *mut *const u8,
    outcome_len: *mut usize,
) -> i32 {
    if outcome.is_null() || outcome_len.is_null() {
        return CMUX_RD_ERR_NULL;
    }
    // SAFETY: the caller passes NULL or a live client, used by one thread.
    let Some(handle) = (unsafe { client.as_mut() }) else { return CMUX_RD_ERR_NULL };
    if handle.poisoned {
        return CMUX_RD_ERR_PANIC;
    }
    // SAFETY: readable for `json_len` bytes by contract.
    let Some(input) = (unsafe { bytes_in(json, json_len) }) else { return CMUX_RD_ERR_NULL };
    let result = catch_unwind(AssertUnwindSafe(|| {
        let Ok(input) = serde_json::from_slice::<ClientInput>(input) else {
            return CMUX_RD_ERR_INVALID;
        };
        let value = match handle.inner.apply(input) {
            Ok(out) => json!({"effects": out.effects, "note": out.note, "reject": null}),
            Err(reject) => json!({"effects": [], "note": null, "reject": reject}),
        };
        handle.outcome = value.to_string().into_bytes();
        CMUX_RD_OK
    }));
    let code = match result {
        Ok(code) => code,
        Err(_) => {
            handle.poisoned = true;
            return CMUX_RD_ERR_PANIC;
        }
    };
    if code == CMUX_RD_OK {
        // SAFETY: both checked non-NULL; writable by contract.
        unsafe {
            *outcome = handle.outcome.as_ptr();
            *outcome_len = handle.outcome.len();
        }
    }
    code
}
