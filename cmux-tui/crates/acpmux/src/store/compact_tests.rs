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

/// A chat's log as a working agent leaves it: its prompt, the harness's raw lines (a request's
/// stream, its message with usage, a retry, a tool result), a tool call with a long output, the
/// agent's answer.
fn chat(store: &LocalStore, id: &str) -> Vec<EventRecord> {
    let output = "line of build output\n".repeat(600);
    let update = |kind: &str, update: Value| json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "a", "update": {"sessionUpdate": kind, "toolCallId": "t1", "status": "completed", "title": "Run the build", "content": update}}});
    let stream = |event: Value, parent: Value| json!({"type": "stream_event", "event": event, "parent_tool_use_id": parent, "session_id": "s"});
    let delta = json!({"type": "content_block_delta", "delta": {"text": "x"}});
    let records = vec![
        record(1, "mux", "created", json!({"name": "old chat"})),
        record(2, "mux", "user_message", json!({"text": "remember pelican", "promptId": "p1"})),
        record(
            3,
            "out",
            "claude.stdin",
            json!({"type": "user", "message": {"content": "p".repeat(3000)}}),
        ),
        // The request's start and first token stay; the rest of its stream and a subagent's go.
        record(
            4,
            "in",
            "claude.stream_event",
            stream(json!({"type": "message_start", "message": {"id": "m1"}}), Value::Null),
        ),
        record(5, "in", "claude.stream_event", stream(delta.clone(), Value::Null)),
        record(6, "in", "claude.stream_event", stream(delta.clone(), Value::Null)),
        record(7, "in", "claude.stream_event", stream(delta, json!("toolu_sub"))),
        record(
            8,
            "in",
            "claude.assistant",
            json!({"type": "assistant", "parent_tool_use_id": null, "message": {"id": "m1", "model": "opus", "usage": {"input_tokens": 7, "output_tokens": 9}, "content": [{"type": "text", "text": "z".repeat(4000)}]}}),
        ),
        record(
            9,
            "in",
            "claude.system.api_retry",
            json!({"type": "system", "subtype": "api_retry", "attempt": 2, "max_retries": 10, "error": "overloaded"}),
        ),
        record(
            10,
            "in",
            "claude.user",
            json!({"type": "user", "isReplay": false, "tool_use_result": {"file": {"filePath": "/x", "content": "f".repeat(5000)}}}),
        ),
        record(11, "in", "tool_call", update("tool_call", json!([]))),
        record(
            12,
            "in",
            "tool_call_update",
            update(
                "tool_call_update",
                json!([{"type": "content", "content": {"type": "text", "text": output}}]),
            ),
        ),
        record(13, "in", "codex.response", json!({"text": "y".repeat(3000)})),
        record(
            14,
            "in",
            "agent_message_chunk",
            json!({"params": {"update": {"content": {"text": "echo: pelican ".repeat(400)}}}}),
        ),
        record(15, "mux", "status", json!({"status": "closed"})),
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
fn compaction_cuts_long_strings_and_keeps_every_field_a_reader_takes() {
    let (_home, store) = Home::new();
    let before = chat(&store, "c1");
    let staged =
        store.stage_compaction("c1", CompactMode::Write { archive: None }).unwrap().unwrap();
    let stats = staged.stats;
    assert!(store.commit_compaction("c1", staged).unwrap());
    assert_eq!((stats.dropped, stats.trimmed), (2, 5), "{stats:?}");
    assert!(stats.bytes_after * 3 < stats.bytes_before, "{stats:?}");

    let after = log(&store, "c1");
    let seqs: Vec<u64> = after.iter().map(|r| r.seq).collect();
    assert_eq!(
        seqs,
        [1, 2, 3, 4, 5, 8, 9, 10, 11, 12, 13, 14, 15],
        "only stream lines no request timing reads go; every seq is kept"
    );
    let get = |seq: u64| after.iter().find(|r| r.seq == seq).unwrap();
    let was = |seq: u64| before.iter().find(|r| r.seq == seq).unwrap();
    // The prompt, the answer, the timing lines, the retry and the chat's own records are as
    // they were.
    for seq in [1, 2, 4, 5, 9, 11, 14, 15] {
        assert_eq!(get(seq), was(seq), "{seq}");
    }
    // A raw message keeps what OptChat reads (`fold.rs`): its id, model and usage.
    let message = &get(8).msg["message"];
    assert_eq!(
        (&message["id"], &message["model"], &message["usage"]),
        (
            &was(8).msg["message"]["id"],
            &was(8).msg["message"]["model"],
            &was(8).msg["message"]["usage"]
        )
    );
    assert_eq!(get(8).msg["parent_tool_use_id"], Value::Null);
    assert_eq!(get(10).msg["isReplay"], false);
    assert_eq!(get(10).msg["tool_use_result"]["file"]["filePath"], "/x");
    let update = &get(12).msg["params"]["update"];
    assert_eq!(update["status"], "completed", "{update}");
    assert_eq!(update["title"], "Run the build");
    let text = update["content"][0]["content"]["text"].as_str().unwrap();
    assert!(
        text.starts_with("line of build output") && text.ends_with("removed by log retention]")
    );
    assert!(text.len() < 700, "{}", text.len());
    assert_eq!(store.compacted_seq("c1"), Some(15));
}

#[test]
fn a_compacted_closed_chat_is_never_taken_for_a_purged_one() {
    let (_home, store) = Home::new();
    // A log of a subagent's stream only: nothing of it stays.
    closed(&store, "raw");
    let line = json!({"event": {"type": "content_block_delta"}, "parent_tool_use_id": "toolu_1"});
    store.append("raw", &record(1, "in", "claude.stream_event", line)).unwrap();
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
    store.append("c1", &record(16, "mux", "status", json!({"status": "idle"}))).unwrap();
    store.close_log("c1");
    let files: Vec<_> = bytes(&store, "c1")
        .into_iter()
        .filter(|(p, _)| p.extension() != Some("compact".as_ref()))
        .collect();
    assert!(!store.commit_compaction("c1", staged).unwrap());
    assert!(bytes(&store, "c1") == files, "the log as it was, and no compacted copy beside it");
    assert_eq!(log(&store, "c1").len(), 16);
}

/// The folders a pass archived chat `id` into, oldest first.
fn passes(archive: &Path, id: &str) -> Vec<PathBuf> {
    let mut dirs: Vec<PathBuf> =
        std::fs::read_dir(archive.join(id)).unwrap().map(|e| e.unwrap().path()).collect();
    dirs.sort();
    dirs
}

#[test]
fn archive_mode_keeps_the_old_segments() {
    let (home, store) = Home::new();
    chat(&store, "c1");
    let original = bytes(&store, "c1");
    let archive = home.0.join("backup").join("archive");
    let mode = CompactMode::Write { archive: Some(&archive) };
    let staged = store.stage_compaction("c1", mode).unwrap().unwrap();
    assert!(store.commit_compaction("c1", staged).unwrap());
    let first = passes(&archive, "c1");
    assert_eq!(first.len(), 1);
    let kept_all = |pass: &Path| {
        for (path, content) in &original {
            let kept = pass.join("events").join(path.file_name().unwrap());
            assert!(std::fs::read(&kept).unwrap() == *content, "{}", kept.display());
        }
        assert!(pass.join("session.json").exists());
    };
    kept_all(&first[0]);
    // A pass done again (a crash left the record incomplete) archives into a folder of its own:
    // the first pass's copies of the original log stay.
    let mut marker: Value =
        serde_json::from_slice(&std::fs::read(store.marker("c1")).unwrap()).unwrap();
    marker["complete"] = json!(false);
    std::fs::write(store.marker("c1"), marker.to_string()).unwrap();
    std::thread::sleep(std::time::Duration::from_millis(2));
    let staged = store.stage_compaction("c1", mode).unwrap().unwrap();
    assert!(store.commit_compaction("c1", staged).unwrap());
    assert_eq!(passes(&archive, "c1").len(), 2);
    kept_all(&first[0]);
    // Appends after it go to the compacted log.
    store.append("c1", &record(16, "mux", "status", json!({"status": "idle"}))).unwrap();
    assert_eq!(log(&store, "c1").last().map(|r| r.seq), Some(16));
}

#[test]
fn a_compaction_a_crash_cut_short_is_done_again_and_still_lists() {
    let (_home, store) = Home::new();
    chat(&store, "c1");
    // What a crash between the record and the renames leaves: the record, not yet complete.
    let marker = json!({"lastSeq": 15, "at": 1, "complete": false, "bytesBefore": 0, "bytesAfter": 0, "dropped": 0, "trimmed": 0});
    std::fs::write(store.marker("c1"), marker.to_string()).unwrap();
    assert_eq!(store.compacted_seq("c1"), None, "a later pass compacts it again");
    let staged =
        store.stage_compaction("c1", CompactMode::Write { archive: None }).unwrap().unwrap();
    assert!(store.commit_compaction("c1", staged).unwrap());
    assert_eq!(store.compacted_seq("c1"), Some(15));
    assert_eq!(store.list().unwrap().len(), 1);
}

/// huge-blue, 2026-10-27: `--archive ~/archive/...` was refused because `~/archive` is
/// group-writable, and the pass archived nothing.
#[cfg(unix)]
#[test]
fn an_archive_under_a_group_writable_folder_is_kept_owner_only() {
    use std::os::unix::fs::PermissionsExt;
    let (home, store) = Home::new();
    chat(&store, "c1");
    let shared = home.0.join("shared");
    std::fs::create_dir_all(&shared).unwrap();
    std::fs::set_permissions(&shared, std::fs::Permissions::from_mode(0o775)).unwrap();
    let archive = shared.join("archive");
    let mode = CompactMode::Write { archive: Some(&archive) };
    let staged = store.stage_compaction("c1", mode).unwrap().unwrap();
    assert!(store.commit_compaction("c1", staged).unwrap());
    let pass = &passes(&archive, "c1")[0];
    for dir in [archive.clone(), archive.join("c1"), pass.clone(), pass.join("events")] {
        let mode = std::fs::metadata(&dir).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o700, "{}", dir.display());
    }
    assert!(pass.join("events/000001.ndjson").exists());
}

/// Another account that may write a folder above the archive puts a link where the chat's folder
/// goes: the pass refuses, and nothing is written where the link points.
#[cfg(unix)]
#[test]
fn an_archive_folder_replaced_by_a_link_is_refused() {
    use std::os::unix::fs::PermissionsExt;
    let (home, store) = Home::new();
    chat(&store, "c1");
    let archive = home.0.join("archive");
    let elsewhere = home.0.join("elsewhere");
    std::fs::create_dir_all(&archive).unwrap();
    std::fs::create_dir_all(&elsewhere).unwrap();
    std::fs::set_permissions(&archive, std::fs::Permissions::from_mode(0o775)).unwrap();
    std::os::unix::fs::symlink(&elsewhere, archive.join("c1")).unwrap();
    let mode = CompactMode::Write { archive: Some(&archive) };
    assert!(store.stage_compaction("c1", mode).is_err());
    assert_eq!(std::fs::read_dir(&elsewhere).unwrap().count(), 0, "nothing went through the link");
    // A chat folder another account made (writable by others) is refused too.
    std::fs::remove_file(archive.join("c1")).unwrap();
    std::fs::create_dir(archive.join("c1")).unwrap();
    std::fs::set_permissions(archive.join("c1"), std::fs::Permissions::from_mode(0o777)).unwrap();
    assert!(store.stage_compaction("c1", mode).is_err());
    assert_eq!(std::fs::read_dir(archive.join("c1")).unwrap().count(), 0);
    assert!(log(&store, "c1").len() == 15, "the log is as it was");
}

/// A link above the archive in a folder another account may write is refused; one only this user
/// could have made is followed.
#[cfg(unix)]
#[test]
fn a_link_above_the_archive_is_followed_only_when_no_one_else_could_have_made_it() {
    use std::os::unix::fs::PermissionsExt;
    let (home, store) = Home::new();
    chat(&store, "c1");
    let elsewhere = home.0.join("elsewhere");
    std::fs::create_dir_all(&elsewhere).unwrap();
    let shared = home.0.join("shared");
    std::fs::create_dir_all(&shared).unwrap();
    std::fs::set_permissions(&shared, std::fs::Permissions::from_mode(0o775)).unwrap();
    std::os::unix::fs::symlink(&elsewhere, shared.join("link")).unwrap();
    let archive = shared.join("link").join("archive");
    let mode = CompactMode::Write { archive: Some(&archive) };
    assert!(store.stage_compaction("c1", mode).is_err());
    assert_eq!(std::fs::read_dir(&elsewhere).unwrap().count(), 0, "nothing went through the link");
    // The same link in a folder only this user may write.
    let own = home.0.join("own");
    std::fs::create_dir_all(&own).unwrap();
    std::fs::set_permissions(&own, std::fs::Permissions::from_mode(0o700)).unwrap();
    std::os::unix::fs::symlink(&elsewhere, own.join("link")).unwrap();
    let archive = own.join("link").join("archive");
    let mode = CompactMode::Write { archive: Some(&archive) };
    let staged = store.stage_compaction("c1", mode).unwrap().unwrap();
    assert!(store.commit_compaction("c1", staged).unwrap());
    assert_eq!(passes(&elsewhere.join("archive"), "c1").len(), 1);
}
