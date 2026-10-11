//! The durable outbox: one op at a time, the agent_rate retry, rejects.

use cmux_conversation::{Change, Op};

use super::{Core, Effect, OUTBOX_TIMER, Port};
use crate::rules::{AGENT_GAP_RETRY_MS, AGENT_GAP_TIMER_SLACK_MS};

impl Core {
    /// Sends the outbox head; the next entry waits for its result.
    pub(super) fn flush_outbox(&mut self) {
        while self.daemon_up && self.outbox_inflight.is_none() {
            let Some(entry) = self.state.outbox.first() else { return };
            if let Some(at) = entry.not_before
                && self.now < at
            {
                // Its one-shot timer flushes it; armed again here after a
                // restart or an early fire.
                self.arm_outbox_timer(at + AGENT_GAP_TIMER_SLACK_MS);
                return;
            }
            let op = match (&entry.child, &entry.op) {
                (Some(child), Op::MessageEdit { parts, .. }) => self
                    .state
                    .children
                    .get(child)
                    .and_then(|c| c.message_id.clone())
                    .filter(|id| !id.is_empty())
                    .map(|message_id| Op::MessageEdit { message_id, parts: parts.clone() }),
                _ => Some(entry.op.clone()),
            };
            let Some(op) = op else {
                // An edit of a card whose send was never confirmed: nothing to edit.
                self.state.outbox.remove(0);
                self.dirty = true;
                continue;
            };
            let (conversation, key) = (entry.conversation.clone(), entry.idempotency_key.clone());
            self.outbox_inflight = Some(key.clone());
            self.emit(Effect::ConversationOp { conversation, idempotency_key: key, op });
        }
    }

    pub(super) fn arm_outbox_timer(&mut self, at: u64) {
        if self.outbox_timer_at == Some(at) {
            return;
        }
        self.outbox_timer_at = Some(at);
        self.emit(Effect::ArmTimer { key: OUTBOX_TIMER.to_owned(), at });
    }

    pub(super) fn op_result(&mut self, key: &str, reason: Option<&str>, change: Option<Change>) {
        if self.outbox_inflight.as_deref() != Some(key) {
            // A read cursor op: the owner's change event updates the summary.
            if let Some(reason) = reason
                && !reason.contains("cursor_regression")
            {
                self.log(format!("op {key} rejected: {reason}"));
            }
            return;
        }
        self.outbox_inflight = None;
        let Some(head) = self.state.outbox.first_mut() else { return };
        match reason {
            None => {
                if let (Some(child), Op::MessageSend { .. }, Some(Change::Message { message })) =
                    (&head.child, &head.op, &change)
                    && let Some(record) = self.state.children.get_mut(child)
                {
                    record.message_id = Some(message.id.clone());
                }
            }
            Some(reason) if reason.contains("actor_mismatch") => {
                // The binding was lost: reconnect, which binds again; keep the entry.
                self.log(format!("op {key}: binding lost; reconnecting to bind again"));
                self.emit(Effect::Reconnect { port: Port::Daemon });
                return;
            }
            Some(reason) if reason.contains("agent_rate") && !head.rate_retried => {
                head.rate_retried = true;
                let at = self.now + AGENT_GAP_RETRY_MS;
                head.not_before = Some(at);
                self.dirty = true;
                self.log(format!("op {key} inside the agent gap; retrying once after it"));
                self.arm_outbox_timer(at + AGENT_GAP_TIMER_SLACK_MS);
                return;
            }
            Some(reason) => self.log(format!("dropping rejected op {key}: {reason}")),
        }
        self.state.outbox.remove(0);
        self.dirty = true;
        self.flush_outbox();
    }
}
