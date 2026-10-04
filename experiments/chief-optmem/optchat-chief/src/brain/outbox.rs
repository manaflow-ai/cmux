//! The durable outbox (mux/host rules): ops in order, one at a time; an
//! `agent_rate` reject is retried once after the owner's gap, any other
//! reject (`agent_budget` included) is dropped so it never loops, and
//! `actor_mismatch` (the app replaced the token) keeps the entry and
//! reconnects, which binds again.

use std::time::{Duration, Instant};

use super::{Brain, now_ms};
use crate::daemon::OpError;

impl Brain {
    pub(super) fn flush_outbox(&mut self) {
        loop {
            let Some(daemon) = self.daemon.as_mut() else {
                return;
            };
            let Some(entry) = self.state.outbox.first() else {
                self.outbox_timer = None;
                return;
            };
            if let Some(at) = entry.not_before {
                let now = now_ms();
                if now < at {
                    // Its one-shot timer flushes it.
                    self.outbox_timer = Some(Instant::now() + Duration::from_millis(at - now + 50));
                    return;
                }
            }
            let (conversation, key, op) = (
                entry.conversation.clone(),
                entry.idempotency_key.clone(),
                entry.op.clone(),
            );
            match daemon.op(&conversation, &key, &op) {
                Ok(_) => {}
                Err(OpError::Rejected(reason)) if reason.contains("actor_mismatch") => {
                    (self.log)(&format!(
                        "op {key}: binding lost; reconnecting to bind again"
                    ));
                    self.drop_daemon();
                    return;
                }
                Err(OpError::Rejected(reason))
                    if reason.contains("agent_rate") && !entry.rate_retried =>
                {
                    let gap = self.settings.agent_gap;
                    let head = &mut self.state.outbox[0];
                    head.rate_retried = true;
                    head.not_before = Some(now_ms() + gap.as_millis() as u64);
                    self.save();
                    (self.log)(&format!(
                        "op {key} inside the agent gap; retrying once after it"
                    ));
                    self.outbox_timer = Some(Instant::now() + gap + Duration::from_millis(50));
                    return;
                }
                Err(OpError::Rejected(reason)) => {
                    (self.log)(&format!("dropping rejected op {key}: {reason}"))
                }
                Err(OpError::Transport(e)) => {
                    // Kept: retried on the next connect (the owner dedupes by key).
                    (self.log)(&format!("op {key}: {e}"));
                    self.drop_daemon();
                    return;
                }
            }
            self.state.outbox.remove(0);
            self.save();
        }
    }
}
