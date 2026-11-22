//! W5-P (for W5-N): a raw `run` reply names its terminal by the host
//! `terminal_id`, and every terminal selector takes the host id as it takes
//! the public id, so `agent list --terminal <terminal_id>` works directly.
//! W5-N had 3 red CI runs because `agent list --terminal` refused the host
//! id. A client that declares `terminal-public-ids-v1` also gets the public
//! ids in the reply; any other client gets the old reply exactly, because
//! released SDKs reject unknown fields in these results.

use super::*;

/// A strict SDK's view of a result type: the fields it decodes. A field
/// gated by `terminal-public-ids-v1` is one an SDK built before it lacks.
fn released_fields(result_type: &str) -> (bool, Vec<String>) {
    let schema: Value =
        serde_json::from_str(include_str!("../../../../spec/sdk-schema.json")).unwrap();
    let ty = &schema["types"][result_type];
    let strict = ty["additional_properties"] == false;
    let fields = ty["fields"]
        .as_object()
        .unwrap_or_else(|| panic!("{result_type} is not in sdk-schema.json"))
        .iter()
        .filter(|(_, field)| field["capability"] != TERMINAL_PUBLIC_IDS_CAPABILITY)
        .map(|(name, _)| name.clone())
        .collect();
    (strict, fields)
}

fn keys(reply: &Value) -> Vec<String> {
    let mut keys = reply.as_object().unwrap().keys().cloned().collect::<Vec<_>>();
    keys.sort();
    keys
}

fn send(mux: &Arc<Mux>, client: u64, request: Value) -> Value {
    let writer = MessageWriter::new(QueuedSink {
        outbound: Arc::new(BoundedOutbound::default()),
        control: None,
    });
    let command: Command = serde_json::from_value(request.clone()).unwrap();
    handle_command(mux, client, command, &writer)
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

/// An old client (no `terminal-public-ids-v1`) gets exactly the reply it
/// got before, which a strict SDK built before this change decodes; and the
/// host `terminal_id` of that reply works as a terminal selector.
#[test]
fn w5p_an_old_client_gets_the_old_reply_and_selectors_take_its_host_id() {
    let mux = Mux::new_for_test("w5p-run-old", crate::SurfaceOptions::default());
    mux.new_workspace(None, Some((60, 8))).unwrap();
    let client = mux.local_test_client(0);
    let reply = send(&mux, client, json!({"cmd":"run","argv":["/bin/sh","-c","sleep 30"]}));
    let old_run = [
        "already_exited",
        "exit",
        "lifecycle",
        "pane",
        "screen",
        "surface",
        "terminal_id",
        "terminal_incarnation",
        "terminal_revision",
        "workspace",
    ];
    assert_eq!(keys(&reply), old_run, "{reply}");
    let pane = reply["pane"].clone();
    let tab = send(&mux, client, json!({"cmd":"new-tab","pane":pane}));
    assert_eq!(keys(&tab), ["surface", "terminal_id", "terminal_incarnation"], "{tab}");
    let split = send(&mux, client, json!({"cmd":"split","pane":pane,"dir":"down"}));
    for (command, reply, result_type) in [
        ("run", &reply, "RunResult"),
        ("new-tab", &tab, "SurfaceResult"),
        ("split", &split, "PaneSurfaceResult"),
    ] {
        let (strict, known) = released_fields(result_type);
        assert!(strict, "{result_type} rejects unknown fields in a released SDK");
        let unknown =
            keys(reply).into_iter().filter(|key| !known.contains(key)).collect::<Vec<_>>();
        assert!(unknown.is_empty(), "{command}: a released SDK rejects {unknown:?}: {reply}");
    }

    let host = reply["terminal_id"].as_str().expect("run gives the host id").to_owned();
    let got = resource(&mux, "terminal.get", json!({"terminal": host}), None);
    let public = got["id"].as_str().expect("terminal.get takes the host id").to_owned();
    assert!(public.starts_with("term_"), "{got}");
    resource(
        &mux,
        "agent.report",
        json!({"terminal_id": public, "state": "working", "source": "socket"}),
        Some("w5p-run-old-report"),
    );
    // `agent list --terminal <the terminal_id run gave>` works directly, and
    // so do the public id and its bare form.
    let bare = public.trim_start_matches("term_").to_owned();
    for terminal in [host.as_str(), public.as_str(), bare.as_str()] {
        let agents = resource(&mux, "agent.list", json!({"terminal": terminal}), None);
        let ids = agents
            .as_array()
            .unwrap()
            .iter()
            .map(|agent| agent["terminal_id"].clone())
            .collect::<Vec<_>>();
        assert_eq!(ids, vec![json!(public)], "agent.list terminal={terminal}: {agents}");
        let got = resource(&mux, "terminal.get", json!({"terminal": terminal}), None);
        assert_eq!(got["id"], public, "terminal.get {terminal}: {got}");
    }
}

/// A client that declares `terminal-public-ids-v1` gets the public ids of
/// the terminal and its view in every creating reply, the ids the session
/// snapshot lists.
#[test]
fn w5p_a_client_with_terminal_public_ids_gets_the_public_ids() {
    let mux = Mux::new_for_test("w5p-run-new", crate::SurfaceOptions::default());
    mux.new_workspace(None, Some((60, 8))).unwrap();
    let client = mux.local_test_client(0);
    send(
        &mux,
        client,
        json!({"cmd":"set-client-info","capabilities":[TERMINAL_PUBLIC_IDS_CAPABILITY]}),
    );
    let reply = send(&mux, client, json!({"cmd":"run","argv":["/bin/sh","-c","sleep 30"]}));
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
    let snapshot = resource(&mux, "session.snapshot", json!({}), None);
    let listed = snapshot["terminals"]
        .as_array()
        .unwrap()
        .iter()
        .find(|terminal| terminal["id"] == public)
        .unwrap_or_else(|| panic!("{public} is not in the snapshot: {snapshot}"));
    assert_eq!(listed["tab_id"], reply["tab_id"], "{listed}");
    let tab = send(&mux, client, json!({"cmd":"new-tab","pane":reply["pane"]}));
    let tab_terminal = tab["terminal_resource_id"].as_str().unwrap_or_default();
    assert!(tab_terminal.starts_with("term_") && tab_terminal != public, "{tab}");
    assert!(tab["tab_id"].as_str().unwrap_or_default().starts_with("tab_"), "{tab}");
}
