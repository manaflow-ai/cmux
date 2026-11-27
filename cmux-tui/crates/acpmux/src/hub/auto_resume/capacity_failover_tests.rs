use super::*;

#[test]
fn the_switch_comes_at_the_configured_attempt_and_after() {
    assert!(!fails_over_at(1, 3));
    assert!(!fails_over_at(2, 3));
    assert!(fails_over_at(3, 3));
    assert!(fails_over_at(7, 3));
    assert!(fails_over_at(1, 1));
    // 0 never switches.
    assert!(!fails_over_at(1, 0));
    assert!(!fails_over_at(50, 0));
}

#[test]
fn the_notices_name_both_models() {
    assert_eq!(
        failover_text("claude-opus-5-5", "claude-sonnet-5-5"),
        "acpmux: Anthropic overloaded: continuing on claude-sonnet-5-5 (was claude-opus-5-5); back when it recovers"
    );
    let back = restored_text("claude-opus-5-5", "claude-sonnet-5-5");
    assert!(back.contains("continuing on claude-opus-5-5"), "{back}");
    assert!(back.contains("claude-sonnet-5-5"), "{back}");
}

#[tokio::test]
async fn automatic_restart_capacity_switch_and_restore_preserve_background_work() {
    use crate::hub::NewRequest;
    use std::sync::atomic::Ordering;

    const OPUS: &str = "claude-opus-5-5";
    const SONNET: &str = "claude-sonnet-5-5";
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut config: crate::config::Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake], "env": {"MODEL": "${model}"}}},
        "defaultHarness": "fake",
        "capacityFallbackAfter": 1,
    }))
    .unwrap();
    config.store.mode = crate::config::StoreMode::Memory;
    config.profile_sources = crate::config::ProfileSources::none();
    config.capacity_fallback_after = Some(1);
    let store = crate::store::open(&config.store, std::path::Path::new("/unused")).unwrap();
    let hub = Hub::new(config, store);
    let session = hub
        .new_session(NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() })
        .await
        .unwrap();
    hub.set_model(&session, OPUS).await.unwrap();
    hub.prompt(&session, vec![json!({"type": "text", "text": "hello"})], "test", false)
        .await
        .unwrap();
    let child = session.child.lock().await.clone().unwrap();
    *session.work_below_since.lock().unwrap() = 1;

    hub.fail_over_on_capacity(&session, "cut", 1).await;
    assert_eq!(session.meta().model_request.as_deref(), Some(SONNET));
    assert!(session.respawn_when_quiet.load(Ordering::SeqCst));
    assert!(Arc::ptr_eq(&child, session.child.lock().await.as_ref().unwrap()));
    assert!(!hub.end_marked_restart_before_retry(&session, 0).await);

    let fallback = session.meta.lock().unwrap().capacity_fallback.take().unwrap();
    hub.put_back(&session, fallback).await;
    assert_eq!(session.meta().model_request.as_deref(), Some(OPUS));
    assert!(Arc::ptr_eq(&child, session.child.lock().await.as_ref().unwrap()));
    assert!(!hub.end_marked_restart_before_retry(&session, 0).await);
    *session.work_below_since.lock().unwrap() = 0;
    assert!(hub.end_marked_restart_before_retry(&session, 0).await);
    assert!(session.child.lock().await.is_none());
    assert_ne!(session.meta().hibernated_ms, 0);
    hub.shutdown_all().await;
}
