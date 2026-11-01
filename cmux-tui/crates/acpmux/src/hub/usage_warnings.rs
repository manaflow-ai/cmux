//! A session's usage warnings (`usageWarnings` on its summary): the rules its usage breaks, so a
//! person sees a runaway session (no autocompact cap, a huge context, a storm of subagents)
//! without reading transcripts. Decided here once from the summary's `usageStats` and the
//! `usageWarnings` thresholds in config (`config/usage_warnings.rs`); the cmux NEXT sidebar badge
//! and the WARN column of `acpmux ls` only show them.
//!
//! Each warning is `{rule, value, limit, text, action}`: `rule` is `noAutocompactCap`,
//! `contextTokens` or `subagentsPerHour`; `value` the session's number (context tokens, or
//! subagents started in the last hour), null when it has none; `limit` the threshold it passed,
//! null for `noAutocompactCap`; `text` one line a tooltip shows, ending in what to do; `actions`
//! `[{label, command, pending}]`, the steps that answer it, first the one to try first (a metric
//! must trigger an action, HQ#5123), each with the command that takes it and `pending` the change
//! that adds that command while it has not landed, else null. Nothing is done automatically. Empty for a closed session or one with no
//! `usageStats` yet. A number acpmux could not read is unknown (null or absent), never zero, and
//! an unknown number never raises a warning: a summary warns only on numbers it knows. acpmux keeps
//! the last numbers it read (`usage_view.rs`), so a later read does not turn a known number
//! unknown; one turns unknown only where acpmux can no longer vouch for it (a backlog it has not
//! read), and then no warning stands on it.

use crate::config::UsageLimits;
use cmux_json::JsonSet as _;
use serde_json::{Value, json};

/// `value`'s `key`, or null: reading a summary never panics (no indexing).
fn at<'a>(value: &'a Value, key: &str) -> &'a Value {
    static NULL: Value = Value::Null;
    value.get(key).unwrap_or(&NULL)
}

/// `noAutocompactCap`: a Claude session launched with no autocompact cap.
pub const NO_AUTOCOMPACT_CAP: &str = "noAutocompactCap";
/// `contextTokens`: its last call's context is above the limit.
pub const CONTEXT_TOKENS: &str = "contextTokens";
/// `subagentsPerHour`: it started more subagents in the last hour than the limit.
pub const SUBAGENTS_PER_HOUR: &str = "subagentsPerHour";

/// The steps that answer each rule for session `name`, first the one to try first: each its
/// label, the command that takes it and the change that adds that command while it has not landed.
fn actions(rule: &str, name: &str) -> Vec<Value> {
    let step = |label: &str, command: String, pending: Option<&str>| json!({"label": label, "command": command, "pending": pending});
    // `lane-place rotate` starts a successor (a dry run until `--yes`); it keeps the harness
    // profile unless `--harness` names another. `session restart` keeps the launch settings.
    let rotate = |extra: &str| format!("lane-place rotate {name}{extra}");
    match rule {
        // The successor runs on the capped profile (claude-sr2, its sr2 `--autocompact`).
        NO_AUTOCOMPACT_CAP => {
            vec![step("Rotate onto a capped profile", rotate(" --harness claude-sr2"), None)]
        }
        // Claude Code's own `/compact`, sent as a prompt (`claude_stdio`: it ends its prompt).
        CONTEXT_TOKENS => vec![
            step("Compact it", format!("acpmux send {name} /compact"), None),
            step("rotate to a fresh session", rotate(""), None),
        ],
        _ => vec![step(
            "Open the session to see what it starts; cancel its turn to stop it",
            format!("acpmux session cancel {name}"),
            None,
        )],
    }
}

/// One step as the tooltip says it: `Compact it (acpmux send lane-1 /compact)`.
fn said(step: &Value) -> String {
    let command = at(step, "command").as_str().unwrap_or_default();
    let soon = at(step, "pending").as_str().map(|p| format!(", {p}")).unwrap_or_default();
    format!("{} ({command}{soon})", at(step, "label").as_str().unwrap_or_default())
}

/// `warning` with its steps for session `name`, and the steps at the end of its text (`… or …`).
/// `finding` keeps the text before the steps, so a new name can be given (`for_name`).
fn with_action(mut warning: Value, name: &str) -> Value {
    let finding = warning
        .get("finding")
        .unwrap_or(at(&warning, "text"))
        .as_str()
        .unwrap_or_default()
        .to_owned();
    let actions = actions(at(&warning, "rule").as_str().unwrap_or_default(), name);
    let steps = actions.iter().map(said).collect::<Vec<_>>().join(" or ");
    warning.set("text", json!(format!("{finding}. {steps}")));
    warning.set("finding", json!(finding));
    warning.set("actions", Value::Array(actions));
    warning
}

/// The warnings a session summary earns under `limits`, in the order above, each with its action.
pub fn usage_warnings(summary: &Value, limits: &UsageLimits) -> Vec<Value> {
    let name = at(summary, "name").as_str().unwrap_or_default().to_owned();
    rules_broken(summary, limits).into_iter().map(|w| with_action(w, &name)).collect()
}

/// `summary`'s warnings with their commands naming it as `summary.name` now says, after a
/// daemon that lists a peer's sessions renamed it `<peer>/<name>` (`peers.rs`), so a command
/// copied from that row reaches the peer's session, not one of the same name here.
pub fn for_name(summary: &mut Value) {
    let name = at(summary, "name").as_str().unwrap_or_default().to_owned();
    let Some(warnings) = summary.get_mut("usageWarnings").and_then(Value::as_array_mut) else {
        return;
    };
    for warning in warnings.iter_mut() {
        *warning = with_action(warning.take(), &name);
    }
}

fn rules_broken(summary: &Value, limits: &UsageLimits) -> Vec<Value> {
    let stats = at(summary, "usageStats");
    if at(summary, "status") == "closed" || !stats.is_object() {
        return Vec::new();
    }
    let context = at(stats, "contextTokens").as_u64();
    let mut out = Vec::new();
    // Only Claude Code takes an autocompact cap; another harness compacts on its own terms. Only a
    // cap known to be absent (`autocompact` "none") warns: "unknown" (an adopted or revived chat
    // whose launch acpmux never saw, an unreadable setting) never does.
    let no_cap = at(stats, "autocompact") == "none";
    if limits.autocompact_cap && at(summary, "family") == "claude" && no_cap {
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
    if let (Some(limit), Some(n)) = (limits.subagents_per_hour, at(stats, "subagents1h").as_u64())
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
    let value = || at(warning, "value").as_u64().map_or_else(|| "?".to_owned(), tokens);
    match at(warning, "rule").as_str() {
        Some(NO_AUTOCOMPACT_CAP) => "no-cap".to_owned(),
        Some(CONTEXT_TOKENS) => format!("ctx {}", value()),
        Some(SUBAGENTS_PER_HOUR) => format!("{} sub/h", value()),
        Some(other) => other.to_owned(),
        None => String::new(),
    }
}

/// `short` with the commands that answer it, for `acpmux ls --wide`:
/// `ctx 412k: acpmux send lane-1 /compact | lane-place rotate lane-1`.
pub fn with_command(warning: &Value) -> String {
    let commands = at(warning, "actions")
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|step| {
            let command = at(step, "command").as_str()?;
            Some(match at(step, "pending").as_str() {
                Some(pending) => format!("{command} ({pending})"),
                None => command.to_owned(),
            })
        })
        .collect::<Vec<_>>();
    match commands.is_empty() {
        true => short(warning),
        false => format!("{}: {}", short(warning), commands.join(" | ")),
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
