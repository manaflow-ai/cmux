use super::*;
use serde_json::json;

const SOURCE: &str = include_str!("../../../../../../schemas/settings/source/agent-retry.json");

fn row(key: &str) -> Value {
    let doc: Value = serde_json::from_str(SOURCE).unwrap();
    doc["lists"][0]["rows"].as_array().unwrap().iter().find(|r| r["key"] == key).unwrap().clone()
}

#[test]
fn the_settings_source_matches_the_daemon_loop() {
    assert_eq!(row(SETTING_ENABLED)["default"], json!(true));
    assert_eq!(row(SETTING_INTERVAL)["default"], json!(0));
    assert_eq!(row(SETTING_INTERVAL)["range"]["max"], json!(MAX_DELAY_MS / 1000));
    assert_eq!(row(SETTING_ATTEMPTS)["default"], json!(DEFAULT_DELAYS_MS.len()));
    assert_eq!(row(SETTING_ATTEMPTS)["range"]["max"], json!(MAX_CONFIGURED_ATTEMPTS));
    // The defaults give exactly the waits a file without the keys gives.
    let defaults =
        json!({"agents": {"autoRetry": {"enabled": true, "intervalSeconds": 0, "attempts": 4}}});
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
    let dotted = json!({"agents.autoRetry.intervalSeconds": 45.9, "agents.autoRetry.attempts": 2});
    assert_eq!(settings_delays(&dotted), vec![45_000; 2]);
}

#[test]
fn no_interval_grows_the_waits_and_repeats_the_last() {
    let doc = json!({"agents": {"autoRetry": {"attempts": 6}}});
    assert_eq!(
        settings_delays(&doc),
        vec![10_000, 60_000, 300_000, 1_200_000, 1_200_000, 1_200_000]
    );
    assert_eq!(settings_delays(&json!({"agents": {"autoRetry": {"attempts": 1}}})), vec![10_000]);
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
