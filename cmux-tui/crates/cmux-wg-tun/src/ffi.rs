//! The C ABI in `include/cmux_wg_tun.h`.

use std::ffi::{CStr, c_char};
use std::ptr;

use crate::{TunEngine, find_utun_fd};

/// Opaque handle: a boxed engine.
pub struct CmuxWgTun(TunEngine);

#[repr(C)]
pub struct CmuxWgTunStats {
    pub tx_bytes: u64,
    pub rx_bytes: u64,
    pub last_handshake_unix: i64,
}

#[unsafe(no_mangle)]
pub extern "C" fn cmux_wg_tun_find_utun_fd() -> i32 {
    find_utun_fd().unwrap_or(-1)
}

/// # Safety
/// `config` is a NUL-terminated string; `error` is null or valid for
/// `error_len` writable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_wg_tun_start(
    config: *const c_char,
    tun_fd: i32,
    error: *mut c_char,
    error_len: usize,
) -> *mut CmuxWgTun {
    let fail = |reason: &str| {
        if !error.is_null() && error_len > 0 {
            let bytes = reason.as_bytes();
            let count = bytes.len().min(error_len - 1);
            // SAFETY: the caller gave `error_len` writable bytes; we write
            // `count + 1 <= error_len`.
            unsafe {
                ptr::copy_nonoverlapping(bytes.as_ptr(), error.cast::<u8>(), count);
                *error.add(count) = 0;
            }
        }
        ptr::null_mut()
    };
    if config.is_null() {
        return fail("missing config");
    }
    // SAFETY: the caller passes a NUL-terminated string.
    let Ok(text) = unsafe { CStr::from_ptr(config) }.to_str() else {
        return fail("config is not UTF-8");
    };
    match TunEngine::start(text, tun_fd) {
        Ok(engine) => Box::into_raw(Box::new(CmuxWgTun(engine))),
        Err(start) => fail(&start.to_string()),
    }
}

/// # Safety
/// `tun` is null or a live handle from `cmux_wg_tun_start`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_wg_tun_network_changed(tun: *mut CmuxWgTun) {
    // SAFETY: see the function contract.
    if let Some(tun) = unsafe { tun.as_ref() } {
        tun.0.network_changed();
    }
}

/// # Safety
/// `tun` is null or a live handle; `out` is null or writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_wg_tun_stats(tun: *const CmuxWgTun, out: *mut CmuxWgTunStats) {
    // SAFETY: see the function contract.
    let (Some(tun), false) = (unsafe { tun.as_ref() }, out.is_null()) else { return };
    let stats = tun.0.stats();
    // SAFETY: `out` is non-null and writable per the contract.
    unsafe {
        *out = CmuxWgTunStats {
            tx_bytes: stats.tx_bytes,
            rx_bytes: stats.rx_bytes,
            last_handshake_unix: stats.last_handshake_unix,
        };
    }
}

/// # Safety
/// `tun` is null or a live handle, not used again after this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_wg_tun_stop(tun: *mut CmuxWgTun) {
    if tun.is_null() {
        return;
    }
    // SAFETY: the handle came from Box::into_raw in cmux_wg_tun_start.
    let tun = unsafe { Box::from_raw(tun) };
    tun.0.stop();
}
