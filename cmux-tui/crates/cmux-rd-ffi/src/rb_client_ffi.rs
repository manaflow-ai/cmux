//! C ABI of the remote browser tab client reducer (`CmuxRbClient`,
//! `cmux_remote_browser::client`). JSON in, JSON out, in the shapes of
//! `schemas/remote-tab/client.json`. Same rules as the rd handles: no I/O,
//! no threads, panics caught, a panic poisons only that client, and the
//! outcome bytes stay valid until the next call on the same client.

use crate::{CMUX_RD_ERR_FAILED};

/// The opaque client handle (`CmuxRbClient`).
#[derive(Debug, Default)]
pub struct CmuxRbClient {
    _private: (),
}

/// Creates a client; NULL only when allocation fails.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_rb_client_new() -> *mut CmuxRbClient {
    std::ptr::null_mut()
}

/// Frees a client; NULL is ignored.
///
/// # Safety
/// `client` is NULL or came from [`cmux_rb_client_new`] and is not used again.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rb_client_free(_client: *mut CmuxRbClient) {}

/// Applies one client input (JSON).
///
/// # Safety
/// `client` is valid; `json` is readable for `json_len` bytes; `outcome` and
/// `outcome_len` are writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rb_client_apply(
    _client: *mut CmuxRbClient,
    _json: *const u8,
    _json_len: usize,
    _outcome: *mut *const u8,
    _outcome_len: *mut usize,
) -> i32 {
    CMUX_RD_ERR_FAILED
}
