//! `new-conversation-tab` over the daemon socket of a real daemon announces
//! the tab it adds to an existing pane with ONE `tab-added` delta (cx-veznz).
//! With a client `transaction` that delta carries it
//! (`conversation-tab-transaction-v1`); without one it is a plain delta. The
//! daemon used to send a plain `tab-added` and then a second one carrying the
//! transaction, so the app listed the tab twice until it paired them.

use serde_json::{Value, json};

use super::*;

/// The `tab-added` deltas of the subscription up to and including the one
/// for `fence` (a later tab of the same pane), keyed by surface.
fn tab_added_until(rx: &mpsc::Receiver<String>, fence: u64) -> Vec<Value> {
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut added = Vec::new();
    let mut seen = Vec::new();
    while let Some(remaining) = deadline.checked_duration_since(Instant::now()) {
        let Ok(line) = rx.recv_timeout(remaining) else { break };
        let message: Value = serde_json::from_str(&line).unwrap();
        if message["event"] == "tab-added" {
            let done = message["surface"].as_u64() == Some(fence);
            added.push(message);
            if done {
                return added;
            }
        }
        seen.push(line);
    }
    panic!("no tab-added for fence surface {fence}; lines={seen:?}");
}

/// A settings page tab in `target` (`{"pane": id}` or `{"workspace": id}`).
fn new_page_tab(server: &HeadlessServer, target: Value, transaction: Option<&str>) -> u64 {
    let mut request = json!({"id": "tab", "cmd": "new-conversation-tab", "page": "settings"});
    request.as_object_mut().unwrap().extend(target.as_object().unwrap().clone());
    if let Some(transaction) = transaction {
        request["transaction"] = json!(transaction);
    }
    let created = json_socket_request(&server.socket, request);
    if let Some(transaction) = transaction {
        assert_eq!(created["transaction"], transaction, "{created}");
    }
    created["surface"].as_u64().unwrap_or_else(|| panic!("no surface: {created}"))
}

#[test]
fn a_new_conversation_tab_is_announced_once_with_its_transaction() {
    let server = HeadlessServer::start("conversation-tab-once");
    json_socket_request(&server.socket, json!({"id": 1, "cmd": "new-workspace"}));
    let tree = json_socket_request(&server.socket, json!({"id": 2, "cmd": "list-workspaces"}));
    let workspace = tree["workspaces"].as_array().and_then(|all| all.last()).cloned().unwrap();
    let pane = workspace["screens"][0]["panes"][0]["id"]
        .as_u64()
        .unwrap_or_else(|| panic!("no pane: {tree}"));
    let workspace_id = workspace["id"].as_u64().unwrap_or_else(|| panic!("no id: {tree}"));
    let (_subscription, rx) = subscribe_deltas(&server);

    let with_transaction = new_page_tab(&server, json!({"pane": pane}), Some("txn-cmd-t-1"));
    let plain = new_page_tab(&server, json!({"pane": pane}), None);
    // A workspace target lands in that workspace's active pane.
    let in_workspace =
        new_page_tab(&server, json!({"workspace": workspace_id}), Some("txn-cmd-t-2"));
    // A last tab fences the stream: every delta of the others precedes it.
    let fence = new_page_tab(&server, json!({"pane": pane}), None);
    let added = tab_added_until(&rx, fence);

    let of = |surface: u64| {
        added.iter().filter(|delta| delta["surface"].as_u64() == Some(surface)).collect::<Vec<_>>()
    };
    let announced = of(with_transaction);
    assert_eq!(announced.len(), 1, "one tab-added per tab: {added:?}");
    assert_eq!(announced[0]["transaction"], "txn-cmd-t-1", "{added:?}");
    assert_eq!(announced[0]["pane"], pane, "{added:?}");
    let announced = of(plain);
    assert_eq!(announced.len(), 1, "one tab-added per tab: {added:?}");
    assert!(announced[0].get("transaction").is_none(), "no transaction: {added:?}");
    let announced = of(in_workspace);
    assert_eq!(announced.len(), 1, "one tab-added per tab: {added:?}");
    assert_eq!(announced[0]["transaction"], "txn-cmd-t-2", "{added:?}");
}
