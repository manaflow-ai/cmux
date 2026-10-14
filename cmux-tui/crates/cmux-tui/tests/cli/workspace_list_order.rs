//! `cmux workspace list` lists workspaces in the order the sidebar shows
//! them. The sidebar shows the personal order (`personal-mixed-order-v1`):
//! a new workspace goes to the top by default (`workspaces.newPlacement`),
//! and a reorder in the sidebar moves the personal row only. The list used
//! to answer the session order (creation order), so an agent that read
//! `workspace list` saw another order than the person.

use serde_json::{Value, json};

use super::*;

fn ids(output: &Output) -> Vec<String> {
    assert_success(output);
    json_output(output)
        .as_array()
        .unwrap_or_else(|| panic!("workspace list is no array: {}", json_output(output)))
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
    let reply = try_json_socket_request(&server.socket, request.clone())
        .unwrap_or_else(|| panic!("{request}: no reply; daemon:\n{}", server.stderr_tail()));
    assert_eq!(reply["ok"], true, "{request}: {reply}");
    reply["result"]["value"].clone()
}

#[test]
fn workspace_list_answers_the_sidebar_order_after_creates_and_a_reorder() {
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

    let sidebar = ids(&json_cli(&server, &["workspace", "list", "--order", "personal"]));
    let position = |order: &[String], id: &str| order.iter().position(|candidate| candidate == id);
    // The sidebar shows the newest workspace first.
    assert!(
        position(&sidebar, &third) < position(&sidebar, &second)
            && position(&sidebar, &second) < position(&sidebar, &first),
        "the sidebar order is not newest first: {sidebar:?}"
    );
    let listed = ids(&json_cli(&server, &["workspace", "list"]));
    assert_eq!(listed, sidebar, "workspace list is not the sidebar order");

    // A reorder in the sidebar (Move Workspace Up/Down, a row drag): the
    // first workspace goes to the top.
    v2(&server, "workspace.place", json!({"workspace": first, "index": 0}), "order-place-1");
    let sidebar = ids(&json_cli(&server, &["workspace", "list", "--order", "personal"]));
    assert_eq!(sidebar.first(), Some(&first), "the reorder did not apply: {sidebar:?}");
    let listed = ids(&json_cli(&server, &["workspace", "list"]));
    assert_eq!(listed, sidebar, "workspace list is not the sidebar order after a reorder");

    // The session order stays available.
    let session = ids(&json_cli(&server, &["workspace", "list", "--order", "session"]));
    assert!(
        position(&session, &first) < position(&session, &second)
            && position(&session, &second) < position(&session, &third),
        "the session order is not creation order: {session:?}"
    );
    let _ = fs::remove_dir_all(&dir);
}
