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
        self.sample_started_us = None;
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
mod tests;
