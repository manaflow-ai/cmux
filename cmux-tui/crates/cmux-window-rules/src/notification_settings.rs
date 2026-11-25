//! `notifications.*` and `feed.mirrorNotifications` / `feed.agentPermissionPrompts`
//! in cmux.json, parsed: what the macOS app's `NotificationConfigParser`,
//! `NotificationConfigParser+Sounds`, `NotificationSoundRule.parse`,
//! `QuietHours.minutes` and `ThemeRGB(cssHex:)` decided. A bad value keeps
//! its default with a diagnostic (`kind` `invalidValue`, the dotted path, a
//! message worded as the Swift reader worded it); a bad level rule is dropped
//! and the other levels apply.
//!
//! The app sends the cmux.json root (`window_notifications_settings_parse`)
//! and builds its `NotificationPreferences` from the answer. Where Swift read
//! a dictionary in its unspecified order (a level map's names, a rule's
//! members), this reads them sorted, so the diagnostics come in one order.

use serde::Serialize;
use serde_json::{Map, Value};
use std::collections::{BTreeMap, BTreeSet};

/// `notifications.dismissal` and each source's: when attention clears on its own.
pub const DISMISSALS: [&str; 6] = ["focus", "keystroke", "click", "explicit", "timeout", "never"];
/// `notifications.desktop`: when a system banner posts.
pub const DESKTOP_MODES: [&str; 4] = ["unlessFocused", "always", "whenInactive", "never"];
/// `notifications.dockBounce`.
pub const DOCK_BOUNCES: [&str; 3] = ["off", "once", "untilActive"];
/// `notifications.showPreviews`.
pub const PREVIEWS: [&str; 3] = ["always", "whenUnlocked", "never"];
/// `notifications.toast.style` (`CmuxToastStyle`).
pub const TOAST_STYLES: [&str; 12] = [
    "standard",
    "capsule",
    "compact",
    "iconCard",
    "filledAction",
    "hoverClose",
    "progressRing",
    "trailing",
    "accentTinted",
    "solid",
    "flat",
    "v2",
];
/// `notifications.sounds.when`.
pub const SOUND_TIMINGS: [&str; 3] = ["unlessViewed", "whenInactive", "always"];
/// `feed.mirrorNotifications.terminal`.
pub const TERMINAL_MIRRORS: [&str; 3] = ["off", "title", "full"];
/// The notification sources, in Swift's `allCases` order (`notifications.sources.<source>`).
pub const SOURCES: [&str; 3] = ["cli", "terminal", "agent"];
/// The sound events, in Swift's `allCases` order.
pub const SOUND_EVENTS: [&str; 5] = ["finished", "needsInput", "error", "bell", "message"];

/// `notifications.timeoutSeconds`'s range (schemas/settings/source/notifications.json).
pub const TIMEOUT_RANGE: (f64, f64) = (1.0, 86400.0);
/// `notifications.suppressWhileTypingSeconds`'s range.
pub const TYPING_RANGE: (f64, f64) = (0.0, 60.0);
/// `notifications.sounds.volume`'s range.
pub const VOLUME_RANGE: (f64, f64) = (0.0, 1.0);
/// `notifications.sounds.maxSeconds`'s range.
pub const MAX_SECONDS_RANGE: (f64, f64) = (0.0, 30.0);
/// `notifications.sounds.cooldownSeconds`'s range.
pub const COOLDOWN_RANGE: (f64, f64) = (0.0, 60.0);

/// One bad value: where, and what was expected.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Diagnostic {
    /// Always `invalidValue` (`SettingsDiagnostic.Kind`).
    pub kind: &'static str,
    pub path: String,
    pub message: String,
}

impl Diagnostic {
    fn invalid(path: impl Into<String>, message: impl Into<String>) -> Self {
        Self { kind: "invalidValue", path: path.into(), message: message.into() }
    }
}

/// A `#RGB`, `#RRGGBB` or `#RRGGBBAA` color: `hex` is `0xRRGGBB`, `alpha` 0 to 1.
#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
pub struct Rgb {
    pub hex: u32,
    pub alpha: f64,
}

/// `ThemeRGB(cssHex:)`: the `#` is optional, blanks around it (`CharacterSet.whitespaces`: tabs
/// and space separators, not line breaks) are trimmed; nil for anything else.
pub fn css_hex(text: &str) -> Option<Rgb> {
    let trimmed = text.trim_matches(|c: char| {
        c.is_whitespace()
            && !matches!(c, '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}')
    });
    let digits = trimmed.strip_prefix('#').unwrap_or(trimmed);
    let count = digits.chars().count();
    if ![3, 6, 8].contains(&count) || !digits.chars().all(|c| c.is_ascii_hexdigit()) {
        return None;
    }
    let mut value = u64::from_str_radix(digits, 16).ok()?;
    if count == 3 {
        let (r, g, b) = ((value >> 8) & 0xF, (value >> 4) & 0xF, value & 0xF);
        value = ((r * 17) << 16) | ((g * 17) << 8) | (b * 17);
    }
    let alpha = if count == 8 { (value & 0xFF) as f64 / 255.0 } else { 1.0 };
    if count == 8 {
        value >>= 8;
    }
    Some(Rgb { hex: value as u32, alpha })
}

/// `QuietHours.minutes`: `"HH:MM"` as minutes after midnight. As Swift's `split(separator:)`,
/// empty pieces are skipped (`"12::30"` reads as 12:30) and a number may carry a sign.
pub fn quiet_hours_minutes(text: &str) -> Option<i64> {
    let parts: Vec<&str> = text.split(':').filter(|part| !part.is_empty()).collect();
    let [hour, minute] = parts.as_slice() else { return None };
    let (hour, minute) = (swift_int(hour)?, swift_int(minute)?);
    ((0..=23).contains(&hour) && (0..=59).contains(&minute)).then_some(hour * 60 + minute)
}

/// Swift's `Int(String)`: optional sign, ASCII digits only.
fn swift_int(text: &str) -> Option<i64> {
    let digits = text.strip_prefix(['+', '-']).unwrap_or(text);
    if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    text.parse().ok()
}

/// A daily quiet window, minutes after midnight.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
pub struct QuietHours {
    pub start: i64,
    pub end: i64,
}

/// One level's sound choices (`NotificationSoundRule`); every field absent inherits.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct SoundRule {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sound: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub volume: Option<f64>,
    pub events: BTreeMap<String, String>,
}

impl SoundRule {
    /// Every field inherits: the level can be removed from cmux.json.
    pub fn is_empty(&self) -> bool {
        self.sound.is_none() && self.volume.is_none() && self.events.is_empty()
    }
}

fn unknown_event_message() -> String {
    format!("unknown event; expected one of {}", SOUND_EVENTS.join(", "))
}

/// `NotificationSoundRule.parse`: a plain string is `{"sound": value}`; nil, with a problem, when
/// `value` is neither a string nor an object; a bad member is dropped with a problem and the rest
/// apply. Members are read in sorted order.
pub fn parse_sound_rule(value: &Value, problems: &mut Vec<String>) -> Option<SoundRule> {
    if let Some(text) = value.as_str() {
        return Some(SoundRule { sound: Some(text.to_owned()), ..SoundRule::default() });
    }
    let Some(members) = value.as_object() else {
        problems.push("expected a sound name or {\"sound\", \"volume\", \"events\"}".to_owned());
        return None;
    };
    let mut rule = SoundRule::default();
    for (key, member) in sorted(members) {
        match key.as_str() {
            "sound" => match member.as_str() {
                Some(text) => rule.sound = Some(text.to_owned()),
                None => problems.push("sound: expected a string".to_owned()),
            },
            "volume" => match member.as_f64().filter(|number| number.is_finite()) {
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
                for (name, sound) in sorted(events) {
                    if !SOUND_EVENTS.contains(&name.as_str()) {
                        problems.push(format!("events.{name}: {}", unknown_event_message()));
                        continue;
                    }
                    match sound.as_str() {
                        Some(text) => {
                            rule.events.insert(name.clone(), text.to_owned());
                        }
                        None => problems.push(format!("events.{name}: expected a string")),
                    }
                }
            }
            _ => problems.push(format!("{key}: unknown key")),
        }
    }
    Some(rule)
}

/// `NotificationSoundRule.accepts`: a rule cmux.json can hold (parses with no problem).
pub fn accepts_sound_rule(value: &Value) -> bool {
    let mut problems = Vec::new();
    parse_sound_rule(value, &mut problems).is_some() && problems.is_empty()
}

/// `notifications.sounds` (`NotificationSoundPreferences`).
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SoundPrefs {
    pub volume: f64,
    pub max_seconds: f64,
    pub when: String,
    pub cooldown_seconds: f64,
    pub events: BTreeMap<String, String>,
    pub groups: BTreeMap<String, SoundRule>,
    pub workspaces: BTreeMap<String, SoundRule>,
    /// Keyed lowercased.
    pub agents: BTreeMap<String, SoundRule>,
}

impl Default for SoundPrefs {
    fn default() -> Self {
        Self {
            volume: 1.0,
            max_seconds: 0.0,
            when: "unlessViewed".to_owned(),
            cooldown_seconds: 1.5,
            events: BTreeMap::new(),
            groups: BTreeMap::new(),
            workspaces: BTreeMap::new(),
            agents: BTreeMap::new(),
        }
    }
}

/// One source's overrides (`NotificationSourceOverrides`); absent keeps the global value.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct SourceOverrides {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub dismissal: Option<String>,
    /// A `#RRGGBB` color; absent: the theme's (`null`, `"theme"`, or no key).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub color: Option<Rgb>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sound: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub desktop: Option<bool>,
}

/// `feed.mirrorNotifications` and `feed.agentPermissionPrompts` (`FeedMirrorPreferences`).
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FeedMirror {
    pub agents: bool,
    pub terminal: String,
    pub agent_permission_prompts: bool,
}

impl Default for FeedMirror {
    fn default() -> Self {
        Self { agents: true, terminal: "off".to_owned(), agent_permission_prompts: false }
    }
}

/// Everything under `notifications` the app applies (`NotificationPreferences`).
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Prefs {
    pub dismissal: String,
    pub timeout_seconds: f64,
    pub desktop: String,
    pub sound: String,
    pub sounds: SoundPrefs,
    pub quiet_hours: Option<QuietHours>,
    pub suppress_while_typing_seconds: f64,
    pub dock_badge: bool,
    pub dock_bounce: String,
    pub show_previews: String,
    pub toast_style: String,
    pub muted_workspaces: BTreeSet<String>,
    pub sources: BTreeMap<String, SourceOverrides>,
    pub feed_mirror: FeedMirror,
}

impl Default for Prefs {
    fn default() -> Self {
        Self {
            dismissal: "focus".to_owned(),
            timeout_seconds: 30.0,
            desktop: "unlessFocused".to_owned(),
            sound: "default".to_owned(),
            sounds: SoundPrefs::default(),
            quiet_hours: None,
            suppress_while_typing_seconds: 0.0,
            dock_badge: true,
            dock_bounce: "once".to_owned(),
            show_previews: "whenUnlocked".to_owned(),
            toast_style: "standard".to_owned(),
            muted_workspaces: BTreeSet::new(),
            sources: BTreeMap::new(),
            feed_mirror: FeedMirror::default(),
        }
    }
}

/// The parse: the preferences and every bad value's diagnostic, in the Swift parser's order.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Parsed {
    pub prefs: Prefs,
    pub diagnostics: Vec<Diagnostic>,
}

fn sorted(members: &Map<String, Value>) -> Vec<(&String, &Value)> {
    let mut entries: Vec<_> = members.iter().collect();
    entries.sort_by(|a, b| a.0.cmp(b.0));
    entries
}

fn value_at<'a>(root: &'a Value, path: &[&str]) -> Option<&'a Value> {
    path.iter().try_fold(root, |value, key| value.as_object()?.get(*key))
}

/// Swift's `Double.description` for a range bound (`1.0`, `86400.0`, `0.5`).
fn swift_double(value: f64) -> String {
    if value.fract() == 0.0 && value.abs() < 1e16 {
        format!("{value:.1}")
    } else {
        format!("{value}")
    }
}

/// `ConfigFieldReader`: one cmux.json object's typed fields; each bad value records a diagnostic
/// in `diagnostics` (appended to the parse's where the Swift reader appended its own).
struct Reader<'a> {
    members: &'a Map<String, Value>,
    path: String,
    diagnostics: Vec<Diagnostic>,
}

impl<'a> Reader<'a> {
    /// The object at `path`, or nil (with a diagnostic when it is not an object).
    fn at(root: &'a Value, path: &[&str], diagnostics: &mut Vec<Diagnostic>) -> Option<Self> {
        let value = value_at(root, path)?;
        let dotted = path.join(".");
        let Some(members) = value.as_object() else {
            diagnostics.push(Diagnostic::invalid(dotted, "expected an object"));
            return None;
        };
        Some(Self { members, path: dotted, diagnostics: Vec::new() })
    }

    fn fail(&mut self, key: &str, message: impl Into<String>) {
        self.diagnostics.push(Diagnostic::invalid(format!("{}.{key}", self.path), message));
    }

    fn bool(&mut self, key: &str) -> Option<bool> {
        let value = self.members.get(key)?;
        let parsed = value.as_bool();
        if parsed.is_none() {
            self.fail(key, "expected true or false");
        }
        parsed
    }

    fn number(&mut self, key: &str, (low, high): (f64, f64)) -> Option<f64> {
        let value = self.members.get(key)?;
        let Some(number) = value.as_f64().filter(|number| number.is_finite()) else {
            self.fail(key, "expected a number");
            return None;
        };
        if !(low..=high).contains(&number) {
            self.fail(key, format!("clamped to {}...{}", swift_double(low), swift_double(high)));
        }
        Some(number.clamp(low, high))
    }

    fn choice(&mut self, key: &str, cases: &[&str]) -> Option<String> {
        let value = self.members.get(key)?;
        match value.as_str().filter(|text| cases.contains(text)) {
            Some(text) => Some(text.to_owned()),
            None => {
                let listed: Vec<String> = cases.iter().map(|case| format!("\"{case}\"")).collect();
                self.fail(key, format!("expected one of {}", listed.join(", ")));
                None
            }
        }
    }

    /// A `#RRGGBB` color; `null` or `"theme"` mean the theme default (`Some(None)`).
    fn color(&mut self, key: &str) -> Option<Option<Rgb>> {
        let value = self.members.get(key)?;
        if value.is_null() {
            return Some(None);
        }
        let Some(text) = value.as_str() else {
            self.fail(key, "expected a #RRGGBB color");
            return None;
        };
        if text == "theme" {
            return Some(None);
        }
        match css_hex(text) {
            Some(color) => Some(Some(color)),
            None => {
                self.fail(key, "expected a #RRGGBB color");
                None
            }
        }
    }

    fn string(&mut self, key: &str) -> Option<String> {
        let value = self.members.get(key)?;
        let parsed = value.as_str().map(str::to_owned);
        if parsed.is_none() {
            self.fail(key, "expected a string");
        }
        parsed
    }
}

/// `NotificationConfigParser.parse`: `notifications.*` and the feed mirror from the cmux.json root.
pub fn parse(root: &Value) -> Parsed {
    let mut diagnostics = Vec::new();
    let mut prefs = Prefs { feed_mirror: feed_mirror(root, &mut diagnostics), ..Prefs::default() };
    let Some(mut reader) = Reader::at(root, &["notifications"], &mut diagnostics) else {
        return Parsed { prefs, diagnostics };
    };
    if let Some(value) = reader.choice("dismissal", &DISMISSALS) {
        prefs.dismissal = value;
    }
    if let Some(value) = reader.number("timeoutSeconds", TIMEOUT_RANGE) {
        prefs.timeout_seconds = value;
    }
    if let Some(value) = reader.choice("desktop", &DESKTOP_MODES) {
        prefs.desktop = value;
    }
    if let Some(value) = reader.string("sound") {
        prefs.sound = value;
    }
    if let Some(value) = reader.number("suppressWhileTypingSeconds", TYPING_RANGE) {
        prefs.suppress_while_typing_seconds = value;
    }
    if let Some(value) = reader.bool("dockBadge") {
        prefs.dock_badge = value;
    }
    if let Some(value) = reader.choice("dockBounce", &DOCK_BOUNCES) {
        prefs.dock_bounce = value;
    }
    if let Some(value) = reader.choice("showPreviews", &PREVIEWS) {
        prefs.show_previews = value;
    }
    diagnostics.append(&mut reader.diagnostics);
    if let Some(mut toast) = Reader::at(root, &["notifications", "toast"], &mut diagnostics) {
        if let Some(value) = toast.choice("style", &TOAST_STYLES) {
            prefs.toast_style = value;
        }
        diagnostics.append(&mut toast.diagnostics);
    }
    prefs.quiet_hours = quiet_hours(root, &mut diagnostics);
    prefs.muted_workspaces = muted_workspaces(root, &mut diagnostics);
    prefs.sounds = sounds(root, &mut diagnostics);
    for source in SOURCES {
        let Some(mut entry) =
            Reader::at(root, &["notifications", "sources", source], &mut diagnostics)
        else {
            continue;
        };
        let overrides = SourceOverrides {
            dismissal: entry.choice("dismissal", &DISMISSALS),
            color: entry.color("color").flatten(),
            sound: entry.string("sound"),
            desktop: entry.bool("desktop"),
        };
        diagnostics.append(&mut entry.diagnostics);
        prefs.sources.insert(source.to_owned(), overrides);
    }
    Parsed { prefs, diagnostics }
}

/// `feed.mirrorNotifications.{agents, terminal}` and `feed.agentPermissionPrompts`.
pub fn feed_mirror(root: &Value, diagnostics: &mut Vec<Diagnostic>) -> FeedMirror {
    let mut mirror = FeedMirror::default();
    if let Some(mut feed) = Reader::at(root, &["feed"], diagnostics) {
        if let Some(value) = feed.bool("agentPermissionPrompts") {
            mirror.agent_permission_prompts = value;
        }
        diagnostics.append(&mut feed.diagnostics);
    }
    let Some(mut reader) = Reader::at(root, &["feed", "mirrorNotifications"], diagnostics) else {
        return mirror;
    };
    if let Some(value) = reader.bool("agents") {
        mirror.agents = value;
    }
    if let Some(value) = reader.choice("terminal", &TERMINAL_MIRRORS) {
        mirror.terminal = value;
    }
    diagnostics.append(&mut reader.diagnostics);
    mirror
}

fn quiet_hours(root: &Value, diagnostics: &mut Vec<Diagnostic>) -> Option<QuietHours> {
    let value = value_at(root, &["notifications", "quietHours"])?;
    if value.is_null() {
        return None;
    }
    let read = |key: &str| value.as_object()?.get(key)?.as_str().and_then(quiet_hours_minutes);
    match (read("start"), read("end")) {
        (Some(start), Some(end)) => Some(QuietHours { start, end }),
        _ => {
            diagnostics.push(Diagnostic::invalid(
                "notifications.quietHours",
                "expected {\"start\": \"HH:MM\", \"end\": \"HH:MM\"}",
            ));
            None
        }
    }
}

fn muted_workspaces(root: &Value, diagnostics: &mut Vec<Diagnostic>) -> BTreeSet<String> {
    let Some(value) = value_at(root, &["notifications", "mutedWorkspaces"]) else {
        return BTreeSet::new();
    };
    let Some(items) = value.as_array() else {
        diagnostics.push(Diagnostic::invalid(
            "notifications.mutedWorkspaces",
            "expected an array of workspace ids",
        ));
        return BTreeSet::new();
    };
    // A bad item is dropped with a diagnostic; the valid ids still apply.
    let ids: Vec<&str> =
        items.iter().filter_map(Value::as_str).filter(|id| !id.is_empty()).collect();
    if ids.len() != items.len() {
        diagnostics.push(Diagnostic::invalid(
            "notifications.mutedWorkspaces",
            "expected workspace ids (non-empty strings)",
        ));
    }
    ids.into_iter().map(str::to_owned).collect()
}

/// `notifications.sounds`.
pub fn sounds(root: &Value, diagnostics: &mut Vec<Diagnostic>) -> SoundPrefs {
    let mut sounds = SoundPrefs::default();
    let Some(mut reader) = Reader::at(root, &["notifications", "sounds"], diagnostics) else {
        return sounds;
    };
    if let Some(value) = reader.number("volume", VOLUME_RANGE) {
        sounds.volume = value;
    }
    if let Some(value) = reader.number("maxSeconds", MAX_SECONDS_RANGE) {
        sounds.max_seconds = value;
    }
    if let Some(value) = reader.choice("when", &SOUND_TIMINGS) {
        sounds.when = value;
    }
    if let Some(value) = reader.number("cooldownSeconds", COOLDOWN_RANGE) {
        sounds.cooldown_seconds = value;
    }
    diagnostics.append(&mut reader.diagnostics);
    if let Some(mut events) = Reader::at(root, &["notifications", "sounds", "events"], diagnostics)
    {
        let names: Vec<String> = events.members.keys().cloned().collect();
        let mut sorted_names = names;
        sorted_names.sort();
        for name in sorted_names {
            if !SOUND_EVENTS.contains(&name.as_str()) {
                diagnostics.push(Diagnostic::invalid(
                    format!("notifications.sounds.events.{name}"),
                    unknown_event_message(),
                ));
                continue;
            }
            if let Some(sound) = events.string(&name) {
                sounds.events.insert(name, sound);
            }
        }
        diagnostics.append(&mut events.diagnostics);
    }
    sounds.groups = rules(root, "groups", diagnostics);
    sounds.workspaces = rules(root, "workspaces", diagnostics);
    // Lowercased; of two names that lowercase alike, the first in sorted order wins.
    for (name, rule) in rules(root, "agents", diagnostics) {
        sounds.agents.entry(name.to_lowercase()).or_insert(rule);
    }
    sounds
}

/// The rules of one level map (`notifications.sounds.<key>`), by id or name; an empty rule is dropped.
fn rules(
    root: &Value,
    key: &str,
    diagnostics: &mut Vec<Diagnostic>,
) -> BTreeMap<String, SoundRule> {
    let mut rules = BTreeMap::new();
    let Some(reader) = Reader::at(root, &["notifications", "sounds", key], diagnostics) else {
        return rules;
    };
    for (name, value) in sorted(reader.members) {
        let mut problems = Vec::new();
        let rule = parse_sound_rule(value, &mut problems);
        for problem in problems {
            diagnostics
                .push(Diagnostic::invalid(format!("notifications.sounds.{key}.{name}"), problem));
        }
        if let Some(rule) = rule.filter(|rule| !rule.is_empty()) {
            rules.insert(name.clone(), rule);
        }
    }
    rules
}

#[cfg(test)]
#[path = "notification_settings_tests.rs"]
mod tests;
