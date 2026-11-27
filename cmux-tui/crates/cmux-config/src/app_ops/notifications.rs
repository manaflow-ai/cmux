//! `notifications.*`: the read of `notifications` and `feed.mirrorNotifications`
//! in cmux.json and the notification rules ([`crate::notifications`]). Values
//! go over the wire in their cmux.json names (camelCase keys, raw choice names).
//! The clock is an input: `now` in seconds on any steady clock,
//! `minuteOfDay` the local minutes after midnight.
//!
//! - `notifications.parse` `{root}` answers `{prefs, diagnostics}`.
//! - `notifications.decide` `{prefs, arrival}` answers `{decision}`.
//! - `notifications.clears` `{prefs, trigger, source}` answers `{clears}`.
//! - `notifications.flashes_on_entry` `{flashesOnRead, flashesOnTyping, trigger}` answers `{flashes}`.
//! - `notifications.sound_choice` `{sounds, event, scope?, fallback}` answers `{choice}` (null: silent).
//! - `notifications.sound_admit` `{event, now, cooldownSeconds, last?}` answers `{admit, last}`.
//! - `notifications.sound_event` `{source?, level?}` answers `{event}` (wire values; unknown read as agent, info).
//! - `notifications.agent_kind` `{agent?}` answers `{agent}` (null when empty).
//! - `notifications.rule_parse` `{value}` answers `{rule, problems}`; `notifications.rule_accepts` `{value}` answers `{accepts}`.
//! - `notifications.rule_apply` `{rule?, sound?, event?, volume?}` answers `{rule, isEmpty}`.
//! - `notifications.sound_edit` `{sounds, level: {kind, key}, sound?, event?, volume?}` answers `{sounds, path, value}`.
//! - `notifications.sound_checked` `{sounds, level, name?}` answers `{sound}`.
//! - `notifications.preview_choice` `{prefs, scope, event?}` answers `{choice}` (event defaults to finished).
//! - `notifications.quiet_minutes` `{text}` answers `{minutes}`; `notifications.quiet_contains` `{quietHours, minuteOfDay}` answers `{contains}`.
//! - `notifications.workspace_key` `{machine, workspace, localMachine, keys?, ruleKeys?, localIds?}` answers
//!   `{settingsKey, qualified, mutes, legacyRemoteKey, ruleKey}`.
//! - `notifications.workspace_ids` `{keys, machine, localMachine, localIds?}` answers `{ids}`.

use std::collections::BTreeSet;

use serde::de::DeserializeOwned;
use serde_json::{Value, json};

use super::OpError;
use crate::notifications::{
    self as n, Arrival, Last, Level, Preferences, QuietHours, SoundEvent, SoundLevel,
    SoundPreferences, SoundRule, SoundScope, Source, Trigger,
};

/// Runs `op` when it is a `notifications.*` op.
pub fn call(op: &str, request: &Value) -> Option<Result<Value, OpError>> {
    Some(match op {
        "notifications.parse" => parse(request),
        "notifications.decide" => decide(request),
        "notifications.clears" => clears(request),
        "notifications.flashes_on_entry" => flashes_on_entry(request),
        "notifications.sound_choice" => sound_choice(request),
        "notifications.sound_admit" => sound_admit(request),
        "notifications.sound_event" => sound_event(request),
        "notifications.agent_kind" => agent_kind(request),
        "notifications.rule_parse" => rule_parse(request),
        "notifications.rule_accepts" => rule_accepts(request),
        "notifications.rule_apply" => rule_apply(request),
        "notifications.sound_edit" => sound_edit(request),
        "notifications.sound_checked" => sound_checked(request),
        "notifications.preview_choice" => preview_choice(request),
        "notifications.quiet_minutes" => quiet_minutes(request),
        "notifications.quiet_contains" => quiet_contains(request),
        "notifications.workspace_key" => workspace_key(request),
        "notifications.workspace_ids" => workspace_ids(request),
        _ => return None,
    })
}

/// The member `key`, decoded; absent or null is an error.
fn field<T: DeserializeOwned>(request: &Value, key: &str) -> Result<T, OpError> {
    let value = request.get(key).filter(|v| !v.is_null());
    let value = value.ok_or_else(|| OpError::Invalid(format!("expected `{key}`")))?;
    T::deserialize(value).map_err(|error| OpError::Invalid(format!("`{key}`: {error}")))
}

/// The member `key`, decoded; absent or null is None.
fn optional<T: DeserializeOwned>(request: &Value, key: &str) -> Result<Option<T>, OpError> {
    match request.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(_) => field(request, key).map(Some),
    }
}

fn reply(value: impl serde::Serialize) -> Result<Value, OpError> {
    serde_json::to_value(value).map_err(|error| OpError::Invalid(error.to_string()))
}

fn parse(request: &Value) -> Result<Value, OpError> {
    let root = request.get("root").ok_or_else(|| OpError::Invalid("expected `root`".into()))?;
    let (prefs, diagnostics) = n::parse(root);
    reply(json!({ "prefs": prefs, "diagnostics": diagnostics }))
}

fn decide(request: &Value) -> Result<Value, OpError> {
    let prefs: Preferences = optional(request, "prefs")?.unwrap_or_default();
    let arrival: Arrival = field(request, "arrival")?;
    reply(json!({ "decision": n::decide(&prefs, &arrival) }))
}

fn clears(request: &Value) -> Result<Value, OpError> {
    let prefs: Preferences = optional(request, "prefs")?.unwrap_or_default();
    let trigger: Trigger = field(request, "trigger")?;
    let source = Source::from_wire(request.get("source").and_then(Value::as_str));
    reply(json!({ "clears": n::clears(&prefs, trigger, source) }))
}

fn flashes_on_entry(request: &Value) -> Result<Value, OpError> {
    let on_read: bool = field(request, "flashesOnRead")?;
    let on_typing: bool = field(request, "flashesOnTyping")?;
    let trigger: Trigger = field(request, "trigger")?;
    reply(json!({ "flashes": n::flashes_on_entry(on_read, on_typing, trigger) }))
}

fn sound_choice(request: &Value) -> Result<Value, OpError> {
    let sounds: SoundPreferences = optional(request, "sounds")?.unwrap_or_default();
    let event: SoundEvent = field(request, "event")?;
    let scope: SoundScope = optional(request, "scope")?.unwrap_or_default();
    let fallback = super::string(request, "fallback")?;
    reply(json!({ "choice": sounds.choice(event, &scope, fallback) }))
}

fn sound_admit(request: &Value) -> Result<Value, OpError> {
    let event: SoundEvent = field(request, "event")?;
    let now: f64 = field(request, "now")?;
    let cooldown: f64 = field(request, "cooldownSeconds")?;
    let last: Option<Last> = optional(request, "last")?;
    let (admit, last) = n::admit(event, now, cooldown, last);
    reply(json!({ "admit": admit, "last": last }))
}

fn sound_event(request: &Value) -> Result<Value, OpError> {
    let source = Source::from_wire(request.get("source").and_then(Value::as_str));
    let level = request.get("level").and_then(Value::as_str).map_or(Level::Info, n::level_of);
    reply(json!({ "event": SoundEvent::of(source, level) }))
}

fn agent_kind(request: &Value) -> Result<Value, OpError> {
    reply(json!({ "agent": n::agent_kind(request.get("agent").and_then(Value::as_str)) }))
}

fn rule_value(request: &Value) -> Result<&Value, OpError> {
    request.get("value").ok_or_else(|| OpError::Invalid("expected `value`".into()))
}

fn rule_parse(request: &Value) -> Result<Value, OpError> {
    let (rule, problems) = n::parse_rule(rule_value(request)?);
    reply(json!({ "rule": rule, "problems": problems }))
}

fn rule_accepts(request: &Value) -> Result<Value, OpError> {
    reply(json!({ "accepts": n::rule_accepts(rule_value(request)?) }))
}

/// `sound`, `event` and `volume` of an edit; an empty sound is no sound.
/// One edit: the sound, the event it is for, the volume.
type Change = (Option<String>, Option<SoundEvent>, Option<f64>);

fn change(request: &Value) -> Result<Change, OpError> {
    let sound: Option<String> = optional(request, "sound")?;
    let event: Option<SoundEvent> = optional(request, "event")?;
    let volume: Option<f64> = optional(request, "volume")?;
    Ok((sound.filter(|s| !s.is_empty()), event, volume))
}

fn rule_apply(request: &Value) -> Result<Value, OpError> {
    let rule: SoundRule = optional(request, "rule")?.unwrap_or_default();
    let (sound, event, volume) = change(request)?;
    let rule = n::apply_rule(&rule, sound.as_deref(), event, volume);
    reply(json!({ "isEmpty": rule.is_empty(), "rule": rule }))
}

fn sound_edit(request: &Value) -> Result<Value, OpError> {
    let sounds: SoundPreferences = optional(request, "sounds")?.unwrap_or_default();
    let level: SoundLevel = field(request, "level")?;
    let (sound, event, volume) = change(request)?;
    reply(n::edit_sounds(&sounds, &level, sound.as_deref(), event, volume))
}

fn sound_checked(request: &Value) -> Result<Value, OpError> {
    let sounds: SoundPreferences = optional(request, "sounds")?.unwrap_or_default();
    let level: SoundLevel = field(request, "level")?;
    let name: Option<String> = optional(request, "name")?;
    reply(json!({ "sound": n::checked_sound(&sounds, &level, name.as_deref()) }))
}

fn preview_choice(request: &Value) -> Result<Value, OpError> {
    let prefs: Preferences = optional(request, "prefs")?.unwrap_or_default();
    let scope: SoundScope = optional(request, "scope")?.unwrap_or_default();
    let event: SoundEvent = optional(request, "event")?.unwrap_or(SoundEvent::Finished);
    reply(json!({ "choice": n::preview_choice(&prefs, &scope, event) }))
}

fn quiet_minutes(request: &Value) -> Result<Value, OpError> {
    reply(json!({ "minutes": QuietHours::minutes(super::string(request, "text")?) }))
}

fn quiet_contains(request: &Value) -> Result<Value, OpError> {
    let hours: Option<QuietHours> = optional(request, "quietHours")?;
    let minute: i64 = field(request, "minuteOfDay")?;
    reply(json!({ "contains": hours.is_some_and(|h| h.contains(minute)) }))
}

fn set(request: &Value, key: &str) -> Result<BTreeSet<String>, OpError> {
    Ok(optional(request, key)?.unwrap_or_default())
}

fn workspace_key(request: &Value) -> Result<Value, OpError> {
    let machine = super::string(request, "machine")?;
    let workspace = super::string(request, "workspace")?;
    let local = super::string(request, "localMachine")?;
    let (keys, rule_keys, local_ids) =
        (set(request, "keys")?, set(request, "ruleKeys")?, set(request, "localIds")?);
    reply(json!({
        "settingsKey": n::settings_key(machine, workspace, local),
        "qualified": n::qualified(machine, workspace),
        "mutes": n::mutes(&keys, machine, workspace, local, &local_ids),
        "legacyRemoteKey": n::legacy_remote_key(&keys, machine, workspace, local, &local_ids),
        "ruleKey": n::rule_key(machine, workspace, local, &rule_keys, &local_ids),
    }))
}

fn workspace_ids(request: &Value) -> Result<Value, OpError> {
    let machine = super::string(request, "machine")?;
    let local = super::string(request, "localMachine")?;
    let (keys, local_ids) = (set(request, "keys")?, set(request, "localIds")?);
    reply(json!({ "ids": n::workspace_ids(&keys, machine, local, &local_ids) }))
}

/// The op names, for tests and the Swift side's parity check.
pub const OPS: &[&str] = &[
    "notifications.parse",
    "notifications.decide",
    "notifications.clears",
    "notifications.flashes_on_entry",
    "notifications.sound_choice",
    "notifications.sound_admit",
    "notifications.sound_event",
    "notifications.agent_kind",
    "notifications.rule_parse",
    "notifications.rule_accepts",
    "notifications.rule_apply",
    "notifications.sound_edit",
    "notifications.sound_checked",
    "notifications.preview_choice",
    "notifications.quiet_minutes",
    "notifications.quiet_contains",
    "notifications.workspace_key",
    "notifications.workspace_ids",
];

#[cfg(test)]
#[path = "notifications_tests.rs"]
mod tests;
