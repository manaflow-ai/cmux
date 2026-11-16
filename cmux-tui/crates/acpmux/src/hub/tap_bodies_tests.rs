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

// Pure-table parity only. Stateful update normalization (plans, subagents, suggestions,
// reply stamps and output files) has its own stage and is deliberately not claimed here.
#[cfg(test)]
mod pure_table {
    use super::*;
    use acpmux_core::chat::record::{self, Context, Entry};

    fn entry(dir: Direction, msg: &Message) -> Entry<'_> {
        let direction = match dir {
            Direction::In => record::Direction::In,
            Direction::Out => record::Direction::Out,
        };
        match msg {
            Message::Notification { method, params } if method == crate::agent::HOST_STDERR => {
                Entry::Stderr {
                    text: params
                        .as_ref()
                        .and_then(|p| p.get("text"))
                        .cloned()
                        .unwrap_or(Value::Null),
                }
            }
            Message::Notification { method, params } if method == crate::agent::HOST_EXIT => {
                Entry::Exit {
                    code: params
                        .as_ref()
                        .and_then(|p| p.get("code"))
                        .cloned()
                        .unwrap_or(Value::Null),
                }
            }
            Message::Notification { method, .. } => {
                Entry::Notification { direction, method, value: msg.to_value() }
            }
            Message::Request { method, .. } => {
                Entry::Request { direction, method, value: msg.to_value() }
            }
            Message::Response { .. } => Entry::Response { direction, value: msg.to_value() },
        }
    }

    fn compare(
        hub: &Arc<Hub>,
        s: &Arc<Session>,
        tap: &crate::agent::Tap,
        context: &mut Context,
        direction: Direction,
        msg: Message,
        eligible_update: bool,
    ) {
        let before = hub.store.events(&s.id, 0, usize::MAX).unwrap();
        let mut prepared = record::record_of(entry(direction, &msg), context);
        if eligible_update && prepared.as_mut().is_some_and(|r| !r.trim_live_update(context)) {
            prepared = None;
        }
        assert!(tap(direction, &msg, Some(71)));
        let after = hub.store.events(&s.id, 0, usize::MAX).unwrap();
        // Hub side effects can append separate records without this host number.
        // This test compares the pure table's record, not those stateful effects.
        let added: Vec<_> =
            after[before.len()..].iter().filter(|r| r.host_seq == Some(71)).collect();
        if let Some(prepared) = prepared {
            assert_eq!(added.len(), 1, "{}", msg.to_value());
            let actual = added[0];
            assert_eq!(
                serde_json::to_vec(&prepared.event(actual.seq, actual.at, Some(71))).unwrap(),
                serde_json::to_vec(actual).unwrap(),
                "{}",
                msg.to_value()
            );
            prepared.note_logged(context);
        } else {
            assert!(added.is_empty(), "{}", msg.to_value());
        }
    }

    #[test]
    fn v2_record_pure_table_matches_v1_tap_bytes_and_skips() {
        let hub = hub();
        let s = claude_chat(&hub, "pure-table");
        let tap = hub.session_tap(&s);
        let mut context = Context { turn_open: true, ..Context::default() };
        let long = "long prompt ".repeat(300);
        let messages = vec![
            (
                Direction::In,
                json!({"method":"claude.control_response","params":{"response":{"request_id":"ctx-1"}}}),
            ),
            (
                Direction::In,
                json!({"method":"claude.stream_event","params":{"event":{"type":"content_block_delta"}}}),
            ),
            (
                Direction::In,
                json!({"method":"claude.stream_event","params":{"event":{"type":"message_start"}}}),
            ),
            (
                Direction::In,
                json!({"method":"claude.stream_event","params":{"parent_tool_use_id":"child","event":{"type":"content_block_delta"}}}),
            ),
            (
                Direction::In,
                json!({"method":"claude.stream_event","params":{"event":{"type":"content_block_delta"}}}),
            ),
            (
                Direction::In,
                json!({"method":"claude.stream_event","params":{"event":{"type":"content_block_delta"}}}),
            ),
            (
                Direction::In,
                json!({"method":"claude.system.init","params":{"tools":["Read"],"model":"model"}}),
            ),
            (
                Direction::In,
                json!({"method":"claude.system.init","params":{"tools":["Read"],"model":"model"}}),
            ),
            (
                Direction::In,
                json!({"method":"claude.control_response","params":{"response":{"request_id":"init-1","response":{"commands":["help"]}}}}),
            ),
            (
                Direction::In,
                json!({"method":"claude.control_response","params":{"response":{"request_id":"init-2","response":{"commands":["help"]}}}}),
            ),
            (
                Direction::In,
                json!({"method":"claude.assistant","params":{"message":{"id":"m1","content":[{"type":"text","text":"body"}]}}}),
            ),
            (
                Direction::Out,
                json!({"method":"claude.stdin","params":{"type":"user","message":{"content":long}}}),
            ),
            (
                Direction::Out,
                json!({"id":1,"method":"session/prompt","params":{"prompt":[{"type":"text","text":long}]}}),
            ),
            (
                Direction::In,
                json!({"id":2,"method":"session/request_permission","params":{"toolCall":{"title":"ask","_meta":{"acpmux":{"display":"untrusted"}}}}}),
            ),
            (Direction::In, json!({"id":3,"result":{"_meta":{"claude":{"commands":["help"]}}}})),
            (Direction::In, json!({"id":4,"result":{"_meta":{"claude":{"commands":["help"]}}}})),
            (Direction::Out, json!({"id":5,"result":{"ok":true}})),
            (
                Direction::Out,
                json!({"method":"session/update","params":{"update":{"sessionUpdate":"outgoing"}}}),
            ),
            (Direction::In, json!({"method":"claude.unknown"})),
            (Direction::In, json!({"method":crate::agent::HOST_STDERR,"params":{"text":"stderr"}})),
        ];
        for (direction, value) in messages {
            compare(
                &hub,
                &s,
                &tap,
                &mut context,
                direction,
                Message::from_value(value).unwrap(),
                false,
            );
        }
        for loading in [false, false, true] {
            context.loading = loading;
            s.loading.store(loading, Ordering::SeqCst);
            compare(
                &hub,
                &s,
                &tap,
                &mut context,
                Direction::In,
                update(
                    json!({"sessionUpdate":"available_commands_update","availableCommands":[{"name":"help"}]}),
                ),
                true,
            );
        }
    }

    #[test]
    fn v2_record_exit_table_matches_v1_including_reconstructed_context() {
        for status in [SessionStatus::Running, SessionStatus::Idle, SessionStatus::Closed] {
            for hibernate in [false, true] {
                let hub = hub();
                let s = claude_chat(&hub, "exit-table");
                s.meta.lock().unwrap().status = status;
                s.hibernated_at.store(u64::from(hibernate), Ordering::SeqCst);
                let tap = hub.session_tap(&s);
                // These fields are reconstructed from claim/mark lines after a restart.
                let mut context = Context {
                    turn_open: status == SessionStatus::Running,
                    closed: status == SessionStatus::Closed,
                    hibernate,
                    ..Context::default()
                };
                compare(
                    &hub,
                    &s,
                    &tap,
                    &mut context,
                    Direction::In,
                    Message::notification(crate::agent::HOST_EXIT, json!({"code": 7})),
                    false,
                );
            }
        }
    }

    #[test]
    fn v2_record_failed_append_keeps_repeat_state_and_harness_restart_resets_timing() {
        let mut context = Context::default();
        let msg = Message::notification("claude.system.init", json!({"tools":["Read"]}));
        let failed = record::record_of(entry(Direction::In, &msg), &mut context).unwrap();
        let bytes = serde_json::to_vec(&failed.event(1, 2, Some(3))).unwrap();
        drop(failed);
        let retry = record::record_of(entry(Direction::In, &msg), &mut context).unwrap();
        assert_eq!(bytes, serde_json::to_vec(&retry.event(1, 2, Some(3))).unwrap());
        retry.note_logged(&mut context);
        let repeated = record::record_of(entry(Direction::In, &msg), &mut context).unwrap();
        assert!(repeated.msg.get("tools").is_none());
        let start =
            Message::notification("claude.stream_event", json!({"event":{"type":"message_start"}}));
        assert!(record::record_of(entry(Direction::In, &start), &mut context).is_some());
        context.harness_started();
        let delta = Message::notification(
            "claude.stream_event",
            json!({"event":{"type":"content_block_delta"}}),
        );
        assert!(record::record_of(entry(Direction::In, &delta), &mut context).is_none());
    }
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

/// Leo, 2026-11-09: "we should fix those too." Claude Code's whole system/init at every turn was
/// ~99 MB a day of the log; through the tap a session's second init keeps its scalars and names
/// the sections it left out (`claude_stdio/logged_init.rs`).
#[test]
fn a_repeated_system_init_is_logged_without_its_unchanged_sections() {
    let hub = hub();
    let s = claude_chat(&hub, "i");
    let tap = hub.session_tap(&s);
    let init = |uuid: &str| {
        Message::notification(
            "claude.system.init",
            json!({"type": "system", "subtype": "init", "session_id": "cc-1", "uuid": uuid,
                "tools": ["Bash", "Read"], "slash_commands": ["compact", "review"]}),
        )
    };
    assert!(tap(Direction::In, &init("u1"), None));
    assert!(tap(Direction::In, &init("u2"), None));
    let logged = hub.store.events("i", 0, usize::MAX).unwrap();
    let inits: Vec<&EventRecord> =
        logged.iter().filter(|r| r.kind == "claude.system.init").collect();
    assert_eq!(inits[0].msg["slash_commands"], json!(["compact", "review"]));
    assert_eq!(
        inits[1].msg,
        json!({"type": "system", "subtype": "init", "session_id": "cc-1", "uuid": "u2",
            "_acpmux": {"sameAsLastInit": ["slash_commands", "tools"]}})
    );
}

/// Through the tap, Claude Code's state updates that repeat the last logged ones are not logged
/// again (`update_repeats.rs`), while the session's meta still takes each one (`on_update`).
#[test]
fn repeated_state_updates_are_not_logged_again() {
    let hub = hub();
    let s = claude_chat(&hub, "r");
    let tap = hub.session_tap(&s);
    let tools = update(json!({"sessionUpdate": "session_info_update", "title": null,
        "_meta": {"claude": {"tools": ["Bash"], "mcp_servers": [], "version": "2.1.400"}}}));
    let context = update(json!({"sessionUpdate": "session_info_update",
        "_meta": {"acpmux": {"contextBreakdown": {"total": 7}}}}));
    for msg in [&tools, &context, &tools, &context, &tools] {
        assert!(tap(Direction::In, msg, None));
    }
    let logged = hub.store.events("r", 0, usize::MAX).unwrap();
    let infos: Vec<&EventRecord> =
        logged.iter().filter(|r| r.kind == "session_info_update").collect();
    // Each system/init's update keeps its scalars (a paged attach reads the session start from
    // them); its lists and the unchanged breakdown are logged once.
    assert_eq!(infos.len(), 4, "{logged:?}");
    let with_tools =
        infos.iter().filter(|r| r.msg.pointer("/params/update/_meta/claude/tools").is_some());
    assert_eq!(with_tools.count(), 1);
    let breakdowns = infos
        .iter()
        .filter(|r| r.msg.pointer("/params/update/_meta/acpmux/contextBreakdown").is_some());
    assert_eq!(breakdowns.count(), 1);
    // Every init's record names Claude Code's version, so the newest page alone has the start.
    let versions = infos.iter().filter(|r| {
        r.msg.pointer("/params/update/_meta/claude/version") == Some(&json!("2.1.400"))
    });
    assert_eq!(versions.count(), 3);
}
