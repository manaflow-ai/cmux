//! An incognito (ephemeral) workspace is never shown to, or acted on by, a
//! remote device's connection (#31210; design/spaces.md "Incognito": nothing
//! of the window shows outside it). A phone spliced onto this socket (the
//! Mac app's daemon lane, cmux-mobile-host) says `set-client-info
//! {remote: true}`; the Mac app's own connection does not.

use super::*;

type Conn = (u64, MessageWriter, Arc<BoundedOutbound>, Arc<ConnectionSurfaceScheduler>);

fn connect(mux: &Arc<Mux>) -> Conn {
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    (client, writer, outbound, scheduler)
}

/// The Mac app's connection: role main.
fn app(mux: &Arc<Mux>) -> Conn {
    let conn = connect(mux);
    let peer_key = "token:999999301.1".to_string();
    origin_gate::set_peer_identity_at_accept(mux, conn.0, Some(peer_key.clone()), None);
    assert!(origin_gate::set_hello(
        mux,
        conn.0,
        crate::request_origin::HelloRole::Main,
        Some(peer_key),
        false,
        None
    ));
    conn
}

/// A phone on the daemon lane: the splice marks its `set-client-info`
/// `remote: true` with its device id.
fn phone(mux: &Arc<Mux>) -> Conn {
    let conn = connect(mux);
    let reply = line(
        mux,
        &conn,
        json!({"id": "info", "cmd": "set-client-info", "name": "iPhone", "kind": "ios",
               "device_id": "phone-1", "remote": true}),
    );
    assert_eq!(reply["ok"], true, "{reply}");
    conn
}

/// One request line through the connection path; its reply.
fn line(mux: &Arc<Mux>, (client, writer, outbound, scheduler): &Conn, request: Value) -> Value {
    assert!(handle_connection_message(mux, *client, &request.to_string(), writer, scheduler));
    pop_json(outbound)
}

fn create(mux: &Arc<Mux>, conn: &Conn, name: &str, ephemeral: bool) -> String {
    let mut params = json!({"machine": "current", "session": "current", "name": name,
                            "initial_content": "empty"});
    if ephemeral {
        params["ephemeral"] = json!(true);
    }
    let key = format!("create-{name}");
    let request = resource_request(&key, "workspace.create", params, Some(key.as_str()));
    assert!(handle_connection_message(mux, conn.0, &request, &conn.1, &conn.3));
    let response = pop_json(&conn.2);
    assert_eq!(response["ok"], true, "{response}");
    response["result"]["value"]["workspace_id"]
        .as_str()
        .or_else(|| response["result"]["workspace_id"].as_str())
        .unwrap_or_else(|| panic!("no workspace id: {response}"))
        .to_string()
}

/// The `list-workspaces` rows `conn` is answered, by resource id.
fn listed(mux: &Arc<Mux>, conn: &Conn) -> Vec<Value> {
    let reply = line(mux, conn, json!({"id": "list", "cmd": "list-workspaces"}));
    assert_eq!(reply["ok"], true, "{reply}");
    reply["data"]["workspaces"].as_array().unwrap().clone()
}

fn row<'a>(rows: &'a [Value], resource_id: &str) -> Option<&'a Value> {
    rows.iter().find(|row| row["resource_id"] == resource_id)
}

#[test]
fn a_remote_device_never_sees_an_incognito_workspace_and_cannot_act_on_it() {
    let mux = test_mux();
    let app = app(&mux);
    let private = create(&mux, &app, "private-space", true);
    let normal = create(&mux, &app, "normal-space", false);

    // The Mac app itself still lists both.
    let local = listed(&mux, &app);
    let private_row = row(&local, &private).expect("the app lists its incognito workspace").clone();
    assert!(row(&local, &normal).is_some());
    let private_id = private_row["id"].as_u64().unwrap();
    let private_key = private_row["key"].as_str().unwrap().to_string();

    let phone = phone(&mux);
    let remote = listed(&mux, &phone);
    assert!(row(&remote, &normal).is_some(), "a normal workspace reaches the phone: {remote:?}");
    assert!(
        row(&remote, &private).is_none(),
        "an incognito workspace must not reach the phone: {remote:?}"
    );
    let text = serde_json::to_string(&remote).unwrap();
    assert!(!text.contains("private-space"), "{text}");

    // `ids` leaves its objects out too.
    let ids = line(&mux, &phone, json!({"id": "ids", "cmd": "ids"}));
    assert!(
        !ids["data"]["ids"].as_array().unwrap().iter().any(|row| row["id"] == private_id),
        "{ids}"
    );
    // A resource read the phone splices never forward is refused outright.
    let request = resource_request(
        "wl",
        "workspace.list",
        json!({"machine": "current", "session": "current"}),
        None,
    );
    assert!(handle_connection_message(&mux, phone.0, &request, &phone.1, &phone.3));
    let refused = pop_json(&phone.2);
    assert_eq!(refused["ok"], false, "{refused}");
    assert!(!refused.to_string().contains("private-space"), "{refused}");

    // Acting on it by id or key is refused as if it did not exist.
    for request in [
        json!({"id": "r1", "cmd": "rename-workspace", "workspace": private_id, "name": "seen"}),
        json!({"id": "r2", "cmd": "rename-workspace", "key": private_key, "name": "seen"}),
        json!({"id": "c1", "cmd": "close-workspace", "workspace": private_id}),
        json!({"id": "s1", "cmd": "new-screen", "workspace": private_id}),
        json!({"id": "n1", "cmd": "rename-workspace", "workspace": "private-space", "name": "x"}),
    ] {
        let reply = line(&mux, &phone, request.clone());
        assert_eq!(reply["ok"], false, "{request} must be refused: {reply}");
        // The refusal tells the phone nothing it did not send.
        let error = reply["error"].as_str().unwrap_or_default();
        assert!(!error.contains(&private), "{error}");
        if request["workspace"] != "private-space" {
            assert!(!error.contains("private-space"), "{error}");
        }
    }
    let local = listed(&mux, &app);
    let still = row(&local, &private).expect("the phone did not close the incognito workspace");
    assert_eq!(still["name"], "private-space");

    // The phone still acts on a normal workspace.
    let normal_id = row(&local, &normal).unwrap()["id"].as_u64().unwrap();
    let reply = line(
        &mux,
        &phone,
        json!({"id": "r3", "cmd": "rename-workspace", "workspace": normal_id, "name": "renamed"}),
    );
    assert_eq!(reply["ok"], true, "{reply}");
}

#[test]
fn a_remote_devices_tree_events_leave_out_incognito_workspaces() {
    let mux = test_mux();
    let app = app(&mux);
    let private = create(&mux, &app, "private-space", true);
    let normal = create(&mux, &app, "normal-space", false);
    let local = listed(&mux, &app);
    let private_id = row(&local, &private).unwrap()["id"].as_u64().unwrap();
    let normal_id = row(&local, &normal).unwrap()["id"].as_u64().unwrap();

    let phone = phone(&mux);
    let reply =
        line(&mux, &phone, json!({"id": "sub", "cmd": "subscribe", "tree_events": "deltas"}));
    assert_eq!(reply["ok"], true, "{reply}");
    let _ = drain_json(&phone.2);

    // The app renames its incognito workspace, then a normal one.
    for (workspace, name) in [(private_id, "secret-plans"), (normal_id, "visible-name")] {
        let reply = line(
            &mux,
            &app,
            json!({"id": "rename", "cmd": "rename-workspace", "workspace": workspace, "name": name}),
        );
        assert_eq!(reply["ok"], true, "{reply}");
    }
    // Events arrive in order: once the normal rename is in, the incognito
    // one would have been too.
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut seen = Vec::new();
    while !seen.iter().any(|message: &String| message.contains("visible-name")) {
        assert!(Instant::now() < deadline, "the normal rename never reached the phone: {seen:?}");
        match phone.2.try_pop() {
            Some(message) => seen.push(message),
            None => std::thread::sleep(Duration::from_millis(2)),
        }
    }
    for message in &seen {
        assert!(
            !message.contains("secret-plans"),
            "an incognito rename reached the phone: {message}"
        );
        assert!(!message.contains(&private), "an incognito workspace reached the phone: {message}");
    }
}
