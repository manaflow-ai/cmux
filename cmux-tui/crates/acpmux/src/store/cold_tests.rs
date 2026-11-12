//! A chat's cold archive (`store/cold.rs`).

use super::*;
use serde_json::json;

struct Home(PathBuf);

impl Home {
    fn new() -> (Self, LocalStore) {
        let path = std::env::temp_dir().join(format!("acpmux-cold-{}", uuid::Uuid::now_v7()));
        let store = LocalStore::new(path.join("sessions"), 64 * 1024).unwrap();
        (Self(path), store)
    }
}

impl Drop for Home {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn closed(store: &LocalStore, id: &str) {
    let meta = json!({
        "schema": META_SCHEMA, "id": id, "name": "old chat", "harness": "claude",
        "cwd": "/tmp", "status": "closed", "createdAt": 1, "updatedAt": 2,
    });
    store.save(&serde_json::from_value(meta).unwrap()).unwrap();
}

fn record(seq: u64, dir: &str, kind: &str, msg: Value) -> EventRecord {
    EventRecord {
        seq,
        at: 1_700_000_000_000 + seq,
        dir: dir.into(),
        kind: kind.into(),
        msg,
        host_seq: None,
    }
}

/// A chat's log as a working Claude agent leaves it, over several segments: prompts, the
/// harness's raw stream and tool results, tool calls with output, and the agent's answers.
fn chat(store: &LocalStore, id: &str, turns: u64) -> Vec<EventRecord> {
    let mut records = Vec::new();
    let mut seq = 0;
    let mut push = |dir: &str, kind: &str, msg: Value| {
        seq += 1;
        records.push(record(seq, dir, kind, msg));
    };
    push("mux", "created", json!({"name": "old chat"}));
    for turn in 0..turns {
        push(
            "mux",
            "user_message",
            json!({"text": format!("turn {turn}: fix the flaky test in crates/acpmux/src/store.rs and run it"), "promptId": format!("p{turn}")}),
        );
        push(
            "mux",
            "turn_started",
            json!({"turnId": format!("t{turn}"), "promptId": format!("p{turn}")}),
        );
        for chunk in 0..40 {
            push(
                "in",
                "claude.stream_event",
                json!({"type": "stream_event", "event": {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": format!("word{chunk} ")}}, "parent_tool_use_id": null, "session_id": "8b1f0c4e-5d1a-4c55-9a7e-3f0b8a1d2c3e", "uuid": format!("{turn:04}-{chunk:04}-6f1e-4b8e-9d1c")}),
            );
        }
        let output: String =
            (0..80).map(|i| format!("test store::tests::case_{i} ... ok\n")).collect();
        push(
            "in",
            "tool_call",
            json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "a", "update": {"sessionUpdate": "tool_call_update", "toolCallId": format!("toolu_{turn}"), "status": "completed", "title": "cargo test -p acpmux --lib store", "content": [{"type": "content", "content": {"type": "text", "text": output}}]}}}),
        );
        push(
            "in",
            "agent_message_chunk",
            json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "a", "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": format!("Turn {turn}: the test passes now; the race was in the segment roll.")}}}}),
        );
        push(
            "mux",
            "turn_result",
            json!({"turnId": format!("t{turn}"), "status": "completed", "stopReason": "end_turn", "usage": {"inputTokens": 1200 + turn, "outputTokens": 300}}),
        );
    }
    for r in &records {
        store.append(id, r).unwrap();
    }
    store.close_log(id);
    records
}

/// Every file of `events/`, by name, with its SHA-256.
fn hashes(store: &LocalStore, id: &str) -> BTreeMap<String, String> {
    let mut out = BTreeMap::new();
    for entry in std::fs::read_dir(store.dir(id).join("events")).unwrap() {
        let entry = entry.unwrap();
        let bytes = std::fs::read(entry.path()).unwrap();
        out.insert(
            entry.file_name().to_string_lossy().into_owned(),
            crate::sha256::sha256_hex(&bytes),
        );
    }
    out
}

fn archive(store: &LocalStore, id: &str) -> ColdStats {
    let staged = store.stage_cold(id).unwrap().expect("a log to archive");
    let stats = staged.stats;
    assert!(store.commit_cold(id, staged).unwrap());
    stats
}

#[test]
fn archive_round_trip_is_byte_identical() {
    let (_home, store) = Home::new();
    closed(&store, "c");
    let records = chat(&store, "c", 60);
    // Read once, so the search and kind copies exist beside the log.
    let mut kinds = 0;
    Store::scan_kinds(&store, "c", &["user_message"], &mut |_| {
        kinds += 1;
        true
    })
    .unwrap();
    let before = hashes(&store, "c");
    assert!(before.len() > 3, "the fixture spans several segments: {before:?}");

    let stats = archive(&store, "c");
    println!(
        "cold archive fixture: {} records, {} files, {} bytes before, {} bytes after ({:.1}x)",
        records.len(),
        stats.files,
        stats.bytes_before,
        stats.bytes_after,
        stats.bytes_before as f64 / stats.bytes_after as f64
    );
    assert_eq!(stats.files, before.len() as u64);
    assert!(stats.bytes_after * 5 < stats.bytes_before, "{stats:?}");
    let dir = store.dir("c");
    assert!(!dir.join("events").exists());
    assert!(!dir.join(crate::store::kind_index::DIR).exists());
    assert!(dir.join(COLD_FILE).exists());
    assert!(store.is_cold("c"));
    assert!(Store::log_written_at(&store, "c").is_none(), "no rehydrate to answer");
    assert!(store.is_cold("c"));

    // The first read rehydrates it, byte for byte.
    let read = Store::events(&store, "c", 0, usize::MAX).unwrap();
    assert_eq!(read, records);
    assert_eq!(hashes(&store, "c"), before);
    assert!(!dir.join(COLD_FILE).exists());
    assert!(!dir.join(THAW_DIR).exists());
    assert!(!dir.join(DROP_DIR).exists());
    assert!(!store.is_cold("c"));
}

#[test]
fn a_cold_chat_lists_without_its_archive_being_read() {
    let (_home, store) = Home::new();
    closed(&store, "c");
    chat(&store, "c", 5);
    archive(&store, "c");
    // An archive that would not decode: listing and loading never open it.
    std::fs::write(store.cold_path("c"), b"not zstd").unwrap();
    let listed = Store::list(&store).unwrap();
    assert_eq!(listed.iter().map(|m| m.id.as_str()).collect::<Vec<_>>(), ["c"]);
    assert!(Store::load_startup(&store, "c").unwrap().is_some());
    assert!(store.is_cold("c"));
    // A read that needs the log fails, and the archive stays where it was.
    assert!(Store::events(&store, "c", 0, 10).is_err());
    assert!(store.cold_path("c").exists());
}

#[test]
fn an_append_rehydrates_first() {
    let (_home, store) = Home::new();
    closed(&store, "c");
    let mut records = chat(&store, "c", 3);
    archive(&store, "c");
    let next = record(records.len() as u64 + 1, "mux", "status", json!({"status": "idle"}));
    store.append("c", &next).unwrap();
    records.push(next);
    assert!(!store.cold_path("c").exists());
    assert_eq!(Store::events(&store, "c", 0, usize::MAX).unwrap(), records);
}

#[test]
fn a_log_that_changed_since_staging_stays_hot() {
    let (_home, store) = Home::new();
    closed(&store, "c");
    let records = chat(&store, "c", 3);
    let staged = store.stage_cold("c").unwrap().unwrap();
    let tmp = staged.tmp.clone();
    store.append("c", &record(records.len() as u64 + 1, "mux", "status", json!({}))).unwrap();
    assert!(!store.commit_cold("c", staged).unwrap());
    assert!(!tmp.exists(), "the refused archive is removed");
    assert!(!store.cold_path("c").exists());
    assert_eq!(Store::events(&store, "c", 0, usize::MAX).unwrap().len(), records.len() + 1);
}

#[test]
fn a_crash_before_the_log_moved_aside_keeps_the_hot_log() {
    let (_home, store) = Home::new();
    closed(&store, "c");
    let records = chat(&store, "c", 4);
    let before = hashes(&store, "c");
    // The archive renamed into place, then the crash: both are there.
    let staged = store.stage_cold("c").unwrap().unwrap();
    std::fs::rename(&staged.tmp, store.cold_path("c")).unwrap();
    drop(staged);
    assert!(!store.is_cold("c"));
    assert_eq!(Store::events(&store, "c", 0, usize::MAX).unwrap(), records);
    // The next archive settles it first: the archive is covered by the log, and goes.
    store.settle_cold("c").unwrap();
    assert!(!store.cold_path("c").exists());
    assert_eq!(hashes(&store, "c"), before);
}

#[test]
fn an_archive_the_log_does_not_cover_is_kept_aside() {
    let (_home, store) = Home::new();
    closed(&store, "c");
    chat(&store, "c", 4);
    let staged = store.stage_cold("c").unwrap().unwrap();
    std::fs::rename(&staged.tmp, store.cold_path("c")).unwrap();
    drop(staged);
    // A segment shorter than the archive's copy of it: never deleted.
    let first = store.segment_files("c").unwrap()[0].1.clone();
    std::fs::write(&first, b"").unwrap();
    store.settle_cold("c").unwrap();
    assert!(!store.cold_path("c").exists());
    let kept: Vec<_> = std::fs::read_dir(store.dir("c"))
        .unwrap()
        .filter_map(|e| e.ok())
        .filter(|e| e.file_name().to_string_lossy().starts_with("cold.zst.orphan-"))
        .collect();
    assert_eq!(kept.len(), 1);
}

/// An older build does not read `cold.zst`: an append to an archived idle chat starts a new
/// `000001.ndjson` of its own beside the archive. Once that log is as long as the archived one or
/// longer, its length says nothing: the archive holds the only copy of the old history and stays
/// (review of #39141).
#[test]
fn an_older_builds_new_log_as_long_as_the_archive_does_not_remove_it() {
    for extra in [0_usize, 4096] {
        let (_home, store) = Home::new();
        closed(&store, "c");
        chat(&store, "c", 4);
        let staged = store.stage_cold("c").unwrap().unwrap();
        let archived = staged.files.clone();
        std::fs::rename(&staged.tmp, store.cold_path("c")).unwrap();
        drop(staged);
        let copy = std::fs::read(store.cold_path("c")).unwrap();
        // The older build's log: other bytes in every file the archive names, as long or longer.
        let events = store.dir("c").join("events");
        for entry in &archived {
            let len = usize::try_from(entry.len).unwrap() + extra;
            std::fs::write(events.join(&entry.name), vec![b'x'; len]).unwrap();
        }
        store.settle_cold("c").unwrap();
        assert!(!store.cold_path("c").exists());
        let kept: Vec<_> = std::fs::read_dir(store.dir("c"))
            .unwrap()
            .filter_map(|e| e.ok())
            .filter(|e| e.file_name().to_string_lossy().starts_with("cold.zst.orphan-"))
            .collect();
        assert_eq!(kept.len(), 1, "the archive went (extra {extra})");
        assert_eq!(std::fs::read(kept[0].path()).unwrap(), copy, "the archive changed");
    }
}

#[test]
fn a_crash_during_or_after_rehydrate_resolves() {
    let (_home, store) = Home::new();
    closed(&store, "c");
    let records = chat(&store, "c", 4);
    let before = hashes(&store, "c");
    archive(&store, "c");
    let copy = std::fs::read(store.cold_path("c")).unwrap();
    // A rehydrate cut short: its half-written folder, and an `events/` an append made.
    let dir = store.dir("c");
    std::fs::create_dir_all(dir.join(THAW_DIR)).unwrap();
    std::fs::write(dir.join(THAW_DIR).join("000001.ndjson"), b"{\"seq\":1").unwrap();
    std::fs::create_dir_all(dir.join("events")).unwrap();
    assert!(store.is_cold("c"));
    assert_eq!(Store::events(&store, "c", 0, usize::MAX).unwrap(), records);
    assert_eq!(hashes(&store, "c"), before);
    // A crash after the rename, before the archive's removal: the log is the log.
    std::fs::write(store.cold_path("c"), &copy).unwrap();
    assert!(!store.is_cold("c"));
    assert_eq!(Store::events(&store, "c", 0, usize::MAX).unwrap(), records);
    store.settle_cold("c").unwrap();
    assert!(!store.cold_path("c").exists());
    assert_eq!(hashes(&store, "c"), before);
}

#[test]
fn a_log_with_a_file_it_does_not_own_is_not_archived() {
    let (_home, store) = Home::new();
    closed(&store, "c");
    chat(&store, "c", 2);
    std::fs::write(store.dir("c").join("events").join("000001.ndjson.compact"), b"x").unwrap();
    assert!(store.stage_cold("c").unwrap().is_none());
    assert!(store.stage_cold("nothing").unwrap().is_none());
}

#[test]
fn a_sealed_store_does_not_rehydrate() {
    let (_home, store) = Home::new();
    closed(&store, "c");
    chat(&store, "c", 2);
    archive(&store, "c");
    Store::seal(&store);
    assert!(Store::events(&store, "c", 0, 10).is_err());
    assert!(store.is_cold("c"));
}

type Stop = (std::sync::mpsc::Receiver<()>, std::sync::mpsc::Sender<()>);

/// Sets the stop in `slot` on this thread: the receiver says the thread is there, and a send on
/// the sender lets it go on.
fn stop_at(slot: &'static std::thread::LocalKey<super::super::log_sync::HoldSlot>) -> Stop {
    let (arrived_tx, arrived) = std::sync::mpsc::channel();
    let (release, release_rx) = std::sync::mpsc::channel();
    slot.with(|hold| *hold.borrow_mut() = Some((arrived_tx, release_rx)));
    (arrived, release)
}

/// Review of #39141 (F1): a second archive of the chat, settling while the first is between its
/// archive's rename into place and the rename of `events/` aside, took the archive for a crash's
/// leftover the log covers and removed it; the first then removed the log, and nothing was left.
#[test]
fn a_second_archive_waits_for_a_commit_between_its_renames() {
    let (_home, store) = Home::new();
    closed(&store, "c");
    let records = chat(&store, "c", 4);
    let store = std::sync::Arc::new(store);
    let staged = store.stage_cold("c").unwrap().unwrap();
    let (tx, rx) = std::sync::mpsc::channel::<Stop>();
    let first = {
        let store = store.clone();
        std::thread::spawn(move || {
            tx.send(stop_at(&HOLD_AFTER_COLD_PUBLISH)).unwrap();
            store.commit_cold("c", staged).unwrap()
        })
    };
    let (arrived, release) = rx.recv().unwrap();
    arrived.recv().unwrap();
    assert!(store.cold_path("c").exists() && store.dir("c").join("events").exists());
    // The second archive: it says when it reaches the cold lock, or that it is done.
    let (said, heard) = std::sync::mpsc::channel::<&'static str>();
    let second = {
        let store = store.clone();
        std::thread::spawn(move || {
            NOTE_BEFORE_COLD_LOCK.with(|note| *note.borrow_mut() = Some(said.clone()));
            let staged = store.stage_cold("c");
            let _ = said.send("done");
            staged.unwrap().is_some()
        })
    };
    assert_eq!(heard.recv().unwrap(), "settle", "the settle waits for the commit");
    release.send(()).unwrap();
    assert!(first.join().unwrap());
    assert!(!second.join().unwrap(), "the log is archived: nothing left to stage");
    assert!(store.cold_path("c").exists());
    assert!(store.is_cold("c"));
    assert_eq!(Store::events(&*store, "c", 0, usize::MAX).unwrap(), records);
}

/// Second review of #39141 (F1): an archive task of a daemon that handed the home over (its
/// store sealed) settled while the next daemon's commit was between its archive's rename into
/// place and the rename of `events/` aside. The two stores' cold locks are their own, so the old
/// one took the archive for a crash's leftover the log covers and removed it, and the new one then
/// removed the log.
#[test]
fn a_sealed_store_does_not_settle_the_next_daemons_archive() {
    let (_home, old) = Home::new();
    closed(&old, "c");
    let records = chat(&old, "c", 4);
    Store::seal(&old);
    let next = std::sync::Arc::new(LocalStore::new(old.root.clone(), 64 * 1024).unwrap());
    let staged = next.stage_cold("c").unwrap().unwrap();
    let (tx, rx) = std::sync::mpsc::channel::<Stop>();
    let commit = {
        let next = next.clone();
        std::thread::spawn(move || {
            tx.send(stop_at(&HOLD_AFTER_COLD_PUBLISH)).unwrap();
            next.commit_cold("c", staged).unwrap()
        })
    };
    let (arrived, release) = rx.recv().unwrap();
    arrived.recv().unwrap();
    assert!(next.cold_path("c").exists() && next.dir("c").join("events").exists());
    assert!(old.stage_cold("c").is_err(), "the sealed store settles nothing");
    assert!(old.cold_path("c").exists(), "the next daemon's archive is still there");
    release.send(()).unwrap();
    assert!(commit.join().unwrap());
    assert!(next.is_cold("c"));
    assert_eq!(Store::events(&*next, "c", 0, usize::MAX).unwrap(), records);
}

/// Review of #39141 (F2): an append that found no segment while another thread rehydrated the
/// log got false from its own rehydrate (the archive was gone by then) and kept its empty
/// listing, so it went on in `000001` of a log whose last segment is later.
#[test]
fn an_append_during_another_rehydrate_goes_on_in_the_last_segment() {
    let (_home, store) = Home::new();
    closed(&store, "c");
    let mut records = chat(&store, "c", 20);
    let segments = store.segment_files("c").unwrap();
    assert!(segments.len() > 2, "the fixture spans several segments: {segments:?}");
    let before = hashes(&store, "c");
    archive(&store, "c");
    let store = std::sync::Arc::new(store);
    let (tx, rx) = std::sync::mpsc::channel::<Stop>();
    let reader = {
        let store = store.clone();
        std::thread::spawn(move || {
            tx.send(stop_at(&HOLD_BEFORE_THAW)).unwrap();
            store.rehydrate("c").unwrap()
        })
    };
    let (arrived, release) = rx.recv().unwrap();
    arrived.recv().unwrap();
    // The append: it lists no segment, finds the archive, and reaches the cold lock the reader
    // holds.
    let next = record(records.len() as u64 + 1, "mux", "status", json!({"status": "idle"}));
    let (said, heard) = std::sync::mpsc::channel::<&'static str>();
    let appender = {
        let store = store.clone();
        let next = next.clone();
        std::thread::spawn(move || {
            NOTE_BEFORE_COLD_LOCK.with(|note| *note.borrow_mut() = Some(said));
            store.append("c", &next).unwrap();
            store.close_log("c");
        })
    };
    assert_eq!(heard.recv().unwrap(), "rehydrate");
    release.send(()).unwrap();
    assert!(reader.join().unwrap());
    appender.join().unwrap();
    records.push(next);
    let after = hashes(&store, "c");
    let last = before.keys().filter(|name| name.ends_with(".ndjson")).max().unwrap().clone();
    for (name, hash) in &before {
        if *name != last {
            assert_eq!(after.get(name), Some(hash), "{name} was written to");
        }
    }
    assert_eq!(Store::events(&*store, "c", 0, usize::MAX).unwrap(), records);
}

/// Forced lost-home races for the cold archive (#41372 review F2): a settle or a rehydrate held
/// past its home check, the home then replaced by a copy of itself (the new daemon's session
/// tree, as restored from the old one). Every removal and rename lands in the held home; the new
/// one is never changed. Each runs in a process of its own (`lost_home_race_tests::isolated`).
#[cfg(unix)]
mod lost_home {
    use super::*;
    use crate::lost_home_race_tests::{copy_tree, forced, isolated};

    /// A chat archived beside its log (a crash before the commit moved the log aside), so a
    /// settle removes the archive.
    #[test]
    fn a_cold_settle_held_past_its_check() {
        isolated(
            module_path!(),
            "a_cold_settle_held_past_its_check",
            |home| {
                let store = LocalStore::new(home.join("sessions"), 64 * 1024).unwrap();
                closed(&store, "c");
                chat(&store, "c", 1);
                archive(&store, "c");
                let copy = std::fs::read(store.cold_path("c")).unwrap();
                assert!(store.rehydrate("c").unwrap());
                std::fs::write(store.cold_path("c"), &copy).unwrap();
                let target = store.dir("c");
                let old = home.with_extension("old");
                let seed = move |home: &Path| copy_tree(&home.with_extension("old"), home);
                forced(home, target, seed, None, move || {
                    let _ = store.settle_cold("c");
                });
                assert!(
                    !old.join("sessions").join("c").join(COLD_FILE).exists(),
                    "the held home's covered archive was not removed"
                );
            },
            |_, _| {},
        );
    }

    /// #41462 review F1: the held home holds archive A and no log; the home that replaces it
    /// holds another archive, B, beside a log that holds B. A settle held past its home check
    /// must read the archive and its log in the held home, where A has no copy beside it, so A
    /// is kept: read in the replacement, B is "covered" and the removal in the held home takes
    /// A, the chat's only history.
    #[test]
    fn a_cold_settle_reads_the_held_home_not_its_replacement() {
        isolated(
            module_path!(),
            "a_cold_settle_reads_the_held_home_not_its_replacement",
            |home| {
                let store = LocalStore::new(home.join("sessions"), 64 * 1024).unwrap();
                closed(&store, "a");
                chat(&store, "a", 1);
                archive(&store, "a");
                let a = std::fs::read(store.cold_path("a")).unwrap();
                closed(&store, "c");
                chat(&store, "c", 2);
                archive(&store, "c");
                let b = std::fs::read(store.cold_path("c")).unwrap();
                assert_ne!(a, b, "the two archives must differ");
                assert!(store.rehydrate("c").unwrap());
                let b_log = home.with_extension("b-log");
                copy_tree(&store.dir("c").join("events"), &b_log);
                // The held home: the chat's only history is archive A, with no log beside it.
                std::fs::remove_dir_all(store.dir("c").join("events")).unwrap();
                std::fs::write(store.cold_path("c"), &a).unwrap();
                let target = store.dir("c");
                let old = home.with_extension("old");
                let seed = move |home: &Path| {
                    copy_tree(&home.with_extension("old"), home);
                    let chat = home.join("sessions").join("c");
                    std::fs::write(chat.join(COLD_FILE), &b).unwrap();
                    copy_tree(&b_log, &chat.join("events"));
                };
                forced(home, target, seed, Some("sessions/c/cold.zst"), move || {
                    let _ = store.settle_cold("c");
                });
                let kept = std::fs::read(old.join("sessions").join("c").join(COLD_FILE)).unwrap();
                assert_eq!(kept, a, "the held home's archive A changed");
            },
            |_, _| {},
        );
    }

    /// A cold chat's first read decodes its archive into a folder beside it, then renames it to
    /// `events/` and removes the archive: held at the check of the last file it decodes.
    #[test]
    fn a_cold_rehydrate_held_past_its_check() {
        isolated(
            module_path!(),
            "a_cold_rehydrate_held_past_its_check",
            |home| {
                let store = LocalStore::new(home.join("sessions"), 64 * 1024).unwrap();
                closed(&store, "c");
                chat(&store, "c", 1);
                let last = hashes(&store, "c").into_keys().last().unwrap();
                archive(&store, "c");
                let target = store.dir("c").join(THAW_DIR).join(&last);
                let kept = format!("sessions/c/events/{last}");
                let seed = |home: &Path| copy_tree(&home.with_extension("old"), home);
                forced(home, target, seed, Some(&kept), move || {
                    let _ = store.rehydrate("c");
                });
            },
            |_, _| {},
        );
    }
}
