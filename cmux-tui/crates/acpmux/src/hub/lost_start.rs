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
//!
//! A prompt an inbox digest took (`dequeued` with `digestPromptId`) is no such prompt: it waits
//! until the digest's turn starts, and comes back in the digest's place if it never did
//! (`queue_waiting.rs` `Digests`).
//!
//! The prompts are indexed by prompt, turn and starting turn, so each record costs the same
//! however many of them a long log holds.

use super::queue_waiting::{Order, Waiting};
use crate::store::EventRecord;
use serde_json::Value;
use std::collections::{BTreeSet, HashMap};

/// A prompt dequeued for a turn that has not started.
struct Lost {
    prompt_id: String,
    turn_id: String,
    /// The turn whose `turn_started` starts it: its own, or the agent message turn it joined
    /// (`joinedTurnId`, `digest.rs` `take_joined`).
    starts_in: String,
}

/// The prompts dequeued for a turn that has not started, read in log order.
#[derive(Default)]
pub(super) struct Unstarted {
    /// A turn started and not settled: a prompt dequeued into it was steered in (`steer_end.rs`).
    open: bool,
    /// In the order they left the queue; `None` once settled or forgotten.
    lost: Vec<Option<Lost>>,
    by_prompt: HashMap<String, BTreeSet<usize>>,
    by_turn: HashMap<String, BTreeSet<usize>>,
    by_start: HashMap<String, BTreeSet<usize>>,
}

impl Unstarted {
    /// One record, before `restore_queue` reads it; `waiting` is what it still holds queued.
    /// Returns the `(promptId, turnId)` of the prompts the record settled: they leave the waiting
    /// list and the queue order.
    pub(super) fn read(
        &mut self,
        e: &EventRecord,
        waiting: &Waiting,
        order: &mut Order,
    ) -> Vec<(Value, Value)> {
        let turn_id = e.msg.get("turnId").and_then(Value::as_str);
        let prompt_id = e.msg.get("promptId").and_then(Value::as_str);
        match e.kind.as_str() {
            // Taken into an inbox digest (`queue_waiting.rs` `Digests` decides).
            "dequeued" if e.msg.get("digestPromptId").is_some() => Vec::new(),
            "dequeued" if !self.open => {
                if let (Some(p), Some(t)) = (prompt_id, turn_id)
                    && waiting.has_turn(e.msg.get("turnId"))
                    && !self.holds(e.msg.get("turnId"))
                {
                    let starts_in = e.msg.get("joinedTurnId").and_then(Value::as_str).unwrap_or(t);
                    self.push(Lost {
                        prompt_id: p.to_owned(),
                        turn_id: t.to_owned(),
                        starts_in: starts_in.to_owned(),
                    });
                }
                Vec::new()
            }
            // Its own turn started, or it ran under another turn id; another prompt's turn did
            // not start it.
            "turn_started" => {
                self.open = true;
                let mut slots = self.of_prompt(prompt_id);
                for index in [&self.by_start, &self.by_turn] {
                    slots.extend(turn_id.and_then(|t| index.get(t)).into_iter().flatten());
                }
                self.settle(slots)
            }
            "turn_result" => {
                self.open = false;
                self.settle(self.of_prompt(prompt_id))
            }
            // Recorded for its own turn, it still waits for `turn_started`; a steer (or a run
            // under another turn id) settled it.
            "user_message" => {
                let steer = e.msg.get("steer") == Some(&Value::Bool(true));
                let slots: Vec<usize> = (self.of_prompt(prompt_id).into_iter())
                    .filter(|&i| {
                        let q = self.lost.get(i).and_then(Option::as_ref);
                        steer || q.is_some_and(|q| Some(q.turn_id.as_str()) != turn_id)
                    })
                    .collect();
                self.settle(slots)
            }
            // Refused, withdrawn, or queued again under a new turn id.
            "prompt_refused" | "queue_removed" | "queued" => self.settle(self.of_prompt(prompt_id)),
            // A daemon that put it back moved or held it (an edit only changes its record): it
            // waits as any queued prompt since, in that place, and only what settles a queued
            // prompt settles it. A reorder places it itself; a hold keeps the place it led from.
            "queue_order" => {
                self.forget(&e.msg, "order", None);
                Vec::new()
            }
            "queue_paused" => {
                self.forget(&e.msg, "held", Some(order));
                Vec::new()
            }
            _ => Vec::new(),
        }
    }

    /// Whether the prompt of `turn_id` left the queue for a turn that has not started: its
    /// `queued` record stays waiting.
    pub(super) fn holds(&self, turn_id: Option<&Value>) -> bool {
        turn_id.and_then(Value::as_str).is_some_and(|t| self.by_turn.contains_key(t))
    }

    /// The prompt ids of the prompts that left the queue for a turn that has not started.
    pub(super) fn prompts(&self) -> impl Iterator<Item = &str> {
        self.lost.iter().flatten().map(|q| q.prompt_id.as_str())
    }

    /// These prompts go to the head of the queue's `order`, as they left it: they run first, as
    /// they would have. A reorder logged after one left does not name it. They keep that place
    /// (`key`); `order` only learns that the ones it holds now led from here.
    pub(super) fn lead(&self, order: &mut Order) {
        order.lead();
    }

    /// The sort key of the prompt `prompt_id` if it is one of these: the last lead put it ahead
    /// of every prompt placed before that lead, in the order they left the queue
    /// (`Order::lead_key`).
    pub(super) fn key(&self, prompt_id: Option<&Value>, order: &Order) -> Option<(i64, u64)> {
        let first = self.by_prompt.get(prompt_id.and_then(Value::as_str)?)?.first()?;
        Some(order.lead_key(*first as u64))
    }

    /// The slots of the prompt `prompt_id`.
    fn of_prompt(&self, prompt_id: Option<&str>) -> Vec<usize> {
        prompt_id.and_then(|p| self.by_prompt.get(p)).into_iter().flatten().copied().collect()
    }

    fn push(&mut self, q: Lost) {
        let i = self.lost.len();
        for (index, id) in [
            (&mut self.by_prompt, &q.prompt_id),
            (&mut self.by_turn, &q.turn_id),
            (&mut self.by_start, &q.starts_in),
        ] {
            index.entry(id.clone()).or_default().insert(i);
        }
        self.lost.push(Some(q));
    }

    /// Takes the prompt in slot `i` out of the list and its indexes.
    fn take(&mut self, i: usize) -> Option<Lost> {
        let q = self.lost.get_mut(i)?.take()?;
        for (index, id) in [
            (&mut self.by_prompt, &q.prompt_id),
            (&mut self.by_turn, &q.turn_id),
            (&mut self.by_start, &q.starts_in),
        ] {
            if let Some(slots) = index.get_mut(id.as_str()) {
                slots.remove(&i);
                if slots.is_empty() {
                    index.remove(id.as_str());
                }
            }
        }
        Some(q)
    }

    /// Settles the prompts in these slots; returns them.
    fn settle(&mut self, slots: Vec<usize>) -> Vec<(Value, Value)> {
        let mut settled: Vec<(usize, Lost)> =
            slots.into_iter().filter_map(|i| self.take(i).map(|q| (i, q))).collect();
        settled.sort_by_key(|(i, _)| *i);
        settled
            .into_iter()
            .map(|(_, q)| (Value::from(q.prompt_id), Value::from(q.turn_id)))
            .collect()
    }

    /// Stops tracking the prompts the record's list `key` names; they stay waiting. With `order`,
    /// each keeps the place it led from there.
    fn forget(&mut self, msg: &Value, key: &str, mut order: Option<&mut Order>) {
        let ids = msg.get(key).and_then(Value::as_array).into_iter().flatten();
        for id in ids.filter_map(Value::as_str) {
            for i in self.by_prompt.get(id).cloned().unwrap_or_default() {
                if let (Some(q), Some(order)) = (self.take(i), order.as_deref_mut()) {
                    order.keep_lead(&q.prompt_id, i as u64);
                }
            }
        }
    }
}
