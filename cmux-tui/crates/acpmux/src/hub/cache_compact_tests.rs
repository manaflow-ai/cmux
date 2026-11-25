//! The cache compaction's decisions (`cache_compact.rs`): the Settings keys, when its timer fires
//! for a usage report, and that its prompt is acpmux's own. The timer end to end, on the hub's
//! clock with the fake Claude: `tests/cache_compact.rs`.

use super::*;

const SOURCE: &str = include_str!("../../../../../schemas/settings/source/agent-cache.json");

fn row(key: &str) -> Value {
    let doc: Value = serde_json::from_str(SOURCE).unwrap();
    doc["lists"][0]["rows"].as_array().unwrap().iter().find(|r| r["key"] == key).unwrap().clone()
}

fn usage(used: u64, size: u64, expires: Option<u64>) -> Value {
    let mut u = json!({"sessionUpdate": "usage_update", "used": used, "size": size});
    if let Some(at) = expires {
        u["_meta"] = json!({"acpmux": {"cacheExpiresAt": at}});
    }
    u
}

#[test]
fn the_settings_source_matches_the_daemon() {
    assert_eq!(row(SETTING_ENABLED)["default"], json!(true), "on by default (Leo, 2026-11-24)");
    assert_eq!(row(SETTING_MIN_CONTEXT)["default"], json!(30));
    assert_eq!(row(SETTING_MIN_CONTEXT)["range"]["min"], json!(10));
    assert_eq!(row(SETTING_MIN_CONTEXT)["range"]["max"], json!(95));
}

#[test]
fn on_unless_turned_off() {
    assert_eq!(settings_threshold(None), Some(0.3), "no settings file: the defaults");
    assert_eq!(settings_threshold(Some(&json!({}))), Some(0.3), "the default is on, at 30%");
    let junk = json!({"agents": {"cacheCompact": {"enabled": "no"}}});
    assert_eq!(settings_threshold(Some(&junk)), Some(0.3), "a non-bool is the default");
    let off = json!({"agents": {"cacheCompact": {"enabled": false}}});
    assert_eq!(settings_threshold(Some(&off)), None, "only an explicit false turns it off");
    let flat_off = json!({"agents.cacheCompact.enabled": false});
    assert_eq!(settings_threshold(Some(&flat_off)), None);
    let on = json!({"agents": {"cacheCompact": {"enabled": true}}});
    assert_eq!(settings_threshold(Some(&on)), Some(0.3), "the default threshold");
    let flat =
        json!({"agents.cacheCompact.enabled": true, "agents.cacheCompact.minContextPercent": 80});
    assert_eq!(settings_threshold(Some(&flat)), Some(0.8));
    let percent_only = json!({"agents": {"cacheCompact": {"minContextPercent": 60}}});
    assert_eq!(settings_threshold(Some(&percent_only)), Some(0.6), "on, at its own percent");
    let wild = json!({"agents": {"cacheCompact": {"enabled": true, "minContextPercent": 400}}});
    assert_eq!(settings_threshold(Some(&wild)), Some(0.95), "clamped to the range");
    let low = json!({"agents": {"cacheCompact": {"minContextPercent": 1}}});
    assert_eq!(settings_threshold(Some(&low)), Some(0.1), "clamped to the range");
}

#[test]
fn the_environment_beats_the_settings_file() {
    let env = |pairs: &'static [(&'static str, &'static str)]| {
        move |var: &str| pairs.iter().find(|(k, _)| *k == var).map(|(_, v)| v.to_string())
    };
    let off = json!({"agents": {"cacheCompact": {"enabled": false}}});
    assert_eq!(settings_threshold_with(Some(&off), env(&[(ENV_ENABLED, "1")])), Some(0.3));
    assert_eq!(settings_threshold_with(None, env(&[(ENV_ENABLED, "0")])), None);
    assert_eq!(settings_threshold_with(None, env(&[(ENV_ENABLED, "false")])), None);
    let at_80 = json!({"agents": {"cacheCompact": {"minContextPercent": 80}}});
    let env_50 = env(&[(ENV_MIN_CONTEXT, "50")]);
    assert_eq!(settings_threshold_with(Some(&at_80), env_50), Some(0.5));
    assert_eq!(settings_threshold_with(None, env(&[(ENV_MIN_CONTEXT, "400")])), Some(0.95));
    let junk = env(&[(ENV_MIN_CONTEXT, "lots"), (ENV_ENABLED, "maybe")]);
    assert_eq!(settings_threshold_with(Some(&at_80), junk), Some(0.8), "junk: the file decides");
    let note = |key: &str| row(key)["note"].as_str().unwrap().to_owned();
    assert!(note(SETTING_ENABLED).contains(ENV_ENABLED), "the note names its env");
    assert!(note(SETTING_MIN_CONTEXT).contains(ENV_MIN_CONTEXT), "the note names its env");
}

#[test]
fn it_fires_the_lead_before_the_expiry_only_over_the_threshold() {
    let now = 1_000_000;
    let expires = now + 300_000;
    assert_eq!(wait_ms(&usage(150_000, 200_000, Some(expires)), 0.5, now), Some(300_000 - LEAD_MS));
    assert_eq!(wait_ms(&usage(100_000, 200_000, Some(expires)), 0.5, now), Some(270_000), "at it");
    assert_eq!(wait_ms(&usage(99_999, 200_000, Some(expires)), 0.5, now), None, "under it");
    assert_eq!(wait_ms(&usage(150_000, 200_000, None), 0.5, now), None, "no cache expiry");
    assert_eq!(wait_ms(&usage(150_000, 0, Some(expires)), 0.5, now), None, "no window");
    let close = usage(150_000, 200_000, Some(now + LEAD_MS - 1));
    assert_eq!(wait_ms(&close, 0.5, now), None, "too late to run while the cache is warm");
    assert_eq!(wait_ms(&usage(150_000, 200_000, Some(now + LEAD_MS)), 0.5, now), None);
}

#[test]
fn a_one_hour_cache_compacts_three_minutes_before_its_expiry() {
    let now = 1_000_000;
    let hour = now + 3_600_000;
    assert_eq!(lead_ms(3_600_000), LONG_LEAD_MS);
    assert_eq!(lead_ms(300_000), LEAD_MS, "a 5-minute cache keeps its 30 s");
    assert_eq!(wait_ms(&usage(150_000, 200_000, Some(hour)), 0.5, now), Some(3_600_000 - 180_000));
}

#[test]
fn its_prompt_is_acpmuxs_own_not_the_persons() {
    let ours = json!({"kind": KIND});
    assert!(!super::super::inbox::persons_prompt(None, Some(&ours)));
    assert!(super::super::inbox::persons_prompt(None, None));
}
