//! cmux.json keys cmux used to read and no longer does (Swift
//! `SettingsSchema.retiredKeys`, SettingsSchema+Retired.swift). The export
//! does not list them, so the table is mirrored here. Loading ignores them
//! without a diagnostic; a write is refused as removed; a reset cleans an
//! old file.

/// Retired dotted key and why.
pub const RETIRED_KEYS: [(&str, &str); 2] = [
    ("appearance.tabBarBackground", "every surface draws the one window background"),
    ("updates.quietHours", "a staged update shows only the small control on Settings"),
];

/// The reason `path` was retired, or `None` when it is not retired.
pub fn retired_reason(path: &[String]) -> Option<&'static str> {
    let dotted = path.join(".");
    RETIRED_KEYS.iter().find(|(key, _)| *key == dotted).map(|(_, reason)| *reason)
}
