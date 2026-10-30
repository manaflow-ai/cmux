//! A session's usage warnings (`usageWarnings` on its summary): the rules its usage breaks, so a
//! person sees a runaway session (no autocompact cap, a huge context, a storm of subagents)
//! without reading transcripts. Decided here once from the summary's `usageStats` and the
//! `usageWarnings` thresholds in config (`config/usage_warnings.rs`); the cmux NEXT sidebar badge
//! and the WARN column of `acpmux ls` only show them.
//!
//! Each warning is `{rule, value, limit, text}`: `rule` is `noAutocompactCap`, `contextTokens` or
//! `subagentsPerHour`; `value` the session's number (context tokens, or subagents started in the
//! last hour), null when it has none; `limit` the threshold it passed, null for
//! `noAutocompactCap`; `text` one line a tooltip shows. Empty for a closed session or one with no
//! `usageStats` yet.

use crate::config::UsageLimits;
use serde_json::{Value, json};

/// `noAutocompactCap`: a Claude session launched with no autocompact cap.
pub const NO_AUTOCOMPACT_CAP: &str = "noAutocompactCap";
/// `contextTokens`: its last call's context is above the limit.
pub const CONTEXT_TOKENS: &str = "contextTokens";
/// `subagentsPerHour`: it started more subagents in the last hour than the limit.
pub const SUBAGENTS_PER_HOUR: &str = "subagentsPerHour";

/// The warnings a session summary earns under `limits`, in the order above.
pub fn usage_warnings(summary: &Value, limits: &UsageLimits) -> Vec<Value> {
    let stats = &summary["usageStats"];
    if summary["status"] == "closed" || !stats.is_object() {
        return Vec::new();
    }
    let context = stats["contextTokens"].as_u64();
    let mut out = Vec::new();
    // Only Claude Code takes an autocompact cap; another harness compacts on its own terms.
    if limits.autocompact_cap && summary["family"] == "claude" && stats["autocompactCap"].is_null()
    {
        let text = match context {
            Some(n) => format!(
                "No autocompact cap: context is {} and only compacts at the model's limit",
                tokens(n)
            ),
            None => "No autocompact cap: context only compacts at the model's limit".to_owned(),
        };
        out.push(
            json!({"rule": NO_AUTOCOMPACT_CAP, "value": context, "limit": null, "text": text}),
        );
    }
    if let (Some(limit), Some(n)) = (limits.context_tokens, context)
        && n > limit
    {
        let text =
            format!("Context {} tokens, above the {} warning line", tokens(n), tokens(limit));
        out.push(json!({"rule": CONTEXT_TOKENS, "value": n, "limit": limit, "text": text}));
    }
    if let (Some(limit), Some(n)) = (limits.subagents_per_hour, stats["subagents1h"].as_u64())
        && n > limit
    {
        let text = format!("{n} subagents started in the last hour, above {limit}");
        out.push(json!({"rule": SUBAGENTS_PER_HOUR, "value": n, "limit": limit, "text": text}));
    }
    out
}

/// One short cell per warning for `acpmux ls`: `no-cap`, `ctx 955k`, `90 sub/h`.
pub fn short(warning: &Value) -> String {
    let value = warning["value"].as_u64();
    match warning["rule"].as_str() {
        Some(NO_AUTOCOMPACT_CAP) => "no-cap".to_owned(),
        Some(CONTEXT_TOKENS) => format!("ctx {}", tokens(value.unwrap_or(0))),
        Some(SUBAGENTS_PER_HOUR) => format!("{} sub/h", value.unwrap_or(0)),
        Some(other) => other.to_owned(),
        None => String::new(),
    }
}

/// `955k`, `1.2M`, `800`.
fn tokens(n: u64) -> String {
    match n {
        0..1_000 => n.to_string(),
        1_000..1_000_000 => format!("{}k", n / 1_000),
        _ => format!("{:.1}M", n as f64 / 1_000_000.0),
    }
}
