//! Browser focus mode's exit gesture, ported from classic cmux
//! (`BrowserPanel.handleBrowserFocusModeKeyEvent`): two plain Escapes in a row.
//!
//! The first plain Escape still reaches the page (a page's own Escape, such
//! as closing its dialog, keeps working) and arms the exit; the toolbar badge
//! then reads "Esc again to exit". A second plain Escape within
//! [`SEQUENCE_INTERVAL`] leaves focus mode and is consumed. A late second
//! Escape re-arms instead. Any other key disarms. A held Escape's repeats and
//! a key-down seen twice (same timestamp) are consumed so they never count as
//! the second press.
//!
//! The app's key router owns one and sends it with each key-down
//! (`focus_escape_exit`); timestamps are the event's seconds since boot.

use serde::{Deserialize, Serialize};

/// Classic cmux's window between the two presses, in seconds.
pub const SEQUENCE_INTERVAL: f64 = 1.6;

/// What the key dispatcher does with the key.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "outcome", rename_all = "camelCase")]
pub enum Outcome {
    /// Not part of the gesture: route the key as usual.
    Pass,
    /// The first Escape: the page gets it, the exit is armed.
    ForwardToPage,
    /// The second Escape: leave focus mode for the tab; consume the key.
    Exit { tab: String },
    /// A repeat or a duplicate delivery of an Escape already counted.
    Consume,
}

/// One key-down, as the key router reads it.
#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Key {
    /// Escape with no modifier.
    pub is_plain_escape: bool,
    /// The key-down is an auto-repeat.
    pub is_repeat: bool,
    /// The event's timestamp (seconds since boot).
    pub timestamp: f64,
    /// The tab in browser focus mode that has the keyboard, none when none.
    #[serde(default)]
    pub focus_mode_tab: Option<String>,
}

/// The gesture's state.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct EscapeExit {
    /// The tab whose exit is armed, none when none is.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub armed_tab: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub armed_at: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_escape_timestamp: Option<f64>,
}

impl EscapeExit {
    /// Feeds one key-down.
    pub fn handle(&mut self, key: &Key) -> Outcome {
        let Some(tab) = key.focus_mode_tab.as_ref().filter(|_| key.is_plain_escape) else {
            self.reset();
            return Outcome::Pass;
        };
        if key.is_repeat {
            return Outcome::Consume;
        }
        if self.last_escape_timestamp == Some(key.timestamp) {
            return Outcome::Consume;
        }
        self.last_escape_timestamp = Some(key.timestamp);
        if self.armed_tab.as_ref() == Some(tab)
            && let Some(armed_at) = self.armed_at
            && key.timestamp - armed_at <= SEQUENCE_INTERVAL
        {
            self.reset();
            return Outcome::Exit { tab: tab.clone() };
        }
        self.armed_tab = Some(tab.clone());
        self.armed_at = Some(key.timestamp);
        Outcome::ForwardToPage
    }

    /// Disarms (focus mode ended, focus moved, a non-Escape key).
    pub fn reset(&mut self) {
        *self = Self::default();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn escape(timestamp: f64, tab: &str) -> Key {
        Key {
            is_plain_escape: true,
            is_repeat: false,
            timestamp,
            focus_mode_tab: Some(tab.to_owned()),
        }
    }

    fn exit(tab: &str) -> Outcome {
        Outcome::Exit { tab: tab.to_owned() }
    }

    #[test]
    fn esc_esc_leaves_focus_mode() {
        let mut gesture = EscapeExit::default();
        assert_eq!(gesture.handle(&escape(10.0, "tab_page")), Outcome::ForwardToPage);
        assert_eq!(gesture.armed_tab.as_deref(), Some("tab_page"));
        assert_eq!(gesture.handle(&escape(10.5, "tab_page")), exit("tab_page"));
        assert_eq!(gesture.armed_tab, None);
    }

    #[test]
    fn late_second_escape_rearms_instead_of_exiting() {
        let mut gesture = EscapeExit::default();
        assert_eq!(gesture.handle(&escape(10.0, "t")), Outcome::ForwardToPage);
        assert_eq!(gesture.handle(&escape(12.0, "t")), Outcome::ForwardToPage);
        assert_eq!(gesture.handle(&escape(13.0, "t")), exit("t"));
    }

    #[test]
    fn exactly_the_interval_still_exits() {
        let mut gesture = EscapeExit::default();
        gesture.handle(&escape(10.0, "t"));
        assert_eq!(gesture.handle(&escape(10.0 + SEQUENCE_INTERVAL, "t")), exit("t"));
    }

    #[test]
    fn other_key_disarms() {
        let mut gesture = EscapeExit::default();
        gesture.handle(&escape(10.0, "t"));
        let other = Key { is_plain_escape: false, ..escape(10.2, "t") };
        assert_eq!(gesture.handle(&other), Outcome::Pass);
        assert_eq!(gesture, EscapeExit::default());
        assert_eq!(gesture.handle(&escape(10.4, "t")), Outcome::ForwardToPage);
    }

    #[test]
    fn held_escape_never_counts_as_second_press() {
        let mut gesture = EscapeExit::default();
        gesture.handle(&escape(10.0, "t"));
        let held = Key { is_repeat: true, ..escape(10.1, "t") };
        assert_eq!(gesture.handle(&held), Outcome::Consume);
        // The same key-down seen twice (two hooks) is one press.
        assert_eq!(gesture.handle(&escape(10.0, "t")), Outcome::Consume);
        assert_eq!(gesture.armed_tab.as_deref(), Some("t"));
    }

    #[test]
    fn escape_outside_focus_mode_is_untouched() {
        let mut gesture = EscapeExit::default();
        let outside = Key { focus_mode_tab: None, ..escape(10.0, "t") };
        assert_eq!(gesture.handle(&outside), Outcome::Pass);
        assert_eq!(gesture.handle(&outside), Outcome::Pass);
    }

    #[test]
    fn armed_exit_belongs_to_one_tab() {
        let mut gesture = EscapeExit::default();
        assert_eq!(gesture.handle(&escape(10.0, "tab_a")), Outcome::ForwardToPage);
        assert_eq!(gesture.handle(&escape(10.3, "tab_b")), Outcome::ForwardToPage);
        assert_eq!(gesture.armed_tab.as_deref(), Some("tab_b"));
    }
}
