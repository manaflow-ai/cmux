//! A chat's summary `effort` falls back to the effort its agent was launched at
//! (`launch_effort.rs`) when the harness reports none, and the start records it in the chat's
//! metadata (Leo, 2026-11-20: "We need to absolutely f***ing not wait on efficiency").

use super::*;
use serde_json::json;

fn hub_with(argv_tail: &[&str]) -> Arc<Hub> {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut argv = vec![json!("python3"), json!(fake)];
    argv.extend(argv_tail.iter().map(|w| json!(w)));
    let mut cfg: crate::config::Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": argv}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

async fn started(hub: &Arc<Hub>, name: &str) -> Arc<Session> {
    let session = hub
        .new_session(NewRequest {
            harness: Some("fake".into()),
            name: Some(name.into()),
            cwd: Some(std::env::temp_dir()),
            ..NewRequest::default()
        })
        .await
        .unwrap();
    hub.child_for(&session).await.expect("an agent");
    session
}

#[tokio::test]
async fn a_launch_effort_shows_when_the_harness_reports_none() {
    let hub = hub_with(&["--effort", "medium"]);
    let session = started(&hub, "launched-medium").await;
    assert_eq!(session.meta().launch_effort.as_deref(), Some("medium"));
    let summary = hub.session_summary(&session);
    assert_eq!(summary["effort"], json!("medium"), "{summary}");
}

#[tokio::test]
async fn a_launch_with_no_effort_records_none() {
    let hub = hub_with(&[]);
    let session = started(&hub, "launched-plain").await;
    assert_eq!(session.meta().launch_effort, None);
    assert!(hub.session_summary(&session)["effort"].is_null());
}

#[test]
fn a_meta_from_an_older_build_reads_no_launch_effort_and_writes_none() {
    let meta: crate::store::SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "s", "name": "s", "harness": "fake",
        "cwd": "/w", "status": "ready", "createdAt": 0, "updatedAt": 0,
    }))
    .unwrap();
    assert_eq!(meta.launch_effort, None);
    assert!(serde_json::to_value(&meta).unwrap().get("launchEffort").is_none());
}
