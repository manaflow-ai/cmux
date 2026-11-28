//! A hook-owned `blocked` row and the screen that shows the dialog going away.
//!
//! Claude Code fires no hook when the person dismisses a permission dialog
//! with Esc: the turn is interrupted, so neither `PostToolUse` nor `Stop`
//! comes. The screen-detection plugin sees the dialog go and reports the new
//! state once (it reports changes only). The roster must take that report,
//! or the terminal stays `blocked` in every view (agent list, sidebar,
//! agents view) for a dialog that is gone.

use serde_json::{Value, json};

use super::*;

const TERMINAL: &str = "term_00000000000000000000000000000d02";
const PLUGIN: &str = "agent-screen-detection";

/// One Claude hook event, built by the same ingress a real hook uses.
fn apply_hook(roster: &mut AgentRoster, at_ms: u64, native_event: &str, tool: &str) {
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
fn apply_screen(roster: &mut AgentRoster, at_ms: u64, state: &str) {
    apply_screen_seen(roster, at_ms, state, false);
}

fn apply_screen_seen(roster: &mut AgentRoster, at_ms: u64, state: &str, visible_idle: bool) {
    let subjects = vec![JournalSubject { kind: "terminal".into(), id: TERMINAL.into() }];
    let payload = plugin_payload_seen(state, at_ms, visible_idle);
    let kind = format!("plugin.{PLUGIN}.agent.state.changed");
    roster.apply(&RosterEvent {
        producer_id: PLUGIN,
        kind: &kind,
        subjects: &subjects,
        payload: &payload,
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
    apply_hook(&mut roster, 10_000, "UserPromptSubmit", "");
    apply_screen(&mut roster, 10_400, "working");
    // The dialog draws a moment before its hook arrives.
    apply_screen(&mut roster, 12_000, "blocked");
    apply_hook(&mut roster, 12_100, "PreToolUse", "Bash");
    apply_hook(&mut roster, 12_150, "PermissionRequest", "Bash");
    assert_eq!(state(&roster), "blocked", "the dialog blocks the agent");
    // The plugin refreshes a stable visible blocker.
    apply_screen(&mut roster, 12_900, "blocked");
    assert_eq!(state(&roster), "blocked");
    // Esc: no hook fires; the screen shows the idle prompt.
    apply_screen(&mut roster, 15_000, "idle");
    roster
}

#[test]
fn a_dialog_dismissed_with_esc_clears_blocked_when_the_screen_shows_it_gone() {
    let roster = denied_with_esc();
    assert_eq!(state(&roster), "idle", "the dialog is gone, so the agent is not blocked");
    let entry = &roster.entries[TERMINAL];
    assert_eq!(entry.source, "plugin");
    assert_eq!(entry.updated_at_ms, 15_000);
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
    apply_hook(&mut roster, 16_000, "UserPromptSubmit", "");
    assert_eq!(state(&roster), "working");
    assert_eq!(roster.entries[TERMINAL].source, "hook");
}

#[test]
fn an_approved_dialog_runs_on_through_the_screen_and_the_turn_ends_by_hook() {
    let mut roster = AgentRoster::default();
    apply_hook(&mut roster, 10_000, "UserPromptSubmit", "");
    apply_screen(&mut roster, 12_000, "blocked");
    apply_hook(&mut roster, 12_150, "PermissionRequest", "Bash");
    // Approved: the dialog goes and the tool runs.
    apply_screen(&mut roster, 13_000, "working");
    assert_eq!(state(&roster), "working");
    apply_hook(&mut roster, 13_500, "PostToolUse", "Bash");
    assert_eq!(state(&roster), "working");
    apply_hook(&mut roster, 14_000, "Stop", "");
    assert_eq!(state(&roster), "idle");
    assert_eq!(roster.entries[TERMINAL].source, "hook");
}

#[test]
fn a_hook_block_the_screen_never_showed_stays_blocked() {
    // A question whose UI the screen rules do not recognize: the screen keeps
    // reporting idle, which proves nothing about the hook's block.
    let mut roster = AgentRoster::default();
    apply_hook(&mut roster, 10_000, "UserPromptSubmit", "");
    apply_screen(&mut roster, 10_400, "working");
    apply_hook(&mut roster, 12_000, "StopFailure", "");
    assert_eq!(state(&roster), "blocked");
    apply_screen(&mut roster, 13_000, "idle");
    assert_eq!(state(&roster), "blocked");
    assert_eq!(roster.entries[TERMINAL].source, "hook");
}

#[test]
fn a_screen_blocker_seen_by_another_plugin_does_not_clear_a_hook_block() {
    let mut roster = AgentRoster::default();
    apply_hook(&mut roster, 10_000, "UserPromptSubmit", "");
    apply_screen(&mut roster, 12_000, "blocked");
    apply_hook(&mut roster, 12_150, "PermissionRequest", "Bash");
    // A second producer that never saw the blocker reports idle.
    let subjects = vec![JournalSubject { kind: "terminal".into(), id: TERMINAL.into() }];
    let mut payload = plugin_payload("idle", 13_000);
    payload["plugin"]["id"] = json!("other-detector");
    roster.apply(&RosterEvent {
        producer_id: "other-detector",
        kind: "plugin.other-detector.agent.state.changed",
        subjects: &subjects,
        payload: &payload,
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
    apply_hook(&mut roster, 10_000, "UserPromptSubmit", "");
    apply_screen(&mut roster, 10_400, "working");
    apply_hook(&mut roster, 12_100, "PreToolUse", "Bash");
    apply_hook(&mut roster, 12_150, "PermissionRequest", "Bash");
    assert_eq!(state(&roster), "blocked");
    apply_screen_seen(&mut roster, 12_600, "idle", true);
    assert_eq!(state(&roster), "idle");
    assert_eq!(roster.entries[TERMINAL].source, "plugin");
}

/// A prompt box seen before the hook's block is older evidence: it cannot
/// clear the block.
#[test]
fn a_visible_prompt_seen_before_the_block_does_not_clear_it() {
    let mut roster = AgentRoster::default();
    apply_hook(&mut roster, 10_000, "UserPromptSubmit", "");
    apply_hook(&mut roster, 12_150, "PermissionRequest", "Bash");
    apply_screen_seen(&mut roster, 12_100, "idle", true);
    assert_eq!(state(&roster), "blocked");
}

/// Screen evidence belongs to the plugin child that saw it: a restarted
/// plugin's first report cannot end a block that only an earlier child saw.
mod plugin_child {
    use super::*;

    /// One screen-detection report from the plugin child `generation`.
    fn apply_screen_from(roster: &mut AgentRoster, at_ms: u64, state: &str, generation: &str) {
        let subjects = vec![JournalSubject { kind: "terminal".into(), id: TERMINAL.into() }];
        let mut payload = plugin_payload(state, at_ms);
        payload["normalized"]["plugin_generation"] = json!(generation);
        let kind = format!("plugin.{PLUGIN}.agent.state.changed");
        roster.apply(&RosterEvent {
            producer_id: PLUGIN,
            kind: &kind,
            subjects: &subjects,
            payload: &payload,
            committed_at_ms: at_ms,
        });
    }

    /// The supervisor's `agent.plugin.exited` for the plugin child `generation`.
    fn apply_plugin_exit(roster: &mut AgentRoster, at_ms: u64, generation: &str) {
        let payload = json!({
            "format": crate::agent_hooks::AGENT_HOOK_FORMAT,
            "adapter": {"id": "cmux", "version": 1},
            "native_event": crate::agent_hooks::JOURNAL_PLUGIN_EXIT_NATIVE_EVENT,
            "normalized": {
                "plugin_id": PLUGIN,
                "plugin_generation": generation,
                "observed_at_ms": at_ms.to_string(),
            },
            "native": {},
        });
        roster.apply(&RosterEvent {
            producer_id: AGENT_HOOK_PRODUCER_ID,
            kind: "agent.plugin.exited",
            subjects: &[],
            payload: &payload,
            committed_at_ms: at_ms,
        });
    }

    /// The plugin saw a dialog whose turn the hook then reported ended; the
    /// plugin stopped before it saw the dialog go, and the agent later blocks
    /// on a question the screen rules do not recognize.
    fn later_block_after_the_plugin_stopped(exit: bool) -> AgentRoster {
        let mut roster = AgentRoster::default();
        apply_hook(&mut roster, 10_000, "UserPromptSubmit", "");
        apply_screen_from(&mut roster, 12_000, "blocked", "1");
        apply_hook(&mut roster, 12_150, "PermissionRequest", "Bash");
        apply_hook(&mut roster, 13_000, "Stop", "");
        assert_eq!(state(&roster), "idle");
        if exit {
            apply_plugin_exit(&mut roster, 14_000, "1");
        }
        apply_hook(&mut roster, 15_000, "StopFailure", "");
        assert_eq!(state(&roster), "blocked");
        roster
    }

    #[test]
    fn a_restarted_plugins_first_idle_does_not_clear_a_later_hook_block() {
        let mut roster = later_block_after_the_plugin_stopped(true);
        // The new child never saw a blocker: its idle proves nothing.
        apply_screen_from(&mut roster, 16_000, "idle", "2");
        assert_eq!(state(&roster), "blocked");
        assert_eq!(roster.entries[TERMINAL].source, "hook");
    }

    #[test]
    fn a_plugin_exit_drops_that_childs_screen_evidence() {
        let roster = later_block_after_the_plugin_stopped(true);
        assert!(roster.screen_evidence.is_empty(), "{:?}", roster.screen_evidence);
    }

    #[test]
    fn a_new_plugin_child_without_a_journaled_exit_does_not_clear_a_later_hook_block() {
        // The supervisor's exit record never reached the journal (a crash).
        let mut roster = later_block_after_the_plugin_stopped(false);
        apply_screen_from(&mut roster, 16_000, "idle", "2");
        assert_eq!(state(&roster), "blocked");
    }

    #[test]
    fn the_same_plugin_child_still_clears_the_blocker_it_saw() {
        let mut roster = AgentRoster::default();
        apply_hook(&mut roster, 10_000, "UserPromptSubmit", "");
        apply_screen_from(&mut roster, 12_000, "blocked", "2");
        apply_hook(&mut roster, 12_150, "PermissionRequest", "Bash");
        apply_screen_from(&mut roster, 15_000, "idle", "2");
        assert_eq!(state(&roster), "idle");
    }

    #[test]
    fn a_late_report_of_an_older_plugin_child_keeps_the_newer_childs_blocker() {
        let mut roster = AgentRoster::default();
        apply_hook(&mut roster, 10_000, "UserPromptSubmit", "");
        apply_screen_from(&mut roster, 12_000, "blocked", "3");
        apply_hook(&mut roster, 12_150, "PermissionRequest", "Bash");
        // Child 2 crashed with no journaled exit; its last report arrives late.
        apply_screen_from(&mut roster, 12_500, "working", "2");
        assert_eq!(state(&roster), "blocked");
        // Esc: child 3, which saw the dialog, sees it gone.
        apply_screen_from(&mut roster, 15_000, "idle", "3");
        assert_eq!(state(&roster), "idle");
    }

    #[test]
    fn a_restored_record_of_plugin_child_zero_is_invalid() {
        let record: ScreenEvidence = serde_json::from_value(
            json!({"producer": PLUGIN, "generation": 0, "state": "blocked"}),
        )
        .unwrap();
        assert!(!record.valid());
    }
}
