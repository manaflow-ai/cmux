//! Part of the queue restore (`queue.rs` `restore_queue`): the `queued` records still waiting,
//! and the queue order, indexed so each record of a long log costs the same however many
//! prompts it ran or queued. Scanning the waiting list per record and keeping every prompt that
//! ever left the queue in the order list made a restore quadratic in the log.

use crate::store::EventRecord;
use serde_json::Value;
use std::collections::HashMap;

/// The `queued` records waiting, in log order, found by turn id and by prompt id. A record
/// without a string `promptId` and `turnId` never runs (`restore_queue`), so it is not kept.
#[derive(Default)]
pub(super) struct Waiting {
    /// Every record kept, in log order; `None` once it left.
    slots: Vec<Option<EventRecord>>,
    by_turn: HashMap<String, Vec<usize>>,
    by_prompt: HashMap<String, Vec<usize>>,
}

impl Waiting {
    pub(super) fn push(&mut self, e: EventRecord) {
        let ids = (str_field(&e, "turnId"), str_field(&e, "promptId"));
        let (Some(turn), Some(prompt)) = (ids.0.map(str::to_owned), ids.1.map(str::to_owned))
        else {
            return;
        };
        let i = self.slots.len();
        self.slots.push(Some(e));
        self.by_turn.entry(turn).or_default().push(i);
        self.by_prompt.entry(prompt).or_default().push(i);
    }

    /// Whether a record of the turn `turn_id` waits.
    pub(super) fn has_turn(&self, turn_id: Option<&Value>) -> bool {
        turn_id.and_then(Value::as_str).is_some_and(|t| self.by_turn.contains_key(t))
    }

    /// The first waiting record of the turn `turn_id`.
    pub(super) fn first_of_turn(&mut self, turn_id: Option<&Value>) -> Option<&mut EventRecord> {
        let i = *self.by_turn.get(turn_id.and_then(Value::as_str)?)?.first()?;
        self.slots[i].as_mut()
    }

    /// Takes the records of the turn `turn_id` out.
    pub(super) fn remove_turn(&mut self, turn_id: Option<&Value>) {
        let Some(turn) = turn_id.and_then(Value::as_str) else { return };
        for i in self.by_turn.get(turn).cloned().unwrap_or_default() {
            self.take(i);
        }
    }

    /// Takes out the records of the prompt `prompt_id` under any turn but `turn_id`.
    pub(super) fn remove_other_turns(&mut self, prompt_id: &Value, turn_id: Option<&Value>) {
        let Some(slots) = prompt_id.as_str().and_then(|p| self.by_prompt.get(p)) else { return };
        let other: Vec<usize> = slots
            .iter()
            .copied()
            .filter(|&i| self.slots[i].as_ref().is_some_and(|q| q.msg.get("turnId") != turn_id))
            .collect();
        for i in other {
            self.take(i);
        }
    }

    /// The records still waiting, in log order.
    pub(super) fn into_records(self) -> Vec<EventRecord> {
        self.slots.into_iter().flatten().collect()
    }

    fn take(&mut self, i: usize) {
        let Some(e) = self.slots.get_mut(i).and_then(Option::take) else { return };
        for (key, index) in [("turnId", &mut self.by_turn), ("promptId", &mut self.by_prompt)] {
            if let Some(id) = str_field(&e, key)
                && let Some(slots) = index.get_mut(id)
            {
                slots.retain(|&j| j != i);
                if slots.is_empty() {
                    index.remove(id);
                }
            }
        }
    }
}

/// The queue order: each prompt's place, from the last reorder and the prompts that led ahead
/// of it since (`lost_start.rs`). A prompt with no place goes after every placed one.
#[derive(Default)]
pub(super) struct Order {
    place: HashMap<String, (i64, u64)>,
    /// How many times the prompts that left the queue for a turn that has not started went to
    /// its head (`lead`).
    leads: i64,
    /// Restart continuations are restored ahead of every ordinary prompt, in log order.
    restart_priority: u64,
}

impl Order {
    /// A reorder (`queue_order`): these prompts, in this order.
    pub(super) fn set<'a>(&mut self, ids: impl Iterator<Item = &'a Value>) {
        self.place.clear();
        for (i, id) in ids.enumerate() {
            if let Some(id) = id.as_str() {
                self.place.entry(id.to_owned()).or_insert((i as i64, 0));
            }
        }
    }

    /// The prompts that left the queue for a turn that has not started went to its head, ahead
    /// of every placed prompt (`lost_start.rs` `key` keeps them there).
    pub(super) fn lead(&mut self) {
        self.leads += 1;
    }

    /// The prompt `prompt_id`, the `slot`-th to leave the queue for a turn that has not started,
    /// stays where the last lead put it: behind the ones that still lead, ahead of every prompt
    /// placed before that lead, in the order they left the queue.
    pub(super) fn keep_lead(&mut self, prompt_id: &str, slot: u64) {
        self.place.insert(prompt_id.to_owned(), self.lead_key(slot));
    }

    /// Where the last lead put the `slot`-th prompt to leave the queue for a turn that has not
    /// started: a later lead goes ahead of it, a reorder before it goes behind it.
    pub(super) fn lead_key(&self, slot: u64) -> (i64, u64) {
        (-self.leads, slot)
    }

    /// A prompt that left the queue for good: a copy queued again goes where its own records say.
    pub(super) fn remove(&mut self, prompt_id: &Value) {
        if let Some(id) = prompt_id.as_str() {
            self.place.remove(id);
        }
    }

    /// Places a daemon-restart continuation ahead of every ordinary prompt while preserving the
    /// order of multiple continuation records in the same log.
    pub(super) fn prioritize_restart(&mut self, prompt_id: &Value) {
        let Some(id) = prompt_id.as_str() else { return };
        let priority = self.restart_priority;
        self.restart_priority = self.restart_priority.saturating_add(1);
        self.place.insert(id.to_owned(), (i64::MIN, priority));
    }

    /// The sort key of the prompt `prompt_id`.
    pub(super) fn key(&self, prompt_id: Option<&Value>) -> (i64, u64) {
        prompt_id
            .and_then(Value::as_str)
            .and_then(|id| self.place.get(id))
            .copied()
            .unwrap_or((i64::MAX, 0))
    }
}

fn str_field<'a>(e: &'a EventRecord, key: &str) -> Option<&'a str> {
    e.msg.get(key).and_then(Value::as_str)
}
