//! `HomeChiefActionPlan` (CmuxNextHomeEngine/Home/HomeChiefActionPlan.swift): where `home.stopChief`
//! and `home.toggleChiefSettings` act when they run from anywhere (the palette, a menu, `cmux action run`).

use serde::{Deserialize, Serialize};

/// A Chief conversation in the inbox.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Chief {
    pub conversation: String,
    /// Its turn runs.
    #[serde(default)]
    pub is_working: bool,
    /// This Mac's default Chief, preferred over the others.
    #[serde(default)]
    pub is_default: bool,
}

/// What the front window's Home shows.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum Front {
    /// No Home in front, or one that shows no Chief conversation.
    None,
    /// A Chief conversation, and whether its turn runs.
    #[serde(rename_all = "camelCase")]
    Chief { is_working: bool },
}

/// What Stop does.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum Stop {
    /// The Home in front stops its own Chief.
    Front,
    /// The Chief of this conversation stops, with no Home in front.
    Chief { conversation: String },
    /// Nothing runs: refused quietly.
    NothingRuns,
}

/// What Toggle Chief Settings does.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum Settings {
    /// The Home in front toggles its own Chief's settings.
    Front,
    /// Home comes forward at this Chief's conversation and opens its settings.
    Open { conversation: String },
    /// No Chief exists: refused with a reason.
    NoChief,
}

/// The Chief a Home in front shows wins, even when idle; else the working Chief, this Mac's default first.
pub fn stop(front: &Front, chiefs: &[Chief]) -> Stop {
    match front {
        Front::Chief { is_working: true } => Stop::Front,
        Front::Chief { is_working: false } => Stop::NothingRuns,
        Front::None => {
            let mut working = chiefs.iter().filter(|chief| chief.is_working);
            let first = working.clone().next();
            match working.find(|chief| chief.is_default).or(first) {
                Some(chief) => Stop::Chief { conversation: chief.conversation.clone() },
                None => Stop::NothingRuns,
            }
        }
    }
}

/// The Home in front toggles; else this Mac's default Chief (or the first one) opens.
pub fn settings(front: &Front, chiefs: &[Chief]) -> Settings {
    if matches!(front, Front::Chief { .. }) {
        return Settings::Front;
    }
    match chiefs.iter().find(|chief| chief.is_default).or(chiefs.first()) {
        Some(chief) => Settings::Open { conversation: chief.conversation.clone() },
        None => Settings::NoChief,
    }
}
