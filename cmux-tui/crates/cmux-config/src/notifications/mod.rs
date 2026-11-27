//! `notifications.*` and `feed.mirrorNotifications` in cmux.json: the
//! preferences, their parse, and the notification rules the Mac app applies
//! (Swift `NotificationPreferences`, `NotificationConfigParser`,
//! `NotificationPolicy`, `NotificationSoundPreferences`, `NotificationSoundRule`,
//! `NotificationSoundThrottle`, `QuietHours`, `NotificationWorkspaceKey`).
//!
//! Everything here is pure: the clock comes in as a number (seconds on any
//! monotonic clock for the sound cooldown, the local minute of the day for
//! quiet hours). Swift keeps only what plays a sound or posts a banner.
//! The ops are [`crate::app_ops::notifications`].

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};

/// A setting whose value is one of a fixed list of names (a Swift `String`
/// enum); `ALL` is in the Swift declaration order, which diagnostics list.
pub trait Choice: Sized + Copy + 'static {
    const ALL: &'static [Self];
    fn name(self) -> &'static str;
    fn from_name(text: &str) -> Option<Self> {
        Self::ALL.iter().copied().find(|choice| choice.name() == text)
    }
}

macro_rules! choice {
    ($(#[$meta:meta])* $name:ident { $($variant:ident = $raw:literal),+ $(,)? } default $default:ident) => {
        $(#[$meta])*
        #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
        pub enum $name { $($variant),+ }

        impl Choice for $name {
            const ALL: &'static [Self] = &[$($name::$variant),+];
            fn name(self) -> &'static str {
                match self { $($name::$variant => $raw),+ }
            }
        }

        impl Default for $name {
            fn default() -> Self {
                $name::$default
            }
        }

        impl ::serde::Serialize for $name {
            fn serialize<S: ::serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
                serializer.serialize_str(self.name())
            }
        }

        impl<'de> ::serde::Deserialize<'de> for $name {
            fn deserialize<D: ::serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
                let text = <String as ::serde::Deserialize>::deserialize(deserializer)?;
                Self::from_name(&text).ok_or_else(|| {
                    ::serde::de::Error::custom(format!("unknown {} `{text}`", stringify!($name)))
                })
            }
        }
    };
}

mod parse;
mod policy;
mod sounds;
mod workspace_key;

pub use parse::{Diagnostic, parse, parse_rule, rule_accepts};
pub use policy::{
    Arrival, Decision, Trigger, agent_kind, clears, clears_mode, decide, flashes_on_entry, level_of,
};
pub use sounds::{
    Last, SoundChoice, SoundEdit, SoundLevel, admit, apply_rule, checked_sound, edit_sounds,
    preview_choice, source_of_event,
};
pub use workspace_key::{
    legacy_remote_key, mutes, qualified, rule_key, settings_key, workspace_ids,
};

choice!(
    /// When a notification's attention clears on its own (`notifications.dismissal`).
    Dismissal {
        Focus = "focus", Keystroke = "keystroke", Click = "click", Explicit = "explicit",
        Timeout = "timeout", Never = "never",
    } default Focus
);

choice!(
    /// When a macOS banner is posted (`notifications.desktop`).
    DesktopMode {
        UnlessFocused = "unlessFocused", Always = "always", WhenInactive = "whenInactive",
        Never = "never",
    } default UnlessFocused
);

choice!(
    /// `notifications.dockBounce`.
    DockBounce { Off = "off", Once = "once", UntilActive = "untilActive" } default Once
);

choice!(
    /// `notifications.showPreviews` (Swift `NotificationPreviews`).
    Previews { Always = "always", WhenUnlocked = "whenUnlocked", Never = "never" } default WhenUnlocked
);

choice!(
    /// `notifications.toast.style` (Swift `CmuxToastStyle`).
    ToastStyle {
        Standard = "standard", Capsule = "capsule", Compact = "compact", IconCard = "iconCard",
        FilledAction = "filledAction", HoverClose = "hoverClose", ProgressRing = "progressRing",
        Trailing = "trailing", AccentTinted = "accentTinted", Solid = "solid", Flat = "flat",
        V2 = "v2",
    } default Standard
);

choice!(
    /// `feed.mirrorNotifications.terminal`.
    FeedTerminalMirror { Off = "off", Title = "title", Full = "full" } default Off
);

choice!(
    /// `notifications.sounds.when`.
    SoundTiming { UnlessViewed = "unlessViewed", WhenInactive = "whenInactive", Always = "always" }
        default UnlessViewed
);

choice!(
    /// Where a notification came from (`notifications.sources.<source>`).
    Source { Cli = "cli", Terminal = "terminal", Agent = "agent" } default Agent
);

choice!(
    /// What a notification is about, for its sound.
    SoundEvent {
        Finished = "finished", NeedsInput = "needsInput", Error = "error", Bell = "bell",
        Message = "message",
    } default Message
);

choice!(
    /// A notification's level as the daemon sends it.
    Level { Info = "info", Warning = "warning", Error = "error" } default Info
);

impl Source {
    /// The source a daemon sends; `daemon` producers and old daemons count as agent.
    pub fn from_wire(wire: Option<&str>) -> Source {
        wire.and_then(Source::from_name).unwrap_or(Source::Agent)
    }
}

impl SoundTiming {
    /// Whether a sound plays for a pane that is `viewed`, while cmux is `app_active` or not.
    pub fn plays(self, viewed: bool, app_active: bool) -> bool {
        match self {
            SoundTiming::UnlessViewed => !viewed,
            SoundTiming::WhenInactive => !app_active,
            SoundTiming::Always => true,
        }
    }
}

impl SoundEvent {
    /// How loud the event is in a burst: a more urgent event passes the cooldown.
    pub fn urgency(self) -> i64 {
        match self {
            SoundEvent::NeedsInput => 3,
            SoundEvent::Error => 2,
            SoundEvent::Finished | SoundEvent::Message => 1,
            SoundEvent::Bell => 0,
        }
    }

    /// The event of a notification from `source` at `level`.
    pub fn of(source: Source, level: Level) -> SoundEvent {
        match (source, level) {
            (_, Level::Error) => SoundEvent::Error,
            (Source::Agent | Source::Cli, Level::Warning) => SoundEvent::NeedsInput,
            (Source::Agent, Level::Info) => SoundEvent::Finished,
            (Source::Terminal, _) => SoundEvent::Bell,
            (Source::Cli, Level::Info) => SoundEvent::Message,
        }
    }
}

/// The ranges and defaults (schemas/settings/source/notifications.json).
pub mod defaults {
    pub const TIMEOUT: f64 = 30.0;
    pub const TIMEOUT_RANGE: (f64, f64) = (1.0, 86400.0);
    pub const SOUND: &str = "default";
    pub const TYPING: f64 = 0.0;
    pub const TYPING_RANGE: (f64, f64) = (0.0, 60.0);
    pub const DOCK_BADGE: bool = true;
    pub const VOLUME: f64 = 1.0;
    pub const VOLUME_RANGE: (f64, f64) = (0.0, 1.0);
    pub const MAX_SECONDS: f64 = 0.0;
    pub const MAX_SECONDS_RANGE: (f64, f64) = (0.0, 30.0);
    pub const COOLDOWN: f64 = 1.5;
    pub const COOLDOWN_RANGE: (f64, f64) = (0.0, 60.0);
    pub const FEED_AGENTS: bool = true;
    pub const FEED_PERMISSION_PROMPTS: bool = false;
}

/// A daily window (local minutes after midnight) in which banners and sounds stay quiet.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct QuietHours {
    pub start: i64,
    pub end: i64,
}

impl QuietHours {
    /// Parses `"HH:MM"`. Like Swift's `split(separator:)`, empty parts are skipped.
    pub fn minutes(text: &str) -> Option<i64> {
        let parts: Vec<&str> = text.split(':').filter(|part| !part.is_empty()).collect();
        let [hour, minute] = parts.as_slice() else { return None };
        let (hour, minute) = (hour.parse::<i64>().ok()?, minute.parse::<i64>().ok()?);
        ((0..=23).contains(&hour) && (0..=59).contains(&minute)).then_some(hour * 60 + minute)
    }

    /// True when `minute_of_day` lies in the window; a window may wrap past midnight.
    pub fn contains(&self, minute_of_day: i64) -> bool {
        if self.start == self.end {
            return false;
        }
        if self.start < self.end {
            (self.start..self.end).contains(&minute_of_day)
        } else {
            minute_of_day >= self.start || minute_of_day < self.end
        }
    }
}

/// One level's sound choices; as cmux.json writes it (nil fields left out).
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct SoundRule {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sound: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub volume: Option<f64>,
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    pub events: BTreeMap<SoundEvent, String>,
}

impl SoundRule {
    /// True when every field inherits: the level can be removed from cmux.json.
    pub fn is_empty(&self) -> bool {
        self.sound.is_none() && self.volume.is_none() && self.events.is_empty()
    }

    /// The sound this level sets for `event`: its event's own, else its `sound`.
    pub fn sound_for(&self, event: SoundEvent) -> Option<&str> {
        self.events.get(&event).or(self.sound.as_ref()).map(String::as_str)
    }
}

/// `notifications.sounds`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct SoundPreferences {
    pub volume: f64,
    pub max_seconds: f64,
    pub when: SoundTiming,
    pub cooldown_seconds: f64,
    pub events: BTreeMap<SoundEvent, String>,
    pub groups: BTreeMap<String, SoundRule>,
    pub workspaces: BTreeMap<String, SoundRule>,
    pub agents: BTreeMap<String, SoundRule>,
}

impl Default for SoundPreferences {
    fn default() -> Self {
        SoundPreferences {
            volume: defaults::VOLUME,
            max_seconds: defaults::MAX_SECONDS,
            when: SoundTiming::default(),
            cooldown_seconds: defaults::COOLDOWN,
            events: BTreeMap::new(),
            groups: BTreeMap::new(),
            workspaces: BTreeMap::new(),
            agents: BTreeMap::new(),
        }
    }
}

/// One group a workspace sits in.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Group {
    pub id: String,
    pub name: String,
}

/// Where a notification comes from, for its sound.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct SoundScope {
    pub agent: Option<String>,
    pub workspace: Option<String>,
    /// Innermost first.
    pub groups: Vec<Group>,
}

/// `notifications.sources.<source>`; nil keeps the global value.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct SourceOverrides {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub dismissal: Option<Dismissal>,
    /// `#RRGGBB` (or `#RRGGBBAA`), uppercase; nil is the theme's.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub color: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sound: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub desktop: Option<bool>,
}

/// `feed.mirrorNotifications` and `feed.agentPermissionPrompts`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct FeedMirror {
    pub agents: bool,
    pub terminal: FeedTerminalMirror,
    pub agent_permission_prompts: bool,
}

impl Default for FeedMirror {
    fn default() -> Self {
        FeedMirror {
            agents: defaults::FEED_AGENTS,
            terminal: FeedTerminalMirror::default(),
            agent_permission_prompts: defaults::FEED_PERMISSION_PROMPTS,
        }
    }
}

/// Everything under `notifications` that the app applies.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Preferences {
    pub dismissal: Dismissal,
    pub timeout_seconds: f64,
    pub desktop: DesktopMode,
    pub sound: String,
    pub sounds: SoundPreferences,
    pub quiet_hours: Option<QuietHours>,
    pub suppress_while_typing_seconds: f64,
    pub dock_badge: bool,
    pub dock_bounce: DockBounce,
    pub show_previews: Previews,
    pub toast_style: ToastStyle,
    pub muted_workspaces: BTreeSet<String>,
    pub sources: BTreeMap<Source, SourceOverrides>,
    pub feed_mirror: FeedMirror,
}

impl Default for Preferences {
    fn default() -> Self {
        Preferences {
            dismissal: Dismissal::default(),
            timeout_seconds: defaults::TIMEOUT,
            desktop: DesktopMode::default(),
            sound: defaults::SOUND.to_owned(),
            sounds: SoundPreferences::default(),
            quiet_hours: None,
            suppress_while_typing_seconds: defaults::TYPING,
            dock_badge: defaults::DOCK_BADGE,
            dock_bounce: DockBounce::default(),
            show_previews: Previews::default(),
            toast_style: ToastStyle::default(),
            muted_workspaces: BTreeSet::new(),
            sources: BTreeMap::new(),
            feed_mirror: FeedMirror::default(),
        }
    }
}

impl Preferences {
    pub fn dismissal_for(&self, source: Source) -> Dismissal {
        self.sources.get(&source).and_then(|o| o.dismissal).unwrap_or(self.dismissal)
    }

    pub fn sound_for(&self, source: Source) -> &str {
        self.sources.get(&source).and_then(|o| o.sound.as_deref()).unwrap_or(&self.sound)
    }

    pub fn posts_desktop(&self, source: Source) -> bool {
        self.sources.get(&source).and_then(|o| o.desktop).unwrap_or(true)
    }
}

#[cfg(test)]
#[path = "tests.rs"]
mod tests;

#[cfg(test)]
#[path = "policy_tests.rs"]
mod policy_tests;
