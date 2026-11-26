//! `conversation-inbox-op` once per `op_id` (`conversation-inbox-op-once-v1`). A phone resends
//! a pin or a mark-unread when its reply is lost. The state is absolute, but each resend still
//! wrote the row and published `conversation-inbox-changed` to every connection of the
//! participant, and a late resend of a pin after the person unpinned pinned it again. With an
//! `op_id`, a repeat answers the first result and writes nothing.
//!
//! A bounded LRU of the most recent [`INBOX_OP_ONCE_MOST`] ids, per participant. Only a success
//! is kept. The same id with another op is refused. No `op_id` runs as before (memory only).

use std::collections::{HashMap, VecDeque};

use serde_json::Value;

/// The capability of an owner that takes `op_id` on `conversation-inbox-op`.
pub const CAPABILITY: &str = "conversation-inbox-op-once-v1";

/// The recent ids kept, across every participant.
pub(crate) const INBOX_OP_ONCE_MOST: usize = 1024;

/// The longest `op_id` read.
pub(crate) const OP_ID_MOST: usize = 128;

/// The recent ops: each id's op (its conversation and `op`) and first result.
#[derive(Default)]
pub(crate) struct InboxOpsOnce {
    slots: HashMap<String, (u64, String, Value)>,
    /// Touches oldest first; one that is not its id's latest is stale and skipped.
    order: VecDeque<(u64, String)>,
    touch: u64,
    #[cfg(test)]
    pub(crate) repeats: u64,
}

/// What [`InboxOpsOnce::seen`] found for an id.
pub(crate) enum Seen {
    New,
    Repeat(Value),
    Reused,
}

impl InboxOpsOnce {
    /// The id's first result, if `op` is the op it ran.
    pub(crate) fn seen(&mut self, key: &str, op: &str) -> Seen {
        self.touch += 1;
        let touch = self.touch;
        let Some((at, first, result)) = self.slots.get_mut(key) else { return Seen::New };
        if first != op {
            return Seen::Reused;
        }
        *at = touch;
        let result = result.clone();
        self.order.push_back((touch, key.to_owned()));
        self.compact();
        #[cfg(test)]
        {
            self.repeats += 1;
        }
        Seen::Repeat(result)
    }

    /// Keep `result` as the id's first.
    pub(crate) fn keep(&mut self, key: String, op: String, result: Value) {
        self.touch += 1;
        let touch = self.touch;
        self.slots.insert(key.clone(), (touch, op, result));
        self.order.push_back((touch, key));
        while self.slots.len() > INBOX_OP_ONCE_MOST {
            let Some((at, key)) = self.order.pop_front() else { break };
            if self.slots.get(&key).is_some_and(|(latest, ..)| *latest == at) {
                self.slots.remove(&key);
            }
        }
        self.compact();
    }

    fn compact(&mut self) {
        if self.order.len() > INBOX_OP_ONCE_MOST * 4 {
            let slots = &self.slots;
            self.order.retain(|(at, key)| slots.get(key).is_some_and(|(latest, ..)| latest == at));
        }
    }

    #[cfg(test)]
    pub(crate) fn len(&self) -> (usize, usize) {
        (self.slots.len(), self.order.len())
    }
}
