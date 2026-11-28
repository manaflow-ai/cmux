//! How long this process could not run its tasks lately: a link's silence while it was starved
//! is not the peer's (cmuxterm-hq RFD 0124, "starved is slow, never dead").
//!
//! One canary task per process sleeps [`TICK`] at a time on the daemon's runtime and records how
//! late each wake was, by the second, for the last [`KEPT`] seconds. A link's loop takes the
//! starved time over the window it was silent ([`Starved::within`]) off that silence before it
//! judges it against the budget. The loop's own late tick (`peer_runtime_io.rs`) saw only the
//! tick that ran; a host at load 187 on 15 cores (cosmic-gray, 2026-11-27) starves every tick a
//! little, which sums past a 2 s floor (cmux#54786) and dropped about 6k links in a day, each a
//! redial and a punch.

use std::sync::OnceLock;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering::Relaxed};
use std::time::{Duration, Instant};

/// How often the canary wakes.
pub const TICK: Duration = Duration::from_millis(100);
/// A wake later than this is starvation; under it, timer slack.
pub const SLACK: Duration = Duration::from_millis(20);
/// Seconds of history kept: past the silence cap (80 s) twice over.
pub const KEPT: usize = 256;

/// Starved milliseconds by the second.
pub struct Starved {
    origin: Instant,
    /// Starved milliseconds in second `epochs[i]`, at `i = second % KEPT`.
    millis: [AtomicU64; KEPT],
    epochs: [AtomicU64; KEPT],
}

impl Default for Starved {
    fn default() -> Self {
        Self::new(Instant::now())
    }
}

impl Starved {
    pub fn new(origin: Instant) -> Self {
        Self {
            origin,
            millis: std::array::from_fn(|_| AtomicU64::new(0)),
            epochs: std::array::from_fn(|_| AtomicU64::new(u64::MAX)),
        }
    }

    fn second(&self, at: Instant) -> u64 {
        at.saturating_duration_since(self.origin).as_secs()
    }

    /// A wake at `at` came `late`.
    pub fn record(&self, at: Instant, late: Duration) {
        if late <= SLACK {
            return;
        }
        let second = self.second(at);
        let i = (second % KEPT as u64) as usize;
        if self.epochs[i].swap(second, Relaxed) != second {
            self.millis[i].store(0, Relaxed);
        }
        self.millis[i].fetch_add(late.as_millis() as u64, Relaxed);
    }

    /// The time this process was starved in the `window` before `now` (to the second, one
    /// second more so a stall recorded as it ended counts), never more than the window.
    pub fn within(&self, now: Instant, window: Duration) -> Duration {
        let last = self.second(now);
        let seconds = (window.as_secs() + 1).min(KEPT as u64 - 1);
        let mut millis = 0;
        for second in last.saturating_sub(seconds)..=last {
            let i = (second % KEPT as u64) as usize;
            if self.epochs[i].load(Relaxed) == second {
                millis += self.millis[i].load(Relaxed);
            }
        }
        Duration::from_millis(millis).min(window)
    }
}

/// The process's meter.
pub fn global() -> &'static Starved {
    static METER: OnceLock<Starved> = OnceLock::new();
    METER.get_or_init(Starved::default)
}

/// Start the canary on this runtime, once per process. Outside a runtime, nothing: the meter
/// reads zero and no silence is discounted.
pub fn ensure_started() {
    static STARTED: AtomicBool = AtomicBool::new(false);
    let Ok(handle) = tokio::runtime::Handle::try_current() else { return };
    if STARTED.swap(true, Relaxed) {
        return;
    }
    handle.spawn(canary(global()));
}

/// Sleep `TICK` and record how late each wake came, by the wall clock: under a paused test
/// clock the sleeps return at once and record nothing.
pub async fn canary(meter: &'static Starved) {
    loop {
        let asked = Instant::now();
        tokio::time::sleep(TICK).await;
        let now = Instant::now();
        meter.record(now, now.saturating_duration_since(asked).saturating_sub(TICK));
    }
}

/// Whether a link silent for `silent` is past its `budget`, once the time this process could
/// not read it (its loop's late tick `late`, the process starved `starved` over the silence) is
/// taken off: the larger of the two, which overlap.
pub fn past_budget(silent: Duration, late: Duration, starved: Duration, budget: Duration) -> bool {
    silent.saturating_sub(late.max(starved)) >= budget
}

#[cfg(test)]
#[path = "peer_starved_tests.rs"]
mod tests;
