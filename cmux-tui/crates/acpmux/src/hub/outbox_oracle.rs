//! A naive model of the outbox (`hub/outbox.rs`): what a correct outbox answers and holds after
//! any sequence of operations, written so it is obviously right rather than fast.
//!
//! It is two in-order lists of messages, oldest first: `memory` (what the running daemon holds)
//! and `durable` (what a restart reads back). Every rule of the real outbox is one line here:
//!
//! - A message is keyed by (prompt id, target). Sending the same key again answers with the first
//!   message, whatever its state; the same prompt id to another target is its own message.
//! - A new message is answered as kept only once it is on disk. When the disk refuses the write,
//!   the sender gets an error and the message is in neither list.
//! - A change to a message (an attempt, an ack, a failure, a hold) is in memory at once. It is
//!   durable when the disk takes the write; when the disk refuses it, it waits in memory, and the
//!   next write that succeeds makes the whole of memory durable.
//! - A repeat of a message whose first write has not reached the disk yet is answered only once
//!   it has; with the disk still refusing, it is an error.
//! - A crash (any restart) leaves exactly `durable`: torn appends and journals left beside a newer
//!   snapshot change nothing. A clean shutdown on a working disk first makes memory durable.
//! - Waiting (unsettled) messages are `Queued` or `Delivering`; `Delivered`, `Held` and `Failed`
//!   are settled. The waiting list is in send order; the listing shows waiting ones first, then
//!   settled ones, each newest first.
//!
//! API: [`OutboxOracle::new`], [`OutboxOracle::set_disk`], [`OutboxOracle::enqueue`],
//! [`OutboxOracle::update`], [`OutboxOracle::restart`], [`OutboxOracle::shutdown`], and the
//! observations [`OutboxOracle::memory`], [`OutboxOracle::durable`], [`OutboxOracle::pending`],
//! [`OutboxOracle::listed`]. It has no I/O and no dependency on the real outbox but its `State`
//! enum, so a test (or a search over random operations) runs both and compares after each step;
//! `hub/outbox_model_tests.rs` does.

use super::outbox::State;

/// One message, as the oracle knows it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Entry {
    pub id: String,
    pub prompt_id: String,
    pub target: String,
    pub state: State,
    pub attempts: u32,
}

impl Entry {
    pub fn settled(&self) -> bool {
        matches!(self.state, State::Delivered | State::Held | State::Failed)
    }
}

/// What the outbox answers a send with.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Enqueued {
    /// A new message, kept on disk.
    New(String),
    /// The first message of the same prompt id to the same target.
    Existing(String),
    /// The disk refused the write: nothing was kept.
    Refused,
}

#[derive(Clone, Debug)]
pub struct OutboxOracle {
    memory: Vec<Entry>,
    durable: Vec<Entry>,
    /// A change since the last write that succeeded.
    unsaved: bool,
    disk_ok: bool,
}

impl Default for OutboxOracle {
    fn default() -> Self {
        Self::new()
    }
}

impl OutboxOracle {
    pub fn new() -> Self {
        Self { memory: Vec::new(), durable: Vec::new(), unsaved: false, disk_ok: true }
    }

    /// Whether the disk takes writes from now on.
    pub fn set_disk(&mut self, ok: bool) {
        self.disk_ok = ok;
    }

    pub fn disk_ok(&self) -> bool {
        self.disk_ok
    }

    /// One write: everything in memory, or nothing.
    fn write(&mut self) -> bool {
        if self.disk_ok {
            self.durable = self.memory.clone();
            self.unsaved = false;
        } else {
            self.unsaved = true;
        }
        self.disk_ok
    }

    /// A send of `prompt_id` to `target`, which becomes message `id` when it is new.
    pub fn enqueue(&mut self, id: &str, prompt_id: &str, target: &str) -> Enqueued {
        if let Some(first) =
            self.memory.iter().find(|e| e.prompt_id == prompt_id && e.target == target)
        {
            let first = first.id.clone();
            // Answered only once the first is on disk.
            return if !self.unsaved || self.write() {
                Enqueued::Existing(first)
            } else {
                Enqueued::Refused
            };
        }
        self.memory.push(Entry {
            id: id.to_owned(),
            prompt_id: prompt_id.to_owned(),
            target: target.to_owned(),
            state: State::Queued,
            attempts: 0,
        });
        if self.write() {
            Enqueued::New(id.to_owned())
        } else {
            // Not kept means not sent.
            self.memory.pop();
            Enqueued::Refused
        }
    }

    /// Changes message `id` with `f`; answers whether the change is on disk (true when there is
    /// no such message).
    pub fn update(&mut self, id: &str, f: impl FnOnce(&mut Entry)) -> bool {
        let Some(entry) = self.memory.iter_mut().find(|e| e.id == id) else { return true };
        f(entry);
        self.write()
    }

    /// A crash and a start: what is durable is what there is. The disk works again.
    pub fn restart(&mut self) {
        self.disk_ok = true;
        self.memory = self.durable.clone();
        self.unsaved = false;
    }

    /// A clean shutdown on a working disk, then a start: memory is written first.
    pub fn shutdown(&mut self) {
        self.disk_ok = true;
        self.write();
        self.restart();
    }

    /// Every message the running outbox holds, in send order.
    pub fn memory(&self) -> &[Entry] {
        &self.memory
    }

    /// Every message a restart would read back, in send order.
    pub fn durable(&self) -> &[Entry] {
        &self.durable
    }

    /// The messages still to deliver, in send order (what a restart resumes, from `durable`).
    pub fn pending(entries: &[Entry]) -> Vec<&Entry> {
        entries.iter().filter(|e| !e.settled()).collect()
    }

    /// The listing (`Outbox::list`): waiting first, then settled, each newest first.
    pub fn listed(&self) -> Vec<&Entry> {
        let waiting = self.memory.iter().rev().filter(|e| !e.settled());
        waiting.chain(self.memory.iter().rev().filter(|e| e.settled())).collect()
    }
}
