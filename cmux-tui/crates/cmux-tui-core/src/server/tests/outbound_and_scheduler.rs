//! Bounded outbound queues, the message writer, WebSocket framing, and the per-connection surface scheduler.

use super::*;

#[test]
fn vt_state_wire_prefix_identifies_attach_before_large_replay_data() {
    let replay = Arc::<[u8]>::from(vec![b'x'; 1024]);
    let message = VtStateMessage {
        surface: 7,
        cols: 80,
        rows: 24,
        replay: replay.clone(),
        kitty_image_aliases: Vec::new(),
        kitty_state: KittyReplayState::disabled(),
        colors: Value::Null,
        pending_sequence: Arc::from([]),
    };

    let serialized = RenderService::new().serialize_vt_state(&message).unwrap();

    assert!(serialized.starts_with(r#"{"event":"vt-state","surface":7,"#), "{}", &**serialized);
    let decoded: Value = serde_json::from_str(&serialized).unwrap();
    assert_eq!(decoded["data"], base64::engine::general_purpose::STANDARD.encode(replay));
    assert!(decoded.get("pending").is_none(), "a boundary replay must not add `pending`");
}

#[test]
fn browser_state_wire_prefix_identifies_attach_before_large_frame_data() {
    let state = BrowserAttachState {
        url: "https://example.com".into(),
        title: "Example".into(),
        cols: 80,
        rows: 24,
        status: BrowserStatus::Live,
        frame: Some(BrowserFrame {
            session_id: "session".into(),
            data_b64: "eA==".repeat(256),
            css_width: 800,
            css_height: 600,
            image_width: 800,
            image_height: 600,
            seq: 1,
        }),
        pointer_frame_floor_seq: Some(1),
        pointer_frame_seq: Some(1),
        frames_stalled: false,
    };

    let serialized =
        RenderService::new().serialize(&browser_state_message(7, &state, true)).unwrap();

    assert!(
        serialized.starts_with(r#"{"event":"browser-state","surface":7,"#),
        "{}",
        &**serialized
    );
    let decoded: Value = serde_json::from_str(&serialized).unwrap();
    assert_eq!(decoded["frame"]["data"], state.frame.as_ref().unwrap().data_b64);
}

#[test]
fn blocking_wait_cannot_overtake_input_queued_behind_a_clear_barrier() {
    let admission = Arc::new(ServerSurfaceOperationAdmission::default());
    let mut state = ConnectionSurfaceState::default();
    state.active_clear_surfaces.insert(1);
    for (id, cmd) in [
        (
            1,
            Command::Send {
                surface: 1,
                text: Some("input".to_string()),
                bytes: None,
                paste: false,
            },
        ),
        (2, Command::WaitFor { surface: 2, pattern: "never".to_string(), timeout_ms: 60_000 }),
    ] {
        state.requests.push_back(PendingSurfaceRequest {
            request: Request { id: Some(json!(id)), cmd },
            retained_bytes: 0,
            _bytes_permit: admission.try_reserve_bytes(0).unwrap(),
        });
    }

    assert_eq!(
        ConnectionSurfaceScheduler::next_runnable_index(&state),
        None,
        "blocking wait overtook earlier input while its clear barrier was active"
    );
}

#[test]
fn guarded_browser_pointer_input_overtakes_an_unrelated_clear_barrier() {
    for cmd in [
        Command::BrowserFramePresented { surface: 2, frame_seq: 7 },
        Command::BrowserMouseGuarded {
            surface: 2,
            kind: "move".to_string(),
            x_px: 1.0,
            y_px: 1.0,
            button: None,
            click_count: None,
            frame_seq: 7,
        },
        Command::BrowserWheelGuarded {
            surface: 2,
            x_px: 1.0,
            y_px: 1.0,
            delta_y_px: 1.0,
            frame_seq: 7,
        },
    ] {
        let admission = Arc::new(ServerSurfaceOperationAdmission::default());
        let mut state = ConnectionSurfaceState::default();
        state.active_clear_surfaces.insert(1);
        state.requests.push_back(PendingSurfaceRequest {
            request: Request { id: Some(json!(1)), cmd },
            retained_bytes: 0,
            _bytes_permit: admission.try_reserve_bytes(0).unwrap(),
        });

        assert_eq!(
            ConnectionSurfaceScheduler::next_runnable_index(&state),
            Some(0),
            "guarded browser pointer input waited behind an unrelated clear-history worker"
        );
    }
}

#[test]
fn queued_same_surface_clears_do_not_reserve_worker_permits() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    surface.with_terminal(|term| {
        term.vt_write(b"history\r\n\x1b]133;A\x07prompt> \x1b[31");
    });
    let admission = Arc::new(ServerSurfaceOperationAdmission::default());
    let scheduler = Arc::new(ConnectionSurfaceScheduler::new(admission.clone()));
    let writer = test_writer();

    for id in 0..SERVER_SURFACE_WORKER_CAPACITY {
        let mut clear = Some(Request {
            id: Some(json!(id)),
            cmd: Command::ClearHistory { surface: surface.id, fallback_key: None },
        });
        assert_eq!(scheduler.dispatch(mux.clone(), 0, &mut clear, 0, writer.clone()), Some(true));
    }

    let reserved_workers = admission.state.lock().unwrap().workers;
    let _ = scheduler.close_and_wait(Duration::from_secs(1));
    mux.close_surface(surface.id).unwrap();

    assert!(
        reserved_workers <= 1,
        "queued same-surface clears reserved {reserved_workers} mux-wide worker permits"
    );
}

#[test]
fn independent_muxes_do_not_share_surface_operation_admission() {
    let first_mux = test_mux();
    let second_mux = test_mux();
    let first = ConnectionSurfaceScheduler::new(first_mux.surface_operation_admission.clone());
    let second = ConnectionSurfaceScheduler::new(second_mux.surface_operation_admission.clone());
    let permits = (0..SERVER_SURFACE_WORKER_CAPACITY)
        .map(|_| first.admission.try_reserve_worker().unwrap())
        .collect::<Vec<_>>();

    let isolated = second.admission.try_reserve_worker();
    drop(permits);

    assert!(
        isolated.is_some(),
        "one mux exhausted the hidden process-global admission budget of another mux"
    );
}

#[test]
fn stalled_websocket_handshake_times_out() {
    let (listener, mux) = (TcpListener::bind("127.0.0.1:0").unwrap(), test_mux());
    let client = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
    let (server, peer) = listener.accept().unwrap();
    let (done, finished) = std::sync::mpsc::channel();
    let handler = std::thread::spawn(move || {
        handle_websocket_connection(mux, server, peer, None, Arc::new(RenderService::new()));
        done.send(()).unwrap();
    });

    finished
        .recv_timeout(Duration::from_secs(30))
        .expect("stalled handshake must not occupy a connection slot indefinitely");
    drop(client);
    handler.join().unwrap();
}

#[test]
fn stalled_websocket_authentication_times_out() {
    let (listener, mux) = (TcpListener::bind("127.0.0.1:0").unwrap(), test_mux());
    let client_stream = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
    let (server, peer) = listener.accept().unwrap();
    let (done, finished) = std::sync::mpsc::channel();
    let handler = std::thread::spawn(move || {
        handle_websocket_connection(
            mux,
            server,
            peer,
            Some("secret"),
            Arc::new(RenderService::new()),
        );
        done.send(()).unwrap();
    });
    let (client, _) = tungstenite::client("ws://localhost/", client_stream).unwrap();

    finished
        .recv_timeout(Duration::from_secs(30))
        .expect("stalled authentication must not occupy a connection slot indefinitely");
    drop(client);
    handler.join().unwrap();
}
