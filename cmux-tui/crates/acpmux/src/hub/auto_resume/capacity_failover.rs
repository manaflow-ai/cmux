//! A chat whose provider stays overloaded goes on on a smaller model of the same harness, and
//! back once it recovers (Leo, 2026-11-24: "fix 529s properly with better designs"). The SR2
//! gateway admits and sheds load; acpmux fails over.
//!
//! - A capacity cut ([`super::super::turn_errors::resume_cause`] `capacity`: HTTP 529 or 503,
//!   "overloaded", the gateway's "no non-exhausted accounts" or call limit) is continued forever
//!   (`waits_it_out`). From attempt `N` of one cut prompt on (`P~resume-N`, so after `N`
//!   capacity failures: the prompt and `N - 1` attempts), the attempt runs on the fallback
//!   model: the catalog's newest Sonnet for a chat on Opus or Fable
//!   ([`crate::model_catalog::capacity_fallback`]); a chat on Sonnet or Haiku, or on a model the
//!   catalog does not know, stays where it is. `N` is `capacityFallbackAfter` in config.json,
//!   else Settings' `agents.autoRetry.capacityFallbackAfter`, default 0: never switches
//!   ([`super::settings::capacity_fallback_after`]; cmux#57784).
//! - The switch is made as the attempt fires, after its wait: a Stop, close or the person's
//!   prompt during the wait takes the mark as before, and nothing switches. The queue is kept;
//!   the session goes on.
//! - The chat's own model is kept in its meta (`SessionMeta::capacity_fallback`, saved before
//!   the switch), so a daemon restart, or a wait the next daemon restores (`restore.rs`), still
//!   puts it back. A chat already on its fallback does not switch again.
//! - A turn that ends well on the fallback model puts the chat's own model back. A chat whose
//!   model someone changed meanwhile keeps theirs.
//! - A chat left on its fallback when switching is off (turned off since, or a chat the gateway's
//!   own 503s cut on every turn, so none ended well: cmux#57784) gets its own model back before
//!   its next capacity attempt fires, instead of staying on the fallback for good, and before
//!   any other prompt goes in ([`Hub::restore_capacity_fallback_if_off`], called from
//!   `turns/prompt_entry.rs` `prompt_with`): nobody runs a turn on a model they did not pick.
//! - One line says each switch, in the daemon's log and as a notice row in the transcript:
//!   `capacity_failover` `{from, to, attempt, promptId, text}` and `capacity_restored`
//!   `{from, to, text}`.

use super::split_attempt;
use crate::hub::{Hub, Session};
use crate::model_catalog;
use crate::store::CapacityFallback;
use serde_json::json;
use std::sync::Arc;
use std::time::{Duration, Instant};

/// The mux record a failover leaves, drawn as a notice row.
pub(in crate::hub) const FAILOVER_RECORD: &str = "capacity_failover";
/// The mux record the way back leaves, drawn as a notice row.
pub(in crate::hub) const RESTORED_RECORD: &str = "capacity_restored";

/// The longest the way back waits for the turn that ended well to let go of the chat.
const IDLE_DEADLINE: Duration = Duration::from_secs(10);

/// Whether capacity attempt `attempt` runs on the fallback model when it is set to switch from
/// attempt `after` on (0: never).
pub(super) fn fails_over_at(attempt: usize, after: usize) -> bool {
    after > 0 && attempt >= after
}

/// The notice of a switch from `from` to `to`.
pub(super) fn failover_text(from: &str, to: &str) -> String {
    format!("acpmux: Anthropic overloaded: continuing on {to} (was {from}); back when it recovers")
}

/// The notice of the way back to `from` from `to`.
pub(super) fn restored_text(from: &str, to: &str) -> String {
    format!("acpmux: capacity is back: continuing on {from} (ran on {to} meanwhile)")
}

impl Hub {
    /// The catalog entry of `session`'s harness; for a harness the catalog has no entry for (a
    /// saved profile, a test harness), Claude Code's or Codex's bundled one that knows `model`.
    async fn failover_entry(
        &self,
        session: &Session,
        model: &str,
    ) -> Option<crate::catalog::CatalogHarness> {
        let harness = session.meta().harness;
        let profile = self.config.read().await.profile(&harness).cloned()?;
        if let Some(entry) = crate::hub::models_view::curated_for(&self.catalog, &harness, &profile)
        {
            return Some(entry);
        }
        model_catalog::ALIASED_HARNESSES
            .iter()
            .filter_map(|h| model_catalog::bundled_harness(h))
            .find(|entry| model_catalog::capacity_fallback(entry, model).is_some())
    }

    /// The model `session` runs now, as it names it.
    fn running_model(session: &Session) -> Option<String> {
        crate::hub::model_options::current_model(&session.meta())
            .or_else(|| session.applied.lock().unwrap_or_else(|e| e.into_inner()).model.clone())
    }

    /// The model `session` runs and the one a sustained overload moves it to; None when it
    /// stays (already small, unknown, or already on its fallback).
    pub(in crate::hub) async fn capacity_fallback_target(
        &self,
        session: &Session,
    ) -> Option<(String, String)> {
        if session.meta().capacity_fallback.is_some() {
            return None;
        }
        let running = Self::running_model(session)?;
        let entry = self.failover_entry(session, &running).await?;
        let to = model_catalog::capacity_fallback(&entry, &running)?;
        (!model_catalog::same_model(Some(&entry), &running, &to)).then_some((running, to))
    }

    /// Before capacity attempt `attempt` at the cut prompt `root` fires: moves the chat to its
    /// fallback model when the attempt is the configured one or later. The attempt's mark is
    /// firing here, so a Stop or close still refuses its turn.
    pub(super) async fn fail_over_on_capacity(
        self: &Arc<Self>,
        session: &Arc<Session>,
        root: &str,
        attempt: usize,
    ) {
        let configured = self.config.read().await.capacity_fallback_after;
        let after = super::settings::capacity_fallback_after(configured);
        if !fails_over_at(attempt, after) {
            // Switching is off, or not yet due: a chat a past switch left on its fallback goes
            // back to its own model before this attempt, instead of waiting for a turn that ends
            // well, which a gateway that cuts every turn never gives (cmux#57784).
            if after == 0 {
                let fallback =
                    session.meta.lock().unwrap_or_else(|e| e.into_inner()).capacity_fallback.take();
                if let Some(fallback) = fallback {
                    self.put_back(session, fallback).await;
                }
            }
            return;
        }
        let Some((from, to)) = self.capacity_fallback_target(session).await else { return };
        // The chat's own model is saved first: a daemon that dies mid-switch still knows it.
        session.meta.lock().unwrap_or_else(|e| e.into_inner()).capacity_fallback =
            Some(CapacityFallback { from: from.clone(), to: to.clone() });
        if let Err(e) = self.save_meta_answered(session) {
            tracing::warn!(session = %session.id, "capacity-failover: meta not saved: {}", e.message);
        }
        if let Err(e) = self.set_model(session, &to).await {
            tracing::warn!(session = %session.id, "capacity-failover: {from} -> {to} refused: {}", e.message);
            session.meta.lock().unwrap_or_else(|e| e.into_inner()).capacity_fallback = None;
            let _ = self.save_meta_answered(session);
            return;
        }
        let text = failover_text(&from, &to);
        tracing::info!(session = %session.id, "capacity-failover: {} {text}", Self::who(session));
        let root = split_attempt(root).0;
        let msg =
            json!({"from": from, "to": to, "attempt": attempt, "promptId": root, "text": text});
        self.append_retry(session, FAILOVER_RECORD, msg);
    }

    /// Before a prompt of `session` goes in: with switching off (the default), a chat a past
    /// switch left on its fallback gets its own model back first, so the prompt runs on the
    /// model its person picked (Leo, 2026-11-26: "austin noticed his models getting switched to
    /// sonnet. we shouldnt do that"). Without this a chat that sat idle on Sonnet ran its next
    /// prompt there, and showed Sonnet in the picker, until a turn ended well or a capacity
    /// attempt fired.
    pub(in crate::hub) async fn restore_capacity_fallback_if_off(
        self: &Arc<Self>,
        session: &Arc<Session>,
    ) {
        if session.read_meta(|m| m.capacity_fallback.is_none()) {
            return;
        }
        let configured = self.config.read().await.capacity_fallback_after;
        if super::settings::capacity_fallback_after(configured) != 0 {
            return;
        }
        let fallback =
            session.meta.lock().unwrap_or_else(|e| e.into_inner()).capacity_fallback.take();
        if let Some(fallback) = fallback {
            self.put_back(session, fallback).await;
        }
    }

    /// `HOST/NAME` of `session`, for a log line.
    fn who(session: &Session) -> String {
        let host = crate::pairing::machine_name();
        let name = Some(session.meta().name).filter(|n| !n.is_empty());
        format!("{host}/{}", name.unwrap_or_else(|| session.id.clone()))
    }

    /// A turn of `session` ended well: when it runs on a capacity fallback, its own model comes
    /// back, once the turn lets go of the chat. Off the turn's path.
    pub(in crate::hub) fn restore_after_capacity(self: &Arc<Self>, session: &Arc<Session>) {
        // Taken now, so one way back runs however many turns end meanwhile.
        let Some(fallback) =
            session.meta.lock().unwrap_or_else(|e| e.into_inner()).capacity_fallback.take()
        else {
            return;
        };
        let (hub, session) = (self.clone(), session.clone());
        self.scope.spawn_until_cancelled("capacity-restore", async move {
            let started = Instant::now();
            while (session.turn().is_some() || session.turn_lock.try_lock().is_err())
                && started.elapsed() < IDLE_DEADLINE
            {
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
            hub.put_back(&session, fallback).await;
        });
    }

    /// Puts `session`'s own model (`fallback.from`) back when it still runs its fallback
    /// (`fallback.to`), with one `capacity_restored` notice; `fallback` is already taken from its
    /// meta. A chat someone moved to another model meanwhile keeps theirs; a switch the harness
    /// refuses keeps the fallback recorded, for the next try.
    async fn put_back(self: &Arc<Self>, session: &Arc<Session>, fallback: CapacityFallback) {
        let CapacityFallback { from, to } = fallback;
        let running = Self::running_model(session);
        let entry = self.failover_entry(session, &from).await;
        // Someone chose another model meanwhile: theirs stays.
        if running.as_deref().is_none_or(|r| !model_catalog::same_model(entry.as_ref(), r, &to)) {
            tracing::info!(session = %session.id, ?running, "capacity-failover: {} kept its model; {from} not put back", Self::who(session));
            let _ = self.save_meta_answered(session);
            return;
        }
        if let Err(e) = self.set_model(session, &from).await {
            tracing::warn!(session = %session.id, "capacity-failover: back to {from} refused: {}", e.message);
            // The next turn that ends well, or the next attempt, tries again.
            let mut meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            meta.capacity_fallback.get_or_insert(CapacityFallback { from, to });
            return;
        }
        let _ = self.save_meta_answered(session);
        let text = restored_text(&from, &to);
        tracing::info!(session = %session.id, "capacity-failover: {} {text}", Self::who(session));
        self.append_retry(session, RESTORED_RECORD, json!({"from": to, "to": from, "text": text}));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_switch_comes_at_the_configured_attempt_and_after() {
        assert!(!fails_over_at(1, 3));
        assert!(!fails_over_at(2, 3));
        assert!(fails_over_at(3, 3));
        assert!(fails_over_at(7, 3));
        assert!(fails_over_at(1, 1));
        // 0 never switches.
        assert!(!fails_over_at(1, 0));
        assert!(!fails_over_at(50, 0));
    }

    #[test]
    fn the_notices_name_both_models() {
        assert_eq!(
            failover_text("claude-opus-5-5", "claude-sonnet-5-5"),
            "acpmux: Anthropic overloaded: continuing on claude-sonnet-5-5 (was claude-opus-5-5); back when it recovers"
        );
        let back = restored_text("claude-opus-5-5", "claude-sonnet-5-5");
        assert!(back.contains("continuing on claude-opus-5-5"), "{back}");
        assert!(back.contains("claude-sonnet-5-5"), "{back}");
    }
}
