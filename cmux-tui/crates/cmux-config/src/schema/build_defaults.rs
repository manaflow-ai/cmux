//! Defaults that depend on the running build, not the schema (Swift `SettingsBuildDefaults`): a DEV build's
//! `mobile.allowIPhoneConnections` on, cmux NEXT's `updates.downloadAutomatically` on. The Mac app is their one
//! source: it passes them to its Rust children as `CMUX_NEXT_SETTINGS_BUILD_DEFAULTS`, a JSON object of dotted
//! keys, so `cmux settings get` and the MCP `settings_get` report the value the app uses. A build default is the
//! row's default (what `get` and `list` report, what `customized` and a write of the default compare against) and
//! fills the effective settings below every layer, as Swift's `SettingsBuildDefaults.filling` does.

use std::collections::BTreeMap;

use serde_json::Value;

use super::Schema;
use crate::domains::Domains;

/// The variable the Mac app sets for its children (`BuildStatePaths.settingsBuildDefaultsKey`).
pub const BUILD_DEFAULTS_ENV: &str = "CMUX_NEXT_SETTINGS_BUILD_DEFAULTS";

/// The defaults in `text` (the variable's value): a JSON object of dotted keys to values. Anything else
/// is none.
pub fn build_defaults_from(text: Option<&str>) -> BTreeMap<String, Value> {
    match text.map(str::trim).filter(|text| !text.is_empty()).map(serde_json::from_str::<Value>) {
        Some(Ok(Value::Object(members))) => members.into_iter().collect(),
        _ => BTreeMap::new(),
    }
}

impl Schema {
    /// This schema with `defaults` as the defaults of their rows. A key no row has and a value its row refuses
    /// are left out, so a build default can never make a value the schema would not take.
    pub fn with_build_defaults(mut self, defaults: &BTreeMap<String, Value>) -> Schema {
        for (key, value) in defaults {
            let Some(index) = self.by_key.get(key).copied() else { continue };
            let Some(row) = self.rows.get_mut(index) else { continue };
            if super::accepts(row, value, &Domains::default()).is_err() {
                continue;
            }
            row.default = Some(value.clone());
            self.build_defaults.insert(key.clone(), value.clone());
        }
        self
    }

    /// The build defaults this schema applies (dotted key to value).
    pub fn build_defaults(&self) -> &BTreeMap<String, Value> {
        &self.build_defaults
    }
}
