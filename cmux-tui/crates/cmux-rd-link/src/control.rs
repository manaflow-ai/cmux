//! The ordered, reliable control channel inside a link: records carry a
//! sequence number; the receiver delivers them in order exactly once and
//! answers with the cumulative ack; the sender resends what is not acked.
//! Control traffic is small (hello, start, stats), so a window and a fixed
//! retransmission timer with backoff are enough.

use std::collections::{BTreeMap, VecDeque};

/// Most unacknowledged records.
const WINDOW: usize = 128;
/// First retransmission timeout, doubled per resend up to [`MAX_RTO_US`].
const RTO_US: u64 = 100_000;
const MAX_RTO_US: u64 = 2_000_000;

pub fn encode_record(seq: u32, record: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(4 + record.len());
    out.extend_from_slice(&seq.to_le_bytes());
    out.extend_from_slice(record);
    out
}

pub fn decode_record(payload: &[u8]) -> Option<(u32, &[u8])> {
    let (seq, record) = payload.split_at_checked(4)?;
    Some((u32::from_le_bytes(seq.try_into().ok()?), record))
}

struct Unacked {
    seq: u32,
    record: Vec<u8>,
    due_us: u64,
    rto_us: u64,
}

#[derive(Default)]
pub struct ControlSender {
    /// Records start at 1; ack 0 means nothing received.
    next_seq: u32,
    unacked: VecDeque<Unacked>,
}

impl ControlSender {
    /// Assigns the next sequence number; `None` when the window is full.
    pub fn push(&mut self, record: Vec<u8>, now_us: u64) -> Option<(u32, Vec<u8>)> {
        if self.unacked.len() >= WINDOW {
            return None;
        }
        self.next_seq += 1;
        let seq = self.next_seq;
        self.unacked.push_back(Unacked {
            seq,
            record: record.clone(),
            due_us: now_us + RTO_US,
            rto_us: RTO_US,
        });
        Some((seq, record))
    }

    /// Everything up to and including `seq` arrived.
    pub fn ack(&mut self, seq: u32, _now_us: u64) {
        while self.unacked.front().is_some_and(|u| u.seq <= seq) {
            self.unacked.pop_front();
        }
    }

    /// Records whose timer ran out, to send again.
    pub fn due(&mut self, now_us: u64) -> Vec<(u32, Vec<u8>)> {
        let mut out = Vec::new();
        for u in self.unacked.iter_mut().filter(|u| u.due_us <= now_us) {
            u.rto_us = (u.rto_us * 2).min(MAX_RTO_US);
            u.due_us = now_us + u.rto_us;
            out.push((u.seq, u.record.clone()));
        }
        out
    }

    pub fn next_deadline_us(&self) -> Option<u64> {
        self.unacked.iter().map(|u| u.due_us).min()
    }
}

#[derive(Default)]
pub struct ControlReceiver {
    /// The highest sequence number delivered in order.
    delivered: u32,
    /// Records that arrived ahead of a gap (bounded by the sender's window).
    ahead: BTreeMap<u32, Vec<u8>>,
}

impl ControlReceiver {
    /// Takes one record, delivers every record that is now in order, and
    /// returns the cumulative ack to send back.
    pub fn receive(&mut self, seq: u32, record: &[u8], mut deliver: impl FnMut(Vec<u8>)) -> u32 {
        if seq > self.delivered && seq <= self.delivered.saturating_add(WINDOW as u32) {
            self.ahead.entry(seq).or_insert_with(|| record.to_vec());
        }
        while let Some(record) = self.ahead.remove(&(self.delivered + 1)) {
            self.delivered += 1;
            deliver(record);
        }
        self.delivered
    }
}
