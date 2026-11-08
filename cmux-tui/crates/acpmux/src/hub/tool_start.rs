//! Part of `Hub`; see `hub/mod.rs`. The earliest sign that a tool is about to run: a tool call
//! named before its arguments finish.
//!
//! Claude Code streams a call's input and sends the whole call once its block ends; acpmux names
//! the call as its block starts, as a pending `tool_call` (`claude_stdio/early_calls.rs`). Other
//! harnesses name a call when they send it. Either way the first `tool_call` record of a call id
//! is the moment a machine that is asleep should start waking: whatever runs the tool needs it
//! once the arguments are in, and the arguments are still streaming. A paused machine's resume
//! then hides behind them instead of adding to the call (the read/write/exec design).
//!
//! [`tool_start`] reads one hub event as such a start. The Cloud activity report turns it into
//! the session's `tool-starting` phase at once (`daemon/cloud_activity.rs`); anything else that
//! follows the hub's events (a relay that holds the model stream outside the machine, a peer
//! link to a paused machine) can read the same signal from [`Hub::subscribe`].

use super::*;

/// A tool call named before it runs.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ToolStart {
    pub session_id: String,
    pub tool_call_id: String,
    /// The tool's name as the harness gave it, or its ACP kind.
    pub tool: String,
    /// When it was named (Unix ms).
    pub at: u64,
}

/// `ev` as a tool start: the agent's `tool_call` record that names a call, still `pending` (its
/// input streams) or with no status (ACP's default). A call that arrives already running is no
/// start: it runs now, so it gives no lead. A peer's mirrored record is never one: the machine
/// it names is the peer's.
pub fn tool_start(ev: &HubEvent) -> Option<ToolStart> {
    if ev.remote.is_some() || ev.record.dir != "in" || ev.record.kind != "tool_call" {
        return None;
    }
    let update = ev.record.msg.pointer("/params/update")?;
    let status = update.get("status").and_then(Value::as_str);
    if !matches!(status, None | Some("pending")) {
        return None;
    }
    let id = update.get("toolCallId").and_then(Value::as_str)?;
    let tool = update
        .pointer("/_meta/claude/tool")
        .or_else(|| update.get("kind"))
        .and_then(Value::as_str)
        .unwrap_or("");
    Some(ToolStart {
        session_id: ev.session_id.clone(),
        tool_call_id: id.to_owned(),
        tool: tool.to_owned(),
        at: ev.record.at,
    })
}

#[cfg(test)]
#[path = "tool_start_tests.rs"]
mod tool_start_tests;
