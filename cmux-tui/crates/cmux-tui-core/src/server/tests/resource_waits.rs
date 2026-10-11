//! Browser provider sharing and resource-protocol waits: coalescing, cancellation, exit resolution and worker capacity.

use super::*;

#[test]
fn browser_provider_clients_share_one_process_without_sharing_client_state() {
    let mux = test_mux();
    let first_writer = test_writer();
    let first = mux.control_clients.register(ClientTransport::Unix, first_writer.clone());
    let second_writer = test_writer();
    let second = mux.control_clients.register(ClientTransport::Unix, second_writer.clone());
    let command = |tab_id: &str, target_id: &str| Command::RegisterBrowserProvider {
        provider_id: "browser-process-1".into(),
        endpoint: "ws://localhost:9222/devtools/browser/one".into(),
        authentication: "none".into(),
        bearer_token: None,
        targets: vec![BrowserProviderTargetRequest {
            tab_id: tab_id.into(),
            target_id: target_id.into(),
        }],
    };
    handle_command(
        &mux,
        first,
        command("tab_00000000000000000000000000000001", "target-one"),
        &first_writer,
    )
    .unwrap();
    let snapshot = handle_command(
        &mux,
        second,
        command("tab_00000000000000000000000000000002", "target-two"),
        &second_writer,
    )
    .unwrap();
    assert_eq!(snapshot["clients"], 2);
    assert_eq!(snapshot["targets"].as_array().unwrap().len(), 2);

    assert!(disconnect_client(&mux, first, false));
    let snapshot = mux.browser_provider_snapshot().unwrap();
    assert_eq!(snapshot.clients, 1);
    assert_eq!(snapshot.targets.len(), 1);
}

#[test]
fn protocol_v1_is_rejected_before_returning_a_zero_view_terminal_snapshot() {
    let mux = test_mux();
    let surface = mux.new_workspace(Some("exiting".into()), None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().unwrap();
    surface.record_process_end_for_test(crate::terminal_host_protocol::TerminalExit::now(
        crate::terminal_host_protocol::TerminalExitOutcome::Exit { code: 0 },
    ));
    mux.surface_exited(surface.id);

    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let current_request = serde_json::to_string(&json!({
        "protocol":crate::resource::PROTOCOL,
        "type":"request",
        "id":"current-zero-view-snapshot",
        "operation":"session.snapshot",
        "params":{"machine":"current","session":"current"},
    }))
    .unwrap();

    assert!(handle_connection_message(&mux, client, &current_request, &writer, &scheduler));
    let current_response = pop_json(&outbound);
    assert_eq!(current_response["ok"], true);
    let terminal = current_response["result"]["terminals"]
        .as_array()
        .unwrap()
        .iter()
        .find(|terminal| terminal["id"] == terminal_id.as_str())
        .expect("the actual response contains the durable exit receipt");
    assert_eq!(terminal["tab_id"], Value::Null);
    assert_eq!(terminal["tab_ids"], json!([]));

    let legacy_request = serde_json::to_string(&json!({
        "protocol":"cmux.protocol/1",
        "type":"request",
        "id":"legacy-zero-view-snapshot",
        "operation":"session.snapshot",
        "params":{"machine":"current","session":"current"},
    }))
    .unwrap();

    assert!(handle_connection_message(&mux, client, &legacy_request, &writer, &scheduler));
    let response = pop_json(&outbound);

    assert_eq!(response["protocol"], crate::resource::PROTOCOL);
    assert_eq!(response["type"], "response");
    assert_eq!(response["id"], "legacy-zero-view-snapshot");
    assert_eq!(response["ok"], false);
    assert_eq!(response["error"]["code"], "validation.invalid");
    assert_eq!(response["error"]["details"]["field"], "protocol");
    assert!(response.get("result").is_none());

    disconnect_client(&mux, client, false);
    mux.shutdown();
}

#[test]
fn terminal_waits_do_not_block_ping_or_stream_cancel_on_the_same_connection() {
    let mux = test_mux();
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let create = resource_request(
        "create-for-waits",
        "workspace.create",
        json!({
            "machine":"current",
            "session":"current",
            "initial_content":"terminal",
        }),
        Some("create-for-waits"),
    );
    assert!(handle_connection_message(&mux, client, &create, &writer, &scheduler));
    let created = pop_json(&outbound);
    assert_eq!(created["ok"], true, "{created}");
    let terminal_id =
        created["result"]["value"]["terminal_id"].as_str().expect("created terminal ID");
    let stream_id = "stream_00000000000000000000000000000042";
    let open = resource_request(
        "events-open-for-wait",
        "session.events",
        json!({
            "machine":"current",
            "session":"current",
            "stream_id":stream_id,
        }),
        None,
    );
    assert!(handle_connection_message(&mux, client, &open, &writer, &scheduler));
    assert_eq!(pop_json(&outbound)["id"], "events-open-for-wait");
    assert_eq!(pop_json(&outbound)["type"], "stream_item");

    for (id, operation, extra) in [
        ("screen-wait", "terminal.wait", json!({"pattern":"cmux-pattern-that-never-matches"})),
        ("process-wait", "terminal.wait_exit", json!({})),
    ] {
        let mut params = json!({
            "machine":"current",
            "session":"current",
            "terminal":terminal_id,
            "timeout_ms":"250",
        });
        params.as_object_mut().unwrap().extend(extra.as_object().unwrap().clone());
        let wait = resource_request(id, operation, params, None);
        assert!(handle_connection_message(&mux, client, &wait, &writer, &scheduler));
    }

    let ping = resource_request(
        "ping-during-waits",
        "session.ping",
        json!({"machine":"current","session":"current"}),
        None,
    );
    assert!(handle_connection_message(&mux, client, &ping, &writer, &scheduler));
    let cancel = resource_request(
        "cancel-during-waits",
        "stream.cancel",
        json!({
            "machine":"current",
            "session":"current",
            "stream":stream_id,
        }),
        None,
    );
    assert!(handle_connection_message(&mux, client, &cancel, &writer, &scheduler));

    let first = pop_json(&outbound);
    assert_eq!(
        first["id"], "ping-during-waits",
        "a wait completed before the same-connection ping: {first}"
    );
    let messages = (0..4).map(|_| pop_json(&outbound)).collect::<Vec<_>>();
    assert!(
        messages.iter().any(|message| {
            message["type"] == "stream_end" && message["stream_id"] == stream_id
        })
    );
    let responses =
        messages.iter().filter(|message| message["type"] == "response").collect::<Vec<_>>();
    assert!(
        responses.iter().all(|response| response["ok"] == true),
        "wait/cancel responses failed: {responses:?}"
    );
    assert!(responses.iter().any(|response| response["id"] == "cancel-during-waits"));
    let wait_ids = responses
        .iter()
        .filter_map(|response| response["id"].as_str())
        .filter(|id| *id != "cancel-during-waits")
        .map(str::to_string)
        .collect::<std::collections::BTreeSet<_>>();
    assert_eq!(
        wait_ids,
        ["process-wait".to_string(), "screen-wait".to_string()].into_iter().collect()
    );

    disconnect_client(&mux, client, false);
}

#[test]
fn connection_terminal_wait_coalesces_more_than_attach_capacity() {
    let mux = test_mux();
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let create = resource_request(
        "create-for-coalesced-wait",
        "workspace.create",
        json!({
            "machine":"current",
            "session":"current",
            "initial_content":"terminal",
        }),
        Some("create-for-coalesced-wait"),
    );
    assert!(handle_connection_message(&mux, client, &create, &writer, &scheduler));
    let created = pop_json(&outbound);
    let terminal_id =
        TerminalPublicId::parse(created["result"]["value"]["terminal_id"].as_str().unwrap())
            .unwrap();
    let surface = mux
        .resource_surface_for_terminal(&terminal_id)
        .and_then(|surface| mux.surface(surface))
        .expect("created terminal surface");
    let wait = resource_request(
        "coalesced-wait",
        "terminal.wait",
        json!({
            "machine":"current",
            "session":"current",
            "terminal":terminal_id,
            "pattern":"READY",
            "timeout_ms":"2000",
        }),
        None,
    );
    assert!(handle_connection_message(&mux, client, &wait, &writer, &scheduler));

    let waiting_deadline = Instant::now() + Duration::from_secs(1);
    while surface.terminal_stream_waiter_count_for_test() != Some(1) {
        assert!(Instant::now() < waiting_deadline, "terminal wait did not subscribe");
        std::thread::yield_now();
    }
    for _ in 0..300 {
        surface.apply_stream_output_for_test(b"\r").unwrap();
    }
    surface.apply_stream_output_for_test(b"READY").unwrap();

    let response = pop_json(&outbound);
    assert_eq!(response["id"], "coalesced-wait");
    assert_eq!(response["ok"], true, "{response}");
    assert_eq!(response["result"]["matched"], true, "{response}");
    disconnect_client(&mux, client, false);
}

#[test]
fn request_cancel_suppresses_target_response_and_reuses_request_id_and_capacity() {
    let mux = test_mux();
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let create = resource_request(
        "create-for-request-cancel",
        "workspace.create",
        json!({
            "machine":"current",
            "session":"current",
            "initial_content":"terminal",
        }),
        Some("create-for-request-cancel"),
    );
    assert!(handle_connection_message(&mux, client, &create, &writer, &scheduler));
    let created = pop_json(&outbound);
    let terminal_id =
        TerminalPublicId::parse(created["result"]["value"]["terminal_id"].as_str().unwrap())
            .unwrap();
    let surface = mux
        .resource_surface_for_terminal(&terminal_id)
        .and_then(|surface| mux.surface(surface))
        .expect("created terminal surface");

    let wait = resource_request(
        "reused-request-id",
        "terminal.wait",
        json!({
            "machine":"current",
            "session":"current",
            "terminal":terminal_id,
            "pattern":"cmux-request-cancel-never-matches",
        }),
        None,
    );
    assert!(handle_connection_message(&mux, client, &wait, &writer, &scheduler));
    let waiting_deadline = Instant::now() + Duration::from_secs(1);
    while surface.terminal_stream_waiter_count_for_test() != Some(1) {
        assert!(Instant::now() < waiting_deadline, "terminal wait did not subscribe");
        std::thread::yield_now();
    }
    assert_eq!(mux.control_clients.resource_wait_admission.active(), 1);

    let cancel = resource_request(
        "cancel-reused-request-id",
        "request.cancel",
        json!({"request_id":"reused-request-id"}),
        None,
    );
    assert!(handle_connection_message(&mux, client, &cancel, &writer, &scheduler));
    let canceled = pop_json(&outbound);
    assert_eq!(canceled["id"], "cancel-reused-request-id");
    assert_eq!(canceled["ok"], true, "{canceled}");
    assert_eq!(canceled["result"], json!({"canceled":true}));
    assert_eq!(
        mux.control_clients.resource_wait_admission.active(),
        0,
        "cancel confirmation preceded worker permit release"
    );
    assert_eq!(surface.terminal_stream_waiter_count_for_test(), Some(0));
    assert!(outbound.try_pop().is_none(), "canceled target emitted a response");

    let repeated = resource_request(
        "repeat-cancel",
        "request.cancel",
        json!({"request_id":"reused-request-id"}),
        None,
    );
    assert!(handle_connection_message(&mux, client, &repeated, &writer, &scheduler));
    assert_eq!(pop_json(&outbound)["result"], json!({"canceled":false}));

    let replacement = resource_request(
        "reused-request-id",
        "terminal.wait",
        json!({
            "machine":"current",
            "session":"current",
            "terminal":terminal_id,
            "pattern":"CMUX_REUSED_REQUEST_READY",
        }),
        None,
    );
    assert!(handle_connection_message(&mux, client, &replacement, &writer, &scheduler));
    let waiting_deadline = Instant::now() + Duration::from_secs(1);
    while surface.terminal_stream_waiter_count_for_test() != Some(1) {
        assert!(Instant::now() < waiting_deadline, "replacement terminal wait did not subscribe");
        std::thread::yield_now();
    }
    surface.apply_stream_output_for_test(b"CMUX_REUSED_REQUEST_READY").unwrap();
    let replacement = pop_json(&outbound);
    assert_eq!(replacement["id"], "reused-request-id");
    assert_eq!(replacement["result"]["matched"], true, "{replacement}");

    let cleanup_deadline = Instant::now() + Duration::from_secs(1);
    while mux.control_clients.resource_wait_admission.active() != 0 {
        assert!(Instant::now() < cleanup_deadline, "completed wait retained admission");
        std::thread::yield_now();
    }
    assert!(disconnect_client(&mux, client, false));
}

#[test]
fn request_cancel_wakes_wait_exit_and_is_connection_local() {
    let mux = test_mux();
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let (other_writer, other_outbound) = captured_writer();
    let other = mux.control_clients.register(ClientTransport::Unix, other_writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let other_scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let create = resource_request(
        "create-for-wait-exit-cancel",
        "workspace.create",
        json!({
            "machine":"current",
            "session":"current",
            "initial_content":"terminal",
        }),
        Some("create-for-wait-exit-cancel"),
    );
    assert!(handle_connection_message(&mux, client, &create, &writer, &scheduler));
    let created = pop_json(&outbound);
    let terminal_id =
        TerminalPublicId::parse(created["result"]["value"]["terminal_id"].as_str().unwrap())
            .unwrap();
    let wait = resource_request(
        "connection-owned-wait-exit",
        "terminal.wait_exit",
        json!({
            "machine":"current",
            "session":"current",
            "terminal":terminal_id,
        }),
        None,
    );
    assert!(handle_connection_message(&mux, client, &wait, &writer, &scheduler));
    let waiting_deadline = Instant::now() + Duration::from_secs(1);
    while mux.terminal_exit_waiter_count_for_test(&terminal_id) != 1 {
        assert!(Instant::now() < waiting_deadline, "wait_exit did not subscribe");
        std::thread::yield_now();
    }

    let foreign_cancel = resource_request(
        "foreign-cancel",
        "request.cancel",
        json!({"request_id":"connection-owned-wait-exit"}),
        None,
    );
    assert!(handle_connection_message(
        &mux,
        other,
        &foreign_cancel,
        &other_writer,
        &other_scheduler,
    ));
    assert_eq!(pop_json(&other_outbound)["result"], json!({"canceled":false}));
    assert_eq!(mux.terminal_exit_waiter_count_for_test(&terminal_id), 1);

    let owner_cancel = resource_request(
        "owner-cancel",
        "request.cancel",
        json!({"request_id":"connection-owned-wait-exit"}),
        None,
    );
    assert!(handle_connection_message(&mux, client, &owner_cancel, &writer, &scheduler));
    assert_eq!(pop_json(&outbound)["result"], json!({"canceled":true}));
    assert_eq!(
        mux.control_clients.resource_wait_admission.active(),
        0,
        "wait_exit cancel confirmation preceded worker permit release"
    );
    assert_eq!(mux.terminal_exit_waiter_count_for_test(&terminal_id), 0);
    assert!(outbound.try_pop().is_none(), "canceled wait_exit emitted a response");

    assert!(disconnect_client(&mux, other, false));
    assert!(disconnect_client(&mux, client, false));
}

#[test]
fn completion_winner_queues_target_response_before_cancel_false() {
    let mux = test_mux();
    let (writer, outbound, target_send_entered, release_target_send) =
        blocking_control_writer("ordered-target");
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let create = resource_request(
        "create-for-cancel-order",
        "workspace.create",
        json!({
            "machine":"current",
            "session":"current",
            "initial_content":"terminal",
        }),
        Some("create-for-cancel-order"),
    );
    assert!(handle_connection_message(&mux, client, &create, &writer, &scheduler));
    let created = pop_json(&outbound);
    let terminal_id =
        TerminalPublicId::parse(created["result"]["value"]["terminal_id"].as_str().unwrap())
            .unwrap();
    let surface = mux
        .resource_surface_for_terminal(&terminal_id)
        .and_then(|surface| mux.surface(surface))
        .expect("created terminal surface");
    let wait = resource_request(
        "ordered-target",
        "terminal.wait",
        json!({
            "machine":"current",
            "session":"current",
            "terminal":terminal_id,
            "pattern":"CMUX_ORDERED_TARGET_READY",
        }),
        None,
    );
    assert!(handle_connection_message(&mux, client, &wait, &writer, &scheduler));
    let waiting_deadline = Instant::now() + Duration::from_secs(1);
    while surface.terminal_stream_waiter_count_for_test() != Some(1) {
        assert!(Instant::now() < waiting_deadline, "ordered wait did not subscribe");
        std::thread::yield_now();
    }
    surface.apply_stream_output_for_test(b"CMUX_ORDERED_TARGET_READY").unwrap();
    target_send_entered
        .recv_timeout(Duration::from_secs(1))
        .expect("wait completion did not begin its target response");

    let cancel = resource_request(
        "ordered-cancel",
        "request.cancel",
        json!({"request_id":"ordered-target"}),
        None,
    );
    std::thread::scope(|scope| {
        let cancel_mux = mux.clone();
        let cancel_writer = writer.clone();
        let cancel_scheduler = scheduler.clone();
        let cancel = scope.spawn(move || {
            handle_connection_message(
                &cancel_mux,
                client,
                &cancel,
                &cancel_writer,
                &cancel_scheduler,
            )
        });
        std::thread::yield_now();
        assert!(
            outbound.try_pop().is_none(),
            "cancel responded before the completing target attempted its response"
        );
        release_target_send.send(()).unwrap();
        assert!(cancel.join().unwrap());
    });

    let target = pop_json(&outbound);
    let canceled = pop_json(&outbound);
    assert_eq!(target["id"], "ordered-target", "{target}");
    assert_eq!(target["result"]["matched"], true, "{target}");
    assert_eq!(canceled["id"], "ordered-cancel", "{canceled}");
    assert_eq!(canceled["result"], json!({"canceled":false}));
    let cleanup_deadline = Instant::now() + Duration::from_secs(1);
    while mux.control_clients.resource_wait_admission.active() != 0 {
        assert!(Instant::now() < cleanup_deadline, "completed wait retained admission");
        std::thread::yield_now();
    }
    assert!(disconnect_client(&mux, client, false));
}

#[test]
fn request_cancel_and_completion_have_one_atomic_winner() {
    let mux = test_mux();
    let writer = test_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer);
    for index in 0..128 {
        let request_id = ResourceRequestId::parse(format!("request-race-{index}")).unwrap();
        let (canceled, worker_permit) =
            mux.control_clients.install_resource_wait(client, &request_id).unwrap();
        let barrier = Arc::new(std::sync::Barrier::new(2));
        let completion = std::thread::scope(|scope| {
            let completion_barrier = barrier.clone();
            let completion_id = request_id.clone();
            let completion_canceled = canceled.clone();
            let completion_mux = mux.clone();
            let completion = scope.spawn(move || {
                completion_barrier.wait();
                let won = completion_mux.control_clients.begin_resource_wait_completion(
                    client,
                    &completion_id,
                    &completion_canceled,
                );
                if won {
                    completion_canceled.mark_response_attempted();
                    completion_mux.control_clients.finish_resource_wait(
                        client,
                        &completion_id,
                        &completion_canceled,
                    );
                }
                completion_canceled.mark_worker_finished();
                won
            });
            barrier.wait();
            let cancellation = match mux.control_clients.cancel_resource_wait(client, &request_id) {
                ResourceWaitCancel::Missing => false,
                ResourceWaitCancel::Canceled(lifecycle) => {
                    lifecycle.wait_for_worker_finish();
                    true
                }
                ResourceWaitCancel::Completing(lifecycle) => {
                    assert!(lifecycle.wait_for_response_attempt());
                    false
                }
            };
            (completion.join().unwrap(), cancellation)
        });
        assert_ne!(
            completion.0, completion.1,
            "completion and cancellation did not have exactly one winner"
        );
        drop(worker_permit);
    }
    assert_eq!(mux.control_clients.resource_wait_admission.active(), 0);
    assert!(disconnect_client(&mux, client, false));
}

#[test]
fn idle_terminal_wait_worker_registers_once_without_polling() {
    let mux = test_mux();
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let create = resource_request(
        "create-for-idle-screen-wait",
        "workspace.create",
        json!({
            "machine":"current",
            "session":"current",
            "initial_content":"terminal",
        }),
        Some("create-for-idle-screen-wait"),
    );
    assert!(handle_connection_message(&mux, client, &create, &writer, &scheduler));
    let created = pop_json(&outbound);
    let terminal_id =
        TerminalPublicId::parse(created["result"]["value"]["terminal_id"].as_str().unwrap())
            .unwrap();
    let surface = mux
        .resource_surface_for_terminal(&terminal_id)
        .and_then(|surface| mux.surface(surface))
        .expect("created terminal surface");
    let wait = resource_request(
        "idle-screen-wait",
        "terminal.wait",
        json!({
            "machine":"current",
            "session":"current",
            "terminal":terminal_id,
            "pattern":"cmux-idle-pattern-that-never-matches",
        }),
        None,
    );
    assert!(handle_connection_message(&mux, client, &wait, &writer, &scheduler));
    let waiting_deadline = Instant::now() + Duration::from_secs(1);
    while surface.terminal_stream_waiter_count_for_test() != Some(1)
        || surface.terminal_stream_subscription_count_for_test() != Some(1)
    {
        assert!(Instant::now() < waiting_deadline, "terminal wait did not become idle");
        std::thread::yield_now();
    }
    std::thread::sleep(Duration::from_millis(350));
    assert_eq!(
        surface.terminal_stream_subscription_count_for_test(),
        Some(1),
        "idle terminal.wait worker polled"
    );

    let cancel = resource_request(
        "cancel-idle-screen-wait",
        "request.cancel",
        json!({"request_id":"idle-screen-wait"}),
        None,
    );
    assert!(handle_connection_message(&mux, client, &cancel, &writer, &scheduler));
    assert_eq!(pop_json(&outbound)["result"], json!({"canceled":true}));
    let cleanup_deadline = Instant::now() + Duration::from_secs(1);
    while mux.control_clients.resource_wait_admission.active() != 0 {
        assert!(Instant::now() < cleanup_deadline, "idle wait retained admission");
        std::thread::yield_now();
    }
    assert!(disconnect_client(&mux, client, false));
}

#[cfg(unix)]
#[test]
fn connection_wait_exit_resolves_durable_detached_terminal_after_restart() {
    let root = std::env::temp_dir().join(format!(
        "cmux-connection-wait-exit-restart-{}-{}",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    ));
    let session = "connection-wait-exit-restart";
    let first = Mux::open_persistent(session, SurfaceOptions::default(), &root).unwrap();
    let (writer, outbound) = captured_writer();
    let client = first.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(first.surface_operation_admission.clone()));
    let create = resource_request(
        "create-for-restart-exit-wait",
        "workspace.create",
        json!({
            "machine":"current",
            "session":"current",
            "initial_content":"terminal",
        }),
        Some("create-for-restart-exit-wait"),
    );
    assert!(handle_connection_message(&first, client, &create, &writer, &scheduler));
    let created = pop_json(&outbound);
    assert_eq!(created["ok"], true, "{created}");
    let terminal_id =
        TerminalPublicId::parse(created["result"]["value"]["terminal_id"].as_str().unwrap())
            .unwrap();
    let exit = crate::terminal_host_protocol::TerminalExit {
        outcome: crate::terminal_host_protocol::TerminalExitOutcome::Exit { code: 0 },
        exited_at_ms: 4_567_890,
    };
    assert!(first.persist_terminal_exit_for_test(&terminal_id, &exit).unwrap());
    assert_eq!(first.resource_surface_for_terminal(&terminal_id), None);
    assert!(disconnect_client(&first, client, false));
    drop(scheduler);
    drop(writer);
    first.shutdown();
    let shutdown_deadline = Instant::now() + Duration::from_secs(10);
    while Arc::strong_count(&first) > 1 && Instant::now() < shutdown_deadline {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(Arc::strong_count(&first), 1, "terminal workers retained the first mux");
    drop(first);

    let reopened = Mux::open_persistent(session, SurfaceOptions::default(), &root).unwrap();
    let (writer, outbound) = captured_writer();
    let client = reopened.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(reopened.surface_operation_admission.clone()));
    let wait = resource_request(
        "wait-for-exit-after-restart",
        "terminal.wait_exit",
        json!({
            "machine":"current",
            "session":"current",
            "terminal":terminal_id,
            "timeout_ms":"0",
        }),
        None,
    );
    assert!(handle_connection_message(&reopened, client, &wait, &writer, &scheduler));
    let response = pop_json(&outbound);
    assert_eq!(response["ok"], true, "{response}");
    assert_eq!(response["result"]["state"], "exited", "{response}");
    assert_eq!(response["result"]["terminal_id"], terminal_id.as_str(), "{response}");
    assert_eq!(response["result"]["outcome"], json!({"kind":"exit","code":0}));
    assert_eq!(response["result"]["exited_at"], "4567890");

    assert!(disconnect_client(&reopened, client, false));
    reopened.shutdown();
    drop(scheduler);
    drop(writer);
    drop(reopened);
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn idle_wait_exit_workers_do_not_poll_the_terminal_registry() {
    let mux = test_mux();
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let create = resource_request(
        "create-for-idle-exit-waits",
        "workspace.create",
        json!({
            "machine":"current",
            "session":"current",
            "initial_content":"terminal",
        }),
        Some("create-for-idle-exit-waits"),
    );
    assert!(handle_connection_message(&mux, client, &create, &writer, &scheduler));
    let created = pop_json(&outbound);
    let terminal_id =
        TerminalPublicId::parse(created["result"]["value"]["terminal_id"].as_str().unwrap())
            .unwrap();
    mux.reset_terminal_exit_state_query_count_for_test();

    for index in 0..RESOURCE_WAITS_PER_CLIENT_CAPACITY {
        let wait = resource_request(
            &format!("idle-exit-wait-{index}"),
            "terminal.wait_exit",
            json!({
                "machine":"current",
                "session":"current",
                "terminal":terminal_id,
            }),
            None,
        );
        assert!(handle_connection_message(&mux, client, &wait, &writer, &scheduler));
    }
    let admission_deadline = Instant::now() + Duration::from_secs(2);
    while mux.terminal_exit_waiter_count_for_test(&terminal_id)
        != RESOURCE_WAITS_PER_CLIENT_CAPACITY
        || mux.terminal_exit_state_query_count_for_test()
            != RESOURCE_WAITS_PER_CLIENT_CAPACITY as u64
    {
        assert!(Instant::now() < admission_deadline, "exit waits did not become idle");
        std::thread::yield_now();
    }
    std::thread::sleep(Duration::from_millis(350));
    assert_eq!(
        mux.terminal_exit_state_query_count_for_test(),
        RESOURCE_WAITS_PER_CLIENT_CAPACITY as u64,
        "idle wait_exit workers polled the registry"
    );

    assert!(disconnect_client(&mux, client, false));
    let cleanup_deadline = Instant::now() + Duration::from_secs(2);
    while mux.control_clients.resource_wait_admission.active() != 0 {
        assert!(Instant::now() < cleanup_deadline, "canceled exit waits stayed blocked");
        std::thread::yield_now();
    }
    assert_eq!(mux.terminal_exit_waiter_count_for_test(&terminal_id), 0);
    assert_eq!(
        mux.terminal_exit_state_query_count_for_test(),
        RESOURCE_WAITS_PER_CLIENT_CAPACITY as u64,
        "cancellation performed a redundant terminal query"
    );
}

#[test]
fn wait_exit_deadline_performs_only_one_final_targeted_query() {
    let mux = test_mux();
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let create = resource_request(
        "create-for-exit-deadline",
        "workspace.create",
        json!({
            "machine":"current",
            "session":"current",
            "initial_content":"terminal",
        }),
        Some("create-for-exit-deadline"),
    );
    assert!(handle_connection_message(&mux, client, &create, &writer, &scheduler));
    let created = pop_json(&outbound);
    let terminal_id = created["result"]["value"]["terminal_id"].as_str().unwrap();
    mux.reset_terminal_exit_state_query_count_for_test();

    let wait = resource_request(
        "bounded-exit-wait",
        "terminal.wait_exit",
        json!({
            "machine":"current",
            "session":"current",
            "terminal":terminal_id,
            "timeout_ms":"25",
        }),
        None,
    );
    assert!(handle_connection_message(&mux, client, &wait, &writer, &scheduler));
    let response = pop_json(&outbound);
    assert_eq!(response["id"], "bounded-exit-wait");
    assert_eq!(response["ok"], true, "{response}");
    assert_eq!(response["result"]["state"], "pending", "{response}");
    assert_eq!(response["result"]["lifecycle"], "running", "{response}");
    assert_eq!(
        mux.terminal_exit_state_query_count_for_test(),
        2,
        "a deadline should perform one initial and one final query"
    );

    let cleanup_deadline = Instant::now() + Duration::from_secs(1);
    while mux.control_clients.resource_wait_admission.active() != 0 {
        assert!(Instant::now() < cleanup_deadline, "bounded exit wait retained admission");
        std::thread::yield_now();
    }
    disconnect_client(&mux, client, false);
}

#[test]
fn concurrent_terminal_close_settles_unbounded_connection_wait_exit() {
    let mux = test_mux();
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let create = resource_request(
        "create-for-close-exit-wait",
        "workspace.create",
        json!({
            "machine":"current",
            "session":"current",
            "initial_content":"terminal",
        }),
        Some("create-for-close-exit-wait"),
    );
    assert!(handle_connection_message(&mux, client, &create, &writer, &scheduler));
    let created = pop_json(&outbound);
    let terminal_id =
        TerminalPublicId::parse(created["result"]["value"]["terminal_id"].as_str().unwrap())
            .unwrap();
    mux.reset_terminal_exit_state_query_count_for_test();

    let wait = resource_request(
        "wait-until-concurrent-close",
        "terminal.wait_exit",
        json!({
            "machine":"current",
            "session":"current",
            "terminal":terminal_id,
        }),
        None,
    );
    assert!(handle_connection_message(&mux, client, &wait, &writer, &scheduler));
    let waiting_deadline = Instant::now() + Duration::from_secs(1);
    while mux.terminal_exit_waiter_count_for_test(&terminal_id) != 1
        || mux.terminal_exit_state_query_count_for_test() != 1
    {
        assert!(Instant::now() < waiting_deadline, "exit wait did not subscribe");
        std::thread::yield_now();
    }

    let close = resource_request(
        "close-terminal-during-exit-wait",
        "terminal.close",
        json!({
            "machine":"current",
            "session":"current",
            "terminal":terminal_id,
        }),
        Some("close-terminal-during-exit-wait"),
    );
    assert!(handle_connection_message(&mux, client, &close, &writer, &scheduler));
    let responses = [pop_json(&outbound), pop_json(&outbound)];
    let close_response =
        responses.iter().find(|response| response["id"] == "close-terminal-during-exit-wait");
    let wait_response =
        responses.iter().find(|response| response["id"] == "wait-until-concurrent-close");
    let close_response = close_response.expect("terminal close response");
    let wait_response = wait_response.expect("terminal wait_exit response");
    assert_eq!(close_response["ok"], true, "{close_response}");
    assert_eq!(wait_response["ok"], false, "{wait_response}");
    assert_eq!(wait_response["error"]["code"], "terminal.closed");
    assert_eq!(wait_response["error"]["details"]["terminal_id"], terminal_id.as_str());
    assert_eq!(mux.terminal_exit_state_query_count_for_test(), 2);
    assert_eq!(mux.terminal_exit_waiter_count_for_test(&terminal_id), 0);

    let cleanup_deadline = Instant::now() + Duration::from_secs(1);
    while mux.control_clients.resource_wait_admission.active() != 0 {
        assert!(Instant::now() < cleanup_deadline, "settled exit wait retained admission");
        std::thread::yield_now();
    }
    disconnect_client(&mux, client, false);
}

#[test]
fn disconnect_cancels_unbounded_terminal_waits_and_releases_worker_capacity() {
    let mux = test_mux();
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let create = resource_request(
        "create-for-unbounded-waits",
        "workspace.create",
        json!({
            "machine":"current",
            "session":"current",
            "initial_content":"terminal",
        }),
        Some("create-for-unbounded-waits"),
    );
    assert!(handle_connection_message(&mux, client, &create, &writer, &scheduler));
    let created = pop_json(&outbound);
    let terminal_id =
        created["result"]["value"]["terminal_id"].as_str().expect("created terminal ID");

    for index in 0..RESOURCE_WAITS_PER_CLIENT_CAPACITY {
        let wait = resource_request(
            &format!("unbounded-wait-{index}"),
            "terminal.wait",
            json!({
                "machine":"current",
                "session":"current",
                "terminal":terminal_id,
                "pattern":format!("cmux-pattern-that-never-matches-{index}"),
            }),
            None,
        );
        assert!(handle_connection_message(&mux, client, &wait, &writer, &scheduler));
    }
    let admission_deadline = Instant::now() + Duration::from_secs(2);
    while mux.control_clients.resource_wait_admission.active() != RESOURCE_WAITS_PER_CLIENT_CAPACITY
    {
        assert!(Instant::now() < admission_deadline, "wait workers did not start");
        std::thread::sleep(Duration::from_millis(2));
    }

    let rejected = resource_request(
        "unbounded-wait-rejected",
        "terminal.wait",
        json!({
            "machine":"current",
            "session":"current",
            "terminal":terminal_id,
            "pattern":"cmux-pattern-that-never-matches-rejected",
        }),
        None,
    );
    assert!(handle_connection_message(&mux, client, &rejected, &writer, &scheduler));
    let rejection = pop_json(&outbound);
    assert_eq!(rejection["id"], "unbounded-wait-rejected");
    assert_eq!(rejection["error"]["code"], "operation.failed");
    assert_eq!(rejection["error"]["details"]["extra"]["reason_code"], "terminal_wait_capacity");
    assert_eq!(rejection["error"]["details"]["extra"]["scope"], "client");

    assert!(disconnect_client(&mux, client, false));
    let cleanup_deadline = Instant::now() + Duration::from_secs(2);
    while mux.control_clients.resource_wait_admission.active() != 0 {
        assert!(
            Instant::now() < cleanup_deadline,
            "disconnected unbounded waits retained worker capacity"
        );
        std::thread::sleep(Duration::from_millis(2));
    }
}

#[test]
fn writer_close_cancels_unbounded_wait_before_client_registry_cleanup() {
    let mux = test_mux();
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let create = resource_request(
        "create-for-writer-close-wait",
        "workspace.create",
        json!({
            "machine":"current",
            "session":"current",
            "initial_content":"terminal",
        }),
        Some("create-for-writer-close-wait"),
    );
    assert!(handle_connection_message(&mux, client, &create, &writer, &scheduler));
    let created = pop_json(&outbound);
    let terminal_id =
        created["result"]["value"]["terminal_id"].as_str().expect("created terminal ID");
    let wait = resource_request(
        "writer-close-wait",
        "terminal.wait_exit",
        json!({
            "machine":"current",
            "session":"current",
            "terminal":terminal_id,
        }),
        None,
    );
    assert!(handle_connection_message(&mux, client, &wait, &writer, &scheduler));
    assert_eq!(mux.control_clients.resource_wait_admission.active(), 1);
    let terminal_id = TerminalPublicId::parse(terminal_id).unwrap();
    let waiting_deadline = Instant::now() + Duration::from_secs(1);
    while mux.terminal_exit_waiter_count_for_test(&terminal_id) != 1 {
        assert!(Instant::now() < waiting_deadline, "exit wait did not subscribe");
        std::thread::yield_now();
    }

    writer.close();
    assert!(
        mux.control_clients.contains(client),
        "test must isolate writer failure from registry disconnect"
    );
    let cleanup_deadline = Instant::now() + Duration::from_secs(2);
    while mux.control_clients.resource_wait_admission.active() != 0 {
        assert!(
            Instant::now() < cleanup_deadline,
            "closed writer retained terminal wait worker capacity"
        );
        std::thread::sleep(Duration::from_millis(2));
    }
    assert!(mux.control_clients.contains(client));
    assert!(disconnect_client(&mux, client, false));
}

#[test]
fn zero_timeout_terminal_waits_complete_once_and_release_worker_capacity() {
    let mux = test_mux();
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let create = resource_request(
        "create-for-zero-wait",
        "workspace.create",
        json!({
            "machine":"current",
            "session":"current",
            "initial_content":"terminal",
        }),
        Some("create-for-zero-wait"),
    );
    assert!(handle_connection_message(&mux, client, &create, &writer, &scheduler));
    let created = pop_json(&outbound);
    let terminal_id =
        created["result"]["value"]["terminal_id"].as_str().expect("created terminal ID");
    let wait = resource_request(
        "zero-timeout-wait",
        "terminal.wait",
        json!({
            "machine":"current",
            "session":"current",
            "terminal":terminal_id,
            "pattern":"cmux-pattern-that-never-matches-zero-timeout",
            "timeout_ms":"0",
        }),
        None,
    );
    assert!(handle_connection_message(&mux, client, &wait, &writer, &scheduler));
    let response = pop_json(&outbound);
    assert_eq!(response["id"], "zero-timeout-wait");
    assert_eq!(response["ok"], true);
    assert_eq!(response["result"]["matched"], false);

    let wait_exit = resource_request(
        "zero-timeout-wait-exit",
        "terminal.wait_exit",
        json!({
            "machine":"current",
            "session":"current",
            "terminal":terminal_id,
            "timeout_ms":"0",
        }),
        None,
    );
    assert!(handle_connection_message(&mux, client, &wait_exit, &writer, &scheduler));
    let response = pop_json(&outbound);
    assert_eq!(response["id"], "zero-timeout-wait-exit");
    assert_eq!(response["ok"], true);
    assert_eq!(response["result"]["state"], "pending");

    let cleanup_deadline = Instant::now() + Duration::from_secs(2);
    while mux.control_clients.resource_wait_admission.active() != 0 {
        assert!(Instant::now() < cleanup_deadline, "zero-timeout wait retained capacity");
        std::thread::sleep(Duration::from_millis(2));
    }
    assert!(disconnect_client(&mux, client, false));
}

#[test]
fn resource_stream_capacity_is_stable_and_reused_after_worker_exit() {
    let mux = test_mux();
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let mut installed = Vec::new();
    for index in 0..RESOURCE_STREAMS_PER_CLIENT_CAPACITY {
        let stream_id = test_stream_id(index as u64 + 1);
        let stream = writer.start_stream(&json!({})).unwrap();
        let (canceled, worker_permit) = mux
            .control_clients
            .install_resource_stream(client, &stream_id, stream)
            .expect("stream below the per-client capacity");
        installed.push((stream_id, canceled, worker_permit));
    }
    assert_eq!(
        mux.control_clients.resource_stream_admission.active(),
        RESOURCE_STREAMS_PER_CLIENT_CAPACITY
    );

    let overflow_id = test_stream_id(10_000);
    let denied_outbound = writer.start_stream(&json!({})).unwrap();
    let denied =
        register_resource_outbound(&mux, client, &overflow_id, &denied_outbound, "session.events");
    let Err(denied) = denied else { panic!("stream above capacity was admitted") };
    assert_eq!(denied.code, "operation.failed");
    assert!(!denied_outbound.is_open(), "denied stream retained an open outbound handle");
    assert_eq!(
        mux.control_clients.resource_stream_admission.active(),
        RESOURCE_STREAMS_PER_CLIENT_CAPACITY,
        "denied stream consumed admission capacity"
    );
    let open_overflow = |request_id: &str| {
        resource_request(
            request_id,
            "session.events",
            json!({
                "machine":"current",
                "session":"current",
                "stream_id":overflow_id,
            }),
            None,
        )
    };
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    assert!(handle_connection_message(
        &mux,
        client,
        &open_overflow("stream-overflow-first"),
        &writer,
        &scheduler,
    ));
    let first_rejection = pop_json(&outbound);
    assert_eq!(first_rejection["error"]["code"], "operation.failed");
    assert_eq!(
        first_rejection["error"]["details"]["extra"]["reason_code"],
        "resource_stream_capacity"
    );
    assert_eq!(first_rejection["error"]["details"]["extra"]["scope"], "client");
    assert_eq!(
        first_rejection["error"]["details"]["extra"]["limit"],
        RESOURCE_STREAMS_PER_CLIENT_CAPACITY
    );

    let (first_id, first_canceled, first_worker_permit) = installed.remove(0);
    drop(
        mux.control_clients
            .take_resource_stream(client, &first_id)
            .expect("installed stream remains registered"),
    );
    assert!(first_canceled.load(Ordering::Acquire));
    assert!(handle_connection_message(
        &mux,
        client,
        &open_overflow("stream-overflow-worker-still-live"),
        &writer,
        &scheduler,
    ));
    assert_eq!(pop_json(&outbound)["error"]["code"], "operation.failed");

    drop(first_worker_permit);
    assert!(handle_connection_message(
        &mux,
        client,
        &open_overflow("stream-overflow-reused"),
        &writer,
        &scheduler,
    ));
    assert_eq!(pop_json(&outbound)["id"], "stream-overflow-reused");
    assert_eq!(pop_json(&outbound)["type"], "stream_item");
    let cancel = resource_request(
        "stream-overflow-cancel",
        "stream.cancel",
        json!({
            "machine":"current",
            "session":"current",
            "stream":overflow_id,
        }),
        None,
    );
    assert!(handle_connection_message(&mux, client, &cancel, &writer, &scheduler));
    assert_eq!(pop_json(&outbound)["reason"], "canceled");
    assert_eq!(pop_json(&outbound)["id"], "stream-overflow-cancel");

    for (stream_id, _, worker_permit) in installed {
        drop(mux.control_clients.take_resource_stream(client, &stream_id));
        drop(worker_permit);
    }
    assert!(disconnect_client(&mux, client, false));
    assert!(
        mux.control_clients
            .resource_stream_admission
            .wait_until_idle(Instant::now() + Duration::from_secs(2)),
        "ended streams retained server worker capacity"
    );
}

#[test]
fn resource_stream_server_capacity_survives_disconnect_until_workers_exit() {
    let mux = test_mux();
    let writer = test_writer();
    let mut clients = Vec::new();
    let mut worker_permits = Vec::new();
    for client_index in 0..(RESOURCE_STREAMS_SERVER_CAPACITY / RESOURCE_STREAMS_PER_CLIENT_CAPACITY)
    {
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let mut client_permits = Vec::new();
        for stream_index in 0..RESOURCE_STREAMS_PER_CLIENT_CAPACITY {
            let id = test_stream_id(
                (client_index * RESOURCE_STREAMS_PER_CLIENT_CAPACITY + stream_index + 1) as u64,
            );
            let stream = writer.start_stream(&json!({})).unwrap();
            let (_, permit) = mux
                .control_clients
                .install_resource_stream(client, &id, stream)
                .expect("stream below the server capacity");
            client_permits.push(permit);
        }
        clients.push(client);
        worker_permits.push(client_permits);
    }
    assert_eq!(
        mux.control_clients.resource_stream_admission.active(),
        RESOURCE_STREAMS_SERVER_CAPACITY
    );

    let (extra_writer, extra_outbound) = captured_writer();
    let extra = mux.control_clients.register(ClientTransport::Unix, extra_writer.clone());
    let extra_id = test_stream_id(20_000);
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let open = resource_request(
        "server-stream-overflow",
        "session.events",
        json!({
            "machine":"current",
            "session":"current",
            "stream_id":extra_id,
        }),
        None,
    );
    assert!(handle_connection_message(&mux, extra, &open, &extra_writer, &scheduler,));
    let rejection = pop_json(&extra_outbound);
    assert_eq!(rejection["error"]["code"], "operation.failed");
    assert_eq!(rejection["error"]["details"]["extra"]["reason_code"], "resource_stream_capacity");
    assert_eq!(rejection["error"]["details"]["extra"]["scope"], "server");
    assert_eq!(rejection["error"]["details"]["extra"]["limit"], RESOURCE_STREAMS_SERVER_CAPACITY);

    assert!(disconnect_client(&mux, clients[0], false));
    let still_rejected = mux.control_clients.install_resource_stream(
        extra,
        &extra_id,
        extra_writer.start_stream(&json!({})).unwrap(),
    );
    assert!(matches!(still_rejected, Err(ResourceStreamInstallError::ServerCapacity)));
    drop(worker_permits.remove(0));
    let (_, extra_permit) = mux
        .control_clients
        .install_resource_stream(extra, &extra_id, extra_writer.start_stream(&json!({})).unwrap())
        .expect("disconnect cleanup is reusable after its workers exit");

    for client in clients.into_iter().skip(1) {
        assert!(disconnect_client(&mux, client, false));
    }
    drop(worker_permits);
    drop(mux.control_clients.take_resource_stream(extra, &extra_id));
    drop(extra_permit);
    assert!(disconnect_client(&mux, extra, false));
    assert_eq!(mux.control_clients.resource_stream_admission.active(), 0);
}
