//! The shutdown's flush and seal (`Hub::flush`, `Hub::seal`) cost what this run changed, not what
//! the store holds. A daemon that stops holds its lock until both return, and the next daemon
//! (each NIGHTLY update, each restart the app asks for) waits for that lock with the app showing no
//! agent service. Before, the flush journaled a whole metadata image for every chat this run had
//! not saved yet, and the checkpoint then rewrote every one of those `session.json` files, two
//! syncs each: on a machine with 525 chats and a busy disk the old daemon took 30 to 117 s to let
//! go of its lock (cosmic-gray's daemon log, 2026-11-12).
//!
//! The bench: a store with [`CHATS`] chats written by one run, a hub that loads them as the next
//! run's startup does, one chat changed, then the shutdown's flush and seal on the real disk. It
//! prints one `shutdown-flush-bench` line (the time and how many `session.json` files were written
//! again) and fails when an unchanged chat's file is written again, or the changed one is lost.
//!
//! `cargo test -p acpmux --lib shutdown_flush_bench_tests -- --nocapture`

use super::*;
use std::time::{Duration, Instant};

const CHATS: usize = 500;

fn meta(index: usize) -> SessionMeta {
    // Sized like a real chat's: a large field every save carries (`contextBreakdown`) and its
    // parts (`availableCommands`, which `session.parts.json` holds).
    let id = format!("00000000-0000-7000-8000-{index:012}");
    let filler: Vec<String> =
        (0..40).map(|n| format!("context line {n} of chat {index}")).collect();
    serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": format!("chat {index}"),
        "harness": "fake", "cwd": "/tmp",
        "status": "idle",
        "createdAt": 1, "updatedAt": 2 + index,
        "contextBreakdown": {"lines": filler},
        "availableCommands": [{"name": "review", "description": "Review the diff"}],
    }))
    .unwrap_or_else(|e| panic!("meta {index}: {e}"))
}

fn open(dir: &std::path::Path) -> Box<dyn crate::store::Store> {
    crate::store::open(&crate::config::StoreConfig::default(), dir)
        .unwrap_or_else(|e| panic!("open the store: {e:#}"))
}

/// Each chat's `session.json` identity: a write by rename (every writer's way) gives a new one.
fn files(dir: &std::path::Path) -> HashMap<String, (u64, std::time::SystemTime)> {
    let mut out = HashMap::new();
    for entry in std::fs::read_dir(dir.join("sessions")).into_iter().flatten().flatten() {
        let Ok(stat) = std::fs::symlink_metadata(entry.path().join("session.json")) else {
            continue;
        };
        #[cfg(unix)]
        let ino = std::os::unix::fs::MetadataExt::ino(&stat);
        #[cfg(not(unix))]
        let ino = 0;
        let modified = stat.modified().unwrap_or(std::time::UNIX_EPOCH);
        out.insert(entry.file_name().to_string_lossy().into_owned(), (ino, modified));
    }
    out
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_shutdown_flush_writes_only_the_chats_this_run_changed() {
    use crate::config::{Config, StoreMode};
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let dir = home.path();
    // The previous run: every chat saved, and its seal's last checkpoint wrote `session.json`.
    {
        let store = open(dir);
        for index in 0..CHATS {
            store.save(&meta(index)).unwrap_or_else(|e| panic!("save {index}: {e:#}"));
        }
        store.seal();
    }
    let before = files(dir);
    assert_eq!(before.len(), CHATS, "the previous run's checkpoint wrote every chat");

    // This run: the startup loads every chat, and one of them changes.
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let cfg = json!({"harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake"});
    let mut cfg: Config = serde_json::from_value(cfg).unwrap_or_else(|e| panic!("config: {e}"));
    cfg.store.mode = StoreMode::Local;
    let hub = Hub::new(cfg, open(dir));
    hub.load_from_store(false);
    assert_eq!(hub.sessions().len(), CHATS);
    let changed = meta(7).id;
    let session = hub
        .sessions
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .get(&changed)
        .cloned()
        .unwrap_or_else(|| panic!("chat {changed} loaded"));
    session.meta.lock().unwrap_or_else(|e| e.into_inner()).name = "renamed".into();
    hub.save_meta(&session);

    let started = Instant::now();
    hub.flush();
    let flushed = started.elapsed();
    hub.seal();
    let sealed = started.elapsed();
    let after = files(dir);
    let rewritten: Vec<&String> =
        after.iter().filter(|(id, file)| before.get(*id) != Some(file)).map(|(id, _)| id).collect();
    println!(
        "shutdown-flush-bench chats={CHATS} flush_ms={} flush_and_seal_ms={} rewritten={}",
        flushed.as_millis(),
        sealed.as_millis(),
        rewritten.len()
    );
    hub.close_owned_tasks().await;

    // The next run reads the change, and every other chat as it was.
    let next = open(dir);
    let read = next.load(&changed).unwrap_or_else(|e| panic!("load: {e:#}"));
    assert_eq!(read.map(|m| m.name), Some("renamed".to_owned()), "the changed chat was lost");
    let other = next.load(&meta(8).id).unwrap_or_else(|e| panic!("load: {e:#}"));
    assert_eq!(other.map(|m| m.name), Some("chat 8".to_owned()));
    next.seal();
    assert!(
        rewritten.iter().all(|id| **id == changed),
        "the shutdown wrote {} unchanged chats' session.json again",
        rewritten.iter().filter(|id| ***id != changed).count()
    );
    assert!(sealed < Duration::from_secs(60), "flush and seal took {sealed:?}");
}
