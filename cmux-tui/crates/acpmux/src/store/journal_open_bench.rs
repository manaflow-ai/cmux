//! Scratch measurement, never lands: how long the event journal store's open takes after a kill,
//! with N chats that each have lines and a metadata image past the checkpoint (review 3 of #34901,
//! follow-up 3: the forced rewrite syncs each replayed chat's log at the open, before the socket
//! is bound; the start budget is 8 s). Real files for the journal and the logs.

use super::journal_store::FencedStorage;
use super::*;
use serde_json::json;
use std::sync::Arc;
use std::time::{Duration, Instant};

fn meta(id: &str, last_seq: u64) -> SessionMeta {
    serde_json::from_value(json!({
        "schema": META_SCHEMA, "id": id, "name": id, "harness": "claude", "family": "claude",
        "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1, "lastSeq": last_seq,
    }))
    .unwrap_or_else(|e| panic!("meta: {e}"))
}

fn record(seq: u64) -> EventRecord {
    EventRecord {
        seq,
        at: 1_000 + seq,
        dir: "mux".into(),
        kind: "queued".into(),
        msg: json!({ "n": seq, "text": "x".repeat(400) }),
        host_seq: None,
    }
}

#[test]
fn open_time_after_a_kill_with_replayed_chats() {
    if !std::env::var("CMUX_CI_STEP_KEY").is_ok_and(|key| key.contains("openbench")) {
        eprintln!("ACPMUX-PERF openbench SKIP (runs in a fleet step whose key contains openbench)");
        return;
    }
    let config = StoreConfig { journal: true, ..StoreConfig::default() };
    for chats in [10usize, 100, 300] {
        let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
        let open = || {
            open_with_journal(
                &config,
                home.path(),
                Arc::new(FencedStorage::daemon()),
                cmux_journal::Config::default(),
            )
            .unwrap_or_else(|e| panic!("open: {e:#}"))
        };
        let store = open();
        for chat in 0..chats {
            let id = format!("chat-{chat}");
            store.save(&meta(&id, 0)).unwrap_or_else(|e| panic!("{e:#}"));
            for seq in 1..=5 {
                store.append(&id, &record(seq)).unwrap_or_else(|e| panic!("{e:#}"));
            }
        }
        store.flush().unwrap_or_else(|e| panic!("{e:#}"));
        for chat in 0..chats {
            let id = format!("chat-{chat}");
            for seq in 6..=10 {
                store.append(&id, &record(seq)).unwrap_or_else(|e| panic!("{e:#}"));
            }
            store.save(&meta(&id, 10)).unwrap_or_else(|e| panic!("{e:#}"));
        }
        assert!(store.wait_durable(Duration::from_secs(60)).unwrap_or_else(|e| panic!("{e:#}")));
        // A kill: no checkpoint, so the next open replays 5 lines and an image per chat.
        drop(store);
        let started = Instant::now();
        let store = open();
        let took = started.elapsed();
        eprintln!(
            "ACPMUX-PERF openbench chats={chats} open_ms={:.1} per_chat_ms={:.2}",
            took.as_secs_f64() * 1000.0,
            took.as_secs_f64() * 1000.0 / chats as f64
        );
        drop(store);
    }
}
