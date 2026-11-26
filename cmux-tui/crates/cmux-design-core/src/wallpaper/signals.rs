//! What a window or workspace notification means to a playing backdrop (Swift
//! `BackdropPlaybackSignals.note`), and which picture a shown desktop selects (Swift
//! `DesktopShown`).

use serde::{Deserialize, Serialize};

/// What the backdrop does about a notification.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Signal {
    Closing,
    Raised,
    Changed,
}

/// The screens and session state the notifications track.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Playback {
    #[serde(default)]
    pub screens_asleep: bool,
    #[serde(default)]
    pub session_inactive: bool,
}

/// The state after the notification `name` (its Cocoa name without `NS` and `Notification`, as
/// `windowWillClose`, `screensDidSleep`), and the signal it sends.
pub fn note(state: Playback, name: &str) -> (Playback, Signal) {
    let mut state = state;
    match name {
        "windowWillClose" => return (state, Signal::Closing),
        "windowDidBecomeMain" | "windowDidBecomeKey" => return (state, Signal::Raised),
        "screensDidSleep" => state.screens_asleep = true,
        "screensDidWake" => state.screens_asleep = false,
        "sessionDidResignActive" => state.session_inactive = true,
        "sessionDidBecomeActive" => state.session_inactive = false,
        _ => {}
    }
    (state, Signal::Changed)
}

/// What a shown desktop picture selects.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum Selection {
    /// One frame of a dynamic picture.
    Moment { path: String, frame: usize, dark: bool },
    /// The file itself.
    System { path: String },
}

/// `DesktopShown.selection(dark:)`.
pub fn selection(path: &str, frame: Option<usize>, dark: bool) -> Selection {
    match frame {
        Some(frame) => Selection::Moment { path: path.to_string(), frame, dark },
        None => Selection::System { path: path.to_string() },
    }
}
