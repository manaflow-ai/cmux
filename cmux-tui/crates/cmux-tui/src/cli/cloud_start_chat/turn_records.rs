//! Part of `cloud_start_chat`: what a fresh chat's records say about its turn's first output.

use serde_json::Value;

/// Where a prompt's wait before the model went (Cloud probe `first_output_split`): written to the agent (acpmux's
/// share), then Claude Code's `system/init` (its boot and MCP connects; none on a booted agent).
pub(super) const PRE_REQUEST_MARKS: [(&str, &str, &str); 2] =
    [("out", "session/prompt", "written_at"), ("in", "claude.system.init", "init_at")];

pub(super) fn is_agent_output(record: &Value) -> bool {
    let replay =
        record.get("kind").and_then(Value::as_str).is_some_and(|kind| kind.ends_with(".replay"));
    let kind = record.pointer("/msg/params/update/sessionUpdate").and_then(Value::as_str);
    !replay && matches!(kind, Some("agent_message_chunk" | "agent_thought_chunk" | "tool_call"))
}

/// The prompt (`mux` `user_message`) to the agent's first output (an `in` record, [`is_agent_output`]) in a fresh
/// chat's records, oldest first, on their own `at` clock: None until both are there.
pub(super) fn first_output_ms(records: &[Value]) -> Option<u64> {
    let at = |record: &Value| record.get("at").and_then(Value::as_u64);
    let prompt = records.iter().position(|record| {
        record.get("dir").and_then(Value::as_str) == Some("mux")
            && record.get("kind").and_then(Value::as_str) == Some("user_message")
    })?;
    let mut after = records.iter().skip(prompt);
    let from = at(after.next()?)?;
    let first = after.find(|record| {
        record.get("dir").and_then(Value::as_str) == Some("in") && is_agent_output(record)
    })?;
    at(first).map(|to| to.saturating_sub(from))
}
