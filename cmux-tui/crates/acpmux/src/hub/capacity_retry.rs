//! Bound the harness's in-turn capacity loop before using the daemon's backed-off retry chain.
//! Older Codex reports `Reconnecting... N` without a maximum. Those notices never end its
//! prompt, so `auto_resume` cannot apply its budget until we end the failed attempt here.

use super::*;

const MAX_CAPACITY_RETRIES: u8 = 3;

#[derive(Debug, Default)]
pub(super) struct Retries {
    generation: u64,
    count: u8,
    ending: bool,
}

impl Retries {
    fn observe(&mut self, generation: u64) -> bool {
        // A real model response, new turn or new agent resets the consecutive failures.
        // A retry notice itself never increments stalled_gen (tap.rs from_the_model).
        if self.generation != generation {
            *self = Self { generation, ..Self::default() };
        }
        self.count = self.count.saturating_add(1);
        self.count >= MAX_CAPACITY_RETRIES && !std::mem::replace(&mut self.ending, true)
    }
}

impl Hub {
    pub(super) fn end_capacity_retries(&self, session: &Arc<Session>, retry: &Value) {
        let error = retry["error"].as_str().unwrap_or("");
        let status = retry["errorStatus"].as_u64();
        if retry["source"] != "codex"
            || !(crate::turn_errors::transient_cause(error) == Some("capacity")
                || (error.is_empty() && matches!(status, Some(503 | 529))))
        {
            return;
        }
        let generation = session.stalled_gen.load(Ordering::SeqCst);
        let Some(turn) = session.turn() else { return };
        if super::cancel::is_stopping(session, &turn.turn_id) {
            return;
        }
        if !session
            .stream
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .capacity_retries
            .observe(generation)
        {
            return;
        }
        let cause = if error.is_empty() { "The selected model is at capacity" } else { error };
        let answer = json!({"stopReason": "cancelled", "_meta": {"acpmux": {
            "capacityRetryExhausted": {"error": cause, "attempts": MAX_CAPACITY_RETRIES}
        }}});
        self.append(
            session,
            "mux",
            "capacity_retry_exhausted",
            json!({
                "turnId": turn.turn_id, "attempts": MAX_CAPACITY_RETRIES, "error": cause
            }),
        );
        let session = session.clone();
        let turn_id = turn.turn_id;
        self.scope.spawn_until_cancelled("capacity-retry-end", async move {
            let ours = |s: &Session| {
                s.stalled_gen.load(Ordering::SeqCst) == generation
                    && s.turn().is_some_and(|t| t.turn_id == turn_id)
                    && !super::cancel::is_stopping(s, &turn_id)
            };
            let _ = tokio::time::timeout(super::stalled_turn::CANCEL_SEND, async {
                // Cancel names the session, not the turn. Hold the next prompt behind this
                // write so a delayed cancel cannot end the automatic retry's new turn.
                let _input = session.input_handoff.lock().await;
                let child = session.child.lock().await.clone();
                if ours(&session)
                    && let (Some(child), Some(sid)) = (child, session.meta().agent_session_id)
                {
                    // Publish the typed failure before the agent can acknowledge cancellation.
                    session.steer_end.send_replace(Some((turn_id.clone(), answer.clone())));
                    let _ = child.notify(method::SESSION_CANCEL, json!({"sessionId": sid})).await;
                }
            })
            .await;
            if ours(&session) {
                session.steer_end.send_replace(Some((turn_id, answer)));
            }
        });
    }

    pub(super) fn capacity_retry_error(answer: &Value) -> Option<RpcError> {
        let exhausted = answer.pointer("/_meta/acpmux/capacityRetryExhausted")?;
        let cause = exhausted["error"].as_str().unwrap_or("The selected model is at capacity");
        Some(RpcError::new(-32000, format!(
            "{cause}. Stopped repeated capacity retries; further automatic attempts use the configured backoff and retry limit."
        )).with_data(json!({"detail": "capacity_retry_exhausted", "attempts": MAX_CAPACITY_RETRIES})))
    }
}

#[cfg(test)]
#[path = "capacity_retry_tests.rs"]
mod tests;
