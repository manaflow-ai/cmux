//! Packet-weighted transport loss with bounded tolerance for reordered feedback.
//! A later receipt exposes a possible gap, but does not prove that gap is lost.
//!
//! Two readings settle from the same receipts. Path loss counts a packet the
//! viewer NACKed and the host repaired as lost, because the repair reuses its
//! transport sequence and is reported as an arrival; it is what the stats show
//! and what sizes FEC. Congestion loss counts only packets never reported:
//! a repaired random loss is not a sign of a full queue.

use std::collections::{HashMap, VecDeque};

const MAX_TRACKED: usize = 8192;
// Feedback is emitted every 50 ms. Allow that cadence plus up to 25 ms of
// packet spread on each leg before settling a gap. This is independent of
// the shorter receiver-side NACK grace: requesting repair is not proof of loss.
const REORDER_GRACE_US: u64 = 100_000;

#[derive(Debug)]
struct Sent {
    seq: u16,
    arrived: bool,
    repaired: bool,
    /// Never sent after all (`forget`): settles as neither received nor lost.
    retired: bool,
    settle_due_us: Option<u64>,
}

#[derive(Debug, Default)]
pub struct LossMeter {
    order: VecDeque<Sent>,
    ordinals: HashMap<u16, u64>,
    next_ordinal: u64,
    exposed_through: Option<u64>,
    sample_started_us: Option<u64>,
    sample_received: u64,
    sample_lost: u64,
}

impl LossMeter {
    /// A path change discards both pending old-path receipts and their sample.
    pub fn reset_congestion_window(&mut self) {
        self.order.clear();
        self.ordinals.clear();
        self.exposed_through = None;
        self.sample_started_us = None;
        self.sample_received = 0;
        self.sample_lost = 0;
    }

    pub fn on_sent(&mut self, seq: u16) {
        self.ordinals.insert(seq, self.next_ordinal);
        self.next_ordinal += 1;
        self.order.push_back(Sent {
            seq,
            arrived: false,
            repaired: false,
            retired: false,
            settle_due_us: None,
        });
        while self.order.len() > MAX_TRACKED {
            self.pop_front(); // Eviction is unknown evidence, not network loss.
        }
    }

    /// The viewer NACKed this datagram (missing past its NACK grace) and the host
    /// resent the same bytes. Unless a receipt came first, the original was lost
    /// on the path, even though the copy is reported under the same sequence.
    /// Without this a 1 % link drop that NACK repairs reads as 0 % loss.
    /// Tail probes are speculative resends and must not call this.
    pub fn on_resent(&mut self, seq: u16) {
        let first_ordinal = self.next_ordinal - self.order.len() as u64;
        let Some(&ordinal) = self.ordinals.get(&seq) else { return };
        if let Some(packet) = self.order.get_mut((ordinal - first_ordinal) as usize)
            && !packet.arrived
        {
            packet.repaired = true;
        }
    }

    /// A datagram recorded by `on_sent` was dropped before it left (a pacer
    /// queue emptied after an outage, D12): its missing receipt is not loss.
    pub fn forget(&mut self, seq: u16) {
        let first_ordinal = self.next_ordinal - self.order.len() as u64;
        let Some(ordinal) = self.ordinals.remove(&seq) else { return };
        if let Some(packet) = self.order.get_mut((ordinal - first_ordinal) as usize) {
            packet.retired = true;
        }
    }

    fn pop_front(&mut self) -> Option<Sent> {
        let ordinal = self.next_ordinal - self.order.len() as u64;
        let packet = self.order.pop_front()?;
        if self.ordinals.get(&packet.seq) == Some(&ordinal) {
            self.ordinals.remove(&packet.seq);
        }
        Some(packet)
    }

    /// Consume a packet-weighted observation window at most once per 500 ms,
    /// after at least 20 packets settle. Settlement itself happens only in
    /// `on_arrivals`, so FEC and congestion observe the same receipts; this
    /// window leaves out repaired packets (see the module comment).
    pub fn take_congestion_loss(&mut self, now_us: u64) -> Option<f64> {
        let total = self.sample_received.saturating_add(self.sample_lost);
        if total == 0 {
            return None;
        }
        let started = self.sample_started_us.get_or_insert(now_us);
        if now_us.saturating_sub(*started) < 500_000 || total < 20 {
            return None;
        }
        let loss = self.sample_lost as f64 / total as f64;
        self.sample_started_us = None;
        self.sample_received = 0;
        self.sample_lost = 0;
        Some(loss)
    }

    /// Record all known receipts before settling expired gaps. Each exposed
    /// packet gets one fixed deadline; continuing traffic cannot extend it.
    /// Empty feedback can settle old gaps but cannot expose an unseen tail.
    /// Work is amortized O(sent packets + receipts), with bounded storage.
    pub fn on_arrivals(&mut self, seqs: impl IntoIterator<Item = u16>, now_us: u64) -> Option<f64> {
        let first_ordinal = self.next_ordinal - self.order.len() as u64;
        let mut newest = self.exposed_through;
        for seq in seqs {
            let Some(&ordinal) = self.ordinals.get(&seq) else { continue };
            let Some(packet) = self.order.get_mut((ordinal - first_ordinal) as usize) else {
                continue;
            };
            packet.arrived = true;
            newest = Some(newest.map_or(ordinal, |last| last.max(ordinal)));
        }
        if let Some(newest) = newest {
            let first_unexposed =
                self.exposed_through.map_or(first_ordinal, |last| last + 1).max(first_ordinal);
            if newest >= first_unexposed {
                let offset = (first_unexposed - first_ordinal) as usize;
                let count = (newest - first_unexposed + 1) as usize;
                for packet in self.order.iter_mut().skip(offset).take(count) {
                    packet.settle_due_us = Some(now_us.saturating_add(REORDER_GRACE_US));
                }
                self.exposed_through = Some(newest);
            }
        }
        let (mut received, mut lost, mut repaired) = (0u64, 0u64, 0u64);
        while self.order.front().is_some_and(|p| p.settle_due_us.is_some_and(|due| now_us >= due)) {
            let Some(packet) = self.pop_front() else { break };
            if packet.retired {
                continue;
            }
            match (packet.arrived, packet.repaired) {
                (true, false) => received += 1,
                (true, true) => repaired += 1,
                (false, _) => lost += 1,
            }
        }
        // Congestion: a repaired packet was delivered.
        self.sample_received = self.sample_received.saturating_add(received + repaired);
        self.sample_lost = self.sample_lost.saturating_add(lost);
        // Path loss: a repaired packet was lost first.
        let path_lost = lost + repaired;
        let total = received + path_lost;
        (total > 0).then(|| path_lost as f64 / total as f64)
    }
}

#[cfg(test)]
#[path = "loss_tests.rs"]
mod tests;
