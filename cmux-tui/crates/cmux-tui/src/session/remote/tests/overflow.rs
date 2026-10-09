//! Surface overflow recovery and its bounds.

use super::*;

#[cfg(unix)]
#[test]
fn surface_exit_event_retires_the_mirror_before_tree_refresh() {
    let (client, _server) = UnixStream::pair().unwrap();
    let session = socket_test_session(client);
    let events = session.subscribe();
    session.surfaces.lock().unwrap().insert(7, test_remote_surface(7));

    session.handle_line(json!({"event": "surface-exited", "surface": 7}));

    assert!(!session.has_surface(7));
    assert!(session.surface_is_exited(7));
    assert!(session.tree_is_stale());
    assert!(matches!(events.recv_timeout(Duration::from_secs(1)), Ok(MuxEvent::SurfaceExited(7))));
}

#[cfg(unix)]
#[test]
fn surface_overflow_invalidates_mirror_and_requests_reattach() {
    let (client, _server) = UnixStream::pair().unwrap();
    let session = socket_test_session(client);
    let events = session.subscribe();
    session.surfaces.lock().unwrap().insert(7, test_remote_surface(7));

    session.handle_line(json!({
        "event": "overflow",
        "scope": "surface",
        "surface": 7,
        "error": "surface stream fell behind",
    }));

    assert!(!session.has_surface(7));
    assert!(!session.retired_surfaces.lock().unwrap().contains(&7));
    let received = events.try_iter().collect::<Vec<_>>();
    assert!(received.iter().any(|event| matches!(event, MuxEvent::SurfaceOutput(7))));
    assert!(received.iter().any(|event| matches!(event, MuxEvent::Status(_))));
}

#[test]
fn overflow_backoff_defers_attach_without_claiming_surface_retirement() {
    let closed = Arc::new(AtomicBool::new(false));
    let session = test_session(Box::new(CloseTrackingWriter { closed }));
    session.surface_overflow_recovery.lock().unwrap().insert(
        7,
        SurfaceOverflowRecovery {
            attempts: 1,
            retry_after: Some(Instant::now() + Duration::from_secs(1)),
            attached_at: None,
            stopped: false,
        },
    );

    let outcome =
        session.try_ensure_surface_with_kind(7, SurfaceKind::Pty, Some((80, 24))).unwrap();

    assert!(matches!(outcome, RemoteSurfaceAttach::Deferred));
    assert!(!session.retired_surfaces.lock().unwrap().contains(&7));
    assert!(!session.has_surface(7));
    assert!(session.pending.lock().unwrap().is_empty());
}

#[cfg(unix)]
#[test]
fn duplicate_surface_overflow_does_not_advance_recovery() {
    let (client, _server) = UnixStream::pair().unwrap();
    let session = socket_test_session(client);
    let events = session.subscribe();
    session.surfaces.lock().unwrap().insert(7, test_remote_surface(7));
    let overflow = json!({
        "event": "overflow",
        "scope": "surface",
        "surface": 7,
        "error": "surface stream fell behind",
    });

    session.handle_line(overflow.clone());
    let _ = events.try_iter().collect::<Vec<_>>();
    session.handle_line(overflow);

    assert_eq!(session.surface_overflow_recovery.lock().unwrap().get(&7).unwrap().attempts, 1);
    assert!(events.try_iter().next().is_none());
}

#[cfg(unix)]
#[test]
fn fabricated_surface_overflow_does_not_allocate_recovery_state() {
    let (client, _server) = UnixStream::pair().unwrap();
    let session = socket_test_session(client);
    let events = session.subscribe();

    session.handle_line(json!({
        "event": "overflow",
        "scope": "surface",
        "surface": 9_999,
        "error": "fabricated",
    }));

    assert!(session.surface_overflow_recovery.lock().unwrap().is_empty());
    assert!(events.try_iter().next().is_none());
}

#[cfg(unix)]
#[test]
fn zero_surface_overflow_is_ignored_even_if_zero_is_attached() {
    let (client, _server) = UnixStream::pair().unwrap();
    let session = socket_test_session(client);
    let events = session.subscribe();
    session.surfaces.lock().unwrap().insert(0, test_remote_surface(0));

    session.handle_line(json!({
        "event": "overflow",
        "scope": "surface",
        "surface": 0,
        "error": "invalid zero surface",
    }));

    assert!(session.has_surface(0));
    assert!(session.surface_overflow_recovery.lock().unwrap().is_empty());
    assert!(events.try_iter().next().is_none());
}

#[cfg(unix)]
#[test]
fn surface_overflow_capacity_requires_one_bounded_reconnect() {
    let (client, _server) = UnixStream::pair().unwrap();
    let session = socket_test_session(client);
    let events = session.subscribe();
    let maximum = u64::try_from(MAX_SURFACE_OVERFLOW_RECOVERIES).unwrap();
    {
        let mut recoveries = session.surface_overflow_recovery.lock().unwrap();
        for id in 1..=maximum {
            recoveries.insert(
                id,
                SurfaceOverflowRecovery {
                    attempts: 1,
                    retry_after: Some(Instant::now() + Duration::from_secs(1)),
                    attached_at: None,
                    stopped: false,
                },
            );
        }
    }
    let overflow_surface = maximum + 1;
    session
        .surfaces
        .lock()
        .unwrap()
        .insert(overflow_surface, test_remote_surface(overflow_surface));

    session.handle_line(json!({
        "event": "overflow",
        "scope": "surface",
        "surface": overflow_surface,
        "error": "recovery capacity",
    }));

    assert_eq!(
        session.surface_overflow_recovery.lock().unwrap().len(),
        MAX_SURFACE_OVERFLOW_RECOVERIES
    );
    assert!(session.surface_overflow_reconnect_required.load(Ordering::Acquire));
    assert!(!session.can_attach_after_overflow(1));
    assert!(!session.surface_overflow_retry_due());
    let first = events.try_iter().collect::<Vec<_>>();
    assert_eq!(first.iter().filter(|event| matches!(event, MuxEvent::Status(_))).count(), 1);

    let next_surface = overflow_surface + 1;
    session.surfaces.lock().unwrap().insert(next_surface, test_remote_surface(next_surface));
    session.handle_line(json!({
        "event": "overflow",
        "scope": "surface",
        "surface": next_surface,
        "error": "already reconnecting",
    }));
    assert!(
        events.try_iter().all(|event| !matches!(event, MuxEvent::Status(_))),
        "reconnect-required status repeated"
    );
}

#[cfg(unix)]
#[test]
fn stable_surface_recoveries_are_pruned_before_capacity() {
    let (client, _server) = UnixStream::pair().unwrap();
    let session = socket_test_session(client);
    let maximum = u64::try_from(MAX_SURFACE_OVERFLOW_RECOVERIES).unwrap();
    {
        let mut recoveries = session.surface_overflow_recovery.lock().unwrap();
        for id in 1..=maximum {
            recoveries.insert(
                id,
                SurfaceOverflowRecovery {
                    attempts: 3,
                    retry_after: None,
                    attached_at: Some(Instant::now() - SURFACE_OVERFLOW_STABLE),
                    stopped: false,
                },
            );
        }
    }
    let overflow_surface = maximum + 1;
    session
        .surfaces
        .lock()
        .unwrap()
        .insert(overflow_surface, test_remote_surface(overflow_surface));

    session.handle_line(json!({
        "event": "overflow",
        "scope": "surface",
        "surface": overflow_surface,
        "error": "after stable recovery",
    }));

    assert_eq!(session.surface_overflow_recovery.lock().unwrap().len(), 1);
    assert!(!session.surface_overflow_reconnect_required.load(Ordering::Acquire));
}
