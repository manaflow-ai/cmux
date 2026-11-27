//! `_acpmux/status` answers while a chat's agent starts or ends (cmuxterm-hq#8489): every pane's
//! handshake asks it, so a status that waited on one chat's child lock drew "Waiting for the agent
//! service" in every pane.

use super::super::*;
use std::time::Duration;

/// A hub on the stand-in agent, its store in `dir`.
fn hub_in(dir: &std::path::Path) -> Arc<Hub> {
    use crate::config::{Config, StoreMode};
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let cfg = json!({"harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake"});
    let mut cfg: Config = serde_json::from_value(cfg).unwrap();
    cfg.store.mode = StoreMode::Local;
    let store = crate::store::open(&cfg.store, dir).unwrap();
    Hub::new(cfg, store)
}

/// A chat whose child lock is held (a detach ending its agent, a start placing one) neither holds
/// up status nor drops out of `liveAgents`.
#[tokio::test]
async fn status_answers_while_a_chat_holds_its_child_lock() {
    let dir = std::env::temp_dir().join(format!("acpmux-status-{}", uuid::Uuid::now_v7()));
    let hub = hub_in(&dir);
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let s = hub.new_session(req).await.unwrap();
    let blocks = vec![json!({"type": "text", "text": "hi"})];
    hub.prompt_with(&s, blocks, "test", false, PromptOptions::default()).await.unwrap();
    let held = s.child.lock().await;
    assert!(held.is_some(), "the chat's agent did not start");
    let status = tokio::time::timeout(Duration::from_secs(5), hub.status())
        .await
        .expect("status waited on a chat's child lock");
    assert_eq!(status["liveAgents"], 1, "{status}");
    drop(held);
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&dir);
}
