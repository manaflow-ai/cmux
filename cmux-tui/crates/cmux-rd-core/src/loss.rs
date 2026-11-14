//! Packet loss from transport-wide feedback: a sent datagram counts as lost once the
//! receiver reports a datagram sent after it and never reports this one. Independent of
//! how many arrivals fit in one feedback message.

use std::collections::{HashSet, VecDeque};

#[derive(Debug, Default)]
pub struct LossMeter {
    order: VecDeque<u16>,
    arrived: HashSet<u16>,
    sample_started_us: Option<u64>,
    sample_received: u64,
    sample_lost: u64,
}

impl LossMeter {
    pub fn reset_congestion_window(&mut self) {
        self.sample_started_us = None;
        self.sample_received = 0;
        self.sample_lost = 0;
    }

    pub fn on_sent(&mut self, seq: u16) {
        // A reused sequence number (after the u16 wrap) starts unreported.
        self.arrived.remove(&seq);
        self.order.push_back(seq);
        while self.order.len() > 8192 {
            if let Some(old) = self.order.pop_front() {
                self.arrived.remove(&old);
            }
        }
    }

    /// Congestion needs a packet-weighted observation window. One lost shard in
    /// a tiny feedback tail is not a persistently lossy path. Keep immediate
    /// observations for FEC, but reduce capacity at most once per 500 ms and
    /// only after at least 20 packets have settled. An empty receipt cannot
    /// apply an earlier loss sample again. The caller supplies monotonic time.
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
        self.sample_started_us = Some(now_us);
        self.sample_received = 0;
        self.sample_lost = 0;
        Some(loss)
    }

    /// Records arrivals; returns the loss fraction among datagrams this feedback settled
    /// (`None` when it settled none).
    pub fn on_arrivals(&mut self, seqs: impl IntoIterator<Item = u16>) -> Option<f64> {
        let mut any = false;
        for s in seqs {
            any = true;
            self.arrived.insert(s);
        }
        if !any {
            return None;
        }
        let last = self.order.iter().rposition(|s| self.arrived.contains(s))?;
        let (mut received, mut lost) = (0u32, 0u32);
        for _ in 0..=last {
            let Some(seq) = self.order.pop_front() else { break };
            if self.arrived.remove(&seq) {
                received += 1;
            } else {
                lost += 1;
            }
        }
        self.sample_received = self.sample_received.saturating_add(u64::from(received));
        self.sample_lost = self.sample_lost.saturating_add(u64::from(lost));
        let total = received + lost;
        (total > 0).then(|| f64::from(lost) / f64::from(total))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn counts_gaps_before_the_newest_arrival_only() {
        let mut m = LossMeter::default();
        for s in 0..10 {
            m.on_sent(s);
        }
        // 0..=4 settled, 2 missing; 5..=9 still in flight.
        assert_eq!(m.on_arrivals([0, 1, 3, 4]), Some(0.2));
        assert_eq!(m.on_arrivals([5, 6, 7, 8, 9]), Some(0.0));
        assert_eq!(m.on_arrivals([]), None);
    }

    #[test]
    fn feedback_split_over_several_messages_is_not_loss() {
        let mut m = LossMeter::default();
        for s in 0..300u16 {
            m.on_sent(s);
        }
        assert_eq!(m.on_arrivals(0..128), Some(0.0));
        assert_eq!(m.on_arrivals(128..256), Some(0.0));
        assert_eq!(m.on_arrivals(256..300), Some(0.0));
    }

    #[test]
    fn wraps_around_u16() {
        let mut m = LossMeter::default();
        for s in [65534u16, 65535, 0, 1] {
            m.on_sent(s);
        }
        assert_eq!(m.on_arrivals([65534, 0, 1]), Some(0.25));
    }

    #[test]
    fn congestion_loss_weights_packets_and_consumes_each_window_once() {
        let mut m = LossMeter::default();
        for seq in 0..100 {
            m.on_sent(seq);
        }
        assert_eq!(m.on_arrivals([0, 1, 3]), Some(0.25));
        assert_eq!(m.take_congestion_loss(50_000), None);
        m.on_arrivals((4..100).filter(|&s| s != 50));
        assert_eq!(m.take_congestion_loss(549_999), None);
        assert_eq!(m.take_congestion_loss(550_000), Some(0.02));
        assert_eq!(m.take_congestion_loss(1_050_000), None);
    }

    #[test]
    fn traffic_after_idle_gets_a_fresh_observation_window() {
        let mut m = LossMeter::default();
        for seq in 0..20 {
            m.on_sent(seq);
        }
        m.on_arrivals(0..20);
        assert_eq!(m.take_congestion_loss(0), None);
        assert_eq!(m.take_congestion_loss(500_000), Some(0.0));

        for seq in 20..220 {
            m.on_sent(seq);
        }
        m.on_arrivals((20..40).filter(|s| ![22, 25, 28].contains(s)));
        assert_eq!(m.take_congestion_loss(1_500_000), None);
        m.on_arrivals(40..220);
        assert_eq!(m.take_congestion_loss(1_999_999), None);
        assert_eq!(m.take_congestion_loss(2_000_000), Some(0.015));
    }

    #[test]
    fn heavy_loss_is_reported_after_a_bounded_observation_window() {
        let mut m = LossMeter::default();
        for seq in 0..100 {
            m.on_sent(seq);
        }
        m.on_arrivals(50..100);
        assert_eq!(m.take_congestion_loss(0), None);
        assert_eq!(m.take_congestion_loss(500_000), Some(0.5));
        assert_eq!(m.take_congestion_loss(500_001), None);
    }

    #[test]
    fn sparse_feedback_waits_for_enough_packets_and_path_change_discards_old_sample() {
        let mut m = LossMeter::default();
        for seq in 0..4 {
            m.on_sent(seq);
        }
        m.on_arrivals([0, 1, 3]);
        assert_eq!(m.take_congestion_loss(0), None);
        assert_eq!(m.take_congestion_loss(500_000), None);
        m.reset_congestion_window();
        for seq in 4..24 {
            m.on_sent(seq);
        }
        m.on_arrivals(4..24);
        assert_eq!(m.take_congestion_loss(600_000), None);
        assert_eq!(m.take_congestion_loss(1_100_000), Some(0.0));
    }
}
