//! The one rule for Chromium's saved-password filling in a tab (plans/cmux-next/passwords.md,
//! slice 1; `PasswordFillPolicy`). An agent-driven tab never fills (an automated click is a user
//! gesture that would release a filled password to page script); a tab whose profile does not
//! allow it never fills (an extension is the profile's password manager, or the person turned
//! autofill off); otherwise Chromium's default, fill. Every caller of the fork's per-tab switch
//! (`cmux_tab_set_password_fill`) goes through it.

use serde::{Deserialize, Serialize};

/// Whether a tab fills saved passwords.
pub fn fills(agent_driven: bool, profile_allows: bool) -> bool {
    !agent_driven && profile_allows
}

/// One tab's input to [`fills`] from its profile, and what the tab last sent to Chromium's switch
/// (`PasswordFillState`). Chromium fills by default, so a tab that fills and was never turned off
/// sends nothing.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PasswordFillState {
    #[serde(default = "default_true")]
    pub allowed_by_profile: bool,
    #[serde(default)]
    pub switched_off: bool,
}

fn default_true() -> bool {
    true
}

impl Default for PasswordFillState {
    fn default() -> Self {
        PasswordFillState { allowed_by_profile: true, switched_off: false }
    }
}

impl PasswordFillState {
    pub fn new(allowed_by_profile: bool) -> Self {
        PasswordFillState { allowed_by_profile, switched_off: false }
    }

    pub fn fills(&self, agent_driven: bool) -> bool {
        fills(agent_driven, self.allowed_by_profile)
    }

    /// True when the value changed.
    pub fn set_allowed_by_profile(&mut self, allowed: bool) -> bool {
        let changed = allowed != self.allowed_by_profile;
        self.allowed_by_profile = allowed;
        changed
    }

    /// The switch value to send now (1 fill, 0 do not), or `None` when Chromium already has it.
    pub fn next_switch_value(&mut self, agent_driven: bool) -> Option<i32> {
        let fills = self.fills(agent_driven);
        // Send only a change: on while switched off, or off while still on.
        if fills != self.switched_off {
            return None;
        }
        self.switched_off = !fills;
        Some(i32::from(fills))
    }
}
