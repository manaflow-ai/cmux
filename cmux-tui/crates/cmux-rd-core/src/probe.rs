//! Bandwidth probes while the screen is quiet (design D4, cmuxterm-hq
//! docs/design/screen-share-under-100ms.md). The delay-gradient controller grows
//! only on evidence: a quiet screen sends a fraction of the target, so the target
//! stays where it was and motion starts low (an 8 Mbit/s start on a Wi-Fi or WAN
//! path takes about a second of motion to reach 15). This scheduler asks for a
//! short train of padding datagrams (`DatagramKind::Probe`) at a rate above the
//! target, at most once per [`ProbeConfig::interval_us`], while the stream sends
//! well under the target and the controller may act (no outage, no overuse, no
//! train still unanswered). The controller times the train's arrivals and grows
//! from what the path carried ([`crate::cc::CongestionController::on_probe_sent`]),
//! never from the quiet stream alone.
//!
//! Every probe byte counts against the rate (D10): probes are timed like frames
//! and go through the pacer behind repairs and frames, never ahead of a frame.
//!
//! Idle cost: one train per interval of at most `rate_factor * target * train_us`
//! and at most `max_datagrams` datagrams, so at the defaults (2x the target for
//! 20 ms, 64 datagrams, once a second) at most 4% of the target and at most
//! 64 x 1152 bytes (590 kbit/s) on a 1152-byte link. No I/O: the caller polls with
//! the controller's view and wakes at `next_deadline_us`.

/// Probe limits.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ProbeConfig {
    /// Shortest time between two trains.
    pub interval_us: u64,
    /// The train's rate, as a multiple of the target.
    pub rate_factor: f64,
    /// How long one train lasts at its rate (before the datagram bounds).
    pub train_us: u64,
    pub min_datagrams: usize,
    pub max_datagrams: usize,
    /// The stream counts as quiet while it sends under this share of the target.
    pub quiet_share: f64,
}

impl Default for ProbeConfig {
    fn default() -> Self {
        Self {
            interval_us: 1_000_000,
            rate_factor: 2.0,
            train_us: 20_000,
            min_datagrams: 8,
            max_datagrams: 64,
            quiet_share: 0.5,
        }
    }
}

impl ProbeConfig {
    /// The most bytes one interval's train can be, with `datagram_bytes` datagrams at
    /// `target_bps`: the idle cost bound.
    pub fn max_train_bytes(&self, target_bps: u64, datagram_bytes: usize) -> u64 {
        let by_rate = (target_bps as f64 * self.rate_factor * self.train_us as f64 / 8e6) as u64;
        let max = (self.max_datagrams * datagram_bytes) as u64;
        let min = (self.min_datagrams * datagram_bytes) as u64;
        by_rate.min(max).max(min)
    }
}

/// What the controller says about probing now.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ProbeView {
    pub target_bps: u64,
    /// The controller's ceiling: a target there has nothing to probe for.
    pub max_bps: u64,
    /// Our own send rate (every datagram, probes too) over the controller's window.
    pub sent_bps: f64,
    /// No outage, no overuse in force, no train waiting for its feedback.
    pub may_probe: bool,
}

/// One train to send now: `datagrams` datagrams of the link's size, paced at `rate_bps`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProbeTrain {
    pub datagrams: usize,
    pub rate_bps: u64,
}

#[derive(Debug)]
pub struct ProbeScheduler {
    config: ProbeConfig,
    datagram_bytes: usize,
    next_us: Option<u64>,
}

impl ProbeScheduler {
    pub fn new(config: ProbeConfig, datagram_bytes: usize) -> Self {
        Self { config, datagram_bytes: datagram_bytes.max(1), next_us: None }
    }

    pub fn config(&self) -> &ProbeConfig {
        &self.config
    }

    /// A train to send now, if one is due and the stream is quiet. The first train
    /// waits one interval from the first poll (the start frames settle first).
    pub fn poll(&mut self, now_us: u64, view: ProbeView) -> Option<ProbeTrain> {
        let next = *self.next_us.get_or_insert(now_us.saturating_add(self.config.interval_us));
        if now_us < next {
            return None;
        }
        let quiet = view.sent_bps < self.config.quiet_share * view.target_bps as f64;
        if !view.may_probe || !quiet || view.target_bps >= view.max_bps {
            // Asked again one interval later: a stream in motion is its own evidence.
            self.next_us = Some(now_us.saturating_add(self.config.interval_us));
            return None;
        }
        self.next_us = Some(now_us.saturating_add(self.config.interval_us));
        let rate_bps = (view.target_bps as f64 * self.config.rate_factor) as u64;
        let bytes = self.config.max_train_bytes(view.target_bps, self.datagram_bytes);
        let datagrams = usize::try_from(bytes).unwrap_or(usize::MAX) / self.datagram_bytes;
        Some(ProbeTrain {
            datagrams: datagrams.clamp(self.config.min_datagrams, self.config.max_datagrams),
            rate_bps,
        })
    }

    /// When the next train may be due (`None` before the first poll).
    pub fn next_deadline_us(&self) -> Option<u64> {
        self.next_us
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn view(target_bps: u64, sent_bps: f64) -> ProbeView {
        ProbeView { target_bps, max_bps: 80_000_000, sent_bps, may_probe: true }
    }

    #[test]
    fn a_quiet_stream_gets_one_bounded_train_per_interval() {
        let mut s = ProbeScheduler::new(ProbeConfig::default(), 1152);
        assert_eq!(s.poll(0, view(8_000_000, 0.3e6)), None, "the first waits an interval");
        let t = s.poll(1_000_000, view(8_000_000, 0.3e6)).expect("due");
        assert_eq!(t.rate_bps, 16_000_000);
        // 16 Mbit/s for 20 ms: 40 KB, 34 datagrams.
        assert_eq!(t.datagrams, 34);
        assert_eq!(s.poll(1_500_000, view(8_000_000, 0.3e6)), None);
        let big = s.poll(2_000_000, view(60_000_000, 0.3e6)).expect("due");
        assert_eq!(big.datagrams, 64, "capped");
    }

    #[test]
    fn no_train_in_motion_at_the_ceiling_or_when_the_controller_says_no() {
        let mut s = ProbeScheduler::new(ProbeConfig::default(), 1152);
        s.poll(0, view(8_000_000, 0.0));
        assert_eq!(s.poll(1_000_000, view(8_000_000, 6e6)), None, "motion");
        assert_eq!(s.poll(2_000_000, view(80_000_000, 0.0)), None, "ceiling");
        let no = ProbeView { may_probe: false, ..view(8_000_000, 0.0) };
        assert_eq!(s.poll(3_000_000, no), None, "outage or overuse");
        assert!(s.poll(4_000_000, view(8_000_000, 0.0)).is_some());
    }
}
