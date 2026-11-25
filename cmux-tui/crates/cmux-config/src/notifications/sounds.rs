//! Which sound plays and how loud (Swift `NotificationSoundPreferences.choice`),
//! the burst cooldown (`NotificationSoundThrottle`), and the edits a menu, the
//! palette or the CLI makes to `notifications.sounds` (`NotificationSoundRule.applying`,
//! `NotificationSoundActions.apply`).

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::{Preferences, SoundEvent, SoundPreferences, SoundRule, SoundScope, Source};

/// The sound a notification plays and how loud, after every level had its say.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SoundChoice {
    /// A sound name, a file path, or `"default"` (the banner's own sound).
    pub name: String,
    /// 0 to 1: the deciding level's volume times the master volume.
    pub volume: f64,
    /// The level that chose it (`agent:claude`, `workspace:ws_1`, `group:Ops`, `event:bell`, `global`).
    pub level: String,
}

impl SoundPreferences {
    /// The levels that apply to `scope`, most specific first: the agent kind,
    /// the workspace, then each group from the innermost out.
    pub fn levels(&self, scope: &SoundScope) -> Vec<(String, &SoundRule)> {
        let mut levels = Vec::new();
        if let Some(agent) = scope.agent.as_deref().map(str::to_lowercase)
            && let Some(rule) = self.agents.get(&agent)
        {
            levels.push((format!("agent:{agent}"), rule));
        }
        if let Some(workspace) = scope.workspace.as_deref()
            && let Some(rule) = self.workspaces.get(workspace)
        {
            levels.push((format!("workspace:{workspace}"), rule));
        }
        for group in &scope.groups {
            if let Some(rule) = self.groups.get(&group.id).or_else(|| self.groups.get(&group.name))
            {
                levels.push((format!("group:{}", group.name), rule));
            }
        }
        levels
    }

    /// The sound `event` plays in `scope`: the most specific level that names
    /// one, then the event's global sound, then `fallback`. `"none"` (or an
    /// empty name) on that path mutes it.
    pub fn choice(
        &self,
        event: SoundEvent,
        scope: &SoundScope,
        fallback: &str,
    ) -> Option<SoundChoice> {
        let levels = self.levels(scope);
        let (name, level) = levels
            .iter()
            .find_map(|(level, rule)| rule.sound_for(event).map(|name| (name, level.clone())))
            .or_else(|| {
                self.events
                    .get(&event)
                    .map(|name| (name.as_str(), format!("event:{}", super::Choice::name(event))))
            })
            .unwrap_or((fallback, "global".to_owned()));
        if name == "none" || name.is_empty() {
            return None;
        }
        let share = levels.iter().find_map(|(_, rule)| rule.volume).unwrap_or(1.0);
        Some(SoundChoice {
            name: name.to_owned(),
            volume: (share * self.volume).clamp(0.0, 1.0),
            level,
        })
    }
}

/// The last sound that passed the cooldown: when (seconds, any clock) and how urgent.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Last {
    pub at: f64,
    pub urgency: i64,
}

/// Whether `event` may sound at `now` (seconds) after `last`, with the
/// cooldown `cooldown_seconds`; a yes is the newest sound. The cooldown is
/// counted in whole milliseconds, as Swift's gate rounds it.
pub fn admit(
    event: SoundEvent,
    now: f64,
    cooldown_seconds: f64,
    last: Option<Last>,
) -> (bool, Option<Last>) {
    let cooldown_ms = (cooldown_seconds.max(0.0) * 1000.0).round();
    if let Some(last) = last
        && (now - last.at) * 1000.0 < cooldown_ms
        && event.urgency() <= last.urgency
    {
        return (false, Some(last));
    }
    (true, Some(Last { at: now, urgency: event.urgency() }))
}

/// The rule after one change. `sound` `"inherit"` clears it (with no `event`:
/// the level's sound and every event's); None keeps it. `volume` clamps to 0...1.
pub fn apply_rule(
    rule: &SoundRule,
    sound: Option<&str>,
    event: Option<SoundEvent>,
    volume: Option<f64>,
) -> SoundRule {
    let mut rule = rule.clone();
    match (sound, event) {
        (None, _) => {}
        (Some("inherit"), None) => {
            rule.sound = None;
            rule.events.clear();
        }
        (Some("inherit"), Some(event)) => {
            rule.events.remove(&event);
        }
        (Some(sound), None) => rule.sound = Some(sound.to_owned()),
        (Some(sound), Some(event)) => {
            rule.events.insert(event, sound.to_owned());
        }
    }
    if let Some(volume) = volume {
        rule.volume = Some(volume.clamp(0.0, 1.0));
    }
    rule
}

/// Where one sound change lands.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", content = "key", rename_all = "camelCase")]
pub enum SoundLevel {
    Workspace(String),
    Group(String),
    Agent(String),
    Event(SoundEvent),
}

/// One change to `notifications.sounds`: the new preferences, and the key path
/// and value to write to cmux.json (None removes it).
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct SoundEdit {
    pub sounds: SoundPreferences,
    pub path: Vec<String>,
    pub value: Option<Value>,
}

/// Applies one change at `level` (Swift `NotificationSoundActions.apply`).
pub fn edit_sounds(
    sounds: &SoundPreferences,
    level: &SoundLevel,
    sound: Option<&str>,
    event: Option<SoundEvent>,
    volume: Option<f64>,
) -> SoundEdit {
    let mut sounds = sounds.clone();
    let mut path = vec!["notifications".to_owned(), "sounds".to_owned()];
    let value = match level {
        SoundLevel::Event(event) => {
            if let Some(sound) = sound {
                if sound == "inherit" {
                    sounds.events.remove(event);
                } else {
                    sounds.events.insert(*event, sound.to_owned());
                }
            }
            path.extend(["events".to_owned(), super::Choice::name(*event).to_owned()]);
            sounds.events.get(event).map(|sound| Value::String(sound.clone()))
        }
        SoundLevel::Workspace(key) => {
            path.push("workspaces".to_owned());
            edit_map(&mut sounds.workspaces, key, sound, event, volume)
        }
        SoundLevel::Group(key) => {
            path.push("groups".to_owned());
            edit_map(&mut sounds.groups, key, sound, event, volume)
        }
        SoundLevel::Agent(key) => {
            path.push("agents".to_owned());
            edit_map(&mut sounds.agents, key, sound, event, volume)
        }
    };
    SoundEdit { sounds, path, value }
}

/// Edits `key`'s rule in `map`; the map as cmux.json holds it (None when empty).
fn edit_map(
    map: &mut BTreeMap<String, SoundRule>,
    key: &str,
    sound: Option<&str>,
    event: Option<SoundEvent>,
    volume: Option<f64>,
) -> Option<Value> {
    let rule = apply_rule(&map.get(key).cloned().unwrap_or_default(), sound, event, volume);
    if rule.is_empty() {
        map.remove(key);
    } else {
        map.insert(key.to_owned(), rule);
    }
    (!map.is_empty()).then(|| serde_json::to_value(&*map).unwrap_or(Value::Null))
}

/// The source whose `notifications.sound` an event falls back to in a preview.
pub fn source_of_event(event: SoundEvent) -> Source {
    match event {
        SoundEvent::Finished | SoundEvent::NeedsInput | SoundEvent::Error => Source::Agent,
        SoundEvent::Bell => Source::Terminal,
        SoundEvent::Message => Source::Cli,
    }
}

/// What a preview of `scope`'s `event` plays now; None when silent (a muted workspace, `"none"`).
pub fn preview_choice(
    prefs: &Preferences,
    scope: &SoundScope,
    event: SoundEvent,
) -> Option<SoundChoice> {
    if scope.workspace.as_ref().is_some_and(|ws| prefs.muted_workspaces.contains(ws)) {
        return None;
    }
    prefs.sounds.choice(event, scope, prefs.sound_for(source_of_event(event)))
}

/// The checked sound in a level's submenu: its own `sound`, else `"inherit"`.
/// A group's rule is found by id, then name.
pub fn checked_sound(sounds: &SoundPreferences, level: &SoundLevel, name: Option<&str>) -> String {
    let rule = match level {
        SoundLevel::Workspace(key) => sounds.workspaces.get(key).and_then(|r| r.sound.clone()),
        SoundLevel::Group(id) => sounds
            .groups
            .get(id)
            .and_then(|r| r.sound.clone())
            .or_else(|| name.and_then(|n| sounds.groups.get(n)).and_then(|r| r.sound.clone())),
        SoundLevel::Agent(key) => sounds.agents.get(key).and_then(|r| r.sound.clone()),
        SoundLevel::Event(event) => sounds.events.get(event).cloned(),
    };
    rule.unwrap_or_else(|| "inherit".to_owned())
}
