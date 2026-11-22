//! A turn the agent failed because it does not know its model goes again once, by itself, under
//! the model's catalog id (Leo, 2026-11-22: "you guys need to be able to hot patch these and
//! reroute and auto-reroute to proper names ... you guys need to be catching these yourselves").
//! Claude Code refused `fable-5.2` (`[claude-code:unrecognized_model]`); `claude-fable-5-2` runs.
//!
//! - Only a model error ([`crate::model_catalog::is_model_error`]), only for a prompt of its own,
//!   never an attempt (`P~resume-n`): the retry is `P~resume-1`, so one that fails the same way
//!   is not retried again, and the chat shows the failure (`errorKind: model.unrecognized`).
//! - Only when the model folds to another id ([`Hub::reroute_target`]): the model the error
//!   names, else the one the chat runs, read against its harness's catalog entry; a harness the
//!   catalog has no entry for (a saved profile, a test harness) against Claude Code's and Codex's.
//! - The chat's model is set to it (`set_model`, so it stays), then the turn is the Retry
//!   button's resend (`retry_turn.rs`), under the failed turn's rules. Its wait is the chat's
//!   continuation mark, as a first send's retry is (`first_send.rs`): Stop, close, a person's
//!   prompt or a manual Retry take it, and nothing is sent.
//! - One line says so, in the daemon's log and as a notice row in the transcript (`model_reroute`
//!   `{from, to, turnId, promptId, text}`): `model-reroute: HOST/SESSION fable-5.2 ->
//!   claude-fable-5-2, turn retried`.

use super::retry_turn::RetryBy;
use super::{CutTurn, split_attempt};
use crate::hub::{Hub, Session, SessionStatus};
use crate::model_catalog;
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::Notify;

/// The wait before a rerouted turn goes: its turn lets go of the chat first.
pub const REROUTE_WAIT_MS: u64 = 300;

/// The longest the reroute waits for the failed turn to let go of the chat.
const IDLE_DEADLINE: Duration = Duration::from_secs(10);

/// Whether the turn `cut` failed is one a reroute may retry: a model error on the chat's own
/// prompt (no attempt). Whether the model folds to another id is settled off the turn's path.
pub(super) fn may_reroute(cut: &CutTurn<'_>) -> bool {
    model_catalog::is_model_error(cut.error) && split_attempt(cut.prompt_id).1 == 0
}

impl Hub {
    /// The model `session`'s failed turn ran (the one `error` names, else the chat's own) and
    /// its catalog id, when they differ. None when the catalog does not know it, or it is
    /// already the catalog's id.
    pub(in crate::hub) async fn reroute_target(
        &self,
        session: &Session,
        error: &str,
    ) -> Option<(String, String)> {
        let meta = session.meta();
        let running = model_catalog::model_named_in(error)
            .or_else(|| crate::hub::model_options::current_model(&meta))
            .or_else(|| session.applied.lock().unwrap_or_else(|e| e.into_inner()).model.clone())?;
        let profile = self.config.read().await.profile(&meta.harness).cloned()?;
        let entry = crate::hub::models_view::curated_for(&self.catalog, &meta.harness, &profile);
        let found = match entry {
            Some(entry) => model_catalog::canonical_model(&entry, &running).ok(),
            // No catalog entry for this harness: the one Claude Code or Codex id the name folds to.
            None => model_catalog::ALIASED_HARNESSES
                .iter()
                .filter_map(|h| model_catalog::bundled_harness(h))
                .filter_map(|entry| model_catalog::canonical_model(&entry, &running).ok())
                .find(|c| c.changed()),
        }?;
        found.changed().then_some((found.given, found.model))
    }

    /// Settles the reroute of the turn `cut` failed: sets the chat's model to its catalog id and
    /// sends the turn again, or, when there is none, lets the mark go as an unretried failure.
    pub(super) fn reroute_model_turn(
        self: &Arc<Self>,
        session: &Arc<Session>,
        cut: &CutTurn<'_>,
        wake: Arc<Notify>,
    ) {
        let by = RetryBy {
            control: cut.control,
            trust_gate: cut.trust_gate,
            full_access_device: None,
            from: cut.from.map(str::to_owned),
        };
        let (root, _) = split_attempt(cut.prompt_id);
        let (root, cut_turn, error) =
            (root.to_owned(), cut.turn_id.to_owned(), cut.error.to_owned());
        let (hub, session) = (self.clone(), session.clone());
        self.scope.spawn_until_cancelled("model-reroute", async move {
            let Some((from, to)) = hub.reroute_target(&session, &error).await else {
                if hub.take_pending(&session, &cut_turn) {
                    hub.settled_unretried(&session, &cut_turn, "not_retried");
                }
                return;
            };
            tokio::select! {
                () = tokio::time::sleep(Duration::from_millis(REROUTE_WAIT_MS)) => {}
                () = wake.notified() => {}
            }
            // The failed turn lets go of the chat, so the switch applies now (a harness that
            // takes its model at spawn restarts on it) and the resend finds it free.
            let started = Instant::now();
            while (session.turn().is_some() || session.turn_lock.try_lock().is_err())
                && started.elapsed() < IDLE_DEADLINE
            {
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
            let gone = session.status() == SessionStatus::Closed
                || session.moving().is_some()
                || session.replaced.load(std::sync::atomic::Ordering::SeqCst);
            if gone || !hub.continuation_pending(&session) {
                hub.take_pending(&session, &cut_turn);
                return;
            }
            if let Err(e) = hub.set_model(&session, &to).await {
                tracing::warn!(session = %session.id, "model-reroute: {from} -> {to} refused: {}", e.message);
                if hub.take_pending(&session, &cut_turn) {
                    hub.settled_unretried(&session, &cut_turn, "not_retried");
                }
                return;
            }
            let host = crate::pairing::machine_name();
            let name = Some(session.meta().name).filter(|n| !n.is_empty());
            let name = name.unwrap_or_else(|| session.id.clone());
            let line = format!("model-reroute: {host}/{name} {from} -> {to}, turn retried");
            tracing::info!(session = %session.id, "{line}");
            let msg =
                json!({"from": from, "to": to, "turnId": cut_turn, "promptId": root, "text": line});
            hub.append_retry(&session, crate::hub::model_alias::REROUTE_RECORD, msg);
            let Err(e) = hub.resend_turn(&session, by, Some(&cut_turn)).await else { return };
            hub.take_pending(&session, &cut_turn);
            let reason = e.data.as_ref().and_then(|d| d.get("reason")).and_then(Value::as_str);
            tracing::info!(session = %session.id, ?reason, "model-reroute: turn not sent: {}", e.message);
            let skipped = json!({"promptId": root, "attempt": 1, "turnId": cut_turn, "skipped": "refused", "error": e.message, "modelReroute": true});
            hub.append_retry(&session, "auto_resume_skipped", skipped);
        });
    }
}

#[cfg(test)]
#[path = "model_reroute_tests.rs"]
mod tests;
