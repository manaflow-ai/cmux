//! A session's usage warnings (`usageWarnings` on its summary): the rules its usage breaks, so a
//! person sees a runaway session (no autocompact cap, a huge context, a storm of subagents)
//! without reading transcripts. Decided here once from the summary's `usageStats` and the
//! `usageWarnings` thresholds in config (`config/usage_warnings.rs`); the cmux NEXT sidebar badge
//! and the WARN column of `acpmux ls` only show them.
//!
//! Each warning is `{rule, value, limit, text, action}`: `rule` is `noAutocompactCap`,
//! `contextTokens` or `subagentsPerHour`; `value` the session's number (context tokens, or
//! subagents started in the last hour), null when it has none; `limit` the threshold it passed,
//! null for `noAutocompactCap`; `text` one line a tooltip shows, ending in what to do; `action`
//! `{label, command, pending}`, the step that answers it (a metric must trigger an action, HQ#5123)
//! and the command that takes it, `pending` the change that adds that command while it has not
//! landed, else null. Nothing is done automatically. Empty for a closed session or one with no
//! `usageStats` yet. A number acpmux could not read is unknown (null or absent), never zero, and
//! an unknown number neither raises nor clears a warning.

use crate::config::UsageLimits;
use serde_json::{Value, json};

/// `noAutocompactCap`: a Claude session launched with no autocompact cap.
pub const NO_AUTOCOMPACT_CAP: &str = "noAutocompactCap";
/// `contextTokens`: its last call's context is above the limit.
pub const CONTEXT_TOKENS: &str = "contextTokens";
/// `subagentsPerHour`: it started more subagents in the last hour than the limit.
pub const SUBAGENTS_PER_HOUR: &str = "subagentsPerHour";

/// The change that adds `lane-place rotate`, named beside the command until it lands.
const ROTATE_PENDING: &str = "leo-workspace#1617";

/// The step that answers each rule, its label and the command that takes it for session `name`,
/// and the change that adds that command while it has not landed.
fn action(rule: &str, name: &str) -> Value {
    let (label, command, pending) = match rule {
        // `session restart` keeps the launch settings, so the old process carries on as it was:
        // `lane-place rotate` starts a successor with a fresh context (a dry run until `--yes`).
        NO_AUTOCOMPACT_CAP => {
            ("Rotate to a fresh session", format!("lane-place rotate {name}"), Some(ROTATE_PENDING))
        }
        // Claude Code's own `/compact`, sent as a prompt (`claude_stdio`: it ends its prompt).
        CONTEXT_TOKENS => ("Compact it", format!("acpmux send {name} /compact"), None),
        _ => (
            "Open the session to see what it starts; cancel its turn to stop it",
            format!("acpmux session cancel {name}"),
            None,
        ),
    };
    json!({"label": label, "command": command, "pending": pending})
}

/// `warning` with its action, and the action at the end of its text.
fn with_action(mut warning: Value, name: &str) -> Value {
    let action = action(warning["rule"].as_str().unwrap_or_default(), name);
    let command = action["command"].as_str().unwrap_or_default().to_owned();
    let soon = action["pending"].as_str().map(|p| format!(", {p}")).unwrap_or_default();
    let text = format!(
        "{}. {} ({command}{soon})",
        warning["text"].as_str().unwrap_or_default(),
        action["label"].as_str().unwrap_or_default()
    );
    warning["text"] = json!(text);
    warning["action"] = action;
    warning
}

/// The warnings a session summary earns under `limits`, in the order above, each with its action.
pub fn usage_warnings(summary: &Value, limits: &UsageLimits) -> Vec<Value> {
    let name = summary["name"].as_str().unwrap_or_default().to_owned();
    rules_broken(summary, limits).into_iter().map(|w| with_action(w, &name)).collect()
}

fn rules_broken(summary: &Value, limits: &UsageLimits) -> Vec<Value> {
    let stats = &summary["usageStats"];
    if summary["status"] == "closed" || !stats.is_object() {
        return Vec::new();
    }
    let context = stats["contextTokens"].as_u64();
    let mut out = Vec::new();
    // Only Claude Code takes an autocompact cap; another harness compacts on its own terms. Only a
    // cap known to be absent (`autocompact` "none") warns: "unknown" (an adopted or revived chat
    // whose launch acpmux never saw, an unreadable setting) never does.
    let no_cap = stats["autocompact"] == "none";
    if limits.autocompact_cap && summary["family"] == "claude" && no_cap {
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

/// One short cell per warning for `acpmux ls`: `no-cap`, `ctx 955k`, `90 sub/h`; `?` for a number
/// it does not have, never a made-up zero.
pub fn short(warning: &Value) -> String {
    let value = || warning["value"].as_u64().map_or_else(|| "?".to_owned(), tokens);
    match warning["rule"].as_str() {
        Some(NO_AUTOCOMPACT_CAP) => "no-cap".to_owned(),
        Some(CONTEXT_TOKENS) => format!("ctx {}", value()),
        Some(SUBAGENTS_PER_HOUR) => format!("{} sub/h", value()),
        Some(other) => other.to_owned(),
        None => String::new(),
    }
}

/// `short` with the command that answers it, for `acpmux ls --wide`:
/// `ctx 412k: acpmux send lane-1 /compact`, `no-cap: lane-place rotate lane-1 (leo-workspace#1617)`.
pub fn with_command(warning: &Value) -> String {
    let action = &warning["action"];
    match (action["command"].as_str(), action["pending"].as_str()) {
        (Some(command), Some(pending)) => format!("{}: {command} ({pending})", short(warning)),
        (Some(command), None) => format!("{}: {command}", short(warning)),
        (None, _) => short(warning),
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
