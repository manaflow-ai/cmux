//! Packet-weighted transport loss with bounded tolerance for reordered feedback.
//! A later receipt exposes a possible gap, but does not prove that gap is lost.

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
        self.order.push_back(Sent { seq, arrived: false, settle_due_us: None });
        while self.order.len() > MAX_TRACKED {
            self.pop_front(); // Eviction is unknown evidence, not network loss.
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
    /// `on_arrivals`, so FEC and congestion observe the same loss evidence.
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
        let (mut received, mut lost) = (0u64, 0u64);
        while self.order.front().is_some_and(|p| p.settle_due_us.is_some_and(|due| now_us >= due)) {
            let Some(packet) = self.pop_front() else { break };
            if packet.arrived {
                received += 1;
            } else {
                lost += 1;
            }
        }
        self.sample_received = self.sample_received.saturating_add(received);
        self.sample_lost = self.sample_lost.saturating_add(lost);
        let total = received + lost;
        (total > 0).then(|| lost as f64 / total as f64)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sent(count: u16) -> LossMeter {
        let mut meter = LossMeter::default();
        for seq in 0..count {
            meter.on_sent(seq);
        }
        meter
    }

    #[test]
    fn counts_gaps_before_the_newest_arrival_only() {
        let mut m = sent(10);
        assert_eq!(m.on_arrivals([0, 1, 3, 4], 0), None);
        assert_eq!(m.on_arrivals([], REORDER_GRACE_US), Some(0.2));
        assert_eq!(m.on_arrivals(5..10, REORDER_GRACE_US), None);
        assert_eq!(m.on_arrivals([], 2 * REORDER_GRACE_US), Some(0.0));
        assert_eq!(m.on_arrivals([], 3 * REORDER_GRACE_US), None);
    }

    #[test]
    fn reversed_feedback_chunks_do_not_invent_loss() {
        let mut m = sent(300);
        assert_eq!(m.on_arrivals(256..300, 0), None);
        assert_eq!(m.on_arrivals(128..256, 25_000), None);
        assert_eq!(m.on_arrivals(0..128, 75_000), None);
        assert_eq!(m.on_arrivals([], REORDER_GRACE_US - 1), None);
        assert_eq!(m.on_arrivals([], REORDER_GRACE_US), Some(0.0));
    }

    #[test]
    fn arrival_in_the_deadline_call_is_recorded_before_settlement() {
        let mut m = sent(4);
        assert_eq!(m.on_arrivals([0, 2, 3], 0), None);
        assert_eq!(m.on_arrivals([1], REORDER_GRACE_US), Some(0.0));
    }

    #[test]
    fn continuous_feedback_does_not_postpone_genuine_loss() {
        let mut m = sent(20);
        assert_eq!(m.on_arrivals([1], 0), None);
        for seq in 2..12 {
            let result = m.on_arrivals([seq], u64::from(seq - 1) * 10_000);
            if seq < 11 {
                assert_eq!(result, None);
            } else if seq == 11 {
                assert_eq!(result, Some(0.5), "the first gap settles after 100 ms");
            }
        }
    }

    #[test]
    fn unknown_and_duplicate_receipts_do_not_expose_or_delay_gaps() {
        let mut m = sent(4);
        assert_eq!(m.on_arrivals([900, 901], 0), None);
        assert_eq!(m.on_arrivals([], REORDER_GRACE_US), None);
        assert_eq!(m.on_arrivals([1, 1, 901], 200_000), None);
        assert_eq!(m.on_arrivals([1, 902], 250_000), None);
        assert_eq!(m.on_arrivals([1, 902], 300_000), Some(0.5));
        assert_eq!(m.on_arrivals([1, 902], 400_000), None);
    }

    #[test]
    fn reordered_receipts_wrap_around_u16() {
        let mut m = LossMeter::default();
        for seq in [65534, 65535, 0, 1] {
            m.on_sent(seq);
        }
        assert_eq!(m.on_arrivals([0, 1], 0), None);
        assert_eq!(m.on_arrivals([65534, 65535], 50_000), None);
        assert_eq!(m.on_arrivals([], REORDER_GRACE_US), Some(0.0));
    }

    #[test]
    fn eviction_does_not_shift_deadlines_onto_unexposed_packets() {
        let mut m = sent(MAX_TRACKED as u16);
        assert_eq!(m.on_arrivals(0..100, 0), None);
        for seq in MAX_TRACKED as u16..MAX_TRACKED as u16 + 200 {
            m.on_sent(seq);
        }
        assert_eq!(m.on_arrivals([], REORDER_GRACE_US), None);
        assert_eq!(m.on_arrivals(200..MAX_TRACKED as u16 + 200, 200_000), None);
        assert_eq!(m.on_arrivals([], 300_000), Some(0.0));
        assert!(m.order.is_empty());
        assert!(m.ordinals.is_empty());
    }

    #[test]
    fn path_reset_discards_unsettled_old_path_feedback() {
        let mut m = sent(100);
        m.on_arrivals(50..100, 0);
        m.reset_congestion_window();
        for seq in 100..120 {
            m.on_sent(seq);
        }
        assert_eq!(m.on_arrivals(0..120, 200_000), None);
        assert_eq!(m.on_arrivals([], 300_000), Some(0.0));
        assert_eq!(m.take_congestion_loss(300_000), None);
        assert_eq!(m.take_congestion_loss(800_000), Some(0.0));
    }

    #[test]
    fn congestion_weights_packets_and_consumes_each_window_once() {
        let mut m = sent(100);
        m.on_arrivals([0, 1, 3], 0);
        m.on_arrivals((4..100).filter(|&s| s != 50), 50_000);
        assert_eq!(m.on_arrivals([], 100_000), Some(0.25));
        assert_eq!(m.take_congestion_loss(100_000), None);
        m.on_arrivals([], 150_000);
        assert_eq!(m.take_congestion_loss(599_999), None);
        assert_eq!(m.take_congestion_loss(600_000), Some(0.02));
        assert_eq!(m.take_congestion_loss(1_100_000), None);
    }

    #[test]
    fn genuine_heavy_loss_still_reaches_congestion() {
        let mut m = sent(100);
        m.on_arrivals(20..100, 0);
        assert_eq!(m.on_arrivals([], REORDER_GRACE_US), Some(0.2));
        assert_eq!(m.take_congestion_loss(REORDER_GRACE_US), None);
        assert_eq!(m.take_congestion_loss(REORDER_GRACE_US + 500_000), Some(0.2));
    }

    #[test]
    fn traffic_after_idle_gets_a_fresh_observation_window() {
        let mut m = sent(20);
        m.on_arrivals(0..20, 0);
        m.on_arrivals([], 100_000);
        assert_eq!(m.take_congestion_loss(100_000), None);
        assert_eq!(m.take_congestion_loss(600_000), Some(0.0));
        for seq in 20..220 {
            m.on_sent(seq);
        }
        m.on_arrivals((20..40).filter(|s| ![22, 25, 28].contains(s)), 1_500_000);
        m.on_arrivals(40..220, 1_550_000);
        m.on_arrivals([], 1_600_000);
        assert_eq!(m.take_congestion_loss(1_600_000), None);
        m.on_arrivals([], 1_650_000);
        assert_eq!(m.take_congestion_loss(2_099_999), None);
        assert_eq!(m.take_congestion_loss(2_100_000), Some(0.015));
    }
}
