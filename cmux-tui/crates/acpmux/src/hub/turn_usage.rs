//! What a turn cost (hq#1920): the model it ran on and the tokens and cost
//! its harness reported go on its `turn_result`, and into the session's
//! running `totals`, so spend can be added up per session, branch and pull
//! request.
//!
//! Only Claude Code reports spend, as `_meta.claude` on the prompt result
//! (`claude_stdio/inbound.rs`). Its `usage` covers that turn's main loop
//! (not its subagents). Its `cost_usd` is Claude Code's running total for
//! the conversation, subagents included, which it restores on `--resume`
//! and a fork; so a turn's cost is the rise since the last turn
//! (`SessionMeta::harness_cost_usd`). When that rise cannot be told from
//! history (a total that went down, a session with earlier turns and no
//! baseline), the turn records no cost and the next one is measured from it.
//! A failed turn records none either; its spend lands on the next answered
//! turn. Other harnesses report no per-turn spend, so their turns carry only
//! the model.

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
    let Some(claude) = result.pointer("/_meta/claude") else { return fields };
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
    if turn.is_empty() {
        return fields;
    }
    meta.totals.get_or_insert_with(TurnUsage::default).add(&turn);
    if let Ok(Value::Object(spent)) = serde_json::to_value(&turn) {
        fields.extend(spent);
    }
    fields
}
