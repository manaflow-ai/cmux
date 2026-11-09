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
