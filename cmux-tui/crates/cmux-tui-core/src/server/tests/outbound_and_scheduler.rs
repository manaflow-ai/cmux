//! Bounded outbound queues, the message writer, WebSocket framing, and the per-connection surface scheduler.

use super::*;

#[test]
fn bounded_writer_reserves_a_control_lane_for_responses_and_overflow() {
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let backlog = writer.start_stream(&json!({"event": "overflow"})).unwrap();

    for sequence in 0..OUTBOUND_CAPACITY - 1 {
        writer.send_stream(&json!({"event": "output", "sequence": sequence}), &backlog).unwrap();
    }

    let failed_stream = writer.start_stream(&subscription_overflow_json()).unwrap();
    writer.send_control(&json!({"id": 42, "ok": true, "data": {}})).unwrap();
    writer.send_terminal(&subscription_overflow_json(), &failed_stream).unwrap();
    let response: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
    assert_eq!(response["id"], 42);
    let terminal: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
    assert_eq!(terminal["event"], "overflow");
    let drained = (0..OUTBOUND_CAPACITY - 1)
        .map(|_| outbound.try_pop().expect("accepted output"))
        .collect::<Vec<_>>();
    assert!(drained[0].contains("\"sequence\":0"));
    assert!(writer.is_open());
}

#[test]
fn initial_stream_state_precedes_its_response_and_overflows_only_its_stream() {
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let stream = writer.start_stream(&attach_overflow_json(7)).unwrap();

    writer.send_initial(&json!({"event": "vt-state", "surface": 7}), &stream).unwrap();
    writer.send_control(&json!({"id": 1, "ok": true})).unwrap();
    let initial: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
    assert_eq!(initial["event"], "vt-state");
    let response: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
    assert_eq!(response["id"], 1);

    let oversized = writer.start_stream(&attach_overflow_json(8)).unwrap();
    let error = writer
        .send_initial(
            &json!({"event": "vt-state", "data": "x".repeat(OUTBOUND_BYTE_CAPACITY)}),
            &oversized,
        )
        .unwrap_err();
    assert_eq!(error.kind(), std::io::ErrorKind::WouldBlock);
    let overflow: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
    assert_eq!(overflow["event"], "overflow");
    assert_eq!(overflow["surface"], 8);
    assert!(writer.is_open());
}

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
fn attach_replays_carry_the_pending_sequence_after_their_colors() {
    let base64 = &base64::engine::general_purpose::STANDARD;
    let message = VtStateMessage {
        surface: 7,
        cols: 80,
        rows: 24,
        replay: Arc::from(&b"screen"[..]),
        kitty_image_aliases: Vec::new(),
        kitty_state: KittyReplayState::disabled(),
        colors: json!({"foreground": "#010203"}),
        pending_sequence: Arc::from(&b"\x1b[1;3"[..]),
    };
    let serialized = RenderService::new().serialize_vt_state(&message).unwrap();
    let decoded: Value = serde_json::from_str(&serialized).unwrap();
    assert_eq!(decoded["data"], base64.encode(b"screen"));
    assert_eq!(decoded["pending"], base64.encode(b"\x1b[1;3"));
    assert_eq!(decoded["colors"]["foreground"], "#010203");

    let resized = AttachFrame::ResizedWithColors {
        cols: 100,
        rows: 30,
        replay: Arc::from(&b"screen"[..]),
        kitty_image_aliases: Vec::new(),
        kitty_state: KittyReplayState::disabled(),
        colors: Box::new(TerminalColors::default()),
        pending_sequence: Arc::from(&b"\xce"[..]),
    };
    let shape = AttachWireShape { color_overrides: true, pending_sequence: true };
    let serialized = RenderService::new().serialize_attach_frame(7, &resized, shape).unwrap();
    let decoded: Value = serde_json::from_str(&serialized).unwrap();
    assert_eq!(decoded["event"], "resized");
    assert_eq!(decoded["replay"], base64.encode(b"screen"));
    assert_eq!(decoded["pending"], base64.encode(b"\xce"));

    // Viewers that did not advertise the capability keep the legacy
    // shape: the pending bytes end the replay itself.
    let legacy = AttachWireShape { color_overrides: true, pending_sequence: false };
    let serialized = RenderService::new().serialize_attach_frame(7, &resized, legacy).unwrap();
    let decoded: Value = serde_json::from_str(&serialized).unwrap();
    assert_eq!(decoded["replay"], base64.encode(b"screen\xce"));
    assert!(decoded.get("pending").is_none());
}

#[test]
fn maximum_vt_state_command_response_fits_the_control_reserve() {
    let service = RenderService::new();
    let outbound = BoundedOutbound::default();
    let replay = vec![0_u8; crate::surface::VT_REPLAY_MAX_BYTES];

    let mut output = service.reserved_control_writer().unwrap();
    write_vt_state_command_json(
        &mut output,
        Some(&json!(1)),
        80,
        24,
        &replay,
        &[],
        KittyReplayState::disabled(),
    )
    .unwrap();
    let serialized = output.finish();
    assert!(serialized.len() < OUTBOUND_CONTROL_BYTE_RESERVE);
    assert_eq!(serialized.retained_bytes, OUTBOUND_CONTROL_BYTE_RESERVE);
    assert!(serialized.starts_with(r#"{"id":1,"ok":true,"data":{"cols":80,"#));
    outbound.push_control(serialized).unwrap();
    assert!(outbound.try_pop().is_some());
}

#[test]
fn vt_state_releases_unused_control_reservation_after_encoding() {
    const RESERVATION: usize = 128;
    let budget = Arc::new(OutboundByteBudget::new(RESERVATION * 4));
    let mut queued = Vec::new();

    for _ in 0..5 {
        let mut reservation =
            BudgetedJsonWriter::with_reservation(budget.clone(), RESERVATION).unwrap();
        assert_eq!(reservation.bytes.capacity(), 0);
        reservation.write_all(b"{}").unwrap();
        queued.push(reservation.finish());
    }

    assert!(budget.retained_bytes.load(Ordering::Acquire) < RESERVATION);
    drop(queued);
    assert_eq!(budget.retained_bytes.load(Ordering::Acquire), 0);
}

#[test]
fn websocket_server_headers_cover_every_outbound_payload_width() {
    let (small, small_len) = websocket_server_frame_header(0x1, 125);
    assert_eq!(&small[..small_len], &[0x81, 125]);

    let (medium, medium_len) = websocket_server_frame_header(0x1, 126);
    assert_eq!(&medium[..medium_len], &[0x81, 126, 0, 126]);

    let (large, large_len) = websocket_server_frame_header(0x1, RENDER_ATTACH_MAX_BYTES);
    assert_eq!(large_len, 10);
    assert_eq!(large[0], 0x81);
    assert_eq!(large[1], 127);
    assert_eq!(&large[2..10], &(RENDER_ATTACH_MAX_BYTES as u64).to_be_bytes());
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
fn vt_state_streaming_releases_partial_global_budget_on_overflow() {
    let service = RenderService::new_with_outbound_budget(64);
    let message = VtStateMessage {
        surface: 7,
        cols: 80,
        rows: 24,
        replay: Arc::from(vec![b'x'; 1024]),
        kitty_image_aliases: Vec::new(),
        kitty_state: KittyReplayState::disabled(),
        colors: Value::Null,
        pending_sequence: Arc::from([]),
    };

    let error = service
        .serialize_vt_state(&message)
        .err()
        .expect("oversized replay must exhaust the global budget");

    assert_eq!(error.kind(), std::io::ErrorKind::WouldBlock);
    assert_eq!(service.outbound_budget.retained_bytes.load(Ordering::Acquire), 0);
}

#[test]
fn resize_stream_serialization_reserves_budget_before_queueing() {
    let service = Arc::new(RenderService::new_with_outbound_budget(64));
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new_with_render_service(
        QueuedSink { outbound: outbound.clone(), control: None },
        service.clone(),
    );
    let stream = writer.start_stream(&attach_overflow_json(7)).unwrap();
    let frame = AttachFrame::Resized {
        cols: 80,
        rows: 24,
        replay: Arc::from(vec![b'x'; 1024]),
        kitty_image_aliases: Vec::new(),
        kitty_state: KittyReplayState::disabled(),
        pending_sequence: Arc::from([]),
    };

    let error = writer
        .send_attach_frame_backpressured(7, &frame, AttachWireShape::default(), &stream)
        .unwrap_err();

    assert_eq!(error.kind(), std::io::ErrorKind::WouldBlock);
    assert!(outbound.try_pop().is_none());
    assert_eq!(service.outbound_budget.retained_bytes.load(Ordering::Acquire), 0);
}

#[test]
fn server_connection_permits_enforce_and_release_the_cap() {
    let connections = Arc::new(crate::diagnostics::ConnectionStats::default());
    let permits: Vec<ConnectionPermit> = (0..MAX_SERVER_CONNECTIONS)
        .map(|_| claim_connection(&connections).expect("slot below the cap"))
        .collect();
    assert!(claim_connection(&connections).is_none());
    assert_eq!(connections.active(), MAX_SERVER_CONNECTIONS as u64);
    drop(permits);
    assert_eq!(connections.active(), 0);
    let snapshot = connections.snapshot(MAX_SERVER_CONNECTIONS as u64);
    assert_eq!(snapshot.refused, 1);
    assert_eq!(snapshot.peak, MAX_SERVER_CONNECTIONS as u64);
}

#[test]
fn server_stats_report_lock_writer_and_connection_metrics() {
    let mux = test_mux();
    let unix_client = mux.control_clients.register(ClientTransport::Unix, test_writer());
    let websocket_client = mux.control_clients.register(ClientTransport::WebSocket, test_writer());
    let identity =
        handle_command(&mux, mux.local_test_client(0), Command::Identify, &test_writer()).unwrap();
    assert!(
        identity["capabilities"].as_array().unwrap().iter().any(|c| c == SERVER_STATS_CAPABILITY)
    );
    // Any registry use records a hold at its call site.
    let _ = mux.registry_identity();
    let stats =
        handle_command(&mux, unix_client, Command::ServerStats { include: None }, &test_writer())
            .unwrap();
    assert_eq!(stats["schema"].as_u64(), Some(crate::diagnostics::SERVER_STATS_SCHEMA as u64));
    assert!(stats["uptime_ms"].is_u64());
    let lock = &stats["registry_lock"];
    assert!(lock["hold_us"]["count"].as_u64().unwrap() >= 1, "{lock}");
    assert!(lock["holder"].is_null(), "{lock}");
    let site = lock["top_sites"][0]["site"].as_str().unwrap();
    assert!(site.contains("mux.rs:") || site.contains("/mux/"), "{site}");
    assert_eq!(stats["connections"]["limit"].as_u64(), Some(MAX_SERVER_CONNECTIONS as u64));
    assert!(stats["journal_writer"].is_object() || stats["journal_writer"].is_null());

    let error = handle_command(
        &mux,
        websocket_client,
        Command::ServerStats { include: None },
        &test_writer(),
    )
    .expect_err("remote clients must not receive internal server stats");
    assert!(error.to_string().contains("trusted local connection"));
}

#[test]
fn shutting_down_a_writer_clone_unblocks_the_reader() {
    let socket = TestSocket::new("shutdown");
    let listener = transport::listen(&socket.path).unwrap();
    let _client = transport::connect(&socket.path).unwrap();
    let mut reader = listener.accept().unwrap();
    let writer = reader.try_clone_box().unwrap();
    let (done, finished) = std::sync::mpsc::channel();
    let read_thread = std::thread::spawn(move || {
        let mut byte = [0_u8; 1];
        done.send(reader.read(&mut byte)).unwrap();
    });

    writer.shutdown(Shutdown::Both).unwrap();
    assert_eq!(finished.recv_timeout(Duration::from_secs(1)).unwrap().unwrap(), 0);
    read_thread.join().unwrap();
}

#[test]
fn write_side_eof_drains_accepted_surface_requests() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    surface.with_terminal(|term| {
        term.vt_write(b"history\r\n\x1b]133;A\x07prompt> \x1b[31");
    });

    let socket = TestSocket::new("write-eof-drain");
    let listener = transport::listen(&socket.path).unwrap();
    let mut client = transport::connect(&socket.path).unwrap();
    let server = listener.accept().unwrap();
    let server_mux = mux.clone();
    let handler = std::thread::spawn(move || handle_connection(server_mux, server));

    writeln!(client, "{}", json!({"id": 1, "cmd": "clear-history", "surface": surface.id}))
        .unwrap();
    writeln!(
        client,
        "{}",
        json!({"id": 2, "cmd": "send", "surface": surface.id, "text": "after-eof"})
    )
    .unwrap();
    client.flush().unwrap();
    client.shutdown(Shutdown::Write).unwrap();
    client.set_read_timeout(Some(Duration::from_secs(2))).unwrap();

    let mut responses = Vec::new();
    let mut reader = BufReader::new(client);
    while responses.len() < 2 {
        let mut line = String::new();
        match reader.read_line(&mut line) {
            Ok(0) => break,
            Ok(_) => responses.push(serde_json::from_str::<Value>(&line).unwrap()),
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) =>
            {
                break;
            }
            Err(error) => panic!("unexpected response read error: {error}"),
        }
    }
    let _ = reader.get_ref().shutdown(Shutdown::Both);
    handler.join().unwrap();
    mux.close_surface(surface.id).unwrap();

    let response_ids =
        responses.iter().filter_map(|response| response["id"].as_u64()).collect::<Vec<_>>();
    assert_eq!(response_ids, [1, 2], "write-side EOF discarded an accepted request");
}

#[test]
fn clear_history_rejection_reports_known_not_delivered_delivery() {
    let mux = test_mux();
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());

    assert!(handle_message(
        &mux,
        client,
        &json!({"id": 1, "cmd": "clear-history", "surface": 999_999}).to_string(),
        &writer,
    ));
    let response: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();

    assert_eq!(response["ok"], false);
    assert_eq!(response["error_delivery"], "known-not-delivered");
}

#[test]
fn clear_history_does_not_block_unrelated_surface_input_on_one_connection() {
    let mux = test_mux();
    let blocked = mux.new_workspace(None, Some((80, 24))).unwrap();
    let unrelated = mux.new_workspace(None, Some((80, 24))).unwrap();
    blocked.with_terminal(|term| {
        for line in 0..24 {
            term.vt_write(format!("history-{line}\r\n").as_bytes());
        }
        term.vt_write(b"\x1b]133;A\x07prompt> \x1b[31");
    });

    let socket = TestSocket::new("clear-concurrency");
    let listener = transport::listen(&socket.path).unwrap();
    let mut client = transport::connect(&socket.path).unwrap();
    let server = listener.accept().unwrap();
    let server_mux = mux.clone();
    let handler = std::thread::spawn(move || handle_connection(server_mux, server));

    client.set_read_timeout(Some(Duration::from_millis(150))).unwrap();
    writeln!(client, "{}", json!({"id": 1, "cmd": "clear-history", "surface": blocked.id}))
        .unwrap();
    client.flush().unwrap();
    std::thread::sleep(Duration::from_millis(30));
    writeln!(client, "{}", json!({"id": 2, "cmd": "send", "surface": blocked.id, "text": "same"}))
        .unwrap();
    writeln!(
        client,
        "{}",
        json!({"id": 3, "cmd": "send", "surface": unrelated.id, "text": "other"})
    )
    .unwrap();
    client.flush().unwrap();

    let mut reader = BufReader::new(client);
    let mut first_line = String::new();
    let first_response = reader.read_line(&mut first_line);
    reader.get_ref().set_read_timeout(Some(Duration::from_secs(1))).unwrap();
    let mut ordered_lines = Vec::new();
    for _ in 0..2 {
        let mut line = String::new();
        ordered_lines.push((reader.read_line(&mut line), line));
    }
    let _ = reader.get_ref().shutdown(Shutdown::Both);
    handler.join().unwrap();
    mux.close_surface(blocked.id).unwrap();
    mux.close_surface(unrelated.id).unwrap();

    first_response.expect("unrelated input response was blocked behind clear-history");
    let first_response: Value = serde_json::from_str(&first_line).unwrap();
    assert_eq!(first_response["id"], 3);
    assert_eq!(first_response["ok"], true);
    let ordered_ids = ordered_lines
        .into_iter()
        .map(|(read, line)| {
            read.expect("same-surface request did not settle after clear-history");
            serde_json::from_str::<Value>(&line).unwrap()["id"].as_u64().unwrap()
        })
        .collect::<Vec<_>>();
    assert_eq!(ordered_ids, [1, 2]);
}

#[test]
fn lifecycle_command_waits_for_active_clear_history_on_one_connection() {
    let mux = test_mux();
    let blocked = mux.new_workspace(None, Some((80, 24))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(blocked.id).unwrap());
    blocked.with_terminal(|term| {
        for line in 0..24 {
            term.vt_write(format!("history-{line}\r\n").as_bytes());
        }
        term.vt_write(b"\x1b]133;A\x07prompt> \x1b[31");
    });

    let socket = TestSocket::new("clear-lifecycle");
    let listener = transport::listen(&socket.path).unwrap();
    let mut client = transport::connect(&socket.path).unwrap();
    let server = listener.accept().unwrap();
    let server_mux = mux;
    let handler = std::thread::spawn(move || handle_connection(server_mux, server));

    writeln!(client, "{}", json!({"id": 1, "cmd": "clear-history", "surface": blocked.id}))
        .unwrap();
    client.flush().unwrap();
    std::thread::sleep(Duration::from_millis(30));
    writeln!(client, "{}", json!({"id": 2, "cmd": "close-pane", "pane": pane})).unwrap();
    client.flush().unwrap();

    client.set_read_timeout(Some(Duration::from_millis(75))).unwrap();
    let mut reader = BufReader::new(client);
    let mut early_line = String::new();
    let early_response = match reader.read_line(&mut early_line) {
        Ok(0) => panic!("connection closed before clear-history settled"),
        Ok(_) => Some(early_line),
        Err(error)
            if matches!(
                error.kind(),
                std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
            ) =>
        {
            None
        }
        Err(error) => panic!("unexpected response read error: {error}"),
    };

    reader.get_ref().set_read_timeout(Some(Duration::from_secs(1))).unwrap();
    let mut responses = early_response.iter().cloned().collect::<Vec<_>>();
    while responses.len() < 2 {
        let mut line = String::new();
        reader.read_line(&mut line).expect("ordered lifecycle response");
        responses.push(line);
    }
    let _ = reader.get_ref().shutdown(Shutdown::Both);
    handler.join().unwrap();

    assert!(
        early_response.is_none(),
        "lifecycle command responded before clear-history reached a safe boundary"
    );
    let response_ids = responses
        .into_iter()
        .map(|line| serde_json::from_str::<Value>(&line).unwrap()["id"].as_u64().unwrap())
        .collect::<Vec<_>>();
    assert_eq!(response_ids, [1, 2]);
}

#[test]
fn connection_surface_schedulers_for_one_mux_share_admission() {
    let mux = test_mux();
    let first = ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone());
    let second = ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone());
    assert!(Arc::ptr_eq(&first.admission, &second.admission));
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
fn queued_wait_releases_clear_worker_permit_after_clear_settles() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    surface.with_terminal(|term| {
        term.vt_write(b"history\r\n\x1b]133;A\x07prompt> \x1b[31");
    });
    let admission = Arc::new(ServerSurfaceOperationAdmission::default());
    let scheduler = Arc::new(ConnectionSurfaceScheduler::new(admission.clone()));
    let (writer, outbound) = captured_writer();

    let mut clear = Some(Request {
        id: Some(json!(1)),
        cmd: Command::ClearHistory { surface: surface.id, fallback_key: None },
    });
    assert_eq!(scheduler.dispatch(mux.clone(), 0, &mut clear, 0, writer.clone()), Some(true));
    let mut wait = Some(Request {
        id: Some(json!(2)),
        cmd: Command::WaitFor {
            surface: surface.id,
            pattern: "never-matches".to_string(),
            timeout_ms: 500,
        },
    });
    assert_eq!(scheduler.dispatch(mux.clone(), 0, &mut wait, 0, writer), Some(true));

    let clear_response = pop_json(&outbound);
    assert_eq!(clear_response["id"], json!(1));
    let clear_deadline = Instant::now() + Duration::from_secs(1);
    let mut state = scheduler.state.lock().unwrap();
    while state.active_clear_surfaces.contains(&surface.id) {
        let remaining = clear_deadline.saturating_duration_since(Instant::now());
        assert!(!remaining.is_zero(), "clear-history worker did not settle");
        let (next, timeout) = scheduler.changed.wait_timeout(state, remaining).unwrap();
        state = next;
        assert!(
            !timeout.timed_out() || !state.active_clear_surfaces.contains(&surface.id),
            "clear-history worker did not settle"
        );
    }
    drop(state);
    let active_clear_workers = admission.state.lock().unwrap().workers;
    let drained = scheduler.close_and_wait(Duration::from_secs(1));
    mux.close_surface(surface.id).unwrap();

    assert_eq!(
        active_clear_workers, 0,
        "a queued wait-for retained the completed clear-history worker permit"
    );
    assert!(drained);
}

#[test]
fn connection_close_cancels_a_wait_queued_after_clear_history() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    surface.with_terminal(|term| {
        term.vt_write(b"history\r\n\x1b]133;A\x07prompt> \x1b[31");
    });
    let scheduler = Arc::new(ConnectionSurfaceScheduler::new(Arc::new(
        ServerSurfaceOperationAdmission::default(),
    )));
    let writer = test_writer();

    let mut clear = Some(Request {
        id: Some(json!(1)),
        cmd: Command::ClearHistory { surface: surface.id, fallback_key: None },
    });
    assert_eq!(scheduler.dispatch(mux.clone(), 0, &mut clear, 0, writer.clone()), Some(true));
    let mut wait = Some(Request {
        id: Some(json!(2)),
        cmd: Command::WaitFor {
            surface: surface.id,
            pattern: "release-wait".to_string(),
            timeout_ms: 1_000,
        },
    });
    assert_eq!(scheduler.dispatch(mux.clone(), 0, &mut wait, 0, writer), Some(true));

    std::thread::sleep(Duration::from_millis(350));
    let drained = scheduler.close_and_wait(Duration::from_millis(500));
    if !drained {
        let _ = scheduler.close_and_wait(Duration::from_secs(1));
    }
    mux.close_surface(surface.id).unwrap();

    assert!(drained, "connection shutdown did not cancel an active wait-for request");
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
fn scheduler_retains_connection_permit_until_dispatcher_exit() {
    let active = Arc::new(crate::diagnostics::ConnectionStats::default());
    let permit = claim_connection(&active).unwrap();
    let scheduler = Arc::new(ConnectionSurfaceScheduler::new_with_connection_permit(
        Arc::new(ServerSurfaceOperationAdmission::default()),
        permit,
    ));
    scheduler.state.lock().unwrap().dispatcher_started = true;
    let (release_tx, release_rx) = std::sync::mpsc::channel();
    let worker_scheduler = scheduler.clone();
    let dispatcher = std::thread::spawn(move || {
        release_rx.recv().unwrap();
        worker_scheduler.finish_dispatcher();
    });
    *scheduler.dispatcher.lock().unwrap() = Some(dispatcher);

    assert!(!scheduler.close_and_wait(Duration::from_millis(25)));
    assert_eq!(
        active.active(),
        1,
        "timed-out shutdown released admission while its dispatcher was live"
    );

    release_tx.send(()).unwrap();
    assert!(scheduler.close_and_wait(Duration::from_secs(1)));
    assert_eq!(active.active(), 0);
}

#[test]
fn surface_worker_limit_is_mux_wide_across_connections() {
    assert!(
        active_clear_lanes_across_connections(17, 0) <= 16,
        "per-connection limits allowed more than 16 mux-wide clear workers"
    );
}

#[test]
fn active_surface_request_bytes_count_toward_mux_budget() {
    const FOUR_MIB: usize = 4 * 1024 * 1024;
    assert!(
        active_clear_lanes_across_connections(5, FOUR_MIB) <= 4,
        "active first requests bypassed the 16 MiB mux-wide byte budget"
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

#[test]
fn each_stream_has_an_independent_message_budget() {
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let noisy = writer.start_stream(&json!({"event": "overflow", "stream": "noisy"})).unwrap();
    let quiet = writer.start_stream(&json!({"event": "overflow", "stream": "quiet"})).unwrap();

    for sequence in 0..OUTBOUND_CAPACITY {
        writer.send_stream(&json!({"event": "output", "sequence": sequence}), &noisy).unwrap();
    }
    writer.send_stream(&json!({"event": "tree-changed"}), &quiet).unwrap();
    assert_eq!(
        writer.send_stream(&json!({"event": "one-too-many"}), &noisy).unwrap_err().kind(),
        std::io::ErrorKind::WouldBlock
    );

    let terminal: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
    assert_eq!(terminal["stream"], "noisy");
    let quiet_event: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
    assert_eq!(quiet_event["event"], "tree-changed");
    assert_eq!(outbound.try_pop(), None);
    assert_eq!(
        writer.send_stream(&json!({"event": "late"}), &noisy).unwrap_err().kind(),
        std::io::ErrorKind::BrokenPipe
    );
    assert!(quiet.is_open());
    assert!(writer.is_open());
}

#[test]
fn graceful_stream_terminal_is_ordered_after_queued_items() {
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let stream = writer.start_stream(&json!({"event":"overflow"})).unwrap();
    writer.send_stream(&json!({"event":"first"}), &stream).unwrap();
    writer.send_stream(&json!({"event":"second"}), &stream).unwrap();
    writer.send_ordered_terminal(&json!({"event":"completed"}), &stream).unwrap();

    assert_eq!(pop_json(&outbound)["event"], "first");
    assert_eq!(pop_json(&outbound)["event"], "second");
    assert_eq!(pop_json(&outbound)["event"], "completed");
    assert!(!stream.is_open());
    assert_eq!(
        writer.send_stream(&json!({"event":"late"}), &stream).unwrap_err().kind(),
        std::io::ErrorKind::BrokenPipe
    );
}

#[test]
fn backpressured_stream_waits_for_its_prior_item_without_overflow() {
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let stream = writer.start_stream(&attach_overflow_json(7)).unwrap();
    writer.send_stream(&json!({"event": "first"}), &stream).unwrap();
    writer.send_stream(&json!({"event": "second"}), &stream).unwrap();
    let (started_tx, started_rx) = std::sync::mpsc::sync_channel(1);
    let (done_tx, done_rx) = std::sync::mpsc::sync_channel(1);
    let waiting_writer = writer;
    let waiting_stream = stream.clone();
    let worker = std::thread::spawn(move || {
        started_tx.send(()).unwrap();
        done_tx
            .send(
                waiting_writer
                    .send_stream_backpressured(&json!({"event": "third"}), &waiting_stream),
            )
            .unwrap();
    });

    started_rx.recv().unwrap();
    assert!(done_rx.recv_timeout(Duration::from_millis(20)).is_err());
    assert!(stream.is_open(), "backpressure terminated a healthy stream");
    assert_eq!(pop_json(&outbound)["event"], "first");
    done_rx.recv_timeout(Duration::from_secs(1)).unwrap().unwrap();
    assert_eq!(pop_json(&outbound)["event"], "second");
    assert_eq!(pop_json(&outbound)["event"], "third");
    assert!(stream.is_open());
    worker.join().unwrap();
}

#[test]
fn backpressured_stream_unblocks_when_the_connection_closes() {
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let stream = writer.start_stream(&attach_overflow_json(7)).unwrap();
    writer.send_stream(&json!({"event": "first"}), &stream).unwrap();
    writer.send_stream(&json!({"event": "second"}), &stream).unwrap();
    let (started_tx, started_rx) = std::sync::mpsc::sync_channel(1);
    let (done_tx, done_rx) = std::sync::mpsc::sync_channel(1);
    let waiting_writer = writer;
    let waiting_stream = stream;
    let worker = std::thread::spawn(move || {
        started_tx.send(()).unwrap();
        done_tx
            .send(
                waiting_writer
                    .send_stream_backpressured(&json!({"event": "third"}), &waiting_stream),
            )
            .unwrap();
    });

    started_rx.recv().unwrap();
    assert!(done_rx.recv_timeout(Duration::from_millis(20)).is_err());
    outbound.close();
    let error = done_rx.recv_timeout(Duration::from_secs(1)).unwrap().unwrap_err();
    assert_eq!(error.kind(), std::io::ErrorKind::BrokenPipe);
    worker.join().unwrap();
}

#[test]
fn bounded_writer_rejects_payloads_beyond_each_byte_budget() {
    let outbound = BoundedOutbound::default();
    let service =
        RenderService::new_with_outbound_budget(OUTBOUND_GLOBAL_BYTE_CAPACITY.saturating_mul(2));
    let stream = OutboundStream::new(1, service.serialize(&json!({"event": "overflow"})).unwrap());

    let regular_text = service.serialize(&"x".repeat(OUTBOUND_BYTE_CAPACITY + 1)).unwrap();
    let regular = outbound.push_regular(regular_text, &stream).unwrap_err();
    assert_eq!(regular.kind(), std::io::ErrorKind::WouldBlock);
    let control_text =
        service.serialize_control(&"x".repeat(OUTBOUND_CONTROL_BYTE_RESERVE + 1)).unwrap();
    let control = outbound.push_control(control_text).unwrap_err();
    assert_eq!(control.kind(), std::io::ErrorKind::WouldBlock);
    let terminal: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
    assert_eq!(terminal["event"], "overflow");
    assert_eq!(outbound.try_pop(), None);
}

#[test]
fn timed_out_control_flush_discards_the_pending_response() {
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(TimedOutFlushSink { outbound: outbound.clone() });
    writer.send_control(&json!({"ok": true})).unwrap();

    let error = writer.flush_control(Duration::from_secs(1)).unwrap_err();

    assert_eq!(error.kind(), std::io::ErrorKind::TimedOut);
    assert!(!writer.is_open());
    assert_eq!(outbound.try_pop(), None);
}

#[test]
fn control_flush_waits_for_the_line_writer_flush() {
    let outbound = Arc::new(BoundedOutbound::default());
    let response = RenderService::new().serialize_control(&json!({"ok": true})).unwrap();
    outbound.push_control(response.clone()).unwrap();
    let waiting = outbound.clone();
    let (done_tx, done_rx) = std::sync::mpsc::sync_channel(1);
    let worker = std::thread::spawn(move || {
        done_tx.send(waiting.flush_control(Duration::from_secs(5))).unwrap();
    });
    let mut writer = FlushRecordingWriter::default();

    write_line_outbound_item(&mut writer, outbound.recv().unwrap()).unwrap();
    assert!(matches!(done_rx.try_recv(), Err(TryRecvError::Empty)));
    write_line_outbound_item(&mut writer, outbound.recv().unwrap()).unwrap();

    done_rx.recv_timeout(Duration::from_secs(1)).unwrap().unwrap();
    worker.join().unwrap();
    let mut expected = response.as_bytes().to_vec();
    expected.push(b'\n');
    assert_eq!(writer.bytes, expected);
    assert_eq!(writer.flushes, 1);
}

#[test]
fn control_flush_waits_until_the_prior_control_message_leaves_the_queue() {
    let outbound = Arc::new(BoundedOutbound::default());
    let service = RenderService::new();
    let response = service.serialize_control(&json!({"ok": true})).unwrap();
    outbound.push_control(response.clone()).unwrap();
    let (started_tx, started_rx) = std::sync::mpsc::sync_channel(1);
    let (done_tx, done_rx) = std::sync::mpsc::sync_channel(1);
    let waiting = outbound.clone();
    let worker = std::thread::spawn(move || {
        started_tx.send(()).unwrap();
        done_tx.send(waiting.flush_control(Duration::from_secs(5))).unwrap();
    });

    started_rx.recv().unwrap();
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        let flush_is_queued = outbound
            .state
            .lock()
            .unwrap()
            .control
            .iter()
            .any(|item| matches!(item, ControlOutbound::Flush(_)));
        if flush_is_queued {
            break;
        }
        assert!(Instant::now() < deadline, "flush barrier was not queued");
        std::thread::yield_now();
    }
    assert!(matches!(done_rx.try_recv(), Err(TryRecvError::Empty)));
    assert_eq!(outbound.try_pop().unwrap(), response.to_string());
    assert!(matches!(done_rx.try_recv(), Err(TryRecvError::Empty)));

    assert_eq!(outbound.try_pop(), None);
    done_rx.recv_timeout(Duration::from_secs(1)).unwrap().unwrap();
    worker.join().unwrap();
}

#[test]
fn terminal_overflow_purges_only_its_stream_and_rejects_late_frames() {
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let stale = writer.start_stream(&subscription_overflow_json()).unwrap();
    let unrelated = writer.start_stream(&subscription_overflow_json()).unwrap();

    writer.send_stream(&json!({"event": "output", "stream": "stale"}), &stale).unwrap();
    writer.send_stream(&json!({"event": "output", "stream": "unrelated"}), &unrelated).unwrap();
    writer.send_terminal(&subscription_overflow_json(), &stale).unwrap();

    let late = writer.send_stream(&json!({"event": "output", "stream": "late"}), &stale);
    assert_eq!(late.unwrap_err().kind(), std::io::ErrorKind::BrokenPipe);
    let terminal: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
    assert_eq!(terminal["event"], "overflow");
    let remaining: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
    assert_eq!(remaining["stream"], "unrelated");
    assert_eq!(outbound.try_pop(), None);
    assert!(writer.is_open());
}

#[test]
fn client_detach_purges_attach_backlog_before_terminal_event() {
    let mux = Mux::new("detach-order-test", SurfaceOptions::default());
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let stream = writer.start_stream(&attach_overflow_json(41)).unwrap();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    mux.control_clients.attach_surface(client, 41, stream.clone()).unwrap();
    mux.control_clients.commit_surface(client, 41, stream.id, None).unwrap();
    writer.send_initial(&json!({"event": "vt-state", "surface": 41}), &stream).unwrap();
    writer.send_stream(&json!({"event": "output", "surface": 41}), &stream).unwrap();

    assert!(disconnect_client(&mux, client, true));

    let terminal: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
    assert_eq!(terminal, json!({"event": "detached", "surface": 41, "reason": "network"}));
    assert_eq!(outbound.try_pop(), None);
}
