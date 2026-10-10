//! A left dock undocks on the left, through a real daemon (cx-x7pl).
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
            "dock": {"edge": "left", "mode": "docked"},
        }),
    );
    let docked = screen(&server, "dock");
    let dock = column_ids(&docked)
        .into_iter()
        .find(|id| !columns_before.contains(id))
        .expect("a new column");
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
