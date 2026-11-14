//! When to reconnect after a session ends (pure; the caller owns the clock).

use std::time::Duration;

/// Sessions in a row that may end in a protocol error before the viewer
/// stops retrying: a server that keeps sending what this client refuses
/// would otherwise be reconnected to forever.
const MAX_PROTOCOL_FAILURES: u32 = 3;

/// Exponential backoff that resets only once a session has lived long
/// enough to count as healthy (a server that accepts and then drops every
/// connection still backs off). An authentication failure never retries:
/// the same credentials cannot succeed, so the viewer asks the person
/// instead; repeated protocol errors stop too.
#[derive(Debug, Clone)]
pub struct Backoff {
    first: Duration,
    max: Duration,
    healthy_after: Duration,
    next: Duration,
    protocol_failures: u32,
}

impl Default for Backoff {
    fn default() -> Self {
        Self::new(Duration::from_millis(250), Duration::from_secs(10), Duration::from_secs(10))
    }
}

impl Backoff {
    pub fn new(first: Duration, max: Duration, healthy_after: Duration) -> Self {
        Self { first, max, healthy_after, next: first, protocol_failures: 0 }
    }

    /// The delay before the next attempt, after a session (or a connection
    /// attempt) that lasted `lived` ended with `error`. `None`: do not retry.
    pub fn after_failure(&mut self, lived: Duration, error: &crate::VncError) -> Option<Duration> {
        if error.is_auth() {
            return None;
        }
        if lived >= self.healthy_after {
            self.next = self.first;
            self.protocol_failures = 0;
        }
        if matches!(error, crate::VncError::Protocol(_)) {
            self.protocol_failures += 1;
            if self.protocol_failures >= MAX_PROTOCOL_FAILURES {
                return None;
            }
        }
        let delay = self.next;
        self.next = (self.next * 2).min(self.max);
        Some(delay)
    }

    /// The person asked to reconnect: start over from the first delay.
    pub fn reset(&mut self) {
        self.next = self.first;
        self.protocol_failures = 0;
    }
}

#[cfg(test)]
mod tests;
