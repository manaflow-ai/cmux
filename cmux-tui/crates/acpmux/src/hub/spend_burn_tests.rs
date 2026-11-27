use super::*;

const ON: Settings =
    Settings { enabled: true, budget_usd: Some(10.0), fast_usd_per_min: FAST_BURN_USD_PER_MIN };

fn levels(w: &[Warning]) -> Vec<&'static str> {
    w.iter().map(|w| w.level).collect()
}

#[test]
fn settings_default_on_with_a_budget_and_parse_off() {
    assert_eq!(Settings::parse(None, None, None), ON);
    assert_eq!(Settings::parse(None, Some("off"), None).budget_usd, None);
    assert_eq!(Settings::parse(None, Some("0"), None).budget_usd, None);
    assert_eq!(Settings::parse(None, Some("2.5"), None).budget_usd, Some(2.5));
    assert!(!Settings::parse(Some("0"), None, None).enabled);
    assert_eq!(Settings::parse(None, None, Some("3")).fast_usd_per_min, 3.0);
}

#[test]
fn a_slow_turn_crossing_50_90_100_warns_once_each_in_order() {
    let mut b = Burn::default();
    b.enter("t1", 0);
    // An hour in: far too slow for a fast burn.
    let hour = 3_600_000;
    let mut seen = Vec::new();
    for (i, spent) in [2.0, 5.1, 5.2, 9.0, 9.5, 10.2, 12.0].into_iter().enumerate() {
        b.add(Some(spent), None, true);
        seen.extend(levels(&b.check(&ON, hour * (i as u64 + 1))));
    }
    assert_eq!(seen, ["budget_50", "budget_90", "over_budget"]);
    assert!(b.over_budget());
}

#[test]
fn a_fast_burn_warns_before_the_budget_is_reached() {
    let mut b = Burn::default();
    b.enter("t1", 0);
    b.add(None, Some(0.5), true);
    assert!(b.check(&ON, 10_000).is_empty(), "under the 10% floor");
    b.add(None, Some(1.0), true);
    // $1.50 in 20 s: the other $8.50 goes in under two minutes.
    let w = b.check(&ON, 20_000);
    assert_eq!(levels(&w), [FAST]);
    assert!(w[0].exhausts_in_s.unwrap() < FAST_BURN_HORIZON_S);
    assert!(b.check(&ON, 21_000).is_empty(), "once a turn");
}

#[test]
fn a_new_turn_measures_from_the_last_cumulative_cost() {
    let mut b = Burn::default();
    b.enter("t1", 0);
    b.add(Some(4.0), None, true);
    assert_eq!(b.spent(), 4.0);
    b.enter("t2", 0);
    b.add(Some(4.5), None, false);
    assert!((b.spent() - 0.5).abs() < 1e-9);
    // A later turn of a session whose cost was never seen counts from its first report.
    let mut fresh = Burn::default();
    fresh.enter("t9", 0);
    fresh.add(Some(30.0), None, false);
    assert_eq!(fresh.spent(), 0.0);
}

#[test]
fn with_no_budget_only_the_rate_warns() {
    let s = Settings { budget_usd: None, ..ON };
    let mut b = Burn::default();
    b.enter("t1", 0);
    b.add(None, Some(100.0), true);
    // $100 over a day: no fast burn, and no budget to cross.
    assert!(b.check(&s, 86_400_000).is_empty());
    let mut b = Burn::default();
    b.enter("t1", 0);
    b.add(None, Some(1.0), true);
    assert_eq!(levels(&b.check(&s, 30_000)), [FAST]);
}

#[test]
fn updates_are_read_for_cost_or_tokens() {
    let u = json!({"sessionUpdate": "usage_update", "cost": {"amount": 1.5, "currency": "USD"}});
    assert_eq!(cumulative_cost(&u), Some(1.5));
    let eur = json!({"cost": {"amount": 1.5, "currency": "EUR"}});
    assert_eq!(cumulative_cost(&eur), None);
    let call = json!({"inputTokens": 10, "outputTokens": 5, "_meta": {"acpmux": {"call": true}}});
    assert_eq!(call_usage(&call).unwrap().output_tokens, Some(5));
    assert!(call_usage(&json!({"used": 10})).is_none());
}
