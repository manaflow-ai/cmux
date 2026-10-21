//! Part of `Hub`; see `hub/mod.rs`. `_acpmux/queue_edit`: change a queued prompt before its
//! turn (`update` its prompt, `move` it, or `send_now`), or `resume` the prompts a failed turn
//! holds (`queue.rs` `pause_queue`; any of the queue's prompts names it). Every change is a record in the log, so
//! a new daemon rebuilds the edited queue (`queue.rs` `restore_queues`), and every client sees it.

use super::queue::PromptRun;
use super::*;
use std::sync::atomic::Ordering;

// `_acpmux/prompt_withdraw`, a queue change too (here: `hub/mod.rs` is at its size budget).
#[path = "withdraw.rs"]
mod withdraw;

/// The stricter of two controls: an edit never runs a prompt under looser rules than either
/// the prompt's sender's or the editor's.
fn stricter(a: Control, b: Control) -> Control {
    match (a, b) {
        (Control::Web, _) | (_, Control::Web) => Control::Web,
        (Control::Peer, _) | (_, Control::Peer) => Control::Peer,
        _ => Control::Local,
    }
}

impl Hub {
    /// `_acpmux/queue_edit {sessionId, promptId, op, prompt?|text?, index?}`. Answers
    /// `{sessionId, promptId, op, ok}`, and `send_now` also how it was sent (`sent`: `steer`,
    /// `interrupt` or `next`). `ok` is false when the prompt no longer waits.
    pub async fn queue_edit(
        self: &Arc<Self>,
        session: &Arc<Session>,
        params: &Value,
        control: Control,
        trust_gate: bool,
    ) -> Result<Value, RpcError> {
        let prompt_id = params
            .get("promptId")
            .and_then(Value::as_str)
            .filter(|p| !p.is_empty())
            .ok_or_else(|| RpcError::invalid_params("promptId is required"))?;
        let op = params.get("op").and_then(Value::as_str).unwrap_or_default();
        // The queue moves as it is (`transfer_out.rs`).
        if session.moving().is_some() {
            return Err(super::queue::moving_error());
        }
        let mut reply = json!({"sessionId": session.id, "promptId": prompt_id, "op": op});
        reply["ok"] = match op {
            "update" => {
                let blocks = params
                    .get("prompt")
                    .and_then(Value::as_array)
                    .cloned()
                    .or_else(|| {
                        let text = params.get("text").and_then(Value::as_str)?;
                        Some(vec![json!({"type": "text", "text": text})])
                    })
                    .ok_or_else(|| RpcError::invalid_params("update needs prompt or text"))?;
                json!(self.update_queued(session, prompt_id, blocks, control, trust_gate))
            }
            "move" => {
                let index = params
                    .get("index")
                    .and_then(Value::as_u64)
                    .ok_or_else(|| RpcError::invalid_params("move needs index"))?;
                json!(self.move_queued(session, prompt_id, index as usize))
            }
            "send_now" => {
                let sent = self.send_queued_now(session, prompt_id, control).await?;
                reply["sent"] = json!(sent);
                json!(sent.is_some())
            }
            "resume" => json!(self.resume_queue(session)),
            _ => {
                let e = "op must be update, move, send_now or resume";
                return Err(RpcError::invalid_params(e));
            }
        };
        Ok(reply)
    }

    /// Whether a waiting prompt holds a secret (`secret_scan`). A peer reads it
    /// masked (`server/peer_text.rs`), so it may not rewrite it: an edit from
    /// the masked text would write the mask over the secret.
    pub fn queued_holds_secret(&self, session: &Session, prompt_id: &str) -> bool {
        let queue = session.queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        queue
            .iter()
            .find(|q| q.prompt_id == prompt_id)
            .is_some_and(|q| !crate::secret_scan::find(&prompt_text(&q.run.blocks)).is_empty())
    }

    /// Replaces a waiting prompt's content; it keeps its place. It runs under the stricter
    /// rules of its sender and its editor.
    fn update_queued(
        &self,
        session: &Arc<Session>,
        prompt_id: &str,
        mut blocks: Vec<Value>,
        control: Control,
        trust_gate: bool,
    ) -> bool {
        // Only `session/prompt` adds a hidden context (prompt_context.rs).
        crate::prompt_context::strip_marks(&mut blocks);
        let text = prompt_text(&blocks);
        let (turn_id, run) = {
            let mut queue = session.queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            let Some(q) = queue.iter_mut().find(|q| q.prompt_id == prompt_id) else {
                return false;
            };
            q.run = Arc::new(PromptRun {
                blocks,
                control: stricter(q.run.control, control),
                trust_gate: q.run.trust_gate || trust_gate,
                // The person rewrote it: it is no longer the sender's message.
                provenance: None,
            });
            q.preview = short_text(&text, 200);
            (q.turn_id.clone(), q.run.clone())
        };
        self.append(
            session,
            "mux",
            "queue_updated",
            json!({"promptId": prompt_id, "turnId": turn_id, "text": text, "prompt": run.blocks, "control": run.control.as_str(), "trustGate": run.trust_gate}),
        );
        true
    }

    /// Moves a waiting prompt to `index` (0 is next); the queue's order is what runs.
    pub(super) fn move_queued(
        &self,
        session: &Arc<Session>,
        prompt_id: &str,
        index: usize,
    ) -> bool {
        let order: Vec<String> = {
            let mut queue = session.queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            let Some(from) = queue.iter().position(|q| q.prompt_id == prompt_id) else {
                return false;
            };
            let q = queue.remove(from);
            let to = index.min(queue.len());
            queue.insert(to, q);
            queue.iter().map(|q| q.prompt_id.clone()).collect()
        };
        session.queue_moved.notify_waiters();
        self.append(session, "mux", "queue_order", json!({"promptId": prompt_id, "order": order}));
        true
    }

    /// Sends a waiting prompt now. With no turn running it goes next (`next`); into a running turn
    /// of an agent that steers it is steered in (`steer`) by the task that waits with it, so its
    /// `session/prompt` answers how it ran; otherwise it goes next and the running turn stops
    /// (`interrupt`). `None` when it no longer waits. A failed turn no longer holds it.
    async fn send_queued_now(
        self: &Arc<Self>,
        session: &Arc<Session>,
        prompt_id: &str,
        control: Control,
    ) -> Result<Option<&'static str>, RpcError> {
        let Some(running) = session.turn().map(|t| t.turn_id) else {
            return Ok(self.put_next(session, prompt_id).then_some("next"));
        };
        if session.steering.load(Ordering::SeqCst) {
            let Some(waiting) = session.queue().into_iter().find(|q| q.prompt_id == prompt_id)
            else {
                return Ok(None);
            };
            // The steer runs under the stricter rules of the prompt and of who sent it now.
            let control = stricter(waiting.run.control, control);
            self.check_steer(session, control)?;
            {
                let mut queue =
                    session.queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
                let Some(q) = queue.iter_mut().find(|q| q.prompt_id == prompt_id) else {
                    return Ok(None);
                };
                let run = PromptRun {
                    blocks: q.run.blocks.clone(),
                    control,
                    trust_gate: q.run.trust_gate,
                    provenance: q.run.provenance.clone(),
                };
                (q.run, q.steer) = (Arc::new(run), true);
            }
            session.queue_moved.notify_waiters();
            return Ok(Some("steer"));
        }
        if !self.put_next(session, prompt_id) {
            return Ok(None);
        }
        self.cancel_turn(session, &running).await;
        Ok(Some("interrupt"))
    }
}
