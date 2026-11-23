//! OpenCode's subagents (`subagents.rs`): OpenCode runs each one through its `task` tool, in a
//! session of its own, and reports it only as that tool call in the parent's session. It sends
//! no `subagent_spawned` (it does not take up `nativeSubagentSessions`), and no update of the
//! child's own session reaches the parent's ACP connection. The call's `rawInput` names the
//! agent (`subagent_type`), its short `description` and its `prompt`; its completed update's
//! `rawOutput.metadata` names the child's own OpenCode session (`sessionId`, with
//! `parentSessionId`) and the model it ran on (`{providerID, modelID}`), and `rawOutput.output`
//! holds its reply as `<task id=…><task_result>…</task_result></task>`.
//!
//! The subagent's id is the tool call's id, the one id every update of it carries; its end adds
//! `agentSessionId`, the child's OpenCode session id, which OpenCode's `session/fork` and
//! `session/load` take (manaflow-ai/cmux#50203).

use super::{SubagentTree, truncate_last_message};
use serde_json::{Value, json};

impl SubagentTree {
    /// The subagent events of one OpenCode `task` tool call, or None for any other tool call
    /// (Claude's and Codex's carry their own `_meta` and are read elsewhere).
    pub(super) fn opencode_task(
        &mut self,
        update: &Value,
        owner: Option<&str>,
    ) -> Option<Vec<Value>> {
        let meta = update.get("_meta");
        if meta.is_some_and(|m| m.get("claude").is_some() || m.get("codex").is_some()) {
            return None;
        }
        let call = update.get("toolCallId").and_then(Value::as_str)?;
        let input = update.get("rawInput");
        let kind = text(input, "subagent_type");
        let out = update.pointer("/rawOutput/metadata");
        let child = text(out, "sessionId").filter(|_| text(out, "parentSessionId").is_some());
        // Its first update (`tool_call`, title "task") has an empty `rawInput`; the next names the
        // agent. Its end carries no `rawInput`, but the child's session, or an id already known.
        if kind.is_none() && child.is_none() && !self.parents.contains_key(call) {
            return None;
        }
        let mut event = self.spawn(call, owner)?;
        let state = match update.get("status").and_then(Value::as_str) {
            Some("completed") => "completed",
            Some("failed") => "failed",
            _ => "running",
        };
        if let Some(kind) = kind {
            event.insert("kind".into(), json!(kind));
        }
        if let Some(task) = text(input, "description") {
            event.insert("task".into(), json!(task));
        }
        if let Some(prompt) = text(input, "prompt") {
            event.insert("prompt".into(), json!(prompt));
        }
        let model = out.and_then(|m| m.get("model"));
        let model = match (text(model, "providerID"), text(model, "modelID")) {
            (Some(provider), Some(id)) => Some(format!("{provider}/{id}")),
            (None, Some(id)) => Some(id.to_owned()),
            _ => model.and_then(Value::as_str).map(str::to_owned),
        };
        if let Some(model) = model {
            event.insert("model".into(), json!(model));
        }
        if let Some(child) = child {
            event.insert("agentSessionId".into(), json!(child));
        }
        if state != "running"
            && let Some(output) = update.pointer("/rawOutput/output").and_then(Value::as_str)
        {
            let reply = task_result(output);
            if !reply.is_empty() {
                let key = if state == "failed" { "error" } else { "lastMessage" };
                event.insert(
                    key.into(),
                    json!(if key == "lastMessage" {
                        truncate_last_message(reply)
                    } else {
                        reply.to_owned()
                    }),
                );
            }
        }
        if state == "failed"
            && !event.contains_key("error")
            && let Some(error) = update.pointer("/rawOutput/error").and_then(Value::as_str)
        {
            event.insert("error".into(), json!(error));
        }
        event.insert("toolCallId".into(), json!(call));
        event.insert("state".into(), json!(state));
        self.remember_label(call, &event);
        self.label(call, &mut event);
        Some(vec![Value::Object(event)])
    }
}

/// `key`'s nonempty string in `v`.
fn text<'a>(v: Option<&'a Value>, key: &str) -> Option<&'a str> {
    v.and_then(|v| v.get(key)).and_then(Value::as_str).filter(|s| !s.is_empty())
}

/// The reply inside OpenCode's `<task …><task_result>…</task_result></task>`, else the output.
fn task_result(output: &str) -> &str {
    let inner = output
        .split_once("<task_result>")
        .map(|(_, rest)| rest.rsplit_once("</task_result>").map_or(rest, |(reply, _)| reply))
        .unwrap_or(output);
    inner.trim()
}

#[cfg(test)]
mod tests {
    use super::*;

    const CALL: &str = "chatcmpl-tool-9538157f63cb04d4";
    const CHAT: &str = "ses_dfd18faedffeVcUYmaF4KNMxpp";
    const CHILD: &str = "ses_dfd18c67affeOepUpF07igXlGG";

    fn annotate(tree: &mut SubagentTree, update: Value) -> Vec<Value> {
        let mut params = json!({"sessionId": CHAT, "update": update});
        tree.annotate(&mut params);
        params
            .pointer("/_meta/acpmux/subagents")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default()
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
}
