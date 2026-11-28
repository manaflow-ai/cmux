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

/// Whether chat `id` is deleted: still there, hidden (archived) and tagged with when.
fn is_deleted(hub: &Hub, id: &str) -> bool {
    let meta = hub.resolve(id).unwrap().meta();
    meta.tags.contains_key(DELETED_TAG) && meta.tags.contains_key("archived")
}

/// Moves chat `id`'s delete `days` back, as if its undo window had been running that long.
fn deleted_days_ago(hub: &Hub, id: &str, days: u64) {
    let session = hub.resolve(id).unwrap();
    let mut set = serde_json::Map::new();
    set.insert(DELETED_TAG.into(), json!((now_ms() - days * DAY).to_string()));
    hub.set_tags(&session, Some(&set), &[], None);
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
    assert!(is_deleted(&hub, "old"), "the chat past the bound is deleted");
    assert!(old_dir.exists(), "its folder stays for the undo window");
    for kept in ["inside", "today", "open", "pinned", "attached"] {
        assert!(!is_deleted(&hub, kept), "{kept} is kept");
        assert!(hub.store.session_path(kept).unwrap().exists(), "{kept}'s folder is kept");
    }
    // Inside its undo window, a pass purges nothing.
    assert_eq!(hub.history_delete_pass_after(after).await, 0);
    assert!(old_dir.exists());
    // Past it, the next pass purges it: folder and all.
    deleted_days_ago(&hub, "old", UNDO_DAYS + 1);
    let req = HistoryDeleteRequest { older_than_days: Some(30), ..Default::default() };
    let report = hub.history_delete_now(req).await.unwrap();
    assert_eq!(report["purged"], 1, "{report}");
    assert!(hub.resolve("old").is_err(), "purged");
    assert!(!old_dir.exists(), "its folder is gone from disk");
    // A client let go: the next pass deletes it.
    attached.attached.fetch_sub(1, Ordering::SeqCst);
    assert_eq!(hub.history_delete_pass_after(after).await, 1);
    assert!(is_deleted(&hub, "attached"));
    assert!(!is_deleted(&hub, "inside"));
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
    let req = HistoryDeleteRequest { older_than_days: Some(30), ..Default::default() };
    let report = hub.history_delete_now(req).await.unwrap();
    assert_eq!(report["deleted"], 1, "{report}");
    assert!(is_deleted(&hub, "cold"));
    hub.shutdown_all().await;
}

#[test]
fn the_setting_deletes_nothing_by_default() {
    assert_eq!(delete_after(&json!({})), None);
    assert_eq!(delete_after(&json!({"agents": {"chats": {"deleteHistoryAfterDays": 0}}})), None);
    assert_eq!(delete_after(&json!({"agents.chats.deleteHistoryAfterDays": "never"})), None);
    assert_eq!(delete_after(&json!({"agents": {"chats": {"autoDelete": false}}})), None);
    // The design's switch: on is 180 days unless its days say otherwise.
    assert_eq!(
        delete_after(&json!({"agents": {"chats": {"autoDelete": true}}})),
        Some(std::time::Duration::from_secs(180 * 86_400))
    );
    assert_eq!(
        delete_after(
            &json!({"agents.chats.autoDelete": true, "agents.chats.autoDeleteAfterDays": 90})
        ),
        Some(std::time::Duration::from_secs(90 * 86_400))
    );
    assert_eq!(
        delete_after(&json!({"agents": {"chats": {"deleteHistoryAfterDays": 30}}})),
        Some(std::time::Duration::from_secs(30 * 86_400))
    );
    assert_eq!(
        delete_after(&json!({"agents.chats.deleteHistoryAfterDays": "7d"})),
        Some(std::time::Duration::from_secs(7 * 86_400))
    );
}

#[tokio::test]
async fn a_dry_run_previews_the_old_chats_and_deletes_nothing() {
    let root =
        Root(std::env::temp_dir().join(format!("acpmux-history-del-{}", uuid::Uuid::now_v7())));
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Local;
    let now = now_ms();
    {
        let store = crate::store::open(&cfg.store, &root.0).unwrap();
        chat(&*store, "old", "closed", now - 40 * DAY, json!({}));
        chat(&*store, "pinned", "closed", now - 40 * DAY, json!({"pinned": {"value": "1"}}));
        chat(&*store, "inside", "closed", now - 10 * DAY, json!({}));
        store.flush().unwrap();
    }
    let hub = open(&root.0);
    let req =
        HistoryDeleteRequest { dry_run: true, older_than_days: Some(30), ..Default::default() };
    let report = hub.history_delete_now(req).await.unwrap();
    assert_eq!(report["wouldDelete"], 1, "{report}");
    assert_eq!(report["chats"][0]["sessionId"], "old");
    assert!(report["chats"][0]["idleDays"].as_u64().unwrap() >= 39);
    assert!(report["bytes"].as_u64().unwrap() > 0, "the preview says what it frees");
    assert_eq!(report["skipped"]["kept"], 1);
    assert_eq!(report["skipped"]["recent"], 1);
    for kept in ["old", "pinned", "inside"] {
        assert!(hub.resolve(kept).is_ok(), "a preview deletes nothing: {kept}");
    }
    // No age at all is refused, not taken as "everything".
    let none = HistoryDeleteRequest { older_than_days: Some(0), ..Default::default() };
    assert!(hub.history_delete_now(none).await.is_err());
    hub.shutdown_all().await;
}

#[tokio::test]
async fn an_export_copies_the_chat_before_it_goes_and_a_failed_one_keeps_it() {
    let root =
        Root(std::env::temp_dir().join(format!("acpmux-history-del-{}", uuid::Uuid::now_v7())));
    let export = root.0.join("export");
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Local;
    let now = now_ms();
    {
        let store = crate::store::open(&cfg.store, &root.0.join("home")).unwrap();
        chat(&*store, "old", "closed", now - 40 * DAY, json!({}));
        chat(&*store, "blocked", "closed", now - 41 * DAY, json!({}));
        store.flush().unwrap();
    }
    // Something is already where "blocked" would be exported: that chat must stay.
    std::fs::create_dir_all(export.join("blocked")).unwrap();
    let hub = open(&root.0.join("home"));
    let req = HistoryDeleteRequest {
        dry_run: false,
        older_than_days: Some(30),
        export: Some(export.clone()),
        ..Default::default()
    };
    let report = hub.history_delete_now(req).await.unwrap();
    assert_eq!(report["deleted"], 1, "{report}");
    assert_eq!(report["skipped"]["export"], 1);
    assert!(is_deleted(&hub, "old"));
    assert!(!is_deleted(&hub, "blocked"), "a chat whose export failed is kept");
    let copy = export.join("old");
    assert!(copy.join("session.json").is_file(), "the export holds its metadata");
    let saved: Value =
        serde_json::from_slice(&std::fs::read(copy.join("session.json")).unwrap()).unwrap();
    assert_eq!(saved["id"], "old");
    let events: u64 = std::fs::read_dir(copy.join("events"))
        .unwrap()
        .map(|e| e.unwrap().metadata().unwrap().len())
        .sum();
    assert!(events > 0, "and its log");
    assert!(
        !std::fs::read_dir(&export).unwrap().any(|e| e
            .unwrap()
            .file_name()
            .to_string_lossy()
            .contains(".export-")),
        "no temporary copy left"
    );
    hub.shutdown_all().await;
}

#[tokio::test]
async fn a_chat_pinned_in_the_list_or_starred_is_never_deleted() {
    // Leo-Ask-Trace: ask-a4c6c940cc. The design's rule: "Pinned and starred chats are never
    // deleted". The sidebar pin (`_acpmux/pin`, `meta.pinned`) is not a tag, so a check on the
    // `pinned` tag alone deleted a chat its person pinned.
    let root =
        Root(std::env::temp_dir().join(format!("acpmux-history-kept-{}", uuid::Uuid::now_v7())));
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Local;
    let now = now_ms();
    {
        let store = crate::store::open(&cfg.store, &root.0).unwrap();
        chat(&*store, "plain", "closed", now - 40 * DAY, json!({}));
        chat(&*store, "sidebar", "closed", now - 40 * DAY, json!({}));
        chat(&*store, "starred", "closed", now - 40 * DAY, json!({"starred": {"value": "1"}}));
        chat(
            &*store,
            "star-expired",
            "closed",
            now - 40 * DAY,
            json!({"starred": {"value": "1", "expires_at": now - DAY}}),
        );
        store.flush().unwrap();
    }
    let hub = open(&root.0);
    let sidebar = hub.resolve("sidebar").unwrap();
    hub.set_pinned(&sidebar, true).unwrap();
    assert!(super::history_delete::kept_by_person(&sidebar.meta()));
    let after = std::time::Duration::from_millis(30 * DAY);
    assert_eq!(hub.history_delete_pass_after(after).await, 2);
    assert!(is_deleted(&hub, "plain"));
    assert!(is_deleted(&hub, "star-expired"), "a star that expired keeps nothing");
    for kept in ["sidebar", "starred"] {
        assert!(!is_deleted(&hub, kept), "{kept} is kept");
    }
    // Unpinned, it goes like any other.
    hub.set_pinned(&sidebar, false).unwrap();
    assert_eq!(hub.history_delete_pass_after(after).await, 1);
    assert!(is_deleted(&hub, "sidebar"));
    // Pinned again inside its undo window, it is never purged.
    hub.set_pinned(&sidebar, true).unwrap();
    deleted_days_ago(&hub, "sidebar", UNDO_DAYS + 1);
    let req = HistoryDeleteRequest { older_than_days: Some(30), ..Default::default() };
    let report = hub.history_delete_now(req).await.unwrap();
    assert_eq!(report["purged"], 0, "{report}");
    assert!(hub.resolve("sidebar").is_ok());
    hub.shutdown_all().await;
}

#[tokio::test]
async fn a_deleted_chat_is_hidden_listed_and_restored_as_it_was() {
    // Leo-Ask-Trace: ask-a4c6c940cc. The design's undo: "Tombstone: hidden from the list; local
    // data and cloud copy kept for an undo window", restored through Recently deleted.
    let root =
        Root(std::env::temp_dir().join(format!("acpmux-history-undo-{}", uuid::Uuid::now_v7())));
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Local;
    let now = now_ms();
    {
        let store = crate::store::open(&cfg.store, &root.0).unwrap();
        chat(&*store, "old", "closed", now - 40 * DAY, json!({}));
        // Archived by its person before: a restore keeps that archive.
        chat(&*store, "shelved", "closed", now - 40 * DAY, json!({"archived": {"value": "5"}}));
        // Restored by an unarchive from a list instead.
        chat(&*store, "unarchived", "closed", now - 40 * DAY, json!({}));
        store.flush().unwrap();
    }
    let hub = open(&root.0);
    let before = hub.resolve("old").unwrap().meta().last_seq;
    let after = std::time::Duration::from_millis(30 * DAY);
    assert_eq!(hub.history_delete_pass_after(after).await, 3);
    let deleted = hub.history_deleted();
    assert_eq!(deleted["undoDays"], UNDO_DAYS);
    let rows = deleted["chats"].as_array().unwrap();
    assert_eq!(rows.len(), 3, "{deleted}");
    for row in rows {
        assert_eq!(row["deletedBy"], "auto");
        let at = row["deletedAt"].as_u64().unwrap();
        assert_eq!(row["purgesAt"].as_u64().unwrap(), at + UNDO_DAYS * DAY);
    }
    // Restored: no delete, no archive the delete made, its log as it was.
    let old = hub.resolve("old").unwrap();
    assert!(hub.history_restore(&old).unwrap());
    let meta = old.meta();
    assert!(!meta.tags.contains_key(DELETED_TAG) && !meta.tags.contains_key(DELETED_BY_TAG));
    assert!(!meta.tags.contains_key("archived"), "back in the lists");
    assert!(meta.last_seq >= before, "nothing of its log went");
    assert!(!hub.history_restore(&old).unwrap(), "a second restore changes nothing");
    // The person's own archive stays.
    let shelved = hub.resolve("shelved").unwrap();
    assert!(hub.history_restore(&shelved).unwrap());
    assert_eq!(shelved.meta().tags.get("archived").map(|t| t.value.as_str()), Some("5"));
    // An unarchive from any list is a restore: never purged later.
    let unarchived = hub.resolve("unarchived").unwrap();
    assert!(hub.set_archived(&unarchived, false, false).unwrap());
    assert!(!unarchived.meta().tags.contains_key(DELETED_TAG));
    assert!(hub.history_deleted()["chats"].as_array().unwrap().is_empty());
    // Restored chats start a new period: the next pass inside the bound deletes none.
    // (Their tag writes moved `updatedAt` to now.)
    assert_eq!(hub.history_delete_pass_after(after).await, 0);
    hub.shutdown_all().await;
}
