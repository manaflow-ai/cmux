//! Chat metadata through the event journal (`store.journal`, R-DURABILITY S3; DESIGN.md 3.3e): a
//! metadata change is a journal record, `session.json` is what a checkpoint writes from it, and a
//! crash at any point leaves the metadata and the log in step.
//!
//! The journal runs on `cmux_journal::SimStorage`; the chat logs are real files whose OS crash
//! follows the syncs that ran (`store/sync_model.rs`).

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

/// An acknowledged chat made after the last checkpoint survives an OS crash that lost its folder
/// (nothing synced the sessions folder since the folder was made): the replay makes it again
/// from its records.
#[test]
fn a_chat_made_after_the_checkpoint_survives_an_os_crash_that_loses_its_folder() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(51);
    let store = open(home.path(), &journal);
    store.save(&meta("chat-old", "old", 0)).unwrap_or_else(|e| panic!("{e:#}"));
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    store.save(&meta(CHAT, "new", 0)).unwrap_or_else(|e| panic!("{e:#}"));
    store.append(CHAT, &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    store.save(&meta(CHAT, "new", 1)).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    let crashed = journal.restart(Crash::Os);
    drop(store);
    // The worst case: the new folder's entry never reached the disk.
    std::fs::remove_dir_all(home.path().join("sessions").join(CHAT))
        .unwrap_or_else(|e| panic!("{e}"));
    let store = open(home.path(), &crashed);
    let loaded = store.load(CHAT).unwrap_or_else(|e| panic!("{e:#}"));
    assert_eq!(
        loaded.map(|meta| (meta.name, meta.last_seq)),
        Some(("new".to_owned(), 1)),
        "an acknowledged chat was lost with its folder"
    );
    assert_eq!(seqs(store.as_ref(), CHAT), vec![1]);
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

// ---------------------------------------------------------------- review of #35562 (not to merge)

/// Makes `id`'s first log segment a link to a copy of itself: the store never follows one, so the
/// chat's repair fails at every open (as `one_chat_that_cannot_be_repaired_does_not_stop_the_open`).
fn link_first_segment(home: &Path, id: &str) {
    let segment = home.join("sessions").join(id).join("events").join("000001.ndjson");
    let copy = home.join(format!("{id}-elsewhere.ndjson"));
    std::fs::copy(&segment, &copy).unwrap_or_else(|e| panic!("{e}"));
    std::fs::remove_file(&segment).unwrap_or_else(|e| panic!("{e}"));
    std::os::unix::fs::symlink(&copy, &segment).unwrap_or_else(|e| panic!("{e}"));
}

/// While a failed repair holds the checkpoint (`Order::held`), a checkpoint still writes only
/// metadata images whose records are durable (S3a: the file never holds an image a crash can take
/// back, and its `journalLsn` never names a record the journal can lose and give out again).
#[test]
fn review_fu_a_checkpoint_below_a_hold_writes_only_durable_images() {
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

/// A run with the switch on that a kill ended, with chat-b's repair failing at every later open:
/// the journal's records stay past the checkpoint.
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

/// With the switch off, a start's catch-up never writes an older journaled image over a change
/// made with the switch off, also while a chat's failed repair holds the checkpoint (DESIGN.md
/// 3.3c: "turning it on again replays nothing old").
#[test]
fn review_fu_a_start_with_the_switch_off_keeps_a_rename_made_with_it_off() {
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

/// With the switch off, a chat deleted with the switch off stays deleted at the next start, also
/// while a chat's failed repair holds the checkpoint.
#[test]
fn review_fu_a_start_with_the_switch_off_keeps_a_chat_deleted_with_it_off() {
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
