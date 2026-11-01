//! A chat's first send that failed because Claude's OAuth token was revoked goes again once,
//! by itself, [`FIRST_SEND_RETRY_MS`] later (cmux#28111, gap 5: on a fresh Cloud VM the first
//! `claude -p` failed with "Failed to authenticate: OAuth token revoked" and the same call 2 s
//! later ran; Leo, 2026-10-30: "like the initial 0 to 1 chat auto it sends to cloud").
//!
//! - Only that failure ([`crate::claude_auth::is_revoked_token`]), only on the chat's first turn
//!   (no turn before it, [`retries`]) and only for a prompt of its own, never an attempt
//!   (`P~resume-n`): the retry is `P~resume-1`, so one that fails the same way is not retried
//!   again and the chat shows the failure as before.
//! - It is the Retry button's resend (`retry_turn.rs` `resend_turn`): the same prompt, in the same
//!   session, under the failed turn's rules, checked again at dispatch. One that cannot be
//!   rebuilt as it was is not sent (`retry.not_resendable`).
//! - Its wait is the chat's continuation mark (`Mark::Waiting`, `auto_resume.rs`): Stop, close, a
//!   person's prompt or a manual Retry since take it, and the retry is then not sent. Nor while
//!   the chat moves or once it closed.
//! - The log says what was decided: `first_send_retry` `{promptId, turnId, delayMs, reason:
//!   "token_revoked"}` when it waits, `auto_resume_skipped` (with `firstSend: true`) when it is
//!   not sent; its turn's `user_message` carries the `auto_resume` provenance of attempt 1.
//!   No `auto_resume_scheduled`: there is no wait for a restart to restore, and the row's
//!   `retry` stays the transient-error retry's alone (its `reason` has no value for this).

use super::retry_turn::RetryBy;
use super::{CutTurn, split_attempt};
use crate::hub::{Hub, Session, SessionStatus};
use cmux_json::JsonSet as _;
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::Notify;

/// The wait before a revoked first send goes again: about the 2 s after which it ran.
pub const FIRST_SEND_RETRY_MS: u64 = 2_000;

/// Whether `error` is one a first send is retried on (`retry_row`, `settled_unretried`: a row
/// may show its retry being decided).
pub(super) fn retried_error(error: &str) -> bool {
    crate::claude_auth::is_revoked_token(error)
}

/// Whether the turn `cut` failed is the chat's first send on a revoked token: its own prompt
/// (no attempt) and the chat's only turn so far.
pub(super) fn retries(session: &Session, cut: &CutTurn<'_>) -> bool {
    retried_error(cut.error)
        && split_attempt(cut.prompt_id).1 == 0
        && session.meta().turn_count == 1
}

impl Hub {
    /// Sends the cut turn again after [`FIRST_SEND_RETRY_MS`], or as soon as its mark `wake`
    /// goes (then the resend finds it gone and records why it was not sent).
    pub(super) fn retry_first_send(
        self: &Arc<Self>,
        session: &Arc<Session>,
        cut: &CutTurn<'_>,
        wake: Arc<Notify>,
    ) {
        let (root, _) = split_attempt(cut.prompt_id);
        let msg = json!({"promptId": root, "turnId": cut.turn_id, "delayMs": FIRST_SEND_RETRY_MS, "reason": "token_revoked"});
        self.append_retry(session, "first_send_retry", msg);
        let by = RetryBy {
            control: cut.control,
            trust_gate: cut.trust_gate,
            full_access_device: None,
            from: cut.from.map(str::to_owned),
        };
        let (root, cut_turn) = (root.to_owned(), cut.turn_id.to_owned());
        let (hub, session) = (self.clone(), session.clone());
        tokio::spawn(async move {
            tokio::select! {
                () = tokio::time::sleep(Duration::from_millis(FIRST_SEND_RETRY_MS)) => {}
                () = wake.notified() => {}
            }
            if session.replaced.load(std::sync::atomic::Ordering::SeqCst) {
                return;
            }
            let skipped = |why: &str, error: Option<&str>| {
                let mut msg = json!({"promptId": root, "attempt": 1, "turnId": cut_turn, "skipped": why, "firstSend": true});
                if let Some(error) = error {
                    msg.set("error", json!(error));
                }
                msg
            };
            if session.status() == SessionStatus::Closed || session.moving().is_some() {
                hub.take_pending(&session, &cut_turn);
                hub.append_retry(&session, "auto_resume_skipped", skipped("closed", None));
                return;
            }
            let Err(e) = hub.resend_turn(&session, by, Some(&cut_turn)).await else { return };
            // What is left of its wait, if the resend did not claim it.
            hub.take_pending(&session, &cut_turn);
            let reason = e.data.as_ref().and_then(|d| d.get("reason")).and_then(Value::as_str);
            let why = match reason {
                Some("auto_resume.stopped" | "retry.stopped") => "stopped",
                Some("auto_resume.superseded" | "retry.busy" | "retry.nothing_failed") => {
                    "superseded"
                }
                Some("retry.not_resendable") => "not_resendable",
                _ => "refused",
            };
            let error = (why == "refused").then_some(e.message.as_str());
            tracing::info!(session = %session.id, why, "first send not retried: {}", e.message);
            hub.append_retry(&session, "auto_resume_skipped", skipped(why, error));
        });
    }
}

#[cfg(test)]
#[path = "first_send_tests.rs"]
mod tests;
