//! Noticing that this machine, or this process, did not run for a while: a paused VM resumed, a
//! sleeping computer woke, or the daemon was stopped (`SIGSTOP`) and continued.
//!
//! Two clocks are read on a coarse tick ([`ResumeWatch::EVERY`]). The monotonic clock stops while a
//! VM is paused or a computer sleeps (Linux `CLOCK_MONOTONIC`, macOS `mach_absolute_time`); the wall
//! clock moves on, at once (kvmclock) or when the guest's clock is set again after the resume
//! (Virtualization.framework, NTP). So the wall clock running ahead of the monotonic one is a pause
//! ([`ResumeKind::Paused`]). A process that was stopped sees both clocks move together, but its own
//! tick comes late on the monotonic clock: that is [`ResumeKind::Stopped`]. Either way the timers
//! that measure quiet (a turn's silent and stalled counts) counted time in which nothing could have
//! arrived, and the network streams held across it come back late (TCP's retransmit backoff: up to
//! about 90 s after a 2 minute pause), so the hub gives them a fresh period (`hub/resume.rs`).
//!
//! The tick runs only while something reads the gaps (a running turn, a subscriber): an idle daemon
//! does not wake for it (`hub/resume.rs`). While nothing ticks the watch is [parked](ResumeWatch::park):
//! lateness then means nothing, so the first check after it sees only a pause (the wall clock ahead
//! of the monotonic one, which needs no tick to be seen) and counts on from there.
//!
//! Sans I/O: the caller passes the clocks, so a test feeds samples instead of pausing a machine.
//! `peer_link::SleepWatch` is the per-link wall-against-monotonic check the peer links already run.

use std::time::Duration;

/// What kind of gap a check found.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ResumeKind {
    /// The wall clock ran ahead of the monotonic one: the machine was paused or asleep.
    Paused,
    /// Both clocks moved, but the tick came late: this process did not run (stopped, starved).
    Stopped,
}

impl ResumeKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Paused => "paused",
            Self::Stopped => "stopped",
        }
    }
}

/// One gap: how long nothing here ran, and how it was seen.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Resume {
    pub gap: Duration,
    pub kind: ResumeKind,
}

impl Resume {
    pub fn gap_ms(&self) -> u64 {
        u64::try_from(self.gap.as_millis()).unwrap_or(u64::MAX)
    }
}

/// The clocks at the last check.
#[derive(Debug, Clone, Copy)]
pub struct ResumeWatch {
    wall_ms: u64,
    mono: Duration,
    /// No tick runs: a late check is no stop (see the module docs).
    parked: bool,
}

impl ResumeWatch {
    /// How often the daemon checks (`hub/resume.rs`). Coarse: one wakeup per period.
    pub const EVERY: Duration = Duration::from_secs(10);
    /// A gap under this is scheduling noise or a small clock correction, not a resume.
    pub const SLACK: Duration = Duration::from_secs(15);

    /// Starts counting from these clocks: the wall clock in Unix ms, the monotonic one as an
    /// offset from any fixed origin.
    pub fn new(wall_ms: u64, mono: Duration) -> Self {
        Self { wall_ms, mono, parked: false }
    }

    /// The tick stops: until the next check, time passing on both clocks is not lateness.
    pub fn park(&mut self) {
        self.parked = true;
    }

    /// Whether the tick is stopped (the next check starts it again).
    pub fn parked(&self) -> bool {
        self.parked
    }

    /// The gap since the last check, when there was one; the watch counts from now either way.
    /// A check may come sooner than [`Self::EVERY`] (a timer about to judge a turn asks first):
    /// only time beyond one period counts as late.
    pub fn observe(&mut self, wall_ms: u64, mono: Duration) -> Option<Resume> {
        let wall = Duration::from_millis(wall_ms.saturating_sub(self.wall_ms));
        let awake = mono.saturating_sub(self.mono);
        let parked = self.parked;
        *self = Self::new(wall_ms, mono);
        // A wall clock set back (a correction) moves `wall` to 0: no pause, and the stopped check
        // still reads the monotonic clock alone.
        let paused = wall.saturating_sub(awake);
        let late = awake.saturating_sub(Self::EVERY);
        if paused >= Self::SLACK {
            // The time the tick was late on either clock is the time nothing ran. A parked watch
            // had no tick: the gap is the wall clock's lead over the monotonic one.
            let gap = if parked { paused } else { wall.saturating_sub(Self::EVERY) };
            Some(Resume { gap, kind: ResumeKind::Paused })
        } else if late >= Self::SLACK && !parked {
            Some(Resume { gap: late, kind: ResumeKind::Stopped })
        } else {
            None
        }
    }
}

#[cfg(test)]
mod tests;
