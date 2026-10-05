//! Input over unreliable datagrams: the viewer repeats each event in later
//! packets until the host acknowledges it (press and motion events at most
//! [`MAX_SENDS`] times; key and button releases until acknowledged, so a lost
//! release never leaves a key held on the host); the host applies every
//! sequence number exactly once and in order. The engine checks
//! `SessionTable::may_inject_input` for every event it injects and calls
//! [`InputApplier::reset`] when control ends.

use std::collections::{BTreeMap, VecDeque};

use cmux_rd_proto::{
    HEADER_LEN, INPUT_PACKET_PREFIX_LEN, InputEvent, InputPacket, MAX_DATAGRAM_VPC,
};

/// How many packets carry one event at most.
pub const MAX_SENDS: u8 = 3;

/// Most events in one packet.
pub const MAX_EVENTS_PER_PACKET: usize = 32;

/// Largest input packet payload: a packet fits the smallest session
/// datagram (`MAX_DATAGRAM_VPC`) after the header, whatever the path.
pub const MAX_PACKET_PAYLOAD: usize = MAX_DATAGRAM_VPC - HEADER_LEN;

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
        Self::starting_at(1)
    }

    /// A sender whose first event gets sequence number `first_seq` (the
    /// host's applier must start at the same number).
    pub fn starting_at(first_seq: u32) -> Self {
        Self { next_seq: first_seq, queue: VecDeque::new(), base: first_seq }
    }

    /// Queues an event and returns its sequence number.
    pub fn push(&mut self, event: InputEvent) -> u32 {
        let seq = self.next_seq;
        self.next_seq = self.next_seq.wrapping_add(1);
        self.queue.push_back(Outgoing { event, sends: 0 });
        seq
    }

    /// True when no event waits for an acknowledgement or a resend.
    pub fn is_empty(&self) -> bool {
        self.queue.is_empty()
    }

    /// True when an event was queued but never put in a packet.
    pub fn has_unsent(&self) -> bool {
        self.queue.iter().any(|o| o.sends == 0)
    }

    /// True when the oldest unacknowledged event went out at least once: the
    /// viewer's resend timer then repeats the oldest window
    /// ([`Self::repeat_packet`]).
    pub fn oldest_was_sent(&self) -> bool {
        self.queue.front().is_some_and(|o| o.sends > 0)
    }

    /// Drops events the host applied (`applied` = newest applied sequence).
    pub fn ack(&mut self, applied: u32) {
        while self.base <= applied && !self.queue.is_empty() {
            self.queue.pop_front();
            self.base = self.base.wrapping_add(1);
        }
    }

    /// The next packet: a run of consecutive unacknowledged events of at most
    /// [`MAX_EVENTS_PER_PACKET`] events and [`MAX_PACKET_PAYLOAD`] bytes
    /// (always at least one event). The run starts at the oldest event, so
    /// older events ride along with new ones; when that run cannot reach the
    /// first never-sent event, it starts at that event instead, so new input
    /// is never held behind repeats. Events that used all sends are dropped
    /// from the front (the host skips the gap after its timeout).
    /// Pair it with [`Self::repeat_packet`] on a timer, so events behind
    /// the jump still repeat while new input keeps flowing.
    pub fn packet(&mut self) -> Option<InputPacket> {
        self.drop_exhausted();
        if self.queue.is_empty() {
            return None;
        }
        let start = match self.queue.iter().position(|o| o.sends == 0) {
            Some(unsent) if self.window_len(0) <= unsent => unsent,
            _ => 0,
        };
        Some(self.window(start))
    }

    /// The window that starts at the oldest unacknowledged event, whether or
    /// not newer events wait: the repeat the viewer's resend timer sends.
    pub fn repeat_packet(&mut self) -> Option<InputPacket> {
        self.drop_exhausted();
        if self.queue.is_empty() {
            return None;
        }
        Some(self.window(0))
    }

    fn drop_exhausted(&mut self) {
        while self.queue.front().is_some_and(|o| o.sends >= MAX_SENDS && !is_release(&o.event)) {
            self.queue.pop_front();
            self.base = self.base.wrapping_add(1);
        }
    }

    /// Takes the window at queue position `start` and counts one send for each event.
    fn window(&mut self, start: usize) -> InputPacket {
        let len = self.window_len(start);
        let first_seq = self.base.wrapping_add(start as u32);
        let events = self
            .queue
            .iter_mut()
            .skip(start)
            .take(len)
            .map(|out| {
                // A release repeats until acknowledged, so the count saturates.
                out.sends = out.sends.saturating_add(1);
                out.event.clone()
            })
            .collect();
        InputPacket { first_seq, events }
    }

    /// How many events from queue position `start` fit one packet (at least one).
    fn window_len(&self, start: usize) -> usize {
        let mut bytes = INPUT_PACKET_PREFIX_LEN;
        let mut n = 0;
        for out in self.queue.iter().skip(start).take(MAX_EVENTS_PER_PACKET) {
            let len = out.event.encoded_len();
            if n > 0 && bytes + len > MAX_PACKET_PAYLOAD {
                break;
            }
            bytes += len;
            n += 1;
        }
        n
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
        Self::starting_at(gap_timeout_us, 1)
    }

    /// An applier that expects `first_seq` first (see [`InputSender::starting_at`]).
    pub fn starting_at(gap_timeout_us: u64, first_seq: u32) -> Self {
        Self {
            next: first_seq,
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

    /// Discards a packet the session may not inject (no control): every
    /// sequence number through the packet's last counts as applied, so the
    /// host's next `InputAck` stops the viewer's repeats, and a late repeat
    /// is never injected after control is granted.
    pub fn refuse(&mut self, packet: &InputPacket) {
        let Some(n) = u32::try_from(packet.events.len()).ok().filter(|n| *n > 0) else {
            return;
        };
        let last = packet.first_seq.wrapping_add(n - 1);
        if last >= self.next {
            self.next = last.wrapping_add(1);
        }
        // Held events arrived without control too; none of them may apply.
        self.held.clear();
        self.gap_since_us = None;
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
