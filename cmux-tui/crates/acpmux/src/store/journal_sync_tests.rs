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

/// The rewrite's first record is in place and its renames have not run: the sync of the record's
/// folder, and no other (a checkpoint's sync of the log's folder before the rewrite finds no
/// record yet).
fn record_written_renames_pending(events: &Path) -> bool {
    renames_pending(events) && events.join(super::compact::MARKER).exists()
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
/// the rewrite must not go on to its renames, and the store freezes. Before the fix the record's
/// folder sync was `config::write_atomic`'s own, whose result it drops, so the rewrite went on.
#[test]
fn a_failed_sync_of_a_rewrite_record_folder_freezes_the_store() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(202);
    let store = open(home.path(), &journal);
    let staged = staged_rewrite(store.as_ref());
    let events = home.path().join("sessions").join(CHAT).join("events");
    let segment = events.join("000001.ndjson");
    let before = std::fs::read(&segment).unwrap_or_else(|e| panic!("{e}"));
    FAIL_DIR_SYNC_WHEN
        .with(|fail| *fail.borrow_mut() = Some((events.clone(), record_written_renames_pending)));
    let committed = store.commit_compaction(CHAT, staged);
    FAIL_DIR_SYNC_WHEN.with(|fail| *fail.borrow_mut() = None);
    assert!(committed.is_err(), "the rewrite went on past a failed sync of its record's folder");
    // A failed commit drops its staged copies (`Staged`'s drop), so the segment itself tells
    // whether a rename ran.
    let after = std::fs::read(&segment).unwrap_or_else(|e| panic!("{e}"));
    assert!(after == before, "the rewrite renamed a segment after its record failed to sync");
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

fn meta(id: &str, name: &str) -> SessionMeta {
    serde_json::from_value(json!({
        "schema": META_SCHEMA,
        "id": id,
        "name": name,
        "harness": "claude",
        "family": "claude",
        "cwd": "/tmp",
        "status": "idle",
        "createdAt": 1,
        "updatedAt": 1,
        "lastSeq": 0,
    }))
    .unwrap_or_else(|e| panic!("a test meta: {e}"))
}

/// The names in `journal-unapplied/`.
fn kept(home: &Path) -> Vec<String> {
    std::fs::read_dir(home.join("journal-unapplied"))
        .map(|entries| {
            entries
                .flatten()
                .map(|entry| entry.file_name().to_string_lossy().into_owned())
                .collect()
        })
        .unwrap_or_default()
}

/// A checkpoint keeps aside the metadata image of a chat whose folder code outside the store
/// replaced (a transfer's swap), and the sync of `journal-unapplied/` fails: the kept file's
/// entry may be lost, and a later sync of that folder may report success without it. The
/// checkpoint must not retire the image's record, and the store freezes; the restart keeps the
/// image aside again.
#[test]
fn a_failed_sync_of_a_kept_aside_image_freezes_the_store() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(203);
    let store = open(home.path(), &journal);
    store.save(&meta(CHAT, "old")).unwrap_or_else(|e| panic!("{e:#}"));
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    store.save(&meta(CHAT, "old-renamed")).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    // A transfer's swap: the live folder aside, another chat's folder in its place.
    let sessions = home.path().join("sessions");
    std::fs::rename(sessions.join(CHAT), sessions.join(format!(".{CHAT}.replacement-backup")))
        .unwrap_or_else(|e| panic!("{e}"));
    std::fs::create_dir(sessions.join(CHAT)).unwrap_or_else(|e| panic!("{e}"));
    let unapplied = home.path().join("journal-unapplied");
    super::log_sync::FAIL_DIR_SYNC.with(|fail| *fail.borrow_mut() = Some(unapplied));
    let failed = store.flush();
    super::log_sync::FAIL_DIR_SYNC.with(|fail| *fail.borrow_mut() = None);
    assert!(failed.is_err(), "the checkpoint did not report its failed folder sync");
    // The next checkpoint writes the file again and syncs the folder again, and that sync may
    // report success without the entry the failed one dropped: it must not go on and retire the
    // image's record.
    assert!(
        store.flush().is_err(),
        "a checkpoint went past a failed sync of the folder that keeps an image aside"
    );
    assert!(stop_asked(store.as_ref()), "the store did not ask the daemon to stop");
    // The kept file's entry is lost (an OS crash after the failed sync); the restart must keep
    // the image aside again from the journal.
    for name in kept(home.path()) {
        std::fs::remove_file(home.path().join("journal-unapplied").join(name))
            .unwrap_or_else(|e| panic!("{e}"));
    }
    let killed = journal.restart(Crash::Process);
    drop(store);
    let _store = open(home.path(), &killed);
    assert!(
        kept(home.path()).iter().any(|name| name.ends_with(".session.json")),
        "the restart lost the kept-aside image: {:?}",
        kept(home.path())
    );
}
