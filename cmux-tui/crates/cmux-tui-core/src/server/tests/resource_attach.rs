//! Resource clients and resource attach streams for terminals, sidebars and browsers.

use super::*;

#[test]
fn resource_clients_use_opaque_ids_and_preserve_exact_nullable_metadata() {
    let mux = test_mux();
    let (first_writer, first_outbound) = captured_writer();
    let first = mux.control_clients.register(ClientTransport::Unix, first_writer.clone());
    let (second_writer, second_outbound) = captured_writer();
    let second = mux.control_clients.register(ClientTransport::WebSocket, second_writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));

    let update = resource_request(
        "client-metadata",
        "client.metadata.update",
        json!({
            "machine":"current",
            "session":"current",
            "client":"current",
            "name":"  α  ",
            "kind":null,
        }),
        None,
    );
    assert!(handle_connection_message(&mux, first, &update, &first_writer, &scheduler));
    let updated = pop_json(&first_outbound);
    assert_eq!(updated["ok"], true);
    assert_eq!(updated["result"]["name"], "  α  ");
    assert_eq!(updated["result"]["client_kind"], Value::Null);
    assert_eq!(updated["result"]["transport"], "unix");
    let first_id = updated["result"]["id"].as_str().unwrap().to_string();
    assert!(first_id.starts_with("client_"));
    assert!(!first_id.ends_with(&format!("{first:032x}")));

    let list = resource_request(
        "client-list",
        "client.list",
        json!({"machine":"current","session":"current"}),
        None,
    );
    assert!(handle_connection_message(&mux, first, &list, &first_writer, &scheduler));
    let listed = pop_json(&first_outbound);
    assert_eq!(listed["result"].as_array().unwrap().len(), 2);
    assert!(listed["result"].as_array().unwrap().iter().any(|client| {
        client["id"] == first_id && client["self"] == true && client["transport"] == "unix"
    }));
    assert!(
        listed["result"]
            .as_array()
            .unwrap()
            .iter()
            .any(|client| { client["self"] == false && client["transport"] == "websocket" })
    );

    let snapshot = resource_request(
        "session-snapshot-with-clients",
        "session.snapshot",
        json!({"machine":"current","session":"current"}),
        None,
    );
    assert!(handle_connection_message(&mux, first, &snapshot, &first_writer, &scheduler));
    let snapshot = pop_json(&first_outbound);
    let clients = snapshot["result"]["clients"].as_array().unwrap();
    assert_eq!(clients.len(), 2);
    assert!(clients.iter().any(|client| client["id"] == first_id && client["self"] == true));
    assert!(
        clients.iter().any(|client| client["self"] == false && client["transport"] == "websocket")
    );

    let clear = resource_request(
        "client-clear-name",
        "client.metadata.update",
        json!({
            "machine":"current",
            "session":"current",
            "client":first_id,
            "name":null,
        }),
        None,
    );
    assert!(handle_connection_message(&mux, first, &clear, &first_writer, &scheduler));
    assert_eq!(pop_json(&first_outbound)["result"]["name"], Value::Null);

    let websocket_update = resource_request(
        "websocket-client-metadata",
        "client.metadata.update",
        json!({
            "machine":"current",
            "session":"current",
            "client":"current",
            "name":"websocket exact α",
            "kind":"web-client",
        }),
        None,
    );
    assert!(
        handle_connection_message(&mux, second, &websocket_update, &second_writer, &scheduler,)
    );
    let updated = pop_json(&second_outbound);
    assert_eq!(updated["ok"], true);
    assert_eq!(updated["result"]["transport"], "websocket");
    assert_eq!(updated["result"]["name"], "websocket exact α");
    assert_eq!(updated["result"]["client_kind"], "web-client");

    for (id, field, value) in [
        ("websocket-client-metadata-control", "name", "\u{1b}]0;evil\u{07}".to_string()),
        ("websocket-client-metadata-c1-control", "name", "c1\u{0085}control".to_string()),
        ("websocket-client-metadata-long", "kind", "k".repeat(65)),
    ] {
        let mut params = json!({
            "machine":"current",
            "session":"current",
            "client":"current",
        });
        params[field] = json!(value);
        let invalid = resource_request(id, "client.metadata.update", params, None);
        assert!(handle_connection_message(&mux, second, &invalid, &second_writer, &scheduler,));
        let rejected = pop_json(&second_outbound);
        assert_eq!(rejected["ok"], false);
        assert_eq!(rejected["error"]["code"], "validation.invalid");
        assert_eq!(rejected["error"]["details"]["field"], field);
    }

    let unchanged = resource_request(
        "websocket-client-metadata-unchanged",
        "client.get",
        json!({
            "machine":"current",
            "session":"current",
            "client":"current",
        }),
        None,
    );
    assert!(handle_connection_message(&mux, second, &unchanged, &second_writer, &scheduler,));
    let unchanged = pop_json(&second_outbound);
    assert_eq!(unchanged["result"]["name"], "websocket exact α");
    assert_eq!(unchanged["result"]["client_kind"], "web-client");

    let websocket_clear = resource_request(
        "websocket-client-metadata-clear",
        "client.metadata.update",
        json!({
            "machine":"current",
            "session":"current",
            "client":"current",
            "name":null,
            "kind":null,
        }),
        None,
    );
    assert!(handle_connection_message(&mux, second, &websocket_clear, &second_writer, &scheduler,));
    let cleared = pop_json(&second_outbound);
    assert_eq!(cleared["result"]["name"], Value::Null);
    assert_eq!(cleared["result"]["client_kind"], Value::Null);
    disconnect_client(&mux, first, false);
    disconnect_client(&mux, second, false);
}

#[test]
fn connection_handler_owns_every_router_connection_operation() {
    let catalog: Value =
        serde_json::from_str(include_str!("../../../../../spec/resource-operations-v2.json"))
            .unwrap();
    let mut connection_operations = 0usize;
    for name in catalog["operations"].as_object().unwrap().keys() {
        let operation: ResourceOperation =
            serde_json::from_value(Value::String(name.clone())).unwrap();
        let requires_connection = crate::resource_router::requires_connection_context(operation);
        assert_eq!(
            handles_resource_connection_operation(operation),
            requires_connection,
            "{name} has inconsistent connection ownership"
        );
        connection_operations += usize::from(requires_connection);
    }
    assert_eq!(connection_operations, 44);
}

#[test]
fn terminal_resource_attach_acknowledges_before_styled_snapshot_and_cancels() {
    let mux = test_mux();
    let created = crate::resource_router::handle_resource_message(
        &mux,
        &resource_request(
            "terminal-attach-create",
            "workspace.create",
            json!({
                "machine":"current",
                "session":"current",
                "name":"attach",
                "initial_content":"terminal",
            }),
            Some("terminal-resource-attach-create"),
        ),
    )
    .unwrap();
    assert_eq!(created["ok"], true);
    let snapshot = crate::resource_api::public_session_snapshot(&mux).unwrap();
    let terminal_id =
        snapshot["terminals"][0]["id"].as_str().expect("created terminal id").to_string();

    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let stream_id = "stream_00000000000000000000000000000021";
    let attach = resource_request(
        "terminal-attach-open",
        "terminal.attach",
        json!({
            "machine":"current",
            "session":"current",
            "terminal":terminal_id,
            "stream_id":stream_id,
        }),
        None,
    );
    assert!(handle_connection_message(&mux, client, &attach, &writer, &scheduler));

    let response = pop_json(&outbound);
    assert_eq!(response["type"], "response");
    assert_eq!(response["id"], "terminal-attach-open");
    assert_eq!(response["ok"], true);
    assert_eq!(response["result"]["stream_id"], stream_id);
    let attachment_lease = response["result"]["attachment_lease"]
        .as_str()
        .expect("resource attachments must expose a per-view lease")
        .to_string();
    let item = pop_json(&outbound);
    assert_eq!(item["type"], "stream_item");
    assert_eq!(item["stream_id"], stream_id);
    assert_eq!(item["sequence"], "0");
    assert!(item.get("cursor").is_none());
    assert_eq!(item["item"]["kind"], "snapshot");
    assert_eq!(item["item"]["terminal_id"], terminal_id);
    assert_eq!(
        item["item"]["render"]["rows"].as_array().unwrap().len(),
        item["item"]["render"]["size"]["rows"].as_u64().unwrap() as usize
    );

    let resize = resource_request(
        "terminal-attach-resize",
        "terminal.viewer.resize",
        json!({
            "machine":"current",
            "session":"current",
            "terminal":terminal_id,
            "attachment_lease":attachment_lease,
            "cols":91,
            "rows":27,
        }),
        None,
    );
    assert!(handle_connection_message(&mux, client, &resize, &writer, &scheduler));
    let resized = pop_json(&outbound);
    assert_eq!(resized["result"]["outcome"], "applied");
    assert_eq!(resized["result"]["size"], json!({"cols":91,"rows":27}));

    let cancel = resource_request(
        "terminal-attach-cancel",
        "stream.cancel",
        json!({
            "machine":"current",
            "session":"current",
            "stream":stream_id,
        }),
        None,
    );
    assert!(handle_connection_message(&mux, client, &cancel, &writer, &scheduler));
    let end = pop_json(&outbound);
    assert_eq!(end["type"], "stream_end");
    assert_eq!(end["stream_id"], stream_id);
    assert_eq!(end["reason"], "canceled");
    assert_eq!(pop_json(&outbound)["id"], "terminal-attach-cancel");
    disconnect_client(&mux, client, false);
}

#[test]
fn sidebar_resource_attach_acknowledges_before_styled_snapshot_and_cancels() {
    let mux = Mux::new("server-sidebar-resource", SurfaceOptions::default());
    mux.configure_sidebar_plugin(Some(SidebarPluginOptions {
        command: vec!["/bin/cat".to_string()],
        cwd: None,
    }));
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let ensure = resource_request(
        "sidebar-attach-ensure",
        "sidebar_view.ensure",
        json!({
            "machine":"current",
            "session":"current",
            "cols":20,
            "rows":4,
        }),
        Some("server-sidebar-attach-ensure"),
    );
    assert!(handle_connection_message(&mux, client, &ensure, &writer, &scheduler));
    let ensured = pop_json(&outbound);
    assert_eq!(ensured["ok"], true);
    let sidebar_id =
        ensured["result"]["value"]["id"].as_str().expect("sidebar view id").to_string();

    let stream_id = "stream_00000000000000000000000000000022";
    let attach = resource_request(
        "sidebar-attach-open",
        "sidebar_view.attach",
        json!({
            "machine":"current",
            "session":"current",
            "sidebar_view":sidebar_id,
            "stream_id":stream_id,
        }),
        None,
    );
    assert!(handle_connection_message(&mux, client, &attach, &writer, &scheduler));
    let response = pop_json(&outbound);
    assert_eq!(response["type"], "response");
    assert_eq!(response["id"], "sidebar-attach-open");
    assert_eq!(response["ok"], true);
    assert_eq!(response["result"]["stream_id"], stream_id);
    let item = pop_json(&outbound);
    assert_eq!(item["type"], "stream_item");
    assert_eq!(item["stream_id"], stream_id);
    assert_eq!(item["sequence"], "0");
    assert!(item.get("cursor").is_none());
    assert_eq!(item["item"]["kind"], "snapshot");
    assert_eq!(item["item"]["sidebar_view"]["id"], sidebar_id);
    assert_eq!(
        item["item"]["render"]["rows"].as_array().unwrap().len(),
        item["item"]["render"]["size"]["rows"].as_u64().unwrap() as usize
    );

    let cancel = resource_request(
        "sidebar-attach-cancel",
        "stream.cancel",
        json!({
            "machine":"current",
            "session":"current",
            "stream":stream_id,
        }),
        None,
    );
    assert!(handle_connection_message(&mux, client, &cancel, &writer, &scheduler));
    let end = pop_json(&outbound);
    assert_eq!(end["type"], "stream_end");
    assert_eq!(end["stream_id"], stream_id);
    assert_eq!(end["reason"], "canceled");
    assert_eq!(pop_json(&outbound)["id"], "sidebar-attach-cancel");
    disconnect_client(&mux, client, false);
}

#[test]
fn session_event_stream_replays_covered_cursor_and_rejects_ahead_cursor() {
    let mux = test_mux();
    let initial = crate::resource_api::public_session_snapshot(&mux).unwrap();
    let generation = initial["cursor"]["generation"].as_str().unwrap().to_string();
    let created = crate::resource_router::handle_resource_message(
        &mux,
        &resource_request(
            "create-for-replay",
            "workspace.create",
            json!({
                "machine":"current",
                "session":"current",
                "name":"replayed",
                "initial_content":"empty",
            }),
            Some("create-for-session-event-replay"),
        ),
    )
    .unwrap();
    assert_eq!(created["result"]["revision"], "1");

    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let stream_id = "stream_00000000000000000000000000000002";
    let open = resource_request(
        "events-replay",
        "session.events",
        json!({
            "machine":"current",
            "session":"current",
            "stream_id":stream_id,
            "cursor":{"generation":generation,"revision":"0"},
        }),
        None,
    );
    assert!(handle_connection_message(&mux, client, &open, &writer, &scheduler));
    assert_eq!(pop_json(&outbound)["id"], "events-replay");
    let delta = pop_json(&outbound);
    assert_eq!(delta["item"]["kind"], "delta");
    assert_eq!(delta["item"]["previous_revision"], "0");
    assert_eq!(delta["item"]["revision"], "1");
    assert_eq!(delta["item"]["changes"][0]["kind"], "upsert");
    assert_eq!(delta["item"]["changes"][0]["resource"], "workspace");

    let ahead_id = "stream_00000000000000000000000000000003";
    let ahead = resource_request(
        "events-ahead",
        "session.events",
        json!({
            "machine":"current",
            "session":"current",
            "stream_id":ahead_id,
            "cursor":{"generation":generation,"revision":"999"},
        }),
        None,
    );
    assert!(handle_connection_message(&mux, client, &ahead, &writer, &scheduler));
    let response = pop_json(&outbound);
    assert_eq!(response["id"], "events-ahead");
    assert_eq!(response["ok"], false);
    assert_eq!(response["error"]["code"], "cursor.invalid");
    disconnect_client(&mux, client, false);
}

#[test]
fn generation_mismatch_resets_one_stream_without_interrupting_another() {
    let mux = test_mux();
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let first_id = "stream_00000000000000000000000000000004";
    let second_id = "stream_00000000000000000000000000000005";
    for (request_id, stream_id, cursor) in [
        ("events-reset", first_id, Some(json!({"generation":"stale","revision":"0"}))),
        ("events-live", second_id, None),
    ] {
        let mut params = json!({
            "machine":"current",
            "session":"current",
            "stream_id":stream_id,
        });
        if let Some(cursor) = cursor {
            params["cursor"] = cursor;
        }
        let open = resource_request(request_id, "session.events", params, None);
        assert!(handle_connection_message(&mux, client, &open, &writer, &scheduler));
        assert_eq!(pop_json(&outbound)["id"], request_id);
        let snapshot = pop_json(&outbound);
        assert_eq!(snapshot["stream_id"], stream_id);
        assert_eq!(
            snapshot["item"]["reset_reason"],
            if stream_id == first_id { "generation_changed" } else { "initial" }
        );
    }

    let cancel = resource_request(
        "cancel-reset",
        "stream.cancel",
        json!({
            "machine":"current",
            "session":"current",
            "stream":first_id,
        }),
        None,
    );
    assert!(handle_connection_message(&mux, client, &cancel, &writer, &scheduler));
    assert_eq!(pop_json(&outbound)["stream_id"], first_id);
    assert_eq!(pop_json(&outbound)["id"], "cancel-reset");

    crate::resource_router::handle_resource_message(
        &mux,
        &resource_request(
            "create-for-live",
            "workspace.create",
            json!({
                "machine":"current",
                "session":"current",
                "name":"live",
                "initial_content":"empty",
            }),
            Some("create-for-live-session-event"),
        ),
    )
    .unwrap();
    let delta = pop_json(&outbound);
    assert_eq!(delta["type"], "stream_item");
    assert_eq!(delta["stream_id"], second_id);
    assert_eq!(delta["item"]["kind"], "delta");
    disconnect_client(&mux, client, false);
}

#[test]
fn browser_state_json_exposes_pointer_admission_separately_from_the_retained_frame() {
    let state = BrowserAttachState {
        url: "https://example.test".to_string(),
        title: "example".to_string(),
        cols: 10,
        rows: 5,
        status: BrowserStatus::Live,
        frame: Some(BrowserFrame {
            session_id: "session-test".to_string(),
            data_b64: "AAAA".to_string(),
            css_width: 80,
            css_height: 48,
            image_width: 80,
            image_height: 48,
            seq: 7,
        }),
        pointer_frame_floor_seq: None,
        pointer_frame_seq: None,
        frames_stalled: false,
    };

    let value = serde_json::to_value(browser_state_message(1, &state, true)).unwrap();
    assert_eq!(
        value.get("pointer_frame_seq"),
        Some(&Value::Null),
        "a retained image can remain renderable while pointer admission is invalid"
    );
    assert_eq!(value["frame"]["seq"], 7);
}

#[test]
fn browser_frame_json_couples_authoritative_pointer_admission() {
    let update = BrowserFrameUpdate {
        frame: BrowserFrame {
            session_id: "session-test".to_string(),
            data_b64: "AAAA".to_string(),
            css_width: 80,
            css_height: 48,
            image_width: 80,
            image_height: 48,
            seq: 7,
        },
        status: BrowserStatus::Failed("navigation failed".to_string()),
        pointer_frame_floor_seq: None,
        pointer_frame_seq: None,
    };

    let value = browser_frame_json(1, &update);

    assert_eq!(value["status"], "failed");
    assert_eq!(value["error"], "navigation failed");
    assert_eq!(value.get("pointer_frame_seq"), Some(&Value::Null));
    assert_eq!(value["seq"], 7);
}

#[test]
fn browser_resource_frame_couples_exact_nullable_pointer_authority() {
    let frame = BrowserFrame {
        session_id: "session-test".to_string(),
        data_b64: "AAAA".to_string(),
        css_width: 80,
        css_height: 48,
        image_width: 80,
        image_height: 48,
        seq: 7,
    };

    let guarded = browser_resource_frame(&frame, Some(u64::MAX));
    assert_eq!(guarded["pointer_frame_seq"], u64::MAX.to_string());

    let retained = browser_resource_frame(&frame, None);
    assert_eq!(retained.get("pointer_frame_seq"), Some(&Value::Null));
}

#[test]
fn browser_attach_stream_publishes_frame_before_positive_state_authority() {
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let stream = writer.start_stream(&json!({"event": "overflow"})).unwrap();
    let frame = BrowserFrame {
        session_id: "session-test".to_string(),
        data_b64: "AAAA".to_string(),
        css_width: 80,
        css_height: 48,
        image_width: 80,
        image_height: 48,
        seq: 7,
    };
    let update = BrowserAttachUpdate {
        frame: Some(BrowserFrameUpdate {
            frame: frame.clone(),
            status: BrowserStatus::Live,
            pointer_frame_floor_seq: Some(7),
            pointer_frame_seq: Some(7),
        }),
        state: Some(BrowserAttachState {
            url: "https://example.test".to_string(),
            title: "example".to_string(),
            cols: 10,
            rows: 5,
            status: BrowserStatus::Live,
            frame: Some(frame),
            pointer_frame_floor_seq: Some(7),
            pointer_frame_seq: Some(7),
            frames_stalled: false,
        }),
    };

    send_browser_attach_update(&writer, 1, update, &stream).unwrap();
    let first: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
    let second: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();

    assert_eq!(first["event"], "frame");
    assert_eq!(first["pointer_frame_floor_seq"], 7);
    assert_eq!(first["pointer_frame_seq"], 7);
    assert_eq!(second["event"], "browser-state");
    assert_eq!(second["pointer_frame_floor_seq"], 7);
    assert_eq!(second["pointer_frame_seq"], 7);
}

#[test]
fn browser_state_serializes_css_and_encoded_image_dimensions() {
    let state = BrowserAttachState {
        url: "https://example.com".to_string(),
        title: "Example".to_string(),
        cols: 80,
        rows: 24,
        status: BrowserStatus::Live,
        frame: Some(BrowserFrame {
            session_id: "browser-session".to_string(),
            data_b64: "frame".to_string(),
            css_width: 800,
            css_height: 600,
            image_width: 400,
            image_height: 300,
            seq: 7,
        }),
        pointer_frame_floor_seq: Some(7),
        pointer_frame_seq: Some(7),
        frames_stalled: false,
    };

    let value = serde_json::to_value(browser_state_message(3, &state, true)).unwrap();
    assert_eq!(value["frame"]["width"], 800);
    assert_eq!(value["frame"]["height"], 600);
    assert_eq!(value["frame"]["image_width"], 400);
    assert_eq!(value["frame"]["image_height"], 300);
}

#[test]
fn stack_json_uses_the_stored_expansion_while_focus_is_elsewhere() {
    let stack = Node::stack_with_expanded(vec![1, 2, 3], 2).unwrap();

    assert_eq!(node_json(&stack, 1)["expanded"], 1);
    assert_eq!(node_json(&stack, 9)["expanded"], 2);
}

#[test]
fn exported_stack_layout_is_accepted_as_an_apply_request() {
    let request = serde_json::from_value::<LayoutRequest>(json!({
        "type": "stack",
        "panes": [3, 4, 5],
        "expanded": 4
    }));

    let spec = layout_request_to_spec(request.unwrap()).unwrap();
    assert!(matches!(spec, LayoutSpec::Stack { pane_count: 3, expanded_index: 1 }));
}

#[test]
fn swapping_across_a_stack_boundary_keeps_exported_expansion_valid() {
    let mut root = Node::Split {
        id: 10,
        dir: SplitDir::Right,
        ratio: 0.5,
        a: Box::new(Node::Leaf(1)),
        b: Box::new(Node::stack_with_expanded(vec![2, 3], 2).unwrap()),
    };

    assert!(root.swap_leaves(1, 2));
    let exported = node_json(&root, 2);
    assert_eq!(exported["b"]["panes"], json!([1, 3]));
    assert_eq!(exported["b"]["expanded"], 1);
}

#[test]
fn swapping_within_a_stack_keeps_the_same_pane_expanded() {
    let mut stack = Node::stack_with_expanded(vec![1, 2, 3], 2).unwrap();

    assert!(stack.swap_leaves(2, 3));
    let exported = node_json(&stack, 9);
    assert_eq!(exported["panes"], json!([1, 3, 2]));
    assert_eq!(exported["expanded"], 2);
}
