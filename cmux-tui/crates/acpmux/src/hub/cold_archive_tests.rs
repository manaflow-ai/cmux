//! Cold archive of old chats through the hub (`hub/cold_archive.rs`).

use super::*;
use crate::config::{Config, StoreMode};

struct Root(PathBuf);

impl Drop for Root {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn record(seq: u64, dir: &str, kind: &str, msg: Value) -> EventRecord {
    EventRecord { seq, at: 1_000 + seq, dir: dir.into(), kind: kind.into(), msg, host_seq: None }
}

/// A chat with `turns` prompts and answers, saved `updated_at` and closed.
fn chat(
    store: &dyn crate::store::Store,
    id: &str,
    updated_at: u64,
    turns: u64,
) -> Vec<EventRecord> {
    let meta = json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": format!("chat {id}"),
        "harness": "claude", "cwd": "/tmp", "status": "closed", "createdAt": 1,
        "updatedAt": updated_at, "lastSeq": turns * 2, "eventCount": turns * 2,
    });
    store.save(&serde_json::from_value(meta).unwrap()).unwrap();
    let mut records = Vec::new();
    for turn in 0..turns {
        records.push(record(
            turn * 2 + 1,
            "mux",
            "user_message",
            json!({"text": format!("question {turn} {}", "q".repeat(400))}),
        ));
        records.push(record(
            turn * 2 + 2,
            "in",
            "agent_message_chunk",
            json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "a", "update": {"sessionUpdate": "agent_message_chunk", "messageId": format!("m{turn}"), "content": {"type": "text", "text": format!("answer {turn}")}}}}),
        ));
    }
    for r in &records {
        store.append(id, r).unwrap();
    }
    store.close_log(id);
    records
}

fn open(root: &Path) -> (Config, Arc<Hub>) {
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Local;
    let hub = Hub::new(cfg.clone(), crate::store::open(&cfg.store, root).unwrap());
    (cfg, hub)
}

#[tokio::test]
async fn archive_lists_from_its_preview_and_opens_back() {
    let root = Root(std::env::temp_dir().join(format!("acpmux-cold-hub-{}", uuid::Uuid::now_v7())));
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Local;
    let records = {
        let store = crate::store::open(&cfg.store, &root.0).unwrap();
        let records = chat(&*store, "old", 2, 5);
        store.flush().unwrap();
        records
    };
    let (_, hub) = open(&root.0);
    let session = hub.resolve("old").unwrap();
    let summary = hub.cold_archive_request(session.clone(), true).await.unwrap();
    let cold = &summary["coldArchive"];
    assert_eq!(cold["messages"], json!(10), "{summary}");
    let last = cold["last"].as_array().unwrap();
    assert_eq!(last.len(), PREVIEW_MESSAGES);
    assert_eq!(last[2], json!({"role": "assistant", "text": "answer 4", "at": 1_010}));
    assert!(last[1]["text"].as_str().unwrap().ends_with('…'), "{}", last[1]);
    assert!(hub.store.is_cold("old"));
    // Archiving it again changes nothing.
    assert!(hub.cold_archive_request(session.clone(), true).await.is_err());
    hub.store.flush().unwrap();
    hub.shutdown_all().await;
    drop(hub);

    // A new daemon lists it and reads every log at its start, without opening the archive: one
    // that would not decode stays as it is.
    let archive = root.0.join("sessions").join("old").join(crate::store::COLD_FILE);
    let kept = std::fs::read(&archive).unwrap();
    std::fs::write(&archive, b"not zstd").unwrap();
    let (_, hub) = open(&root.0);
    hub.load_logs();
    let session = hub.resolve("old").unwrap();
    assert_eq!(hub.session_list_summary(&session)["coldArchive"]["messages"], json!(10));
    assert_eq!(std::fs::read(&archive).unwrap(), b"not zstd");
    std::fs::write(&archive, &kept).unwrap();

    // Opening it brings the log back, byte for byte, and the preview goes.
    hub.session_log_on_screen(&session).await;
    assert!(!hub.store.is_cold("old"));
    assert!(session.meta().cold.is_none());
    assert!(hub.session_summary(&session).get("coldArchive").is_none());
    assert_eq!(hub.events("old", 0, 100).unwrap(), records);
    hub.shutdown_all().await;
}

#[tokio::test]
async fn a_replay_rehydrates_and_unarchive_is_explicit_too() {
    let root = Root(std::env::temp_dir().join(format!("acpmux-cold-hub-{}", uuid::Uuid::now_v7())));
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Local;
    let records = {
        let store = crate::store::open(&cfg.store, &root.0).unwrap();
        let mut records = chat(&*store, "a", 2, 3);
        records.extend(chat(&*store, "b", 2, 2));
        store.flush().unwrap();
        records
    };
    let (_, hub) = open(&root.0);
    for id in ["a", "b"] {
        hub.cold_archive_request(hub.resolve(id).unwrap(), true).await.unwrap();
    }
    let mut replayed = Vec::new();
    hub.scan_events("a", 0, &mut |r| {
        replayed.push(r);
        true
    })
    .unwrap();
    assert_eq!(replayed, records[..6]);
    assert!(hub.resolve("a").unwrap().meta().cold.is_none());

    let b = hub.resolve("b").unwrap();
    hub.cold_archive_request(b.clone(), false).await.unwrap();
    assert!(!hub.store.is_cold("b"));
    assert!(b.meta().cold.is_none());
    assert_eq!(hub.events("b", 0, 100).unwrap(), records[6..]);
    hub.shutdown_all().await;
}

#[tokio::test]
async fn the_automatic_pass_takes_only_chats_idle_past_the_setting() {
    let root = Root(std::env::temp_dir().join(format!("acpmux-cold-hub-{}", uuid::Uuid::now_v7())));
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Local;
    let day = 86_400_000;
    {
        let store = crate::store::open(&cfg.store, &root.0).unwrap();
        chat(&*store, "old", now_ms() - 40 * day, 2);
        chat(&*store, "recent", now_ms() - 10 * day, 2);
        chat(&*store, "today", now_ms(), 2);
        store.flush().unwrap();
    }
    let (_, hub) = open(&root.0);
    let after = std::time::Duration::from_millis(30 * day);
    assert_eq!(hub.cold_pass_after(after), 1);
    assert!(hub.store.is_cold("old"));
    assert!(!hub.store.is_cold("recent"));
    assert!(!hub.store.is_cold("today"));
    // A chat with an agent attached or a turn open is left too: here, one a client attached.
    let recent = hub.resolve("recent").unwrap();
    recent.attached.fetch_add(1, Ordering::SeqCst);
    assert_eq!(hub.cold_pass_after(std::time::Duration::from_millis(day)), 0);
    recent.attached.fetch_sub(1, Ordering::SeqCst);
    assert_eq!(hub.cold_pass_after(std::time::Duration::from_millis(day)), 1);
    assert!(hub.store.is_cold("recent"));
    hub.shutdown_all().await;
}

#[test]
fn the_setting_is_off_by_default() {
    assert_eq!(auto_after(&json!({})), None);
    assert_eq!(auto_after(&json!({"agents": {"chats": {"coldArchiveAfterDays": 3}}})), None);
    assert_eq!(
        auto_after(&json!({"agents": {"chats": {"coldArchive": true}}})),
        Some(std::time::Duration::from_secs(30 * 86_400))
    );
    assert_eq!(
        auto_after(
            &json!({"agents.chats.coldArchive": true, "agents.chats.coldArchiveAfterDays": 7})
        ),
        Some(std::time::Duration::from_secs(7 * 86_400))
    );
}

#[tokio::test]
async fn a_rehydrate_on_any_path_drops_the_preview() {
    let root = Root(std::env::temp_dir().join(format!("acpmux-cold-hub-{}", uuid::Uuid::now_v7())));
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Local;
    {
        let store = crate::store::open(&cfg.store, &root.0).unwrap();
        chat(&*store, "old", 2, 3);
        store.flush().unwrap();
    }
    let (_, hub) = open(&root.0);
    let session = hub.resolve("old").unwrap();
    hub.cold_archive_request(session.clone(), true).await.unwrap();
    assert!(session.meta().cold.is_some());
    // A read straight through the store, not the hub's open: the turn summary's.
    assert_eq!(hub.history(&session, 10).len(), 3);
    assert!(!hub.store.is_cold("old"));
    // The hook queued it; the worker (or this call) drops the preview.
    hub.settle_rehydrated();
    assert!(session.meta().cold.is_none());
    assert!(hub.session_summary(&session).get("coldArchive").is_none());
    hub.shutdown_all().await;
    drop(hub);
    let (_, hub) = open(&root.0);
    assert!(hub.resolve("old").unwrap().meta().cold.is_none(), "session.json has no preview");
    hub.shutdown_all().await;
}

#[tokio::test]
async fn a_preview_left_by_a_crash_goes_at_the_next_start() {
    let root = Root(std::env::temp_dir().join(format!("acpmux-cold-hub-{}", uuid::Uuid::now_v7())));
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Local;
    let records = {
        let store = crate::store::open(&cfg.store, &root.0).unwrap();
        let records = chat(&*store, "old", 2, 3);
        store.flush().unwrap();
        records
    };
    let (_, hub) = open(&root.0);
    hub.cold_archive_request(hub.resolve("old").unwrap(), true).await.unwrap();
    hub.shutdown_all().await;
    drop(hub);
    // The log comes back with no hub to drop the preview: a crash right after a rehydrate.
    {
        let store = crate::store::open(&cfg.store, &root.0).unwrap();
        assert!(store.rehydrate("old").unwrap());
        assert!(store.load("old").unwrap().unwrap().cold.is_some());
        store.flush().unwrap();
    }
    let (_, hub) = open(&root.0);
    hub.load_logs();
    let session = hub.resolve("old").unwrap();
    assert!(session.meta().cold.is_none());
    assert!(hub.session_log_loaded(&session));
    assert_eq!(hub.events("old", 0, 100).unwrap(), records);
    hub.shutdown_all().await;
}
