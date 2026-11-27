//! What a notification does when it arrives and when its attention clears
//! (plans/cmux-next/notifications.md): the read-on-sight, typing, quiet-hours
//! and muted-workspace rules, the banner, Dock bounce and timeout, the sound
//! a notification plays and how loud (agent kind, then workspace, then each
//! group from the innermost out, then the event's global sound, then the
//! source's), and the burst cooldown that keeps ten finishing agents from
//! stacking ten sounds.
//!
//! The rules were the Swift `NotificationPolicy`, `NotificationSoundPreferences.choice`
//! and `NotificationSoundThrottle` of the macOS app; the app now sends the
//! facts (`window_notifications_decide`, `window_notifications_clears_table`,
//! `window_notifications_sound_admit`) and applies the answer: the banner,
//! the ring, the sound. The daemon owns unread state; these rules only decide
//! when the app acknowledges it and what an arrival shows.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

/// A user interaction with a pane that has an unread notification.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Trigger {
    /// The pane became the focused pane of the key window while cmux is active.
    Focus,
    /// A mouse-down in the pane.
    Click,
    /// A key typed into the pane's terminal or page (not an app shortcut).
    Keystroke,
    /// The notification was opened: jump to unread, a banner click, Open Notification.
    Open,
    /// The `timeout` dismissal deadline passed.
    Timeout,
}

impl Trigger {
    pub const ALL: [Trigger; 5] =
        [Trigger::Focus, Trigger::Click, Trigger::Keystroke, Trigger::Open, Trigger::Timeout];
}

/// When a notification's attention clears on its own (`notifications.dismissal`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Dismissal {
    /// The pane is selected, clicked, typed in, or opened (the default, as in cmux classic).
    #[default]
    Focus,
    Keystroke,
    Click,
    Explicit,
    Timeout,
    Never,
}

impl Dismissal {
    pub const ALL: [Dismissal; 6] = [
        Dismissal::Focus,
        Dismissal::Keystroke,
        Dismissal::Click,
        Dismissal::Explicit,
        Dismissal::Timeout,
        Dismissal::Never,
    ];
}

/// When a macOS banner is posted (`notifications.desktop`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Desktop {
    #[default]
    UnlessFocused,
    Always,
    WhenInactive,
    Never,
}

/// Whether the Dock icon bounces on an alert while cmux is inactive (`notifications.dockBounce`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum DockBounce {
    Off,
    #[default]
    Once,
    UntilActive,
}

/// When a notification plays its sound (`notifications.sounds.when`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum SoundTiming {
    /// Unless the notifying pane is the one in front of the person.
    #[default]
    UnlessViewed,
    WhenInactive,
    Always,
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

/// Where a notification came from.
#[derive(
    Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash, Deserialize, Serialize,
)]
#[serde(rename_all = "camelCase")]
pub enum Source {
    /// `cmux notify` and the `notification.create*` socket methods.
    Cli,
    /// A terminal program: OSC 9, OSC 777 or OSC 99.
    Terminal,
    /// An agent hook or any daemon-side producer.
    #[default]
    Agent,
}

/// The level of a notification, as the daemon sends it.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Level {
    #[default]
    Info,
    Warning,
    Error,
}

/// What a notification is about, for its sound.
#[derive(
    Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash, Deserialize, Serialize,
)]
#[serde(rename_all = "camelCase")]
pub enum SoundEvent {
    /// An agent finished its turn.
    Finished,
    /// An agent asks: a permission prompt, a question, a plan review.
    NeedsInput,
    /// Something failed.
    Error,
    /// A terminal program's own notification.
    Bell,
    /// `cmux notify` and every other message.
    #[default]
    Message,
}

impl SoundEvent {
    /// How loud the event is in a burst: the cooldown lets a more urgent event through.
    pub fn urgency(self) -> u8 {
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

/// One level's sound choices; every field absent inherits from the level above.
#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SoundRule {
    pub sound: Option<String>,
    pub volume: Option<f64>,
    pub events: BTreeMap<SoundEvent, String>,
}

impl SoundRule {
    /// The sound this level sets for `event`: its event's own, else its `sound`.
    pub fn sound_for(&self, event: SoundEvent) -> Option<&str> {
        self.events.get(&event).or(self.sound.as_ref()).map(String::as_str)
    }
}

/// One group the workspace sits in.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Group {
    pub id: String,
    pub name: String,
}

/// Where a notification comes from, for its sound.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SoundScope {
    /// The agent kind, lowercased.
    pub agent: Option<String>,
    pub workspace: Option<String>,
    /// Innermost first.
    pub groups: Vec<Group>,
}

/// `notifications.sounds`.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SoundPrefs {
    pub volume: f64,
    pub when: SoundTiming,
    pub events: BTreeMap<SoundEvent, String>,
    pub groups: BTreeMap<String, SoundRule>,
    pub workspaces: BTreeMap<String, SoundRule>,
    pub agents: BTreeMap<String, SoundRule>,
}

impl Default for SoundPrefs {
    fn default() -> Self {
        SoundPrefs {
            volume: 1.0,
            when: SoundTiming::default(),
            events: BTreeMap::new(),
            groups: BTreeMap::new(),
            workspaces: BTreeMap::new(),
            agents: BTreeMap::new(),
        }
    }
}

/// The sound a notification plays and how loud.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SoundChoice {
    pub name: String,
    /// 0 to 1: the deciding level's volume times the master volume.
    pub volume: f64,
    /// The level that chose it (`agent:claude`, `workspace:ws_1`, `group:Ops`, `event:finished`, `global`).
    pub level: String,
}

fn event_name(event: SoundEvent) -> &'static str {
    match event {
        SoundEvent::Finished => "finished",
        SoundEvent::NeedsInput => "needsInput",
        SoundEvent::Error => "error",
        SoundEvent::Bell => "bell",
        SoundEvent::Message => "message",
    }
}

impl SoundPrefs {
    /// The levels that apply to `scope`, most specific first.
    pub fn levels<'a>(&'a self, scope: &SoundScope) -> Vec<(String, &'a SoundRule)> {
        let mut levels = Vec::new();
        if let Some(agent) = scope.agent.as_ref().map(|agent| agent.to_lowercase())
            && let Some(rule) = self.agents.get(&agent)
        {
            levels.push((format!("agent:{agent}"), rule));
        }
        if let Some(workspace) = &scope.workspace
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

    /// The sound `event` plays in `scope`: the most specific level that names one wins, then the
    /// event's global sound, then `fallback`. `"none"` (or an empty name) on that path mutes it.
    pub fn choice(
        &self,
        event: SoundEvent,
        scope: &SoundScope,
        fallback: &str,
    ) -> Option<SoundChoice> {
        let levels = self.levels(scope);
        let (name, level) = levels
            .iter()
            .find_map(|(level, rule)| {
                rule.sound_for(event).map(|name| (name.to_owned(), level.clone()))
            })
            .or_else(|| {
                self.events
                    .get(&event)
                    .map(|name| (name.clone(), format!("event:{}", event_name(event))))
            })
            .unwrap_or_else(|| (fallback.to_owned(), "global".to_owned()));
        if name == "none" || name.is_empty() {
            return None;
        }
        let share = levels.iter().find_map(|(_, rule)| rule.volume).unwrap_or(1.0);
        Some(SoundChoice { name, volume: (share * self.volume).clamp(0.0, 1.0), level })
    }
}

/// A daily window (local minutes after midnight) in which banners and sounds stay quiet.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", default)]
pub struct QuietHours {
    pub start: i64,
    pub end: i64,
}

impl QuietHours {
    /// True when `minute` lies in the window; a window may wrap past midnight.
    pub fn contains(self, minute: i64) -> bool {
        if self.start == self.end {
            return false;
        }
        if self.start < self.end {
            (self.start..self.end).contains(&minute)
        } else {
            minute >= self.start || minute < self.end
        }
    }
}

/// `notifications.sources.<source>`; absent keeps the global value.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SourceOverrides {
    pub dismissal: Option<Dismissal>,
    pub sound: Option<String>,
    pub desktop: Option<bool>,
}

/// What the arrival rules read of `notifications` in cmux.json.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Prefs {
    pub dismissal: Dismissal,
    pub timeout_seconds: f64,
    pub desktop: Desktop,
    pub sound: String,
    pub sounds: SoundPrefs,
    pub quiet_hours: Option<QuietHours>,
    pub suppress_while_typing_seconds: f64,
    pub dock_bounce: DockBounce,
    pub sources: BTreeMap<Source, SourceOverrides>,
}

impl Default for Prefs {
    fn default() -> Self {
        Prefs {
            dismissal: Dismissal::default(),
            timeout_seconds: 0.0,
            desktop: Desktop::default(),
            sound: "default".to_owned(),
            sounds: SoundPrefs::default(),
            quiet_hours: None,
            suppress_while_typing_seconds: 0.0,
            dock_bounce: DockBounce::default(),
            sources: BTreeMap::new(),
        }
    }
}

impl Prefs {
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

/// Whether `trigger` acknowledges a notification under `mode`. The dismiss
/// verbs (Mark Read, Mark All Read, CLI clear) always do and never ask.
pub fn clears(trigger: Trigger, mode: Dismissal) -> bool {
    match mode {
        Dismissal::Focus => trigger != Trigger::Timeout,
        Dismissal::Click => matches!(trigger, Trigger::Click | Trigger::Keystroke | Trigger::Open),
        Dismissal::Keystroke => matches!(trigger, Trigger::Keystroke | Trigger::Open),
        Dismissal::Explicit => trigger == Trigger::Open,
        Dismissal::Timeout => matches!(trigger, Trigger::Open | Trigger::Timeout),
        Dismissal::Never => false,
    }
}

/// Every dismissal mode with the triggers that clear under it: the app asks
/// once and reads the table on every focus, click and keystroke.
pub fn clears_table() -> BTreeMap<Dismissal, Vec<Trigger>> {
    Dismissal::ALL
        .into_iter()
        .map(|mode| (mode, Trigger::ALL.into_iter().filter(|&t| clears(t, mode)).collect()))
        .collect()
}

fn yes() -> bool {
    true
}

fn noon() -> i64 {
    12 * 60
}

/// What the app knows when a notification arrives.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Arrival {
    #[serde(default)]
    pub source: Source,
    #[serde(default)]
    pub workspace_muted: bool,
    /// The pane is the focused pane of the key window and cmux is active.
    #[serde(default)]
    pub pane_is_viewed: bool,
    #[serde(default)]
    pub app_active: bool,
    /// Local minutes after midnight, for quiet hours.
    #[serde(default = "noon")]
    pub minute_of_day: i64,
    /// Seconds since the last keystroke in the notifying pane, if any.
    #[serde(default)]
    pub typed_ago: Option<f64>,
    /// The poster allows a banner (false for `notify --desktop false`).
    #[serde(default = "yes")]
    pub banner_allowed: bool,
    /// What it is about; absent reads it from the source alone.
    #[serde(default)]
    pub sound_event: Option<SoundEvent>,
    #[serde(default)]
    pub sound_scope: SoundScope,
}

impl Arrival {
    pub fn new(source: Source) -> Self {
        Arrival {
            source,
            workspace_muted: false,
            pane_is_viewed: false,
            app_active: false,
            minute_of_day: noon(),
            typed_ago: None,
            banner_allowed: true,
            sound_event: None,
            sound_scope: SoundScope::default(),
        }
    }
}

/// What an arrival does.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Decision {
    /// Acknowledge at once: it is already seen.
    pub acknowledge: bool,
    /// Draw the pane attention ring.
    pub attention: bool,
    /// It would alert were the poster not asking for no banner (the phone push follows this).
    pub alerts: bool,
    pub desktop: bool,
    pub sound: Option<String>,
    pub sound_volume: f64,
    pub sound_event: SoundEvent,
    pub sound_level: Option<String>,
    /// Acknowledge after this many seconds unless cleared earlier.
    pub timeout: Option<f64>,
    pub bounce: Option<DockBounce>,
}

impl Default for Decision {
    fn default() -> Self {
        Decision {
            acknowledge: false,
            attention: true,
            alerts: false,
            desktop: false,
            sound: None,
            sound_volume: 1.0,
            sound_event: SoundEvent::Message,
            sound_level: None,
            timeout: None,
            bounce: None,
        }
    }
}

/// What `arrival` does under `prefs`.
pub fn decide(prefs: &Prefs, arrival: &Arrival) -> Decision {
    let mut decision = Decision::default();
    let mode = prefs.dismissal_for(arrival.source);
    if prefs.suppress_while_typing_seconds > 0.0
        && let Some(typed) = arrival.typed_ago
        && typed <= prefs.suppress_while_typing_seconds
    {
        decision.acknowledge = true;
        decision.attention = false;
        return decision;
    }
    let quiet = prefs.quiet_hours.is_some_and(|hours| hours.contains(arrival.minute_of_day));
    if mode == Dismissal::Focus && arrival.pane_is_viewed {
        decision.acknowledge = true;
        decision.attention = false;
        // Read on sight, but `sounds.when = always` means always: the viewed pane still sounds.
        if prefs.sounds.when == SoundTiming::Always {
            choose_sound(prefs, arrival, quiet, &mut decision);
        }
        return decision;
    }
    if arrival.workspace_muted {
        decision.attention = false;
    }
    if !arrival.workspace_muted && !quiet && prefs.posts_desktop(arrival.source) {
        decision.alerts = match prefs.desktop {
            Desktop::Always => true,
            Desktop::UnlessFocused => !arrival.pane_is_viewed,
            Desktop::WhenInactive => !arrival.app_active,
            Desktop::Never => false,
        };
    }
    decision.desktop = decision.alerts && arrival.banner_allowed;
    choose_sound(prefs, arrival, quiet, &mut decision);
    if mode == Dismissal::Timeout {
        decision.timeout = Some(prefs.timeout_seconds);
    }
    // A poster asking for no banner gets no bounce either.
    if decision.desktop && !arrival.app_active && prefs.dock_bounce != DockBounce::Off {
        decision.bounce = Some(prefs.dock_bounce);
    }
    decision
}

fn choose_sound(prefs: &Prefs, arrival: &Arrival, quiet: bool, decision: &mut Decision) {
    let event = arrival.sound_event.unwrap_or_else(|| SoundEvent::of(arrival.source, Level::Info));
    decision.sound_event = event;
    if arrival.workspace_muted
        || quiet
        || !prefs.sounds.when.plays(arrival.pane_is_viewed, arrival.app_active)
    {
        return;
    }
    let Some(choice) =
        prefs.sounds.choice(event, &arrival.sound_scope, prefs.sound_for(arrival.source))
    else {
        return;
    };
    decision.sound = Some(choice.name);
    decision.sound_volume = choice.volume;
    decision.sound_level = Some(choice.level);
}

/// The last sound that played, for the burst cooldown: the app keeps it and
/// sends it back with the next sound.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LastSound {
    /// On the app's monotonic clock, milliseconds.
    pub at_ms: i64,
    pub urgency: u8,
}

/// Whether `event` may sound at `now_ms`, after `last`: an event no more
/// urgent than the last one that sounded stays silent within `cooldown_ms`.
/// A yes is the new last sound.
pub fn admit(
    last: Option<LastSound>,
    event: SoundEvent,
    now_ms: i64,
    cooldown_ms: i64,
) -> Option<LastSound> {
    if let Some(last) = last
        && now_ms - last.at_ms < cooldown_ms
        && event.urgency() <= last.urgency
    {
        return None;
    }
    Some(LastSound { at_ms: now_ms, urgency: event.urgency() })
}

#[cfg(test)]
#[path = "notification_policy_tests.rs"]
mod tests;
