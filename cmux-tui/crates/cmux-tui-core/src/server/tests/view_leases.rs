//! View attachment leases and attach failure cleanup.

use super::*;

#[test]
fn attachment_leases_fence_independent_same_connection_views() {
    let mux = test_mux();
    let surface = sizing_browser(&mux, (120, 40));
    let other_surface = mux.new_workspace(None, Some((90, 30))).unwrap();
    let writer = test_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    handle_command(
        &mux,
        client,
        Command::SetClientInfo {
            name: Some("lease test".to_string()),
            kind: Some("tui".to_string()),
            capabilities: Some(vec![
                VIEW_ATTACHMENT_LEASE_CAPABILITY.to_string(),
                VIEW_ATTACHMENT_DETACH_CAPABILITY.to_string(),
            ]),
            user_id: None,
            display_name: None,
            device_kind: None,
            device_name: None,
            device_id: None,
        },
        &writer,
    )
    .unwrap();

    let first_stream = writer.start_stream(&json!({"event": "first"})).unwrap();
    let first_attach =
        mark_client_attached(&mux, client, surface.id, first_stream.clone(), Some((100, 30)))
            .unwrap();
    let first_lease = first_attach.lease.clone().expect("negotiated attach omitted its lease");
    settle_marked_browser_resize(&surface, &first_attach);
    commit_client_attach(
        &mux,
        client,
        surface.id,
        first_stream.id,
        first_attach.client_changed,
        first_attach.size_rollback,
    )
    .unwrap();

    let second_stream = writer.start_stream(&json!({"event": "second"})).unwrap();
    let second_attach =
        mark_client_attached(&mux, client, surface.id, second_stream.clone(), Some((80, 24)))
            .unwrap();
    let second_lease =
        second_attach.lease.clone().expect("second negotiated attach omitted its lease");
    settle_marked_browser_resize(&surface, &second_attach);
    commit_client_attach(
        &mux,
        client,
        surface.id,
        second_stream.id,
        second_attach.client_changed,
        second_attach.size_rollback,
    )
    .unwrap();

    assert_ne!(first_lease, second_lease);
    assert_eq!(surface.size(), (100, 30));
    let owner = handle_command(
        &mux,
        client,
        Command::ResizeAttachedView {
            surface: surface.id,
            lease: Some(first_lease.clone()),
            view: None,
            identity: None,
            cols: 110,
            rows: 35,
        },
        &writer,
    )
    .unwrap();
    assert_eq!(owner["outcome"], "applied");
    settle_browser_size(&surface, (110, 35));

    let passive = handle_command(
        &mux,
        client,
        Command::ResizeAttachedView {
            surface: surface.id,
            lease: Some(second_lease.clone()),
            view: None,
            identity: None,
            cols: 70,
            rows: 20,
        },
        &writer,
    )
    .unwrap();
    assert_eq!(passive["outcome"], "passive");
    assert_eq!(surface.size(), (110, 35));

    let geometry_before_invalid_requests = surface.size();
    for (request_client, request_surface, lease, expected) in [
        (client, surface.id, "fabricated".to_string(), "invalid or foreign"),
        (client, other_surface.id, second_lease.clone(), "belongs to surface"),
    ] {
        let error = handle_command(
            &mux,
            request_client,
            Command::ResizeAttachedView {
                surface: request_surface,
                lease: Some(lease),
                view: None,
                identity: None,
                cols: 40,
                rows: 10,
            },
            &writer,
        )
        .unwrap_err();
        assert!(error.to_string().contains(expected), "unexpected lease error: {error:#}");
    }
    let foreign_writer = test_writer();
    let foreign = mux.control_clients.register(ClientTransport::Unix, foreign_writer.clone());
    let foreign_error = handle_command(
        &mux,
        foreign,
        Command::ResizeAttachedView {
            surface: surface.id,
            lease: Some(second_lease.clone()),
            view: None,
            identity: None,
            cols: 40,
            rows: 10,
        },
        &foreign_writer,
    )
    .unwrap_err();
    assert!(foreign_error.to_string().contains("invalid or foreign"));
    assert_eq!(surface.size(), geometry_before_invalid_requests);

    let detached = handle_command(
        &mux,
        client,
        Command::DetachAttachedView {
            surface: surface.id,
            lease: Some(first_lease.clone()),
            view: None,
        },
        &writer,
    )
    .unwrap();
    assert_eq!(detached["outcome"], "applied");
    assert!(!first_stream.is_open());
    let repeated = handle_command(
        &mux,
        client,
        Command::DetachAttachedView {
            surface: surface.id,
            lease: Some(first_lease.clone()),
            view: None,
        },
        &writer,
    )
    .unwrap();
    assert_eq!(repeated["outcome"], "superseded");
    settle_browser_size(&surface, (70, 20));
    for command in [
        Command::ResizeAttachedView {
            surface: surface.id,
            lease: Some(first_lease.clone()),
            view: None,
            identity: None,
            cols: 60,
            rows: 18,
        },
        Command::ReleaseAttachedViewSize {
            surface: surface.id,
            lease: Some(first_lease.clone()),
            view: None,
        },
    ] {
        let retired = handle_command(&mux, client, command, &writer).unwrap();
        assert_eq!(retired["outcome"], "superseded");
    }

    let promoted = handle_command(
        &mux,
        client,
        Command::ResizeAttachedView {
            surface: surface.id,
            lease: Some(second_lease.clone()),
            view: None,
            identity: None,
            cols: 90,
            rows: 28,
        },
        &writer,
    )
    .unwrap();
    assert_eq!(promoted["outcome"], "applied");
    settle_browser_size(&surface, (90, 28));

    detach_committed_attach(&mux, client, surface.id, second_stream.id);
    let retired = handle_command(
        &mux,
        client,
        Command::ResizeAttachedView {
            surface: surface.id,
            lease: Some(second_lease.clone()),
            view: None,
            identity: None,
            cols: 55,
            rows: 16,
        },
        &writer,
    )
    .unwrap();
    assert_eq!(retired["outcome"], "superseded");

    let third_stream = writer.start_stream(&json!({"event": "third"})).unwrap();
    let third_attach =
        mark_client_attached(&mux, client, surface.id, third_stream.clone(), Some((75, 22)))
            .unwrap();
    let third_lease = third_attach.lease.clone().expect("reattach omitted its lease");
    settle_marked_browser_resize(&surface, &third_attach);
    commit_client_attach(
        &mux,
        client,
        surface.id,
        third_stream.id,
        third_attach.client_changed,
        third_attach.size_rollback,
    )
    .unwrap();
    assert_ne!(third_lease, first_lease);
    assert_ne!(third_lease, second_lease);
    let old_after_reattach = handle_command(
        &mux,
        client,
        Command::ReleaseAttachedViewSize {
            surface: surface.id,
            lease: Some(second_lease),
            view: None,
        },
        &writer,
    )
    .unwrap();
    assert_eq!(old_after_reattach["outcome"], "superseded");
    assert_eq!(surface.size(), (75, 22));

    assert!(disconnect_client(&mux, client, true));
    assert!(mux.surface(surface.id).is_some(), "disconnect must not close the terminal");
    assert!(!mux.control_clients.contains(client));
    assert!(disconnect_client(&mux, foreign, true));
}

#[test]
fn attachment_resize_waits_for_detach_lifecycle_and_becomes_superseded() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, Some((100, 30))).unwrap();
    let writer = test_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    handle_command(
        &mux,
        client,
        Command::SetClientInfo {
            name: Some("lease fence".to_string()),
            kind: Some("tui".to_string()),
            capabilities: Some(vec![VIEW_ATTACHMENT_LEASE_CAPABILITY.to_string()]),
            user_id: None,
            display_name: None,
            device_kind: None,
            device_name: None,
            device_id: None,
        },
        &writer,
    )
    .unwrap();
    let stream = writer.start_stream(&json!({"event": "fence"})).unwrap();
    let surface_id = surface.id;
    let lease = mux
        .control_clients
        .attach_surface(client, surface_id, stream.clone())
        .unwrap()
        .expect("negotiated attach omitted its lease");
    mux.control_clients.commit_surface(client, surface_id, stream.id, None).unwrap();

    let lifecycle = mux.lock_client_sizing_lifecycle();
    let (started_tx, started_rx) = std::sync::mpsc::sync_channel(1);
    let (result_tx, result_rx) = std::sync::mpsc::sync_channel(1);
    let resize_mux = mux.clone();
    let resize_writer = writer;
    let resize = std::thread::spawn(move || {
        started_tx.send(()).unwrap();
        let result = handle_command(
            &resize_mux,
            client,
            Command::ResizeAttachedView {
                surface: surface_id,
                lease: Some(lease),
                view: None,
                identity: None,
                cols: 80,
                rows: 24,
            },
            &resize_writer,
        );
        result_tx.send(result).unwrap();
    });
    started_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    assert!(
        result_rx.recv_timeout(Duration::from_millis(100)).is_err(),
        "resize crossed the held detach lifecycle fence"
    );

    let detached = mux.control_clients.detach_surface(client, surface_id, stream.id);
    assert!(detached.final_stream);
    mux.remove_surface_size_client(surface_id, client);
    drop(lifecycle);

    let result = result_rx.recv_timeout(Duration::from_secs(1)).unwrap().unwrap();
    assert_eq!(result["outcome"], "superseded");
    resize.join().unwrap();
    assert_eq!(mux.client_surface_size(surface_id, client), None);
    assert!(disconnect_client(&mux, client, true));
    mux.close_surface(surface_id).unwrap();
}

#[test]
fn terminal_view_leases_converge_after_500_rapid_attach_resize_detach_cycles() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, Some((120, 40))).unwrap();
    let writer = test_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    handle_command(
        &mux,
        client,
        Command::SetClientInfo {
            name: Some("lease stress".to_string()),
            kind: Some("tui".to_string()),
            capabilities: Some(vec![VIEW_ATTACHMENT_LEASE_CAPABILITY.to_string()]),
            user_id: None,
            display_name: None,
            device_kind: None,
            device_name: None,
            device_id: None,
        },
        &writer,
    )
    .unwrap();

    for cycle in 0_u16..500 {
        let initial = (80 + cycle % 31, 20 + cycle % 13);
        let resized = (90 + cycle % 23, 24 + cycle % 11);
        let stream = writer.start_stream(&json!({"event": "stress", "cycle": cycle})).unwrap();
        let marked =
            mark_client_attached(&mux, client, surface.id, stream.clone(), Some(initial)).unwrap();
        let lease = marked.lease.clone().expect("negotiated attach omitted its lease");
        commit_client_attach(
            &mux,
            client,
            surface.id,
            stream.id,
            marked.client_changed,
            marked.size_rollback,
        )
        .unwrap();
        let resize = handle_command(
            &mux,
            client,
            Command::ResizeAttachedView {
                surface: surface.id,
                lease: Some(lease.clone()),
                view: None,
                identity: None,
                cols: resized.0,
                rows: resized.1,
            },
            &writer,
        )
        .unwrap();
        assert_eq!(resize["outcome"], "applied", "cycle {cycle}");

        detach_committed_attach(&mux, client, surface.id, stream.id);
        let stale = handle_command(
            &mux,
            client,
            Command::ResizeAttachedView {
                surface: surface.id,
                lease: Some(lease),
                view: None,
                identity: None,
                cols: 40,
                rows: 10,
            },
            &writer,
        )
        .unwrap();
        assert_eq!(stale["outcome"], "superseded", "cycle {cycle}");
        assert_eq!(mux.client_surface_size(surface.id, client), None, "cycle {cycle}");
    }

    assert!(mux.surface(surface.id).is_some());
    assert!(mux.control_clients.list_json(client)[0]["attached"].as_array().unwrap().is_empty());
    assert!(disconnect_client(&mux, client, true));
    mux.close_surface(surface.id).unwrap();
}

#[test]
fn failed_attach_cleanup_releases_stream_and_size_lease() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, Some((120, 40))).unwrap();
    let writer = test_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let stream = writer.start_stream(&json!({"event": "test"})).unwrap();

    mux.control_clients.attach_surface(client, surface.id, stream.clone()).unwrap();
    mux.resize_surface_for_control_client_with_reservation(surface.id, client, 80, 24).unwrap();
    cleanup_failed_attach(&mux, client, surface.id, stream.id);

    assert!(!mux.control_clients.attached_client_ids().contains(&client));
    assert_eq!(mux.client_surface_size(surface.id, client), None);
}

#[test]
fn failed_first_attach_restores_pre_attach_surface_geometry() {
    let mux = test_mux();
    let surface = sizing_browser(&mux, (120, 40));
    let writer = test_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let stream = writer.start_stream(&json!({"event": "test"})).unwrap();

    let marked =
        mark_client_attached(&mux, client, surface.id, stream.clone(), Some((80, 24))).unwrap();
    settle_marked_browser_resize(&surface, &marked);
    settle_browser_size(&surface, (80, 24));

    rollback_failed_attach(&mux, client, surface.id, stream.id, marked.size_rollback);

    assert_eq!(surface.size(), (120, 40));
    assert_eq!(mux.client_surface_size(surface.id, client), None);
    assert!(!mux.control_clients.attached_client_ids().contains(&client));
}

#[test]
fn attach_rollback_wait_does_not_hold_global_sizing_locks() {
    let mux = test_mux();
    let failed_surface = sizing_browser(&mux, (120, 40));
    let unrelated_surface = sizing_browser(&mux, (100, 30));
    let writer = test_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let stream = writer.start_stream(&json!({"event": "test"})).unwrap();
    mux.control_clients.attach_surface(client, failed_surface.id, stream).unwrap();
    let resize = mux
        .resize_surface_for_control_client_with_reservation(failed_surface.id, client, 80, 24)
        .unwrap();
    settle_browser_size(&failed_surface, (80, 24));

    let entered = Arc::new(std::sync::Barrier::new(2));
    let resume = Arc::new(std::sync::Barrier::new(2));
    mux.set_client_rollback_before_wait(Some(Arc::new({
        let entered = entered.clone();
        let resume = resume.clone();
        move || {
            entered.wait();
            resume.wait();
        }
    })));
    let rollback_mux = mux.clone();
    let rollback = std::thread::spawn(move || {
        rollback_mux.rollback_surface_size_client(failed_surface.id, client, resize.rollback);
    });
    entered.wait();

    let (resized_tx, resized_rx) = std::sync::mpsc::sync_channel(1);
    let resize_mux = mux.clone();
    let unrelated = unrelated_surface.id;
    let resize_thread = std::thread::spawn(move || {
        resized_tx.send(resize_mux.resize_surface_for_client(unrelated, 9_999, 70, 20)).unwrap();
    });
    assert!(resized_rx.recv_timeout(Duration::from_secs(1)).unwrap().unwrap());

    resume.wait();
    rollback.join().unwrap();
    resize_thread.join().unwrap();
    mux.set_client_rollback_before_wait(None);
}

#[test]
fn failed_secondary_attach_preserves_surviving_stream_size_lease() {
    let mux = test_mux();
    let surface = sizing_browser(&mux, (120, 40));
    let writer = test_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let first = writer.start_stream(&json!({"event": "test"})).unwrap();
    let failed = writer.start_stream(&json!({"event": "test"})).unwrap();

    let first = mark_client_attached(&mux, client, surface.id, first, Some((80, 24))).unwrap();
    settle_marked_browser_resize(&surface, &first);
    let rollback =
        mark_client_attached(&mux, client, surface.id, failed.clone(), Some((60, 20))).unwrap();
    settle_marked_browser_resize(&surface, &rollback);
    assert_eq!(mux.client_surface_size(surface.id, client), Some((60, 20)));
    settle_browser_size(&surface, (60, 20));
    rollback_failed_attach(&mux, client, surface.id, failed.id, rollback.size_rollback);

    assert!(mux.control_clients.attached_client_ids().contains(&client));
    assert_eq!(mux.client_surface_size(surface.id, client), Some((80, 24)));
    settle_browser_size(&surface, (80, 24));
}

#[test]
fn failed_attach_setup_does_not_announce_or_suppress_retry() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, Some((120, 40))).unwrap();
    let writer = test_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let events = mux.subscribe();
    let failed_stream = writer.start_stream(&json!({"event": "test"})).unwrap();

    assert!(
        mark_client_attached(&mux, client, surface.id + 10_000, failed_stream, Some((80, 24)),)
            .is_err()
    );
    assert!(!events.try_iter().any(|event| matches!(event, MuxEvent::ClientAttached { .. })));
    assert!(!mux.control_clients.attached_client_ids().contains(&client));

    let retry_stream = writer.start_stream(&json!({"event": "test"})).unwrap();
    let retry_stream_id = retry_stream.id;
    mark_client_attached(&mux, client, surface.id, retry_stream, Some((80, 24))).unwrap();
    let staged = mux.control_clients.list_json(client);
    assert_eq!(staged[0]["attached"], json!([]));
    assert_eq!(staged[0]["sizes"], json!([]));
    assert!(!events.try_iter().any(|event| matches!(
        event,
        MuxEvent::ClientAttached { .. } | MuxEvent::ClientChanged { .. }
    )));
    commit_client_attach(&mux, client, surface.id, retry_stream_id, None, None).unwrap();

    assert!(matches!(
        events.recv_timeout(Duration::from_secs(1)),
        Ok(MuxEvent::ClientAttached { client: attached, .. }) if attached == client
    ));
}

#[test]
fn attach_worker_cleanup_starts_after_stream_commit() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, Some((120, 40))).unwrap();
    let writer = test_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let stream = writer.start_stream(&json!({"event": "test"})).unwrap();
    let stream_id = stream.id;
    let surface_id = surface.id;
    let marked = mark_client_attached(&mux, client, surface_id, stream, None).unwrap();
    let lifecycle = AttachLifecycle::default();
    let (worker_start, worker_committed) = std::sync::mpsc::sync_channel(1);
    let (observed_tx, observed_rx) = std::sync::mpsc::sync_channel(1);
    let worker_mux = mux.clone();
    let worker = std::thread::spawn(move || {
        worker_committed.recv().unwrap();
        let clients = worker_mux.control_clients.list_json(client);
        let attached = clients[0]["attached"]
            .as_array()
            .is_some_and(|surfaces| surfaces.contains(&json!(surface_id)));
        observed_tx.send(attached).unwrap();
        cleanup_failed_attach(&worker_mux, client, surface_id, stream_id);
    });

    commit_client_attach_and_start_worker(
        &mux,
        client,
        surface_id,
        stream_id,
        AttachWorkerCommit {
            start: worker_start,
            lifecycle,
            changed: marked.client_changed,
            size_rollback: marked.size_rollback,
        },
    )
    .unwrap();

    assert!(observed_rx.recv_timeout(Duration::from_secs(1)).unwrap());
    worker.join().unwrap();
}
