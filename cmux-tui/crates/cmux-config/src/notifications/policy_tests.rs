//! Ports of the Swift policy tests: NotificationSoundTests' policy cases,
//! NotificationSoundOnSightTests, UnreadDismissDefaultsTests and DockBouncePolicyTests.

use super::*;

fn arrival() -> Arrival {
    Arrival::default()
}

fn prefs_with(f: impl FnOnce(&mut Preferences)) -> Preferences {
    let mut prefs = Preferences::default();
    f(&mut prefs);
    prefs
}

// MARK: Sound policy

#[test]
fn the_policy_picks_the_scopes_sound_and_volume() {
    let prefs = prefs_with(|p| {
        p.sound = "Glass".into();
        p.sounds.volume = 0.8;
        p.sounds.workspaces.insert(
            "ws_1".into(),
            SoundRule { sound: Some("Frog".into()), volume: Some(0.5), ..SoundRule::default() },
        );
    });
    let arrival = Arrival {
        sound_scope: SoundScope { workspace: Some("ws_1".into()), ..SoundScope::default() },
        ..arrival()
    };
    let decision = decide(&prefs, &arrival);
    assert_eq!(decision.sound.as_deref(), Some("Frog"));
    assert!((decision.sound_volume - 0.4).abs() < 1e-9);
    assert_eq!(decision.sound_level.as_deref(), Some("workspace:ws_1"));
    assert_eq!(decision.sound_event, SoundEvent::Finished);
}

#[test]
fn the_sound_timing_decides_by_viewing_and_activity() {
    use SoundTiming::*;
    // (timing, viewed, app active, plays)
    for (timing, viewed, active, plays) in [
        (UnlessViewed, false, true, true),
        (UnlessViewed, true, true, false),
        (WhenInactive, false, true, false),
        (WhenInactive, false, false, true),
        (Always, true, true, true),
    ] {
        assert_eq!(
            timing.plays(viewed, active),
            plays,
            "{timing:?} viewed={viewed} active={active}"
        );
    }
}

#[test]
fn a_timing_that_does_not_play_still_names_the_event() {
    let prefs = prefs_with(|p| p.sounds.when = SoundTiming::WhenInactive);
    let decision =
        decide(&prefs, &Arrival { app_active: true, source: Source::Terminal, ..arrival() });
    assert_eq!(decision.sound, None);
    assert_eq!(decision.sound_event, SoundEvent::Bell);
    let given = Arrival { sound_event: Some(SoundEvent::NeedsInput), ..arrival() };
    assert_eq!(decide(&Preferences::default(), &given).sound_event, SoundEvent::NeedsInput);
}

// MARK: On sight

#[test]
fn a_viewed_pane_is_acknowledged_under_every_timing() {
    for timing in SoundTiming::ALL {
        let prefs = prefs_with(|p| p.sounds.when = *timing);
        let decision =
            decide(&prefs, &Arrival { pane_is_viewed: true, app_active: true, ..arrival() });
        assert!(decision.acknowledge, "{timing:?}");
        assert!(!decision.attention, "{timing:?}");
        assert!(!decision.desktop, "{timing:?}");
        assert_eq!(decision.bounce, None);
    }
}

#[test]
fn always_sounds_on_a_viewed_pane() {
    let prefs = prefs_with(|p| p.sounds.when = SoundTiming::Always);
    let decision = decide(&prefs, &Arrival { pane_is_viewed: true, app_active: true, ..arrival() });
    assert_eq!(decision.sound.as_deref(), Some("default"));
    assert_eq!(decision.sound_event, SoundEvent::Finished);
    let unless = decide(&Preferences::default(), &Arrival { pane_is_viewed: true, ..arrival() });
    assert_eq!(unless.sound, None, "unlessViewed is silent on a viewed pane");
}

#[test]
fn always_stays_silent_when_muted_or_quiet() {
    let prefs = prefs_with(|p| p.sounds.when = SoundTiming::Always);
    let viewed = Arrival { pane_is_viewed: true, app_active: true, ..arrival() };
    let muted = decide(&prefs, &Arrival { workspace_muted: true, ..viewed.clone() });
    assert_eq!(muted.sound, None);
    let quiet = prefs_with(|p| {
        p.sounds.when = SoundTiming::Always;
        p.quiet_hours = Some(QuietHours { start: 0, end: 1439 });
    });
    assert_eq!(decide(&quiet, &viewed).sound, None);
}

#[test]
fn typing_suppresses_an_arrival() {
    let prefs = prefs_with(|p| p.suppress_while_typing_seconds = 2.0);
    let decision = decide(&prefs, &Arrival { typed_ago: Some(1.0), ..arrival() });
    assert!(decision.acknowledge && !decision.attention && decision.sound.is_none());
    assert!(!decide(&prefs, &Arrival { typed_ago: Some(3.0), ..arrival() }).acknowledge);
    assert!(
        !decide(&Preferences::default(), &Arrival { typed_ago: Some(0.0), ..arrival() })
            .acknowledge
    );
}

#[test]
fn the_timeout_mode_sets_a_timeout() {
    let prefs = prefs_with(|p| {
        p.dismissal = Dismissal::Timeout;
        p.timeout_seconds = 12.0;
    });
    assert_eq!(decide(&prefs, &arrival()).timeout, Some(12.0));
    assert_eq!(decide(&Preferences::default(), &arrival()).timeout, None);
}

#[test]
fn a_muted_workspace_has_no_ring_banner_or_sound() {
    let decision = decide(&Preferences::default(), &Arrival { workspace_muted: true, ..arrival() });
    assert!(!decision.attention && !decision.alerts && !decision.desktop);
    assert_eq!(decision.sound, None);
}

#[test]
fn desktop_modes_decide_the_banner() {
    for (mode, viewed, active, alerts) in [
        (DesktopMode::Always, false, true, true),
        (DesktopMode::UnlessFocused, false, true, true),
        (DesktopMode::WhenInactive, false, true, false),
        (DesktopMode::WhenInactive, false, false, true),
        (DesktopMode::Never, false, false, false),
    ] {
        let prefs = prefs_with(|p| {
            p.desktop = mode;
            p.dismissal = Dismissal::Click; // a viewed pane is not read on sight
        });
        let a = Arrival { pane_is_viewed: viewed, app_active: active, ..arrival() };
        assert_eq!(decide(&prefs, &a).alerts, alerts, "{mode:?}");
    }
    let prefs = prefs_with(|p| p.dismissal = Dismissal::Click);
    let viewed = Arrival { pane_is_viewed: true, ..arrival() };
    assert!(!decide(&prefs, &viewed).alerts, "unlessFocused skips the viewed pane");
}

// MARK: Dismiss defaults

#[test]
fn every_source_clears_on_focus_by_default() {
    let prefs = Preferences::default();
    assert_eq!(prefs.dismissal, Dismissal::Focus);
    for source in Source::ALL {
        for trigger in [Trigger::Focus, Trigger::Click, Trigger::Keystroke, Trigger::Open] {
            assert!(clears(&prefs, trigger, *source), "{trigger:?} {source:?}");
        }
        assert!(!clears(&prefs, Trigger::Timeout, *source));
    }
}

#[test]
fn each_dismissal_mode_clears_on_its_triggers() {
    use Trigger::*;
    for (mode, clearing) in [
        (Dismissal::Focus, vec![Focus, Click, Keystroke, Open]),
        (Dismissal::Click, vec![Click, Keystroke, Open]),
        (Dismissal::Keystroke, vec![Keystroke, Open]),
        (Dismissal::Explicit, vec![Open]),
        (Dismissal::Timeout, vec![Open, Timeout]),
        (Dismissal::Never, vec![]),
    ] {
        for trigger in Trigger::ALL {
            assert_eq!(
                clears_mode(*trigger, mode),
                clearing.contains(trigger),
                "{mode:?} {trigger:?}"
            );
        }
    }
    let prefs = prefs_with(|p| {
        p.sources.insert(
            Source::Terminal,
            SourceOverrides { dismissal: Some(Dismissal::Never), ..SourceOverrides::default() },
        );
    });
    assert!(!clears(&prefs, Focus, Source::Terminal), "a source's own dismissal wins");
    assert!(clears(&prefs, Focus, Source::Agent));
}

#[test]
fn entering_a_pane_flashes_unless_off_or_typed() {
    assert!(flashes_on_entry(true, false, Trigger::Focus));
    assert!(flashes_on_entry(true, false, Trigger::Click));
    assert!(!flashes_on_entry(true, false, Trigger::Keystroke));
    assert!(flashes_on_entry(true, true, Trigger::Keystroke));
    assert!(!flashes_on_entry(true, true, Trigger::Timeout));
    assert!(!flashes_on_entry(false, true, Trigger::Focus));
}

// MARK: Dock bounce

#[test]
fn a_notification_bounces_once_by_default() {
    assert_eq!(decide(&Preferences::default(), &arrival()).bounce, Some(DockBounce::Once));
}

#[test]
fn the_dock_bounce_setting_picks_the_bounce() {
    let until = prefs_with(|p| p.dock_bounce = DockBounce::UntilActive);
    assert_eq!(decide(&until, &arrival()).bounce, Some(DockBounce::UntilActive));
    let off = prefs_with(|p| p.dock_bounce = DockBounce::Off);
    assert_eq!(decide(&off, &arrival()).bounce, None);
}

#[test]
fn an_active_app_never_bounces() {
    assert_eq!(
        decide(&Preferences::default(), &Arrival { app_active: true, ..arrival() }).bounce,
        None
    );
}

#[test]
fn a_muted_or_bannerless_notification_never_bounces() {
    let prefs = prefs_with(|p| p.dock_bounce = DockBounce::UntilActive);
    assert_eq!(decide(&prefs, &Arrival { workspace_muted: true, ..arrival() }).bounce, None);
    let never = prefs_with(|p| p.desktop = DesktopMode::Never);
    assert_eq!(decide(&never, &arrival()).bounce, None);
    let cli = Arrival { source: Source::Cli, banner_allowed: false, ..arrival() };
    let decision = decide(&prefs, &cli);
    assert_eq!(decision.bounce, None, "notify --desktop false has no bounce");
    assert!(decision.alerts && !decision.desktop, "it still alerts for the phone push");
}

#[test]
fn quiet_hours_never_bounce() {
    let prefs = prefs_with(|p| {
        p.dock_bounce = DockBounce::UntilActive;
        p.quiet_hours = Some(QuietHours { start: 22 * 60, end: 7 * 60 });
    });
    assert_eq!(decide(&prefs, &Arrival { minute_of_day: 23 * 60, ..arrival() }).bounce, None);
    assert_eq!(
        decide(&prefs, &Arrival { minute_of_day: 12 * 60, ..arrival() }).bounce,
        Some(DockBounce::UntilActive)
    );
}
