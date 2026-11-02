//! `usage_warnings`: the rules a session summary's `usageStats` breaks, under the configured
//! thresholds. The numbers are the 2026-10-30 runaway deputies' (no cap, 290-330k context and
//! more, 67-90 subagents an hour) against an ordinary capped lane.

use super::usage_warnings::{short, usage_warnings};
use crate::config::{UsageLimits, UsageWarningsConfig};
use serde_json::{Value, json};

fn row(family: &str, stats: Value) -> Value {
    json!({"name": "dep-1", "status": "idle", "family": family, "usageStats": stats})
}

fn rules(warnings: &[Value]) -> Vec<&str> {
    warnings.iter().filter_map(|w| w["rule"].as_str()).collect()
}

#[test]
fn a_runaway_claude_session_breaks_all_three_rules_with_its_numbers() {
    let deputy = row(
        "claude",
        json!({"autocompact": "none", "autocompactCap": null, "contextTokens": 412_000, "subagents1h": 90}),
    );
    let w = usage_warnings(&deputy, &UsageLimits::default());
    assert_eq!(rules(&w), ["noAutocompactCap", "contextTokens", "subagentsPerHour"]);
    assert_eq!(w[0]["value"], 412_000);
    assert_eq!(w[0]["limit"], Value::Null);
    assert_eq!(
        w[0]["text"],
        "No autocompact cap: context is 412k and only compacts at the model's limit. \
         Rotate onto a capped profile (lane-place rotate dep-1 --harness claude-sr2)"
    );
    assert_eq!(
        w[0]["actions"],
        json!([{"label": "Rotate onto a capped profile", "command": "lane-place rotate dep-1 --harness claude-sr2",
                "pending": null}])
    );
    // Compact first; rotate when that is not enough.
    assert_eq!(
        w[1],
        json!({"rule": "contextTokens", "value": 412_000, "limit": 400_000,
        "finding": "Context 412k tokens, above the 400k warning line",
        "text": "Context 412k tokens, above the 400k warning line. Compact it (acpmux send dep-1 /compact) \
                 or rotate to a fresh session (lane-place rotate dep-1)",
        "actions": [
            {"label": "Compact it", "command": "acpmux send dep-1 /compact", "pending": null},
            {"label": "rotate to a fresh session", "command": "lane-place rotate dep-1", "pending": null},
        ]})
    );
    assert_eq!(
        w[2],
        json!({"rule": "subagentsPerHour", "value": 90, "limit": 40,
        "finding": "90 subagents started in the last hour, above 40",
        "text": "90 subagents started in the last hour, above 40. Open the session to see what it starts; \
                 cancel its turn to stop it (acpmux session cancel dep-1)",
        "actions": [{"label": "Open the session to see what it starts; cancel its turn to stop it",
                   "command": "acpmux session cancel dep-1", "pending": null}]})
    );
    assert_eq!(w.iter().map(short).collect::<Vec<_>>(), ["no-cap", "ctx 412k", "90 sub/h"]);
}

/// A warning with no number shows `?`, never a made-up zero.
#[test]
fn a_cell_without_a_number_says_so() {
    assert_eq!(short(&json!({"rule": "contextTokens", "value": null})), "ctx ?");
    assert_eq!(short(&json!({"rule": "subagentsPerHour"})), "? sub/h");
}

#[test]
fn an_ordinary_capped_lane_has_none() {
    let lane = row(
        "claude",
        json!({"autocompact": "capped", "autocompactCap": 400_000, "contextTokens": 180_000, "subagents1h": 9}),
    );
    assert!(usage_warnings(&lane, &UsageLimits::default()).is_empty());
}

#[test]
fn the_limits_are_exclusive() {
    let at = row(
        "claude",
        json!({"autocompact": "capped", "autocompactCap": 400_000, "contextTokens": 400_000, "subagents1h": 40}),
    );
    assert!(usage_warnings(&at, &UsageLimits::default()).is_empty());
}

#[test]
fn only_claude_is_held_to_an_autocompact_cap() {
    let codex = row(
        "codex",
        json!({"autocompact": "none", "autocompactCap": null, "contextTokens": 120_000}),
    );
    assert!(usage_warnings(&codex, &UsageLimits::default()).is_empty());
    let big = row(
        "codex",
        json!({"autocompact": "none", "autocompactCap": null, "contextTokens": 600_000}),
    );
    assert_eq!(rules(&usage_warnings(&big, &UsageLimits::default())), ["contextTokens"]);
}

#[test]
fn no_stats_yet_or_a_closed_session_warns_nothing() {
    let none = json!({"status": "idle", "family": "claude"});
    assert!(usage_warnings(&none, &UsageLimits::default()).is_empty());
    let mut closed =
        row("claude", json!({"autocompact": "none", "autocompactCap": null, "subagents1h": 90}));
    closed["status"] = json!("closed");
    assert!(usage_warnings(&closed, &UsageLimits::default()).is_empty());
}

#[test]
fn no_cap_with_no_context_read_yet_still_warns() {
    let fresh = row(
        "claude",
        json!({"autocompact": "none", "autocompactCap": null, "contextTokens": null}),
    );
    let w = usage_warnings(&fresh, &UsageLimits::default());
    assert_eq!(rules(&w), ["noAutocompactCap"]);
    assert_eq!(w[0]["value"], Value::Null);
    assert!(
        w[0]["text"]
            .as_str()
            .unwrap()
            .starts_with("No autocompact cap: context only compacts at the model's limit. ")
    );
}

#[test]
fn the_config_moves_or_turns_off_each_rule() {
    let cfg: UsageWarningsConfig = serde_json::from_value(
        json!({"contextTokens": 1_000_000, "subagentsPerHour": 0, "autocompactCap": false}),
    )
    .unwrap();
    let limits = cfg.limits();
    assert_eq!(
        limits,
        UsageLimits {
            context_tokens: Some(1_000_000),
            subagents_per_hour: None,
            autocompact_cap: false
        }
    );
    let deputy = row(
        "claude",
        json!({"autocompact": "none", "autocompactCap": null, "contextTokens": 1_200_000, "subagents1h": 90}),
    );
    let w = usage_warnings(&deputy, &limits);
    assert_eq!(rules(&w), ["contextTokens"]);
    assert!(
        w[0]["text"]
            .as_str()
            .unwrap()
            .starts_with("Context 1.2M tokens, above the 1.0M warning line. Compact it")
    );
    // The defaults are written nowhere: a config without the section keeps an empty file.
    assert!(UsageWarningsConfig::default().is_default());
    assert_eq!(serde_json::to_value(UsageWarningsConfig::default()).unwrap(), json!({}));
}

/// Unknown stays unknown: a cap acpmux could not read, or a count it could not read (null), never
/// warns; a cap known to be absent does.
#[test]
fn an_unknown_field_never_warns() {
    for cap in [
        json!({"autocompact": "unknown", "autocompactCap": null}),
        json!({"autocompactCap": null}),
        json!({}),
    ] {
        let mut stats = cap;
        stats["contextTokens"] = Value::Null;
        stats["subagents1h"] = Value::Null;
        let unread = row("claude", stats);
        assert!(usage_warnings(&unread, &UsageLimits::default()).is_empty(), "{unread}");
    }
    // A percentage cap of an unknown window: capped, with no number.
    let capped = row("claude", json!({"autocompact": "capped", "autocompactCap": null}));
    assert!(usage_warnings(&capped, &UsageLimits::default()).is_empty());
    let none = row("claude", json!({"autocompact": "none", "autocompactCap": null}));
    assert_eq!(rules(&usage_warnings(&none, &UsageLimits::default())), ["noAutocompactCap"]);
}

/// A peer's row is renamed `<peer>/<name>`; its commands follow, so they reach the peer's session.
#[test]
fn a_peers_row_names_the_peers_session_in_its_commands() {
    let mut summary = row("claude", json!({"autocompact": "none", "contextTokens": 412_000}));
    let warnings = usage_warnings(&summary, &UsageLimits::default());
    summary["usageWarnings"] = json!(warnings);
    summary["name"] = json!("box/dep-1");
    super::usage_warnings::for_name(&mut summary);
    let w = summary["usageWarnings"].as_array().unwrap();
    assert_eq!(w[0]["actions"][0]["command"], "lane-place rotate box/dep-1 --harness claude-sr2");
    assert_eq!(w[1]["actions"][0]["command"], "acpmux send box/dep-1 /compact");
    assert_eq!(
        w[1]["text"],
        "Context 412k tokens, above the 400k warning line. Compact it (acpmux send box/dep-1 /compact) \
         or rotate to a fresh session (lane-place rotate box/dep-1)"
    );
    assert!(!w[1]["text"].as_str().unwrap().contains(" dep-1 "), "no bare name is left");
}
