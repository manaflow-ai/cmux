//! Which idle agent sessions leave this machine while it is over budget, with
//! nobody asking (Leo: "if my computer is too under load, go distribute the
//! sessions into other vms and whatnot").
//!
//! [`evacuate_plan`] is the one decision, beside [`crate::place::decide`]
//! (where new work runs): this host's budget level, the sessions here, the
//! user's setting and the time in; the sessions to move this tick and why
//! out, as data. It is pure: the acpmux daemon's timer feeds it and carries
//! out the moves through `session move --host auto`'s own path.
//!
//! The rules, in order:
//! 1. Off (the default) moves nothing, and the caller runs no timer.
//! 2. The trigger is the budget's own level ([`crate::Tracker`]), the same
//!    line [`crate::place::decide`] calls over: at [`Setting::enter`]
//!    ([`Level::Warning`] by default) or above. A level not read is never over.
//! 3. Hysteresis, so nothing flaps: evacuation starts once the level has been
//!    at or above `enter` for `hold_secs` without a break, and ends once it
//!    has been back at [`Level::Normal`] for `calm_secs`. While it is on,
//!    sessions move only on ticks whose level is at or above `enter`.
//! 4. A session moves only when no turn runs in it, nobody is looking at it,
//!    it is not kept here, it has been idle `min_idle_secs`, and it was not
//!    moved (or tried) in the last `cooldown_secs`. The longest idle go first,
//!    at most `per_tick` a tick.
//!
//! The sessions are asked for only once evacuation is on and the level is
//! over, so a host within budget pays nothing per tick; when asked, one pass
//! over them picks the `per_tick` longest idle.

use serde::Serialize;

use crate::Level;

/// The user's setting (acpmux `autoEvacuate` in config.json).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Setting {
    /// Off by default: a behaviour that moves people's sessions is opt-in.
    pub on: bool,
    /// The level that counts as over budget.
    pub enter: Level,
    /// How long the level must stay at or above `enter` before anything moves.
    pub hold_secs: u64,
    /// How long the level must stay at Normal before evacuation ends.
    pub calm_secs: u64,
    /// The most sessions moved in one tick.
    pub per_tick: usize,
    /// A session moved (or tried) this recently is never moved again.
    pub cooldown_secs: u64,
    /// A session idle for less than this stays.
    pub min_idle_secs: u64,
}

/// [`Setting::hold_secs`]'s default: two minutes over. A build spikes the load
/// for tens of seconds; a machine still over after two minutes is loaded.
pub const DEFAULT_HOLD_SECS: u64 = 120;
/// [`Setting::calm_secs`]'s default: a minute back at Normal.
pub const DEFAULT_CALM_SECS: u64 = 60;
/// [`Setting::per_tick`]'s default: one move a tick. A move pushes a branch and
/// starts the chat on another machine; one at a time lets the load answer.
pub const DEFAULT_PER_TICK: usize = 1;
/// [`Setting::cooldown_secs`]'s default: thirty minutes.
pub const DEFAULT_COOLDOWN_SECS: u64 = 30 * 60;
/// [`Setting::min_idle_secs`]'s default: five minutes without a turn.
pub const DEFAULT_MIN_IDLE_SECS: u64 = 5 * 60;

impl Default for Setting {
    fn default() -> Self {
        Self {
            on: false,
            enter: Level::Warning,
            hold_secs: DEFAULT_HOLD_SECS,
            calm_secs: DEFAULT_CALM_SECS,
            per_tick: DEFAULT_PER_TICK,
            cooldown_secs: DEFAULT_COOLDOWN_SECS,
            min_idle_secs: DEFAULT_MIN_IDLE_SECS,
        }
    }
}

/// What [`evacuate_plan`] keeps between ticks.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Hysteresis {
    /// When the current run of ticks at or above `enter` began, in ms.
    over_since: Option<u64>,
    /// When the current run of ticks at Normal began while evacuating, in ms.
    calm_since: Option<u64>,
    /// Evacuating.
    active: bool,
}

impl Hysteresis {
    pub fn active(&self) -> bool {
        self.active
    }
}

/// A session here, as the plan reads it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Candidate {
    pub id: String,
    pub name: String,
    /// When its last turn ended or a client last let go of it, in ms (the clock `now_ms` is on).
    pub idle_since_ms: u64,
    /// A turn runs in it.
    pub running: bool,
    /// A client shows it: the person is looking at it.
    pub attended: bool,
    /// Kept here by the person.
    pub kept: bool,
    /// When it was last moved or tried, in ms.
    pub moved_at_ms: Option<u64>,
}

/// One session to move.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Move {
    pub id: String,
    pub name: String,
    pub idle_ms: u64,
}

/// Why the plan is what it is, as data.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "code", rename_all = "snake_case")]
pub enum Why {
    /// The setting is off.
    Off,
    /// No budget level was read: never over.
    BudgetUnknown,
    /// Within budget and not evacuating.
    WithinBudget { level: Level },
    /// Over, but not for `hold_secs` yet.
    Holding { level: Level, over_secs: u64, hold_secs: u64 },
    /// Evacuating, but this tick's level is under `enter`: nothing moves until it
    /// is over again or calm for `calm_secs`.
    Easing { level: Level },
    /// Evacuating and over: the moves (none when no session qualifies).
    Over { level: Level, over_secs: u64 },
}

/// The sessions to move this tick, and why.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Plan {
    pub moves: Vec<Move>,
    pub why: Why,
}

impl Plan {
    fn none(why: Why) -> Self {
        Self { moves: Vec::new(), why }
    }
}

/// This tick's moves (module docs). `sessions` is called only when evacuating
/// and over budget.
pub fn evacuate_plan(
    state: &mut Hysteresis,
    level: Option<Level>,
    sessions: impl FnOnce() -> Vec<Candidate>,
    setting: &Setting,
    now_ms: u64,
) -> Plan {
    if !setting.on {
        *state = Hysteresis::default();
        return Plan::none(Why::Off);
    }
    let Some(level) = level else {
        *state = Hysteresis::default();
        return Plan::none(Why::BudgetUnknown);
    };
    let enter = setting.enter.max(Level::Warning);
    if level >= enter {
        state.calm_since = None;
        let since = *state.over_since.get_or_insert(now_ms);
        let over_secs = now_ms.saturating_sub(since) / 1000;
        if !state.active && over_secs >= setting.hold_secs {
            state.active = true;
        }
        if !state.active {
            return Plan::none(Why::Holding { level, over_secs, hold_secs: setting.hold_secs });
        }
        let moves = pick(sessions(), setting, now_ms);
        return Plan { moves, why: Why::Over { level, over_secs } };
    }
    state.over_since = None;
    if !state.active {
        return Plan::none(Why::WithinBudget { level });
    }
    if level == Level::Normal {
        let since = *state.calm_since.get_or_insert(now_ms);
        if now_ms.saturating_sub(since) / 1000 >= setting.calm_secs {
            *state = Hysteresis::default();
            return Plan::none(Why::WithinBudget { level });
        }
    } else {
        // Between the marks: the run of calm ticks is broken, evacuation stays on.
        state.calm_since = None;
    }
    Plan::none(Why::Easing { level })
}

/// The `per_tick` longest idle sessions that may move, in one pass.
fn pick(sessions: Vec<Candidate>, setting: &Setting, now_ms: u64) -> Vec<Move> {
    let k = setting.per_tick;
    if k == 0 {
        return Vec::new();
    }
    let cooldown_ms = setting.cooldown_secs.saturating_mul(1000);
    let min_idle_ms = setting.min_idle_secs.saturating_mul(1000);
    // Kept sorted longest idle first; at most `k` long, so the pass is O(n * k).
    let mut best: Vec<Candidate> = Vec::with_capacity(k + 1);
    for c in sessions {
        if c.running || c.attended || c.kept {
            continue;
        }
        if c.moved_at_ms.is_some_and(|at| now_ms.saturating_sub(at) < cooldown_ms) {
            continue;
        }
        if now_ms.saturating_sub(c.idle_since_ms) < min_idle_ms {
            continue;
        }
        let at = best
            .iter()
            .position(|b| (c.idle_since_ms, &c.id) < (b.idle_since_ms, &b.id))
            .unwrap_or(best.len());
        if at < k {
            best.insert(at, c);
            best.truncate(k);
        }
    }
    best.into_iter()
        .map(|c| Move { idle_ms: now_ms.saturating_sub(c.idle_since_ms), id: c.id, name: c.name })
        .collect()
}

impl std::fmt::Display for Why {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Off => write!(f, "automatic evacuation is off"),
            Self::BudgetUnknown => write!(f, "this machine's budget could not be read"),
            Self::WithinBudget { level } => write!(f, "this machine is within budget ({level:?})"),
            Self::Holding { level, over_secs, hold_secs } => write!(
                f,
                "this machine is over budget ({level:?}) for {over_secs}s of the {hold_secs}s \
                 that start an evacuation"
            ),
            Self::Easing { level } => {
                write!(f, "this machine is easing ({level:?}): nothing moves this tick")
            }
            Self::Over { level, over_secs } => {
                write!(f, "this machine has been over budget ({level:?}) for {over_secs}s")
            }
        }
    }
}

#[cfg(test)]
#[path = "evacuate_tests.rs"]
mod tests;
