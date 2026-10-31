//! Superseded tool call content (`store/superseded.rs`).

use super::*;
use serde_json::json;

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

/// Each call as a reader that folds every record of it in order ends it (`mergeToolItem`): content
/// replaces, input keys merge, `_meta` keys merge (Codex's increments aside), any other field the
/// record names is set, the start is the first record's time, the end the first ending one's.
pub(super) fn fold(records: &[EventRecord]) -> BTreeMap<String, Map<String, Value>> {
    let mut calls: BTreeMap<String, Map<String, Value>> = BTreeMap::new();
    for rec in records {
        let Some(update) = rec.msg.pointer("/params/update").and_then(Value::as_object) else {
            continue;
        };
        let Some(id) = update.get("toolCallId").and_then(Value::as_str) else { continue };
        let call = calls.entry(id.to_owned()).or_default();
        call.entry("startedAt").or_insert(json!(rec.at));
        if matches!(update.get("status").and_then(Value::as_str), Some("completed" | "failed")) {
            call.entry("endedAt").or_insert(json!(rec.at));
        }
        for (key, value) in update {
            match (key.as_str(), value.as_object()) {
                ("rawInput" | "_meta", Some(parts)) => {
                    for (k, v) in parts
                        .iter()
                        .filter(|(k, _)| *k != "terminal_output_delta" && *k != "acpmux")
                    {
                        call.entry(key.clone()).or_insert_with(|| json!({}))[k] = v.clone();
                    }
                }
                _ => {
                    call.insert(key.clone(), value.clone());
                }
            }
        }
    }
    calls
}

/// A page's read of `log`, newest first: what stays, oldest first.
pub(super) fn read_back(log: &[EventRecord]) -> Vec<EventRecord> {
    let mut superseded = Superseded::default();
    let mut slots: Vec<Option<EventRecord>> = Vec::new();
    for rec in log.iter().rev() {
        let mut rec = rec.clone();
        if let Some(slot) = superseded.read(&mut rec, slots.len(), |_| true) {
            slots[slot] = None;
        }
        slots.push(Some(rec));
    }
    slots.into_iter().rev().flatten().collect()
}

fn content_of(rec: &EventRecord) -> Option<&Value> {
    rec.msg.pointer("/params/update/content").filter(|c| !c.is_null())
}

fn output(seq: u64, id: &str, text: &str) -> EventRecord {
    update(
        seq,
        "tool_call_update",
        json!({"sessionUpdate": "tool_call_update", "toolCallId": id, "content": [{"type": "content", "content": {"type": "text", "text": text}}], "_meta": {"terminal_output_delta": {"data": "x"}}}),
    )
}

#[test]
fn a_newest_first_read_keeps_each_call_as_it_ends_without_superseded_updates() {
    let log = codex_chat(3, 40, 64);
    let kept = read_back(&log);
    assert_eq!(fold(&kept), fold(&log), "every call ends as logged");
    // The prompts, starts, ends and answers stay; of the updates only each call's end.
    assert_eq!(kept.len(), 3 * 4, "{:#?}", kept.iter().map(|r| r.seq).collect::<Vec<_>>());
    assert!(kept.iter().all(|r| r.kind != "tool_call_update"
        || r.msg.pointer("/params/update/status") == Some(&json!("completed"))));
}

/// A read that starts after a call's start keeps the oldest update of it that it reads: the
/// reader takes the call's start time from there. Its content goes, as a newer update replaces it.
#[test]
fn a_read_without_the_calls_start_keeps_its_oldest_update_without_its_content() {
    let mut log: Vec<EventRecord> =
        (1..=6).map(|seq| output(seq, "c", &"o".repeat(seq as usize))).collect();
    log.push(update(7, "tool_call_update", json!({"sessionUpdate": "tool_call_update", "toolCallId": "c", "status": "completed", "content": [{"type": "content", "content": {"type": "text", "text": "done"}}]})));
    let kept = read_back(&log);
    assert_eq!(kept.iter().map(|r| r.seq).collect::<Vec<_>>(), [1, 7]);
    assert_eq!(fold(&kept), fold(&log), "it starts and ends as logged");
    assert_eq!(content_of(&kept[0]), None);
    assert_eq!(
        kept[0].msg.pointer("/params/update/_meta/acpmux/supersededContent"),
        Some(&json!(57))
    );
    assert_eq!(kept[1], log[6], "the newest update is untouched");
}

/// An update that carries anything but output (a title, an input, a diff, a subagent's `_meta`)
/// reads as logged: the reader's fold keeps parts of it no newer update names again.
#[test]
fn an_update_that_carries_more_than_output_stays_as_logged() {
    let newer = output(9, "c", "newer");
    for older in [
        json!({"title": "Read a.rs", "content": [{"type": "text", "text": "partial"}]}),
        json!({"rawInput": {"command": "echo hi"}, "content": [{"type": "text", "text": "hi"}]}),
        json!({"content": [{"type": "diff", "path": "a.rs", "oldText": "a", "newText": "b"}]}),
        json!({"content": [{"type": "content", "content": {"type": "text", "text": "t"}}], "_meta": {"codex": {"subagent": {"path": "/root/auditor", "model": "m"}}}}),
    ] {
        let mut u = json!({"sessionUpdate": "tool_call_update", "toolCallId": "c"});
        u.as_object_mut().unwrap().extend(older.as_object().unwrap().clone());
        let log = vec![
            update(1, "tool_call_update", u.clone()),
            update(2, "tool_call_update", u),
            newer.clone(),
        ];
        assert_eq!(read_back(&log), log, "{older}");
    }
    // Other calls' updates, and other records, are never touched.
    let log = vec![
        output(1, "a", "a"),
        output(2, "b", "b"),
        update(3, "agent_message_chunk", json!({"sessionUpdate": "agent_message_chunk"})),
    ];
    assert_eq!(read_back(&log), log);
}

/// A call id names a call within its prompt only: an adapter that numbers calls per process reuses
/// one in a later prompt (cx-jzhka). The later call never takes the earlier one's output away.
#[test]
fn a_call_id_a_later_prompt_reuses_supersedes_nothing_before_that_prompt() {
    let prompt = |seq| EventRecord {
        seq,
        at: seq,
        dir: "mux".into(),
        kind: "user_message".into(),
        msg: json!({"text": "again"}),
        host_seq: None,
    };
    let log = vec![
        prompt(1),
        output(2, "0", "first prompt's"),
        output(3, "0", "first prompt's output"),
        prompt(4),
        output(5, "0", "second prompt's output"),
    ];
    let kept = read_back(&log);
    assert_eq!(kept.iter().map(|r| r.seq).collect::<Vec<_>>(), [1, 2, 3, 4, 5]);
    assert_eq!(kept[2], log[2], "the first prompt's newest output is its own");
    assert_eq!(content_of(&kept[1]), None);
}

/// An update that clears its call's output (`content: null`) is a field of its own: a newer one
/// that names no content leaves it in the page.
#[test]
fn an_update_that_clears_the_output_stays() {
    let log = vec![
        output(1, "c", "stale"),
        update(
            2,
            "tool_call_update",
            json!({"sessionUpdate": "tool_call_update", "toolCallId": "c", "content": null}),
        ),
        update(
            3,
            "tool_call_update",
            json!({"sessionUpdate": "tool_call_update", "toolCallId": "c", "status": "completed"}),
        ),
    ];
    let kept = read_back(&log);
    // The clear stays; the output it clears may go, as nothing reads it after the clear.
    assert_eq!(kept.iter().map(|r| r.seq).collect::<Vec<_>>(), [1, 2, 3]);
    assert_eq!(kept[1..], log[1..]);
    assert_eq!(fold(&kept), fold(&log), "the call ends with no output, as logged");
}

/// A native subagent numbers its calls apart from its chat's (`params._meta.acpmux.subagent`):
/// its call `c` supersedes nothing of the chat's call `c`.
#[test]
fn a_subagents_call_supersedes_nothing_of_its_chats_call_of_the_same_id() {
    let mut child = output(2, "c", "child's output");
    child.msg["params"]["_meta"] = json!({"acpmux": {"subagent": "toolu_task"}});
    let log = vec![output(1, "c", "chat's output"), child];
    assert_eq!(read_back(&log), log);
    // A `_meta` of any other shape is read as it is: never plain.
    for meta in [json!(null), json!("x"), json!({"acpmux": {"subagent": "t", "other": 1}})] {
        let mut older = output(1, "c", "older");
        older.msg["params"]["_meta"] = meta;
        let log = vec![older, output(2, "c", "newer")];
        assert_eq!(read_back(&log), log);
    }
}

/// A record a page sends as a stub (too big for a message) carries none of its output: it
/// supersedes nothing older.
#[test]
fn an_update_too_big_to_send_supersedes_nothing() {
    let log = [output(1, "c", "small"), output(2, "c", "too big")];
    let mut superseded = Superseded::default();
    let (mut newest, mut older) = (log[1].clone(), log[0].clone());
    assert_eq!(superseded.read(&mut newest, 0, |_| false), None);
    assert_eq!(superseded.read(&mut older, 1, |_| true), None);
    assert_eq!(older, log[0], "the older output is the one the reader gets");
}
