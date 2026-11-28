//! Part of `Hub`; see `hub/mod.rs`. A blocker's notice that goes into a running turn as a steer
//! is read when the agent's current step ends. A step that never ends (Claude Code's model
//! request hung on a 503 and retried minutes apart) left the notice unread for 20 minutes:
//! on 2026-11-26 a coordinator's FIREs and blockers queued behind one such request from
//! 03:58Z until Leo typed "can you wake up" at 04:18Z, whose steer stopped the step at once.
//! Leo: "idk why you got stuck for so long".
//!
//! So a steer that carries a blocker (a block, a question or a FIRE: the notice's thread says
//! `blocker`) and is still unread [`UNREAD_AFTER`] after it was written, in the turn it went
//! into, stops the agent's step as Send now does (`queue_edit.rs` `step_now`): the agent reads
//! it at once and the turn runs on. It looks again every [`UNREAD_AFTER`], [`MAX_STEPS`] times
//! at most. Stop condition: the steer was read or answered, the turn ended or changed, or the
//! agent went. Cleanup: the hub's scope owns the task, so it ends with the hub; it holds only
//! the session, which the hub holds anyway.

use super::*;
use std::time::Duration;

/// How long a blocker's steer may sit unread before the agent's step is stopped for it.
pub(super) const UNREAD_AFTER: Duration = Duration::from_secs(120);
/// The most times one steer stops the step.
const MAX_STEPS: usize = 5;
/// The longest the agent's answer to a stop of its step is waited for.
const STEP_NOW_WAIT: Duration = Duration::from_secs(5);

/// Whether an inbox notice's provenance carries a blocker in any of its threads.
pub(super) fn carries_blocker(provenance: Option<&Value>) -> bool {
    provenance
        .and_then(|p| p.get("threads"))
        .and_then(Value::as_array)
        .is_some_and(|threads| threads.iter().any(|t| t["blocker"] == true))
}

impl Hub {
    /// Watches the steer `prompt_id`, written into `session`'s turn `turn_id` (module docs).
    pub(super) fn watch_urgent_steer(
        self: &Arc<Self>,
        session: &Arc<Session>,
        prompt_id: &str,
        turn_id: &str,
    ) {
        let hub = self.clone();
        let session = session.clone();
        let (prompt_id, turn_id) = (prompt_id.to_owned(), turn_id.to_owned());
        self.scope.spawn_until_cancelled("urgent-steer", async move {
            for step in 1..=MAX_STEPS {
                tokio::time::sleep(UNREAD_AFTER).await;
                let waiting = session
                    .steer_now
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .waiting
                    .contains_key(&prompt_id);
                let same_turn = session.turn().is_some_and(|t| t.turn_id == turn_id);
                if !waiting || !same_turn {
                    return;
                }
                let child = session.child.lock().await.clone();
                let (Some(child), Some(sid)) = (child, session.meta().agent_session_id) else {
                    return;
                };
                let ask = child.request(method::MUX_STEP_NOW, json!({"sessionId": sid}));
                let stopped = matches!(
                    tokio::time::timeout(STEP_NOW_WAIT, ask).await,
                    Ok(Ok(v)) if v["interrupted"] == true
                );
                tracing::warn!(session = %session.id, turn = %turn_id, step, stopped, "a blocker's steer sat unread; stopped the agent's step for it");
                hub.append(
                    &session,
                    "mux",
                    "steer_unread_stepped",
                    json!({"promptId": prompt_id, "turnId": turn_id, "step": step, "stopped": stopped}),
                );
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::carries_blocker;
    use serde_json::json;

    #[test]
    fn a_notice_with_a_blocker_thread_is_urgent() {
        let p = json!({"kind": "inbox_notice", "threads": [{"blocker": false}, {"blocker": true}]});
        assert!(carries_blocker(Some(&p)));
    }

    #[test]
    fn a_notice_without_one_is_not() {
        let p = json!({"kind": "inbox_notice", "threads": [{"blocker": false}]});
        assert!(!carries_blocker(Some(&p)));
        assert!(!carries_blocker(None));
    }
}
