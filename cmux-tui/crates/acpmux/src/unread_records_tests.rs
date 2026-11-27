use super::*;
use serde_json::json;

#[test]
fn only_mode_and_option_replays_are_read_back() {
    assert!(unread_replay("agent_message_chunk.replay"));
    assert!(unread_replay("tool_call.replay"));
    assert!(!unread_replay("current_mode_update.replay"));
    assert!(!unread_replay("config_option_update.replay"));
    assert!(!unread_replay("agent_message_chunk"));
}

#[test]
fn a_replayed_tool_end_keeps_its_id_status_and_session_only() {
    let msg = json!({"jsonrpc": "2.0", "method": "session/update", "params": {
        "sessionId": "t1", "_meta": {"acpmux": {"subagent": {"id": "c"}}},
        "update": {"sessionUpdate": "tool_call_update", "toolCallId": "x", "status": "completed",
            "content": [{"type": "content", "content": {"type": "text", "text": "out".repeat(999)}}]}}});
    let (id, kept) = replayed_tool_end(&msg).unwrap();
    assert_eq!(id, "x");
    assert_eq!(
        kept["params"],
        json!({"sessionId": "t1", "_meta": {"acpmux": {"subagent": {"id": "c"}}},
            "update": {"sessionUpdate": "tool_call_update", "toolCallId": "x", "status": "completed"}})
    );
    let open = json!({"params": {"update": {"sessionUpdate": "tool_call", "toolCallId": "x", "status": "in_progress"}}});
    assert!(replayed_tool_end(&open).is_none());
}

#[test]
fn hook_callbacks_and_their_plain_answers_are_named_and_a_denial_is_not() {
    let call = json!({"type": "control_request", "request_id": "r1",
        "request": {"subtype": "hook_callback", "callback_id": "cmux-repo-sync", "input": {}}});
    assert_eq!(hook_callback_id(&call), Some("r1"));
    let other = json!({"type": "control_request", "request_id": "r2", "request": {"subtype": "can_use_tool"}});
    assert_eq!(hook_callback_id(&other), None);
    let answer = |output: Value| json!({"type": "control_response", "response": {"subtype": "success", "request_id": "r1", "response": output}});
    assert_eq!(plain_answer_id(&answer(json!({}))), Some("r1"));
    let allow = json!({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow"}});
    assert_eq!(plain_answer_id(&answer(allow)), Some("r1"));
    let deny = json!({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny"}});
    assert_eq!(plain_answer_id(&answer(deny)), None);
}

#[test]
fn a_resume_answer_is_logged_without_its_turns() {
    let mut line = json!({"id": 3, "result": {"thread": {"id": "th", "preview": "hello",
        "turns": [{"id": "t1", "items": []}, {"id": "t2", "items": []}]}, "model": "gpt"}});
    assert!(leave_out_resumed_history(&mut line));
    assert_eq!(
        line,
        json!({"id": 3, "result": {"thread": {"id": "th", "preview": "hello", "turnsOmitted": 2}, "model": "gpt"}})
    );
    let mut fresh = json!({"id": 1, "result": {"thread": {"id": "th", "turns": []}}});
    assert!(!leave_out_resumed_history(&mut fresh));
}
