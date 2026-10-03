//! Retry spacing after a real failure: exponential, capped and jittered.
//!
//! Every retry and reconnect loop in cmux-tui uses this type
//! (plans/cmux-next/idle-wakeups.md). A retry loop first waits for an event
//! that can make the retry succeed when one exists (a readable socket, a
//! process exit, a channel message); `Backoff` only spaces attempts after a
//! failure and is never a poll period.

use std::io;
use std::time::Duration;

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
        let mut byte = [0_u8; 2];
        let unit = match getrandom::fill(&mut byte) {
            Ok(()) => f64::from(u16::from_le_bytes(byte)) / f64::from(u16::MAX),
            Err(_) => 0.5,
        };
        let factor = 1.0 + self.jitter * (unit * 2.0 - 1.0);
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
    fn descriptor_exhaustion_needs_backoff() {
        assert!(accept_error_needs_backoff(&io::Error::from_raw_os_error(libc::EMFILE)));
        assert!(accept_error_needs_backoff(&io::Error::from_raw_os_error(libc::ENFILE)));
        assert!(!accept_error_needs_backoff(&io::Error::from(io::ErrorKind::Interrupted)));
        assert!(!accept_error_needs_backoff(&io::Error::from(io::ErrorKind::PermissionDenied)));
    }
}
