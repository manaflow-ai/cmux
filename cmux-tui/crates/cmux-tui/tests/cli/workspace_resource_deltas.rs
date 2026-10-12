//! `cmux workspace <id> rename` and `move` (the `workspace.rename` and
//! `workspace.move` resource operations) committed without the tree delta
//! the legacy commands emit, so the app's sidebar kept the old name until a
//! later change made it resync (cx-urd.5 daily-driver capture). A
//! `subscribe` client now sees each one, at the next workspace revision.

use serde_json::{Value, json};

use super::*;

/// One `cmux.protocol/2` mutation, as the CLI sends it.
fn v2(server: &HeadlessServer, operation: &str, params: Value) -> Value {
    let mut fields = json!({"machine": "current", "session": "current"});
    fields.as_object_mut().unwrap().extend(params.as_object().unwrap().clone());
    let request = json!({"protocol": "cmux.protocol/2", "type": "request",
                         "id": format!("resource-deltas-{operation}"), "operation": operation,
                         "idempotency_key": format!("resource-deltas-{operation}"),
                         "params": fields});
    let stream = transport::connect(&server.socket).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    writeln!(writer, "{request}").unwrap();
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    let reply: Value = serde_json::from_str(&line)
        .unwrap_or_else(|_| panic!("{operation}: no JSON reply: {line}"));
    assert_eq!(reply["ok"], true, "{reply}");
    reply
}

/// A raw `subscribe` with tree deltas, as the app opens it; its lines arrive
/// on the receiver. The returned writer keeps the connection open.
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
    let line = rx.recv_timeout(Duration::from_secs(5)).expect("no subscribe reply");
    let reply: Value = serde_json::from_str(&line).unwrap();
    assert_eq!(reply["ok"], true, "subscribe failed: {reply}");
    (writer, rx)
}

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
    v2(&server, "workspace.rename", json!({"workspace": first, "name": "Research"}));
    let renamed = next_delta(&rx, "workspace-renamed");
    assert_eq!(renamed["entity"]["resource_id"], first.as_str(), "{renamed}");
    assert_eq!(renamed["entity"]["name"], "Research", "{renamed}");
    assert_eq!(renamed["workspace_revision"], before + 1, "{renamed}");

    v2(&server, "workspace.move", json!({"workspace": first, "index": 1}));
    let moved = next_delta(&rx, "workspace-moved");
    assert_eq!(moved["entity"]["resource_id"], first.as_str(), "{moved}");
    assert_eq!(moved["index"], 1, "{moved}");
    assert_eq!(moved["workspace_revision"], before + 2, "{moved}");
}
