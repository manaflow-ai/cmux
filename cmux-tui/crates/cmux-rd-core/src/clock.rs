//! The viewer's session clock estimator (rd change C8). NTP style: a ping
//! leaves at viewer time `t0`, the host stamps receive `t1` and send `t2`,
//! the pong arrives at `t3`; `rtt = (t3 - t0) - (t2 - t1)` and
//! `offset = ((t1 - t0) + (t2 - t3)) / 2` (host = viewer + offset). The
//! sample with the smallest RTT of the last [`WINDOW`] wins, because queueing
//! only adds delay and skews the offset. Pings come in a short burst so an
//! estimate exists within ~150 ms, then once a second. No I/O, no clock.

use std::collections::VecDeque;

use cmux_rd_proto::{ClockEstimate, ClockPing, ClockPong};

/// Pings sent [`BURST_INTERVAL_US`] apart when the session starts.
pub const PING_BURST: u32 = 4;
pub const BURST_INTERVAL_US: u64 = 50_000;
/// The interval after the burst.
pub const PING_INTERVAL_US: u64 = 1_000_000;
/// Samples kept for the minimum-RTT choice.
pub const WINDOW: usize = 8;
/// Pings waiting for an answer; older ones count as lost.
const MAX_OUTSTANDING: usize = 8;

#[derive(Debug, Default)]
pub struct ClockEstimator {
    next_seq: u32,
    sent: u32,
    next_ping_us: u64,
    outstanding: VecDeque<(u32, u64)>,
    samples: VecDeque<ClockEstimate>,
}

impl ClockEstimator {
    pub fn new() -> Self {
        Self::default()
    }

    /// The ping due at `now_us`, carrying the current estimate, or `None`
    /// before [`Self::next_ping_us`].
    pub fn ping(&mut self, now_us: u64) -> Option<ClockPing> {
        if now_us < self.next_ping_us {
            return None;
        }
        let seq = self.next_seq;
        self.next_seq = self.next_seq.wrapping_add(1);
        self.sent = self.sent.saturating_add(1);
        let interval = if self.sent < PING_BURST { BURST_INTERVAL_US } else { PING_INTERVAL_US };
        self.next_ping_us = now_us.saturating_add(interval);
        if self.outstanding.len() >= MAX_OUTSTANDING {
            self.outstanding.pop_front();
        }
        self.outstanding.push_back((seq, now_us));
        Some(ClockPing { seq, t_viewer_us: now_us, estimate: self.estimate() })
    }

    /// When the next ping is due.
    pub fn next_ping_us(&self) -> u64 {
        self.next_ping_us
    }

    /// Takes one answer received at `now_us`. False (and no change) for a
    /// pong whose ping is unknown, answered already, or inconsistent.
    pub fn on_pong(&mut self, pong: &ClockPong, now_us: u64) -> bool {
        let Some(i) = self
            .outstanding
            .iter()
            .position(|(seq, t0)| *seq == pong.seq && *t0 == pong.t_viewer_us)
        else {
            return false;
        };
        let (_, t0) = self.outstanding.remove(i).unwrap_or((0, 0));
        let (t0, t1, t2, t3) = (
            i128::from(t0),
            i128::from(pong.t_host_rx_us),
            i128::from(pong.t_host_tx_us),
            i128::from(now_us),
        );
        let rtt = (t3 - t0) - (t2 - t1);
        if t2 < t1 || t3 < t0 || rtt < 0 {
            return false;
        }
        let offset = ((t1 - t0) + (t2 - t3)) / 2;
        let (Ok(offset_us), Ok(rtt_us)) = (i64::try_from(offset), u32::try_from(rtt)) else {
            return false;
        };
        if self.samples.len() >= WINDOW {
            self.samples.pop_front();
        }
        self.samples.push_back(ClockEstimate { offset_us, rtt_us });
        true
    }

    /// The minimum-RTT sample of the window, or `None` before the first answer.
    pub fn estimate(&self) -> Option<ClockEstimate> {
        self.samples.iter().min_by_key(|s| s.rtt_us).copied()
    }
}
