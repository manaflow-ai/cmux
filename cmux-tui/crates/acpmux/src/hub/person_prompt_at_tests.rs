use super::*;

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

#[test]
fn the_time_only_moves_forward() {
    let hub = test_hub();
    assert_eq!(hub.last_person_prompt_at(), None);
    let mut rx = hub.subscribe_person_prompts();
    hub.person_prompted(5_000);
    assert_eq!(hub.last_person_prompt_at(), Some(5_000));
    assert!(rx.has_changed().unwrap());
    rx.borrow_and_update();
    hub.person_prompted(4_000);
    assert_eq!(hub.last_person_prompt_at(), Some(5_000), "an older time never moves it back");
    assert!(!rx.has_changed().unwrap(), "nor wakes the report");
    hub.person_prompted(6_000);
    assert_eq!(hub.last_person_prompt_at(), Some(6_000));
}
