//! Packet loss from transport-wide feedback: a sent datagram counts as lost once the
//! receiver reports a datagram sent after it and never reports this one. Independent of
//! how many arrivals fit in one feedback message.

use std::collections::{HashSet, VecDeque};

#[derive(Debug, Default)]
pub struct LossMeter {
    order: VecDeque<u16>,
    arrived: HashSet<u16>,
}

impl LossMeter {
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
        let total = received + lost;
        (total > 0).then(|| f64::from(lost) / f64::from(total))
    }
}
