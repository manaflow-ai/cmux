//! Every export runs its body in cmux-ffi-guard's boundary: a panic returns
//! the documented error value and is recorded under the export's name, the
//! process keeps running.

use super::*;
use cmux_ffi_guard::testing::{panic_through, quiet_boundary, unguarded_exports};

#[test]
fn every_export_is_guarded() {
    for (file, source) in [
        ("lib.rs", include_str!("lib.rs")),
        ("bulk_ffi.rs", include_str!("bulk_ffi.rs")),
        ("input_ffi.rs", include_str!("input_ffi.rs")),
        ("rb_client_ffi.rs", include_str!("rb_client_ffi.rs")),
        ("session_ffi.rs", include_str!("session_ffi.rs")),
        ("upstream_ffi.rs", include_str!("upstream_ffi.rs")),
    ] {
        assert_eq!(unguarded_exports(source), Vec::<String>::new(), "{file}");
    }
}

/// Calls `export` with its boundary armed to panic; checks the error value
/// and the recorded name.
fn panics_to<R: PartialEq + std::fmt::Debug>(name: &str, expected: R, export: impl FnOnce() -> R) {
    let (value, recorded) = panic_through(export);
    assert_eq!(value, expected, "{name}");
    assert_eq!(recorded.as_deref(), Some(name));
}

#[test]
fn a_guarded_panic_returns_the_error_value() {
    panics_to("cmux_rd_receiver_new", std::ptr::null_mut(), || {
        cmux_rd_receiver_new(CMUX_RD_CARRIER_DATAGRAM, 50_000, 10_000)
    });
    let receiver = cmux_rd_receiver_new(CMUX_RD_CARRIER_DATAGRAM, 50_000, 10_000);
    // SAFETY: a live receiver, freed below.
    panics_to("cmux_rd_receiver_tick", CMUX_RD_ERR_PANIC, || unsafe {
        cmux_rd_receiver_tick(receiver, 0)
    });
    // SAFETY: as above.
    panics_to("cmux_rd_receiver_next_deadline_us", u64::MAX, || unsafe {
        cmux_rd_receiver_next_deadline_us(receiver)
    });
    // The panic came before the handle call: the receiver still works.
    // SAFETY: as above.
    assert_eq!(unsafe { cmux_rd_receiver_tick(receiver, 0) }, 0);
    // SAFETY: freed once; the panic leaks it but the process lives on.
    panics_to("cmux_rd_receiver_free", (), || unsafe { cmux_rd_receiver_free(receiver) });
    // SAFETY: freed once (the panicked free never reached the drop).
    unsafe { cmux_rd_receiver_free(receiver) };

    let mut out = [0_u8; 16];
    let mut len = 0;
    // SAFETY: a writable buffer and length.
    panics_to("cmux_rd_encode_stream_frame", CMUX_RD_ERR_PANIC, || unsafe {
        cmux_rd_encode_stream_frame(0, std::ptr::null(), 0, out.as_mut_ptr(), out.len(), &mut len)
    });

    let session = cmux_rd_session_new(CMUX_RD_CARRIER_DATAGRAM, 50_000, 10_000);
    // SAFETY: a live session, freed below.
    panics_to("cmux_rd_session_open_stream", CMUX_RD_ERR_PANIC, || unsafe {
        cmux_rd_session_open_stream(session, 1)
    });
    // SAFETY: freed once.
    unsafe { cmux_rd_session_free(session) };

    let input = cmux_rd_input_new(CMUX_RD_CARRIER_DATAGRAM, 50_000);
    // SAFETY: a live input channel, freed below.
    panics_to("cmux_rd_input_next_deadline_us", u64::MAX, || unsafe {
        cmux_rd_input_next_deadline_us(input)
    });
    // SAFETY: freed once.
    unsafe { cmux_rd_input_free(input) };

    let upstream = cmux_rd_upstream_new(
        CMUX_RD_CARRIER_DATAGRAM,
        1,
        CMUX_RD_MEDIA_MIC,
        1_200,
        CMUX_RD_PATH_DIRECT_LAN,
        0,
        0,
        0,
        false,
    );
    assert!(!upstream.is_null());
    // SAFETY: a live sender, freed below.
    panics_to("cmux_rd_upstream_target_bps", 0, || unsafe {
        cmux_rd_upstream_target_bps(upstream, 0)
    });
    // SAFETY: freed once.
    unsafe { cmux_rd_upstream_free(upstream) };

    let sender = cmux_rd_bulk_sender_new(16_667);
    // SAFETY: a live sender, freed below.
    panics_to("cmux_rd_bulk_sender_on_credit", CMUX_RD_ERR_PANIC, || unsafe {
        cmux_rd_bulk_sender_on_credit(sender, 1, 0)
    });
    // SAFETY: freed once.
    unsafe { cmux_rd_bulk_sender_free(sender) };

    let client = cmux_rb_client_new();
    let mut outcome = std::ptr::null();
    let mut outcome_len = 0;
    // SAFETY: a live client and writable outs, freed below.
    panics_to("cmux_rb_client_apply", CMUX_RD_ERR_PANIC, || unsafe {
        cmux_rb_client_apply(client, b"{}".as_ptr(), 2, &mut outcome, &mut outcome_len)
    });
    // SAFETY: freed once.
    unsafe { cmux_rb_client_free(client) };
}

#[test]
fn a_panic_inside_a_handle_call_poisons_that_handle() {
    let session = cmux_rd_session_new(CMUX_RD_CARRIER_DATAGRAM, 50_000, 10_000);
    let other = cmux_rd_session_new(CMUX_RD_CARRIER_DATAGRAM, 50_000, 10_000);
    let rc = quiet_boundary(CMUX_RD_ERR_PANIC, || {
        // SAFETY: a live session.
        unsafe { with_handle(session, |_: &mut CmuxRdSession| panic!("boom")) }
    });
    assert_eq!(rc, CMUX_RD_ERR_PANIC);
    // SAFETY: live (one poisoned) sessions, freed below.
    unsafe {
        assert_eq!(cmux_rd_session_tick(session, 0), CMUX_RD_ERR_PANIC);
        assert_eq!(cmux_rd_session_next_deadline_us(session), u64::MAX);
        assert_eq!(cmux_rd_session_tick(other, 0), 0);
        cmux_rd_session_free(session);
        cmux_rd_session_free(other);
    }
}
