//! The pane's access gate (Swift `ScreenshotsGate`): nothing is detected or listed until the person
//! clicks Show Screenshots in a pane, and a click is remembered so later panes start at once.
//!
//! The app keeps the remembered flag in its defaults under [`ACCESS_KEY`]; this type holds the
//! panes unlocked this launch and says what each pane does.

use std::collections::HashSet;

/// The defaults key remembering that the person clicked Show Screenshots.
pub const ACCESS_KEY: &str = "screenshots.showScreenshotsClicked";

/// The panes unlocked this launch.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Gate {
    unlocked: HashSet<String>,
}

impl Gate {
    /// Whether the pane `key` was unlocked this launch.
    pub fn is_unlocked(&self, key: &str) -> bool {
        self.unlocked.contains(key)
    }

    /// Whether sources may be detected (some pane is unlocked).
    pub fn may_detect(&self) -> bool {
        !self.unlocked.is_empty()
    }

    /// Unlocks the pane `key`; the app then remembers access (sets [`ACCESS_KEY`]).
    pub fn unlock(&mut self, key: &str) {
        self.unlocked.insert(key.to_owned());
    }

    /// Whether a pane shown now starts listing on its own: access is remembered and it is not
    /// unlocked yet (an unlocked pane already lists at once).
    pub fn starts_when_shown(&self, key: &str, remembers_access: bool) -> bool {
        remembers_access && !self.is_unlocked(key)
    }
}

#[cfg(test)]
#[path = "gate_tests.rs"]
mod tests;
