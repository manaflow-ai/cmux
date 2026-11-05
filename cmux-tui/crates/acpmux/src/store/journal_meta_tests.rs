//! Chat metadata through the event journal (`store.journal`, R-DURABILITY S3; DESIGN.md 3.3e): a
//! metadata change is a journal record, `session.json` is what a checkpoint writes from it, and a
//! crash at any point leaves the metadata and the log in step.
//!
//! The journal runs on `cmux_journal::SimStorage`; the chat logs are real files whose OS crash
//! follows the syncs that ran (`store/sync_model.rs`).

use super::journal_store::{FORCE_FROZEN_BACKLOG, HOLD_AFTER_START, HOLD_BEFORE_FROZEN_RECORD};
use super::log_sync::{FAIL_NEXT_LOG_SYNC, NOTE_BEFORE_SYNCS_WAIT};
use super::sync_model;
use super::*;
use cmux_journal::{Crash, SimStorage};
use serde_json::json;
use std::os::unix::fs::PermissionsExt;
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

fn meta(id: &str, name: &str, last_seq: u64) -> SessionMeta {
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
        "lastSeq": last_seq,
    }))
    .unwrap_or_else(|e| panic!("a test meta: {e}"))
}

/// A line the daemon logs itself (`Ack`).
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

/// An agent chunk (`Stream`: synced with the next acknowledged record or a second later).
fn chunk(seq: u64) -> EventRecord {
    EventRecord {
        seq,
        at: 1_000 + seq,
        dir: "in".into(),
        kind: "agent_message_chunk".into(),
        msg: json!({ "method": "session/update", "params": { "n": seq } }),
        host_seq: None,
    }
}

fn seqs(store: &dyn Store, id: &str) -> Vec<u64> {
    let events = store.events(id, 0, 10_000).unwrap_or_else(|e| panic!("read {id}: {e:#}"));
    events.iter().map(|record| record.seq).collect()
}

fn session_json(home: &Path, id: &str) -> Option<Value> {
    let bytes = std::fs::read(home.join("sessions").join(id).join("session.json")).ok()?;
    serde_json::from_slice(&bytes).ok()
}

/// E13: the metadata a turn's end saves names the chat's last line. After an OS crash the
/// metadata must never name a line the log lost: on the code before S3, `session.json` was synced
/// at once while the agent's lines waited for the journal's next sync.
#[test]
fn last_seq_never_passes_the_log_after_an_os_crash() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(50);
    let store = open(home.path(), &journal);
    store.save(&meta(CHAT, "chat", 0)).unwrap_or_else(|e| panic!("{e:#}"));
    store.append(CHAT, &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    for seq in 2..=6 {
        store.append(CHAT, &chunk(seq)).unwrap_or_else(|e| panic!("{e:#}"));
    }
    store.save(&meta(CHAT, "chat", 6)).unwrap_or_else(|e| panic!("{e:#}"));
    // An OS crash now, before the journal's next sync.
    let crashed = journal.restart(Crash::Os);
    drop(store);
    sync_model::os_crash(&home.path().join("sessions"));
    let store = open(home.path(), &crashed);
    let last_line = seqs(store.as_ref(), CHAT).last().copied().unwrap_or(0);
    let last_seq = store
        .load(CHAT)
        .unwrap_or_else(|e| panic!("{e:#}"))
        .unwrap_or_else(|| panic!("the chat is gone"))
        .last_seq;
    assert!(
        last_seq <= last_line,
        "the metadata names line {last_seq}, the log ends at {last_line}"
    );
}

/// A metadata change does not write `session.json` on the request path (no file sync per
/// change): the store answers with the change at once, and the next checkpoint writes the file.
#[test]
fn a_metadata_change_is_written_to_session_json_by_the_checkpoint() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(52);
    let store = open(home.path(), &journal);
    store.save(&meta(CHAT, "before", 0)).unwrap_or_else(|e| panic!("{e:#}"));
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    store.save(&meta(CHAT, "after", 0)).unwrap_or_else(|e| panic!("{e:#}"));
    let on_disk = session_json(home.path(), CHAT).map(|value| value["name"].clone());
    assert_eq!(on_disk, Some(json!("before")), "session.json was written on the request path");
    let loaded = store.load(CHAT).unwrap_or_else(|e| panic!("{e:#}")).map(|meta| meta.name);
    assert_eq!(loaded.as_deref(), Some("after"), "a read missed a change before its checkpoint");
    let listed: Vec<String> = store
        .list()
        .unwrap_or_else(|e| panic!("{e:#}"))
        .into_iter()
        .filter(|meta| meta.id == CHAT)
        .map(|meta| meta.name)
        .collect();
    assert_eq!(listed, vec!["after".to_owned()], "the list missed a change before its checkpoint");
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    let on_disk = session_json(home.path(), CHAT).map(|value| value["name"].clone());
    assert_eq!(on_disk, Some(json!("after")), "the checkpoint did not write session.json");
}

/// A chat made before the checkpoint and deleted is not made again by a replay, even when the
/// crash took its `forget` back (the delete was not acknowledged; S2's rule for folders).
#[test]
fn a_chat_made_before_the_checkpoint_and_deleted_is_not_made_again() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(53);
    let store = open(home.path(), &journal);
    store.save(&meta(CHAT, "chat", 0)).unwrap_or_else(|e| panic!("{e:#}"));
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    store.save(&meta(CHAT, "renamed", 0)).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    journal.set_sync_delay(Duration::from_secs(2));
    // The writer is in chat-b's 2 s sync: the `forget` waits in memory.
    store.append("chat-b", &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    std::thread::sleep(Duration::from_millis(300));
    store.delete(CHAT).unwrap_or_else(|e| panic!("{e:#}"));
    // A kill now: the folder is gone and the `forget` record is lost.
    let killed = journal.restart(Crash::Process);
    killed.set_sync_delay(Duration::ZERO);
    drop(store);
    let store = open(home.path(), &killed);
    assert!(
        store.load(CHAT).unwrap_or_else(|e| panic!("{e:#}")).is_none(),
        "a deleted chat came back"
    );
    assert!(!home.path().join("sessions").join(CHAT).exists(), "the replay made the folder again");
}

/// A checkpoint writes a metadata image only once its record is durable (it waits for the
/// journal's sync on its own thread), and the replay never writes an older image over a newer
/// `session.json`.
#[test]
fn the_replay_never_writes_an_older_image_over_session_json() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(54);
    let store = open(home.path(), &journal);
    store.save(&meta(CHAT, "one", 0)).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    journal.set_sync_delay(Duration::from_secs(1));
    // The writer takes "two" into a 1 s sync; "three" waits for the next one.
    store.save(&meta(CHAT, "two", 0)).unwrap_or_else(|e| panic!("{e:#}"));
    std::thread::sleep(Duration::from_millis(300));
    store.save(&meta(CHAT, "three", 0)).unwrap_or_else(|e| panic!("{e:#}"));
    // The checkpoint waits until "three" is durable, then writes it.
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    let crashed = journal.restart(Crash::Os);
    crashed.set_sync_delay(Duration::ZERO);
    drop(store);
    let store = open(home.path(), &crashed);
    let name = store.load(CHAT).unwrap_or_else(|e| panic!("{e:#}")).map(|meta| meta.name);
    assert_eq!(name.as_deref(), Some("three"), "the replay wrote an older image over a newer one");
}

// ---------------------------------------------------------------- folders handed out of the store

/// Code outside the store moves chat folders directly (`hub/transfer_in.rs` puts the live folder
/// aside and installs a transferred chat in its place). The image the store holds for the old
/// folder must never land in the new one: not in a read, not at the checkpoint, not in a replay.
#[test]
fn a_folder_replaced_outside_the_store_keeps_its_own_metadata() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(55);
    let store = open(home.path(), &journal);
    store.save(&meta(CHAT, "old", 0)).unwrap_or_else(|e| panic!("{e:#}"));
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    store.save(&meta(CHAT, "old-renamed", 0)).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    // A transfer's swap: the live folder aside, the transferred chat in its place.
    let sessions = home.path().join("sessions");
    std::fs::rename(sessions.join(CHAT), sessions.join(format!(".{CHAT}.replacement-backup")))
        .unwrap_or_else(|e| panic!("{e}"));
    std::fs::create_dir(sessions.join(CHAT)).unwrap_or_else(|e| panic!("{e}"));
    let transferred =
        serde_json::to_vec_pretty(&meta(CHAT, "transferred", 0)).unwrap_or_else(|e| panic!("{e}"));
    std::fs::write(sessions.join(CHAT).join("session.json"), transferred)
        .unwrap_or_else(|e| panic!("{e}"));
    let name = |store: &dyn Store| {
        store.load(CHAT).unwrap_or_else(|e| panic!("{e:#}")).map(|meta| meta.name)
    };
    assert_eq!(
        name(store.as_ref()).as_deref(),
        Some("transferred"),
        "a read saw the old folder's image"
    );
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    let on_disk = session_json(home.path(), CHAT).map(|value| value["name"].clone());
    assert_eq!(
        on_disk,
        Some(json!("transferred")),
        "the checkpoint wrote the old image into the new folder"
    );
    let crashed = journal.restart(Crash::Process);
    drop(store);
    let store = open(home.path(), &crashed);
    assert_eq!(
        name(store.as_ref()).as_deref(),
        Some("transferred"),
        "the replay wrote the old image into the new folder"
    );
}

/// The same swap, then a kill before any checkpoint: the replay must not write the old folder's
/// journaled image into the folder that replaced it.
#[test]
fn a_replay_never_writes_an_image_into_a_folder_replaced_since() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(59);
    let store = open(home.path(), &journal);
    store.save(&meta(CHAT, "old", 0)).unwrap_or_else(|e| panic!("{e:#}"));
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    store.save(&meta(CHAT, "old-renamed", 0)).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    let sessions = home.path().join("sessions");
    std::fs::rename(sessions.join(CHAT), sessions.join(format!(".{CHAT}.replacement-backup")))
        .unwrap_or_else(|e| panic!("{e}"));
    std::fs::create_dir(sessions.join(CHAT)).unwrap_or_else(|e| panic!("{e}"));
    let transferred =
        serde_json::to_vec_pretty(&meta(CHAT, "transferred", 0)).unwrap_or_else(|e| panic!("{e}"));
    std::fs::write(sessions.join(CHAT).join("session.json"), transferred)
        .unwrap_or_else(|e| panic!("{e}"));
    let killed = journal.restart(Crash::Process);
    drop(store);
    let store = open(home.path(), &killed);
    let name = store.load(CHAT).unwrap_or_else(|e| panic!("{e:#}")).map(|meta| meta.name);
    assert_eq!(
        name.as_deref(),
        Some("transferred"),
        "the replay wrote the old image into the new folder"
    );
}

/// `session_dir` hands the chat's folder to code that reads its files directly: its
/// `session.json` is current then.
#[test]
fn session_dir_hands_out_a_folder_whose_metadata_is_written() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(56);
    let store = open(home.path(), &journal);
    store.save(&meta(CHAT, "before", 0)).unwrap_or_else(|e| panic!("{e:#}"));
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    store.save(&meta(CHAT, "after", 0)).unwrap_or_else(|e| panic!("{e:#}"));
    let dir = store.session_dir(CHAT).unwrap_or_else(|| panic!("no session folder"));
    let bytes = std::fs::read(dir.join("session.json")).unwrap_or_else(|e| panic!("{e}"));
    let value: Value = serde_json::from_slice(&bytes).unwrap_or_else(|e| panic!("{e}"));
    assert_eq!(value["name"], json!("after"), "session_dir handed out a stale session.json");
}

/// `flush_session` makes the chat's log and metadata durable on disk (`Store::flush_session`).
#[test]
fn flush_session_writes_the_chats_metadata() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(57);
    let store = open(home.path(), &journal);
    store.save(&meta(CHAT, "before", 0)).unwrap_or_else(|e| panic!("{e:#}"));
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    store.save(&meta(CHAT, "after", 1)).unwrap_or_else(|e| panic!("{e:#}"));
    store.append(CHAT, &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    store.flush_session(CHAT).unwrap_or_else(|e| panic!("{e:#}"));
    let on_disk = session_json(home.path(), CHAT).map(|value| value["name"].clone());
    assert_eq!(on_disk, Some(json!("after")), "flush_session left the metadata in memory");
}

/// A folder that code outside the store removed is not made again by the checkpoint (S2's rule:
/// recovery and projection never make a folder that is gone).
#[test]
fn the_checkpoint_never_makes_a_folder_removed_outside_the_store_again() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(58);
    let store = open(home.path(), &journal);
    store.save(&meta(CHAT, "chat", 0)).unwrap_or_else(|e| panic!("{e:#}"));
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    store.save(&meta(CHAT, "renamed", 0)).unwrap_or_else(|e| panic!("{e:#}"));
    let dir = home.path().join("sessions").join(CHAT);
    std::fs::remove_dir_all(&dir).unwrap_or_else(|e| panic!("{e}"));
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    assert!(!dir.exists(), "the checkpoint made a removed folder again");
    assert!(
        store.load(CHAT).unwrap_or_else(|e| panic!("{e:#}")).is_none(),
        "a removed chat still reads"
    );
}

// ---------------------------------------------------------------- the open's syncs

/// An open that replays many chats flushes the drive's cache a bounded number of times, not a
/// few times per chat: on macOS each flush (`F_FULLFSYNC`) costs milliseconds, and at 29 ms per
/// replayed chat (fleet ead05e82, aws-m4pro-5) an open after a kill with 300 active chats took
/// 8.8 s, past the daemon's 8 s start budget. Every file is still made durable (the order of the
/// writes is kept with a barrier sync, and one full flush ends the open).
#[test]
fn an_open_that_replays_many_chats_flushes_the_drive_a_bounded_number_of_times() {
    use super::log_sync::FULL_SYNCS;
    use std::sync::atomic::Ordering;
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(70);
    let store = open(home.path(), &journal);
    let chats = 40;
    for chat in 0..chats {
        let id = format!("chat-{chat}");
        store.save(&meta(&id, "chat", 0)).unwrap_or_else(|e| panic!("{e:#}"));
        store.append(&id, &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    }
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    for chat in 0..chats {
        let id = format!("chat-{chat}");
        store.append(&id, &record(2, "queued")).unwrap_or_else(|e| panic!("{e:#}"));
        store.save(&meta(&id, "renamed", 2)).unwrap_or_else(|e| panic!("{e:#}"));
    }
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    let killed = journal.restart(Crash::Process);
    drop(store);
    let before = FULL_SYNCS.load(Ordering::SeqCst);
    let store = open(home.path(), &killed);
    let flushes = FULL_SYNCS.load(Ordering::SeqCst).saturating_sub(before);
    for chat in 0..chats {
        let id = format!("chat-{chat}");
        assert_eq!(seqs(store.as_ref(), &id), vec![1, 2], "{id} lost a line");
    }
    assert!(
        flushes <= 8,
        "the open flushed the drive {flushes} times for {chats} replayed chats (one or two per open, not per chat)"
    );
}

/// The open after a kill syncs nothing per replayed chat before it returns (the daemon binds its
/// socket after it): the log already holds the dead daemon's lines, only the checkpoint needs them
/// durable, and the checkpoint runs on its own thread after the start. At about 8 ordered syncs
/// per chat, an open with 300 chats took 6.1 s on an owned Mac (fleet 59175d6b, 2 ms a sync
/// under load). Every acknowledged line still survives an OS crash after the checkpoint.
#[test]
fn an_open_after_a_kill_syncs_nothing_per_chat_and_the_checkpoint_makes_it_durable() {
    use super::log_sync::ALL_SYNCS;
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(71);
    let store = open(home.path(), &journal);
    let chats = 40;
    for chat in 0..chats {
        let id = format!("chat-{chat}");
        store.save(&meta(&id, "chat", 0)).unwrap_or_else(|e| panic!("{e:#}"));
        store.append(&id, &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    }
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    for chat in 0..chats {
        let id = format!("chat-{chat}");
        store.append(&id, &record(2, "queued")).unwrap_or_else(|e| panic!("{e:#}"));
        store.save(&meta(&id, "renamed", 2)).unwrap_or_else(|e| panic!("{e:#}"));
    }
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    let killed = journal.restart(Crash::Process);
    drop(store);
    // This thread's syncs: the open's own (the daemon binds its socket on this thread after it).
    let before = ALL_SYNCS.with(std::cell::Cell::get);
    let store = open(home.path(), &killed);
    let syncs = ALL_SYNCS.with(std::cell::Cell::get).saturating_sub(before);
    for chat in 0..chats {
        let id = format!("chat-{chat}");
        assert_eq!(seqs(store.as_ref(), &id), vec![1, 2], "{id} lost a line");
        let name = store.load(&id).unwrap_or_else(|e| panic!("{e:#}")).map(|meta| meta.name);
        assert_eq!(name.as_deref(), Some("renamed"), "{id} lost its metadata");
    }
    assert!(
        syncs <= 4,
        "the open synced {syncs} times for {chats} replayed chats before it returned"
    );
    // The checkpoint (a timer on its own thread; here at once) makes it all durable.
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    let crashed = killed.restart(Crash::Os);
    drop(store);
    sync_model::os_crash(&home.path().join("sessions"));
    let store = open(home.path(), &crashed);
    for chat in 0..chats {
        let id = format!("chat-{chat}");
        assert_eq!(seqs(store.as_ref(), &id), vec![1, 2], "{id} lost a line in the OS crash");
    }
}

// ---------------------------------------------------------------- review of #35483 (F1 to F4)

/// F1 (review of #35483): the metadata twin of S2's finding 1a (lines written with the switch off).
/// A kill with the switch on; a run with it off whose catch-up did not replay this journal (an
/// older build stops at kind 4, and the journal here is on `SimStorage`, so the switch-off start
/// finds none); a rename then; the switch on again. The replay must not write the journal's older
/// image over the change made with the switch off.
#[test]
fn metadata_written_with_the_switch_off_survives_turning_it_on_again() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(60);
    let store = open(home.path(), &journal);
    store.save(&meta(CHAT, "one", 0)).unwrap_or_else(|e| panic!("{e:#}"));
    store.append(CHAT, &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    store.save(&meta(CHAT, "two", 1)).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    let killed = journal.restart(Crash::Process);
    drop(store);
    let off = super::open(&StoreConfig::default(), home.path())
        .unwrap_or_else(|e| panic!("open the store with the switch off: {e:#}"));
    off.save(&meta(CHAT, "three", 1)).unwrap_or_else(|e| panic!("{e:#}"));
    drop(off);
    let store = open(home.path(), &killed);
    let name = store.load(CHAT).unwrap_or_else(|e| panic!("{e:#}")).map(|meta| meta.name);
    assert_eq!(
        name.as_deref(),
        Some("three"),
        "the replay wrote the journal's older image over a change made with the switch off"
    );
}

/// F1, a delete: a chat made after the checkpoint, a kill, a start with the switch off whose
/// catch-up fails (here its checkpoint file does not read), and the chat deleted in that run. The
/// next start with the switch on must not make the chat again from its journaled records.
#[test]
fn a_chat_deleted_with_the_switch_off_after_a_failed_catch_up_is_not_made_again() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(63);
    let store = open(home.path(), &journal);
    store.save(&meta("chat-old", "old", 0)).unwrap_or_else(|e| panic!("{e:#}"));
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    store.save(&meta(CHAT, "new", 0)).unwrap_or_else(|e| panic!("{e:#}"));
    store.append(CHAT, &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    store.save(&meta(CHAT, "new", 1)).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    let killed = journal.restart(Crash::Process);
    drop(store);
    // The switch-off start finds a journal on disk and cannot catch up with it.
    let checkpoint = home.path().join("journal-projected.json");
    let saved = std::fs::read(&checkpoint).unwrap_or_else(|e| panic!("{e}"));
    std::fs::write(&checkpoint, b"not a checkpoint").unwrap_or_else(|e| panic!("{e}"));
    let on_disk = home.path().join("journal");
    std::fs::create_dir(&on_disk).unwrap_or_else(|e| panic!("{e}"));
    let off = super::open(&StoreConfig::default(), home.path())
        .unwrap_or_else(|e| panic!("open the store with the switch off: {e:#}"));
    off.delete(CHAT).unwrap_or_else(|e| panic!("{e:#}"));
    drop(off);
    std::fs::write(&checkpoint, saved).unwrap_or_else(|e| panic!("{e}"));
    std::fs::remove_dir(&on_disk).unwrap_or_else(|e| panic!("{e}"));
    let store = open(home.path(), &killed);
    assert!(
        store.load(CHAT).unwrap_or_else(|e| panic!("{e:#}")).is_none(),
        "a chat deleted with the switch off came back"
    );
    assert!(
        !home.path().join("sessions").join(CHAT).exists(),
        "the replay made the folder of a chat deleted with the switch off again"
    );
}

/// F2: a `session_dir` (or `flush_session`) that read a chat's overlay image before a checkpoint
/// wrote a newer one must not write its older image over the newer file. It reads "one"; "two"
/// is saved, made durable and checkpointed; "three" is saved and stays in memory; then the late
/// write runs. A kill that loses "three" must keep the acknowledged "two".
#[test]
fn a_late_settle_never_writes_an_older_image_over_a_checkpointed_one() {
    const SETTLED: &str = "chat-settled";
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(61);
    let store: Arc<dyn Store> = Arc::from(open(home.path(), &journal));
    store.save(&meta(SETTLED, "one", 0)).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    let (arrived_tx, arrived) = std::sync::mpsc::channel();
    let (release, release_rx) = std::sync::mpsc::channel();
    *super::journal_store::SETTLE_HOLD.lock().unwrap_or_else(std::sync::PoisonError::into_inner) =
        Some((SETTLED.to_owned(), arrived_tx, release_rx));
    let late = {
        let store = Arc::clone(&store);
        std::thread::spawn(move || store.session_dir(SETTLED))
    };
    arrived.recv_timeout(WAIT).unwrap_or_else(|e| panic!("the settle never read its image: {e}"));
    store.save(&meta(SETTLED, "two", 0)).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    journal.set_sync_delay(Duration::from_secs(2));
    // The writer is in chat-b's 2 s sync: "three" waits in memory.
    store.append("chat-b", &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    std::thread::sleep(Duration::from_millis(300));
    store.save(&meta(SETTLED, "three", 0)).unwrap_or_else(|e| panic!("{e:#}"));
    release.send(()).unwrap_or_else(|e| panic!("{e}"));
    let _dir = late.join().unwrap_or_else(|_| panic!("the late settle panicked"));
    // A kill now: "three" is lost, "two" was acknowledged.
    let killed = journal.restart(Crash::Process);
    killed.set_sync_delay(Duration::ZERO);
    drop(store);
    let store = open(home.path(), &killed);
    let name = store.load(SETTLED).unwrap_or_else(|e| panic!("{e:#}")).map(|meta| meta.name);
    assert_eq!(
        name.as_deref(),
        Some("two"),
        "a late settle wrote an older image over an acknowledged one"
    );
}

/// F3: a checkpoint that writes a chat's `session.json` and then fails to sync the chat's folder
/// (the rename may be lost in an OS crash) freezes, as a failed log sync does, and keeps the
/// record: the store asks the daemon to stop, and the restart writes the image again.
#[test]
fn a_failed_folder_sync_after_a_metadata_write_freezes_the_checkpoint() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(64);
    let store = open(home.path(), &journal);
    store.save(&meta(CHAT, "before", 0)).unwrap_or_else(|e| panic!("{e:#}"));
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    // A draft change: a `meta` record and no log line.
    store.save(&meta(CHAT, "after", 0)).unwrap_or_else(|e| panic!("{e:#}"));
    let folder = home.path().join("sessions").join(CHAT);
    super::log_sync::FAIL_DIR_SYNC.with(|fail| *fail.borrow_mut() = Some(folder));
    let failed = store.flush();
    super::log_sync::FAIL_DIR_SYNC.with(|fail| *fail.borrow_mut() = None);
    assert!(failed.is_err(), "the checkpoint went on past a failed sync of a session.json folder");
    assert!(store.flush().is_err(), "a checkpoint after a failed folder sync went ahead");
    let reason = store.stop_reason().and_then(|reason| reason.borrow().clone());
    assert!(reason.is_some(), "the store did not ask the daemon to stop");
    let killed = journal.restart(Crash::Process);
    drop(store);
    let store = open(home.path(), &killed);
    let name = store.load(CHAT).unwrap_or_else(|e| panic!("{e:#}")).map(|meta| meta.name);
    assert_eq!(name.as_deref(), Some("after"), "the restart lost the image of a frozen checkpoint");
}

/// F4: a chat made after the last checkpoint and deleted by code no client waits for (a purge),
/// then a kill before the group commit takes the `forget`: the next start must not make the chat
/// again from its `created` record.
#[test]
fn a_chat_made_after_the_checkpoint_and_deleted_is_not_made_again() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(62);
    let store = open(home.path(), &journal);
    store.save(&meta("chat-old", "old", 0)).unwrap_or_else(|e| panic!("{e:#}"));
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    store.save(&meta(CHAT, "new", 0)).unwrap_or_else(|e| panic!("{e:#}"));
    store.append(CHAT, &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    store.save(&meta(CHAT, "new", 1)).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    journal.set_sync_delay(Duration::from_secs(2));
    // The writer is in chat-b's 2 s sync: the `forget` waits in memory.
    store.append("chat-b", &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    std::thread::sleep(Duration::from_millis(300));
    store.delete(CHAT).unwrap_or_else(|e| panic!("{e:#}"));
    let killed = journal.restart(Crash::Process);
    killed.set_sync_delay(Duration::ZERO);
    drop(store);
    let store = open(home.path(), &killed);
    assert!(
        store.load(CHAT).unwrap_or_else(|e| panic!("{e:#}")).is_none(),
        "a deleted chat came back"
    );
    assert!(
        !home.path().join("sessions").join(CHAT).exists(),
        "the replay made a deleted chat's folder again"
    );
    assert!(
        !store.list().unwrap_or_else(|e| panic!("{e:#}")).iter().any(|meta| meta.id == CHAT),
        "a deleted chat is listed"
    );
}

/// F4 and F1 at the root (review of #35483): the replay never makes a chat's folder again, so a
/// chat removed by any path (a purge, a run without the journal, the transfer recovery) stays
/// removed. That holds only if an OS crash can never take back the folder of a chat a client was
/// told about: a new chat's first record is acknowledged (the durability the outbound gate waits
/// for) only once its folder's entry in `sessions/` is synced too. The model keeps what each
/// folder's last sync held (`sync_model::os_crash_folders`).
#[test]
fn a_new_chat_is_acknowledged_only_once_its_folder_is_durable() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(65);
    let store = open(home.path(), &journal);
    store.save(&meta("chat-old", "old", 0)).unwrap_or_else(|e| panic!("{e:#}"));
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    store.save(&meta(CHAT, "new", 0)).unwrap_or_else(|e| panic!("{e:#}"));
    store.append(CHAT, &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    store.save(&meta(CHAT, "new", 1)).unwrap_or_else(|e| panic!("{e:#}"));
    let durability = store.durability().unwrap_or_else(|| panic!("no durability"));
    let acked = durability.acked.load(std::sync::atomic::Ordering::SeqCst);
    let deadline = std::time::Instant::now() + WAIT;
    while *durability.durable.borrow() < acked {
        assert!(std::time::Instant::now() < deadline, "the chat's records never became durable");
        std::thread::sleep(Duration::from_millis(5));
    }
    let sessions = home.path().join("sessions");
    assert!(
        sync_model::folder_keeps(&sessions, CHAT),
        "the new chat was acknowledged while an OS crash could still take back its folder"
    );
    let crashed = journal.restart(Crash::Os);
    drop(store);
    sync_model::os_crash(&sessions);
    sync_model::os_crash_folders(&sessions);
    let store = open(home.path(), &crashed);
    let loaded = store.load(CHAT).unwrap_or_else(|e| panic!("{e:#}"));
    assert_eq!(
        loaded.map(|meta| (meta.name, meta.last_seq)),
        Some(("new".to_owned(), 1)),
        "an acknowledged chat was lost in an OS crash"
    );
    assert_eq!(seqs(store.as_ref(), CHAT), vec![1]);
}

/// Review of #35483, P3 1: a caller that needs only a chat's folder path (an agent's start, a
/// fixed id's check under the hub's sessions lock) never waits for the journal or the disk; only
/// `session_dir`, for code that reads or moves the chat's files, writes its metadata first.
#[test]
fn session_path_never_waits_for_the_journal() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(66);
    let store = open(home.path(), &journal);
    store.save(&meta(CHAT, "one", 0)).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    journal.set_sync_delay(Duration::from_secs(2));
    // The writer takes "two" into a 2 s sync.
    store.save(&meta(CHAT, "two", 0)).unwrap_or_else(|e| panic!("{e:#}"));
    let started = std::time::Instant::now();
    let path = store.session_path(CHAT);
    let took = started.elapsed();
    assert_eq!(path, Some(home.path().join("sessions").join(CHAT)));
    assert!(
        took < Duration::from_millis(500),
        "session_path waited {took:?} for the journal and the disk"
    );
    journal.set_sync_delay(Duration::ZERO);
}

// ---------------------------------------------------------------- review of #35562 (the hold)

/// Makes `id`'s first log segment a link to a copy of itself: the store never follows one, so the
/// chat's repair fails at every open (as `one_chat_that_cannot_be_repaired_does_not_stop_the_open`).
fn link_first_segment(home: &Path, id: &str) {
    let segment = home.join("sessions").join(id).join("events").join("000001.ndjson");
    let copy = home.join(format!("{id}-elsewhere.ndjson"));
    std::fs::copy(&segment, &copy).unwrap_or_else(|e| panic!("{e}"));
    std::fs::remove_file(&segment).unwrap_or_else(|e| panic!("{e}"));
    std::os::unix::fs::symlink(&copy, &segment).unwrap_or_else(|e| panic!("{e}"));
}

/// F1 of the review of #35562 (its test): after a failed repair, a checkpoint still writes only
/// metadata images whose records are durable (the file never holds an image a crash can take
/// back, and its `journalLsn` never names a record the journal can lose and give out again).
#[test]
fn a_checkpoint_after_a_failed_repair_writes_only_durable_images() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(70);
    let store = open(home.path(), &journal);
    store.append("chat-b", &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    store.append("chat-b", &record(2, "queued")).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    // A kill: chat-b's line 2 is past the checkpoint, and its repair fails at the next open.
    let killed = journal.restart(Crash::Process);
    drop(store);
    link_first_segment(home.path(), "chat-b");
    let store = open(home.path(), &killed);
    // A metadata change whose record waits in a 2 s sync, then a checkpoint.
    killed.set_sync_delay(Duration::from_secs(2));
    store.save(&meta(CHAT, "after", 0)).unwrap_or_else(|e| panic!("{e:#}"));
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    let written = session_json(home.path(), CHAT).map(|value| value["name"].clone());
    let durable = store.wait_durable(Duration::ZERO).unwrap_or_else(|e| panic!("{e:#}"));
    killed.set_sync_delay(Duration::ZERO);
    assert!(
        written != Some(json!("after")) || durable,
        "the checkpoint wrote an image to session.json before its record was durable"
    );
}

/// A run with the switch on that a kill ended, with chat-b's repair failing at every later open.
fn killed_run_with_a_broken_chat(home: &Path, save: &[SessionMeta]) {
    let store = super::open(&config(), home).unwrap_or_else(|e| panic!("{e:#}"));
    store.append("chat-b", &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    for meta in save {
        store.save(meta).unwrap_or_else(|e| panic!("{e:#}"));
    }
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    drop(store);
    link_first_segment(home, "chat-b");
}

fn open_switch_off(home: &Path) -> Box<dyn Store> {
    super::open(&StoreConfig::default(), home).unwrap_or_else(|e| panic!("{e:#}"))
}

/// F2 of the review of #35562 (its test): with the switch off, a start's catch-up never writes an
/// older journaled image over a change made with the switch off, also after a failed repair
/// (DESIGN.md 3.3c: "turning it on again replays nothing old").
#[test]
fn a_start_with_the_switch_off_after_a_failed_repair_keeps_a_rename_made_with_it_off() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    killed_run_with_a_broken_chat(home.path(), &[meta(CHAT, "on", 0)]);
    let off = open_switch_off(home.path());
    let mut renamed = off
        .load(CHAT)
        .unwrap_or_else(|e| panic!("{e:#}"))
        .unwrap_or_else(|| panic!("the chat is gone"));
    renamed.name = "off".into();
    off.save(&renamed).unwrap_or_else(|e| panic!("{e:#}"));
    drop(off);
    let off = open_switch_off(home.path());
    let name = off.load(CHAT).unwrap_or_else(|e| panic!("{e:#}")).map(|meta| meta.name);
    assert_eq!(
        name.as_deref(),
        Some("off"),
        "the catch-up wrote an older journaled image over a rename made with the switch off"
    );
}

/// F2 of the review of #35562 (its test): with the switch off, a chat deleted with the switch off
/// stays deleted at the next start, also after a failed repair.
#[test]
fn a_start_with_the_switch_off_after_a_failed_repair_keeps_a_chat_deleted_with_it_off() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    killed_run_with_a_broken_chat(home.path(), &[meta(CHAT, "chat", 0)]);
    let off = open_switch_off(home.path());
    off.delete(CHAT).unwrap_or_else(|e| panic!("{e:#}"));
    drop(off);
    let off = open_switch_off(home.path());
    assert!(
        off.load(CHAT).unwrap_or_else(|e| panic!("{e:#}")).is_none(),
        "a chat deleted with the switch off came back"
    );
    assert!(
        !home.path().join("sessions").join(CHAT).exists(),
        "the catch-up made its folder again"
    );
}

// ---------------------------------------------------------------- review of #35483 at 8301994b135 (N1)

/// N1 (the reviewer's test): a chat folder moved in from another acpmux home
/// (`build_adopt::acpmux::merge_sessions` moves a post-update home's chat folders into the
/// adopted home) keeps the other journal's `journalLsn`, which can be above every LSN this home's
/// journal has given. A change saved here must still reach `session.json`: the checkpoint must not
/// take that number for "this image or a newer one is on disk" and drop the change.
#[test]
fn a_change_to_a_chat_moved_in_from_another_home_reaches_session_json() {
    let source = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let source_journal = SimStorage::new(70);
    let store = open(source.path(), &source_journal);
    for n in 1..=10 {
        store.save(&meta(CHAT, &format!("a{n}"), 0)).unwrap_or_else(|e| panic!("{e:#}"));
    }
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    drop(store);
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(71);
    let store = open(home.path(), &journal);
    store.save(&meta("chat-here", "here", 0)).unwrap_or_else(|e| panic!("{e:#}"));
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    // The move, as `merge_sessions` makes it: one rename into this home's sessions folder.
    std::fs::rename(
        source.path().join("sessions").join(CHAT),
        home.path().join("sessions").join(CHAT),
    )
    .unwrap_or_else(|e| panic!("{e}"));
    let moved = store.load(CHAT).unwrap_or_else(|e| panic!("{e:#}")).map(|meta| meta.name);
    assert_eq!(moved.as_deref(), Some("a10"));
    store.save(&meta(CHAT, "b1", 0)).unwrap_or_else(|e| panic!("{e:#}"));
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    let name = store.load(CHAT).unwrap_or_else(|e| panic!("{e:#}")).map(|meta| meta.name);
    assert_eq!(name.as_deref(), Some("b1"), "the checkpoint dropped a change it never wrote");
    let on_disk = session_json(home.path(), CHAT).map(|value| value["name"].clone());
    assert_eq!(on_disk, Some(json!("b1")), "session.json kept the moved-in image");
}

/// N1, the replay: the same moved-in chat, a change saved here, a kill before any checkpoint. The
/// replay must write the change over the other journal's image.
#[test]
fn a_replayed_change_to_a_chat_moved_in_from_another_home_reaches_session_json() {
    let source = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let source_journal = SimStorage::new(72);
    let store = open(source.path(), &source_journal);
    for n in 1..=10 {
        store.save(&meta(CHAT, &format!("a{n}"), 0)).unwrap_or_else(|e| panic!("{e:#}"));
    }
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    drop(store);
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(73);
    let store = open(home.path(), &journal);
    store.save(&meta("chat-here", "here", 0)).unwrap_or_else(|e| panic!("{e:#}"));
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    std::fs::rename(
        source.path().join("sessions").join(CHAT),
        home.path().join("sessions").join(CHAT),
    )
    .unwrap_or_else(|e| panic!("{e}"));
    store.save(&meta(CHAT, "b1", 0)).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    let killed = journal.restart(Crash::Process);
    drop(store);
    let store = open(home.path(), &killed);
    let name = store.load(CHAT).unwrap_or_else(|e| panic!("{e:#}")).map(|meta| meta.name);
    assert_eq!(name.as_deref(), Some("b1"), "the replay dropped a change to a moved-in chat");
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    let on_disk = session_json(home.path(), CHAT).map(|value| value["name"].clone());
    assert_eq!(on_disk, Some(json!("b1")), "session.json kept the moved-in image");
}

/// N1, a journal made again: the journal folder and its checkpoint removed (a reset), so the new
/// journal gives out LSNs the old one gave. A change saved after the reset must reach
/// `session.json`, whose `journalLsn` is the old journal's.
#[test]
fn a_change_after_the_journal_is_made_again_reaches_session_json() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(74);
    let store = open(home.path(), &journal);
    for n in 1..=10 {
        store.save(&meta(CHAT, &format!("a{n}"), 0)).unwrap_or_else(|e| panic!("{e:#}"));
    }
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    drop(store);
    // The reset: a new journal (another simulated disk) and no checkpoint file.
    std::fs::remove_file(home.path().join("journal-projected.json"))
        .unwrap_or_else(|e| panic!("{e}"));
    let fresh = SimStorage::new(75);
    let store = open(home.path(), &fresh);
    store.save(&meta(CHAT, "b1", 0)).unwrap_or_else(|e| panic!("{e:#}"));
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    let name = store.load(CHAT).unwrap_or_else(|e| panic!("{e:#}")).map(|meta| meta.name);
    assert_eq!(name.as_deref(), Some("b1"), "a change after a journal reset was dropped");
    let on_disk = session_json(home.path(), CHAT).map(|value| value["name"].clone());
    assert_eq!(on_disk, Some(json!("b1")), "session.json kept the old journal's image");
}

// ---------------------------------------------------------------- review of #35866 (P1-1, P2-1, P2-2)

/// Whether this user can still make a file in a folder of mode 0o500 (root can): the tests
/// below use a folder's mode to make one write fail.
fn mode_stops_writes(folder: &Path) -> bool {
    std::fs::set_permissions(folder, std::fs::Permissions::from_mode(0o500))
        .unwrap_or_else(|e| panic!("chmod {}: {e}", folder.display()));
    let probe = folder.join("rsync-review-probe");
    let made = std::fs::File::create(&probe).is_ok();
    let _ = std::fs::remove_file(&probe);
    std::fs::set_permissions(folder, std::fs::Permissions::from_mode(0o700))
        .unwrap_or_else(|e| panic!("chmod {}: {e}", folder.display()));
    !made
}

/// Review of #35866, P1-1 (the reviewer's test): the open's repair leaves a whole log as it is
/// and puts its segments in `Order::read_segments`; the first checkpoint takes them. When that checkpoint fails before
/// `sync_read_segments` (here: a replayed metadata image whose `session.json` cannot be
/// written yet, so `project_metas` fails), the set is dropped, and the next checkpoint that
/// succeeds retires the records of lines that no sync made durable. An OS crash then loses
/// acknowledged lines.
#[test]
fn a_failed_checkpoint_after_the_open_keeps_the_segments_it_read() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    assert!(
        mode_stops_writes(home.path()),
        "this test needs a user that a folder's mode stops (not root)"
    );
    let journal = SimStorage::new(91);
    let store = open(home.path(), &journal);
    store.append(CHAT, &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    for seq in 2..=5 {
        store.append(CHAT, &record(seq, "queued")).unwrap_or_else(|e| panic!("{e:#}"));
    }
    // Another chat's metadata change past the checkpoint (its folder made by the save).
    store.save(&meta("chat-b", "renamed", 0)).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    let killed = journal.restart(Crash::Process);
    drop(store);
    // chat-b's folder takes no new file for a while: a checkpoint's write of its
    // `session.json` fails (not a failed sync: no freeze).
    let folder = home.path().join("sessions").join("chat-b");
    std::fs::set_permissions(&folder, std::fs::Permissions::from_mode(0o500))
        .unwrap_or_else(|e| panic!("{e}"));
    let store = open(home.path(), &killed);
    // Every checkpoint fails while the folder is so (the checkpointer's first, at once, and
    // this one): whichever ran first took the segments the open read.
    let first = store.flush();
    std::fs::set_permissions(&folder, std::fs::Permissions::from_mode(0o700))
        .unwrap_or_else(|e| panic!("{e}"));
    eprintln!(
        "the checkpoint while chat-b's folder was 0o500: {:?}",
        first.as_ref().err().map(|e| format!("{e:#}"))
    );
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    let crashed = killed.restart(Crash::Os);
    drop(store);
    sync_model::os_crash(&home.path().join("sessions"));
    let store = open(home.path(), &crashed);
    assert_eq!(
        seqs(store.as_ref(), CHAT),
        (1..=5).collect::<Vec<_>>(),
        "a checkpoint retired records whose log lines the open read and no sync made durable (a failed checkpoint dropped Order::read_segments)"
    );
}

/// Review of #35866, P2-1 (the reviewer's test): a freeze on another thread while a checkpoint
/// is in flight. The checkpoint read its LSN before the freeze, goes on, and at its end removes the freeze
/// marker the freeze just wrote (`clear_frozen_marker` runs after every checkpoint). The
/// restart then takes the whole-log path for the frozen chat, its sync reports success for
/// pages the failed sync dropped, and its checkpoint retires the line's record.
#[test]
fn a_freeze_during_a_checkpoint_still_makes_the_restart_write_the_lines_again() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(92);
    let store: Arc<dyn Store> = Arc::from(open(home.path(), &journal));
    store.append(CHAT, &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    // A checkpoint in flight: it waits in a 2 s sync of chat-b's record.
    journal.set_sync_delay(Duration::from_secs(2));
    store.append("chat-b", &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    let flusher = {
        let store = Arc::clone(&store);
        std::thread::spawn(move || store.flush())
    };
    std::thread::sleep(Duration::from_millis(300));
    // Meanwhile a line past that checkpoint's LSN, and a failed sync of its log on this
    // thread (`flush_session`): the store freezes and writes its marker.
    store.append(CHAT, &record(2, "queued")).unwrap_or_else(|e| panic!("{e:#}"));
    FAIL_NEXT_LOG_SYNC.with(|fail| fail.set(true));
    let failed = store.flush_session(CHAT);
    FAIL_NEXT_LOG_SYNC.with(|fail| fail.set(false));
    journal.set_sync_delay(Duration::ZERO);
    assert!(failed.is_err(), "flush_session's sync did not fail as the test asked");
    let marker = home.path().join("journal-frozen");
    let after_freeze = marker.exists();
    let in_flight = flusher.join().unwrap_or_else(|_| panic!("the flush panicked"));
    let after_checkpoint = marker.exists();
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
        "the restart after a failed sync trusted the log and lost an acked line (marker after the freeze: {after_freeze}; after the checkpoint in flight ended ({}): {after_checkpoint})",
        if in_flight.is_ok() { "ok" } else { "error" }
    );
}

/// Review of #35866, P2-2 (the reviewer's test): the freeze marker is the only thing that
/// makes the restart write the lines again, and `freeze` only logs a failed marker write (`write_atomic`: a new file, its full
/// sync, a rename). Here the home takes no new file when the log sync fails; on a real disk
/// the marker's own sync can fail with the log's. The restart then trusts the log's pages.
#[test]
fn a_freeze_in_a_home_that_takes_no_new_file_still_writes_the_lines_again() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    assert!(
        mode_stops_writes(home.path()),
        "this test needs a user that a folder's mode stops (not root)"
    );
    let journal = SimStorage::new(94);
    let store = open(home.path(), &journal);
    store.append(CHAT, &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    for seq in 2..=5 {
        store.append(CHAT, &record(seq, "queued")).unwrap_or_else(|e| panic!("{e:#}"));
    }
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    std::fs::set_permissions(home.path(), std::fs::Permissions::from_mode(0o500))
        .unwrap_or_else(|e| panic!("{e}"));
    FAIL_NEXT_LOG_SYNC.with(|fail| fail.set(true));
    let failed = store.flush();
    FAIL_NEXT_LOG_SYNC.with(|fail| fail.set(false));
    std::fs::set_permissions(home.path(), std::fs::Permissions::from_mode(0o700))
        .unwrap_or_else(|e| panic!("{e}"));
    assert!(failed.is_err(), "the checkpoint went on past a failed log sync");
    eprintln!("the marker after the freeze: {}", home.path().join("journal-frozen").exists());
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
        (1..=5).collect::<Vec<_>>(),
        "the restart after a failed sync whose freeze marker could not be written trusted the log's pages and lost acked lines"
    );
}

/// A failed sync's freeze journals a `frozen` record (review of #35866, P2-1 and P2-2). When the
/// journal's queue is full, that append waits for the journal's writer (up to `SEAL_WAIT`) and
/// appends again. A checkpoint waits for a failed sync only until the store is frozen, never for
/// that wait (lead's review of #35866): its wait stays bounded by the syncs under way (#35895). A
/// checkpoint in flight (held right after its start, `HOLD_AFTER_START`) and another thread's
/// `flush_session`, whose log sync fails, whose record finds the queue full
/// (`FORCE_FROZEN_BACKLOG`) and which stops before it waits for the writer
/// (`HOLD_BEFORE_FROZEN_RECORD`): the checkpoint must return, refused, before that thread goes
/// on. It says if it waits (`NOTE_BEFORE_SYNCS_WAIT`): no timer.
#[test]
fn a_checkpoint_does_not_wait_for_a_frozen_record_on_another_thread() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(99);
    let store: Arc<dyn Store> = Arc::from(open(home.path(), &journal));
    store.append(CHAT, &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    store.append(CHAT, &record(2, "queued")).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    // A checkpoint in flight: past its start, where it read `frozen` (false). It says when it
    // waits for a sync under way, or that it returned.
    let (started_tx, started) = std::sync::mpsc::channel();
    let (go, go_rx) = std::sync::mpsc::channel();
    let (events_tx, events) = std::sync::mpsc::channel();
    let flusher = {
        let store = Arc::clone(&store);
        std::thread::spawn(move || {
            HOLD_AFTER_START.with(|hold| *hold.borrow_mut() = Some((started_tx, go_rx)));
            NOTE_BEFORE_SYNCS_WAIT.with(|note| *note.borrow_mut() = Some(events_tx.clone()));
            let result = store.flush();
            let _ = events_tx.send("returned");
            result
        })
    };
    started.recv_timeout(WAIT).unwrap_or_else(|e| panic!("the checkpoint never started: {e}"));
    // Another thread's flush_session: its log sync fails, its frozen record finds the queue full,
    // and it stops before it waits for the writer.
    let (arrived_tx, arrived) = std::sync::mpsc::channel();
    let (release, release_rx) = std::sync::mpsc::channel();
    let failing = {
        let store = Arc::clone(&store);
        std::thread::spawn(move || {
            HOLD_BEFORE_FROZEN_RECORD
                .with(|hold| *hold.borrow_mut() = Some((arrived_tx, release_rx)));
            FORCE_FROZEN_BACKLOG.with(|force| force.set(true));
            FAIL_NEXT_LOG_SYNC.with(|fail| fail.set(true));
            let result = store.flush_session(CHAT);
            FAIL_NEXT_LOG_SYNC.with(|fail| fail.set(false));
            result
        })
    };
    arrived.recv_timeout(WAIT).unwrap_or_else(|e| panic!("the failed sync never froze: {e}"));
    let _ = go.send(());
    let first =
        events.recv_timeout(WAIT).unwrap_or_else(|e| panic!("no word from the checkpoint: {e}"));
    let _ = release.send(());
    let failed = failing.join().unwrap_or_else(|_| panic!("the failing thread panicked"));
    let checkpointed = flusher.join().unwrap_or_else(|_| panic!("the flush panicked"));
    assert!(failed.is_err(), "flush_session's sync did not fail as the test asked");
    assert_eq!(
        first, "returned",
        "a checkpoint waited for another thread's frozen record, not only for its failed sync"
    );
    assert!(checkpointed.is_err(), "a checkpoint went past a freeze");
    // The record is journaled all the same: the restart writes the lines again, and an OS crash
    // after its checkpoint keeps them.
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
        "the restart lost a line of the frozen store"
    );
}

// ---------------------------------------------------------------- delta review of #35866: a refused frozen record

// Delta review of #35866 at `f62feba6e3d` (`r-durability-rsync-reviewer`), finding D1: the
/// shutdown's last checkpoint runs after the journal's seal (`Hub::seal`: `Store::seal`, then
/// `Store::flush`; the daemon's exit past its budget does the same after `Hub::flush`). A log sync
/// that fails in it freezes the store, but the `frozen` record finds the journal closed
/// (`AppendError::Closed`) and only an error is logged. The restart in the same boot takes the
/// whole-log path, its checkpoint's sync of a new descriptor reports success for the pages the
/// failed sync dropped, and it retires their records: an OS crash then loses acknowledged lines.
/// The reviewer's test (branch `fix/r-durability-rsync-review-frozen-record-nomerge`, red at `2fd5a947e69` on macOS fleet 8be47d90 and Linux fleet 4e352aa0).
#[test]
fn a_log_sync_that_fails_in_the_shutdowns_last_checkpoint_keeps_the_rewrite() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(95);
    let store = open(home.path(), &journal);
    store.append(CHAT, &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    // The shutdown's first checkpoint (`Hub::flush`).
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    // Lines that land before the seal (a request on an open connection, an agent past the
    // budget), acknowledged: their records are durable.
    for seq in 2..=5 {
        store.append(CHAT, &record(seq, "queued")).unwrap_or_else(|e| panic!("{e:#}"));
    }
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    // `Hub::seal`: the seal, then the last checkpoint, whose log sync fails.
    store.seal();
    FAIL_NEXT_LOG_SYNC.with(|fail| fail.set(true));
    let failed = store.flush();
    FAIL_NEXT_LOG_SYNC.with(|fail| fail.set(false));
    assert!(failed.is_err(), "the last checkpoint went on past a failed log sync");
    // The daemon exits and starts again in the same boot; the restart's first checkpoint runs.
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
        "a log sync that failed after the seal journaled no frozen record: the restart trusted the log's pages and lost acked lines"
    );
}

/// The reviewer's test (delta review of #35866, finding D1, the queue-full form, with no test
/// seam in the store): the writer is behind (one sync of a
/// slow or failing disk takes 8 s here) and other chats' lines fill its queue. A request's
/// `flush_session` fails its log sync; its `frozen` record finds the queue full, the wait for the
/// writer (`SEAL_WAIT`, 5 s) ends first, and the retried append finds it full again. Only an error
/// is logged, and the restart in the same boot trusts the log's pages.
#[test]
fn a_frozen_record_while_the_journals_queue_stays_full_keeps_the_rewrite() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(97);
    let small = cmux_journal::Config { max_pending_bytes: 8 * 1024, ..journal_config() };
    let open_small = |sim: &SimStorage| {
        open_with_journal(&config(), home.path(), Arc::new(sim.clone()), small.clone())
            .unwrap_or_else(|e| panic!("open the store: {e:#}"))
    };
    let store = open_small(&journal);
    store.append(CHAT, &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    for seq in 2..=5 {
        store.append(CHAT, &record(seq, "queued")).unwrap_or_else(|e| panic!("{e:#}"));
    }
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    // The writer is behind: each sync takes 8 s, and another chat's lines fill its queue.
    journal.set_sync_delay(Duration::from_secs(8));
    let full = (1..=100_000u64).any(|seq| store.append("chat-b", &record(seq, "queued")).is_err());
    assert!(full, "the journal's queue never filled");
    FAIL_NEXT_LOG_SYNC.with(|fail| fail.set(true));
    let started = std::time::Instant::now();
    let failed = store.flush_session(CHAT);
    let took = started.elapsed();
    FAIL_NEXT_LOG_SYNC.with(|fail| fail.set(false));
    journal.set_sync_delay(Duration::ZERO);
    assert!(failed.is_err(), "flush_session's sync did not fail as the test asked");
    eprintln!("the failed flush_session returned after {took:?}");
    // The daemon stops for a restart in the same boot (no crash); the restart's checkpoint runs.
    drop(store);
    let store = open_small(&journal);
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    let crashed = journal.restart(Crash::Os);
    drop(store);
    sync_model::os_crash(&home.path().join("sessions"));
    let store = open_small(&crashed);
    assert_eq!(
        seqs(store.as_ref(), CHAT),
        (1..=5).collect::<Vec<_>>(),
        "the frozen record found the journal's queue full twice and was not journaled: the restart trusted the log's pages and lost acked lines"
    );
}

/// Delta review of #35866, finding D1, a seal while a freeze is under way: a request's
/// `flush_session` fails its log sync and stops right before it freezes the store
/// (`HOLD_BEFORE_FREEZE`), and a shutdown seals the store meanwhile (begun by another cause: a
/// signal, an update's handoff). The freeze's `frozen` record must still reach the journal: the
/// journal closes only after the shutdown's last checkpoint, which waits for the sync under way.
/// The sealing thread says when it waits for that sync (`NOTE_BEFORE_SYNCS_WAIT`) or that the
/// seal returned, and only then is the freeze let go on: no timer. Red where the seal closes the
/// journal at once (the record is refused, `AppendError::Closed`).
#[test]
fn a_seal_while_a_freeze_is_under_way_keeps_the_rewrite() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(98);
    let store: Arc<dyn Store> = Arc::from(open(home.path(), &journal));
    store.append(CHAT, &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    for seq in 2..=5 {
        store.append(CHAT, &record(seq, "queued")).unwrap_or_else(|e| panic!("{e:#}"));
    }
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    // A request's flush_session: its log sync fails, and it stops right before it freezes.
    let (arrived_tx, arrived) = std::sync::mpsc::channel();
    let (release, release_rx) = std::sync::mpsc::channel();
    let failing = {
        let store = Arc::clone(&store);
        std::thread::spawn(move || {
            super::journal_store::HOLD_BEFORE_FREEZE
                .with(|hold| *hold.borrow_mut() = Some((arrived_tx, release_rx)));
            FAIL_NEXT_LOG_SYNC.with(|fail| fail.set(true));
            let result = store.flush_session(CHAT);
            FAIL_NEXT_LOG_SYNC.with(|fail| fail.set(false));
            result
        })
    };
    arrived.recv_timeout(WAIT).unwrap_or_else(|e| panic!("the failed sync never froze: {e}"));
    // The shutdown's seal, on another thread: it says when it waits for the sync under way, or
    // that it returned.
    let (events_tx, events) = std::sync::mpsc::channel();
    let sealer = {
        let store = Arc::clone(&store);
        std::thread::spawn(move || {
            NOTE_BEFORE_SYNCS_WAIT.with(|note| *note.borrow_mut() = Some(events_tx.clone()));
            store.seal();
            let _ = events_tx.send("returned");
        })
    };
    let first = events.recv_timeout(WAIT).unwrap_or_else(|e| panic!("no word from the seal: {e}"));
    let _ = release.send(());
    let failed = failing.join().unwrap_or_else(|_| panic!("the failing thread panicked"));
    sealer.join().unwrap_or_else(|_| panic!("the seal panicked"));
    assert!(failed.is_err(), "flush_session's sync did not fail as the test asked");
    // The restart in the same boot; its first checkpoint runs.
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
        "a seal while a freeze was under way lost its frozen record (the seal {}): the restart trusted the log's pages and lost acked lines",
        if first == "returned" { "closed the journal at once" } else { "waited for the sync" }
    );
}
