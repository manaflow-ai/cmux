//! Periodic loss (RFD 0142 O5): some links lose datagrams on a schedule. A
//! satellite link reconfigures every 15 s, and a cell may hand over or
//! rescan on a timer. Each time, Auto ([`crate::ultra_auto`]) turns repair on
//! only at the first loss, so that first loss of every burst is unprotected
//! whenever Auto turned off in between (a period longer than its hold).
//!
//! [`LossPeriod`] keeps the times losses began ("onsets": a loss after
//! [`ONSET_QUIET`] without one), and when the gaps between them are whole
//! multiples of one period, within [`TOLERANCE`], it says when the next onset
//! is due. Auto then sends repair from [`LEAD`] before that time to [`TAIL`]
//! after it. A missed burst (no traffic crossed it) is a skipped multiple,
//! not a broken pattern. After [`FORGET_PERIODS`] periods with no onset the
//! prediction lapses, so a link whose loss stopped returns to sending nothing
//! extra.
//!
//! It needs no timer of its own: Auto is asked before every send pass, so
//! the window opens at the first send inside it, and a quiet link sends
//! nothing either way.

use std::collections::VecDeque;
use std::time::Duration;

use tokio::time::Instant;

/// A loss this long after the previous one begins a new burst.
pub(crate) const ONSET_QUIET: Duration = Duration::from_secs(3);
/// The shortest period learned. Shorter than Auto's hold, Auto never turns
/// off between bursts and needs no prediction, but learning it does no harm
/// and keeps the window right when the hold is shortened.
pub(crate) const PERIOD_MIN: Duration = Duration::from_secs(5);
/// The longest period learned.
pub(crate) const PERIOD_MAX: Duration = Duration::from_secs(120);
/// How far one onset may sit from the period's grid and still fit it: a
/// burst is seen at the first datagram after it begins, which on a sparse
/// link (typing, keepalives) is up to a few hundred ms late.
pub(crate) const TOLERANCE: Duration = Duration::from_millis(500);
/// Repair turns on this long before the predicted onset: the fit's error plus
/// a round trip for the hello that tells the peer.
pub(crate) const LEAD: Duration = Duration::from_secs(1);
/// And stays on this long after it, past a burst seen late.
pub(crate) const TAIL: Duration = Duration::from_secs(2);
/// Periods with no onset after which the prediction lapses.
pub(crate) const FORGET_PERIODS: u32 = 8;
/// Onsets kept.
const KEPT: usize = 6;
/// The most periods one gap between onsets may span (bursts no traffic saw).
const MULTIPLE_MAX: u32 = 8;

/// The learned period of a link's loss, if it has one.
#[derive(Debug, Default)]
pub(crate) struct LossPeriod {
    onsets: VecDeque<Instant>,
    period: Option<Duration>,
    last_loss: Option<Instant>,
}

impl LossPeriod {
    /// A loss at `now`. Returns true when it began a burst.
    pub(crate) fn loss(&mut self, now: Instant) -> bool {
        let onset =
            self.last_loss.is_none_or(|at| now.saturating_duration_since(at) >= ONSET_QUIET);
        self.last_loss = Some(now);
        if onset {
            if self.onsets.len() == KEPT {
                self.onsets.pop_front();
            }
            self.onsets.push_back(now);
            self.fit();
        }
        onset
    }

    /// The last onset was reordering, not loss: forget it.
    pub(crate) fn retract(&mut self) {
        self.onsets.pop_back();
        self.fit();
    }

    /// The learned period.
    #[cfg(test)]
    pub(crate) fn period(&self) -> Option<Duration> {
        self.period
    }

    /// Whether `now` is inside a predicted burst's window.
    pub(crate) fn armed(&self, now: Instant) -> bool {
        let (Some(period), Some(&last)) = (self.period, self.onsets.back()) else {
            return false;
        };
        let since = now.saturating_duration_since(last);
        if since > period * FORGET_PERIODS {
            return false;
        }
        let phase = Duration::from_nanos((since.as_nanos() % period.as_nanos()) as u64);
        phase + LEAD >= period || (since >= period && phase <= TAIL)
    }

    /// Fit one period to the kept onsets, dropping the oldest until the rest
    /// agree (a pattern that changed). At least three onsets, two gaps.
    fn fit(&mut self) {
        self.period = None;
        while self.onsets.len() >= 3 {
            if let Some(period) = fit_period(&self.onsets) {
                self.period = Some(period);
                return;
            }
            self.onsets.pop_front();
        }
    }
}

fn fit_period(onsets: &VecDeque<Instant>) -> Option<Duration> {
    let gaps: Vec<Duration> = onsets
        .iter()
        .zip(onsets.iter().skip(1))
        .map(|(a, b)| b.saturating_duration_since(*a))
        .collect();
    let base = *gaps.iter().min()?;
    if base < PERIOD_MIN.saturating_sub(TOLERANCE) {
        return None;
    }
    let mut total = Duration::ZERO;
    let mut periods = 0u32;
    for gap in &gaps {
        let multiple = (gap.as_secs_f64() / base.as_secs_f64()).round() as u32;
        if multiple == 0 || multiple > MULTIPLE_MAX {
            return None;
        }
        let expected = base * multiple;
        let off = gap.abs_diff(expected);
        if off > TOLERANCE {
            return None;
        }
        total += *gap;
        periods += multiple;
    }
    let period = total / periods;
    (PERIOD_MIN..=PERIOD_MAX).contains(&period).then_some(period)
}

#[cfg(test)]
#[path = "ultra_period_tests.rs"]
mod tests;
