//! Daemon shutdown as the remote session sees it: the shutdown notice, the
//! EOF that follows it, and requests the daemon refused while its shutdown
//! handoff was pending (the session_shutdown flake).

use super::tests::{CloseTrackingWriter, SilentWriter, test_session};
use super::*;

#[test]
fn daemon_shutdown_event_marks_the_following_eof_as_expected() {
    let session =
        test_session(Box::new(CloseTrackingWriter { closed: Arc::new(AtomicBool::new(false)) }));

    session.handle_line(json!({
        "event": cmux_tui_core::server::DAEMON_SHUTDOWN_EVENT,
    }));
    session.disconnect_transport_with_reason(Some("the daemon closed the connection".into()));

    assert!(session.daemon_shutdown_requested());
    assert_eq!(session.transport_disconnect_reason(), None);
    assert!(matches!(
        session
            .request(json!({"cmd": "identify"}))
            .unwrap_err()
            .downcast_ref::<RemoteRequestError>(),
        Some(RemoteRequestError::DaemonShutdown)
    ));
}

/// The daemon refuses requests while its shutdown handoff is reserved,
/// and announces the shutdown to other clients only after the requester
/// acknowledged it. A request refused in that window must end as
/// DaemonShutdown once the announcement follows, not as an error that
/// makes the client exit with status 1 (the session_shutdown flake).
#[test]
fn a_request_refused_during_a_pending_shutdown_ends_as_daemon_shutdown() {
    let session = test_session(Box::new(SilentWriter));
    let request_session = session.clone();
    let worker = std::thread::spawn(move || {
        request_session.request_with_deadline(
            json!({"cmd": "identify"}),
            RequestDeadline::Fixed(Duration::from_secs(5)),
        )
    });
    let deadline = Instant::now() + Duration::from_secs(1);
    let id = loop {
        if let Some(id) = session.pending.lock().unwrap().requests.keys().next().copied() {
            break id;
        }
        assert!(Instant::now() < deadline, "request did not become pending");
        std::thread::yield_now();
    };
    session.handle_line(json!({
        "id": id,
        "ok": false,
        "error": "daemon shutdown is in progress; request was not executed",
        "error_code": cmux_tui_core::server::DAEMON_SHUTDOWN_PENDING_CODE,
    }));
    std::thread::sleep(Duration::from_millis(50));
    session.handle_line(json!({
        "event": cmux_tui_core::server::DAEMON_SHUTDOWN_EVENT,
    }));

    let error = worker
        .join()
        .expect("request worker panicked")
        .expect_err("a refused request unexpectedly succeeded");
    assert!(
        matches!(
            error.downcast_ref::<RemoteRequestError>(),
            Some(RemoteRequestError::DaemonShutdown)
        ),
        "{error:#}"
    );
}

/// A shutdown the daemon cancels (the requester's acknowledgement failed)
/// sends no announcement: the refusal then stays a plain rejection.
#[test]
fn a_request_refused_during_a_cancelled_shutdown_stays_rejected() {
    let session = test_session(Box::new(SilentWriter));
    let request_session = session.clone();
    let worker = std::thread::spawn(move || {
        request_session.request_with_deadline(
            json!({"cmd": "identify"}),
            RequestDeadline::Fixed(Duration::from_secs(30)),
        )
    });
    let deadline = Instant::now() + Duration::from_secs(1);
    let id = loop {
        if let Some(id) = session.pending.lock().unwrap().requests.keys().next().copied() {
            break id;
        }
        assert!(Instant::now() < deadline, "request did not become pending");
        std::thread::yield_now();
    };
    session.handle_line(json!({
        "id": id,
        "ok": false,
        "error": "daemon shutdown is in progress; request was not executed",
        "error_code": cmux_tui_core::server::DAEMON_SHUTDOWN_PENDING_CODE,
    }));

    let error = worker
        .join()
        .expect("request worker panicked")
        .expect_err("a refused request unexpectedly succeeded");
    assert_eq!(
        error.downcast_ref::<RemoteRequestError>().and_then(RemoteRequestError::rejection_code),
        Some(cmux_tui_core::server::DAEMON_SHUTDOWN_PENDING_CODE),
        "{error:#}"
    );
}

#[test]
fn daemon_shutdown_event_cancels_an_inflight_request_as_expected() {
    let session = test_session(Box::new(SilentWriter));
    let request_session = session.clone();
    let worker = std::thread::spawn(move || {
        request_session.request_with_deadline(
            json!({"cmd": "identify"}),
            RequestDeadline::Fixed(Duration::from_secs(2)),
        )
    });

    let deadline = Instant::now() + Duration::from_secs(1);
    while session.pending.lock().unwrap().is_empty() {
        assert!(Instant::now() < deadline, "request did not become pending");
        std::thread::yield_now();
    }
    session.handle_line(json!({
        "event": cmux_tui_core::server::DAEMON_SHUTDOWN_EVENT,
    }));

    let error = worker
        .join()
        .expect("request worker panicked")
        .expect_err("in-flight request unexpectedly succeeded");
    assert!(matches!(
        error.downcast_ref::<RemoteRequestError>(),
        Some(RemoteRequestError::DaemonShutdown)
    ));
    assert!(session.shutdown.load(Ordering::Acquire));
    assert!(session.pending.lock().unwrap().is_empty());
}
