//! Part of `Hub`; see `hub/mod.rs`. A steer the agent cannot read yet waits in acpmux, where it
//! can still be edited and taken back (Leo, 2026-10-21: "I can't edit and cancel these").
//!
//! An agent reads a steer when its current step ends: Claude Code at its next tool boundary,
//! Codex at its next model request. A steer sent into the agent at once during a long tool call
//! sat in the agent's input, where Remove and Edit found no queue entry to change. While a tool
//! call of the running turn is open, a steer now waits in the queue instead (its `queued` record
//! gives it a queue row with Edit, Remove and Send now) and goes into the agent once no call is
//! open (`queue_turn`). When the turn ends first, it runs as a prompt in its place in the queue,
//! never as a steer into a later turn. A call that never reports its end holds it until the turn
//! ends. Send now and a steer sent with `interrupt` go in at once.

use super::*;

/// Whether a tool call of the running turn is open: its agent reads no steer until it ends.
pub(super) fn mid_step(session: &Session) -> bool {
    let turn = session.turn.lock().unwrap_or_else(|e| e.into_inner());
    turn.as_ref().is_some_and(|t| !t.doing.open_calls.is_empty())
}

/// The running turn's id while none of its tool calls is open: a steer that waited for that
/// turn's call goes in now. A steer never goes into a later turn: it runs as a prompt instead.
pub(super) fn between_steps(session: &Session) -> Option<String> {
    let turn = session.turn.lock().unwrap_or_else(|e| e.into_inner());
    turn.as_ref().filter(|t| t.doing.open_calls.is_empty()).map(|t| t.turn_id.clone())
}

impl Hub {
    /// Notes the tool call `update` opens or closes on the running turn. When the last open one
    /// closes, a steer that waited for it goes in (`queue_turn`).
    pub(super) fn note_tool_step(&self, session: &Session, update: &Value) {
        let kind = update.get("sessionUpdate").and_then(Value::as_str);
        if !matches!(kind, Some("tool_call" | "tool_call_update")) {
            return;
        }
        let Some(id) = update.get("toolCallId").and_then(Value::as_str) else {
            return;
        };
        // A new call without a status is pending (ACP); an update without one changes nothing.
        let status = update
            .get("status")
            .and_then(Value::as_str)
            .or((kind == Some("tool_call")).then_some("pending"));
        let ended = {
            let mut turn = session.turn.lock().unwrap_or_else(|e| e.into_inner());
            let Some(turn) = turn.as_mut() else {
                return;
            };
            let open = &mut turn.doing.open_calls;
            match status {
                Some("pending" | "in_progress") => {
                    open.insert(id.to_owned());
                    false
                }
                Some(_) => open.remove(id) && open.is_empty(),
                None => false,
            }
        };
        if ended {
            session.queue_moved.notify_waiters();
        }
    }
}
