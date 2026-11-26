//! The backdrop's agent glow (Swift `BackdropAgentGlow`): the loudest agent's level, colored by
//! its machine.

use serde::{Deserialize, Serialize};

/// How loud an agent is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Level {
    Calm,
    Working,
    NeedsYou,
}

/// One agent's machine and level.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Agent {
    pub machine: String,
    pub level: Level,
}

/// The glow: a level and the machine whose color it takes (none when calm).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Glow {
    pub level: Level,
    pub machine: Option<String>,
    pub opacity: f32,
}

/// The glow's alpha at the window edge.
pub const EDGE_ALPHA: f64 = 0.32;

/// The glow of `agents`: the loudest level, the alphabetically first machine at it; calm for none.
pub fn glow(agents: &[Agent]) -> Glow {
    let loudest = agents.iter().map(|a| a.level).max().unwrap_or(Level::Calm);
    let machine = agents.iter().filter(|a| a.level == loudest).map(|a| &a.machine).min();
    match machine {
        Some(machine) if loudest > Level::Calm => {
            Glow { level: loudest, machine: Some(machine.clone()), opacity: opacity(loudest) }
        }
        _ => Glow { level: Level::Calm, machine: None, opacity: 0.0 },
    }
}

/// How strongly a level glows.
pub fn opacity(level: Level) -> f32 {
    match level {
        Level::Calm => 0.0,
        Level::Working => 0.35,
        Level::NeedsYou => 1.0,
    }
}
