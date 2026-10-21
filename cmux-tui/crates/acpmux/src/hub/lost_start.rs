//! Part of the queue restore (`queue.rs` `restore_queue`): a queued prompt that left the queue
//! for its own turn (`dequeued`) when the daemon stopped, before that turn started, goes back at
//! the head of the queue. `turn_started` is logged before the prompt is sent, so such a prompt
//! never reached the agent: running it after the restart runs it once. Without this it had no
//! queue entry and no result, and a resend answered it `interrupted`.

use crate::store::EventRecord;
use serde_json::Value;

/// The `queued` records of prompts dequeued for a turn that has not started, read in log order.
#[derive(Default)]
pub(super) struct Unstarted {
    /// A turn started and not settled: a prompt dequeued into it was steered in (`steer_end.rs`).
    open: bool,
    prompts: Vec<EventRecord>,
}

impl Unstarted {
    /// One record, before `restore_queue` reads it; `waiting` is what it still holds queued.
    pub(super) fn read(&mut self, e: &EventRecord, waiting: &[EventRecord]) {
        let (turn_id, prompt_id) = (e.msg.get("turnId"), e.msg.get("promptId"));
        let other = |q: &EventRecord| q.msg.get("promptId") != prompt_id;
        match e.kind.as_str() {
            "dequeued" if !self.open => {
                let q = waiting.iter().find(|q| q.msg.get("turnId") == turn_id);
                self.prompts.extend(q.cloned());
            }
            // Its turn started; a daemon that started another turn had settled it too.
            "turn_started" => (self.open, self.prompts) = (true, Vec::new()),
            "turn_result" => {
                self.open = false;
                self.prompts.retain(other);
            }
            // Recorded for its own turn, it still waits for `turn_started`; a steer (or a run
            // under another turn id) settled it.
            "user_message" => {
                let steer = e.msg.get("steer") == Some(&Value::Bool(true));
                self.prompts.retain(|q| other(q) || (!steer && q.msg.get("turnId") == turn_id));
            }
            // Refused, withdrawn, or queued again under a new turn id.
            "prompt_refused" | "queue_removed" | "queued" => self.prompts.retain(other),
            _ => {}
        }
    }

    pub(super) fn prompts(self) -> Vec<EventRecord> {
        self.prompts
    }
}
