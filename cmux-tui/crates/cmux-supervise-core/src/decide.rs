//! The one restart decision, pure: no clock, no I/O. The supervisor is the only actor that
//! decides; clients ask it.
//!
//! A restart needs proof:
//! - the process is gone by its recorded identity ([`Liveness::Dead`]), or
//! - the progress probe failed on every look for the whole bound (the longest real hold), with
//!   at least [`MIN_FAILED_LOOKS`] looks. Time alone never counts: a machine that slept, or a
//!   supervisor that did not look, has no failed looks to show, so a long gap restarts nothing.
//!
//! [`Liveness::Unknown`] proves nothing either way: the supervisor keeps what runs. A standing
//! stop intent is never restarted: dead, it stays stopped; alive, it is stopping.

use std::time::Duration;

use crate::identity::Liveness;

/// Fewest failed progress looks, spread over the whole bound, before a stall is proof.
pub const MIN_FAILED_LOOKS: u32 = 3;

/// What the progress probe found on one look.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Progress {
    /// Work moved since the last look (or there was no work to move).
    Moved,
    /// Work is waiting and did not move.
    Stalled,
}

/// The stall evidence so far: looks that found no progress, on the monotonic clock.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Stall {
    /// Monotonic time of the first failed look in the current run of failed looks.
    first_failed: Option<Duration>,
    failed_looks: u32,
}

impl Stall {
    /// Fold one look in, at monotonic time `now`.
    pub fn look(&mut self, progress: Progress, now: Duration) {
        match progress {
            Progress::Moved => *self = Self::default(),
            Progress::Stalled => {
                self.first_failed.get_or_insert(now);
                self.failed_looks = self.failed_looks.saturating_add(1);
            }
        }
    }

    /// Whether the looks prove a stall over `bound` at `now`.
    pub fn proven(&self, bound: Duration, now: Duration) -> bool {
        self.first_failed.is_some_and(|first| now.saturating_sub(first) >= bound)
            && self.failed_looks >= MIN_FAILED_LOOKS
    }

    pub fn failed_looks(&self) -> u32 {
        self.failed_looks
    }
}

/// What the supervisor does next.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Decision {
    /// Leave it running.
    Keep,
    /// Run the restart command, for this cause.
    Restart(crate::budget::StopCause),
    /// It stopped on purpose: no respawn.
    StayStopped(String),
    /// Over today's budget: no restart; report `restart-budget-exceeded`.
    Hold,
}

/// What the supervisor knows on one pass.
#[derive(Clone, Copy, Debug)]
pub struct Facts<'a> {
    pub liveness: Liveness,
    pub stall: &'a Stall,
    /// The longest real hold: a probe may fail this long during real work.
    pub bound: Duration,
    pub now: Duration,
    /// A standing stop intent for this epoch, with its reason.
    pub intent: Option<&'a str>,
    pub budget_exceeded: bool,
}

pub fn decide(f: Facts<'_>) -> Decision {
    let cause = match f.liveness {
        Liveness::Unknown => return Decision::Keep,
        Liveness::Dead => {
            if let Some(why) = f.intent {
                return Decision::StayStopped(why.to_owned());
            }
            crate::budget::StopCause::Died("gone by its recorded identity".into())
        }
        Liveness::Alive => {
            // A meant stop under way, however long it takes, is never restarted.
            if f.intent.is_some() || !f.stall.proven(f.bound, f.now) {
                return Decision::Keep;
            }
            crate::budget::StopCause::NoProgress(format!(
                "no progress on {} looks over {:?}",
                f.stall.failed_looks(),
                f.bound
            ))
        }
    };
    if f.budget_exceeded { Decision::Hold } else { Decision::Restart(cause) }
}

#[cfg(test)]
#[path = "decide_tests.rs"]
mod tests;
