//! Input over unreliable datagrams: the viewer repeats each event in later
//! packets until the host acknowledges it (press and motion events at most
//! [`MAX_SENDS`] times; key and button releases until acknowledged, so a lost
//! release never leaves a key held on the host); the host applies every
//! sequence number exactly once and in order. The engine checks
//! `SessionTable::may_inject_input` for every event it injects and calls
//! [`InputApplier::reset`] when control ends.

use std::collections::{BTreeMap, VecDeque};

use cmux_rd_proto::{InputEvent, InputPacket};

/// How many packets carry one event at most.
pub const MAX_SENDS: u8 = 3;

/// Most events in one packet.
pub const MAX_EVENTS_PER_PACKET: usize = 32;

#[derive(Debug, Clone)]
struct Outgoing {
    event: InputEvent,
    sends: u8,
}

/// Viewer side.
#[derive(Debug, Default)]
pub struct InputSender {
    next_seq: u32,
    /// Unacknowledged events, oldest first; the first has sequence `base`.
    queue: VecDeque<Outgoing>,
    base: u32,
}

impl InputSender {
    pub fn new() -> Self {
        Self { next_seq: 1, queue: VecDeque::new(), base: 1 }
    }

    /// Queues an event and returns its sequence number.
    pub fn push(&mut self, event: InputEvent) -> u32 {
        let seq = self.next_seq;
        self.next_seq = self.next_seq.wrapping_add(1);
        self.queue.push_back(Outgoing { event, sends: 0 });
        seq
    }

    /// Drops events the host applied (`applied` = newest applied sequence).
    pub fn ack(&mut self, applied: u32) {
        while self.base <= applied && !self.queue.is_empty() {
            self.queue.pop_front();
            self.base = self.base.wrapping_add(1);
        }
    }

    /// The next packet: the run of unacknowledged events that still have sends
    /// left, starting at the oldest such event. Events that used all sends are
    /// dropped from the front (the host skips the gap after its timeout).
    pub fn packet(&mut self) -> Option<InputPacket> {
        while self.queue.front().is_some_and(|o| o.sends >= MAX_SENDS && !is_release(&o.event)) {
            self.queue.pop_front();
            self.base = self.base.wrapping_add(1);
        }
        if self.queue.is_empty() {
            return None;
        }
        let first_seq = self.base;
        let mut events = Vec::new();
        for out in self.queue.iter_mut().take(MAX_EVENTS_PER_PACKET) {
            out.sends += 1;
            events.push(out.event.clone());
        }
        Some(InputPacket { first_seq, events })
    }
}

fn is_release(event: &InputEvent) -> bool {
    matches!(event, InputEvent::Key { down: false, .. } | InputEvent::Button { down: false, .. })
}

/// Host side: in-order, exactly-once application.
#[derive(Debug)]
pub struct InputApplier {
    next: u32,
    held: BTreeMap<u32, InputEvent>,
    gap_since_us: Option<u64>,
    gap_timeout_us: u64,
    max_held: usize,
    skipped_gap: bool,
}

impl InputApplier {
    /// `gap_timeout_us`: how long a missing event may block later ones.
    pub fn new(gap_timeout_us: u64) -> Self {
        Self {
            next: 1,
            held: BTreeMap::new(),
            gap_since_us: None,
            gap_timeout_us,
            max_held: 1024,
            skipped_gap: false,
        }
    }

    /// Newest applied sequence number (the `InputAck` value).
    pub fn applied(&self) -> u32 {
        self.next.wrapping_sub(1)
    }

    /// True once after the applier skipped a missing event: the engine then
    /// releases every key and button it holds down on the host.
    pub fn take_skipped_gap(&mut self) -> bool {
        std::mem::take(&mut self.skipped_gap)
    }

    /// Drops held events (control ended or the session stopped); later
    /// sequence numbers continue from the next expected one.
    pub fn reset(&mut self) {
        self.held.clear();
        self.gap_since_us = None;
    }

    /// Accepts a packet and returns the events to inject now, in order.
    pub fn accept(&mut self, packet: &InputPacket, now_us: u64) -> Vec<InputEvent> {
        for (i, event) in packet.events.iter().enumerate() {
            let seq = packet.first_seq.wrapping_add(i as u32);
            if seq >= self.next && self.held.len() < self.max_held {
                self.held.entry(seq).or_insert_with(|| event.clone());
            }
        }
        self.drain(now_us)
    }

    /// Advances time; after the gap timeout, skips a missing event.
    pub fn tick(&mut self, now_us: u64) -> Vec<InputEvent> {
        self.drain(now_us)
    }

    fn drain(&mut self, now_us: u64) -> Vec<InputEvent> {
        let mut out = Vec::new();
        loop {
            if let Some(event) = self.held.remove(&self.next) {
                out.push(event);
                self.next = self.next.wrapping_add(1);
                self.gap_since_us = None;
                continue;
            }
            let Some((&first_held, _)) = self.held.iter().next() else {
                self.gap_since_us = None;
                break;
            };
            let since = *self.gap_since_us.get_or_insert(now_us);
            if now_us.saturating_sub(since) >= self.gap_timeout_us {
                self.next = first_held;
                self.gap_since_us = None;
                self.skipped_gap = true;
                continue;
            }
            break;
        }
        out
    }
}
