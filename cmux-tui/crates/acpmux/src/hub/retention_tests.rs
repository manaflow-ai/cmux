//! A pass never compacts a chat an import is replacing (`hub/retention.rs`, `transfer_in.rs`).

use super::*;
use crate::config::{Config, StoreMode};

#[tokio::test]
async fn a_chat_an_import_is_replacing_is_left_whole() {
    let root = std::env::temp_dir().join(format!("acpmux-retention-{}", uuid::Uuid::now_v7()));
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Local;
    let store = crate::store::open(&cfg.store, &root).unwrap();
    let meta = json!({
        "schema": crate::store::META_SCHEMA, "id": "old", "name": "old", "harness": "claude",
        "cwd": "/tmp", "status": "closed", "createdAt": 1, "updatedAt": 2,
    });
    store.save(&serde_json::from_value(meta).unwrap()).unwrap();
    let text = "x".repeat(5000);
    let record = |seq: u64, kind: &str, msg: Value| crate::store::EventRecord {
        seq,
        at: 2,
        dir: "in".into(),
        kind: kind.into(),
        msg,
        host_seq: None,
    };
    store.append("old", &record(1, "claude.assistant", json!({"text": text}))).unwrap();
    store.close_log("old");
    drop(store);
    let hub = Hub::new(cfg.clone(), crate::store::open(&cfg.store, &root).unwrap());
    let session = hub.resolve("old").unwrap();
    let req = || RetentionRequest { older_than_days: Some(0), ..Default::default() };

    // An import replacing it marks it before it moves its folder aside (`transfer_in.rs`).
    session.replaced.store(true, Ordering::SeqCst);
    let pass = hub.retention_pass(req()).await.unwrap();
    assert_eq!((&pass["chats"], &pass["skipped"]["busy"]), (&json!(0), &json!(1)), "{pass}");
    assert_eq!(hub.events("old", 0, 10).unwrap()[0].msg["text"], json!(text));

    // The same chat when nothing replaces it: the pass does compact it.
    session.replaced.store(false, Ordering::SeqCst);
    let pass = hub.retention_pass(req()).await.unwrap();
    assert_eq!(pass["chats"], 1, "{pass}");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}
