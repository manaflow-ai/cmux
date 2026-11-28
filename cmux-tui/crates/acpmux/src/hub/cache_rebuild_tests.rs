use super::*;

const MODEL: &str = "claude-opus-4-5";
const MIN: u64 = 60_000;

fn turn(context: u64, writes: u64, writes_1h: u64) -> Map<String, Value> {
    json!({"model": MODEL, "contextTokens": context, "cacheWriteTokens": writes,
           "cacheWrite1hTokens": writes_1h})
    .as_object()
    .cloned()
    .unwrap()
}

fn after(context: u64, ended_ms: u64) -> CacheRebuildState {
    CacheRebuildState {
        last: Some(LastTurnCache { context_tokens: context, ended_ms }),
        total_usd: None,
    }
}

#[test]
fn a_first_turn_has_nothing_to_compare_and_keeps_its_context() {
    let (out, next) = rebuild_fields(&turn(120_000, 120_000, 120_000), 1_000, Default::default());
    assert!(out.is_empty(), "{out:?}");
    assert_eq!(next.last, Some(LastTurnCache { context_tokens: 120_000, ended_ms: 1_000 }));
}

#[test]
fn a_warm_turn_writes_only_what_its_context_grew() {
    // 100k before, 110k after, 11k written (the new tail plus a little): no rebuild.
    let (out, next) = rebuild_fields(&turn(110_000, 11_000, 11_000), 2 * MIN, after(100_000, MIN));
    assert!(out.is_empty(), "{out:?}");
    assert_eq!(next.total_usd, None);
}

#[test]
fn a_return_after_forty_minutes_rebuilds_the_whole_context_as_idle() {
    let (out, next) =
        rebuild_fields(&turn(110_000, 110_000, 110_000), 41 * MIN, after(100_000, MIN));
    assert_eq!(out["cacheRebuildTokens"], json!(100_000));
    assert_eq!(out["cacheRebuildCause"], json!("idle"));
    assert_eq!(out["cacheIdleSeconds"], json!(40 * 60));
    let (_, p) = crate::pricing::table().lookup(MODEL).unwrap();
    let want = 100_000.0 * (p.cache_write_1h_rate() - p.cache_read.unwrap()) / 1e6;
    let got = out["cacheRebuildUsd"].as_f64().unwrap();
    assert!(got > 0.0 && (got - want).abs() < 1e-6, "{got} vs {want}");
    assert_eq!(out["sessionCacheRebuildUsd"], out["cacheRebuildUsd"]);
    assert!((next.total_usd.unwrap() - want).abs() < 1e-6);
}

#[test]
fn a_rebuild_inside_the_cache_life_is_a_changed_prefix() {
    let (out, _) = rebuild_fields(&turn(101_000, 101_000, 101_000), 3 * MIN, after(100_000, MIN));
    assert_eq!(out["cacheRebuildCause"], json!("prefix"));
}

#[test]
fn five_minute_writes_go_cold_after_five_minutes() {
    let (out, _) = rebuild_fields(&turn(101_000, 101_000, 0), 7 * MIN, after(100_000, MIN));
    assert_eq!(out["cacheRebuildCause"], json!("idle"));
}

#[test]
fn a_shrunken_context_is_a_compaction() {
    let (out, _) = rebuild_fields(&turn(30_000, 60_000, 60_000), 2 * MIN, after(100_000, MIN));
    assert_eq!(out["cacheRebuildCause"], json!("compaction"));
    assert_eq!(out["cacheRebuildTokens"], json!(60_000));
}

#[test]
fn a_small_context_is_cheap_to_write_again_and_not_flagged() {
    let (out, _) = rebuild_fields(&turn(15_000, 15_000, 15_000), 90 * MIN, after(10_000, MIN));
    assert!(out.is_empty(), "{out:?}");
}

#[test]
fn the_session_total_adds_up_and_an_unknown_model_is_unpriced() {
    let mut state = after(100_000, MIN);
    state.total_usd = Some(1.0);
    let (out, next) = rebuild_fields(&turn(100_000, 100_000, 100_000), 90 * MIN, state);
    assert!(out["sessionCacheRebuildUsd"].as_f64().unwrap() > 1.0);
    assert!(next.total_usd.unwrap() > 1.0);

    let mut unknown = turn(100_000, 100_000, 100_000);
    unknown.insert("model".into(), json!("no-such-model-x"));
    let (out, next) = rebuild_fields(&unknown, 90 * MIN, after(100_000, MIN));
    assert_eq!(out["cacheRebuildTokens"], json!(100_000));
    assert!(out.get("cacheRebuildUsd").is_none(), "unpriced, never 0");
    assert_eq!(next.total_usd, None);
}

#[test]
fn a_turn_without_context_keeps_the_last_one() {
    let mut fields = turn(0, 50_000, 0);
    fields.remove("contextTokens");
    let (out, next) = rebuild_fields(&fields, 90 * MIN, after(100_000, MIN));
    assert!(out.is_empty());
    assert_eq!(next, after(100_000, MIN));
}
