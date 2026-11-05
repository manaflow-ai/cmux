//! The write-back of the log ranges the open's repair verified (delta reviews 2 and 3 of #35866,
//! D2 and D3): the verified bytes go back into the file the open read, and never into another
//! file that a delete or a folder replace put at the same path since. An inode number is not a
//! file's identity: a file system that hands a freed inode out again (ext4, XFS) gives a new file
//! at the same path the old number, and Windows has no number to compare.
//!
//! The journal runs on `cmux_journal::SimStorage`; the chat logs are real files.

use super::*;
use cmux_journal::{Crash, SimStorage};
use serde_json::json;
use std::io::Write as _;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt};
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

fn set_mode(path: &Path, mode: u32) {
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode))
        .unwrap_or_else(|e| panic!("chmod {}: {e}", path.display()));
}

/// Gives a folder its mode 0o700 back when dropped, also when the test panics (so the temporary
/// home can be removed).
struct Writable(PathBuf);

impl Drop for Writable {
    fn drop(&mut self) {
        let _ = std::fs::set_permissions(&self.0, std::fs::Permissions::from_mode(0o700));
    }
}

/// Whether this user can still make a file in a folder of mode 0o500 (root can).
fn mode_stops_writes(folder: &Path) -> bool {
    set_mode(folder, 0o500);
    let probe = folder.join("write-back-probe");
    let made = std::fs::File::create(&probe).is_ok();
    let _ = std::fs::remove_file(&probe);
    set_mode(folder, 0o700);
    !made
}

/// chat-a replayed after a kill: its log holds lines 1 to 5, and lines 2 to 5 are past the
/// checkpoint, so the open's repair reads them back, finds them equal to the journal's and keeps
/// the log as it is (`Order::read_segments`). Every checkpoint is then held off before it reaches
/// the logs: chat-b's folder takes no new file, so its replayed metadata image cannot be written
/// and the checkpoint fails in `project_metas` (no freeze: the segments stay listed). Returns the
/// store, chat-b's folder guard, chat-a's first segment and that segment's file id.
fn replayed_chat_with_its_checkpoints_held(
    home: &Path,
    seed: u64,
) -> (Box<dyn Store>, Writable, PathBuf, u64) {
    let journal = SimStorage::new(seed);
    let store = open(home, &journal);
    store.append(CHAT, &record(1, "created")).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    for seq in 2..=5 {
        store.append(CHAT, &record(seq, "queued")).unwrap_or_else(|e| panic!("{e:#}"));
    }
    store.save(&meta("chat-b", "renamed")).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    let killed = journal.restart(Crash::Process);
    drop(store);
    let folder_b = home.join("sessions").join("chat-b");
    set_mode(&folder_b, 0o500);
    let guard = Writable(folder_b);
    let store = open(home, &killed);
    let held = store.flush();
    assert!(held.is_err(), "the checkpoint went on although chat-b's image cannot be written");
    let segment = home.join("sessions").join(CHAT).join("events").join("000001.ndjson");
    let ino = std::fs::metadata(&segment).unwrap_or_else(|e| panic!("{e}")).ino();
    (store, guard, segment, ino)
}

/// Makes chat-a's folder and its `events/` again (owner-only), as a new chat or an import does.
fn make_events_folder(home: &Path) {
    let events = home.join("sessions").join(CHAT).join("events");
    std::fs::DirBuilder::new()
        .mode(0o700)
        .recursive(true)
        .create(&events)
        .unwrap_or_else(|e| panic!("make {}: {e}", events.display()));
}

/// The test's message when the checkpoint changed a log it must not write.
fn changed(why: &str, before: &[u8], after: &[u8]) -> String {
    format!(
        "the checkpoint wrote the old chat's verified bytes into {why}:\nbefore: {}\nafter:  {}",
        String::from_utf8_lossy(before),
        String::from_utf8_lossy(after)
    )
}

/// Delta review 3 of #35866, D3 (the reviewer's test, `r-durability-rsync-reviewer` at
/// `7f3e036d277`; its repro
/// `rsync_review5_a_deleted_chats_write_back_never_lands_in_a_new_chats_log`, red on macOS
/// fleet 857c0030 and Linux fleet 878ccf7a). chat-a is deleted while the open's
/// write-back of its log is pending, and made again under the same id (the trigger bridge's fixed
/// ids allow it once the folder is gone). The new chat's first segment gets the old file id: a
/// stand-in for a reused inode, the old file kept by a second link and linked back, emptied
/// (ext4 handed the freed inode out again in the reviewer's Linux repro). The checkpoint must
/// not write the deleted chat's bytes over the new chat's lines.
#[test]
fn a_chat_deleted_and_made_again_never_takes_the_old_chats_verified_bytes() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    assert!(
        mode_stops_writes(home.path()),
        "this test needs a user that a folder's mode stops (not root)"
    );
    let (store, guard, segment, ino) = replayed_chat_with_its_checkpoints_held(home.path(), 111);
    let kept = home.path().join("kept-old-segment");
    std::fs::hard_link(&segment, &kept).unwrap_or_else(|e| panic!("{e}"));
    store.delete(CHAT).unwrap_or_else(|e| panic!("{e:#}"));
    make_events_folder(home.path());
    std::fs::hard_link(&kept, &segment).unwrap_or_else(|e| panic!("{e}"));
    std::fs::remove_file(&kept).unwrap_or_else(|e| panic!("{e}"));
    std::fs::OpenOptions::new()
        .write(true)
        .open(&segment)
        .and_then(|file| file.set_len(0))
        .unwrap_or_else(|e| panic!("{e}"));
    assert_eq!(std::fs::metadata(&segment).unwrap_or_else(|e| panic!("{e}")).ino(), ino);
    for seq in 1..=8 {
        store.append(CHAT, &record(seq, "made-again")).unwrap_or_else(|e| panic!("{e:#}"));
    }
    assert!(store.wait_durable(WAIT).unwrap_or_else(|e| panic!("{e:#}")), "never durable");
    let before = std::fs::read(&segment).unwrap_or_else(|e| panic!("{e}"));
    // chat-b's folder takes files again: the next checkpoint goes on.
    drop(guard);
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    let after = std::fs::read(&segment).unwrap_or_else(|e| panic!("{e}"));
    assert!(
        after == before,
        "{}",
        changed(
            "a new chat's log (a delete, then another file with the same file id)",
            &before,
            &after
        )
    );
}

/// D3 with no delete: code outside the store replaces chat-a's folder, as a transfer-in that
/// replaces a durable chat does (`hub/transfer_in.rs`: the old folder is renamed aside, the
/// import puts a new one in its place, and the old one is removed). The new folder's first
/// segment has the old segment's file id (the old file renamed in, a stand-in for a reused
/// inode) and the new chat's own lines. The store never hears of the replace, so only a
/// write-back that never runs after the open keeps the checkpoint from writing the old chat's
/// bytes over these lines.
#[test]
fn a_folder_replaced_outside_the_store_never_takes_the_old_chats_verified_bytes() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    assert!(
        mode_stops_writes(home.path()),
        "this test needs a user that a folder's mode stops (not root)"
    );
    let (store, guard, segment, ino) = replayed_chat_with_its_checkpoints_held(home.path(), 113);
    let sessions = home.path().join("sessions");
    let aside = sessions.join(format!(".{CHAT}.replacement-backup"));
    std::fs::rename(sessions.join(CHAT), &aside).unwrap_or_else(|e| panic!("{e}"));
    make_events_folder(home.path());
    std::fs::rename(aside.join("events").join("000001.ndjson"), &segment)
        .unwrap_or_else(|e| panic!("{e}"));
    let mut before = Vec::new();
    for seq in 1..=8 {
        let line =
            serde_json::to_vec(&record(seq, "transferred-in")).unwrap_or_else(|e| panic!("{e}"));
        before.extend_from_slice(&line);
        before.push(b'\n');
    }
    std::fs::OpenOptions::new()
        .write(true)
        .truncate(true)
        .open(&segment)
        .and_then(|mut file| file.write_all(&before))
        .unwrap_or_else(|e| panic!("{e}"));
    std::fs::remove_dir_all(&aside).unwrap_or_else(|e| panic!("{e}"));
    assert_eq!(std::fs::metadata(&segment).unwrap_or_else(|e| panic!("{e}")).ino(), ino);
    drop(guard);
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    let after = std::fs::read(&segment).unwrap_or_else(|e| panic!("{e}"));
    assert!(
        after == before,
        "{}",
        changed("a folder put in its place outside the store (the same file id)", &before, &after)
    );
}
