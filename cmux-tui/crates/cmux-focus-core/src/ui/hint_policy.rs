//! When a held modifier shows the shortcut hints (Swift
//! `ShortcutHintModifierPolicy`): Command, Control or Option (Shift only
//! with one of them) held for the intentional hold delay, and no other key
//! pressed during the hold. A key that keeps the hints (pane navigation)
//! leaves them up.
//!
//! Flags are `NSEvent.ModifierFlags` raw bits.

use serde::{Deserialize, Serialize};

pub const SHIFT: u64 = 1 << 17;
pub const CONTROL: u64 = 1 << 18;
pub const OPTION: u64 = 1 << 19;
pub const COMMAND: u64 = 1 << 20;
const MODIFIERS: u64 = COMMAND | CONTROL | SHIFT | OPTION;
const ARMING: u64 = COMMAND | CONTROL | OPTION;

/// How long a modifier is held before the hints show.
pub const INTENTIONAL_HOLD_DELAY_NS: i64 = 300 * 1_000_000;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ShortcutHintPolicy {
    pub suppressed: bool,
    pub held: bool,
}

impl ShortcutHintPolicy {
    /// A key went down; unless it keeps the hints, they stay hidden until
    /// the held modifiers are released.
    pub fn key_down(&mut self, keeps_hints: bool) {
        if !keeps_hints {
            self.suppressed = self.held;
        }
    }

    /// The held modifiers that show hints: the four modifiers in `flags`,
    /// or `None` when none of Command, Control and Option is held.
    pub fn armed(flags: u64) -> Option<u64> {
        let modifiers = flags & MODIFIERS;
        (modifiers & ARMING != 0).then_some(modifiers)
    }

    /// The modifiers changed (or the hold timer fired): whether the hints show.
    pub fn update(&mut self, flags: u64, eligible: bool, elapsed_ns: i64) -> bool {
        self.held = flags & MODIFIERS != 0;
        if !self.held {
            self.suppressed = false;
        }
        eligible
            && !self.suppressed
            && Self::armed(flags).is_some()
            && elapsed_ns >= INTENTIONAL_HOLD_DELAY_NS
    }
}

#[cfg(test)]
#[path = "hint_policy_tests.rs"]
mod tests;
