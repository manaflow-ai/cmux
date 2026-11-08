//! A hook-owned `working` row whose end no hook reports, and the screen that
//! shows it ended.
//!
//! Claude Code fires no `Stop` hook when the person interrupts a turn with
//! Esc (manaflow-ai/cmux#36529), a `Stop` that runs can still be lost before
//! it reaches cmux (#21229), and a killed harness sends no `SessionEnd`
//! (#20874). Each left the sidebar on Running: the screen-detection plugin
//! saw the turn end or the agent go and said so once, and the roster dropped
//! it while the hook row was younger than 30 s, and always for an exit.
//!
//! `the_shown_state_matches_the_harness_one_second_after_each_transition`
//! is the probe: it drives turn end, Esc, a lost `Stop`, a killed harness and
//! a dismissed dialog for Claude Code and Codex, reads the roster 1 s after
//! each transition, and prints the share that matches the harness.

use serde_json::{Value, json};

use super::*;

const TERMINAL: &str = "term_00000000000000000000000000000e01";
const PLUGIN: &str = "agent-screen-detection";

struct Rig {
    roster: AgentRoster,
    adapter: &'static str,
    sequence: u64,
}

impl Rig {
    fn new(adapter: &'static str) -> Self {
        Self { roster: AgentRoster::default(), adapter, sequence: 0 }
    }

    fn next(&mut self) -> u64 {
        self.sequence += 1;
        self.sequence
    }

    /// One hook event, built by the same ingress a real hook uses.
    fn hook(&mut self, at_ms: u64, native_event: &str) {
        let sequence = self.next();
        let ingress = crate::agent_hook_journal_ingress(
            self.adapter,
            native_event,
            Some(TERMINAL),
            json!({"tool_name": "Bash", "session_id": format!("{}-session-1", self.adapter)}),
        )
        .unwrap();
        self.roster.apply(&RosterEvent {
            producer_id: &ingress.producer_id,
            kind: &ingress.kind,
            subjects: &ingress.subjects,
            payload: &ingress.payload,
            sequence,
            committed_at_ms: at_ms,
        });
    }

    /// One screen-detection report, committed when it was observed.
    /// `visible_idle`: the detector matched the agent's own idle prompt.
    fn screen_from(&mut self, producer: &str, at_ms: u64, state: &str, visible_idle: bool) {
        let sequence = self.next();
        let event = if state == "done" { "session.ended" } else { "state.changed" };
        let payload: Value = json!({
            "format": AGENT_PLUGIN_FORMAT,
            "plugin": {"id": producer, "version": 1},
            "adapter": {"id": self.adapter, "version": 1},
            "event": event,
            "normalized": {
                "state": state,
                "source_session": "pid:4242",
                "observed_at_ms": at_ms.to_string(),
                "plugin_generation": "1",
            },
            "native": {"visible": {"idle": visible_idle, "blocker": state == "blocked", "working": state == "working"}},
        });
        let subjects = vec![JournalSubject { kind: "terminal".into(), id: TERMINAL.into() }];
        let kind = format!("plugin.{producer}.agent.{event}");
        self.roster.apply(&RosterEvent {
            producer_id: producer,
            kind: &kind,
            subjects: &subjects,
            payload: &payload,
            sequence,
            committed_at_ms: at_ms,
        });
    }

    fn screen(&mut self, at_ms: u64, state: &str) {
        self.screen_from(PLUGIN, at_ms, state, false);
    }

    /// The agent's idle prompt is on screen again (no spinner).
    fn prompt(&mut self, at_ms: u64) {
        self.screen_from(PLUGIN, at_ms, "idle", true);
    }

    /// What every view shows for the terminal: no row once the agent is gone.
    fn shown(&self) -> &str {
        self.roster.entries.get(TERMINAL).map_or("done", |entry| entry.state.as_str())
    }

    /// A turn the plugin watched run: prompt, spinner, a tool call.
    fn running_turn(adapter: &'static str) -> Self {
        let mut rig = Self::new(adapter);
        rig.hook(10_000, "SessionStart");
        rig.prompt(10_050);
        rig.hook(11_000, "UserPromptSubmit");
        rig.screen(11_300, "working");
        rig.hook(13_000, "PreToolUse");
        rig.hook(13_500, "PostToolUse");
        assert_eq!(rig.shown(), "working");
        rig
    }
}

/// One transition, the state the harness is in after it, and what the
/// roster shows 1 s later. The events after the transition are the ones a
/// real build sends inside that second (the detector confirms an exit in six
/// 100 ms rechecks, and an idle prompt as soon as the screen is quiet).
fn scenarios() -> Vec<(String, &'static str, String)> {
    let mut out = Vec::new();
    for adapter in ["claude", "codex"] {
        // The turn ends and its Stop hook comes.
        let mut rig = Rig::running_turn(adapter);
        rig.hook(15_000, "Stop");
        rig.prompt(15_300);
        out.push((format!("{adapter}: turn end"), "idle", rig.shown().to_owned()));

        // Esc mid-turn: no hook fires; the spinner goes and the prompt shows.
        let mut rig = Rig::running_turn(adapter);
        rig.prompt(14_300);
        out.push((format!("{adapter}: Esc mid-turn"), "idle", rig.shown().to_owned()));

        // The turn ends but its Stop hook never reaches cmux.
        let mut rig = Rig::running_turn(adapter);
        rig.prompt(15_300);
        out.push((format!("{adapter}: lost Stop hook"), "idle", rig.shown().to_owned()));

        // The harness is killed mid-turn: no SessionEnd, the shell is back.
        let mut rig = Rig::running_turn(adapter);
        rig.screen(14_600, "done");
        out.push((format!("{adapter}: harness killed"), "done", rig.shown().to_owned()));

        // The harness quits normally between turns.
        let mut rig = Rig::running_turn(adapter);
        rig.hook(15_000, "Stop");
        rig.hook(16_000, "SessionEnd");
        rig.screen(16_400, "done");
        out.push((format!("{adapter}: harness quit"), "done", rig.shown().to_owned()));

        // A permission dialog dismissed with Esc (#38265).
        let mut rig = Rig::running_turn(adapter);
        rig.screen(14_000, "blocked");
        rig.hook(14_100, "PermissionRequest");
        rig.prompt(15_000);
        out.push((format!("{adapter}: dialog dismissed"), "idle", rig.shown().to_owned()));
    }
    out
}

#[test]
fn the_shown_state_matches_the_harness_one_second_after_each_transition() {
    let results = scenarios();
    let matched = results.iter().filter(|(_, want, got)| want == got).count();
    for (name, want, got) in &results {
        let mark = if want == got { "ok  " } else { "MISS" };
        println!("turn-state probe {mark} {name}: harness {want}, shown {got}");
    }
    println!(
        "turn-state probe: {matched}/{} shown states match the harness 1 s after the transition ({:.0}%)",
        results.len(),
        100.0 * matched as f64 / results.len() as f64
    );
    assert_eq!(matched, results.len(), "every shown state matches its harness");
}

#[test]
fn esc_mid_turn_clears_working_when_the_screen_shows_the_prompt() {
    let mut rig = Rig::running_turn("claude");
    rig.prompt(14_300);
    assert_eq!(rig.shown(), "idle");
    assert_eq!(rig.roster.entries[TERMINAL].source, "plugin");
    assert_eq!(rig.roster.entries[TERMINAL].since_ms(), 14_300);
}

#[test]
fn a_killed_harness_leaves_the_roster() {
    let mut rig = Rig::running_turn("claude");
    rig.screen(14_600, "done");
    assert!(!rig.roster.entries.contains_key(TERMINAL));
    assert!(!rig.roster.screen_evidence.contains_key(TERMINAL));
}

#[test]
fn an_interrupted_turn_stays_cleared_after_a_restart() {
    let mut rig = Rig::running_turn("claude");
    rig.prompt(14_300);
    let restored = AgentRoster::restore(&rig.roster.snapshot().to_string()).unwrap();
    assert_eq!(restored.entries[TERMINAL].state, "idle");
}

#[test]
fn the_next_prompt_after_an_interrupted_turn_is_the_hooks_again() {
    let mut rig = Rig::running_turn("claude");
    rig.prompt(14_300);
    rig.hook(16_000, "UserPromptSubmit");
    assert_eq!(rig.shown(), "working");
    assert_eq!(rig.roster.entries[TERMINAL].source, "hook");
}

/// A plain screen `idle` (no prompt matched) proves nothing about the turn.
#[test]
fn a_plain_screen_idle_does_not_end_a_hook_turn() {
    let mut rig = Rig::running_turn("claude");
    rig.screen(14_300, "idle");
    assert_eq!(rig.shown(), "working");
}

/// The plugin must have seen this turn run: an idle prompt it reports
/// without having seen a spinner is not the turn's end.
#[test]
fn a_prompt_the_plugin_never_saw_leave_does_not_end_a_hook_turn() {
    let mut rig = Rig::new("claude");
    rig.hook(10_000, "UserPromptSubmit");
    rig.prompt(10_400);
    assert_eq!(rig.shown(), "working");
}

/// A prompt seen before the hook's latest state report (a late append) is
/// older evidence.
#[test]
fn a_prompt_seen_before_the_hooks_report_does_not_end_the_turn() {
    let mut rig = Rig::new("claude");
    rig.hook(10_000, "SessionStart");
    rig.screen(10_300, "working");
    rig.hook(12_000, "UserPromptSubmit");
    rig.prompt(11_900);
    assert_eq!(rig.shown(), "working");
}

/// Another producer that never saw the agent cannot end it.
#[test]
fn another_plugins_exit_does_not_remove_a_hook_row() {
    let mut rig = Rig::running_turn("claude");
    rig.screen_from("other-detector", 14_600, "done", false);
    assert_eq!(rig.shown(), "working");
    rig.screen_from("other-detector", 14_700, "idle", true);
    assert_eq!(rig.shown(), "working");
}

/// An exit observed before the hook's latest state report (the turn's
/// start) is not this run's.
#[test]
fn an_exit_seen_before_the_hooks_report_does_not_remove_it() {
    let mut rig = Rig::running_turn("claude");
    rig.screen(10_900, "done");
    assert_eq!(rig.shown(), "working");
}

/// A working report the plugin saw before this turn's prompt, appended late,
/// is not this turn running: the next prompt box does not end the turn.
#[test]
fn a_late_working_report_from_before_the_prompt_does_not_end_the_turn() {
    let mut rig = Rig::new("claude");
    rig.hook(10_000, "SessionStart");
    rig.hook(12_000, "UserPromptSubmit");
    rig.screen(11_500, "working");
    rig.prompt(12_200);
    assert_eq!(rig.shown(), "working");
    // The screen then shows this turn run and end.
    rig.screen(12_600, "working");
    rig.prompt(14_000);
    assert_eq!(rig.shown(), "idle");
}

/// A late append older than the recorded observation changes no evidence.
#[test]
fn an_older_observation_does_not_replace_newer_evidence() {
    let mut rig = Rig::running_turn("claude");
    rig.prompt(14_300);
    assert_eq!(rig.shown(), "idle");
    rig.hook(16_000, "UserPromptSubmit");
    // A working report from the previous turn arrives late.
    rig.screen(14_000, "working");
    rig.prompt(16_200);
    assert_eq!(rig.shown(), "working");
}

/// A second prompt while the row is still `working` (no `Stop` between, or a
/// lost one) opens a new turn: the screen must see that turn run before its
/// idle prompt ends it (second review of #38417, F1).
#[test]
fn a_prompt_submitted_while_working_fences_the_earlier_evidence() {
    let mut rig = Rig::running_turn("claude");
    rig.hook(16_000, "UserPromptSubmit");
    rig.prompt(18_000);
    assert_eq!(rig.shown(), "working");
    rig.screen(18_300, "working");
    rig.prompt(19_000);
    assert_eq!(rig.shown(), "idle");
}

#[test]
fn a_retired_terminal_forgets_its_turn_start() {
    let mut rig = Rig::running_turn("claude");
    assert!(rig.roster.retire_terminal(TERMINAL));
    assert!(rig.roster.hook_turn_started_at.is_empty());
}
