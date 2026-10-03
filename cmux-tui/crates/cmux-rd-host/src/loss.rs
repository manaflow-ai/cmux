//! Packet loss from transport-wide feedback: a sent datagram counts as lost once the
//! viewer reports a datagram sent after it and never reports this one. Independent of
//! how many arrivals fit in one feedback message.

use std::collections::{HashSet, VecDeque};

#[derive(Default)]
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
}
