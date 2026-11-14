//! `status` answers while a reading it takes waits (`hub/views.rs`, ask-64cfa32e34): every
//! pane's connect waits on it, so one chat's agent starting or ending must not hold it.

use super::*;
use serde_json::json;

fn test_hub() -> Arc<Hub> {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: crate::config::Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

#[tokio::test]
async fn status_answers_while_a_chat_holds_its_agent_slot() {
    let hub = test_hub();
    let session = hub
        .new_session(NewRequest {
            harness: Some("fake".into()),
            name: Some("slot-held".into()),
            cwd: Some(std::env::temp_dir()),
            ..NewRequest::default()
        })
        .await
        .unwrap();
    // What an agent's start or kill does for as long as it takes.
    let _held = session.child.lock().await;
    let started = std::time::Instant::now();
    let status = tokio::time::timeout(std::time::Duration::from_secs(5), hub.status())
        .await
        .expect("status waited on a chat's agent slot");
    assert!(started.elapsed() < std::time::Duration::from_secs(3), "{:?}", started.elapsed());
    // Never 0 while a slot is held: readers take 0 as idle (`RemoteAgentDaemon.idleForKeyedRestart`).
    assert_ne!(status["liveAgents"], json!(0), "{status}");
    assert_eq!(status["sessions"], json!(1), "{status}");
    assert!(status["build"].is_string(), "{status}");
}

#[tokio::test]
async fn status_does_not_hold_the_config_lock_while_a_reading_waits() {
    let hub = test_hub();
    let session = hub
        .new_session(NewRequest {
            harness: Some("fake".into()),
            name: Some("config-writer".into()),
            cwd: Some(std::env::temp_dir()),
            ..NewRequest::default()
        })
        .await
        .unwrap();
    let held = session.child.lock().await;
    let status = tokio::spawn({
        let hub = hub.clone();
        async move { hub.status().await }
    });
    // Let status reach its readings, then a config writer must get in at once.
    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    drop(
        tokio::time::timeout(std::time::Duration::from_millis(500), hub.config.write())
            .await
            .expect("status held the config lock while it waited on a chat's agent slot"),
    );
    drop(held);
    tokio::time::timeout(std::time::Duration::from_secs(5), status).await.unwrap().unwrap();
}
