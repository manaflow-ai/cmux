use super::*;
use crate::store::TurnUsage;

#[test]
fn bundled_table_parses_with_a_version() {
    let t = PriceTable::parse(BUNDLED).expect("bundled prices.json");
    assert!(!t.version.is_empty());
    assert_eq!(t.currency, "USD");
    assert!(t.entries.len() > 50);
}

#[test]
fn matches_the_longest_id_with_tags_and_snapshots() {
    let t = table();
    let (vendor, opus) = t.lookup("claude-opus-5-5[1m]").unwrap();
    assert_eq!(vendor, "anthropic");
    assert_eq!(opus.input, 4.0);
    assert_eq!(t.lookup("opus").unwrap().1, opus);
    assert_eq!(t.lookup("anthropic/claude-opus-5-5").unwrap().1, opus);
    assert_eq!(t.lookup("claude-opus-4-5-20251101").unwrap().1.input, 5.0);
    assert_eq!(t.lookup("openai/gpt-5.5").unwrap().0, "openai");
    // A sibling the table does not list is not priced like its neighbour.
    assert!(t.lookup("claude-opus-5-9").is_none());
    assert_eq!(t.lookup("gpt-5-2025-08-07").unwrap().1, t.lookup("gpt-5").unwrap().1);
    assert!(t.lookup("gpt-5.5-turbo-x").is_none());
    assert!(t.lookup("").is_none());
}

#[test]
fn cost_bills_each_token_kind() {
    let usage = TurnUsage {
        cost_usd: None,
        input_tokens: Some(1_000_000),
        output_tokens: Some(100_000),
        cache_read_tokens: Some(1_000_000),
        cache_write_tokens: Some(1_000_000),
        cache_write_1h_tokens: None,
    };
    // 4 + 2 + 0.2 + 5
    let cost = table().cost("claude-opus-5-5", &usage).unwrap();
    assert!((cost - 11.2).abs() < 1e-9, "{cost}");
    assert!(table().cost("no-such-model", &usage).is_none());
    // A model with no reported counts is unpriced, not free; an explicit zero is free.
    let none = TurnUsage::default();
    assert!(table().cost("claude-opus-5-5", &none).is_none());
    let zero = TurnUsage { input_tokens: Some(0), ..TurnUsage::default() };
    assert_eq!(table().cost("claude-opus-5-5", &zero), Some(0.0));
}

#[test]
fn hour_long_cache_writes_bill_at_their_tier() {
    let t = table();
    let usage = |write_1h: Option<u64>| TurnUsage {
        cache_write_tokens: Some(1_000_000),
        cache_write_1h_tokens: write_1h,
        ..TurnUsage::default()
    };
    // Opus 5.5: input 4, 5-minute writes 5, hour-long writes twice the input (8).
    let cost = |write_1h| t.cost("claude-opus-5-5", &usage(write_1h)).unwrap();
    assert!((cost(None) - 5.0).abs() < 1e-9, "{}", cost(None));
    assert!((cost(Some(1_000_000)) - 8.0).abs() < 1e-9, "{}", cost(Some(1_000_000)));
    // A quarter hour-long: 0.75 * 5 + 0.25 * 8.
    assert!((cost(Some(250_000)) - 5.75).abs() < 1e-9, "{}", cost(Some(250_000)));
    // A count past the writes is the writes.
    assert!((cost(Some(5_000_000)) - 8.0).abs() < 1e-9, "{}", cost(Some(5_000_000)));
    // A tier count with no aggregate writes is reported usage (priced, not unpriced), and
    // bills as no writes: the aggregate counts as 0 (#39324 review F2).
    let tier_only = TurnUsage { cache_write_1h_tokens: Some(1_000_000), ..TurnUsage::default() };
    assert_eq!(t.cost("claude-opus-5-5", &tier_only), Some(0.0));

    // An entry's own hour-long rate wins; a vendor that charges no writes bills none.
    let custom = PriceTable::parse(
        r#"{"version": "t", "currency": "USD", "vendors": {"v": {"models": [
                {"id": "own", "input": 1, "output": 1, "cacheWrite": 1.25, "cacheWrite1h": 3},
                {"id": "free", "input": 1, "output": 1},
                {"id": "zero", "input": 1, "output": 1, "cacheWrite": 0},
                {"id": "zero-own", "input": 1, "output": 1, "cacheWrite": 0, "cacheWrite1h": 2}
            ]}}}"#,
    )
    .unwrap();
    assert_eq!(custom.cost("own", &usage(Some(1_000_000))), Some(3.0));
    assert_eq!(custom.cost("free", &usage(Some(1_000_000))), Some(0.0));
    // An explicit zero write price is free at both tiers, not twice the input.
    assert_eq!(custom.cost("zero", &usage(Some(1_000_000))), Some(0.0));
    assert_eq!(custom.cost("zero", &usage(None)), Some(0.0));
    // Unless the entry names an hour-long rate of its own.
    assert_eq!(custom.cost("zero-own", &usage(Some(1_000_000))), Some(2.0));
}

#[test]
fn bundled_entries_that_charge_no_writes_bill_no_hour_long_writes() {
    let t = PriceTable::parse(BUNDLED).unwrap();
    let free: Vec<&str> = t
        .entries
        .iter()
        .filter(|(_, _, p)| p.cache_write.is_none_or(|rate| rate == 0.0))
        .map(|(id, _, p)| {
            assert_eq!(p.cache_write_1h_rate(), p.cache_write_1h.unwrap_or(0.0), "{id}");
            id.as_str()
        })
        .collect();
    // The bundled table lists such vendors (glm-5.2 has `"cacheWrite": 0`).
    assert!(free.contains(&"glm-5.2"), "{free:?}");
    for (id, _, p) in &t.entries {
        if p.cache_write.is_some_and(|rate| rate > 0.0) && p.cache_write_1h.is_none() {
            assert_eq!(p.cache_write_1h_rate(), p.input * 2.0, "{id}");
        }
    }
}

#[test]
fn a_provider_prefix_picks_its_own_vendor_for_a_shared_id() {
    let t = table();
    for (model, vendor) in [
        ("moonshotai/kimi-k3", "moonshotai"),
        ("alibaba/kimi-k3", "alibaba"),
        ("zai/glm-5.2", "zai"),
        ("alibaba/glm-5.2", "alibaba"),
    ] {
        assert_eq!(t.lookup(model).unwrap().0, vendor, "{model}");
    }
    // An unknown provider still finds the id.
    assert!(t.lookup("router/kimi-k3").is_some());
}
