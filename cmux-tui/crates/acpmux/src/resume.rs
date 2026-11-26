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
mod tests {
    use super::*;

    const S: u64 = 1000;

    fn secs(s: u64) -> Duration {
        Duration::from_secs(s)
    }

    #[test]
    fn ticks_on_time_are_no_resume() {
        let mut w = ResumeWatch::new(1_000 * S, secs(0));
        for i in 1..=20 {
            // A little jitter either way is noise.
            let jitter = if i % 2 == 0 { 300 } else { 0 };
            assert_eq!(w.observe(1_000 * S + i * 10 * S + jitter, secs(i * 10)), None, "tick {i}");
        }
        // An early check (a timer asks before it judges) is no resume either.
        assert_eq!(w.observe(1_000 * S + 201 * S, secs(201)), None);
    }

    #[test]
    fn a_vm_pause_is_the_wall_clock_running_ahead() {
        let mut w = ResumeWatch::new(1_000 * S, secs(50));
        // Paused 5 minutes between two ticks: the monotonic clock moved one period.
        let r = w.observe(1_000 * S + 310 * S, secs(60)).expect("a pause");
        assert_eq!(r.kind, ResumeKind::Paused);
        assert_eq!(r.gap, secs(300));
        // The next tick counts from the resume.
        assert_eq!(w.observe(1_000 * S + 320 * S, secs(70)), None);
    }

    #[test]
    fn a_wall_clock_set_late_after_the_resume_still_reads_as_a_pause() {
        // Virtualization.framework: the guest clock stops with the VM and is set again later. The
        // tick right after the resume sees nothing; the one after the clock is set sees the jump.
        let mut w = ResumeWatch::new(1_000 * S, secs(0));
        assert_eq!(w.observe(1_000 * S + 10 * S, secs(10)), None);
        let r = w.observe(1_000 * S + 20 * S + 120 * S, secs(20)).expect("the set clock");
        assert_eq!((r.kind, r.gap), (ResumeKind::Paused, secs(120)));
    }

    #[test]
    fn a_stopped_process_is_a_late_tick_on_both_clocks() {
        let mut w = ResumeWatch::new(1_000 * S, secs(0));
        // SIGSTOP for 60 s: both clocks moved 70 s over a 10 s period.
        let r = w.observe(1_000 * S + 70 * S, secs(70)).expect("a stop");
        assert_eq!((r.kind, r.gap), (ResumeKind::Stopped, secs(60)));
    }

    #[test]
    fn a_parked_watch_sees_a_pause_but_no_stop() {
        // An idle daemon parks the watch: an hour on both clocks is no gap.
        let mut w = ResumeWatch::new(1_000 * S, secs(0));
        w.park();
        assert!(w.parked());
        assert_eq!(w.observe(1_000 * S + 3_600 * S, secs(3_600)), None);
        // The check unparked it: from here a late tick is a stop again.
        assert!(!w.parked());
        let r = w.observe(1_000 * S + 3_670 * S, secs(3_670)).expect("a stop");
        assert_eq!((r.kind, r.gap), (ResumeKind::Stopped, secs(60)));
        // A computer that slept 5 minutes while parked: the wall clock ran ahead, seen at once.
        w.park();
        let r = w.observe(1_000 * S + 4_270 * S + 300 * S, secs(4_270)).expect("a pause");
        assert_eq!((r.kind, r.gap), (ResumeKind::Paused, secs(300)));
    }

    #[test]
    fn small_gaps_and_a_clock_set_back_are_noise() {
        let mut w = ResumeWatch::new(10_000 * S, secs(0));
        // 14 s late: under the slack.
        assert_eq!(w.observe(10_000 * S + 24 * S, secs(24)), None);
        // The wall clock set back an hour: no pause.
        assert_eq!(w.observe(10_000 * S - 3_600 * S, secs(34)), None);
        // And the watch goes on from there.
        assert_eq!(w.observe(10_000 * S - 3_590 * S, secs(44)), None);
    }
}
