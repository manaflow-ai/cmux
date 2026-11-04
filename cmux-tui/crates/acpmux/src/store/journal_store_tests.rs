//! The event log through the journal (`store.journal`, R-DURABILITY S2; DESIGN.md 3.3b): a line
//! the store says is durable survives an OS crash, a kill keeps every line once, and a chat that
//! was deleted stays deleted.
//!
//! The journal runs on a simulated file system (`cmux_journal::SimStorage`), so a crash keeps
//! exactly what a real one would. The chat logs (`sessions/<id>/events/*.ndjson`) are real files
//! in a temporary folder; an OS crash of them is modelled as the worst case: every log file goes
//! back to its length at the last `flush` (the kernel lost every write since).

use super::journal_store::{FencedStorage, HOLD_BEFORE_FREEZE, JournalStore, STOP_AFTER_CUT};
use super::log_sync::FAIL_NEXT_LOG_SYNC;
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

// ---------------------------------------------------------------- review of #35400 (S2c)

/// F1: a read that shows a line returns only once that line's record is appended, so the reply
/// built from it raises its connection's gate to that record. Before, a read saw the log line
/// between the log write and the record, and the reply went out with no wait for it.
#[test]
fn a_read_that_shows_a_line_covers_its_record() {
    use super::journal_store::PAUSE_AFTER_LOG_WRITE;
    use std::sync::atomic::Ordering;
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(47);
    let store: Arc<dyn Store> = Arc::from(open(home.path(), &journal));
    let durability = store.durability().unwrap_or_else(|| panic!("no durability"));
    store.append(CHAT, &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    let (arrived_tx, arrived) = std::sync::mpsc::channel();
    let (release, release_rx) = std::sync::mpsc::channel();
    *PAUSE_AFTER_LOG_WRITE.lock().unwrap_or_else(|e| e.into_inner()) =
        Some((arrived_tx, release_rx));
    let appender = {
        let store = Arc::clone(&store);
        std::thread::spawn(move || store.append(CHAT, &record(2, "queued")))
    };
    arrived.recv_timeout(WAIT).unwrap_or_else(|e| panic!("the append never paused: {e}"));
    let reader = {
        let store = Arc::clone(&store);
        let acked = Arc::clone(&durability.acked);
        std::thread::spawn(move || {
            let seen = seqs(store.as_ref(), CHAT);
            (seen, acked.load(Ordering::SeqCst))
        })
    };
    std::thread::sleep(Duration::from_millis(200));
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

// ---------------------------------------------------------------- review of #35866: a checkpoint and a freeze

/// The reviewer's test (review of #35866, finding 2's base part): a checkpoint in flight when a
/// log sync fails on another thread (a request's `flush_session`; the store freezes). The
/// checkpoint checked `frozen` only at its start, went on, and its own sync of that log may
/// report success for the pages the failed sync dropped: it must not retire the line's record.
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
    // A checkpoint in flight: it waits in a 2 s sync of chat-b's record.
    journal.set_sync_delay(Duration::from_secs(2));
    store.append("chat-b", &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    let flusher = {
        let store = Arc::clone(&store);
        std::thread::spawn(move || store.flush())
    };
    std::thread::sleep(Duration::from_millis(300));
    FAIL_NEXT_LOG_SYNC.with(|fail| fail.set(true));
    let failed = store.flush_session(CHAT);
    FAIL_NEXT_LOG_SYNC.with(|fail| fail.set(false));
    journal.set_sync_delay(Duration::ZERO);
    assert!(failed.is_err(), "flush_session's sync did not fail as the test asked");
    let in_flight = flusher.join().unwrap_or_else(|_| panic!("the flush panicked"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
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
/// store yet when a checkpoint runs. The checkpoint must not retire the line's record either.
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
    // A checkpoint now, while that failure is not recorded yet.
    let checkpointed = store.flush();
    let _ = release.send(());
    let failed = failing.join().unwrap_or_else(|_| panic!("the failing thread panicked"));
    assert!(failed.is_err(), "flush_session's sync did not fail as the test asked");
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
        "a checkpoint went past a sync that was failing on another thread (it returned {})",
        if checkpointed.is_ok() { "ok" } else { "an error" }
    );
}
