//! Surface attach deadlines, ordering, and retirement.

use super::*;

#[cfg(unix)]
#[test]
fn browser_attach_deadline_advances_while_a_large_initial_frame_is_arriving() {
    let (client, server) = UnixStream::pair().unwrap();
    let (release_tx, release_rx) = channel();
    let peer = std::thread::spawn(move || {
        let mut peer = BufReader::new(server);
        for expected_command in ["identify", "set-client-info", "subscribe"] {
            let mut line = String::new();
            peer.read_line(&mut line).unwrap();
            let request: Value = serde_json::from_str(&line).unwrap();
            assert_eq!(request["cmd"], expected_command);
            let data = if expected_command == "identify" {
                json!({"app": "cmux-tui", "protocol": SUPPORTED_PROTOCOL_VERSION})
            } else {
                Value::Null
            };
            writeln!(peer.get_mut(), "{}", json!({"id": request["id"], "ok": true, "data": data}))
                .unwrap();
        }

        let mut line = String::new();
        peer.read_line(&mut line).unwrap();
        let request: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(request["cmd"], "attach-surface");
        let frame = concat!(
            "{\"event\":\"browser-state\",\"surface\":7,",
            "\"cols\":80,\"rows\":24,\"status\":\"live\",",
            "\"frame\":{\"seq\":1,\"width\":800,\"height\":600,\"data\":\"\"}}"
        );
        let first = frame.find(",\"cols\"").unwrap() + 1;
        let second = first + (frame.len() - first) / 2;
        for (index, fragment) in [
            &frame.as_bytes()[..first],
            &frame.as_bytes()[first..second],
            &frame.as_bytes()[second..],
        ]
        .into_iter()
        .enumerate()
        {
            peer.get_mut().write_all(fragment).unwrap();
            peer.get_mut().flush().unwrap();
            if index < 2 {
                std::thread::sleep(Duration::from_millis(150));
            }
        }
        peer.get_mut().write_all(b"\n").unwrap();
        writeln!(peer.get_mut(), "{}", json!({"id": request["id"], "ok": true, "data": null}))
            .unwrap();
        release_rx.recv().unwrap();
    });
    let session = RemoteSession::connect_stream(Box::new(client)).unwrap();

    let started = Instant::now();
    let surface = attached_surface(
        session.try_ensure_surface_with_kind(7, SurfaceKind::Browser, None).unwrap(),
    );

    assert_eq!(surface.id, 7);
    assert_eq!(surface.kind, SurfaceKind::Browser);
    assert!(
        started.elapsed() > REMOTE_ATTACH_IDLE_TIMEOUT,
        "attach completed before exercising the progress-aware deadline"
    );
    assert!(!session.shutdown.load(Ordering::Acquire));
    release_tx.send(()).unwrap();
    peer.join().unwrap();
}

#[test]
fn attach_deadline_expires_without_progress() {
    let started = Instant::now();
    let idle = Duration::from_millis(10);
    let mut deadline = AttachResponseDeadline::new(started, 0, 3, idle, Duration::from_millis(100));

    assert_eq!(deadline.next_wait(started, 0, 3), Some(idle));
    assert_eq!(
        deadline.next_wait(started + Duration::from_millis(9), 0, 3),
        Some(Duration::from_millis(1))
    );
    assert_eq!(deadline.next_wait(started + idle, 0, 3), None);
}

#[test]
fn attach_deadline_extends_from_own_request_progress() {
    let started = Instant::now();
    let idle = Duration::from_millis(10);
    let mut deadline = AttachResponseDeadline::new(started, 0, 3, idle, Duration::from_millis(100));

    assert_eq!(deadline.next_wait(started + Duration::from_millis(8), 1, 3), Some(idle));
    assert_eq!(
        deadline.next_wait(started + Duration::from_millis(10), 1, 3),
        Some(Duration::from_millis(8))
    );
    assert_eq!(deadline.next_wait(started + Duration::from_millis(18), 1, 3), None);
}

#[test]
fn queued_attach_deadline_extends_from_connection_progress_until_own_progress() {
    let started = Instant::now();
    let idle = Duration::from_millis(10);
    let mut deadline = AttachResponseDeadline::new(started, 0, 3, idle, Duration::from_millis(100));

    assert_eq!(deadline.next_wait(started + idle, 0, 4), Some(idle));
    assert_eq!(deadline.next_wait(started + Duration::from_millis(20), 1, 5), Some(idle));
    assert_eq!(deadline.next_wait(started + Duration::from_millis(30), 1, 6), None);
}

#[test]
fn attach_deadline_hard_maximum_wins_over_progress() {
    let started = Instant::now();
    let idle = Duration::from_millis(10);
    let maximum = Duration::from_millis(25);
    let mut deadline = AttachResponseDeadline::new(started, 0, 3, idle, maximum);

    assert_eq!(deadline.next_wait(started + Duration::from_millis(9), 1, 3), Some(idle));
    assert_eq!(
        deadline.next_wait(started + Duration::from_millis(18), 2, 3),
        Some(Duration::from_millis(7))
    );
    assert_eq!(deadline.next_wait(started + maximum, 3, 3), None);
}

#[test]
fn attach_progress_reverse_index_tracks_only_live_matching_requests() {
    let mut pending = PendingRemoteRequests::default();
    let unrelated_progress = Arc::new(AtomicU64::new(0));
    for id in 0..1_000 {
        pending.insert(
            id,
            PendingRemoteRequest {
                response: channel().0,
                progress: unrelated_progress.clone(),
                attach_surface: Some(8),
            },
        );
    }
    let matching_progress = Arc::new(AtomicU64::new(0));
    pending.insert(
        1_000,
        PendingRemoteRequest {
            response: channel().0,
            progress: matching_progress.clone(),
            attach_surface: Some(7),
        },
    );

    assert!(pending.progress_for_attach_surface(7));
    assert_eq!(matching_progress.load(Ordering::Acquire), 1);
    assert_eq!(unrelated_progress.load(Ordering::Acquire), 0);

    let removed = pending.remove(&1_000).expect("matching request is pending");
    drop(removed);
    assert!(!pending.progress_for_attach_surface(7));
    assert_eq!(matching_progress.load(Ordering::Acquire), 1);
}

#[cfg(unix)]
#[test]
fn queued_attach_preserves_two_request_wire_order() {
    let (client, server) = UnixStream::pair().unwrap();
    let (first_seen_tx, first_seen_rx) = channel();
    let (both_pending_tx, both_pending_rx) = channel();
    let (release_responses_tx, release_responses_rx) = channel();
    let (release_peer_tx, release_peer_rx) = channel();
    let peer = std::thread::spawn(move || {
        let mut peer = BufReader::new(server);
        for expected_command in ["identify", "set-client-info", "subscribe"] {
            let mut line = String::new();
            peer.read_line(&mut line).unwrap();
            let request: Value = serde_json::from_str(&line).unwrap();
            assert_eq!(request["cmd"], expected_command);
            let data = if expected_command == "identify" {
                json!({"app": "cmux-tui", "protocol": SUPPORTED_PROTOCOL_VERSION})
            } else {
                Value::Null
            };
            writeln!(peer.get_mut(), "{}", json!({"id": request["id"], "ok": true, "data": data}))
                .unwrap();
        }

        let mut first_line = String::new();
        peer.read_line(&mut first_line).unwrap();
        let first: Value = serde_json::from_str(&first_line).unwrap();
        assert_eq!(first["cmd"], "attach-surface");
        assert_eq!(first["surface"], 7);
        first_seen_tx.send(()).unwrap();

        let mut second_line = String::new();
        peer.read_line(&mut second_line).unwrap();
        let second: Value = serde_json::from_str(&second_line).unwrap();
        assert_eq!(second["cmd"], "attach-surface");
        assert_eq!(second["surface"], 8);
        both_pending_tx.send(()).unwrap();
        release_responses_rx.recv().unwrap();

        writeln!(
            peer.get_mut(),
            "{}",
            json!({
                "event": "vt-state",
                "surface": 7,
                "cols": 80,
                "rows": 24,
                "data": "",
            })
        )
        .unwrap();
        writeln!(peer.get_mut(), "{}", json!({"id": first["id"], "ok": true, "data": null}))
            .unwrap();

        writeln!(
            peer.get_mut(),
            "{}",
            json!({
                "event": "vt-state",
                "surface": 8,
                "cols": 80,
                "rows": 24,
                "data": "",
            })
        )
        .unwrap();
        writeln!(peer.get_mut(), "{}", json!({"id": second["id"], "ok": true, "data": null}))
            .unwrap();
        release_peer_rx.recv().unwrap();
    });
    let session = RemoteSession::connect_stream(Box::new(client)).unwrap();

    let first_session = session.clone();
    let first = std::thread::spawn(move || {
        first_session.try_ensure_surface_with_kind(7, SurfaceKind::Pty, None)
    });
    first_seen_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    let second_session = session.clone();
    let second = std::thread::spawn(move || {
        second_session.try_ensure_surface_with_kind(8, SurfaceKind::Pty, None)
    });

    both_pending_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    let attach_progress = session.attach_progress.load(Ordering::Acquire);
    session.report_read_progress(br#"{"event":"vt-state","surface":7,"cols":80,"data":"partial"#);
    assert_eq!(session.attach_progress.load(Ordering::Acquire), attach_progress + 1);
    {
        let pending = session.pending.lock().unwrap();
        assert_eq!(pending.len(), 2);
        let progress_for = |surface| {
            pending
                .values()
                .find(|request| request.attach_surface == Some(surface))
                .unwrap()
                .progress
                .load(Ordering::Acquire)
        };
        assert_eq!(progress_for(7), 1);
        assert_eq!(progress_for(8), 0);
    }
    release_responses_tx.send(()).unwrap();
    assert!(matches!(first.join().unwrap().unwrap(), RemoteSurfaceAttach::Attached(_)));
    assert!(matches!(second.join().unwrap().unwrap(), RemoteSurfaceAttach::Attached(_)));
    assert!(!session.shutdown.load(Ordering::Acquire));
    release_peer_tx.send(()).unwrap();
    peer.join().unwrap();
}

#[test]
fn inflight_attach_does_not_hold_the_cell_pixel_lifecycle() {
    let (session, attach_started_rx, release_attach_tx) = test_session_with_deferred_attach();
    let attaching = session.clone();
    let worker = std::thread::spawn(move || {
        attaching.try_ensure_surface_with_kind(7, SurfaceKind::Pty, Some((80, 24)))
    });
    attach_started_rx.recv_timeout(Duration::from_secs(1)).unwrap();

    let update = session.set_cell_pixel_size(9, 18).unwrap();

    assert!(update.failures.is_empty());
    assert_eq!(*session.cell_pixels.lock().unwrap(), (9, 18));
    assert_eq!(session.surface(7).unwrap().cell_pixel_size(), (9, 18));
    release_attach_tx.send(()).unwrap();
    assert!(matches!(worker.join().unwrap().unwrap(), RemoteSurfaceAttach::Attached(_)));
}

#[test]
fn retired_surface_is_not_resurrected_by_an_inflight_attach() {
    let (session, attach_started_rx, release_attach_tx) = test_session_with_deferred_attach();
    let attaching = session.clone();
    let worker = std::thread::spawn(move || {
        attaching.try_ensure_surface_with_kind(7, SurfaceKind::Pty, Some((80, 24)))
    });
    attach_started_rx.recv_timeout(Duration::from_secs(1)).unwrap();

    session.retire_surface(7);
    release_attach_tx.send(()).unwrap();

    assert!(matches!(worker.join().unwrap().unwrap(), RemoteSurfaceAttach::Retired));
    assert!(session.surface(7).is_none());
    assert!(session.retired_surfaces.lock().unwrap().contains(&7));
}

#[test]
fn retired_surface_releases_an_inflight_attach_lease() {
    let (session, attach_started_rx, release_attach_tx, requests) =
        test_session_with_deferred_leased_attach();
    let attaching = session.clone();
    let worker = std::thread::spawn(move || {
        attaching.try_ensure_surface_with_kind(7, SurfaceKind::Pty, Some((80, 24)))
    });
    attach_started_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    let attach = requests.recv_timeout(Duration::from_secs(1)).unwrap();
    assert_eq!(attach["cmd"], "attach-surface");

    session.retire_surface(7);
    release_attach_tx.send(()).unwrap();

    assert!(matches!(worker.join().unwrap().unwrap(), RemoteSurfaceAttach::Retired));
    let release = requests
        .recv_timeout(Duration::from_secs(1))
        .expect("retired in-flight attach must release its server lease");
    assert_eq!(release["cmd"], "detach-attached-view");
    assert_eq!(release["surface"], 7);
    assert_eq!(release["lease"], "test-view-lease");
}

#[test]
fn surface_exit_during_attach_retires_the_exact_mirror_before_return() {
    let (session, attach_started_rx, release_attach_tx) = test_session_with_deferred_attach();
    let attaching = session.clone();
    let worker = std::thread::spawn(move || {
        attaching.try_ensure_surface_with_kind(7, SurfaceKind::Pty, Some((80, 24)))
    });
    attach_started_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    let mirror = session.surface(7).expect("attach did not stage its local mirror");

    session.drop_surface(7);
    release_attach_tx.send(()).unwrap();

    assert!(matches!(worker.join().unwrap().unwrap(), RemoteSurfaceAttach::Retired));
    assert!(!session.has_surface(7));
    assert!(session.surface_is_exited(7));
    assert!(crate::session::SurfaceHandle::Remote(mirror, session).is_dead());
}

#[test]
fn exited_marker_outlives_every_cached_remote_surface_handle() {
    let session = super::super::test_session_with_provider_context(None, HashSet::new());
    let surface = test_remote_surface(7);
    session.surfaces.lock().unwrap().insert(7, surface.clone());
    let handle = crate::session::SurfaceHandle::Remote(surface.clone(), session.clone());

    session.drop_surface(7);
    session.prune_exited_surfaces(&HashSet::new());

    assert!(handle.is_dead());
    drop(handle);
    drop(surface);
    session.prune_exited_surfaces(&HashSet::new());
    assert!(!session.surface_is_exited(7));
}

#[cfg(unix)]
#[test]
fn unrelated_remote_traffic_does_not_extend_attach_idle_deadline() {
    let (client, server) = UnixStream::pair().unwrap();
    let peer = std::thread::spawn(move || {
        let mut peer = BufReader::new(server);
        for expected_command in ["identify", "set-client-info", "subscribe"] {
            let mut line = String::new();
            peer.read_line(&mut line).unwrap();
            let request: Value = serde_json::from_str(&line).unwrap();
            assert_eq!(request["cmd"], expected_command);
            let data = if expected_command == "identify" {
                json!({"app": "cmux-tui", "protocol": SUPPORTED_PROTOCOL_VERSION})
            } else {
                Value::Null
            };
            writeln!(peer.get_mut(), "{}", json!({"id": request["id"], "ok": true, "data": data}))
                .unwrap();
        }

        let mut line = String::new();
        peer.read_line(&mut line).unwrap();
        let request: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(request["cmd"], "attach-surface");
        let traffic_deadline = Instant::now() + REMOTE_ATTACH_IDLE_TIMEOUT * 8;
        while Instant::now() < traffic_deadline {
            if writeln!(peer.get_mut(), "{}", json!({"event": "tree-changed"})).is_err() {
                break;
            }
            std::thread::sleep(REMOTE_ATTACH_IDLE_TIMEOUT / 4);
        }
    });
    let session = RemoteSession::connect_stream(Box::new(client)).unwrap();

    let started = Instant::now();
    let error = session
        .try_ensure_surface_with_kind(7, SurfaceKind::Pty, None)
        .err()
        .expect("missing attach response must time out");

    assert!(matches!(
        error.downcast_ref::<RemoteRequestError>(),
        Some(RemoteRequestError::Timeout)
    ));
    assert!(
        started.elapsed() < REMOTE_ATTACH_IDLE_TIMEOUT * 3,
        "unrelated traffic extended the attach idle deadline to {:?}",
        started.elapsed()
    );
    peer.join().unwrap();
}

#[test]
fn timed_out_attach_closes_transport_and_removes_local_mirror() {
    let closed = Arc::new(AtomicBool::new(false));
    let session = test_session(Box::new(CloseTrackingWriter { closed: closed.clone() }));

    let error = session
        .try_ensure_surface_with_kind(7, SurfaceKind::Pty, None)
        .err()
        .expect("silent attach must time out");

    assert!(matches!(
        error.downcast_ref::<RemoteRequestError>(),
        Some(RemoteRequestError::Timeout)
    ));
    assert!(!session.has_surface(7));
    assert!(session.pending.lock().unwrap().is_empty());
    assert!(session.shutdown.load(Ordering::Acquire));
    assert!(closed.load(Ordering::Acquire));
}

#[cfg(unix)]
#[test]
fn eof_cancels_a_pending_request_without_waiting_for_the_request_timeout() {
    let (client, server) = UnixStream::pair().unwrap();
    let peer = std::thread::spawn(move || {
        let mut peer = BufReader::new(server);
        for expected_command in ["identify", "set-client-info", "subscribe"] {
            let mut line = String::new();
            peer.read_line(&mut line).unwrap();
            let request: Value = serde_json::from_str(&line).unwrap();
            assert_eq!(request["cmd"], expected_command);
            let data = if expected_command == "identify" {
                json!({
                    "app": "cmux-tui",
                    "protocol": SUPPORTED_PROTOCOL_VERSION,
                    "capabilities": ["browser-pointer-frame-guard-v1"],
                })
            } else {
                Value::Null
            };
            writeln!(peer.get_mut(), "{}", json!({"id": request["id"], "ok": true, "data": data}))
                .unwrap();
        }

        let mut line = String::new();
        peer.read_line(&mut line).unwrap();
        let request: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(request["cmd"], "wait-for-eof");
        // Dropping the peer produces EOF while this request is pending.
    });
    let session = RemoteSession::connect_stream(Box::new(client)).unwrap();
    let request_session = session.clone();
    let (done_tx, done_rx) = channel();
    let started = Instant::now();
    let request = std::thread::spawn(move || {
        done_tx.send(request_session.request(json!({"cmd": "wait-for-eof"}))).unwrap();
    });

    let result = match done_rx.recv_timeout(Duration::from_secs(2)) {
        Ok(result) => result,
        Err(error) => {
            session.begin_shutdown();
            request.join().unwrap();
            panic!("EOF did not cancel the request promptly: {error}");
        }
    };
    request.join().unwrap();
    peer.join().unwrap();

    let error = result.unwrap_err();
    assert!(
        matches!(error.downcast_ref::<RemoteRequestError>(), Some(RemoteRequestError::Shutdown)),
        "expected shutdown after EOF canceled the request, got {error:?}"
    );
    assert!(started.elapsed() < Duration::from_secs(2));
    assert!(session.shutdown.load(Ordering::Acquire));
    assert!(session.pending.lock().unwrap().is_empty());
}
