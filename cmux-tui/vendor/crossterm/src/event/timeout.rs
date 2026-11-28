use std::time::{Duration, Instant};

/// Keeps track of the elapsed time since the moment the polling started.
#[derive(Debug, Clone)]
pub struct PollTimeout {
    timeout: Option<Duration>,
    start: Instant,
}

impl PollTimeout {
    /// Constructs a new `PollTimeout` with the given optional `Duration`.
    pub fn new(timeout: Option<Duration>) -> PollTimeout {
        PollTimeout { timeout, start: Instant::now() }
    }

    /// Returns whether the timeout has elapsed.
    ///
    /// It always returns `false` if the initial timeout was set to `None`.
    pub fn elapsed(&self) -> bool {
        self.timeout.map(|timeout| self.start.elapsed() >= timeout).unwrap_or(false)
    }

    /// Returns the timeout leftover (initial timeout duration - elapsed duration).
    pub fn leftover(&self) -> Option<Duration> {
        self.timeout.map(|timeout| {
            let elapsed = self.start.elapsed();

            if elapsed >= timeout {
                Duration::from_secs(0)
            } else {
                timeout - elapsed
            }
        })
    }
}

#[cfg(test)]
#[path = "timeout_tests.rs"]
mod tests;
