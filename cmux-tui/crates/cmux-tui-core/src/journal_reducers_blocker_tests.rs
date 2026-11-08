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
    })
}

/// One screen-detection report, committed when it was observed.
fn apply_screen(roster: &mut AgentRoster, sequence: u64, at_ms: u64, state: &str) {
    let subjects = vec![JournalSubject { kind: "terminal".into(), id: TERMINAL.into() }];
    let payload = plugin_payload(state, at_ms);
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
