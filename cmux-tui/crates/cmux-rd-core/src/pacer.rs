//! Spreads a frame's datagrams over a short window instead of one burst. A
//! keyframe is hundreds of datagrams; written back to back they arrive at a
//! Wi-Fi radio or a switch port faster than it drains, so the tail is queued
//! (read as delay by congestion control) or dropped (read as loss, and
//! repaired a round trip later). The pacer releases them at a rate above
//! the target bitrate, fast enough that a frame of the encoder's budget
//! (target / fps) leaves within part of its frame interval, with a small burst
//! allowance so one wakeup sends several datagrams. No I/O: the caller pushes
//! a frame, asks what is due, and wakes at `next_deadline_us`.
//!
//! Every datagram leaves at that one rate (design D3 and D6, cmuxterm-hq
//! docs/design/screen-share-under-100ms.md). A keyframe or a recovery frame
//! larger than the budget takes longer than one frame interval instead of
//! leaving as a burst that a radio, a relay or a shallow switch buffer drops
//! (and the loss then costs a repair round trip or another keyframe).
//! Repairs (NACK resends and tail-loss probes) go through the same pacer,
//! ahead of queued frames.
//!
//! One exception, bounded: a stream's first keyframe (session start, a new
//! stream after a resize) follows no loss and has nothing to repair, and at the
//! low start target the pacing rate would hold the first picture back (a 300 KB
//! keyframe at 8 Mbps: 120 ms). It may leave within one frame interval, at no
//! more than [`START_BURST_FACTOR`] times the larger of the target and
//! [`START_BURST_FLOOR_BPS`].

use std::collections::VecDeque;

/// The pacing rate is at least this multiple of the target bitrate.
pub const PACING_FACTOR: f64 = 2.5;
/// Burst allowance: what one wakeup may send at once, in microseconds of the rate.
pub const BURST_US: u64 = 2_000;
/// Datagrams one wakeup may always send, however low the rate.
pub const MIN_BURST_DATAGRAMS: usize = 4;
/// A start keyframe's rate is at most this multiple of
/// `max(target, START_BURST_FLOOR_BPS)`.
pub const START_BURST_FACTOR: f64 = 4.0;
/// The target a start keyframe's bound assumes at least: the controller's LAN
/// start rate (`CcConfig::lan_start_bps`).
pub const START_BURST_FLOOR_BPS: u64 = 30_000_000;

#[derive(Debug, Default)]
pub struct Pacer {
    queue: VecDeque<Vec<u8>>,
    queued_bytes: usize,
    /// How many datagrams at the queue's head are repairs (they go first).
    repairs_queued: usize,
    /// Frame datagrams (not repairs) `due` returned since the last
    /// [`Pacer::take_frame_datagrams_sent`].
    frame_datagrams_sent: usize,
    rate_bytes_per_us: f64,
    budget_bytes: f64,
    last_us: Option<u64>,
    /// Datagrams of a start keyframe still queued, and the rate they may leave at.
    start_datagrams: usize,
    start_rate_bytes_per_us: f64,
    /// `PACING_FACTOR` times the last target.
    floor_bytes_per_us: f64,
}

impl Pacer {
    pub fn new() -> Self {
        Self::default()
    }

    /// Queues one frame's datagrams, after any still queued. `target_bps` is the
    /// encoder's target. A frame larger than `target_bps / fps` takes longer
    /// than `_frame_interval_us` to leave: its size never raises the rate.
    pub fn push_frame(
        &mut self,
        datagrams: Vec<Vec<u8>>,
        target_bps: u64,
        _frame_interval_us: u64,
        now_us: u64,
    ) {
        self.wake(now_us);
        for d in datagrams {
            self.queued_bytes += d.len();
            self.queue.push_back(d);
        }
        self.set_rate(target_bps);
    }

    /// Queues a stream's first keyframe (session start, a new stream after a
    /// resize): like [`Pacer::push_frame`], but it may leave within
    /// `frame_interval_us`, at no more than [`START_BURST_FACTOR`] times
    /// `max(target_bps, START_BURST_FLOOR_BPS)`. Never for a keyframe that
    /// answers loss: that one leaves at the pacing rate.
    pub fn push_start_keyframe(
        &mut self,
        datagrams: Vec<Vec<u8>>,
        target_bps: u64,
        frame_interval_us: u64,
        now_us: u64,
    ) {
        let bytes: usize = datagrams.iter().map(Vec::len).sum();
        let fit = bytes as f64 / frame_interval_us.max(1_000) as f64;
        let cap = START_BURST_FACTOR * target_bps.max(START_BURST_FLOOR_BPS) as f64 / 8.0 / 1e6;
        self.start_datagrams += datagrams.len();
        self.start_rate_bytes_per_us = self.start_rate_bytes_per_us.max(fit.min(cap));
        self.push_frame(datagrams, target_bps, frame_interval_us, now_us);
    }

    /// Queues repairs (resent datagrams of frames already sent: NACK answers,
    /// tail-loss probes) ahead of any queued frame, after earlier repairs. The
    /// viewer is waiting on them, but they leave at the pacing rate like any
    /// datagram: a resend burst is lost the way a keyframe burst is.
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

    /// `PACING_FACTOR` times the target, whatever is queued (a start keyframe
    /// still queued keeps its own bound).
    fn set_rate(&mut self, target_bps: u64) {
        let floor = target_bps as f64 * PACING_FACTOR / 8.0 / 1e6;
        self.floor_bytes_per_us = floor;
        self.rate_bytes_per_us =
            if self.start_datagrams > 0 { floor.max(self.start_rate_bytes_per_us) } else { floor };
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
                if self.start_datagrams > 0 {
                    self.start_datagrams -= 1;
                    if self.start_datagrams == 0 {
                        // The start keyframe left: what follows goes at the pacing rate.
                        self.start_rate_bytes_per_us = 0.0;
                        self.rate_bytes_per_us = self.floor_bytes_per_us;
                    }
                }
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
        self.start_datagrams = 0;
        self.start_rate_bytes_per_us = 0.0;
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

    /// Design D3/D6: a keyframe leaves at the pacing rate (2.5 times the target), not at
    /// whatever rate fits it into half a frame interval (base: 41 bytes/us here, 11 times
    /// the target, 345 KB in 8.3 ms). Detector for the class "a large frame leaves as a
    /// burst".
    #[test]
    fn a_keyframe_leaves_at_the_pacing_rate_in_order() {
        let mut p = Pacer::new();
        // 300 datagrams (345 KB) at 30 Mbps and 60 fps: 9.375 bytes/us.
        p.push_frame(frame(300), 30_000_000, 16_667, 1_000);
        let sent = drain(&mut p, 1_000);
        assert_eq!(sent.len(), 300);
        let last = sent.last().unwrap().0;
        let rate = 30_000_000.0 * PACING_FACTOR / 8.0 / 1e6;
        // Less the first burst allowance, which goes at once.
        let floor = ((345_600.0 - rate * BURST_US as f64 - 1152.0) / rate) as u64;
        assert!(last - 1_000 >= floor, "keyframe burst: {} us, pacing needs {floor}", last - 1_000);
        assert!(last - 1_000 <= floor + 2_500, "keyframe took {} us", last - 1_000);
        for (i, (_, d)) in sent.iter().enumerate() {
            assert_eq!(d[0], i as u8, "order");
        }
        // No wakeup sends more than the burst allowance plus one datagram.
        let mut per_time = std::collections::BTreeMap::new();
        for (t, _) in &sent {
            *per_time.entry(*t).or_insert(0usize) += 1;
        }
        let burst = (rate * BURST_US as f64 / 1152.0).ceil() as usize + 1;
        assert!(per_time.values().all(|&n| n <= burst), "{per_time:?}");
    }

    #[test]
    fn repairs_go_before_queued_frames_at_the_pacing_rate() {
        let mut p = Pacer::new();
        p.push_frame(frame(100), 10_000_000, 16_667, 0);
        let first = p.due(0).len();
        assert_eq!(p.take_frame_datagrams_sent(), first);
        // 64 resends (the most one feedback asks for), marked 0xaa.
        let repairs: Vec<Vec<u8>> = (0..64).map(|_| vec![0xaa; 1152]).collect();
        p.push_repair(repairs, 10_000_000, 1_000);
        p.push_repair(vec![vec![0xbb; 1152]], 10_000_000, 1_000);
        let sent = drain(&mut p, 1_000);
        assert_eq!(sent.len(), 100 - first + 65);
        assert!(sent[..64].iter().all(|(_, d)| d[0] == 0xaa), "repairs first, in order");
        assert_eq!(sent[64].1[0], 0xbb);
        assert_eq!(p.take_frame_datagrams_sent(), 100 - first);
        // Paced: 74 KB of repairs at 3.125 bytes/us take about 23 ms, not one wakeup.
        let repairs_done = sent[64].0 - 1_000;
        assert!(repairs_done >= 20_000, "repairs left as a burst: {repairs_done} us");
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
