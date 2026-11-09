//! `terminal.close` with `if_unplaced` (W5-O follow-up): the reaper's rule
//! without the grace. A terminal with a tab, a `keep` mark or an attach
//! stream stays running and the close is a stored known failure; an
//! unplaced, unkept, unattached one ends.

use super::*;

/// Whether the session snapshot lists `terminal` as running.
fn running(mux: &Arc<Mux>, terminal: &str) -> bool {
    let snapshot = crate::resource_api::public_session_snapshot(mux).unwrap();
    snapshot["terminals"]
        .as_array()
        .into_iter()
        .flatten()
        .any(|record| record["id"] == terminal && record["lifecycle"].as_str() != Some("exited"))
}

fn retained(response: &Value) -> bool {
    response["ok"] == false
        && response["error"]["code"] == "operation.failed"
        && response["error"]["details"]["extra"]["terminal_retained"] == true
}

#[test]
fn w5o_guarded_terminal_close_ends_only_an_unplaced_unkept_unattached_terminal() {
    let mux = test_mux();
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let request = |id: &str, operation: &str, params: Value| {
        let message = resource_request(id, operation, params, Some(id));
        assert!(handle_connection_message(&mux, client, &message, &writer, &scheduler));
        pop_json(&outbound)
    };
    let created = request(
        "w5o-create",
        "workspace.create",
        json!({"machine":"current","session":"current","initial_content":"terminal"}),
    );
    assert_eq!(created["ok"], true, "{created}");
    let workspace = created["result"]["value"]["workspace_id"].as_str().unwrap().to_owned();
    let terminal = created["result"]["value"]["terminal_id"].as_str().unwrap().to_owned();
    let close = |key: &str| {
        request(
            key,
            "terminal.close",
            json!({
                "machine":"current",
                "session":"current",
                "terminal":terminal,
                "if_unplaced":true,
            }),
        )
    };

    // A terminal with a tab stays, and a retry with the key answers the same.
    assert!(retained(&close("w5o-placed")), "a terminal with a tab was ended");
    assert!(retained(&close("w5o-placed")), "the replay changed its answer");
    assert!(running(&mux, &terminal));

    // The workspace close takes the tab and leaves the terminal running.
    let closed = request(
        "w5o-workspace-close",
        "workspace.close",
        json!({"machine":"current","session":"current","workspace":workspace}),
    );
    assert_eq!(closed["ok"], true, "{closed}");
    assert!(running(&mux, &terminal));

    // A kept terminal stays.
    let keep = |keep: bool| Command::SetTerminalKeep {
        surface: None,
        terminal_id: Some(terminal.clone()),
        keep,
    };
    handle_command(&mux, client, keep(true), &writer).unwrap();
    assert!(retained(&close("w5o-kept")), "a kept terminal was ended");
    assert!(running(&mux, &terminal));
    handle_command(&mux, client, keep(false), &writer).unwrap();

    // An attached terminal stays.
    let public_id = TerminalPublicId::parse(terminal.clone()).unwrap();
    let runtime = mux.resource_surface_for_terminal(&public_id).unwrap();
    let viewer_writer = test_writer();
    let viewer = mux.control_clients.register(ClientTransport::Unix, viewer_writer.clone());
    let stream = viewer_writer.start_stream(&json!({"event":"test"})).unwrap();
    mux.control_clients.attach_surface(viewer, runtime, stream).unwrap();
    assert!(retained(&close("w5o-attached")), "an attached terminal was ended");
    assert!(running(&mux, &terminal));
    disconnect_client(&mux, viewer, false);

    // No tab, no keep mark, no attach stream: it ends.
    let ended = close("w5o-ended");
    assert_eq!(ended["ok"], true, "{ended}");
    assert!(!running(&mux, &terminal), "the guarded close left the terminal running");
    disconnect_client(&mux, client, false);
}
