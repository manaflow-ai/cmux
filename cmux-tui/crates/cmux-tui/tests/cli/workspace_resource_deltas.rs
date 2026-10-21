//! `cmux workspace <id> rename` and `move` (the `workspace.rename` and
//! `workspace.move` resource operations) committed without the tree delta
//! the legacy commands emit, so the app's sidebar kept the old name until a
//! later change made it resync (cx-urd.5 daily-driver capture). A
//! `subscribe` client now sees each one, at the next workspace revision.

use serde_json::{Value, json};

use super::*;

/// The first `event` delta on the subscription.
fn next_delta(rx: &mpsc::Receiver<String>, event: &str) -> Value {
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut seen = Vec::new();
    while let Some(remaining) = deadline.checked_duration_since(Instant::now()) {
        let Ok(line) = rx.recv_timeout(remaining) else { break };
        let message: Value = serde_json::from_str(&line).unwrap();
        if message["event"] == event {
            return message;
        }
        seen.push(line);
    }
    panic!("no {event} delta; lines={seen:?}");
}

fn workspace_revision(server: &HeadlessServer) -> u64 {
    let listed = json_socket_request(&server.socket, json!({"id": 1, "cmd": "list-workspaces"}));
    listed["workspace_revision"].as_u64().unwrap_or_else(|| panic!("{listed}"))
}

#[test]
fn renaming_and_moving_a_workspace_reach_subscribers() {
    let server = HeadlessServer::start("resource-deltas");
    for id in 1..=2 {
        json_socket_request(&server.socket, json!({"id": id, "cmd": "new-workspace"}));
    }
    let listed = json_socket_request(&server.socket, json!({"id": 3, "cmd": "list-workspaces"}));
    let first = listed["workspaces"][0]["resource_id"].as_str().unwrap().to_string();
    let (_subscription, rx) = subscribe_deltas(&server);

    let before = workspace_revision(&server);
    let rename = json!({"workspace": first, "name": "Research"});
    let reply = v2(&server, "workspace.rename", rename, Some("resource-deltas-rename"));
    assert_eq!(reply["ok"], true, "{reply}");
    let renamed = next_delta(&rx, "workspace-renamed");
    assert_eq!(renamed["entity"]["resource_id"], first.as_str(), "{renamed}");
    assert_eq!(renamed["entity"]["name"], "Research", "{renamed}");
    assert_eq!(renamed["workspace_revision"], before + 1, "{renamed}");

    let reply = v2(
        &server,
        "workspace.move",
        json!({"workspace": first, "index": 1}),
        Some("resource-deltas-move"),
    );
    assert_eq!(reply["ok"], true, "{reply}");
    let moved = next_delta(&rx, "workspace-moved");
    assert_eq!(moved["entity"]["resource_id"], first.as_str(), "{moved}");
    assert_eq!(moved["index"], 1, "{moved}");
    assert_eq!(moved["workspace_revision"], before + 2, "{moved}");
}

/// `cmux workspace list` in the cmux app's context (the daemon it addresses
/// is the app's own daemon) lists workspaces in the order the app's sidebar
/// shows. The NEXT sidebar shows the personal order: a new workspace goes on
/// top (`workspaces.newPlacement`), and Move Up/Down or a row drag moves only
/// the personal row. Elsewhere (a headless daemon, the TUI, whose sidebar
/// draws the session order) the list keeps the session order, and `--order`
/// always wins.
mod sidebar_order {
    use super::*;

    /// `cmux --json --socket <server> <args>`, inside the app's context when
    /// `in_app` (the app's Chief names its daemon in `CMUX_APP_DAEMON_SOCKET`).
    fn ids(server: &HeadlessServer, in_app: bool, args: &[&str]) -> Vec<String> {
        let mut command = Command::new(bin());
        command
            .args(["--json", "--socket"])
            .arg(&server.socket)
            .args(args)
            .env_remove("CMUX_TUI_SOCKET")
            .env_remove("CMUX_APP_DAEMON_SOCKET")
            .env_remove("CMUX_BUNDLE_ID")
            .env_remove("CMUX_TAG")
            .env_remove("CMUX_SOCKET_PATH");
        if in_app {
            command.env("CMUX_APP_DAEMON_SOCKET", &server.socket);
        }
        let output = command.output().unwrap();
        assert_success(&output);
        json_output(&output)
            .as_array()
            .unwrap_or_else(|| panic!("workspace list is no array: {}", json_output(&output)))
            .iter()
            .map(|workspace| workspace["id"].as_str().unwrap().to_string())
            .collect()
    }

    fn created(server: &HeadlessServer, name: &str) -> String {
        let output = json_cli(server, &["workspace", "create", "--empty", "--name", name]);
        assert_success(&output);
        json_output(&output)["value"]["workspace_id"].as_str().unwrap().to_string()
    }

    /// One `cmux.protocol/2` mutation on its own connection; its value.
    fn v2(server: &HeadlessServer, operation: &str, params: Value, key: &str) -> Value {
        let mut fields = json!({"machine": "current", "session": "current"});
        fields.as_object_mut().unwrap().extend(params.as_object().unwrap().clone());
        let request = json!({"protocol": "cmux.protocol/2", "type": "request",
                             "id": format!("order-{key}"), "operation": operation,
                             "params": fields, "idempotency_key": key});
        let stream = transport::connect(&server.socket).unwrap();
        let mut writer = stream.try_clone_box().unwrap();
        let mut reader = BufReader::new(stream);
        writeln!(writer, "{request}").unwrap();
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        let reply: Value = serde_json::from_str(&line).unwrap_or_else(|_| {
            panic!("{request}: no JSON reply: {line}; daemon:\n{}", server.stderr_tail())
        });
        assert_eq!(reply["ok"], true, "{request}: {reply}");
        reply["result"]["value"].clone()
    }

    #[test]
    fn workspace_list_in_the_app_answers_the_sidebar_order() {
        // The default placement (new workspaces on top), whatever the
        // developer's own settings file says.
        let dir = unique_temp_dir("ws-list-order-config");
        fs::create_dir_all(&dir).unwrap();
        let settings = dir.join("cmux.json");
        let settings = settings.to_str().unwrap();
        let server = HeadlessServer::start_with_options(
            "ws-list-order",
            None,
            None,
            &[("CMUX_NEXT_CONFIG_FILE", settings)],
        );
        let first = created(&server, "first");
        let second = created(&server, "second");
        let third = created(&server, "third");
        let position =
            |order: &[String], id: &str| order.iter().position(|candidate| candidate == id);

        let sidebar = ids(&server, false, &["workspace", "list", "--order", "personal"]);
        assert!(
            position(&sidebar, &third) < position(&sidebar, &second)
                && position(&sidebar, &second) < position(&sidebar, &first),
            "the sidebar order is not newest first: {sidebar:?}"
        );
        let session = ids(&server, false, &["workspace", "list"]);
        assert!(
            position(&session, &first) < position(&session, &second)
                && position(&session, &second) < position(&session, &third),
            "outside the app the list is not the session order: {session:?}"
        );
        assert_eq!(
            ids(&server, true, &["workspace", "list"]),
            sidebar,
            "workspace list in the app is not the sidebar order"
        );

        // A reorder in the sidebar (Move Workspace Up/Down, a row drag).
        v2(&server, "workspace.place", json!({"workspace": first, "index": 0}), "order-place-1");
        let sidebar = ids(&server, false, &["workspace", "list", "--order", "personal"]);
        assert_eq!(sidebar.first(), Some(&first), "the reorder did not apply: {sidebar:?}");
        assert_eq!(
            ids(&server, true, &["workspace", "list"]),
            sidebar,
            "workspace list in the app is not the sidebar order after a reorder"
        );
        // --order wins in the app too, and the list outside it is unchanged.
        assert_eq!(ids(&server, true, &["workspace", "list", "--order", "session"]), session);
        assert_eq!(ids(&server, false, &["workspace", "list"]), session);
        let _ = fs::remove_dir_all(&dir);
    }
}
