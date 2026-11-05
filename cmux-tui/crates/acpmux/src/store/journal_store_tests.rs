//! The event log through the journal (`store.journal`, R-DURABILITY S2; DESIGN.md 3.3b): a line
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

// ------------------------------------------------- review of #34901 (FIX at ab0e9535d9da)

/// A store with the switch off on `home` (the logs alone).
fn open_off(home: &Path) -> Box<dyn Store> {
    super::open(&StoreConfig::default(), home).unwrap_or_else(|e| panic!("open the store: {e:#}"))
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

/// Finding 1a: a kill with the switch on, a run with it off, then the switch on again.
#[test]
fn lines_written_with_the_switch_off_survive_turning_it_on_again() {
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
    let off = open_off(home.path());
    for seq in 6..=9 {
        off.append(CHAT, &record(seq, "queued")).unwrap_or_else(|e| panic!("{e:#}"));
    }
    off.flush().unwrap_or_else(|e| panic!("{e:#}"));
    drop(off);
    let store = open(home.path(), &killed);
    assert_eq!(
        seqs(store.as_ref(), CHAT),
        (1..=9).collect::<Vec<_>>(),
        "the lines written with the switch off are gone"
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

/// Switch off after a crash with it on: the start with the switch off writes the journal's lines
/// that the logs lost back first, so every acknowledged line is there (the catch-up of DESIGN.md
/// 3.6).
#[test]
fn switching_off_after_a_crash_keeps_every_acknowledged_line() {
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
    let off = open_off(home.path());
    assert_eq!(seqs(off.as_ref(), CHAT), (1..=5).collect::<Vec<_>>());
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
    // The restart replays 2..5 and its first checkpoint runs.
    let store = open(home.path(), &killed);
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
    // The daemon stops for a restart (no crash), and the restart's first checkpoint runs.
    drop(store);
    let store = open(home.path(), &journal);
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
    idle_release.send(()).unwrap_or_else(|e| panic!("{e}"));
    touch_release.send(()).unwrap_or_else(|e| panic!("{e}"));
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
/// checkpoint kept every chat's records past it, so a start with the switch off replayed them
/// again, a retention rewrite came undone, and the journal grew with each restart.)
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
