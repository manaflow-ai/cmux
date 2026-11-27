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
    assert_eq!(row(SETTING_ENABLED)["default"], json!(false), "opt-in (Leo)");
    assert_eq!(row(SETTING_MIN_CONTEXT)["default"], json!(50));
    assert_eq!(row(SETTING_MIN_CONTEXT)["range"]["min"], json!(10));
    assert_eq!(row(SETTING_MIN_CONTEXT)["range"]["max"], json!(95));
}

#[test]
fn off_unless_turned_on() {
    assert_eq!(settings_threshold(None), None, "no settings file");
    assert_eq!(settings_threshold(Some(&json!({}))), None, "the default is off");
    let off = json!({"agents": {"cacheCompact": {"enabled": false}}});
    assert_eq!(settings_threshold(Some(&off)), None);
    let on = json!({"agents": {"cacheCompact": {"enabled": true}}});
    assert_eq!(settings_threshold(Some(&on)), Some(0.5), "the default threshold");
    let flat =
        json!({"agents.cacheCompact.enabled": true, "agents.cacheCompact.minContextPercent": 80});
    assert_eq!(settings_threshold(Some(&flat)), Some(0.8));
    let wild = json!({"agents": {"cacheCompact": {"enabled": true, "minContextPercent": 400}}});
    assert_eq!(settings_threshold(Some(&wild)), Some(0.95), "clamped to the range");
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
fn its_prompt_is_acpmuxs_own_not_the_persons() {
    let ours = json!({"kind": KIND});
    assert!(!super::super::inbox::persons_prompt(None, Some(&ours)));
    assert!(super::super::inbox::persons_prompt(None, None));
}
