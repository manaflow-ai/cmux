//! The cache compaction's decisions (`cache_compact.rs`): the Settings keys, when its timer fires
//! for a usage report, and that its prompt is acpmux's own. The timer end to end, on the hub's
//! clock with the fake Claude: `tests/cache_compact.rs`.

use super::*;

const SOURCE: &str = include_str!("../../../../../schemas/settings/source/agent-cache.json");

fn row(key: &str) -> Value {
    let doc: Value = serde_json::from_str(SOURCE).unwrap();
    doc["lists"][0]["rows"].as_array().unwrap().iter().find(|r| r["key"] == key).unwrap().clone()
}

/// A share-only threshold at 50% (the token bar out of reach).
const HALF: Threshold = Threshold { share: 0.5, tokens: u64::MAX };

fn share(t: Option<Threshold>) -> Option<f64> {
    t.map(|t| t.share)
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
    assert_eq!(row(SETTING_MIN_TOKENS)["default"], json!(DEFAULT_MIN_TOKENS));
    assert_eq!(row(SETTING_MIN_TOKENS)["range"]["min"], json!(MIN_TOKENS_RANGE.0));
    assert_eq!(row(SETTING_MIN_TOKENS)["range"]["max"], json!(MIN_TOKENS_RANGE.1));
}

/// The autocompact cap acpmux's Claude Code chats ran with when the 30% trigger was measured
/// (2026-11-25): a context never grows past it, so a trigger above it never fires.
const AUTOCOMPACT_CAP: u64 = 178_500;

#[test]
fn the_default_trigger_fires_under_the_autocompact_cap_whatever_the_window() {
    // A percent of the reported window moved with the window: at 1M, 30% was 300K, past the cap,
    // and the timer never armed. The token bar keeps the default reachable on any window.
    let t = settings_threshold(None).unwrap();
    for window in [200_000, 400_000, 1_000_000, 2_000_000] {
        let trigger = (1..=AUTOCOMPACT_CAP).find(|&used| over((used, window), t));
        assert!(
            trigger.is_some_and(|at| at < AUTOCOMPACT_CAP),
            "{window}-token window: the default trigger ({trigger:?}) must sit under the cap"
        );
    }
    assert!(over((DEFAULT_MIN_TOKENS, 1_000_000), t), "60K of a 1M window compacts");
    assert!(!over((DEFAULT_MIN_TOKENS - 1, 1_000_000), t), "under both bars");
    assert!(over((30_000, 100_000), t), "on a 100K window 30% trips first");
    assert!(!over((29_999, 100_000), t), "under both bars");
}

#[test]
fn the_token_bar_is_a_setting_clamped_to_its_range() {
    let tokens = |doc: Value| settings_threshold(Some(&doc)).unwrap().tokens;
    assert_eq!(settings_threshold(None).unwrap().tokens, 60_000, "the default is 60K");
    assert_eq!(tokens(json!({"agents": {"cacheCompact": {"minContextTokens": 90_000}}})), 90_000);
    assert_eq!(tokens(json!({"agents.cacheCompact.minContextTokens": 1})), MIN_TOKENS_RANGE.0);
    assert_eq!(tokens(json!({"agents.cacheCompact.minContextTokens": 9e9})), MIN_TOKENS_RANGE.1);
    assert_eq!(tokens(json!({"agents.cacheCompact.minContextTokens": "x"})), 60_000, "junk");
}

#[test]
fn on_unless_turned_off() {
    assert_eq!(share(settings_threshold(None)), Some(0.3), "no settings file: the defaults");
    assert_eq!(share(settings_threshold(Some(&json!({})))), Some(0.3), "the default is on, at 30%");
    let junk = json!({"agents": {"cacheCompact": {"enabled": "no"}}});
    assert_eq!(share(settings_threshold(Some(&junk))), Some(0.3), "a non-bool is the default");
    let off = json!({"agents": {"cacheCompact": {"enabled": false}}});
    assert_eq!(share(settings_threshold(Some(&off))), None, "only an explicit false turns it off");
    let flat_off = json!({"agents.cacheCompact.enabled": false});
    assert_eq!(share(settings_threshold(Some(&flat_off))), None);
    let on = json!({"agents": {"cacheCompact": {"enabled": true}}});
    assert_eq!(share(settings_threshold(Some(&on))), Some(0.3), "the default threshold");
    let flat =
        json!({"agents.cacheCompact.enabled": true, "agents.cacheCompact.minContextPercent": 80});
    assert_eq!(share(settings_threshold(Some(&flat))), Some(0.8));
    let percent_only = json!({"agents": {"cacheCompact": {"minContextPercent": 60}}});
    assert_eq!(share(settings_threshold(Some(&percent_only))), Some(0.6), "on, at its own percent");
    let wild = json!({"agents": {"cacheCompact": {"enabled": true, "minContextPercent": 400}}});
    assert_eq!(share(settings_threshold(Some(&wild))), Some(0.95), "clamped to the range");
    let low = json!({"agents": {"cacheCompact": {"minContextPercent": 1}}});
    assert_eq!(share(settings_threshold(Some(&low))), Some(0.1), "clamped to the range");
}

#[test]
fn the_environment_beats_the_settings_file() {
    let env = |pairs: &'static [(&'static str, &'static str)]| {
        move |var: &str| pairs.iter().find(|(k, _)| *k == var).map(|(_, v)| v.to_string())
    };
    let off = json!({"agents": {"cacheCompact": {"enabled": false}}});
    assert_eq!(share(settings_threshold_with(Some(&off), env(&[(ENV_ENABLED, "1")]))), Some(0.3));
    assert_eq!(share(settings_threshold_with(None, env(&[(ENV_ENABLED, "0")]))), None);
    assert_eq!(share(settings_threshold_with(None, env(&[(ENV_ENABLED, "false")]))), None);
    let at_80 = json!({"agents": {"cacheCompact": {"minContextPercent": 80}}});
    let env_50 = env(&[(ENV_MIN_CONTEXT, "50")]);
    assert_eq!(share(settings_threshold_with(Some(&at_80), env_50)), Some(0.5));
    assert_eq!(share(settings_threshold_with(None, env(&[(ENV_MIN_CONTEXT, "400")]))), Some(0.95));
    let junk = env(&[(ENV_MIN_CONTEXT, "lots"), (ENV_ENABLED, "maybe")]);
    assert_eq!(
        share(settings_threshold_with(Some(&at_80), junk)),
        Some(0.8),
        "junk: the file decides"
    );
    let note = |key: &str| row(key)["note"].as_str().unwrap().to_owned();
    assert!(note(SETTING_ENABLED).contains(ENV_ENABLED), "the note names its env");
    assert!(note(SETTING_MIN_CONTEXT).contains(ENV_MIN_CONTEXT), "the note names its env");
    assert!(note(SETTING_MIN_TOKENS).contains(ENV_MIN_TOKENS), "the note names its env");
    let at_90k = json!({"agents": {"cacheCompact": {"minContextTokens": 90_000}}});
    let t = settings_threshold_with(Some(&at_90k), env(&[(ENV_MIN_TOKENS, "70000")])).unwrap();
    assert_eq!(t.tokens, 70_000, "ACPMUX_CACHE_COMPACT_MIN_CONTEXT_TOKENS beats the file");
    let t = settings_threshold_with(Some(&at_90k), env(&[(ENV_MIN_TOKENS, "lots")])).unwrap();
    assert_eq!(t.tokens, 90_000, "junk: the file decides");
}

#[test]
fn it_fires_the_lead_before_the_expiry_only_over_the_threshold() {
    let now = 1_000_000;
    let expires = now + 300_000;
    assert_eq!(
        wait_ms(&usage(150_000, 200_000, Some(expires)), HALF, now),
        Some(300_000 - LEAD_MS)
    );
    assert_eq!(wait_ms(&usage(100_000, 200_000, Some(expires)), HALF, now), Some(270_000), "at it");
    assert_eq!(wait_ms(&usage(99_999, 200_000, Some(expires)), HALF, now), None, "under it");
    assert_eq!(wait_ms(&usage(150_000, 200_000, None), HALF, now), None, "no cache expiry");
    assert_eq!(wait_ms(&usage(150_000, 0, Some(expires)), HALF, now), None, "no window, no bar");
    let bar = Threshold { share: 0.5, tokens: 120_000 };
    let at_bar = Some(300_000 - LEAD_MS);
    assert_eq!(wait_ms(&usage(150_000, 0, Some(expires)), bar, now), at_bar, "no window: the bar");
    let big = usage(120_000, 1_000_000, Some(expires));
    assert_eq!(wait_ms(&big, bar, now), at_bar, "the token bar trips first");
    let both_under = usage(119_999, 1_000_000, Some(expires));
    assert_eq!(wait_ms(&both_under, bar, now), None, "under both");
    let close = usage(150_000, 200_000, Some(now + LEAD_MS - 1));
    assert_eq!(wait_ms(&close, HALF, now), None, "too late to run while the cache is warm");
    assert_eq!(wait_ms(&usage(150_000, 200_000, Some(now + LEAD_MS)), HALF, now), None);
}

#[test]
fn a_one_hour_cache_compacts_three_minutes_before_its_expiry() {
    let now = 1_000_000;
    let hour = now + 3_600_000;
    assert_eq!(lead_ms(3_600_000), LONG_LEAD_MS);
    assert_eq!(lead_ms(300_000), LEAD_MS, "a 5-minute cache keeps its 30 s");
    assert_eq!(wait_ms(&usage(150_000, 200_000, Some(hour)), HALF, now), Some(3_600_000 - 180_000));
}

#[test]
fn its_prompt_is_acpmuxs_own_not_the_persons() {
    let ours = json!({"kind": KIND});
    assert!(!super::super::inbox::persons_prompt(None, Some(&ours)));
    assert!(super::super::inbox::persons_prompt(None, None));
}

/// What surgery must reach to stand in for the timer's `/compact`: under whichever of the token
/// bar and the window's share trips first.
#[test]
fn compact_line_is_the_lower_bar() {
    let t = Threshold { share: 0.3, tokens: 60_000 };
    assert_eq!(compact_line((100_000, 1_000_000), t), 60_000);
    assert_eq!(compact_line((100_000, 100_000), t), 30_000);
    assert_eq!(compact_line((100_000, 0), t), 60_000);
    assert_eq!(compact_line((100_000, 1_000_000), HALF), 500_000);
}
