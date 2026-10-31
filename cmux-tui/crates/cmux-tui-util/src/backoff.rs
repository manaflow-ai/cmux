//! Retry spacing after a real failure: exponential, capped and jittered.
//!
//! Every retry and reconnect loop in cmux-tui uses this type
//! (plans/cmux-next/idle-wakeups.md). A retry loop first waits for an event
//! that can make the retry succeed when one exists (a readable socket, a
//! process exit, a channel message); `Backoff` only spaces attempts after a
//! failure and is never a poll period.

use std::io;
use std::time::{Duration, Instant};

#[derive(Clone, Debug)]
pub struct Backoff {
    initial: Duration,
    max: Duration,
    /// Fraction of each delay drawn at random, in 0..=1 (0.2 means ±20%).
    jitter: f64,
    attempt: u32,
}

impl Backoff {
    pub const fn new(initial: Duration, max: Duration) -> Self {
        Self { initial, max, jitter: 0.2, attempt: 0 }
    }

    pub const fn with_jitter(mut self, jitter: f64) -> Self {
        self.jitter = jitter;
        self
    }

    /// Failures since the last `reset`.
    pub fn attempts(&self) -> u32 {
        self.attempt
    }

    /// The delay before the next attempt. It doubles from `initial` up to `max`.
    pub fn next_delay(&mut self) -> Duration {
        let base = self.initial.saturating_mul(1_u32 << self.attempt.min(20)).min(self.max);
        self.attempt = self.attempt.saturating_add(1);
        if self.jitter <= 0.0 {
            return base;
        }
        let factor = 1.0 + self.jitter * (unit_random() * 2.0 - 1.0);
        base.mul_f64(factor.max(0.0)).min(self.max)
    }

    /// Sleeps `next_delay()` on the current thread.
    pub fn sleep(&mut self) {
        std::thread::sleep(self.next_delay());
    }

    /// Call after a success: the next failure starts from `initial` again.
    pub fn reset(&mut self) {
        self.attempt = 0;
    }
}

/// A uniform draw in `0..=1` (0.5 when the OS has no randomness to give).
fn unit_random() -> f64 {
    let mut bytes = [0_u8; 4];
    match getrandom::fill(&mut bytes) {
        Ok(()) => f64::from(u32::from_le_bytes(bytes)) / f64::from(u32::MAX),
        Err(_) => 0.5,
    }
}

/// A client's tries of one request after a refusal or a lost connection:
/// full-jitter exponential backoff that honours the server's retry-after,
/// inside a total budget when the caller has one. The one retry policy of
/// cmux-tui clients (rule R-L4 of the B9 limits audit): no fixed schedule, no
/// spin.
///
/// Copied from Chromium's `net::BackoffEntry` (net/base/backoff_entry.cc):
/// the delay after the n-th failure is `initial * 2^(n-1)`, clamped to
/// `maximum_backoff`, and the jitter factor is 1, so the wait is drawn
/// uniformly from `[0, delay]` (BackoffEntry: `delay -= RandDouble() *
/// jitter_factor * delay`). That "full jitter" is what spreads clients that
/// failed at the same moment.
///
/// Two differences, both on purpose:
/// - BackoffEntry takes a server's Retry-After through
///   `SetCustomReleaseTime`, and the release time is the later of the two.
///   Clients refused together get the same retry-after, so `max` sends them
///   back as one wave. Here the retry-after is a floor that the jittered delay
///   is added to.
/// - A budget ([`RetryBudget::until`]) is total: a wait that would end at or
///   past the deadline is not taken ([`RetryBudget::next_wait`] answers
///   `None`), so the caller stops at once instead of sleeping into a try it
///   cannot make. A caller that stops on a signal instead (the server is gone)
///   has none ([`RetryBudget::new`]).
#[derive(Clone, Debug)]
pub struct RetryBudget {
    initial: Duration,
    max: Duration,
    deadline: Option<Instant>,
    failures: u32,
}

impl RetryBudget {
    /// Tries with no deadline: the caller stops on a signal of its own. The
    /// first failure waits up to `initial`, each later one up to twice the
    /// last, never more than `max`.
    pub fn new(initial: Duration, max: Duration) -> Self {
        Self { initial, max, deadline: None, failures: 0 }
    }

    /// Tries that end by `deadline`, spaced as [`Self::new`]'s.
    pub fn until(initial: Duration, max: Duration, deadline: Instant) -> Self {
        Self { deadline: Some(deadline), ..Self::new(initial, max) }
    }

    /// The instant the last try must start before, when there is a budget.
    pub fn deadline(&self) -> Option<Instant> {
        self.deadline
    }

    /// Call after a success: the next failure waits up to `initial` again.
    pub fn reset(&mut self) {
        self.failures = 0;
    }

    /// The wait before the next try after a failure. `retry_after` is the
    /// server's own estimate, when it sent one. `None`: the wait would end at
    /// or past the deadline, so no further try fits the budget.
    pub fn next_wait(&mut self, retry_after: Option<Duration>) -> Option<Duration> {
        self.next_wait_drawn(retry_after, unit_random(), Instant::now())
    }

    /// Sleeps [`Self::next_wait`] on the current thread; false (and no sleep)
    /// when no further try fits the budget.
    pub fn sleep(&mut self, retry_after: Option<Duration>) -> bool {
        match self.next_wait(retry_after) {
            Some(wait) => {
                std::thread::sleep(wait);
                true
            }
            None => false,
        }
    }

    fn next_wait_drawn(
        &mut self,
        retry_after: Option<Duration>,
        unit: f64,
        now: Instant,
    ) -> Option<Duration> {
        let ceiling = self.initial.saturating_mul(1_u32 << self.failures.min(20)).min(self.max);
        self.failures = self.failures.saturating_add(1);
        let wait =
            retry_after.unwrap_or_default().saturating_add(ceiling.mul_f64(unit.clamp(0.0, 1.0)));
        match self.deadline {
            Some(deadline) => (now.checked_add(wait)? < deadline).then_some(wait),
            None => Some(wait),
        }
    }
}

/// True when an `accept` error can persist across calls, so an immediate
/// retry would fail again at once: descriptor or buffer exhaustion, or an
/// unexpected listener error. Per-connection errors (the peer went away,
/// a signal, a refused peer uid) end with that connection, and the next
/// `accept` blocks, so they need no backoff.
pub fn accept_error_needs_backoff(error: &io::Error) -> bool {
    !matches!(
        error.kind(),
        io::ErrorKind::Interrupted
            | io::ErrorKind::ConnectionAborted
            | io::ErrorKind::ConnectionReset
            | io::ErrorKind::PermissionDenied
            | io::ErrorKind::NotConnected
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn doubles_to_the_cap_and_resets() {
        let mut backoff =
            Backoff::new(Duration::from_millis(10), Duration::from_millis(50)).with_jitter(0.0);
        let delays: Vec<_> = (0..5).map(|_| backoff.next_delay().as_millis()).collect();
        assert_eq!(delays, vec![10, 20, 40, 50, 50]);
        backoff.reset();
        assert_eq!(backoff.next_delay(), Duration::from_millis(10));
    }

    #[test]
    fn jitter_stays_within_its_fraction_and_the_cap() {
        let mut backoff = Backoff::new(Duration::from_millis(100), Duration::from_secs(1));
        for _ in 0..100 {
            backoff.reset();
            let delay = backoff.next_delay();
            assert!(delay >= Duration::from_millis(80) && delay <= Duration::from_millis(120));
        }
        for _ in 0..20 {
            assert!(backoff.next_delay() <= Duration::from_secs(1));
        }
    }

    #[test]
    fn a_retry_waits_the_servers_retry_after_plus_full_jitter_doubling_to_the_cap() {
        let now = Instant::now();
        let mut retries = RetryBudget::until(
            Duration::from_millis(100),
            Duration::from_millis(300),
            now + Duration::from_secs(60),
        );
        let after = Some(Duration::from_millis(50));
        let tops: Vec<_> =
            (0..4).map(|_| retries.next_wait_drawn(after, 1.0, now).unwrap().as_millis()).collect();
        assert_eq!(tops, vec![150, 250, 350, 350]);
        let mut retries = RetryBudget::until(
            Duration::from_millis(100),
            Duration::from_secs(1),
            now + Duration::from_secs(60),
        );
        assert_eq!(retries.next_wait_drawn(after, 0.0, now), after);
        assert_eq!(retries.next_wait_drawn(None, 0.5, now), Some(Duration::from_millis(100)));
    }

    #[test]
    fn a_wait_that_ends_past_the_budget_is_not_taken() {
        let now = Instant::now();
        let mut retries = RetryBudget::until(
            Duration::from_millis(100),
            Duration::from_secs(1),
            now + Duration::from_millis(120),
        );
        assert_eq!(retries.next_wait_drawn(None, 1.0, now), Some(Duration::from_millis(100)));
        assert_eq!(retries.next_wait_drawn(None, 0.6, now), None);
        let mut retries = RetryBudget::until(
            Duration::from_millis(10),
            Duration::from_secs(1),
            now + Duration::from_millis(120),
        );
        assert_eq!(retries.next_wait_drawn(Some(Duration::from_millis(500)), 0.0, now), None);
    }

    #[test]
    fn with_no_budget_every_failure_waits_and_a_success_starts_over() {
        let now = Instant::now();
        let mut retries = RetryBudget::new(Duration::from_millis(100), Duration::from_millis(300));
        let tops: Vec<_> =
            (0..4).map(|_| retries.next_wait_drawn(None, 1.0, now).unwrap().as_millis()).collect();
        assert_eq!(tops, vec![100, 200, 300, 300]);
        retries.reset();
        assert_eq!(retries.next_wait_drawn(None, 1.0, now), Some(Duration::from_millis(100)));
    }

    #[test]
    fn clients_refused_together_spread_over_the_whole_jitter_window() {
        let now = Instant::now();
        let after = Duration::from_millis(200);
        let waits: Vec<Duration> = (0..64)
            .map(|_| {
                RetryBudget::until(
                    Duration::from_millis(100),
                    Duration::from_secs(1),
                    now + Duration::from_secs(60),
                )
                .next_wait(Some(after))
                .unwrap()
            })
            .collect();
        assert!(
            waits.iter().all(|wait| *wait >= after && *wait <= after + Duration::from_millis(100))
        );
        let spread = *waits.iter().max().unwrap() - *waits.iter().min().unwrap();
        assert!(spread >= Duration::from_millis(50), "64 draws within {spread:?}");
    }

    #[test]
    fn descriptor_exhaustion_needs_backoff() {
        assert!(accept_error_needs_backoff(&io::Error::from_raw_os_error(libc::EMFILE)));
        assert!(accept_error_needs_backoff(&io::Error::from_raw_os_error(libc::ENFILE)));
        assert!(!accept_error_needs_backoff(&io::Error::from(io::ErrorKind::Interrupted)));
        assert!(!accept_error_needs_backoff(&io::Error::from(io::ErrorKind::PermissionDenied)));
    }
}
