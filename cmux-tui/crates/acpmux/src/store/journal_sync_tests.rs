//! The journal store's rule for a failed sync (R-DURABILITY; #35905): a failed sync of a file or
//! folder under the store's home freezes the store, as a failed log sync does. A later sync of
//! the same file or folder may report success for what the failed one dropped, so no checkpoint
//! may go past it: the journal keeps every line, and the daemon stops for a restart that writes
//! them again.

use super::log_sync::FAIL_DIR_SYNC_WHEN;
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

/// A chat whose log a retention rewrite cuts (a long line), durable, and the rewrite staged.
fn staged_rewrite(store: &dyn Store) -> Staged {
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
    store
        .stage_compaction(CHAT, CompactMode::Write { archive: None })
        .unwrap_or_else(|e| panic!("{e:#}"))
        .unwrap_or_else(|| panic!("nothing to compact"))
}

/// Whether a rewritten copy of a segment still waits in `events` for its rename.
fn renames_pending(events: &Path) -> bool {
    std::fs::read_dir(events)
        .into_iter()
        .flatten()
        .flatten()
        .any(|entry| entry.file_name().to_string_lossy().ends_with(".compact"))
}

fn renames_done(events: &Path) -> bool {
    !renames_pending(events)
}

fn stop_asked(store: &dyn Store) -> bool {
    store.stop_reason().is_some_and(|reason| reason.borrow().is_some())
}

/// A retention rewrite whose sync of the chat's `events` folder after the renames fails: the
/// renames' entries may be lost, and a later sync of `events` may report success without them,
/// so a line appended to a rewritten segment would be lost by an OS crash after a checkpoint
/// retired its record. The store freezes: no checkpoint goes on, and the restart writes the
/// lines again.
#[test]
fn a_failed_sync_of_a_rewritten_log_folder_freezes_the_store() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(201);
    let store = open(home.path(), &journal);
    let staged = staged_rewrite(store.as_ref());
    let events = home.path().join("sessions").join(CHAT).join("events");
    FAIL_DIR_SYNC_WHEN.with(|fail| *fail.borrow_mut() = Some((events.clone(), renames_done)));
    let committed = store.commit_compaction(CHAT, staged);
    FAIL_DIR_SYNC_WHEN.with(|fail| *fail.borrow_mut() = None);
    assert!(committed.is_err(), "the rewrite did not report its failed folder sync");
    // A line after the rewrite, in the rewritten segment.
    store.append(CHAT, &record(3, "queued")).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    assert!(
        store.flush().is_err(),
        "a checkpoint went past a failed sync of a rewritten log's folder"
    );
    assert!(stop_asked(store.as_ref()), "the store did not ask the daemon to stop");
    let killed = journal.restart(Crash::Process);
    drop(store);
    let store = open(home.path(), &killed);
    assert_eq!(seqs(store.as_ref(), CHAT), vec![1, 2, 3], "the restart lost a line");
}

/// A retention rewrite whose record (`events/compacted.json`, written before the renames so that
/// a log that may hold nothing never passes for a purged chat's) fails the sync of its folder:
/// the rewrite must not go on to its renames, and the store freezes.
#[test]
fn a_failed_sync_of_a_rewrite_record_folder_freezes_the_store() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(202);
    let store = open(home.path(), &journal);
    let staged = staged_rewrite(store.as_ref());
    let events = home.path().join("sessions").join(CHAT).join("events");
    FAIL_DIR_SYNC_WHEN.with(|fail| *fail.borrow_mut() = Some((events.clone(), renames_pending)));
    let committed = store.commit_compaction(CHAT, staged);
    FAIL_DIR_SYNC_WHEN.with(|fail| *fail.borrow_mut() = None);
    assert!(committed.is_err(), "the rewrite went on past a failed sync of its record's folder");
    assert!(
        renames_pending(&events),
        "the rewrite renamed segments after its record failed to sync"
    );
    assert!(
        store.flush().is_err(),
        "a checkpoint went past a failed sync of a rewrite record's folder"
    );
    assert!(stop_asked(store.as_ref()), "the store did not ask the daemon to stop");
    let killed = journal.restart(Crash::Process);
    drop(store);
    let store = open(home.path(), &killed);
    assert_eq!(seqs(store.as_ref(), CHAT), vec![1, 2], "the restart lost a line");
}
