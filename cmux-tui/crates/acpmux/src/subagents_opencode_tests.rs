use super::*;

const CALL: &str = "chatcmpl-tool-9538157f63cb04d4";
const CHAT: &str = "ses_dfd18faedffeVcUYmaF4KNMxpp";
const CHILD: &str = "ses_dfd18c67affeOepUpF07igXlGG";

fn annotate(tree: &mut SubagentTree, update: Value) -> Vec<Value> {
    let mut params = json!({"sessionId": CHAT, "update": update});
    tree.annotate(&mut params);
    params.pointer("/_meta/acpmux/subagents").and_then(Value::as_array).cloned().unwrap_or_default()
}

fn input() -> Value {
    json!({"description": "Reply SUBAGENT-PONG",
           "prompt": "Reply with exactly the word SUBAGENT-PONG and nothing else.",
           "subagent_type": "general"})
}

/// OpenCode 1.19's own updates of a `task` call (fh-opencode-sub-base, seq 39-45): the
/// subagent runs under the chat with its agent type and task, and ends with its reply, its
/// model and its own OpenCode session, which a fork takes (manaflow-ai/cmux#50203).
#[test]
fn an_opencode_task_call_is_a_subagent_with_its_kind_model_and_session() {
    let mut tree = SubagentTree::default();
    tree.set_own(Some(CHAT));
    let first = annotate(
        &mut tree,
        json!({"sessionUpdate": "tool_call", "toolCallId": CALL, "title": "task", "kind": "think",
               "status": "pending", "rawInput": {}, "locations": []}),
    );
    assert!(first.is_empty(), "an empty input names no agent yet: {first:?}");
    let running = annotate(
        &mut tree,
        json!({"sessionUpdate": "tool_call_update", "toolCallId": CALL, "title": "task",
               "kind": "think", "status": "in_progress", "rawInput": input(), "locations": []}),
    );
    assert_eq!(running.len(), 1, "{running:?}");
    assert_eq!(running[0]["id"], CALL);
    assert_eq!(running[0]["parent"], Value::Null);
    assert_eq!(running[0]["state"], "running");
    assert_eq!(running[0]["kind"], "general");
    assert_eq!(running[0]["task"], "Reply SUBAGENT-PONG");
    assert_eq!(running[0]["toolCallId"], CALL);
    assert_eq!(tree.running_now(true), vec![(CALL, Some("Reply SUBAGENT-PONG"))]);

    let output = format!(
        "<task id=\"{CHILD}\" state=\"completed\">\n<task_result>\nSUBAGENT-PONG\n</task_result>\n</task>"
    );
    let done = annotate(
        &mut tree,
        json!({"sessionUpdate": "tool_call_update", "toolCallId": CALL, "title": "Reply SUBAGENT-PONG",
               "kind": "think", "status": "completed",
               "content": [{"type": "content", "content": {"type": "text", "text": output}}],
               "rawOutput": {"output": output, "metadata": {
                   "model": {"modelID": "big-pickle", "providerID": "opencode"},
                   "parentSessionId": CHAT, "sessionId": CHILD, "truncated": false}}}),
    );
    assert_eq!(done.len(), 1, "{done:?}");
    assert_eq!(done[0]["state"], "completed");
    assert_eq!(done[0]["model"], "opencode/big-pickle");
    assert_eq!(done[0]["agentSessionId"], CHILD);
    assert_eq!(done[0]["lastMessage"], "SUBAGENT-PONG");
    assert_eq!(done[0]["result"], "SUBAGENT-PONG");
    assert_eq!(done[0]["task"], "Reply SUBAGENT-PONG", "its end still names its task");
    assert!(tree.running_now(true).is_empty());
}

/// Only a `task` call is a subagent: OpenCode's other tool calls, and Claude's Agent call
/// (its own `subagent_spawned` reports it), are not.
#[test]
fn other_tool_calls_are_not_opencode_subagents() {
    let mut tree = SubagentTree::default();
    tree.set_own(Some(CHAT));
    let bash = annotate(
        &mut tree,
        json!({"sessionUpdate": "tool_call", "toolCallId": "call_b", "title": "bash",
               "kind": "execute", "status": "completed", "rawInput": {"command": "ls"},
               "rawOutput": {"output": "a", "metadata": {"exit": 0}}}),
    );
    assert!(bash.is_empty(), "{bash:?}");
    let claude = annotate(
        &mut tree,
        json!({"sessionUpdate": "tool_call", "toolCallId": "toolu_1", "title": "Agent",
               "status": "in_progress", "rawInput": input(), "_meta": {"claude": {"toolName": "Agent"}}}),
    );
    assert!(claude.is_empty(), "{claude:?}");
}

#[test]
fn a_failed_task_says_its_error() {
    let mut tree = SubagentTree::default();
    tree.set_own(Some(CHAT));
    annotate(
        &mut tree,
        json!({"sessionUpdate": "tool_call_update", "toolCallId": CALL, "status": "in_progress", "rawInput": input()}),
    );
    let failed = annotate(
        &mut tree,
        json!({"sessionUpdate": "tool_call_update", "toolCallId": CALL, "status": "failed",
               "rawOutput": {"error": "Tool execution aborted"}}),
    );
    assert_eq!(failed[0]["state"], "failed");
    assert_eq!(failed[0]["error"], "Tool execution aborted");
    assert!(tree.running_now(true).is_empty());
}
