//! Spreads a frame's datagrams over a short window instead of one burst. A
//! keyframe is hundreds of datagrams; written back to back they arrive at a
//! Wi-Fi radio or a switch port faster than it drains, so the tail is queued
//! (read as delay by congestion control) or dropped (read as loss, and
//! repaired a round trip later). The pacer releases them at a rate above
//! the target bitrate, fast enough that a frame still leaves within a
//! fraction of its frame interval, with a small burst allowance so one wakeup
//! sends several datagrams. No I/O: the caller pushes a frame, asks what is
//! due, and wakes at `next_deadline_us`.
//!
//! Repairs (NACK resends and tail-loss probes) go through the same pacer, ahead
//! of queued frames, under the same rule: a 64-datagram resend written back to
//! back is lost the way a keyframe burst is (design D6, cmuxterm-hq
//! docs/design/screen-share-under-100ms.md).
//!
//! Why a large frame raises the rate rather than taking longer than half a frame
//! interval: pacing a keyframe at only 2.5 times a target that loss has cut held
//! recovery keyframes and their repairs past the viewer's deadline. On the
//! Wi-Fi-away netem profile that meant 31 recovery keyframes instead of 2, and a
//! key-to-decoded p95 of 272 ms instead of 132 ms.

use std::collections::VecDeque;

/// The pacing rate is at least this multiple of the target bitrate.
pub const PACING_FACTOR: f64 = 2.5;
/// What is queued (repairs, frames) leaves within this share of the frame interval
/// at most (the rate rises to fit a large frame: a keyframe).
pub const SPREAD_SHARE: f64 = 0.5;
/// ... and within this many microseconds whatever the frame rate. The send stage
/// adds its span to every frame's glass-to-glass time, so it is bounded in time,
/// not only as a share of the interval: at 30 fps half an interval is 16.7 ms
/// and an at-budget frame took 11.4 ms to leave (goal screen-share-rate-control,
/// "Send stage p50 at most 8 ms at any rate").
pub const MAX_SPREAD_US: f64 = 8_000.0;
/// Burst allowance: what one wakeup may send at once, in microseconds of the rate.
pub const BURST_US: u64 = 2_000;
/// Datagrams one wakeup may always send, however low the rate.
pub const MIN_BURST_DATAGRAMS: usize = 4;

#[derive(Debug, Default)]
pub struct Pacer {
    queue: VecDeque<Vec<u8>>,
    queued_bytes: usize,
    /// How many datagrams at the queue's head are repairs (they go first).
    repairs_queued: usize,
    /// Frame datagrams (not repairs) `due` returned since the last
    /// [`Pacer::take_frame_datagrams_sent`].
    frame_datagrams_sent: usize,
    /// The stream's frame interval, from the last frame pushed.
    frame_interval_us: u64,
    rate_bytes_per_us: f64,
    budget_bytes: f64,
    last_us: Option<u64>,
}

impl Pacer {
    pub fn new() -> Self {
        Self::default()
    }

    /// Queues one frame's datagrams, after any still queued. `target_bps` is the
    /// encoder's target and `frame_interval_us` the stream's frame interval.
    pub fn push_frame(
        &mut self,
        datagrams: Vec<Vec<u8>>,
        target_bps: u64,
        frame_interval_us: u64,
        now_us: u64,
    ) {
        self.frame_interval_us = frame_interval_us;
        self.wake(now_us);
        for d in datagrams {
            self.queued_bytes += d.len();
            self.queue.push_back(d);
        }
        self.set_rate(target_bps);
    }

    /// Queues repairs (resent datagrams of frames already sent: NACK answers,
    /// tail-loss probes) ahead of any queued frame, after earlier repairs, at the
    /// same rate as frames: never as one burst, and never behind a queued frame.
    pub fn push_repair(&mut self, datagrams: Vec<Vec<u8>>, target_bps: u64, now_us: u64) {
        if datagrams.is_empty() {
            return;
        }
        self.wake(now_us);
        for d in datagrams {
            self.queued_bytes += d.len();
            self.queue.insert(self.repairs_queued, d);
            self.repairs_queued += 1;
        }
        self.set_rate(target_bps);
    }

    /// Idle: what is pushed next starts at once.
    fn wake(&mut self, now_us: u64) {
        if self.queue.is_empty() {
            self.last_us = Some(now_us);
            self.budget_bytes = 0.0;
        }
    }

    /// `PACING_FACTOR` times the target, or faster when that would hold what is
    /// queued longer than `SPREAD_SHARE` of a frame interval or `MAX_SPREAD_US`.
    fn set_rate(&mut self, target_bps: u64) {
        let interval_us = if self.frame_interval_us == 0 { 16_667 } else { self.frame_interval_us };
        let window_us = (interval_us as f64 * SPREAD_SHARE).clamp(1_000.0, MAX_SPREAD_US);
        let floor = target_bps as f64 * PACING_FACTOR / 8.0 / 1e6;
        let fit = self.queued_bytes as f64 / window_us;
        self.rate_bytes_per_us = floor.max(fit);
        if self.budget_bytes <= 0.0 {
            self.budget_bytes = self.burst_bytes();
        }
    }

    fn burst_bytes(&self) -> f64 {
        let head = self.queue.front().map_or(0, Vec::len) as f64;
        (self.rate_bytes_per_us * BURST_US as f64).max(head * MIN_BURST_DATAGRAMS as f64)
    }

    /// The datagrams due now, in order.
    pub fn due(&mut self, now_us: u64) -> Vec<Vec<u8>> {
        let mut out = Vec::new();
        if self.queue.is_empty() {
            return out;
        }
        let last = self.last_us.unwrap_or(now_us);
        let elapsed = now_us.saturating_sub(last) as f64;
        self.last_us = Some(now_us);
        self.budget_bytes = (self.budget_bytes + elapsed * self.rate_bytes_per_us)
            .min(self.burst_bytes().max(self.budget_bytes));
        while self.budget_bytes > 0.0 {
            let Some(d) = self.queue.pop_front() else { break };
            self.budget_bytes -= d.len() as f64;
            self.queued_bytes -= d.len();
            if self.repairs_queued > 0 {
                self.repairs_queued -= 1;
            } else {
                self.frame_datagrams_sent += 1;
            }
            out.push(d);
        }
        if self.queue.is_empty() {
            self.budget_bytes = 0.0;
        }
        out
    }

    /// When the next datagram is due (`None` while nothing is queued).
    pub fn next_deadline_us(&self) -> Option<u64> {
        self.queue.front()?;
        let last = self.last_us?;
        if self.budget_bytes > 0.0 {
            return Some(last);
        }
        let need = -self.budget_bytes + 1.0;
        let wait = (need / self.rate_bytes_per_us.max(1e-6)).ceil() as u64;
        Some(last.saturating_add(wait.max(1)))
    }

    pub fn is_empty(&self) -> bool {
        self.queue.is_empty()
    }

    pub fn queued_bytes(&self) -> usize {
        self.queued_bytes
    }

    /// How many of the datagrams `due` returned since the last call were frame
    /// datagrams rather than repairs (for per-frame send times).
    pub fn take_frame_datagrams_sent(&mut self) -> usize {
        std::mem::take(&mut self.frame_datagrams_sent)
    }

    /// Drops everything queued (the session ended).
    pub fn clear(&mut self) {
        self.queue.clear();
        self.queued_bytes = 0;
        self.repairs_queued = 0;
        self.budget_bytes = 0.0;
    }

    /// The queued frame datagrams, in send order (to decide what an outage end drops,
    /// D12). Repairs are left out: they resend frames that already left, and a
    /// tail-loss probe of a one-datagram frame would otherwise read as that whole
    /// frame unstarted.
    pub fn queued(&self) -> impl Iterator<Item = &[u8]> {
        self.queue.iter().skip(self.repairs_queued).map(Vec::as_slice)
    }

    /// Takes the queued frame datagrams `stale` picks, in order, so the caller can
    /// retire them (an outage ended and they are stale, D12); the rest, and every
    /// queued repair, keep their place and pacing. When nothing is left the next
    /// frame pushed goes at once.
    pub fn take_where(&mut self, mut stale: impl FnMut(&[u8]) -> bool) -> Vec<Vec<u8>> {
        let mut taken = Vec::new();
        let mut kept = VecDeque::with_capacity(self.queue.len());
        for (i, d) in self.queue.drain(..).enumerate() {
            if i >= self.repairs_queued && stale(&d) {
                self.queued_bytes -= d.len();
                taken.push(d);
            } else {
                kept.push_back(d);
            }
        }
        self.queue = kept;
        if self.queue.is_empty() {
            self.budget_bytes = 0.0;
        }
        taken
    }
}

#[cfg(test)]
#[path = "pacer_tests.rs"]
mod tests;
