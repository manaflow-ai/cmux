//! Part of `Hub`; see `hub/mod.rs`. Prompts waiting for a session's running turn.

use super::*;
use std::sync::atomic::Ordering;

/// A prompt waiting for the running turn to end.
#[derive(Debug, Clone)]
pub struct QueuedPrompt {
    pub prompt_id: String,
    pub turn_id: String,
    pub client: String,
    pub preview: String,
    pub queued_at: u64,
    /// Fired by `remove_queued`: the waiting `session/prompt` answers withdrawn at once.
    pub(super) withdraw: Arc<Notify>,
}

/// What a withdrawn prompt's `session/prompt` answers: no turn ran.
pub(super) fn withdrawn_reply(prompt_id: &str, turn_id: &str) -> Value {
    json!({
        "stopReason": "cancelled",
        "_meta": {"acpmux": {"promptId": prompt_id, "turnId": turn_id, "withdrawn": true}},
    })
}

impl Hub {
    /// Puts a prompt that waits for the running turn in the queue and tells every client right
    /// away; the turn itself starts when the turn lock frees. The returned `Notify` fires when
    /// `remove_queued` withdraws it.
    pub(super) fn enqueue(
        &self,
        session: &Arc<Session>,
        text: &str,
        client: &str,
        position: u64,
        prompt_id: &str,
        turn_id: &str,
    ) -> Arc<Notify> {
        let withdraw = Arc::new(Notify::new());
        session.queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner).push(
            QueuedPrompt {
                prompt_id: prompt_id.to_owned(),
                turn_id: turn_id.to_owned(),
                client: client.to_owned(),
                preview: short_text(text, 200),
                queued_at: now_ms(),
                withdraw: withdraw.clone(),
            },
        );
        self.append(
            session,
            "mux",
            "queued",
            json!({"text": text, "client": client, "position": position, "promptId": prompt_id, "turnId": turn_id}),
        );
        withdraw
    }

    /// With the turn lock held, takes a queued prompt out of the queue for its turn. A prompt
    /// `remove_queued` withdrew just as the lock freed (and counted off) gets no turn: the reply
    /// its `session/prompt` answers instead.
    pub(super) fn take_queued(
        &self,
        session: &Arc<Session>,
        prompt_id: &str,
        turn_id: &str,
    ) -> Option<Value> {
        {
            let mut queue = session.queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            let Some(i) = queue.iter().position(|q| q.turn_id == turn_id) else {
                return Some(withdrawn_reply(prompt_id, turn_id));
            };
            queue.remove(i);
            session.queued.fetch_sub(1, Ordering::SeqCst);
        }
        self.append(
            session,
            "mux",
            "dequeued",
            json!({"promptId": prompt_id, "turnId": turn_id, "queued": session.queued()}),
        );
        None
    }

    /// Takes a waiting prompt out of the queue before its turn starts; its `session/prompt` then
    /// answers `cancelled` with `_meta.acpmux.withdrawn`. False when the prompt is not waiting
    /// (it started, ended or was already removed).
    pub fn remove_queued(&self, session: &Arc<Session>, prompt_id: &str) -> bool {
        let removed = {
            let mut queue = session.queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            let Some(i) = queue.iter().position(|q| q.prompt_id == prompt_id) else {
                return false;
            };
            session.queued.fetch_sub(1, Ordering::SeqCst);
            queue.remove(i)
        };
        self.append(
            session,
            "mux",
            "queue_removed",
            json!({"promptId": prompt_id, "turnId": removed.turn_id, "queued": session.queued()}),
        );
        // A stored permit: the waiting task sees it even before it polls.
        removed.withdraw.notify_one();
        true
    }
}
