//! The unresponsive-owner watch (cx-jniyz.1): restarts a session owner that
//! stays alive but never answers, without the confirm of "Restart cmux-tui".
//! Once ensures in a row failed the way a stuck owner makes them fail, at
//! least [`Policy::stuck_ensures`] of them over at least
//! [`Policy::sustained_ms`], it starts a replace, at most once per owner
//! process and [`Policy::per_launch`] times in all. Any other ensure ends the
//! streak (one that worked, one that failed another way, one refused at the
//! connection limit: that owner answers).
//!
//! This is the state machine only. The app runs the window's one-shot timer
//! ([`Effects::schedule`], [`Effects::cancel`]) under the same lock as each
//! call, so an older outcome never cancels a newer streak's deadline, reads
//! the Debug toggle before each call (`enabled`), and runs the replace task
//! ([`Watch::evaluate`]'s start), which claims ([`Watch::claim`]) right
//! before it replaces and reports its end ([`Watch::finish`]).

use crate::failure::EnsureKind;
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Policy {
    /// How long ensures must keep failing as stuck before the replace.
    pub sustained_ms: u64,
    /// How many stuck ensures in a row the replace needs.
    pub stuck_ensures: u32,
    /// The most replaces in one app launch.
    pub per_launch: u32,
}

impl Policy {
    /// 30 s and two stuck ensures: past the reconnect's first attempts, and
    /// each stuck ensure already waited its own bound.
    pub const STANDARD: Policy = Policy { sustained_ms: 30_000, stuck_ensures: 2, per_launch: 3 };
}

impl Default for Policy {
    fn default() -> Self {
        Self::STANDARD
    }
}

/// What the app does with the window's timer after a call.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Effects {
    /// Schedule the window (replacing any pending one): after `after_ms`,
    /// call [`Watch::window_passed`] with `streak`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub schedule: Option<Schedule>,
    /// Cancel the pending window.
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub cancel: bool,
    /// Read the toggle again and call [`Watch::evaluate`].
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub evaluate: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Schedule {
    pub streak: u64,
    pub after_ms: u64,
}

/// A replace to start: the app runs it with a claim for `streak` and `owner`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Start {
    pub streak: u64,
    pub owner: Option<i32>,
}

#[derive(Debug, Clone, Default)]
pub struct Watch {
    policy: Policy,
    /// Stuck ensures in a row, and which streak it is.
    streak: u32,
    streak_id: u64,
    window_passed: bool,
    /// The owner the last ensure that worked found.
    owner: Option<i32>,
    replaced_owners: BTreeSet<Option<i32>>,
    replaces: u32,
    /// The streak whose replace is queued or running.
    replacing: Option<u64>,
    /// The last streak whose claim said yes.
    claimed: Option<u64>,
    stopped: bool,
}

impl Watch {
    pub fn new(policy: Policy) -> Self {
        Self { policy, ..Self::default() }
    }

    /// Replaces started so far (a claim that says no gives its replace back).
    pub fn replace_count(&self) -> u32 {
        self.replaces
    }

    fn end_streak(&mut self) -> Effects {
        self.streak = 0;
        self.window_passed = false;
        Effects { cancel: true, ..Effects::default() }
    }

    /// Ends the watch for good: the deadline is cancelled and nothing is
    /// replaced after it.
    pub fn stop(&mut self) -> Effects {
        self.stopped = true;
        self.end_streak()
    }

    /// Records how one ensure ended. The window is pending only during a
    /// stuck streak with the toggle on.
    pub fn note(&mut self, ensure: EnsureKind, enabled: bool) -> Effects {
        if self.stopped {
            return Effects::default();
        }
        match ensure {
            EnsureKind::Stuck if enabled => {
                self.streak = self.streak.saturating_add(1);
                let mut effects = Effects { evaluate: true, ..Effects::default() };
                if self.streak == 1 {
                    self.streak_id = self.streak_id.wrapping_add(1);
                    self.window_passed = false;
                    // One bounded deadline per streak, not a poll.
                    effects.schedule = Some(Schedule {
                        streak: self.streak_id,
                        after_ms: self.policy.sustained_ms,
                    });
                }
                effects
            }
            EnsureKind::Ready { pid } => {
                self.owner = pid;
                self.end_streak()
            }
            EnsureKind::Stuck | EnsureKind::Busy | EnsureKind::Failed => self.end_streak(),
        }
    }

    /// The window of `streak` passed (its timer fired).
    pub fn window_passed(&mut self, streak: u64, enabled: bool) -> Effects {
        if self.stopped || self.streak_id != streak || self.streak == 0 {
            return Effects::default();
        }
        if !enabled {
            self.streak = 0;
            return Effects::default();
        }
        self.window_passed = true;
        Effects { evaluate: true, ..Effects::default() }
    }

    fn due(&self) -> bool {
        !self.stopped
            && self.streak >= self.policy.stuck_ensures
            && self.window_passed
            && self.replaces < self.policy.per_launch
            && !self.replaced_owners.contains(&self.owner)
    }

    /// Starts the replace when the current streak is due.
    pub fn evaluate(&mut self, enabled: bool) -> Option<Start> {
        if !enabled || self.replacing.is_some() || !self.due() {
            return None;
        }
        self.replacing = Some(self.streak_id);
        self.replaced_owners.insert(self.owner);
        self.replaces = self.replaces.saturating_add(1);
        Some(Start { streak: self.streak_id, owner: self.owner })
    }

    /// Whether the replace queued for `streak` may still run: the toggle is
    /// on, the watch was not stopped, and the same owner is still in the same
    /// stuck streak. When not, it is given back (its count and its owner); a
    /// claim that finds the toggle off also ends the streak.
    pub fn claim(&mut self, streak: u64, owner: Option<i32>, enabled: bool) -> (bool, Effects) {
        let current = enabled
            && !self.stopped
            && self.replacing == Some(streak)
            && self.streak_id == streak
            && self.streak >= self.policy.stuck_ensures
            && self.window_passed
            && self.owner == owner;
        if current {
            self.claimed = Some(streak);
        } else if self.replacing == Some(streak) {
            self.give_back(owner);
        }
        let effects = if enabled { Effects::default() } else { self.end_streak() };
        (current, effects)
    }

    /// The replace for `streak` ended. One that never got a yes from its
    /// claim is given back, so the same owner, still stuck, is replaced later.
    pub fn finish(&mut self, streak: u64, owner: Option<i32>) {
        if self.replacing != Some(streak) {
            return;
        }
        if self.claimed != Some(streak) {
            self.give_back(owner);
        } else {
            self.replacing = None;
        }
    }

    fn give_back(&mut self, owner: Option<i32>) {
        self.replaces = self.replaces.saturating_sub(1);
        self.replaced_owners.remove(&owner);
        self.replacing = None;
    }
}
