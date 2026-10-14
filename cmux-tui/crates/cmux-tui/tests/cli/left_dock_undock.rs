//! The agent chat dock through a real daemon: a left dock undocks on the left (cx-x7pl), and its
//! role and permanence survive a layout export and apply (cx-w62ew).
#![cfg(unix)]

use super::*;

fn request(server: &HeadlessServer, request: serde_json::Value) -> serde_json::Value {
    try_json_socket_request(&server.socket, request.clone())
        .unwrap_or_else(|| panic!("{request} failed; daemon stderr:\n{}", server.stderr_tail()))
}

/// The screen of the workspace named `name`.
fn screen(server: &HeadlessServer, name: &str) -> serde_json::Value {
    let tree = request(server, serde_json::json!({"cmd": "list-workspaces"}));
    tree["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .find(|workspace| workspace["name"] == name)
        .unwrap_or_else(|| panic!("no workspace {name}: {tree}"))["screens"][0]
        .clone()
}

fn column_ids(screen: &serde_json::Value) -> Vec<serde_json::Value> {
    screen["columns"].as_array().unwrap().iter().map(|column| column["id"].clone()).collect()
}

/// The pane holding `surface`.
fn pane_of(screen: &serde_json::Value, surface: &serde_json::Value) -> serde_json::Value {
    screen["panes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|pane| pane["tabs"].as_array().unwrap().iter().any(|tab| tab["surface"] == *surface))
        .unwrap_or_else(|| panic!("no pane holds {surface}: {screen}"))["id"]
        .clone()
}

/// The agent chat dock is a tab moved into a new column pinned to the left
/// edge. Undocking it must scroll it in on the left, where it was shown,
/// not after the strip's last column on the right.
#[test]
fn a_tab_moved_into_a_left_dock_undocks_on_the_left() {
    let server = HeadlessServer::start("left-dock-undock");
    request(
        &server,
        serde_json::json!({"cmd": "new-workspace", "name": "dock", "cols": 160, "rows": 40}),
    );
    let first = screen(&server, "dock");
    let pane = first["panes"][0]["id"].clone();
    request(&server, serde_json::json!({"cmd": "new-pane-right", "pane": pane, "width": 0.5}));
    let strip = screen(&server, "dock");
    let right = strip["panes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|pane| pane["id"].clone())
        .find(|id| *id != pane)
        .unwrap();
    request(&server, serde_json::json!({"cmd": "new-tab", "pane": right}));
    let before = screen(&server, "dock");
    let tabs = before["panes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|candidate| candidate["id"] == right)
        .unwrap()["tabs"]
        .clone();
    let chat = tabs.as_array().unwrap().last().unwrap()["surface"].clone();
    let columns_before = column_ids(&before);

    request(
        &server,
        serde_json::json!({
            "cmd": "move-tab-to-column",
            "surface": chat,
            "pane": right,
            "dock": {"edge": "left", "mode": "docked", "role": "agent_chat"},
        }),
    );
    let docked = screen(&server, "dock");
    let dock = column_ids(&docked)
        .into_iter()
        .find(|id| !columns_before.contains(id))
        .expect("a new column");
    // The move pins the new column with its role, and the left dock leads the order.
    assert_eq!(column_ids(&docked)[0], dock, "the left dock must lead the order: {docked}");
    assert_eq!(
        docked["columns"][0]["dock"],
        serde_json::json!({"edge": "left", "mode": "docked", "role": "agent_chat"}),
        "{docked}"
    );
    let dock_pane = pane_of(&docked, &chat);

    request(
        &server,
        serde_json::json!({"cmd": "set-column-dock", "pane": dock_pane, "dock": false}),
    );
    let undocked = screen(&server, "dock");
    let columns = column_ids(&undocked);
    assert_eq!(columns.len(), 3, "{undocked}");
    assert!(
        undocked["columns"].as_array().unwrap().iter().all(|column| column.get("dock").is_none()),
        "{undocked}"
    );
    assert_eq!(columns[0], dock, "the undocked chat column must lead the strip: {columns:?}");
}

/// The agent chat column (a left dock with its role, kept permanent) is part
/// of the screen's public layout (cx-w62ew): `screen layout export` returns
/// it with that dock, and applying the exported document keeps it.
#[test]
fn an_agent_chat_dock_exports_and_applies_with_its_role() {
    let server = HeadlessServer::start("agent-chat-dock-export");
    let created = json_cli(&server, &["workspace", "create", "--name", "chat"]);
    assert_success(&created);
    let created = json_output(&created);
    let workspace_id = created["value"]["workspace_id"].as_str().unwrap().to_string();
    let screen_id = created["value"]["screen_id"].as_str().unwrap().to_string();
    let first = screen(&server, "chat");
    let pane = first["panes"][0]["id"].clone();
    request(&server, serde_json::json!({"cmd": "new-pane-right", "pane": pane, "width": 0.5}));
    let strip = screen(&server, "chat");
    let right = strip["panes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|pane| pane["id"].clone())
        .find(|id| *id != pane)
        .unwrap();
    request(&server, serde_json::json!({"cmd": "new-tab", "pane": right}));
    let tabs = screen(&server, "chat")["panes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|candidate| candidate["id"] == right)
        .unwrap()["tabs"]
        .clone();
    let chat = tabs.as_array().unwrap().last().unwrap()["surface"].clone();
    request(
        &server,
        serde_json::json!({
            "cmd": "move-tab-to-column",
            "surface": chat,
            "pane": right,
            "dock": {"edge": "left", "mode": "docked", "role": "agent_chat"},
        }),
    );
    let dock_pane = pane_of(&screen(&server, "chat"), &chat);
    request(
        &server,
        serde_json::json!({
            "cmd": "set-column-dock", "pane": dock_pane, "dock": true, "edge": "left",
            "mode": "docked", "role": "agent_chat", "permanent": true,
        }),
    );
    let dock = serde_json::json!({"edge": "left", "mode": "docked", "role": "agent_chat", "permanent": true});
    assert_eq!(screen(&server, "chat")["columns"][0]["dock"], dock);

    let docks = |document: &serde_json::Value| -> Vec<serde_json::Value> {
        document["root"]["columns"]
            .as_array()
            .unwrap_or_else(|| panic!("no viewport columns: {document}"))
            .iter()
            .filter_map(|column| column.get("dock").cloned())
            .collect()
    };
    let exported = json_cli(&server, &["screen", &screen_id, "layout", "export"]);
    assert_success(&exported);
    let document = json_output(&exported);
    assert_eq!(docks(&document), vec![dock.clone()], "{document}");

    let layout = document.to_string();
    let applied =
        json_cli(&server, &["workspace", &workspace_id, "layout", "apply", "--layout", &layout]);
    assert_success(&applied);
    let again = json_cli(&server, &["screen", &screen_id, "layout", "export"]);
    assert_success(&again);
    assert_eq!(docks(&json_output(&again)), vec![dock], "{}", json_output(&again));
}
