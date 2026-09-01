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

use std::collections::{BTreeMap, HashMap};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::agent_hooks::AGENT_HOOK_PRODUCER_ID;
use crate::workspace_registry::SessionJournalRecord;
use crate::{AgentSource, AgentState, JournalSubject};

pub(crate) const AGENT_ROSTER_REDUCER_ID: &str = "agent_roster";
/// Bump to discard persisted snapshots and re-fold from the journal head.
/// Version 2 added the agent adapter id to roster entries. Version 3 retains
/// ended hook fences after their live roster entries are removed. Version 4
/// added a global authority bit. Version 5 removes that global bit and scopes
/// compatibility cleanup to each terminal's durable removal fence. Version 6
/// retains the last socket semantic receipt after a Done entry is removed.
/// Version 7 makes that receipt source-neutral for socket and detection
/// adapters.
pub(crate) const AGENT_ROSTER_REDUCER_VERSION: u32 = 7;

/// Retirement tombstones protect delayed journal rows after a terminal leaves
/// the resource tree. Keep each exact tombstone while its journal rows may be
/// retained. A future journal-compaction watermark can safely remove older
/// tombstones; count-based eviction would allow delayed rows to resurrect a
/// retired terminal.

/// The adapter id and native event the socket report path uses for its echo
/// journal events. The echo carries the explicit state in `normalized`, so
/// the fold never has to guess a semantic mapping for it.
pub(crate) const SOCKET_REPORT_ADAPTER: &str = "socket";
pub(crate) const SOCKET_REPORT_NATIVE_EVENT: &str = "StateReport";
/// Screen-detection reports use the same durable state-change envelope. Keep
/// a distinct adapter id so the reducer preserves their lower authority.
pub(crate) const DETECTED_REPORT_ADAPTER: &str = "detected";
pub(crate) const DETECTED_REPORT_NATIVE_EVENT: &str = "StateReport";

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
    /// Monotonic journal sequence. Synthetic test events may use zero;
    /// persisted records always carry their committed sequence.
    pub(crate) sequence: u64,
    pub(crate) producer_id: &'a str,
    pub(crate) kind: &'a str,
    pub(crate) subjects: &'a [JournalSubject],
    pub(crate) payload: &'a Value,
    pub(crate) committed_at_ms: u64,
}

impl<'a> RosterEvent<'a> {
    pub(crate) fn from_record(record: &'a SessionJournalRecord) -> Self {
        Self {
            sequence: record.sequence,
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
struct RosterFence {
    session_id: String,
    sequence: u64,
    ended: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct ExternalReportReceipt {
    source: String,
    state: String,
    session: Option<String>,
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
        // Unknown persisted values are untrusted. Treat them as detected
        // state so they never gain hook authority over a socket report.
        agent_source_from_str(&self.source).unwrap_or(AgentSource::Detected)
    }
}

/// A roster change produced by folding one record. The host applies these
/// as side effects (projection commits, change broadcasts); the fold itself
/// only mutates roster state.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum RosterDelta {
    Upsert {
        terminal_id: String,
        entry: RosterEntry,
    },
    /// Remove only the lifecycle represented by `entry`. A fold may lag a
    /// newer direct projection, so the host must not delete that newer record
    /// just because the terminal id matches.
    Remove {
        terminal_id: String,
        entry: RosterEntry,
    },
}

/// Live-agent roster: terminal public id to the agent's last reported
/// lifecycle state. An ended session leaves the roster (history stays in
/// the journal and the durable agent projection); a hook-owned entry
/// ignores socket reports so a slow poller cannot overwrite live hook
/// state.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub(crate) struct AgentRoster {
    pub(crate) entries: HashMap<String, RosterEntry>,
    /// Hook generation watermarks remain after an ended session leaves the
    /// live roster. Socket echoes cannot recreate an ended entry, and delayed
    /// events from an old named session cannot cross into a newer lifecycle.
    #[serde(default)]
    hook_fences: HashMap<String, RosterFence>,
    /// Terminals removed from the resource tree remain fenced in the durable
    /// reducer. The value is the highest committed journal cursor observed at
    /// retirement, so delayed records from that terminal cannot recreate it.
    #[serde(default)]
    retired_terminals: BTreeMap<String, u64>,
    /// The last accepted external state remains after a Done report removes
    /// the live roster entry. This receipt is bounded by terminal lifecycle,
    /// and lets repeated polls reuse the same semantic transition instead of
    /// appending another journal row on every poll. It covers socket and
    /// screen-detection adapters.
    #[serde(default)]
    external_receipts: HashMap<String, ExternalReportReceipt>,
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
        let socket_echo = event.adapter_id() == Some(SOCKET_REPORT_ADAPTER);
        let detected_echo = event.adapter_id() == Some(DETECTED_REPORT_ADAPTER);
        let external_echo = socket_echo || detected_echo;
        if let Some(retired_at) = self.retired_terminals.get(terminal_id).copied() {
            // A terminal retirement fences records through the committed
            // cursor that caused it. A strictly newer hook session start is a
            // new lifecycle, so clear only that terminal's fence and let the
            // normal session-generation checks below run. All older rows,
            // non-start rows, and external echoes remain suppressed.
            if external_echo
                || event.kind != "agent.session.started"
                || event.sequence <= retired_at
            {
                return Vec::new();
            }
            self.retired_terminals.remove(terminal_id);
        }
        let (state, source, session, agent, updated_at_ms) = if external_echo {
            // Socket echo: explicit state and timestamp carried in the
            // payload, so the roster mirrors the direct projection
            // commit exactly. The reporter does not know the agent type.
            let Some(state) = event.normalized("state").and_then(agent_state_from_str) else {
                return Vec::new();
            };
            // The socket adapter is authoritative about origin. Do not
            // trust the user-controlled normalized source field, or it
            // could bypass hook-over-socket precedence.
            let source = if socket_echo { AgentSource::Socket } else { AgentSource::Detected };
            let updated_at_ms = event
                .normalized("updated_at_ms")
                .and_then(|value| value.parse::<u64>().ok())
                .unwrap_or(event.committed_at_ms);
            let session = event.normalized("source_session").map(str::to_string);
            if self
                .external_receipts
                .get(terminal_id)
                .is_some_and(|receipt| receipt.state == AgentState::Done.as_str())
            {
                // An external Done closes that source session. A later
                // report must prove a distinct non-empty session before it
                // can start a new lifecycle on the same terminal.
                let fresh_session = session.as_deref().is_some_and(|session| {
                    !session.is_empty()
                        && self
                            .external_receipts
                            .get(terminal_id)
                            .and_then(|receipt| receipt.session.as_deref())
                            != Some(session)
                });
                if !fresh_session {
                    return Vec::new();
                }
            }
            if self.hook_fences.get(terminal_id).is_some_and(|fence| {
                fence.ended
                    && event
                        .normalized("source_session")
                        .is_none_or(|session| session.is_empty() || session == fence.session_id)
            }) {
                return Vec::new();
            }
            (state, source, session, None, updated_at_ms)
        } else {
            let Some(state) = state_for_hook_kind(event.kind) else { return Vec::new() };
            let agent = event.adapter_id().map(str::to_string);
            let explicit_session = event
                .normalized("agent_session_id")
                .filter(|session| !session.is_empty())
                .map(str::to_owned);
            let is_session_start = event.kind == "agent.session.started";
            let previous_fence = self.hook_fences.get(terminal_id).cloned();
            // Once an adapter supplies a native identity, a later
            // session-less event is ambiguous and cannot attach to that
            // generation.
            if explicit_session.is_none()
                && previous_fence
                    .as_ref()
                    .is_some_and(|fence| !fence.session_id.starts_with("legacy:"))
            {
                return Vec::new();
            }
            let public_session = explicit_session.clone();
            let session_id = explicit_session
                .or_else(|| {
                    (!is_session_start)
                        .then(|| previous_fence.as_ref().filter(|fence| !fence.ended))
                        .flatten()
                        .map(|fence| fence.session_id.clone())
                })
                .unwrap_or_else(|| format!("legacy:{terminal_id}:{}", event.sequence));
            if let Some(fence) = previous_fence.as_ref() {
                if fence.session_id == session_id {
                    // A provider may reuse its native session id. A newer
                    // explicit session start reopens that lifecycle, while
                    // all other ended-fence records remain rejected.
                    if (fence.ended && !is_session_start) || event.sequence <= fence.sequence {
                        return Vec::new();
                    }
                } else if !is_session_start || !fence.ended || event.sequence <= fence.sequence {
                    return Vec::new();
                }
            }
            self.hook_fences.insert(
                terminal_id.to_string(),
                RosterFence {
                    session_id: session_id.clone(),
                    sequence: event.sequence,
                    ended: state == AgentState::Done,
                },
            );
            // A hook event claims this terminal's lifecycle. Any socket
            // receipt from the previous lifecycle must not suppress a later
            // socket transition after the hook state is gone.
            self.external_receipts.remove(terminal_id);
            (state, AgentSource::Hook, public_session, agent, event.committed_at_ms)
        };
        if source != AgentSource::Hook
            && self.entries.get(terminal_id).is_some_and(|entry| {
                entry.agent_source() == AgentSource::Hook
                    || (entry.agent_source() == AgentSource::Socket
                        && source == AgentSource::Detected)
            })
        {
            // Hook state is live agent truth. A structured socket report also
            // outranks the screen detector, so neither lower-authority source
            // can replace a stronger live projection.
            return Vec::new();
        }
        let external_receipt_changed = if source != AgentSource::Hook {
            let receipt = ExternalReportReceipt {
                source: source.as_str().to_string(),
                state: state.as_str().to_string(),
                session: session.clone(),
            };
            let changed = self.external_receipts.get(terminal_id) != Some(&receipt);
            if changed {
                self.external_receipts.insert(terminal_id.to_string(), receipt);
            }
            changed
        } else {
            false
        };
        if state == AgentState::Done && source != AgentSource::Hook && !external_receipt_changed {
            // A repeated external Done is already represented by its durable
            // receipt. Do not emit another removal delta.
            return Vec::new();
        }
        if state == AgentState::Done {
            // An ended agent leaves the roster entirely; the done state is
            // still committed to the durable projection by the host so
            // history and remote caches converge.
            let removed = self.entries.remove(terminal_id);
            return if removed.is_some() || source == AgentSource::Hook || external_receipt_changed {
                vec![RosterDelta::Remove {
                    terminal_id: terminal_id.to_string(),
                    entry: RosterEntry {
                        state: state.as_str().to_string(),
                        source: source.as_str().to_string(),
                        session,
                        agent,
                        updated_at_ms,
                    },
                }]
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
    pub(crate) fn retire_terminal(&mut self, terminal_id: &str, retired_at: u64) -> bool {
        let removed_entry = self.entries.remove(terminal_id).is_some();
        let removed_external_receipt = self.external_receipts.remove(terminal_id).is_some();
        // A retired terminal is no longer allowed to receive socket echoes,
        // and its ended hook fence is redundant with the retirement cursor.
        let removed_fence = self.hook_fences.remove(terminal_id).is_some();
        let retired_changed = match self.retired_terminals.entry(terminal_id.to_string()) {
            std::collections::btree_map::Entry::Occupied(mut entry) => {
                let previous = *entry.get();
                let effective = previous.max(retired_at);
                entry.insert(effective);
                removed_entry || effective != previous
            }
            std::collections::btree_map::Entry::Vacant(entry) => {
                entry.insert(retired_at);
                true
            }
        };
        removed_entry || removed_fence || removed_external_receipt || retired_changed
    }

    /// Remove retirement fences whose source records are covered by a sealed
    /// checkpoint. Segment sealing is checkpoint-aligned, so no reducer replay
    /// can revisit a record at or below this watermark after compaction.
    pub(crate) fn compact_retired_terminals(&mut self, through_sequence: u64) -> bool {
        let before = self.retired_terminals.len();
        self.retired_terminals.retain(|_, retired_at| *retired_at > through_sequence);
        self.retired_terminals.len() != before
    }

    pub(crate) fn is_retired(&self, terminal_id: &str) -> bool {
        self.retired_terminals.contains_key(terminal_id)
    }

    /// Return true when this terminal has a durable roster decision that
    /// removes its compatibility record. The decision is terminal-local, so
    /// an event for one terminal cannot discard a different terminal's record.
    pub(crate) fn has_terminal_removal_fence(&self, terminal_id: &str) -> bool {
        self.retired_terminals.contains_key(terminal_id)
            || self.hook_fences.get(terminal_id).is_some_and(|fence| fence.ended)
            || self
                .external_receipts
                .get(terminal_id)
                .is_some_and(|receipt| receipt.state == AgentState::Done.as_str())
    }

    /// Return every terminal represented by durable roster state. Startup
    /// reconciliation uses this list to remove fences whose terminal resource
    /// is confirmed gone, while preserving rows whose host mapping is still
    /// being rebuilt.
    pub(crate) fn fenced_terminal_ids(&self) -> Vec<String> {
        let mut ids = Vec::with_capacity(
            self.entries.len()
                + self.hook_fences.len()
                + self.retired_terminals.len()
                + self.external_receipts.len(),
        );
        ids.extend(self.entries.keys().cloned());
        ids.extend(self.hook_fences.keys().cloned());
        ids.extend(self.retired_terminals.keys().cloned());
        ids.extend(self.external_receipts.keys().cloned());
        ids.sort_unstable();
        ids.dedup();
        ids
    }

    pub(crate) fn has_ended_hook_fence(&self, terminal_id: &str) -> bool {
        self.hook_fences.get(terminal_id).is_some_and(|fence| fence.ended)
    }

    pub(crate) fn ended_hook_session(&self, terminal_id: &str) -> Option<&str> {
        self.hook_fences
            .get(terminal_id)
            .filter(|fence| fence.ended)
            .map(|fence| fence.session_id.as_str())
    }

    /// Return the last accepted external state for idempotency checks. The
    /// receipt survives live-entry removal, but only semantic fields are
    /// retained because report timestamps are intentionally non-semantic.
    pub(crate) fn last_external_report(
        &self,
        terminal_id: &str,
    ) -> Option<(&str, &str, Option<&str>)> {
        self.external_receipts.get(terminal_id).map(|receipt| {
            (receipt.source.as_str(), receipt.state.as_str(), receipt.session.as_deref())
        })
    }

    pub(crate) fn ended_external_session(&self, terminal_id: &str) -> Option<&str> {
        self.external_receipts
            .get(terminal_id)
            .filter(|receipt| receipt.state == AgentState::Done.as_str())
            .and_then(|receipt| receipt.session.as_deref())
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
            sequence,
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
        assert_eq!(
            deltas,
            vec![RosterDelta::Remove {
                terminal_id: "term_a".into(),
                entry: RosterEntry {
                    state: "done".into(),
                    source: "hook".into(),
                    session: None,
                    agent: None,
                    updated_at_ms: 1_005,
                },
            }]
        );
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
    fn detected_echo_keeps_detected_authority() {
        let subjects = terminal_subject("term_a");
        let payload = json!({
            "adapter": {"id": DETECTED_REPORT_ADAPTER, "version": 1},
            "normalized": {
                "state": "working",
                "source": "detected",
                "source_session": "screen-1"
            }
        });
        let mut roster = AgentRoster::default();
        let deltas = roster.apply(&hook_event(1, "agent.state.changed", &subjects, &payload));
        assert_eq!(deltas.len(), 1);
        assert_eq!(roster.entries["term_a"].agent_source(), AgentSource::Detected);
        assert_eq!(roster.entries["term_a"].session.as_deref(), Some("screen-1"));
    }

    #[test]
    fn detected_echo_cannot_replace_socket_authority() {
        let subjects = terminal_subject("term_a");
        let socket = json!({
            "adapter": {"id": SOCKET_REPORT_ADAPTER, "version": 1},
            "normalized": {
                "state": "working",
                "source": "socket",
                "source_session": "socket-1"
            }
        });
        let detected = json!({
            "adapter": {"id": DETECTED_REPORT_ADAPTER, "version": 1},
            "normalized": {
                "state": "blocked",
                "source": "detected",
                "source_session": "screen-1"
            }
        });
        let mut roster = AgentRoster::default();
        assert_eq!(
            roster.apply(&hook_event(1, "agent.state.changed", &subjects, &socket)).len(),
            1
        );
        assert!(
            roster.apply(&hook_event(2, "agent.state.changed", &subjects, &detected)).is_empty()
        );
        assert_eq!(roster.entries["term_a"].agent_source(), AgentSource::Socket);
        assert_eq!(roster.entries["term_a"].state, AgentState::Working.as_str());
    }

    #[test]
    fn external_done_fence_survives_restart_and_requires_a_new_session() {
        let subjects = terminal_subject("term_a");
        let done = json!({
            "adapter": {"id": DETECTED_REPORT_ADAPTER, "version": 1},
            "normalized": {
                "state": "done",
                "source": "detected",
                "source_session": "screen-1"
            }
        });
        let mut roster = AgentRoster::default();

        assert_eq!(
            roster.apply(&hook_event(1, "agent.state.changed", &subjects, &done)),
            vec![RosterDelta::Remove {
                terminal_id: "term_a".into(),
                entry: RosterEntry {
                    state: "done".into(),
                    source: "detected".into(),
                    session: Some("screen-1".into()),
                    agent: None,
                    updated_at_ms: 1_001,
                },
            }]
        );
        assert!(roster.entries.is_empty());
        assert!(roster.has_terminal_removal_fence("term_a"));

        let mut restored = AgentRoster::restore(&roster.snapshot().to_string()).unwrap();
        assert!(restored.apply(&hook_event(2, "agent.state.changed", &subjects, &done)).is_empty());

        let mut stale_working = done.clone();
        stale_working["normalized"]["state"] = json!("working");
        assert!(
            restored
                .apply(&hook_event(3, "agent.state.changed", &subjects, &stale_working))
                .is_empty()
        );

        let mut fresh_working = stale_working;
        fresh_working["normalized"]["source_session"] = json!("screen-2");
        let deltas =
            restored.apply(&hook_event(4, "agent.state.changed", &subjects, &fresh_working));
        assert_eq!(deltas.len(), 1);
        assert!(matches!(
            &deltas[0],
            RosterDelta::Upsert { terminal_id, entry }
                if terminal_id == "term_a"
                    && entry.session.as_deref() == Some("screen-2")
                    && entry.state == "working"
        ));
        assert_eq!(restored.entries["term_a"].session.as_deref(), Some("screen-2"));
    }

    #[test]
    fn ended_hook_fence_rejects_late_socket_but_allows_a_new_session() {
        let subjects = terminal_subject("term_a");
        let old_hook_payload = json!({
            "adapter": {"id": "claude", "version": 1},
            "normalized": {"agent_session_id": "old-hook-session"}
        });
        let new_hook_payload = json!({
            "adapter": {"id": "claude", "version": 1},
            "normalized": {"agent_session_id": "new-hook-session"}
        });
        let socket_payload = json!({
            "adapter": {"id": SOCKET_REPORT_ADAPTER, "version": 1},
            "normalized": {
                "state": "working",
                "source": "socket",
                "source_session": "fresh-socket-session"
            }
        });
        let mut roster = AgentRoster::default();

        roster.apply(&hook_event(1, "agent.session.started", &subjects, &old_hook_payload));
        roster.apply(&hook_event(5, "agent.session.ended", &subjects, &old_hook_payload));
        assert!(roster.has_ended_hook_fence("term_a"));
        let deltas =
            roster.apply(&hook_event(6, "agent.state.changed", &subjects, &socket_payload));
        assert_eq!(deltas.len(), 1);
        assert_eq!(roster.entries["term_a"].session.as_deref(), Some("fresh-socket-session"));
        assert!(roster.has_ended_hook_fence("term_a"));
        let mut late_payload = socket_payload.clone();
        late_payload["normalized"]["source_session"] = json!("old-hook-session");
        assert!(
            roster
                .apply(&hook_event(7, "agent.state.changed", &subjects, &late_payload))
                .is_empty()
        );
        late_payload["normalized"]["source_session"] = Value::Null;
        assert!(
            roster
                .apply(&hook_event(8, "agent.state.changed", &subjects, &late_payload))
                .is_empty()
        );

        let mut restored = AgentRoster::restore(&roster.snapshot().to_string()).unwrap();
        assert!(restored.has_ended_hook_fence("term_a"));
        let deltas =
            restored.apply(&hook_event(7, "agent.state.changed", &subjects, &socket_payload));
        assert!(deltas.is_empty(), "identical external state is coalesced");
        assert_eq!(restored.entries["term_a"].session.as_deref(), Some("fresh-socket-session"));
        assert!(
            restored
                .apply(&hook_event(5, "agent.session.started", &subjects, &new_hook_payload))
                .is_empty()
        );
        assert!(restored.has_ended_hook_fence("term_a"));

        let deltas =
            restored.apply(&hook_event(6, "agent.session.started", &subjects, &new_hook_payload));
        assert_eq!(deltas.len(), 1);
        assert!(!restored.has_ended_hook_fence("term_a"));
        assert!(
            restored
                .apply(&hook_event(7, "agent.turn.started", &subjects, &old_hook_payload))
                .is_empty()
        );
        assert_eq!(restored.entries["term_a"].state, "idle");
    }

    #[test]
    fn newer_hook_session_start_can_reopen_when_provider_reuses_session_id() {
        let subjects = terminal_subject("term_a");
        let payload = json!({
            "adapter": {"id": "claude", "version": 1},
            "normalized": {"agent_session_id": "reused-session"}
        });
        let mut roster = AgentRoster::default();

        roster.apply(&hook_event(1, "agent.session.started", &subjects, &payload));
        roster.apply(&hook_event(2, "agent.session.ended", &subjects, &payload));
        let deltas = roster.apply(&hook_event(3, "agent.session.started", &subjects, &payload));

        assert_eq!(deltas.len(), 1, "a newer start reopens a reused provider session id");
        assert_eq!(roster.entries["term_a"].state, "idle");
        assert!(!roster.has_ended_hook_fence("term_a"));
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

    #[test]
    fn unknown_snapshot_source_fails_closed_without_hook_authority() {
        let entry = RosterEntry {
            state: "working".into(),
            source: "future-source".into(),
            session: Some("future-session".into()),
            agent: Some("future-agent".into()),
            updated_at_ms: 1,
        };
        assert_eq!(entry.agent_source(), AgentSource::Detected);

        let subjects = terminal_subject("term_a");
        let socket_payload = json!({
            "adapter": {"id": SOCKET_REPORT_ADAPTER, "version": 1},
            "normalized": {"state": "idle", "source_session": "socket"}
        });
        let mut roster = AgentRoster {
            entries: HashMap::from([(String::from("term_a"), entry)]),
            ..AgentRoster::default()
        };
        let deltas =
            roster.apply(&hook_event(2, "agent.state.changed", &subjects, &socket_payload));
        assert_eq!(deltas.len(), 1, "socket state must be allowed to replace an unknown source");
        assert_eq!(roster.entries["term_a"].source, "socket");
    }

    #[test]
    fn retired_terminal_rejects_late_events_but_allows_a_newer_session_start() {
        let subjects = terminal_subject("term_a");
        let payload = json!({});
        let mut roster = AgentRoster::default();

        roster.apply(&hook_event(1, "agent.session.started", &subjects, &payload));
        assert!(roster.retire_terminal("term_a", 1));

        // Events from the retired terminal cannot recreate a live entry,
        // including events committed after the retirement cursor.
        assert!(roster.apply(&hook_event(2, "agent.turn.started", &subjects, &payload)).is_empty());
        assert!(!roster.entries.contains_key("term_a"));

        // A session start at or before the retirement cursor is still stale.
        assert!(
            roster.apply(&hook_event(1, "agent.session.started", &subjects, &payload)).is_empty()
        );
        let new_session_payload = json!({
            "adapter": {"id": "claude", "version": 1},
            "normalized": {"agent_session_id": "new-session"}
        });
        let deltas =
            roster.apply(&hook_event(2, "agent.session.started", &subjects, &new_session_payload));
        assert_eq!(deltas.len(), 1);
        assert_eq!(roster.entries["term_a"].session.as_deref(), Some("new-session"));
        assert!(!roster.is_retired("term_a"));

        // Session-less rows from the old lifecycle cannot cross into the
        // reopened native session.
        assert!(roster.apply(&hook_event(3, "agent.turn.started", &subjects, &payload)).is_empty());
    }

    #[test]
    fn retired_terminal_reopens_for_a_newer_session_start_but_suppresses_old_session_events() {
        let subjects = terminal_subject("term_a");
        let old_payload = json!({
            "adapter": {"id": "claude", "version": 1},
            "normalized": {"agent_session_id": "old-session"}
        });
        let new_payload = json!({
            "adapter": {"id": "claude", "version": 1},
            "normalized": {"agent_session_id": "new-session"}
        });
        let mut roster = AgentRoster::default();

        roster.apply(&hook_event(1, "agent.session.started", &subjects, &old_payload));
        assert!(roster.retire_terminal("term_a", 2));

        // A delayed row from the retired lifecycle remains fenced.
        assert!(
            roster.apply(&hook_event(2, "agent.turn.started", &subjects, &old_payload)).is_empty()
        );

        // A strictly newer session start is a new lifecycle on the same
        // terminal, so it must clear the retirement fence and reappear.
        let deltas = roster.apply(&hook_event(3, "agent.session.started", &subjects, &new_payload));
        assert_eq!(deltas.len(), 1);
        assert!(!roster.is_retired("term_a"));
        assert_eq!(roster.entries["term_a"].session.as_deref(), Some("new-session"));

        // Events from the old provider session cannot cross into the reopened
        // lifecycle even after the terminal is live again.
        assert!(
            roster.apply(&hook_event(4, "agent.turn.started", &subjects, &old_payload)).is_empty()
        );
        assert_eq!(roster.entries["term_a"].state, "idle");
    }

    #[test]
    fn invalid_newer_session_start_does_not_clear_retirement_tombstone() {
        let subjects = terminal_subject("term_a");
        let active_payload = json!({
            "adapter": {"id": "claude", "version": 1},
            "normalized": {"agent_session_id": "active-session"}
        });
        let new_payload = json!({
            "adapter": {"id": "claude", "version": 1},
            "normalized": {"agent_session_id": "new-session"}
        });
        let mut roster = AgentRoster::default();
        roster.apply(&hook_event(1, "agent.session.started", &subjects, &active_payload));

        // A stale snapshot can contain both fences while it is being
        // reconciled. The live hook generation makes this newer start
        // invalid because it attempts to replace an active session.
        roster.retired_terminals.insert("term_a".into(), 2);
        roster.hook_fences.insert(
            "term_a".into(),
            RosterFence { session_id: "active-session".into(), sequence: 3, ended: false },
        );

        assert!(
            roster
                .apply(&hook_event(4, "agent.session.started", &subjects, &new_payload))
                .is_empty()
        );
        assert!(roster.is_retired("term_a"));
        assert_eq!(roster.entries["term_a"].session.as_deref(), Some("active-session"));
    }

    #[test]
    fn retirement_cursor_only_moves_forward() {
        let subjects = terminal_subject("term_a");
        let payload = json!({});
        let mut roster = AgentRoster::default();

        roster.apply(&hook_event(1, "agent.session.started", &subjects, &payload));
        assert!(roster.retire_terminal("term_a", 9));
        assert!(!roster.retire_terminal("term_a", 4));

        assert!(roster.apply(&hook_event(8, "agent.turn.started", &subjects, &payload)).is_empty());
        assert!(
            roster.apply(&hook_event(10, "agent.turn.started", &subjects, &payload)).is_empty()
        );
        let deltas = roster.apply(&hook_event(10, "agent.session.started", &subjects, &payload));
        assert_eq!(deltas.len(), 1);
        assert!(!roster.is_retired("term_a"));
    }

    #[test]
    fn terminal_fences_are_retained_until_journal_compaction() {
        const RETIRED_TERMINAL_COUNT: usize = 2_048;
        let payload = json!({});
        let mut live = AgentRoster::default();
        for sequence in 1..=RETIRED_TERMINAL_COUNT * 2 {
            let subjects = terminal_subject("long_lived");
            live.apply(&hook_event(
                sequence as u64,
                if sequence % 2 == 0 { "agent.session.started" } else { "agent.turn.started" },
                &subjects,
                &payload,
            ));
        }
        assert_eq!(live.hook_fences.len(), 1);

        let mut retired = AgentRoster::default();
        for index in 0..RETIRED_TERMINAL_COUNT {
            let terminal_id = format!("retired_{index}");
            let subjects = terminal_subject(&terminal_id);
            let sequence = index as u64 * 2 + 1;
            retired.apply(&hook_event(sequence, "agent.turn.started", &subjects, &payload));
            retired.apply(&hook_event(sequence + 1, "agent.session.ended", &subjects, &payload));
            retired.retire_terminal(&terminal_id, sequence);
        }
        assert!(retired.hook_fences.is_empty());
        // A delayed journal row can arrive at any time while its sequence is
        // retained. Keep every exact tombstone until a journal-compaction
        // watermark exists; count-based eviction permits resurrection.
        assert_eq!(retired.retired_terminals.len(), RETIRED_TERMINAL_COUNT);
        assert_eq!(retired.retired_terminals.get("retired_0"), Some(&1));
        assert_eq!(retired.retired_terminals.get("retired_2047"), Some(&4_095));

        // Once the journal is checkpointed and sealed through sequence 2_047,
        // the first half of these records is covered by the checkpoint and
        // no longer needs an in-memory delayed-row fence.
        assert!(retired.compact_retired_terminals(2_047));
        assert_eq!(retired.retired_terminals.len(), RETIRED_TERMINAL_COUNT / 2);
        assert!(!retired.retired_terminals.contains_key("retired_1023"));
        assert_eq!(retired.retired_terminals.get("retired_1024"), Some(&2_049));
        assert!(!retired.compact_retired_terminals(2_047));
    }
}
