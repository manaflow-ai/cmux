//! Part of `Hub`; see `hub/mod.rs`. A turn whose prompt the agent holds behind its own work. Claude
//! Code takes a prompt line written while it still runs (a turn of its own, a side question, a
//! compaction) into its queue (`command_lifecycle` `queued`) and starts it (`started`) only when
//! that work ends; meanwhile clients drew the turn as "Thinking" (cmuxterm-hq
//! `docs/findings/2026-11-23-lane-vm-first-token.md`: 92 of 3,416 turns on a lane VM waited so,
//! p50 47 s, max 476 s). When the turn's prompt line is still held [`HELD`] after Claude Code
//! queued it, the chat logs `turn_queued` {turnId, on: `busy` | `compacting`} once and marks the
//! turn silent, so the model's next sign logs `turn_heard` (`silent_turn.rs`), which ends it.
//! `acpmux history` reads the same wait from the log as `queuedMs` (`history_timing.rs`).

use super::*;

/// How long Claude Code may hold the line before it counts as queued: an idle chat's `queued` and
/// `started` come a millisecond or two apart.
const HELD: std::time::Duration = std::time::Duration::from_secs(1);

/// The turn's prompt line, from its write until Claude Code starts it.
#[derive(Default)]
pub(super) struct QueuedPrompt {
    /// The turn whose prompt was written, while its line is not started.
    turn: Option<String>,
    /// Claude Code's id of that line: the first `queued` after the write.
    command: Option<String>,
}

impl Hub {
    /// `session`'s running turn wrote its prompt to the agent: the next line Claude Code queues is
    /// that prompt's (a steered line is written only once the turn runs, after it).
    pub(super) fn prompt_line_written(&self, session: &Session) {
        let mut q = session.queued_prompt.lock().unwrap_or_else(|e| e.into_inner());
        *q = QueuedPrompt { turn: session.turn().map(|t| t.turn_id), command: None };
    }

    /// Claude Code's `command_lifecycle` line (module docs).
    pub(super) fn command_lifecycle(self: &Arc<Self>, session: &Arc<Session>, line: &Value) {
        let Some(command) = line.get("command_uuid").and_then(Value::as_str) else { return };
        let state = line.get("state").and_then(Value::as_str).unwrap_or("");
        let turn_id = {
            let mut q = session.queued_prompt.lock().unwrap_or_else(|e| e.into_inner());
            match (&q.command, state) {
                (None, "queued") if q.turn.is_some() => {
                    q.command = Some(command.to_owned());
                    q.turn.clone()
                }
                (Some(ours), _) if ours == command && state != "queued" => {
                    *q = QueuedPrompt::default();
                    None
                }
                _ => None,
            }
        };
        let Some(turn_id) = turn_id else { return };
        let hub = self.clone();
        let session = session.clone();
        let command = command.to_owned();
        self.scope.spawn_until_cancelled("queued-turn", async move {
            tokio::time::sleep(HELD).await;
            hub.log_queued(&session, &turn_id, &command);
        });
    }

    /// Logs `turn_queued` when `turn_id`'s line `command` is still held (module docs).
    fn log_queued(&self, session: &Session, turn_id: &str, command: &str) {
        let held = {
            let q = session.queued_prompt.lock().unwrap_or_else(|e| e.into_inner());
            q.turn.as_deref() == Some(turn_id) && q.command.as_deref() == Some(command)
        };
        if !held || session.turn().is_none_or(|t| t.turn_id != turn_id) {
            return;
        }
        let on = if session.compacting.load(Ordering::SeqCst) { "compacting" } else { "busy" };
        // Held while it logs, as `turn_retrying` does, so a sign the tap counts meanwhile finds
        // the wait to end.
        let mut silent = session.silent_turn.lock().unwrap_or_else(|e| e.into_inner());
        self.append(session, "mux", "turn_queued", json!({"turnId": turn_id, "on": on}));
        *silent = Some(turn_id.to_owned());
    }
}

#[cfg(test)]
#[path = "queued_turn_tests.rs"]
mod tests;
