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
            0 => DEFAULT_DELAYS_MS[n.min(DEFAULT_DELAYS_MS.len() - 1)],
            ms => ms.max(MIN_DELAY_MS),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const SOURCE: &str = include_str!("../../../../../../schemas/settings/source/agent-retry.json");

    fn row(key: &str) -> Value {
        let doc: Value = serde_json::from_str(SOURCE).unwrap();
        doc["lists"][0]["rows"]
            .as_array()
            .unwrap()
            .iter()
            .find(|r| r["key"] == key)
            .unwrap()
            .clone()
    }

    #[test]
    fn the_settings_source_matches_the_daemon_loop() {
        assert_eq!(row(SETTING_ENABLED)["default"], json!(true));
        assert_eq!(row(SETTING_INTERVAL)["default"], json!(0));
        assert_eq!(row(SETTING_INTERVAL)["range"]["max"], json!(MAX_DELAY_MS / 1000));
        assert_eq!(row(SETTING_ATTEMPTS)["default"], json!(DEFAULT_DELAYS_MS.len()));
        assert_eq!(row(SETTING_ATTEMPTS)["range"]["max"], json!(MAX_CONFIGURED_ATTEMPTS));
        // The defaults give exactly the waits a file without the keys gives.
        let defaults = json!({"agents": {"autoRetry": {"enabled": true, "intervalSeconds": 0, "attempts": 4}}});
        assert_eq!(settings_delays(&defaults), DEFAULT_DELAYS_MS.to_vec());
        assert_eq!(settings_delays(&json!({})), DEFAULT_DELAYS_MS.to_vec());
    }

    #[test]
    fn off_schedules_no_attempt() {
        let doc = json!({"agents": {"autoRetry": {"enabled": false, "intervalSeconds": 30}}});
        assert!(settings_delays(&doc).is_empty());
    }

    #[test]
    fn an_interval_waits_that_long_before_every_attempt() {
        let doc = json!({"agents": {"autoRetry": {"intervalSeconds": 30, "attempts": 6}}});
        assert_eq!(settings_delays(&doc), vec![30_000; 6]);
        // The dotted form the app may write reads the same.
        let dotted =
            json!({"agents.autoRetry.intervalSeconds": 45.9, "agents.autoRetry.attempts": 2});
        assert_eq!(settings_delays(&dotted), vec![45_000; 2]);
    }

    #[test]
    fn no_interval_grows_the_waits_and_repeats_the_last() {
        let doc = json!({"agents": {"autoRetry": {"attempts": 6}}});
        assert_eq!(
            settings_delays(&doc),
            vec![10_000, 60_000, 300_000, 1_200_000, 1_200_000, 1_200_000]
        );
        assert_eq!(
            settings_delays(&json!({"agents": {"autoRetry": {"attempts": 1}}})),
            vec![10_000]
        );
    }

    #[test]
    fn values_are_held_to_the_settings_ranges() {
        let doc = json!({"agents": {"autoRetry": {"intervalSeconds": 99_999, "attempts": 500}}});
        assert_eq!(settings_delays(&doc), vec![MAX_DELAY_MS; MAX_CONFIGURED_ATTEMPTS]);
        let low = json!({"agents": {"autoRetry": {"intervalSeconds": -5, "attempts": 0}}});
        assert_eq!(settings_delays(&low), vec![DEFAULT_DELAYS_MS[0]]);
        let junk = json!({"agents": {"autoRetry": {"enabled": "no", "intervalSeconds": "x"}}});
        assert_eq!(settings_delays(&junk), DEFAULT_DELAYS_MS.to_vec());
    }

    #[test]
    fn config_json_comes_before_the_settings() {
        assert_eq!(effective_delays(Some(vec![])), Vec::<u64>::new());
        assert_eq!(effective_delays(Some(vec![5_000])), vec![5_000]);
    }
}
