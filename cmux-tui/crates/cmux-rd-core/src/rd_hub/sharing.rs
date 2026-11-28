//! This Mac's default sharing (`MacScreenHubHost+DefaultSharing.swift`): on by default once
//! the Screen Recording grant is there, off when the grant goes, and never back on after the
//! person turned it off.

use serde::{Deserialize, Serialize};

/// What to do to this Mac's sharing now.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SharingStep {
    None,
    TurnOn,
    TurnOff,
}

/// This Mac's sharing as the machine record names it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SharingState {
    On,
    Off,
    TurnedOff,
    NeedsGrant,
}

/// The step for what is known: `shared` is the hub's bit, `grant_known` whether the Screen
/// Recording grant was read, `turned_off` the person's own switch. Anything unknown (a
/// failed read) leaves sharing alone.
pub fn default_sharing_step(
    shared: Option<bool>,
    grant_known: bool,
    screen_recording: bool,
    turned_off: Option<bool>,
) -> SharingStep {
    let (Some(shared), true, Some(turned_off)) = (shared, grant_known, turned_off) else {
        return SharingStep::None;
    };
    if shared && !screen_recording {
        SharingStep::TurnOff
    } else if !shared && screen_recording && !turned_off {
        SharingStep::TurnOn
    } else {
        SharingStep::None
    }
}

pub fn sharing_state(
    shared: bool,
    grant_known: bool,
    screen_recording: bool,
    turned_off: bool,
) -> SharingState {
    if grant_known && !screen_recording {
        SharingState::NeedsGrant
    } else if shared {
        SharingState::On
    } else if turned_off {
        SharingState::TurnedOff
    } else {
        SharingState::Off
    }
}

#[cfg(test)]
#[path = "sharing_tests.rs"]
mod tests;
