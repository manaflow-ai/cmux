//! A stop names who asked for it (`server/stop_requester.rs`, hq#22914): the closing `status`
//! record carries `stoppedBy`, a refused conditional stop leaves no name behind, and a stop the
//! daemon made itself closes the chat as `daemon`.

use super::*;
use crate::config::{Config, StoreMode};
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

/// The `stoppedBy` of the chat's closing `status` record.
fn closed_by(hub: &Hub, session: &Session) -> Option<Value> {
    hub.events(&session.id, 0, 10_000)
        .unwrap()
        .into_iter()
        .rev()
        .find(|e| e.kind == "status" && e.msg["status"] == "closed")
        .map(|e| e.msg["stoppedBy"].clone())
}

#[tokio::test]
async fn a_requested_stop_names_its_requester_on_the_close() {
    let (hub, session) = chat().await;
    let by = json!({"client": "acpmux-cli", "origin": "local", "pid": 4242});
    hub.stop_by(&session, false, stop_if_idle::StopCondition::default(), by.clone()).await.unwrap();
    assert_eq!(session.status(), SessionStatus::Closed);
    assert_eq!(closed_by(&hub, &session), Some(by));
    assert!(session.stop_by.lock().unwrap().is_none(), "the name goes with the stop");
}

#[tokio::test]
async fn a_daemons_own_stop_closes_as_the_daemon() {
    let (hub, session) = chat().await;
    hub.kill(&session, false).await.unwrap();
    assert_eq!(closed_by(&hub, &session), Some(json!({"origin": "daemon"})));
}

#[tokio::test]
async fn a_refused_conditional_stop_leaves_no_name() {
    let (hub, session) = chat().await;
    // A turn under way: `--if-idle` refuses.
    let _turn = session.turn_lock.lock().await;
    let condition = stop_if_idle::StopCondition { if_idle: true, expect_revision: None };
    let by = json!({"client": "reaper", "origin": "local"});
    assert!(hub.stop_by(&session, false, condition, by).await.is_err());
    assert_ne!(session.status(), SessionStatus::Closed);
    assert!(session.stop_by.lock().unwrap().is_none());
}
