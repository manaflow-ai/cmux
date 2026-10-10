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
