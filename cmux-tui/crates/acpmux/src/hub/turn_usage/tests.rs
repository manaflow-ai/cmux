use super::{claude_tokens, generic_usage};
use crate::store::TurnUsage;
use serde_json::{Value, json};

#[test]
fn claude_hour_long_writes_never_exceed_the_writes_and_a_tier_only_payload_counts_none() {
    let usage = |u: Value| claude_tokens(&json!({ "usage": u }));
    let both = usage(json!({"cache_creation_input_tokens": 1000,
            "cache_creation": {"ephemeral_1h_input_tokens": 800}}));
    assert_eq!((both.cache_write_tokens, both.cache_write_1h_tokens), (Some(1000), Some(800)));
    let past = usage(json!({"cache_creation_input_tokens": 100,
            "cache_creation": {"ephemeral_1h_input_tokens": 800}}));
    assert_eq!(past.cache_write_1h_tokens, Some(100));
    // A partial payload: the tier with no aggregate. The aggregate counts as 0, so the turn
    // records 0 hour-long writes, as pricing bills it, never 800 the ledger would not price.
    let tier_only = usage(json!({"input_tokens": 5,
            "cache_creation": {"ephemeral_1h_input_tokens": 800}}));
    assert_eq!(tier_only.cache_write_tokens, None);
    assert_eq!(tier_only.cache_write_1h_tokens, Some(0));
    let table = crate::pricing::table();
    let model = "claude-opus-5-5";
    let alone = TurnUsage { input_tokens: Some(5), ..TurnUsage::default() };
    assert_eq!(table.cost(model, &tier_only), table.cost(model, &alone));
    // No tier field: none recorded.
    assert_eq!(usage(json!({"cache_creation_input_tokens": 10})).cache_write_1h_tokens, None);
}

#[test]
fn maps_gemini_usage() {
    let usage = generic_usage(
        Some(
            &json!({"inputTokens": 12, "outputTokens": 8, "thoughtsTokens": 3, "cachedTokens": 4}),
        ),
        false,
    );
    // Its 12 input count the 4 read from the cache: 8 were fresh.
    assert_eq!(usage.input_tokens, Some(8));
    assert_eq!(usage.output_tokens, Some(8));
    assert_eq!(usage.cache_read_tokens, Some(4));
}

#[test]
fn maps_codex_usage_with_its_cached_input_apart() {
    // A Codex turn of 22 calls (a real rollout's token_count events, added up): its input
    // counts the 3,021,696 read from the cache, so 314,899 were fresh.
    let usage = generic_usage(
        Some(&json!({"inputTokens": 3_336_595, "cachedReadTokens": 3_021_696,
            "outputTokens": 4_017, "thoughtTokens": 1_182, "totalTokens": 3_340_612})),
        false,
    );
    assert_eq!(usage.input_tokens, Some(314_899));
    assert_eq!(usage.cache_read_tokens, Some(3_021_696));
    assert_eq!(usage.cache_write_tokens, None);
    assert_eq!(usage.output_tokens, Some(4_017));
}

#[test]
fn maps_muse_usage_and_derives_output_when_needed() {
    let usage = generic_usage(
        Some(
            &json!({"promptTokens": 20, "totalTokens": 31, "cost": {"amount": 0.25, "currency": "USD"}}),
        ),
        false,
    );
    assert_eq!(usage.input_tokens, Some(20));
    assert_eq!(usage.output_tokens, Some(11));
    assert_eq!(usage.cost_usd, Some(0.25));
}

// A Claude ACP adapter turn (`@agentclientprotocol/claude-agent-acp` `sessionUsage`): its
// `inputTokens` is Anthropic's `input_tokens`, the fresh part alone, and its `totalTokens`
// adds the cache's reads and writes on.
const CLAUDE_ACP: &str = r#"{"inputTokens": 112, "outputTokens": 23702,
        "cachedReadTokens": 4530027, "cachedWriteTokens": 124616, "totalTokens": 4678457}"#;

#[test]
fn maps_claude_acp_usage_without_taking_its_cache_out_twice() {
    let usage: serde_json::Value = serde_json::from_str(CLAUDE_ACP).unwrap();
    // Its total says the input left the cache out, whatever the harness is named.
    for fresh_harness in [true, false] {
        let usage = generic_usage(Some(&usage), fresh_harness);
        assert_eq!(usage.input_tokens, Some(112));
        assert_eq!(usage.cache_read_tokens, Some(4_530_027));
        assert_eq!(usage.cache_write_tokens, Some(124_616));
        assert_eq!(usage.output_tokens, Some(23_702));
    }
    // With no total, its harness says it.
    let mut bare = usage.clone();
    bare.as_object_mut().unwrap().remove("totalTokens");
    assert_eq!(generic_usage(Some(&bare), true).input_tokens, Some(112));
    assert_eq!(generic_usage(Some(&bare), false).input_tokens, Some(0));
}

#[test]
fn a_codex_total_takes_its_cache_out_even_under_a_claude_name() {
    // opencode or a renamed profile: its total (input plus output) says the cache is in.
    let usage = generic_usage(
        Some(&json!({"inputTokens": 3_336_595, "cachedReadTokens": 3_021_696,
                "outputTokens": 4_017, "totalTokens": 3_340_612})),
        true,
    );
    assert_eq!(usage.input_tokens, Some(314_899));
}
