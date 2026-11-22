//! A chat's log grows by what its readers take back, not by what its harness repeats
//! (`unread_records.rs`): a wake costs the same bytes whatever the chat's history, a Claude tool
//! call adds its own records and no hook traffic, and a thinking tick adds nothing. Restart-resume
//! and the subagents a log rebuilds read the same without the replays.

use super::*;
use crate::agent::Direction;

fn new_hub() -> Arc<Hub> {
    let mut config = Config::default();
    config.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/unused")).unwrap();
    Hub::new(config, store)
}

fn chat(hub: &Hub, id: &str, harness: &str) -> Arc<Session> {
    let meta: SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": id, "harness": harness,
        "cwd": "/tmp", "status": "running", "createdAt": 1, "updatedAt": 1,
        "agentSessionId": "s1"
    }))
    .unwrap();
    hub.store.save(&meta).unwrap();
    hub.make_session(meta)
}

fn log_bytes(hub: &Hub, id: &str) -> usize {
    let records = hub.store.events(id, 0, usize::MAX).unwrap();
    records.iter().map(|r| serde_json::to_string(r).unwrap().len() + 1).sum()
}

fn update(update: Value) -> Message {
    Message::notification(
        crate::rpc::method::SESSION_UPDATE,
        json!({"sessionId": "s1", "update": update}),
    )
}

fn tool(id: &str, status: &str) -> Value {
    json!({"sessionUpdate": "tool_call", "toolCallId": id, "title": format!("cargo test {id}"),
        "kind": "execute", "status": status, "rawInput": {"command": format!("cargo test {id}")}})
}

/// The history a Codex `session/load` replays, `turns` turns of it, and the `thread/resume`
/// answer before it, which carries the same turns.
fn codex_wake(turns: usize) -> Vec<Message> {
    let text = "The build passes and the tests are green. ".repeat(20);
    let output = "test result: ok. 412 passed\n".repeat(40);
    let thread_turns: Vec<Value> = (0..turns)
        .map(|n| {
            json!({"id": format!("turn-{n}"), "status": "completed", "items": [
                {"type": "userMessage", "content": [{"type": "text", "text": format!("prompt {n}")}]},
                {"type": "commandExecution", "command": "cargo test", "aggregatedOutput": output},
                {"type": "agentMessage", "text": text}]})
        })
        .collect();
    // As the agent's reader hands it to the tap (`agent.rs`, `agent_host/host.rs`).
    let mut wake = vec![Message::notification(
        "codex.response",
        crate::codex_app_server::logged(&json!({"id": 2, "result": {"thread": {"id": "th-1",
            "preview": "prompt 0", "turns": thread_turns}, "model": "gpt-5.5", "cwd": "/tmp"}})),
    )];
    for n in 0..turns {
        let id = format!("call-{n}");
        wake.push(update(json!({"sessionUpdate": "user_message_chunk",
            "content": {"type": "text", "text": format!("prompt {n}")}})));
        wake.push(update(tool(&id, "in_progress")));
        wake.push(update(json!({"sessionUpdate": "tool_call_update", "toolCallId": id,
            "status": "completed",
            "content": [{"type": "content", "content": {"type": "text", "text": output}}]})));
        wake.push(update(json!({"sessionUpdate": "agent_message_chunk",
            "content": {"type": "text", "text": text}})));
    }
    wake.push(update(json!({"sessionUpdate": "current_mode_update", "currentModeId": "auto"})));
    wake
}

/// Wakes `session` `times` times, each a load that replays `turns` turns: the log bytes each adds.
fn bytes_per_wake(hub: &Arc<Hub>, session: &Arc<Session>, turns: usize, times: usize) -> usize {
    let tap = hub.session_tap(session);
    let before = log_bytes(hub, &session.id);
    for _ in 0..times {
        session.loading.store(true, Ordering::SeqCst);
        for msg in codex_wake(turns) {
            assert!(tap(Direction::In, &msg, None));
        }
        session.loading.store(false, Ordering::SeqCst);
    }
    (log_bytes(hub, &session.id) - before) / times
}

/// Leo, 2026-11-18: "Ok... we need to get fable 5.2 on the case for unfucking more boneheaded
/// designs". A Codex chat woke from hibernation 569 times held 1.2 GB for 3 turns: each wake
/// logged its whole history twice, in the `thread/resume` answer and as `.replay` records no
/// reader takes back. A wake now adds the same bytes whatever the history: the answer without
/// its turns, and the mode the load reports (`full_access_bound.rs` reads it back).
#[test]
fn a_codex_wake_logs_the_same_bytes_whatever_the_chats_history() {
    let hub = new_hub();
    let short = chat(&hub, "short", "codex");
    let long = chat(&hub, "long", "codex");
    let small = bytes_per_wake(&hub, &short, 3, 20);
    let large = bytes_per_wake(&hub, &long, 300, 20);
    println!("log bytes per wake: 3 turns {small}, 300 turns {large}");
    assert!(large <= small + 64, "a wake grows with the history: 3 turns {small}, 300 {large}");
    assert!(large < 2048, "a wake logs {large} bytes");
    let logged = hub.store.events("long", 0, usize::MAX).unwrap();
    let modes = logged.iter().filter(|r| r.kind == "current_mode_update.replay").count();
    assert_eq!(modes, 20, "each load's mode report is read back after a restart");
    let answer = logged.iter().find(|r| r.kind == "codex.response").unwrap();
    assert_eq!(answer.msg.pointer("/params/result/thread/id"), Some(&json!("th-1")));
    assert_eq!(answer.msg.pointer("/params/result/model"), Some(&json!("gpt-5.5")));
}

/// hq#19257: a Codex chat's log on a lane host was 13.7 GiB, 0.64 GiB of it the chat; every resume
/// (a wake every 1-2 h) appended the whole history so far again as `.replay` records, about
/// 20 MiB on that chat, so the log grew with the square of its resumes. A chat that takes a turn
/// and then resumes, `RESUMES` times over, adds the same bytes on its last resume as on its first.
#[test]
fn a_chat_resumed_after_every_turn_logs_bounded_bytes_per_resume() {
    const RESUMES: usize = 40;
    let hub = new_hub();
    let session = chat(&hub, "resumed", "codex");
    let tap = hub.session_tap(&session);
    let mut per_resume = Vec::with_capacity(RESUMES);
    for turn in 1..=RESUMES {
        // One live turn (the newest turn's four updates; `codex_wake` puts the resume answer
        // first): its own records stay, they are the chat.
        let wake = codex_wake(turn);
        for msg in &wake[1 + 4 * (turn - 1)..1 + 4 * turn] {
            assert!(tap(Direction::In, msg, None));
        }
        // The resume replays every turn so far.
        let before = log_bytes(&hub, &session.id);
        session.loading.store(true, Ordering::SeqCst);
        for msg in &wake {
            assert!(tap(Direction::In, msg, None));
        }
        session.loading.store(false, Ordering::SeqCst);
        per_resume.push(log_bytes(&hub, &session.id) - before);
    }
    let (first, last) = (per_resume[0], per_resume[RESUMES - 1]);
    println!("log bytes per resume: first {first}, last {last} ({RESUMES} resumes)");
    assert!(last <= first + 64, "a resume grows with the chat: first {first}, last {last}");
    assert!(last < 2048, "a resume logs {last} bytes");
    // The chat itself is all there: every turn's prompt, call and reply, once.
    let logged = hub.store.events("resumed", 0, usize::MAX).unwrap();
    let prompts = logged.iter().filter(|r| r.kind == "user_message_chunk").count();
    assert_eq!(prompts, RESUMES);
}

/// One Claude tool call as Claude Code and acpmux send it: the model's call, its ACP record,
/// the two PreToolUse hook callbacks (`claude_stdio/outbound.rs` `initialize_request`) with
/// their answers, the result, and the ACP end.
fn claude_tool_call(n: usize) -> Vec<(Direction, Message)> {
    let id = format!("toolu_{n}");
    let input =
        json!({"command": format!("cargo test -p acpmux {n}"), "description": "Run the tests"});
    let hook = |callback: &str, rid: String| {
        Message::notification(
            "claude.control_request",
            json!({"type": "control_request", "request_id": rid, "request": {
                "subtype": "hook_callback", "callback_id": callback, "tool_use_id": id,
                "input": {"session_id": "cc-1", "transcript_path": "/home/u/.claude/projects/x.jsonl",
                    "cwd": "/tmp", "permission_mode": "default", "hook_event_name": "PreToolUse",
                    "tool_name": "Bash", "tool_input": input, "tool_use_id": id}}}),
        )
    };
    let answer = |rid: String, output: Value| {
        Message::notification(
            "claude.stdin",
            json!({"type": "control_response", "response": {"subtype": "success",
                "request_id": rid, "response": output}}),
        )
    };
    let allow = json!({"hookSpecificOutput": {"hookEventName": "PreToolUse",
        "permissionDecision": "allow", "permissionDecisionReason": "acpmux policy"}});
    vec![
        (Direction::In, update(tool(&id, "pending"))),
        (Direction::In, hook("cmux-repo-sync", format!("sync-{n}"))),
        (Direction::Out, answer(format!("sync-{n}"), json!({}))),
        (Direction::In, hook("acpmux-policy-gate", format!("gate-{n}"))),
        (Direction::Out, answer(format!("gate-{n}"), allow)),
        (
            Direction::In,
            update(json!({"sessionUpdate": "tool_call_update", "toolCallId": id,
                "status": "completed",
                "content": [{"type": "content", "content": {"type": "text", "text": "ok"}}]})),
        ),
    ]
}

/// A Claude tool call adds its own ACP records and none of the hook traffic around it (315 MB on
/// one lane), and Claude Code's thinking ticks (25,716 in one chat) add nothing; a hook answer
/// that denies the call stays.
#[test]
fn a_claude_tool_call_logs_its_records_and_a_thinking_tick_logs_nothing() {
    let hub = new_hub();
    let s = chat(&hub, "c", "claude");
    let tap = hub.session_tap(&s);
    let mut call_bytes = Vec::new();
    for n in 0..10 {
        let before = log_bytes(&hub, "c");
        for (dir, msg) in claude_tool_call(n) {
            assert!(tap(dir, &msg, None));
        }
        call_bytes.push(log_bytes(&hub, "c") - before);
    }
    let acp: usize = {
        let check = new_hub();
        let only = chat(&check, "acp", "claude");
        let tap = check.session_tap(&only);
        let before = log_bytes(&check, "acp");
        for (dir, msg) in claude_tool_call(0) {
            if msg.method() == Some(crate::rpc::method::SESSION_UPDATE) {
                assert!(tap(dir, &msg, None));
            }
        }
        log_bytes(&check, "acp") - before
    };
    let before = log_bytes(&hub, "c");
    for n in 0..1000 {
        let tick = Message::notification(
            "claude.system.thinking_tokens",
            json!({"type": "system", "subtype": "thinking_tokens", "session_id": "cc-1",
                "uuid": format!("u-{n}"), "tokens": n * 12}),
        );
        assert!(tap(Direction::In, &tick, None));
    }
    let ticks = log_bytes(&hub, "c") - before;
    println!(
        "log bytes per Claude tool call: {} (its ACP records alone: {acp}); per 1,000 thinking ticks: {ticks}",
        call_bytes[9]
    );
    assert!(call_bytes.iter().all(|b| *b <= acp + 16), "{call_bytes:?} past its {acp} ACP bytes");
    assert_eq!(ticks, 0, "1,000 thinking ticks logged {ticks} bytes");

    let deny = json!({"hookSpecificOutput": {"hookEventName": "PreToolUse",
        "permissionDecision": "deny", "permissionDecisionReason": "a protected path"}});
    let request = Message::notification(
        "claude.control_request",
        json!({"type": "control_request", "request_id": "gate-x",
            "request": {"subtype": "hook_callback", "callback_id": "acpmux-policy-gate"}}),
    );
    let answer = Message::notification(
        "claude.stdin",
        json!({"type": "control_response", "response": {"subtype": "success",
            "request_id": "gate-x", "response": deny}}),
    );
    assert!(tap(Direction::In, &request, None));
    assert!(tap(Direction::Out, &answer, None));
    let logged = hub.store.events("c", 0, usize::MAX).unwrap();
    let denials: Vec<_> = logged
        .iter()
        .filter(|r| {
            r.kind == "claude.stdin"
                && r.msg.pointer("/response/request_id") == Some(&json!("gate-x"))
        })
        .collect();
    assert_eq!(denials.len(), 1, "a denial stays");
}

/// A cut turn's continuation reads the same without the replays: a call the live log left open
/// and a load's replay ended is not listed as unfinished (`restart_resume.rs`), and the replayed
/// history's calls are not either.
#[tokio::test]
async fn a_restart_continuation_reads_a_replayed_end_of_a_call_left_open() {
    let hub = new_hub();
    let s = chat(&hub, "cut", "codex");
    let tap = hub.session_tap(&s);
    hub.append(
        &s,
        "mux",
        "turn_started",
        json!({"turnId": "t", "promptId": "p", "control": "local", "trustGate": false}),
    );
    assert!(tap(Direction::In, &update(tool("own", "in_progress")), None));
    assert!(tap(Direction::In, &update(tool("still", "in_progress")), None));
    // A new agent for the turn loads the chat: its history, the open call's end with it.
    s.loading.store(true, Ordering::SeqCst);
    for msg in codex_wake(5) {
        assert!(tap(Direction::In, &msg, None));
    }
    let end = json!({"sessionUpdate": "tool_call_update", "toolCallId": "own", "status": "completed",
        "content": [{"type": "content", "content": {"type": "text", "text": "done"}}]});
    assert!(tap(Direction::In, &update(end), None));
    s.loading.store(false, Ordering::SeqCst);
    assert!(hub.log_restart_continuation(&s, "t").is_some());
    let records = hub.store.events("cut", 0, usize::MAX).unwrap();
    let text = records.iter().find(|e| e.kind == "queued").unwrap().msg["text"].as_str().unwrap();
    assert!(text.contains("still (id: still)"), "{text}");
    for absent in ["own (id:", "call-"] {
        assert!(!text.contains(absent), "{text}");
    }
    hub.shutdown_all().await;
}

/// The subagents a log rebuilds before a daemon adopts a running host (`work_below.rs`
/// `subagents_in_log`) are the ones the tap followed live: a replay starts none.
#[test]
fn the_subagents_a_log_rebuilds_are_the_live_ones_without_the_replays() {
    let hub = new_hub();
    let s = chat(&hub, "sub", "claude");
    let tap = hub.session_tap(&s);
    let spawn = |id: &str, background: bool| {
        update(json!({"sessionUpdate": "subagent_spawned", "subagentSessionId": id,
            "name": id, "background": background}))
    };
    let end = |id: &str| {
        update(json!({"sessionUpdate": "subagent_state_update", "subagentSessionId": id,
            "state": "completed"}))
    };
    assert!(tap(Direction::In, &spawn("bg", true), None));
    assert!(tap(Direction::In, &spawn("fg", false), None));
    s.loading.store(true, Ordering::SeqCst);
    for msg in [spawn("old", true), end("old"), spawn("replayed", true), spawn("bg", true)] {
        assert!(tap(Direction::In, &msg, None));
    }
    s.loading.store(false, Ordering::SeqCst);
    let live = {
        let tree = s.subagents.lock().unwrap();
        (tree.running_count(), tree.background_running())
    };
    assert_eq!(live, (2, 1));
    let rebuilt = hub.subagents_in_log(&s);
    hub.seed_subagents(&s, rebuilt);
    let tree = s.subagents.lock().unwrap();
    assert_eq!((tree.running_count(), tree.background_running()), live);
}
