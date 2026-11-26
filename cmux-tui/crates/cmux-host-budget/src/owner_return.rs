//! The owner always wins on a machine enrolled in AutoCloud: when its owner comes back to the
//! keyboard, the work AutoCloud placed here gets out of the way.
//!
//! [`owner_return_plan`] is the one decision, beside [`crate::evacuate::evacuate_plan`]: whether
//! the machine is enrolled, the owner's HID idle time, the AutoCloud-placed sessions here and the
//! time in; what to do to each this tick and why, as data. It is pure: the acpmux daemon's timer
//! feeds it and carries the moves out through `session move --host auto`'s own path (the move
//! protocol's holder change, as automatic evacuation does) and the pauses with SIGSTOP/SIGCONT of
//! the agent's process group.
//!
//! The rules, in order:
//! 1. Not enrolled: nothing moves or pauses, and every session this left paused is resumed.
//! 2. The owner's idle time not read: nothing at all (never destructive on a guess); paused
//!    sessions stay paused until a reading says the owner is away.
//! 3. Hysteresis, so nothing flaps: the owner is back once idle drops under
//!    [`ReturnSetting::back_secs`]; back ends once idle reaches [`ReturnSetting::resume_secs`].
//! 4. While the owner is back: a placed session with no running turn moves off (at most
//!    `per_tick` a tick, never one moving or tried in the last `cooldown_secs`); one mid-turn is
//!    paused, never killed or dropped. A paused one whose turn is over is resumed so it can move.
//! 5. Not back: every paused session is resumed.
//!
//! [`ReturnPlan::freed`] says the machine is free of placed work (nothing left running or to
//! move): the daemon logs the time from the owner's return to it.

use serde::Serialize;

/// The decision's knobs. Only enrollment turns it on (`cloud.autoCloudEnroll`, default off).
#[derive(Debug, Clone, PartialEq)]
pub struct ReturnSetting {
    /// HID idle under this many seconds: the owner is back.
    pub back_secs: f64,
    /// HID idle at or over this many seconds: the owner is away again, paused work resumes.
    pub resume_secs: u64,
    /// The most sessions moved in one tick.
    pub per_tick: usize,
    /// A session moved (or tried) this recently is not tried again.
    pub cooldown_secs: u64,
}

/// [`ReturnSetting::back_secs`]'s default: input in the last 5 s.
pub const DEFAULT_BACK_SECS: f64 = 5.0;
/// [`ReturnSetting::resume_secs`]'s default: a minute without input.
pub const DEFAULT_RESUME_SECS: u64 = 60;
/// [`ReturnSetting::per_tick`]'s default.
pub const DEFAULT_PER_TICK: usize = 4;
/// [`ReturnSetting::cooldown_secs`]'s default: five minutes.
pub const DEFAULT_COOLDOWN_SECS: u64 = 5 * 60;

impl Default for ReturnSetting {
    fn default() -> Self {
        Self {
            back_secs: DEFAULT_BACK_SECS,
            resume_secs: DEFAULT_RESUME_SECS,
            per_tick: DEFAULT_PER_TICK,
            cooldown_secs: DEFAULT_COOLDOWN_SECS,
        }
    }
}

/// What [`owner_return_plan`] keeps between ticks.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ReturnState {
    back: bool,
}

impl ReturnState {
    /// The owner is back (rule 3).
    pub fn back(&self) -> bool {
        self.back
    }
}

/// An AutoCloud-placed session here, as the plan reads it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Placed {
    pub id: String,
    pub name: String,
    /// A turn runs in it (or is queued or claimed).
    pub running: bool,
    /// Its agent's process group is stopped by this plan.
    pub paused: bool,
    /// A move of it is under way.
    pub moving: bool,
    /// When it was last moved or tried, in ms.
    pub tried_at_ms: Option<u64>,
}

/// One thing to do to one session.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "action", rename_all = "snake_case")]
pub enum Action {
    /// Move it off this machine (`session move --host auto`).
    Move { id: String, name: String },
    /// Stop its agent's process group (SIGSTOP): mid-turn, so it cannot move now.
    Pause { id: String },
    /// Continue its agent's process group (SIGCONT).
    Resume { id: String },
}

/// Why the plan is what it is.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "code", rename_all = "snake_case")]
pub enum Why {
    NotEnrolled,
    PresenceUnread,
    OwnerAway { idle_secs: f64 },
    OwnerBack { idle_secs: f64 },
}

/// This tick's actions, and why.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct ReturnPlan {
    pub actions: Vec<Action>,
    pub why: Why,
    /// The owner just came back this tick (the start of the measurement).
    pub returned: bool,
    /// The owner is back and no placed session here runs or waits to move.
    pub freed: bool,
}

/// This tick's actions (module docs). `sessions` is called only when there may be something to
/// do: not on an unread idle time.
pub fn owner_return_plan(
    state: &mut ReturnState,
    enrolled: bool,
    owner_idle_secs: Option<f64>,
    sessions: impl FnOnce() -> Vec<Placed>,
    setting: &ReturnSetting,
    now_ms: u64,
) -> ReturnPlan {
    let plan = |actions, why, returned, freed| ReturnPlan { actions, why, returned, freed };
    if !enrolled {
        *state = ReturnState::default();
        return plan(resume_all(sessions()), Why::NotEnrolled, false, false);
    }
    let Some(idle) = owner_idle_secs else {
        return plan(Vec::new(), Why::PresenceUnread, false, false);
    };
    let idle = idle.max(0.0);
    let was_back = state.back;
    if idle < setting.back_secs {
        state.back = true;
    } else if state.back && idle >= setting.resume_secs as f64 {
        state.back = false;
    }
    if !state.back {
        return plan(resume_all(sessions()), Why::OwnerAway { idle_secs: idle }, false, false);
    }
    let returned = !was_back;
    let cooldown_ms = setting.cooldown_secs.saturating_mul(1000);
    let mut actions = Vec::new();
    let mut moves = 0;
    let mut freed = true;
    for s in sessions() {
        match (s.running, s.paused) {
            (true, true) => {}
            (true, false) => {
                freed = false;
                actions.push(Action::Pause { id: s.id });
            }
            // Its turn ended while paused: continue it so the next tick moves it.
            (false, true) => {
                freed = false;
                actions.push(Action::Resume { id: s.id });
            }
            (false, false) => {
                if s.moving {
                    freed = false;
                    continue;
                }
                if s.tried_at_ms.is_some_and(|at| now_ms.saturating_sub(at) < cooldown_ms) {
                    // Tried and still here: it stays idle here, using nothing until it is moved.
                    continue;
                }
                freed = false;
                if moves < setting.per_tick {
                    moves += 1;
                    actions.push(Action::Move { id: s.id, name: s.name });
                }
            }
        }
    }
    plan(actions, Why::OwnerBack { idle_secs: idle }, returned, freed)
}

fn resume_all(sessions: Vec<Placed>) -> Vec<Action> {
    sessions.into_iter().filter(|s| s.paused).map(|s| Action::Resume { id: s.id }).collect()
}

impl std::fmt::Display for Why {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NotEnrolled => write!(f, "this machine is not enrolled in AutoCloud"),
            Self::PresenceUnread => write!(f, "the owner's presence could not be read"),
            Self::OwnerAway { idle_secs } => write!(f, "the owner is away ({idle_secs:.0}s idle)"),
            Self::OwnerBack { idle_secs } => {
                write!(f, "the owner is back at this machine ({idle_secs:.0}s idle)")
            }
        }
    }
}

#[cfg(test)]
#[path = "owner_return_tests.rs"]
mod tests;
