//! A chat's log leaves out the state updates that repeat what it last logged (`update_repeats.rs`).

use super::*;
use serde_json::json;

/// `leave_out_repeats`, then the write succeeds: whether nothing was left to log.
fn log(repeats: &mut UpdateRepeats, kind: &str, update: &mut Value) -> bool {
    let found = repeats.leave_out_repeats(kind, update);
    let nothing_left = found.nothing_left;
    repeats.note_logged(found);
    nothing_left
}

fn init_info(model: &str) -> Value {
    json!({"sessionUpdate": "session_info_update", "title": null,
        "_meta": {"claude": {"tools": ["Bash", "Read"], "mcp_servers": [{"name": "cmux"}],
            "skills": ["review"], "model": model}}})
}

fn breakdown(tokens: u64) -> Value {
    json!({"sessionUpdate": "session_info_update",
        "_meta": {"acpmux": {"contextBreakdown": {"total": tokens}}}})
}

/// Claude Code's two shapes alternate (system/init's tools, then the turn's context breakdown):
/// each is compared with the last of its own section, so a turn that changes neither logs neither.
#[test]
fn alternating_shapes_log_only_what_changed() {
    let mut repeats = UpdateRepeats::default();
    let kind = "session_info_update";
    assert!(!log(&mut repeats, kind, &mut init_info("opus")));
    assert!(!log(&mut repeats, kind, &mut breakdown(100)));
    let mut again = init_info("opus");
    assert!(!log(&mut repeats, kind, &mut again), "its model and version are always logged");
    assert_eq!(
        again,
        json!({"sessionUpdate": "session_info_update", "title": null,
            "_meta": {"claude": {"model": "opus"}}})
    );
    let mut grown = breakdown(140);
    assert!(!log(&mut repeats, kind, &mut grown));
    assert_eq!(grown, breakdown(140), "a changed section is logged whole");
    assert!(log(&mut repeats, kind, &mut breakdown(140)));
    let mut switched = init_info("sonnet");
    assert!(!log(&mut repeats, kind, &mut switched));
    assert_eq!(switched["_meta"]["claude"]["model"], "sonnet");
}

/// A record with other fields keeps them when its repeated section goes; a goal or a title is
/// never compared.
#[test]
fn other_fields_stay() {
    let mut repeats = UpdateRepeats::default();
    log(&mut repeats, "session_info_update", &mut breakdown(1));
    let mut update = json!({"sessionUpdate": "session_info_update", "title": "Fix the tests",
        "_meta": {"goal": {"objective": "x"}, "acpmux": {"contextBreakdown": {"total": 1}}}});
    assert!(!log(&mut repeats, "session_info_update", &mut update));
    assert_eq!(
        update,
        json!({"sessionUpdate": "session_info_update", "title": "Fix the tests",
            "_meta": {"goal": {"objective": "x"}}})
    );
}

/// The slash commands a new process sends are not logged again when they are the same; another
/// kind is never touched.
#[test]
fn a_restarted_processs_same_commands_are_not_logged() {
    let mut repeats = UpdateRepeats::default();
    let commands = || {
        json!({"sessionUpdate": "available_commands_update",
            "availableCommands": [{"name": "compact"}, {"name": "review"}]})
    };
    assert!(!log(&mut repeats, "available_commands_update", &mut commands()));
    assert!(log(&mut repeats, "available_commands_update", &mut commands()));
    let mut usage = json!({"sessionUpdate": "usage_update", "used": 1});
    assert!(!log(&mut repeats, "usage_update", &mut usage));
    assert!(!log(&mut repeats, "usage_update", &mut usage));
}

/// A day of one busy session's state updates as Leo's Mac logged them (2026-11-08: a ~21 KB
/// `_meta.claude` each turn, a breakdown after it, an `available_commands_update` of 1,200
/// commands at each of 4 process starts): the harness the PR's before and after numbers come from.
#[test]
fn a_day_of_state_updates_logs_each_change_once() {
    let tools: Vec<String> = (0..300).map(|i| format!("mcp__server__tool_{i:03}")).collect();
    let commands: Vec<Value> = (0..1200)
        .map(
            |i| json!({"name": format!("plugin:command-{i:04}"), "description": "Runs a command."}),
        )
        .collect();
    let mut repeats = UpdateRepeats::default();
    let (mut before, mut after) = (0usize, 0usize);
    let mut write = |kind: &str, mut update: Value| {
        before += serde_json::to_vec(&update).unwrap().len();
        if !log(&mut repeats, kind, &mut update) {
            after += serde_json::to_vec(&update).unwrap().len();
        }
    };
    for turn in 0..200u64 {
        if turn % 50 == 0 {
            write(
                "available_commands_update",
                json!({"sessionUpdate": "available_commands_update", "availableCommands": commands}),
            );
        }
        write(
            "session_info_update",
            json!({"sessionUpdate": "session_info_update", "title": null,
            "_meta": {"claude": {"tools": tools, "model": "claude-opus-5-5"}}}),
        );
        // The breakdown changes on one turn in four (a tool's output grows the context).
        write("session_info_update", breakdown(turn / 4));
    }
    eprintln!("200 turns: {before} bytes before, {after} after");
    assert!(after * 10 < before, "200 turns: {before} bytes before, {after} after");
}

/// A section whose write failed is not recorded as logged: the retried update is logged whole
/// (review F1 on #39147: a retry taken as a repeat lost the changed section).
#[test]
fn a_failed_write_is_compared_again_on_retry() {
    let mut repeats = UpdateRepeats::default();
    let failed = repeats.leave_out_repeats("session_info_update", &mut breakdown(9));
    assert!(!failed.nothing_left);
    drop(failed);
    let mut retry = breakdown(9);
    assert!(!log(&mut repeats, "session_info_update", &mut retry));
    assert_eq!(retry, breakdown(9));
    assert!(log(&mut repeats, "session_info_update", &mut breakdown(9)));
}

/// Claude Code's raw answer to `initialize`, as the log keeps it (`claude.control_response`).
fn init_answer(pid: u64, commands: &Value) -> Value {
    json!({"type": "control_response", "response": {"subtype": "success", "request_id": "init-1",
        "response": {"pid": pid, "commands": commands, "agents": [{"name": "general-purpose"}],
            "models": [{"value": "opus"}], "account": {"apiProvider": "firstParty"}}}})
}

/// The ACP `initialize` response translated from it.
fn initialize_response(commands: &Value) -> Value {
    json!({"jsonrpc": "2.0", "id": 1, "result": {"protocolVersion": 1,
        "agentCapabilities": {"loadSession": true},
        "_meta": {"claude": {"capabilities": ["ui_surface_v1"], "commands": commands}}}})
}

/// An agent's process starts again with the same lists: both answers to `initialize` are logged,
/// without the lists the start before logged; their other fields stay; a changed list is logged
/// whole. The harness of the PR's numbers: 2 starts of a chat (a busy machine, 2026-11-11: 57 starts
/// of 29 chats in 16 minutes, 42 KB of commands in each answer).
#[test]
fn a_restarted_agents_answers_to_initialize_leave_out_the_lists_it_logged() {
    let commands: Value = (0..300)
        .map(|i| {
            json!({"name": format!("plugin:command-{i:03}"), "description": "Runs a command the person asked for.", "argumentHint": ""})
        })
        .collect();
    let mut repeats = UpdateRepeats::default();
    let (mut before, mut after) = (0usize, 0usize);
    let mut write = |kind: &str, mut line: Value| {
        before += serde_json::to_vec(&line).unwrap().len();
        assert!(!log(&mut repeats, kind, &mut line), "an answer to initialize was not logged");
        after += serde_json::to_vec(&line).unwrap().len();
        line
    };
    let starts = 10u64;
    let mut last = (Value::Null, Value::Null);
    for start in 0..starts {
        last = (
            write("claude.control_response", init_answer(1_000 + start, &commands)),
            write("response", initialize_response(&commands)),
        );
        if start == 0 {
            assert_eq!(last.0, init_answer(1_000, &commands), "the first start is logged whole");
            assert_eq!(last.1, initialize_response(&commands));
        }
    }
    eprintln!(
        "STRESS {starts} starts of one chat: answers to initialize {before} bytes before, {after} after ({} per start before, {} per later start after)",
        before / starts as usize,
        (after - (before / starts as usize)) / (starts as usize - 1),
    );
    assert!(after * 4 < before, "{starts} starts: {before} bytes before, {after} after");
    let (answer, response) = last;
    assert!(answer.pointer("/response/response/commands").is_none());
    assert_eq!(answer["response"]["response"]["pid"], 1_009, "its scalars stay");
    assert_eq!(answer["response"]["request_id"], "init-1");
    assert!(response.pointer("/result/_meta/claude/commands").is_none());
    assert_eq!(response["id"], 1, "the response keeps its id");
    assert_eq!(response["result"]["_meta"]["claude"]["capabilities"], json!(["ui_surface_v1"]));

    // A start with another list logs it whole; a response to anything else is untouched.
    let grown: Value = json!([{"name": "new-skill"}]);
    let mut changed = initialize_response(&grown);
    assert!(!log(&mut repeats, "response", &mut changed));
    assert_eq!(changed, initialize_response(&grown));
    let mut prompt = json!({"jsonrpc": "2.0", "id": 7, "result": {"stopReason": "end_turn"}});
    assert!(!log(&mut repeats, "response", &mut prompt));
    assert_eq!(prompt, json!({"jsonrpc": "2.0", "id": 7, "result": {"stopReason": "end_turn"}}));
}
