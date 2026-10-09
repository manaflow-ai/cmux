//! Workspace selector conflicts, provider-managed locking, identify capabilities, protocol key input and window titles.

use super::*;

#[test]
fn stale_workspace_selectors_report_revision_conflicts_before_lookup() {
    let mux = test_mux();
    let key = "018f6e21-7b70-7e70-8000-000000001022";
    let workspace =
        mux.create_empty_workspace(Some("stale".into()), Some(key.into()), None).unwrap();
    mux.close_workspace_at_revision(workspace.workspace, Some(1)).unwrap();
    let writer = test_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());

    for command in [
        Command::CloseWorkspace {
            workspace: None,
            key: Some(key.into()),
            end_terminals: false,
            mutation: MutationRequest { expected_revision: Some(1), ..Default::default() },
        },
        Command::RenameWorkspace {
            workspace: None,
            key: Some(key.into()),
            name: "renamed".into(),
            mutation: MutationRequest { expected_revision: Some(1), ..Default::default() },
        },
        Command::MoveWorkspace {
            workspace: None,
            key: Some(key.into()),
            index: 0,
            mutation: MutationRequest { expected_revision: Some(1), ..Default::default() },
        },
    ] {
        let error = handle_command(&mux, client, command, &writer).unwrap_err();
        assert_eq!(error.to_string(), "workspace revision conflict: expected 1, current 2");
    }
}

/// Regression test for the packaged-browser alt+n wedge (cmux-browser
/// issue #417): a receipted resource `workspace.create` advanced the
/// reported `workspace_revision` without advancing the legacy workspace
/// ledger, so every later legacy CAS mutation failed with
/// "workspace revision conflict: expected 1, current 0" forever.
#[test]
fn receipted_workspace_create_keeps_legacy_workspace_cas_consistent() {
    let mux = test_mux();
    let writer = test_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());

    // The packaged browser bootstraps its first workspace through the
    // receipted resource API (workspace.create, initial_content=empty).
    let selectors = crate::ResourceSelectors {
        machine: Some("current".to_string()),
        session: Some("current".to_string()),
        ..crate::ResourceSelectors::default()
    };
    let before = handle_command(&mux, client, Command::ListWorkspaces, &writer).unwrap();
    let before_revision = before["workspace_revision"].as_u64().unwrap();
    let created = mux
        .resource_create_empty_workspace_selected(
            selectors,
            Some("bootstrap".into()),
            "bootstrap-receipt-00000001",
            None,
            &WorkspaceMutation::daemon("bootstrap-create", "chrome-gui").unwrap(),
            Default::default(),
        )
        .unwrap();
    assert!(!created.replayed);

    // The browser then snapshots the registry and sends its alt+n create
    // with the reported revision, exactly like SyncWorkspaceRegistry.
    let listed = handle_command(&mux, client, Command::ListWorkspaces, &writer).unwrap();
    let revision = listed["workspace_revision"].as_u64().unwrap();
    // A real registry change must advance the reported revision: clients
    // gate delta application and snapshot refreshes on it.
    assert_eq!(revision, before_revision + 1);
    let response = handle_command(
        &mux,
        client,
        Command::CreateWorkspace {
            name: Some("alt-n".into()),
            key: Some("018f6e21-7b70-7e70-8000-0000000000aa".into()),
            mutation: MutationRequest {
                origin: Some("chrome-gui".into()),
                mutation_id: Some("alt-n-create".into()),
                expected_generation: None,
                expected_revision: Some(revision),
            },
        },
        &writer,
    )
    .unwrap();
    assert_eq!(response["replayed"], false);
    let after = handle_command(&mux, client, Command::ListWorkspaces, &writer).unwrap();
    assert_eq!(after["workspace_revision"].as_u64().unwrap(), revision + 1);
}

/// Same ledger invariant for the resource rename and move paths: the
/// revision the daemon reports must stay usable as a legacy CAS expected
/// value after every workspace-projection mutation.
#[test]
fn resource_rename_and_move_keep_legacy_workspace_cas_consistent() {
    let mux = test_mux();
    let writer = test_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    mux.create_empty_workspace(
        Some("first".into()),
        Some("018f6e21-7b70-7e70-8000-0000000000b1".into()),
        None,
    )
    .unwrap();
    mux.create_empty_workspace(
        Some("second".into()),
        Some("018f6e21-7b70-7e70-8000-0000000000b2".into()),
        None,
    )
    .unwrap();
    let first_id = mux.with_state(|state| state.workspaces[0].public_id.clone());

    mux.resource_rename_workspace(
        &first_id,
        "renamed".into(),
        None,
        None,
        &WorkspaceMutation::daemon("resource-rename", "resource-api").unwrap(),
    )
    .unwrap();
    let listed = handle_command(&mux, client, Command::ListWorkspaces, &writer).unwrap();
    let revision = listed["workspace_revision"].as_u64().unwrap();
    handle_command(
        &mux,
        client,
        Command::RenameWorkspace {
            workspace: None,
            key: Some("018f6e21-7b70-7e70-8000-0000000000b2".into()),
            name: "legacy-rename".into(),
            mutation: MutationRequest { expected_revision: Some(revision), ..Default::default() },
        },
        &writer,
    )
    .expect("legacy CAS rename must accept the reported revision");

    mux.resource_move_workspace(
        &first_id,
        1,
        None,
        None,
        &WorkspaceMutation::daemon("resource-move", "resource-api").unwrap(),
    )
    .unwrap();
    let listed = handle_command(&mux, client, Command::ListWorkspaces, &writer).unwrap();
    let revision = listed["workspace_revision"].as_u64().unwrap();
    handle_command(
        &mux,
        client,
        Command::MoveWorkspace {
            workspace: None,
            key: Some("018f6e21-7b70-7e70-8000-0000000000b2".into()),
            index: 0,
            mutation: MutationRequest { expected_revision: Some(revision), ..Default::default() },
        },
        &writer,
    )
    .expect("legacy CAS move must accept the reported revision");
}

#[test]
fn provider_managed_mux_is_locked_before_authority_handshake() {
    let mux = provider_test_mux();
    let workspace = mux
        .create_empty_workspace(
            Some("managed".into()),
            Some("018f6e21-7b70-7e70-8000-00000000aa03".into()),
            None,
        )
        .unwrap();
    let writer = test_writer();
    let ordinary = mux.control_clients.register(ClientTransport::Unix, writer.clone());

    let mutation_error = handle_command(
        &mux,
        ordinary,
        Command::RenameWorkspace {
            workspace: Some(workspace.workspace),
            key: Some(workspace.key),
            name: "won the race".into(),
            mutation: MutationRequest::default(),
        },
        &writer,
    )
    .unwrap_err();
    let handshake_error = handle_command(
        &mux,
        ordinary,
        Command::MarkWorkspacesProviderManaged { authority: "ordinary-control-client".into() },
        &writer,
    )
    .unwrap_err();

    assert!(mutation_error.to_string().contains("provider-managed workspace directly"));
    assert_eq!(handshake_error.to_string(), "invalid provider workspace authority");
    assert_eq!(mux.with_state(|state| state.workspaces[0].name.clone()), "managed");
}

#[test]
fn provider_managed_workspaces_reject_ordinary_server_mutations() {
    let mux = provider_test_mux();
    let workspace = mux
        .create_empty_workspace(
            Some("managed".into()),
            Some("018f6e21-7b70-7e70-8000-00000000aa04".into()),
            None,
        )
        .unwrap();
    let writer = test_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());

    handle_command(
        &mux,
        client,
        Command::MarkWorkspacesProviderManaged { authority: PROVIDER_AUTHORITY.into() },
        &writer,
    )
    .unwrap();
    for (command, expected_error) in [
        (
            Command::RenameWorkspace {
                workspace: Some(workspace.workspace),
                key: Some(workspace.key.clone()),
                name: "raw rename".into(),
                mutation: MutationRequest::default(),
            },
            "cannot rename a provider-managed workspace directly; use the managed workspace lifecycle controls",
        ),
        (
            Command::CloseWorkspace {
                workspace: Some(workspace.workspace),
                key: Some(workspace.key.clone()),
                end_terminals: false,
                mutation: MutationRequest::default(),
            },
            "cannot close a provider-managed workspace directly; use the managed workspace lifecycle controls",
        ),
    ] {
        let error = handle_command(&mux, client, command, &writer).unwrap_err();
        assert_eq!(error.to_string(), expected_error);
    }
    mux.with_state(|state| {
        assert_eq!(state.workspace_revision, 1);
        let current =
            state.workspaces.iter().find(|candidate| candidate.id == workspace.workspace).unwrap();
        assert_eq!(current.name, "managed");
    });

    handle_command(
        &mux,
        client,
        Command::RenameProviderManagedWorkspace {
            workspace: workspace.workspace,
            key: workspace.key.clone(),
            name: "provider rename".into(),
            authority: PROVIDER_AUTHORITY.into(),
        },
        &writer,
    )
    .unwrap();
    assert_eq!(
        mux.with_state(|state| state
            .workspaces
            .iter()
            .find(|candidate| candidate.id == workspace.workspace)
            .unwrap()
            .name
            .clone()),
        "provider rename"
    );

    handle_command(
        &mux,
        client,
        Command::CloseProviderManagedWorkspace {
            workspace: workspace.workspace,
            key: workspace.key,
            authority: PROVIDER_AUTHORITY.into(),
        },
        &writer,
    )
    .unwrap();
    assert!(mux.with_state(|state| state.workspaces.is_empty()));
}

#[test]
fn ordinary_control_client_cannot_forge_provider_workspace_commits() {
    let mux = provider_test_mux();
    let workspace = mux
        .create_empty_workspace(
            Some("managed".into()),
            Some("018f6e21-7b70-7e70-8000-00000000aa05".into()),
            None,
        )
        .unwrap();
    let writer = test_writer();
    let provider = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let ordinary = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    handle_command(
        &mux,
        provider,
        Command::MarkWorkspacesProviderManaged { authority: PROVIDER_AUTHORITY.into() },
        &writer,
    )
    .unwrap();

    let rename_error = handle_command(
        &mux,
        ordinary,
        Command::RenameProviderManagedWorkspace {
            workspace: workspace.workspace,
            key: workspace.key.clone(),
            name: "forged rename".into(),
            authority: "ordinary-control-client".into(),
        },
        &writer,
    )
    .unwrap_err();
    let close_error = handle_command(
        &mux,
        ordinary,
        Command::CloseProviderManagedWorkspace {
            workspace: workspace.workspace,
            key: workspace.key,
            authority: "ordinary-control-client".into(),
        },
        &writer,
    )
    .unwrap_err();

    assert!(rename_error.to_string().contains("provider workspace authority"));
    assert!(close_error.to_string().contains("provider workspace authority"));
    mux.with_state(|state| {
        assert_eq!(state.workspaces.len(), 1);
        assert_eq!(state.workspaces[0].name, "managed");
        assert_eq!(state.workspace_revision, 1);
    });
}

#[test]
fn identify_advertises_additive_capabilities() {
    let mux = test_mux();
    let identity =
        handle_command(&mux, mux.local_test_client(0), Command::Identify, &test_writer()).unwrap();

    let capabilities = identity["capabilities"].as_array().expect("capabilities");
    for expected in [
        "attach-initial-size",
        SURFACE_SUBSCRIBE_FILTER_CAPABILITY,
        "workspace-registry-v1",
        GUARDED_BROWSER_POINTER_CAPABILITY,
        VIEWPORT_SPLITS_CAPABILITY,
        VIEWPORT_COLUMN_RESIZE_CAPABILITY,
        LAYOUT_UNDO_CAPABILITY,
        CLEAR_HISTORY_CAPABILITY,
        CLEAR_HISTORY_KEY_CAPABILITY,
        "surface-subscribe-filter",
        SESSION_JOURNAL_CAPABILITY,
        FRONTEND_JOURNAL_CAPABILITY,
        VIEW_ATTACHMENT_LEASE_CAPABILITY,
        VIEW_ATTACHMENT_DETACH_CAPABILITY,
        CREATION_RECEIPTS_CAPABILITY,
        CREATION_SELECTOR_FALLBACKS_CAPABILITY,
        PROVIDER_MANAGED_WORKSPACE_GUARD_CAPABILITY,
        STATE_RESOURCES_CAPABILITY,
        WINDOW_RECORDS_CAPABILITY,
        TERMINAL_STATE_CAPABILITY,
        FRONTEND_BROWSER_OWNER_CAPABILITY,
        crate::git_ops::CHECKPOINTS_CAPABILITY,
        crate::git_ops::FILES_SEARCH_CAPABILITY,
    ] {
        assert!(capabilities.iter().any(|value| value.as_str() == Some(expected)));
    }
}

#[test]
fn layout_undo_protocol_requires_the_preview_revision_before_closing_a_pane() {
    let mux = test_mux();
    let first = mux.new_workspace(None, Some((80, 22))).unwrap();
    let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let right = mux.new_pane_right(first_pane, 0.5, Some((38, 22))).unwrap();
    let right_pane = mux.with_state(|state| state.pane_of(right.id).unwrap());
    let writer = test_writer();

    let preview = handle_command(
        &mux,
        mux.local_test_client(0),
        Command::UndoLayout { pane: right_pane, revision: None, confirm_close: false },
        &writer,
    )
    .unwrap();
    let revision = preview["revision"].as_u64().expect("preview revision");
    assert_eq!(preview["undone"].as_bool(), Some(false));
    assert_eq!(preview["confirmation_required"].as_bool(), Some(true));
    assert_eq!(preview["closes_panes"], json!([right_pane]));

    let error = handle_command(
        &mux,
        mux.local_test_client(0),
        Command::UndoLayout { pane: right_pane, revision: None, confirm_close: true },
        &writer,
    )
    .unwrap_err();
    assert!(error.to_string().contains("requires the preview revision"));
    assert!(mux.surface(right.id).is_some());

    let result = handle_command(
        &mux,
        mux.local_test_client(0),
        Command::UndoLayout { pane: right_pane, revision: Some(revision), confirm_close: true },
        &writer,
    )
    .unwrap();
    assert_eq!(result["undone"].as_bool(), Some(true));
    assert!(!mux.with_state(|state| state.surfaces.contains_key(&right.id)));
    assert!(mux.surface(right.id).is_some());
}

#[test]
fn layout_undo_protocol_serializes_the_machine_readable_error_code() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, Some((80, 22))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(surface.id).unwrap());
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });

    handle_message(
        &mux,
        mux.local_test_client(7),
        &json!({"id": 19, "cmd": "undo-layout", "pane": pane}).to_string(),
        &writer,
    );

    let response: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
    assert_eq!(response["id"], 19);
    assert_eq!(response["ok"], false);
    assert_eq!(response["error_code"], crate::LayoutUndoError::UNAVAILABLE_CODE);
}

#[test]
fn identify_advertises_clear_history_key_only_with_bounded_fallback_writes() {
    let unsupported = advertised_capabilities(false);
    assert!(unsupported.contains(&CLEAR_HISTORY_CAPABILITY));
    assert!(unsupported.contains(&CREATION_ATTEMPT_KEYS_CAPABILITY));
    assert!(!unsupported.contains(&CLEAR_HISTORY_KEY_CAPABILITY));

    let supported = advertised_capabilities(true);
    assert!(supported.contains(&CLEAR_HISTORY_CAPABILITY));
    assert!(supported.contains(&CLEAR_HISTORY_KEY_CAPABILITY));
}

#[test]
fn identify_advertises_private_link_port_discovery() {
    assert!(advertised_capabilities(true).contains(&MACHINE_LISTENING_TCP_CAPABILITY));
    let command: Command = serde_json::from_value(json!({
        "cmd": "machine-listening-tcp",
    }))
    .unwrap();
    assert!(matches!(command, Command::MachineListeningTcp));
}

#[cfg(target_os = "linux")]
#[test]
fn private_link_port_discovery_reports_listener_process() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let endpoint = listener.local_addr().unwrap().to_string();
    let inventory = machine_listening_tcp_json().unwrap();
    let stdout = inventory["stdout"].as_str().unwrap();
    let row = stdout
        .lines()
        .find(|line| line.split_whitespace().nth(3) == Some(endpoint.as_str()))
        .expect("the inventory must contain the test's listening socket");
    let pid = std::process::id();
    assert!(
        row.contains(&format!("pid={pid},"))
            || row.split_whitespace().any(|field| field.starts_with(&format!("{pid}/"))),
        "listener ownership is needed to distinguish application ports from internal services: {row}"
    );
}

#[test]
fn protocol_key_input_round_trips_encoder_metadata() {
    let input = KeyInput {
        key: sys::GHOSTTY_KEY_NUMPAD_ENTER,
        mods: Mods::SHIFT | Mods::CTRL | Mods::ALT | Mods::CAPS_LOCK | Mods::NUM_LOCK,
        consumed_mods: Mods::SHIFT | Mods::ALT,
        composing: true,
        utf8: "ß".to_string(),
        unshifted_codepoint: 's' as u32,
        shifted_codepoint: 'S' as u32,
        base_layout_codepoint: '1' as u32,
        action: Some(KeyAction::Repeat),
        macos_option_as_alt: false,
    };

    let value = serde_json::to_value(ProtocolKeyInput::try_from(&input).unwrap()).unwrap();
    assert_eq!(value["key"], "numpad-enter");
    assert_eq!(value["composing"], true);
    assert_eq!(value["unshifted_codepoint"], "s");
    assert_eq!(value["shifted_codepoint"], "S");
    assert_eq!(value["base_layout_codepoint"], "1");
    let decoded = serde_json::from_value::<ProtocolKeyInput>(value).unwrap();
    let decoded = KeyInput::try_from(decoded).unwrap();

    assert_eq!(decoded.key, input.key);
    assert_eq!(decoded.mods, input.mods);
    assert_eq!(decoded.consumed_mods, input.consumed_mods);
    assert_eq!(decoded.composing, input.composing);
    assert_eq!(decoded.utf8, input.utf8);
    assert_eq!(decoded.unshifted_codepoint, input.unshifted_codepoint);
    assert_eq!(decoded.shifted_codepoint, input.shifted_codepoint);
    assert_eq!(decoded.base_layout_codepoint, input.base_layout_codepoint);
    assert_eq!(decoded.action, input.action);
    assert_eq!(decoded.macos_option_as_alt, input.macos_option_as_alt);
}

#[test]
fn protocol_key_text_limit_is_bounded_for_one_key_event() {
    const {
        assert!(
            PROTOCOL_KEY_TEXT_MAX_BYTES <= 4 * 1024,
            "one key event may retain an unbounded fallback payload"
        );
    }
    let input = KeyInput {
        key: sys::GHOSTTY_KEY_K,
        mods: Mods::SUPER,
        utf8: "\"".repeat(PROTOCOL_KEY_TEXT_MAX_BYTES),
        unshifted_codepoint: 'k' as u32,
        base_layout_codepoint: 'k' as u32,
        action: Some(KeyAction::Press),
        macos_option_as_alt: true,
        ..Default::default()
    };
    let fallback_key = ProtocolKeyInput::try_from(&input).unwrap();
    let request = json!({
        "id": u64::MAX,
        "cmd": "clear-history",
        "surface": u64::MAX,
        "fallback_key": fallback_key,
    });
    let encoded = serde_json::to_vec(&request).unwrap();

    assert!(
        encoded.len() <= WEBSOCKET_INBOUND_MESSAGE_MAX_BYTES,
        "accepted fallback key serialized to {} bytes, above the {}-byte WebSocket limit",
        encoded.len(),
        WEBSOCKET_INBOUND_MESSAGE_MAX_BYTES
    );
}

#[test]
fn protocol_key_input_rejects_raw_ghostty_discriminants() {
    let raw = json!({
        "key": u32::MAX,
        "mods": u16::MAX,
        "consumed_mods": 0,
        "utf8": "",
        "unshifted_codepoint": 0,
        "action": "press",
        "macos_option_as_alt": true,
    });

    assert!(
        serde_json::from_value::<ProtocolKeyInput>(raw).is_err(),
        "raw Ghostty enum and modifier values crossed the protocol boundary"
    );
}

#[test]
fn protocol_key_input_rejects_unknown_or_invalid_semantics() {
    let input = KeyInput {
        key: sys::GHOSTTY_KEY_K,
        mods: Mods::SUPER,
        unshifted_codepoint: 'k' as u32,
        action: Some(KeyAction::Press),
        ..Default::default()
    };
    let valid = serde_json::to_value(ProtocolKeyInput::try_from(&input).unwrap()).unwrap();

    let mut unknown_key = valid.clone();
    unknown_key["key"] = json!("future-key");
    assert!(serde_json::from_value::<ProtocolKeyInput>(unknown_key).is_err());

    let mut unknown_modifier = valid.clone();
    unknown_modifier["mods"]["hyper"] = json!(true);
    assert!(serde_json::from_value::<ProtocolKeyInput>(unknown_modifier).is_err());

    let mut invalid_codepoint = valid.clone();
    invalid_codepoint["unshifted_codepoint"] = json!("ss");
    assert!(serde_json::from_value::<ProtocolKeyInput>(invalid_codepoint).is_err());

    let mut invalid_shifted_codepoint = valid.clone();
    invalid_shifted_codepoint["shifted_codepoint"] = json!("SS");
    assert!(serde_json::from_value::<ProtocolKeyInput>(invalid_shifted_codepoint).is_err());

    let mut invalid_base_layout_codepoint = valid.clone();
    invalid_base_layout_codepoint["base_layout_codepoint"] = json!("11");
    assert!(serde_json::from_value::<ProtocolKeyInput>(invalid_base_layout_codepoint).is_err());

    let mut control_text = valid.clone();
    control_text["utf8"] = json!("\r");
    let control_text = serde_json::from_value::<ProtocolKeyInput>(control_text).unwrap();
    assert!(KeyInput::try_from(control_text).is_err());

    let mut inactive_consumed_modifier = valid;
    inactive_consumed_modifier["consumed_mods"]["shift"] = json!(true);
    let inactive_consumed_modifier =
        serde_json::from_value::<ProtocolKeyInput>(inactive_consumed_modifier).unwrap();
    assert!(KeyInput::try_from(inactive_consumed_modifier).is_err());

    let invalid_key = KeyInput { key: sys::GhosttyKey::MAX, ..input.clone() };
    assert!(ProtocolKeyInput::try_from(&invalid_key).is_err());
    let invalid_mods = KeyInput { mods: Mods(u16::MAX), ..input.clone() };
    assert!(ProtocolKeyInput::try_from(&invalid_mods).is_err());
    let invalid_codepoint = KeyInput { unshifted_codepoint: 0xD800, ..input.clone() };
    assert!(ProtocolKeyInput::try_from(&invalid_codepoint).is_err());
    let invalid_shifted = KeyInput { shifted_codepoint: 0xD800, ..input.clone() };
    assert!(ProtocolKeyInput::try_from(&invalid_shifted).is_err());
    let oversized_text = KeyInput { utf8: "x".repeat(PROTOCOL_KEY_TEXT_MAX_BYTES + 1), ..input };
    assert!(ProtocolKeyInput::try_from(&oversized_text).is_err());
    let invalid_base_layout = KeyInput { base_layout_codepoint: 0xD800, ..input };
    assert!(ProtocolKeyInput::try_from(&invalid_base_layout).is_err());
}

#[test]
fn reload_config_waits_for_owner_application_before_returning() {
    let mux = test_mux();
    let events = mux.subscribe();
    let worker_mux = mux.clone();
    let (result_tx, result_rx) = std::sync::mpsc::sync_channel(1);
    let worker = std::thread::spawn(move || {
        result_tx
            .send(handle_command(
                &worker_mux,
                worker_mux.local_test_client(0),
                Command::ReloadConfig,
                &test_writer(),
            ))
            .unwrap();
    });
    assert!(matches!(
        events.recv_timeout(Duration::from_secs(1)),
        Ok(MuxEvent::ConfigReloadRequested)
    ));
    assert!(matches!(result_rx.try_recv(), Err(TryRecvError::Empty)));

    let target = mux.begin_config_reload_application();
    mux.complete_config_reload_application(target);
    let data = result_rx.recv_timeout(Duration::from_secs(1)).unwrap().unwrap();
    worker.join().unwrap();
    assert_eq!(data["reloaded"].as_bool(), Some(true));
    assert!(data.get("path").is_some());
}

#[cfg(unix)]
#[test]
fn paused_server_serves_identity_before_lifecycle_readiness() {
    let dir = TestSocketDir::create("paused-readiness");
    let path = dir.path().join("mux.sock");
    let mux = test_mux();
    let pending = serve_paused(mux, Some(path.clone())).unwrap();
    let mut stream = transport::connect(&path).unwrap();
    writeln!(stream, r#"{{"id":1,"cmd":"identify"}}"#).unwrap();
    stream.flush().unwrap();
    let (response_tx, response_rx) = std::sync::mpsc::sync_channel(1);
    std::thread::spawn(move || {
        let mut response = String::new();
        let result = BufReader::new(stream).read_line(&mut response).map(|_| response);
        response_tx.send(result).unwrap();
    });
    let response = response_rx
        .recv_timeout(Duration::from_secs(1))
        .expect("ordinary protocol identify waited for lifecycle readiness")
        .unwrap();
    assert_eq!(serde_json::from_str::<Value>(&response).unwrap()["ok"], true);

    let mut lifecycle = transport::connect(&path).unwrap();
    writeln!(lifecycle, r#"{{"id":2,"cmd":"identify"}}"#).unwrap();
    lifecycle.flush().unwrap();
    let mut starting = String::new();
    BufReader::new(&mut lifecycle).read_line(&mut starting).unwrap();
    assert_eq!(serde_json::from_str::<Value>(&starting).unwrap()["data"]["lifecycle_ready"], false);

    writeln!(lifecycle, r#"{{"id":3,"cmd":"reload-config"}}"#).unwrap();
    lifecycle.flush().unwrap();
    let mut rejected = String::new();
    BufReader::new(&mut lifecycle).read_line(&mut rejected).unwrap();
    assert_eq!(serde_json::from_str::<Value>(&rejected).unwrap()["ok"], false);

    let served = pending.mark_ready().unwrap();
    writeln!(lifecycle, r#"{{"id":4,"cmd":"identify"}}"#).unwrap();
    lifecycle.flush().unwrap();
    let mut ready = String::new();
    BufReader::new(lifecycle).read_line(&mut ready).unwrap();
    assert_eq!(served, path);
    assert_eq!(serde_json::from_str::<Value>(&ready).unwrap()["data"]["lifecycle_ready"], true);
    cleanup(&served);
}

#[test]
fn window_title_commands_emit_requests() {
    let mux = test_mux();
    let events = mux.subscribe();

    let data = handle_command(
        &mux,
        mux.local_test_client(0),
        Command::SetWindowTitle { title: "hello".to_string() },
        &test_writer(),
    )
    .unwrap();
    assert_eq!(data, json!({}));
    assert!(matches!(
        events.recv_timeout(Duration::from_secs(1)),
        Ok(MuxEvent::WindowTitleRequested(title)) if title == "hello"
    ));

    handle_command(&mux, mux.local_test_client(0), Command::ClearWindowTitle, &test_writer())
        .unwrap();
    assert!(matches!(
        events.recv_timeout(Duration::from_secs(1)),
        Ok(MuxEvent::WindowTitleRequested(title)) if title.is_empty()
    ));
}

#[test]
fn cmux_next_notify_accepts_a_source_and_reports_it_on_the_wire() {
    assert!(advertised_capabilities(false).contains(&NOTIFICATION_SOURCE_CAPABILITY));
    let mux = test_mux();
    let surface = mux.new_workspace(None, Some((20, 4))).unwrap();
    let events = mux.subscribe();
    run_json_command(
        &mux,
        json!({"cmd":"notify","title":"hook","body":"","surface":surface.id,"source":"agent"}),
    )
    .unwrap();
    run_json_command(&mux, json!({"cmd":"notify","title":"cli","body":"","surface":surface.id}))
        .unwrap();
    let notes = events
        .try_iter()
        .filter(|event| matches!(event, MuxEvent::Notification(_)))
        .map(|event| subscribed_event_json(&event))
        .collect::<Vec<_>>();
    assert_eq!(notes.len(), 2, "{notes:?}");
    assert_eq!(notes[0]["title"], "hook");
    assert_eq!(notes[0]["source"], "agent");
    assert_eq!(notes[1]["title"], "cli");
    assert_eq!(notes[1]["source"], "cli", "notify defaults to the cli source");

    let tree = run_json_command(&mux, json!({"cmd":"list-workspaces"})).unwrap();
    let tab = tree["workspaces"][0]["screens"][0]["panes"][0]["tabs"][0].clone();
    assert_eq!(tab["surface"], json!(surface.id));
    assert_eq!(tab["notification"]["source"], "cli", "{tab}");

    for source in ["daemon", "terminal"] {
        run_json_command(
            &mux,
            json!({"cmd":"notify","title":source,"body":"","surface":surface.id,"source":source}),
        )
        .unwrap();
    }
    assert!(
        run_json_command(&mux, json!({"cmd":"notify","title":"x","body":"","source":"bogus"}))
            .is_err()
    );
}

#[test]
fn cmux_next_terminal_osc_notifications_post_from_unattached_terminals() {
    // No client attaches: the daemon parses the program's output itself,
    // as for a terminal in a hidden tab or a background workspace. The
    // pauses keep each sequence outside the 1 s rate limit.
    let mux = Mux::new(
        "terminal-osc-notifications-test",
        SurfaceOptions {
            command: Some(vec![
                "/bin/sh".to_string(),
                "-c".to_string(),
                "printf '\\033]9;nine\\007'; sleep 1.3; \
                 printf '\\033]777;notify;seven;body\\007'; sleep 1.3; \
                 printf '\\033]99;;kitty\\033\\\\'; exec cat"
                    .to_string(),
            ]),
            ..SurfaceOptions::default()
        },
    );
    let events = mux.subscribe();
    let surface = mux.new_workspace(None, Some((20, 4))).unwrap();
    let deadline = Instant::now() + Duration::from_secs(20);
    let mut notes = Vec::new();
    while notes.len() < 3 {
        let remaining = deadline.saturating_duration_since(Instant::now());
        assert!(!remaining.is_zero(), "terminal notifications missing: {notes:?}");
        if let Ok(MuxEvent::Notification(note)) = events.recv_timeout(remaining) {
            notes.push(note);
        }
    }
    let summary = notes
        .iter()
        .map(|note| (note.title.as_str(), note.body.as_str(), note.source, note.surface))
        .collect::<Vec<_>>();
    assert_eq!(
        summary,
        vec![
            ("nine", "", NotificationSource::Terminal, Some(surface.id)),
            ("seven", "body", NotificationSource::Terminal, Some(surface.id)),
            ("kitty", "", NotificationSource::Terminal, Some(surface.id)),
        ]
    );
    mux.shutdown();
}

#[test]
fn title_changed_event_includes_authoritative_surface_title() {
    let mux = Mux::new(
        "title-event-test",
        SurfaceOptions {
            command: Some(vec![
                "/bin/sh".to_string(),
                "-c".to_string(),
                "printf '\\033]2;server title\\007'; exec cat".to_string(),
            ]),
            ..SurfaceOptions::default()
        },
    );
    let events = mux.subscribe();
    let surface = mux.new_workspace(None, Some((20, 4))).unwrap();
    loop {
        match events.recv_timeout(Duration::from_secs(1)).unwrap() {
            MuxEvent::TitleChanged { surface: id, title }
                if id == surface.id && title.as_ref() == "server title" =>
            {
                break;
            }
            _ => {}
        }
    }

    assert_eq!(surface.title(), "server title");
    assert_eq!(
        subscribed_event_json(&MuxEvent::TitleChanged {
            surface: surface.id,
            title: Arc::<str>::from("server title"),
        }),
        json!({
            "event": "title-changed",
            "surface": surface.id,
            "title": "server title",
        })
    );
}
