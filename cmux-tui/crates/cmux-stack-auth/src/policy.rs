//! The sign-in flow's pure policies: its bounded retry after a 429 (AuthRateLimit.swift) and its
//! per-phase deadlines (AuthTimeouts.swift).

use std::time::Duration;

use crate::error::StackError;
use crate::wire::BodyKind;

/// A 429 from the sign-in service, recognized on a call's error, and the bounded retry policy
/// the sign-in flow uses after one.
#[derive(Clone, Debug, PartialEq)]
pub struct SignInRateLimit {
    /// The server's `Retry-After`, when it sent one.
    pub retry_after: Option<Duration>,
    /// The answered path with ids replaced by `ID`, for telemetry.
    pub endpoint: String,
    /// Whether the API (`json`) or an edge page (`html`) answered.
    pub body_kind: BodyKind,
}

impl SignInRateLimit {
    /// Retries the sign-in flow makes after a 429 before it shows a failure.
    pub const MAXIMUM_RETRIES: u32 = 6;

    /// The longest single wait: a larger `Retry-After` is clamped to this, so the pane never
    /// waits silently for many minutes.
    pub const MAXIMUM_DELAY: Duration = Duration::from_secs(120);

    /// The rate limit `error` reports, or `None` for any other error.
    pub fn from_error(error: &StackError) -> Option<Self> {
        match error {
            StackError::RateLimited(limit) => Some(SignInRateLimit {
                retry_after: limit
                    .retry_after_s
                    .filter(|s| s.is_finite() && *s >= 0.0)
                    .map(|s| Duration::from_secs_f64(s.min(86_400.0))),
                endpoint: limit.endpoint.clone(),
                body_kind: limit.body_kind,
            }),
            StackError::Known { code, .. } if code.eq_ignore_ascii_case("RATE_LIMIT") => {
                Some(SignInRateLimit {
                    retry_after: None,
                    endpoint: "/unknown".to_owned(),
                    body_kind: BodyKind::Other,
                })
            }
            _ => None,
        }
    }

    /// The wait before retry number `retry` (1-based). Honors `Retry-After` (clamped to 1 s to
    /// [`Self::MAXIMUM_DELAY`]); without it, 2 s doubled per retry up to 60 s, scaled by `jitter`
    /// (clamped to 0.5 to 1) so many Macs behind one IP spread out.
    pub fn delay(retry_after: Option<Duration>, retry: u32, jitter: f64) -> Duration {
        if let Some(retry_after) = retry_after {
            return retry_after.clamp(Duration::from_secs(1), Self::MAXIMUM_DELAY);
        }
        let exponent = retry.saturating_sub(1).min(5);
        let base = (2.0 * 2_f64.powi(exponent.try_into().unwrap_or(5))).min(60.0);
        Duration::from_secs_f64(base * jitter.clamp(0.5, 1.0))
    }
}

/// Per-phase deadlines for the sign-in and session flows. Every phase that holds a visible
/// loading state is raced against one, so no flow leaves the UI spinning forever.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AuthTimeouts {
    /// Flows with interactive system auth UI (the browser sheet): generous, since the person may
    /// be typing a password or doing 2FA; it ends the "callback never fires" hang.
    pub interactive_flow: Duration,
    /// Non-interactive backend calls (magic-link send and verify, credential sign-in, user fetch,
    /// session validation, team list). Above the 30 s per-request timeout, so it fires only when
    /// retries stack up or a call wedges.
    pub network: Duration,
    /// Launch session restore: it blocks the first screen, so it fails open to the cached session
    /// sooner than the network budget.
    pub session_restore: Duration,
}

impl AuthTimeouts {
    /// `session_restore` defaults to `network`, as the Swift initializer's does.
    pub fn new(
        interactive_flow: Duration,
        network: Duration,
        session_restore: Option<Duration>,
    ) -> Self {
        AuthTimeouts {
            interactive_flow,
            network,
            session_restore: session_restore.unwrap_or(network),
        }
    }
}

/// The production table: 300 s interactive, 60 s network, 8 s launch restore.
impl Default for AuthTimeouts {
    fn default() -> Self {
        AuthTimeouts::new(
            Duration::from_secs(300),
            Duration::from_secs(60),
            Some(Duration::from_secs(8)),
        )
    }
}

#[cfg(test)]
#[path = "policy_tests.rs"]
mod tests;
