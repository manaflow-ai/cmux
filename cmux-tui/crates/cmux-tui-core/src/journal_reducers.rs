//! Durable materialized views folded from the session journal.
//!
//! A journal reducer is a pure fold: committed `agent.*` records go in, a
//! deterministic state comes out. The daemon persists each reducer's cursor
//! (the last journal sequence folded) and a snapshot of its state in the
//! registry's `meta` table, so a restart restores the snapshot and re-folds
//! only the journal tail. Bumping a reducer's version discards the snapshot
//! and re-folds from the journal head; state older than the earliest
//! retained journal record is rebuilt lazily by the next events, which is
//! acceptable for live rosters and wrong for ledgers - keep ledger-shaped
//! reducers versioned conservatively.
//!
//! The first reducer is the agent roster: the set of live agents per
//! terminal that agents views render. Every write path is a journal event
//! (hook helpers append `agent.*` events; socket `agent report` appends an
//! echo event after its direct projection commit), so the roster never has
//! a second writer to diverge from.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::agent_hooks::AGENT_HOOK_PRODUCER_ID;
use crate::workspace_registry::SessionJournalRecord;
use crate::{AgentSource, AgentState, JournalSubject};

pub(crate) const AGENT_ROSTER_REDUCER_ID: &str = "agent_roster";
/// Bump to discard persisted snapshots and re-fold from the journal head.
/// Version 2 added the agent adapter id to roster entries.
pub(crate) const AGENT_ROSTER_REDUCER_VERSION: u32 = 2;

/// The adapter id and native event the socket report path uses for its echo
/// journal events. The echo carries the explicit state in `normalized`, so
/// the fold never has to guess a semantic mapping for it.
pub(crate) const SOCKET_REPORT_ADAPTER: &str = "socket";
pub(crate) const SOCKET_REPORT_NATIVE_EVENT: &str = "StateReport";

fn agent_state_from_str(value: &str) -> Option<AgentState> {
    Some(match value {
        "working" => AgentState::Working,
        "blocked" => AgentState::Blocked,
        "idle" => AgentState::Idle,
        "done" => AgentState::Done,
        "unknown" => AgentState::Unknown,
        _ => return None,
    })
}

fn agent_source_from_str(value: &str) -> Option<AgentSource> {
    Some(match value {
        "detected" => AgentSource::Detected,
        "socket" => AgentSource::Socket,
        "hook" => AgentSource::Hook,
        _ => return None,
    })
}

/// The lifecycle state a hook journal kind implies, or `None` for kinds
/// that carry no top-level transition (child agents, unclassified changes).
fn state_for_hook_kind(kind: &str) -> Option<AgentState> {
    Some(match kind {
        // A freshly started session sits at its prompt; a completed turn
        // returns to it.
        "agent.session.started" | "agent.turn.completed" => AgentState::Idle,
        "agent.turn.started" => AgentState::Working,
        "agent.approval.requested"
        | "agent.question.requested"
        | "agent.plan_review.requested"
        | "agent.error.reported" => AgentState::Blocked,
        "agent.session.ended" => AgentState::Done,
        _ => return None,
    })
}

/// One journal record reduced to the fields the roster fold reads. Built
/// from a live `JournalIngress` at commit time and from stored
/// `SessionJournalRecord`s during tail replay, with identical semantics so
/// both paths fold to the same state.
pub(crate) struct RosterEvent<'a> {
    pub(crate) producer_id: &'a str,
    pub(crate) kind: &'a str,
    pub(crate) subjects: &'a [JournalSubject],
    pub(crate) payload: &'a Value,
    pub(crate) committed_at_ms: u64,
}

impl<'a> RosterEvent<'a> {
    pub(crate) fn from_record(record: &'a SessionJournalRecord) -> Self {
        Self {
            producer_id: &record.producer.id,
            kind: &record.kind,
            subjects: &record.subjects,
            payload: &record.payload,
            committed_at_ms: record.committed_at_ms,
        }
    }

    fn terminal_id(&self) -> Option<&str> {
        self.subjects
            .iter()
            .find(|subject| subject.kind == "terminal")
            .map(|subject| subject.id.as_str())
    }

    fn adapter_id(&self) -> Option<&str> {
        self.payload.get("adapter")?.get("id")?.as_str()
    }

    fn normalized(&self, field: &str) -> Option<&str> {
        self.payload.get("normalized")?.get(field)?.as_str()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct RosterEntry {
    pub(crate) state: String,
    pub(crate) source: String,
    pub(crate) session: Option<String>,
    /// The reporting adapter id (`claude`, `codex`, ...). Direct socket
    /// reports do not know the agent behind the terminal, so it is absent
    /// there until a hook event claims the terminal.
    #[serde(default)]
    pub(crate) agent: Option<String>,
    pub(crate) updated_at_ms: u64,
}

impl RosterEntry {
    pub(crate) fn agent_state(&self) -> AgentState {
        agent_state_from_str(&self.state).unwrap_or(AgentState::Unknown)
    }

    pub(crate) fn agent_source(&self) -> AgentSource {
        agent_source_from_str(&self.source).unwrap_or(AgentSource::Hook)
    }
}

/// A roster change produced by folding one record. The host applies these
/// as side effects (projection commits, change broadcasts); the fold itself
/// only mutates roster state.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum RosterDelta {
    Upsert { terminal_id: String, entry: RosterEntry },
    Remove { terminal_id: String },
}

/// Live-agent roster: terminal public id to the agent's last reported
/// lifecycle state. An ended session leaves the roster (history stays in
/// the journal and the durable agent projection); a hook-owned entry
/// ignores socket reports so a slow poller cannot overwrite live hook
/// state.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub(crate) struct AgentRoster {
    pub(crate) entries: HashMap<String, RosterEntry>,
}

impl AgentRoster {
    /// Fold one committed record. Deterministic: identical event sequences
    /// produce identical rosters, so a snapshot plus the journal tail always
    /// reproduces the live state.
    pub(crate) fn apply(&mut self, event: &RosterEvent<'_>) -> Vec<RosterDelta> {
        if event.producer_id != AGENT_HOOK_PRODUCER_ID {
            return Vec::new();
        }
        let Some(terminal_id) = event.terminal_id() else { return Vec::new() };
        let (state, source, session, agent, updated_at_ms) =
            if event.adapter_id() == Some(SOCKET_REPORT_ADAPTER) {
                // Socket echo: explicit state and timestamp carried in the
                // payload, so the roster mirrors the direct projection
                // commit exactly. The reporter does not know the agent type.
                let Some(state) = event.normalized("state").and_then(agent_state_from_str) else {
                    return Vec::new();
                };
                // The socket adapter is authoritative about origin. Do not
                // trust the user-controlled normalized source field, or it
                // could bypass hook-over-socket precedence.
                let source = AgentSource::Socket;
                let updated_at_ms = event
                    .normalized("updated_at_ms")
                    .and_then(|value| value.parse::<u64>().ok())
                    .unwrap_or(event.committed_at_ms);
                let session = event.normalized("source_session").map(str::to_string);
                (state, source, session, None, updated_at_ms)
            } else {
                let Some(state) = state_for_hook_kind(event.kind) else { return Vec::new() };
                let agent = event.adapter_id().map(str::to_string);
                (state, AgentSource::Hook, None, agent, event.committed_at_ms)
            };
        if source == AgentSource::Socket
            && self
                .entries
                .get(terminal_id)
                .is_some_and(|entry| entry.agent_source() == AgentSource::Hook)
        {
            // Hook state is live agent truth; socket reports cannot
            // overwrite it (mirrors the projection commit precedence).
            return Vec::new();
        }
        if state == AgentState::Done {
            // An ended agent leaves the roster entirely; the done state is
            // still committed to the durable projection by the host so
            // history and remote caches converge.
            return if self.entries.remove(terminal_id).is_some() {
                vec![RosterDelta::Remove { terminal_id: terminal_id.to_string() }]
            } else {
                Vec::new()
            };
        }
        let entry = RosterEntry {
            state: state.as_str().to_string(),
            source: source.as_str().to_string(),
            session,
            // A socket entry keeps any agent identity a hook already
            // established for this terminal.
            agent: if source == AgentSource::Socket {
                agent
                    .or_else(|| self.entries.get(terminal_id).and_then(|entry| entry.agent.clone()))
            } else {
                agent
            },
            updated_at_ms,
        };
        if self.entries.get(terminal_id).is_some_and(|existing| {
            existing.state == entry.state
                && existing.source == entry.source
                && existing.session == entry.session
                && existing.agent == entry.agent
                && existing.updated_at_ms == entry.updated_at_ms
        }) {
            return Vec::new();
        }
        self.entries.insert(terminal_id.to_string(), entry.clone());
        vec![RosterDelta::Upsert { terminal_id: terminal_id.to_string(), entry }]
    }

    /// Drop a terminal that left the session (tab closed, terminal
    /// tombstoned). Terminal lifecycle does not flow through `agent.*`
    /// events yet, so the host retires entries explicitly.
    pub(crate) fn retire_terminal(&mut self, terminal_id: &str) -> bool {
        self.entries.remove(terminal_id).is_some()
    }

    pub(crate) fn snapshot(&self) -> Value {
        serde_json::to_value(self).unwrap_or(Value::Null)
    }

    pub(crate) fn restore(snapshot: &str) -> Option<Self> {
        serde_json::from_str(snapshot).ok()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn hook_event<'a>(
        sequence: u64,
        kind: &'a str,
        subjects: &'a [JournalSubject],
        payload: &'a Value,
    ) -> RosterEvent<'a> {
        RosterEvent {
            producer_id: AGENT_HOOK_PRODUCER_ID,
            kind,
            subjects,
            payload,
            committed_at_ms: 1_000 + sequence,
        }
    }

    fn terminal_subject(id: &str) -> Vec<JournalSubject> {
        vec![JournalSubject { kind: "terminal".into(), id: id.into() }]
    }

    #[test]
    fn lifecycle_kinds_fold_into_roster_states() {
        let subjects = terminal_subject("term_a");
        let payload = json!({});
        let mut roster = AgentRoster::default();

        roster.apply(&hook_event(1, "agent.session.started", &subjects, &payload));
        assert_eq!(roster.entries["term_a"].state, "idle");
        assert_eq!(roster.entries["term_a"].agent, None, "payload without adapter has no agent");

        roster.apply(&hook_event(2, "agent.turn.started", &subjects, &payload));
        assert_eq!(roster.entries["term_a"].state, "working");

        roster.apply(&hook_event(3, "agent.approval.requested", &subjects, &payload));
        assert_eq!(roster.entries["term_a"].state, "blocked");

        // Child events carry no top-level transition.
        let deltas = roster.apply(&hook_event(4, "agent.child.spawned", &subjects, &payload));
        assert!(deltas.is_empty());
        assert_eq!(roster.entries["term_a"].state, "blocked");

        let deltas = roster.apply(&hook_event(5, "agent.session.ended", &subjects, &payload));
        assert_eq!(deltas, vec![RosterDelta::Remove { terminal_id: "term_a".into() }]);
        assert!(roster.entries.is_empty());
    }

    #[test]
    fn socket_echo_carries_explicit_state_and_loses_to_hook_entries() {
        let subjects = terminal_subject("term_a");
        let socket_payload = json!({
            "adapter": {"id": SOCKET_REPORT_ADAPTER, "version": 1},
            "normalized": {"state": "working", "source": "socket", "source_session": "probe"},
        });
        let mut roster = AgentRoster::default();

        roster.apply(&hook_event(1, "agent.state.changed", &subjects, &socket_payload));
        let entry = &roster.entries["term_a"];
        assert_eq!(entry.state, "working");
        assert_eq!(entry.source, "socket");
        assert_eq!(entry.session.as_deref(), Some("probe"));
        assert_eq!(entry.agent, None);

        // A hook event takes the terminal over and names the agent...
        let hook_payload = json!({"adapter": {"id": "claude", "version": 1}});
        roster.apply(&hook_event(2, "agent.turn.started", &subjects, &hook_payload));
        assert_eq!(roster.entries["term_a"].source, "hook");
        assert_eq!(roster.entries["term_a"].agent.as_deref(), Some("claude"));

        // ...and later socket reports cannot downgrade it.
        let deltas =
            roster.apply(&hook_event(3, "agent.state.changed", &subjects, &socket_payload));
        assert!(deltas.is_empty());
        assert_eq!(roster.entries["term_a"].source, "hook");
    }

    #[test]
    fn socket_echo_cannot_spoof_hook_source() {
        let subjects = terminal_subject("term_a");
        let hook_payload = json!({"adapter": {"id": "claude", "version": 1}});
        let socket_payload = json!({
            "adapter": {"id": SOCKET_REPORT_ADAPTER, "version": 1},
            "normalized": {"state": "idle", "source": "hook"}
        });
        let mut roster = AgentRoster::default();
        roster.apply(&hook_event(1, "agent.turn.started", &subjects, &hook_payload));
        assert!(
            roster
                .apply(&hook_event(2, "agent.state.changed", &subjects, &socket_payload))
                .is_empty()
        );
        assert_eq!(roster.entries["term_a"].state, "working");
        assert_eq!(roster.entries["term_a"].source, "hook");
    }

    #[test]
    fn folds_are_idempotent_per_state_and_deterministic_across_replays() {
        let subjects = terminal_subject("term_a");
        let payload = json!({});
        let events = [
            "agent.session.started",
            "agent.turn.started",
            "agent.turn.started",
            "agent.turn.completed",
        ];

        let mut live = AgentRoster::default();
        let mut delta_count = 0usize;
        for (index, kind) in events.iter().enumerate() {
            delta_count +=
                live.apply(&hook_event(index as u64 + 1, kind, &subjects, &payload)).len();
        }
        // A same-state re-report still refreshes recency (chronological
        // views sort on it), so every event here produces a delta.
        assert_eq!(delta_count, 4);

        let mut replayed = AgentRoster::default();
        for (index, kind) in events.iter().enumerate() {
            replayed.apply(&hook_event(index as u64 + 1, kind, &subjects, &payload));
        }
        assert_eq!(serde_json::to_value(&live).unwrap(), serde_json::to_value(&replayed).unwrap());
    }

    #[test]
    fn same_state_event_with_new_commit_time_refreshes_roster() {
        let subjects = terminal_subject("term_a");
        let payload = json!({});
        let mut roster = AgentRoster::default();

        roster.apply(&hook_event(1, "agent.turn.started", &subjects, &payload));
        let deltas = roster.apply(&hook_event(2, "agent.turn.started", &subjects, &payload));

        assert_eq!(deltas.len(), 1);
        assert_eq!(roster.entries["term_a"].updated_at_ms, 1_002);
    }

    #[test]
    fn snapshot_round_trips_and_foreign_producers_are_ignored() {
        let subjects = terminal_subject("term_a");
        let payload = json!({});
        let mut roster = AgentRoster::default();
        roster.apply(&hook_event(1, "agent.turn.started", &subjects, &payload));

        let snapshot = roster.snapshot().to_string();
        let restored = AgentRoster::restore(&snapshot).unwrap();
        assert_eq!(restored.entries, roster.entries);

        let foreign = RosterEvent {
            producer_id: "someone_else",
            ..hook_event(2, "agent.session.ended", &subjects, &payload)
        };
        assert!(roster.apply(&foreign).is_empty());
        assert!(!roster.entries.is_empty());
    }
}
