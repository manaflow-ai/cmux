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
async fn time_breakdown_is_lazy_and_updates_after_append() {
    let hub = test_hub();
    let session = hub
        .new_session(NewRequest {
            harness: Some("fake".into()),
            name: Some("time-breakdown".into()),
            cwd: Some(std::env::temp_dir()),
            ..NewRequest::default()
        })
        .await
        .unwrap();

    assert!(!session.time_breakdown.lock().unwrap().initialized);
    assert!(hub.session_list_summary(&session).get("timeBreakdown").is_none());
    assert!(!session.time_breakdown.lock().unwrap().initialized);
    assert!(hub.session_summary(&session).get("timeBreakdown").is_none());
    assert!(!session.time_breakdown.lock().unwrap().initialized);

    hub.append_at(
        &session,
        "mux",
        "turn_started",
        json!({"turnSeq": 1, "turnId": "turn-1"}),
        None,
        Some(100),
    );
    hub.append_at(
        &session,
        "mux",
        "turn_result",
        json!({"turnSeq": 1, "turnId": "turn-1", "totalTokens": 5}),
        None,
        Some(200),
    );

    // Attach answers without waiting on the append lock or the seed's journal read.
    {
        let _append = session.append_lock.lock().unwrap();
        let detail = hub.session_detail(&session);
        assert!(detail.get("timeBreakdown").is_none());
        assert!(!session.time_breakdown.lock().unwrap().initialized);
    }
    // The seed the detail started in the background, run here so the test need not wait.
    hub.seed_time_breakdown(&session, false);
    let detail = hub.session_detail(&session);
    assert!(session.time_breakdown.lock().unwrap().initialized);
    assert_eq!(detail["timeBreakdown"]["totalMs"], 100);
    assert_eq!(detail["timeBreakdown"]["totalTokens"], 5);

    hub.append_at(
        &session,
        "mux",
        "turn_started",
        json!({"turnSeq": 2, "turnId": "turn-2"}),
        None,
        Some(300),
    );
    hub.append_at(
        &session,
        "mux",
        "turn_result",
        json!({"turnSeq": 2, "turnId": "turn-2", "totalTokens": 7}),
        None,
        Some(450),
    );

    let summary = hub.session_summary(&session);
    assert!(session.time_breakdown.lock().unwrap().initialized);
    assert_eq!(summary["timeBreakdown"]["totalMs"], 250);
    assert_eq!(summary["timeBreakdown"]["totalTokens"], 12);
}
