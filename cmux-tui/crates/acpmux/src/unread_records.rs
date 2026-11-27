//! The harness records a chat's log keeps nowhere, because no reader takes them back from it: the
//! tap drops them as they come (`hub/tap.rs`), and retention drops the ones older logs hold
//! (`store/compact.rs`). Measured on a lane (2026-11-18), they were 3.2 GB of a 4.97 GB sessions
//! folder:
//!
//! - A load's replay of the chat's history (`*.replay`, a Codex `session/load` on every wake from
//!   hibernation): no client shows one (`paging.rs`, `session_open.rs`), and the history is in
//!   the records it was first logged as. One chat held 1.2 GB for 3 turns (569 loads). Two kinds
//!   stay ([`KEPT_REPLAYS`]): the modes and options a load reports, which a restart reads back
//!   (`full_access_bound.rs` `reported_by_left_host`). A replayed tool call's end stays, its id,
//!   status and session only, when the live log left that call open (`hub/tap.rs`): a cut turn's
//!   continuation counts it ended (`restart_resume.rs`).
//! - Codex's answer to `thread/resume` (`codex.response`) carries the whole thread
//!   (`result.thread.turns`, 977,675 of one answer's 992,343 bytes): the tap logs it without them
//!   (`codex_app_server::logged`), and retention gives an older line the same
//!   ([`leave_out_resumed_history`]).
//! - Claude Code's `system/thinking_tokens` ticks (25,716 in one chat): only a sign of work in
//!   memory (`hub/tap.rs` `MODEL_LINES`), read before the log.
//! - Claude Code's PreToolUse hook callbacks (`control_request` `hook_callback`, two per tool call,
//!   each with the call's whole input) and acpmux's answers to them: the tool call's own records
//!   carry the call, and the policy gate's decision is its own request to the hub. An answer that
//!   denies the call stays.

use serde_json::Value;

/// The replayed `session/update` kinds the log keeps: what a load reports of the chat's modes and
/// options (`full_access_bound.rs` reads them back after a restart).
pub(crate) const KEPT_REPLAYS: [&str; 2] = ["current_mode_update", "config_option_update"];

/// The raw Claude line kind of a thinking tick.
pub(crate) const THINKING_TICK: &str = "claude.system.thinking_tokens";

/// Whether a replayed record of `kind` (`<update>.replay`) is one no reader takes from the log.
/// A replayed tool call is decided by its id ([`replayed_tool_end`]).
pub(crate) fn unread_replay(kind: &str) -> bool {
    kind.strip_suffix(".replay").is_some_and(|base| !KEPT_REPLAYS.contains(&base))
}

/// A replayed `session/update` (`msg`, as the tap logs it) that ends a tool call: the call's id,
/// and the record kept for it (its update's kind, id and status, its session and acpmux meta).
pub(crate) fn replayed_tool_end(msg: &Value) -> Option<(String, Value)> {
    let update = msg.pointer("/params/update")?;
    let kind = update.get("sessionUpdate").and_then(Value::as_str)?;
    let status = update.get("status").and_then(Value::as_str)?;
    if !matches!(kind, "tool_call" | "tool_call_update")
        || !matches!(status, "completed" | "failed")
    {
        return None;
    }
    let id = update.get("toolCallId").and_then(Value::as_str)?;
    let mut params = serde_json::Map::new();
    params.insert(
        "update".into(),
        serde_json::json!({"sessionUpdate": kind, "toolCallId": id, "status": status}),
    );
    for field in ["sessionId", "_meta"] {
        if let Some(value) = msg.pointer(&format!("/params/{field}")) {
            params.insert(field.into(), value.clone());
        }
    }
    let mut kept = msg.clone();
    kept.as_object_mut()?.insert("params".into(), Value::Object(params));
    Some((id.to_owned(), kept))
}

/// The request id of a Claude Code `control_request` line that is a hook callback.
pub(crate) fn hook_callback_id(line: &Value) -> Option<&str> {
    (line.get("type").and_then(Value::as_str) == Some("control_request")
        && line.pointer("/request/subtype").and_then(Value::as_str) == Some("hook_callback"))
    .then(|| line.get("request_id").and_then(Value::as_str))
    .flatten()
}

/// The request id a `control_response` line acpmux writes to Claude Code answers, unless its
/// answer denies a tool call.
pub(crate) fn plain_answer_id(line: &Value) -> Option<&str> {
    if line.get("type").and_then(Value::as_str) != Some("control_response") {
        return None;
    }
    let response = line.get("response")?;
    let decision = response
        .pointer("/response/hookSpecificOutput/permissionDecision")
        .or_else(|| response.pointer("/response/decision"))
        .and_then(Value::as_str);
    if matches!(decision, Some("deny" | "block")) {
        return None;
    }
    response.get("request_id").and_then(Value::as_str)
}

/// Codex's `thread/resume` (or `thread/fork`) answer `line` (a raw `codex.response`) as the tap
/// now logs it (`codex_app_server::logged`): without the thread's turns, with how many it held
/// (`turnsOmitted`); whether it held any. Retention gives a log written before that the same line.
pub(crate) fn leave_out_resumed_history(line: &mut Value) -> bool {
    let held = line
        .pointer("/result/thread/turns")
        .and_then(Value::as_array)
        .is_some_and(|t| !t.is_empty());
    if held {
        *line = crate::codex_app_server::logged(line);
    }
    held
}

#[cfg(test)]
#[path = "unread_records_tests.rs"]
mod tests;
