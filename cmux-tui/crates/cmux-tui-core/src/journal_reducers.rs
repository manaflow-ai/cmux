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
pub(crate) const AGENT_ROSTER_REDUCER_VERSION: u32 = 5;
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
    Remove { terminal_id: String, source: AgentSource },
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
}

impl AgentRoster {
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
        if event.plugin_event()
            && self.plugin_observation_is_fenced(
                event.producer_id,
                event.normalized("plugin_generation"),
            )
        {
            return Vec::new();
        }
        let Some(terminal_id) = event.terminal_id() else { return Vec::new() };
        let (state, source, producer, producer_generation, session, agent, updated_at_ms) =
            if event.plugin_event() {
                let Some(event_name) = event.plugin_event_name() else { return Vec::new() };
                let Some(state) = event.normalized("state").and_then(agent_state_from_str) else {
                    return Vec::new();
                };
                if event_name != "state.changed" && event_name != "session.ended" {
                    return Vec::new();
                }
                let updated_at_ms =
                    event.plugin_observed_at_ms().unwrap_or(event.committed_at_ms);
                let producer_generation = event
                    .normalized("plugin_generation")
                    .and_then(|value| value.parse::<u64>().ok())
                    .map(|value| value.to_string());
                let session = event.normalized("source_session").map(str::to_string);
                let agent = event.adapter_id().map(str::to_string);
                (
                    if event_name == "session.ended" { AgentState::Done } else { state },
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
                let Some(state) = state_for_hook_kind(event.kind) else { return Vec::new() };
                let agent = event.adapter_id().map(str::to_string);
                (state, AgentSource::Hook, None, None, None, agent, event.committed_at_ms)
            };
        // Source arbitration: hook > screen > socket per terminal. Hook
        // events always win. Screen detection may not overwrite an entry a
        // live hook owns (fresher than STALE_HOOK_MS), and its exit removal
        // only applies to entries screen detection itself established.
        // Socket reports lose to both stronger sources.
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
                    if existing_source == AgentSource::Hook {
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
            return if owned_by_event {
                self.entries.remove(terminal_id);
                vec![RosterDelta::Remove { terminal_id: terminal_id.to_string(), source }]
            } else {
                Vec::new()
            };
        }
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
        self.entries.remove(terminal_id).is_some()
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
        assert_eq!(
            deltas,
            vec![RosterDelta::Remove { terminal_id: "term_a".into(), source: AgentSource::Hook }]
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
    fn screen_detect_loses_to_fresh_hooks_and_claims_stale_ones() {
        let subjects = terminal_subject("term_a");
        let hook_payload = json!({"adapter": {"id": "claude", "version": 1}});
        let screen = screen_payload("claude", "blocked");
        let mut roster = AgentRoster::default();

        roster.apply(&stamped_event(10_000, "agent.turn.started", &subjects, &hook_payload));
        // A fresh hook entry (29s old) is live agent truth.
        let deltas =
            roster.apply(&stamped_event(39_000, "agent.state.changed", &subjects, &screen));
        assert!(deltas.is_empty());
        assert_eq!(roster.entries["term_a"].source, "hook");

        // At 30s the hook is stale and screen detection takes over.
        let deltas =
            roster.apply(&stamped_event(40_000, "agent.state.changed", &subjects, &screen));
        assert_eq!(deltas.len(), 1);
        assert_eq!(roster.entries["term_a"].source, "detected");
        assert_eq!(roster.entries["term_a"].state, "blocked");

        // A hook event always reclaims the terminal.
        let deltas =
            roster.apply(&stamped_event(41_000, "agent.turn.started", &subjects, &hook_payload));
        assert_eq!(deltas.len(), 1);
        assert_eq!(roster.entries["term_a"].source, "hook");
    }

    #[test]
    fn legacy_detected_source_reclaims_a_stale_hook_at_the_boundary() {
        let subjects = terminal_subject("term_a");
        let hook_payload = json!({"adapter": {"id": "claude", "version": 1}});
        let screen = screen_payload("claude", "idle");
        let mut roster = AgentRoster::default();

        roster.apply(&stamped_event(10_000, "agent.turn.started", &subjects, &hook_payload));
        let deltas = roster.apply(&stamped_event(
            10_000 + STALE_HOOK_MS,
            "agent.state.changed",
            &subjects,
            &screen,
        ));

        assert_eq!(deltas.len(), 1);
        assert_eq!(roster.entries["term_a"].source, "detected");
        assert_eq!(roster.entries["term_a"].state, "idle");
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
        assert_eq!(
            deltas,
            vec![RosterDelta::Remove {
                terminal_id: "term_a".into(),
                source: AgentSource::Detected,
            }]
        );
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
    fn userland_plugin_events_fold_without_core_vendor_knowledge() {
        let subjects = terminal_subject("term_a");
        let working = json!({
            "format": AGENT_PLUGIN_FORMAT,
            "plugin": {"id":"screen_detector","version":1},
            "adapter": {"id":"codex","version":1},
            "event":"state.changed",
            "normalized": {
                "state":"working",
                "source_session":"pid:42",
                "observed_at_ms":"1000"
            }
        });
        let ended = json!({
            "format": AGENT_PLUGIN_FORMAT,
            "plugin": {"id":"screen_detector","version":1},
            "adapter": {"id":"codex","version":1},
            "event":"session.ended",
            "normalized": {
                "state":"done",
                "source_session":"pid:42",
                "observed_at_ms":"2000"
            }
        });
        let mut roster = AgentRoster::default();
        let event = RosterEvent {
            producer_id: "screen_detector",
            kind: "plugin.screen_detector.agent.state.changed",
            subjects: &subjects,
            payload: &working,
            committed_at_ms: 1000,
        };
        let deltas = roster.apply(&event);
        assert_eq!(deltas.len(), 1);
        assert_eq!(roster.entries["term_a"].source, "plugin");
        assert_eq!(roster.entries["term_a"].agent.as_deref(), Some("codex"));

        let event = RosterEvent {
            producer_id: "screen_detector",
            kind: "plugin.screen_detector.agent.session.ended",
            subjects: &subjects,
            payload: &ended,
            committed_at_ms: 2000,
        };
        assert_eq!(
            roster.apply(&event),
            vec![RosterDelta::Remove { terminal_id: "term_a".into(), source: AgentSource::Plugin }]
        );
        assert!(roster.entries.is_empty());
    }

    #[test]
    fn fresh_hook_wins_over_plugin_and_stale_hook_can_be_replaced() {
        let subjects = terminal_subject("term_a");
        let hook_payload = json!({"adapter":{"id":"claude","version":1}});
        let plugin_payload = |observed_at_ms: u64| {
            json!({
                "format": AGENT_PLUGIN_FORMAT,
                "plugin": {"id":"screen_detector","version":1},
                "adapter": {"id":"claude","version":1},
                "event":"state.changed",
                "normalized":{
                    "state":"blocked",
                    "source_session":"pid:42",
                    "observed_at_ms":observed_at_ms.to_string()
                }
            })
        };
        let mut roster = AgentRoster::default();
        roster.apply(&stamped_event(10_000, "agent.turn.started", &subjects, &hook_payload));
        let first_plugin_payload = plugin_payload(39_000);
        let plugin = RosterEvent {
            producer_id: "screen_detector",
            kind: "plugin.screen_detector.agent.state.changed",
            subjects: &subjects,
            payload: &first_plugin_payload,
            committed_at_ms: 39_000,
        };
        assert!(roster.apply(&plugin).is_empty());
        assert_eq!(roster.entries["term_a"].source, "hook");
        let plugin_payload = plugin_payload(40_000);
        let plugin = RosterEvent { payload: &plugin_payload, committed_at_ms: 40_000, ..plugin };
        assert_eq!(roster.apply(&plugin).len(), 1);
        assert_eq!(roster.entries["term_a"].source, "plugin");
    }

    #[test]
    fn an_older_plugin_observation_cannot_reclaim_a_hook_row() {
        let subjects = terminal_subject("term_a");
        let hook_payload = json!({"adapter":{"id":"claude","version":1}});
        let plugin_payload = json!({
            "format": AGENT_PLUGIN_FORMAT,
            "plugin": {"id":"screen_detector","version":1},
            "adapter": {"id":"claude","version":1},
            "event":"state.changed",
            "normalized":{"state":"blocked","source_session":"pid:42","observed_at_ms":"9000"}
        });
        let mut roster = AgentRoster::default();
        roster.apply(&stamped_event(10_000, "agent.turn.started", &subjects, &hook_payload));
        let plugin = RosterEvent {
            producer_id: "screen_detector",
            kind: "plugin.screen_detector.agent.state.changed",
            subjects: &subjects,
            payload: &plugin_payload,
            committed_at_ms: 50_000,
        };
        assert!(roster.apply(&plugin).is_empty());
        assert_eq!(roster.entries["term_a"].source, "hook");
    }

    #[test]
    fn future_plugin_observation_cannot_outdate_a_live_hook() {
        let subjects = terminal_subject("term_a");
        let hook_payload = json!({"adapter":{"id":"claude","version":1}});
        let plugin_payload = json!({
            "format": AGENT_PLUGIN_FORMAT,
            "plugin": {"id":"screen_detector","version":1},
            "adapter": {"id":"claude","version":1},
            "event":"state.changed",
            "normalized": {
                "state":"blocked",
                "source_session":"pid:42",
                "observed_at_ms":u64::MAX.to_string()
            }
        });
        let mut roster = AgentRoster::default();
        roster.apply(&stamped_event(10_000, "agent.turn.started", &subjects, &hook_payload));
        let plugin = RosterEvent {
            producer_id: "screen_detector",
            kind: "plugin.screen_detector.agent.state.changed",
            subjects: &subjects,
            payload: &plugin_payload,
            committed_at_ms: 20_000,
        };
        assert!(roster.apply(&plugin).is_empty());
        assert_eq!(roster.entries["term_a"].source, "hook");
    }

    #[test]
    fn supervisor_exit_retires_only_old_entries_for_that_plugin() {
        let subjects_a = terminal_subject("term_a");
        let subjects_b = terminal_subject("term_b");
        let payload = |session: &str, timestamp: u64| {
            json!({
                "format": AGENT_PLUGIN_FORMAT,
                "plugin": {"id":"screen_detector","version":1},
                "adapter": {"id":"codex","version":1},
                "event":"state.changed",
                "normalized": {
                    "state":"working",
                    "source_session":session,
                    "observed_at_ms":timestamp.to_string()
                }
            })
        };
        let mut roster = AgentRoster::default();
        let first = payload("pid:1", 100);
        let second = payload("pid:2", 300);
        roster.apply(&RosterEvent {
            producer_id: "screen_detector",
            kind: "plugin.screen_detector.agent.state.changed",
            subjects: &subjects_a,
            payload: &first,
            committed_at_ms: 100,
        });
        roster.apply(&RosterEvent {
            producer_id: "screen_detector",
            kind: "plugin.screen_detector.agent.state.changed",
            subjects: &subjects_b,
            payload: &second,
            committed_at_ms: 300,
        });
        let exit = json!({
                "format": crate::agent_hooks::AGENT_HOOK_FORMAT,
            "adapter":{"id":"cmux","version":1},
            "native_event": crate::agent_hooks::JOURNAL_PLUGIN_EXIT_NATIVE_EVENT,
            "normalized":{"plugin_id":"screen_detector","observed_at_ms":"200"},
            "native":{}
        });
        let deltas = roster.apply(&RosterEvent {
            producer_id: AGENT_HOOK_PRODUCER_ID,
            kind: "agent.plugin.exited",
            subjects: &[],
            payload: &exit,
            committed_at_ms: 200,
        });
        assert_eq!(
            deltas,
            vec![RosterDelta::Remove { terminal_id: "term_a".into(), source: AgentSource::Plugin }]
        );
        assert!(!roster.entries.contains_key("term_a"));
        assert!(roster.entries.contains_key("term_b"));
    }

    #[test]
    fn late_exit_from_an_old_plugin_generation_cannot_remove_replacement_rows() {
        let subjects = terminal_subject("term_a");
        let event = |generation: &str, timestamp: u64| {
            let payload = json!({
                "format": AGENT_PLUGIN_FORMAT,
                "plugin": {"id":"screen_detector","version":1},
                "adapter": {"id":"codex","version":1},
                "event":"state.changed",
                "normalized": {
                    "state":"working",
                    "source_session":"pid:42",
                    "plugin_generation":generation,
                    "observed_at_ms":timestamp.to_string()
                }
            });
            (payload, timestamp)
        };
        let (old_payload, old_time) = event("1", 100);
        let (new_payload, new_time) = event("2", 200);
        let mut roster = AgentRoster::default();
        roster.apply(&RosterEvent {
            producer_id: "screen_detector",
            kind: "plugin.screen_detector.agent.state.changed",
            subjects: &subjects,
            payload: &old_payload,
            committed_at_ms: old_time,
        });
        roster.apply(&RosterEvent {
            producer_id: "screen_detector",
            kind: "plugin.screen_detector.agent.state.changed",
            subjects: &subjects,
            payload: &new_payload,
            committed_at_ms: new_time,
        });
        let exit = json!({
            "format": crate::agent_hooks::AGENT_HOOK_FORMAT,
            "adapter":{"id":"cmux","version":1},
            "native_event": crate::agent_hooks::JOURNAL_PLUGIN_EXIT_NATIVE_EVENT,
            "normalized": {
                "plugin_id":"screen_detector",
                "plugin_generation":"1",
                "observed_at_ms":"300"
            },
            "native":{}
        });
        assert!(
            roster
                .apply(&RosterEvent {
                    producer_id: AGENT_HOOK_PRODUCER_ID,
                    kind: "agent.plugin.exited",
                    subjects: &[],
                    payload: &exit,
                    committed_at_ms: 300,
                })
                .is_empty()
        );
        assert_eq!(roster.entries["term_a"].producer_generation.as_deref(), Some("2"));
    }

    #[test]
    fn late_observation_from_an_exited_plugin_generation_cannot_recreate_a_row() {
        let subjects = terminal_subject("term_a");
        let payload = |observed_at_ms: u64| {
            json!({
                "format": AGENT_PLUGIN_FORMAT,
                "plugin": {"id":"screen_detector","version":1},
                "adapter": {"id":"codex","version":1},
                "event":"state.changed",
                "normalized": {
                    "state":"working",
                    "source_session":"pid:42",
                    "plugin_generation":"1",
                    "observed_at_ms": observed_at_ms.to_string()
                }
            })
        };
        let mut roster = AgentRoster::default();
        let first = payload(100);
        roster.apply(&RosterEvent {
            producer_id: "screen_detector",
            kind: "plugin.screen_detector.agent.state.changed",
            subjects: &subjects,
            payload: &first,
            committed_at_ms: 100,
        });
        let exit = json!({
            "format": crate::agent_hooks::AGENT_HOOK_FORMAT,
            "adapter":{"id":"cmux","version":1},
            "native_event": crate::agent_hooks::JOURNAL_PLUGIN_EXIT_NATIVE_EVENT,
            "normalized": {
                "plugin_id":"screen_detector",
                "plugin_generation":"1",
                "observed_at_ms":"200"
            },
            "native":{}
        });
        assert_eq!(
            roster.apply(&RosterEvent {
                producer_id: AGENT_HOOK_PRODUCER_ID,
                kind: "agent.plugin.exited",
                subjects: &[],
                payload: &exit,
                committed_at_ms: 200,
            }),
            vec![RosterDelta::Remove { terminal_id: "term_a".into(), source: AgentSource::Plugin }]
        );
        let late = payload(300);
        assert!(
            roster
                .apply(&RosterEvent {
                    producer_id: "screen_detector",
                    kind: "plugin.screen_detector.agent.state.changed",
                    subjects: &subjects,
                    payload: &late,
                    committed_at_ms: 300,
                })
                .is_empty()
        );
        assert!(!roster.entries.contains_key("term_a"));
    }

    #[test]
    fn newer_plugin_generation_can_claim_after_an_exit_fence() {
        let subjects = terminal_subject("term_a");
        let payload = |generation: &str, observed_at_ms: u64| {
            json!({
                "format": AGENT_PLUGIN_FORMAT,
                "plugin": {"id":"screen_detector","version":1},
                "adapter": {"id":"codex","version":1},
                "event":"state.changed",
                "normalized": {
                    "state":"working",
                    "source_session":"pid:42",
                    "plugin_generation":generation,
                    "observed_at_ms": observed_at_ms.to_string()
                }
            })
        };
        let exit = |generation: &str, observed_at_ms: u64| {
            json!({
                "format": crate::agent_hooks::AGENT_HOOK_FORMAT,
                "adapter":{"id":"cmux","version":1},
                "native_event": crate::agent_hooks::JOURNAL_PLUGIN_EXIT_NATIVE_EVENT,
                "normalized": {
                    "plugin_id":"screen_detector",
                    "plugin_generation":generation,
                    "observed_at_ms": observed_at_ms.to_string()
                },
                "native":{}
            })
        };
        let mut roster = AgentRoster::default();
        let old = payload("1", 100);
        roster.apply(&RosterEvent {
            producer_id: "screen_detector",
            kind: "plugin.screen_detector.agent.state.changed",
            subjects: &subjects,
            payload: &old,
            committed_at_ms: 100,
        });
        let old_exit = exit("1", 200);
        roster.apply(&RosterEvent {
            producer_id: AGENT_HOOK_PRODUCER_ID,
            kind: "agent.plugin.exited",
            subjects: &[],
            payload: &old_exit,
            committed_at_ms: 200,
        });
        let replacement = payload("2", 150);
        assert_eq!(
            roster
                .apply(&RosterEvent {
                    producer_id: "screen_detector",
                    kind: "plugin.screen_detector.agent.state.changed",
                    subjects: &subjects,
                    payload: &replacement,
                    committed_at_ms: 300,
                })
                .len(),
            1
        );
        assert_eq!(roster.entries["term_a"].producer_generation.as_deref(), Some("2"));
    }

    #[test]
    fn untagged_plugin_exit_cannot_remove_a_tagged_child() {
        let subjects = terminal_subject("term_a");
        let payload = json!({
            "format": AGENT_PLUGIN_FORMAT,
            "plugin": {"id":"screen_detector","version":1},
            "adapter": {"id":"codex","version":1},
            "event":"state.changed",
            "normalized": {
                "state":"working",
                "source_session":"pid:42",
                "plugin_generation":"7",
                "observed_at_ms":"100"
            }
        });
        let mut roster = AgentRoster::default();
        assert_eq!(
            roster
                .apply(&RosterEvent {
                    producer_id: "screen_detector",
                    kind: "plugin.screen_detector.agent.state.changed",
                    subjects: &subjects,
                    payload: &payload,
                    committed_at_ms: 100,
                })
                .len(),
            1
        );

        let exit = json!({
            "format": crate::agent_hooks::AGENT_HOOK_FORMAT,
            "adapter":{"id":"cmux","version":1},
                "native_event": crate::agent_hooks::JOURNAL_PLUGIN_EXIT_NATIVE_EVENT,
            "normalized":{"plugin_id":"screen_detector","observed_at_ms":"200"},
            "native":{}
        });
        assert!(
            roster
                .apply(&RosterEvent {
                    producer_id: AGENT_HOOK_PRODUCER_ID,
                    kind: "agent.plugin.exited",
                    subjects: &[],
                    payload: &exit,
                    committed_at_ms: 200,
                })
                .is_empty()
        );
        assert!(roster.entries.contains_key("term_a"));
    }

    #[test]
    fn stale_plugin_observations_cannot_regress_a_generation() {
        let subjects = terminal_subject("term_a");
        let payload = |generation: &str, state: &str, observed_at_ms: &str| {
            json!({
                "format": AGENT_PLUGIN_FORMAT,
                "plugin": {"id":"screen_detector","version":1},
                "adapter": {"id":"codex","version":1},
                "event":"state.changed",
                "normalized": {
                    "state":state,
                    "source_session":"pid:42",
                    "plugin_generation":generation,
                    "observed_at_ms":observed_at_ms
                }
            })
        };
        let mut roster = AgentRoster::default();
        let current = payload("2", "working", "200");
        roster.apply(&RosterEvent {
            producer_id: "screen_detector",
            kind: "plugin.screen_detector.agent.state.changed",
            subjects: &subjects,
            payload: &current,
            committed_at_ms: 200,
        });
        let old_timestamp = payload("2", "blocked", "100");
        assert!(
            roster
                .apply(&RosterEvent {
                    producer_id: "screen_detector",
                    kind: "plugin.screen_detector.agent.state.changed",
                    subjects: &subjects,
                    payload: &old_timestamp,
                    committed_at_ms: 300,
                })
                .is_empty()
        );
        assert_eq!(roster.entries["term_a"].state, "working");

        let old_generation = payload("1", "blocked", "999");
        assert!(
            roster
                .apply(&RosterEvent {
                    producer_id: "screen_detector",
                    kind: "plugin.screen_detector.agent.state.changed",
                    subjects: &subjects,
                    payload: &old_generation,
                    committed_at_ms: 999,
                })
                .is_empty()
        );
        assert_eq!(roster.entries["term_a"].producer_generation.as_deref(), Some("2"));
    }

    #[test]
    fn malformed_plugin_envelopes_never_enter_the_roster() {
        let subjects = terminal_subject("term_a");
        let valid = json!({
            "format": AGENT_PLUGIN_FORMAT,
            "plugin": {"id":"screen_detector","version":1},
            "adapter": {"id":"codex","version":1},
            "event":"state.changed",
            "normalized": {
                "state":"working",
                "source_session":"pid:42",
                "observed_at_ms":"100"
            }
        });
        let malformed = [
            json!({"format":"wrong","plugin":{"id":"screen_detector","version":1},"adapter":{"id":"codex","version":1},"event":"state.changed","normalized":{"state":"working","source_session":"pid:42","observed_at_ms":"100"}}),
            json!({"format":AGENT_PLUGIN_FORMAT,"plugin":{"id":"other","version":1},"adapter":{"id":"codex","version":1},"event":"state.changed","normalized":{"state":"working","source_session":"pid:42","observed_at_ms":"100"}}),
            json!({"format":AGENT_PLUGIN_FORMAT,"plugin":{"id":"screen_detector","version":1},"adapter":{"id":"codex","version":1},"event":"state.changed","normalized":{"state":"working","source_session":"pid:42"}}),
            json!({"format":AGENT_PLUGIN_FORMAT,"plugin":{"id":"screen_detector","version":1},"adapter":{"id":"codex","version":1},"event":"state.changed","normalized":{"state":"working","source_session":"pid:42","plugin_generation":7,"observed_at_ms":"100"}}),
        ];
        for payload in malformed {
            let event = RosterEvent {
                producer_id: "screen_detector",
                kind: "plugin.screen_detector.agent.state.changed",
                subjects: &subjects,
                payload: &payload,
                committed_at_ms: 100,
            };
            let mut roster = AgentRoster::default();
            assert!(roster.apply(&event).is_empty());
            assert!(roster.entries.is_empty());
        }
        let mut roster = AgentRoster::default();
        assert_eq!(
            roster
                .apply(&RosterEvent {
                    producer_id: "screen_detector",
                    kind: "plugin.screen_detector.agent.state.changed",
                    subjects: &subjects,
                    payload: &valid,
                    committed_at_ms: 100,
                })
                .len(),
            1
        );
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
