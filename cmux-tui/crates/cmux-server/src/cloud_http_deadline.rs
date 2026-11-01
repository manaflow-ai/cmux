//! One local budget shared by authentication and every original policy stage.
use std::time::{Duration, Instant};

use cmux_link::elapsed::{Deadline, Elapsed};

#[derive(Clone)]
pub struct RequestDeadline {
    active: Instant,
    elapsed: Option<Deadline>,
}

impl RequestDeadline {
    /// Capture before any work charged to this request. Unavailable clocks fail closed.
    pub fn after(duration: Duration) -> Option<Self> {
        let elapsed = Elapsed::system()?;
        Self::with_elapsed(Instant::now(), elapsed, duration)
    }

    /// Preserve an observation captured before protected files or executor queuing.
    pub fn with_elapsed(started: Instant, elapsed: Elapsed, duration: Duration) -> Option<Self> {
        let deadline = Self {
            active: started.checked_add(duration)?,
            elapsed: Some(elapsed.deadline_at(duration)?),
        };
        deadline.remaining()?;
        Some(deadline)
    }

    pub fn active(&self) -> Instant {
        self.active
    }

    pub fn remaining(&self) -> Option<Duration> {
        let active = self.active.checked_duration_since(Instant::now())?;
        let remaining = match &self.elapsed {
            Some(elapsed) => active.min(elapsed.remaining()?),
            None => active,
        };
        (!remaining.is_zero()).then_some(remaining)
    }

    pub(super) fn elapsed(&self) -> Option<Deadline> {
        self.elapsed.clone()
    }

    /// Preserve legacy active-clock callers on unsupported systems, while
    /// failing closed on clock failure where a continuous clock is supported.
    pub(super) fn from_active(active: Instant) -> Option<Self> {
        #[cfg(any(target_os = "linux", target_vendor = "apple"))]
        let elapsed = {
            let source = Elapsed::system()?;
            Some(source.deadline_at(active.checked_duration_since(Instant::now())?)?)
        };
        #[cfg(not(any(target_os = "linux", target_vendor = "apple")))]
        let elapsed = None;
        let deadline = Self { active, elapsed };
        deadline.remaining()?;
        Some(deadline)
    }
}
