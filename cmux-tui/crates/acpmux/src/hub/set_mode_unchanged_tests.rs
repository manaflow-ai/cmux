//! `set_mode` to the mode the chat already runs (a start's, a wake's or a policy's set of the
//! same mode) tells the harness but logs no `mode` record (idle-gpu-disk; Leo, 2026-11-18: "disk
//! growth too i feel like").

use super::*;

#[tokio::test]
async fn set_mode_preserves_the_harness_reported_mode() {
    use crate::config::{Config, StoreMode};
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": [
            "/usr/bin/env", "FAKE_SET_MODE_ACTUAL=strict", "python3", fake
        ]}},
        "defaultHarness": "fake"
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let session = hub
        .new_session(NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() })
        .await
        .unwrap();
    let answer = hub.set_mode(&session, "full-access").await.unwrap();
    assert_eq!(answer["currentModeId"], "strict");
    assert_eq!(crate::web_modes::mode_of(&session.meta()).as_deref(), Some("strict"));
    assert_ne!(session.meta().mode_set_by_cmux.as_deref(), Some("full-access"));
    let events = hub.events(&session.id, 0, 10_000).unwrap();
    let modes: Vec<_> = events.iter().filter(|e| e.dir == "mux" && e.kind == "mode").collect();
    assert_eq!(modes.last().unwrap().msg["modeId"], "strict");
    hub.shutdown_all().await;
}

#[tokio::test]
async fn the_same_mode_set_twice_logs_one_record() {
    use crate::config::{Config, StoreMode};
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let cfg = json!({"harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake"});
    let mut cfg: Config = serde_json::from_value(cfg).unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let s = hub.new_session(req).await.unwrap();
    let modes = |hub: &Hub| {
        hub.events(&s.id, 0, 10_000)
            .unwrap()
            .into_iter()
            .filter(|e| e.dir == "mux" && e.kind == "mode")
            .map(|e| e.msg["modeId"].as_str().unwrap_or_default().to_owned())
            .collect::<Vec<_>>()
    };
    let start = modes(&hub);
    // The fake agent starts in `normal` and offers `strict`.
    hub.set_mode(&s, "strict").await.unwrap();
    hub.set_mode(&s, "strict").await.unwrap();
    let current = |s: &Session| crate::web_modes::mode_of(&s.meta());
    assert_eq!(current(&s).as_deref(), Some("strict"));
    let mut want = start.clone();
    want.push("strict".to_owned());
    assert_eq!(modes(&hub), want, "the same mode set twice logged twice");
    hub.set_mode(&s, "normal").await.unwrap();
    want.push("normal".to_owned());
    assert_eq!(modes(&hub), want, "a mode change logs its record");
    assert_eq!(current(&s).as_deref(), Some("normal"));
    hub.shutdown_all().await;
}
