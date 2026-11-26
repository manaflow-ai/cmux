//! A `chat.turn_failed` whose agent's account is out of usage or turned off says what happened,
//! which agent, when it resets and what to do (cmux#55066), instead of the agent's bare
//! "You've hit your weekly limit · resets Nov 27, 7am (UTC)". The agent's own words stay in
//! `details.agent_error`; `details.errorKind` is acpmux's (`usage.limit`, `account.disabled`),
//! and `details.switch_agent` / `details.sign_in` name the two ways on for a script.

use serde_json::{Value, json};

use acpmux::usage_limit::{AccountLimit, harness_name, other_agent};
use cmux_json::JsonSet as _;

/// Rewrites `error` (a `chat.turn_failed`) when `said`, the agent's error, names an account
/// limit. `harness` is the chat's harness id (`claude`, `codex`, `claude-sr`); empty is Claude.
pub(super) fn explain(error: &mut Value, said: &str, harness: &str) {
    let Some(limit) = acpmux::usage_limit::account_limit(said) else { return };
    let harness = if harness.is_empty() { "claude" } else { harness };
    let other = other_agent(harness);
    let base = harness.split(['/', '@']).next().unwrap_or(harness);
    let sign_in = format!("cmux harness login {base}");
    let message = message(&limit, harness, other, &sign_in);
    error.set("message", json!(message));
    if !error.get("details").is_some_and(Value::is_object) {
        error.set("details", json!({}));
    }
    let details = &mut error["details"];
    details.set("errorKind", json!(limit.error_kind()));
    details.set("agent_error", json!(said));
    details.set("harness", json!(harness));
    details.set("switch_agent", json!(other));
    details.set("sign_in", json!(sign_in));
    for (key, value) in limit.details() {
        details.set(&key, value);
    }
}

fn message(limit: &AccountLimit, harness: &str, other: &str, sign_in: &str) -> String {
    let name = harness_name(harness);
    let until = match limit.kind {
        acpmux::usage_limit::AccountLimitKind::UsageLimit => " until it resets",
        acpmux::usage_limit::AccountLimitKind::Disabled => "",
    };
    format!(
        "{} Sending again fails the same way{until}. To go on now, ask {} instead (--agent {other}), \
         or sign {name} in with another account (`{sign_in}`) and ask again.",
        limit.what_happened(Some(harness)),
        harness_name(other),
    )
}
