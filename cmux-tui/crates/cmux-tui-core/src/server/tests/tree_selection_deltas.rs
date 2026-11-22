//! #32408: a 512-workspace classic upgrade made the app read the whole tree 577 times. Each create
//! moved the selection (the new workspace takes the focus, a new tab becomes its pane's active tab),
//! and the daemon sent that as a coarse `tree-changed` after the exact delta. A connection that says
//! `tree-selection-deltas-v1` gets `selection-changed` with the workspace's whole selection instead;
//! any other delta connection still gets `tree-changed`.

use super::*;

type Conn = (u64, MessageWriter, Arc<BoundedOutbound>, Arc<ConnectionSurfaceScheduler>);

fn connect(mux: &Arc<Mux>) -> Conn {
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    (client, writer, outbound, scheduler)
}

fn line(mux: &Arc<Mux>, (client, writer, outbound, scheduler): &Conn, request: Value) -> Value {
    assert!(handle_connection_message(mux, *client, &request.to_string(), writer, scheduler));
    pop_json(outbound)
}

fn until_marker(conn: &Conn, marker: &str) -> Vec<Value> {
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut seen: Vec<Value> = Vec::new();
    while !seen.iter().any(|message| message.to_string().contains(marker)) {
        assert!(Instant::now() < deadline, "the marker never arrived: {seen:?}");
        match conn.2.try_pop() {
            Some(message) => seen.push(serde_json::from_str(&message).unwrap()),
            None => std::thread::sleep(Duration::from_millis(2)),
        }
    }
    seen
}

fn events(seen: &[Value], name: &str) -> usize {
    seen.iter().filter(|message| message["event"] == name).count()
}

#[test]
fn a_create_that_moves_the_selection_sends_selection_changed_not_tree_changed() {
    let mux = test_mux();
    let app = connect(&mux);
    let reply = line(
        &mux,
        &app,
        json!({"id": "info", "cmd": "set-client-info", "name": "cmux-next",
               "capabilities": [TREE_SELECTION_DELTAS_CAPABILITY]}),
    );
    assert_eq!(reply["ok"], true, "{reply}");
    let other = connect(&mux);
    for conn in [&app, &other] {
        let reply =
            line(&mux, conn, json!({"id": "sub", "cmd": "subscribe", "tree_events": "deltas"}));
        assert_eq!(reply["ok"], true, "{reply}");
        let _ = drain_json(&conn.2);
    }
    let maker = connect(&mux);
    let first = line(&mux, &maker, json!({"id": 1, "cmd": "create-workspace", "name": "one"}));
    assert_eq!(first["ok"], true, "{first}");
    // The second takes the focus from the first: a selection change.
    let second = line(&mux, &maker, json!({"id": 2, "cmd": "create-workspace", "name": "two"}));
    assert_eq!(second["ok"], true, "{second}");
    let workspace = second["data"]["workspace"].clone();
    mux.emit(MuxEvent::Status("selection-marker".into()));

    let app_seen = until_marker(&app, "selection-marker");
    assert_eq!(
        events(&app_seen, "tree-changed"),
        0,
        "a connection that reads selection-changed got tree-changed: {app_seen:?}"
    );
    let selection = app_seen
        .iter()
        .find(|message| message["event"] == "selection-changed")
        .unwrap_or_else(|| panic!("no selection-changed: {app_seen:?}"));
    assert_eq!(selection["workspace"], workspace, "{selection}");
    assert_eq!(selection["active"], true, "{selection}");
    let other_seen = until_marker(&other, "selection-marker");
    assert!(
        events(&other_seen, "tree-changed") > 0 && events(&other_seen, "selection-changed") == 0,
        "a connection that did not ask must keep tree-changed: {other_seen:?}"
    );
}

#[test]
fn identify_lists_tree_selection_deltas() {
    let mux = test_mux();
    let identity = handle_command(
        &mux,
        mux.local_test_client(0),
        Command::Identify { machine_metadata: false, revisions: false },
        &test_writer(),
    )
    .unwrap();
    let capabilities = identity["capabilities"].as_array().cloned().unwrap_or_default();
    assert!(
        capabilities.iter().any(|c| c == TREE_SELECTION_DELTAS_CAPABILITY),
        "identify does not list {TREE_SELECTION_DELTAS_CAPABILITY}: {capabilities:?}"
    );
}
