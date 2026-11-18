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
    /// queued longer than `SPREAD_SHARE` of a frame interval.
    fn set_rate(&mut self, target_bps: u64) {
        let interval_us = if self.frame_interval_us == 0 { 16_667 } else { self.frame_interval_us };
        let window_us = (interval_us as f64 * SPREAD_SHARE).max(1_000.0);
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
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frame(n: usize) -> Vec<Vec<u8>> {
        (0..n).map(|i| vec![i as u8; 1152]).collect()
    }

    /// Runs the pacer by its own deadlines; returns (send time, datagram) pairs.
    fn drain(p: &mut Pacer, from: u64) -> Vec<(u64, Vec<u8>)> {
        let mut out = Vec::new();
        let mut now = from;
        for _ in 0..100_000 {
            for d in p.due(now) {
                out.push((now, d));
            }
            match p.next_deadline_us() {
                Some(t) => now = t.max(now + 1),
                None => break,
            }
        }
        out
    }

    #[test]
    fn a_keyframe_leaves_within_half_a_frame_interval_in_order() {
        let mut p = Pacer::new();
        // 300 datagrams (345 KB) at 30 Mbps and 60 fps.
        p.push_frame(frame(300), 30_000_000, 16_667, 1_000);
        let sent = drain(&mut p, 1_000);
        assert_eq!(sent.len(), 300);
        let last = sent.last().unwrap().0;
        assert!(last - 1_000 <= 8_400, "keyframe took {} us", last - 1_000);
        // Less the first burst allowance, which goes at once.
        assert!(last - 1_000 >= 5_500, "keyframe was not spread: {} us", last - 1_000);
        for (i, (_, d)) in sent.iter().enumerate() {
            assert_eq!(d[0], i as u8, "order");
        }
        // No wakeup sends more than the burst allowance plus one datagram.
        let mut per_time = std::collections::BTreeMap::new();
        for (t, _) in &sent {
            *per_time.entry(*t).or_insert(0usize) += 1;
        }
        let rate = 345_600.0 / 8_333.0; // bytes per us
        let burst = (rate * BURST_US as f64 / 1152.0).ceil() as usize + 1;
        assert!(per_time.values().all(|&n| n <= burst), "{per_time:?}");
    }

    /// Design D6, detector for the class "a recovery leaves as an unpaced burst": a
    /// NACK answer (64 resends, the most one feedback asks for) leaves ahead of the
    /// queued frame, in order, no more than the burst allowance per wakeup, and within
    /// half a frame interval.
    #[test]
    fn repairs_leave_paced_ahead_of_queued_frames() {
        let mut p = Pacer::new();
        p.push_frame(frame(100), 10_000_000, 16_667, 0);
        let first = p.due(0).len();
        assert_eq!(p.take_frame_datagrams_sent(), first);
        let repairs: Vec<Vec<u8>> = (0..64).map(|_| vec![0xaa; 1152]).collect();
        p.push_repair(repairs, 10_000_000, 1_000);
        p.push_repair(vec![vec![0xbb; 1152]], 10_000_000, 1_000);
        let sent = drain(&mut p, 1_000);
        assert_eq!(sent.len(), 100 - first + 65);
        assert!(sent[..64].iter().all(|(_, d)| d[0] == 0xaa), "repairs first, in order");
        assert_eq!(sent[64].1[0], 0xbb);
        assert_eq!(p.take_frame_datagrams_sent(), 100 - first);
        let at_once = sent.iter().filter(|(t, _)| *t == 1_000).count();
        assert!(at_once < 65, "the repairs left as one burst: {at_once} datagrams at once");
        let last = sent.last().unwrap().0 - 1_000;
        assert!(last <= 8_400, "repairs and the frame behind them took {last} us");
    }

    #[test]
    fn a_repair_on_an_idle_pacer_goes_at_once() {
        let mut p = Pacer::new();
        p.push_repair(vec![vec![1; 1152]; 3], 30_000_000, 5_000);
        assert_eq!(p.due(5_000).len(), 3);
        assert!(p.is_empty());
        assert_eq!(p.take_frame_datagrams_sent(), 0);
    }

    #[test]
    fn a_small_frame_goes_at_once_and_a_p_frame_at_two_and_a_half_times_the_target() {
        let mut p = Pacer::new();
        p.push_frame(frame(3), 30_000_000, 16_667, 0);
        assert_eq!(p.due(0).len(), 3);
        assert!(p.is_empty());
        assert_eq!(p.next_deadline_us(), None);
        // 54 datagrams (62 KB, one 30 Mbps frame at 60 fps) at 75 Mbps: about 6.6 ms, less
        // the first burst allowance.
        p.push_frame(frame(54), 30_000_000, 16_667, 100_000);
        let sent = drain(&mut p, 100_000);
        let span = sent.last().unwrap().0 - 100_000;
        assert!((4_200..=7_000).contains(&span), "span {span}");
    }

    #[test]
    fn a_frame_pushed_while_one_is_queued_follows_it() {
        let mut p = Pacer::new();
        p.push_frame(frame(100), 10_000_000, 16_667, 0);
        let first = p.due(0).len();
        assert!(first < 100);
        p.push_frame(vec![vec![0xee; 1152]], 10_000_000, 16_667, 1_000);
        let rest = drain(&mut p, 1_000);
        assert_eq!(first + rest.len(), 101);
        assert_eq!(rest.last().unwrap().1[0], 0xee);
    }

    #[test]
    fn a_late_wakeup_does_not_release_a_burst() {
        let mut p = Pacer::new();
        p.push_frame(frame(200), 20_000_000, 16_667, 0);
        p.due(0);
        // The caller slept 5 ms instead of the deadline: still at most the burst allowance.
        let late = p.due(5_000).len();
        let rate = 230_400.0 / 8_333.0;
        assert!(late as f64 <= (rate * BURST_US as f64 / 1152.0).ceil() + 1.0, "{late}");
    }
}
