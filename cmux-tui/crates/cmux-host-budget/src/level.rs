//! How hard the host is pressed, as the app shows it: nothing, a calm
//! titlebar indicator, or a dismissible banner; and the [`Tracker`] that turns
//! verdicts into a level that does not flicker (pure: the app's monitor feeds
//! it on its timer and on each memory pressure event).
//!
//! The levels sit on the shared budget, never on caps of their own:
//! - warning: one part of the budget is over (load at the limit, memory
//!   pressure warn, swap growing at the budget's rate), or the load reached
//!   [`LOAD_WARN_FRACTION`] of its limit, before acpmux would warn;
//! - critical: memory pressure is critical, or two parts are over at once
//!   (a busy CPU alone is a busy Mac, not a freeze; Leo: "just limit it nicer").
//!
//! A level rises on the first verdict that reaches it and falls only after
//! `calm_samples` verdicts in a row below it; a load warning also holds until
//! the load is [`LOAD_RELEASE_FRACTION`] under where it started.

use serde::{Deserialize, Serialize};

/// The warning's load line, as a share of the budget's load limit.
pub const LOAD_WARN_FRACTION: f64 = 0.75;
/// The deadband under the load line that keeps a warning up.
pub const LOAD_RELEASE_FRACTION: f64 = 0.10;

/// The level the app shows. Its number is the C ABI's (0, 1, 2).
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Default, Serialize, Deserialize,
)]
#[serde(rename_all = "lowercase")]
pub enum Level {
    #[default]
    Normal = 0,
    Warning = 1,
    Critical = 2,
}

impl Level {
    /// The C ABI's number.
    pub fn code(self) -> i32 {
        self as i32
    }

    /// The level of a C ABI number; `None` for any other.
    pub fn from_code(code: i32) -> Option<Self> {
        match code {
            0 => Some(Self::Normal),
            1 => Some(Self::Warning),
            2 => Some(Self::Critical),
            _ => None,
        }
    }
}

/// The parts of a verdict the level reads: a [`crate::Verdict`], or acpmux's
/// `host_pressure` (which adds the session facts) read from its JSON.
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct Reading {
    /// `normal`, `warn`, `critical` or `unknown`.
    pub pressure: String,
    pub over: Vec<String>,
    /// `None` when the host could not read it (it then counts as 0).
    #[serde(default)]
    pub load1: Option<f64>,
    pub load_limit: f64,
}

impl From<&crate::Verdict> for Reading {
    fn from(v: &crate::Verdict) -> Self {
        Self {
            pressure: v.pressure.to_owned(),
            over: v.over.clone(),
            load1: v.load1,
            load_limit: v.load_limit,
        }
    }
}

/// The level `reading` alone calls for while the app shows `holding`.
pub fn level_for(_reading: &Reading, _holding: Level) -> Level {
    // Red step: the rule is not ported yet.
    Level::Normal
}

/// Turns verdicts into a level that does not flicker (module docs).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Tracker {
    level: Level,
    calm_samples: u32,
    calm_streak: u32,
}

impl Default for Tracker {
    fn default() -> Self {
        Self::new(2)
    }
}

impl Tracker {
    /// A tracker at normal that falls after `calm_samples` (at least 1) calm verdicts.
    pub fn new(calm_samples: u32) -> Self {
        Self { level: Level::Normal, calm_samples: calm_samples.max(1), calm_streak: 0 }
    }

    pub fn level(&self) -> Level {
        self.level
    }

    pub fn calm_samples(&self) -> u32 {
        self.calm_samples
    }

    /// Feeds one verdict; returns the new level when it changed.
    pub fn feed(&mut self, _reading: &Reading) -> Option<Level> {
        // Red step: the rule is not ported yet.
        None
    }
}

#[cfg(test)]
#[path = "level_tests.rs"]
mod tests;
