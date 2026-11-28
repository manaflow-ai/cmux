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

#[test]
fn a_call_is_judged_by_the_same_rule_and_its_own_cause() {
    let mut r = CallRebuilds::default();
    r.call(100_000, 110_000, (11_000, 11_000), MIN, false);
    assert_eq!(r, CallRebuilds::default(), "warm: wrote what grew");
    r.call(100_000, 101_000, (101_000, 101_000), 40 * MIN, false);
    r.call(101_000, 102_000, (102_000, 0), 2 * MIN, false);
    // A compaction to 30k that wrote 60k: at least half the old context written again.
    r.call(100_000, 30_000, (60_000, 60_000), MIN, true);
    assert_eq!(r.by_cause["idle"], 100_000);
    assert_eq!(r.by_cause["prefix"], 101_000);
    assert_eq!(r.by_cause["compaction"], 60_000);
    assert_eq!(r.tokens, 261_000);
    assert_eq!(r.tokens_1h, 160_000);
    assert_eq!(r.idle_ms, 40 * MIN);
    let j = r.to_json();
    assert_eq!((j["cause"].clone(), j["idleSeconds"].clone()), (json!("prefix"), json!(2400)));
    // A 5-minute write is cold after 5 minutes; a small context is not flagged.
    let mut five = CallRebuilds::default();
    five.call(100_000, 100_000, (100_000, 0), 6 * MIN, false);
    five.call(10_000, 10_000, (10_000, 0), 90 * MIN, false);
    assert_eq!(five.by_cause.get("idle"), Some(&100_000));
    assert_eq!(five.tokens, 100_000);
}

#[test]
fn a_turns_calls_count_every_cold_call_where_its_sums_count_one() {
    // Two cold calls inside a warm-looking turn: the sums net out to under half the context.
    let mut fields = turn(110_000, 60_000, 60_000);
    fields.insert(
        CALLS_FIELD.into(),
        json!({"tokens": 200_000, "tokens1h": 200_000, "cause": "idle", "idleSeconds": 2400}),
    );
    let (out, next) = rebuild_fields(&fields, 3 * MIN, after(100_000, MIN));
    assert_eq!(out["cacheRebuildTokens"], json!(200_000));
    assert_eq!(out["cacheRebuildCause"], json!("idle"));
    assert_eq!(out["cacheIdleSeconds"], json!(2400));
    let (_, p) = crate::pricing::table().lookup(MODEL).unwrap();
    let want = 200_000.0 * (p.cache_write_1h_rate() - p.cache_read.unwrap()) / 1e6;
    assert!((out["cacheRebuildUsd"].as_f64().unwrap() - want).abs() < 1e-6);
    assert!(next.total_usd.is_some());
}

#[test]
fn the_turn_rule_still_counts_what_the_calls_could_not_see() {
    // A cold first call after acpmux restarted has no call before it: the calls say 0, the turn
    // rule against the kept last turn says 100k.
    let mut fields = turn(110_000, 110_000, 110_000);
    fields.insert(
        CALLS_FIELD.into(),
        json!({"tokens": 0, "tokens1h": 0, "cause": null, "idleSeconds": 0}),
    );
    let (out, _) = rebuild_fields(&fields, 41 * MIN, after(100_000, MIN));
    assert_eq!(out["cacheRebuildTokens"], json!(100_000));
    assert_eq!(out["cacheRebuildCause"], json!("idle"));
    // And a first turn the calls count is flagged even with no turn before it.
    let mut first = turn(120_000, 120_000, 120_000);
    first.insert(
        CALLS_FIELD.into(),
        json!({"tokens": 50_000, "tokens1h": 0, "cause": "prefix", "idleSeconds": 0}),
    );
    let (out, _) = rebuild_fields(&first, MIN, Default::default());
    assert_eq!(out["cacheRebuildTokens"], json!(50_000));
}
