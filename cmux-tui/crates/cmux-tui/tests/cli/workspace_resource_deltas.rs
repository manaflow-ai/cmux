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
