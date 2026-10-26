//! Compacting a closed chat's log (`store/compact.rs`).

use super::*;
use serde_json::json;

struct Home(PathBuf);

impl Home {
    fn new() -> (Self, LocalStore) {
        let path = std::env::temp_dir().join(format!("acpmux-compact-{}", uuid::Uuid::now_v7()));
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
    EventRecord { seq, at: seq, dir: dir.into(), kind: kind.into(), msg, host_seq: None }
}

/// A chat's log as a working agent leaves it: its prompt, the harness's raw lines, a tool call
/// with a long output, the agent's answer.
fn chat(store: &LocalStore, id: &str) -> Vec<EventRecord> {
    let output = "line of build output\n".repeat(600);
    let update = |kind: &str, update: Value| json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "a", "update": {"sessionUpdate": kind, "toolCallId": "t1", "status": "completed", "title": "Run the build", "content": update}}});
    let records = vec![
        record(1, "mux", "created", json!({"name": "old chat"})),
        record(2, "mux", "user_message", json!({"text": "remember pelican", "promptId": "p1"})),
        record(3, "in", "claude.stream_event", json!({"event": {"delta": "x".repeat(4000)}})),
        record(4, "in", "tool_call", update("tool_call", json!([]))),
        record(
            5,
            "in",
            "tool_call_update",
            update(
                "tool_call_update",
                json!([{"type": "content", "content": {"type": "text", "text": output}}]),
            ),
        ),
        record(6, "in", "codex.response", json!({"text": "y".repeat(3000)})),
        record(
            7,
            "in",
            "agent_message_chunk",
            json!({"params": {"update": {"content": {"text": "echo: pelican ".repeat(400)}}}}),
        ),
        record(8, "mux", "status", json!({"status": "closed"})),
    ];
    closed(store, id);
    for r in &records {
        store.append(id, r).unwrap();
    }
    store.close_log(id);
    records
}

fn log(store: &LocalStore, id: &str) -> Vec<EventRecord> {
    store.events(id, 0, usize::MAX).unwrap()
}

fn bytes(store: &LocalStore, id: &str) -> Vec<(PathBuf, Vec<u8>)> {
    let mut files: Vec<_> = std::fs::read_dir(store.dir(id).join("events"))
        .unwrap()
        .map(|e| e.unwrap().path())
        .map(|p| (p.clone(), std::fs::read(&p).unwrap()))
        .collect();
    files.sort();
    files
}

#[test]
fn compaction_drops_raw_harness_lines_and_cuts_tool_output_only() {
    let (_home, store) = Home::new();
    let before = chat(&store, "c1");
    let staged =
        store.stage_compaction("c1", CompactMode::Write { archive: None }).unwrap().unwrap();
    let stats = staged.stats;
    assert!(store.commit_compaction("c1", staged).unwrap());
    assert_eq!((stats.dropped, stats.trimmed), (2, 1), "{stats:?}");
    assert!(stats.bytes_after * 3 < stats.bytes_before, "{stats:?}");

    let after = log(&store, "c1");
    let seqs: Vec<u64> = after.iter().map(|r| r.seq).collect();
    assert_eq!(seqs, [1, 2, 4, 5, 7, 8], "every record but the raw lines stays, its seq kept");
    // The prompt, the answer and the chat's own records are as they were.
    for r in after.iter().filter(|r| r.seq != 5) {
        assert_eq!(Some(r), before.iter().find(|b| b.seq == r.seq));
    }
    let update = &after[3].msg["params"]["update"];
    assert_eq!(update["status"], "completed", "{update}");
    assert_eq!(update["title"], "Run the build");
    let text = update["content"][0]["content"]["text"].as_str().unwrap();
    assert!(
        text.starts_with("line of build output") && text.ends_with("removed by log retention]")
    );
    assert!(text.len() < 700, "{}", text.len());
    assert_eq!(store.compacted_seq("c1"), Some(8));
}

#[test]
fn a_compacted_closed_chat_is_never_taken_for_a_purged_one() {
    let (_home, store) = Home::new();
    // A log of raw harness lines only: nothing of it stays.
    closed(&store, "raw");
    store.append("raw", &record(1, "in", "claude.system", json!({"subtype": "init"}))).unwrap();
    store.close_log("raw");
    let staged =
        store.stage_compaction("raw", CompactMode::Write { archive: None }).unwrap().unwrap();
    assert!(store.commit_compaction("raw", staged).unwrap());
    assert!(log(&store, "raw").is_empty());
    let listed: Vec<String> = store.list().unwrap().into_iter().map(|m| m.id).collect();
    assert_eq!(listed, ["raw"], "the compacted chat still lists");
}

#[test]
fn a_dry_run_measures_and_changes_nothing() {
    let (_home, store) = Home::new();
    chat(&store, "c1");
    let files = bytes(&store, "c1");
    let staged = store.stage_compaction("c1", CompactMode::DryRun).unwrap().unwrap();
    assert!(staged.stats.bytes_after < staged.stats.bytes_before);
    assert!(!store.commit_compaction("c1", staged).unwrap(), "a dry run never commits");
    assert!(bytes(&store, "c1") == files, "a dry run wrote nothing");
    assert_eq!(store.compacted_seq("c1"), None);
}

#[test]
fn a_log_written_since_it_was_read_is_left_whole() {
    let (_home, store) = Home::new();
    chat(&store, "c1");
    let staged =
        store.stage_compaction("c1", CompactMode::Write { archive: None }).unwrap().unwrap();
    store.append("c1", &record(9, "mux", "status", json!({"status": "idle"}))).unwrap();
    store.close_log("c1");
    let files: Vec<_> = bytes(&store, "c1")
        .into_iter()
        .filter(|(p, _)| p.extension() != Some("compact".as_ref()))
        .collect();
    assert!(!store.commit_compaction("c1", staged).unwrap());
    assert!(bytes(&store, "c1") == files, "the log as it was, and no compacted copy beside it");
    assert_eq!(log(&store, "c1").len(), 9);
}

#[test]
fn archive_mode_keeps_the_old_segments() {
    let (home, store) = Home::new();
    chat(&store, "c1");
    let original = bytes(&store, "c1");
    let archive = home.0.join("archive");
    let mode = CompactMode::Write { archive: Some(&archive) };
    let staged = store.stage_compaction("c1", mode).unwrap().unwrap();
    assert!(store.commit_compaction("c1", staged).unwrap());
    for (path, content) in original {
        let kept = archive.join("c1/events").join(path.file_name().unwrap());
        assert!(std::fs::read(&kept).unwrap() == content, "{}", kept.display());
    }
    assert!(archive.join("c1/session.json").exists());
    // Appends after it go to the compacted log.
    store.append("c1", &record(9, "mux", "status", json!({"status": "idle"}))).unwrap();
    assert_eq!(log(&store, "c1").last().map(|r| r.seq), Some(9));
}
