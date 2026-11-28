//! The notification rules (plans/cmux-next/notifications.md; Swift
//! `NotificationPolicy`): when a trigger acknowledges a notification and what
//! an arrival shows. The daemon owns unread state; these only decide.

use serde::{Deserialize, Serialize};

use super::{Choice, DesktopMode, Dismissal, DockBounce, Preferences, SoundEvent, SoundScope};
use super::{Level, Source};

choice!(
    /// A person's interaction with a pane that has an unread notification.
    Trigger {
        Focus = "focus", Click = "click", Keystroke = "keystroke", Open = "open",
        Timeout = "timeout",
    } default Focus
);

/// Whether `trigger` acknowledges a notification under `mode`. The dismiss
/// verbs (Mark Read, Mark All Read, CLI clear) always do and do not come here.
pub fn clears_mode(trigger: Trigger, mode: Dismissal) -> bool {
    use Trigger::*;
    match mode {
        Dismissal::Focus => trigger != Timeout,
        Dismissal::Click => matches!(trigger, Click | Keystroke | Open),
        Dismissal::Keystroke => matches!(trigger, Keystroke | Open),
        Dismissal::Explicit => trigger == Open,
        Dismissal::Timeout => matches!(trigger, Open | Timeout),
        Dismissal::Never => false,
    }
}

/// [`clears_mode`] under `source`'s dismissal.
pub fn clears(prefs: &Preferences, trigger: Trigger, source: Source) -> bool {
    clears_mode(trigger, prefs.dismissal_for(source))
}

/// Whether reading a pane by `trigger` flashes its ring (Swift
/// `AttentionSettings.flashesOnEntry`): going into it, unless the flash is
/// off, or for a key unless `flashOnTyping` is on.
pub fn flashes_on_entry(flashes_on_read: bool, flashes_on_typing: bool, trigger: Trigger) -> bool {
    if !flashes_on_read || trigger == Trigger::Timeout {
        return false;
    }
    trigger != Trigger::Keystroke || flashes_on_typing
}

/// What the app knows when a notification arrives.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Arrival {
    pub source: Source,
    pub workspace_muted: bool,
    /// The pane is the focused pane of the key window and cmux is active.
    pub pane_is_viewed: bool,
    pub app_active: bool,
    /// Local minutes after midnight, for quiet hours.
    pub minute_of_day: i64,
    /// Seconds since the last keystroke in the notifying pane, if any.
    pub typed_ago: Option<f64>,
    /// The poster allows a banner (false for `notify --desktop false`).
    pub banner_allowed: bool,
    /// What it is about; None reads it from the source alone.
    pub sound_event: Option<SoundEvent>,
    pub sound_scope: SoundScope,
}

impl Default for Arrival {
    fn default() -> Self {
        Arrival {
            source: Source::Agent,
            workspace_muted: false,
            pane_is_viewed: false,
            app_active: false,
            minute_of_day: 12 * 60,
            typed_ago: None,
            banner_allowed: true,
            sound_event: None,
            sound_scope: SoundScope::default(),
        }
    }
}

/// What an arrival shows.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Decision {
    /// Acknowledge at once: it is already seen.
    pub acknowledge: bool,
    /// Draw the pane attention ring.
    pub attention: bool,
    /// It would alert (banner) were the poster not asking for none: the phone push follows this.
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

/// What `arrival` shows under `prefs`.
pub fn decide(prefs: &Preferences, arrival: &Arrival) -> Decision {
    let mut decision = Decision::default();
    let mode = prefs.dismissal_for(arrival.source);
    let typing = prefs.suppress_while_typing_seconds;
    if typing > 0.0 && arrival.typed_ago.is_some_and(|typed| typed <= typing) {
        decision.acknowledge = true;
        decision.attention = false;
        return decision;
    }
    let quiet = prefs.quiet_hours.is_some_and(|q| q.contains(arrival.minute_of_day));
    if mode == Dismissal::Focus && arrival.pane_is_viewed {
        decision.acknowledge = true;
        decision.attention = false;
        // Read on sight, but `sounds.when = always` means always: the viewed pane still sounds.
        if prefs.sounds.when == super::SoundTiming::Always {
            choose_sound(prefs, arrival, quiet, &mut decision);
        }
        return decision;
    }
    if arrival.workspace_muted {
        decision.attention = false;
    }
    if !arrival.workspace_muted && !quiet && prefs.posts_desktop(arrival.source) {
        decision.alerts = match prefs.desktop {
            DesktopMode::Always => true,
            DesktopMode::UnlessFocused => !arrival.pane_is_viewed,
            DesktopMode::WhenInactive => !arrival.app_active,
            DesktopMode::Never => false,
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

/// The arrival's sound event, and its sound when `sounds.when` plays it and
/// neither a muted workspace nor quiet hours silence it.
fn choose_sound(prefs: &Preferences, arrival: &Arrival, quiet: bool, decision: &mut Decision) {
    let event = arrival.sound_event.unwrap_or(SoundEvent::of(arrival.source, Level::Info));
    decision.sound_event = event;
    if arrival.workspace_muted
        || quiet
        || !prefs.sounds.when.plays(arrival.pane_is_viewed, arrival.app_active)
    {
        return;
    }
    let fallback = prefs.sound_for(arrival.source);
    let Some(choice) = prefs.sounds.choice(event, &arrival.sound_scope, fallback) else { return };
    decision.sound = Some(choice.name);
    decision.sound_volume = choice.volume;
    decision.sound_level = Some(choice.level);
}

/// An agent name as sound rules key it: lowercased, None when empty.
pub fn agent_kind(raw: Option<&str>) -> Option<String> {
    raw.filter(|raw| !raw.is_empty()).map(str::to_lowercase)
}

/// The daemon's level; another value reads as `info`.
pub fn level_of(raw: &str) -> Level {
    Level::from_name(raw).unwrap_or(Level::Info)
}
