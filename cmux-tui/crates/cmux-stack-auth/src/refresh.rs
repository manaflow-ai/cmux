//! The refresh-token exchange's outcomes and its 429 cooldown (APIClient.swift's
//! `RefreshOutcome`, `refreshRespectingRateLimit` and `rateLimitDelaySeconds`).
//!
//! The distinction between outcomes is load-bearing: only [`RefreshOutcome::Rejected`] means the
//! refresh token will never work again, so it is the only one after which the caller may clear
//! the stored session. Every other outcome keeps it, so a network blip never signs anyone out.

use std::time::{Duration, Instant};

use crate::wire::BodyKind;

/// One refresh exchange's result.
#[derive(Clone, PartialEq)]
pub enum RefreshOutcome {
    /// Stack minted a new access token.
    Success { access_token: String },
    /// HTTP 400 or 401 (`invalid_grant`): the refresh token is dead. Clearing is correct.
    Rejected,
    /// Offline, DNS, TLS, 5xx, a redirect, an unreadable 200: not the token's fault.
    Transient,
    /// No answer by the refresh deadline: kept like a transient failure.
    TimedOut,
    /// HTTP 429: kept like a transient failure, and no exchange starts until the cooldown ends.
    RateLimited { retry_after_s: Option<f64>, body_kind: BodyKind },
}

/// Never the new token.
impl std::fmt::Debug for RefreshOutcome {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RefreshOutcome::Success { .. } => f.write_str("Success { access_token: <redacted> }"),
            RefreshOutcome::Rejected => f.write_str("Rejected"),
            RefreshOutcome::Transient => f.write_str("Transient"),
            RefreshOutcome::TimedOut => f.write_str("TimedOut"),
            RefreshOutcome::RateLimited { retry_after_s, body_kind } => f
                .debug_struct("RateLimited")
                .field("retry_after_s", retry_after_s)
                .field("body_kind", body_kind)
                .finish(),
        }
    }
}

/// Why no usable access token came back while the session was kept.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum RefreshFailure {
    Transient,
    TimedOut,
    /// Stack answered 429 to this exchange.
    RateLimited {
        retry_after_s: Option<f64>,
    },
    /// An earlier 429's cooldown is still running, so no exchange was sent.
    CoolingDown,
}

/// The longest cooldown after a 429 that named its `Retry-After`.
const MAX_RETRY_AFTER_COOLDOWN: f64 = 600.0;
/// The first cooldown with no `Retry-After`, doubled per consecutive 429 up to
/// [`MAX_BACKOFF_COOLDOWN`].
const FIRST_BACKOFF_COOLDOWN: f64 = 5.0;
const MAX_BACKOFF_COOLDOWN: f64 = 300.0;

/// When the next refresh exchange may start, after 429s. One per client (the SDK keeps one per
/// `APIClient`).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct RefreshRateLimiter {
    until: Option<Instant>,
    streak: u32,
}

impl RefreshRateLimiter {
    /// Whether an exchange at `now` must not be sent.
    pub fn cooling_down(&self, now: Instant) -> bool {
        self.until.is_some_and(|until| now < until)
    }

    /// Consecutive rate-limited exchanges.
    pub fn streak(&self) -> u32 {
        self.streak
    }

    /// Records an exchange's outcome. A 429 starts a cooldown and answers its length; a success
    /// or a rejection ends the streak; a transient failure leaves it as it was.
    pub fn record(
        &mut self,
        outcome: &RefreshOutcome,
        now: Instant,
        jitter: f64,
    ) -> Option<Duration> {
        match outcome {
            RefreshOutcome::RateLimited { retry_after_s, .. } => {
                self.streak = self.streak.saturating_add(1);
                let delay = Self::delay(*retry_after_s, self.streak, jitter);
                self.until = now.checked_add(delay);
                Some(delay)
            }
            RefreshOutcome::Success { .. } | RefreshOutcome::Rejected => {
                self.streak = 0;
                self.until = None;
                None
            }
            RefreshOutcome::Transient | RefreshOutcome::TimedOut => None,
        }
    }

    /// The cooldown after the `streak`th consecutive 429: its `Retry-After` clamped to 1 to 600 s;
    /// without one, 5 s doubled per 429 up to 300 s, scaled by `jitter` (clamped to 0.5 to 1).
    pub fn delay(retry_after_s: Option<f64>, streak: u32, jitter: f64) -> Duration {
        if let Some(seconds) = retry_after_s.filter(|s| s.is_finite()) {
            return Duration::from_secs_f64(seconds.clamp(1.0, MAX_RETRY_AFTER_COOLDOWN));
        }
        let exponent = streak.saturating_sub(1).min(6);
        let base = (FIRST_BACKOFF_COOLDOWN * 2_f64.powi(exponent.try_into().unwrap_or(6)))
            .min(MAX_BACKOFF_COOLDOWN);
        Duration::from_secs_f64(base * jitter.clamp(0.5, 1.0))
    }
}

/// A random number in [0, 1], for jitter (0.5 when the system has no randomness to give).
pub(crate) fn random_unit() -> f64 {
    let mut bytes = [0_u8; 4];
    if getrandom::fill(&mut bytes).is_err() {
        return 0.5;
    }
    f64::from(u32::from_le_bytes(bytes)) / f64::from(u32::MAX)
}

/// Jitter in [0.5, 1], the range every backoff here scales by.
pub(crate) fn random_jitter() -> f64 {
    0.5 + random_unit() / 2.0
}

#[cfg(test)]
#[path = "refresh_tests.rs"]
mod tests;
