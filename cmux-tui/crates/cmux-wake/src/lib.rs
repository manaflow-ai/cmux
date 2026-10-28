//! Wakes cmux's Rust processes share: the daemon through
//! `cmux_tui_core::wake`, acpmux directly.
//!
//! - [`deadline`]: the window a one-shot delayed wake may fire in, so that
//!   deadlines close to each other share one wake. The table is the app's
//!   `WakeLeeway` (CmuxNextWakeups), which follows Chromium's delay policy
//!   (`base/task/delay_policy.h`) and `kAlignWakeUps` (`base/message_pump.cc`,
//!   `AdjustDelayedRunTime`), with 10% leeway on a whole-second grid from 1 s
//!   on. Durability deadlines (output store flush and snapshot, journal
//!   checkpoint and maintenance) are one-shot deadlines of this kind.
//! - [`EnergyMode`]: whether Energy Saver is on for this process, and who to
//!   tell when it changes.
//! - [`MaintenanceClock`]: one thread per process that runs periodic
//!   maintenance on a 5-minute wall-clock grid with a leeway the kernel sees.
//! - [`PowerSource`]: the power inputs that thread follows on macOS, so the
//!   daemon reads AC, battery, the charge, Low Power Mode and the thermal
//!   state itself.
//!
//! The grid is [`Ticks`]: `CLOCK_UPTIME_RAW` on macOS (the origin of the app's
//! queue and of Chromium's `TimeTicks`), `CLOCK_MONOTONIC` on other Unix
//! systems. A boundary is then the same instant for the daemon and the app,
//! and their wakes on it coincide.

mod energy;
mod maintenance;
mod power;

use std::time::Duration;

pub use energy::{EnergyMode, EnergyWatch};
pub use maintenance::{JobSpec, MaintenanceClock, Placement, RegisterError};
pub use power::{PowerReading, PowerSource, Thermal};

/// Chromium's `kDefaultLeeway` on macOS: the leeway and grid of a flexible
/// delay below 1 s (`base/task/task_features.cc`).
pub const DEFAULT_ALIGNMENT: Duration = Duration::from_millis(8);
/// The leeway and grid of a flexible delay below 1 s in Energy Saver
/// (Chromium's `kBatterySaverModeAlignWakeUps`, 32 ms).
pub const SAVER_ALIGNMENT: Duration = Duration::from_millis(32);
/// The longest delay that stays precise, "slightly above 30Hz timer"
/// (`kDefaultMaxPreciseDelay`, `base/task/task_features.cc`).
pub const MAX_PRECISE_DELAY: Duration = Duration::from_millis(36);
/// From this delay on, the grid is one second and the leeway 10% of the delay.
pub const WHOLE_SECOND_DELAY: Duration = Duration::from_secs(1);
/// The largest leeway [`deadline`] gives.
pub const MAX_LEEWAY: Duration = Duration::from_secs(1);

/// How strictly a delayed wake honors its deadline (Chromium's
/// `subtle::DelayPolicy`, `base/task/delay_policy.h`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Policy {
    /// Never before the deadline, at most the leeway after it
    /// (`kFlexibleNoSooner`). Debounces, timeouts and flushes use this.
    FlexibleNoSooner,
    /// At most the leeway before the deadline, never after it
    /// (`kFlexiblePreferEarly`): a lease renewal.
    FlexiblePreferEarly,
    /// Exactly at the deadline (`kPrecise`). Only below
    /// [`MAX_PRECISE_DELAY`]; a longer precise delay is flexible.
    Precise,
}

impl Policy {
    /// The policy that applies to `delay` (Chromium's
    /// `MaybeOverrideDelayPolicy`): zero is due now and exact; a precise
    /// delay of 36 ms or more becomes [`Policy::FlexibleNoSooner`].
    pub fn effective(self, delay: Duration) -> Self {
        if delay.is_zero() {
            Self::Precise
        } else if self == Self::Precise && delay >= MAX_PRECISE_DELAY {
            Self::FlexibleNoSooner
        } else {
            self
        }
    }
}

/// An instant on the process's monotonic clock in nanoseconds: the
/// alignment grid of [`deadline`].
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Ticks(pub u64);

impl Ticks {
    /// Now on the grid clock.
    pub fn now() -> Self {
        Self(clock::now_ns())
    }

    /// `self + delay`, saturating.
    pub fn after(self, delay: Duration) -> Self {
        Self(self.0.saturating_add(nanos(delay)))
    }

    /// The time from `now` until `self`; zero when `self` is not after `now`.
    pub fn since(self, now: Ticks) -> Duration {
        Duration::from_nanos(self.0.saturating_sub(now.0))
    }
}

/// The window one delayed wake may fire in.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Deadline {
    /// The policy after [`Policy::effective`].
    pub policy: Policy,
    /// How far from the deadline the wake may move: after it for
    /// [`Policy::FlexibleNoSooner`], before it for
    /// [`Policy::FlexiblePreferEarly`], zero for [`Policy::Precise`].
    pub leeway: Duration,
    /// The first instant the wake may fire.
    pub earliest: Ticks,
    /// The last instant the wake may fire.
    pub latest: Ticks,
    /// The instant it fires when nothing else shares it: the first grid
    /// boundary at or after `earliest`, never after `latest` (Chromium's
    /// `std::min(aligned, latest_time)`).
    pub fire: Ticks,
}

impl Deadline {
    /// The relative wait from `now` until [`Deadline::fire`], for a timed
    /// receive or an async sleep.
    pub fn wait_from(&self, now: Ticks) -> Duration {
        self.fire.since(now)
    }
}

/// The window of a wake `delay` after `now`, on the 8 ms grid. In Energy
/// Saver use [`EnergyMode::deadline`], which takes the 32 ms grid.
///
/// | delay, policy                         | leeway          | grid          |
/// |---------------------------------------|-----------------|---------------|
/// | 0, or precise below 36 ms             | 0               | none (exact)  |
/// | below 1 s, flexible or precise 36 ms+ | alignment       | alignment     |
/// | 1 s or more                           | min(10%, 1 s)   | whole second  |
pub fn deadline(now: Ticks, delay: Duration, policy: Policy) -> Deadline {
    deadline_aligned(now, delay, policy, DEFAULT_ALIGNMENT)
}

/// [`deadline`] with the sub-second grid `alignment` (8 ms, or 32 ms in
/// Energy Saver; zero reads as 8 ms).
pub fn deadline_aligned(
    now: Ticks,
    delay: Duration,
    policy: Policy,
    alignment: Duration,
) -> Deadline {
    let policy = policy.effective(delay);
    let target = now.after(delay);
    let (leeway, grid) = match policy {
        Policy::Precise => (Duration::ZERO, Duration::ZERO),
        _ if delay >= WHOLE_SECOND_DELAY => ((delay / 10).min(MAX_LEEWAY), WHOLE_SECOND_DELAY),
        _ => {
            let step = if alignment.is_zero() { DEFAULT_ALIGNMENT } else { alignment };
            (step, step)
        }
    };
    let (earliest, latest) = match policy {
        Policy::Precise => (target, target),
        Policy::FlexibleNoSooner => (target, target.after(leeway)),
        Policy::FlexiblePreferEarly => (Ticks(target.0.saturating_sub(nanos(leeway))), target),
    };
    let step = nanos(grid);
    let fire = if step == 0 {
        earliest
    } else {
        let remainder = earliest.0 % step;
        let aligned =
            if remainder == 0 { earliest.0 } else { earliest.0.saturating_add(step - remainder) };
        Ticks(aligned.min(latest.0))
    };
    Deadline { policy, leeway, earliest, latest, fire }
}

fn nanos(duration: Duration) -> u64 {
    u64::try_from(duration.as_nanos()).unwrap_or(u64::MAX)
}

#[cfg(unix)]
mod clock {
    #[cfg(target_os = "macos")]
    const GRID_CLOCK: libc::clockid_t = libc::CLOCK_UPTIME_RAW;
    #[cfg(not(target_os = "macos"))]
    const GRID_CLOCK: libc::clockid_t = libc::CLOCK_MONOTONIC;

    pub(super) fn now_ns() -> u64 {
        let mut now = libc::timespec { tv_sec: 0, tv_nsec: 0 };
        // SAFETY: `now` is a valid, writable timespec; the clock id is one
        // every supported kernel has, so the call cannot fail.
        unsafe { libc::clock_gettime(GRID_CLOCK, &mut now) };
        let seconds = u64::try_from(now.tv_sec).unwrap_or(0);
        let nanos = u64::try_from(now.tv_nsec).unwrap_or(0);
        seconds.saturating_mul(1_000_000_000).saturating_add(nanos)
    }
}

#[cfg(not(unix))]
mod clock {
    use std::sync::OnceLock;
    use std::time::Instant;

    /// The grid origin where no system clock id is available: the first read.
    static ORIGIN: OnceLock<Instant> = OnceLock::new();

    pub(super) fn now_ns() -> u64 {
        let origin = *ORIGIN.get_or_init(Instant::now);
        super::nanos(origin.elapsed())
    }
}

#[cfg(test)]
mod tests;
