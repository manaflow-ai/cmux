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
#[path = "subagents_opencode_tests.rs"]
mod tests;
