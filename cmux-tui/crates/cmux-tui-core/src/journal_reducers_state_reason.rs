//! Why the roster holds each terminal's agent state: the journal record that
//! moved the terminal into its state, how the fold took it (hook, screen,
//! socket report, or the screen over a hook row), the state before it, and
//! the screen's last observation whether or not it won arbitration.
//!
//! The fold records this as it decides ([`AgentRoster::apply`]); nothing here
//! classifies a state again. `cmux agent explain` reads it from the private
//! `list-agents` rows (`state_reason`) and fetches the screen text of the named journal
//! records itself, through the journal's own sensitivity rules: the roster
//! keeps ids, names and times only, never terminal text.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

use super::{AgentRoster, RosterEntry, RosterEvent};

/// The longest rule id, event name or manifest field kept from a producer
/// payload. A plugin is untrusted: its strings are cut, never stored whole.
const MAX_FIELD_BYTES: usize = 128;

/// How the roster fold took the record that set a terminal's state.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum FoldDecision {
    /// An agent hook event (the strongest source).
    Hook,
    /// A direct hook-source report (`agent report --source hook`).
    HookReport,
    /// A direct socket report (`agent report`).
    SocketReport,
    /// A screen-detection plugin observation on a terminal no hook owns.
    Screen,
    /// A screen observation that took a hook row whose hooks went quiet
    /// for longer than the hook freshness window.
    ScreenAfterStaleHook,
    /// The screen showed a hook-announced dialog gone (no hook says so).
    ScreenClearedHookBlocker,
    /// The screen showed a hook turn end with no hook (Esc, a lost `Stop`).
    ScreenEndedHookTurn,
    /// The legacy in-core screen detector (old journals only).
    LegacyScreen,
    /// The program's own status report (OSC 7501) ended a hook dialog.
    ProgramStatusClearedHookBlocker,
}

impl FoldDecision {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::Hook => "hook",
            Self::HookReport => "hook_report",
            Self::SocketReport => "socket_report",
            Self::Screen => "screen",
            Self::ScreenAfterStaleHook => "screen_after_stale_hook",
            Self::ScreenClearedHookBlocker => "screen_cleared_hook_blocker",
            Self::ScreenEndedHookTurn => "screen_ended_hook_turn",
            Self::LegacyScreen => "screen_legacy",
            Self::ProgramStatusClearedHookBlocker => "program_status_cleared_hook_blocker",
        }
    }
}

/// The journal record that moved a terminal into its current state.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct StateCause {
    /// Journal sequence of the record.
    pub(crate) sequence: u64,
    /// The record's commit time.
    pub(crate) at_ms: u64,
    /// When its producer saw it, when the record says.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) observed_at_ms: Option<u64>,
    /// The journal kind (`agent.turn.completed`, `plugin.<id>.agent.state.changed`).
    pub(crate) kind: String,
    /// The hook's native event (`Stop`, `PermissionRequest`), the plugin's
    /// event (`state.changed`), or the report's (`StateReport`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) event: Option<String>,
    /// [`FoldDecision::as_str`].
    pub(crate) decision: String,
    /// The plugin that observed the screen.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) producer: Option<String>,
    /// The screen rule that matched (`native.matched_rule`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) rule: Option<String>,
    /// What the plugin's state rests on (`native.basis`: `rule`,
    /// `idle_fallback`, `output_activity`, `process_identity`, `process_exit`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) basis: Option<String>,
    /// The rule manifest's version (`native.manifest.version`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) manifest_version: Option<String>,
    /// Where the manifest came from (`native.manifest.source`: `bundled`,
    /// `remote`, `local_override`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) manifest_source: Option<String>,
}

/// The state a terminal held before its current one.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct PreviousState {
    pub(crate) state: String,
    pub(crate) source: String,
    pub(crate) since_ms: u64,
    /// When the current state replaced it.
    pub(crate) until_ms: u64,
}

impl PreviousState {
    /// `entry` as the state before one that starts at `until_ms`.
    pub(super) fn of(entry: &RosterEntry, until_ms: u64) -> Self {
        Self {
            state: entry.state.clone(),
            source: entry.source.clone(),
            since_ms: entry.since_ms(),
            until_ms,
        }
    }
}

fn bounded(value: Option<&Value>) -> Option<String> {
    let text = value?.as_str()?;
    if text.is_empty() || text.chars().any(char::is_control) {
        return None;
    }
    let mut kept = String::new();
    for character in text.chars() {
        if kept.len().saturating_add(character.len_utf8()) > MAX_FIELD_BYTES {
            break;
        }
        kept.push(character);
    }
    Some(kept)
}

/// The screen rule a plugin report names (`native.matched_rule`), cut as
/// every producer string is.
pub(super) fn matched_rule(event: &RosterEvent<'_>) -> Option<String> {
    bounded(event.payload.pointer("/native/matched_rule"))
}

impl StateCause {
    /// The cause `event` records when the fold takes it as `decision`.
    pub(super) fn of(event: &RosterEvent<'_>, decision: FoldDecision) -> Self {
        let payload = event.payload;
        let native = payload.get("native");
        let plugin = event.plugin_event();
        let observed_at_ms = if plugin {
            event.plugin_observed_at_ms()
        } else {
            event
                .normalized_u64("observed_at_ms")
                .or_else(|| event.normalized_u64("updated_at_ms"))
                .map(|observed| observed.min(event.committed_at_ms))
        };
        let event_name = if plugin {
            bounded(payload.get("event"))
        } else {
            bounded(payload.get("native_event"))
        };
        let field = |pointer: &str| bounded(native.and_then(|native| native.pointer(pointer)));
        Self {
            sequence: event.sequence,
            at_ms: event.committed_at_ms,
            observed_at_ms,
            kind: event.kind.chars().take(MAX_FIELD_BYTES).collect(),
            event: event_name,
            decision: decision.as_str().to_owned(),
            producer: plugin.then(|| event.producer_id.to_owned()),
            rule: field("/matched_rule"),
            basis: field("/basis"),
            manifest_version: field("/manifest/version"),
            manifest_source: field("/manifest/source"),
        }
    }

    fn to_json(&self) -> Value {
        let mut value = Map::new();
        value.insert("sequence".into(), json!(self.sequence.to_string()));
        value.insert("at_ms".into(), json!(self.at_ms.to_string()));
        if let Some(observed) = self.observed_at_ms {
            value.insert("observed_at_ms".into(), json!(observed.to_string()));
        }
        value.insert("kind".into(), json!(self.kind));
        value.insert("decision".into(), json!(self.decision));
        for (key, field) in [
            ("event", &self.event),
            ("producer", &self.producer),
            ("rule", &self.rule),
            ("basis", &self.basis),
        ] {
            if let Some(field) = field {
                value.insert(key.into(), json!(field));
            }
        }
        if self.manifest_version.is_some() || self.manifest_source.is_some() {
            value.insert(
                "manifest".into(),
                json!({"version": self.manifest_version, "source": self.manifest_source}),
            );
        }
        Value::Object(value)
    }
}

impl AgentRoster {
    /// Each roster terminal's `state_reason`: when its state began,
    /// the record that set it ([`StateCause`]), the state before it, and the
    /// screen's last observation. Decimal times and sequences are strings,
    /// as in every public agent value.
    pub(crate) fn state_reasons(&self) -> HashMap<String, Value> {
        self.entries
            .iter()
            .map(|(terminal_id, entry)| {
                let mut reason = Map::new();
                reason.insert("since_ms".into(), json!(entry.since_ms().to_string()));
                reason.insert("updated_at_ms".into(), json!(entry.updated_at_ms.to_string()));
                if let Some(cause) = &entry.cause {
                    reason.insert("cause".into(), cause.to_json());
                }
                if let Some(previous) = &entry.previous {
                    reason.insert(
                        "previous".into(),
                        json!({
                            "state": previous.state,
                            "source": previous.source,
                            "since_ms": previous.since_ms.to_string(),
                            "until_ms": previous.until_ms.to_string(),
                        }),
                    );
                }
                if let Some(screen) = self.screen_evidence.get(terminal_id) {
                    reason.insert("screen".into(), screen.to_json());
                }
                (terminal_id.clone(), Value::Object(reason))
            })
            .collect()
    }
}

#[cfg(test)]
#[path = "journal_reducers_state_reason_tests.rs"]
mod tests;
