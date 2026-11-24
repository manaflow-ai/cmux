//! How good one peer's link is, as a game's ping bar says it: `good`, `slow` or `poor`
//! (`quality` in `_acpmux/peers`), and how long a check of a silent link waits for its answer,
//! scaled to the round trip the link measured, so a slow link is slow, not dead.
//!
//! - Round trips: each keepalive ping's pong (`peer_runtime_io.rs`) feeds [`RttEstimator`],
//!   TCP's smoothed round trip and its mean deviation (RFC 6298: `srtt`, `rttvar`).
//! - Late ticks: each ping tick that found the link silent a whole interval (the tick that marks
//!   it `degraded`) counts as late; the share of late ticks in the last [`LATE_WINDOW`] ticks is
//!   the link's loss as a person feels it (over TCP a lost packet arrives late, not never).
//! - Tier: [`TierState::next`] reads both, with hysteresis, so the bar does not flap.
//! - Waits: [`probe_wait`] and [`silence_floor`] take TCP's retransmission timeout shape,
//!   `srtt + 4 * rttvar`, between today's constants and a stated ceiling.
//!
//! Memory is constant: two numbers and a ring of [`LATE_WINDOW`] bits per peer. No timer: it
//! moves on the link's own pings.

use serde_json::{Value, json};
use std::time::Duration;

/// Ping ticks the late share is read over: one minute at the 2 s ping.
pub const LATE_WINDOW: usize = 30;

/// How a link feels to a person typing or chatting over it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Tier {
    Good,
    Slow,
    Poor,
}

impl Tier {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Good => "good",
            Self::Slow => "slow",
            Self::Poor => "poor",
        }
    }
}

/// The tier thresholds. Games call under 80 ms good and under 250 ms playable: aiming feels a
/// frame. Typing into a terminal or a chat through a peer tolerates about twice that: an ssh
/// session across the Atlantic (100 to 150 ms) is used all day, and past about half a second
/// each keystroke and each send visibly waits. Latency here is `srtt + 2 * rttvar`, about the
/// round trip most answers come within, so a jittery link reads as slow as it feels.
///
/// | tier | latency   | late ticks |
/// |------|-----------|------------|
/// | good | <= 200 ms | <= 5 %     |
/// | slow | <= 500 ms | <= 20 %    |
/// | poor | else      | else       |
///
/// Hysteresis: a link moves to a better tier only once it is under 80 % of that tier's limits
/// (160 ms and 4 %, 400 ms and 16 %) for [`UPGRADE_AFTER`] ticks in a row, and to a worse one
/// once it is past its own tier's limits for [`DOWNGRADE_AFTER`] ticks in a row. A link that
/// sits on a limit keeps its tier.
pub const GOOD_MS: f64 = 200.0;
pub const SLOW_MS: f64 = 500.0;
pub const GOOD_LATE: f64 = 0.05;
pub const SLOW_LATE: f64 = 0.20;
/// The share of a limit a link must be under to move up to it.
pub const UPGRADE_MARGIN: f64 = 0.8;
/// Ticks in a row (10 s at the 2 s ping) under a better tier's limits before the link moves up.
pub const UPGRADE_AFTER: u8 = 5;
/// Ticks in a row (4 s) past the tier's limits before the link moves down: one late pong is
/// not a bad link, two in a row is.
pub const DOWNGRADE_AFTER: u8 = 2;

/// What one tick knows of the link.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Reading {
    /// `srtt + 2 * rttvar`, ms.
    pub latency_ms: f64,
    /// The share of late ticks in the window, 0 to 1.
    pub late: f64,
}

impl Reading {
    /// The tier this reading meets with limits scaled by `margin` (1: the tier's own limits).
    fn tier(self, margin: f64) -> Tier {
        if self.latency_ms <= GOOD_MS * margin && self.late <= GOOD_LATE * margin {
            Tier::Good
        } else if self.latency_ms <= SLOW_MS * margin && self.late <= SLOW_LATE * margin {
            Tier::Slow
        } else {
            Tier::Poor
        }
    }
}

/// The tier shown, and the ticks in a row that argued for moving it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TierState {
    pub tier: Tier,
    better: u8,
    worse: u8,
}

impl TierState {
    /// The first reading sets the tier at once: there is nothing to flap from.
    pub fn first(reading: Reading) -> Self {
        Self { tier: reading.tier(1.0), better: 0, worse: 0 }
    }

    /// The state after one more tick's reading.
    pub fn next(self, reading: Reading) -> Self {
        let held = reading.tier(1.0);
        if held > self.tier {
            let worse = self.worse.saturating_add(1);
            if worse >= DOWNGRADE_AFTER {
                return Self { tier: held, better: 0, worse: 0 };
            }
            return Self { tier: self.tier, better: 0, worse };
        }
        if reading.tier(UPGRADE_MARGIN) < self.tier {
            let better = self.better.saturating_add(1);
            if better >= UPGRADE_AFTER {
                // One step at a time: poor to slow, then slow to good after another run.
                let up = if self.tier == Tier::Poor { Tier::Slow } else { Tier::Good };
                return Self { tier: up, better: 0, worse: 0 };
            }
            return Self { tier: self.tier, better, worse: 0 };
        }
        Self { tier: self.tier, better: 0, worse: 0 }
    }
}

/// TCP's round-trip estimate (RFC 6298 section 2): `srtt` moves an eighth of the way to each
/// sample, `rttvar` a quarter of the way to the sample's distance from `srtt`.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct RttEstimator {
    srtt: Duration,
    rttvar: Duration,
    samples: u32,
}

impl RttEstimator {
    pub fn sample(&mut self, rtt: Duration) {
        if self.samples == 0 {
            self.srtt = rtt;
            self.rttvar = rtt / 2;
        } else {
            let gap = self.srtt.abs_diff(rtt);
            self.rttvar = self.rttvar * 3 / 4 + gap / 4;
            self.srtt = self.srtt * 7 / 8 + rtt / 8;
        }
        self.samples = self.samples.saturating_add(1);
    }

    pub fn srtt(&self) -> Option<Duration> {
        (self.samples > 0).then_some(self.srtt)
    }

    pub fn rttvar(&self) -> Option<Duration> {
        (self.samples > 0).then_some(self.rttvar)
    }

    /// TCP's retransmission timeout shape, `srtt + 4 * rttvar`, once a sample came.
    pub fn rto(&self) -> Option<Duration> {
        (self.samples > 0).then(|| self.srtt + self.rttvar * 4)
    }
}

/// The ceiling of [`probe_wait`]: the floor of the silence budget
/// (`LinkTimings::silence_budget`, 6 s). A check that waited longer would find a dead link no
/// sooner than the ping tick does.
pub const PROBE_MOST: Duration = Duration::from_secs(6);

/// How long a ping sent to check a silent link (a request on it, a network change) waits for any
/// byte before the link is dropped: four of the link's retransmission timeouts, never under
/// `floor` (`NETWORK_PROBE`, 2 s, which a link with no round trip measured yet keeps) nor over
/// [`PROBE_MOST`]. Four, because over TCP the answer to a ping whose packet is lost twice in a
/// row comes after one timeout, then a doubled one, then the round trip: `rto + 2 * rto + srtt`,
/// under `4 * rto`. A link at 20 or 150 ms keeps 2 s; one at 800 ms waits about 4 s.
pub fn probe_wait(rtt: &RttEstimator, floor: Duration) -> Duration {
    rtt.rto().map_or(floor, |rto| (rto * 4).clamp(floor, PROBE_MOST.max(floor)))
}

/// How much longer than its base a silence budget may grow from round trips alone: twice it
/// (12 s at the default 6 s), so a dead link on the slowest link is found within 12 s plus one
/// ping interval. Answers that came late still grow the budget further (`SilenceBudget`).
pub const SILENCE_SCALE_MOST: u32 = 2;

/// The silence budget's floor for a link with this round trip: one ping interval plus the same
/// four timeouts as [`probe_wait`] (a pong due one interval after the last byte, lost twice), not
/// under `base` (`LinkTimings::silence_budget`) nor over [`SILENCE_SCALE_MOST`] times it. Below
/// about 700 ms of round trip it is `base`: today's 6 s.
pub fn silence_floor(rtt: &RttEstimator, ping_every: Duration, base: Duration) -> Duration {
    rtt.rto().map_or(base, |rto| (ping_every + rto * 4).clamp(base, base * SILENCE_SCALE_MOST))
}

/// One peer's link quality, kept across its links: its round trips, its recent late ticks and
/// the tier shown.
#[derive(Debug, Clone, Default)]
pub struct LinkQuality {
    rtt: RttEstimator,
    /// The last [`LATE_WINDOW`] ticks, a bit each, newest in bit 0.
    late_bits: u64,
    ticks: u8,
    tier: Option<TierState>,
}

impl LinkQuality {
    pub fn rtt(&self) -> &RttEstimator {
        &self.rtt
    }

    /// A pong answered a ping after `rtt`.
    pub fn pong(&mut self, rtt: Duration) {
        self.rtt.sample(rtt);
    }

    /// A ping tick on a link that is up; `late` when it found the link silent a whole interval.
    /// Nothing counts until a round trip is known: before the first pong a late tick is the link
    /// opening, and on a two-tick window it would read as half the minute late.
    pub fn tick(&mut self, late: bool) {
        if self.rtt.srtt().is_none() {
            return;
        }
        let mask = (1u64 << LATE_WINDOW) - 1;
        self.late_bits = ((self.late_bits << 1) | u64::from(late)) & mask;
        self.ticks = self.ticks.saturating_add(1).min(LATE_WINDOW as u8);
        let Some(reading) = self.reading() else { return };
        self.tier = Some(self.tier.map_or_else(|| TierState::first(reading), |t| t.next(reading)));
    }

    fn reading(&self) -> Option<Reading> {
        let (srtt, rttvar) = (self.rtt.srtt()?, self.rtt.rttvar()?);
        let late = if self.ticks == 0 {
            0.0
        } else {
            f64::from(self.late_bits.count_ones()) / f64::from(self.ticks)
        };
        Some(Reading { latency_ms: (srtt + rttvar * 2).as_secs_f64() * 1000.0, late })
    }

    pub fn tier(&self) -> Option<Tier> {
        self.tier.map(|t| t.tier)
    }

    /// `quality` in `_acpmux/peers`: null until a round trip was measured.
    pub fn view(&self) -> Value {
        let (Some(tier), Some(reading)) = (self.tier(), self.reading()) else {
            return Value::Null;
        };
        let ms = |d: Option<Duration>| d.map(|d| (d.as_secs_f64() * 10_000.0).round() / 10.0);
        json!({
            "tier": tier.as_str(),
            "srttMs": ms(self.rtt.srtt()),
            "rttvarMs": ms(self.rtt.rttvar()),
            "lateShare": (reading.late * 1000.0).round() / 1000.0,
        })
    }
}

#[cfg(test)]
#[path = "peer_link_quality_unit_tests.rs"]
mod tests;
