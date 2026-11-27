//! The roster's record of what each terminal's program last said of its own
//! wait (OSC 7501 `blocked`, then `working` or `idle`, journaled by the
//! daemon as [`PROGRAM_STATUS_NATIVE_EVENT`]), and the rule that lets that
//! report end a hook-owned `blocked` row
//! ([`AgentRoster::apply_program_status`]).
//!
//! Claude Code fires no hook when the person dismisses its permission dialog
//! with Esc: the turn is interrupted, so neither the tool's completion nor
//! the turn's end is reported, and the hook row stays `blocked`. The
//! screen-detection plugin can see the dialog go; without the plugin, Claude
//! Code's own status report is the only witness.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::{
    AGENT_HOOK_PRODUCER_ID, AgentRoster, RosterDelta, RosterEntry, RosterEvent,
    agent_state_from_str,
};
use crate::{AgentSource, AgentState};

/// The native event of the daemon's program status evidence
/// (`agent.state.changed`, adapter [`PROGRAM_STATUS_ADAPTER`]).
pub(crate) const PROGRAM_STATUS_NATIVE_EVENT: &str = "ProgramStatusObserved";
/// The adapter of program status evidence: the daemon, not an agent.
pub(crate) const PROGRAM_STATUS_ADAPTER: &str = "cmux";

/// Whether a journal record is the daemon's program status evidence, whose
/// roster delta the host applies like a plugin's (hook deltas are the hook
/// projector's).
pub(crate) fn is_program_status_evidence(producer_id: &str, payload: &Value) -> bool {
    producer_id == AGENT_HOOK_PRODUCER_ID
        && payload.pointer("/adapter/id").and_then(Value::as_str) == Some(PROGRAM_STATUS_ADAPTER)
        && payload.get("native_event").and_then(Value::as_str) == Some(PROGRAM_STATUS_NATIVE_EVENT)
}

/// The last wait state a terminal's program reported of itself.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(super) struct ProgramStatusEvidence {
    state: String,
}

impl ProgramStatusEvidence {
    /// A restored record holds a state a program reports.
    pub(super) fn valid(&self) -> bool {
        agent_state_from_str(&self.state).is_some_and(reported)
    }
}

/// The states a program's status reports to the roster.
fn reported(state: AgentState) -> bool {
    matches!(state, AgentState::Blocked | AgentState::Working | AgentState::Idle)
}

impl RosterEvent<'_> {
    pub(super) fn is_program_status_evidence(&self) -> bool {
        is_program_status_evidence(self.producer_id, self.payload)
    }
}

impl AgentRoster {
    /// Fold one program status edge: record it, and when it ends a wait the
    /// program reported before (`blocked`, then `working` or `idle`) while a
    /// hook row of the terminal is `blocked` since earlier, the program's
    /// state replaces that row. The program said it shows its dialog and then
    /// that it does not: the dialog the hook announced is gone. An `idle`
    /// that follows no `blocked` proves nothing about the hook's dialog (a
    /// program that reports only part of its states), so the row stays.
    ///
    /// The new row is `detected` (the daemon read it from the terminal), so
    /// the agent's next hook takes the terminal back at once.
    pub(super) fn apply_program_status(&mut self, event: &RosterEvent<'_>) -> Vec<RosterDelta> {
        let Some(terminal_id) = event.terminal_id() else { return Vec::new() };
        let Some(state) = event.normalized("state").and_then(agent_state_from_str) else {
            return Vec::new();
        };
        if !reported(state) {
            return Vec::new();
        }
        let observed_at_ms = event
            .normalized_u64("observed_at_ms")
            .unwrap_or(event.committed_at_ms)
            .min(event.committed_at_ms);
        let previous = self.program_status_evidence.insert(
            terminal_id.to_string(),
            ProgramStatusEvidence { state: state.as_str().to_string() },
        );
        let ended_wait = state != AgentState::Blocked
            && previous.is_some_and(|previous| previous.state == AgentState::Blocked.as_str());
        let Some(existing) = self.entries.get(terminal_id) else { return Vec::new() };
        if !ended_wait
            || existing.agent_source() != AgentSource::Hook
            || existing.agent_state() != AgentState::Blocked
            || observed_at_ms <= existing.updated_at_ms
        {
            return Vec::new();
        }
        let entry = RosterEntry {
            state: state.as_str().to_string(),
            source: AgentSource::Detected.as_str().to_string(),
            producer: None,
            producer_generation: None,
            session: None,
            agent: existing.agent.clone(),
            updated_at_ms: observed_at_ms,
            since_ms: Some(observed_at_ms),
        };
        self.entries.insert(terminal_id.to_string(), entry.clone());
        vec![RosterDelta::Upsert { terminal_id: terminal_id.to_string(), entry }]
    }
}

#[cfg(test)]
#[path = "journal_reducers_program_status_tests.rs"]
mod tests;
