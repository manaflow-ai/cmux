//! When to reconnect after a session ends (pure; the caller owns the clock).

use std::time::Duration;

/// Exponential backoff that resets once a session has lived long enough to
/// count as healthy. An authentication failure never retries: the same
/// credentials cannot succeed, so the viewer asks the person instead.
#[derive(Debug, Clone)]
pub struct Backoff {
    first: Duration,
    max: Duration,
    healthy_after: Duration,
    next: Duration,
}

impl Default for Backoff {
    fn default() -> Self {
        Self::new(Duration::from_millis(250), Duration::from_secs(10), Duration::from_secs(10))
    }
}

impl Backoff {
    pub fn new(first: Duration, max: Duration, healthy_after: Duration) -> Self {
        Self { first, max, healthy_after, next: first }
    }

    /// The delay before the next attempt, after a session (or a connection
    /// attempt) that lasted `lived` ended with `error`. `None`: do not retry.
    pub fn after_failure(&mut self, lived: Duration, error: &crate::VncError) -> Option<Duration> {
        if error.is_auth() {
            return None;
        }
        if lived >= self.healthy_after {
            self.next = self.first;
        }
        let delay = self.next;
        self.next = (self.next * 2).min(self.max);
        Some(delay)
    }

    /// A session connected; the next failure starts from the first delay
    /// only if this session then lives long enough.
    pub fn reset(&mut self) {
        self.next = self.first;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::VncError;

    fn io() -> VncError {
        VncError::Io(std::io::Error::from(std::io::ErrorKind::ConnectionRefused))
    }

    #[test]
    fn backoff_doubles_caps_and_resets_after_a_healthy_session() {
        let mut backoff = Backoff::default();
        let quick = Duration::from_millis(5);
        let delays: Vec<_> = (0..8).map(|_| backoff.after_failure(quick, &io()).unwrap()).collect();
        assert_eq!(delays[0], Duration::from_millis(250));
        assert_eq!(delays[1], Duration::from_millis(500));
        assert_eq!(delays[6], Duration::from_secs(10));
        assert_eq!(delays[7], Duration::from_secs(10));
        assert_eq!(
            backoff.after_failure(Duration::from_secs(60), &io()).unwrap(),
            Duration::from_millis(250)
        );
    }

    #[test]
    fn auth_failures_never_retry() {
        let mut backoff = Backoff::default();
        assert_eq!(backoff.after_failure(Duration::ZERO, &VncError::AuthFailed("no".into())), None);
        assert_eq!(
            backoff
                .after_failure(Duration::ZERO, &VncError::CredentialsRequired { username: false }),
            None
        );
    }
}
