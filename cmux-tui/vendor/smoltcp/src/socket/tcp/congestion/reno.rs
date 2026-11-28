use crate::{socket::tcp::RttEstimator, time::Instant};

use super::Controller;

const DEFAULT_MSS: usize = 1024;

#[derive(Debug, Clone)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
pub struct Reno {
    cwnd: usize,
    mss: usize,
    ssthresh: usize,
    rwnd: usize,

    in_fast_recovery: bool,
    // Set on RTO, cleared when new data is ACKed. While set, further RTOs
    // are retransmissions of the same segment and must not reduce ssthresh
    // again (RFC 5681 section 3.1).
    in_rto_recovery: bool,
}

impl Reno {
    pub fn new() -> Self {
        Reno {
            cwnd: DEFAULT_MSS * 2,
            mss: DEFAULT_MSS,
            ssthresh: usize::MAX,
            rwnd: 64 * DEFAULT_MSS,
            in_fast_recovery: false,
            in_rto_recovery: false,
        }
    }
}

impl Controller for Reno {
    fn window(&self) -> usize {
        self.cwnd
    }

    fn on_ack(&mut self, _now: Instant, len: usize, _in_flight: usize, _rtt: &RttEstimator) {
        // RFC 5681 only acts on ACKs of new data. The socket also notifies us
        // of accepted segments that acknowledge nothing (window updates, data
        // segments from the remote): those must not exit fast recovery nor
        // grow the window.
        if len == 0 {
            return;
        }

        // New data was ACKed: a timer-based loss episode, if any, is over.
        self.in_rto_recovery = false;

        // First new-data-ack exits fast recovery and deflates `cwnd`
        if self.in_fast_recovery {
            self.in_fast_recovery = false;
            self.cwnd = self.ssthresh;
            return;
        }

        let inc = if self.cwnd < self.ssthresh {
            // Slow start: increase `cwnd` by 1 MSS per ACK.
            len.min(self.mss)
        } else {
            // Congestion avoidance: increase by ~1 MSS per RTT.
            (self.mss * self.mss / self.cwnd).max(1)
        };

        self.cwnd = self.cwnd.saturating_add(inc).min(self.rwnd).max(self.mss);
    }

    fn on_dup_ack(&mut self, _now: Instant, len: usize, _in_flight: usize) {
        if self.in_fast_recovery {
            self.cwnd = self.cwnd.saturating_add(len).min(self.rwnd).max(self.mss);
        }
    }

    fn on_loss(&mut self, _now: Instant, in_flight: usize) {
        // Only cut window size on first entrance to fast recovery.
        if !self.in_fast_recovery {
            self.ssthresh = (in_flight >> 1).max(2 * self.mss);
            self.cwnd = self.ssthresh.min(self.rwnd).saturating_add(3 * self.mss);

            self.in_fast_recovery = true;
        }
    }

    fn on_sack_loss(&mut self, now: Instant, in_flight: usize) {
        let entering = !self.in_fast_recovery;
        self.on_loss(now, in_flight);
        if entering {
            self.cwnd = self.ssthresh.min(self.rwnd).max(self.mss);
        }
    }

    fn on_rto(&mut self, _now: Instant, in_flight: usize) {
        // RFC 5681: when the retransmission timer fires for a segment that has
        // already been retransmitted by the timer (no new data was ACKed since
        // the previous RTO), ssthresh is held constant.
        if !self.in_rto_recovery {
            self.ssthresh = (in_flight >> 1).max(2 * self.mss);
            self.in_rto_recovery = true;
        }

        // cwnd collapses to the loss window (1 MSS) and we re-enter slow start.
        self.cwnd = self.mss;

        // Major loss has occurred, ensure we move from fast recovery (if in it) to slow start.
        self.in_fast_recovery = false
    }

    fn set_mss(&mut self, mss: usize) {
        self.mss = mss;
    }

    fn set_remote_window(&mut self, remote_window: usize) {
        if self.rwnd < remote_window {
            self.rwnd = remote_window;
        }
    }
}

#[cfg(test)]
#[path = "reno_test_tests.rs"]
mod test;
