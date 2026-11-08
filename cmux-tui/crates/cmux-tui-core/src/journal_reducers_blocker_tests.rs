//! A hook-owned `blocked` row and the screen that shows the dialog going away.
//!
//! Claude Code fires no hook when the person dismisses a permission dialog
//! with Esc: the turn is interrupted, so neither `PostToolUse` nor `Stop`
//! comes. The screen-detection plugin sees the dialog go and reports the new
//! state once (it reports changes only). The roster must take that report,
//! or the terminal stays `blocked` in every view and the next
//! `terminal send` is refused as an answer to a dialog that is gone.

use serde_json::{Value, json};

use super::*;

const TERMINAL: &str = "term_00000000000000000000000000000d02";
const PLUGIN: &str = "agent-screen-detection";

/// One Claude hook event, built by the same ingress a real hook uses.
fn apply_hook(roster: &mut AgentRoster, sequence: u64, at_ms: u64, native_event: &str, tool: &str) {
    let ingress = crate::agent_hook_journal_ingress(
        "claude",
        native_event,
        Some(TERMINAL),
        json!({"tool_name": tool, "session_id": "claude-session-1"}),
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

fn plugin_payload(state: &str, observed_at_ms: u64) -> Value {
    plugin_payload_seen(state, observed_at_ms, false)
}

/// `visible_idle`: the detector matched the agent's idle prompt box.
fn plugin_payload_seen(state: &str, observed_at_ms: u64, visible_idle: bool) -> Value {
    json!({
        "format": AGENT_PLUGIN_FORMAT,
        "plugin": {"id": PLUGIN, "version": 1},
        "adapter": {"id": "claude", "version": 1},
        "event": "state.changed",
        "normalized": {
            "state": state,
            "source_session": "pid:4242",
            "observed_at_ms": observed_at_ms.to_string(),
            "plugin_generation": "1",
        },
        "native": {"visible": {"idle": visible_idle, "blocker": false, "working": false}},
    })
}

/// One screen-detection report, committed when it was observed.
fn apply_screen(roster: &mut AgentRoster, sequence: u64, at_ms: u64, state: &str) {
    apply_screen_seen(roster, sequence, at_ms, state, false);
}

fn apply_screen_seen(
    roster: &mut AgentRoster,
    sequence: u64,
    at_ms: u64,
    state: &str,
    visible_idle: bool,
) {
    let subjects = vec![JournalSubject { kind: "terminal".into(), id: TERMINAL.into() }];
    let payload = plugin_payload_seen(state, at_ms, visible_idle);
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

fn state(roster: &AgentRoster) -> &str {
    roster.entries.get(TERMINAL).map_or("", |entry| entry.state.as_str())
}

/// The bench sequence: a prompt, a permission dialog the screen also shows,
/// then Esc. Every report after Esc is within the 30 s hook freshness window.
fn denied_with_esc() -> AgentRoster {
    let mut roster = AgentRoster::default();
    apply_hook(&mut roster, 1, 10_000, "UserPromptSubmit", "");
    apply_screen(&mut roster, 2, 10_400, "working");
    // The dialog draws a moment before its hook arrives.
    apply_screen(&mut roster, 3, 12_000, "blocked");
    apply_hook(&mut roster, 4, 12_100, "PreToolUse", "Bash");
    apply_hook(&mut roster, 5, 12_150, "PermissionRequest", "Bash");
    assert_eq!(state(&roster), "blocked", "the dialog blocks the agent");
    // The plugin refreshes a stable visible blocker.
    apply_screen(&mut roster, 6, 12_900, "blocked");
    assert_eq!(state(&roster), "blocked");
    // Esc: no hook fires; the screen shows the idle prompt.
    apply_screen(&mut roster, 7, 15_000, "idle");
    roster
}

#[test]
fn a_dialog_dismissed_with_esc_clears_blocked_when_the_screen_shows_it_gone() {
    let roster = denied_with_esc();
    assert_eq!(state(&roster), "idle", "the dialog is gone, so the agent is not blocked");
    let entry = &roster.entries[TERMINAL];
    assert_eq!(entry.source, "plugin");
    assert_eq!(entry.since_ms(), 15_000);
}

#[test]
fn a_dismissed_dialog_stays_cleared_after_a_restart() {
    // A restart restores the snapshot, and a version bump refolds the journal: both agree.
    let roster = denied_with_esc();
    let restored = AgentRoster::restore(&roster.snapshot().to_string()).unwrap();
    assert_eq!(state(&restored), "idle");
}

#[test]
fn the_next_hook_after_a_dismissed_dialog_owns_the_terminal_again() {
    let mut roster = denied_with_esc();
    apply_hook(&mut roster, 8, 16_000, "UserPromptSubmit", "");
    assert_eq!(state(&roster), "working");
    assert_eq!(roster.entries[TERMINAL].source, "hook");
}

#[test]
fn an_approved_dialog_runs_on_through_the_screen_and_the_turn_ends_by_hook() {
    let mut roster = AgentRoster::default();
    apply_hook(&mut roster, 1, 10_000, "UserPromptSubmit", "");
    apply_screen(&mut roster, 2, 12_000, "blocked");
    apply_hook(&mut roster, 3, 12_150, "PermissionRequest", "Bash");
    // Approved: the dialog goes and the tool runs.
    apply_screen(&mut roster, 4, 13_000, "working");
    assert_eq!(state(&roster), "working");
    apply_hook(&mut roster, 5, 13_500, "PostToolUse", "Bash");
    assert_eq!(state(&roster), "working");
    apply_hook(&mut roster, 6, 14_000, "Stop", "");
    assert_eq!(state(&roster), "idle");
    assert_eq!(roster.entries[TERMINAL].source, "hook");
}

#[test]
fn a_hook_block_the_screen_never_showed_stays_blocked() {
    // A question whose UI the screen rules do not recognize: the screen keeps
    // reporting idle, which proves nothing about the hook's block.
    let mut roster = AgentRoster::default();
    apply_hook(&mut roster, 1, 10_000, "UserPromptSubmit", "");
    apply_screen(&mut roster, 2, 10_400, "working");
    apply_hook(&mut roster, 3, 12_000, "StopFailure", "");
    assert_eq!(state(&roster), "blocked");
    apply_screen(&mut roster, 4, 13_000, "idle");
    assert_eq!(state(&roster), "blocked");
    assert_eq!(roster.entries[TERMINAL].source, "hook");
}

#[test]
fn a_screen_blocker_seen_by_another_plugin_does_not_clear_a_hook_block() {
    let mut roster = AgentRoster::default();
    apply_hook(&mut roster, 1, 10_000, "UserPromptSubmit", "");
    apply_screen(&mut roster, 2, 12_000, "blocked");
    apply_hook(&mut roster, 3, 12_150, "PermissionRequest", "Bash");
    // A second producer that never saw the blocker reports idle.
    let subjects = vec![JournalSubject { kind: "terminal".into(), id: TERMINAL.into() }];
    let mut payload = plugin_payload("idle", 13_000);
    payload["plugin"]["id"] = json!("other-detector");
    roster.apply(&RosterEvent {
        producer_id: "other-detector",
        kind: "plugin.other-detector.agent.state.changed",
        subjects: &subjects,
        payload: &payload,
        sequence: 4,
        committed_at_ms: 13_000,
    });
    assert_eq!(state(&roster), "blocked");
}

#[test]
fn a_retired_terminal_forgets_its_screen_evidence() {
    let mut roster = denied_with_esc();
    assert!(roster.retire_terminal(TERMINAL));
    assert!(roster.screen_evidence.is_empty());
}

/// The real-build repro: Esc 0.3 s after the dialog drew, before the plugin's
/// next scan, so the plugin never reported the blocker. Its next report is
/// the idle prompt box, which no dialog shows.
#[test]
fn a_dialog_dismissed_before_the_screen_scan_clears_on_the_visible_prompt() {
    let mut roster = AgentRoster::default();
    apply_hook(&mut roster, 1, 10_000, "UserPromptSubmit", "");
    apply_screen(&mut roster, 2, 10_400, "working");
    apply_hook(&mut roster, 3, 12_100, "PreToolUse", "Bash");
    apply_hook(&mut roster, 4, 12_150, "PermissionRequest", "Bash");
    assert_eq!(state(&roster), "blocked");
    apply_screen_seen(&mut roster, 5, 12_600, "idle", true);
    assert_eq!(state(&roster), "idle");
    assert_eq!(roster.entries[TERMINAL].source, "plugin");
}

/// A prompt box seen before the hook's block is older evidence: it cannot
/// clear the block.
#[test]
fn a_visible_prompt_seen_before_the_block_does_not_clear_it() {
    let mut roster = AgentRoster::default();
    apply_hook(&mut roster, 1, 10_000, "UserPromptSubmit", "");
    apply_hook(&mut roster, 2, 12_150, "PermissionRequest", "Bash");
    apply_screen_seen(&mut roster, 3, 12_100, "idle", true);
    assert_eq!(state(&roster), "blocked");
}
