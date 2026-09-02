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
/// Version 2 added the agent adapter id to roster entries. Version 3
/// added screen-detected events and hook/screen/socket arbitration. Version 4
/// added ended-session fences and timestamp ordering for socket reports.
pub(crate) const AGENT_ROSTER_REDUCER_VERSION: u32 = 4;

/// The adapter id and native event the socket report path uses for its echo
/// journal events. The echo carries the explicit state in `normalized`, so
/// the fold never has to guess a semantic mapping for it.
pub(crate) const SOCKET_REPORT_ADAPTER: &str = "socket";
pub(crate) const SOCKET_REPORT_NATIVE_EVENT: &str = "StateReport";
pub(crate) const DIRECT_REPORT_ADAPTER: &str = "direct";
pub(crate) const DIRECT_REPORT_NATIVE_EVENT: &str = "DirectReport";

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

    fn native_event(&self) -> Option<&str> {
        self.payload.get("native_event")?.as_str()
    }

    fn normalized(&self, field: &str) -> Option<&str> {
        self.payload.get("normalized")?.get(field)?.as_str()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
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
#[serde(deny_unknown_fields)]
pub(crate) struct AgentRoster {
    pub(crate) entries: HashMap<String, RosterEntry>,
    /// Tombstones for ended hook sessions. The live entry is removed on
    /// `session.ended`, but the session identity remains fenced so delayed
    /// records cannot resurrect it after a restart.
    #[serde(default)]
    pub(crate) ended_hook_sessions: HashMap<String, Option<String>>,
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
        let (state, source, session, agent, updated_at_ms) = if event.adapter_id()
            == Some(SOCKET_REPORT_ADAPTER)
        {
            // Socket echo: explicit state and timestamp carried in the
            // payload, so the roster mirrors the direct projection
            // commit exactly. The reporter does not know the agent type.
            let Some(state) = event.normalized("state").and_then(agent_state_from_str) else {
                return Vec::new();
            };
            // Socket echoes are a trust boundary. Ignore any source label a
            // caller supplied and keep them below hook and screen authority.
            let source = AgentSource::Socket;
            let updated_at_ms = event
                .normalized("updated_at_ms")
                .and_then(|value| value.parse::<u64>().ok())
                .unwrap_or(event.committed_at_ms);
            let session = event.normalized("source_session").map(str::to_string);
            (state, source, session, None, updated_at_ms)
        } else if event.native_event() == Some(DIRECT_REPORT_NATIVE_EVENT) {
            let Some(state) = event.normalized("state").and_then(agent_state_from_str) else {
                return Vec::new();
            };
            let source = event
                .normalized("source")
                .and_then(agent_source_from_str)
                .unwrap_or(AgentSource::Socket);
            let updated_at_ms = event
                .normalized("updated_at_ms")
                .and_then(|value| value.parse::<u64>().ok())
                .unwrap_or(event.committed_at_ms);
            let session = event.normalized("source_session").map(str::to_string);
            (state, source, session, None, updated_at_ms)
        } else if event.native_event() == Some(crate::screen_detect::SCREEN_DETECT_NATIVE_EVENT) {
            // Screen detection: the daemon parsed the terminal tail.
            // Explicit state like the socket echo, but the adapter is
            // the detected agent and the source is `detected`.
            let Some(state) = event.normalized("state").and_then(agent_state_from_str) else {
                return Vec::new();
            };
            let agent = event.adapter_id().map(str::to_string);
            (state, AgentSource::Detected, None, agent, event.committed_at_ms)
        } else {
            let Some(state) = state_for_hook_kind(event.kind) else { return Vec::new() };
            let agent = event.adapter_id().map(str::to_string);
            let session = event.normalized("agent_session_id").map(str::to_string);
            (state, AgentSource::Hook, session, agent, event.committed_at_ms)
        };
        if source == AgentSource::Hook
            && let Some(ended_session) = self.ended_hook_sessions.get(terminal_id)
        {
            // A session-start event opens a new lifecycle. When the adapter
            // has no native session id, the projector's sequence fence is the
            // only available generation proof, so the reducer must allow the
            // new start instead of permanently blocking that terminal.
            let is_new_session = event.kind == "agent.session.started"
                && (session.is_none() || session.as_deref() != ended_session.as_deref());
            if is_new_session {
                self.ended_hook_sessions.remove(terminal_id);
            } else {
                // A delayed event from the ended generation, including a
                // session-less legacy event, cannot reclaim the terminal.
                return Vec::new();
            }
        }
        // Source arbitration: hook > screen > socket per terminal. Hook
        // events always win. Screen detection never overwrites a hook-owned
        // lifecycle because screen evidence cannot prove that the hook
        // session ended. Its exit removal only applies to detected entries.
        // Socket reports lose to both stronger sources.
        if source == AgentSource::Hook
            && let Some(existing) = self.entries.get(terminal_id)
            && existing.agent_source() == AgentSource::Hook
            && match (existing.session.as_deref(), session.as_deref()) {
                (Some(existing), Some(incoming)) => existing != incoming,
                (Some(_), None) => true,
                _ => false,
            }
        {
            // The hook projector fences lifecycle events by session. Apply
            // the same rule in the journal reducer so a delayed event from a
            // previous process cannot remove or overwrite a live session.
            return Vec::new();
        }
        match source {
            AgentSource::Hook => {}
            AgentSource::Detected => {
                if let Some(existing) = self.entries.get(terminal_id) {
                    let existing_source = existing.agent_source();
                    if existing_source == AgentSource::Hook {
                        return Vec::new();
                    }
                    if state == AgentState::Done && existing_source != AgentSource::Detected {
                        return Vec::new();
                    }
                }
            }
            AgentSource::Socket => {
                if let Some(existing) = self.entries.get(terminal_id) {
                    if existing.agent_source() != AgentSource::Socket
                        || updated_at_ms <= existing.updated_at_ms
                    {
                        return Vec::new();
                    }
                }
            }
        }
        if state == AgentState::Done {
            // An ended agent leaves the roster entirely; the done state is
            // still committed to the durable projection by the host so
            // history and remote caches converge.
            let removed = self.entries.remove(terminal_id);
            if source == AgentSource::Hook {
                self.ended_hook_sessions.insert(terminal_id.to_string(), session);
            }
            return removed
                .map(|_| vec![RosterDelta::Remove { terminal_id: terminal_id.to_string() }])
                .unwrap_or_default();
        }
        let entry = RosterEntry {
            state: state.as_str().to_string(),
            source: source.as_str().to_string(),
            session,
            // A socket entry keeps any agent identity a hook already
            // established for this terminal.
            agent: agent
                .or_else(|| self.entries.get(terminal_id).and_then(|entry| entry.agent.clone())),
            updated_at_ms,
        };
        if self.entries.get(terminal_id) == Some(&entry) {
            return Vec::new();
        }
        self.entries.insert(terminal_id.to_string(), entry.clone());
        vec![RosterDelta::Upsert { terminal_id: terminal_id.to_string(), entry }]
    }

    /// Drop a terminal that left the session (tab closed, terminal
    /// tombstoned). Terminal lifecycle does not flow through `agent.*`
    /// events yet, so the host retires entries explicitly.
    pub(crate) fn retire_terminal(&mut self, terminal_id: &str) -> bool {
        let removed_entry = self.entries.remove(terminal_id).is_some();
        let removed_fence = self.ended_hook_sessions.remove(terminal_id).is_some();
        removed_entry || removed_fence
    }

    pub(crate) fn snapshot(&self) -> Value {
        serde_json::to_value(self).unwrap_or(Value::Null)
    }

    pub(crate) fn restore(snapshot: &str) -> Option<Self> {
        let roster: Self = serde_json::from_str(snapshot).ok()?;
        // A syntactically valid snapshot can still be unusable. In
        // particular, an entry with an unknown source/state would make the
        // reducer silently reinterpret persisted data, and a done entry can
        // never be produced by `apply` because done removes the row.
        if roster.entries.iter().any(|(terminal_id, entry)| {
            terminal_id.is_empty()
                || agent_state_from_str(&entry.state).is_none()
                || entry.state == AgentState::Done.as_str()
                || agent_source_from_str(&entry.source).is_none()
                || (entry.source == AgentSource::Detected.as_str()
                    && entry.agent.as_deref().is_none_or(str::is_empty))
        }) {
            return None;
        }
        Some(roster)
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

        let spoofed_socket = json!({
            "adapter": {"id": SOCKET_REPORT_ADAPTER, "version": 1},
            "normalized": {"state": "working", "source": "hook"},
        });
        let mut isolated = AgentRoster::default();
        isolated.apply(&hook_event(4, "agent.state.changed", &subjects, &spoofed_socket));
        assert_eq!(isolated.entries["term_a"].source, "socket");
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

    fn stamped_event<'a>(
        committed_at_ms: u64,
        kind: &'a str,
        subjects: &'a [JournalSubject],
        payload: &'a Value,
    ) -> RosterEvent<'a> {
        RosterEvent {
            producer_id: AGENT_HOOK_PRODUCER_ID,
            kind,
            subjects,
            payload,
            committed_at_ms,
        }
    }

    fn screen_payload(agent: &str, state: &str) -> Value {
        json!({
            "format": "cmux.agent-hook.v1",
            "adapter": {"id": agent, "version": 1},
            "native_event": "ScreenDetect",
            "normalized": {"state": state},
            "native": {},
        })
    }

    #[test]
    fn screen_detect_events_fold_with_detected_source_and_adapter_agent() {
        let subjects = terminal_subject("term_a");
        let payload = screen_payload("codex", "working");
        let mut roster = AgentRoster::default();

        let deltas =
            roster.apply(&stamped_event(5_000, "agent.state.changed", &subjects, &payload));
        assert_eq!(deltas.len(), 1);
        let entry = &roster.entries["term_a"];
        assert_eq!(entry.state, "working");
        assert_eq!(entry.source, "detected");
        assert_eq!(entry.agent.as_deref(), Some("codex"));
        assert_eq!(entry.updated_at_ms, 5_000);
    }

    #[test]
    fn screen_detect_never_overwrites_hook_lifecycle() {
        let subjects = terminal_subject("term_a");
        let hook_payload = json!({"adapter": {"id": "claude", "version": 1}});
        let screen = screen_payload("claude", "blocked");
        let mut roster = AgentRoster::default();

        roster.apply(&stamped_event(10_000, "agent.turn.started", &subjects, &hook_payload));
        // A hook entry is live lifecycle truth.
        let deltas =
            roster.apply(&stamped_event(39_000, "agent.state.changed", &subjects, &screen));
        assert!(deltas.is_empty());
        assert_eq!(roster.entries["term_a"].source, "hook");

        // Even after a long quiet interval, screen evidence cannot prove
        // that the hook session ended, so it cannot take ownership.
        let deltas =
            roster.apply(&stamped_event(40_000, "agent.state.changed", &subjects, &screen));
        assert!(deltas.is_empty());
        assert_eq!(roster.entries["term_a"].source, "hook");

        // A hook event always reclaims the terminal.
        let deltas =
            roster.apply(&stamped_event(41_000, "agent.turn.started", &subjects, &hook_payload));
        assert_eq!(deltas.len(), 1);
        assert_eq!(roster.entries["term_a"].source, "hook");
    }

    #[test]
    fn ended_hook_session_cannot_be_resurrected_by_delayed_events() {
        let subjects = terminal_subject("term_a");
        let session_one = json!({
            "adapter": {"id": "claude", "version": 1},
            "normalized": {"agent_session_id": "session-one"},
        });
        let session_two = json!({
            "adapter": {"id": "claude", "version": 1},
            "normalized": {"agent_session_id": "session-two"},
        });
        let mut roster = AgentRoster::default();

        roster.apply(&stamped_event(1_000, "agent.session.started", &subjects, &session_one));
        roster.apply(&stamped_event(2_000, "agent.session.ended", &subjects, &session_one));
        assert!(roster.entries.is_empty());

        // A delayed event from the ended generation stays fenced even though
        // the live entry was removed.
        let delayed =
            roster.apply(&stamped_event(3_000, "agent.turn.started", &subjects, &session_one));
        assert!(delayed.is_empty());
        assert!(roster.entries.is_empty());

        // A distinct, explicit session start opens a new lifecycle.
        let fresh =
            roster.apply(&stamped_event(4_000, "agent.session.started", &subjects, &session_two));
        assert_eq!(fresh.len(), 1);
        assert_eq!(roster.entries["term_a"].session.as_deref(), Some("session-two"));
        assert!(roster.retire_terminal("term_a"));
        assert!(!roster.ended_hook_sessions.contains_key("term_a"));
    }

    #[test]
    fn socket_reports_ignore_out_of_order_timestamps() {
        let subjects = terminal_subject("term_a");
        let newer = json!({
            "adapter": {"id": SOCKET_REPORT_ADAPTER, "version": 1},
            "native_event": SOCKET_REPORT_NATIVE_EVENT,
            "normalized": {"state": "working", "source": "socket", "updated_at_ms": "200"},
        });
        let older = json!({
            "adapter": {"id": SOCKET_REPORT_ADAPTER, "version": 1},
            "native_event": SOCKET_REPORT_NATIVE_EVENT,
            "normalized": {"state": "idle", "source": "socket", "updated_at_ms": "100"},
        });
        let mut roster = AgentRoster::default();

        roster.apply(&stamped_event(2_000, "agent.state.changed", &subjects, &newer));
        let delayed = roster.apply(&stamped_event(3_000, "agent.state.changed", &subjects, &older));
        assert!(delayed.is_empty());
        assert_eq!(roster.entries["term_a"].state, "working");
        assert_eq!(roster.entries["term_a"].updated_at_ms, 200);
    }

    #[test]
    fn screen_detect_beats_socket_reports_in_both_directions() {
        let subjects = terminal_subject("term_a");
        let socket_payload = json!({
            "adapter": {"id": SOCKET_REPORT_ADAPTER, "version": 1},
            "normalized": {"state": "idle", "source": "socket"},
        });
        let screen = screen_payload("codex", "working");
        let mut roster = AgentRoster::default();

        // Screen detection overwrites a socket-owned entry...
        roster.apply(&stamped_event(1_000, "agent.state.changed", &subjects, &socket_payload));
        let deltas = roster.apply(&stamped_event(2_000, "agent.state.changed", &subjects, &screen));
        assert_eq!(deltas.len(), 1);
        assert_eq!(roster.entries["term_a"].source, "detected");

        // ...and a later socket report cannot downgrade it.
        let deltas =
            roster.apply(&stamped_event(3_000, "agent.state.changed", &subjects, &socket_payload));
        assert!(deltas.is_empty());
        assert_eq!(roster.entries["term_a"].source, "detected");
        assert_eq!(roster.entries["term_a"].state, "working");
    }

    #[test]
    fn screen_detect_exit_removes_only_detected_entries() {
        let subjects = terminal_subject("term_a");
        let done = screen_payload("codex", "done");
        let mut roster = AgentRoster::default();

        // Detected entry: the agent process left the pane -> removal.
        roster.apply(&stamped_event(
            1_000,
            "agent.state.changed",
            &subjects,
            &screen_payload("codex", "working"),
        ));
        let deltas = roster.apply(&stamped_event(2_000, "agent.session.ended", &subjects, &done));
        assert_eq!(deltas, vec![RosterDelta::Remove { terminal_id: "term_a".into() }]);
        assert!(roster.entries.is_empty());

        // A fresh hook entry is never removed by a screen exit.
        let hook_payload = json!({"adapter": {"id": "claude", "version": 1}});
        roster.apply(&stamped_event(10_000, "agent.turn.started", &subjects, &hook_payload));
        let deltas = roster.apply(&stamped_event(11_000, "agent.session.ended", &subjects, &done));
        assert!(deltas.is_empty());
        assert_eq!(roster.entries["term_a"].source, "hook");

        // A socket entry is not removed by a screen exit either.
        let mut socket_roster = AgentRoster::default();
        let socket_payload = json!({
            "adapter": {"id": SOCKET_REPORT_ADAPTER, "version": 1},
            "normalized": {"state": "idle", "source": "socket"},
        });
        socket_roster.apply(&stamped_event(
            1_000,
            "agent.state.changed",
            &subjects,
            &socket_payload,
        ));
        let deltas =
            socket_roster.apply(&stamped_event(2_000, "agent.session.ended", &subjects, &done));
        assert!(deltas.is_empty());
        assert_eq!(socket_roster.entries["term_a"].source, "socket");
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

    #[test]
    fn restore_rejects_semantically_invalid_entries() {
        let invalid_snapshots = [
            // Unknown state and source spellings must not be reinterpreted.
            r#"{"entries":{"term_a":{"state":"running","source":"hook","session":null,"agent":null,"updated_at_ms":1}}}"#,
            r#"{"entries":{"term_a":{"state":"working","source":"poll","session":null,"agent":null,"updated_at_ms":1}}}"#,
            // Done rows are removed during folding and cannot be a live snapshot.
            r#"{"entries":{"term_a":{"state":"done","source":"hook","session":null,"agent":null,"updated_at_ms":1}}}"#,
            // Detected rows must identify the adapter that produced them.
            r#"{"entries":{"term_a":{"state":"working","source":"detected","session":null,"agent":null,"updated_at_ms":1}}}"#,
            // A blank terminal identity cannot be addressed by later events.
            r#"{"entries":{"":{"state":"working","source":"hook","session":null,"agent":null,"updated_at_ms":1}}}"#,
        ];

        for snapshot in invalid_snapshots {
            assert!(AgentRoster::restore(snapshot).is_none(), "snapshot was accepted: {snapshot}");
        }
    }
}
