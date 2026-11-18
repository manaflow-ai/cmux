//! The Labs switch `labs.gcpMachineProvider`, off by default. A settings
//! file that is missing, unreadable or lacks the key leaves it off.

use crate::contract::ProviderError;
use cmux_config::{jsonc, location};
use serde_json::Value;
use std::path::Path;

pub const KEY: &str = "labs.gcpMachineProvider";

/// Proof that the switch was on when it was read. `GcpProvider::new` takes
/// one, so no provider (and no call) exists while the switch is off; only
/// the `require` functions make one.
#[derive(Debug, Clone, Copy)]
pub struct Enabled(());

/// The switch from the settings file at its usual place.
pub fn require() -> Result<Enabled, ProviderError> {
    let text = std::fs::read_to_string(location::config_path()).unwrap_or_default();
    require_in_text(&text)
}

/// The switch from settings text (either form the settings owner writes:
/// nested `labs` or one flat key).
pub fn require_in_text(text: &str) -> Result<Enabled, ProviderError> {
    if enabled_in_text(text) {
        Ok(Enabled(()))
    } else {
        Err(ProviderError::Refused(format!(
            "the GCP machine provider is a Labs feature and {KEY} is off"
        )))
    }
}

pub fn enabled_in(path: &Path) -> bool {
    std::fs::read_to_string(path).ok().is_some_and(|text| enabled_in_text(&text))
}

pub fn enabled_in_text(text: &str) -> bool {
    let Some(doc) = jsonc::strip(text).ok().and_then(|t| serde_json::from_str::<Value>(&t).ok())
    else {
        return false;
    };
    let value = doc.get(KEY).or_else(|| doc.pointer("/labs/gcpMachineProvider"));
    value == Some(&Value::Bool(true))
}
