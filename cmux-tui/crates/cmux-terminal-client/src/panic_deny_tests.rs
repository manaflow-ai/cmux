//! Peer frames no longer panic; a poisoned one-value slot
//! keeps serving and a poisoned shared-state lock escalates to Fatal.

use std::sync::{Arc, Mutex};

use cmux_remote::identity::{KnownDaemon, KnownDaemonAuth};
use cmux_tui_core::terminal_host_protocol::{Frame, MessageKind};

use super::panic_free::{LockShared as _, RecoverPoison as _, ResizeAckPayload, ResizedPayload};
use super::{ClientState, ResizeDelivery, ResizeRequest, select_enrolled_daemon};

fn client_state() -> ClientState {
    let terminal_id = super::unattached_terminal_id().expect("placeholder id parses");
    ClientState::new("test".into(), "direct".into(), 1, terminal_id).expect("client state")
}

#[test]
fn resized_payload_decodes_both_forms_and_refuses_other_lengths() {
    assert_eq!(
        ResizedPayload::decode(&[80, 0, 24, 0]),
        Some(ResizedPayload { cols: 80, rows: 24, cell_pixels: None })
    );
    assert_eq!(
        ResizedPayload::decode(&[0, 0, 0, 1, 7, 0, 0, 0]),
        Some(ResizedPayload { cols: 1, rows: 256, cell_pixels: Some((7, 1)) })
    );
    for length in [0, 1, 3, 5, 7, 9] {
        assert_eq!(ResizedPayload::decode(&vec![1; length]), None, "length {length}");
    }
}

#[test]
fn resize_ack_payload_needs_exactly_eight_bytes() {
    assert_eq!(
        ResizeAckPayload::decode(&[120, 0, 40, 0, 1, 0, 0, 0]),
        Some(ResizeAckPayload { cols: 120, rows: 40, flags: 1 })
    );
    assert_eq!(ResizeAckPayload::decode(&[120, 0, 40, 0]), None);
    assert_eq!(ResizeAckPayload::decode(&[0; 9]), None);
}

#[test]
fn a_short_resized_frame_is_a_stream_error() {
    let mut state = client_state();
    let error = state
        .apply(Frame::new(MessageKind::Resized, vec![80, 0, 24]))
        .expect_err("a 3-byte Resized payload is refused");
    assert!(error.contains("4 or 8 bytes"), "{error}");
}

#[test]
fn a_short_resize_ack_frame_is_a_stream_error() {
    let mut state = client_state();
    let mut frame = Frame::new(MessageKind::ResizeAck, vec![80, 0, 24, 0]);
    frame.request_id = 7;
    let error = state.apply(frame).expect_err("a 4-byte ResizeAck payload is refused");
    assert!(error.contains("8 bytes"), "{error}");
}

fn daemon(name: &str, hints: &[&str]) -> KnownDaemon {
    KnownDaemon {
        fingerprint: format!("fp-{name}"),
        name: name.into(),
        public_key: String::new(),
        route_hints: hints.iter().map(|hint| (*hint).to_string()).collect(),
        auth: KnownDaemonAuth::Enrolled,
        first_seen_at_unix: 0,
        last_used_at_unix: 0,
    }
}

#[test]
fn a_bare_route_picks_the_only_enrolled_daemon_or_refuses() {
    let route = "wss://example.invalid/terminal";
    let only = select_enrolled_daemon(vec![daemon("only", &[])], route).expect("the only daemon");
    assert_eq!(only.name, "only");

    let none = select_enrolled_daemon(Vec::new(), route).expect_err("no daemons");
    assert!(none.contains("no enrolled daemon"), "{none}");

    let two = select_enrolled_daemon(vec![daemon("a", &[]), daemon("b", &[])], route)
        .expect_err("two unmatched daemons");
    assert!(two.contains("no enrolled daemon"), "{two}");
}

#[test]
fn a_poisoned_resize_delivery_keeps_serving() {
    let delivery = Arc::new(ResizeDelivery::default());
    let poisoner = Arc::clone(&delivery);
    let joined = std::thread::spawn(move || {
        let _guard = poisoner.desired.lock().recover_poison();
        std::panic::panic_any("poison the desired-resize lock");
    })
    .join();
    assert!(joined.is_err());
    assert!(delivery.desired.is_poisoned());

    let request = ResizeRequest { request_id: 3, cols: 100, rows: 30 };
    delivery.request(request);
    assert_eq!(delivery.desired(), Some(request));
    delivery.complete_if_current(3);
    assert_eq!(delivery.desired(), None);
}

#[test]
fn recover_poison_yields_the_data_left_behind() {
    let lock = Arc::new(Mutex::new(vec![1_u8]));
    let poisoner = Arc::clone(&lock);
    let joined = std::thread::spawn(move || {
        poisoner.lock().recover_poison().push(2);
        let _guard = poisoner.lock().recover_poison();
        std::panic::panic_any("poison the lock");
    })
    .join();
    assert!(joined.is_err());
    assert_eq!(*lock.lock().recover_poison(), vec![1, 2]);
}

#[test]
fn a_panic_during_frame_apply_escalates_to_fatal() {
    let state = Arc::new(Mutex::new(client_state()));
    let stream_task = Arc::clone(&state);
    let joined = std::thread::spawn(move || {
        // The stream task's hold: the frame is applied under the lock and
        // the panic comes before the frame is whole.
        let mut guard = stream_task.lock_shared();
        guard.status = "live".into();
        let _ = guard.apply(Frame::new(MessageKind::Resized, vec![80, 0, 24, 0]));
        std::panic::panic_any("panic part way through a frame");
    })
    .join();
    assert!(joined.is_err());
    assert!(state.is_poisoned());

    // Every FFI entry point locks through lock_shared; its panic cannot
    // unwind out of `extern "C"`, so the process ends instead of serving
    // the half-applied state with status "live".
    let next_locker = std::panic::catch_unwind(|| state.lock_shared().exited);
    let payload = next_locker.expect_err("a poisoned shared lock is Fatal");
    let message = payload
        .downcast_ref::<String>()
        .map(String::as_str)
        .or_else(|| payload.downcast_ref::<&str>().copied())
        .unwrap_or_default();
    assert!(message.contains("INVARIANT"), "{message}");
}
