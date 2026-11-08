//! `acp history` keeps a turn result's `detail`: a turn a daemon restart cut short reads as the
//! interrupted outcome (status failed, detail outcome_unknown), not as a plain failure.

use super::*;

#[test]
fn a_history_row_keeps_the_turn_results_detail() {
    let mut cfg = Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let meta: SessionMeta = serde_json::from_value(json!({
        "schema": META_SCHEMA, "id":"history-detail", "name":"detail", "harness":"fake",
        "cwd":"/tmp", "status":"idle", "createdAt":1, "updatedAt":1
    }))
    .unwrap();
    store.save(&meta).unwrap();
    let hub = Hub::new(cfg, store);
    let session = hub.resolve("history-detail").unwrap();
    hub.append(&session, "client", "user_message", json!({"text": "cut short"}));
    hub.append(
        &session,
        "mux",
        "turn_result",
        json!({"turnId": "cut", "status": "failed", "detail": "outcome_unknown"}),
    );
    hub.append(&session, "client", "user_message", json!({"text": "done"}));
    hub.append(&session, "mux", "turn_result", json!({"turnId": "done", "status": "completed"}));

    let turns = hub.history(&session, 20);
    let cut = turns.iter().find(|t| t["prompt"] == "cut short").unwrap();
    assert_eq!(cut["status"], "failed");
    assert_eq!(cut["detail"], "outcome_unknown");
    let done = turns.iter().find(|t| t["prompt"] == "done").unwrap();
    assert_eq!(done["status"], "completed");
    assert!(done.get("detail").is_none(), "a result with no detail adds none: {done}");
}
