//! The work below a session's turn follows its subagent tree whatever update changed it.

use super::*;
use crate::agent::Direction;
use crate::config::{Config, StoreMode};
use crate::rpc::Message;
use std::path::Path;

async fn chat() -> (Arc<Hub>, Arc<Session>) {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let session = hub.new_session(req).await.unwrap();
    (hub, session)
}

fn update(update: Value) -> Message {
    Message::Notification {
        method: crate::rpc::method::SESSION_UPDATE.to_owned(),
        params: Some(json!({"sessionId": "acp-root", "update": update})),
    }
}

/// A Codex echo of the chat's own thread, before the session metadata names that thread, reads
/// as a running background subagent, so the chat works below its turn. When the metadata names
/// the root, the next update drops that phantom, and the work below ends with it even when the
/// update carries no subagent event: no end event ever comes for the root.
#[tokio::test]
async fn a_root_learned_late_ends_the_work_below_it_held() {
    let (hub, session) = chat().await;
    let root = "root-native-thread";
    session.meta.lock().unwrap().agent_session_id = None;
    let tap = hub.session_tap(&session);
    tap(
        Direction::In,
        &update(json!({"sessionUpdate": "tool_call_update", "toolCallId": "echo-root",
            "_meta": {"codex": {"subagent": {"threadId": root,
              "path": "/root", "activity": "working"}}}})),
        None,
    );
    assert!(hub.work_below_since(&session).is_some(), "the echo reads as background work");

    session.meta.lock().unwrap().agent_session_id = Some(root.to_owned());
    tap(
        Direction::In,
        &update(json!({"sessionUpdate": "agent_message_chunk",
            "content": {"type": "text", "text": "hi"}})),
        None,
    );
    assert_eq!(
        session.subagents.lock().unwrap().background_running(),
        0,
        "the root is not background work"
    );
    assert_eq!(hub.work_below_since(&session), None, "the phantom still holds the chat working");
    let summary = hub.session_summary(&session);
    assert!(summary["subagentsWorkingSince"].is_null(), "{summary}");
    hub.shutdown_all().await;
}
