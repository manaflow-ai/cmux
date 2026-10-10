//! `workspace.ensure_app` (`app-screens-v1`) over the daemon socket of a
//! real daemon: an installed app's one workspace is created with its app tab
//! in one operation, survives a restart, closes, and an app that is not
//! installed is refused.

use super::*;

const APP: &str = "cmux/coderouter";

/// The daemon's installed apps: the first-party packages of this checkout,
/// with only [`APP`] installed by default.
fn app_env(apps_dir: &std::path::Path) -> Vec<(String, String)> {
    let first_party = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../first-party-apps")
        .canonicalize()
        .expect("first-party-apps exists in the checkout");
    vec![
        ("CMUX_APPS_FIRST_PARTY_DIR".into(), first_party.display().to_string()),
        ("CMUX_APPS_DIRS".into(), apps_dir.display().to_string()),
        ("CMUX_APPS_DEFAULT".into(), APP.into()),
    ]
}

/// A daemon on the fixture's socket and state; its stderr goes to a file in
/// the fixture directory (the fixture drains only the first daemon's pipe).
fn spawn_daemon(server_dir: &std::path::Path, env: &[(String, String)]) -> Child {
    let log = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(server_dir.join("app-daemon.log"))
        .unwrap();
    Command::new(bin())
        .args(["--headless", "--socket"])
        .arg(server_dir.join("mux.sock"))
        .arg("--state")
        .arg(server_dir.join("state"))
        .env("CMUX_TUI_CONFIG", server_dir.join("config.json"))
        .envs(env.iter().map(|(key, value)| (key.as_str(), value.as_str())))
        .stdout(Stdio::null())
        .stderr(log)
        .spawn()
        .unwrap()
}

/// One `cmux.protocol/2` request; returns the whole response.
fn v2(
    server: &HeadlessServer,
    operation: &str,
    params: serde_json::Value,
    key: Option<&str>,
) -> serde_json::Value {
    let mut params_with_session = serde_json::json!({"machine": "current", "session": "current"});
    params_with_session.as_object_mut().unwrap().extend(params.as_object().unwrap().clone());
    let mut request = serde_json::json!({
        "protocol": "cmux.protocol/2",
        "type": "request",
        "id": format!("app-workspaces-{operation}"),
        "operation": operation,
        "params": params_with_session,
    });
    if let Some(key) = key {
        request["idempotency_key"] = serde_json::json!(key);
    }
    let stream = transport::connect(&server.socket).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    writeln!(writer, "{request}").unwrap();
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    serde_json::from_str(&line).unwrap_or_else(|_| panic!("{operation}: no JSON reply: {line}"))
}

/// A raw `subscribe` with tree deltas; its lines arrive on the receiver.
/// The returned writer keeps the subscription's connection open.
fn subscribe_deltas(server: &HeadlessServer) -> (impl Sized + use<>, mpsc::Receiver<String>) {
    let stream = transport::connect(&server.socket).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        for line in BufReader::new(stream).lines() {
            let Ok(line) = line else { break };
            if tx.send(line).is_err() {
                break;
            }
        }
    });
    writeln!(writer, r#"{{"id":1,"cmd":"subscribe","tree_events":"deltas"}}"#).unwrap();
    writer.flush().unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let remaining =
            deadline.checked_duration_since(Instant::now()).expect("no subscribe reply");
        let line = rx.recv_timeout(remaining).expect("no subscribe reply");
        let message: serde_json::Value = serde_json::from_str(&line).unwrap();
        if message["id"].as_u64() == Some(1) {
            assert_eq!(message["ok"], true, "subscribe failed: {message}");
            return (writer, rx);
        }
    }
}

/// The first `workspace-added` delta of `workspace_id` on the subscription.
fn first_workspace_added(rx: &mpsc::Receiver<String>, workspace_id: &str) -> serde_json::Value {
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut seen = Vec::new();
    while let Some(remaining) = deadline.checked_duration_since(Instant::now()) {
        let Ok(line) = rx.recv_timeout(remaining) else { break };
        let message: serde_json::Value = serde_json::from_str(&line).unwrap();
        if message["event"] == "workspace-added" && message["entity"]["resource_id"] == workspace_id
        {
            return message;
        }
        seen.push(line);
    }
    panic!("no workspace-added delta for {workspace_id}; lines={seen:?}");
}

fn ensure_app(server: &HeadlessServer, app: &str, key: &str) -> serde_json::Value {
    v2(
        server,
        "workspace.ensure_app",
        serde_json::json!({"app": app, "name": "CodeRouter"}),
        Some(key),
    )
}

/// The raw tree's workspaces.
fn workspaces(server: &HeadlessServer) -> Vec<serde_json::Value> {
    json_socket_request(&server.socket, serde_json::json!({"id": 1, "cmd": "list-workspaces"}))
        ["workspaces"]
        .as_array()
        .unwrap()
        .clone()
}

fn app_workspace(server: &HeadlessServer, id: &str) -> serde_json::Value {
    workspaces(server)
        .into_iter()
        .find(|workspace| workspace["resource_id"] == id)
        .unwrap_or_else(|| panic!("no workspace {id} in {:?}", workspaces(server)))
}

/// The app workspace holds exactly one screen with one pane and one app tab.
fn assert_app_shape(workspace: &serde_json::Value) {
    assert_eq!(workspace["kind"], "app", "{workspace}");
    assert_eq!(workspace["app"], APP, "{workspace}");
    let screens = workspace["screens"].as_array().unwrap();
    assert_eq!(screens.len(), 1, "{workspace}");
    let panes = screens[0]["panes"].as_array().unwrap();
    assert_eq!(panes.len(), 1, "{workspace}");
    let tabs = panes[0]["tabs"].as_array().unwrap();
    assert_eq!(tabs.len(), 1, "{workspace}");
    assert_eq!(tabs[0]["app"]["app"], APP, "{workspace}");
}

#[test]
fn cmux_next_app_workspace_is_created_with_its_tab_reopened_after_restart_and_closed() {
    let mut server = HeadlessServer::start("app-workspaces");
    let apps_dir = server.dir.join("apps");
    fs::create_dir_all(&apps_dir).unwrap();
    let env = app_env(&apps_dir);
    // Restart the fixture's daemon with the app catalog.
    server.child.kill().unwrap();
    server.child.wait().unwrap();
    server.child = spawn_daemon(&server.dir, &env);
    server.wait_for_socket();

    // An app that is not installed, and a malformed id, are refused and
    // create nothing.
    let before = workspaces(&server).len();
    for app in ["cmux/app-store", "../escape"] {
        let refused = ensure_app(&server, app, &format!("refused-{app}"));
        assert_eq!(refused["ok"], false, "{refused}");
        assert_eq!(refused["error"]["code"], "validation.invalid", "{refused}");
    }
    assert_eq!(workspaces(&server).len(), before);

    // One operation makes the workspace with its kind and its app tab; a raw
    // delta subscriber sees the kind in the workspace's first delta.
    let (_subscription, deltas) = subscribe_deltas(&server);
    let created = ensure_app(&server, APP, "open-1");
    assert_eq!(created["ok"], true, "{created}");
    assert_eq!(created["result"]["replayed"], false, "{created}");
    let workspace_id = created["result"]["value"]["workspace_id"].as_str().unwrap().to_string();
    assert_app_shape(&app_workspace(&server, &workspace_id));
    let added = first_workspace_added(&deltas, &workspace_id);
    assert_eq!(added["entity"]["kind"], "app", "{added}");
    assert_eq!(added["entity"]["app"], APP, "{added}");
    let snapshot =
        v2(&server, "workspace.get", serde_json::json!({"workspace": workspace_id}), None);
    assert_eq!(snapshot["result"]["extra"]["kind"], "app", "{snapshot}");
    assert_eq!(snapshot["result"]["extra"]["app"], APP, "{snapshot}");

    // A second call (another key) names the same workspace.
    let again = ensure_app(&server, APP, "open-2");
    assert_eq!(again["result"]["replayed"], true, "{again}");
    assert_eq!(again["result"]["value"]["workspace_id"], workspace_id.as_str(), "{again}");

    // After a restart the store reopens the same app workspace.
    server.child.kill().unwrap();
    server.child.wait().unwrap();
    server.child = spawn_daemon(&server.dir, &env);
    server.wait_for_socket();
    assert_app_shape(&app_workspace(&server, &workspace_id));
    let reopened = ensure_app(&server, APP, "open-3");
    assert_eq!(reopened["result"]["replayed"], true, "{reopened}");
    assert_eq!(reopened["result"]["value"]["workspace_id"], workspace_id.as_str(), "{reopened}");

    // Closing the workspace closes the app; the next call makes a new one.
    let closed = v2(
        &server,
        "workspace.close",
        serde_json::json!({"workspace": workspace_id}),
        Some("close-1"),
    );
    assert_eq!(closed["ok"], true, "{closed}");
    assert!(
        workspaces(&server)
            .iter()
            .all(|workspace| workspace["resource_id"] != workspace_id.as_str())
    );
    let fresh = ensure_app(&server, APP, "open-4");
    assert_eq!(fresh["result"]["replayed"], false, "{fresh}");
    let fresh_id = fresh["result"]["value"]["workspace_id"].as_str().unwrap();
    assert_ne!(fresh_id, workspace_id);
    assert_app_shape(&app_workspace(&server, fresh_id));
}
