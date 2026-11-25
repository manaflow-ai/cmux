//! Deleting old chat history on a setting (`hub/history_delete.rs`).

use super::*;
use crate::config::{Config, StoreMode};

struct Root(PathBuf);

impl Drop for Root {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

const DAY: u64 = 86_400_000;

/// A chat with two records, saved with `status`, `updated_at` and `tags`.
fn chat(store: &dyn crate::store::Store, id: &str, status: &str, updated_at: u64, tags: Value) {
    let meta = json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": format!("chat {id}"),
        "harness": "claude", "cwd": "/tmp", "status": status, "createdAt": 1,
        "updatedAt": updated_at, "lastSeq": 2, "eventCount": 2, "tags": tags,
    });
    store.save(&serde_json::from_value(meta).unwrap()).unwrap();
    for seq in 1..=2 {
        let record = EventRecord {
            seq,
            at: updated_at,
            dir: "mux".into(),
            kind: "user_message".into(),
            msg: json!({"text": format!("question {seq}")}),
            host_seq: None,
        };
        store.append(id, &record).unwrap();
    }
    store.close_log(id);
}

fn open(root: &Path) -> Arc<Hub> {
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Local;
    Hub::new(cfg.clone(), crate::store::open(&cfg.store, root).unwrap())
}

#[tokio::test]
async fn a_closed_chat_past_the_bound_is_deleted_and_one_inside_is_kept() {
    let root =
        Root(std::env::temp_dir().join(format!("acpmux-history-del-{}", uuid::Uuid::now_v7())));
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Local;
    let now = now_ms();
    {
        let store = crate::store::open(&cfg.store, &root.0).unwrap();
        chat(&*store, "old", "closed", now - 40 * DAY, json!({}));
        chat(&*store, "inside", "closed", now - 10 * DAY, json!({}));
        chat(&*store, "today", "closed", now, json!({}));
        // Past the bound but never deleted: an open chat and a pinned one.
        chat(&*store, "open", "idle", now - 40 * DAY, json!({}));
        chat(&*store, "pinned", "closed", now - 40 * DAY, json!({"pinned": {"value": "1"}}));
        chat(&*store, "attached", "closed", now - 40 * DAY, json!({}));
        store.flush().unwrap();
    }
    let hub = open(&root.0);
    let old_dir = hub.store.session_path("old").unwrap();
    assert!(old_dir.exists());
    let attached = hub.resolve("attached").unwrap();
    attached.attached.fetch_add(1, Ordering::SeqCst);
    let after = std::time::Duration::from_millis(30 * DAY);
    assert_eq!(hub.history_delete_pass_after(after).await, 1);
    assert!(hub.resolve("old").is_err(), "the chat past the bound is gone");
    assert!(!old_dir.exists(), "its folder is gone from disk");
    for kept in ["inside", "today", "open", "pinned", "attached"] {
        assert!(hub.resolve(kept).is_ok(), "{kept} is kept");
        assert!(hub.store.session_path(kept).unwrap().exists(), "{kept}'s folder is kept");
    }
    // A client let go: the next pass deletes it.
    attached.attached.fetch_sub(1, Ordering::SeqCst);
    assert_eq!(hub.history_delete_pass_after(after).await, 1);
    assert!(hub.resolve("attached").is_err());
    assert!(hub.resolve("inside").is_ok());
    hub.shutdown_all().await;
}

#[tokio::test]
async fn a_cold_archived_idle_chat_past_the_bound_is_deleted() {
    let root =
        Root(std::env::temp_dir().join(format!("acpmux-history-del-{}", uuid::Uuid::now_v7())));
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Local;
    let now = now_ms();
    {
        let store = crate::store::open(&cfg.store, &root.0).unwrap();
        chat(&*store, "cold", "idle", now - 40 * DAY, json!({}));
        store.flush().unwrap();
    }
    let hub = open(&root.0);
    let session = hub.resolve("cold").unwrap();
    hub.cold_archive_request(session.clone(), true).await.unwrap();
    assert!(hub.store.is_cold("cold"));
    assert_eq!(hub.history_delete_pass_after(std::time::Duration::from_millis(30 * DAY)).await, 1);
    assert!(hub.resolve("cold").is_err());
    hub.shutdown_all().await;
}

#[test]
fn the_setting_deletes_nothing_by_default() {
    assert_eq!(delete_after(&json!({})), None);
    assert_eq!(delete_after(&json!({"agents": {"chats": {"deleteHistoryAfterDays": 0}}})), None);
    assert_eq!(delete_after(&json!({"agents.chats.deleteHistoryAfterDays": "never"})), None);
    assert_eq!(
        delete_after(&json!({"agents": {"chats": {"deleteHistoryAfterDays": 30}}})),
        Some(std::time::Duration::from_secs(30 * 86_400))
    );
    assert_eq!(
        delete_after(&json!({"agents.chats.deleteHistoryAfterDays": "7d"})),
        Some(std::time::Duration::from_secs(7 * 86_400))
    );
}
