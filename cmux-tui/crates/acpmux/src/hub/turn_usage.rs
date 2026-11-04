//! What a turn cost (hq#1920): the model it ran on and the tokens and cost
//! its harness reported go on its `turn_result`, and into the session's
//! running `totals`, so spend can be added up per session, branch and pull
//! request.
//!
//! Claude Code reports its running spend under `_meta.claude`. ACP harnesses
//! such as Gemini and Muse report a standard root `usage` object instead; the
//! adapter's per-turn counters are copied into the same durable turn fields.
//! Missing counters stay absent, so a provider that does not report usage still
//! carries only its model.

use super::{Session, current_model};
use crate::store::TurnUsage;
use serde_json::{Map, Value, json};

/// The turn's `turn_result` fields for a prompt `result` (`model`, then any
/// of `costUsd`, `inputTokens`, `outputTokens`, `cacheReadTokens` and
/// `cacheWriteTokens`), added to the session's totals as they are taken.
pub(super) fn turn_usage(session: &Session, result: &Value) -> Map<String, Value> {
    let mut meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
    let mut fields = Map::new();
    if let Some(model) = current_model(&meta) {
        fields.insert("model".into(), json!(model));
    }
    let mut turn = if let Some(claude) = result.pointer("/_meta/claude") {
        let tokens = |key: &str| claude.get("usage")?.get(key)?.as_u64();
        let mut turn = TurnUsage {
            cost_usd: None,
            input_tokens: tokens("input_tokens"),
            output_tokens: tokens("output_tokens"),
            cache_read_tokens: tokens("cache_read_input_tokens"),
            cache_write_tokens: tokens("cache_creation_input_tokens"),
        };
        let running = claude.get("cost_usd").and_then(Value::as_f64);
        if let Some(running) = running.filter(|c| c.is_finite() && *c >= 0.0) {
            match meta.harness_cost_usd {
                Some(before) if running == 0.0 && before > 0.0 => {}
                Some(before) if running >= before => turn.cost_usd = Some(running - before),
                None if meta.turn_count <= 1 => turn.cost_usd = Some(running),
                _ => {}
            }
            if running > 0.0 || meta.harness_cost_usd.is_none() {
                meta.harness_cost_usd = Some(running);
            }
        }
        turn
    } else {
        generic_usage(result.get("usage"))
    };
    if turn.is_empty() {
        return fields;
    }
    meta.totals.get_or_insert_with(TurnUsage::default).add(&turn);
    if let Ok(Value::Object(spent)) = serde_json::to_value(&turn) {
        fields.extend(spent);
    }
    fields
}

/// Map ACP's provider-neutral prompt result usage to the durable cmux names.
/// Muse uses `promptTokens`/`outputTokens`; Gemini uses `inputTokens`/
/// `outputTokens`; accepting both keeps the adapter boundary provider-neutral.
fn generic_usage(usage: Option<&Value>) -> TurnUsage {
    let Some(usage) = usage else { return TurnUsage::default() };
    let number =
        |keys: &[&str]| keys.iter().find_map(|key| usage.get(*key).and_then(Value::as_u64));
    let input = number(&["inputTokens", "promptTokens", "input_tokens"]);
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
    TurnUsage {
        cost_usd: cost,
        input_tokens: input,
        output_tokens: output,
        cache_read_tokens: number(&[
            "cacheReadTokens",
            "cachedReadTokens",
            "cachedTokens",
            "cache_read_input_tokens",
        ]),
        cache_write_tokens: number(&[
            "cacheWriteTokens",
            "cachedWriteTokens",
            "cache_creation_input_tokens",
        ]),
    }
}

#[cfg(test)]
mod tests {
    use super::generic_usage;
    use serde_json::json;

    #[test]
    fn maps_gemini_usage() {
        let usage = generic_usage(Some(
            &json!({"inputTokens": 12, "outputTokens": 8, "thoughtsTokens": 3, "cachedTokens": 4}),
        ));
        assert_eq!(usage.input_tokens, Some(12));
        assert_eq!(usage.output_tokens, Some(8));
        assert_eq!(usage.cache_read_tokens, Some(4));
    }

    #[test]
    fn maps_muse_usage_and_derives_output_when_needed() {
        let usage = generic_usage(Some(
            &json!({"promptTokens": 20, "totalTokens": 31, "cost": {"amount": 0.25, "currency": "USD"}}),
        ));
        assert_eq!(usage.input_tokens, Some(20));
        assert_eq!(usage.output_tokens, Some(11));
        assert_eq!(usage.cost_usd, Some(0.25));
    }
}
