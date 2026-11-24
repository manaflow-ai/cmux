//! A delay-based window for a bulk TCP connection (Vegas, LEDBAT and Copa's
//! idea), so bulk never fills the bottleneck queue.
//!
//! A FIFO in the path (an LTE cell's buffer, a home router) holds whatever
//! the sender puts in flight past the path's bandwidth-delay product.
//! smoltcp's loss-based congestion control only backs off once that queue
//! overflows, so a bulk transfer keeps it full, and every packet behind it,
//! a keystroke's echo included, waits the whole queue (about 250 ms on the
//! lte profile). Priority in the pacer cannot help: the packets are already
//! queued past it.
//!
//! The window here caps the bytes a connection has on the wire (sent and
//! not acknowledged), from the round-trip times of its own segments:
//!
//! - Every fresh segment's departure is kept; an ACK gives one sample per
//!   segment it covers (the newest one's), so samples come per ACK, not per
//!   round trip. A retransmission clears them (Karn).
//! - The base delay is the minimum sample over the last few minutes
//!   (LEDBAT's base history: [`BASE_BUCKETS`] minutes in one-minute
//!   buckets), so it follows a route change within minutes but a standing
//!   queue cannot raise it within one.
//! - The window is set about once every two round trips. A round's samples
//!   are only those of segments sent after the last change (the ACKs of
//!   segments already in flight describe the old window); it ends one round
//!   trip after the first of them is back. From the round's smallest
//!   sample `rtt` (the least noisy: delayed ACKs and jitter only add), the
//!   window becomes `window * (base + TARGET) / rtt`: with a standing queue
//!   the throughput is `window / rtt`, so the new window holds the
//!   bandwidth-delay product plus [`TARGET`] of queue; with no queue it grows
//!   by `TARGET / base`. Each change is at most a factor of two either way.
//! - Slow start doubles the window each measured round while the queueing
//!   delay stays under half the target, and ends as soon as the last
//!   [`SLOW_START_SAMPLES`] samples all show more than the target (cutting
//!   the window as above from the smallest, by up to four times).
//! - A connection that did not use its window in a round (application
//!   limited) does not grow it.
//! - The window holds fresh data only: the pacer queues a resent segment
//!   ahead of the fresh ones, which may wait for the ACK it brings.
//!
//! The backlog the window holds back waits in the pacer, behind every
//! interactive connection and datagram, instead of in the path's queue.
//! Nothing changes on the wire.

use std::collections::VecDeque;
use std::sync::OnceLock;
use std::time::Duration;

use tokio::time::Instant;

/// Queueing delay the window aims to add over the base delay.
pub(crate) const TARGET: Duration = Duration::from_millis(5);
/// The smallest window: four full-size segments.
const MIN_WINDOW: u32 = 4 * 1200;
/// The window before the first round is measured.
const INITIAL_WINDOW: u32 = 32 * 1200;
/// Samples of a round before slow start may end on them.
const SLOW_START_SAMPLES: usize = 8;
/// Departures kept for samples; past this, segments go unsampled.
const MAX_DEPARTURES: usize = 4096;
/// Minutes of base-delay history (RFC 6817's BASE_HISTORY).
const BASE_BUCKETS: usize = 10;
const BUCKET: Duration = Duration::from_secs(60);

/// Whether bulk connections are held to a delay-based window:
/// `CMUX_WG_DELAY_WINDOW=off` turns it off (to compare), read once.
pub(crate) fn enabled() -> bool {
    static ENABLED: OnceLock<bool> = OnceLock::new();
    *ENABLED.get_or_init(|| {
        std::env::var("CMUX_WG_DELAY_WINDOW").map_or(true, |value| value != "off" && value != "0")
    })
}

/// `a` is after `b` in sequence space.
fn after(a: u32, b: u32) -> bool {
    (a.wrapping_sub(b) as i32) > 0
}

/// The round being measured: samples of segments sent from `since` (the
/// last change) on; once the first of them is back, the round runs until the
/// ACK passes `until`, what had been sent by then.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Round {
    since: Instant,
    until: Option<u32>,
}

#[derive(Debug)]
pub(crate) struct DelayWindow {
    /// Bytes the connection may have on the wire.
    window: u32,
    slow_start: bool,
    /// Sequence end and departure of fresh segments not yet acknowledged.
    departures: VecDeque<(u32, Instant)>,
    /// Minimum sample per minute, newest last.
    base: VecDeque<(Instant, Duration)>,
    round: Option<Round>,
    /// Smallest sample of the round being measured.
    round_min: Option<Duration>,
    /// The last [`SLOW_START_SAMPLES`] samples, in slow start.
    recent: VecDeque<Duration>,
    /// Largest wire flight seen in the round being measured.
    round_flight: u32,
}

impl Default for DelayWindow {
    fn default() -> Self {
        Self {
            window: INITIAL_WINDOW,
            slow_start: true,
            departures: VecDeque::new(),
            base: VecDeque::new(),
            round: None,
            round_min: None,
            recent: VecDeque::new(),
            round_flight: 0,
        }
    }
}

impl DelayWindow {
    /// The bytes of fresh data allowed on the wire, or `None` when off.
    pub(crate) fn window(&self) -> Option<u32> {
        enabled().then_some(self.window)
    }

    /// The base delay: the smallest sample of the history.
    pub(crate) fn base(&self) -> Option<Duration> {
        self.base.iter().map(|(_, min)| *min).min()
    }

    /// A fresh segment ending at `end` left at `now`, with `flight` bytes on
    /// the wire after it.
    pub(crate) fn departed(&mut self, end: u32, flight: u32, now: Instant) {
        if self.departures.len() < MAX_DEPARTURES {
            self.departures.push_back((end, now));
        }
        self.round_flight = self.round_flight.max(flight);
        if self.round.is_none() {
            self.round = Some(Round { since: now, until: None });
        }
    }

    /// TCP sends old sequence space again.
    pub(crate) fn resent(&mut self) {
        // Karn: an ACK after a resend may be for either copy.
        self.departures.clear();
        self.round_min = None;
        self.recent.clear();
        self.round = self.round.map(|round| Round { until: None, ..round });
    }

    /// The ACK moved to `ack` at `now`; `snd_max` is the highest sequence end
    /// sent.
    pub(crate) fn acked(&mut self, ack: u32, snd_max: u32, now: Instant) {
        let mut newest = None;
        while let Some(&(end, departed)) = self.departures.front() {
            if after(end, ack) {
                break;
            }
            self.departures.pop_front();
            newest = Some(departed);
        }
        let Some(round) = self.round.as_mut() else { return };
        if let Some(departed) = newest {
            let sample = now.saturating_duration_since(departed);
            if departed >= round.since {
                self.round_min = Some(self.round_min.map_or(sample, |min| min.min(sample)));
                round.until.get_or_insert(snd_max);
            }
            self.note_base(sample, now);
            if self.slow_start && self.queue_standing(sample) {
                return self.end_slow_start(now);
            }
        }
        let Some(round) = self.round else { return };
        if round.until.is_some_and(|until| !after(until, ack))
            && let Some(rtt) = self.round_min.take()
        {
            self.adjust(rtt);
            self.new_round(now);
        }
    }

    /// Measure afresh from `now`: what was sent before saw the old window.
    fn new_round(&mut self, now: Instant) {
        self.round = Some(Round { since: now, until: None });
        self.round_min = None;
        self.round_flight = 0;
    }

    /// Slow start ends as soon as the last [`SLOW_START_SAMPLES`] samples
    /// all show more than the target of queue: a round's minimum misses a
    /// queue a doubled window builds within the round, and by the round's
    /// end that queue is a whole window deep. Several samples, so one
    /// burst's own queue does not end it.
    fn queue_standing(&mut self, sample: Duration) -> bool {
        if self.recent.len() == SLOW_START_SAMPLES {
            self.recent.pop_front();
        }
        self.recent.push_back(sample);
        let Some(base) = self.base() else { return false };
        self.recent.len() == SLOW_START_SAMPLES
            && self.recent.iter().all(|sample| sample.saturating_sub(base) > target())
    }

    /// Leave slow start, scaling the window down by the queue the recent
    /// samples show (as a round would, but by up to four times: the last
    /// doubling may have overshot by more than two).
    fn end_slow_start(&mut self, now: Instant) {
        self.slow_start = false;
        if let (Some(base), Some(&rtt)) = (self.base(), self.recent.iter().min()) {
            let window = f64::from(self.window);
            let scaled = window * (base + target()).as_secs_f64() / rtt.as_secs_f64().max(1e-6);
            self.window = (scaled.clamp(window / 4.0, window) as u32).max(MIN_WINDOW);
        }
        self.recent.clear();
        self.new_round(now);
    }

    /// A new connection on the same 4-tuple: same path, so the base stays.
    pub(crate) fn restart(&mut self) {
        let base = std::mem::take(&mut self.base);
        *self = Self { base, ..Self::default() };
    }

    fn note_base(&mut self, sample: Duration, now: Instant) {
        match self.base.back_mut() {
            Some((start, min)) if now.saturating_duration_since(*start) < BUCKET => {
                *min = (*min).min(sample);
            }
            _ => {
                self.base.push_back((now, sample));
                if self.base.len() > BASE_BUCKETS {
                    self.base.pop_front();
                }
            }
        }
    }

    /// Set the window from a measured round's smallest sample.
    fn adjust(&mut self, rtt: Duration) {
        let Some(base) = self.base() else { return };
        let queueing = rtt.saturating_sub(base);
        // Application limited: the window did not bound the round, so the
        // round says nothing about it (another flow's queue included).
        if self.round_flight.saturating_mul(2) < self.window {
            return;
        }
        let window = f64::from(self.window);
        let next = if self.slow_start && queueing < target() / 2 {
            window * 2.0
        } else {
            self.slow_start = false;
            let scaled = window * (base + target()).as_secs_f64() / rtt.as_secs_f64().max(1e-6);
            scaled.clamp(window / 2.0, window * 2.0)
        };
        self.window = (next as u32).max(MIN_WINDOW);
        if std::env::var_os("DW_TRACE").is_some() {
            eprintln!(
                "DWTRACE {:?} rtt={:?} base={:?} flight={} ss={} -> {}",
                std::time::Instant::now(),
                rtt,
                base,
                self.round_flight,
                self.slow_start,
                self.window
            );
        }
    }
}

#[cfg(test)]
#[path = "delay_window_tests.rs"]
mod tests;

// TEMP tuning hook (removed before commit).
fn target() -> Duration {
    static T: OnceLock<Duration> = OnceLock::new();
    *T.get_or_init(|| {
        std::env::var("DW_TARGET_MS")
            .ok()
            .and_then(|v| v.parse().ok())
            .map_or(TARGET, Duration::from_millis)
    })
}
