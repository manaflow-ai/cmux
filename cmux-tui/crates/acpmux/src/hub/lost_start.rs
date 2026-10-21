//! Part of the queue restore (`queue.rs` `restore_queue`): a queued prompt that left the queue
//! for its own turn (`dequeued`) when the daemon stopped, before that turn started, goes back at
//! the head of the queue. `turn_started` is logged before the prompt is sent, so such a prompt
//! never reached the agent: running it after the restart runs it once. Without this it had no
//! queue entry and no result, and a resend answered it `interrupted`.
//!
//! Its `queued` record stays in the restore's waiting list, so what a daemon that put it back
//! logged about it afterwards (an edit, a reorder, a hold) applies to it as to any waiting
//! prompt, and a later restore runs its latest copy.
//!
//! Only its own turn's start settles it: another turn's (one a daemon that did not restore it
//! ran, its log load failed) did not run it, and settling it there dropped it unrun.

use super::queue_waiting::{Order, Waiting};
use crate::store::EventRecord;
use serde_json::Value;

/// A prompt dequeued for a turn that has not started.
struct Lost {
    prompt_id: Value,
    turn_id: Value,
    /// The turn whose `turn_started` starts it: its own, or the agent message turn it joined
    /// (`joinedTurnId`, `digest.rs` `take_joined`).
    starts_in: Value,
}

/// The prompts dequeued for a turn that has not started, read in log order.
#[derive(Default)]
pub(super) struct Unstarted {
    /// A turn started and not settled: a prompt dequeued into it was steered in (`steer_end.rs`).
    open: bool,
    /// In the order they left the queue.
    lost: Vec<Lost>,
}

impl Unstarted {
    /// One record, before `restore_queue` reads it; `waiting` is what it still holds queued.
    /// Returns the `(promptId, turnId)` of the prompts the record settled: they leave the waiting
    /// list and the queue order.
    pub(super) fn read(&mut self, e: &EventRecord, waiting: &Waiting) -> Vec<(Value, Value)> {
        let (turn_id, prompt_id) = (e.msg.get("turnId"), e.msg.get("promptId"));
        let other = |q: &Lost| Some(&q.prompt_id) != prompt_id;
        match e.kind.as_str() {
            "dequeued" if !self.open => {
                if let (true, Some(p), Some(t)) = (waiting.has_turn(turn_id), prompt_id, turn_id)
                    && !self.holds(turn_id)
                {
                    let starts_in = e.msg.get("joinedTurnId").unwrap_or(t).clone();
                    self.lost.push(Lost { prompt_id: p.clone(), turn_id: t.clone(), starts_in });
                }
                Vec::new()
            }
            // Its own turn started, or it ran under another turn id; another prompt's turn did
            // not start it.
            "turn_started" => {
                self.open = true;
                self.settle(|q| {
                    other(q) && Some(&q.starts_in) != turn_id && Some(&q.turn_id) != turn_id
                })
            }
            "turn_result" => {
                self.open = false;
                self.settle(other)
            }
            // Recorded for its own turn, it still waits for `turn_started`; a steer (or a run
            // under another turn id) settled it.
            "user_message" => {
                let steer = e.msg.get("steer") == Some(&Value::Bool(true));
                self.settle(|q| other(q) || (!steer && Some(&q.turn_id) == turn_id))
            }
            // Refused, withdrawn, or queued again under a new turn id.
            "prompt_refused" | "queue_removed" | "queued" => self.settle(other),
            // A daemon that put it back moved or held it (an edit only changes its record): it
            // waits as any queued prompt since, in that place, and only what settles a queued
            // prompt settles it.
            "queue_order" => self.forget(|q| named(&e.msg, "order", &q.prompt_id)),
            "queue_paused" => self.forget(|q| named(&e.msg, "held", &q.prompt_id)),
            _ => Vec::new(),
        }
    }

    /// Whether the prompt of `turn_id` left the queue for a turn that has not started: its
    /// `queued` record stays waiting.
    pub(super) fn holds(&self, turn_id: Option<&Value>) -> bool {
        self.lost.iter().any(|q| Some(&q.turn_id) == turn_id)
    }

    /// The prompt ids of the prompts that left the queue for a turn that has not started.
    pub(super) fn prompts(&self) -> impl DoubleEndedIterator<Item = &Value> {
        self.lost.iter().map(|q| &q.prompt_id)
    }

    /// Puts these prompts at the head of the queue's `order`, as they left it: they run first,
    /// as they would have. A reorder logged after one left does not name it.
    pub(super) fn lead(&self, order: &mut Order) {
        order.lead(self.prompts());
    }

    /// Keeps the prompts `keep` accepts; returns the others.
    fn settle(&mut self, keep: impl Fn(&Lost) -> bool) -> Vec<(Value, Value)> {
        let (kept, settled): (Vec<_>, Vec<_>) =
            std::mem::take(&mut self.lost).into_iter().partition(|q| keep(q));
        self.lost = kept;
        settled.into_iter().map(|q| (q.prompt_id, q.turn_id)).collect()
    }

    /// Stops tracking the prompts `waits` accepts; they stay waiting.
    fn forget(&mut self, waits: impl Fn(&Lost) -> bool) -> Vec<(Value, Value)> {
        self.lost.retain(|q| !waits(q));
        Vec::new()
    }
}

/// Whether the record's list `key` names `prompt_id`.
fn named(msg: &Value, key: &str, prompt_id: &Value) -> bool {
    msg.get(key).and_then(Value::as_array).is_some_and(|ids| ids.contains(prompt_id))
}
