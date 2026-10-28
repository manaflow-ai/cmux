//! Stop: the agent gets the cancel, and the turn ends even if it never
//! answers. Claude Code idle after a local slash command takes the interrupt
//! and writes no result, so acpmux's turn stayed open, Stop did nothing and
//! the queue waited (cosmic-gray, 2026-10-14). After [`CANCEL_GRACE`] acpmux
//! ends the turn itself, as cancelled, and its `turn_result` says
//! `cancelForced`; the prompt's answer, if it ever comes, finds no turn.
//!
//! The grace is long enough for an agent that is only slow to stop: the next
//! queued prompt goes out when the turn ends, and an agent still inside the
//! stopped turn mishandles it (codex-acp folds it into that turn and answers
//! it cancelled, cx-he737). The pane stops showing the turn as working 5 s
//! after Stop on its own.

use super::*;

/// How long a cancelled turn waits for its agent's answer before acpmux ends it.
const CANCEL_GRACE: std::time::Duration = std::time::Duration::from_secs(10);

impl Hub {
    pub async fn cancel(&self, session: &Arc<Session>) -> Result<(), RpcError> {
        // First: a prompt about to be written sees it (`turns.rs`).
        session.cancels.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        // Stop also stops an automatic continuation that has not fired yet, and the running
        // turn gets none (`auto_resume.rs`).
        self.stop_auto_resume(session);
        self.stop_subagent_retries(session, false);
        let child = session
            .child
            .lock()
            .await
            .clone()
            .ok_or_else(|| RpcError::invalid_params("session has no live agent"))?;
        let sid = session
            .meta()
            .agent_session_id
            .ok_or_else(|| RpcError::internal("no agent session"))?;
        self.cancel_pending_permissions(session);
        let sent = child
            .notify(method::SESSION_CANCEL, json!({"sessionId": sid}))
            .await
            .map_err(|e| RpcError::internal(e.to_string()));
        // Stop always ends the turn: an agent that does not answer the cancel
        // (Claude Code idle after a local slash command, while acpmux still
        // waits on the prompt) gets its turn ended here, as cancelled and
        // marked forced. The prompt's answer, if it ever comes, finds no turn.
        if let Some(turn) = session.turn() {
            let session = session.clone();
            tokio::spawn(async move {
                tokio::time::sleep(CANCEL_GRACE).await;
                if session.turn().is_some_and(|t| t.turn_id == turn.turn_id) {
                    tracing::warn!(session = %session.id, "the agent did not answer the cancel: ending its turn");
                    let answer = json!({"stopReason": "cancelled", "_meta": {"acpmux": {"cancelForced": true}}});
                    session.steer_end.send_replace(Some((turn.turn_id, answer)));
                }
            });
        }
        sent
    }
}
