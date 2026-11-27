//! Resume a sub-session that was stopped (Leo, 2026-11-12: "WHY CANT WE RESTART AGENTS THAT WERE
//! STOPPED!??!?!?!? THAT'S A STUPID ARTIFICIAL SOUNDING LIMITATION").
//!
//! `subagent_resume.rs` brings back a stopped Claude Agent-tool subagent. An acpmux sub-session
//! (`start_session`, `acpmux run --parent`) is a chat of its own, so a stopped one needs no
//! transcript replay: its agent session still holds everything it did. Before this, its Resume had
//! nowhere to go: `_acpmux/retry` and `_acpmux/subsession/retry` refused a stopped (`cancelled`)
//! last turn with `retry.nothing_failed`, so the parent's row of it, its tray line and Session
//! Info offered nothing, and its parent agent could not bring it back with `retry_session`.
//!
//! - `_acpmux/retry {sessionId}` (the Resume on the sub-session's row, `acpmux retry`) and the
//!   sub-session tool `retry_session {session}` on a sub-session whose last turn ended stopped
//!   (`lastTurn.status` `cancelled`) start one new turn in the same chat and agent session: a
//!   continuation that tells the agent its turn was stopped and to carry on from where it stopped
//!   ([`continue_text`]). Its `user_message` carries `_meta.provenance = {kind: "auto_resume",
//!   reason: "stopped", promptId, turnId, manual: true}` (the stopped turn's prompt and turn), plus
//!   `from` when a sub-session asked: the same shape as a failed turn's retry, so it runs under the
//!   same family checks at dispatch (`subsession_guard.rs` `is_family_retry`) and a pane draws it
//!   as acpmux's continuation, never the person's prompt.
//! - It runs under the caller's rules (`retry_allowed`), never queues (`PromptOptions::no_queue`):
//!   `retry.busy` while a turn runs or is about to start, a prompt waits, a continuation may still
//!   fire, or a run slot is full; so a second click or a second surface sends nothing more. It
//!   answers once its turn started: `{promptId, turnId, kind: "turn"}`, `promptId`
//!   `stopped-resume-<ms>` (never an attempt of the stopped prompt, which a workflow's stop of
//!   that prompt refuses for good, `auto_resume.rs` `prompt_stop_set`).
//! - A top-level chat is not changed: its stopped turn's Continue is the pane's, and its retry
//!   still says `retry.nothing_failed`. Capability `subsession-resume-v1`.

use super::auto_resume::retry_turn::{RetryBy, busy};
use super::queue::closing;
use super::{Hub, PromptOptions, Session};
use crate::protocol::session::{RetryKind, RetryResult};
use crate::rpc::RpcError;
use cmux_json::JsonSet as _;
use serde_json::{Value, json};
use std::sync::Arc;
use std::sync::atomic::Ordering;

/// The `reason` of a stopped sub-session's continuation in its `auto_resume` provenance.
pub(crate) const STOPPED_REASON: &str = "stopped";

/// The text the agent gets.
pub(super) fn continue_text() -> &'static str {
    "Your previous turn was stopped before it finished, and you are now asked to resume it. \
     Check what already finished (files, commands, messages), then continue from where it \
     stopped. Do not redo work that completed."
}

/// The stopped turn a Resume of `session` continues: `(turn id, prompt id)` when `session` is a
/// sub-session whose last turn ended stopped and no turn runs.
pub(super) fn stopped_subsession_turn(session: &Session) -> Option<(String, String)> {
    let meta = session.meta();
    meta.subsession.as_ref()?;
    let last = meta.last_turn.as_ref()?;
    let field = |k: &str| last.get(k).and_then(Value::as_str).map(str::to_owned);
    if field("status").as_deref() != Some("cancelled") {
        return None;
    }
    Some((field("turnId")?, field("promptId").unwrap_or_default()))
}

impl Hub {
    /// Continues the stopped sub-session `session` (the module doc), whose stopped turn is
    /// `cut_turn` of prompt `stopped_prompt`; answers once its turn starts.
    pub(super) async fn resume_stopped_subsession(
        self: &Arc<Self>,
        session: &Arc<Session>,
        cut_turn: String,
        stopped_prompt: String,
        by: RetryBy,
    ) -> Result<Value, RpcError> {
        if closing(session) {
            return Err(RpcError::invalid_params("retry.nothing_failed: the chat closed")
                .with_data(json!({"reason": "retry.nothing_failed", "why": "closed"})));
        }
        self.retry_allowed(session, &by).await?;
        // Checked here for a clear answer; the queue checks it again under its lock.
        let busy_now = session.turn().is_some()
            || session.queue().iter().any(|q| !q.aside())
            || session.harness_turn.load(Ordering::SeqCst)
            || self.continuation_pending(session)
            || session.moving().is_some();
        if busy_now {
            return Err(busy());
        }
        let mut provenance = json!({"kind": "auto_resume", "reason": STOPPED_REASON,
            "promptId": stopped_prompt, "turnId": cut_turn, "manual": true});
        if let Some(from) = by.from {
            provenance.set("from", json!(from));
        }
        let prompt_id = format!("stopped-resume-{}", crate::store::now_ms());
        let (tx, rx) = tokio::sync::oneshot::channel::<Value>();
        let on_accepted: Box<dyn FnOnce(Value) + Send> = Box::new(move |v| {
            let _ = tx.send(v);
        });
        let opts = PromptOptions {
            prompt_id: Some(prompt_id.clone()),
            on_accepted: Some(on_accepted),
            control: by.control,
            trust_gate: by.trust_gate,
            full_access_device: by.full_access_device,
            provenance: Some(provenance),
            no_queue: true,
            ..PromptOptions::default()
        };
        let blocks = vec![json!({"type": "text", "text": continue_text()})];
        let (hub, s) = (self.clone(), session.clone());
        // The turn runs on: only its acceptance is awaited.
        let task = self.scope.spawn_named("subsession-resume", async move {
            hub.prompt_with(&s, blocks, "acpmux", false, opts).await
        });
        let accepted = match rx.await {
            Ok(v) => v,
            // Dropped before acceptance: the prompt was refused.
            Err(_) => match task.await {
                Ok(Ok(v)) => v,
                Ok(Err(e)) => return Err(e),
                Err(e) => return Err(RpcError::internal(e.to_string())),
            },
        };
        let turn_id = accepted.get("turnId").and_then(Value::as_str).map(str::to_owned);
        let result = RetryResult { prompt_id, turn_id, kind: RetryKind::Turn };
        Ok(serde_json::to_value(result).unwrap_or(Value::Null))
    }
}

#[cfg(test)]
#[path = "subsession_resume_tests.rs"]
mod tests;
