//! A Codex chat's log keeps one snapshot per stretch of a command's output (`store/deferred.rs`).

use super::*;
use crate::store::EventRecord;

fn session(hub: &Hub, id: &str) -> Arc<Session> {
    let meta: SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": "codex chat", "harness": "codex",
        "cwd": "/tmp", "status": "running", "createdAt": 1, "updatedAt": 1
    }))
    .unwrap();
    hub.store.save(&meta).unwrap();
    hub.make_session(meta)
}

fn hub() -> Arc<Hub> {
    let mut config = Config::default();
    config.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/unused")).unwrap();
    Hub::new(config, store)
}

fn update(update: Value) -> Value {
    json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "a", "update": update}})
}

/// A Codex chat as codex-acp sends it: per turn a prompt, a command whose updates each carry its
/// increment and, every few, its whole output so far, its end (with the output on even turns,
/// without on odd ones) and an answer. The last command is still running.
fn codex_chat(turns: usize, steps: usize) -> Vec<(&'static str, String, Value)> {
    let mut out = Vec::new();
    for turn in 0..turns {
        let id = format!("call_{turn}");
        out.push(("mux", "user_message".to_owned(), json!({"text": format!("prompt {turn}")})));
        out.push(("in", "tool_call".to_owned(), update(json!({"sessionUpdate": "tool_call", "toolCallId": id, "title": "cargo test", "kind": "execute", "status": "in_progress"}))));
        let mut output = String::new();
        for step in 0..steps {
            let piece = format!("{step:06} {}\n", "o".repeat(80));
            output.push_str(&piece);
            let mut u = json!({"sessionUpdate": "tool_call_update", "toolCallId": id, "_meta": {"terminal_output_delta": {"data": piece}}});
            if step % 4 == 0 {
                u["content"] =
                    json!([{"type": "content", "content": {"type": "text", "text": output}}]);
            }
            out.push(("in", "tool_call_update".to_owned(), update(u)));
        }
        if turn + 1 == turns {
            break;
        }
        let mut end = json!({"sessionUpdate": "tool_call_update", "toolCallId": id, "status": "completed", "rawOutput": {"exit_code": 0}});
        if turn % 2 == 0 {
            end["content"] =
                json!([{"type": "content", "content": {"type": "text", "text": output}}]);
        }
        out.push(("in", "tool_call_update".to_owned(), update(end)));
        out.push(("in", "agent_message_chunk".to_owned(), update(json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": format!("answer {turn}")}}))));
        out.push((
            "mux",
            "turn_result".to_owned(),
            json!({"status": "completed", "stopReason": "end_turn"}),
        ));
    }
    out
}

fn transcript(records: &[EventRecord]) -> Vec<crate::transcript::Item> {
    let mut t = crate::transcript::Transcript::default();
    for rec in records {
        t.apply_event(&serde_json::to_value(rec).unwrap());
    }
    t.items
}

fn bytes(records: &[EventRecord]) -> usize {
    records.iter().map(|r| serde_json::to_string(r).unwrap().len() + 1).sum()
}

/// Leo, 2026-10-29: "as in i want ours to load fast too". The log a chat restarts and opens from
/// replays to the transcript its live stream showed, at every turn's end and after shutdown, and
/// is under half the bytes.
#[test]
fn a_codex_chats_log_replays_as_its_live_stream_at_half_the_bytes() {
    let hub = hub();
    let s = session(&hub, "c");
    let mut live = hub.events.subscribe();
    let chat = codex_chat(5, 64);
    let mut heard = Vec::new();
    for (dir, kind, msg) in &chat {
        hub.append(&s, dir, kind, msg.clone());
        while let Ok(event) = live.try_recv() {
            heard.push((*event.record).clone());
        }
    }
    // Clients hear every record as sent, in order.
    let sent: Vec<_> = heard
        .iter()
        .filter(|r| r.msg.pointer("/params/update/_meta/acpmux").is_none())
        .map(|r| r.msg.clone())
        .collect();
    let originals: Vec<_> = chat.iter().map(|(_, _, m)| m.clone()).collect();
    assert!(originals.iter().all(|m| sent.contains(m)));
    let logged = hub.store.events("c", 0, usize::MAX).unwrap();
    // At each turn's end the log replays to what the stream showed then.
    for end in logged.iter().filter(|r| r.kind == "turn_result") {
        let upto = |records: &[EventRecord]| -> Vec<EventRecord> {
            records.iter().filter(|r| r.seq <= end.seq).cloned().collect()
        };
        assert_eq!(transcript(&upto(&logged)), transcript(&upto(&heard)), "at seq {}", end.seq);
    }
    // The running command's newest output is stored at shutdown.
    hub.store_deferred(&s);
    let logged = hub.store.events("c", 0, usize::MAX).unwrap();
    assert_eq!(transcript(&logged), transcript(&heard));
    let sent_bytes = bytes(&heard);
    let logged_bytes = bytes(&logged);
    assert!(logged_bytes * 2 < sent_bytes, "{logged_bytes} logged of {sent_bytes} sent");
}

/// A fork's copy of its parent's records (`append_at` with a time) is stored as copied.
#[test]
fn a_copied_record_is_stored_whole() {
    let hub = hub();
    let s = session(&hub, "f");
    let chat = codex_chat(1, 8);
    for (dir, kind, msg) in &chat {
        let _ = hub.append_at(&s, dir, kind, msg.clone(), None, Some(5));
    }
    let logged: Vec<_> =
        hub.store.events("f", 0, usize::MAX).unwrap().into_iter().map(|r| r.msg).collect();
    assert_eq!(logged, chat.into_iter().map(|(_, _, m)| m).collect::<Vec<_>>());
}
