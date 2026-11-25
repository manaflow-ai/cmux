//! acpmux start with many long chats (2026-10-20, Lawrence: "Why is starting
//! a background service so slow?"). On the Chief's Mac, 355 open sessions hold
//! 3.9 GB of event logs, and the daemon read and parsed every line twice before
//! it said ready (catch-up of each log past its saved `lastSeq`, then the queue
//! restore): 26.8 s from "listening" to "ready". A restart answers within 100 ms:
//! it reads only the session list first, and the logs after its ready line.
//!
//! `ACPMUX_STARTUP_BENCH_SESSIONS` / `ACPMUX_STARTUP_BENCH_EVENTS` size the
//! store (defaults 24 sessions of 4,000 output records, ~70 MB) and
//! `ACPMUX_STARTUP_BUDGET_MS` the budget; the test prints `acpmux-start: {...}`.

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process starts no agent. The bench sizes and the budget are
// test-runner knobs that hold no credential.
const HERMETIC: daemon_env::Process = daemon_env::Process::deny().keep(&[
    "ACPMUX_STARTUP_BENCH_SESSIONS",
    "ACPMUX_STARTUP_BENCH_EVENTS",
    "ACPMUX_STARTUP_BUDGET_MS",
]);

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::store::{EventRecord, META_SCHEMA, SessionMeta, SessionStatus};
use serde_json::json;
use std::path::PathBuf;
use std::time::Instant;

fn env_or(name: &str, default: u64) -> u64 {
    std::env::var(name).ok().and_then(|value| value.parse().ok()).unwrap_or(default)
}

fn meta(id: &str, last_seq: u64) -> SessionMeta {
    serde_json::from_value(json!({
        "schema": META_SCHEMA, "id": id, "name": id, "harness": "claude", "cwd": "/tmp",
        "status": "idle", "createdAt": 1, "updatedAt": 1, "lastSeq": last_seq, "eventCount": last_seq,
    }))
    .unwrap()
}

fn record(seq: u64, kind: &str, msg: serde_json::Value) -> EventRecord {
    EventRecord {
        seq,
        at: 1_791_540_000_000 + seq,
        dir: "in".into(),
        kind: kind.into(),
        msg,
        host_seq: None,
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_restart_over_long_chats_loads_within_budget_and_keeps_queues_and_tails() {
    let sessions = env_or("ACPMUX_STARTUP_BENCH_SESSIONS", 24);
    let events = env_or("ACPMUX_STARTUP_BENCH_EVENTS", 4_000);
    let budget_ms = env_or("ACPMUX_STARTUP_BUDGET_MS", 100) as u128;
    let root = PathBuf::from("/tmp").join(format!("acpmux-startup-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&root).unwrap();
    let mut cfg: Config = serde_json::from_value(json!({})).unwrap();
    cfg.store.mode = StoreMode::Local;
    let chunk = "x".repeat(600);
    {
        let store = acpmux::store::open(&cfg.store, &root).unwrap();
        for index in 0..sessions {
            let id = format!("01a15800-0000-7000-8000-{index:012}");
            for seq in 1..=events {
                let rec = record(
                    seq,
                    "agent_message_chunk",
                    json!({"update": {"content": {"text": chunk}}}),
                );
                store.append(&id, &rec).unwrap();
            }
            // Session 0 has a prompt still queued, and its log runs 3 records past its saved
            // `lastSeq` (a hard stop saved the meta before the last appends).
            let last_seq = if index == 0 {
                store
                    .append(&id, &record(events + 1, "queued", json!({
                        "promptId": "p-1", "turnId": "t-1", "text": "after the restart", "client": "cli"})))
                    .unwrap();
                store
                    .append(&id, &record(events + 2, "agent_message_chunk", json!({"text": "a"})))
                    .unwrap();
                store
                    .append(&id, &record(events + 3, "agent_message_chunk", json!({"text": "b"})))
                    .unwrap();
                events
            } else {
                events
            };
            store.save(&meta(&id, last_seq)).unwrap();
            store.flush().unwrap();
        }
    }

    let store = acpmux::store::open(&cfg.store, &root).unwrap();
    let mailbox = acpmux::mailbox::Mailbox::open(root.join("mailbox")).unwrap();
    // The daemon's start: the hub it answers with, then the chat logs after the ready line.
    let started = Instant::now();
    let hub = Hub::new_deferred(cfg, store, mailbox);
    let ready_ms = started.elapsed().as_millis();
    let logs = Instant::now();
    hub.load_logs_async().await;
    let logs_ms = logs.elapsed().as_millis();
    println!(
        "acpmux-start: {}",
        json!({"sessions": sessions, "events_per_session": events, "ready_ms": ready_ms,
               "logs_after_ready_ms": logs_ms, "budget_ms": budget_ms})
    );

    let first = hub.resolve("01a15800-0000-7000-8000-000000000000").unwrap();
    // The 3 records past the saved lastSeq are caught up, and the restored queue adds its one
    // `queue_restored` notice after them (`hub/queue.rs` `restore_queue`, #28098).
    assert_eq!(
        first.meta().last_seq,
        events + 4,
        "the log's tail past lastSeq was not caught up, or the queue restore's notice is not one record"
    );
    let queue = first.queue();
    assert_eq!(queue.iter().map(|q| q.prompt_id.as_str()).collect::<Vec<_>>(), ["p-1"]);
    assert_eq!(hub.sessions().len() as u64, sessions);
    assert!(matches!(first.meta().status, SessionStatus::Idle));
    let _ = std::fs::remove_dir_all(&root);
    assert!(
        ready_ms <= budget_ms,
        "acpmux took {ready_ms} ms to be ready over {sessions} sessions of {events} records (budget {budget_ms} ms)"
    );
}
