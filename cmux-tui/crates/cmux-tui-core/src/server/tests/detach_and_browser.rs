//! Client detach, relay sub-views, agent reports and browser pointer/capability wire shapes.

use super::*;

#[test]
fn self_detach_responds_before_closing_and_releases_the_size_lease() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, Some((120, 40))).unwrap();
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let events = mux.subscribe();
    let attached_stream = writer.start_stream(&json!({"event": "attach-overflow"})).unwrap();
    mux.control_clients.attach_surface(client, surface.id, attached_stream.clone()).unwrap();
    mux.control_clients.commit_surface(client, surface.id, attached_stream.id, None).unwrap();
    let subscription_stream =
        writer.start_stream(&json!({"event": "subscription-overflow"})).unwrap();
    writer.send_stream(&json!({"event": "stale-subscription"}), &subscription_stream).unwrap();
    mux.resize_surface_for_client(surface.id, client, 80, 24).unwrap();

    assert!(!handle_message(
        &mux,
        client,
        &json!({"id": 9, "cmd": "detach-client", "client": client}).to_string(),
        &writer,
    ));

    let response: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
    assert_eq!(response["id"], 9);
    assert_eq!(response["ok"], true);
    let detached: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
    assert_eq!(
        detached,
        json!({"event": "detached", "surface": surface.id, "reason": "disconnected-by"})
    );
    assert_eq!(outbound.try_pop(), None, "stream data followed the terminal detach marker");
    assert_eq!(mux.client_surface_size(surface.id, client), None);
    assert!(mux.control_clients_json(client).as_array().unwrap().is_empty());
    assert!((0..4).any(|_| matches!(
        events.recv_timeout(Duration::from_secs(1)),
        Ok(MuxEvent::ClientDetached(id)) if id == client
    )));
    assert!(mux.surface(surface.id).is_some(), "the session must survive its last viewer");
}

#[test]
fn peer_detach_is_id_stable_and_does_not_disconnect_the_initiator() {
    let mux = test_mux();
    let initiator_writer = test_writer();
    let target_writer = test_writer();
    let initiator = mux.control_clients.register(ClientTransport::Unix, initiator_writer.clone());
    let target = mux.control_clients.register(ClientTransport::Unix, target_writer);

    handle_command(
        &mux,
        initiator,
        Command::DetachClient {
            client: DetachClientTarget::Client(target),
            by: None,
            surface: None,
        },
        &initiator_writer,
    )
    .unwrap();

    let listed = handle_command(&mux, initiator, Command::ListClients, &initiator_writer).unwrap();
    assert_eq!(listed.as_array().unwrap().len(), 1);
    assert_eq!(listed[0]["client"], initiator);
    let error = handle_command(
        &mux,
        initiator,
        Command::DetachClient {
            client: DetachClientTarget::Client(target),
            by: None,
            surface: None,
        },
        &initiator_writer,
    )
    .unwrap_err();
    assert!(error.to_string().contains(&format!("unknown client {target}")));
}

#[test]
fn owner_disconnect_elects_the_next_terminal_owner() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let join = |cols, rows| {
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        attach_test_view(&mux, client, surface.id, &writer);
        handle_command(
            &mux,
            client,
            Command::ResizeSurface { surface: surface.id, cols, rows },
            &writer,
        )
        .unwrap();
        client
    };
    let first = join(150, 42);
    let second = join(118, 38);
    assert_eq!(surface.size(), (118, 38));

    assert!(disconnect_client(&mux, second, false));
    assert_eq!(surface.size(), (150, 42), "the grid must not freeze at the departed owner");
    let state = mux.terminal_size_state(surface.id).unwrap();
    assert_eq!(state.owners, [format!("c{first}")]);
    assert_eq!(state.participants.len(), 1);
}

#[test]
fn relay_sub_views_join_shared_sizing_with_their_own_identity() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    mux.pin_latest_size_policy_for_test(surface.id);
    let (writer, outbound) = captured_writer();
    let relay = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    handle_command(
        &mux,
        relay,
        json_command(json!({
            "cmd": "set-client-info", "name": "mirror", "kind": "mac",
            "capabilities": [SHARED_SIZING_CAPABILITY],
            "user_id": "u1", "display_name": "Maya", "device_kind": "mac",
            "device_name": "Mac Studio",
        })),
        &writer,
    )
    .unwrap();
    attach_test_view(&mux, relay, surface.id, &writer);
    handle_command(
        &mux,
        relay,
        Command::ResizeSurface { surface: surface.id, cols: 150, rows: 42 },
        &writer,
    )
    .unwrap();
    assert_eq!(surface.size(), (150, 42));

    // The same user's phone defers to their Mac.
    let phone = handle_command(
        &mux,
        relay,
        json_command(json!({
            "cmd": "resize-attached-view", "surface": surface.id, "view": "mobile:p1",
            "identity": {"user_id": "u1", "display_name": "Maya", "device_kind": "iphone",
                         "device_name": "Maya's iPhone"},
            "cols": 54, "rows": 26,
        })),
        &writer,
    )
    .unwrap();
    assert_eq!(phone["participant"], format!("c{relay}/mobile:p1"));
    assert_eq!(phone["accepted"], false);
    assert_eq!(surface.size(), (150, 42));
    let state = handle_command(
        &mux,
        relay,
        json_command(json!({"cmd": "get-size-state", "surface": surface.id})),
        &writer,
    )
    .unwrap();
    assert_eq!(state["self_participant"], format!("c{relay}"));
    let row = state["state"]["participants"]
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["id"] == format!("c{relay}/mobile:p1"))
        .unwrap()
        .clone();
    assert_eq!(row["via"], format!("c{relay}"));
    assert_eq!(row["device_kind"], "iphone");
    assert_eq!(row["counts"], false);
    assert_eq!(row["priority_key"], "u1/iphone");
    let mac = &state["state"]["participants"][0];
    assert_eq!(mac["id"], format!("c{relay}"));
    assert_eq!(mac["user_id"], "u1");
    assert_eq!(mac["device_name"], "Mac Studio");

    // Another user's phone counts and, as the newest view, takes the grid.
    drain_json(&outbound);
    let other = handle_command(
        &mux,
        relay,
        json_command(json!({
            "cmd": "resize-attached-view", "surface": surface.id, "view": "mobile:p2",
            "identity": {"user_id": "u2", "device_kind": "iphone"}, "cols": 40, "rows": 20,
        })),
        &writer,
    )
    .unwrap();
    assert_eq!(other["accepted"], true);
    assert_eq!(surface.size(), (40, 20));
    let published = drain_json(&outbound)
        .into_iter()
        .rfind(|event| event["event"] == "size-state")
        .expect("the attach stream receives size-state");
    assert_eq!(published["surface"], surface.id);
    assert_eq!(published["self_participant"], format!("c{relay}"));
    assert_eq!(published["state"]["owners"], json!([format!("c{relay}/mobile:p2")]));

    // Detaching the sub-view hands the grid to the next owner.
    let detached = handle_command(
        &mux,
        relay,
        json_command(json!({
            "cmd": "detach-attached-view", "surface": surface.id, "view": "mobile:p2",
        })),
        &writer,
    )
    .unwrap();
    assert_eq!(detached["outcome"], "applied");
    assert_eq!(surface.size(), (150, 42));

    assert!(disconnect_client(&mux, relay, false));
    assert!(mux.terminal_size_state(surface.id).unwrap().participants.is_empty());
}

#[test]
fn detach_client_reports_the_kick_reason_and_actor() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let kicker_writer = test_writer();
    let kicker = mux.control_clients.register(ClientTransport::Unix, kicker_writer.clone());
    handle_command(
        &mux,
        kicker,
        json_command(json!({
            "cmd": "set-client-info", "user_id": "u_maya", "display_name": "Maya",
            "device_name": "Mac Studio",
        })),
        &kicker_writer,
    )
    .unwrap();

    let (target_writer, target_outbound) = captured_writer();
    let target = mux.control_clients.register(ClientTransport::Unix, target_writer.clone());
    attach_test_view(&mux, target, surface.id, &target_writer);
    handle_command(
        &mux,
        kicker,
        json_command(json!({"cmd": "detach-client", "client": format!("c{target}")})),
        &kicker_writer,
    )
    .unwrap();
    let detached = drain_json(&target_outbound)
        .into_iter()
        .find(|event| event["event"] == "detached")
        .expect("kicked client receives detached");
    assert_eq!(
        detached,
        json!({
            "event": "detached", "surface": surface.id, "reason": "disconnected-by",
            "by": {"user_id": "u_maya", "display_name": "Maya", "device_name": "Mac Studio"},
        })
    );
    assert!(!mux.control_clients.contains(target));

    // Kicking a relay sub-view detaches only that view.
    let (relay_writer, relay_outbound) = captured_writer();
    let relay = mux.control_clients.register(ClientTransport::Unix, relay_writer.clone());
    attach_test_view(&mux, relay, surface.id, &relay_writer);
    handle_command(
        &mux,
        relay,
        json_command(json!({
            "cmd": "resize-attached-view", "surface": surface.id, "view": "mobile:p1",
            "cols": 54, "rows": 26,
        })),
        &relay_writer,
    )
    .unwrap();
    drain_json(&relay_outbound);
    handle_command(
        &mux,
        kicker,
        json_command(json!({
            "cmd": "detach-client", "client": format!("c{relay}/mobile:p1"),
            "by": {"display_name": "Kai"},
        })),
        &kicker_writer,
    )
    .unwrap();
    let notice = drain_json(&relay_outbound)
        .into_iter()
        .find(|event| event["event"] == "detached")
        .expect("relay receives the sub-view detach");
    assert_eq!(
        notice,
        json!({
            "event": "detached", "surface": surface.id, "reason": "disconnected-by",
            "by": {"display_name": "Kai"}, "view": "mobile:p1",
        })
    );
    assert!(mux.control_clients.contains(relay));
    let state = mux.terminal_size_state(surface.id).unwrap();
    assert_eq!(
        state.participants.iter().map(|row| row.participant.id.clone()).collect::<Vec<_>>(),
        [format!("c{relay}")]
    );
    let error = handle_command(
        &mux,
        kicker,
        json_command(json!({"cmd": "detach-client", "client": format!("c{relay}/gone")})),
        &kicker_writer,
    )
    .unwrap_err();
    assert!(error.to_string().contains("unknown participant"));
}

/// docs/shared-terminal-sizing.md: disconnecting a relay Mac's own view
/// (for example from the phone it relays) detaches that view only. The
/// connection, its byte stream and the phones it relays stay; Reattach
/// restores the view without reconnecting.
#[test]
fn detaching_a_relay_macs_own_view_keeps_its_connection_and_phones() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    mux.pin_latest_size_policy_for_test(surface.id);
    let (writer, outbound) = captured_writer();
    let relay = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    handle_command(
        &mux,
        relay,
        json_command(json!({
            "cmd": "set-client-info", "kind": "mac",
            "capabilities": [SHARED_SIZING_CAPABILITY, SIZING_VIEW_DETACH_CAPABILITY],
            "user_id": "u1", "display_name": "Maya", "device_kind": "mac",
            "device_name": "Maya's MacBook Pro", "device_id": "laptop",
        })),
        &writer,
    )
    .unwrap();
    attach_test_view(&mux, relay, surface.id, &writer);
    mux.resize_surface_for_client(surface.id, relay, 150, 42).unwrap();
    handle_command(
        &mux,
        relay,
        json_command(json!({
            "cmd": "resize-attached-view", "surface": surface.id, "view": "mobile:p1",
            "identity": {"user_id": "u1", "device_kind": "iphone", "device_id": "p1"},
            "cols": 54, "rows": 26,
        })),
        &writer,
    )
    .unwrap();
    let mac = format!("c{relay}");
    let phone = format!("c{relay}/mobile:p1");
    let state = mux.terminal_size_state(surface.id).unwrap();
    assert_eq!(state.participant(&mac).unwrap().priority_key, "u1/mac/laptop");
    assert_eq!(surface.size(), (150, 42));
    drain_json(&outbound);

    // The phone asks its own Mac to disconnect the Mac: the Mac forwards
    // detach-client for its own participant, scoped to this terminal.
    assert!(handle_message(
        &mux,
        relay,
        &json!({
            "id": 1, "cmd": "detach-client", "client": mac, "surface": surface.id,
            "by": {"display_name": "Maya", "device_name": "Maya's iPhone"},
        })
        .to_string(),
        &writer,
    ));
    assert!(mux.control_clients.contains(relay), "the relay connection stays");
    let events = drain_json(&outbound);
    let detached = events.iter().find(|event| event["event"] == "detached").unwrap();
    assert_eq!(
        *detached,
        json!({
            "event": "detached", "surface": surface.id, "reason": "disconnected-by",
            "by": {"display_name": "Maya", "device_name": "Maya's iPhone"}, "scope": "view",
        })
    );
    let state = mux.terminal_size_state(surface.id).unwrap();
    assert!(state.participant(&mac).is_none());
    assert!(state.participant(&phone).unwrap().counts, "the phone no longer defers");
    assert_eq!(state.owners, [phone]);
    assert_eq!(surface.size(), (54, 26));

    // The detached view's own reports and activity do not count.
    mux.resize_surface_for_client(surface.id, relay, 160, 50).unwrap();
    assert!(mux.terminal_size_state(surface.id).unwrap().participant(&mac).is_none());
    assert_eq!(surface.size(), (54, 26));

    // Reattach as a viewer: back without reconnecting, not counting.
    let reattached = handle_command(
        &mux,
        relay,
        json_command(json!({"cmd": "reattach-view", "surface": surface.id, "counts": false})),
        &writer,
    )
    .unwrap();
    assert_eq!(reattached["participant"], mac);
    let state = mux.terminal_size_state(surface.id).unwrap();
    let row = state.participant(&mac).unwrap();
    assert_eq!(row.participant.counts_override, Some(false));
    assert_eq!(
        row.participant.viewport,
        Some(crate::sizing_policy::TerminalGridSize::new(160, 50))
    );
    assert_eq!(surface.size(), (54, 26));
    let again = handle_command(
        &mux,
        relay,
        json_command(json!({"cmd": "reattach-view", "surface": surface.id})),
        &writer,
    )
    .unwrap_err();
    assert!(again.to_string().contains("not detached"));
}

/// A client that did not opt into view detach is still kicked whole, the
/// tmux `detach-client` behavior older Macs and TUIs expect.
#[test]
fn detach_client_kicks_a_client_without_view_detach() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let kicker_writer = test_writer();
    let kicker = mux.control_clients.register(ClientTransport::Unix, kicker_writer.clone());
    let target_writer = test_writer();
    let target = mux.control_clients.register(ClientTransport::Unix, target_writer.clone());
    attach_test_view(&mux, target, surface.id, &target_writer);
    handle_command(
        &mux,
        kicker,
        json_command(json!({
            "cmd": "detach-client", "client": format!("c{target}"), "surface": surface.id,
        })),
        &kicker_writer,
    )
    .unwrap();
    assert!(!mux.control_clients.contains(target));
}

#[test]
fn relay_forwarded_input_counts_as_the_phone_sub_view_activity() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    mux.pin_latest_size_policy_for_test(surface.id);
    let writer = test_writer();
    let relay = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let activity = |view: Option<&str>| {
        let mut request = json!({"cmd": "note-size-activity", "surface": surface.id});
        if let Some(view) = view {
            request["view"] = json!(view);
        }
        handle_command(&mux, relay, json_command(request), &writer)
    };
    // The command is gated on the client capability.
    assert!(activity(None).unwrap_err().to_string().contains(SHARED_SIZING_CAPABILITY));
    handle_command(
        &mux,
        relay,
        json_command(json!({
            "cmd": "set-client-info", "capabilities": [SHARED_SIZING_CAPABILITY],
            "user_id": "u1", "device_kind": "mac",
        })),
        &writer,
    )
    .unwrap();
    attach_test_view(&mux, relay, surface.id, &writer);
    mux.resize_surface_for_client(surface.id, relay, 150, 42).unwrap();
    handle_command(
        &mux,
        relay,
        json_command(json!({
            "cmd": "resize-attached-view", "surface": surface.id, "view": "mobile:p1",
            "identity": {"user_id": "u1", "device_kind": "iphone"}, "cols": 54, "rows": 26,
        })),
        &writer,
    )
    .unwrap();
    let phone = format!("c{relay}/mobile:p1");
    assert_eq!(mux.set_terminal_size_counts(surface.id, &phone, Some(true)), Some(true));

    // The Mac's own activity keeps the grid on the Mac.
    assert_eq!(activity(None).unwrap()["participant"], format!("c{relay}"));
    assert_eq!(surface.size(), (150, 42));
    assert_eq!(mux.terminal_size_state(surface.id).unwrap().owners, [format!("c{relay}")]);

    // Forwarded phone input marks the phone, which then owns the grid.
    let response = activity(Some("mobile:p1")).unwrap();
    assert_eq!(response["participant"], phone);
    assert_eq!(response["changed"], true);
    assert_eq!(surface.size(), (54, 26));
    assert_eq!(mux.terminal_size_state(surface.id).unwrap().owners, [phone]);

    assert!(activity(Some("mobile:gone")).unwrap_err().to_string().contains("unknown participant"));
}

#[test]
fn shared_sizing_is_advertised() {
    assert!(advertised_capabilities(false).contains(&SHARED_SIZING_CAPABILITY));
}

#[test]
fn remote_client_cannot_detach_synthetic_local_client_zero() {
    let mux = test_mux();
    let writer = test_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());

    let error = handle_command(
        &mux,
        client,
        Command::DetachClient { client: DetachClientTarget::Client(0), by: None, surface: None },
        &writer,
    )
    .unwrap_err();

    assert!(error.to_string().contains("unknown client 0"));
    assert!(
        mux.control_clients_json(client)
            .as_array()
            .unwrap()
            .iter()
            .any(|info| { info["client"] == client })
    );
}

#[test]
fn websocket_direct_writer_emits_a_tungstenite_compatible_text_frame() {
    let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
    let client = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
    let (server, _) = listener.accept().unwrap();
    let mut writer = SynchronizedTcpStream::new(server);
    let write = std::thread::spawn(move || {
        writer.write_websocket_text(&"x".repeat(65_536)).unwrap();
    });
    let mut websocket =
        WebSocket::from_raw_socket(client, tungstenite::protocol::Role::Client, None);

    let message = websocket.read().unwrap();

    assert_eq!(message.into_text().unwrap().len(), 65_536);
    write.join().unwrap();
}

#[test]
fn closing_bounded_writer_wakes_a_waiting_drain() {
    let outbound = Arc::new(BoundedOutbound::default());
    let waiting = outbound.clone();
    let drain = std::thread::spawn(move || waiting.recv());

    outbound.close();

    assert!(drain.join().unwrap().is_none());
}

#[test]
fn websocket_overflow_marks_attach_lifecycle() {
    let lifecycle = AttachLifecycle::default();
    let error = std::io::Error::new(std::io::ErrorKind::WouldBlock, "queue full");

    handle_attach_send_error(&lifecycle, &error);

    assert!(lifecycle.is_canceled());
    assert!(lifecycle.overflowed());
}

#[test]
fn identify_and_ping_return_build_metadata() {
    let mux = test_mux();
    let identity =
        handle_command(&mux, mux.local_test_client(0), Command::Identify, &test_writer()).unwrap();
    assert_eq!(identity["app"].as_str(), Some("cmux-tui"));
    assert_eq!(identity["version"].as_str(), Some(env!("CARGO_PKG_VERSION")));
    assert_eq!(identity["protocol"].as_u64(), Some(PROTOCOL_VERSION as u64));
    assert_eq!(identity["build_commit"].as_str(), stamped_build_commit());
    assert_eq!(identity["ghostty_commit"].as_str(), stamped_ghostty_commit());

    let data =
        handle_command(&mux, mux.local_test_client(0), Command::Ping, &test_writer()).unwrap();
    assert_eq!(data["ok"].as_bool(), Some(true));
    assert_eq!(data["version"].as_str(), Some(env!("CARGO_PKG_VERSION")));
    assert_eq!(data["build_commit"].as_str(), stamped_build_commit());
    assert_eq!(data["ghostty_commit"].as_str(), stamped_ghostty_commit());
    assert_eq!(data["protocol"].as_u64(), Some(PROTOCOL_VERSION as u64));
    assert_eq!(identity["daemon_handoff"].as_u64(), Some(1));
    assert!(
        identity["capabilities"].as_array().is_some_and(|capabilities| capabilities
            .iter()
            .any(|capability| capability == DAEMON_HANDOFF_FORCE_CAPABILITY)),
        "the server must advertise forced fenced daemon handoff"
    );
    assert_eq!(STABLE_SPLIT_IDS_PROTOCOL_VERSION, 8);
    assert_eq!(STACK_LAYOUT_PROTOCOL_VERSION, 9);
    assert_eq!(PER_SURFACE_CLIENT_SIZING_PROTOCOL_VERSION, 10);
    assert_eq!(TERMINAL_LIFECYCLE_PROTOCOL_VERSION, 11);
    assert_eq!(LIFECYCLE_READINESS_PROTOCOL_VERSION, 12);
    assert_eq!(PROTOCOL_VERSION, 12);
    assert!(
        identity["capabilities"].as_array().is_some_and(|capabilities| capabilities
            .iter()
            .any(|capability| capability == "browser-pointer-frame-guard-v1")),
        "the server must advertise guarded browser pointer input"
    );
}

#[test]
fn lifecycle_ready_identity_advertises_new_public_protocol() {
    let mux = test_mux();
    mux.mark_server_lifecycle_ready();
    let identity =
        handle_command(&mux, mux.local_test_client(0), Command::Identify, &test_writer()).unwrap();

    assert_eq!(identity["lifecycle_ready"], true);
    assert_eq!(identity["protocol"].as_u64(), Some(12));
    assert_eq!(
        identity["protocol"].as_u64(),
        Some(u64::from(TERMINAL_LIFECYCLE_PROTOCOL_VERSION) + 1)
    );
}

#[test]
fn raw_report_agent_command_commits_public_revision_projection_and_event() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, None).unwrap();
    let revision = mux.with_state(|state| state.resource_revision);
    let epoch = mux.resource_event_epoch();

    let result = handle_command(
        &mux,
        mux.local_test_client(0),
        Command::ReportAgent {
            surface: surface.id,
            state: "working".into(),
            source: "socket".into(),
            session: Some("raw-command".into()),
        },
        &test_writer(),
    )
    .unwrap();

    assert_eq!(result["surface"], surface.id);
    assert_eq!(result["state"], "working");
    assert_eq!(result["source"], "socket");
    assert_eq!(result["session"], "raw-command");
    assert_eq!(mux.with_state(|state| state.resource_revision), revision + 1);
    // A fresh direct report publishes twice on the shared change epoch:
    // its resource commit and its journal echo.
    assert_eq!(mux.resource_event_epoch(), epoch + 2);
    assert_eq!(mux.resource_agent_projection_count_for_test().unwrap(), 1);
    let events = mux.resource_events_after(revision).unwrap();
    assert_eq!(events.batches.len(), 1);
    assert_eq!(events.batches[0].changes[0]["resource"], "agent");
    assert_eq!(events.batches[0].changes[0]["value"]["source_session"], "raw-command");
}

#[test]
fn raw_report_agent_command_rejects_internal_projection_sources() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, None).unwrap();

    for source in ["plugin", "detected"] {
        let error = handle_command(
            &mux,
            mux.local_test_client(0),
            Command::ReportAgent {
                surface: surface.id,
                state: "working".into(),
                source: source.into(),
                session: Some("raw-command".into()),
            },
            &test_writer(),
        )
        .unwrap_err();
        assert!(error.to_string().contains("bad source"), "{source}: {error}");
    }

    assert_eq!(mux.resource_agent_projection_count_for_test().unwrap(), 0);
}

#[test]
fn guarded_browser_pointer_commands_require_a_numeric_frame_guard() {
    for cmd in ["browser-mouse-guarded", "browser-wheel-guarded"] {
        let mut request = json!({
            "id": 1,
            "cmd": cmd,
            "surface": 7,
            "x_px": 1.0,
            "y_px": 2.0,
            "frame_seq": 9,
        });
        if cmd.starts_with("browser-mouse") {
            request["kind"] = json!("down");
        } else {
            request["delta_y_px"] = json!(3.0);
        }
        assert!(
            serde_json::from_value::<Request>(request.clone()).is_ok(),
            "{cmd} must accept a numeric frame guard"
        );

        request.as_object_mut().unwrap().remove("frame_seq");
        assert!(
            serde_json::from_value::<Request>(request.clone()).is_err(),
            "{cmd} must reject a missing frame guard"
        );

        request["frame_seq"] = Value::Null;
        assert!(
            serde_json::from_value::<Request>(request).is_err(),
            "{cmd} must reject a null frame guard"
        );
    }
}

#[test]
fn legacy_browser_pointer_schema_remains_compatible() {
    for cmd in ["browser-mouse", "browser-wheel"] {
        let mut request = json!({
            "id": 1,
            "cmd": cmd,
            "surface": 7,
            "x_px": 1.0,
            "y_px": 2.0,
        });
        if cmd == "browser-mouse" {
            request["kind"] = json!("down");
        } else {
            request["delta_y_px"] = json!(3.0);
        }
        assert!(
            serde_json::from_value::<Request>(request.clone()).is_ok(),
            "{cmd} must keep accepting the protocol-10 legacy schema"
        );

        request["frame_seq"] = Value::Null;
        assert!(
            serde_json::from_value::<Request>(request).is_ok(),
            "{cmd} must keep accepting a legacy null frame guard"
        );
    }
}

#[test]
fn browser_frame_presentation_requires_a_numeric_guard_and_capability() {
    let request = json!({
        "id": 1,
        "cmd": "browser-frame-presented",
        "surface": 7,
        "frame_seq": 9,
    });
    assert!(serde_json::from_value::<Request>(request.clone()).is_ok());
    let mut missing_guard = request.clone();
    missing_guard.as_object_mut().unwrap().remove("frame_seq");
    assert!(serde_json::from_value::<Request>(missing_guard).is_err());
    let mut null_guard = request;
    null_guard["frame_seq"] = Value::Null;
    assert!(serde_json::from_value::<Request>(null_guard).is_err());

    let mux = test_mux();
    let writer = test_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let error = handle_command(
        &mux,
        client,
        Command::BrowserFramePresented { surface: 99_999, frame_seq: 9 },
        &writer,
    )
    .unwrap_err();
    assert!(error.to_string().contains(GUARDED_BROWSER_POINTER_CAPABILITY));
}

#[test]
fn parsed_legacy_browser_pointer_still_requires_frame_authority() {
    for cmd in ["browser-mouse", "browser-wheel"] {
        let mut request = json!({
            "id": 1,
            "cmd": cmd,
            "surface": 7,
            "x_px": 1.0,
            "y_px": 2.0,
        });
        if cmd == "browser-mouse" {
            request["kind"] = json!("down");
        } else {
            request["delta_y_px"] = json!(3.0);
        }
        request["frame_seq"] = Value::Null;
        let request = serde_json::from_value::<Request>(request).expect("legacy schema must parse");
        let mux = test_mux();
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        assert!(handle_message(
            &mux,
            client,
            &json!({
                "id": 1,
                "cmd": "set-client-info",
                "capabilities": [GUARDED_BROWSER_POINTER_CAPABILITY],
            })
            .to_string(),
            &writer,
        ));
        let error = handle_command(&mux, client, request.cmd, &writer).unwrap_err().to_string();
        assert!(
            error.contains("requires a frame guard"),
            "{cmd} with a null frame_seq must fail closed before surface lookup: {error}"
        );
    }
}

#[test]
fn guarded_browser_capability_and_pointer_owner_are_connection_stable() {
    let mux = test_mux();
    let writer = test_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());

    assert!(!mux.control_clients.supports_capability(client, GUARDED_BROWSER_POINTER_CAPABILITY));
    assert!(handle_message(
        &mux,
        client,
        &json!({
            "id": 1,
            "cmd": "set-client-info",
            "kind": "tui",
            "capabilities": [GUARDED_BROWSER_POINTER_CAPABILITY],
        })
        .to_string(),
        &writer,
    ));
    assert!(mux.control_clients.supports_capability(client, GUARDED_BROWSER_POINTER_CAPABILITY));
    assert_eq!(
        mux.control_clients.browser_pointer_owner(client).unwrap(),
        BrowserPointerOwner::Client(client)
    );
    assert!(handle_message(
        &mux,
        client,
        &json!({
            "id": 2,
            "cmd": "set-client-info",
            "capabilities": [],
        })
        .to_string(),
        &writer,
    ));
    assert!(
        mux.control_clients.supports_capability(client, GUARDED_BROWSER_POINTER_CAPABILITY),
        "connection-scoped pointer capability must not be withdrawn after admission"
    );
    assert_eq!(
        mux.control_clients.browser_pointer_owner(client).unwrap(),
        BrowserPointerOwner::Client(client),
        "metadata replacement must not change an already claimed pointer owner"
    );

    let legacy = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    assert_eq!(
        mux.control_clients.browser_pointer_owner(legacy).unwrap(),
        BrowserPointerOwner::Legacy
    );
    assert!(handle_message(
        &mux,
        legacy,
        &json!({
            "id": 3,
            "cmd": "set-client-info",
            "capabilities": [GUARDED_BROWSER_POINTER_CAPABILITY],
        })
        .to_string(),
        &writer,
    ));
    assert_eq!(
        mux.control_clients.browser_pointer_owner(legacy).unwrap(),
        BrowserPointerOwner::Legacy,
        "a connection cannot change pointer identity after its first pointer command"
    );
}

#[test]
fn creation_attachment_identity_rejects_wrong_generation_and_terminal() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, None).unwrap();
    let writer = test_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let terminal = surface.terminal_public_id().unwrap().to_string();
    for (generation, terminal, expected) in [
        ("old-generation".to_string(), terminal.clone(), "attachment_generation_mismatch"),
        (
            mux.registry_identity().1,
            "term_00000000000000000000000000000000".to_string(),
            "attachment_terminal_mismatch",
        ),
    ] {
        let command = Command::AttachSurface {
            surface: Some(surface.id),
            mode: None,
            cols: None,
            rows: None,
            expected_generation: Some(generation),
            expected_terminal_id: Some(terminal),
            snapshot: Default::default(),
        };
        let error = handle_command(&mux, client, command, &writer).unwrap_err();
        assert!(error.to_string().contains(expected), "{error:#}");
    }
    let command = Command::AttachSurface {
        surface: None,
        mode: None,
        cols: None,
        rows: None,
        expected_generation: Some(mux.registry_identity().1),
        expected_terminal_id: Some(terminal),
        snapshot: Default::default(),
    };
    handle_command(&mux, client, command, &writer).unwrap();
    disconnect_client(&mux, client, false);
    mux.shutdown();
}

#[test]
fn guarded_browser_attach_rejects_a_late_capability_upgrade() {
    let mux = test_mux();
    let writer = test_writer();
    let surface = mux.new_browser_tab("about:blank".to_string(), None, Some((80, 24))).unwrap();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    assert_eq!(
        mux.control_clients.browser_pointer_owner(client).unwrap(),
        BrowserPointerOwner::Legacy
    );
    assert!(handle_message(
        &mux,
        client,
        &json!({
            "id": 1,
            "cmd": "set-client-info",
            "capabilities": [GUARDED_BROWSER_POINTER_CAPABILITY],
        })
        .to_string(),
        &writer,
    ));

    let attach = handle_command(
        &mux,
        client,
        Command::AttachSurface {
            surface: Some(surface.id),
            mode: None,
            cols: None,
            rows: None,
            expected_generation: None,
            expected_terminal_id: None,
            snapshot: Default::default(),
        },
        &writer,
    );
    mux.shutdown();

    let error = attach.expect_err("a legacy pointer owner must not gain a guarded attach");
    assert!(
        error.to_string().contains(GUARDED_BROWSER_POINTER_CAPABILITY),
        "late capability upgrade must return the guarded-pointer admission error: {error:#}"
    );
}
