//! The C ABI's own memory handling: the error buffer it writes and the handles it takes. No
//! tunnel starts, so these run under Miri (`scripts/miri.sh`), which checks every write
//! stays inside the buffer the caller gave.

use std::ffi::c_char;
use std::ptr;

use super::*;

/// `cmux_wg_tun_start` on `config` with an error buffer of `len` bytes, each set to 0x7f first.
fn start_error(config: &[u8], len: usize) -> Vec<u8> {
    let mut error = vec![0x7f_u8; len];
    // SAFETY: `config` is NUL-terminated; `error` holds `len` writable bytes.
    let tun = unsafe {
        cmux_wg_tun_start(config.as_ptr().cast(), -1, error.as_mut_ptr().cast(), error.len())
    };
    assert!(tun.is_null(), "a refused config starts no tunnel");
    error
}

#[test]
fn a_refused_config_names_its_reason_inside_the_callers_buffer() {
    let error = start_error(b"not a config\0", 256);
    let end = error.iter().position(|byte| *byte == 0).expect("NUL-terminated");
    assert!(end > 0, "a reason is written");
    assert!(error[end + 1..].iter().all(|byte| *byte == 0x7f), "nothing is written past the NUL");
}

#[test]
fn a_short_buffer_holds_a_truncated_reason_and_its_nul() {
    for len in [1, 2, 5] {
        let error = start_error(b"not a config\0", len);
        assert_eq!(error.len(), len);
        assert_eq!(error[len - 1], 0, "the last byte is the NUL for len {len}");
        assert!(error[..len - 1].iter().all(|byte| *byte != 0), "the reason fills the rest");
    }
}

#[test]
fn a_null_or_empty_error_buffer_is_never_written() {
    // SAFETY: a NUL-terminated config; a null error pointer is allowed.
    let tun = unsafe { cmux_wg_tun_start(c"not a config".as_ptr(), -1, ptr::null_mut(), 64) };
    assert!(tun.is_null());
    let mut byte = 0x7f_u8;
    // SAFETY: as above; a zero length allows no write.
    let tun = unsafe {
        cmux_wg_tun_start(c"not a config".as_ptr(), -1, (&raw mut byte).cast::<c_char>(), 0)
    };
    assert!(tun.is_null());
    assert_eq!(byte, 0x7f);
}

#[test]
fn a_null_or_non_utf8_config_is_refused() {
    let error = start_error(&[0xff, 0xfe, 0], 64);
    assert!(error.starts_with(b"config is not UTF-8\0"));
    let mut error = [0x7f_u8; 64];
    // SAFETY: a null config is allowed; `error` holds 64 writable bytes.
    let tun = unsafe { cmux_wg_tun_start(ptr::null(), -1, error.as_mut_ptr().cast(), error.len()) };
    assert!(tun.is_null());
    assert!(error.starts_with(b"missing config\0"));
}

#[test]
fn null_handles_are_ignored() {
    let mut stats = CmuxWgTunStats { tx_bytes: 7, rx_bytes: 7, last_handshake_unix: 7 };
    // SAFETY: every function takes a null handle.
    unsafe {
        cmux_wg_tun_network_changed(ptr::null_mut());
        cmux_wg_tun_stats(ptr::null(), &raw mut stats);
        cmux_wg_tun_stop(ptr::null_mut());
    }
    assert_eq!((stats.tx_bytes, stats.rx_bytes, stats.last_handshake_unix), (7, 7, 7));
}
