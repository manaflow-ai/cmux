//! W5-P (for W5-N): the raw `run` reply names its terminal by the public
//! `term_` id too, so a client needs no second request to map the host
//! `terminal_id`, and every terminal selector takes the host id as it takes
//! the public id. W5-N had 3 red CI runs because `run` gave only the host
//! id, which `agent list --terminal` refused.

use super::*;

fn run(mux: &Arc<Mux>, request: Value) -> Value {
    let writer = MessageWriter::new(QueuedSink {
        outbound: Arc::new(BoundedOutbound::default()),
        control: None,
    });
    let command: Command = serde_json::from_value(request.clone()).unwrap();
    handle_command(mux, mux.local_test_client(0), command, &writer)
        .unwrap_or_else(|error| panic!("{request}: {error:?}"))
}

fn resource(mux: &Arc<Mux>, operation: &str, fields: Value, key: Option<&str>) -> Value {
    let mut params = json!({"machine":"current","session":"current"});
    params.as_object_mut().unwrap().extend(fields.as_object().unwrap().clone());
    let mut envelope = json!({
        "protocol":"cmux.protocol/2",
        "type":"request",
        "id":format!("w5p-run-{operation}"),
        "operation":operation,
        "params":params,
    });
    if let Some(key) = key {
        envelope["idempotency_key"] = json!(key);
    }
    let response = crate::resource_router::handle_resource_message(
        mux,
        &serde_json::to_string(&envelope).unwrap(),
    )
    .unwrap_or_else(|error| panic!("{operation}: {error:?}"));
    assert_eq!(response["ok"], true, "{operation} failed: {response}");
    response["result"].clone()
}

#[test]
fn w5p_run_reply_gives_the_public_ids_and_agent_list_takes_its_host_id() {
    let mux = Mux::new_for_test("w5p-run", crate::SurfaceOptions::default());
    mux.new_workspace(None, Some((60, 8))).unwrap();
    let reply = run(&mux, json!({"cmd":"run","argv":["/bin/sh","-c","sleep 30"]}));
    let host = reply["terminal_id"].as_str().expect("run gives the host id").to_owned();
    let public = reply["terminal_resource_id"].as_str().expect("run gives the term_ id");
    assert!(public.starts_with("term_"), "{reply}");
    for (field, prefix) in [
        ("tab_id", "tab_"),
        ("pane_id", "pane_"),
        ("screen_id", "screen_"),
        ("workspace_id", "ws_"),
    ] {
        let id = reply[field].as_str().unwrap_or_default();
        assert!(id.starts_with(prefix), "run gives {field}: {reply}");
    }
    // The ids are the ones the session snapshot lists.
    let snapshot = resource(&mux, "session.snapshot", json!({}), None);
    let listed = snapshot["terminals"]
        .as_array()
        .unwrap()
        .iter()
        .find(|terminal| terminal["id"] == public)
        .unwrap_or_else(|| panic!("{public} is not in the snapshot: {snapshot}"));
    assert_eq!(listed["tab_id"], reply["tab_id"], "{listed}");

    // `agent list --terminal <the id run gave>` works directly, with the
    // host id, the public id and its bare form.
    resource(
        &mux,
        "agent.report",
        json!({"terminal_id": public, "state": "working", "source": "socket"}),
        Some("w5p-run-report"),
    );
    let bare = public.trim_start_matches("term_").to_owned();
    for terminal in [host.as_str(), public, bare.as_str()] {
        let agents = resource(&mux, "agent.list", json!({"terminal": terminal}), None);
        let ids = agents
            .as_array()
            .unwrap()
            .iter()
            .map(|agent| agent["terminal_id"].clone())
            .collect::<Vec<_>>();
        assert_eq!(ids, vec![json!(public)], "agent.list terminal={terminal}: {agents}");
        // And `terminal.get` with that selector is the same terminal.
        let got = resource(&mux, "terminal.get", json!({"terminal": terminal}), None);
        assert_eq!(got["id"], public, "terminal.get {terminal}: {got}");
    }
}
