//! Client sizing participation, geometry ownership and size reports.

use super::*;

#[test]
fn dimensionless_terminal_client_reports_disabled_sizing_participation() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let writer = test_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let stream = writer.start_stream(&json!({"event": "test"})).unwrap();
    let stream_id = stream.id;
    mux.control_clients.attach_surface(client, surface.id, stream).unwrap();
    mux.control_clients.commit_surface(client, surface.id, stream_id, None).unwrap();

    handle_command(
        &mux,
        client,
        Command::SetClientSizing {
            surface: surface.id,
            client: Some(client),
            enabled: false,
            exclusive: false,
        },
        &writer,
    )
    .unwrap();

    let listed = handle_command(&mux, client, Command::ListClients, &writer).unwrap();
    assert_eq!(listed[0]["attached"], json!([surface.id]));
    assert_eq!(listed[0]["sizes"][0]["cols"], Value::Null);
    assert_eq!(listed[0]["sizes"][0]["rows"], Value::Null);
    assert_eq!(listed[0]["sizes"][0]["size_participating"], false);
}

#[test]
fn client_sizing_command_applies_exclusive_and_all_modes_atomically() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, Some((120, 40))).unwrap();
    mux.pin_latest_size_policy_for_test(surface.id);
    let first_writer = test_writer();
    let second_writer = test_writer();
    let first = mux.control_clients.register(ClientTransport::Unix, first_writer.clone());
    let second = mux.control_clients.register(ClientTransport::Unix, second_writer.clone());
    for (client, writer, size) in
        [(first, &first_writer, (120, 40)), (second, &second_writer, (80, 30))]
    {
        let stream = writer.start_stream(&json!({"event": "test"})).unwrap();
        mux.control_clients.attach_surface(client, surface.id, stream).unwrap();
        handle_command(
            &mux,
            client,
            Command::ResizeSurface { surface: surface.id, cols: size.0, rows: size.1 },
            writer,
        )
        .unwrap();
    }
    assert_eq!(surface.size(), (80, 30));

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
    assert_eq!(surface.size(), (120, 40));
    assert!(mux.client_size_participates(surface.id, first));
    assert!(!mux.client_size_participates(surface.id, second));

    // "All sizes" restores automatic counting; it no longer freezes the
    // grid, so the latest active view keeps it.
    handle_command(
        &mux,
        first,
        Command::SetClientSizing {
            surface: surface.id,
            client: None,
            enabled: true,
            exclusive: false,
        },
        &first_writer,
    )
    .unwrap();
    assert_eq!(surface.size(), (120, 40));
    assert!(mux.client_size_participates(surface.id, first));
    assert!(!mux.client_size_participates(surface.id, second));
}

#[test]
fn terminal_exclusive_sizing_defaults_to_the_requesting_client() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, Some((120, 40))).unwrap();
    let writer = test_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());

    let error = handle_command(
        &mux,
        client,
        Command::SetClientSizing {
            surface: surface.id,
            client: None,
            enabled: true,
            exclusive: true,
        },
        &writer,
    )
    .unwrap_err();
    assert!(error.to_string().contains("reported size"));

    let stream = writer.start_stream(&json!({"event": "test"})).unwrap();
    let stream_id = stream.id;
    mux.control_clients.attach_surface(client, surface.id, stream).unwrap();
    mux.control_clients.commit_surface(client, surface.id, stream_id, None).unwrap();
    let joined = handle_command(
        &mux,
        client,
        Command::ResizeSurface { surface: surface.id, cols: 90, rows: 28 },
        &writer,
    )
    .unwrap();
    assert_eq!(joined["accepted"], true);

    handle_command(
        &mux,
        client,
        Command::SetClientSizing {
            surface: surface.id,
            client: None,
            enabled: true,
            exclusive: true,
        },
        &writer,
    )
    .unwrap();
    assert!(mux.client_size_participates(surface.id, client));
    assert_eq!(surface.size(), (90, 28));
}

#[test]
fn client_sizing_command_reports_unknown_surface_before_client_errors() {
    let mux = test_mux();
    let writer = test_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let missing_surface = 999_999;

    let error = handle_command(
        &mux,
        client,
        Command::SetClientSizing {
            surface: missing_surface,
            client: Some(client),
            enabled: false,
            exclusive: false,
        },
        &writer,
    )
    .unwrap_err();

    assert_eq!(error.to_string(), format!("unknown surface {missing_surface}"));
}

#[test]
fn client_sizing_command_only_changes_requested_surface() {
    let mux = test_mux();
    let current = mux.new_workspace(None, Some((120, 40))).unwrap();
    let other = mux.new_workspace(None, Some((110, 35))).unwrap();
    mux.pin_latest_size_policy_for_test(current.id);
    mux.pin_latest_size_policy_for_test(other.id);
    let writer = test_writer();
    let first = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let second = mux.control_clients.register(ClientTransport::Unix, test_writer());
    let first_stream = writer.start_stream(&attach_overflow_json(current.id)).unwrap();
    mux.control_clients.attach_surface(first, current.id, first_stream.clone()).unwrap();
    mux.control_clients.commit_surface(first, current.id, first_stream.id, None).unwrap();

    mux.resize_surface_for_client(current.id, first, 100, 32).unwrap();
    mux.resize_surface_for_client(current.id, second, 80, 30).unwrap();
    mux.resize_surface_for_client(other.id, first, 90, 28).unwrap();
    mux.resize_surface_for_client(other.id, second, 70, 20).unwrap();
    assert_eq!(current.size(), (80, 30));
    assert_eq!(other.size(), (70, 20));

    let request = serde_json::from_value::<Request>(json!({
        "cmd": "set-client-sizing",
        "surface": current.id,
        "client": first,
        "enabled": true,
        "exclusive": true,
    }))
    .unwrap();
    handle_command(&mux, first, request.cmd, &writer).unwrap();

    assert_eq!(current.size(), (100, 32));
    assert_eq!(other.size(), (70, 20));
}

#[test]
fn releasing_surface_size_keeps_attach_but_removes_visibility_lease() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, Some((120, 40))).unwrap();
    let writer = test_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let stream = writer.start_stream(&json!({"event": "test"})).unwrap();
    let stream_id = stream.id;
    mux.control_clients.attach_surface(client, surface.id, stream).unwrap();
    mux.control_clients.commit_surface(client, surface.id, stream_id, None).unwrap();
    let events = mux.subscribe();

    handle_command(
        &mux,
        client,
        Command::ResizeSurface { surface: surface.id, cols: 80, rows: 24 },
        &writer,
    )
    .unwrap();
    assert_eq!(mux.client_surface_size(surface.id, client), Some((80, 24)));
    assert!((0..4).any(|_| matches!(
        events.recv_timeout(Duration::from_secs(1)),
        Ok(MuxEvent::ClientChanged { client: id, .. }) if id == client
    )));

    handle_command(&mux, client, Command::ReleaseSurfaceSize { surface: surface.id }, &writer)
        .unwrap();
    assert_eq!(mux.client_surface_size(surface.id, client), None);
    let listed = handle_command(&mux, client, Command::ListClients, &writer).unwrap();
    assert_eq!(listed[0]["attached"], json!([surface.id]));
    assert_eq!(listed[0]["sizes"][0]["cols"], Value::Null);
    assert_eq!(listed[0]["sizes"][0]["rows"], Value::Null);
    assert!((0..4).any(|_| matches!(
        events.recv_timeout(Duration::from_secs(1)),
        Ok(MuxEvent::ClientChanged { client: id, .. }) if id == client
    )));
}

#[test]
fn attached_unreported_client_suppresses_global_ignore_size_fallback() {
    let mux = test_mux();
    let surface = sizing_browser(&mux, (100, 40));
    let reporter_writer = test_writer();
    let reporter = mux.control_clients.register(ClientTransport::Unix, reporter_writer.clone());
    let reporter_stream = reporter_writer.start_stream(&json!({"event": "test"})).unwrap();
    mux.control_clients.attach_surface(reporter, surface.id, reporter_stream).unwrap();
    handle_command(
        &mux,
        reporter,
        Command::ResizeSurface { surface: surface.id, cols: 100, rows: 40 },
        &reporter_writer,
    )
    .unwrap();
    handle_command(
        &mux,
        reporter,
        Command::SetClientSizing {
            surface: surface.id,
            client: Some(reporter),
            enabled: false,
            exclusive: false,
        },
        &reporter_writer,
    )
    .unwrap();

    let blocker_writer = test_writer();
    let blocker = mux.control_clients.register(ClientTransport::Unix, blocker_writer.clone());
    let blocker_stream = blocker_writer.start_stream(&json!({"event": "test"})).unwrap();
    mux.control_clients.attach_surface(blocker, surface.id, blocker_stream).unwrap();

    handle_command(
        &mux,
        reporter,
        Command::ResizeSurface { surface: surface.id, cols: 70, rows: 20 },
        &reporter_writer,
    )
    .unwrap();
    assert_eq!(surface.size(), (100, 40));

    handle_command(
        &mux,
        blocker,
        Command::SetClientSizing {
            surface: surface.id,
            client: Some(blocker),
            enabled: false,
            exclusive: false,
        },
        &blocker_writer,
    )
    .unwrap();
    settle_browser_size(&surface, (70, 20));
}

#[test]
fn unsized_attach_invalidates_excluded_fallback_creation_default() {
    let mux = test_mux();
    let surface = sizing_browser(&mux, (100, 40));
    let reporter_writer = test_writer();
    let reporter = mux.control_clients.register(ClientTransport::Unix, reporter_writer.clone());
    let reporter_stream = reporter_writer.start_stream(&json!({"event": "reporter"})).unwrap();
    let reporter_stream_id = reporter_stream.id;
    let reporter_attach =
        mark_client_attached(&mux, reporter, surface.id, reporter_stream, Some((70, 20))).unwrap();
    settle_marked_browser_resize(&surface, &reporter_attach);
    commit_client_attach(
        &mux,
        reporter,
        surface.id,
        reporter_stream_id,
        reporter_attach.client_changed,
        reporter_attach.size_rollback,
    )
    .unwrap();
    assert_eq!(mux.set_client_size_participation(surface.id, reporter, false), Some(true));
    assert_eq!(mux.new_workspace(None, None).unwrap().size(), (70, 20));

    let blocker_writer = test_writer();
    let blocker = mux.control_clients.register(ClientTransport::Unix, blocker_writer.clone());
    let blocker_stream = blocker_writer.start_stream(&json!({"event": "blocker"})).unwrap();
    let blocker_stream_id = blocker_stream.id;
    let blocker_attach =
        mark_client_attached(&mux, blocker, surface.id, blocker_stream, None).unwrap();
    commit_client_attach(
        &mux,
        blocker,
        surface.id,
        blocker_stream_id,
        blocker_attach.client_changed,
        blocker_attach.size_rollback,
    )
    .unwrap();

    mux.resize_surface_for_control_client_with_reservation(surface.id, reporter, 60, 18).unwrap();

    assert_eq!(surface.size(), (70, 20));
    assert_eq!(mux.new_workspace(None, None).unwrap().size(), (80, 24));
}

#[test]
fn remaining_view_takes_the_grid_when_the_newer_owner_stops_counting() {
    // Shared sizing (`latest`): when the newest owner stops counting, the
    // next counting view takes the grid in the same step, so a laptop
    // regains its size when a phone stops sizing the terminal.
    let mux = test_mux();
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    mux.pin_latest_size_policy_for_test(surface.id);
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
    let laptop = join(120, 40);
    let phone = join(66, 52);
    assert_eq!(surface.size(), (66, 52));

    mux.set_client_size_participation(surface.id, phone, false).unwrap();
    assert_eq!(surface.size(), (120, 40));
    let state = mux.terminal_size_state(surface.id).unwrap();
    assert_eq!(state.owners, [format!("c{laptop}")]);
}

#[test]
fn departed_owner_never_reclaims_terminal_geometry() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    mux.pin_latest_size_policy_for_test(surface.id);
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
    let laptop = join(120, 40);
    let phone = join(66, 52);
    assert_eq!(surface.size(), (66, 52));

    // A disconnected view leaves the engine and never returns; with no
    // counting view left the grid keeps its last size.
    assert!(disconnect_client(&mux, laptop, false));
    assert!(disconnect_client(&mux, phone, false));
    assert_eq!(surface.size(), (66, 52));
    let state = mux.terminal_size_state(surface.id).unwrap();
    assert!(state.participants.is_empty());
}

#[test]
fn unsized_attach_preserves_newer_explicit_creation_default() {
    let mux = test_mux();
    let surface = sizing_browser(&mux, (100, 40));
    let reporter_writer = test_writer();
    let reporter = mux.control_clients.register(ClientTransport::Unix, reporter_writer.clone());
    let reporter_stream = reporter_writer.start_stream(&json!({"event": "reporter"})).unwrap();
    let reporter_stream_id = reporter_stream.id;
    let reporter_attach =
        mark_client_attached(&mux, reporter, surface.id, reporter_stream, Some((80, 24))).unwrap();
    settle_marked_browser_resize(&surface, &reporter_attach);
    commit_client_attach(
        &mux,
        reporter,
        surface.id,
        reporter_stream_id,
        reporter_attach.client_changed,
        reporter_attach.size_rollback,
    )
    .unwrap();

    assert_eq!(mux.new_workspace(None, Some((120, 40))).unwrap().size(), (120, 40));

    let blocker_writer = test_writer();
    let blocker = mux.control_clients.register(ClientTransport::Unix, blocker_writer.clone());
    let blocker_stream = blocker_writer.start_stream(&json!({"event": "blocker"})).unwrap();
    let blocker_stream_id = blocker_stream.id;
    let blocker_attach =
        mark_client_attached(&mux, blocker, surface.id, blocker_stream, None).unwrap();
    commit_client_attach(
        &mux,
        blocker,
        surface.id,
        blocker_stream_id,
        blocker_attach.client_changed,
        blocker_attach.size_rollback,
    )
    .unwrap();

    assert_eq!(mux.new_workspace(None, None).unwrap().size(), (120, 40));
}

#[test]
fn final_stream_detach_restores_excluded_report_fallback() {
    let mux = test_mux();
    let surface = sizing_browser(&mux, (100, 40));
    let reporter_writer = test_writer();
    let reporter = mux.control_clients.register(ClientTransport::Unix, reporter_writer.clone());
    let reporter_stream = reporter_writer.start_stream(&json!({"event": "test"})).unwrap();
    mux.control_clients.attach_surface(reporter, surface.id, reporter_stream).unwrap();
    handle_command(
        &mux,
        reporter,
        Command::ResizeSurface { surface: surface.id, cols: 70, rows: 20 },
        &reporter_writer,
    )
    .unwrap();
    settle_browser_size(&surface, (70, 20));
    handle_command(
        &mux,
        reporter,
        Command::SetClientSizing {
            surface: surface.id,
            client: Some(reporter),
            enabled: false,
            exclusive: false,
        },
        &reporter_writer,
    )
    .unwrap();

    let blocker_writer = test_writer();
    let blocker = mux.control_clients.register(ClientTransport::Unix, blocker_writer.clone());
    let blocker_stream = blocker_writer.start_stream(&json!({"event": "test"})).unwrap();
    let blocker_stream_id = blocker_stream.id;
    mux.control_clients.attach_surface(blocker, surface.id, blocker_stream).unwrap();
    mux.resize_surface(surface.id, 100, 40).unwrap();
    settle_browser_size(&surface, (100, 40));

    assert!(
        mux.control_clients.detach_surface(blocker, surface.id, blocker_stream_id).final_stream
    );
    mux.remove_surface_size_client(surface.id, blocker);

    settle_browser_size(&surface, (70, 20));
    assert!(!mux.control_clients.attached_client_ids().contains(&blocker));
}

#[test]
fn final_stream_detach_of_excluded_unsized_client_preserves_newer_geometry() {
    let mux = test_mux();
    let surface = sizing_browser(&mux, (100, 40));
    let reporter_writer = test_writer();
    let reporter = mux.control_clients.register(ClientTransport::Unix, reporter_writer.clone());
    let reporter_stream = reporter_writer.start_stream(&json!({"event": "test"})).unwrap();
    mux.control_clients.attach_surface(reporter, surface.id, reporter_stream).unwrap();
    handle_command(
        &mux,
        reporter,
        Command::ResizeSurface { surface: surface.id, cols: 70, rows: 20 },
        &reporter_writer,
    )
    .unwrap();
    settle_browser_size(&surface, (70, 20));
    handle_command(
        &mux,
        reporter,
        Command::SetClientSizing {
            surface: surface.id,
            client: Some(reporter),
            enabled: false,
            exclusive: false,
        },
        &reporter_writer,
    )
    .unwrap();

    let blocker_writer = test_writer();
    let blocker = mux.control_clients.register(ClientTransport::Unix, blocker_writer.clone());
    let blocker_stream = blocker_writer.start_stream(&json!({"event": "test"})).unwrap();
    let blocker_stream_id = blocker_stream.id;
    mux.control_clients.attach_surface(blocker, surface.id, blocker_stream).unwrap();
    handle_command(
        &mux,
        blocker,
        Command::SetClientSizing {
            surface: surface.id,
            client: Some(blocker),
            enabled: false,
            exclusive: false,
        },
        &blocker_writer,
    )
    .unwrap();
    mux.resize_surface(surface.id, 100, 40).unwrap();
    settle_browser_size(&surface, (100, 40));

    assert!(
        mux.control_clients.detach_surface(blocker, surface.id, blocker_stream_id).final_stream
    );
    mux.remove_surface_size_client(surface.id, blocker);

    settle_browser_size(&surface, (100, 40));
}

#[test]
fn final_stream_detach_does_not_recalculate_other_surface() {
    let mux = test_mux();
    let blocker_surface = sizing_browser(&mux, (100, 40));
    let reported_surface = sizing_browser(&mux, (100, 40));
    let reporter_writer = test_writer();
    let reporter = mux.control_clients.register(ClientTransport::Unix, reporter_writer.clone());
    let reporter_stream = reporter_writer.start_stream(&json!({"event": "test"})).unwrap();
    mux.control_clients.attach_surface(reporter, reported_surface.id, reporter_stream).unwrap();
    handle_command(
        &mux,
        reporter,
        Command::ResizeSurface { surface: reported_surface.id, cols: 70, rows: 20 },
        &reporter_writer,
    )
    .unwrap();
    settle_browser_size(&reported_surface, (70, 20));
    handle_command(
        &mux,
        reporter,
        Command::SetClientSizing {
            surface: reported_surface.id,
            client: Some(reporter),
            enabled: false,
            exclusive: false,
        },
        &reporter_writer,
    )
    .unwrap();

    let blocker_writer = test_writer();
    let blocker = mux.control_clients.register(ClientTransport::Unix, blocker_writer.clone());
    let blocker_stream = blocker_writer.start_stream(&json!({"event": "test"})).unwrap();
    let blocker_stream_id = blocker_stream.id;
    mux.control_clients.attach_surface(blocker, blocker_surface.id, blocker_stream).unwrap();
    mux.resize_surface(reported_surface.id, 100, 40).unwrap();
    settle_browser_size(&reported_surface, (100, 40));

    assert!(
        mux.control_clients
            .detach_surface(blocker, blocker_surface.id, blocker_stream_id)
            .final_stream
    );
    mux.remove_surface_size_client(blocker_surface.id, blocker);

    settle_browser_size(&reported_surface, (100, 40));
}

#[test]
fn failed_reducer_resize_restores_registry_size() {
    let mux = test_mux();
    let missing_surface = 99_999;
    let writer = test_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let stream = writer.start_stream(&json!({"event": "test"})).unwrap();
    let stream_id = stream.id;
    mux.control_clients.attach_surface(client, missing_surface, stream).unwrap();
    mux.control_clients.commit_surface(client, missing_surface, stream_id, None).unwrap();

    assert!(
        mux.resize_surface_for_control_client_with_reservation(missing_surface, client, 70, 20,)
            .is_err()
    );

    let clients = mux.control_clients.list_json(client);
    assert_eq!(clients[0]["sizes"][0]["surface"], missing_surface);
    assert_eq!(clients[0]["sizes"][0]["cols"], Value::Null);
    assert_eq!(clients[0]["sizes"][0]["rows"], Value::Null);
}

#[test]
fn failed_attach_rollback_does_not_restore_disconnected_client_size() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, Some((100, 40))).unwrap();
    let writer = test_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let stream = writer.start_stream(&json!({"event": "test"})).unwrap();
    mux.control_clients.attach_surface(client, surface.id, stream).unwrap();
    let resize =
        mux.resize_surface_for_control_client_with_reservation(surface.id, client, 70, 20).unwrap();
    assert_eq!(mux.client_surface_size(surface.id, client), Some((70, 20)));

    assert!(disconnect_client(&mux, client, false));
    mux.rollback_surface_size_client(surface.id, client, resize.rollback);

    assert_eq!(mux.client_surface_size(surface.id, client), None);
    assert!(!mux.control_clients.contains(client));
}

#[test]
fn rejected_attach_rollback_keeps_registry_at_actual_size() {
    let mux = test_mux();
    let surface = sizing_browser(&mux, (100, 40));
    let writer = test_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let stream = writer.start_stream(&json!({"event": "test"})).unwrap();
    let stream_id = stream.id;
    mux.control_clients.attach_surface(client, surface.id, stream).unwrap();
    mux.control_clients.commit_surface(client, surface.id, stream_id, None).unwrap();
    mux.resize_surface_for_control_client_with_reservation(surface.id, client, 80, 24).unwrap();
    settle_browser_size(&surface, (80, 24));
    let changed =
        mux.resize_surface_for_control_client_with_reservation(surface.id, client, 70, 20).unwrap();
    settle_browser_size(&surface, (70, 20));

    let removed = mux.remove_surface_runtime_for_test(surface.id).unwrap();
    mux.rollback_surface_size_client(surface.id, client, changed.rollback);

    assert_eq!(mux.client_surface_size(surface.id, client), Some((70, 20)));
    let clients = mux.control_clients.list_json(client);
    assert_eq!(clients[0]["sizes"][0]["cols"], 70);
    assert_eq!(clients[0]["sizes"][0]["rows"], 20);
    removed.kill();
}

#[test]
fn unrelated_attach_does_not_cancel_failed_surface_rollback_repair() {
    let mux = test_mux();
    let surface = sizing_browser(&mux, (100, 40));
    let unrelated_surface = sizing_browser(&mux, (100, 40));
    let writer = test_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let stream = writer.start_stream(&json!({"event": "test"})).unwrap();
    let stream_id = stream.id;
    mux.control_clients.attach_surface(client, surface.id, stream).unwrap();
    mux.control_clients.commit_surface(client, surface.id, stream_id, None).unwrap();
    mux.resize_surface_for_control_client_with_reservation(surface.id, client, 80, 24).unwrap();
    settle_browser_size(&surface, (80, 24));
    let changed =
        mux.resize_surface_for_control_client_with_reservation(surface.id, client, 70, 20).unwrap();
    settle_browser_size(&surface, (70, 20));

    let unrelated_writer = test_writer();
    let unrelated_client =
        mux.control_clients.register(ClientTransport::Unix, unrelated_writer.clone());
    let unrelated_stream = unrelated_writer.start_stream(&json!({"event": "test"})).unwrap();
    mux.set_client_rollback_before_wait(Some(Arc::new({
        let hook_mux = mux.clone();
        move || {
            hook_mux
                .control_clients
                .attach_surface(unrelated_client, unrelated_surface.id, unrelated_stream.clone())
                .unwrap();
        }
    })));
    let removed = mux.remove_surface_runtime_for_test(surface.id).unwrap();

    mux.rollback_surface_size_client(surface.id, client, changed.rollback);
    mux.set_client_rollback_before_wait(None);

    assert_eq!(mux.client_surface_size(surface.id, client), Some((70, 20)));
    let clients = mux.control_clients.list_json(client);
    let client = clients.as_array().unwrap().iter().find(|entry| entry["self"] == true).unwrap();
    assert_eq!(client["sizes"][0]["cols"], 70);
    assert_eq!(client["sizes"][0]["rows"], 20);
    removed.kill();
}

#[test]
fn disconnect_cleanup_wins_over_a_waiting_stale_sizing_action() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, Some((100, 40))).unwrap();
    let writer = test_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let stream = writer.start_stream(&json!({"event": "test"})).unwrap();
    mux.control_clients.attach_surface(client, surface.id, stream).unwrap();
    mux.resize_surface_for_control_client_with_reservation(surface.id, client, 80, 24).unwrap();

    let lifecycle = mux.lock_client_sizing_lifecycle();
    let (ready_tx, ready_rx) = std::sync::mpsc::sync_channel(1);
    let action_mux = mux.clone();
    let action = std::thread::spawn(move || {
        ready_tx.send(()).unwrap();
        action_mux.set_client_size_participation(surface.id, client, false)
    });
    ready_rx.recv_timeout(Duration::from_secs(1)).unwrap();

    let removed = mux.control_clients.remove(client).expect("registered client");
    mux.remove_size_client(client);
    drop(removed);
    drop(lifecycle);

    assert_eq!(action.join().unwrap(), None);
    assert!(!mux.control_clients.contains(client));
}

#[test]
fn detached_client_cannot_fall_through_to_direct_resize() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, Some((100, 40))).unwrap();
    let writer = test_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    assert!(disconnect_client(&mux, client, false));

    let error = handle_command(
        &mux,
        client,
        Command::ResizeSurface { surface: surface.id, cols: 70, rows: 20 },
        &writer,
    )
    .unwrap_err();

    // A disconnected id is unregistered, so dispatch fails closed before
    // the resize path (server/remote_relay: never local trust).
    assert_eq!(error.to_string(), "remote_denied");
    assert_eq!(surface.size(), (100, 40));
}

#[test]
fn unattached_live_resize_still_obeys_visible_client_minimum() {
    let mux = test_mux();
    let surface = sizing_browser(&mux, (100, 40));
    let viewer_writer = test_writer();
    let viewer = mux.control_clients.register(ClientTransport::Unix, viewer_writer.clone());
    let stream = viewer_writer.start_stream(&json!({"event": "test"})).unwrap();
    mux.control_clients.attach_surface(viewer, surface.id, stream).unwrap();
    handle_command(
        &mux,
        viewer,
        Command::ResizeSurface { surface: surface.id, cols: 100, rows: 40 },
        &viewer_writer,
    )
    .unwrap();

    let control_writer = test_writer();
    let control = mux.control_clients.register(ClientTransport::Unix, control_writer.clone());
    handle_command(
        &mux,
        control,
        Command::ResizeSurface { surface: surface.id, cols: 120, rows: 50 },
        &control_writer,
    )
    .unwrap();
    assert_eq!(surface.size(), (100, 40));

    handle_command(
        &mux,
        control,
        Command::ResizeSurface { surface: surface.id, cols: 70, rows: 20 },
        &control_writer,
    )
    .unwrap();
    settle_browser_size(&surface, (70, 20));

    assert!(disconnect_client(&mux, control, false));
    settle_browser_size(&surface, (100, 40));
}

#[test]
fn terminal_viewer_that_opts_out_never_takes_geometry() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, Some((100, 40))).unwrap();
    let target_writer = test_writer();
    let target = mux.control_clients.register(ClientTransport::Unix, target_writer.clone());
    let target_stream = target_writer.start_stream(&json!({"event": "test"})).unwrap();
    mux.control_clients.attach_surface(target, surface.id, target_stream).unwrap();
    handle_command(
        &mux,
        target,
        Command::ResizeSurface { surface: surface.id, cols: 120, rows: 40 },
        &target_writer,
    )
    .unwrap();
    handle_command(
        &mux,
        target,
        Command::SetClientSizing {
            surface: surface.id,
            client: Some(target),
            enabled: true,
            exclusive: true,
        },
        &target_writer,
    )
    .unwrap();

    let later_writer = test_writer();
    let later = mux.control_clients.register(ClientTransport::Unix, later_writer.clone());
    let later_stream = later_writer.start_stream(&json!({"event": "test"})).unwrap();
    let later_stream_id = later_stream.id;
    mux.control_clients.attach_surface(later, surface.id, later_stream).unwrap();
    mux.control_clients.commit_surface(later, surface.id, later_stream_id, None).unwrap();
    // tmux `attach -f ignore-size`: the later viewer opts out first.
    mux.sync_terminal_client_view(surface.id, later);
    handle_command(
        &mux,
        later,
        Command::SetSizeCounts {
            surface: surface.id,
            client: None,
            lease: None,
            view: None,
            participant: None,
            counts: Some(false),
        },
        &later_writer,
    )
    .unwrap();
    handle_command(
        &mux,
        later,
        Command::ResizeSurface { surface: surface.id, cols: 60, rows: 20 },
        &later_writer,
    )
    .unwrap();

    assert_eq!(surface.size(), (120, 40));
    assert!(!mux.client_size_participates(surface.id, later));
    let clients = mux.control_clients_json(target);
    assert_eq!(
        clients.as_array().unwrap().iter().find(|client| client["client"] == later).unwrap()["sizes"]
            [0]["size_participating"],
        false
    );
}

#[test]
fn enabling_late_unsized_terminal_client_takes_geometry_on_first_report() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, Some((100, 40))).unwrap();
    let target_writer = test_writer();
    let target = mux.control_clients.register(ClientTransport::Unix, target_writer.clone());
    let target_stream = target_writer.start_stream(&json!({"event": "test"})).unwrap();
    mux.control_clients.attach_surface(target, surface.id, target_stream).unwrap();
    handle_command(
        &mux,
        target,
        Command::ResizeSurface { surface: surface.id, cols: 120, rows: 40 },
        &target_writer,
    )
    .unwrap();
    handle_command(
        &mux,
        target,
        Command::SetClientSizing {
            surface: surface.id,
            client: Some(target),
            enabled: true,
            exclusive: true,
        },
        &target_writer,
    )
    .unwrap();

    let late_writer = test_writer();
    let late = mux.control_clients.register(ClientTransport::Unix, late_writer.clone());
    let late_stream = late_writer.start_stream(&json!({"event": "test"})).unwrap();
    mux.control_clients.attach_surface(late, surface.id, late_stream).unwrap();
    assert!(!mux.client_size_participates(surface.id, late));

    let other_writer = test_writer();
    let other = mux.control_clients.register(ClientTransport::Unix, other_writer.clone());
    let other_stream = other_writer.start_stream(&json!({"event": "test"})).unwrap();
    mux.control_clients.attach_surface(other, surface.id, other_stream).unwrap();
    assert!(!mux.client_size_participates(surface.id, other));

    handle_command(
        &mux,
        late,
        Command::SetClientSizing {
            surface: surface.id,
            client: Some(late),
            enabled: true,
            exclusive: false,
        },
        &late_writer,
    )
    .unwrap();

    // Without a viewport the late view cannot set the grid, so the
    // current owner keeps it instead of freezing.
    assert!(!mux.client_size_participates(surface.id, late));
    assert!(mux.client_size_participates(surface.id, target));
    assert_eq!(surface.size(), (120, 40));

    handle_command(
        &mux,
        late,
        Command::ResizeSurface { surface: surface.id, cols: 90, rows: 30 },
        &late_writer,
    )
    .unwrap();
    assert!(mux.client_size_participates(surface.id, late));
    assert!(!mux.client_size_participates(surface.id, target));
    assert!(!mux.client_size_participates(surface.id, other));
    assert_eq!(surface.size(), (90, 30));
}

#[test]
fn disabling_late_unsized_terminal_client_preserves_geometry_authority() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, Some((100, 40))).unwrap();
    let target_writer = test_writer();
    let target = mux.control_clients.register(ClientTransport::Unix, target_writer.clone());
    let target_stream = target_writer.start_stream(&json!({"event": "test"})).unwrap();
    mux.control_clients.attach_surface(target, surface.id, target_stream).unwrap();
    handle_command(
        &mux,
        target,
        Command::ResizeSurface { surface: surface.id, cols: 120, rows: 40 },
        &target_writer,
    )
    .unwrap();
    handle_command(
        &mux,
        target,
        Command::SetClientSizing {
            surface: surface.id,
            client: Some(target),
            enabled: true,
            exclusive: true,
        },
        &target_writer,
    )
    .unwrap();

    let late_writer = test_writer();
    let late = mux.control_clients.register(ClientTransport::Unix, late_writer.clone());
    let late_stream = late_writer.start_stream(&json!({"event": "test"})).unwrap();
    mux.control_clients.attach_surface(late, surface.id, late_stream).unwrap();
    handle_command(
        &mux,
        late,
        Command::SetClientSizing {
            surface: surface.id,
            client: Some(late),
            enabled: false,
            exclusive: false,
        },
        &late_writer,
    )
    .unwrap();

    let newest_writer = test_writer();
    let newest = mux.control_clients.register(ClientTransport::Unix, newest_writer.clone());
    let newest_stream = newest_writer.start_stream(&json!({"event": "test"})).unwrap();
    mux.control_clients.attach_surface(newest, surface.id, newest_stream).unwrap();
    assert!(!mux.client_size_participates(surface.id, newest));
}

#[test]
fn ignored_report_does_not_replace_unsized_creation_default() {
    let mux = test_mux();
    let surface = sizing_browser(&mux, (100, 40));

    let blocker_writer = test_writer();
    let blocker = mux.control_clients.register(ClientTransport::Unix, blocker_writer.clone());
    let blocker_stream = blocker_writer.start_stream(&json!({"event": "test"})).unwrap();
    mux.control_clients.attach_surface(blocker, surface.id, blocker_stream).unwrap();

    let reporter_writer = test_writer();
    let reporter = mux.control_clients.register(ClientTransport::Unix, reporter_writer.clone());
    let reporter_stream = reporter_writer.start_stream(&json!({"event": "test"})).unwrap();
    mux.control_clients.attach_surface(reporter, surface.id, reporter_stream).unwrap();
    handle_command(
        &mux,
        reporter,
        Command::SetClientSizing {
            surface: surface.id,
            client: Some(reporter),
            enabled: false,
            exclusive: false,
        },
        &reporter_writer,
    )
    .unwrap();
    handle_command(
        &mux,
        reporter,
        Command::ResizeSurface { surface: surface.id, cols: 60, rows: 20 },
        &reporter_writer,
    )
    .unwrap();

    assert_eq!(surface.size(), (100, 40));
    assert_eq!(mux.new_workspace(None, None).unwrap().size(), (100, 40));
}

#[test]
fn browser_attach_initial_sizes_share_the_smallest_viewer_grid() {
    let mux = test_mux();
    let surface = sizing_browser(&mux, (120, 40));
    let first_writer = test_writer();
    let second_writer = test_writer();
    let first = mux.control_clients.register(ClientTransport::Unix, first_writer.clone());
    let second = mux.control_clients.register(ClientTransport::Unix, second_writer.clone());
    let first_stream = first_writer.start_stream(&json!({"event": "test"})).unwrap();
    let second_stream = second_writer.start_stream(&json!({"event": "test"})).unwrap();

    let first_attach =
        mark_client_attached(&mux, first, surface.id, first_stream.clone(), Some((100, 30)))
            .unwrap();
    settle_marked_browser_resize(&surface, &first_attach);
    let second_attach =
        mark_client_attached(&mux, second, surface.id, second_stream.clone(), Some((80, 35)))
            .unwrap();
    settle_marked_browser_resize(&surface, &second_attach);

    assert_eq!(mux.client_surface_size(surface.id, first), Some((100, 30)));
    assert_eq!(mux.client_surface_size(surface.id, second), Some((80, 35)));
    settle_browser_size(&surface, (80, 30));

    cleanup_failed_attach(&mux, first, surface.id, first_stream.id);
    assert_eq!(mux.client_surface_size(surface.id, first), None);
    settle_browser_size(&surface, (80, 35));

    cleanup_failed_attach(&mux, second, surface.id, second_stream.id);
    assert_eq!(mux.client_surface_size(surface.id, second), None);
    assert!(mux.surface(surface.id).is_some());
}

#[test]
fn secondary_attach_detach_restores_the_surviving_stream_size() {
    let mux = test_mux();
    let surface = sizing_browser(&mux, (120, 40));
    let writer = test_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let first_stream = writer.start_stream(&json!({"event": "first"})).unwrap();
    let second_stream = writer.start_stream(&json!({"event": "second"})).unwrap();

    let first =
        mark_client_attached(&mux, client, surface.id, first_stream.clone(), Some((100, 30)))
            .unwrap();
    settle_marked_browser_resize(&surface, &first);
    commit_client_attach(
        &mux,
        client,
        surface.id,
        first_stream.id,
        first.client_changed,
        first.size_rollback,
    )
    .unwrap();
    let second =
        mark_client_attached(&mux, client, surface.id, second_stream.clone(), Some((80, 24)))
            .unwrap();
    settle_marked_browser_resize(&surface, &second);
    commit_client_attach(
        &mux,
        client,
        surface.id,
        second_stream.id,
        second.client_changed,
        second.size_rollback,
    )
    .unwrap();
    settle_browser_size(&surface, (80, 24));

    detach_committed_attach(&mux, client, surface.id, second_stream.id);

    assert_eq!(mux.client_surface_size(surface.id, client), Some((100, 30)));
    settle_browser_size(&surface, (100, 30));
    let listed = mux.control_clients.list_json(client);
    assert_eq!(listed[0]["sizes"][0]["cols"].as_u64(), Some(100));
    assert_eq!(listed[0]["sizes"][0]["rows"].as_u64(), Some(30));

    detach_committed_attach(&mux, client, surface.id, first_stream.id);
}
