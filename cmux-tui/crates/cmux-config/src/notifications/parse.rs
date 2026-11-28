//! The read of `notifications.*` and `feed.*` from cmux.json (Swift
//! `NotificationConfigParser` and `NotificationSoundRule.parse`). A bad value
//! keeps its default with a diagnostic, in the order Swift adds them.

use std::collections::BTreeMap;

use serde::Serialize;
use serde_json::{Map, Value};

use super::{
    Choice, DesktopMode, Dismissal, DockBounce, FeedMirror, FeedTerminalMirror, Preferences,
    Previews, QuietHours, SoundEvent, SoundPreferences, SoundRule, SoundTiming, Source,
    SourceOverrides, ToastStyle, defaults,
};
use crate::value::value_at;

/// One problem with a value (Swift `SettingsDiagnostic` of kind `invalidValue`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Diagnostic {
    pub kind: &'static str,
    pub path: String,
    pub message: String,
}

impl Diagnostic {
    fn invalid(path: impl Into<String>, message: impl Into<String>) -> Diagnostic {
        Diagnostic { kind: "invalidValue", path: path.into(), message: message.into() }
    }
}

/// The members of one object in cmux.json (Swift `ConfigFieldReader`).
struct Reader<'a> {
    members: &'a Map<String, Value>,
    path: String,
    diagnostics: Vec<Diagnostic>,
}

impl<'a> Reader<'a> {
    /// The object at `key_path`; None when absent, None with a diagnostic when not an object.
    fn at(root: &'a Value, key_path: &[&str], out: &mut Vec<Diagnostic>) -> Option<Reader<'a>> {
        let path: Vec<String> = key_path.iter().map(|part| (*part).to_owned()).collect();
        let value = value_at(root, &path)?;
        let path = key_path.join(".");
        let Some(members) = value.as_object() else {
            out.push(Diagnostic::invalid(path, "expected an object"));
            return None;
        };
        Some(Reader { members, path, diagnostics: Vec::new() })
    }

    fn fail(&mut self, key: &str, message: impl Into<String>) {
        self.diagnostics.push(Diagnostic::invalid(format!("{}.{key}", self.path), message));
    }

    fn bool(&mut self, key: &str) -> Option<bool> {
        let value = self.members.get(key)?;
        let bool = value.as_bool();
        if bool.is_none() {
            self.fail(key, "expected true or false");
        }
        bool
    }

    fn number(&mut self, key: &str, (lo, hi): (f64, f64)) -> Option<f64> {
        let value = self.members.get(key)?;
        let Some(number) = value.as_f64().filter(|n| n.is_finite()) else {
            self.fail(key, "expected a number");
            return None;
        };
        if !(lo..=hi).contains(&number) {
            self.fail(key, format!("clamped to {lo:?}...{hi:?}"));
        }
        Some(number.clamp(lo, hi))
    }

    fn choice<T: Choice>(&mut self, key: &str) -> Option<T> {
        let value = self.members.get(key)?;
        let choice = value.as_str().and_then(T::from_name);
        if choice.is_none() {
            let names: Vec<String> = T::ALL.iter().map(|c| format!("\"{}\"", c.name())).collect();
            self.fail(key, format!("expected one of {}", names.join(", ")));
        }
        choice
    }

    /// A color: `Some(None)` is the theme's (`null` or `"theme"`).
    fn color(&mut self, key: &str) -> Option<Option<String>> {
        let value = self.members.get(key)?;
        if value.is_null() {
            return Some(None);
        }
        let color = match value.as_str() {
            Some("theme") => return Some(None),
            Some(text) => css_hex(text),
            None => None,
        };
        if color.is_none() {
            self.fail(key, "expected a #RRGGBB color");
        }
        color.map(Some)
    }

    fn string(&mut self, key: &str) -> Option<String> {
        let value = self.members.get(key)?;
        let text = value.as_str().map(str::to_owned);
        if text.is_none() {
            self.fail(key, "expected a string");
        }
        text
    }
}

/// `#RGB`, `#RRGGBB` or `#RRGGBBAA` (`#` optional), as Swift `ThemeRGB(cssHex:)`
/// reads it, written back as `#RRGGBB` (`#RRGGBBAA` when translucent).
pub(super) fn css_hex(text: &str) -> Option<String> {
    // Swift's `.whitespaces`: tab and the space separators, not line breaks.
    let trimmed = text.trim_matches(|c: char| {
        c == '\t' || (c.is_whitespace() && !c.is_control() && !matches!(c, '\u{2028}' | '\u{2029}'))
    });
    let digits = trimmed.strip_prefix('#').unwrap_or(trimmed);
    if ![3, 6, 8].contains(&digits.len()) || !digits.chars().all(|c| c.is_ascii_hexdigit()) {
        return None;
    }
    let mut value = u64::from_str_radix(digits, 16).ok()?;
    if digits.len() == 3 {
        let (r, g, b) = ((value >> 8) & 0xF, (value >> 4) & 0xF, value & 0xF);
        value = ((r * 17) << 16) | ((g * 17) << 8) | (b * 17);
    }
    if digits.len() == 8 && value & 0xFF != 0xFF {
        return Some(format!("#{value:08X}"));
    }
    if digits.len() == 8 {
        value >>= 8;
    }
    Some(format!("#{value:06X}"))
}

/// The preferences in `root` (the whole cmux.json value) and the problems with them.
pub fn parse(root: &Value) -> (Preferences, Vec<Diagnostic>) {
    let mut out = Vec::new();
    let mut prefs =
        Preferences { feed_mirror: feed_mirror(root, &mut out), ..Preferences::default() };
    let Some(mut reader) = Reader::at(root, &["notifications"], &mut out) else {
        return (prefs, out);
    };
    if let Some(value) = reader.choice::<Dismissal>("dismissal") {
        prefs.dismissal = value;
    }
    if let Some(value) = reader.number("timeoutSeconds", defaults::TIMEOUT_RANGE) {
        prefs.timeout_seconds = value;
    }
    if let Some(value) = reader.choice::<DesktopMode>("desktop") {
        prefs.desktop = value;
    }
    if let Some(value) = reader.string("sound") {
        prefs.sound = value;
    }
    if let Some(value) = reader.number("suppressWhileTypingSeconds", defaults::TYPING_RANGE) {
        prefs.suppress_while_typing_seconds = value;
    }
    if let Some(value) = reader.bool("dockBadge") {
        prefs.dock_badge = value;
    }
    if let Some(value) = reader.choice::<DockBounce>("dockBounce") {
        prefs.dock_bounce = value;
    }
    if let Some(value) = reader.choice::<Previews>("showPreviews") {
        prefs.show_previews = value;
    }
    out.append(&mut reader.diagnostics);
    if let Some(mut toast) = Reader::at(root, &["notifications", "toast"], &mut out) {
        if let Some(value) = toast.choice::<ToastStyle>("style") {
            prefs.toast_style = value;
        }
        out.append(&mut toast.diagnostics);
    }
    prefs.quiet_hours = quiet_hours(root, &mut out);
    prefs.muted_workspaces = muted_workspaces(root, &mut out);
    prefs.sounds = sounds(root, &mut out);
    for &source in Source::ALL {
        let Some(mut entry) =
            Reader::at(root, &["notifications", "sources", source.name()], &mut out)
        else {
            continue;
        };
        let overrides = SourceOverrides {
            dismissal: entry.choice::<Dismissal>("dismissal"),
            color: entry.color("color").flatten(),
            sound: entry.string("sound"),
            desktop: entry.bool("desktop"),
        };
        out.append(&mut entry.diagnostics);
        prefs.sources.insert(source, overrides);
    }
    (prefs, out)
}

/// `feed.mirrorNotifications.{agents, terminal}` and `feed.agentPermissionPrompts`.
fn feed_mirror(root: &Value, out: &mut Vec<Diagnostic>) -> FeedMirror {
    let mut mirror = FeedMirror::default();
    if let Some(mut feed) = Reader::at(root, &["feed"], out) {
        if let Some(value) = feed.bool("agentPermissionPrompts") {
            mirror.agent_permission_prompts = value;
        }
        out.append(&mut feed.diagnostics);
    }
    let Some(mut reader) = Reader::at(root, &["feed", "mirrorNotifications"], out) else {
        return mirror;
    };
    if let Some(value) = reader.bool("agents") {
        mirror.agents = value;
    }
    if let Some(value) = reader.choice::<FeedTerminalMirror>("terminal") {
        mirror.terminal = value;
    }
    out.append(&mut reader.diagnostics);
    mirror
}

fn quiet_hours(root: &Value, out: &mut Vec<Diagnostic>) -> Option<QuietHours> {
    let value = value_at(root, &["notifications".to_owned(), "quietHours".to_owned()])?;
    if value.is_null() {
        return None;
    }
    let minutes = |key: &str| value.get(key).and_then(Value::as_str).and_then(QuietHours::minutes);
    let window = value.as_object().and(minutes("start").zip(minutes("end")));
    if window.is_none() {
        out.push(Diagnostic::invalid(
            "notifications.quietHours",
            "expected {\"start\": \"HH:MM\", \"end\": \"HH:MM\"}",
        ));
    }
    window.map(|(start, end)| QuietHours { start, end })
}

fn muted_workspaces(root: &Value, out: &mut Vec<Diagnostic>) -> std::collections::BTreeSet<String> {
    let path = "notifications.mutedWorkspaces";
    let Some(value) = value_at(root, &["notifications".to_owned(), "mutedWorkspaces".to_owned()])
    else {
        return Default::default();
    };
    let Some(items) = value.as_array() else {
        out.push(Diagnostic::invalid(path, "expected an array of workspace ids"));
        return Default::default();
    };
    let ids: Vec<String> = items
        .iter()
        .filter_map(Value::as_str)
        .filter(|id| !id.is_empty())
        .map(str::to_owned)
        .collect();
    if ids.len() != items.len() {
        out.push(Diagnostic::invalid(path, "expected workspace ids (non-empty strings)"));
    }
    ids.into_iter().collect()
}

fn event_names() -> String {
    SoundEvent::ALL.iter().map(|e| e.name()).collect::<Vec<_>>().join(", ")
}

/// `notifications.sounds`. A bad level rule is dropped and the other levels apply.
fn sounds(root: &Value, out: &mut Vec<Diagnostic>) -> SoundPreferences {
    let mut sounds = SoundPreferences::default();
    let Some(mut reader) = Reader::at(root, &["notifications", "sounds"], out) else {
        return sounds;
    };
    if let Some(value) = reader.number("volume", defaults::VOLUME_RANGE) {
        sounds.volume = value;
    }
    if let Some(value) = reader.number("maxSeconds", defaults::MAX_SECONDS_RANGE) {
        sounds.max_seconds = value;
    }
    if let Some(value) = reader.choice::<SoundTiming>("when") {
        sounds.when = value;
    }
    if let Some(value) = reader.number("cooldownSeconds", defaults::COOLDOWN_RANGE) {
        sounds.cooldown_seconds = value;
    }
    out.append(&mut reader.diagnostics);
    if let Some(mut events) = Reader::at(root, &["notifications", "sounds", "events"], out) {
        // serde_json's map is sorted, as Swift sorts the keys here.
        let names: Vec<String> = events.members.keys().cloned().collect();
        for name in names {
            let Some(event) = SoundEvent::from_name(&name) else {
                out.push(Diagnostic::invalid(
                    format!("notifications.sounds.events.{name}"),
                    format!("unknown event; expected one of {}", event_names()),
                ));
                continue;
            };
            if let Some(sound) = events.string(&name) {
                sounds.events.insert(event, sound);
            }
        }
        out.append(&mut events.diagnostics);
    }
    sounds.groups = rules(root, "groups", out);
    sounds.workspaces = rules(root, "workspaces", out);
    // Agent kinds are lowercased; of two keys that meet, the first in key order wins.
    for (name, rule) in rules(root, "agents", out) {
        sounds.agents.entry(name.to_lowercase()).or_insert(rule);
    }
    sounds
}

/// The rules of one level map (`notifications.sounds.<key>`), by id or name.
fn rules(root: &Value, key: &str, out: &mut Vec<Diagnostic>) -> BTreeMap<String, SoundRule> {
    let mut rules = BTreeMap::new();
    let Some(reader) = Reader::at(root, &["notifications", "sounds", key], out) else {
        return rules;
    };
    for (name, value) in reader.members {
        let (rule, problems) = parse_rule(value);
        for problem in problems {
            out.push(Diagnostic::invalid(format!("notifications.sounds.{key}.{name}"), problem));
        }
        if let Some(rule) = rule.filter(|rule| !rule.is_empty()) {
            rules.insert(name.clone(), rule);
        }
    }
    rules
}

/// The rule in `value` and the problems with it. A plain string is shorthand
/// for `{"sound": value}`; None when `value` is neither. A bad member is
/// dropped and the rest apply.
pub fn parse_rule(value: &Value) -> (Option<SoundRule>, Vec<String>) {
    let mut problems = Vec::new();
    if let Some(text) = value.as_str() {
        return (
            Some(SoundRule { sound: Some(text.to_owned()), ..SoundRule::default() }),
            problems,
        );
    }
    let Some(members) = value.as_object() else {
        problems.push("expected a sound name or {\"sound\", \"volume\", \"events\"}".to_owned());
        return (None, problems);
    };
    let mut rule = SoundRule::default();
    for (key, member) in members {
        match key.as_str() {
            "sound" => match member.as_str() {
                Some(text) => rule.sound = Some(text.to_owned()),
                None => problems.push("sound: expected a string".to_owned()),
            },
            "volume" => match member.as_f64().filter(|n| n.is_finite()) {
                Some(number) => {
                    rule.volume = Some(number.clamp(0.0, 1.0));
                    if !(0.0..=1.0).contains(&number) {
                        problems.push("volume: clamped to 0...1".to_owned());
                    }
                }
                None => problems.push("volume: expected a number from 0 to 1".to_owned()),
            },
            "events" => {
                let Some(events) = member.as_object() else {
                    problems.push("events: expected an object".to_owned());
                    continue;
                };
                for (name, sound) in events {
                    let Some(event) = SoundEvent::from_name(name) else {
                        problems.push(format!(
                            "events.{name}: unknown event; expected one of {}",
                            event_names()
                        ));
                        continue;
                    };
                    match sound.as_str() {
                        Some(text) => {
                            rule.events.insert(event, text.to_owned());
                        }
                        None => problems.push(format!("events.{name}: expected a string")),
                    }
                }
            }
            _ => problems.push(format!("{key}: unknown key")),
        }
    }
    (Some(rule), problems)
}

/// Whether `value` is a rule cmux.json can hold (the schema's check before a write).
pub fn rule_accepts(value: &Value) -> bool {
    matches!(parse_rule(value), (Some(_), problems) if problems.is_empty())
}
