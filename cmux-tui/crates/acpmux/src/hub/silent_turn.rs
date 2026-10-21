//! Part of `Hub`; see `hub/mod.rs`. A turn whose agent says nothing: a model
//! that never answers (an OpenCode free model that stalls, a provider that
//! hangs) left the chat on "Thinking" with no end and no sign why. When a
//! prompt went out and nothing at all came back from the agent (no update,
//! request or answer, `Session::heard`) for `silentTurnMs` (default 90 s), the
//! chat logs `turn_silent` {turnId, silentMs} once, so a client can say the
//! model has not answered; the agent's first word after it ends that on the
//! client. Only silence from the prompt counts: an agent that answered and then
//! works quietly (a long command) is not silent.

use super::*;

impl Hub {
    /// Watches `session`'s turn `turn_id`, whose prompt goes out now (module docs).
    pub(super) async fn watch_silent_turn(self: &Arc<Self>, session: &Arc<Session>, turn_id: &str) {
        let Some(after) = self.config.read().await.silent_turn() else { return };
        let heard = session.heard.load(Ordering::SeqCst);
        let hub = self.clone();
        let session = session.clone();
        let turn_id = turn_id.to_owned();
        tokio::spawn(async move {
            tokio::time::sleep(after).await;
            if session.turn().is_some_and(|t| t.turn_id == turn_id)
                && session.heard.load(Ordering::SeqCst) == heard
            {
                tracing::warn!(session = %session.id, turn = %turn_id, "the agent has said nothing since the prompt");
                let silent_ms = u64::try_from(after.as_millis()).unwrap_or(u64::MAX);
                hub.append(
                    &session,
                    "mux",
                    "turn_silent",
                    json!({"turnId": turn_id, "silentMs": silent_ms}),
                );
            }
        });
    }
}
