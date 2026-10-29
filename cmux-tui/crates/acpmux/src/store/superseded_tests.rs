//! Superseded tool call content (`store/superseded.rs`).

use super::*;
use serde_json::json;

struct Home(PathBuf);

impl Home {
    fn new() -> (Self, PathBuf) {
        let path = std::env::temp_dir().join(format!("acpmux-superseded-{}", uuid::Uuid::now_v7()));
        (Self(path.clone()), path.join("sessions"))
    }
}

impl Drop for Home {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn update(seq: u64, kind: &str, update: Value) -> EventRecord {
    let msg = json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "a", "update": update}});
    EventRecord { seq, at: seq, dir: "in".into(), kind: kind.into(), msg, host_seq: None }
}

/// A Codex chat's log as codex-acp leaves it: per call a start, `steps` updates that each carry
/// the whole output so far and its increment, and an end with the whole output.
fn codex_chat(calls: usize, steps: usize, step_bytes: usize) -> Vec<EventRecord> {
    let mut seq = 0;
    let mut next = || {
        seq += 1;
        seq
    };
    let mut out = Vec::new();
    for call in 0..calls {
        let id = format!("call_{call}");
        let msg = json!({"text": format!("prompt {call}")});
        out.push(EventRecord {
            seq: next(),
            at: 0,
            dir: "mux".into(),
            kind: "user_message".into(),
            msg,
            host_seq: None,
        });
        out.push(update(next(), "tool_call", json!({"sessionUpdate": "tool_call", "toolCallId": id, "title": format!("cargo test {call}"), "kind": "execute", "status": "in_progress", "rawInput": {"command": ["cargo", "test"]}})));
        let mut output = String::new();
        for step in 0..steps {
            let piece = format!("{step:06} {}\n", "o".repeat(step_bytes.saturating_sub(8)));
            output.push_str(&piece);
            let meta = json!({"terminal_output_delta": {"data": piece}});
            // codex-acp sends the whole output with some of them, the increment with each.
            let mut u =
                json!({"sessionUpdate": "tool_call_update", "toolCallId": id, "_meta": meta});
            if step % 7 != 3 {
                u["content"] =
                    json!([{"type": "content", "content": {"type": "text", "text": output}}]);
            }
            out.push(update(next(), "tool_call_update", u));
        }
        out.push(update(next(), "tool_call_update", json!({"sessionUpdate": "tool_call_update", "toolCallId": id, "status": "completed", "title": format!("cargo test {call}"), "kind": "execute", "rawOutput": {"exit_code": 0}, "content": [{"type": "content", "content": {"type": "text", "text": output}}]})));
        let chunk = json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": format!("answer {call}")}});
        out.push(update(next(), "agent_message_chunk", chunk));
    }
    out
}

/// Each call as a reader that folds every update in order ends it: content replaces, any other
/// field the update names is set.
fn fold(records: &[EventRecord]) -> BTreeMap<String, Map<String, Value>> {
    let mut calls: BTreeMap<String, Map<String, Value>> = BTreeMap::new();
    for rec in records {
        let Some(update) = rec.msg.pointer("/params/update").and_then(Value::as_object) else {
            continue;
        };
        let Some(id) = update.get("toolCallId").and_then(Value::as_str) else { continue };
        let call = calls.entry(id.to_owned()).or_default();
        for (key, value) in update {
            if key != "_meta" {
                call.insert(key.clone(), value.clone());
            }
        }
    }
    calls
}

fn content_of(rec: &EventRecord) -> Option<&Value> {
    rec.msg.pointer("/params/update/content").filter(|c| !c.is_null())
}

#[test]
fn a_newest_first_read_keeps_each_call_as_it_ends_without_superseded_updates() {
    let log = codex_chat(3, 40, 64);
    let mut superseded = Superseded::default();
    let mut kept: Vec<EventRecord> = log
        .iter()
        .rev()
        .cloned()
        .filter_map(|mut rec| superseded.keep(&mut rec).then_some(rec))
        .collect();
    kept.reverse();
    assert_eq!(fold(&kept), fold(&log), "every call ends as logged");
    // The prompts, starts, ends and answers stay; of the updates only each call's end.
    assert_eq!(kept.len(), 3 * 4, "{:#?}", kept.iter().map(|r| r.seq).collect::<Vec<_>>());
    assert!(kept.iter().all(|r| r.kind != "tool_call_update"
        || r.msg.pointer("/params/update/status") == Some(&json!("completed"))));
}

#[test]
fn an_update_with_a_field_no_newer_one_carries_stays_without_its_content() {
    let id = "toolu_1";
    let older = update(
        1,
        "tool_call_update",
        json!({"sessionUpdate": "tool_call_update", "toolCallId": id, "title": "Read a.rs", "rawInput": {"file_path": "a.rs"}, "content": [{"type": "text", "text": "partial"}]}),
    );
    let newer = update(
        2,
        "tool_call_update",
        json!({"sessionUpdate": "tool_call_update", "toolCallId": id, "status": "completed", "content": [{"type": "text", "text": "whole"}]}),
    );
    let mut superseded = Superseded::default();
    let mut newest = newer.clone();
    assert!(superseded.keep(&mut newest));
    assert_eq!(newest, newer, "the newest update is untouched");
    let mut rec = older.clone();
    assert!(superseded.keep(&mut rec), "its title and input are its own");
    assert_eq!(content_of(&rec), None);
    assert_eq!(rec.msg.pointer("/params/update/title"), Some(&json!("Read a.rs")));
    assert_eq!(rec.msg.pointer("/params/update/_meta/acpmux/supersededContent"), Some(&json!(34)));
    // A call's end stays even when a newer update names everything it does.
    let mut superseded = Superseded::default();
    let mut end = newer.clone();
    end.seq = 3;
    assert!(superseded.keep(&mut end));
    let mut rec = newer.clone();
    assert!(superseded.keep(&mut rec));
    assert_eq!(content_of(&rec), None);
    // Other records, and other calls' updates, are never touched.
    let mut other = update(
        0,
        "tool_call_update",
        json!({"sessionUpdate": "tool_call_update", "toolCallId": "toolu_2", "content": []}),
    );
    let before = other.clone();
    assert!(superseded.keep(&mut other));
    assert_eq!(other, before);
}

/// The records of every segment of chat `id`, by segment.
fn segments(store: &LocalStore, id: &str) -> Vec<(PathBuf, Vec<u8>, Vec<EventRecord>)> {
    store
        .segments(id)
        .unwrap()
        .into_iter()
        .map(|(_, path)| {
            let bytes = std::fs::read(&path).unwrap();
            let records = bytes
                .split(|b| *b == b'\n')
                .filter(|l| !l.is_empty())
                .map(|l| serde_json::from_slice::<EventRecord>(l).unwrap())
                .collect();
            (path, bytes, records)
        })
        .collect()
}

#[test]
fn a_sealed_segment_loses_only_content_a_later_update_in_it_supersedes() {
    let (_home, root) = Home::new();
    let store = LocalStore::new(root, 64 * 1024).unwrap();
    let log = codex_chat(4, 60, 90);
    for rec in &log {
        store.append("c", rec).unwrap();
    }
    let before = segments(&store, "c");
    assert!(before.len() > 4, "the log spans several segments: {}", before.len());
    let events = store.dir("c").join("events");
    let stats = compact_sealed(&events).unwrap();
    let after = segments(&store, "c");
    assert_eq!(after.len(), before.len());
    assert!(stats.trimmed > 0 && stats.bytes_after * 3 < stats.bytes_before, "{stats:?}");
    // The newest segment, the one appends go to, is never rewritten.
    assert_eq!(after.last().unwrap().1, before.last().unwrap().1);
    for ((_, _, old), (_, _, new)) in before.iter().zip(&after) {
        assert_eq!(
            new.iter().map(|r| r.seq).collect::<Vec<_>>(),
            old.iter().map(|r| r.seq).collect::<Vec<_>>()
        );
        for (i, (o, n)) in old.iter().zip(new).enumerate() {
            let later = old[i + 1..].iter().any(|r| {
                content_of(r).is_some()
                    && r.msg.pointer("/params/update/toolCallId")
                        == o.msg.pointer("/params/update/toolCallId")
            });
            if o.kind == "tool_call_update" && content_of(o).is_some() && later {
                assert_eq!(content_of(n), None, "seq {}", o.seq);
                let mut expected = o.clone();
                let u =
                    expected.msg.pointer_mut("/params/update").unwrap().as_object_mut().unwrap();
                let bytes = serde_json::to_string(&u.remove("content").unwrap()).unwrap().len();
                u["_meta"]["acpmux"] = json!({"supersededContent": bytes});
                assert_eq!(*n, expected, "only the content goes, the increment stays");
            } else {
                assert_eq!(n, o, "seq {}", o.seq);
            }
        }
    }
    let all: Vec<EventRecord> = after.iter().flat_map(|(_, _, r)| r.clone()).collect();
    assert_eq!(fold(&all), fold(&log), "every call ends as logged");
    // Done once: the marker holds the newest sealed segment, and a second pass reads nothing.
    assert_eq!(read_marker(&events).through as usize, after.len() - 1);
    assert_eq!(compact_sealed(&events).unwrap(), Compaction::default());
    assert!(!waiting(&events).unwrap());
}

#[test]
fn the_daemon_store_compacts_a_segment_once_it_is_sealed() {
    let (_home, root) = Home::new();
    let store = LocalStore::new(root, 64 * 1024).unwrap().compacting_sealed();
    let log = codex_chat(3, 60, 90);
    let raw: usize = log.iter().map(|r| serde_json::to_vec(r).unwrap().len() + 1).sum();
    for rec in &log {
        store.append("c", rec).unwrap();
    }
    // Its thread ends once no sealed segment waits (bounded: a test that never ends fails).
    let started = std::time::Instant::now();
    while store.sealing_now("c") {
        assert!(
            started.elapsed() < std::time::Duration::from_secs(30),
            "the sealed segments' thread never ended"
        );
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
    let events = store.dir("c").join("events");
    assert!(!waiting(&events).unwrap());
    let on_disk: usize = segments(&store, "c").iter().map(|(_, b, _)| b.len()).sum();
    assert!(on_disk * 2 < raw, "{on_disk} of {raw} bytes");
    let all: Vec<EventRecord> = segments(&store, "c").into_iter().flat_map(|(_, _, r)| r).collect();
    assert_eq!(all.len(), log.len());
    assert_eq!(fold(&all), fold(&log));
}
