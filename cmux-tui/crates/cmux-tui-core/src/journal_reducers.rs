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

use std::cmp::Ordering;
use std::collections::HashMap;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::agent_hooks::AGENT_HOOK_PRODUCER_ID;
use crate::workspace_registry::SessionJournalRecord;
use crate::{AgentSource, AgentState, JournalSubject};

pub(crate) const AGENT_ROSTER_REDUCER_ID: &str = "agent_roster";
/// Bump to discard persisted snapshots and re-fold from the journal head.
/// Version 2 added the agent adapter id to roster entries. Version 3
/// added screen-detected events and hook/screen/socket arbitration. Version 5
/// adds durable plugin-exit fences so late observations cannot resurrect rows.
/// Version 6 folds hook events through the same per-terminal session fence as
/// the hook projector, so a late event from an ended or superseded session
/// cannot change a later session's roster state. The bump re-folds from the
/// journal head so fences exist for every retained lifecycle. Version 7 keeps
/// each terminal's last screen observation, so a hook `blocked` row clears
/// when the screen shows its dialog gone; the re-fold clears rows that stayed
/// blocked after a dialog was dismissed with Esc. Version 8 ties that record
/// to the plugin child that saw it, so a restarted plugin cannot clear a block.
/// Version 9 lets the screen end a hook `working` row whose turn ended with no
/// hook (Esc, a lost `Stop`) and end a hook session whose agent exited; the
/// re-fold clears rows that stayed working after either.
pub(crate) const AGENT_ROSTER_REDUCER_VERSION: u32 = 9;
/// The oldest roster version whose snapshot [`AgentRoster::migrate`] takes.
/// Version 6 added the hook session fences: a snapshot without them would
/// let a late event from an ended session bring its row back while the
/// rebuild runs.
const AGENT_ROSTER_MIGRATES_FROM: u32 = 6;
/// Stable envelope used by userland agent plugins. The producer id is the
/// plugin identity; the payload id must match it before the event is folded.
pub(crate) const AGENT_PLUGIN_FORMAT: &str = "cmux.agent-plugin.v1";
/// Legacy native event retained so journals written by the old in-core
/// detector can still be replayed after the detector moves to userland. New
/// detector processes must use the generic plugin event envelope instead.
pub(crate) const LEGACY_SCREEN_DETECT_NATIVE_EVENT: &str = "ScreenDetect";

/// A hook-owned roster entry younger than this cannot be overwritten by a
/// screen-detected state: live hooks are stronger evidence than screen
/// scraping. An agent whose hooks stopped reporting for this long (dead
/// helper, uninstalled hooks) falls back to screen detection.
pub(crate) const STALE_HOOK_MS: u64 = 30_000;

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
        "plugin" => AgentSource::Plugin,
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

/// The roster state a hook journal event moves its terminal to, given the state the roster holds
/// for it now (`current`); `None` when the event leaves it as it is. A question, an approval or an
/// error blocks the agent (`state_for_hook_kind`) until the turn ends. A tool call that completes
/// after the person answered (`PostToolUse`, or its failure) resumes a blocked agent instead:
/// the agent runs on in its turn, so it is working, not waiting on the person.
pub(crate) fn hook_roster_state(
    kind: &str,
    native_event: &str,
    current: Option<AgentState>,
) -> Option<AgentState> {
    if crate::agent_hooks::is_tool_completion(native_event)
        && matches!(kind, "agent.state.changed" | "agent.error.reported")
    {
        return (current == Some(AgentState::Blocked)).then_some(AgentState::Working);
    }
    state_for_hook_kind(kind)
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
    /// Journal sequence. Hook session fences order lifecycles by it.
    pub(crate) sequence: u64,
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

    fn native_event(&self) -> Option<&str> {
        self.payload.get("native_event")?.as_str()
    }

    fn normalized(&self, field: &str) -> Option<&str> {
        self.payload.get("normalized")?.get(field)?.as_str()
    }

    fn normalized_u64(&self, field: &str) -> Option<u64> {
        let value = self.payload.get("normalized")?.get(field)?;
        value.as_str().and_then(|value| value.parse::<u64>().ok()).or_else(|| value.as_u64())
    }

    /// A plugin can report when it observed a terminal, but it cannot make
    /// that evidence newer than the host commit that admitted it. Keeping
    /// older timestamps preserves the delayed-append fence, while clamping a
    /// future timestamp prevents a buggy or hostile plugin from outranking a
    /// live hook indefinitely.
    fn plugin_observed_at_ms(&self) -> Option<u64> {
        self.normalized_u64("observed_at_ms").map(|observed| observed.min(self.committed_at_ms))
    }

    fn plugin_event(&self) -> bool {
        if self.producer_id == AGENT_HOOK_PRODUCER_ID
            || !valid_component(self.producer_id)
            || self.payload.get("format").and_then(Value::as_str) != Some(AGENT_PLUGIN_FORMAT)
        {
            return false;
        }
        let Some(plugin) = self.payload.get("plugin") else { return false };
        let Some(plugin_id) = plugin.get("id").and_then(Value::as_str) else { return false };
        let Some(plugin_version) = plugin.get("version").and_then(Value::as_u64) else {
            return false;
        };
        if plugin_id != self.producer_id
            || plugin_version == 0
            || plugin_version > u64::from(u32::MAX)
        {
            return false;
        }
        let Some(adapter) = self.payload.get("adapter") else { return false };
        let Some(adapter_id) = adapter.get("id").and_then(Value::as_str) else { return false };
        let Some(adapter_version) = adapter.get("version").and_then(Value::as_u64) else {
            return false;
        };
        if !valid_component(adapter_id) || adapter_version == 0 {
            return false;
        }
        let Some(event_name) = self.payload.get("event").and_then(Value::as_str) else {
            return false;
        };
        if event_name != "state.changed" && event_name != "session.ended" {
            return false;
        }
        let expected_kind = format!("plugin.{}.agent.{}", self.producer_id, event_name);
        if self.kind != expected_kind {
            return false;
        }
        let Some(normalized) = self.payload.get("normalized") else { return false };
        let Some(state) = normalized.get("state").and_then(Value::as_str) else { return false };
        if agent_state_from_str(state).is_none() {
            return false;
        }
        let Some(source_session) = normalized.get("source_session").and_then(Value::as_str) else {
            return false;
        };
        if source_session.is_empty() || source_session.len() > 256 || source_session.contains('\0')
        {
            return false;
        }
        let Some(observed_at_ms) = normalized.get("observed_at_ms") else { return false };
        if decimal_u64(observed_at_ms).is_none() {
            return false;
        }
        if let Some(generation) = normalized.get("plugin_generation")
            && decimal_string_u64(generation).is_none()
        {
            return false;
        }
        true
    }

    fn plugin_event_name(&self) -> Option<&str> {
        if !self.plugin_event() {
            return None;
        }
        self.payload.get("event")?.as_str()
    }
}

fn valid_component(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 64
        && value.bytes().all(|byte| {
            byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_' || byte == b'-'
        })
        && value.as_bytes().first().is_some_and(|byte| byte.is_ascii_alphanumeric())
}

fn decimal_u64(value: &Value) -> Option<u64> {
    value
        .as_str()
        .and_then(|text| {
            (!text.is_empty() && text.bytes().all(|byte| byte.is_ascii_digit())).then_some(text)
        })
        .and_then(|text| text.parse::<u64>().ok())
        .or_else(|| value.as_u64())
}

/// Generation tags are part of the public plugin envelope and must stay
/// strings. Keeping one wire type avoids a number/string fork in replay and
/// prevents a producer from changing the identity representation between
/// emissions.
fn decimal_string_u64(value: &Value) -> Option<u64> {
    let text = value.as_str()?;
    (!text.is_empty() && text.bytes().all(|byte| byte.is_ascii_digit()))
        .then_some(text)
        .and_then(|text| text.parse::<u64>().ok())
}

/// Compare evidence owned by the same userland producer. A supervisor
/// generation is a restart fence, so a newer generation wins even when its
/// wall-clock observation is older than the previous process' last report.
fn plugin_event_order(
    existing: &RosterEntry,
    producer: &str,
    generation: Option<&str>,
    updated_at_ms: u64,
) -> Ordering {
    if existing.producer.as_deref() != Some(producer) {
        return updated_at_ms.cmp(&existing.updated_at_ms);
    }
    match (
        generation.and_then(|value| value.parse::<u64>().ok()),
        existing.producer_generation.as_deref().and_then(|value| value.parse::<u64>().ok()),
    ) {
        (Some(incoming), Some(current)) => match incoming.cmp(&current) {
            Ordering::Equal => updated_at_ms.cmp(&existing.updated_at_ms),
            ordering => ordering,
        },
        (Some(_), None) => Ordering::Greater,
        (None, Some(_)) => Ordering::Less,
        (None, None) => updated_at_ms.cmp(&existing.updated_at_ms),
    }
}

fn source_rank(source: AgentSource) -> u8 {
    match source {
        AgentSource::Socket => 0,
        AgentSource::Detected => 1,
        AgentSource::Plugin => 2,
        AgentSource::Hook => 3,
    }
}

/// Return true only when an incoming timestamp is current or newer. Using a
/// signed comparison avoids `saturating_sub`, which treats an older event as
/// fresh after clock skew or journal replay.
fn timestamp_is_current(existing: u64, incoming: u64) -> bool {
    incoming >= existing
}

fn fresh_hook(existing: u64, incoming: u64) -> bool {
    timestamp_is_current(existing, incoming) && incoming - existing < STALE_HOOK_MS
}

/// Session-less adapters get a local generation token. The journal sequence
/// is durable and strictly increasing, so a new legacy lifecycle cannot reuse
/// the previous fence identity after restart.
pub(crate) fn legacy_hook_session_id(terminal_id: &str, sequence: u64) -> String {
    format!("legacy:{terminal_id}:{sequence}")
}

/// When the hook helper observed a hook event (`normalized.observed_at_ms`,
/// a decimal string stamped at invocation). Journal order says when an event
/// arrived; this says when the agent emitted it, which is the only evidence
/// that separates a late event of an ended incarnation from an event of a
/// resumed incarnation that reuses the same session id. Events from older
/// helpers and direct reports carry no stamp.
pub(crate) fn hook_observed_at_ms(payload: &Value) -> Option<u64> {
    let value = payload.get("normalized")?.get("observed_at_ms")?;
    decimal_string_u64(value)
}

/// Per-terminal hook session fence: the agent session that owns the
/// terminal's hook state, the last journal sequence applied for it, whether
/// that session ended, and when its latest incarnation ended. The hook
/// projector (public agent rows) and the roster reducer (`list_agents`, the
/// TUI, raw `agents`) both decide hook events with
/// [`HookFence::journal_transition`] and build the next fence with
/// [`HookFence::next`], so the two views accept and reject exactly the same
/// events when they fold the journal in order.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct HookFence {
    pub(crate) session_id: String,
    pub(crate) sequence: u64,
    pub(crate) ended: bool,
    /// Observed time of the latest end of `session_id` on this terminal. It
    /// is the incarnation boundary: an event of this session observed at or
    /// before it belongs to an ended incarnation, and one observed after it
    /// resumes the id as a new incarnation. It survives the
    /// resume and resets when another session takes the terminal.
    #[serde(default)]
    pub(crate) ended_at_ms: Option<u64>,
}

pub(crate) enum JournalHookTransition {
    Ignore,
    Apply(String),
}

/// Outcome of a direct (socket/SDK) hook-source report against a fence.
pub(crate) enum DirectHookTransition {
    Continue,
    /// A fresh session id follows an ended session: the fence restarts on it
    /// and keeps its applied sequence.
    Restart(String),
}

/// Why a direct hook-source report was rejected by the fence.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum DirectHookRejection {
    SessionEnded,
    SessionConflict,
}

impl DirectHookRejection {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::SessionEnded => "agent_session_ended",
            Self::SessionConflict => "agent_session_conflict",
        }
    }
}

impl HookFence {
    /// Decide one journal hook event. `explicit_session_id` is the adapter's
    /// native session id; a session-less event continues the live legacy
    /// generation or starts a new one keyed by its sequence.
    /// `observed_at_ms` is [`hook_observed_at_ms`] of the event.
    pub(crate) fn journal_transition(
        current: Option<&Self>,
        terminal_id: &str,
        explicit_session_id: Option<&str>,
        is_session_start: bool,
        sequence: u64,
        observed_at_ms: Option<u64>,
    ) -> JournalHookTransition {
        if current.is_some_and(|fence| sequence <= fence.sequence) {
            return JournalHookTransition::Ignore;
        }
        Self::session_transition(
            current,
            terminal_id,
            explicit_session_id,
            is_session_start,
            sequence,
            observed_at_ms,
        )
    }

    /// Session ownership without lifecycle ordering. A child's completion may project
    /// after a later parent Stop; its caller supplies the session-boundary sequence fence.
    pub(crate) fn session_transition(
        current: Option<&Self>,
        terminal_id: &str,
        explicit_session_id: Option<&str>,
        is_session_start: bool,
        sequence: u64,
        observed_at_ms: Option<u64>,
    ) -> JournalHookTransition {
        if explicit_session_id.is_none()
            && current.is_some_and(|fence| !fence.session_id.starts_with("legacy:"))
        {
            return JournalHookTransition::Ignore;
        }
        let session_id = explicit_session_id
            .map(str::to_owned)
            .or_else(|| {
                (!is_session_start)
                    .then(|| current.filter(|fence| !fence.ended))
                    .flatten()
                    .map(|fence| fence.session_id.clone())
            })
            .unwrap_or_else(|| legacy_hook_session_id(terminal_id, sequence));
        let Some(fence) = current else { return JournalHookTransition::Apply(session_id) };
        // Compare the event's observation with the fence's incarnation
        // boundary. Unknown on either side proves nothing.
        let after_end =
            observed_at_ms.zip(fence.ended_at_ms).map(|(observed, ended)| observed > ended);
        let observed_before_end = after_end == Some(false);
        let observed_after_end = after_end == Some(true);
        let accepted = if fence.session_id == session_id {
            if fence.ended {
                // A start resumes an ended id (`claude --resume`), but not
                // one observed before that end: that start belongs to the
                // ended incarnation. So does any event observed after the
                // end: a session the screen saw leave the foreground
                // (Ctrl+Z) comes back with `fg` and no start, and an agent
                // that really ended emits nothing after its end.
                observed_after_end || (is_session_start && !observed_before_end)
            } else {
                // A live resumed incarnation rejects events its ended
                // predecessor emitted before it ended.
                !observed_before_end
            }
        } else if fence.ended {
            // After a session ends, a start takes the terminal. So does an
            // event with a native session id observed after that end: its
            // session started without a start event reaching this fence, for
            // example after a direct hook report restarted the projector.
            is_session_start || (explicit_session_id.is_some() && observed_after_end)
        } else {
            false
        };
        if accepted {
            JournalHookTransition::Apply(session_id)
        } else {
            JournalHookTransition::Ignore
        }
    }

    /// The fence after applying an event of `session_id` at `sequence`. The
    /// incarnation boundary carries over while the session keeps the
    /// terminal, moves to the observed end when the event ends it, and resets
    /// when another session takes the terminal.
    pub(crate) fn next(
        current: Option<&Self>,
        session_id: String,
        sequence: u64,
        ended: bool,
        observed_at_ms: Option<u64>,
    ) -> Self {
        let carried = current
            .filter(|fence| fence.session_id == session_id)
            .and_then(|fence| fence.ended_at_ms);
        let ended_at_ms = if ended { observed_at_ms.or(carried) } else { carried };
        Self { session_id, sequence, ended, ended_at_ms }
    }

    /// Decide one direct hook-source report. Internal hook markers are not
    /// session identities.
    pub(crate) fn direct_transition(
        &self,
        session_id: Option<&str>,
    ) -> Result<DirectHookTransition, DirectHookRejection> {
        let session_id = session_id.filter(|session_id| {
            !session_id.is_empty()
                && !session_id.starts_with("cmux-hook-sequence:")
                && !session_id.starts_with("cmux-hook-ended:")
        });
        if self.ended {
            let Some(session_id) = session_id.filter(|session_id| *session_id != self.session_id)
            else {
                return Err(DirectHookRejection::SessionEnded);
            };
            return Ok(DirectHookTransition::Restart(session_id.to_owned()));
        }
        if session_id != Some(self.session_id.as_str()) {
            return Err(DirectHookRejection::SessionConflict);
        }
        Ok(DirectHookTransition::Continue)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct RosterEntry {
    pub(crate) state: String,
    pub(crate) source: String,
    /// Producer identity for plugin-owned entries. This prevents one
    /// plugin's exit event from removing another plugin's observation.
    #[serde(default)]
    pub(crate) producer: Option<String>,
    /// Supervisor child generation, when the plugin supplied it. This is a
    /// stronger restart fence than wall-clock timestamps.
    #[serde(default)]
    pub(crate) producer_generation: Option<String>,
    pub(crate) session: Option<String>,
    /// The reporting adapter id (`claude`, `codex`, ...). Direct socket
    /// reports do not know the agent behind the terminal, so it is absent
    /// there until a hook event claims the terminal.
    #[serde(default)]
    pub(crate) agent: Option<String>,
    pub(crate) updated_at_ms: u64,
    /// When the terminal's agent entered `state` (the journal's clock, like
    /// `updated_at_ms`): a report that keeps the state, source and session
    /// keeps it. Absent from entries written before it: `updated_at_ms`.
    #[serde(default)]
    pub(crate) since_ms: Option<u64>,
}

/// Restart fences retained after a plugin child exits. A tagged observation
/// proves its process generation. An untagged observation cannot prove that a
/// replacement exists, so it stays fenced after the first untagged exit.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
struct PluginExitFence {
    #[serde(default)]
    highest_tagged_generation: Option<u64>,
    #[serde(default)]
    untagged_exit_at_ms: Option<u64>,
}

impl RosterEntry {
    /// When the agent entered its state; `updated_at_ms` for an older entry.
    pub(crate) fn since_ms(&self) -> u64 {
        self.since_ms.unwrap_or(self.updated_at_ms)
    }

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
    Upsert {
        terminal_id: String,
        entry: RosterEntry,
    },
    Remove {
        terminal_id: String,
        source: AgentSource,
    },
    /// The screen proved a hook session's agent gone with no `SessionEnd`
    /// (the plugin's exit at journal `sequence`, observed at
    /// `observed_at_ms`): the roster ended `session_id`'s fence and dropped
    /// its row, and the hook projector ends its fence and row the same way.
    EndHookSession {
        terminal_id: String,
        session_id: String,
        sequence: u64,
        observed_at_ms: u64,
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
    /// Durable producer fences. The map is keyed by validated plugin id and
    /// grows only when a configured producer is observed by the journal.
    #[serde(default)]
    plugin_exit_fences: HashMap<String, PluginExitFence>,
    /// Hook session fences keyed by terminal public id. They decide hook
    /// events and hook-source socket echoes exactly as the hook projector
    /// does, so a late event from an ended or superseded session cannot
    /// change a later session's roster state.
    #[serde(default)]
    hook_fences: HashMap<String, HookFence>,
    /// The last plugin screen observation per terminal public id
    /// ([`ScreenEvidence`]).
    #[serde(default)]
    screen_evidence: HashMap<String, ScreenEvidence>,
    /// The last program status edge per terminal ([`ProgramStatusEvidence`]).
    #[serde(default)]
    program_status_evidence: HashMap<String, ProgramStatusEvidence>,
    /// When a hook last started a turn on each terminal (`agent.turn.started`,
    /// its commit time). A prompt submitted while the row is already `working`
    /// keeps the row's `since_ms`, so only this fences the screen's evidence of
    /// a turn running to the turn now open ([`Self::screen_ends_hook_row`]).
    #[serde(default)]
    hook_turn_started_at: HashMap<String, HookTurnStart>,
}

impl AgentRoster {
    /// The journal kinds [`Self::apply`] can act on. Its replays read only
    /// these (`session_journal_kinds_after`), so a replay costs the agent
    /// records, not the journal's other history. Every other kind is a no-op:
    ///
    /// - `apply` folds a record of the agent hook producer or a valid plugin
    ///   event, and drops the rest first.
    /// - A plugin event's kind must be `plugin.<producer>.agent.state.changed`
    ///   or `plugin.<producer>.agent.session.ended` ([`RosterEvent::plugin_event`]).
    /// - The hook producer appends through journal ingress, which refuses a
    ///   kind its manifest does not declare; it declares only `agent.*` kinds
    ///   (`AGENT_EVENT_KINDS`). That covers the plugin exit, program status,
    ///   socket echo and legacy screen-detect events, which are all hook
    ///   producer events.
    /// - A record of another writer whose producer id happens to be the hook
    ///   producer's (an admin, checkpoint, retention or resource record, named
    ///   by its origin) has no `agent.*` kind and none of the hook envelope's
    ///   `adapter` and `native_event` fields, so every branch of `apply`
    ///   returns before it changes anything: the hook branch needs a kind
    ///   [`hook_roster_state`] maps, which are `agent.*` kinds.
    ///
    /// `mux/tests/agent_roster_kind_scope.rs` checks this on a mixed stream.
    pub(crate) fn folds_kind(kind: &str) -> bool {
        kind.starts_with("agent.")
            || (kind.starts_with("plugin.")
                && (kind.ends_with(".agent.state.changed")
                    || kind.ends_with(".agent.session.ended")))
    }

    /// Fold one committed record. Deterministic: identical event sequences
    /// produce identical rosters, so a snapshot plus the journal tail always
    /// reproduces the live state.
    pub(crate) fn apply(&mut self, event: &RosterEvent<'_>) -> Vec<RosterDelta> {
        if event.producer_id != AGENT_HOOK_PRODUCER_ID && !event.plugin_event() {
            return Vec::new();
        }
        if event.producer_id == AGENT_HOOK_PRODUCER_ID
            && event.native_event() == Some(crate::agent_hooks::JOURNAL_PLUGIN_EXIT_NATIVE_EVENT)
        {
            let Some(plugin_id) = event.normalized("plugin_id") else { return Vec::new() };
            if !valid_component(plugin_id) {
                return Vec::new();
            }
            let cutoff = event
                .normalized_u64("observed_at_ms")
                .unwrap_or(event.committed_at_ms)
                .min(event.committed_at_ms);
            let generation = event.normalized("plugin_generation");
            let generation_number = generation.and_then(|value| value.parse::<u64>().ok());
            if generation.is_some() && generation_number.is_none() {
                return Vec::new();
            }
            self.record_plugin_exit_fence(plugin_id, generation_number, cutoff);
            self.forget_screen_evidence_of(plugin_id, generation_number);
            let retired = self
                .entries
                .iter()
                .filter(|(_, entry)| {
                    entry.agent_source() == AgentSource::Plugin
                        && entry.producer.as_deref() == Some(plugin_id)
                        && match generation_number {
                            // A tagged generation is a unique child identity,
                            // so remove every row from it even if its wall
                            // clock is ahead of the supervisor's cutoff.
                            Some(generation) => {
                                entry
                                    .producer_generation
                                    .as_deref()
                                    .and_then(|value| value.parse::<u64>().ok())
                                    == Some(generation)
                            }
                            // An untagged exit can only retire an untagged
                            // row. It must never clear a replacement child
                            // whose generation is known.
                            None => entry.producer_generation.is_none(),
                        }
                        && (generation_number.is_some() || entry.updated_at_ms <= cutoff)
                })
                .map(|(terminal_id, _)| terminal_id.clone())
                .collect::<Vec<_>>();
            return retired
                .into_iter()
                .filter_map(|terminal_id| {
                    self.entries.remove(&terminal_id)?;
                    Some(RosterDelta::Remove { terminal_id, source: AgentSource::Plugin })
                })
                .collect();
        }
        if event.is_program_status_evidence() {
            return self.apply_program_status(event);
        }
        if event.plugin_event()
            && self.plugin_observation_is_fenced(
                event.producer_id,
                event.normalized("plugin_generation"),
            )
        {
            return Vec::new();
        }
        let Some(terminal_id) = event.terminal_id() else { return Vec::new() };
        // The screen proves that no dialog is up any more ([`Self::screen_clears_hook_blocker`]).
        let mut screen_cleared_blocker = false;
        // What the screen proves about a turn's end or an exit ([`Self::screen_ends_hook_row`]).
        let mut screen_note = ScreenNote::default();
        let (state, source, producer, producer_generation, session, agent, updated_at_ms) = if event
            .plugin_event()
        {
            let Some(event_name) = event.plugin_event_name() else { return Vec::new() };
            let Some(state) = event.normalized("state").and_then(agent_state_from_str) else {
                return Vec::new();
            };
            if event_name != "state.changed" && event_name != "session.ended" {
                return Vec::new();
            }
            let updated_at_ms = event.plugin_observed_at_ms().unwrap_or(event.committed_at_ms);
            let generation =
                event.normalized("plugin_generation").and_then(|value| value.parse::<u64>().ok());
            let producer_generation = generation.map(|value| value.to_string());
            let session = event.normalized("source_session").map(str::to_string);
            let agent = event.adapter_id().map(str::to_string);
            let state = if event_name == "session.ended" { AgentState::Done } else { state };
            let visible_idle = event.plugin_visible_idle();
            screen_note = self.note_screen_evidence(
                terminal_id,
                event.producer_id,
                generation,
                session.as_deref(),
                state,
                visible_idle,
                updated_at_ms,
            );
            screen_cleared_blocker =
                screen_note.cleared_blocker || (state == AgentState::Idle && visible_idle);
            (
                state,
                AgentSource::Plugin,
                Some(event.producer_id.to_string()),
                producer_generation,
                session,
                agent,
                updated_at_ms,
            )
        } else if event.adapter_id() == Some(SOCKET_REPORT_ADAPTER) {
            // Socket echo: explicit state and timestamp carried in the
            // payload, so the roster mirrors the direct projection
            // commit exactly. The reporter does not know the agent type.
            let Some(state) = event.normalized("state").and_then(agent_state_from_str) else {
                return Vec::new();
            };
            let source = event
                .normalized("source")
                .and_then(agent_source_from_str)
                .unwrap_or(AgentSource::Socket);
            let updated_at_ms =
                event.normalized_u64("updated_at_ms").unwrap_or(event.committed_at_ms);
            let session = event.normalized("source_session").map(str::to_string);
            // A hook-source echo records a direct hook report the
            // projector already accepted. Apply the projector's direct
            // fence rule: a fresh session restarts an ended fence, and an
            // echo for another session (a restated record) is ignored.
            if source == AgentSource::Hook
                && let Some(fence) = self.hook_fences.get(terminal_id)
            {
                match fence.direct_transition(session.as_deref()) {
                    Err(_) => return Vec::new(),
                    Ok(DirectHookTransition::Continue) => {}
                    Ok(DirectHookTransition::Restart(session_id)) => {
                        let restarted =
                            HookFence::next(Some(fence), session_id, fence.sequence, false, None);
                        self.hook_fences.insert(terminal_id.to_string(), restarted);
                    }
                }
            }
            (state, source, None, None, session, None, updated_at_ms)
        } else if event.native_event() == Some(LEGACY_SCREEN_DETECT_NATIVE_EVENT) {
            // Screen detection: the daemon parsed the terminal tail.
            // Explicit state like the socket echo, but the adapter is
            // the detected agent and the source is `detected`.
            let Some(state) = event.normalized("state").and_then(agent_state_from_str) else {
                return Vec::new();
            };
            let agent = event.adapter_id().map(str::to_string);
            (state, AgentSource::Detected, None, None, None, agent, event.committed_at_ms)
        } else {
            let current =
                self.entries.get(terminal_id).and_then(|entry| agent_state_from_str(&entry.state));
            let native_event = event.native_event().unwrap_or_default();
            let Some(state) = hook_roster_state(event.kind, native_event, current) else {
                return Vec::new();
            };
            // The session fence shared with the hook projector decides
            // whether this event belongs to the terminal's current
            // session. It advances even when timestamp arbitration below
            // keeps the existing entry, exactly like the projector.
            let explicit_session_id =
                event.normalized("agent_session_id").filter(|session_id| !session_id.is_empty());
            let observed_at_ms = hook_observed_at_ms(event.payload);
            let current = self.hook_fences.get(terminal_id);
            let JournalHookTransition::Apply(session_id) = HookFence::journal_transition(
                current,
                terminal_id,
                explicit_session_id,
                event.kind == "agent.session.started",
                event.sequence,
                observed_at_ms,
            ) else {
                return Vec::new();
            };
            let next = HookFence::next(
                current,
                session_id,
                event.sequence,
                state == AgentState::Done,
                observed_at_ms,
            );
            // Another agent session took the terminal, an ended one came
            // back, or a new process started (`claude --resume` reuses the
            // id): what the screen saw belongs to the agent before it, so a
            // late exit of that process cannot remove this row
            // ([`Self::screen_ends_hook_row`]). Claude Code's `SessionStart`
            // for a compaction or `/clear` runs in the same process and keeps it.
            let new_process = event.kind == "agent.session.started"
                && !matches!(
                    event.payload.pointer("/native/source").and_then(Value::as_str),
                    Some("compact" | "clear")
                );
            if new_process
                || current.is_none_or(|fence| fence.ended || fence.session_id != next.session_id)
            {
                self.screen_evidence.remove(terminal_id);
            }
            self.hook_fences.insert(terminal_id.to_string(), next);
            if event.kind == "agent.turn.started" {
                let start = HookTurnStart {
                    at_ms: event.committed_at_ms,
                    screen_working_since_ms: self
                        .screen_evidence
                        .get(terminal_id)
                        .and_then(ScreenEvidence::working_since_ms),
                };
                self.hook_turn_started_at.insert(terminal_id.to_string(), start);
            }
            let agent = event.adapter_id().map(str::to_string);
            (state, AgentSource::Hook, None, None, None, agent, event.committed_at_ms)
        };
        // Source arbitration: hook > screen > socket per terminal. Hook
        // events always win. Screen detection may not overwrite an entry a
        // live hook owns (fresher than STALE_HOOK_MS), and its exit removal
        // only applies to entries screen detection itself established.
        // Socket reports lose to both stronger sources.
        // The screen ends a hook row no hook will end (Esc, a lost `Stop`, a
        // killed harness): it wins over the fresh hook, and its exit removes it.
        let mut screen_ended_hook_row = false;
        match source {
            AgentSource::Hook => {
                if let Some(existing) = self.entries.get(terminal_id)
                    && existing.agent_source() == AgentSource::Hook
                    && !timestamp_is_current(existing.updated_at_ms, updated_at_ms)
                {
                    return Vec::new();
                }
            }
            AgentSource::Plugin => {
                if let Some(existing) = self.entries.get(terminal_id) {
                    let existing_source = existing.agent_source();
                    // The dialog a hook announced is gone from the screen,
                    // and no hook will say so: the screen's state wins.
                    let dialog_gone = existing_source == AgentSource::Hook
                        && Self::screen_clears_hook_blocker(
                            existing,
                            screen_cleared_blocker,
                            state,
                            updated_at_ms,
                        );
                    screen_ended_hook_row = existing_source == AgentSource::Hook
                        && Self::screen_ends_hook_row(
                            existing,
                            self.hook_turn_started_at.get(terminal_id),
                            screen_note,
                            state,
                            updated_at_ms,
                        );
                    if existing_source == AgentSource::Hook
                        && !dialog_gone
                        && !screen_ended_hook_row
                    {
                        // The producer observation is the evidence clock. A
                        // delayed append must not turn an old screen read
                        // into fresh evidence just because the journal
                        // accepted it later. The journal commit time orders
                        // transport, while `observed_at_ms` orders what the
                        // plugin actually saw.
                        if fresh_hook(existing.updated_at_ms, updated_at_ms) {
                            return Vec::new();
                        }
                        // An older plugin observation cannot reclaim a hook
                        // row merely because the hook is stale. The next
                        // current observation can do so.
                        if updated_at_ms < existing.updated_at_ms {
                            return Vec::new();
                        }
                    }
                    if source_rank(existing_source) == source_rank(source)
                        && plugin_event_order(
                            existing,
                            producer.as_deref().unwrap_or_default(),
                            producer_generation.as_deref(),
                            updated_at_ms,
                        ) == Ordering::Less
                    {
                        return Vec::new();
                    }
                }
            }
            AgentSource::Detected => {
                if let Some(existing) = self.entries.get(terminal_id) {
                    let existing_source = existing.agent_source();
                    // A stale hook may be reclaimed by screen evidence. Keep
                    // the generic precedence fence for plugin observations,
                    // which are stronger than this legacy detected source,
                    // while preserving the documented hook staleness rule.
                    if existing_source != AgentSource::Hook
                        && source_rank(existing_source) > source_rank(source)
                    {
                        return Vec::new();
                    }
                    if existing_source == AgentSource::Hook
                        && fresh_hook(existing.updated_at_ms, updated_at_ms)
                    {
                        return Vec::new();
                    }
                    if existing_source == AgentSource::Hook
                        && updated_at_ms < existing.updated_at_ms
                    {
                        return Vec::new();
                    }
                    if existing_source == AgentSource::Detected
                        && !timestamp_is_current(existing.updated_at_ms, updated_at_ms)
                    {
                        return Vec::new();
                    }
                    if state == AgentState::Done && existing_source != AgentSource::Detected {
                        return Vec::new();
                    }
                }
            }
            AgentSource::Socket => {
                if let Some(existing) = self.entries.get(terminal_id)
                    && (existing.agent_source() != AgentSource::Socket
                        || !timestamp_is_current(existing.updated_at_ms, updated_at_ms))
                {
                    return Vec::new();
                }
            }
        }
        if state == AgentState::Done {
            // An ended agent leaves the roster entirely; the done state is
            // still committed to the durable projection by the host so
            // history and remote caches converge.
            let owned_by_event = self.entries.get(terminal_id).is_some_and(|entry| {
                entry.agent_source() == source
                    && (source != AgentSource::Plugin
                        || (entry.producer.as_deref() == producer.as_deref()
                            && match (
                                entry.producer_generation.as_deref(),
                                producer_generation.as_deref(),
                            ) {
                                (Some(existing), Some(incoming)) => {
                                    if existing == incoming {
                                        true
                                    } else {
                                        incoming
                                            .parse::<u64>()
                                            .ok()
                                            .zip(existing.parse::<u64>().ok())
                                            .is_some_and(|(incoming, existing)| incoming > existing)
                                    }
                                }
                                (None, None) => true,
                                _ => false,
                            }))
            });
            // The screen proved the hook session's agent gone from the
            // foreground, which no `SessionEnd` will say (a killed harness,
            // or one suspended with Ctrl+Z): its session ends here, at the
            // exit's observation, so another session's hooks take the
            // terminal, this session's resume only when observed after the
            // exit (`fg`), and a late hook from before the exit is refused.
            // The hook projector ends its own fence the same way
            // ([`RosterDelta::EndHookSession`]).
            if screen_ended_hook_row
                && let Some(fence) =
                    self.hook_fences.get(terminal_id).filter(|fence| !fence.ended).cloned()
            {
                let session_id = fence.session_id.clone();
                self.hook_fences.insert(
                    terminal_id.to_string(),
                    HookFence::next(
                        Some(&fence),
                        session_id.clone(),
                        event.sequence.max(fence.sequence),
                        true,
                        Some(updated_at_ms),
                    ),
                );
                self.entries.remove(terminal_id);
                return vec![RosterDelta::EndHookSession {
                    terminal_id: terminal_id.to_string(),
                    session_id,
                    sequence: event.sequence,
                    observed_at_ms: updated_at_ms,
                }];
            }
            return if owned_by_event || screen_ended_hook_row {
                self.entries.remove(terminal_id);
                vec![RosterDelta::Remove { terminal_id: terminal_id.to_string(), source }]
            } else {
                Vec::new()
            };
        }
        let since_ms = self
            .entries
            .get(terminal_id)
            .filter(|previous| {
                previous.state == state.as_str()
                    && previous.source == source.as_str()
                    && previous.session == session
            })
            .map_or(updated_at_ms, RosterEntry::since_ms);
        let entry = RosterEntry {
            state: state.as_str().to_string(),
            source: source.as_str().to_string(),
            producer,
            producer_generation,
            session,
            // A socket entry keeps any agent identity a hook already
            // established for this terminal.
            agent: agent
                .or_else(|| self.entries.get(terminal_id).and_then(|entry| entry.agent.clone())),
            updated_at_ms,
            since_ms: Some(since_ms),
        };
        if self.entries.get(terminal_id) == Some(&entry) {
            return Vec::new();
        }
        self.entries.insert(terminal_id.to_string(), entry.clone());
        vec![RosterDelta::Upsert { terminal_id: terminal_id.to_string(), entry }]
    }

    /// Each terminal's hook session id (ended or not) and the harness its
    /// roster entry names, from the journal: a restarted daemon shows the
    /// session a resume needs again (W5-R).
    pub(crate) fn hook_sessions(&self) -> Vec<(String, String, Option<String>)> {
        self.hook_fences
            .iter()
            .map(|(terminal, fence)| {
                let agent = self.entries.get(terminal).and_then(|entry| entry.agent.clone());
                (terminal.clone(), fence.session_id.clone(), agent)
            })
            .collect()
    }

    /// Drop a terminal that left the session (tab closed, terminal
    /// tombstoned). Terminal lifecycle does not flow through `agent.*`
    /// events yet, so the host retires entries explicitly.
    pub(crate) fn retire_terminal(&mut self, terminal_id: &str) -> bool {
        let entry = self.entries.remove(terminal_id).is_some();
        let fence = self.hook_fences.remove(terminal_id).is_some();
        let evidence = self.screen_evidence.remove(terminal_id).is_some();
        let program = self.program_status_evidence.remove(terminal_id).is_some();
        let turn = self.hook_turn_started_at.remove(terminal_id).is_some();
        entry || fence || evidence || program || turn
    }

    fn record_plugin_exit_fence(
        &mut self,
        plugin_id: &str,
        generation: Option<u64>,
        cutoff_ms: u64,
    ) {
        let fence = self.plugin_exit_fences.entry(plugin_id.to_string()).or_default();
        match generation {
            Some(generation) => {
                if fence.highest_tagged_generation.is_none_or(|current| generation > current) {
                    fence.highest_tagged_generation = Some(generation);
                }
            }
            None => {
                if fence.highest_tagged_generation.is_none() {
                    fence.untagged_exit_at_ms =
                        Some(fence.untagged_exit_at_ms.unwrap_or_default().max(cutoff_ms));
                }
            }
        }
    }

    fn plugin_observation_is_fenced(&self, plugin_id: &str, generation: Option<&str>) -> bool {
        let Some(fence) = self.plugin_exit_fences.get(plugin_id) else { return false };
        match generation.and_then(|value| value.parse::<u64>().ok()) {
            Some(generation) => {
                fence.highest_tagged_generation.is_some_and(|highest| generation <= highest)
            }
            // An untagged event cannot prove that it belongs to a child that
            // started after any observed exit. Once a tagged child has also
            // exited, reject it for the same reason.
            None => {
                fence.highest_tagged_generation.is_some() || fence.untagged_exit_at_ms.is_some()
            }
        }
    }

    pub(crate) fn snapshot(&self) -> Value {
        serde_json::to_value(self).unwrap_or(Value::Null)
    }

    /// The roster of a snapshot an older reducer version (`from_version`)
    /// saved, or `None` when its format no longer restores. Every bump so
    /// far kept the format (new fields default) and fixed the fold's logic,
    /// so a migrated roster can hold state the current reducer would not
    /// have produced: it is served marked stale while the full history is
    /// folded again in the background (`mux/agent_roster_rebuild.rs`).
    pub(crate) fn migrate(from_version: u32, snapshot: &str) -> Option<Self> {
        if !(AGENT_ROSTER_MIGRATES_FROM..=AGENT_ROSTER_REDUCER_VERSION).contains(&from_version) {
            return None;
        }
        Self::restore(snapshot)
    }

    pub(crate) fn restore(snapshot: &str) -> Option<Self> {
        let roster = serde_json::from_str::<Self>(snapshot).ok()?;
        if !roster.entries.values().all(valid_restored_entry) {
            return None;
        }
        if !roster
            .hook_fences
            .values()
            .all(|fence| !fence.session_id.is_empty() && !fence.session_id.contains('\0'))
        {
            return None;
        }
        if !roster.screen_evidence.values().all(ScreenEvidence::valid)
            || !roster.program_status_evidence.values().all(ProgramStatusEvidence::valid)
        {
            return None;
        }
        if !roster.plugin_exit_fences.iter().all(|(plugin_id, fence)| {
            plugin_id != AGENT_HOOK_PRODUCER_ID
                && valid_component(plugin_id)
                && fence.highest_tagged_generation.is_none_or(|generation| generation > 0)
        }) {
            return None;
        }
        Some(roster)
    }
}

fn valid_restored_entry(entry: &RosterEntry) -> bool {
    let Some(state) = agent_state_from_str(&entry.state) else { return false };
    let Some(source) = agent_source_from_str(&entry.source) else { return false };
    if state == AgentState::Done {
        return false;
    }
    if entry
        .session
        .as_deref()
        .is_some_and(|session| session.is_empty() || session.len() > 256 || session.contains('\0'))
    {
        return false;
    }
    if entry.agent.as_deref().is_some_and(|agent| !valid_component(agent)) {
        return false;
    }
    match source {
        AgentSource::Plugin => {
            let Some(producer) = entry.producer.as_deref() else { return false };
            if producer == AGENT_HOOK_PRODUCER_ID || !valid_component(producer) {
                return false;
            }
            entry.producer_generation.as_deref().is_none_or(valid_decimal_generation)
        }
        AgentSource::Detected | AgentSource::Socket | AgentSource::Hook => {
            entry.producer.is_none() && entry.producer_generation.is_none()
        }
    }
}

fn valid_decimal_generation(value: &str) -> bool {
    !value.is_empty()
        && value.bytes().all(|byte| byte.is_ascii_digit())
        && value.parse::<u64>().is_ok()
}

#[path = "journal_reducers_screen_evidence.rs"]
mod screen_evidence;
use screen_evidence::{HookTurnStart, ScreenEvidence, ScreenNote};
#[path = "journal_reducers_program_status.rs"]
mod program_status;
use program_status::ProgramStatusEvidence;
pub(crate) use program_status::{PROGRAM_STATUS_NATIVE_EVENT, is_program_status_evidence};

#[cfg(test)]
#[path = "journal_reducers_blocker_tests.rs"]
mod blocker_tests;

#[cfg(test)]
#[path = "journal_reducers_turn_end_tests.rs"]
mod turn_end_tests;

#[cfg(test)]
mod tests;
