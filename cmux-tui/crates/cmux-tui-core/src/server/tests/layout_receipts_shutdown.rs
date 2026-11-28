//! Split and viewport layout commands, creation receipts, attached resizes, and daemon shutdown/handoff.

use super::*;

#[test]
fn split_ids_serialize_stably_and_both_ratio_commands_work() {
    let mux = test_mux();
    let first = mux.new_workspace(None, None).unwrap();
    let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let second = mux.split(first_pane, SplitDir::Right, None).unwrap();
    let second_pane = mux.with_state(|state| state.pane_of(second.id).unwrap());

    let before =
        handle_command(&mux, mux.local_test_client(0), Command::ListWorkspaces, &test_writer())
            .unwrap();
    let split = before["workspaces"][0]["screens"][0]["layout"]["split"]
        .as_u64()
        .expect("protocol v8 split id");

    let request: Request = serde_json::from_value(json!({
        "id": 1,
        "cmd": "set-split-ratio",
        "split": split,
        "ratio": 0.7
    }))
    .unwrap();
    handle_command(&mux, mux.local_test_client(0), request.cmd, &test_writer()).unwrap();
    let after_exact =
        handle_command(&mux, mux.local_test_client(0), Command::ListWorkspaces, &test_writer())
            .unwrap();
    assert_eq!(after_exact["workspaces"][0]["screens"][0]["layout"]["split"], split);
    let exact_ratio = after_exact["workspaces"][0]["screens"][0]["layout"]["ratio"]
        .as_f64()
        .expect("split ratio");
    assert!((exact_ratio - 0.7).abs() < 1e-6);

    let legacy: Request = serde_json::from_value(json!({
        "id": 2,
        "cmd": "set-ratio",
        "pane": second_pane,
        "dir": "right",
        "ratio": 0.3
    }))
    .unwrap();
    handle_command(&mux, mux.local_test_client(0), legacy.cmd, &test_writer()).unwrap();
    let after_legacy =
        handle_command(&mux, mux.local_test_client(0), Command::ListWorkspaces, &test_writer())
            .unwrap();
    assert_eq!(after_legacy["workspaces"][0]["screens"][0]["layout"]["split"], split);
    let legacy_ratio = after_legacy["workspaces"][0]["screens"][0]["layout"]["ratio"]
        .as_f64()
        .expect("split ratio");
    assert!((legacy_ratio - 0.3).abs() < 1e-6);

    let unknown: Request = serde_json::from_value(json!({
        "cmd": "set-split-ratio",
        "split": 999999,
        "ratio": 0.5
    }))
    .unwrap();
    assert_eq!(
        handle_command(&mux, mux.local_test_client(0), unknown.cmd, &test_writer())
            .unwrap_err()
            .to_string(),
        "unknown split 999999"
    );
}

#[test]
fn workspace_tree_exposes_stable_resource_ids_for_startup_attach_and_receipts() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, None).unwrap();
    let expected = match &surface.resource_identity().unwrap().content_id {
        ContentPublicId::Terminal(id) => id.as_str(),
        ContentPublicId::Browser(_) => panic!("workspace started with a browser"),
    };

    let tree =
        handle_command(&mux, mux.local_test_client(0), Command::ListWorkspaces, &test_writer())
            .unwrap();

    for (path, prefix) in [
        (&tree["workspaces"][0]["resource_id"], "ws_"),
        (&tree["workspaces"][0]["screens"][0]["resource_id"], "screen_"),
        (&tree["workspaces"][0]["screens"][0]["panes"][0]["resource_id"], "pane_"),
    ] {
        assert!(path.as_str().is_some_and(|id| id.starts_with(prefix)));
    }
    assert_eq!(
        tree["workspaces"][0]["screens"][0]["panes"][0]["tabs"][0]["terminal_resource_id"],
        expected
    );
    mux.shutdown();
}

#[test]
fn projected_split_ratio_range_failure_is_not_reported_as_unknown() {
    let mux = test_mux();
    let first = mux.new_workspace(None, Some((80, 22))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    mux.new_pane_right(pane, 0.5, Some((38, 22))).unwrap();
    let split =
        handle_command(&mux, mux.local_test_client(0), Command::ListWorkspaces, &test_writer())
            .unwrap()["workspaces"][0]["screens"][0]["layout"]["split"]
            .as_u64()
            .expect("viewport projection exposes a stable split");
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });

    handle_message(
        &mux,
        mux.local_test_client(7),
        &json!({
            "id": 21,
            "cmd": "set-split-ratio",
            "split": split,
            "ratio": 0.25
        })
        .to_string(),
        &writer,
    );

    let response: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
    assert_eq!(response["id"], 21);
    assert_eq!(response["ok"], false);
    assert_eq!(response["error_code"], LayoutRatioError::OUT_OF_RANGE_CODE);
    assert!(response["error"].as_str().unwrap().contains("width must be between"));
    assert!(!response["error"].as_str().unwrap().contains("unknown split"));
}

#[test]
fn viewport_width_failures_have_stable_error_codes() {
    let mux = test_mux();
    let first = mux.new_workspace(None, Some((80, 22))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });

    for (id, width, code) in [
        (31, 0.5, ViewportWidthError::COLUMN_MISSING_CODE),
        (32, 1.1, ViewportWidthError::OUT_OF_RANGE_CODE),
    ] {
        handle_message(
            &mux,
            mux.local_test_client(7),
            &json!({
                "id": id,
                "cmd": "set-viewport-pane-width",
                "pane": pane,
                "width": width
            })
            .to_string(),
            &writer,
        );
        let response: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        assert_eq!(response["id"], id);
        assert_eq!(response["ok"], false);
        assert_eq!(response["error_code"], code);
    }

    handle_message(
        &mux,
        mux.local_test_client(7),
        &json!({
            "id": 33,
            "cmd": "new-pane-right",
            "pane": pane,
            "width": 1.1
        })
        .to_string(),
        &writer,
    );
    let response: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
    assert_eq!(response["id"], 33);
    assert_eq!(response["ok"], false);
    assert_eq!(response["error_code"], ViewportWidthError::OUT_OF_RANGE_CODE);
}

#[test]
fn create_terminal_rejects_partial_dimensions() {
    let mux = test_mux();
    let workspace = mux.create_empty_workspace(None, None, None).unwrap().workspace;

    for (cols, rows) in [(Some(80), None), (None, Some(24))] {
        let error = handle_command(
            &mux,
            mux.local_test_client(0),
            Command::CreateTerminal {
                workspace: Some(workspace),
                key: None,
                argv: None,
                shell_args: None,
                command: None,
                cwd: None,
                name: None,
                cols,
                rows,
                terminal_id: None,
                env: None,
                keep: false,
                detached: false,
                mutation: MutationRequest::default(),
            },
            &test_writer(),
        )
        .unwrap_err();

        assert_eq!(error.to_string(), "create-terminal cols and rows must be supplied together");
    }
}

#[test]
fn mutation_specific_raw_terminal_create_updates_public_projection_once() {
    let mux = test_mux();
    let workspace = mux.create_empty_workspace(None, None, None).unwrap().workspace;
    let command = || Command::CreateTerminal {
        workspace: Some(workspace),
        key: None,
        argv: None,
        shell_args: None,
        command: None,
        cwd: None,
        name: Some("raw terminal".to_string()),
        cols: Some(80),
        rows: Some(24),
        terminal_id: Some("00000000000040008000000000000001".to_string()),
        env: None,
        keep: false,
        detached: false,
        mutation: MutationRequest {
            origin: Some("raw-projection-test".to_string()),
            mutation_id: Some("raw-terminal-create-once".to_string()),
            expected_generation: None,
            expected_revision: None,
        },
    };

    let first = handle_command(&mux, mux.local_test_client(0), command(), &test_writer()).unwrap();
    assert_eq!(first["replayed"], false);
    let first_snapshot = crate::resource_api::public_session_snapshot(&mux).unwrap();
    assert_eq!(first_snapshot["screens"].as_array().unwrap().len(), 1);
    assert_eq!(first_snapshot["panes"].as_array().unwrap().len(), 1);
    assert_eq!(first_snapshot["tabs"].as_array().unwrap().len(), 1);
    assert_eq!(first_snapshot["terminals"].as_array().unwrap().len(), 1);
    assert_eq!(first_snapshot["tabs"][0]["content_id"], first_snapshot["terminals"][0]["id"]);
    let first_revision = first_snapshot["cursor"]["revision"].clone();

    let replay = handle_command(&mux, mux.local_test_client(0), command(), &test_writer()).unwrap();
    assert_eq!(replay["replayed"], true);
    let replayed_snapshot = crate::resource_api::public_session_snapshot(&mux).unwrap();
    assert_eq!(replayed_snapshot["cursor"]["revision"], first_revision);
    assert_eq!(replayed_snapshot["terminals"].as_array().unwrap().len(), 1);
    mux.shutdown();
}

#[test]
fn creation_receipts_replay_exact_surfaces_across_control_connections() {
    let mux = test_mux();
    let original = mux.new_workspace(None, Some((100, 30))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(original.id).unwrap());
    let selectors = mux.resource_selectors_for_pane(Some(pane)).unwrap();
    let receipt = "split-receipt-00000001";
    let origin = "tui-receipt-test";
    let command = |direction: &str, idempotency_key: &str| {
        Command::CreateSurfaceWithReceipt(Box::new(CreateSurfaceWithReceiptRequest {
            operation: format!("split-{direction}"),
            origin: origin.to_string(),
            receipt: receipt.to_string(),
            idempotency_key: Some(idempotency_key.to_string()),
            selectors: Some(selectors.clone()),
            selector_fallbacks: Vec::new(),
            pane: Some(pane),
            workspace: None,
            argv: None,
            cwd: None,
            url: None,
            width: None,
            cols: Some(100),
            rows: Some(30),
        }))
    };
    let register = |writer: &MessageWriter, attempt_keys: bool| {
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let mut capabilities = vec![CREATION_RECEIPTS_CAPABILITY.to_string()];
        if attempt_keys {
            capabilities.push(CREATION_ATTEMPT_KEYS_CAPABILITY.to_string());
        }
        handle_command(
            &mux,
            client,
            Command::SetClientInfo {
                name: Some("receipt test".to_string()),
                kind: Some("tui".to_string()),
                capabilities: Some(capabilities),
                user_id: None,
                display_name: None,
                device_kind: None,
                device_name: None,
                device_id: None,
            },
            writer,
        )
        .unwrap();
        client
    };

    let legacy_writer = test_writer();
    let legacy_client = register(&legacy_writer, false);
    let capability_error = handle_command(
        &mux,
        legacy_client,
        command("right", "split-attempt-unsupported"),
        &legacy_writer,
    )
    .unwrap_err();
    assert!(capability_error.to_string().contains(CREATION_ATTEMPT_KEYS_CAPABILITY));
    assert!(disconnect_client(&mux, legacy_client, true));

    let first_writer = test_writer();
    let first_client = register(&first_writer, true);
    let first = handle_command(
        &mux,
        first_client,
        command("right", "split-attempt-00000001"),
        &first_writer,
    )
    .unwrap();
    assert_eq!(first["replayed"], false);
    let created = first["surface"].as_u64().expect("creation omitted its surface");
    let snapshot = crate::resource_api::public_session_snapshot(&mux).unwrap();
    assert_eq!(snapshot["panes"].as_array().unwrap().len(), 2);

    let replay = handle_command(
        &mux,
        first_client,
        command("right", "split-attempt-00000001"),
        &first_writer,
    )
    .unwrap();
    assert_eq!(replay["replayed"], true);
    assert_eq!(replay["surface"].as_u64(), Some(created));
    assert_eq!(
        crate::resource_api::public_session_snapshot(&mux).unwrap()["panes"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
    assert!(mux.close_pane(pane).unwrap());
    assert!(mux.with_state(|state| state.pane_of(created).is_some()));
    assert!(disconnect_client(&mux, first_client, true));

    let second_writer = test_writer();
    let second_client = register(&second_writer, true);
    let reconnect_replay = handle_command(
        &mux,
        second_client,
        command("right", "split-attempt-00000002"),
        &second_writer,
    )
    .unwrap();
    assert_eq!(reconnect_replay["replayed"], true);
    assert_eq!(reconnect_replay["surface"].as_u64(), Some(created));

    let conflict = handle_command(
        &mux,
        second_client,
        command("down", "split-attempt-00000003"),
        &second_writer,
    )
    .unwrap_err();
    assert!(
        conflict.to_string().contains("bound to different semantics"),
        "unexpected receipt conflict: {conflict:#}"
    );
    assert_eq!(
        crate::resource_api::public_session_snapshot(&mux).unwrap()["panes"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    assert!(disconnect_client(&mux, second_client, true));
    mux.shutdown();
}

#[test]
fn browser_receipt_targets_an_exact_empty_workspace_without_focus_state() {
    let mux = test_mux();
    let workspace = mux.create_empty_workspace(None, None, None).unwrap().workspace;
    let selectors = mux.resource_selectors_for_workspace(Some(workspace)).unwrap();
    let writer = test_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    handle_command(
        &mux,
        client,
        Command::SetClientInfo {
            name: Some("native browser bootstrap".to_string()),
            kind: Some("native-browser".to_string()),
            capabilities: Some(vec![CREATION_RECEIPTS_CAPABILITY.to_string()]),
            user_id: None,
            display_name: None,
            device_kind: None,
            device_name: None,
            device_id: None,
        },
        &writer,
    )
    .unwrap();
    let command = || {
        Command::CreateSurfaceWithReceipt(Box::new(CreateSurfaceWithReceiptRequest {
            operation: "new-browser-tab".to_string(),
            origin: "native-browser-bootstrap-test".to_string(),
            receipt: "browser-workspace-receipt-00000001".to_string(),
            idempotency_key: None,
            selectors: Some(selectors.clone()),
            selector_fallbacks: Vec::new(),
            pane: None,
            workspace: None,
            argv: None,
            cwd: None,
            url: Some("about:blank".to_string()),
            width: None,
            cols: None,
            rows: None,
        }))
    };

    let first = handle_command(&mux, client, command(), &writer).unwrap();
    assert_eq!(first["replayed"], false);
    let surface = first["surface"].as_u64().expect("creation omitted its surface");
    let snapshot = crate::resource_api::public_session_snapshot(&mux).unwrap();
    assert_eq!(snapshot["workspaces"].as_array().unwrap().len(), 1);
    assert_eq!(snapshot["screens"].as_array().unwrap().len(), 1);
    assert_eq!(snapshot["panes"].as_array().unwrap().len(), 1);
    assert_eq!(snapshot["tabs"].as_array().unwrap().len(), 1);
    assert_eq!(snapshot["tabs"][0]["content_kind"], "browser");

    let replay = handle_command(&mux, client, command(), &writer).unwrap();
    assert_eq!(replay["replayed"], true);
    assert_eq!(replay["surface"].as_u64(), Some(surface));
    assert_eq!(
        crate::resource_api::public_session_snapshot(&mux).unwrap()["tabs"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    mux.close_surface(surface).unwrap();
    mux.shutdown();
}

#[test]
fn creation_selector_fallbacks_are_negotiated_atomic_and_durably_replayed() {
    let mux = test_mux();
    let fallback = mux.new_workspace(None, Some((100, 30))).unwrap();
    let fallback_pane = mux.with_state(|state| state.pane_of(fallback.id).unwrap());
    let primary = mux.split(fallback_pane, SplitDir::Right, Some((50, 30))).unwrap();
    let primary_pane = mux.with_state(|state| state.pane_of(primary.id).unwrap());
    let primary_selectors = mux.resource_selectors_for_pane(Some(primary_pane)).unwrap();
    let fallback_selectors = mux.resource_selectors_for_pane(Some(fallback_pane)).unwrap();
    assert!(mux.close_pane(primary_pane).unwrap());

    let command = || {
        Command::CreateSurfaceWithReceipt(Box::new(CreateSurfaceWithReceiptRequest {
            operation: "split-right".to_string(),
            origin: "tui-fallback-test".to_string(),
            receipt: "split-fallback-receipt-00000001".to_string(),
            idempotency_key: None,
            selectors: Some(primary_selectors.clone()),
            selector_fallbacks: vec![fallback_selectors.clone()],
            pane: Some(primary_pane),
            workspace: None,
            argv: None,
            cwd: None,
            url: None,
            width: None,
            cols: Some(50),
            rows: Some(30),
        }))
    };
    let register = |capabilities: &[&str], writer: &MessageWriter| {
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        handle_command(
            &mux,
            client,
            Command::SetClientInfo {
                name: Some("fallback receipt test".to_string()),
                kind: Some("tui".to_string()),
                capabilities: Some(
                    capabilities.iter().map(|capability| (*capability).to_string()).collect(),
                ),
                user_id: None,
                display_name: None,
                device_kind: None,
                device_name: None,
                device_id: None,
            },
            writer,
        )
        .unwrap();
        client
    };

    let old_writer = test_writer();
    let old_client = register(&[CREATION_RECEIPTS_CAPABILITY], &old_writer);
    let error = handle_command(&mux, old_client, command(), &old_writer).unwrap_err();
    assert!(error.to_string().contains(CREATION_SELECTOR_FALLBACKS_CAPABILITY));
    assert!(disconnect_client(&mux, old_client, true));

    let first_writer = test_writer();
    let first_client = register(
        &[CREATION_RECEIPTS_CAPABILITY, CREATION_SELECTOR_FALLBACKS_CAPABILITY],
        &first_writer,
    );
    let first = handle_command(&mux, first_client, command(), &first_writer).unwrap();
    assert_eq!(first["replayed"], false);
    let created = first["surface"].as_u64().expect("creation omitted its surface");
    assert!(mux.with_state(|state| state.pane_of(created).is_some()));
    assert!(mux.close_pane(fallback_pane).unwrap());
    assert!(disconnect_client(&mux, first_client, true));

    let replay_writer = test_writer();
    let replay_client = register(
        &[CREATION_RECEIPTS_CAPABILITY, CREATION_SELECTOR_FALLBACKS_CAPABILITY],
        &replay_writer,
    );
    let replay = handle_command(&mux, replay_client, command(), &replay_writer).unwrap();
    assert_eq!(replay["replayed"], true);
    assert_eq!(replay["surface"].as_u64(), Some(created));
    assert!(disconnect_client(&mux, replay_client, true));
    mux.close_surface(created).unwrap();
    mux.shutdown();
}

#[test]
fn attached_terminal_resizes_follow_the_latest_view_until_claimed() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    mux.pin_latest_size_policy_for_test(surface.id);

    let first_writer = test_writer();
    let first_stream = first_writer.start_stream(&attach_overflow_json(surface.id)).unwrap();
    let first = mux.control_clients.register(ClientTransport::Unix, first_writer.clone());
    mux.control_clients.attach_surface(first, surface.id, first_stream.clone()).unwrap();
    mux.control_clients.commit_surface(first, surface.id, first_stream.id, None).unwrap();

    let second_writer = test_writer();
    let second_stream = second_writer.start_stream(&attach_overflow_json(surface.id)).unwrap();
    let second = mux.control_clients.register(ClientTransport::Unix, second_writer.clone());
    mux.control_clients.attach_surface(second, surface.id, second_stream.clone()).unwrap();
    mux.control_clients.commit_surface(second, surface.id, second_stream.id, None).unwrap();

    let first_result = handle_command(
        &mux,
        first,
        Command::ResizeSurface { surface: surface.id, cols: 100, rows: 30 },
        &first_writer,
    )
    .unwrap();
    assert_eq!(first_result["accepted"].as_bool(), Some(true));
    assert_eq!(surface.size(), (100, 30));

    let second_result = handle_command(
        &mux,
        second,
        Command::ResizeSurface { surface: surface.id, cols: 132, rows: 44 },
        &second_writer,
    )
    .unwrap();
    assert_eq!(second_result["accepted"].as_bool(), Some(true));
    assert_eq!(surface.size(), (132, 44));

    handle_command(
        &mux,
        first,
        Command::SetClientSizing {
            surface: surface.id,
            client: Some(first),
            enabled: true,
            exclusive: true,
        },
        &first_writer,
    )
    .unwrap();
    assert_eq!(surface.size(), (100, 30));
    assert!(mux.client_size_participates(surface.id, first));
    assert!(!mux.client_size_participates(surface.id, second));

    let clients = mux.control_clients.list_json(first);
    let clients = clients.as_array().unwrap();
    let recorded_size = |client: u64| {
        let record =
            clients.iter().find(|record| record["client"].as_u64() == Some(client)).unwrap();
        let size = record["sizes"].as_array().unwrap().first().unwrap();
        (size["cols"].as_u64().unwrap(), size["rows"].as_u64().unwrap())
    };
    assert_eq!(recorded_size(first), (100, 30));
    assert_eq!(recorded_size(second), (132, 44));
}

#[test]
fn resize_after_attached_surface_close_is_superseded() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let surface_id = surface.id;
    let writer = test_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let stream = writer.start_stream(&attach_overflow_json(surface_id)).unwrap();
    mux.control_clients.attach_surface(client, surface_id, stream.clone()).unwrap();
    mux.control_clients.commit_surface(client, surface_id, stream.id, None).unwrap();

    mux.close_surface(surface_id).unwrap();
    let response = handle_command(
        &mux,
        client,
        Command::ResizeSurface { surface: surface_id, cols: 100, rows: 30 },
        &writer,
    )
    .expect("a late resize from a retired attachment is not an unknown-surface error");

    assert_eq!(response["outcome"], "superseded");
    assert_eq!(response["accepted"], false);
    mux.shutdown();
}

#[test]
fn daemon_shutdown_is_local_fenced_and_queues_ack_first() {
    let rejected = test_mux();
    rejected.mark_server_lifecycle_ready();
    let rejected_outbound = Arc::new(BoundedOutbound::default());
    let rejected_writer =
        MessageWriter::new(QueuedSink { outbound: rejected_outbound.clone(), control: None });
    let websocket =
        rejected.control_clients.register(ClientTransport::WebSocket, rejected_writer.clone());
    let (_, generation) = rejected.registry_identity();
    assert!(handle_message(
        &rejected,
        websocket,
        &json!({
            "id": 91,
            "cmd": "shutdown-daemon",
            "pid": std::process::id(),
            "generation": generation,
        })
        .to_string(),
        &rejected_writer,
    ));
    let response: Value = serde_json::from_str(&rejected_outbound.try_pop().unwrap()).unwrap();
    assert_eq!(response["ok"], false);
    assert!(response["error"].as_str().unwrap().contains("trusted local"));
    assert!(!rejected.daemon_shutdown_requested());

    let local = rejected.control_clients.register(ClientTransport::Unix, rejected_writer.clone());
    assert!(handle_message(
        &rejected,
        local,
        &json!({
            "id": 92,
            "cmd": "shutdown-daemon",
            "pid": std::process::id().wrapping_add(1),
            "generation": generation,
        })
        .to_string(),
        &rejected_writer,
    ));
    let response: Value = serde_json::from_str(&rejected_outbound.try_pop().unwrap()).unwrap();
    assert_eq!(response["ok"], false);
    assert!(response["error"].as_str().unwrap().contains("pid changed"));
    assert!(!rejected.daemon_shutdown_requested());

    assert!(handle_message(
        &rejected,
        local,
        &json!({
            "id": 93,
            "cmd": "shutdown-daemon",
            "pid": std::process::id(),
            "generation": "stale-generation",
        })
        .to_string(),
        &rejected_writer,
    ));
    let response: Value = serde_json::from_str(&rejected_outbound.try_pop().unwrap()).unwrap();
    assert_eq!(response["ok"], false);
    assert!(response["error"].as_str().unwrap().contains("generation changed"));
    assert!(!rejected.daemon_shutdown_requested());

    let accepted = test_mux();
    accepted.mark_server_lifecycle_ready();
    let accepted_outbound = Arc::new(BoundedOutbound::default());
    let accepted_writer =
        MessageWriter::new(QueuedSink { outbound: accepted_outbound.clone(), control: None });
    let local = accepted.control_clients.register(ClientTransport::Unix, accepted_writer.clone());
    let (interactive_writer, interactive_outbound) = captured_writer();
    let interactive = accepted.control_clients.register(ClientTransport::Unix, interactive_writer);
    let (_, generation) = accepted.registry_identity();
    assert!(handle_message(
        &accepted,
        local,
        &json!({
            "id": 94,
            "cmd": "shutdown-daemon",
            "pid": std::process::id(),
            "generation": generation,
        })
        .to_string(),
        &accepted_writer,
    ));

    // `handle_message` queues this response before it flips the shutdown
    // flag, so observing the requested state implies the ACK is already
    // available to the connection's writer thread.
    assert!(accepted.daemon_shutdown_requested());
    let response: Value = serde_json::from_str(&accepted_outbound.try_pop().unwrap()).unwrap();
    assert_eq!(response["ok"], true);
    assert_eq!(response["data"]["accepted"], true);
    assert_eq!(response["data"]["pid"], std::process::id());
    assert_eq!(response["data"]["generation"], generation);
    assert!(accepted.control_clients.contains(local));
    assert!(!accepted.control_clients.contains(interactive));
    let requester_shutdown = pop_json(&accepted_outbound);
    assert_eq!(requester_shutdown["event"], DAEMON_SHUTDOWN_EVENT);
    let shutdown = pop_json(&interactive_outbound);
    assert_eq!(shutdown["event"], DAEMON_SHUTDOWN_EVENT);
}

#[test]
fn daemon_shutdown_waits_for_ack_flush_before_disconnecting_the_owner() {
    let mux = test_mux();
    mux.mark_server_lifecycle_ready();
    let (writer, outbound, flush_entered, release_flush) = blocking_flush_writer();
    let requester = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let interactive = mux.control_clients.register(ClientTransport::Unix, test_writer());
    let (_, generation) = mux.registry_identity();
    let request = json!({
        "id": 97,
        "cmd": "shutdown-daemon",
        "pid": std::process::id(),
        "generation": generation,
    })
    .to_string();
    let worker_mux = mux.clone();
    let worker =
        std::thread::spawn(move || handle_message(&worker_mux, requester, &request, &writer));

    flush_entered
        .recv_timeout(Duration::from_secs(2))
        .expect("shutdown did not wait for the response flush");
    assert!(!mux.daemon_shutdown_requested());
    assert!(matches!(
        mux.control_clients.state.try_lock(),
        Err(std::sync::TryLockError::WouldBlock)
    ));

    release_flush.send(()).unwrap();
    flush_entered
        .recv_timeout(Duration::from_secs(2))
        .expect("shutdown did not flush the requester shutdown notice");
    assert!(!mux.daemon_shutdown_requested());
    assert!(mux.control_clients.daemon_handoff_pending());
    release_flush.send(()).unwrap();
    assert!(worker.join().unwrap());
    assert!(mux.daemon_shutdown_requested());
    assert!(mux.control_clients.contains(requester));
    assert!(!mux.control_clients.contains(interactive));
    let response = pop_json(&outbound);
    assert_eq!(response["ok"], true);
    let shutdown = pop_json(&outbound);
    assert_eq!(shutdown["event"], DAEMON_SHUTDOWN_EVENT);
    assert_eq!(response["data"]["accepted"], true);
}

/// Replies can arrive out of order, so a client matches every reply to
/// its request by id. A request the server cannot decode must still echo
/// the id it carried, or the client hands the error to the wrong request.
#[test]
fn undecodable_requests_reply_with_their_request_id() {
    let mux = test_mux();
    mux.mark_server_lifecycle_ready();
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));

    for (message, id) in [
        (json!({"id": 41, "cmd": "no-such-command"}).to_string(), json!(41)),
        (
            json!({"id": "text-id", "cmd": "new-tab", "pane": "not-a-number"}).to_string(),
            json!("text-id"),
        ),
        (
            json!({"id": {"nested": [1, 2]}, "cmd": "rename-workspace"}).to_string(),
            json!({"nested": [1, 2]}),
        ),
    ] {
        assert!(handle_connection_message(&mux, client, &message, &writer, &scheduler));
        let reply = pop_json(&outbound);
        assert_eq!(reply["ok"], false, "{reply}");
        assert!(reply["error"].as_str().unwrap().starts_with("bad request:"), "{reply}");
        assert_eq!(reply["id"], id, "an undecodable request lost its id: {reply}");
    }

    // Without a readable id (not JSON, or no id member) the reply keeps
    // the null id, as before.
    for message in ["{not json", r#"{"cmd":"no-such-command"}"#, r#"[1,2]"#] {
        assert!(handle_connection_message(&mux, client, message, &writer, &scheduler));
        let reply = pop_json(&outbound);
        assert_eq!(reply["ok"], false, "{reply}");
        assert!(reply["id"].is_null(), "{reply}");
    }
}

#[test]
fn shutdown_requester_waits_for_owner_eof_and_rejects_pipelined_mutations() {
    let mux = test_mux();
    mux.mark_server_lifecycle_ready();
    let (writer, outbound) = captured_writer();
    let requester = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let (_, generation) = mux.registry_identity();
    let shutdown = json!({
        "id": 98,
        "cmd": "shutdown-daemon",
        "pid": std::process::id(),
        "generation": generation,
    })
    .to_string();

    // Complete the shutdown request through the shared request handler
    // before testing the connection-level fence. The real connection
    // scheduler is asynchronous, so using it for setup would race the
    // shutdown flag that this test needs as its precondition.
    assert!(handle_message(&mux, requester, &shutdown, &writer));
    assert!(mux.daemon_shutdown_requested());
    assert!(mux.control_clients.contains(requester));
    assert!(writer.is_open());
    let response = pop_json(&outbound);
    assert_eq!(response["ok"], true);
    let shutdown = pop_json(&outbound);
    assert_eq!(shutdown["event"], DAEMON_SHUTDOWN_EVENT);

    let workspace_count = mux.with_state(|state| state.workspaces.len());
    let pipelined = json!({
        "id": 99,
        "cmd": "new-workspace",
        "name": "must-not-exist",
    })
    .to_string();
    assert!(!handle_connection_message(&mux, requester, &pipelined, &writer, &scheduler,));
    assert_eq!(mux.with_state(|state| state.workspaces.len()), workspace_count);
    assert!(outbound.try_pop().is_none());
}

#[test]
fn daemon_handoff_fences_pipelined_messages_before_shutdown_flag() {
    let mux = test_mux();
    mux.mark_server_lifecycle_ready();
    let (writer, outbound) = captured_writer();
    let requester = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    mux.begin_daemon_handoff(requester, DaemonHandoffRequest::unfenced(false)).unwrap();
    mux.commit_daemon_handoff_after_ack(requester, || Ok(())).unwrap();
    assert!(mux.control_clients.daemon_handoff_pending());
    assert!(!mux.daemon_shutdown_requested());

    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let workspace_count = mux.with_state(|state| state.workspaces.len());
    let pipelined = json!({
        "id": 99,
        "cmd": "new-workspace",
        "name": "must-not-exist",
    })
    .to_string();
    assert!(!handle_connection_message(&mux, requester, &pipelined, &writer, &scheduler));
    assert_eq!(mux.with_state(|state| state.workspaces.len()), workspace_count);
    assert!(outbound.try_pop().is_none());
}

/// While `shutdown-daemon` is still running (for example awaiting hosts
/// under `end_terminals`), a pipelined message from a subscriber must not
/// close the connection: that drops the pending shutdown reply and, if
/// the handoff then fails, leaves the client disconnected from a daemon
/// that keeps serving. The message is refused unexecuted instead.
#[test]
fn daemon_shutdown_pending_handoff_refuses_pipelined_messages_and_keeps_the_connection() {
    let mux = test_mux();
    mux.mark_server_lifecycle_ready();
    let (writer, outbound) = captured_writer();
    let requester = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    mux.begin_daemon_handoff(requester, DaemonHandoffRequest::unfenced(false)).unwrap();
    assert!(mux.control_clients.daemon_handoff_pending());

    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let workspace_count = mux.with_state(|state| state.workspaces.len());
    let pipelined = json!({
        "id": 99,
        "cmd": "new-workspace",
        "name": "must-not-exist",
    })
    .to_string();
    assert!(handle_connection_message(&mux, requester, &pipelined, &writer, &scheduler));
    let refused = pop_json(&outbound);
    assert_eq!(refused["id"], 99);
    assert_eq!(refused["ok"], false);
    assert!(refused["error"].as_str().unwrap().contains("shutdown is in progress"));
    assert_eq!(mux.with_state(|state| state.workspaces.len()), workspace_count);

    let resource = resource_request(
        "pending-get",
        "session.get",
        json!({"machine":"current","session":"current"}),
        None,
    );
    assert!(handle_connection_message(&mux, requester, &resource, &writer, &scheduler));
    let refused = pop_json(&outbound);
    assert_eq!(refused["id"], "pending-get");
    assert_eq!(refused["ok"], false);
    assert_eq!(refused["error"]["code"], "operation.failed");
    assert_eq!(refused["error"]["details"]["reason"], "daemon_handoff_pending");

    assert!(writer.is_open());
    assert!(mux.control_clients.contains(requester));
    assert!(outbound.try_pop().is_none());

    // A failed handoff leaves the same connection fully usable.
    mux.cancel_daemon_handoff(requester);
    let ping = json!({"id": 100, "cmd": "ping"}).to_string();
    assert!(handle_request(
        &mux,
        requester,
        serde_json::from_str::<Request>(&ping).unwrap(),
        &writer
    ));
    assert_eq!(pop_json(&outbound)["ok"], true);
}

#[test]
fn daemon_shutdown_force_preserves_the_identity_fence() {
    let mux = test_mux();
    mux.mark_server_lifecycle_ready();
    let owner_writer = test_writer();
    let owner = mux.control_clients.register(ClientTransport::Unix, owner_writer.clone());
    handle_command(
        &mux,
        owner,
        Command::SetClientInfo {
            name: Some("browser owner".to_string()),
            kind: Some("native-browser".to_string()),
            capabilities: None,
            user_id: None,
            display_name: None,
            device_kind: None,
            device_name: None,
            device_id: None,
        },
        &owner_writer,
    )
    .unwrap();

    let (requester_writer, outbound) = captured_writer();
    let requester = mux.control_clients.register(ClientTransport::Unix, requester_writer.clone());
    let (_, generation) = mux.registry_identity();
    assert!(handle_message(
        &mux,
        requester,
        &json!({
            "id": 95,
            "cmd": "shutdown-daemon",
            "pid": std::process::id(),
            "generation": "stale-generation",
            "force": true,
        })
        .to_string(),
        &requester_writer,
    ));
    let rejected = pop_json(&outbound);
    assert_eq!(rejected["ok"], false);
    assert!(rejected["error"].as_str().unwrap().contains("generation changed"));
    assert!(!mux.daemon_shutdown_requested());

    assert!(handle_message(
        &mux,
        requester,
        &json!({
            "id": 96,
            "cmd": "shutdown-daemon",
            "pid": std::process::id(),
            "generation": generation,
            "force": true,
        })
        .to_string(),
        &requester_writer,
    ));
    let accepted = pop_json(&outbound);
    assert_eq!(accepted["ok"], true);
    assert!(mux.daemon_shutdown_requested());
}

#[test]
fn daemon_shutdown_atomically_fences_native_browser_ownership() {
    let owned = test_mux();
    let requester_writer = test_writer();
    let owner_writer = test_writer();
    let requester = owned.control_clients.register(ClientTransport::Unix, requester_writer.clone());
    let owner = owned.control_clients.register(ClientTransport::Unix, owner_writer.clone());
    handle_command(
        &owned,
        owner,
        Command::SetClientInfo {
            name: Some("existing browser".to_string()),
            kind: Some("native-browser".to_string()),
            capabilities: None,
            user_id: None,
            display_name: None,
            device_kind: None,
            device_name: None,
            device_id: None,
        },
        &owner_writer,
    )
    .unwrap();
    let (_, generation) = owned.registry_identity();
    let error = handle_command(
        &owned,
        requester,
        Command::ShutdownDaemon {
            pid: std::process::id(),
            generation,
            force: false,
            end_terminals: false,
            keep_layout: false,
        },
        &requester_writer,
    )
    .unwrap_err();
    assert!(error.to_string().contains("still owns"));
    assert!(!owned.daemon_shutdown_requested());

    let fenced = test_mux();
    let requester_writer = test_writer();
    let late_writer = test_writer();
    let requester =
        fenced.control_clients.register(ClientTransport::Unix, requester_writer.clone());
    let late = fenced.control_clients.register(ClientTransport::Unix, late_writer.clone());
    let (_, generation) = fenced.registry_identity();
    handle_command(
        &fenced,
        requester,
        Command::ShutdownDaemon {
            pid: std::process::id(),
            generation,
            force: false,
            end_terminals: false,
            keep_layout: false,
        },
        &requester_writer,
    )
    .unwrap();
    let error = handle_command(
        &fenced,
        late,
        Command::SetClientInfo {
            name: Some("late browser".to_string()),
            kind: Some("native-browser".to_string()),
            capabilities: None,
            user_id: None,
            display_name: None,
            device_kind: None,
            device_name: None,
            device_id: None,
        },
        &late_writer,
    )
    .unwrap_err();
    assert!(error.to_string().contains("handoff is already in progress"));
}

#[test]
fn daemon_handoff_rejects_clients_registered_after_the_fence() {
    let mux = test_mux();
    let requester_writer = test_writer();
    let requester = mux.control_clients.register(ClientTransport::Unix, requester_writer);
    mux.begin_daemon_handoff(requester, DaemonHandoffRequest::unfenced(false)).unwrap();

    let late_writer = test_writer();
    let late = mux.control_clients.register(ClientTransport::Unix, late_writer.clone());

    assert!(!mux.control_clients.contains(late));
    assert!(!late_writer.is_open());

    mux.cancel_daemon_handoff(requester);
    let retry_writer = test_writer();
    let retry = mux.control_clients.register(ClientTransport::Unix, retry_writer.clone());
    assert!(mux.control_clients.contains(retry));
    assert!(retry_writer.is_open());
}

#[test]
fn daemon_handoff_requester_disconnect_releases_the_reservation() {
    let mux = test_mux();
    let requester = mux.control_clients.register(ClientTransport::Unix, test_writer());
    mux.begin_daemon_handoff(requester, DaemonHandoffRequest::unfenced(false)).unwrap();
    assert!(mux.control_clients.daemon_handoff_pending());

    assert!(disconnect_client(&mux, requester, false));
    assert!(!mux.control_clients.daemon_handoff_pending());

    let retry_writer = test_writer();
    let retry = mux.control_clients.register(ClientTransport::Unix, retry_writer.clone());
    assert!(mux.control_clients.contains(retry));
    assert!(retry_writer.is_open());
}

#[test]
fn daemon_handoff_ack_commit_holds_the_requester_removal_lock() {
    let mux = test_mux();
    let requester = mux.control_clients.register(ClientTransport::Unix, test_writer());
    mux.begin_daemon_handoff(requester, DaemonHandoffRequest::unfenced(false)).unwrap();

    mux.commit_daemon_handoff_after_ack(requester, || {
        assert!(matches!(
            mux.control_clients.state.try_lock(),
            Err(std::sync::TryLockError::WouldBlock)
        ));
        Ok(())
    })
    .unwrap();

    assert!(disconnect_client(&mux, requester, false));
    assert!(mux.control_clients.daemon_handoff_pending());
}

#[test]
fn committed_daemon_handoff_requester_disconnect_keeps_the_fence() {
    let mux = test_mux();
    let requester = mux.control_clients.register(ClientTransport::Unix, test_writer());
    mux.begin_daemon_handoff(requester, DaemonHandoffRequest::unfenced(false)).unwrap();
    mux.commit_daemon_handoff_after_ack(requester, || Ok(())).unwrap();
    mux.request_daemon_shutdown();

    assert!(disconnect_client(&mux, requester, false));
    assert!(mux.control_clients.daemon_handoff_pending());

    let retry_writer = test_writer();
    let retry = mux.control_clients.register(ClientTransport::Unix, retry_writer.clone());
    assert!(!mux.control_clients.contains(retry));
    assert!(!retry_writer.is_open());
}

#[cfg(unix)]
#[test]
fn pane_and_screen_close_detach_views_without_closing_terminal_hosts() {
    const TERMINAL: &str = "00000000000040008000000000000012";
    const INCARNATION: &str = "10000000000040008000000000000012";
    for close_screen in [false, true] {
        let mux = test_mux();
        let workspace = mux
            .create_empty_workspace(None, Some("018f6e21-7b70-7e70-8000-000000001001".into()), None)
            .unwrap();
        let surface =
            mux.seed_running_terminal_for_test(TERMINAL, INCARNATION, &workspace.key).unwrap();
        let (pane, screen) = mux.with_state(|state| {
            let pane = state.pane_of(surface).unwrap();
            let (workspace, screen) = state.screen_of(pane).unwrap();
            (pane, state.workspaces[workspace].screens[screen].id)
        });
        mux.set_terminal_close_failure_for_test(true).unwrap();

        let command = if close_screen {
            Command::CloseScreen { screen, end_terminals: false }
        } else {
            Command::ClosePane { pane, end_terminals: false }
        };
        handle_command(&mux, mux.local_test_client(0), command, &test_writer()).unwrap();

        assert!(!mux.with_state(|state| state.surfaces.contains_key(&surface)));
        assert!(mux.surface(surface).is_some());
        assert_eq!(
            mux.resolve_terminal(TERMINAL).unwrap().unwrap().terminal.lifecycle,
            TerminalLifecycle::Running
        );
        assert!(mux.close_terminal(TERMINAL, INCARNATION).is_err());

        mux.set_terminal_close_failure_for_test(false).unwrap();
        mux.close_terminal(TERMINAL, INCARNATION).unwrap();
        assert!(mux.surface(surface).is_none());
    }
}
