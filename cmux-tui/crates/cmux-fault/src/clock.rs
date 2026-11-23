//! `clock-jump`: a wall clock that runs on tokio's clock and jumps when a scenario says so, while
//! monotonic time ([`tokio::time::Instant`]) does not. On a paused tokio clock (the carrier
//! simulation's) it advances with simulated time; on a running one, with real time. A paused
//! Cloud VM that resumes is exactly this: its monotonic clock stood still, its wall clock is set
//! forward (`cmux-remote` `relay_liveness.rs` `ClockWatch` reads the two).

use std::sync::Arc;
use std::sync::atomic::{AtomicI64, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use tokio::time::Instant;

use crate::trace::Trace;

#[derive(Clone)]
pub struct WallClock {
    base: SystemTime,
    started: Instant,
    /// Milliseconds the wall clock was jumped by, in total (negative: set back).
    jumped_ms: Arc<AtomicI64>,
    trace: Trace,
}

impl WallClock {
    /// Starts at the real wall clock's time.
    pub fn new(trace: &Trace) -> Self {
        Self::starting_at(SystemTime::now(), trace)
    }

    pub fn starting_at(base: SystemTime, trace: &Trace) -> Self {
        Self { base, started: Instant::now(), jumped_ms: Arc::default(), trace: trace.clone() }
    }

    pub fn now(&self) -> SystemTime {
        let at = self.base + self.started.elapsed();
        let jumped = self.jumped_ms.load(Ordering::SeqCst);
        if jumped >= 0 {
            at + Duration::from_millis(jumped as u64)
        } else {
            at - Duration::from_millis(jumped.unsigned_abs())
        }
    }

    /// Whole unix seconds (a relay ticket's unit).
    pub fn unix_seconds(&self) -> u64 {
        self.now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs()
    }

    /// Unix seconds, rounded up: a ticket issued then is valid for at least its stated lifetime.
    pub fn unix_seconds_ceil(&self) -> u64 {
        let since = self.now().duration_since(UNIX_EPOCH).unwrap_or_default();
        since.as_secs() + u64::from(since.subsec_nanos() > 0)
    }

    pub fn jump_forward(&self, by: Duration) {
        self.trace.note(format!("fault clock-jump +{} s", by.as_secs_f64()));
        self.jumped_ms.fetch_add(by.as_millis() as i64, Ordering::SeqCst);
    }

    pub fn jump_back(&self, by: Duration) {
        self.trace.note(format!("fault clock-jump -{} s", by.as_secs_f64()));
        self.jumped_ms.fetch_sub(by.as_millis() as i64, Ordering::SeqCst);
    }
}

#[cfg(test)]
mod tests {
    use super::WallClock;
    use crate::trace::Trace;
    use std::time::{Duration, UNIX_EPOCH};

    #[tokio::test(start_paused = true)]
    async fn the_wall_clock_jumps_and_monotonic_time_does_not() {
        let clock = WallClock::starting_at(UNIX_EPOCH + Duration::from_secs(1_000), &Trace::new());
        let mono = tokio::time::Instant::now();
        tokio::time::sleep(Duration::from_millis(1_500)).await;
        assert_eq!(clock.unix_seconds(), 1_001);
        assert_eq!(clock.unix_seconds_ceil(), 1_002);
        clock.jump_forward(Duration::from_secs(7_200));
        assert_eq!(clock.unix_seconds(), 8_201);
        assert_eq!(mono.elapsed(), Duration::from_millis(1_500));
        clock.jump_back(Duration::from_secs(7_200));
        assert_eq!(clock.unix_seconds(), 1_001);
    }
}
