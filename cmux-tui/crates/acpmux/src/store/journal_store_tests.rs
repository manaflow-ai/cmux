//! The event log through the journal (`store.journal`, R-DURABILITY S2; DESIGN.md 3.3b): a line
//! the store says is durable survives an OS crash, a kill keeps every line once, and a chat that
//! was deleted stays deleted.
//!
//! The journal runs on a simulated file system (`cmux_journal::SimStorage`), so a crash keeps
//! exactly what a real one would. The chat logs (`sessions/<id>/events/*.ndjson`) are real files
//! in a temporary folder; an OS crash of them is modelled as the worst case: every log file goes
//! back to its length at the last `flush` (the kernel lost every write since).

use super::*;
use cmux_journal::{Crash, SimStorage};
use serde_json::json;
use std::sync::Arc;
use std::time::Duration;

const CHAT: &str = "chat-a";
const WAIT: Duration = Duration::from_secs(10);

fn config() -> StoreConfig {
    StoreConfig { journal: true, ..StoreConfig::default() }
}

fn journal_config() -> cmux_journal::Config {
    cmux_journal::Config {
        retry_min: Duration::from_millis(1),
        retry_max: Duration::from_millis(5),
        ..cmux_journal::Config::default()
    }
}

fn open(home: &Path, journal: &SimStorage) -> Box<dyn Store> {
    open_with_journal(&config(), home, Arc::new(journal.clone()), journal_config())
        .unwrap_or_else(|e| panic!("open the store: {e:#}"))
}

fn record(seq: u64, kind: &str) -> EventRecord {
    EventRecord {
        seq,
        at: 1_000 + seq,
        dir: "mux".into(),
        kind: kind.into(),
        msg: json!({ "n": seq }),
        host_seq: None,
    }
}

fn seqs(store: &dyn Store, id: &str) -> Vec<u64> {
    let events = store.events(id, 0, 10_000).unwrap_or_else(|e| panic!("read {id}: {e:#}"));
    events.iter().map(|record| record.seq).collect()
}

/// Every event-log segment under `home/sessions`, with its length.
fn log_files(home: &Path) -> BTreeMap<PathBuf, u64> {
    let mut out = BTreeMap::new();
    let Ok(chats) = std::fs::read_dir(home.join("sessions")) else { return out };
    for chat in chats.flatten() {
        let Ok(segments) = std::fs::read_dir(chat.path().join("events")) else { continue };
        for segment in segments.flatten() {
            let path = segment.path();
            if path.extension().is_some_and(|ext| ext == "ndjson") {
                let len = segment.metadata().map(|meta| meta.len()).unwrap_or(0);
                out.insert(path, len);
            }
        }
    }
    out
}

/// An OS crash of the log files: each goes back to its length in `synced`, or to empty.
fn lose_unsynced_log_writes(home: &Path, synced: &BTreeMap<PathBuf, u64>) {
    for path in log_files(home).into_keys() {
        let len = synced.get(&path).copied().unwrap_or(0);
        let file = std::fs::OpenOptions::new()
            .write(true)
            .open(&path)
            .unwrap_or_else(|e| panic!("open {}: {e}", path.display()));
        file.set_len(len).unwrap_or_else(|e| panic!("cut {}: {e}", path.display()));
    }
}

#[test]
fn a_line_the_store_says_is_durable_survives_an_os_crash() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(7);
    let store = open(home.path(), &journal);
    store.append(CHAT, &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    let synced = log_files(home.path());
    for seq in 2..=20 {
        store.append(CHAT, &record(seq, "queued")).unwrap_or_else(|e| panic!("{e:#}"));
    }
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    // An OS crash now: the journal keeps what it synced, the logs lose every write since the
    // flush.
    let crashed = journal.restart(Crash::Os);
    drop(store);
    lose_unsynced_log_writes(home.path(), &synced);
    let store = open(home.path(), &crashed);
    assert_eq!(seqs(store.as_ref(), CHAT), (1..=20).collect::<Vec<_>>());
}

#[test]
fn a_kill_keeps_every_line_once() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(8);
    let store = open(home.path(), &journal);
    store.append(CHAT, &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    for seq in 2..=30 {
        store.append(CHAT, &record(seq, "queued")).unwrap_or_else(|e| panic!("{e:#}"));
    }
    store.append("chat-b", &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    // A kill -9: the logs keep every write, the journal every write it got.
    let killed = journal.restart(Crash::Process);
    drop(store);
    let store = open(home.path(), &killed);
    assert_eq!(seqs(store.as_ref(), CHAT), (1..=30).collect::<Vec<_>>(), "each line once");
    assert_eq!(seqs(store.as_ref(), "chat-b"), vec![1]);
    // And again: a second restart writes nothing twice.
    let again = killed.restart(Crash::Process);
    drop(store);
    let store = open(home.path(), &again);
    assert_eq!(seqs(store.as_ref(), CHAT), (1..=30).collect::<Vec<_>>(), "each line once");
}

#[test]
fn a_deleted_chat_stays_deleted_after_a_crash() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(9);
    let store = open(home.path(), &journal);
    for seq in 1..=5 {
        store.append(CHAT, &record(seq, "queued")).unwrap_or_else(|e| panic!("{e:#}"));
    }
    store.append("chat-b", &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    store.delete(CHAT).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    let crashed = journal.restart(Crash::Os);
    drop(store);
    let store = open(home.path(), &crashed);
    assert_eq!(seqs(store.as_ref(), CHAT), Vec::<u64>::new(), "the deleted chat came back");
    assert!(!home.path().join("sessions").join(CHAT).exists());
    assert_eq!(seqs(store.as_ref(), "chat-b"), vec![1]);
}

#[test]
fn a_line_the_log_refused_is_never_written_later() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(10);
    let store = open(home.path(), &journal);
    store.append(CHAT, &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    // A file where chat-b's folder would be: its log cannot be written.
    let sessions = home.path().join("sessions");
    std::fs::create_dir_all(&sessions).unwrap_or_else(|e| panic!("{e}"));
    std::fs::write(sessions.join("chat-b"), b"not a folder").unwrap_or_else(|e| panic!("{e}"));
    assert!(store.append("chat-b", &record(1, "created")).is_err(), "the append was refused");
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    let crashed = journal.restart(Crash::Os);
    drop(store);
    std::fs::remove_file(sessions.join("chat-b")).unwrap_or_else(|e| panic!("{e}"));
    let store = open(home.path(), &crashed);
    assert_eq!(seqs(store.as_ref(), "chat-b"), Vec::<u64>::new(), "a refused line came back");
    assert_eq!(seqs(store.as_ref(), CHAT), vec![1]);
}

#[test]
fn a_line_after_the_seal_is_refused_and_never_written_later() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(11);
    let store = open(home.path(), &journal);
    store.append(CHAT, &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    store.seal();
    assert!(store.append(CHAT, &record(2, "queued")).is_err(), "an append after the seal");
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    let killed = journal.restart(Crash::Process);
    drop(store);
    let store = open(home.path(), &killed);
    assert_eq!(seqs(store.as_ref(), CHAT), vec![1]);
}

/// A chat deleted and then made again under the same id (a transfer back) before a crash: the
/// replay writes its new lines and keeps its own files (its `session.json`).
#[test]
fn a_chat_made_again_after_its_delete_keeps_its_files_through_a_replay() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(12);
    let store = open(home.path(), &journal);
    for seq in 1..=3 {
        store.append(CHAT, &record(seq, "queued")).unwrap_or_else(|e| panic!("{e:#}"));
    }
    store.delete(CHAT).unwrap_or_else(|e| panic!("{e:#}"));
    let meta: SessionMeta = serde_json::from_value(json!({
        "schema": META_SCHEMA,
        "id": CHAT,
        "name": "again",
        "harness": "claude",
        "family": "claude",
        "cwd": "/tmp",
        "status": "idle",
        "createdAt": 1,
        "updatedAt": 1,
    }))
    .unwrap_or_else(|e| panic!("meta: {e}"));
    store.save(&meta).unwrap_or_else(|e| panic!("{e:#}"));
    for seq in 1..=2 {
        store.append(CHAT, &record(seq, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    }
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    let killed = journal.restart(Crash::Process);
    drop(store);
    let store = open(home.path(), &killed);
    assert_eq!(seqs(store.as_ref(), CHAT), vec![1, 2]);
    let loaded = store.load(CHAT).unwrap_or_else(|e| panic!("{e:#}"));
    assert_eq!(loaded.map(|meta| meta.name), Some("again".to_owned()), "its session.json is gone");
}
