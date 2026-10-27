//! A pass never compacts a chat an import is replacing (`transfer_in.rs`) or one written to while
//! its log was read (`hub/retention.rs`).

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

#[tokio::test]
async fn a_chat_written_to_while_its_log_was_read_is_left_whole() {
    let root = std::env::temp_dir().join(format!("acpmux-retention-{}", uuid::Uuid::now_v7()));
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Local;
    let store = crate::store::open(&cfg.store, &root).unwrap();
    let meta = json!({
        "schema": crate::store::META_SCHEMA, "id": "old", "name": "old", "harness": "claude",
        "cwd": "/tmp", "status": "closed", "createdAt": 1, "updatedAt": 2,
    });
    store.save(&serde_json::from_value(meta).unwrap()).unwrap();
    let record = crate::store::EventRecord {
        seq: 1,
        at: 2,
        dir: "mux".into(),
        kind: "status".into(),
        msg: json!({"status": "closed"}),
        host_seq: None,
    };
    store.append("old", &record).unwrap();
    store.close_log("old");
    drop(store);
    let hub = Hub::new(cfg.clone(), crate::store::open(&cfg.store, &root).unwrap());
    let session = hub.resolve("old").unwrap();
    let hosted = std::collections::HashSet::new();
    let seen = hub.retainable(&session, now_ms(), &hosted).unwrap_or_else(|why| panic!("{why}"));
    assert!(hub.untouched(&session, seen), "nothing happened to it since");
    // While the pass read its log, it was reopened and closed again: each status write stamps
    // the chat before its record waits for the append lock the pass holds (`write_status`).
    std::thread::sleep(std::time::Duration::from_millis(2));
    assert!(hub.reopen(&session, session.stops.load(Ordering::SeqCst)));
    hub.set_status(&session, SessionStatus::Closed);
    assert_eq!(session.status(), SessionStatus::Closed);
    assert!(!hub.untouched(&session, seen), "a chat closed just now is not compacted");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// huge-blue, 2026-10-27: something stopped its 464 closed chats again every few minutes, each
/// stop dated the chat now, and none was ever older than a day, so no pass compacted any.
#[tokio::test]
async fn a_closed_chat_stopped_again_keeps_its_age() {
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
    let record = crate::store::EventRecord {
        seq: 1,
        at: 2,
        dir: "in".into(),
        kind: "claude.assistant".into(),
        msg: json!({"text": text}),
        host_seq: None,
    };
    store.append("old", &record).unwrap();
    store.close_log("old");
    drop(store);
    let hub = Hub::new(cfg.clone(), crate::store::open(&cfg.store, &root).unwrap());
    let session = hub.resolve("old").unwrap();
    hub.kill(&session, false).await.unwrap();
    assert_eq!(session.meta().updated_at, 2, "a stop that changed nothing dates nothing");
    assert_eq!(hub.events("old", 0, 10).unwrap().len(), 1, "and logs nothing");
    // The default 14 days: the chat closed long ago is compacted.
    let pass = hub.retention_pass(RetentionRequest::default()).await.unwrap();
    assert_eq!(pass["chats"], 1, "{pass}");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}
