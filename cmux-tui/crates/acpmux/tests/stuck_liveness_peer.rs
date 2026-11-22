//! A peer gets the liveness class, but no diagnostic text or timestamp.
#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();
use acpmux::rpc::{Message, method};
use acpmux::server::peer_text::masked;
use serde_json::{Value, json};

fn summary() -> Value {
    json!({
        "sessionId": "s1", "name": "stuck", "harness": "claude", "status": "ready",
        "state": "stuck", "stuckReason": "harness_unavailable", "stuckSince": 1234,
        "stuckError": "HTTP 503 https://user:secret@example.invalid/inference", "lastSeq": 9
    })
}

fn response(message: Message) -> Value {
    match message {
        Message::Response { result: Some(value), .. } => value,
        Message::Notification { params: Some(value), .. } => value,
        other => panic!("unexpected message: {other:?}"),
    }
}

#[test]
fn peer_session_list_keeps_stuck_class_but_drops_details() {
    let reply = Message::ok(json!(1), json!({"sessions": [summary()]}));
    let result = response(masked(&reply).expect("summary changed"));
    let row = &result["sessions"][0];
    assert_eq!(row["state"], "stuck");
    assert_eq!(row["stuckReason"], "harness_unavailable");
    assert!(row.get("stuckSince").is_none(), "peer received timestamp: {row}");
    assert!(row.get("stuckError").is_none(), "peer received diagnostic: {row}");
}

#[test]
fn peer_session_changed_watch_keeps_stuck_class_but_drops_details() {
    let note = Message::notification(
        method::MUX_SESSION_CHANGED,
        json!({"sessionId": "s1", "kind": "status", "session": summary()}),
    );
    let result = response(masked(&note).expect("summary changed"));
    let row = &result["session"];
    assert_eq!(row["state"], "stuck");
    assert_eq!(row["stuckReason"], "harness_unavailable");
    assert!(row.get("stuckSince").is_none(), "peer received timestamp: {row}");
    assert!(row.get("stuckError").is_none(), "peer received diagnostic: {row}");
}
