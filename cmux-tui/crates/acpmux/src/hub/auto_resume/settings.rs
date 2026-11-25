//! The retry loop as the person sets it in Settings > Agents > Retry After Errors (Lawrence via
//! Leo, 2026-10-28: "should have retry button + configurable timer loop retry"): the
//! `agents.autoRetry.*` keys of the settings file (`crate::user_settings`), whose defaults and
//! ranges are `schemas/settings/source/agent-retry.json`. Read at each retry, so a change applies
//! to the next failed turn. `autoResumeDelaysMs` in config.json, when it is set, comes first.

use super::{DEFAULT_DELAYS_MS, MAX_CONFIGURED_ATTEMPTS, MAX_DELAY_MS, MIN_DELAY_MS};
use serde_json::Value;

pub const SETTING_ENABLED: &str = "agents.autoRetry.enabled";
pub const SETTING_INTERVAL: &str = "agents.autoRetry.intervalSeconds";
pub const SETTING_ATTEMPTS: &str = "agents.autoRetry.attempts";

/// The waits in force, one per attempt: `configured` (config.json's `autoResumeDelaysMs`) when
/// set, else the settings file's, else the default. A settings file that cannot be read keeps
/// the default waits.
pub(in crate::hub) fn effective_delays(configured: Option<Vec<u64>>) -> Vec<u64> {
    configured.unwrap_or_else(|| match crate::user_settings::read() {
        crate::user_settings::Settings::Parsed(doc) => settings_delays(&doc),
        _ => DEFAULT_DELAYS_MS.to_vec(),
    })
}

/// The waits the Settings keys give: none when off; with an interval of 0 the default's growing
/// waits (the last one repeated past them), else that many seconds before every attempt.
/// Numbers are clamped to the Settings ranges, a fraction rounded down, as the app reads them.
fn settings_delays(doc: &Value) -> Vec<u64> {
    let get = |key: &str| crate::user_settings::value(doc, key);
    if get(SETTING_ENABLED).and_then(|v| v.as_bool()) == Some(false) {
        return Vec::new();
    }
    let number = |key: &str| get(key).and_then(|v| v.as_f64()).filter(|n| n.is_finite());
    let attempts = number(SETTING_ATTEMPTS).map_or(DEFAULT_DELAYS_MS.len(), |n| {
        n.floor().clamp(1.0, MAX_CONFIGURED_ATTEMPTS as f64) as usize
    });
    let interval_ms = number(SETTING_INTERVAL)
        .map_or(0, |n| n.floor().clamp(0.0, (MAX_DELAY_MS / 1000) as f64) as u64 * 1000);
    (0..attempts)
        .map(|n| match interval_ms {
            // Past the defaults the last wait repeats; the array is never empty.
            0 => DEFAULT_DELAYS_MS
                .get(n)
                .or(DEFAULT_DELAYS_MS.last())
                .copied()
                .unwrap_or(MIN_DELAY_MS),
            ms => ms.max(MIN_DELAY_MS),
        })
        .collect()
}

#[cfg(test)]
#[path = "settings_tests.rs"]
mod tests;
