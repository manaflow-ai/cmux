//! Defaults that depend on the running build, not the schema (Swift `SettingsBuildDefaults`): a DEV build's
//! `mobile.allowIPhoneConnections` on, cmux NEXT's `updates.downloadAutomatically` on. The Mac app is their one
//! source: it passes them to its Rust children as `CMUX_NEXT_SETTINGS_BUILD_DEFAULTS`, a JSON object of dotted
//! keys, so `cmux settings get` and the MCP `settings_get` report the value the app uses.

use std::collections::BTreeMap;

use serde_json::Value;

use super::Schema;

/// The variable the Mac app sets for its children (`BuildStatePaths.settingsBuildDefaultsKey`).
pub const BUILD_DEFAULTS_ENV: &str = "CMUX_NEXT_SETTINGS_BUILD_DEFAULTS";

/// The defaults in `text` (the variable's value): a JSON object of dotted keys to values. Anything else
/// is none.
pub fn build_defaults_from(_text: Option<&str>) -> BTreeMap<String, Value> {
    BTreeMap::new()
}

impl Schema {
    /// This schema with `defaults` as the defaults of their rows.
    pub fn with_build_defaults(self, _defaults: &BTreeMap<String, Value>) -> Schema {
        self
    }
}
