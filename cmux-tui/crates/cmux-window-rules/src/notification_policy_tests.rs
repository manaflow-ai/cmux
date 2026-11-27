//! Parity with the Swift tests these rules came from
//! (CmuxNextSettingsTests NotificationSoundTests, UnreadDismissDefaultsTests,
//! NotificationSoundOnSightTests; CmuxNextAppTests DockBouncePolicyTests).

use super::*;

fn scope() -> SoundScope {
    SoundScope {
        agent: Some("codex".into()),
        workspace: Some("ws_1".into()),
        groups: vec![
            Group { id: "grp_inner".into(), name: "Inner".into() },
            Group { id: "grp_outer".into(), name: "Agents & routing".into() },
        ],
    }
}

fn rule(sound: Option<&str>, volume: Option<f64>) -> SoundRule {
    SoundRule { sound: sound.map(Into::into), volume, events: BTreeMap::new() }
}

fn event_rule(event: SoundEvent, sound: &str) -> SoundRule {
    SoundRule { events: BTreeMap::from([(event, sound.to_owned())]), ..SoundRule::default() }
}

fn name(sounds: &SoundPrefs, event: SoundEvent) -> Option<String> {
    sounds.choice(event, &scope(), "Glass").map(|choice| choice.name)
}

#[test]
fn with_no_levels_the_global_sound_plays() {
    let choice = SoundPrefs::default().choice(SoundEvent::Finished, &scope(), "Glass");
    assert_eq!(
        choice,
        Some(SoundChoice { name: "Glass".into(), volume: 1.0, level: "global".into() })
    );
}

#[test]
fn an_events_global_sound_beats_the_default_sound() {
    let mut sounds = SoundPrefs::default();
    sounds.events.insert(SoundEvent::NeedsInput, "Ping".into());
    assert_eq!(name(&sounds, SoundEvent::NeedsInput).as_deref(), Some("Ping"));
    assert_eq!(
        sounds.choice(SoundEvent::NeedsInput, &scope(), "Glass").unwrap().level,
        "event:needsInput"
    );
    assert_eq!(name(&sounds, SoundEvent::Finished).as_deref(), Some("Glass"));
}

#[test]
fn the_most_specific_level_wins() {
    let mut sounds = SoundPrefs::default();
    sounds.events.insert(SoundEvent::Finished, "Pop".into());
    sounds.groups.insert("Agents & routing".into(), rule(Some("Submarine"), None));
    assert_eq!(name(&sounds, SoundEvent::Finished).as_deref(), Some("Submarine"));
    sounds.groups.insert("grp_inner".into(), rule(Some("Tink"), None));
    assert_eq!(name(&sounds, SoundEvent::Finished).as_deref(), Some("Tink"));
    sounds.workspaces.insert("ws_1".into(), rule(Some("Frog"), None));
    assert_eq!(name(&sounds, SoundEvent::Finished).as_deref(), Some("Frog"));
    sounds.agents.insert("codex".into(), event_rule(SoundEvent::Finished, "Hero"));
    assert_eq!(name(&sounds, SoundEvent::Finished).as_deref(), Some("Hero"));
    assert_eq!(name(&sounds, SoundEvent::NeedsInput).as_deref(), Some("Frog"));
}

#[test]
fn an_agent_kind_matches_case_insensitively() {
    let mut sounds = SoundPrefs::default();
    sounds.agents.insert("codex".into(), rule(Some("Hero"), None));
    let mut upper = scope();
    upper.agent = Some("Codex".into());
    let choice = sounds.choice(SoundEvent::Finished, &upper, "Glass").unwrap();
    assert_eq!((choice.name.as_str(), choice.level.as_str()), ("Hero", "agent:codex"));
}

#[test]
fn none_mutes_a_level_but_a_more_specific_level_still_plays() {
    let mut sounds = SoundPrefs::default();
    sounds.groups.insert("grp_outer".into(), rule(Some("none"), None));
    assert_eq!(name(&sounds, SoundEvent::Finished), None);
    sounds.workspaces.insert("ws_1".into(), event_rule(SoundEvent::NeedsInput, "Ping"));
    assert_eq!(name(&sounds, SoundEvent::NeedsInput).as_deref(), Some("Ping"));
    assert_eq!(name(&sounds, SoundEvent::Finished), None);
}

#[test]
fn an_empty_fallback_is_silent() {
    assert_eq!(SoundPrefs::default().choice(SoundEvent::Bell, &scope(), ""), None);
}

#[test]
fn volume_is_the_nearest_levels_share_of_the_master() {
    let mut sounds = SoundPrefs { volume: 0.5, ..SoundPrefs::default() };
    let volume = |s: &SoundPrefs| s.choice(SoundEvent::Finished, &scope(), "Glass").unwrap().volume;
    assert_eq!(volume(&sounds), 0.5);
    sounds.groups.insert("grp_outer".into(), rule(None, Some(0.5)));
    assert_eq!(volume(&sounds), 0.25);
    sounds.workspaces.insert("ws_1".into(), rule(None, Some(1.0)));
    assert_eq!(volume(&sounds), 0.5);
}

fn arrival(viewed: bool, active: bool, event: Option<SoundEvent>) -> Arrival {
    Arrival {
        pane_is_viewed: viewed,
        app_active: active,
        sound_event: event,
        sound_scope: scope(),
        ..Arrival::new(Source::Agent)
    }
}

#[test]
fn the_decision_carries_the_scopes_sound_and_volume() {
    let mut prefs = Prefs { dismissal: Dismissal::Click, ..Prefs::default() };
    prefs.sounds.workspaces.insert("ws_1".into(), rule(Some("Frog"), Some(0.4)));
    let decision = decide(&prefs, &arrival(false, true, Some(SoundEvent::NeedsInput)));
    assert_eq!(decision.sound.as_deref(), Some("Frog"));
    assert_eq!(decision.sound_volume, 0.4);
    assert_eq!(decision.sound_level.as_deref(), Some("workspace:ws_1"));
    assert_eq!(decision.sound_event, SoundEvent::NeedsInput);
}

#[test]
fn timing_decides_whether_a_viewed_pane_or_an_active_app_sounds() {
    let mut prefs = Prefs { dismissal: Dismissal::Click, ..Prefs::default() };
    assert_eq!(decide(&prefs, &arrival(true, true, None)).sound, None);
    assert_eq!(decide(&prefs, &arrival(false, true, None)).sound.as_deref(), Some("default"));
    prefs.sounds.when = SoundTiming::Always;
    assert_eq!(decide(&prefs, &arrival(true, true, None)).sound.as_deref(), Some("default"));
    prefs.sounds.when = SoundTiming::WhenInactive;
    assert_eq!(decide(&prefs, &arrival(false, true, None)).sound, None);
    assert_eq!(decide(&prefs, &arrival(false, false, None)).sound.as_deref(), Some("default"));
}

#[test]
fn a_viewed_pane_is_read_on_sight_under_focus_and_only_always_sounds() {
    let mut prefs = Prefs::default();
    for when in [SoundTiming::UnlessViewed, SoundTiming::WhenInactive] {
        prefs.sounds.when = when;
        let decision = decide(&prefs, &arrival(true, true, None));
        assert!(decision.acknowledge && !decision.attention && !decision.alerts, "{when:?}");
        assert_eq!(decision.sound, None, "{when:?}");
    }
    prefs.sounds.when = SoundTiming::Always;
    let decision = decide(&prefs, &arrival(true, true, None));
    assert!(decision.acknowledge && !decision.attention);
    assert_eq!(decision.sound.as_deref(), Some("default"));
    assert_eq!(decision.bounce, None);
}

#[test]
fn a_muted_workspace_or_quiet_hours_still_silence_always() {
    let mut prefs = Prefs {
        sounds: SoundPrefs { when: SoundTiming::Always, ..SoundPrefs::default() },
        ..Prefs::default()
    };
    let mut muted = arrival(true, true, None);
    muted.workspace_muted = true;
    assert_eq!(decide(&prefs, &muted).sound, None);
    prefs.quiet_hours = Some(QuietHours { start: 22 * 60, end: 7 * 60 });
    let mut night = arrival(true, true, None);
    night.minute_of_day = 23 * 60;
    assert_eq!(decide(&prefs, &night).sound, None);
}

#[test]
fn typing_in_the_pane_reads_it_at_once() {
    let prefs = Prefs { suppress_while_typing_seconds: 2.0, ..Prefs::default() };
    let mut typed = arrival(false, true, None);
    typed.typed_ago = Some(1.5);
    let decision = decide(&prefs, &typed);
    assert!(decision.acknowledge && !decision.attention && !decision.alerts);
    assert_eq!(decision.sound, None);
    typed.typed_ago = Some(3.0);
    assert!(!decide(&prefs, &typed).acknowledge);
}

#[test]
fn desktop_modes_decide_the_banner() {
    let mut prefs = Prefs { dismissal: Dismissal::Click, ..Prefs::default() };
    let cases = [
        (Desktop::UnlessFocused, true, true, false),
        (Desktop::UnlessFocused, false, true, true),
        (Desktop::Always, true, true, true),
        (Desktop::WhenInactive, false, true, false),
        (Desktop::WhenInactive, false, false, true),
        (Desktop::Never, false, false, false),
    ];
    for (desktop, viewed, active, alerts) in cases {
        prefs.desktop = desktop;
        let decision = decide(&prefs, &arrival(viewed, active, None));
        assert_eq!(decision.alerts, alerts, "{desktop:?} viewed {viewed} active {active}");
        assert_eq!(decision.desktop, alerts);
    }
    let mut no_banner = arrival(false, true, None);
    no_banner.banner_allowed = false;
    let decision = decide(&Prefs::default(), &no_banner);
    assert!(decision.alerts && !decision.desktop);
}

#[test]
fn a_source_override_wins() {
    let mut prefs = Prefs::default();
    prefs.sources.insert(
        Source::Terminal,
        SourceOverrides {
            dismissal: Some(Dismissal::Timeout),
            sound: Some("Ping".into()),
            desktop: Some(false),
        },
    );
    prefs.timeout_seconds = 9.0;
    let mut bell = Arrival::new(Source::Terminal);
    bell.app_active = true;
    let decision = decide(&prefs, &bell);
    assert!(!decision.alerts);
    assert_eq!(decision.sound.as_deref(), Some("Ping"));
    assert_eq!(decision.sound_event, SoundEvent::Bell);
    assert_eq!(decision.timeout, Some(9.0));
}

#[test]
fn dock_bounce_follows_the_banner_while_inactive() {
    let mut prefs = Prefs::default();
    assert_eq!(decide(&prefs, &arrival(false, false, None)).bounce, Some(DockBounce::Once));
    prefs.dock_bounce = DockBounce::UntilActive;
    assert_eq!(decide(&prefs, &arrival(false, false, None)).bounce, Some(DockBounce::UntilActive));
    prefs.dock_bounce = DockBounce::Off;
    assert_eq!(decide(&prefs, &arrival(false, false, None)).bounce, None);
    prefs.dock_bounce = DockBounce::Once;
    assert_eq!(
        decide(&prefs, &arrival(false, true, None)).bounce,
        None,
        "an active app never bounces"
    );
    let mut no_banner = arrival(false, false, None);
    no_banner.banner_allowed = false;
    assert_eq!(decide(&prefs, &no_banner).bounce, None);
    prefs.desktop = Desktop::Never;
    assert_eq!(decide(&prefs, &arrival(false, false, None)).bounce, None);
    prefs.desktop = Desktop::UnlessFocused;
    prefs.quiet_hours = Some(QuietHours { start: 0, end: 24 * 60 });
    assert_eq!(decide(&prefs, &arrival(false, false, None)).bounce, None);
}

#[test]
fn a_notification_clears_when_its_pane_is_selected_by_default() {
    for trigger in [Trigger::Focus, Trigger::Click, Trigger::Keystroke, Trigger::Open] {
        assert!(clears(trigger, Dismissal::default()), "{trigger:?}");
    }
    assert!(!clears(Trigger::Timeout, Dismissal::Focus));
    assert!(clears(Trigger::Timeout, Dismissal::Timeout));
}

#[test]
fn the_clears_table_is_every_mode() {
    let table = clears_table();
    assert_eq!(table.len(), Dismissal::ALL.len());
    assert_eq!(table[&Dismissal::Never], Vec::<Trigger>::new());
    assert_eq!(table[&Dismissal::Explicit], vec![Trigger::Open]);
    assert_eq!(table[&Dismissal::Click], vec![Trigger::Click, Trigger::Keystroke, Trigger::Open]);
    assert_eq!(table[&Dismissal::Keystroke], vec![Trigger::Keystroke, Trigger::Open]);
    assert_eq!(table[&Dismissal::Timeout], vec![Trigger::Open, Trigger::Timeout]);
    let json = serde_json::to_value(&table).unwrap();
    assert_eq!(json["explicit"], serde_json::json!(["open"]));
}

#[test]
fn quiet_hours_may_wrap_midnight() {
    let night = QuietHours { start: 22 * 60, end: 7 * 60 };
    assert!(night.contains(23 * 60) && night.contains(60) && !night.contains(12 * 60));
    assert!(!QuietHours { start: 60, end: 60 }.contains(60));
    let day = QuietHours { start: 9 * 60, end: 17 * 60 };
    assert!(day.contains(9 * 60) && !day.contains(17 * 60));
}

#[test]
fn sound_events_come_from_source_and_level() {
    use Level::*;
    use Source::*;
    assert_eq!(SoundEvent::of(Terminal, Error), SoundEvent::Error);
    assert_eq!(SoundEvent::of(Agent, Warning), SoundEvent::NeedsInput);
    assert_eq!(SoundEvent::of(Cli, Warning), SoundEvent::NeedsInput);
    assert_eq!(SoundEvent::of(Agent, Info), SoundEvent::Finished);
    assert_eq!(SoundEvent::of(Terminal, Warning), SoundEvent::Bell);
    assert_eq!(SoundEvent::of(Cli, Info), SoundEvent::Message);
}

#[test]
fn a_burst_sounds_once_but_a_more_urgent_event_still_plays() {
    let steps = [
        (SoundEvent::Finished, 0),
        (SoundEvent::Finished, 200),
        (SoundEvent::Bell, 400),
        (SoundEvent::NeedsInput, 600),
        (SoundEvent::Finished, 1_000),
        (SoundEvent::Finished, 2_200),
    ];
    let mut last = None;
    let mut admitted = Vec::new();
    for (event, ms) in steps {
        let next = admit(last, event, ms, 1_500);
        admitted.push(next.is_some());
        last = next.or(last);
    }
    assert_eq!(admitted, [true, false, false, true, false, true]);
}

#[test]
fn a_zero_cooldown_never_throttles() {
    let first = admit(None, SoundEvent::Finished, 5, 0);
    assert!(first.is_some());
    assert!(admit(first, SoundEvent::Finished, 5, 0).is_some());
}

#[test]
fn the_wire_reads_the_apps_names() {
    let prefs: Prefs = serde_json::from_value(serde_json::json!({
        "dismissal": "explicit",
        "timeoutSeconds": 4,
        "desktop": "whenInactive",
        "sound": "Glass",
        "sounds": {"volume": 0.8, "when": "always", "events": {"needsInput": "Ping"},
                   "agents": {"claude": {"events": {"finished": "Hero"}}}},
        "quietHours": {"start": 1320, "end": 420},
        "suppressWhileTypingSeconds": 1.5,
        "dockBounce": "untilActive",
        "sources": {"cli": {"desktop": false}}
    }))
    .unwrap();
    assert_eq!(prefs.dismissal, Dismissal::Explicit);
    assert_eq!(prefs.sounds.events[&SoundEvent::NeedsInput], "Ping");
    assert!(!prefs.posts_desktop(Source::Cli));
    let arrival: Arrival = serde_json::from_value(serde_json::json!({
        "source": "terminal", "typedAgo": null, "soundScope": {"groups": [{"id": "g", "name": "G"}]}
    }))
    .unwrap();
    assert!(arrival.banner_allowed);
    assert_eq!(arrival.minute_of_day, 720);
    let reply = serde_json::to_value(decide(&prefs, &arrival)).unwrap();
    assert_eq!(reply["soundEvent"], "bell");
    assert_eq!(reply["bounce"], "untilActive");
}
