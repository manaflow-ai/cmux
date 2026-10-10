//! Surface attach deadlines, ordering, and retirement.

use super::*;

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
