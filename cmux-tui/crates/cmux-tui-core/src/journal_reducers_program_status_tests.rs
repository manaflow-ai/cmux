//! A hook-owned `blocked` row and the program's own status report, on a
//! daemon without the screen-detection plugin.

use serde_json::json;

use super::super::*;
use super::PROGRAM_STATUS_NATIVE_EVENT;

const TERMINAL: &str = "term_00000000000000000000000000000d07";

fn apply_hook(roster: &mut AgentRoster, sequence: u64, at_ms: u64, native_event: &str) {
    let ingress = crate::agent_hook_journal_ingress(
        "claude",
        native_event,
        Some(TERMINAL),
        json!({"tool_name": "Bash", "session_id": "claude-session-7"}),
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

/// One program status edge as the daemon journals it.
fn apply_program(roster: &mut AgentRoster, sequence: u64, at_ms: u64, state: &str) -> usize {
    let subjects = vec![JournalSubject { kind: "terminal".into(), id: TERMINAL.into() }];
    let payload = json!({
        "format": crate::agent_hooks::AGENT_HOOK_FORMAT,
        "adapter": {"id": "cmux", "version": 1},
        "native_event": PROGRAM_STATUS_NATIVE_EVENT,
        "normalized": {"state": state, "observed_at_ms": at_ms.to_string()},
        "native": {},
    });
    roster
        .apply(&RosterEvent {
            producer_id: AGENT_HOOK_PRODUCER_ID,
            kind: "agent.state.changed",
            subjects: &subjects,
            payload: &payload,
            sequence,
            committed_at_ms: at_ms + 1,
        })
        .len()
}

fn state(roster: &AgentRoster) -> (&str, &str) {
    roster
        .entries
        .get(TERMINAL)
        .map_or(("", ""), |entry| (entry.state.as_str(), entry.source.as_str()))
}

/// A prompt, then a permission dialog the program reports before its hook.
fn asked() -> AgentRoster {
    let mut roster = AgentRoster::default();
    apply_hook(&mut roster, 1, 10_000, "UserPromptSubmit");
    assert_eq!(apply_program(&mut roster, 2, 10_100, "working"), 0);
    assert_eq!(apply_program(&mut roster, 3, 12_000, "blocked"), 0);
    apply_hook(&mut roster, 4, 12_150, "PermissionRequest");
    assert_eq!(state(&roster), ("blocked", "hook"));
    roster
}

#[test]
fn dialog_dismissed_with_esc_ends_the_hook_block_from_the_programs_report() {
    let mut roster = asked();
    assert_eq!(apply_program(&mut roster, 5, 15_000, "idle"), 1);
    assert_eq!(state(&roster), ("idle", "detected"));
    assert_eq!(roster.entries[TERMINAL].agent.as_deref(), Some("claude"));
    // A restart restores the same roster.
    let restored = AgentRoster::restore(&roster.snapshot().to_string()).unwrap();
    assert_eq!(state(&restored), ("idle", "detected"));
    // The agent's next hook owns the terminal again.
    apply_hook(&mut roster, 6, 16_000, "UserPromptSubmit");
    assert_eq!(state(&roster), ("working", "hook"));
}

#[test]
fn dialog_report_without_a_blocked_first_leaves_the_hook_block() {
    let mut roster = AgentRoster::default();
    apply_hook(&mut roster, 1, 10_000, "UserPromptSubmit");
    apply_hook(&mut roster, 2, 12_150, "PermissionRequest");
    assert_eq!(apply_program(&mut roster, 3, 15_000, "idle"), 0);
    assert_eq!(state(&roster), ("blocked", "hook"));
}

#[test]
fn dialog_wait_that_ended_before_the_hook_block_does_not_end_it() {
    let mut roster = AgentRoster::default();
    apply_hook(&mut roster, 1, 10_000, "UserPromptSubmit");
    apply_program(&mut roster, 2, 11_000, "blocked");
    apply_hook(&mut roster, 3, 12_150, "PermissionRequest");
    // A stop the program saw before the hook's block (journaled late) is
    // the end of an earlier wait, not of this dialog.
    assert_eq!(apply_program(&mut roster, 4, 12_000, "working"), 0);
    assert_eq!(state(&roster), ("blocked", "hook"));
}

#[test]
fn dialog_evidence_goes_with_its_terminal() {
    let mut roster = asked();
    assert!(roster.retire_terminal(TERMINAL));
    apply_hook(&mut roster, 5, 20_000, "UserPromptSubmit");
    apply_hook(&mut roster, 6, 21_000, "PermissionRequest");
    assert_eq!(apply_program(&mut roster, 7, 22_000, "idle"), 0, "the old blocked is gone");
    assert_eq!(state(&roster), ("blocked", "hook"));
}
