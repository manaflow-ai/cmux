//! `extra.state_reason`: the roster fold records why it holds each state
//! (bench round 4: herdr `agent explain`; cmux showed `source` only).

use serde_json::{Value, json};

use super::super::*;

const TERMINAL: &str = "term_00000000000000000000000000000e51";
const PLUGIN: &str = "agent-screen-detection";

fn apply_hook(roster: &mut AgentRoster, sequence: u64, at_ms: u64, native_event: &str) {
    let ingress = crate::agent_hook_journal_ingress(
        "claude",
        native_event,
        Some(TERMINAL),
        json!({"tool_name": "Bash", "session_id": "claude-session-w5t"}),
    )
    .unwrap();
    roster.apply(&RosterEvent {
        producer_id: &ingress.producer_id,
        kind: &ingress.kind,
        subjects: &ingress.subjects,
        payload: &ingress.payload,
        sequence,
        committed_at_ms: at_ms,
    });
}

/// One screen-detection report with the explain fields the plugin sends.
fn apply_screen(
    roster: &mut AgentRoster,
    sequence: u64,
    at_ms: u64,
    state: &str,
    rule: Option<&str>,
    visible_idle: bool,
) {
    let subjects = vec![JournalSubject { kind: "terminal".into(), id: TERMINAL.into() }];
    let payload = json!({
        "format": AGENT_PLUGIN_FORMAT,
        "plugin": {"id": PLUGIN, "version": 1},
        "adapter": {"id": "claude", "version": 1},
        "event": "state.changed",
        "normalized": {
            "state": state,
            "source_session": "pid:4242",
            "observed_at_ms": at_ms.to_string(),
            "plugin_generation": "1",
        },
        "native": {
            "engine": "herdr-manifest-v3",
            "matched_rule": rule,
            "basis": if rule.is_some() { "rule" } else { "idle_fallback" },
            "manifest": {"version": "2026.10.11.1", "source": "bundled"},
            "evidence": "Do you want to proceed?\n❯ 1. Yes",
            "visible": {"idle": visible_idle, "blocker": state == "blocked", "working": false},
        },
    });
    let kind = format!("plugin.{PLUGIN}.agent.state.changed");
    roster.apply(&RosterEvent {
        producer_id: PLUGIN,
        kind: &kind,
        subjects: &subjects,
        payload: &payload,
        sequence,
        committed_at_ms: at_ms,
    });
}

fn reason(roster: &AgentRoster) -> Value {
    roster.state_reasons().remove(TERMINAL).expect("the terminal has a roster row")
}

#[test]
fn w5t_hook_state_names_its_event_time_and_the_state_before() {
    let mut roster = AgentRoster::default();
    apply_hook(&mut roster, 1, 10_000, "UserPromptSubmit");
    apply_hook(&mut roster, 2, 14_000, "Stop");
    let reason = reason(&roster);
    assert_eq!(reason["since_ms"], "14000", "{reason}");
    let cause = &reason["cause"];
    assert_eq!(cause["sequence"], "2", "{reason}");
    assert_eq!(cause["at_ms"], "14000", "{reason}");
    assert_eq!(cause["event"], "Stop", "{reason}");
    assert_eq!(cause["decision"], "hook", "{reason}");
    assert!(cause["kind"].as_str().is_some_and(|kind| kind.starts_with("agent.")), "{reason}");
    assert!(cause.get("rule").is_none(), "a hook has no screen rule: {reason}");
    let previous = &reason["previous"];
    assert_eq!(previous["state"], "working", "{reason}");
    assert_eq!(previous["source"], "hook", "{reason}");
    assert_eq!(previous["since_ms"], "10000", "{reason}");
    assert_eq!(previous["until_ms"], "14000", "{reason}");
}

#[test]
fn w5t_a_report_that_keeps_the_state_keeps_the_record_that_set_it() {
    let mut roster = AgentRoster::default();
    apply_hook(&mut roster, 1, 10_000, "UserPromptSubmit");
    // Prompts typed while the turn runs report working again.
    apply_hook(&mut roster, 2, 11_000, "UserPromptSubmit");
    apply_hook(&mut roster, 3, 12_000, "UserPromptSubmit");
    let reason = reason(&roster);
    assert_eq!(roster.entries[TERMINAL].state, "working");
    assert_eq!(reason["cause"]["sequence"], "1", "the turn start set working: {reason}");
    assert_eq!(reason["cause"]["event"], "UserPromptSubmit", "{reason}");
    assert_eq!(reason["since_ms"], "10000", "{reason}");
    assert_eq!(reason["updated_at_ms"], "12000", "{reason}");
}

#[test]
fn w5t_screen_state_names_rule_manifest_and_the_screen_record() {
    let mut roster = AgentRoster::default();
    apply_screen(&mut roster, 1, 20_000, "working", Some("live_turn_working"), false);
    apply_screen(&mut roster, 2, 21_000, "blocked", Some("bash_permission_prompt"), false);
    let reason = reason(&roster);
    let cause = &reason["cause"];
    assert_eq!(cause["decision"], "screen", "{reason}");
    assert_eq!(cause["producer"], PLUGIN, "{reason}");
    assert_eq!(cause["rule"], "bash_permission_prompt", "{reason}");
    assert_eq!(cause["basis"], "rule", "{reason}");
    assert_eq!(cause["manifest"]["version"], "2026.10.11.1", "{reason}");
    assert_eq!(cause["manifest"]["source"], "bundled", "{reason}");
    assert_eq!(cause["sequence"], "2", "{reason}");
    assert_eq!(cause["observed_at_ms"], "21000", "{reason}");
    assert_eq!(reason["previous"]["state"], "working", "{reason}");
    assert_eq!(reason["previous"]["source"], "plugin", "{reason}");
    let screen = &reason["screen"];
    assert_eq!(screen["state"], "blocked", "{reason}");
    assert_eq!(screen["sequence"], "2", "the screen's own record: {reason}");
    assert_eq!(screen["rule"], "bash_permission_prompt", "{reason}");
}

#[test]
fn w5t_the_screen_over_a_hook_dialog_says_so_and_a_fresh_hook_shows_the_ignored_screen() {
    let mut roster = AgentRoster::default();
    apply_hook(&mut roster, 1, 10_000, "UserPromptSubmit");
    apply_hook(&mut roster, 2, 12_150, "PermissionRequest");
    // A fresh hook owns the row: the screen's working is noted, not taken.
    apply_screen(&mut roster, 3, 12_500, "blocked", Some("bash_permission_prompt"), false);
    let held = reason(&roster);
    assert_eq!(held["cause"]["decision"], "hook", "{held}");
    assert_eq!(held["cause"]["event"], "PermissionRequest", "{held}");
    assert_eq!(held["screen"]["state"], "blocked", "{held}");
    assert_eq!(held["screen"]["sequence"], "3", "{held}");
    // Esc: no hook fires; the screen shows the idle prompt.
    apply_screen(&mut roster, 4, 15_000, "idle", Some("live_prompt_box"), true);
    let cleared = reason(&roster);
    assert_eq!(roster.entries[TERMINAL].state, "idle");
    assert_eq!(cleared["cause"]["decision"], "screen_cleared_hook_blocker", "{cleared}");
    assert_eq!(cleared["cause"]["rule"], "live_prompt_box", "{cleared}");
    assert_eq!(cleared["previous"]["state"], "blocked", "{cleared}");
    assert_eq!(cleared["previous"]["source"], "hook", "{cleared}");
    assert_eq!(cleared["previous"]["since_ms"], "12150", "{cleared}");
    assert_eq!(cleared["previous"]["until_ms"], "15000", "{cleared}");
}

#[test]
fn w5t_the_state_reason_survives_a_restart() {
    let mut roster = AgentRoster::default();
    apply_hook(&mut roster, 1, 10_000, "UserPromptSubmit");
    apply_hook(&mut roster, 2, 14_000, "Stop");
    let restored = AgentRoster::restore(&roster.snapshot().to_string()).unwrap();
    assert_eq!(reason(&restored), reason(&roster));
    assert_eq!(reason(&restored)["cause"]["event"], "Stop");
}
