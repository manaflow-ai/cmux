//! One deadline for a whole operation, from one monotonic start, that every layer under it takes
//! its timeout from. A port of leo-workspace `tools/deadline.py`, under the same names.
//!
//! Why: each layer adding its own margin to the one below (`timeout = wait + 600`) and a loop
//! starting each try with a fresh budget made a stalled transport run 840 s and then 660 s, 25
//! minutes against a 15-minute bound (hq#8876, cmux#40530, cmux#40574). In cmux Remote and Cloud
//! the same shape is a retry loop that never ends and never says so (design
//! `remote-cloud-durability.md` 4.3, handbook `wait-with-no-deadline`).
//!
//! The rule: declare the bound once, as a [`Deadline`], where the operation starts. Every socket
//! wait, child process, retry and step under it takes its timeout from that deadline
//! ([`Deadline::timeout`], or [`Deadline::sub`] for a step with its own smaller cap), never
//! `x + const` per layer: a retry loop then ends when the one deadline does, however many tries it
//! makes. `tests/no_fresh_timeout.rs` fails on a `timeout = <expr> + <const>` in a file that uses
//! this type.
//!
//! The clock is the instant type: `std::time::Instant` by default, `tokio::time::Instant` with the
//! `tokio` feature (so a paused test clock moves it). Every method also has an `_at(now)` form
//! for a caller that already read the clock.

mod progress;

use std::ops::Add;
use std::time::Duration;

pub use progress::{IdleDeadline, Progress, Stalled};
#[cfg(feature = "tokio")]
pub use progress::{ProgressIo, progress_timeout};

/// A monotonic instant a [`Deadline`] can be measured on.
pub trait Clock: Copy + Ord + Add<Duration, Output = Self> {
    fn now() -> Self;
    /// `self + duration`, or None past the clock's range.
    fn checked_add(self, duration: Duration) -> Option<Self>;
    fn saturating_duration_since(self, earlier: Self) -> Duration;
}

impl Clock for std::time::Instant {
    fn now() -> Self {
        std::time::Instant::now()
    }
    fn checked_add(self, duration: Duration) -> Option<Self> {
        std::time::Instant::checked_add(&self, duration)
    }
    fn saturating_duration_since(self, earlier: Self) -> Duration {
        std::time::Instant::saturating_duration_since(&self, earlier)
    }
}

#[cfg(feature = "tokio")]
impl Clock for tokio::time::Instant {
    fn now() -> Self {
        tokio::time::Instant::now()
    }
    fn checked_add(self, duration: Duration) -> Option<Self> {
        tokio::time::Instant::checked_add(&self, duration)
    }
    fn saturating_duration_since(self, earlier: Self) -> Duration {
        tokio::time::Instant::saturating_duration_since(&self, earlier)
    }
}

/// About 30 years: what a deadline past the clock's range is clamped to.
const FAR: Duration = Duration::from_secs(30 * 365 * 86_400);

/// A deadline `bound` after its start (read once, when it is made).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Deadline<I: Clock = std::time::Instant> {
    start: I,
    end: I,
}

impl<I: Clock> Deadline<I> {
    /// A deadline `bound` from now.
    pub fn after(bound: Duration) -> Self {
        Self::starting(I::now(), bound)
    }

    /// A deadline `bound` after `start`.
    pub fn starting(start: I, bound: Duration) -> Self {
        Self { start, end: end_of(start, bound) }
    }

    /// When it started.
    pub fn start(&self) -> I {
        self.start
    }

    /// When it ends: what a `sleep_until` waits for.
    pub fn end(&self) -> I {
        self.end
    }

    /// Time left, never negative.
    pub fn remaining(&self) -> Duration {
        self.remaining_at(I::now())
    }

    pub fn remaining_at(&self, now: I) -> Duration {
        self.end.saturating_duration_since(now)
    }

    pub fn elapsed(&self) -> Duration {
        self.elapsed_at(I::now())
    }

    pub fn elapsed_at(&self, now: I) -> Duration {
        now.saturating_duration_since(self.start)
    }

    pub fn expired(&self) -> bool {
        self.expired_at(I::now())
    }

    pub fn expired_at(&self, now: I) -> bool {
        now >= self.end
    }

    /// A child deadline ending at the earlier of this one's end and now + `cap`: a step's own cap
    /// never outlives its parent.
    pub fn sub(&self, cap: Duration) -> Self {
        self.sub_at(I::now(), cap)
    }

    pub fn sub_at(&self, now: I, cap: Duration) -> Self {
        Self { start: now, end: end_of(now, cap).min(self.end) }
    }

    /// A socket or child timeout: what is left less `reserve` (kept for the caller's own step
    /// after it), at most `cap`, and at least `floor`, so a call is never handed zero (which some
    /// APIs read as "no wait" or "no limit"). The floor is the most one call can run past the
    /// deadline.
    pub fn timeout(&self, cap: Option<Duration>, floor: Duration, reserve: Duration) -> Duration {
        self.timeout_at(I::now(), cap, floor, reserve)
    }

    pub fn timeout_at(
        &self,
        now: I,
        cap: Option<Duration>,
        floor: Duration,
        reserve: Duration,
    ) -> Duration {
        let mut left = self.remaining_at(now).saturating_sub(reserve);
        if let Some(cap) = cap {
            left = left.min(cap);
        }
        left.max(floor)
    }
}

fn end_of<I: Clock>(start: I, bound: Duration) -> I {
    start.checked_add(bound).unwrap_or_else(|| start + FAR)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Instant;

    const S: fn(u64) -> Duration = Duration::from_secs;

    #[test]
    fn remaining_counts_down_and_never_goes_negative() {
        let t0 = Instant::now();
        let d = Deadline::starting(t0, S(60));
        assert_eq!(d.remaining_at(t0), S(60));
        assert_eq!(d.remaining_at(t0 + S(45)), S(15));
        assert_eq!(d.remaining_at(t0 + S(90)), Duration::ZERO);
        assert!(!d.expired_at(t0 + S(59)));
        assert!(d.expired_at(t0 + S(60)));
        assert_eq!(d.elapsed_at(t0 + S(7)), S(7));
    }

    /// A step's cap never outlives its parent; a short cap ends first.
    #[test]
    fn sub_ends_at_the_earlier_of_its_cap_and_the_parent() {
        let t0 = Instant::now();
        let d = Deadline::starting(t0, S(60));
        assert_eq!(d.sub_at(t0 + S(50), S(30)).end(), d.end());
        assert_eq!(d.sub_at(t0 + S(10), S(5)).end(), t0 + S(15));
        assert_eq!(d.sub_at(t0 + S(10), S(5)).start(), t0 + S(10));
    }

    #[test]
    fn timeout_keeps_the_reserve_obeys_the_cap_and_never_hands_out_zero() {
        let t0 = Instant::now();
        let d = Deadline::starting(t0, S(60));
        assert_eq!(d.timeout_at(t0, None, S(1), S(10)), S(50));
        assert_eq!(d.timeout_at(t0, Some(S(5)), S(1), Duration::ZERO), S(5));
        assert_eq!(d.timeout_at(t0 + S(120), None, S(1), Duration::ZERO), S(1));
    }

    /// The bug the type exists for: a retry loop of 10 s tries under one 25 s deadline makes three
    /// tries and ends on time, where a fresh budget per try would go on.
    #[test]
    fn a_retry_loop_under_one_deadline_ends_when_it_does() {
        let t0 = Instant::now();
        let d = Deadline::starting(t0, S(25));
        let mut now = t0;
        let mut tries = 0;
        while !d.expired_at(now) {
            let step = d.timeout_at(now, Some(S(10)), Duration::from_millis(1), Duration::ZERO);
            now += step;
            tries += 1;
        }
        assert_eq!((tries, now), (3, t0 + S(25)));
    }

    #[test]
    fn a_bound_past_the_clock_is_clamped_not_a_panic() {
        let d = Deadline::<Instant>::after(Duration::MAX);
        assert!(!d.expired());
        assert!(d.remaining() > S(86_400));
    }

    #[cfg(feature = "tokio")]
    #[tokio::test(start_paused = true)]
    async fn a_paused_tokio_clock_moves_a_tokio_deadline() {
        let d = Deadline::<tokio::time::Instant>::after(S(30));
        tokio::time::advance(S(20)).await;
        assert_eq!(d.remaining(), S(10));
        tokio::time::advance(S(20)).await;
        assert!(d.expired());
    }
}
