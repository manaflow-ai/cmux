//! A hold another machine wrote is not restored (`rate_hold.rs`, `restore_rate_hold`): a chat
//! moved to a Cloud machine answers on the team's gateway there, not on the login whose limit
//! held it where it came from.

use super::*;
use crate::config::{Config, StoreMode};
use std::path::Path;
use std::sync::atomic::Ordering;

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

/// The chat's log read back as after a move or restart, its last record `kind` with `msg`.
async fn restored_with(kind: &str, msg: Value) -> (bool, u32) {
    let (hub, session) = chat().await;
    hub.append(&session, "mux", kind, msg);
    session.rate_hold.restored.store(false, Ordering::SeqCst);
    hub.restore_rate_hold(&session);
    let out = (Hub::rate_held(&session), session.rate_hold_strikes());
    hub.shutdown_all().await;
    out
}

#[tokio::test]
async fn a_hold_another_machine_wrote_holds_nothing_here() {
    let until = now_ms() + 3_600_000;
    let elsewhere = "a-mac-whose-login-was-used-up.local";
    let held = json!({"turnId": "t-cut", "until": until, "strikes": 1, "host": elsewhere});
    assert_eq!(restored_with("rate_limit_held", held).await, (false, 0));
    let parked = json!({"turnId": "t-cut", "strikes": 6, "why": "strikes", "host": elsewhere});
    assert_eq!(restored_with("rate_limit_parked", parked).await, (false, 0));
}

#[tokio::test]
async fn a_hold_this_machine_wrote_or_one_naming_no_machine_still_holds() {
    let until = now_ms() + 3_600_000;
    let here = json!({"turnId": "t-cut", "until": until, "strikes": 1, "host": hold_host()});
    assert_eq!(restored_with("rate_limit_held", here).await, (true, 1));
    let before_hosts = json!({"turnId": "t-cut", "until": until, "strikes": 2});
    assert_eq!(restored_with("rate_limit_held", before_hosts).await, (true, 2));
}

/// Each hold record names the machine that wrote it.
#[tokio::test]
async fn a_hold_names_its_machine() {
    let (hub, session) = chat().await;
    hub.hold_for_rate_limit(&session, "t-cut", now_ms() + 600_000, false);
    let held = hub.events(&session.id, 0, 10_000).unwrap();
    let held = held.iter().rev().find(|e| e.kind == "rate_limit_held").unwrap();
    assert_eq!(held.msg["host"].as_str(), Some(hold_host().as_str()));
    hub.shutdown_all().await;
}
