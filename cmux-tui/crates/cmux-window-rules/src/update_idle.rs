//! Update when idle (`updates.installWhenIdle`, off by default): whether a
//! downloaded app update may install and relaunch the app now (Leo,
//! 2026-11-19: "when it's idle, it's able to ... update automatically ...
//! maybe even having it as an opt-in option would be pretty interesting.
//! Yeah, like update when idle").
//!
//! The app reads the facts (seconds since the last keyboard or pointer input,
//! this Mac's agent turns, the unsent drafts) and asks here once a second
//! while a staged update waits; it installs on [`Hold`] none. The relaunch keeps
//! every terminal, agent host and running turn (the daemons outlive the app),
//! but it never starts while the person could be cut off:
//!
//! - input in the last `idle_minutes` (default 15): the person is at the Mac;
//! - an agent turn running on this Mac: its streaming chat would blink away;
//! - an unsent draft in a composer: the person is mid-message;
//! - any of those unknown (the daemon did not answer): never guess.
//!
//! The input check comes first, so the app reads the agents only once the
//! person has been away long enough.

use serde::{Deserialize, Serialize};

/// The shortest idle time the setting takes, in minutes.
pub const MIN_IDLE_MINUTES: f64 = 1.0;

/// What the app knows now.
#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct IdleFacts {
    /// `updates.installWhenIdle`.
    pub enabled: bool,
    /// `updates.installWhenIdleMinutes`; below [`MIN_IDLE_MINUTES`] (or not a
    /// number) counts as that.
    pub idle_minutes: f64,
    /// Seconds since the last keyboard or pointer input anywhere on the Mac;
    /// none when the app could not read it.
    pub input_idle_seconds: Option<f64>,
    /// Agent turns running on this Mac (the app's chats and its Home chief);
    /// none when the daemon did not answer.
    pub running_turns: Option<u32>,
    /// Composers holding typed text not sent yet; none when unknown.
    pub unsent_drafts: Option<u32>,
}

impl Default for IdleFacts {
    fn default() -> Self {
        Self {
            enabled: false,
            idle_minutes: 15.0,
            input_idle_seconds: None,
            running_turns: None,
            unsent_drafts: None,
        }
    }
}

/// Why the update waits.
#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", tag = "reason")]
pub enum Hold {
    /// The setting is off: only a click installs.
    Off,
    /// Input came too recently; `seconds_left` until the idle time is reached
    /// if nothing else happens.
    NotIdle {
        #[serde(rename = "secondsLeft")]
        seconds_left: f64,
    },
    /// An agent turn runs.
    AgentWorking,
    /// A composer holds an unsent message.
    UnsentDraft,
    /// Input, turns or drafts could not be read.
    Unknown,
}

/// The decision: install now, or the hold and its reason.
#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Decision {
    pub install: bool,
    pub hold: Option<Hold>,
}

impl Decision {
    fn hold(hold: Hold) -> Self {
        Decision { install: false, hold: Some(hold) }
    }
}

/// The idle time the setting asks for, in seconds.
pub fn idle_seconds(idle_minutes: f64) -> f64 {
    let minutes = if idle_minutes.is_finite() {
        idle_minutes.max(MIN_IDLE_MINUTES)
    } else {
        MIN_IDLE_MINUTES
    };
    minutes * 60.0
}

/// Whether the staged update installs now.
pub fn decide(facts: &IdleFacts) -> Decision {
    if !facts.enabled {
        return Decision::hold(Hold::Off);
    }
    let Some(idle) = facts.input_idle_seconds.filter(|s| s.is_finite() && *s >= 0.0) else {
        return Decision::hold(Hold::Unknown);
    };
    let needed = idle_seconds(facts.idle_minutes);
    if idle < needed {
        return Decision::hold(Hold::NotIdle { seconds_left: needed - idle });
    }
    match (facts.running_turns, facts.unsent_drafts) {
        (None, _) | (_, None) => Decision::hold(Hold::Unknown),
        (Some(turns), _) if turns > 0 => Decision::hold(Hold::AgentWorking),
        (_, Some(drafts)) if drafts > 0 => Decision::hold(Hold::UnsentDraft),
        _ => Decision { install: true, hold: None },
    }
}

#[cfg(test)]
#[path = "update_idle_tests.rs"]
mod tests;
