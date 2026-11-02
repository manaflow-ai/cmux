//! Part of `Hub`; see `hub/mod.rs`. `_acpmux/queue_text {sessionId, promptId}`: one queued
//! prompt's whole text and blocks, so a client that expands a queue row shows all of it. The queue
//! list itself (the session summary's `queue`, `_acpmux/composers`) carries only a 200-character
//! `prompt` preview per row: a coordinator's queue may hold hundreds of agent messages of up to
//! 64 KB each, so the whole text is read one prompt at a time, on demand.
//!
//! Anyone who may read the session's log may read it (as `_acpmux/events`, whose `queued` record
//! already holds the same text): it changes nothing. A peer's session is forwarded there. Once
//! the prompt has left the queue it is `queue.not_found`: its `user_message` record (it ran) or its
//! `queued` record (`_acpmux/events` `kinds: ["queued"]`) has its text.

use super::*;

impl Hub {
    /// `{sessionId, promptId, turnId, text, prompt, fromAgent, fromSessionId, fromHarness}` of the
    /// prompt `prompt_id` while it waits in `session`'s queue.
    pub fn queued_text(&self, session: &Session, prompt_id: &str) -> Result<Value, RpcError> {
        let found = {
            let queue = session.queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            queue
                .iter()
                .find(|q| q.prompt_id == prompt_id)
                .map(|q| (q.turn_id.clone(), q.run.clone()))
        };
        let Some((turn_id, run)) = found else {
            return Err(RpcError::not_found(format!(
                "no prompt {prompt_id} waits in this session's queue"
            ))
            .with_data(json!({"reason": "queue.not_found", "promptId": prompt_id})));
        };
        let (from_session_id, from_harness) =
            crate::prompt_provenance::sender_of(run.provenance.as_ref());
        Ok(json!({
            "sessionId": session.id,
            "promptId": prompt_id,
            "turnId": turn_id,
            "text": crate::hub::session::prompt_text(&run.blocks),
            "prompt": run.blocks,
            "fromAgent": run.agent,
            "fromSessionId": from_session_id,
            "fromHarness": from_harness,
        }))
    }
}
