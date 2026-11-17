//! The Labs switch `labs.gcpMachineProvider`, off by default. A settings
//! file that is missing, unreadable or lacks the key leaves it off.

use cmux_config::{jsonc, location};
use serde_json::Value;
use std::path::Path;

pub const KEY: &str = "labs.gcpMachineProvider";

/// Whether the settings file at its usual place turns the provider on.
pub fn enabled() -> bool {
    enabled_in(&location::config_path())
}

pub fn enabled_in(path: &Path) -> bool {
    std::fs::read_to_string(path).ok().is_some_and(|text| enabled_in_text(&text))
}

/// Either form the settings owner writes: nested `labs` or one flat key.
pub fn enabled_in_text(text: &str) -> bool {
    let Some(doc) = jsonc::strip(text).ok().and_then(|t| serde_json::from_str::<Value>(&t).ok())
    else {
        return false;
    };
    let value = doc.get(KEY).or_else(|| doc.pointer("/labs/gcpMachineProvider"));
    value == Some(&Value::Bool(true))
}
