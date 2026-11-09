//! What a turn cost (hq#1920): the model it ran on and the tokens and cost
//! its harness reported go on its `turn_result`, and into the session's
//! running `totals`, so spend can be added up per session, branch and pull
//! request.
//!
//! Claude Code reports spend as `_meta.claude` on the prompt result
//! (`claude_stdio/inbound.rs`). Its `usage` covers that turn's main loop
//! (not its subagents). Its `cost_usd` is Claude Code's running total for
//! the conversation, subagents included, which it restores on `--resume`
//! and a fork; so a turn's cost is the rise since the last turn
//! (`SessionMeta::harness_cost_usd`). When that rise cannot be told from
//! history (a total that went down, a session with earlier turns and no
//! baseline), the turn records no cost and the next one is measured from it.
//! A failed turn records none either; its spend lands on the next answered
//! turn.
//!
//! ACP harnesses such as Codex, Gemini and Muse report a standard root
//! `usage` object instead; its per-turn counters are copied into the same
//! durable turn fields. Codex's and Gemini's input counts the cached part
//! (their total is input plus output), so the fresh input is what is left of
//! it after the cache's reads and writes, as Claude's `input_tokens` is; the
//! Claude ACP adapter's is already that (`generic_usage`). Missing counters stay
//! absent, so a harness that reports no usage carries only its model.
//!
//! Every token count is the turn's model calls added up, and each call reads
//! the whole context again: a turn of 58 calls whose context ended at 125K
//! read 4.7M, nearly all of it from the prompt cache. That sum is what was
//! billed, not what the context holds, so a turn also records
//! `contextTokens`, the context after its last call (what that call read
//! and wrote: Claude's `_meta.claude.contextTokens`, else the `used` of the
//! last `usage_update`), and Claude's `modelCalls`, how many calls made the
//! sum. Neither goes into the totals.

use super::{Session, current_model};
use crate::store::TurnUsage;
use serde_json::{Map, Value, json};

/// The `turn_result` field that says its `inputTokens` leaves out the cache's
/// reads and writes (what every turn this acpmux records does).
pub(super) const INPUT_EXCLUDES_CACHE: &str = "inputExcludesCache";

/// The turn's `turn_result` fields for a prompt `result` (`model`, then any
/// of `costUsd`, `inputTokens`, `outputTokens`, `cacheReadTokens` and
/// `cacheWriteTokens`, added to the session's totals as the harness reported
/// them (`as_reported`), and `contextTokens`, `modelCalls` and
/// `inputExcludesCache`, which are not), and what the turn spent toward a
/// goal's token budget: its reported input plus its output.
pub(super) fn turn_usage(session: &Session, result: &Value) -> (Map<String, Value>, Option<u64>) {
    let mut meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
    let mut fields = Map::new();
    if let Some(model) = current_model(&meta) {
        fields.insert("model".into(), json!(model));
    }
    let calls;
    let context;
    let turn = if let Some(claude) = result.pointer("/_meta/claude") {
        context = claude.get("contextTokens").and_then(Value::as_u64);
        calls = claude.get("modelCalls").and_then(Value::as_u64);
        let tokens = |key: &str| claude.get("usage")?.get(key)?.as_u64();
        let write = tokens("cache_creation_input_tokens");
        // The hour-long part of the writes (`cache_creation`, as each call's usage names it):
        // what prices them at their own tier in the ledger (`crate::pricing`).
        let write_1h = claude
            .pointer("/usage/cache_creation/ephemeral_1h_input_tokens")
            .and_then(Value::as_u64)
            .map(|n| write.map_or(n, |write| n.min(write)));
        let mut turn = TurnUsage {
            cost_usd: None,
            input_tokens: tokens("input_tokens"),
            output_tokens: tokens("output_tokens"),
            cache_read_tokens: tokens("cache_read_input_tokens"),
            cache_write_tokens: write,
            cache_write_1h_tokens: write_1h,
        };
        let running = claude.get("cost_usd").and_then(Value::as_f64);
        if let Some(running) = running.filter(|c| c.is_finite() && *c >= 0.0) {
            match meta.harness_cost_usd {
                // A zeroed total (a crashed process's last result) says nothing: keep the baseline.
                Some(before) if running == 0.0 && before > 0.0 => {}
                Some(before) if running >= before => turn.cost_usd = Some(running - before),
                // A session's first turn: all of the total is its own.
                None if meta.turn_count <= 1 => turn.cost_usd = Some(running),
                // Below the baseline (a process that started over or restored less), or no
                // baseline after earlier turns (an older session, a fork through an earlier
                // turn): this turn's share cannot be told from history, so it records none.
                _ => {}
            }
            if running > 0.0 || meta.harness_cost_usd.is_none() {
                meta.harness_cost_usd = Some(running);
            }
        }
        turn
    } else {
        // The context Codex's last call held, read and written (its `usage_update`'s `used`).
        context = meta.usage.as_ref().and_then(|u| u.get("used")).and_then(Value::as_u64);
        calls = None;
        generic_usage(result.get("usage"), meta.input_excludes_cache())
    };
    let reported = as_reported(result, &turn);
    let budget = [reported.input_tokens, reported.output_tokens]
        .into_iter()
        .flatten()
        .reduce(u64::saturating_add);
    if turn.is_empty() {
        return (fields, budget);
    }
    meta.totals.get_or_insert_with(TurnUsage::default).add(&reported);
    if let Ok(Value::Object(spent)) = serde_json::to_value(&turn) {
        fields.extend(spent);
    }
    // Its `inputTokens` is the fresh input alone, for every harness. An older acpmux stored an
    // ACP harness's (Codex's, Gemini's) input whole, its cached reads in it, and wrote no mark:
    // clients read an unmarked record by its harness (webviews tokenSplit.ts).
    if turn.input_tokens.is_some() {
        fields.insert(INPUT_EXCLUDES_CACHE.into(), Value::Bool(true));
    }
    if let Some(context) = context.filter(|c| *c > 0) {
        fields.insert("contextTokens".into(), json!(context));
    }
    if let Some(calls) = calls.filter(|c| *c > 0) {
        fields.insert("modelCalls".into(), json!(calls));
    }
    (fields, budget)
}

/// The turn's spend with its input as its harness reported it: what the
/// session's `totals` and a goal's token budget (`generic_goal::next_step`,
/// input plus output) have always added up, so neither changes meaning with
/// the record's. An ACP harness's input has the cache's reads in it where it
/// counts them there (Codex, Gemini), while the record's `inputTokens` is the
/// fresh part alone (`generic_usage`, `inputExcludesCache`). Claude Code's
/// (`_meta.claude`) was always its fresh input.
fn as_reported(result: &Value, turn: &TurnUsage) -> TurnUsage {
    let mut reported = turn.clone();
    if result.pointer("/_meta/claude").is_none() {
        reported.input_tokens = result.get("usage").and_then(reported_input);
    }
    reported
}

/// An ACP usage's input as its harness reported it (`generic_usage` takes it
/// from the same keys).
fn reported_input(usage: &Value) -> Option<u64> {
    ["inputTokens", "promptTokens", "input_tokens"]
        .iter()
        .find_map(|key| usage.get(*key).and_then(Value::as_u64))
}

/// Map ACP's provider-neutral prompt result usage to the durable cmux names.
/// Muse uses `promptTokens`/`outputTokens`; Gemini uses `inputTokens`/
/// `outputTokens`; accepting both keeps the adapter boundary provider-neutral.
///
/// The record's input is the fresh part alone. Codex's and Gemini's ACP input
/// counts the cache's reads (their `totalTokens` is input plus output), the
/// Claude ACP adapter's leaves them out (its `totalTokens` adds them on): a
/// `totalTokens` that holds the cache past input, output and thought says the
/// input left it out, one that does not says it is in. A usage with no total
/// is read by its harness (`fresh_harness`, `SessionMeta::input_excludes_cache`).
fn generic_usage(usage: Option<&Value>, fresh_harness: bool) -> TurnUsage {
    let Some(usage) = usage else { return TurnUsage::default() };
    let number =
        |keys: &[&str]| keys.iter().find_map(|key| usage.get(*key).and_then(Value::as_u64));
    let input = reported_input(usage);
    let output = number(&["outputTokens", "output_tokens"]).or_else(|| {
        number(&["totalTokens", "total_tokens"])
            .zip(input)
            .map(|(total, input)| total.saturating_sub(input))
    });
    let cost = usage
        .get("costUsd")
        .and_then(Value::as_f64)
        .or_else(|| usage.get("cost").and_then(|v| v.get("amount")).and_then(Value::as_f64))
        .filter(|v| v.is_finite() && *v >= 0.0);
    let cache_read =
        number(&["cacheReadTokens", "cachedReadTokens", "cachedTokens", "cache_read_input_tokens"]);
    let cache_write =
        number(&["cacheWriteTokens", "cachedWriteTokens", "cache_creation_input_tokens"]);
    let cached = cache_read.unwrap_or(0).saturating_add(cache_write.unwrap_or(0));
    let total = number(&["totalTokens", "total_tokens"]);
    let thought = number(&["thoughtTokens", "thoughtsTokens", "reasoningTokens"]).unwrap_or(0);
    let fresh = match (total, input) {
        (Some(total), Some(input)) if cached > 0 => {
            let apart = input
                .saturating_add(output.unwrap_or(0))
                .saturating_add(thought)
                .saturating_add(cached);
            total >= apart
        }
        _ => fresh_harness,
    };
    TurnUsage {
        cost_usd: cost,
        input_tokens: if fresh { input } else { input.map(|input| input.saturating_sub(cached)) },
        output_tokens: output,
        cache_read_tokens: cache_read,
        cache_write_tokens: cache_write,
        cache_write_1h_tokens: None,
    }
}

#[cfg(test)]
mod tests {
    use super::generic_usage;
    use serde_json::json;

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
}
