//! Part of `Hub`; see `hub/mod.rs`. A turn whose agent says nothing: a model
//! that never answers (an OpenCode free model that stalls, a provider that
//! hangs) left the chat on "Thinking" with no end and no sign why. When a
//! prompt went out and the agent sent no sign of its model at work
//! (`Session::heard`, `tap.rs` `from_the_model`: a message, thought, tool call,
//! plan, compaction or request, or a harness line only a responding model
//! produces) for `silentTurnMs` (default 90 s), the chat logs `turn_silent`
//! {turnId, silentMs} once, so a client can say the model has not answered.
//! The model's first sign after it logs `turn_heard` {turnId}, which ends that
//! on every client. The agent's own bookkeeping is no answer: Codex reports its
//! turn and its usage as soon as the prompt goes out, whatever its model does.
//! Only silence from the prompt counts: an agent that answered and then works
//! quietly (a long command) is not silent.

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
            // Held while it logs, so a sign the tap counts meanwhile finds the silence to end.
            let mut silent = session.silent_turn.lock().unwrap_or_else(|e| e.into_inner());
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
                *silent = Some(turn_id);
            }
        });
    }

    /// The tap heard `session`'s model: a turn that logged `turn_silent` logs `turn_heard`.
    pub(super) fn heard_after_silence(&self, session: &Session) {
        let Some(turn_id) = session.silent_turn.lock().unwrap_or_else(|e| e.into_inner()).take()
        else {
            return;
        };
        if session.turn().is_some_and(|t| t.turn_id == turn_id) {
            self.append(session, "mux", "turn_heard", json!({"turnId": turn_id}));
        }
    }
}
