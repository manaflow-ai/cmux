//! A Claude chat's log keeps its raw `assistant` and `user` lines without the bodies the
//! translated records carry (`claude_stdio/logged_bodies.rs`), and reads back the same.

use super::*;
use crate::agent::Direction;
use crate::store::EventRecord;

fn claude_chat(hub: &Hub, id: &str) -> Arc<Session> {
    let meta: SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": "claude chat", "harness": "claude",
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

fn update(update: Value) -> Message {
    Message::notification(
        crate::rpc::method::SESSION_UPDATE,
        json!({"sessionId": "acp-1", "update": update}),
    )
}

/// A turn as Claude Code and its translation send it: the prompt's echo, a thought, a command
/// with its output, and the answer. Each raw line as Claude Code wrote it (`claude.<type>`).
fn claude_turn() -> Vec<Message> {
    let output = "test result: ok. 412 passed\n".repeat(200);
    let input = json!({"command": "cargo test -p acpmux", "description": "Run the tests"});
    let usage = json!({"input_tokens": 2, "output_tokens": 8, "cache_read_input_tokens": 42494});
    let assistant = |block: Value| {
        Message::notification(
            "claude.assistant",
            json!({"type": "assistant", "parent_tool_use_id": null, "session_id": "cc-1",
                "uuid": "u-a", "request_id": "req_1",
                "message": {"id": "msg_1", "model": "claude-opus-5-5", "role": "assistant",
                    "type": "message", "stop_reason": null, "usage": usage, "content": [block]},
                "wire_tool_inputs": [input]}),
        )
    };
    vec![
        Message::notification(
            "claude.user",
            json!({"type": "user", "isReplay": true, "session_id": "cc-1", "uuid": "u-p",
                "parent_tool_use_id": null,
                "message": {"role": "user", "content": [{"type": "text", "text": "run the tests"}]}}),
        ),
        Message::notification(
            "claude.system.init",
            json!({"type": "system", "subtype": "init", "session_id": "cc-1",
                "model": "claude-opus-5-5", "tools": ["Bash", "Read"]}),
        ),
        assistant(
            json!({"type": "thinking", "thinking": "The tests first.", "signature": "CAQS4gUK".repeat(80)}),
        ),
        update(
            json!({"sessionUpdate": "agent_thought_chunk", "content": {"type": "text", "text": "The tests first."}}),
        ),
        assistant(json!({"type": "tool_use", "id": "toolu_1", "name": "Bash", "input": input})),
        update(
            json!({"sessionUpdate": "tool_call", "toolCallId": "toolu_1", "title": "cargo test -p acpmux", "kind": "execute", "status": "pending", "rawInput": input}),
        ),
        Message::notification(
            "claude.user",
            json!({"type": "user", "session_id": "cc-1", "uuid": "u-r", "parent_tool_use_id": null,
                "message": {"role": "user", "content": [{"type": "tool_result",
                    "tool_use_id": "toolu_1", "is_error": false, "content": output}]},
                "tool_use_result": {"stdout": output, "stderr": "", "interrupted": false},
                "tool_result_meta": {"duration_ms": 1234}}),
        ),
        update(
            json!({"sessionUpdate": "tool_call_update", "toolCallId": "toolu_1", "status": "completed",
            "content": [{"type": "content", "content": {"type": "text", "text": output}}]}),
        ),
        assistant(json!({"type": "text", "text": "All 412 tests pass."})),
        update(
            json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "All 412 tests pass."}}),
        ),
    ]
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

/// Leo, 2026-10-29: "as in i want ours to load fast too". A Claude turn's raw lines are logged
/// without the bodies its translated records carry: a block keeps what it is and its ids, the
/// line every field its readers take (optchat-chief's `fold.rs`: the message's id, model and
/// usage, the session, `parent_tool_use_id`, `isReplay`), and other raw kinds are as sent. The
/// log replays to the transcript of the turn as sent, in fewer bytes.
#[test]
fn a_claude_turns_raw_lines_are_logged_without_the_bodies_its_updates_carry() {
    let hub = hub();
    let s = claude_chat(&hub, "c");
    let tap = hub.session_tap(&s);
    let mut live = hub.events.subscribe();
    let turn = claude_turn();
    let mut heard = Vec::new();
    for msg in &turn {
        assert!(tap(Direction::In, msg, None));
        while let Ok(event) = live.try_recv() {
            heard.push((*event.record).clone());
        }
    }
    let logged = hub.store.events("c", 0, usize::MAX).unwrap();
    // A live subscriber (`eventStream`) hears each record as it is logged, the raw lines trimmed
    // alike (README, `_acpmux/attach`).
    assert_eq!(
        serde_json::to_value(&heard).unwrap(),
        serde_json::to_value(&logged).unwrap(),
        "live records are the logged ones"
    );
    let raw =
        |kind: &str| -> Vec<&EventRecord> { logged.iter().filter(|r| r.kind == kind).collect() };

    for line in raw("claude.assistant") {
        let m = &line.msg;
        assert_eq!(m["message"]["id"], "msg_1");
        assert_eq!(m["message"]["model"], "claude-opus-5-5");
        assert_eq!(m["message"]["usage"]["cache_read_input_tokens"], 42494);
        assert_eq!(m["session_id"], "cc-1");
        assert!(m.get("parent_tool_use_id").is_some_and(Value::is_null));
        assert!(m.get("wire_tool_inputs").is_none(), "{m}");
        assert!(m.pointer("/_acpmux/bodiesLeftOut").and_then(Value::as_u64).is_some_and(|n| n > 0));
        for block in m["message"]["content"].as_array().unwrap() {
            let keys: Vec<&str> = block.as_object().unwrap().keys().map(String::as_str).collect();
            assert!(keys.iter().all(|k| ["type", "id", "name"].contains(k)), "{block}");
        }
    }
    let call = raw("claude.assistant")[1];
    assert_eq!(
        call.msg["message"]["content"],
        json!([{"type": "tool_use", "id": "toolu_1", "name": "Bash"}])
    );

    let users = raw("claude.user");
    assert_eq!(users[0].msg["isReplay"], true);
    assert_eq!(users[0].msg["message"]["content"], json!([{"type": "text"}]));
    assert_eq!(
        users[1].msg["message"]["content"],
        json!([{"type": "tool_result", "tool_use_id": "toolu_1", "is_error": false}])
    );
    assert!(users[1].msg.get("tool_use_result").is_none());
    assert!(users[1].msg.get("tool_result_meta").is_none());

    let Message::Notification { params: Some(init), .. } = &turn[1] else { unreachable!() };
    assert_eq!(&raw("claude.system.init")[0].msg, init, "other raw kinds are as sent");

    let sent: Vec<EventRecord> = turn
        .iter()
        .enumerate()
        .map(|(i, msg)| {
            let Message::Notification { method, params: Some(params) } = msg else {
                unreachable!()
            };
            let kind = if method.starts_with("claude.") {
                method.clone()
            } else {
                params["update"]["sessionUpdate"].as_str().unwrap().to_owned()
            };
            let msg = if method.starts_with("claude.") { params.clone() } else { msg.to_value() };
            EventRecord { seq: i as u64 + 1, at: 0, dir: "in".into(), kind, msg, host_seq: None }
        })
        .collect();
    assert_eq!(transcript(&logged), transcript(&sent));
    assert!(
        bytes(&logged) * 10 < bytes(&sent) * 7,
        "{} logged of {} sent",
        bytes(&logged),
        bytes(&sent)
    );
}
