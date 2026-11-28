//! What a viewer's connect waits for next (the Mac's `MacScreenConnectStage`,
//! cmuxterm-hq#13721): the host's answer, then the secure link, then the first picture. A
//! connect gets 15 s to show a picture; past that it fails naming the stage it was in.

use serde::{Deserialize, Serialize};

/// A connect's stage, in order (it only moves forward).
#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Default)]
#[serde(rename_all = "snake_case")]
pub enum Stage {
    /// The offer went; the host's answer has not come.
    #[default]
    Answer,
    /// The host answered; the link to it is not up.
    Link,
    /// The link is up; no picture has shown.
    Frame,
    /// A picture showed: the connect is done.
    Shown,
}

/// How long a connect may take to show its first picture, in milliseconds.
pub const CONNECT_TIMEOUT_MS: u64 = 15_000;

impl Stage {
    pub const ALL: [Stage; 4] = [Stage::Answer, Stage::Link, Stage::Frame, Stage::Shown];

    /// The stage's name in the log and `mac_screen.state`'s `connect_stage`.
    pub fn name(self) -> &'static str {
        match self {
            Stage::Answer => "no_answer",
            Stage::Link => "no_link",
            Stage::Frame => "no_frame",
            Stage::Shown => "shown",
        }
    }

    /// The stage's key in `mac_screen.state`'s `connect_stage_ms` (the time it ended).
    pub fn timing_key(self) -> &'static str {
        match self {
            Stage::Answer => "answer",
            Stage::Link => "link",
            Stage::Frame => "frame",
            Stage::Shown => "shown",
        }
    }

    /// The localized key of the failed card's text for a connect that timed out in this stage
    /// (the app formats it with the host's name); None once shown.
    pub fn timeout_key(self) -> Option<&'static str> {
        match self {
            Stage::Answer => Some("macScreen.card.noAnswer"),
            Stage::Link => Some("macScreen.card.noLink"),
            Stage::Frame => Some("macScreen.card.noFrame"),
            Stage::Shown => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stages_are_ordered_and_named_like_the_mac() {
        assert!(
            Stage::Answer < Stage::Link
                && Stage::Link < Stage::Frame
                && Stage::Frame < Stage::Shown
        );
        let names: Vec<_> = Stage::ALL.iter().map(|s| s.name()).collect();
        assert_eq!(names, ["no_answer", "no_link", "no_frame", "shown"]);
        let keys: Vec<_> = Stage::ALL.iter().map(|s| s.timing_key()).collect();
        assert_eq!(keys, ["answer", "link", "frame", "shown"]);
        assert_eq!(Stage::Shown.timeout_key(), None);
        assert_eq!(Stage::Link.timeout_key(), Some("macScreen.card.noLink"));
        assert_eq!(serde_json::to_value(Stage::Frame).unwrap(), "frame");
    }
}
