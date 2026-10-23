//! Part of the queue restore (`queue.rs` `restore_queue`): a queued prompt that left the queue
//! for its own turn (`dequeued`) when the daemon stopped, before that turn started, goes back at
//! the head of the queue. `turn_started` is logged before the prompt is sent, so such a prompt
//! never reached the agent: running it after the restart runs it once. Without this it had no
//! queue entry and no result, and a resend answered it `interrupted`.
//!
//! Its `queued` record stays in the restore's waiting list, so what a daemon that put it back
//! logged about it afterwards (an edit, a reorder, a hold) applies to it as to any waiting
//! prompt, and a later restore runs its latest copy.

use crate::store::EventRecord;
use serde_json::Value;

/// The prompts dequeued for a turn that has not started, read in log order.
#[derive(Default)]
pub(super) struct Unstarted {
    /// A turn started and not settled: a prompt dequeued into it was steered in (`steer_end.rs`).
    open: bool,
    /// `(promptId, turnId)` of each, in the order they left the queue.
    lost: Vec<(Value, Value)>,
}

impl Unstarted {
    /// One record, before `restore_queue` reads it; `waiting` is what it still holds queued.
    /// Returns the turn ids of the prompts the record settled: they leave the waiting list.
    pub(super) fn read(&mut self, e: &EventRecord, waiting: &[EventRecord]) -> Vec<Value> {
        let (turn_id, prompt_id) = (e.msg.get("turnId"), e.msg.get("promptId"));
        let other = |(p, _): &(Value, Value)| Some(p) != prompt_id;
        match e.kind.as_str() {
            "dequeued" if !self.open => {
                let queued = waiting.iter().any(|q| q.msg.get("turnId") == turn_id);
                if let (true, Some(p), Some(t)) = (queued, prompt_id, turn_id)
                    && !self.holds(turn_id)
                {
                    self.lost.push((p.clone(), t.clone()));
                }
                Vec::new()
            }
            // Its turn started; a daemon that started another turn had settled it too.
            "turn_started" => {
                self.open = true;
                self.settle(|_| false)
            }
            "turn_result" => {
                self.open = false;
                self.settle(other)
            }
            // Recorded for its own turn, it still waits for `turn_started`; a steer (or a run
            // under another turn id) settled it.
            "user_message" => {
                let steer = e.msg.get("steer") == Some(&Value::Bool(true));
                self.settle(|q| other(q) || (!steer && Some(&q.1) == turn_id))
            }
            // Refused, withdrawn, or queued again under a new turn id.
            "prompt_refused" | "queue_removed" | "queued" => self.settle(other),
            // A daemon that put it back moved or held it (an edit only changes its record): it
            // waits as any queued prompt since, in that place, and only what settles a queued
            // prompt settles it.
            "queue_order" => self.forget(|q| named(&e.msg, "order", &q.0)),
            "queue_paused" => self.forget(|q| named(&e.msg, "held", &q.0)),
            _ => Vec::new(),
        }
    }

    /// Whether the prompt of `turn_id` left the queue for a turn that has not started: its
    /// `queued` record stays waiting.
    pub(super) fn holds(&self, turn_id: Option<&Value>) -> bool {
        self.lost.iter().any(|(_, t)| Some(t) == turn_id)
    }

    /// Whether the prompt `prompt_id` left the queue for a turn that has not started.
    pub(super) fn holds_prompt(&self, prompt_id: &Value) -> bool {
        self.lost.iter().any(|(p, _)| p == prompt_id)
    }

    /// Puts these prompts at the head of the queue's `order`, as they left it: they run first,
    /// as they would have. A reorder logged after one left does not name it.
    pub(super) fn lead(&self, order: &mut Vec<Value>) {
        order.retain(|id| !self.holds_prompt(id));
        order.splice(0..0, self.lost.iter().map(|(p, _)| p.clone()));
    }

    /// Keeps the prompts `keep` accepts; returns the turn ids of the others.
    fn settle(&mut self, keep: impl Fn(&(Value, Value)) -> bool) -> Vec<Value> {
        let (kept, settled): (Vec<_>, Vec<_>) =
            std::mem::take(&mut self.lost).into_iter().partition(keep);
        self.lost = kept;
        settled.into_iter().map(|(_, t)| t).collect()
    }

    /// Stops tracking the prompts `waits` accepts; they stay waiting.
    fn forget(&mut self, waits: impl Fn(&(Value, Value)) -> bool) -> Vec<Value> {
        self.lost.retain(|q| !waits(q));
        Vec::new()
    }
}

/// Whether the record's list `key` names `prompt_id`.
fn named(msg: &Value, key: &str, prompt_id: &Value) -> bool {
    msg.get(key).and_then(Value::as_array).is_some_and(|ids| ids.contains(prompt_id))
}
