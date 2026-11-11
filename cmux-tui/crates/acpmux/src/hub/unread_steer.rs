//! A steer that a restart left unread goes back to the queue.
//!
//! A steer goes into the running turn (`steer_end.rs` `steer_turn`). An agent that ends the turn
//! before it reads the steer answers `STEER_NO_TURN` (Claude Code holds another agent's message
//! for the turn's next tool step, `claude_stdio/steer_batch.rs`), and the daemon that wrote the
//! steer then runs it as the next turn. A daemon that adopted the turn after a restart
//! (`hosts.rs`) has no such task: it waited for the steer's answer only to see whether it ended
//! the turn. The sender was told the message went in, and the agent never got it.
//!
//! Here it goes back at the head of the queue, once, under a new turn id, as the writer's own
//! fallback would have run it. A `queued` record keeps it across a second restart
//! (`restored: "unstarted"`, as `unstarted_prompt.rs` does). Not for a steer that goes into its
//! turn or nowhere: a steer-only one, a turn cap's or a workflow's nudge, a trigger's, and
//! acpmux's own notices (an inbox notice's messages are new again by themselves, `inbox.rs`).

use super::*;
use crate::store::EventRecord;

/// The records that say what became of a steer since its `user_message`.
const STEER_KINDS: &[&str] = &[
    "user_message",
    "queued",
    "steer_read",
    "steer_withdrawn",
    "steer_returned",
    "queue_removed",
    "prompt_refused",
];

impl Hub {
    /// `answer`, the agent's answer to recovered steer `prompt_id`, passed on as it comes. An
    /// answer that found no turn first puts the steer back in the queue.
    pub(super) fn unread_steer_runs_next(
        self: &Arc<Self>,
        session: &Arc<Session>,
        prompt_id: Option<String>,
        answer: tokio::sync::oneshot::Receiver<Result<Value, RpcError>>,
    ) -> tokio::sync::oneshot::Receiver<Result<Value, RpcError>> {
        let Some(prompt_id) = prompt_id.filter(|id| !id.is_empty()) else { return answer };
        let (tx, rx) = tokio::sync::oneshot::channel();
        let (hub, session) = (self.clone(), session.clone());
        tokio::spawn(async move {
            // A dropped channel drops `tx` too: the turn's answer sees the same end.
            let Ok(answer) = answer.await else { return };
            if matches!(&answer, Err(e) if e.message.starts_with(crate::claude_stdio::STEER_NO_TURN))
            {
                hub.requeue_unread_steer(&session, &prompt_id);
            }
            let _ = tx.send(answer);
        });
        rx
    }

    /// Puts steer `prompt_id` back at the head of the queue and runs it after the turn, when its
    /// `user_message` is the last record about it and it is a steer that runs as the next turn.
    fn requeue_unread_steer(self: &Arc<Self>, session: &Arc<Session>, prompt_id: &str) {
        if session.meta().status == SessionStatus::Closed {
            return;
        }
        let mut steer: Option<EventRecord> = None;
        let scanned = self.store.scan_kinds(&session.id, STEER_KINDS, &mut |e: EventRecord| {
            if e.dir == "mux" && e.msg.get("promptId").and_then(Value::as_str) == Some(prompt_id) {
                // Queued, run, read, taken back, returned or refused since: settled.
                steer = (e.kind == "user_message"
                    && e.msg.get("steer") == Some(&Value::Bool(true)))
                .then_some(e);
            }
            true
        });
        let Some(steer) = steer.filter(|_| scanned.is_ok()) else { return };
        if !runs_next(&steer.msg) {
            return;
        }
        let turn_id = uuid::Uuid::now_v7().to_string();
        let Some(queued) = self.queued_copy(session, &steer.msg, &turn_id) else {
            tracing::warn!(session = %session.id, prompt = %prompt_id, "an unread steer cannot be rebuilt; a resend runs it");
            return;
        };
        let (_, stored) = self.append_logged(session, "mux", "queued", queued, None);
        if !stored {
            return;
        }
        self.restore_queue_only(session, Some(prompt_id));
        let _ = self.move_queued(session, prompt_id, 0, None);
        if !self.hold_in_protected_folder(session) {
            self.start_restored(session);
        }
    }
}

/// Whether the steer logged as `msg` runs as the next turn when its turn ends unread, as
/// `steer_turn`'s fallback runs it.
fn runs_next(msg: &Value) -> bool {
    let provenance = crate::prompt_provenance::recorded(msg);
    let p = provenance.as_ref();
    msg.get("steerOnly") != Some(&Value::Bool(true))
        && msg.get("client").and_then(Value::as_str) != Some("workflow")
        && !crate::prompt_provenance::is_trigger(p)
        && !super::inbox::is_notice(p)
        && !super::prompt_line::is_notice(p)
        && !super::turn_cap::is_notice(p)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_a_steer_with_a_fallback_runs_next() {
        assert!(runs_next(&json!({"text": "a tell", "steer": true, "client": "acpmux"})));
        assert!(!runs_next(&json!({"text": "x", "steer": true, "steerOnly": true})));
        assert!(!runs_next(&json!({"text": "x", "steer": true, "client": "workflow"})));
        let cap = json!({"kind": super::super::turn_cap::NOTICE_KIND});
        assert!(!runs_next(&json!({"text": "x", "steer": true, "_meta": {"provenance": cap}})));
        let inbox = json!({"kind": super::super::inbox::NOTICE_KIND});
        assert!(!runs_next(&json!({"text": "x", "steer": true, "_meta": {"provenance": inbox}})));
    }
}
