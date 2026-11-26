//! The switches of browser sync, read from the effective settings root (`cmux-next.json`). Every one is off until
//! the person turns it on.

use serde_json::Value;

use crate::keys::EscrowPolicy;

/// `browser.sync.profiles`: push and pull the profile list and its bindings over the cmux account.
pub const PROFILES_KEY: &str = "browser.sync.profiles";

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct BrowserSyncSettings {
    pub profiles: bool,
    /// Never read from settings: the escrow question is Leo's ([irreversible] 2). Stays `None` until he rules.
    pub escrow: EscrowPolicy,
}

impl BrowserSyncSettings {
    /// Reads the switches from a settings root. Missing, `null` or anything but `true` is off.
    pub fn from_root(root: &Value) -> Self {
        Self { profiles: flag(root, PROFILES_KEY), escrow: EscrowPolicy::None }
    }
}

/// A boolean at a dotted path, as a nested object (`{"browser":{"sync":{"profiles":true}}}`) or a flat key
/// (`{"browser.sync.profiles": true}`).
fn flag(root: &Value, path: &str) -> bool {
    if root.get(path).and_then(Value::as_bool) == Some(true) {
        return true;
    }
    let mut node = root;
    for part in path.split('.') {
        match node.get(part) {
            Some(next) => node = next,
            None => return false,
        }
    }
    node.as_bool() == Some(true)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn profiles_sync_is_off_unless_set_true() {
        assert!(!BrowserSyncSettings::from_root(&json!({})).profiles);
        assert!(
            !BrowserSyncSettings::from_root(&json!({"browser": {"sync": {"profiles": "yes"}}}))
                .profiles
        );
        assert!(
            BrowserSyncSettings::from_root(&json!({"browser": {"sync": {"profiles": true}}}))
                .profiles
        );
        assert!(BrowserSyncSettings::from_root(&json!({"browser.sync.profiles": true})).profiles);
        assert_eq!(BrowserSyncSettings::default().escrow, EscrowPolicy::None);
    }
}
