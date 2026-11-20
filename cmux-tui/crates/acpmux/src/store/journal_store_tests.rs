//! The event log through the journal (always on, R-DURABILITY S2; DESIGN.md 3.3b): a line
//! the store says is durable survives an OS crash, a kill keeps every line once, and a chat that
//! was deleted stays deleted.
//!
//! The journal runs on a simulated file system (`cmux_journal::SimStorage`), so a crash keeps
//! exactly what a real one would. The chat logs (`sessions/<id>/events/*.ndjson`) are real files
//! in a temporary folder; an OS crash of them is modelled as the worst case: every log file goes
//! back to its length at the last `flush` (the kernel lost every write since).

use super::journal_store::{
    FAIL_NEXT_FOLDER_REMOVAL, FencedStorage, HOLD_AFTER_START, HOLD_BEFORE_FREEZE, HOLD_IN_SYNC,
    JournalStore, STOP_AFTER_CUT, checkpointer_seams,
};
use super::log_sync::{FAIL_NEXT_LOG_SYNC, NOTE_BEFORE_SYNCS_WAIT};
use super::sync_model;
use super::*;
use cmux_journal::{Crash, SimStorage};
use proc_macro2::{Delimiter, Spacing, TokenStream, TokenTree};
use serde_json::json;
use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use std::time::Duration;

const CHAT: &str = "chat-a";
const WAIT: Duration = Duration::from_secs(10);

fn config() -> StoreConfig {
    StoreConfig::default()
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

// ------------------------------------------------- review of #34901 (FIX at ab0e9535d9da)

/// The store an older build (no event journal: the logs alone, as a downgrade runs) opens on
/// `home`.
fn open_older_build(home: &Path) -> Box<dyn Store> {
    let store = LocalStore::new(home.join("sessions"), config().segment_bytes)
        .unwrap_or_else(|e| panic!("open the store as an older build: {e:#}"));
    Box::new(store)
}

/// A line written straight into the newest log segment of `id`, as a log line whose journal
/// record was lost.
fn write_log_line(home: &Path, id: &str, record: &EventRecord) {
    let events = home.join("sessions").join(id).join("events");
    let last = std::fs::read_dir(&events)
        .unwrap_or_else(|e| panic!("read {}: {e}", events.display()))
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| path.extension().is_some_and(|ext| ext == "ndjson"))
        .max()
        .unwrap_or_else(|| panic!("no segment in {}", events.display()));
    let mut line = serde_json::to_vec(record).unwrap_or_else(|e| panic!("{e}"));
    line.push(b'\n');
    let mut file = std::fs::OpenOptions::new()
        .append(true)
        .open(&last)
        .unwrap_or_else(|e| panic!("open {}: {e}", last.display()));
    file.write_all(&line).unwrap_or_else(|e| panic!("write {}: {e}", last.display()));
}

/// Overwrites, in `id`'s log, the lines of `seqs` with zero bytes (their newlines too): a hole an
/// OS crash leaves where the kernel never wrote a page.
fn zero_log_lines(home: &Path, id: &str, seqs: &[u64]) {
    let events = home.join("sessions").join(id).join("events");
    for entry in std::fs::read_dir(&events).unwrap_or_else(|e| panic!("{e}")).flatten() {
        let path = entry.path();
        let mut bytes = std::fs::read(&path).unwrap_or_else(|e| panic!("{e}"));
        let mut offset = 0;
        let mut changed = false;
        while offset < bytes.len() {
            let end = bytes[offset..]
                .iter()
                .position(|b| *b == b'\n')
                .map_or(bytes.len(), |at| offset + at + 1);
            if record_seq(&bytes[offset..end]).is_some_and(|seq| seqs.contains(&seq)) {
                bytes[offset..end].fill(0);
                changed = true;
            }
            offset = end;
        }
        if changed {
            std::fs::write(path, bytes).unwrap_or_else(|e| panic!("{e}"));
        }
    }
}

/// Finding 1a (from when the journal had a switch): a kill, a run of an older build that does not
/// replay this journal and writes more lines, then this build again.
#[test]
fn lines_an_older_build_wrote_after_a_kill_survive_the_replay() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(20);
    let store = open(home.path(), &journal);
    store.append(CHAT, &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    for seq in 2..=5 {
        store.append(CHAT, &record(seq, "queued")).unwrap_or_else(|e| panic!("{e:#}"));
    }
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    let killed = journal.restart(Crash::Process);
    drop(store);
    let older = open_older_build(home.path());
    for seq in 6..=9 {
        older.append(CHAT, &record(seq, "queued")).unwrap_or_else(|e| panic!("{e:#}"));
    }
    older.flush().unwrap_or_else(|e| panic!("{e:#}"));
    drop(older);
    let store = open(home.path(), &killed);
    assert_eq!(
        seqs(store.as_ref(), CHAT),
        (1..=9).collect::<Vec<_>>(),
        "the lines the older build wrote are gone"
    );
}

/// Finding 1b: a kill -9 while the journal writer syncs. Record 4 is only in memory; its line is
/// in the log's page cache, which a kill keeps.
#[test]
fn a_kill_while_the_journal_syncs_keeps_the_lines_the_log_got() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(21);
    let store = open(home.path(), &journal);
    store.append(CHAT, &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    store.append(CHAT, &record(2, "queued")).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    journal.set_sync_delay(Duration::from_secs(2));
    store.append(CHAT, &record(3, "queued")).unwrap_or_else(|e| panic!("{e:#}"));
    // The writer wrote 3 and is in its 2 s sync.
    std::thread::sleep(Duration::from_millis(300));
    store.append(CHAT, &record(4, "queued")).unwrap_or_else(|e| panic!("{e:#}"));
    let killed = journal.restart(Crash::Process);
    killed.set_sync_delay(Duration::ZERO);
    drop(store);
    let store = open(home.path(), &killed);
    assert_eq!(seqs(store.as_ref(), CHAT), vec![1, 2, 3, 4], "a kill lost a line the log had");
}

/// Finding 1c: a line `flush_session` made durable in the log, whose journal record an OS crash
/// took back (it was still in memory: the writer was in another batch's sync).
#[test]
fn a_line_flush_session_made_durable_survives_losing_its_record() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(24);
    let store = open(home.path(), &journal);
    store.append(CHAT, &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    store.append(CHAT, &record(2, "queued")).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    journal.set_sync_delay(Duration::from_secs(2));
    store.append("chat-b", &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    // The writer is in chat-b's 2 s sync: record 3 waits in memory.
    std::thread::sleep(Duration::from_millis(300));
    store.append(CHAT, &record(3, "queued")).unwrap_or_else(|e| panic!("{e:#}"));
    store.flush_session(CHAT).unwrap_or_else(|e| panic!("{e:#}"));
    let synced = log_files(home.path());
    let crashed = journal.restart(Crash::Os);
    crashed.set_sync_delay(Duration::ZERO);
    drop(store);
    lose_unsynced_log_writes(home.path(), &synced);
    let store = open(home.path(), &crashed);
    assert_eq!(seqs(store.as_ref(), CHAT), vec![1, 2, 3], "a line flush_session synced is gone");
}

/// Finding 2: a folder put back by a rename after its delete (a replacing transfer's rollback,
/// `hub/transfer_in.rs`).
#[test]
fn a_folder_put_back_after_a_delete_is_not_deleted_by_the_replay() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(22);
    let store = open(home.path(), &journal);
    store.append(CHAT, &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    store.close_log(CHAT);
    let sessions = home.path().join("sessions");
    let backup = sessions.join(".chat-a.replacement-backup");
    std::fs::rename(sessions.join(CHAT), &backup).unwrap_or_else(|e| panic!("{e}"));
    store.append(CHAT, &record(1, "imported")).unwrap_or_else(|e| panic!("{e:#}"));
    store.delete(CHAT).unwrap_or_else(|e| panic!("{e:#}"));
    std::fs::rename(&backup, sessions.join(CHAT)).unwrap_or_else(|e| panic!("{e}"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    let killed = journal.restart(Crash::Process);
    drop(store);
    let store = open(home.path(), &killed);
    assert_eq!(seqs(store.as_ref(), CHAT), vec![1], "the chat put back was deleted");
}

/// Finding 3: a kill -9 while a delete's forget record waits in memory. After the restart the
/// chat is whole or gone, never a new folder with only its last lines.
#[test]
fn a_kill_in_a_delete_leaves_the_chat_whole_or_gone() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(23);
    let store: Arc<dyn Store> = Arc::from(open(home.path(), &journal));
    store.append(CHAT, &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    store.append(CHAT, &record(2, "queued")).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    journal.set_sync_delay(Duration::from_secs(3));
    store.append("chat-b", &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    // The writer is in chat-b's 3 s sync.
    std::thread::sleep(Duration::from_millis(300));
    let deleting = {
        let store = Arc::clone(&store);
        std::thread::spawn(move || store.delete(CHAT))
    };
    // The folder is gone; the forget record waits in memory.
    std::thread::sleep(Duration::from_millis(500));
    let killed = journal.restart(Crash::Process);
    killed.set_sync_delay(Duration::ZERO);
    let _ = deleting.join();
    drop(store);
    let store = open(home.path(), &killed);
    let left = seqs(store.as_ref(), CHAT);
    assert!(left.is_empty() || left == vec![1, 2], "a deleted chat came back in part: {left:?}");
}

/// Finding 4: a delete does not wait for the journal's sync (it held every append of every chat
/// and a Tokio worker for up to 5 s).
#[test]
fn a_delete_does_not_wait_for_the_journal_sync() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(25);
    let store = open(home.path(), &journal);
    store.append(CHAT, &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    journal.set_sync_delay(Duration::from_secs(3));
    store.append("chat-b", &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    std::thread::sleep(Duration::from_millis(100));
    let started = std::time::Instant::now();
    store.delete(CHAT).unwrap_or_else(|e| panic!("{e:#}"));
    let took = started.elapsed();
    journal.set_sync_delay(Duration::ZERO);
    assert!(took < Duration::from_secs(1), "the delete waited {took:?} for the journal");
    assert!(!home.path().join("sessions").join(CHAT).exists(), "the chat is still there");
}

/// Finding 5: a log sync that fails inside a checkpoint freezes it (a later sync may report
/// success for pages the kernel dropped), and the store asks the daemon to stop.
#[test]
fn a_failed_log_sync_freezes_the_checkpoint() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(26);
    let store = open(home.path(), &journal);
    store.append(CHAT, &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    store.append(CHAT, &record(2, "queued")).unwrap_or_else(|e| panic!("{e:#}"));
    FAIL_NEXT_LOG_SYNC.with(|fail| fail.set(true));
    let failed = store.flush();
    FAIL_NEXT_LOG_SYNC.with(|fail| fail.set(false));
    assert!(failed.is_err(), "the checkpoint went on past a failed log sync");
    assert!(store.flush().is_err(), "a checkpoint after a failed sync went ahead");
    let reason = store.stop_reason().and_then(|reason| reason.borrow().clone());
    assert!(reason.is_some(), "the store did not ask the daemon to stop");
}

/// Finding 5, the other way: a checkpoint that keeps failing for another reason (its file cannot
/// be put in place) asks the daemon to stop after a bounded number of tries, so the journal past
/// it does not grow without end.
#[test]
fn a_checkpoint_that_keeps_failing_asks_the_daemon_to_stop() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(27);
    let store = open(home.path(), &journal);
    // A non-empty folder where the checkpoint file goes: its rename fails.
    let blocker = home.path().join("journal-projected.json");
    std::fs::create_dir_all(blocker.join("in-the-way")).unwrap_or_else(|e| panic!("{e}"));
    for seq in 1..=40 {
        store.append(CHAT, &record(seq, "queued")).unwrap_or_else(|e| panic!("{e:#}"));
        let _ = store.flush();
    }
    let reason = store.stop_reason().and_then(|reason| reason.borrow().clone());
    assert!(reason.is_some(), "40 failed checkpoints and the store goes on");
}

/// Finding 6: one chat whose log cannot be repaired (a segment that is a link) does not stop the
/// open; its journaled lines are kept beside the logs.
#[test]
fn one_chat_that_cannot_be_repaired_does_not_stop_the_open() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(28);
    let store = open(home.path(), &journal);
    store.append(CHAT, &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    store.append("chat-b", &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    // Durable first: a checkpoint never passes the journal's durable end, and this one must
    // cover line 1.
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    for seq in 2..=3 {
        store.append(CHAT, &record(seq, "queued")).unwrap_or_else(|e| panic!("{e:#}"));
        store.append("chat-b", &record(seq, "queued")).unwrap_or_else(|e| panic!("{e:#}"));
    }
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    let killed = journal.restart(Crash::Process);
    drop(store);
    // chat-b's segment becomes a link to a copy of itself: the store never follows one.
    let events = home.path().join("sessions").join("chat-b").join("events");
    let segment = events.join("000001.ndjson");
    let copy = home.path().join("elsewhere.ndjson");
    std::fs::copy(&segment, &copy).unwrap_or_else(|e| panic!("{e}"));
    std::fs::remove_file(&segment).unwrap_or_else(|e| panic!("{e}"));
    std::os::unix::fs::symlink(&copy, &segment).unwrap_or_else(|e| panic!("{e}"));
    let store = open(home.path(), &killed);
    assert_eq!(seqs(store.as_ref(), CHAT), vec![1, 2, 3]);
    let kept: Vec<u8> = std::fs::read_dir(home.path().join("journal-unapplied"))
        .unwrap_or_else(|e| panic!("journal-unapplied: {e}"))
        .flatten()
        .flat_map(|entry| std::fs::read(entry.path()).unwrap_or_default())
        .collect();
    let kept_seqs: Vec<u64> = kept.split(|b| *b == b'\n').filter_map(record_seq).collect();
    assert_eq!(kept_seqs, vec![2, 3], "chat-b's journaled lines were not kept");
}

/// Finding 7: the journal's storage refuses every write under a lost home.
#[test]
fn the_journal_storage_refuses_a_lost_home() {
    use cmux_journal::{OpenMode, Storage as _};
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let lost = home.path().join("journal");
    let fence_root = lost.clone();
    let storage = FencedStorage::new(
        Arc::new(SimStorage::new(29)),
        Box::new(move |path: &Path| {
            anyhow::ensure!(
                !path.starts_with(&fence_root),
                "{} is under a lost home",
                path.display()
            );
            Ok(())
        }),
    );
    assert!(storage.create_dir_all(&lost).is_err(), "made a folder under a lost home");
    assert!(storage.open(&lost.join("a.seg"), OpenMode::Create).is_err(), "made a file");
    assert!(storage.open(&lost.join("a.seg"), OpenMode::Write).is_err(), "opened a file to write");
    assert!(storage.rename(&lost.join("a"), &lost.join("b")).is_err(), "renamed a file");
    assert!(storage.remove_file(&lost.join("a.seg")).is_err(), "removed a file");
    // Reads and syncs are not writes.
    let elsewhere = home.path().join("other");
    assert!(storage.create_dir_all(&elsewhere).is_ok(), "refused outside the lost home");
}

/// An OS crash leaves a hole of zeros over two journaled lines, and the log has a line after them
/// that the journal never held: the repair writes the two lines back and keeps the last one.
#[test]
fn an_os_crash_hole_is_repaired_and_the_lines_after_it_kept() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(30);
    let store = open(home.path(), &journal);
    for seq in 1..=5 {
        store.append(CHAT, &record(seq, "queued")).unwrap_or_else(|e| panic!("{e:#}"));
    }
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    for seq in 6..=9 {
        store.append(CHAT, &record(seq, "queued")).unwrap_or_else(|e| panic!("{e:#}"));
    }
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    let crashed = journal.restart(Crash::Process);
    drop(store);
    zero_log_lines(home.path(), CHAT, &[6, 7]);
    write_log_line(home.path(), CHAT, &record(10, "queued"));
    let store = open(home.path(), &crashed);
    assert_eq!(seqs(store.as_ref(), CHAT), (1..=10).collect::<Vec<_>>());
}

/// A crash inside that repair, right after the log was cut: the next open still has every line,
/// the one only the log held too.
#[test]
fn a_crash_inside_a_repair_loses_no_line() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(31);
    let store = open(home.path(), &journal);
    for seq in 1..=5 {
        store.append(CHAT, &record(seq, "queued")).unwrap_or_else(|e| panic!("{e:#}"));
    }
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    for seq in 6..=9 {
        store.append(CHAT, &record(seq, "queued")).unwrap_or_else(|e| panic!("{e:#}"));
    }
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    let crashed = journal.restart(Crash::Process);
    drop(store);
    zero_log_lines(home.path(), CHAT, &[6, 7]);
    write_log_line(home.path(), CHAT, &record(10, "queued"));
    STOP_AFTER_CUT.with(|stop| stop.set(true));
    let stopped =
        open_with_journal(&config(), home.path(), Arc::new(crashed.clone()), journal_config());
    STOP_AFTER_CUT.with(|stop| stop.set(false));
    assert!(stopped.is_err(), "the repair did not stop where the test asked");
    drop(stopped);
    let again = crashed.restart(Crash::Process);
    let store = open(home.path(), &again);
    assert_eq!(seqs(store.as_ref(), CHAT), (1..=10).collect::<Vec<_>>());
}

/// Nit: an unreadable checkpoint fails the open (a replay from the oldest record could undo a
/// retention rewrite).
#[test]
fn an_unreadable_checkpoint_fails_the_open() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(32);
    let store = open(home.path(), &journal);
    store.append(CHAT, &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    drop(store);
    std::fs::write(home.path().join("journal-projected.json"), b"{not json")
        .unwrap_or_else(|e| panic!("{e}"));
    let reopened =
        open_with_journal(&config(), home.path(), Arc::new(journal.clone()), journal_config());
    assert!(reopened.is_err(), "an unreadable checkpoint was read as LSN 0");
}

/// Nit: a restart may overlap the old daemon's exit; the open waits a bounded time for the
/// journal's lock.
#[test]
fn the_open_waits_for_the_previous_daemon_to_let_go_of_the_journal() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(33);
    let first = open(home.path(), &journal);
    let releaser = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(300));
        drop(first);
    });
    let second =
        open_with_journal(&config(), home.path(), Arc::new(journal.clone()), journal_config());
    let _ = releaser.join();
    assert!(second.is_ok(), "the open did not wait for the lock: {:?}", second.err());
}

/// Nit: a checkpoint's temporary file that a crash left is removed at the next open.
#[test]
fn a_crashed_checkpoint_temporary_is_removed_at_open() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(34);
    let stale = home.path().join("journal-projected.json.tmp-99999");
    std::fs::write(&stale, b"{}").unwrap_or_else(|e| panic!("{e}"));
    let _store = open(home.path(), &journal);
    assert!(!stale.exists(), "a crashed checkpoint's temporary file was left");
}

/// Nit: a crash right after a checkpoint is a normal crash: the open reports no damage (the
/// checkpoint was past the journal's durable records, which read as "the journal lost records").
#[test]
fn a_crash_right_after_a_checkpoint_reports_no_damage() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(35);
    let store = open(home.path(), &journal);
    store.append(CHAT, &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    journal.set_sync_delay(Duration::from_secs(2));
    store.append("chat-b", &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    // The writer is in chat-b's 2 s sync: record 2 waits in memory through the checkpoint.
    std::thread::sleep(Duration::from_millis(300));
    store.append(CHAT, &record(2, "queued")).unwrap_or_else(|e| panic!("{e:#}"));
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    let crashed = journal.restart(Crash::Os);
    crashed.set_sync_delay(Duration::ZERO);
    drop(store);
    let reopened = JournalStore::open(&config(), home.path(), Arc::new(crashed), journal_config())
        .unwrap_or_else(|e| panic!("{e:#}"));
    assert!(reopened.opened().damage.is_empty(), "{:?}", reopened.opened());
    assert_eq!(seqs(&reopened, CHAT), vec![1, 2]);
}

/// The daemon's store (`store::open`, its journal on the real file system) after an OS crash
/// that its logs lost writes in: the next open writes the journal's lines that the logs lost back
/// first, so every acknowledged line is there (the replay of DESIGN.md 3.6).
#[test]
fn the_daemon_store_keeps_every_acknowledged_line_after_an_os_crash() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let store = super::open(&config(), home.path()).unwrap_or_else(|e| panic!("{e:#}"));
    store.append(CHAT, &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    let synced = log_files(home.path());
    for seq in 2..=5 {
        store.append(CHAT, &record(seq, "queued")).unwrap_or_else(|e| panic!("{e:#}"));
    }
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    drop(store);
    // An OS crash: the logs lose their writes since the flush; the journal synced its records.
    lose_unsynced_log_writes(home.path(), &synced);
    let next = super::open(&config(), home.path()).unwrap_or_else(|e| panic!("{e:#}"));
    assert_eq!(seqs(next.as_ref(), CHAT), (1..=5).collect::<Vec<_>>());
}

/// An agent's streamed output is a `Stream` record, synced with the next acknowledged batch or a
/// second later (DESIGN.md 3.3b, C4); every other line is `Ack`. The hub's tap logs an ACP
/// `session/update` under its `sessionUpdate` kind (`agent_message_chunk`, `tool_call`, ...), so
/// the record's kind is never `session/update`: its message's method is. Found by the S2c I/O A/B
/// (STATUS 11723): every chunk was `Ack`, and its event waited for its sync.
#[test]
fn an_agent_chunk_is_a_stream_record() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(37);
    let store = open(home.path(), &journal);
    let chunk = EventRecord {
        seq: 1,
        at: 1_001,
        dir: "in".into(),
        kind: "agent_message_chunk".into(),
        msg: json!({"jsonrpc": "2.0", "method": "session/update", "params": {
            "sessionId": CHAT,
            "update": {"sessionUpdate": "agent_message_chunk",
                       "content": {"type": "text", "text": "hi"}}
        }}),
        host_seq: None,
    };
    let raw = EventRecord { seq: 2, kind: "claude.assistant".into(), ..chunk.clone() };
    store.append(CHAT, &chunk).unwrap_or_else(|e| panic!("{e:#}"));
    store.append(CHAT, &raw).unwrap_or_else(|e| panic!("{e:#}"));
    store.append(CHAT, &record(3, "queued")).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    let restarted = journal.restart(Crash::Process);
    drop(store);
    // Each record's class, as the journal holds it.
    let mut classes = Vec::new();
    let (reopened, _) = cmux_journal::Journal::open(
        Arc::new(restarted),
        &home.path().join("journal"),
        journal_config(),
        0,
        &mut |record| {
            if let Some((_, line)) = super::journal_store::decode_log_for_test(record.payload) {
                classes.push((line_seq(line), record.class));
            }
            Ok(())
        },
    )
    .unwrap_or_else(|e| panic!("reopen the journal: {e}"));
    drop(reopened);
    assert_eq!(
        classes,
        vec![
            (Some(1), cmux_journal::Class::Stream),
            (Some(2), cmux_journal::Class::Stream),
            (Some(3), cmux_journal::Class::Ack),
        ],
        "an agent chunk and a raw harness line are Stream, a queue line Ack"
    );
}

/// The `seq` of one journaled line (the test reads the journal itself).
fn line_seq(line: &[u8]) -> Option<u64> {
    record_seq(line)
}

// ---------------------------------------------------------------- review 2 of #34901

/// Overwrites `id`'s log with zeros from the middle of line `from` to the middle of line `to`:
/// the hole an OS crash leaves where a page in the middle never reached the disk (a page boundary
/// is almost never at a line start).
fn zero_log_mid_lines(home: &Path, id: &str, from: u64, to: u64) {
    let events = home.join("sessions").join(id).join("events");
    for entry in std::fs::read_dir(&events).unwrap_or_else(|e| panic!("{e}")).flatten() {
        let path = entry.path();
        if path.extension().is_none_or(|ext| ext != "ndjson") {
            continue;
        }
        let mut bytes = std::fs::read(&path).unwrap_or_else(|e| panic!("{e}"));
        let mut lines = BTreeMap::new();
        let mut offset = 0;
        while offset < bytes.len() {
            let end = bytes
                .get(offset..)
                .and_then(|rest| rest.iter().position(|b| *b == b'\n'))
                .map_or(bytes.len(), |at| offset + at + 1);
            if let Some(seq) = bytes.get(offset..end).and_then(record_seq) {
                lines.insert(seq, (offset, end));
            }
            offset = end;
        }
        if let (Some(&(a, a_end)), Some(&(b, b_end))) = (lines.get(&from), lines.get(&to)) {
            if let Some(hole) = bytes.get_mut(a + (a_end - a) / 2..b + (b_end - b) / 2) {
                hole.fill(0);
            }
            std::fs::write(&path, bytes).unwrap_or_else(|e| panic!("{e}"));
        }
    }
}

/// Finding 2: an OS crash hole that starts inside a line. Line 6 keeps its `{"seq":6,` head and
/// runs through the zeros into the tail of line 8: it is torn bytes, not a line of a log that
/// moved on, so the journaled lines go back in.
#[test]
fn a_hole_that_starts_inside_a_line_is_repaired() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(40);
    let store = open(home.path(), &journal);
    for seq in 1..=5 {
        store.append(CHAT, &record(seq, "queued")).unwrap_or_else(|e| panic!("{e:#}"));
    }
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    for seq in 6..=9 {
        store.append(CHAT, &record(seq, "queued")).unwrap_or_else(|e| panic!("{e:#}"));
    }
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    let crashed = journal.restart(Crash::Os);
    drop(store);
    zero_log_mid_lines(home.path(), CHAT, 6, 8);
    let store = open(home.path(), &crashed);
    assert_eq!(
        seqs(store.as_ref(), CHAT),
        (1..=9).collect::<Vec<_>>(),
        "a torn line was taken for a line of a log that moved on"
    );
}

/// Finding 1a: after a kill, the dead daemon's log writes may be in the page cache only. The next
/// start's first checkpoint retires their records, so it must sync those bytes first. An OS crash
/// after that restart keeps every acknowledged line (the logs' crash model follows real syncs).
#[test]
fn an_os_crash_after_a_restart_from_a_kill_keeps_every_acked_line() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(41);
    let store = open(home.path(), &journal);
    store.append(CHAT, &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    for seq in 2..=5 {
        store.append(CHAT, &record(seq, "queued")).unwrap_or_else(|e| panic!("{e:#}"));
    }
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    let killed = journal.restart(Crash::Process);
    drop(store);
    // The restart replays 2..5 and its first checkpoint runs (on the checkpointer's thread after
    // the open returns; `flush` waits for one here, so the crash comes after it).
    let store = open(home.path(), &killed);
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    let crashed = killed.restart(Crash::Os);
    drop(store);
    sync_model::os_crash(&home.path().join("sessions"));
    let store = open(home.path(), &crashed);
    assert_eq!(
        seqs(store.as_ref(), CHAT),
        (1..=5).collect::<Vec<_>>(),
        "the restart's checkpoint retired records whose log lines no sync made durable"
    );
}

/// Finding 1b: a failed log sync freezes the checkpoint and the daemon restarts. The kernel may
/// have marked the lost pages clean, so a plain sync after the restart reports success without
/// them: the restart must write those lines again before its checkpoint retires their records.
#[test]
fn an_os_crash_after_a_restart_from_a_failed_sync_keeps_every_acked_line() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(42);
    let store = open(home.path(), &journal);
    store.append(CHAT, &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    for seq in 2..=5 {
        store.append(CHAT, &record(seq, "queued")).unwrap_or_else(|e| panic!("{e:#}"));
    }
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    FAIL_NEXT_LOG_SYNC.with(|fail| fail.set(true));
    let failed = store.flush();
    FAIL_NEXT_LOG_SYNC.with(|fail| fail.set(false));
    assert!(failed.is_err(), "the checkpoint went on past a failed log sync");
    // The daemon stops for a restart (no crash), and the restart's first checkpoint runs (on the
    // checkpointer's thread after the open returns; `flush` waits for one here).
    drop(store);
    let store = open(home.path(), &journal);
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    let crashed = journal.restart(Crash::Os);
    drop(store);
    sync_model::os_crash(&home.path().join("sessions"));
    let store = open(home.path(), &crashed);
    assert_eq!(
        seqs(store.as_ref(), CHAT),
        (1..=5).collect::<Vec<_>>(),
        "the restart's checkpoint retired records whose lines a failed sync lost"
    );
}

/// Finding 3: a failed sync in `flush_session` (transfer receipts, forks, auto-resume, team
/// messages) freezes the checkpoint, as a failed sync in a checkpoint or at a log's close does.
#[test]
fn a_failed_sync_in_flush_session_freezes_the_checkpoint() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(43);
    let store = open(home.path(), &journal);
    for seq in 1..=3 {
        store.append(CHAT, &record(seq, "queued")).unwrap_or_else(|e| panic!("{e:#}"));
    }
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    FAIL_NEXT_LOG_SYNC.with(|fail| fail.set(true));
    let failed = store.flush_session(CHAT);
    FAIL_NEXT_LOG_SYNC.with(|fail| fail.set(false));
    assert!(failed.is_err(), "flush_session's sync did not fail as the test asked");
    assert!(store.flush().is_err(), "a checkpoint after a failed sync in flush_session went ahead");
    let reason = store.stop_reason().and_then(|reason| reason.borrow().clone());
    assert!(reason.is_some(), "the store did not ask the daemon to stop");
}

// ---------------------------------------------------------------- review 3 of #34901 (follow-ups)

/// Follow-up 1: a chat whose repair fails (its log cannot be read or written now) is repaired at a
/// later start: its lines go to its repair file in `journal-unapplied/`, which the next open
/// journals again (review of #35562: no hold of the global checkpoint).
#[test]
fn a_chat_whose_repair_failed_is_repaired_at_the_next_start() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(44);
    let store = open(home.path(), &journal);
    store.append("chat-b", &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    for seq in 2..=3 {
        store.append("chat-b", &record(seq, "queued")).unwrap_or_else(|e| panic!("{e:#}"));
    }
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    // An OS crash: the log loses lines 2 and 3; the journal keeps them.
    let crashed = journal.restart(Crash::Os);
    drop(store);
    sync_model::os_crash(&home.path().join("sessions"));
    // chat-b's segment becomes a link: the store never follows one, so its repair fails.
    let events = home.path().join("sessions").join("chat-b").join("events");
    let segment = events.join("000001.ndjson");
    let copy = home.path().join("elsewhere.ndjson");
    std::fs::copy(&segment, &copy).unwrap_or_else(|e| panic!("{e}"));
    std::fs::remove_file(&segment).unwrap_or_else(|e| panic!("{e}"));
    std::os::unix::fs::symlink(&copy, &segment).unwrap_or_else(|e| panic!("{e}"));
    let store = open(home.path(), &crashed);
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    drop(store);
    // The cause goes; the next start repairs the chat.
    std::fs::remove_file(&segment).unwrap_or_else(|e| panic!("{e}"));
    std::fs::copy(&copy, &segment).unwrap_or_else(|e| panic!("{e}"));
    let store = open(home.path(), &crashed);
    assert_eq!(
        seqs(store.as_ref(), "chat-b"),
        vec![1, 2, 3],
        "the open's checkpoint retired the records of a chat it could not repair"
    );
}

/// Overwrites `id`'s log with zeros from the middle of line `from` to the start of line `to`: a
/// hole that ends exactly where a line starts, after a torn line.
fn zero_log_mid_line_to_line_start(home: &Path, id: &str, from: u64, to: u64) {
    let events = home.join("sessions").join(id).join("events");
    for entry in std::fs::read_dir(&events).unwrap_or_else(|e| panic!("{e}")).flatten() {
        let path = entry.path();
        if path.extension().is_none_or(|ext| ext != "ndjson") {
            continue;
        }
        let mut bytes = std::fs::read(&path).unwrap_or_else(|e| panic!("{e}"));
        let mut lines = BTreeMap::new();
        let mut offset = 0;
        while offset < bytes.len() {
            let end = bytes
                .get(offset..)
                .and_then(|rest| rest.iter().position(|b| *b == b'\n'))
                .map_or(bytes.len(), |at| offset + at + 1);
            if let Some(seq) = bytes.get(offset..end).and_then(record_seq) {
                lines.insert(seq, (offset, end));
            }
            offset = end;
        }
        if let (Some(&(a, a_end)), Some(&(b, _))) = (lines.get(&from), lines.get(&to)) {
            if let Some(hole) = bytes.get_mut(a + (a_end - a) / 2..b) {
                hole.fill(0);
            }
            std::fs::write(&path, bytes).unwrap_or_else(|e| panic!("{e}"));
        }
    }
}

/// Follow-up 2: a hole that ends exactly at a line start, after a torn line, does not swallow
/// that line. It matters for a line only the log holds (here line 8: written, its record never
/// made, as after a crash between the two).
#[test]
fn a_hole_that_ends_at_a_line_start_keeps_that_line() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(45);
    let store = open(home.path(), &journal);
    for seq in 1..=5 {
        store.append(CHAT, &record(seq, "queued")).unwrap_or_else(|e| panic!("{e:#}"));
    }
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    for seq in 6..=7 {
        store.append(CHAT, &record(seq, "queued")).unwrap_or_else(|e| panic!("{e:#}"));
    }
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    let killed = journal.restart(Crash::Process);
    drop(store);
    write_log_line(home.path(), CHAT, &record(8, "queued"));
    zero_log_mid_line_to_line_start(home.path(), CHAT, 6, 8);
    let store = open(home.path(), &killed);
    assert_eq!(
        seqs(store.as_ref(), CHAT),
        (1..=8).collect::<Vec<_>>(),
        "a line after a hole that ends at its start was dropped"
    );
}

/// Follow-up 4: an idle store's checkpointer sleeps until the next change, instead of waking every
/// period (cmux-ad m9: an idle daemon must not wake periodically); the next change still gets its
/// checkpoint one period later.
#[test]
fn an_idle_store_does_not_wake_its_checkpointer() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    checkpointer_seams(home.path(), |seams| seams.every_ms = 20);
    let wakes = || checkpointer_seams(home.path(), |seams| seams.wakes);
    let journal = SimStorage::new(46);
    let store = open(home.path(), &journal);
    store.append(CHAT, &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    // Let the checkpointer see that nothing is left to do.
    std::thread::sleep(Duration::from_millis(100));
    let before = wakes();
    std::thread::sleep(Duration::from_millis(500));
    let woke = wakes().saturating_sub(before);
    assert!(woke <= 1, "an idle checkpointer woke {woke} times in 500 ms (period 20 ms)");
    // A change wakes it: its checkpoint comes about one period later.
    store.append(CHAT, &record(2, "queued")).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    let checkpointed = loop {
        let bytes = std::fs::read(home.path().join("journal-projected.json")).unwrap_or_default();
        let lsn =
            serde_json::from_slice::<Value>(&bytes).ok().and_then(|value| value["lsn"].as_u64());
        if lsn.is_some_and(|lsn| lsn >= 2) || std::time::Instant::now() > deadline {
            break lsn;
        }
        std::thread::sleep(Duration::from_millis(20));
    };
    assert!(
        checkpointed.is_some_and(|lsn| lsn >= 2),
        "no checkpoint after a change ({checkpointed:?})"
    );
}

/// A freeze is a `frozen` record in the journal: the next open writes every replayed chat's
/// lines again even when its log reads whole (the kernel may have dropped pages that still read
/// back), and its first checkpoint retires the record, so the open after that takes the whole log
/// as it is (no write on the opening thread).
#[test]
fn a_freeze_makes_the_next_open_write_the_lines_again_and_only_that_open() {
    use super::log_sync::ALL_SYNCS;
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(48);
    let store = open(home.path(), &journal);
    store.append(CHAT, &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    store.append(CHAT, &record(2, "queued")).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    FAIL_NEXT_LOG_SYNC.with(|fail| fail.set(true));
    let failed = store.flush();
    FAIL_NEXT_LOG_SYNC.with(|fail| fail.set(false));
    assert!(failed.is_err(), "the checkpoint went on past a failed log sync");
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    drop(store);
    let log = home.path().join("sessions").join(CHAT).join("events").join("000001.ndjson");
    let before = std::fs::read(&log).unwrap_or_default();
    // The restart after the freeze writes the chat's lines again (its repair cuts and writes the
    // log, with syncs on the opening thread).
    let syncs = ALL_SYNCS.with(std::cell::Cell::get);
    let store = open(home.path(), &journal);
    let rewritten = ALL_SYNCS.with(std::cell::Cell::get).saturating_sub(syncs);
    assert!(rewritten > 0, "the open after a freeze did not write the chat's lines again");
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    assert_eq!(seqs(store.as_ref(), CHAT), vec![1, 2]);
    assert_eq!(
        std::fs::read(&log).unwrap_or_default(),
        before,
        "the rewrite changed the log's bytes"
    );
    // A kill after that checkpoint (which retired the record): the next open trusts the log.
    store.append(CHAT, &record(3, "queued")).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    let killed = journal.restart(Crash::Process);
    drop(store);
    let syncs = ALL_SYNCS.with(std::cell::Cell::get);
    let store = open(home.path(), &killed);
    let again = ALL_SYNCS.with(std::cell::Cell::get).saturating_sub(syncs);
    assert_eq!(seqs(store.as_ref(), CHAT), vec![1, 2, 3]);
    assert!(
        again < rewritten,
        "an open long after a freeze still wrote the lines again ({again} syncs on its thread, {rewritten} at the open after the freeze)"
    );
}

/// The idle checkpointer (follow-up 4) and its period. A change whose `touched` takes the idle
/// flag while the checkpointer holds the timer lock (between marking itself idle and its second
/// look) notifies once it gets that lock. The second look saw the change, so the checkpointer is
/// in its period wait by then, and that notify must not end it: else a checkpoint runs at once on
/// the checkpointer's thread, and a burst no longer shares one. In fleet run 0577ac62 such a
/// checkpoint took the line whose sync `a_failed_log_sync_freezes_the_checkpoint` fails (on a
/// thread where the failure is not set), and the test's own flush had nothing to do.
#[test]
fn a_change_seen_by_the_idle_checkpointers_second_look_waits_one_period() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let (idle_arrived, idle_seen) = std::sync::mpsc::channel();
    let (idle_release, idle_released) = std::sync::mpsc::channel();
    let (touch_arrived, touch_seen) = std::sync::mpsc::channel();
    let (touch_release, touch_released) = std::sync::mpsc::channel();
    checkpointer_seams(home.path(), |seams| {
        seams.idle_hold = Some((idle_arrived, idle_released));
        seams.touch_hold = Some((touch_arrived, touch_released));
    });
    let journal = SimStorage::new(47);
    let store: Arc<dyn Store> = Arc::from(open(home.path(), &journal));
    // After the store: a panic before the releases lets both holds go before the unwind drops it.
    let idle_release = super::journal_store::Release::new(idle_release);
    let touch_release = super::journal_store::Release::new(touch_release);
    // The checkpointer found nothing to do, marked itself idle and holds the timer lock.
    idle_seen
        .recv_timeout(WAIT)
        .unwrap_or_else(|e| panic!("the checkpointer never went idle: {e}"));
    let appender = {
        let store = Arc::clone(&store);
        std::thread::spawn(move || {
            store.append(CHAT, &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
        })
    };
    // The change took the idle flag; its notify waits for the timer lock.
    touch_seen
        .recv_timeout(WAIT)
        .unwrap_or_else(|e| panic!("the change never took the idle flag: {e}"));
    // The second look sees the change, so the checkpointer goes to its period wait (30 s), and
    // the change's notify comes in there.
    idle_release.now();
    touch_release.now();
    appender.join().unwrap_or_else(|_| panic!("the append panicked"));
    std::thread::sleep(Duration::from_millis(300));
    let woke = checkpointer_seams(home.path(), |seams| seams.wakes);
    assert_eq!(
        woke, 0,
        "the change's notify ended the checkpointer's period: a checkpoint ran at once"
    );
    assert!(
        !home.path().join("journal-projected.json").exists(),
        "a checkpoint ran before one period after the change"
    );
}

// ---------------------------------------------------------------- review of #35400 (S2c)

/// F1: a read that shows a line returns only once that line's record is appended, so the reply
/// built from it raises its connection's gate to that record. Before, a read saw the log line
/// between the log write and the record, and the reply went out with no wait for it.
#[test]
fn a_read_that_shows_a_line_covers_its_record() {
    use std::sync::atomic::Ordering;
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(47);
    let store: Arc<dyn Store> = Arc::from(open(home.path(), &journal));
    let durability = store.durability().unwrap_or_else(|| panic!("no durability"));
    store.append(CHAT, &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    let (arrived_tx, arrived) = std::sync::mpsc::channel();
    let (release, release_rx) = std::sync::mpsc::channel();
    let appender = {
        let store = Arc::clone(&store);
        std::thread::spawn(move || {
            pause_next_log_write_on_this_thread(arrived_tx, release_rx);
            store.append(CHAT, &record(2, "queued"))
        })
    };
    arrived.recv_timeout(WAIT).unwrap_or_else(|e| panic!("the append never paused: {e}"));
    let (at_fence_tx, at_fence) = std::sync::mpsc::channel();
    let reader = {
        let store = Arc::clone(&store);
        let acked = Arc::clone(&durability.acked);
        std::thread::spawn(move || {
            super::journal_store::NOTE_AT_READ_FENCE
                .with(|note| *note.borrow_mut() = Some(at_fence_tx));
            let seen = seqs(store.as_ref(), CHAT);
            (seen, acked.load(Ordering::SeqCst))
        })
    };
    // The read has read the log and waits at the fence: only then the append goes on.
    at_fence.recv_timeout(WAIT).unwrap_or_else(|e| panic!("the read never reached the fence: {e}"));
    let _ = release.send(());
    appender
        .join()
        .unwrap_or_else(|_| panic!("append panicked"))
        .unwrap_or_else(|e| panic!("{e:#}"));
    let (seen, acked_then) = reader.join().unwrap_or_else(|_| panic!("read panicked"));
    let acked_now = durability.acked.load(Ordering::SeqCst);
    if seen.contains(&2) {
        assert_eq!(
            acked_then, acked_now,
            "a read showed line 2 before its record was appended (acked {acked_then}, then {acked_now})"
        );
    }
}

// ---------------------------------------------------------------- review of #35562 (the hold)

/// Makes `id`'s first log segment a link to a copy of itself: the store never follows one, so the
/// chat's repair fails at every open until the link goes.
fn link_first_segment(home: &Path, id: &str) -> (PathBuf, PathBuf) {
    let segment = home.join("sessions").join(id).join("events").join("000001.ndjson");
    let copy = home.join(format!("{id}-elsewhere.ndjson"));
    std::fs::copy(&segment, &copy).unwrap_or_else(|e| panic!("{e}"));
    std::fs::remove_file(&segment).unwrap_or_else(|e| panic!("{e}"));
    std::os::unix::fs::symlink(&copy, &segment).unwrap_or_else(|e| panic!("{e}"));
    (segment, copy)
}

/// A store whose open could not repair chat-b (its segment a link): chat-b's line 2 was past the
/// checkpoint at a kill.
fn open_with_a_failed_repair(home: &Path, journal: &SimStorage) -> (Box<dyn Store>, SimStorage) {
    let store = open(home, journal);
    store.append("chat-b", &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    store.append("chat-b", &record(2, "queued")).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    let killed = journal.restart(Crash::Process);
    drop(store);
    link_first_segment(home, "chat-b");
    (open(home, &killed), killed)
}

fn checkpoint_lsn(home: &Path) -> u64 {
    let bytes = std::fs::read(home.join("journal-projected.json")).unwrap_or_default();
    serde_json::from_slice::<Value>(&bytes).ok().and_then(|v| v["lsn"].as_u64()).unwrap_or(0)
}

/// F2 and F3 of the review of #35562, at the root: a chat whose repair failed keeps only its own
/// lines for the next start; the checkpoint of every other chat goes on. (A hold of the global
/// checkpoint kept every chat's records past it, so each start replayed them again, a retention
/// rewrite came undone, and the journal grew with each restart.)
#[test]
fn a_failed_repair_does_not_hold_the_checkpoint_of_other_chats() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(80);
    let (store, _killed) = open_with_a_failed_repair(home.path(), &journal);
    for seq in 1..=3 {
        store.append(CHAT, &record(seq, "queued")).unwrap_or_else(|e| panic!("{e:#}"));
    }
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    let durability = store.durability().unwrap_or_else(|| panic!("no durability"));
    let last = durability.acked.load(std::sync::atomic::Ordering::SeqCst);
    assert!(
        checkpoint_lsn(home.path()) >= last,
        "the checkpoint stayed at {} below chat-a's records (the journal ends at {last})",
        checkpoint_lsn(home.path())
    );
}

/// A retention rewrite of another chat after a failed repair stays: the next open writes none of
/// the lines it cut back, and keeps no copy of them aside.
#[test]
fn a_retention_rewrite_after_a_failed_repair_stays_after_a_restart() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(81);
    let (store, killed) = open_with_a_failed_repair(home.path(), &journal);
    store.append(CHAT, &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    let long = EventRecord {
        seq: 2,
        at: 1_002,
        dir: "in".into(),
        kind: "claude.assistant".into(),
        msg: json!({ "text": "x".repeat(8 * 1024) }),
        host_seq: None,
    };
    store.append(CHAT, &long).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    let staged = store
        .stage_compaction(CHAT, CompactMode::Write { archive: None })
        .unwrap_or_else(|e| panic!("{e:#}"))
        .unwrap_or_else(|| panic!("nothing to compact"));
    assert!(store.commit_compaction(CHAT, staged).unwrap_or_else(|e| panic!("{e:#}")));
    let cut = std::fs::read(home.path().join("sessions").join(CHAT).join("events/000001.ndjson"))
        .unwrap_or_else(|e| panic!("{e}"));
    drop(store);
    let store = open(home.path(), &killed);
    let after = std::fs::read(home.path().join("sessions").join(CHAT).join("events/000001.ndjson"))
        .unwrap_or_else(|e| panic!("{e}"));
    assert_eq!(seqs(store.as_ref(), CHAT), vec![1, 2]);
    assert!(after == cut, "the open wrote lines a retention rewrite cut back into the log");
    let kept: Vec<String> = std::fs::read_dir(home.path().join("journal-unapplied"))
        .map(|entries| {
            entries
                .flatten()
                .map(|entry| entry.file_name().to_string_lossy().into_owned())
                .collect()
        })
        .unwrap_or_default();
    assert!(
        !kept.iter().any(|name| name.starts_with(CHAT)),
        "the open kept a copy of a rewritten log aside: {kept:?}"
    );
}

/// A chat whose repair failed, then deleted and made again under the same id in that run: the
/// next start gives the new chat none of the old chat's kept lines.
#[test]
fn a_chat_deleted_after_its_failed_repair_does_not_get_its_old_lines() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(82);
    let (store, killed) = open_with_a_failed_repair(home.path(), &journal);
    store.delete("chat-b").unwrap_or_else(|e| panic!("{e:#}"));
    store.append("chat-b", &record(1, "created-again")).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    drop(store);
    let store = open(home.path(), &killed);
    let kinds: Vec<String> = store
        .events("chat-b", 0, 100)
        .unwrap_or_else(|e| panic!("{e:#}"))
        .into_iter()
        .map(|record| record.kind)
        .collect();
    assert_eq!(kinds, vec!["created-again".to_owned()], "the new chat got the old chat's lines");
}

// ---------------------------------------------------------------- delta review of #35562 (D1 to D4)

/// The link goes: the segment is a file again.
fn unlink_first_segment(segment: &Path, copy: &Path) {
    std::fs::remove_file(segment).unwrap_or_else(|e| panic!("{e}"));
    std::fs::copy(copy, segment).unwrap_or_else(|e| panic!("{e}"));
}

/// The seqs of every line in any file of `journal-unapplied/`.
fn kept_seqs(home: &Path) -> BTreeSet<u64> {
    let Ok(entries) = std::fs::read_dir(home.join("journal-unapplied")) else {
        return BTreeSet::new();
    };
    let mut seqs = BTreeSet::new();
    for entry in entries.flatten() {
        let bytes = std::fs::read(entry.path()).unwrap_or_default();
        seqs.extend(bytes.split(|b| *b == b'\n').filter_map(record_seq));
    }
    seqs
}

/// The repair files of chat `id` in `journal-unapplied/`.
fn repair_files(home: &Path, id: &str) -> Vec<String> {
    std::fs::read_dir(home.join("journal-unapplied"))
        .map(|entries| {
            entries
                .flatten()
                .map(|entry| entry.file_name().to_string_lossy().into_owned())
                .filter(|name| {
                    name.starts_with(&format!("{id}.")) && name.ends_with(".repair.ndjson")
                })
                .collect()
        })
        .unwrap_or_default()
}

/// chat-b at an OS crash: its log keeps line 1, the journal lines 1 to `last`. Then its segment
/// is a link, so the next open cannot repair it. Returns the journal after the crash and the link.
fn crash_with_a_broken_chat(home: &Path, seed: u64, last: u64) -> (SimStorage, PathBuf, PathBuf) {
    let journal = SimStorage::new(seed);
    let store = open(home, &journal);
    store.append("chat-b", &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    for seq in 2..=last {
        store.append("chat-b", &record(seq, "queued")).unwrap_or_else(|e| panic!("{e:#}"));
    }
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    let crashed = journal.restart(Crash::Os);
    drop(store);
    sync_model::os_crash(&home.join("sessions"));
    let (segment, copy) = link_first_segment(home, "chat-b");
    (crashed, segment, copy)
}

/// D1 (the reviewer's test): a chat whose repair failed, and whose folder is aside at the next
/// open (a replacing transfer staged it, `hub/transfer_in.rs`, and the daemon was killed before
/// the import committed; `Hub::recover_staged_replacements` renames it back after the store's
/// open). Its kept lines must not be lost: in its log once the folder is back, or still kept.
#[test]
fn a_failed_repairs_lines_survive_a_folder_that_is_aside_at_the_open() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let (crashed, segment, copy) = crash_with_a_broken_chat(home.path(), 90, 3);
    // This open cannot repair chat-b: its lines 2 and 3 are kept.
    let store = open(home.path(), &crashed);
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    drop(store);
    // The folder is aside at the next open, and back after it.
    let sessions = home.path().join("sessions");
    let aside = sessions.join(".chat-b.replacement-backup");
    std::fs::rename(sessions.join("chat-b"), &aside).unwrap_or_else(|e| panic!("{e}"));
    let store = open(home.path(), &crashed);
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    drop(store);
    std::fs::rename(&aside, sessions.join("chat-b")).unwrap_or_else(|e| panic!("{e}"));
    unlink_first_segment(&segment, &copy);
    let store = open(home.path(), &crashed);
    let logged = seqs(store.as_ref(), "chat-b");
    let kept = kept_seqs(home.path());
    assert!(
        logged == vec![1, 2, 3] || (kept.contains(&2) && kept.contains(&3)),
        "chat-b's kept lines are lost: its log holds {logged:?}, journal-unapplied/ holds {kept:?}"
    );
}

/// D1, the other half: a failed repair's lines belong to the folder they were kept for. A
/// transfer that replaced that folder (the old one aside, another chat's in its place) must not
/// get them, and they stay kept.
#[test]
fn a_failed_repairs_lines_never_go_into_a_folder_that_replaced_it() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let (crashed, _segment, _copy) = crash_with_a_broken_chat(home.path(), 92, 3);
    let store = open(home.path(), &crashed);
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    drop(store);
    // A transfer replaces the folder: the old one aside, the incoming chat's in its place.
    let sessions = home.path().join("sessions");
    std::fs::rename(sessions.join("chat-b"), sessions.join(".chat-b.replacement-backup"))
        .unwrap_or_else(|e| panic!("{e}"));
    let local = LocalStore::new(sessions.clone(), 1 << 20).unwrap_or_else(|e| panic!("{e:#}"));
    Store::append(&local, "chat-b", &record(1, "transferred")).unwrap_or_else(|e| panic!("{e:#}"));
    Store::flush(&local).unwrap_or_else(|e| panic!("{e:#}"));
    drop(local);
    let store = open(home.path(), &crashed);
    let kinds: Vec<String> = store
        .events("chat-b", 0, 100)
        .unwrap_or_else(|e| panic!("{e:#}"))
        .into_iter()
        .map(|record| record.kind)
        .collect();
    assert_eq!(
        kinds,
        vec!["transferred".to_owned()],
        "the old chat's kept lines went into the folder that replaced it"
    );
    let kept = kept_seqs(home.path());
    assert!(kept.contains(&2) && kept.contains(&3), "the old chat's kept lines are lost: {kept:?}");
}

/// D2 (the reviewer's test): an OS crash before a repair file's sync could leave its last line
/// torn. No checkpoint ran after the file, so the journal still holds the chat's records. The
/// next open must still repair the chat.
#[test]
fn a_torn_repair_file_does_not_stop_the_chats_repair() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let (crashed, segment, copy) = crash_with_a_broken_chat(home.path(), 91, 3);
    // The state of a crash right after the next open wrote its repair file: the journal and the
    // checkpoint as before that open, the file torn in its last line.
    let checkpoint_path = home.path().join("journal-projected.json");
    let checkpoint = std::fs::read(&checkpoint_path).unwrap_or_else(|e| panic!("{e}"));
    let before = crashed.snapshot(Crash::Process);
    let store = open(home.path(), &crashed);
    drop(store);
    std::fs::write(&checkpoint_path, &checkpoint).unwrap_or_else(|e| panic!("{e}"));
    let unapplied = home.path().join("journal-unapplied");
    for entry in std::fs::read_dir(&unapplied).unwrap_or_else(|e| panic!("{e}")).flatten() {
        let len = entry.metadata().map(|meta| meta.len()).unwrap_or(0);
        let file = std::fs::OpenOptions::new()
            .write(true)
            .open(entry.path())
            .unwrap_or_else(|e| panic!("{e}"));
        file.set_len(len.saturating_sub(10)).unwrap_or_else(|e| panic!("{e}"));
    }
    // The cause goes: the chat can be repaired now.
    unlink_first_segment(&segment, &copy);
    let store = open(home.path(), &before);
    assert_eq!(
        seqs(store.as_ref(), "chat-b"),
        vec![1, 2, 3],
        "a torn repair file stopped the chat's repair"
    );
}

/// D3: a delete whose folder removal fails keeps the chat's repair file in its hands, so the
/// delete that succeeds later removes it.
#[test]
fn a_delete_that_succeeds_after_a_failed_one_removes_the_repair_file() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let (crashed, _segment, _copy) = crash_with_a_broken_chat(home.path(), 93, 3);
    let store = open(home.path(), &crashed);
    assert!(!repair_files(home.path(), "chat-b").is_empty(), "no repair file");
    FAIL_NEXT_FOLDER_REMOVAL.with(|fail| fail.set(true));
    assert!(store.delete("chat-b").is_err(), "the folder removal did not fail");
    FAIL_NEXT_FOLDER_REMOVAL.with(|fail| fail.set(false));
    store.delete("chat-b").unwrap_or_else(|e| panic!("{e:#}"));
    assert_eq!(
        repair_files(home.path(), "chat-b"),
        Vec::<String>::new(),
        "a deleted chat's repair file was left"
    );
}

/// D4: a repair file larger than what the journal takes at once (`max_pending_bytes`) is still
/// applied: the open waits for the journal's writer instead of failing at its backlog.
#[test]
fn a_repair_file_larger_than_the_journal_queue_is_applied() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let (crashed, segment, copy) = crash_with_a_broken_chat(home.path(), 94, 300);
    // This open cannot repair chat-b: its lines 2 to 300 go to its repair file.
    let store = open(home.path(), &crashed);
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    drop(store);
    unlink_first_segment(&segment, &copy);
    // The next open's journal takes at most 4 KiB of records at once, and its syncs are slow.
    crashed.set_sync_delay(Duration::from_millis(20));
    let small = cmux_journal::Config { max_pending_bytes: 4096, ..journal_config() };
    let store = open_with_journal(&config(), home.path(), Arc::new(crashed.clone()), small)
        .unwrap_or_else(|e| panic!("open the store: {e:#}"));
    crashed.set_sync_delay(Duration::ZERO);
    assert_eq!(
        seqs(store.as_ref(), "chat-b"),
        (1..=300).collect::<Vec<_>>(),
        "a repair file larger than the journal's queue was not applied"
    );
}

// ---------------------------------------------------------------- review of #35866: a checkpoint and a freeze

/// The reviewer's test (review of #35866, finding 2's base part): a checkpoint in flight (past
/// its start, where it read `frozen`) when a log sync fails on another thread (a request's
/// `flush_session`; the store freezes). The checkpoint's own sync of that log may report success
/// for the pages the failed sync dropped: it must not retire the line's record. The checkpoint is
/// held right after its start (test seam `HOLD_AFTER_START`) while the sync fails: no timer.
#[test]
fn a_checkpoint_in_flight_does_not_go_past_a_freeze() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(95);
    let store: Arc<dyn Store> = Arc::from(open(home.path(), &journal));
    store.append(CHAT, &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    store.append(CHAT, &record(2, "queued")).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    // A checkpoint in flight: held right after its start.
    let (started_tx, started) = std::sync::mpsc::channel();
    let (go, go_rx) = std::sync::mpsc::channel();
    let flusher = {
        let store = Arc::clone(&store);
        std::thread::spawn(move || {
            HOLD_AFTER_START.with(|hold| *hold.borrow_mut() = Some((started_tx, go_rx)));
            store.flush()
        })
    };
    started.recv_timeout(WAIT).unwrap_or_else(|e| panic!("the checkpoint never started: {e}"));
    FAIL_NEXT_LOG_SYNC.with(|fail| fail.set(true));
    let failed = store.flush_session(CHAT);
    FAIL_NEXT_LOG_SYNC.with(|fail| fail.set(false));
    assert!(failed.is_err(), "flush_session's sync did not fail as the test asked");
    let _ = go.send(());
    let in_flight = flusher.join().unwrap_or_else(|_| panic!("the flush panicked"));
    // The daemon stops for a restart (no crash); the restart's first checkpoint runs.
    drop(store);
    let store = open(home.path(), &journal);
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    let crashed = journal.restart(Crash::Os);
    drop(store);
    sync_model::os_crash(&home.path().join("sessions"));
    let store = open(home.path(), &crashed);
    assert_eq!(
        seqs(store.as_ref(), CHAT),
        vec![1, 2],
        "a checkpoint in flight went on past a freeze and retired the record of a line whose sync failed (it returned {})",
        if in_flight.is_ok() { "ok" } else { "an error" }
    );
}

/// The same race at its narrowest: another thread's log sync has failed and has not frozen the
/// store yet when a checkpoint is about to write its LSN. The checkpoint must not retire the
/// line's record either: it waits for that sync, which freezes the store when the test lets it
/// go on. The test knows that the checkpoint waits from its note (test seam
/// `NOTE_BEFORE_SYNCS_WAIT`), sent right before it blocks: no timer.
#[test]
fn a_checkpoint_never_goes_past_a_sync_that_is_failing_on_another_thread() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(96);
    let store: Arc<dyn Store> = Arc::from(open(home.path(), &journal));
    store.append(CHAT, &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    store.append(CHAT, &record(2, "queued")).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    // Another thread's flush_session: its log sync fails, and it stops right before it freezes
    // the store.
    let (arrived_tx, arrived) = std::sync::mpsc::channel();
    let (release, release_rx) = std::sync::mpsc::channel();
    let failing = {
        let store = Arc::clone(&store);
        std::thread::spawn(move || {
            HOLD_BEFORE_FREEZE.with(|hold| *hold.borrow_mut() = Some((arrived_tx, release_rx)));
            FAIL_NEXT_LOG_SYNC.with(|fail| fail.set(true));
            let result = store.flush_session(CHAT);
            FAIL_NEXT_LOG_SYNC.with(|fail| fail.set(false));
            result
        })
    };
    arrived.recv_timeout(WAIT).unwrap_or_else(|e| panic!("the failing sync never arrived: {e}"));
    // A checkpoint now, while that failure is not recorded yet: it says when it waits, or that it
    // returned.
    let (events_tx, events) = std::sync::mpsc::channel();
    let flusher = {
        let store = Arc::clone(&store);
        std::thread::spawn(move || {
            NOTE_BEFORE_SYNCS_WAIT.with(|note| *note.borrow_mut() = Some(events_tx.clone()));
            let result = store.flush();
            let _ = events_tx.send("returned");
            result
        })
    };
    let first =
        events.recv_timeout(WAIT).unwrap_or_else(|e| panic!("no word from the checkpoint: {e}"));
    let waited = first != "returned";
    if waited {
        // Blocked on the held sync's ticket: it cannot return before the release.
        assert!(!flusher.is_finished(), "the checkpoint returned while it waited for a sync");
    }
    let _ = release.send(());
    let failed = failing.join().unwrap_or_else(|_| panic!("the failing thread panicked"));
    assert!(failed.is_err(), "flush_session's sync did not fail as the test asked");
    let checkpointed = flusher.join().unwrap_or_else(|_| panic!("the flush panicked"));
    drop(store);
    let store = open(home.path(), &journal);
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    let crashed = journal.restart(Crash::Os);
    drop(store);
    sync_model::os_crash(&home.path().join("sessions"));
    let store = open(home.path(), &crashed);
    assert_eq!(
        seqs(store.as_ref(), CHAT),
        vec![1, 2],
        "a checkpoint went past a sync that was failing on another thread (it {} and returned {})",
        if waited { "waited" } else { "did not wait" },
        if checkpointed.is_ok() { "ok" } else { "an error" }
    );
    assert!(waited, "the checkpoint did not wait for the failing sync");
}

/// A checkpoint while a sync of the store's files that succeeds is under way on another thread:
/// the checkpoint waits for it and goes on. It never fails for it: a failed checkpoint also
/// refuses a compaction's commit and leaves the shutdown's checkpoint undone. The test knows that
/// the checkpoint waits from its note (test seam `NOTE_BEFORE_SYNCS_WAIT`): no timer.
#[test]
fn a_checkpoint_waits_for_a_sync_under_way_on_another_thread() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(97);
    let store: Arc<dyn Store> = Arc::from(open(home.path(), &journal));
    store.append(CHAT, &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    // Another thread's flush_session: its sync is under way and stops before it syncs.
    let (arrived_tx, arrived) = std::sync::mpsc::channel();
    let (release, release_rx) = std::sync::mpsc::channel();
    let syncing = {
        let store = Arc::clone(&store);
        std::thread::spawn(move || {
            HOLD_IN_SYNC.with(|hold| *hold.borrow_mut() = Some((arrived_tx, release_rx)));
            store.flush_session(CHAT)
        })
    };
    arrived.recv_timeout(WAIT).unwrap_or_else(|e| panic!("the sync never began: {e}"));
    let (events_tx, events) = std::sync::mpsc::channel();
    let flusher = {
        let store = Arc::clone(&store);
        std::thread::spawn(move || {
            NOTE_BEFORE_SYNCS_WAIT.with(|note| *note.borrow_mut() = Some(events_tx.clone()));
            let result = store.flush();
            let _ = events_tx.send("returned");
            result
        })
    };
    let first =
        events.recv_timeout(WAIT).unwrap_or_else(|e| panic!("no word from the checkpoint: {e}"));
    if first == "returned" {
        let _ = release.send(());
        let result = flusher.join().unwrap_or_else(|_| panic!("the flush panicked"));
        panic!(
            "a checkpoint did not wait for a sync under way on another thread: it returned {}",
            result.map_or_else(|e| format!("{e:#}"), |()| "ok".to_owned())
        );
    }
    // Blocked on the held sync's ticket: it cannot return before the release.
    assert!(!flusher.is_finished(), "the checkpoint returned while it waited for a sync");
    let _ = release.send(());
    syncing
        .join()
        .unwrap_or_else(|_| panic!("the sync panicked"))
        .unwrap_or_else(|e| panic!("the sync failed: {e:#}"));
    flusher.join().unwrap_or_else(|_| panic!("the flush panicked")).unwrap_or_else(|e| {
        panic!("a checkpoint failed for a sync under way on another thread: {e:#}")
    });
}

// ---------------------------------------------------------------- review of #35895: a log's close

/// The reviewer's test (review of #35895, finding 1): a log's close on another thread
/// (`close_log`; an eviction, a segment's end and a retention commit use the same
/// `SegmentWriter::close`) notes a failed sync in `sync_failed` only after its sync returned,
/// both under the writers' lock. A checkpoint that cloned the log before the close syncs the
/// clone after the close's failed sync and sees success (the clone shares the close's error
/// report); it must still not retire the line's record. The close is held before its note,
/// holding the writers' lock. The checkpoint must then wait for it, not return: it says so right
/// before it takes the lock (test seam `NOTE_BEFORE_CLOSE_NOTE_READ`), and only then does the
/// test let the close go on. No timer.
#[test]
fn a_checkpoint_never_goes_past_a_log_close_whose_sync_is_failing_on_another_thread() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(98);
    let store: Arc<dyn Store> = Arc::from(open(home.path(), &journal));
    store.append(CHAT, &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    store.append(CHAT, &record(2, "queued")).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    // A checkpoint that cloned the chat's open log and stops before its own sync of it. It says
    // when it is about to wait for the closes' note, or that it returned.
    let (cloned_tx, cloned) = std::sync::mpsc::channel();
    let (go, go_rx) = std::sync::mpsc::channel();
    let (events_tx, events) = std::sync::mpsc::channel();
    let checkpoint = {
        let store = Arc::clone(&store);
        std::thread::spawn(move || {
            super::log_sync::HOLD_AFTER_LOG_CLONE
                .with(|hold| *hold.borrow_mut() = Some((cloned_tx, go_rx)));
            super::log_sync::NOTE_BEFORE_CLOSE_NOTE_READ
                .with(|note| *note.borrow_mut() = Some(events_tx.clone()));
            let result = store.flush();
            let _ = events_tx.send("returned");
            result
        })
    };
    cloned
        .recv_timeout(WAIT)
        .unwrap_or_else(|e| panic!("the checkpoint never cloned the log: {e}"));
    // The log closes on another thread: its sync fails, and it stops before it notes that,
    // holding the writers' lock.
    let (failed_tx, failed) = std::sync::mpsc::channel();
    let (release, release_rx) = std::sync::mpsc::channel();
    let closing = {
        let store = Arc::clone(&store);
        std::thread::spawn(move || {
            super::log_sync::HOLD_BEFORE_CLOSE_NOTE
                .with(|hold| *hold.borrow_mut() = Some((failed_tx, release_rx)));
            FAIL_NEXT_LOG_SYNC.with(|fail| fail.set(true));
            store.close_log(CHAT);
            FAIL_NEXT_LOG_SYNC.with(|fail| fail.set(false));
        })
    };
    failed.recv_timeout(WAIT).unwrap_or_else(|e| panic!("the close's sync never failed: {e}"));
    // The checkpoint syncs its clone (success: the close's sync took the error) and goes on.
    let _ = go.send(());
    let first =
        events.recv_timeout(WAIT).unwrap_or_else(|e| panic!("no word from the checkpoint: {e}"));
    let waited = first != "returned";
    if waited {
        // At the writers' lock, which the held close owns: it cannot return before the release.
        assert!(!checkpoint.is_finished(), "the checkpoint returned while the close held its lock");
    }
    let _ = release.send(());
    let checkpointed = checkpoint.join().unwrap_or_else(|_| panic!("the checkpoint panicked"));
    closing.join().unwrap_or_else(|_| panic!("the close panicked"));
    drop(store);
    let store = open(home.path(), &journal);
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    let crashed = journal.restart(Crash::Os);
    drop(store);
    sync_model::os_crash(&home.path().join("sessions"));
    let store = open(home.path(), &crashed);
    assert_eq!(
        seqs(store.as_ref(), CHAT),
        vec![1, 2],
        "a checkpoint went past a log close whose sync was failing on another thread (it {} and returned {})",
        if waited { "waited for the close's note" } else { "did not wait for the close's note" },
        if checkpointed.is_ok() { "ok" } else { "an error" }
    );
    assert!(waited, "the checkpoint did not wait for the close's note");
}

// ---------------------------------------------------------------- the open's checkpoint in flight

/// A record whose long text a retention rewrite cuts (`store/compact.rs`).
fn long_line(seq: u64) -> EventRecord {
    EventRecord {
        seq,
        at: 1_000 + seq,
        dir: "in".into(),
        kind: "claude.assistant".into(),
        msg: json!({ "text": "x".repeat(8 * 1024) }),
        host_seq: None,
    }
}

/// The names in `journal-unapplied/` that start with `id`.
fn kept_aside(home: &Path, id: &str) -> Vec<String> {
    std::fs::read_dir(home.join("journal-unapplied"))
        .map(|entries| {
            entries
                .flatten()
                .map(|entry| entry.file_name().to_string_lossy().into_owned())
                .filter(|name| name.starts_with(id))
                .collect()
        })
        .unwrap_or_default()
}

/// A retention rewrite of a chat whose records are all checkpointed (retention takes a chat
/// untouched for days) runs no checkpoint of its own. Its caller holds the chat's append lock for
/// the commit (`hub/retention.rs`), so a checkpoint in flight, such as the one the checkpointer
/// runs right after a restart's replay (seconds with many chats), must not hold that lock: a
/// person's first message to that chat would wait for it.
#[test]
fn a_retention_rewrite_of_a_checkpointed_chat_does_not_wait_for_a_checkpoint() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(83);
    let store: Arc<dyn Store> = Arc::from(open(home.path(), &journal));
    store.append(CHAT, &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    store.append(CHAT, &long_line(2)).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    let staged = store
        .stage_compaction(CHAT, CompactMode::Write { archive: None })
        .unwrap_or_else(|e| panic!("{e:#}"))
        .unwrap_or_else(|| panic!("nothing to compact"));
    // A checkpoint in flight: chat-b's record waits in a 2 s sync, and the checkpoint for it.
    journal.set_sync_delay(Duration::from_secs(2));
    store.append("chat-b", &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    let flusher = {
        let store = Arc::clone(&store);
        std::thread::spawn(move || store.flush())
    };
    std::thread::sleep(Duration::from_millis(300));
    let started = std::time::Instant::now();
    let committed = store.commit_compaction(CHAT, staged).unwrap_or_else(|e| panic!("{e:#}"));
    let took = started.elapsed();
    journal.set_sync_delay(Duration::ZERO);
    flusher
        .join()
        .unwrap_or_else(|_| panic!("the flush panicked"))
        .unwrap_or_else(|e| panic!("{e:#}"));
    assert!(committed, "the rewrite was refused");
    assert!(
        took < Duration::from_millis(500),
        "the retention rewrite of a checkpointed chat waited {took:?} for a checkpoint in flight"
    );
}

/// The other way: a retention rewrite of a chat with a record past the checkpoint checkpoints
/// first, so a kill right after it replays no line the rewrite cut, and keeps no copy aside.
#[test]
fn a_retention_rewrite_of_a_chat_with_records_past_the_checkpoint_checkpoints_first() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(84);
    let store = open(home.path(), &journal);
    store.append(CHAT, &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    store.append(CHAT, &long_line(2)).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    let staged = store
        .stage_compaction(CHAT, CompactMode::Write { archive: None })
        .unwrap_or_else(|e| panic!("{e:#}"))
        .unwrap_or_else(|| panic!("nothing to compact"));
    assert!(store.commit_compaction(CHAT, staged).unwrap_or_else(|e| panic!("{e:#}")));
    let log = home.path().join("sessions").join(CHAT).join("events/000001.ndjson");
    let cut = std::fs::read(&log).unwrap_or_else(|e| panic!("{e}"));
    let killed = journal.restart(Crash::Process);
    drop(store);
    let store = open(home.path(), &killed);
    assert_eq!(seqs(store.as_ref(), CHAT), vec![1, 2]);
    assert!(
        std::fs::read(&log).unwrap_or_else(|e| panic!("{e}")) == cut,
        "a replay wrote lines a retention rewrite cut back into the log"
    );
    assert!(
        kept_aside(home.path(), CHAT).is_empty(),
        "a replay kept a rewritten chat's journaled lines aside: {:?}",
        kept_aside(home.path(), CHAT)
    );
}

/// The same after a restart: a chat the replay wrote has records past the checkpoint until the
/// checkpoint after the open, so its retention rewrite checkpoints first too. (A guard of the
/// outcome: the checkpointer may finish the open's checkpoint before the rewrite, and then the
/// rewrite needs none.)
#[test]
fn a_retention_rewrite_of_a_replayed_chat_checkpoints_first() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(85);
    let store = open(home.path(), &journal);
    store.append(CHAT, &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    store.append(CHAT, &long_line(2)).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    let killed = journal.restart(Crash::Process);
    drop(store);
    // The checkpoint after the open waits in a 2 s sync of chat-b's line: the replayed records
    // stay past the checkpoint while the rewrite runs.
    let store = open(home.path(), &killed);
    killed.set_sync_delay(Duration::from_secs(2));
    store.append("chat-b", &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    let staged = store
        .stage_compaction(CHAT, CompactMode::Write { archive: None })
        .unwrap_or_else(|e| panic!("{e:#}"))
        .unwrap_or_else(|| panic!("nothing to compact"));
    assert!(store.commit_compaction(CHAT, staged).unwrap_or_else(|e| panic!("{e:#}")));
    killed.set_sync_delay(Duration::ZERO);
    let log = home.path().join("sessions").join(CHAT).join("events/000001.ndjson");
    let cut = std::fs::read(&log).unwrap_or_else(|e| panic!("{e}"));
    let again = killed.restart(Crash::Process);
    drop(store);
    let store = open(home.path(), &again);
    assert_eq!(seqs(store.as_ref(), CHAT), vec![1, 2]);
    assert!(
        std::fs::read(&log).unwrap_or_else(|e| panic!("{e}")) == cut,
        "a replay wrote lines a retention rewrite cut back into the log"
    );
    assert!(
        kept_aside(home.path(), CHAT).is_empty(),
        "a replay kept a rewritten chat's journaled lines aside: {:?}",
        kept_aside(home.path(), CHAT)
    );
}

/// A journal restore takes back the seqs a restart's recovery wrote (`Store::truncate_after`,
/// review of #37284 at 4dcbe192, F1): the records past the cut go, and the records appended
/// after it at those seqs are read back, from this store and from one opened again.
#[test]
fn a_log_cut_back_takes_the_records_appended_after_it() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(11);
    let store = open(home.path(), &journal);
    for seq in 1..=20 {
        store.append(CHAT, &record(seq, "queued")).unwrap_or_else(|e| panic!("{e:#}"));
    }
    assert!(store.truncate_after(CHAT, 16).unwrap_or_else(|e| panic!("{e:#}")));
    assert_eq!(seqs(store.as_ref(), CHAT), (1..=16).collect::<Vec<_>>());
    for seq in 17..=30 {
        store.append(CHAT, &record(seq, "status")).unwrap_or_else(|e| panic!("{e:#}"));
    }
    store.flush_session(CHAT).unwrap_or_else(|e| panic!("{e:#}"));
    assert_eq!(seqs(store.as_ref(), CHAT), (1..=30).collect::<Vec<_>>());
    let kinds = |store: &dyn Store| {
        store.events(CHAT, 16, 100).unwrap().into_iter().map(|r| r.kind).collect::<Vec<_>>()
    };
    assert!(kinds(store.as_ref()).iter().all(|k| k == "status"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    let restarted = journal.restart(Crash::Process);
    drop(store);
    let store = open(home.path(), &restarted);
    assert_eq!(seqs(store.as_ref(), CHAT), (1..=30).collect::<Vec<_>>());
    assert!(kinds(store.as_ref()).iter().all(|k| k == "status"));
}

/// #41627 F1, the class: a test that holds a thread the store owns (the checkpointer's
/// `idle_hold` and `touch_hold`) releases it through `journal_store::Release` bound after the
/// store, never a bare `send` on the hold's sender. A bare sender bound before the store outlives
/// it on an unwind: a panic before the send (a `recv_timeout` that expired) drops the store first,
/// and its drop waits on the held thread forever, so a timeout becomes a hang. Scans every source
/// file of the crate.
#[test]
fn every_checkpointer_hold_is_released_by_a_guard_bound_after_the_store() {
    fn sources(dir: &Path, into: &mut Vec<PathBuf>) {
        let entries = std::fs::read_dir(dir).unwrap_or_else(|e| panic!("{}: {e}", dir.display()));
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                sources(&path, into);
            } else if path.extension().is_some_and(|ext| ext == "rs") {
                into.push(path);
            }
        }
    }
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
    let mut files = Vec::new();
    sources(&root, &mut files);
    // Built here, so this scan's own text is not an install.
    let installs = ["idle_hold", "touch_hold"].map(|seam| format!("{seam} = Some(("));
    let mut found = Vec::new();
    let mut checked = 0;
    for file in &files {
        let text = std::fs::read_to_string(file).unwrap_or_default();
        // One test (or helper) per top-level `fn`: the text up to the next one.
        for body in text.split("\nfn ").skip(1) {
            let body = body.split("\n}\n").next().unwrap_or(body);
            let held: Vec<&str> = installs
                .iter()
                .filter_map(|install| {
                    let at = body.find(install.as_str())?;
                    let pair = &body[at + install.len()..];
                    let release = pair.split(&[',', ')'][..]).nth(1)?.trim();
                    Some(release)
                })
                .collect();
            for receiver in held {
                checked += 1;
                let name = body.split('(').next().unwrap_or("?");
                // The sender that pairs with `receiver`: `let (sender, receiver) = ...channel()`.
                let sender = body.lines().find_map(|line| {
                    let pair = line.trim().strip_prefix("let (")?;
                    let (sender, rest) = pair.split_once(',')?;
                    let rest = rest.trim_start();
                    rest.strip_prefix(receiver)
                        .filter(|after| after.starts_with(')'))
                        .map(|_| sender.trim())
                });
                let Some(sender) = sender else {
                    found.push(format!(
                        "{}: {name}: no `let ({{sender}}, {receiver})` pair",
                        file.display()
                    ));
                    continue;
                };
                let guard = format!("Release::new({sender})");
                let store = body.find("let store");
                match (body.find(&guard), store) {
                    (Some(at), Some(store)) if at > store => {}
                    (Some(_), _) => found.push(format!(
                        "{}: {name}: `{guard}` is bound before the store",
                        file.display()
                    )),
                    (None, _) => found.push(format!(
                        "{}: {name}: the release `{sender}` is not a `Release` guard",
                        file.display()
                    )),
                }
            }
        }
    }
    assert!(checked >= 3, "the scan found {checked} checkpointer holds: it no longer sees them");
    assert!(found.is_empty(), "a hold a panic can leave unreleased:\n{}", found.join("\n"));
}

/// #41816 follow-up, the class: a test that waits for the code under test to reach a hold (an
/// `arrived`, `entered`, `copied` or `ready` signal, or the hold's own channel) waits with a
/// bound, `recv_timeout`, and panics naming what did not arrive. A bare blocking `recv` there
/// blocks forever when the code never reaches the hold (or keeps the sender alive), so a
/// regression becomes a hung run instead of a failure. Scans every test source of the crate:
/// the test-only files (`*tests.rs`, `*_bench.rs`, any `#[cfg(test)] mod name;`) and every
/// `#[cfg(test)] mod name { ... }` block, read as Rust tokens (#41842 review: never as text).
/// What it exempts, and why each ends, is `scan_test_waits`'s list. `ALLOWED` lists the other
/// unbounded waits, each with why it cannot hang.
#[test]
fn every_test_wait_on_a_hold_is_bounded() {
    /// `(file under src/, receiver, why it may block unbounded)`.
    const ALLOWED: &[(&str, &str, &str)] = &[
        (
            "agent_host/host/orphan.rs",
            "held",
            "the harness waiter's park: it ends when the test drops `release`",
        ),
        (
            "server/ack_latency_bench.rs",
            "outgoing",
            "the page's reader drains the served connection's output: it ends when the \
             connection drops `output`, and no test waits on it",
        ),
    ];
    fn sources(dir: &Path, into: &mut Vec<PathBuf>) {
        let entries = std::fs::read_dir(dir).unwrap_or_else(|e| panic!("{}: {e}", dir.display()));
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                sources(&path, into);
            } else if path.extension().is_some_and(|ext| ext == "rs") {
                into.push(path);
            }
        }
    }
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
    let mut paths = Vec::new();
    sources(&root, &mut paths);
    paths.sort();
    let mut files: Vec<(PathBuf, String)> = paths
        .iter()
        .map(|file| {
            let relative = file.strip_prefix(&root).unwrap_or(file).to_path_buf();
            (relative, std::fs::read_to_string(file).unwrap_or_default())
        })
        .collect();
    // A test module's `#[path]` may name a file outside `src/` (`tests/support/`): read it too.
    let CrateScan { checked, unread, unresolved, waits } = loop {
        let scan = scan_crate(&files);
        let more: BTreeMap<PathBuf, String> = scan
            .unresolved
            .iter()
            .flat_map(|(_, candidates)| candidates)
            .filter_map(|path| Some((path.clone(), std::fs::read_to_string(root.join(path)).ok()?)))
            .collect();
        if more.is_empty() {
            break scan;
        }
        files.extend(more);
    };
    let unresolved: Vec<String> = unresolved
        .iter()
        .map(|(file, candidates)| {
            let at: Vec<String> = candidates.iter().map(|p| p.display().to_string()).collect();
            format!("{file}: no file at {}", at.join(" or "))
        })
        .collect();
    assert!(
        unresolved.is_empty(),
        "a test module's `mod child;` resolves to no file:\n{}",
        unresolved.join("\n")
    );
    // #41842 review F1: a `}` in a raw string once cut hub/restart_resume.rs's test module
    // short at line 1143, hiding the tests after it. The scan reads it to its last test.
    let resume = files
        .iter()
        .find(|(path, _)| path == Path::new("hub/restart_resume.rs"))
        .map(|(_, text)| text)
        .expect("hub/restart_resume.rs is a source of the crate");
    let last_fn = resume.rfind("fn ").map_or(0, |at| resume[..at].lines().count());
    let mut modules = Modules::default();
    modules_in(lex(resume), Path::new(""), Path::new(""), false, &mut modules);
    let reached = modules
        .bodies
        .iter()
        .filter_map(|body| body.clone().into_iter().last())
        .map(|tt| tt.span().end().line)
        .max()
        .unwrap_or(0);
    assert!(
        last_fn > 1143 && reached >= last_fn,
        "the scan read hub/restart_resume.rs's test module to line {reached}, not its last \
         test at line {last_fn}"
    );
    let mut found = Vec::new();
    let mut allowed_seen = vec![false; ALLOWED.len()];
    for (path, wait) in waits {
        if let Some(i) = ALLOWED.iter().position(|(f, r, _)| *f == path && *r == wait.root) {
            allowed_seen[i] = true;
            continue;
        }
        found.push(format!("{path}:{}: `{}` has no bound", wait.line, wait.call));
    }
    assert!(checked >= 50, "the scan read {checked} test sources: it no longer sees them");
    assert!(
        unread.is_empty(),
        "a file declares a `#[cfg(test)] mod name {{` the scan read nothing of:\n{}",
        unread.join("\n")
    );
    for ((file, receiver, _), seen) in ALLOWED.iter().zip(allowed_seen) {
        assert!(seen, "ALLOWED lists `{receiver}` in {file}, which no longer waits there");
    }
    assert!(
        found.is_empty(),
        "a test waits on a hold with no bound; use `recv_timeout` and name what did not \
         arrive:\n{}",
        found.join("\n")
    );
}

fn ident(c: char) -> bool {
    c.is_ascii_alphanumeric() || c == '_'
}

/// Whether `text` writes a `#[cfg(test)] mod name {` header. Read as text on purpose, apart from
/// the scan, so it checks that the scan read every test module a file has.
fn declares_test_module(text: &str) -> bool {
    let attr = "#[cfg(test)]";
    text.match_indices(attr).any(|(at, _)| {
        let mut rest = text[at + attr.len()..].trim_start();
        // Other attributes may sit between it and the item.
        while rest.starts_with("#[") {
            rest = rest.split_once(']').map_or("", |(_, r)| r).trim_start();
        }
        let rest = rest.strip_prefix("pub(crate) ").or(rest.strip_prefix("pub ")).unwrap_or(rest);
        rest.strip_prefix("mod ").is_some_and(|module| {
            let head = module.find(|c: char| !ident(c)).unwrap_or(module.len());
            module[head..].trim_start().starts_with('{')
        })
    })
}

/// One blocking wait the bounded-wait scan judged unbounded.
#[derive(Debug)]
struct Wait {
    /// The call's line in the scanned text.
    line: usize,
    /// The receiver and the call (`self.gate.lock().unwrap().recv()`).
    call: String,
    /// The channel the receiver names: its last field or variable (`gate`).
    root: String,
}

/// What the scan read of one source: how many test ranges, and the waits in them.
struct TestScan {
    ranges: usize,
    waits: Vec<Wait>,
}

/// What the scan read of a crate's sources.
struct CrateScan {
    /// How many sources gave it test code.
    checked: usize,
    /// The files that declare a `#[cfg(test)] mod name {` it read nothing of.
    unread: Vec<String>,
    /// Each test module declared `mod child;` that no source is the file of: the file that
    /// declares it, and where its file may be.
    unresolved: Vec<(String, Vec<PathBuf>)>,
    /// Each unbounded wait, with its file.
    waits: Vec<(String, Wait)>,
}

/// The scan of a crate's sources, `(path under src/, text)`: which are test code, and the
/// unbounded waits in them. A pure function of the sources, so fixtures can feed it files. A
/// file is test code when its name says so (`*tests.rs`, `*_bench.rs`), when a module declared
/// `#[cfg(test)] mod name;` has its name, or when the module tree makes it one: a `mod child;`
/// that `#[cfg(test)]` declares, or that sits in test code (an inline `#[cfg(test)] mod tests
/// { mod child; }`, or a test file), resolved to its file as rustc does (`#[path]` too).
fn scan_crate(files: &[(PathBuf, String)]) -> CrateScan {
    let index: HashMap<&Path, usize> =
        files.iter().enumerate().map(|(i, (path, _))| (path.as_path(), i)).collect();
    let tokens: Vec<TokenStream> = files.iter().map(|(_, text)| lex(text)).collect();
    let mut drops: Vec<DropNames> = tokens.iter().map(DropNames::of).collect();
    let shadows = drops.iter().any(|d| d.items.contains("drop") || d.items.contains("mem"));
    for d in &mut drops {
        d.crate_shadows = shadows;
    }
    let modules_of = |i: usize, in_test: bool| {
        let (dir, base) = module_dirs(&files[i].0);
        let mut modules = Modules::default();
        modules_in(tokens[i].clone(), &dir, &base, in_test, &mut modules);
        modules
    };
    let named = |relative: &Path| {
        let stem = relative.file_stem().and_then(|s| s.to_str()).unwrap_or("");
        stem.ends_with("tests") || stem.ends_with("_bench")
    };
    let mut modules: Vec<Modules> =
        (0..files.len()).map(|i| modules_of(i, named(&files[i].0))).collect();
    // Modules declared `#[cfg(test)] mod name;`: files with that name only build under test.
    let test_names: HashSet<String> = modules.iter().flat_map(|m| m.names.clone()).collect();
    let mut whole: Vec<bool> = files
        .iter()
        .map(|(relative, _)| {
            named(relative)
                || relative.iter().any(|part| {
                    let part = part.to_str().unwrap_or("");
                    test_names.contains(part.strip_suffix(".rs").unwrap_or(part))
                })
        })
        .collect();
    let mut scan =
        CrateScan { checked: 0, unread: Vec::new(), unresolved: Vec::new(), waits: Vec::new() };
    // Each test file's own `mod child;` files are test files too, to any depth.
    let mut todo: Vec<usize> = (0..files.len()).collect();
    while let Some(i) = todo.pop() {
        if whole[i] && !named(&files[i].0) {
            modules[i] = modules_of(i, true);
        }
        for candidates in &modules[i].files {
            match candidates.iter().find_map(|path| index.get(path.as_path())) {
                Some(&child) if !whole[child] => {
                    whole[child] = true;
                    todo.push(child);
                }
                Some(_) => {}
                None => scan
                    .unresolved
                    .push((files[i].0.to_string_lossy().to_string(), candidates.clone())),
            }
        }
    }
    for (i, (relative, text)) in files.iter().enumerate() {
        let path = relative.to_string_lossy().to_string();
        let bodies = if whole[i] { vec![tokens[i].clone()] } else { modules[i].bodies.clone() };
        let file = waits_of(&bodies, &drops[i]);
        // The self-check: a file that writes a test module's header gives the scan its code.
        if !whole[i] && declares_test_module(text) && file.ranges == 0 {
            scan.unread.push(path.clone());
        }
        if file.ranges > 0 {
            scan.checked += 1;
        }
        scan.waits.extend(file.waits.into_iter().map(|wait| (path.clone(), wait)));
    }
    scan
}

/// Where a source's modules live: the folder its `mod child;` files sit in, and the folder its
/// top-level `#[path]` attributes are relative to.
fn module_dirs(relative: &Path) -> (PathBuf, PathBuf) {
    let parent = relative.parent().unwrap_or(Path::new("")).to_path_buf();
    let stem = relative.file_stem().and_then(|s| s.to_str()).unwrap_or("");
    let owns_folder = matches!(stem, "mod" | "lib" | "main") || parent == Path::new("bin");
    let dir = if owns_folder { parent.clone() } else { parent.join(stem) };
    (dir, parent)
}

/// What one source declares of the module tree.
#[derive(Default)]
struct Modules {
    /// Each `#[cfg(test)] mod name { ... }` body outside test code: the scan's ranges.
    bodies: Vec<TokenStream>,
    /// Each `mod child;` whose file is test code: where it may be, the first that exists.
    files: Vec<Vec<PathBuf>>,
    /// Each name declared `#[cfg(test)] mod name;` outside test code.
    names: Vec<String>,
}

/// The modules in `tokens`, at any depth. `dir` holds the `mod child;` files, `base` is what a
/// `#[path]` is relative to, and `in_test` says the tokens are test code already.
fn modules_in(tokens: TokenStream, dir: &Path, base: &Path, in_test: bool, out: &mut Modules) {
    let tts: Vec<TokenTree> = tokens.into_iter().collect();
    let mut i = 0;
    while i < tts.len() {
        // An item's outer attributes, then its visibility.
        let (mut j, mut test, mut path) = (i, false, None);
        while punct(tts.get(j), '#')
            && let Some(attr) = group(tts.get(j + 1), Delimiter::Bracket)
        {
            test |= is_cfg_test(attr);
            path = path.or_else(|| path_attr(attr));
            j += 2;
        }
        if word(tts.get(j), "pub") {
            j += 1;
            if group(tts.get(j), Delimiter::Parenthesis).is_some() {
                j += 1;
            }
        }
        if word(tts.get(j), "mod")
            && let Some(TokenTree::Ident(name)) = tts.get(j + 1)
        {
            let name = name.to_string();
            let test = in_test || test;
            if let Some(body) = group(tts.get(j + 2), Delimiter::Brace) {
                if test && !in_test {
                    out.bodies.push(body.stream());
                }
                let inner = path.as_ref().map_or_else(|| dir.join(&name), |p| base.join(p));
                modules_in(body.stream(), &inner, &inner, test, out);
                i = j + 3;
                continue;
            }
            if punct(tts.get(j + 2), ';') {
                if test {
                    out.files.push(match &path {
                        Some(p) => vec![normalize(&base.join(p))],
                        None => {
                            vec![dir.join(format!("{name}.rs")), dir.join(&name).join("mod.rs")]
                        }
                    });
                }
                if test && !in_test {
                    out.names.push(name);
                }
                i = j + 3;
                continue;
            }
        }
        if let TokenTree::Group(g) = &tts[i] {
            modules_in(g.stream(), dir, base, in_test, out);
        }
        i += 1;
    }
}

/// `path` with each `..` taken out against the folder before it; one that leaves `src/` keeps
/// its leading `..` (`#[path = "../../tests/support/held_turn.rs"]`).
fn normalize(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for part in path.components() {
        match part {
            std::path::Component::ParentDir
                if out
                    .components()
                    .next_back()
                    .is_some_and(|last| !matches!(last, std::path::Component::ParentDir)) =>
            {
                out.pop();
            }
            std::path::Component::CurDir => {}
            part => out.push(part),
        }
    }
    out
}

/// The file a `#[path = ...]` attribute names: its string literal's value as rustc reads it,
/// raw (`r"..."`, `r#"..."#`) or with escapes (#42023 review F2).
fn path_attr(attr: &proc_macro2::Group) -> Option<String> {
    let tts: Vec<TokenTree> = attr.stream().into_iter().collect();
    let [TokenTree::Ident(key), TokenTree::Punct(eq), TokenTree::Literal(lit)] = &tts[..] else {
        return None;
    };
    if key != "path" || eq.as_char() != '=' {
        return None;
    }
    match syn::Lit::new(lit.clone()) {
        syn::Lit::Str(path) => Some(path.value()),
        _ => None,
    }
}

fn is_cfg_test(attr: &proc_macro2::Group) -> bool {
    attr.stream().to_string().replace(' ', "") == "cfg(test)"
}

fn lex(text: &str) -> TokenStream {
    text.parse().unwrap_or_else(|e| panic!("the scan cannot lex a source: {e:?}"))
}

fn punct(tt: Option<&TokenTree>, c: char) -> bool {
    matches!(tt, Some(TokenTree::Punct(p)) if p.as_char() == c)
}

fn word(tt: Option<&TokenTree>, name: &str) -> bool {
    matches!(tt, Some(TokenTree::Ident(i)) if i == name)
}

fn group(tt: Option<&TokenTree>, delimiter: Delimiter) -> Option<&proc_macro2::Group> {
    match tt {
        Some(TokenTree::Group(g)) if g.delimiter() == delimiter => Some(g),
        _ => None,
    }
}

/// Whether a `::` starts at `k`.
fn path_sep(tts: &[TokenTree], k: usize) -> bool {
    matches!(tts.get(k), Some(TokenTree::Punct(p)) if p.as_char() == ':' && p.spacing() == Spacing::Joint)
        && punct(tts.get(k + 1), ':')
}

/// Whether the `>` at `k` ends a `->`.
fn arrow(tts: &[TokenTree], k: usize) -> bool {
    k > 0
        && matches!(&tts[k - 1], TokenTree::Punct(p) if p.as_char() == '-' && p.spacing() == Spacing::Joint)
}

/// The arguments of a call to `std::mem::drop` that starts at `k`, however the path is written:
/// `drop`, `mem::drop` (under `use std::mem;`), `std::mem::drop`, `core::mem::drop`, an alias,
/// with a leading `::` or a turbofish (`drop::<Sender<u8>>`) (#42023 review F1). The path is
/// resolved against what the source binds ([`DropNames`]), so a local `fn drop` or `mod mem`,
/// or another module's `drop`, is not it (#42081 review F1).
fn drop_call_at<'t>(
    tts: &'t [TokenTree],
    k: usize,
    drops: &DropNames,
) -> Option<&'t proc_macro2::Group> {
    let leading = path_sep(tts, k);
    let mut at = if leading { k + 2 } else { k };
    let mut segments = Vec::new();
    loop {
        let Some(TokenTree::Ident(name)) = tts.get(at) else { return None };
        segments.push(name.to_string());
        at += 1;
        if !path_sep(tts, at) || !matches!(tts.get(at + 2), Some(TokenTree::Ident(_))) {
            break;
        }
        at += 2;
    }
    if !drops.is_std_drop(leading, &segments) {
        return None;
    }
    // A turbofish: `::<` up to its matching `>`.
    if path_sep(tts, at) && punct(tts.get(at + 2), '<') {
        let mut depth = 0usize;
        at += 2;
        loop {
            match tts.get(at) {
                Some(TokenTree::Punct(p)) if p.as_char() == '<' => depth += 1,
                // `->` in a `Fn() -> T` closes nothing.
                Some(TokenTree::Punct(p)) if p.as_char() == '>' && !arrow(tts, at) => {
                    depth = depth.checked_sub(1)?;
                }
                Some(_) => {}
                None => return None,
            }
            at += 1;
            if depth == 0 {
                break;
            }
        }
    }
    group(tts.get(at), Delimiter::Parenthesis)
}

/// What one source binds the names of a drain's drop to, so a call counts only when it is
/// `std::mem::drop` or `core::mem::drop` (#42081 review F1): the prelude's `drop`, or an import
/// of either (`use std::mem;`, `use core::mem::drop;`, `use std::mem::drop as release;`). A free
/// `fn drop` or a `mod mem` the source declares shadows them, and so does a name it imports from
/// anywhere else. An import's `std` or `core` is the crate only when the path starts with `::` or
/// the source binds no `std` or `core` of its own (`use crate::fake as std;`, `mod std`: #42111
/// review F1). Read over the whole source rather than by scope, imports inside functions and
/// methods included (#42111 review F2), so a shadow anywhere in it counts against every drop
/// there: a drain it cannot place is flagged, never exempt. A definition or an import under a
/// `#[cfg(..)]` counts as a shadow too (#41970 review F1's class): the code this scans is test
/// code, and the gated one may be what that build runs.
#[derive(Default)]
struct DropNames {
    /// Each name a `use` binds, with each path it binds it to and whether that path starts
    /// with `::`.
    uses: HashMap<String, Vec<(bool, Vec<String>)>>,
    /// The free functions and the modules the source declares, at any depth: never an
    /// `impl`'s or a `trait`'s own methods (`impl Drop for Guard { fn drop(&mut self) {} }`),
    /// though what their bodies declare and import counts.
    items: HashSet<String>,
    /// The source imports a module whole (`use super::*`).
    globs: bool,
    /// Some source of the crate declares a free `fn drop` or a `mod mem`, which a glob may
    /// bring in over the prelude's.
    crate_shadows: bool,
}

impl DropNames {
    fn of(tokens: &TokenStream) -> Self {
        let mut names = Self::default();
        names.read(&tokens.clone().into_iter().collect::<Vec<_>>(), false);
        names
    }

    /// Reads `tts`; `methods` says they are an `impl`'s or a `trait`'s body, whose own `fn`s
    /// are methods and declare no name.
    fn read(&mut self, tts: &[TokenTree], methods: bool) {
        let mut k = 0;
        while k < tts.len() {
            if word(tts.get(k), "use") {
                let end = (k..tts.len()).find(|&e| punct(tts.get(e), ';')).unwrap_or(tts.len());
                let item: TokenStream = tts[k..(end + 1).min(tts.len())].iter().cloned().collect();
                if let Ok(item) = syn::parse2::<syn::ItemUse>(item) {
                    self.use_tree(item.leading_colon.is_some(), Vec::new(), &item.tree);
                }
                k = end + 1;
                continue;
            }
            if (word(tts.get(k), "mod") || (word(tts.get(k), "fn") && !methods))
                && let Some(TokenTree::Ident(name)) = tts.get(k + 1)
            {
                self.items.insert(name.to_string());
            }
            // An `impl` or a `trait` item: its body's own `fn`s are methods.
            if (word(tts.get(k), "impl") || word(tts.get(k), "trait"))
                && item_start(tts, k)
                && let Some(body) =
                    (k + 1..tts.len()).find(|&b| group(tts.get(b), Delimiter::Brace).is_some())
                && let Some(g) = group(tts.get(body), Delimiter::Brace)
            {
                self.read(&g.stream().into_iter().collect::<Vec<_>>(), true);
                k = body + 1;
                continue;
            }
            if let TokenTree::Group(g) = &tts[k] {
                self.read(&g.stream().into_iter().collect::<Vec<_>>(), false);
            }
            k += 1;
        }
    }

    fn use_tree(&mut self, leading: bool, mut prefix: Vec<String>, tree: &syn::UseTree) {
        match tree {
            syn::UseTree::Path(p) => {
                prefix.push(p.ident.to_string());
                self.use_tree(leading, prefix, &p.tree);
            }
            syn::UseTree::Name(n) => {
                if n.ident != "self" {
                    prefix.push(n.ident.to_string());
                }
                if let Some(name) = prefix.last().cloned() {
                    self.uses.entry(name).or_default().push((leading, prefix));
                }
            }
            syn::UseTree::Rename(r) => {
                if r.ident != "self" {
                    prefix.push(r.ident.to_string());
                }
                if r.rename != "_" {
                    self.uses.entry(r.rename.to_string()).or_default().push((leading, prefix));
                }
            }
            syn::UseTree::Glob(_) => self.globs = true,
            syn::UseTree::Group(g) => {
                for item in &g.items {
                    self.use_tree(leading, prefix.clone(), item);
                }
            }
        }
    }

    /// Whether the path `segments` (after a leading `::` when `leading`) names
    /// `std::mem::drop` or `core::mem::drop` here.
    fn is_std_drop(&self, leading: bool, segments: &[String]) -> bool {
        // A `std` or `core` root is the crate after a leading `::`, or when the source binds
        // no name of its own over it (`use std::{self, ..}` binds `std` to the crate itself).
        let rebound = |root: &str| {
            self.items.contains(root)
                || self.uses.get(root).is_some_and(|paths| paths.iter().any(|(_, p)| p != &[root]))
        };
        let root_is_crate = |leading: bool, root: &str| {
            matches!(root, "std" | "core") && (leading || !rebound(root))
        };
        let std_mem = |leading: bool, p: &[String]| {
            p.len() == 2 && root_is_crate(leading, &p[0]) && p[1] == "mem"
        };
        let std_drop = |leading: bool, p: &[String]| {
            p.len() == 3 && std_mem(leading, &p[..2]) && p[2] == "drop"
        };
        // What the source binds `name` to: `None` when it neither declares nor imports it.
        let bound = |name: &str, is: &dyn Fn(bool, &[String]) -> bool| -> Option<bool> {
            if self.items.contains(name) {
                return Some(false);
            }
            self.uses.get(name).map(|paths| paths.iter().all(|(l, p)| is(*l, p.as_slice())))
        };
        if leading {
            return std_drop(true, segments);
        }
        match segments {
            [_, _, _] => std_drop(false, segments),
            [module, last] => last == "drop" && bound(module.as_str(), &std_mem) == Some(true),
            [name] => bound(name.as_str(), &std_drop)
                .unwrap_or(name == "drop" && !(self.globs && self.crate_shadows)),
            _ => false,
        }
    }
}

/// Whether the keyword at `k` starts an item: the first token of a block, or after a `;`, a
/// block, an attribute or a qualifier (`pub`, `pub(crate)`, `unsafe`).
fn item_start(tts: &[TokenTree], k: usize) -> bool {
    let Some(prev) = k.checked_sub(1) else { return true };
    punct(tts.get(prev), ';')
        || group(tts.get(prev), Delimiter::Brace).is_some()
        || group(tts.get(prev), Delimiter::Bracket).is_some()
        || ["pub", "unsafe", "auto", "default"].iter().any(|w| word(tts.get(prev), w))
        || (group(tts.get(prev), Delimiter::Parenthesis).is_some()
            && word(prev.checked_sub(1).and_then(|p| tts.get(p)), "pub"))
}

/// The scan of one source, read as Rust tokens: strings, comments and macro bodies are what
/// the compiler sees them as. The test code is all of `text` for a test-only file, else each
/// `#[cfg(test)] mod name { ... }` body. A blocking `.recv()` or `.blocking_recv()` there is
/// exempt only for a reason it ends, from what the code does:
/// - a `.recv()` future that is `.await`ed, or is a whole argument of a timeout or join
///   (`timeout(d, rx.recv())`, `join!(a.recv(), b.recv())`); never a `.blocking_recv()`, which
///   blocks before any timeout sees it;
/// - a hold's park: the receiver itself (not an argument or another field on the way to it) is
///   named `release`, `release_rx`, `gate` or `go_rx`, and the test's sender drops on an unwind;
/// - a drain (`while let Some(n) = rx.recv()`) whose function makes the pair `let (tx, rx)`
///   and drops `tx` or closes `rx`, so the loop ends.
fn scan_test_waits(text: &str, whole: bool) -> TestScan {
    let tokens = lex(text);
    let drops = DropNames::of(&tokens);
    if whole {
        return waits_of(&[tokens], &drops);
    }
    let mut modules = Modules::default();
    modules_in(tokens, Path::new(""), Path::new(""), false, &mut modules);
    waits_of(&modules.bodies, &drops)
}

/// The unbounded waits in `bodies`, the test code of one source.
fn waits_of(bodies: &[TokenStream], drops: &DropNames) -> TestScan {
    let mut waits = Vec::new();
    for body in bodies {
        let tts: Vec<TokenTree> = body.clone().into_iter().collect();
        waits_in(&tts, None, &[], drops, &mut waits);
    }
    waits.sort_by_key(|wait| wait.line);
    TestScan { ranges: bodies.len(), waits }
}

/// The unbounded waits at one level of tokens and below. `callee` names the call or macro whose
/// arguments this level is (`timeout`, `assert_eq!`); `before` holds, for each enclosing level
/// of the innermost function, the tokens that run before this level is reached.
fn waits_in(
    tts: &[TokenTree],
    callee: Option<&str>,
    before: &[&[TokenTree]],
    drops: &DropNames,
    out: &mut Vec<Wait>,
) {
    const BOUNDS: &[&str] = &["timeout", "timeout_at", "join", "try_join", "join!", "try_join!"];
    const PARKS: &[&str] = &["release", "release_rx", "gate", "go_rx"];
    for (j, tt) in tts.iter().enumerate() {
        let TokenTree::Group(g) = tt else { continue };
        let inner: Vec<TokenTree> = g.stream().into_iter().collect();
        let called =
            match (j.checked_sub(2).and_then(|k| tts.get(k)), j.checked_sub(1).map(|k| &tts[k])) {
                (Some(TokenTree::Ident(name)), Some(TokenTree::Punct(p))) if p.as_char() == '!' => {
                    Some(format!("{name}!"))
                }
                (_, Some(TokenTree::Ident(name))) => Some(name.to_string()),
                _ => None,
            };
        let fn_body = g.delimiter() == Delimiter::Brace && is_fn_body(tts, j);
        let mut path: Vec<&[TokenTree]> = if fn_body { Vec::new() } else { before.to_vec() };
        if !fn_body {
            path.push(&tts[..j]);
        }
        waits_in(&inner, called.as_deref(), &path, drops, out);
    }
    for i in 0..tts.len() {
        let (Some(TokenTree::Ident(wait)), Some(args)) =
            (tts.get(i + 1), group(tts.get(i + 2), Delimiter::Parenthesis))
        else {
            continue;
        };
        let blocking = wait == "blocking_recv";
        if !punct(tts.get(i), '.') || !args.stream().is_empty() || !(blocking || wait == "recv") {
            continue;
        }
        let head = chain_start(tts, i);
        let awaited = punct(tts.get(i + 3), '.') && word(tts.get(i + 4), "await");
        let whole_argument = (head == 0 || punct(tts.get(head - 1), ','))
            && (i + 3 == tts.len() || punct(tts.get(i + 3), ','));
        let bounded = callee.is_some_and(|c| BOUNDS.contains(&c)) && whole_argument;
        if !blocking && (awaited || bounded) {
            continue;
        }
        let root = root_name(&tts[head..i]);
        let drained = while_let_at(tts, head).is_some_and(|at| {
            let mut path = before.to_vec();
            path.push(&tts[..at]);
            ended_before(&path, &root, drops)
        });
        if PARKS.contains(&root.as_str()) || drained {
            continue;
        }
        let call: TokenStream = tts[head..i + 3].iter().cloned().collect();
        out.push(Wait {
            line: wait.span().start().line,
            call: call.to_string().replace(' ', ""),
            root,
        });
    }
}

/// Where the receiver chain before the `.` at `dot` starts (`rx`, `self.gate.lock().unwrap()`).
fn chain_start(tts: &[TokenTree], dot: usize) -> usize {
    let mut head = dot;
    while head > 0 {
        let next = &tts[head];
        let links = matches!(next, TokenTree::Punct(p) if p.as_char() == '.' || p.as_char() == ':');
        let takes = match &tts[head - 1] {
            TokenTree::Punct(p) => p.as_char() == '.' || p.as_char() == ':',
            TokenTree::Ident(_) | TokenTree::Literal(_) => {
                links || group(Some(next), Delimiter::Parenthesis).is_some()
            }
            TokenTree::Group(g) => g.delimiter() == Delimiter::Parenthesis && links,
        };
        if !takes {
            break;
        }
        head -= 1;
    }
    head
}

/// The channel a receiver chain names: its last field or variable, past method calls
/// (`self.gate.lock().unwrap()` is `gate`, `pick(release)` is `pick`).
fn root_name(chain: &[TokenTree]) -> String {
    let segments: Vec<&[TokenTree]> = chain.split(|tt| punct(Some(tt), '.')).collect();
    let field = segments
        .iter()
        .rev()
        .find(|s| !s.is_empty() && !s.iter().any(|tt| matches!(tt, TokenTree::Group(_))));
    let segment = field.or(segments.last()).copied().unwrap_or(&[]);
    let mut names = segment.iter().filter_map(|tt| match tt {
        TokenTree::Ident(i) => Some(i.to_string()),
        _ => None,
    });
    let name = if field.is_some() { names.next_back() } else { names.next() };
    name.unwrap_or_else(|| "?".to_owned())
}

/// Where the `while` is when the chain starting at `head` is what a `while let PATTERN =`
/// matches.
fn while_let_at(tts: &[TokenTree], head: usize) -> Option<usize> {
    let eq = head.checked_sub(1)?;
    let alone = matches!(&tts[eq], TokenTree::Punct(p) if p.as_char() == '=' && p.spacing() == Spacing::Alone);
    let joined =
        eq > 0 && matches!(&tts[eq - 1], TokenTree::Punct(p) if p.spacing() == Spacing::Joint);
    if !alone || joined {
        return None;
    }
    for k in (1..eq).rev() {
        if punct(tts.get(k), ';') || group(tts.get(k), Delimiter::Brace).is_some() {
            return None;
        }
        if word(tts.get(k), "let") {
            return word(tts.get(k - 1), "while").then_some(k - 1);
        }
    }
    None
}

/// Whether the brace group at `j` is a function's body: `fn` heads its statement.
fn is_fn_body(tts: &[TokenTree], j: usize) -> bool {
    for k in (0..j).rev() {
        if punct(tts.get(k), ';') || group(tts.get(k), Delimiter::Brace).is_some() {
            return false;
        }
        if word(tts.get(k), "fn") {
            return true;
        }
    }
    false
}

/// Whether the channel `receiver` reads has ended before the `while let` that drains it starts.
/// `path` is what runs first, in order: for each enclosing block of the loop's function, its
/// tokens before the block the loop is in, then the loop's own block up to the loop. On that
/// path the pair `let (sender, receiver)` is made, and then a statement drops the sender
/// (`drop(tx)`, `std::mem::drop(tx)`: [`drop_call_at`]) or closes the receiver. A drop in the
/// loop, after it, in a block beside it or in a closure ends nothing the loop can count on
/// (#41961 review F1).
fn ended_before(path: &[&[TokenTree]], receiver: &str, drops: &DropNames) -> bool {
    let names = |pair: &proc_macro2::Group| -> Vec<String> {
        let tts: Vec<TokenTree> = pair.stream().into_iter().collect();
        tts.split(|tt| punct(Some(tt), ','))
            .map(|part| {
                let part: Vec<&TokenTree> =
                    part.iter().filter(|tt| !word(Some(*tt), "mut")).collect();
                match part[..] {
                    [TokenTree::Ident(name)] => name.to_string(),
                    _ => String::new(),
                }
            })
            .collect()
    };
    // A statement starts the block or follows a `;` or a block.
    let statement = |level: &[TokenTree], k: usize| {
        k == 0
            || punct(level.get(k - 1), ';')
            || group(level.get(k - 1), Delimiter::Brace).is_some()
    };
    let (mut sender, mut ended) = (None, false);
    for level in path {
        for k in 0..level.len() {
            if word(level.get(k), "let")
                && let Some(pair) = group(level.get(k + 1), Delimiter::Parenthesis)
                && let [tx, rx] = &names(pair)[..]
                && rx == receiver
                && !tx.is_empty()
            {
                // A new pair: what ended the last one does not end it.
                (sender, ended) = (Some(tx.clone()), false);
                continue;
            }
            let Some(tx) = &sender else { continue };
            if !statement(level, k) {
                continue;
            }
            let dropped =
                drop_call_at(level, k, drops).is_some_and(|args| names(args) == [tx.clone()]);
            let closed = word(level.get(k), receiver)
                && punct(level.get(k + 1), '.')
                && word(level.get(k + 2), "close");
            ended |= dropped || closed;
        }
    }
    ended
}

/// #41842 review F1/F2 and its two follow-ups, the class: the bounded-wait scan reads Rust as
/// tokens and exempts a wait only for a reason it ends, never by the text around it. Each row is
/// source the scan must judge; the fixtures spell each call `RECV`.
#[test]
fn the_bounded_wait_scan_exempts_by_meaning_not_text_shape() {
    /// `(shape, test source)`: waits nothing bounds. Each must be flagged.
    const FLAGGED: &[(&str, &str)] = &[
        (
            "F1: a while-let on a hold whose sender the test keeps",
            "let (tx, held) = std::sync::mpsc::channel::<()>();\n\
             start(tx.clone());\n\
             while let Ok(_) = held.RECV {}\n",
        ),
        (
            "F1: a while-let whose sender is dropped only in another test",
            "fn a() {\n    let (tx, rx) = channel::<()>();\n    while let Ok(_) = rx.RECV {}\n}\n\
             fn b() {\n    let (tx, rx) = channel::<()>();\n    drop(tx);\n}\n",
        ),
        (
            "F1 at 699228e4: a drain whose sender is dropped inside the loop",
            "let (tx, rx) = channel::<()>();\n\
             while let Ok(_) = rx.RECV {\n    drop(tx);\n}\n",
        ),
        (
            "F1 at 699228e4: a drain whose sender is dropped after the loop",
            "let (tx, rx) = channel::<()>();\n\
             while let Ok(_) = rx.RECV {}\n\
             drop(tx);\n",
        ),
        (
            "#42023 F1: a drain whose sender std::mem::drop drops after the loop",
            "let (tx, rx) = channel::<()>();\n\
             while let Ok(_) = rx.RECV {}\n\
             std::mem::drop(tx);\n",
        ),
        (
            "#42023 F1: a drain whose sender a qualified drop in a closure drops",
            "let (tx, rx) = channel::<()>();\n\
             let later = move || std::mem::drop(tx);\n\
             while let Ok(_) = rx.RECV {}\n",
        ),
        (
            "#42081 F1: a local `mod mem` whose drop forgets the sender",
            "mod mem {\n    pub fn drop<T>(t: T) {\n        std::mem::forget(t)\n    }\n}\n\
             let (tx, rx) = channel::<u8>();\n\
             mem::drop(tx);\n\
             while let Ok(n) = rx.RECV {}\n",
        ),
        (
            "#42081 F1: a local `fn drop` that forgets the sender",
            "fn drop<T>(t: T) {\n    std::mem::forget(t)\n}\n\
             let (tx, rx) = channel::<u8>();\n\
             drop(tx);\n\
             while let Ok(n) = rx.RECV {}\n",
        ),
        (
            "#42081 F1: a `drop` imported from another module",
            "use other::drop;\n\
             let (tx, rx) = channel::<u8>();\n\
             drop(tx);\n\
             while let Ok(n) = rx.RECV {}\n",
        ),
        (
            "#42081 F1: a `mem` imported from another crate",
            "use other::mem;\n\
             let (tx, rx) = channel::<u8>();\n\
             mem::drop(tx);\n\
             while let Ok(n) = rx.RECV {}\n",
        ),
        (
            "#42111 F1: std's drop imported through a std root the source rebinds",
            "use crate::fake as std;\n\
             use std::mem::drop as release_tx;\n\
             let (tx, rx) = channel::<u8>();\n\
             release_tx(tx);\n\
             while let Ok(n) = rx.RECV {}\n",
        ),
        (
            "#42111 F1: core's mem imported through a core root the source rebinds",
            "use self::fake as core;\n\
             use core::mem;\n\
             let (tx, rx) = channel::<u8>();\n\
             mem::drop(tx);\n\
             while let Ok(n) = rx.RECV {}\n",
        ),
        (
            "#42111 F1: a local `mod std` whose mem::drop forgets",
            "mod std {\n    pub mod mem {\n        pub fn drop<T>(t: T) {\n            \
             core::mem::forget(t)\n        }\n    }\n}\n\
             let (tx, rx) = channel::<u8>();\n\
             std::mem::drop(tx);\n\
             while let Ok(n) = rx.RECV {}\n",
        ),
        (
            "#42111 F2: a method-local `use std::mem::forget as drop`",
            "impl Probe {\n    fn t() {\n        use std::mem::forget as drop;\n        \
             let (tx, rx) = channel::<u8>();\n        drop(tx);\n        \
             while let Ok(n) = rx.RECV {}\n    }\n}\n",
        ),
        (
            "#41970 F1 (same class): a `#[cfg(test)] fn drop` that forgets shadows test code",
            "#[cfg(test)]\nfn drop<T>(t: T) {\n    std::mem::forget(t)\n}\n\
             let (tx, rx) = channel::<u8>();\n\
             drop(tx);\n\
             while let Ok(n) = rx.RECV {}\n",
        ),
        (
            "#41970 F1 (same class): a platform-gated `mod mem` may be the one that runs",
            "#[cfg(windows)]\nmod mem {\n    pub fn drop<T>(t: T) {\n        \
             std::mem::forget(t)\n    }\n}\n\
             let (tx, rx) = channel::<u8>();\n\
             mem::drop(tx);\n\
             while let Ok(n) = rx.RECV {}\n",
        ),
        (
            "#41970 F1 (same class): a platform-gated `use std::mem::forget as drop`",
            "#[cfg(target_os = \"linux\")]\nuse std::mem::forget as drop;\n\
             let (tx, rx) = channel::<u8>();\n\
             drop(tx);\n\
             while let Ok(n) = rx.RECV {}\n",
        ),
        (
            "#42023 F1: a drain whose sender another function's drop drops",
            "let (tx, rx) = channel::<()>();\n\
             other::drop(tx);\n\
             while let Ok(_) = rx.RECV {}\n",
        ),
        (
            "F1 at 699228e4: a drain whose sender a closure drops, not a statement",
            "let (tx, rx) = channel::<()>();\n\
             let later = move || drop(tx);\n\
             while let Ok(_) = rx.RECV {}\n",
        ),
        (
            "F1 at 699228e4: a drain whose sender a block beside it drops",
            "let (tx, rx) = channel::<()>();\n\
             if done {\n    drop(tx);\n}\n\
             while let Ok(_) = rx.RECV {}\n",
        ),
        ("F2: a call's argument", "consume(rx.RECV);\n"),
        ("F2: a value used by drop", "drop(rx.RECV);\n"),
        ("F2: a call's last argument after a comma", "consume(1, rx.RECV);\n"),
        ("F2: an assert! argument", "assert!(rx.RECV.is_ok());\n"),
        ("F2: a format! argument", "let shown = format!(\"{:?}\", rx.RECV);\n"),
        ("F2: an assert_eq! argument", "assert_eq!(arrived.RECV, Ok(()));\n"),
        ("F2: an assert_eq! second argument", "assert_eq!(Ok(()), arrived.RECV);\n"),
        ("F2: an assert_eq! with a message", "assert_eq!(arrived.RECV, Ok(()), \"arrived\");\n"),
        ("F2: a blocking_recv argument", "consume(rx.blocking_RECV);\n"),
        ("#41842 F2: a blocking_recv in assert!", "assert!(rx.blocking_RECV.is_some());\n"),
        ("#41842 F2: a blocking_recv in assert_eq!", "assert_eq!(rx.blocking_RECV, Some(1));\n"),
        ("#41842 F2: a recv as assert_eq!'s last argument", "assert_eq!(Ok(1), rx.RECV);\n"),
        ("#41842 F2: a recv in a matches! in assert!", "assert!(matches!(rx.RECV, Ok(_)));\n"),
        ("F2: a blocking_recv handed to a timeout", "timeout(d, rx.blocking_RECV);\n"),
        ("sweep: a comparison", "let same = arrived.RECV == Ok(());\n"),
        ("sweep: a call's argument inside a timeout", "consume(timeout(d, wrap(rx.RECV)));\n"),
        ("sweep: a select! arm with no timeout", "tokio::select! {\n    n = rx.RECV => n,\n}\n"),
        ("sweep: a park name in an argument, not the receiver", "pick(release).RECV.unwrap();\n"),
        ("sweep: a park name on another field", "self.release.held.RECV.unwrap();\n"),
    ];
    /// `(shape, file)`: a file's `#[cfg(test)]` module, which the scan must read (one range at
    /// least) and whose wait it must flag. The first three are the brace shapes that hid
    /// server/upload_frames.rs, forum.rs and hub/pool/spare.rs from 06f7b35a's scan.
    const MODULES: &[(&str, &str)] = &[
        (
            "F1': a `{` in a byte string (server/upload_frames.rs)",
            "fn live() {}\n#[cfg(test)]\nmod tests {\n    fn t() {\n        \
             let bad = b\"XXXX\\0\\0\\0\\x01{\";\n        arrived.RECV.unwrap();\n    }\n}\n",
        ),
        (
            "F1': a `{` in an escaped JSON string (forum.rs)",
            "#[cfg(test)]\nmod tests {\n    fn t() {\n        \
             f.write_all(b\"{\\\"type\\\":\\\"post\\\"\").unwrap();\n        \
             arrived.RECV.unwrap();\n    }\n}\n",
        ),
        (
            "F1': a `{` in a string (hub/pool/spare.rs)",
            "#[cfg(test)]\nmod tests {\n    fn t() {\n        \
             std::fs::write(&path, b\"{not json\").unwrap();\n        arrived.RECV.unwrap();\n    }\n}\n",
        ),
        (
            "F1': a `{` in a char and a comment",
            "#[cfg(test)]\nmod tests {\n    // an open `{`\n    fn t() {\n        \
             let open = '{';\n        arrived.RECV.unwrap();\n    }\n}\n",
        ),
        (
            "#41842 F1: a `}` in a string, a raw string and a comment (hub/restart_resume.rs)",
            "#[cfg(test)]\nmod tests {\n    fn t() {\n        let a = \"}\";\n        \
             let b = r#\"}\"#;\n        // }\n    }\n    fn u() {\n        \
             arrived.RECV.unwrap();\n    }\n}\n",
        ),
        (
            "F1': a `}` in a string closes nothing",
            "#[cfg(test)]\nmod tests {\n    fn t() {\n        \
             let close = \"}}\";\n    }\n    fn u() {\n        arrived.RECV.unwrap();\n    }\n}\n",
        ),
    ];
    /// `(shape, test source)`: waits that end on their own. None may be flagged.
    const EXEMPT: &[(&str, &str)] = &[
        (
            "F1: a real drain: the test drops the sender first",
            "let (tx, rx) = std::sync::mpsc::channel::<u8>();\n\
             tx.send(1).unwrap();\n\
             drop(tx);\n\
             while let Ok(n) = rx.RECV {\n    seen.push(n);\n}\n",
        ),
        (
            "F1: a real drain of a tokio channel the test closes",
            "let (mut tx, mut rx) = tokio::sync::mpsc::channel::<u8>(4);\n\
             rx.close();\n\
             while let Some(n) = rx.blocking_RECV {}\n",
        ),
        (
            "F1: a drain whose sender is dropped before the loop, in an enclosing block",
            "fn t() {\n    let (tx, rx) = channel::<u8>();\n    drop(tx);\n    \
             if go {\n        while let Ok(n) = rx.RECV {}\n    }\n}\n",
        ),
        (
            "#42023 F1: a drain whose sender std::mem::drop drops first",
            "let (tx, rx) = channel::<u8>();\n\
             std::mem::drop(tx);\n\
             while let Ok(n) = rx.RECV {}\n",
        ),
        (
            "#42023 F1: a drain whose sender core::mem::drop drops first",
            "let (tx, rx) = channel::<u8>();\n\
             ::core::mem::drop(tx);\n\
             while let Ok(n) = rx.RECV {}\n",
        ),
        (
            "#42023 F1: a drain whose sender mem::drop drops first, with `use std::mem;`",
            "use std::mem;\n\
             let (tx, rx) = channel::<u8>();\n\
             mem::drop(tx);\n\
             while let Ok(n) = rx.RECV {}\n",
        ),
        (
            "#42081 F1: std's drop imported under another name",
            "use std::mem::drop as release_tx;\n\
             let (tx, rx) = channel::<u8>();\n\
             release_tx(tx);\n\
             while let Ok(n) = rx.RECV {}\n",
        ),
        (
            "#42081 F1: std's mem imported under another name",
            "use std::mem as m;\n\
             let (tx, rx) = channel::<u8>();\n\
             m::drop(tx);\n\
             while let Ok(n) = rx.RECV {}\n",
        ),
        (
            "#42081 F1: core's drop imported by name",
            "use core::mem::drop;\n\
             let (tx, rx) = channel::<u8>();\n\
             drop(tx);\n\
             while let Ok(n) = rx.RECV {}\n",
        ),
        (
            "#42081 F1: a `Drop` impl's `fn drop` is a method, not a shadow of the prelude's",
            "impl Drop for Guard {\n    fn drop(&mut self) {}\n}\n\
             let (tx, rx) = channel::<u8>();\n\
             drop(tx);\n\
             while let Ok(n) = rx.RECV {}\n",
        ),
        (
            "#42111 F1: `::std::mem::drop` beside a rebound std root",
            "use crate::fake as std;\n\
             let (tx, rx) = channel::<u8>();\n\
             ::std::mem::drop(tx);\n\
             while let Ok(n) = rx.RECV {}\n",
        ),
        (
            "#42111 F1: `use ::std::mem::drop as release_tx` beside a rebound std root",
            "use crate::fake as std;\n\
             use ::std::mem::drop as release_tx;\n\
             let (tx, rx) = channel::<u8>();\n\
             release_tx(tx);\n\
             while let Ok(n) = rx.RECV {}\n",
        ),
        (
            "#42111 F2: a method-local `use std::mem`",
            "impl Probe {\n    fn t() {\n        use std::mem;\n        \
             let (tx, rx) = channel::<u8>();\n        mem::drop(tx);\n        \
             while let Ok(n) = rx.RECV {}\n    }\n}\n",
        ),
        (
            "#42023 F1: a drain whose sender a turbofish drop drops first",
            "let (tx, rx) = channel::<u8>();\n\
             std::mem::drop::<Sender<u8>>(tx);\n\
             while let Ok(n) = rx.RECV {}\n",
        ),
        ("F2: a tokio timeout", "let got = tokio::time::timeout(d, rx.RECV).await;\n"),
        (
            "F2: a tokio timeout across lines",
            "let got = tokio::time::timeout(\n    Duration::from_secs(5),\n    rx.RECV,\n)\n.await;\n",
        ),
        ("F2: a timeout_at", "let got = tokio::time::timeout_at(deadline, self.rx.RECV).await;\n"),
        (
            "F2: a timeout in a select! arm",
            "tokio::select! {\n    n = tokio::time::timeout(d, rx.RECV) => n,\n}\n",
        ),
        ("F2: a join! call", "let (a, b) = tokio::join!(left.RECV, right.RECV);\n"),
        ("F2: a join call", "let (a, b) = futures::future::join(left.RECV, right.RECV).await;\n"),
        ("an awaited future", "let line = rx.RECV.await;\n"),
        ("#41842 F2: an awaited future in assert_eq!", "assert_eq!(rx.RECV.await, Some(1));\n"),
        (
            "#41842 F2: an awaited future as assert_eq!'s last argument",
            "assert_eq!(Some(1), rx.RECV.await);\n",
        ),
        ("#41842 F2: an awaited future in assert!", "assert!(rx.RECV.await.is_some());\n"),
        ("a release park", "let _ = release.RECV;\n"),
        ("a release park behind a lock", "let _ = self.release.lock().unwrap().RECV;\n"),
        (
            "a release park in block_in_place",
            "let _ = tokio::task::block_in_place(|| release.blocking_RECV);\n",
        ),
        ("a release park across a line break", "release\n    .RECV\n    .unwrap();\n"),
        ("a gate park", "self.gate.lock().unwrap().RECV.unwrap();\n"),
        ("a comment naming a wait", "// waits on `rx.RECV` here\nlet x = 1;\n"),
        ("a string naming a wait", "let shown = \"rx.RECV\";\n"),
    ];
    let source = |text: &str| text.replace("RECV", "recv()");
    let mut wrong = Vec::new();
    for (shape, text) in FLAGGED {
        if scan_test_waits(&source(text), true).waits.is_empty() {
            wrong.push(format!("not flagged: {shape}"));
        }
    }
    for (shape, text) in MODULES {
        let scan = scan_test_waits(&source(text), false);
        if scan.ranges == 0 {
            wrong.push(format!("module not read: {shape}"));
        } else if scan.waits.is_empty() {
            wrong.push(format!("not flagged: {shape}"));
        }
    }
    for (shape, text) in EXEMPT {
        let waits = scan_test_waits(&source(text), true).waits;
        if !waits.is_empty() {
            let calls: Vec<&str> = waits.iter().map(|w| w.call.as_str()).collect();
            wrong.push(format!("flagged: {shape}: {calls:?}"));
        }
    }
    // F2 at 699228e4: a `mod child;` inside an inline `#[cfg(test)]` module is a test file, read
    // from where the module tree puts it (`#[path]` when given).
    type Files<'a> = &'a [(&'a str, &'a str)];
    let crates: &[(&str, Files<'_>)] = &[
        (
            "F2 at 699228e4: a child of an inline test module, by name",
            &[
                ("hub/foo.rs", "fn live() {}\n#[cfg(test)]\nmod tests {\n    mod child;\n}\n"),
                ("hub/foo/tests/child.rs", "fn t() {\n    arrived.RECV.unwrap();\n}\n"),
            ],
        ),
        (
            "F2 at 699228e4: a child of an inline test module in a mod.rs, as a folder",
            &[
                ("hub/mod.rs", "#[cfg(test)]\nmod checks {\n    mod deep;\n}\n"),
                ("hub/checks/deep/mod.rs", "fn t() {\n    arrived.RECV.unwrap();\n}\n"),
            ],
        ),
        (
            "F2 at 699228e4: a child of an inline test module, by #[path]",
            &[
                (
                    "hub/foo.rs",
                    "#[cfg(test)]\nmod tests {\n    #[path = \"probe.rs\"]\n    mod child;\n}\n",
                ),
                ("hub/foo/tests/probe.rs", "fn t() {\n    arrived.RECV.unwrap();\n}\n"),
            ],
        ),
        (
            "#42023 F2: a child of an inline test module, by a raw-string #[path]",
            &[
                (
                    "hub/foo.rs",
                    "#[cfg(test)]\nmod tests {\n    #[path = r\"raw.rs\"]\n    mod child;\n}\n",
                ),
                ("hub/foo/tests/raw.rs", "fn t() {\n    arrived.RECV.unwrap();\n}\n"),
            ],
        ),
        (
            "#42023 F2: a test file's child by a hashed raw-string #[path]",
            &[
                ("hub/foo_tests.rs", "#[path = r#\"support/hashed.rs\"#]\nmod held;\n"),
                ("hub/support/hashed.rs", "fn t() {\n    arrived.RECV.unwrap();\n}\n"),
            ],
        ),
        (
            "#42023 F2: a test file's child by an escaped #[path]",
            &[
                ("hub/foo_tests.rs", "#[path = \"support/\\x65scaped.rs\"]\nmod held;\n"),
                ("hub/support/escaped.rs", "fn t() {\n    arrived.RECV.unwrap();\n}\n"),
            ],
        ),
        (
            "F2: a test file's child by #[path] outside src/",
            &[
                ("hub/foo_tests.rs", "#[path = \"../../tests/support/held.rs\"]\nmod held;\n"),
                ("../tests/support/held.rs", "fn t() {\n    arrived.RECV.unwrap();\n}\n"),
            ],
        ),
        (
            "F2 at 699228e4: a grandchild of an inline test module",
            &[
                ("hub/foo.rs", "#[cfg(test)]\nmod tests {\n    mod child;\n}\n"),
                ("hub/foo/tests/child.rs", "mod grand;\n"),
                ("hub/foo/tests/child/grand.rs", "fn t() {\n    arrived.RECV.unwrap();\n}\n"),
            ],
        ),
    ];
    for (shape, files) in crates {
        let files: Vec<(PathBuf, String)> =
            files.iter().map(|(path, text)| (PathBuf::from(path), source(text))).collect();
        let child = files.last().map(|(path, _)| path.to_string_lossy().to_string());
        if !scan_crate(&files).waits.iter().any(|(path, _)| Some(path) == child.as_ref()) {
            wrong.push(format!("child file not read: {shape}"));
        }
    }
    assert!(wrong.is_empty(), "the bounded-wait scan judges by text shape:\n{}", wrong.join("\n"));
}

/// Production local storage is a [`JournalStore`] over a [`LocalStore`], so a [`Store`] method
/// the local store overrides and the journal store does not answers with the trait's default
/// there: a restore point's fold rescanned the log instead of the kind copies (review of #42837,
/// P2-F1), and a search read every record instead of the text copies. Each override of the local
/// store is forwarded, or named here with why the default stands.
#[test]
fn journal_store_forwards_every_local_store_override() {
    const DEFAULT_STANDS: &[&str] = &[];
    let root = concat!(env!("CARGO_MANIFEST_DIR"), "/src");
    let fns = |text: &str, from: &str| -> Vec<String> {
        let body = text.split(from).nth(1).unwrap_or_default();
        let body = body.split("\n}\n").next().unwrap_or_default();
        let names = body.lines().filter_map(|l| l.strip_prefix("    fn "));
        names.filter_map(|l| l.split(['(', '<']).next()).map(str::to_owned).collect()
    };
    let store = std::fs::read_to_string(format!("{root}/store.rs")).unwrap();
    let journal = std::fs::read_to_string(format!("{root}/store/journal_store.rs")).unwrap();
    let local = fns(&store, "impl Store for LocalStore {");
    let forwarded = fns(&journal, "impl Store for JournalStore {");
    assert!(local.len() > 20 && forwarded.len() > 20, "the scan read no methods");
    let missing: Vec<&String> = local
        .iter()
        .filter(|m| !forwarded.contains(m) && !DEFAULT_STANDS.contains(&m.as_str()))
        .collect();
    assert!(missing.is_empty(), "JournalStore does not forward: {missing:?}");
    let stale: Vec<&&str> =
        DEFAULT_STANDS.iter().filter(|m| forwarded.iter().any(|f| f == *m)).collect();
    assert!(stale.is_empty(), "forwarded now, take them out of DEFAULT_STANDS: {stale:?}");
}
