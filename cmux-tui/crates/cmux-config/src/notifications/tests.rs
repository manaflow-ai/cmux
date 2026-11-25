//! Ports of the Swift tests of the parse, the sound levels, the rule edits and
//! the workspace keys (NotificationSoundTests, AttentionBannerTests,
//! DockBouncePolicyTests' cmux.json case, UnreadDismissDefaultsTests).

use std::collections::{BTreeMap, BTreeSet};

use serde_json::{Value, json};

use super::*;

fn scope() -> SoundScope {
    SoundScope {
        agent: Some("Codex".into()),
        workspace: Some("ws_1".into()),
        groups: vec![
            Group { id: "grp_inner".into(), name: "Inner".into() },
            Group { id: "grp_outer".into(), name: "Agents & routing".into() },
        ],
    }
}

fn rule(sound: Option<&str>, volume: Option<f64>, events: &[(SoundEvent, &str)]) -> SoundRule {
    SoundRule {
        sound: sound.map(str::to_owned),
        volume,
        events: events.iter().map(|(e, s)| (*e, (*s).to_owned())).collect(),
    }
}

fn with_sounds(sounds: Value) -> (Preferences, Vec<Diagnostic>) {
    parse(&json!({ "notifications": { "sound": "Glass", "sounds": sounds } }))
}

fn paths(diagnostics: &[Diagnostic]) -> BTreeSet<&str> {
    diagnostics.iter().map(|d| d.path.as_str()).collect()
}

// MARK: Events

#[test]
fn each_notification_has_an_event() {
    use Level::{Error as LError, Info, Warning};
    use SoundEvent::{Bell, Error, Finished, Message, NeedsInput};
    for (source, level, event) in [
        (Source::Agent, Info, Finished),
        (Source::Agent, Warning, NeedsInput),
        (Source::Agent, LError, Error),
        (Source::Terminal, Info, Bell),
        (Source::Terminal, Warning, Bell),
        (Source::Terminal, LError, Error),
        (Source::Cli, Info, Message),
        (Source::Cli, Warning, NeedsInput),
        (Source::Cli, LError, Error),
    ] {
        assert_eq!(SoundEvent::of(source, level), event, "{source:?} {level:?}");
    }
}

#[test]
fn an_unknown_wire_source_or_level_reads_as_agent_and_info() {
    assert_eq!(Source::from_wire(Some("terminal")), Source::Terminal);
    assert_eq!(Source::from_wire(Some("daemon")), Source::Agent);
    assert_eq!(Source::from_wire(None), Source::Agent);
    assert_eq!(level_of("loud"), Level::Info);
    assert_eq!(agent_kind(Some("Codex")).as_deref(), Some("codex"));
    assert_eq!(agent_kind(Some("")), None);
    assert_eq!(agent_kind(None), None);
}

#[test]
fn urgency_orders_events_in_a_burst() {
    use SoundEvent::*;
    assert_eq!(
        [NeedsInput, Error, Finished, Message, Bell].map(SoundEvent::urgency),
        [3, 2, 1, 1, 0]
    );
}

// MARK: Parsing

#[test]
fn an_empty_file_reads_with_the_defaults() {
    let (prefs, diagnostics) = parse(&json!({}));
    assert!(diagnostics.is_empty());
    assert_eq!(prefs, Preferences::default());
    assert_eq!(
        prefs.dismissal,
        Dismissal::Focus,
        "an empty cmux-next.json reads with the focus rule"
    );
    assert_eq!(prefs.dock_bounce, DockBounce::Once);
    assert_eq!(prefs.sounds.max_seconds, 0.0, "by default a sound plays to its end");
}

#[test]
fn sounds_parse_from_cmux_json() {
    let (prefs, diagnostics) = with_sounds(json!({
        "volume": 0.8, "when": "whenInactive", "cooldownSeconds": 3, "maxSeconds": 2.5,
        "events": {"needsInput": "Ping", "error": "Basso"},
        "groups": {"Agents & routing": {"sound": "Submarine", "volume": 0.5}},
        "workspaces": {"ws_1": "none"},
        "agents": {"codex": {"events": {"finished": "Hero"}}},
    }));
    let sounds = prefs.sounds;
    assert!(diagnostics.is_empty(), "{diagnostics:?}");
    assert_eq!(sounds.volume, 0.8);
    assert_eq!(sounds.when, SoundTiming::WhenInactive);
    assert_eq!(sounds.cooldown_seconds, 3.0);
    assert_eq!(sounds.max_seconds, 2.5);
    assert_eq!(
        sounds.events,
        BTreeMap::from([
            (SoundEvent::NeedsInput, "Ping".into()),
            (SoundEvent::Error, "Basso".into())
        ])
    );
    assert_eq!(sounds.groups["Agents & routing"], rule(Some("Submarine"), Some(0.5), &[]));
    assert_eq!(sounds.workspaces["ws_1"], rule(Some("none"), None, &[]));
    assert_eq!(sounds.agents["codex"], rule(None, None, &[(SoundEvent::Finished, "Hero")]));
}

#[test]
fn a_bad_value_keeps_its_default_with_a_diagnostic() {
    let (prefs, diagnostics) = with_sounds(json!({
        "volume": "loud", "when": "sometimes", "maxSeconds": 90,
        "events": {"ringing": "Ping"},
        "workspaces": {"ws_1": 3, "ws_2": {"sound": "Pop", "volume": 4}},
    }));
    let sounds = prefs.sounds;
    assert_eq!(sounds.volume, 1.0);
    assert_eq!(sounds.when, SoundTiming::UnlessViewed);
    assert_eq!(sounds.max_seconds, 30.0, "a duration past the longest clamps to it");
    assert!(sounds.events.is_empty());
    assert!(!sounds.workspaces.contains_key("ws_1"));
    assert_eq!(
        sounds.workspaces["ws_2"],
        rule(Some("Pop"), Some(1.0), &[]),
        "an out-of-range volume clamps"
    );
    let found = paths(&diagnostics);
    for path in [
        "notifications.sounds.volume",
        "notifications.sounds.when",
        "notifications.sounds.events.ringing",
        "notifications.sounds.workspaces.ws_1",
        "notifications.sounds.workspaces.ws_2",
    ] {
        assert!(found.contains(path), "{path} missing from {found:?}");
    }
}

#[test]
fn diagnostics_carry_swifts_messages_in_swifts_order() {
    let (_, diagnostics) = with_sounds(json!({
        "volume": "loud", "when": "sometimes", "maxSeconds": 90,
        "events": {"ringing": "Ping", "bell": 3},
        "workspaces": {"ws_1": 3},
    }));
    let got: Vec<(&str, &str)> =
        diagnostics.iter().map(|d| (d.path.as_str(), d.message.as_str())).collect();
    assert_eq!(
        got,
        [
            ("notifications.sounds.volume", "expected a number"),
            ("notifications.sounds.maxSeconds", "clamped to 0.0...30.0"),
            (
                "notifications.sounds.when",
                "expected one of \"unlessViewed\", \"whenInactive\", \"always\""
            ),
            (
                "notifications.sounds.events.ringing",
                "unknown event; expected one of finished, needsInput, error, bell, message"
            ),
            ("notifications.sounds.events.bell", "expected a string"),
            (
                "notifications.sounds.workspaces.ws_1",
                "expected a sound name or {\"sound\", \"volume\", \"events\"}"
            ),
        ]
    );
    assert!(diagnostics.iter().all(|d| d.kind == "invalidValue"));
}

#[test]
fn every_top_level_setting_parses_and_a_bad_one_is_named() {
    let (prefs, diagnostics) = parse(&json!({
        "notifications": {
            "dismissal": "timeout", "timeoutSeconds": 0, "desktop": "always", "sound": "Pop",
            "suppressWhileTypingSeconds": 2, "dockBadge": false, "dockBounce": "untilActive",
            "showPreviews": "never", "toast": {"style": "capsule"},
            "quietHours": {"start": "22:00", "end": "07:30"},
            "mutedWorkspaces": ["ws_1", "", 3, "ws_2"],
            "sources": {
                "terminal": {"dismissal": "click", "color": "#0f8", "sound": "Tink", "desktop": false},
                "cli": {},
                "agent": {"color": "theme"},
            },
        },
        "feed": {"agentPermissionPrompts": true, "mirrorNotifications": {"agents": false, "terminal": "full"}},
    }));
    assert_eq!(prefs.dismissal, Dismissal::Timeout);
    assert_eq!(prefs.timeout_seconds, 1.0);
    assert_eq!(prefs.desktop, DesktopMode::Always);
    assert_eq!(prefs.sound, "Pop");
    assert_eq!(prefs.suppress_while_typing_seconds, 2.0);
    assert!(!prefs.dock_badge);
    assert_eq!(prefs.dock_bounce, DockBounce::UntilActive);
    assert_eq!(prefs.show_previews, Previews::Never);
    assert_eq!(prefs.toast_style, ToastStyle::Capsule);
    assert_eq!(prefs.quiet_hours, Some(QuietHours { start: 22 * 60, end: 7 * 60 + 30 }));
    assert_eq!(prefs.muted_workspaces, BTreeSet::from(["ws_1".into(), "ws_2".into()]));
    let terminal = &prefs.sources[&Source::Terminal];
    assert_eq!(terminal.dismissal, Some(Dismissal::Click));
    assert_eq!(terminal.color.as_deref(), Some("#00FF88"));
    assert_eq!(terminal.sound.as_deref(), Some("Tink"));
    assert_eq!(terminal.desktop, Some(false));
    assert_eq!(
        prefs.sources[&Source::Cli],
        SourceOverrides::default(),
        "an empty entry still overrides"
    );
    assert_eq!(prefs.sources[&Source::Agent].color, None);
    assert_eq!(prefs.dismissal_for(Source::Terminal), Dismissal::Click);
    assert_eq!(prefs.dismissal_for(Source::Agent), Dismissal::Timeout);
    assert_eq!(prefs.sound_for(Source::Terminal), "Tink");
    assert!(!prefs.posts_desktop(Source::Terminal));
    assert!(prefs.posts_desktop(Source::Cli));
    assert_eq!(
        prefs.feed_mirror,
        FeedMirror {
            agents: false,
            terminal: FeedTerminalMirror::Full,
            agent_permission_prompts: true
        }
    );
    let got: Vec<(&str, &str)> =
        diagnostics.iter().map(|d| (d.path.as_str(), d.message.as_str())).collect();
    assert_eq!(
        got,
        [
            ("notifications.timeoutSeconds", "clamped to 1.0...86400.0"),
            ("notifications.mutedWorkspaces", "expected workspace ids (non-empty strings)"),
        ]
    );
}

#[test]
fn bad_top_level_values_keep_their_defaults() {
    let (prefs, diagnostics) = parse(&json!({
        "notifications": {
            "dismissal": "soon", "dockBounce": "loud", "dockBadge": "yes", "sound": 3,
            "toast": "big", "quietHours": {"start": "25:00", "end": "07:00"},
            "mutedWorkspaces": "ws_1", "sources": {"agent": {"color": "red", "desktop": 1}},
        },
        "feed": {"mirrorNotifications": 3},
    }));
    assert_eq!(prefs.dismissal, Dismissal::Focus);
    assert_eq!(prefs.dock_bounce, DockBounce::Once);
    assert!(prefs.dock_badge);
    assert_eq!(prefs.sound, "default");
    assert_eq!(prefs.quiet_hours, None);
    assert!(prefs.muted_workspaces.is_empty());
    assert_eq!(prefs.sources[&Source::Agent], SourceOverrides::default());
    let got: Vec<(&str, &str)> =
        diagnostics.iter().map(|d| (d.path.as_str(), d.message.as_str())).collect();
    assert_eq!(
        got,
        [
            ("feed.mirrorNotifications", "expected an object"),
            (
                "notifications.dismissal",
                "expected one of \"focus\", \"keystroke\", \"click\", \"explicit\", \"timeout\", \"never\""
            ),
            ("notifications.sound", "expected a string"),
            ("notifications.dockBadge", "expected true or false"),
            ("notifications.dockBounce", "expected one of \"off\", \"once\", \"untilActive\""),
            ("notifications.toast", "expected an object"),
            ("notifications.quietHours", "expected {\"start\": \"HH:MM\", \"end\": \"HH:MM\"}"),
            ("notifications.mutedWorkspaces", "expected an array of workspace ids"),
            ("notifications.sources.agent.color", "expected a #RRGGBB color"),
            ("notifications.sources.agent.desktop", "expected true or false"),
        ]
    );
}

#[test]
fn notifications_that_is_not_an_object_still_reads_the_feed() {
    let (prefs, diagnostics) =
        parse(&json!({"notifications": [], "feed": {"agentPermissionPrompts": true}}));
    assert!(prefs.feed_mirror.agent_permission_prompts);
    assert_eq!(prefs.sounds, SoundPreferences::default());
    assert_eq!(paths(&diagnostics), BTreeSet::from(["notifications"]));
}

#[test]
fn the_dock_bounce_setting_loads_from_cmux_json() {
    let (prefs, _) = parse(&json!({"notifications": {"dockBounce": "untilActive"}}));
    assert_eq!(prefs.dock_bounce, DockBounce::UntilActive);
    let (prefs, diagnostics) = parse(&json!({"notifications": {"dockBounce": "loud"}}));
    assert_eq!(prefs.dock_bounce, DockBounce::Once);
    assert!(diagnostics.iter().any(|d| d.path == "notifications.dockBounce"));
}

#[test]
fn agent_kinds_are_lowercased() {
    let (prefs, _) = with_sounds(json!({"agents": {"Claude": "Hero", "codex": "", "Codex": {}}}));
    assert_eq!(prefs.sounds.agents.keys().collect::<Vec<_>>(), ["claude", "codex"]);
    assert_eq!(prefs.sounds.agents["claude"], rule(Some("Hero"), None, &[]));
    assert_eq!(prefs.sounds.agents["codex"], rule(Some(""), None, &[]), "an empty rule is dropped");
}

#[test]
fn css_colors_read_as_swifts_theme_rgb_does() {
    for (text, hex) in [
        ("#0f8", Some("#00FF88")),
        ("00ff88", Some("#00FF88")),
        (" #A1B2C3 ", Some("#A1B2C3")),
        ("#A1B2C380", Some("#A1B2C380")),
        ("#A1B2C3FF", Some("#A1B2C3")),
        ("#12345", None),
        ("#ggg", None),
        ("red", None),
        ("\n#fff", None),
    ] {
        assert_eq!(parse::css_hex(text).as_deref(), hex, "{text:?}");
    }
}

// MARK: Rules

#[test]
fn a_rule_round_trips_through_its_json() {
    let original = rule(Some("Glass"), Some(0.25), &[(SoundEvent::NeedsInput, "Ping")]);
    let encoded = serde_json::to_value(&original).unwrap();
    assert_eq!(
        encoded,
        json!({"sound": "Glass", "volume": 0.25, "events": {"needsInput": "Ping"}})
    );
    let (parsed, problems) = parse_rule(&encoded);
    assert_eq!(parsed, Some(original));
    assert!(problems.is_empty());
    assert!(rule_accepts(&encoded));
    assert!(!rule_accepts(&json!({"sound": 3})));
    assert_eq!(serde_json::to_value(SoundRule::default()).unwrap(), json!({}));
}

#[test]
fn a_rules_problems_name_each_member() {
    let (parsed, problems) = parse_rule(&json!({
        "sound": 3, "volume": -1, "events": {"ringing": "x", "bell": 2, "error": "Basso"}, "pitch": 2,
    }));
    assert_eq!(parsed, Some(rule(None, Some(0.0), &[(SoundEvent::Error, "Basso")])));
    assert_eq!(
        problems,
        [
            "events.bell: expected a string",
            "events.ringing: unknown event; expected one of finished, needsInput, error, bell, message",
            "pitch: unknown key",
            "sound: expected a string",
            "volume: clamped to 0...1",
        ]
    );
    assert_eq!(
        parse_rule(&json!({"volume": "x", "events": 1})).1,
        ["events: expected an object", "volume: expected a number from 0 to 1",]
    );
    assert_eq!(
        parse_rule(&json!(3)),
        (None, vec!["expected a sound name or {\"sound\", \"volume\", \"events\"}".to_owned()])
    );
}

// MARK: Inheritance

#[test]
fn with_no_levels_the_global_sound_plays() {
    let sounds = SoundPreferences::default();
    assert_eq!(
        sounds.choice(SoundEvent::Finished, &scope(), "Glass"),
        Some(SoundChoice { name: "Glass".into(), volume: 1.0, level: "global".into() })
    );
}

#[test]
fn an_events_global_sound_beats_the_default_sound() {
    let mut sounds = SoundPreferences::default();
    sounds.events.insert(SoundEvent::NeedsInput, "Ping".into());
    let pick = sounds.choice(SoundEvent::NeedsInput, &scope(), "Glass").unwrap();
    assert_eq!((pick.name.as_str(), pick.level.as_str()), ("Ping", "event:needsInput"));
    assert_eq!(sounds.choice(SoundEvent::Finished, &scope(), "Glass").unwrap().name, "Glass");
}

#[test]
fn the_most_specific_level_wins() {
    let mut sounds = SoundPreferences::default();
    let name = |s: &SoundPreferences, e| s.choice(e, &scope(), "Glass").map(|c| (c.name, c.level));
    let pair = |n: &str, l: &str| Some((n.to_owned(), l.to_owned()));
    sounds.events.insert(SoundEvent::Finished, "Pop".into());
    sounds.groups.insert("Agents & routing".into(), rule(Some("Submarine"), None, &[]));
    assert_eq!(
        name(&sounds, SoundEvent::Finished),
        pair("Submarine", "group:Agents & routing"),
        "a group (by name) beats the global event sound"
    );
    sounds.groups.insert("grp_inner".into(), rule(Some("Tink"), None, &[]));
    assert_eq!(
        name(&sounds, SoundEvent::Finished),
        pair("Tink", "group:Inner"),
        "an inner group beats its outer group"
    );
    sounds.workspaces.insert("ws_1".into(), rule(Some("Frog"), None, &[]));
    assert_eq!(
        name(&sounds, SoundEvent::Finished),
        pair("Frog", "workspace:ws_1"),
        "a workspace beats its groups"
    );
    sounds.agents.insert("codex".into(), rule(None, None, &[(SoundEvent::Finished, "Hero")]));
    assert_eq!(
        name(&sounds, SoundEvent::Finished),
        pair("Hero", "agent:codex"),
        "an agent kind beats its workspace"
    );
    assert_eq!(
        name(&sounds, SoundEvent::NeedsInput),
        pair("Frog", "workspace:ws_1"),
        "the agent sets only finished; needsInput inherits"
    );
}

#[test]
fn none_mutes_a_level_but_a_more_specific_level_still_plays() {
    let mut sounds = SoundPreferences::default();
    sounds.groups.insert("grp_outer".into(), rule(Some("none"), None, &[]));
    assert_eq!(sounds.choice(SoundEvent::Finished, &scope(), "Glass"), None);
    sounds.workspaces.insert("ws_1".into(), rule(None, None, &[(SoundEvent::NeedsInput, "Ping")]));
    assert_eq!(sounds.choice(SoundEvent::NeedsInput, &scope(), "Glass").unwrap().name, "Ping");
    assert_eq!(sounds.choice(SoundEvent::Finished, &scope(), "Glass"), None);
    assert_eq!(
        SoundPreferences::default().choice(SoundEvent::Bell, &scope(), ""),
        None,
        "an empty name is silent"
    );
}

#[test]
fn volume_is_the_nearest_levels_share_of_the_master() {
    let mut sounds = SoundPreferences { volume: 0.5, ..SoundPreferences::default() };
    let volume =
        |s: &SoundPreferences| s.choice(SoundEvent::Finished, &scope(), "Glass").unwrap().volume;
    assert_eq!(volume(&sounds), 0.5);
    sounds.groups.insert("grp_outer".into(), rule(None, Some(0.5), &[]));
    assert_eq!(volume(&sounds), 0.25);
    sounds.workspaces.insert("ws_1".into(), rule(None, Some(1.0), &[]));
    assert_eq!(volume(&sounds), 0.5);
}

// MARK: Bursts

#[test]
fn a_burst_sounds_once_but_a_more_urgent_event_still_plays() {
    use SoundEvent::*;
    let mut last = None;
    let mut admitted = Vec::new();
    for (event, ms) in [
        (Finished, 0),
        (Finished, 200),
        (Bell, 400),
        (NeedsInput, 600),
        (Finished, 1000),
        (Finished, 2200),
    ] {
        let (yes, newest) = admit(event, 1000.0 + f64::from(ms) / 1000.0, 1.5, last);
        admitted.push(yes);
        last = newest;
    }
    // A second finish and a bell in the burst are silent; an agent asking still sounds; after the
    // cooldown a finish sounds again.
    assert_eq!(admitted, [true, false, false, true, false, true]);
}

#[test]
fn a_zero_cooldown_never_throttles() {
    let (first, last) = admit(SoundEvent::Finished, 5.0, 0.0, None);
    let (second, _) = admit(SoundEvent::Finished, 5.0, 0.0, last);
    assert!(first && second);
    let (negative, _) = admit(SoundEvent::Finished, 5.0, -3.0, last);
    assert!(negative, "a negative cooldown is none");
}

#[test]
fn a_burst_of_ten_finishes_sounds_once_and_an_ask_still_sounds() {
    // NotificationSoundGateTests: ten finishes 50 ms apart, then an ask, then a finish 2 s later.
    let (mut now, mut last, mut played) = (0.0, None, Vec::new());
    for _ in 0..10 {
        let (yes, newest) = admit(SoundEvent::Finished, now, 1.5, last);
        last = newest;
        if yes {
            played.push("Glass");
        }
        now += 0.05;
    }
    let (yes, newest) = admit(SoundEvent::NeedsInput, now, 1.5, last);
    last = newest;
    if yes {
        played.push("Ping");
    }
    assert_eq!(played, ["Glass", "Ping"]);
    now += 2.0;
    assert!(
        admit(SoundEvent::Finished, now, 1.5, last).0,
        "after the cooldown a finish sounds again"
    );
}

// MARK: Menu, palette and CLI edits

#[test]
fn an_edit_sets_inherits_or_clears_a_level() {
    let mut edited = apply_rule(&SoundRule::default(), Some("Glass"), None, None);
    assert_eq!(edited, rule(Some("Glass"), None, &[]));
    edited = apply_rule(&edited, Some("Ping"), Some(SoundEvent::NeedsInput), Some(0.5));
    assert_eq!(edited, rule(Some("Glass"), Some(0.5), &[(SoundEvent::NeedsInput, "Ping")]));
    assert!(
        apply_rule(&edited, Some("inherit"), Some(SoundEvent::NeedsInput), None).events.is_empty(),
        "inherit for one event clears only it"
    );
    let cleared = apply_rule(&edited, Some("inherit"), None, None);
    assert_eq!(
        cleared,
        rule(None, Some(0.5), &[]),
        "inherit for every event keeps only the volume"
    );
    assert!(apply_rule(&SoundRule::default(), Some("inherit"), None, None).is_empty());
    assert_eq!(
        apply_rule(&edited, None, None, Some(7.0)).volume,
        Some(1.0),
        "a volume clamps to 0...1"
    );
}

#[test]
fn a_level_edit_writes_its_whole_map_or_removes_it() {
    let sounds = SoundPreferences::default();
    let edit =
        edit_sounds(&sounds, &SoundLevel::Workspace("ws_1".into()), Some("Frog"), None, None);
    assert_eq!(edit.path, ["notifications", "sounds", "workspaces"]);
    assert_eq!(edit.value, Some(json!({"ws_1": {"sound": "Frog"}})));
    assert_eq!(edit.sounds.workspaces["ws_1"], rule(Some("Frog"), None, &[]));
    let back = edit_sounds(
        &edit.sounds,
        &SoundLevel::Workspace("ws_1".into()),
        Some("inherit"),
        None,
        None,
    );
    assert_eq!(back.value, None, "an empty map is removed");
    assert!(back.sounds.workspaces.is_empty());

    let edit =
        edit_sounds(&sounds, &SoundLevel::Event(SoundEvent::Bell), Some("Tink"), None, Some(0.2));
    assert_eq!(edit.path, ["notifications", "sounds", "events", "bell"]);
    assert_eq!(edit.value, Some(json!("Tink")));
    assert_eq!(edit.sounds.volume, 1.0, "an event's edit ignores the volume");
    let back = edit_sounds(
        &edit.sounds,
        &SoundLevel::Event(SoundEvent::Bell),
        Some("inherit"),
        None,
        None,
    );
    assert_eq!(back.value, None);
    let kept =
        edit_sounds(&edit.sounds, &SoundLevel::Event(SoundEvent::Bell), None, None, Some(0.5));
    assert_eq!(kept.value, Some(json!("Tink")), "no sound keeps the event's");

    let edit = edit_sounds(
        &sounds,
        &SoundLevel::Agent("codex".into()),
        Some("Hero"),
        Some(SoundEvent::Finished),
        Some(0.5),
    );
    assert_eq!(edit.path, ["notifications", "sounds", "agents"]);
    assert_eq!(edit.value, Some(json!({"codex": {"volume": 0.5, "events": {"finished": "Hero"}}})));
    let edit = edit_sounds(&sounds, &SoundLevel::Group("grp".into()), Some("Pop"), None, None);
    assert_eq!(edit.path, ["notifications", "sounds", "groups"]);
}

#[test]
fn the_checked_sound_is_the_levels_own_or_inherit() {
    let mut sounds = SoundPreferences::default();
    assert_eq!(checked_sound(&sounds, &SoundLevel::Workspace("ws_1".into()), None), "inherit");
    sounds.workspaces.insert("ws_1".into(), rule(Some("Frog"), None, &[]));
    sounds.groups.insert("Ops".into(), rule(Some("Pop"), None, &[]));
    assert_eq!(checked_sound(&sounds, &SoundLevel::Workspace("ws_1".into()), None), "Frog");
    assert_eq!(checked_sound(&sounds, &SoundLevel::Group("grp_1".into()), Some("Ops")), "Pop");
    assert_eq!(checked_sound(&sounds, &SoundLevel::Group("grp_1".into()), None), "inherit");
}

#[test]
fn a_preview_plays_the_scopes_sound_unless_muted() {
    let mut prefs = Preferences::default();
    prefs.sources.insert(
        Source::Terminal,
        SourceOverrides { sound: Some("Tink".into()), ..Default::default() },
    );
    let ws = SoundScope { workspace: Some("ws_1".into()), ..SoundScope::default() };
    assert_eq!(preview_choice(&prefs, &ws, SoundEvent::Finished).unwrap().name, "default");
    assert_eq!(
        preview_choice(&prefs, &ws, SoundEvent::Bell).unwrap().name,
        "Tink",
        "a bell falls back to the terminal's sound"
    );
    assert_eq!(source_of_event(SoundEvent::Message), Source::Cli);
    prefs.muted_workspaces.insert("ws_1".into());
    assert_eq!(preview_choice(&prefs, &ws, SoundEvent::Finished), None);
}

// MARK: Quiet hours

#[test]
fn quiet_hours_read_hh_mm_and_wrap_past_midnight() {
    assert_eq!(QuietHours::minutes("22:00"), Some(1320));
    assert_eq!(QuietHours::minutes("7:05"), Some(425));
    assert_eq!(QuietHours::minutes("::7:05"), Some(425), "Swift's split drops empty parts");
    assert_eq!(QuietHours::minutes("24:00"), None);
    assert_eq!(QuietHours::minutes("12:60"), None);
    assert_eq!(QuietHours::minutes("12"), None);
    assert_eq!(QuietHours::minutes("1:2:3"), None);
    assert_eq!(QuietHours::minutes("a:00"), None);
    let night = QuietHours { start: 22 * 60, end: 7 * 60 };
    assert!(night.contains(23 * 60) && night.contains(0) && night.contains(22 * 60));
    assert!(!night.contains(7 * 60) && !night.contains(12 * 60));
    let day = QuietHours { start: 9 * 60, end: 17 * 60 };
    assert!(day.contains(9 * 60) && !day.contains(17 * 60) && !day.contains(8 * 60));
    assert!(!QuietHours { start: 60, end: 60 }.contains(60), "an empty window is never quiet");
}

// MARK: Workspace keys

#[test]
fn a_remote_mute_saved_before_qualified_keys_stays_muted() {
    let keys = BTreeSet::from(["ws_lab".to_owned()]);
    let none = BTreeSet::new();
    assert!(
        mutes(&keys, "lab", "ws_lab", "local", &none),
        "an earlier build's remote mute was dropped on upgrade"
    );
    assert_eq!(workspace_ids(&keys, "lab", "local", &none), keys);
    assert_eq!(
        legacy_remote_key(&keys, "lab", "ws_lab", "local", &none).as_deref(),
        Some("ws_lab")
    );
    let local_has = BTreeSet::from(["ws_lab".to_owned()]);
    assert!(
        !mutes(&keys, "lab", "ws_lab", "local", &local_has),
        "a local mute reached a forked machine's same-id workspace"
    );
    assert!(workspace_ids(&keys, "lab", "local", &local_has).is_empty());
    let other = BTreeSet::from([qualified("other", "ws_lab")]);
    assert!(
        workspace_ids(&other, "lab", "local", &none).is_empty(),
        "another machine's qualified key read as a bare id"
    );
}

#[test]
fn a_remote_sound_rule_saved_before_qualified_keys_still_applies() {
    let q = qualified("lab", "ws_lab");
    let key = |rules: &[&str], local_has: bool| {
        let rules: BTreeSet<String> = rules.iter().map(|r| (*r).to_owned()).collect();
        let local: BTreeSet<String> =
            if local_has { BTreeSet::from(["ws_lab".to_owned()]) } else { BTreeSet::new() };
        rule_key("lab", "ws_lab", "local", &rules, &local)
    };
    assert_eq!(
        key(&["ws_lab"], false),
        "ws_lab",
        "an earlier build's remote sound rule was dropped on upgrade"
    );
    assert_eq!(key(&[], false), q);
    assert_eq!(key(&["ws_lab", &q], false), q);
    assert_eq!(
        key(&["ws_lab"], true),
        q,
        "a local workspace's rule reached a forked machine's same-id workspace"
    );
    let all = BTreeSet::from(["ws_lab".to_owned()]);
    assert_eq!(rule_key("local", "ws_lab", "local", &BTreeSet::new(), &all), "ws_lab");
}

#[test]
fn qualified_keys_encode_both_parts_and_decode_for_their_machine() {
    assert_eq!(qualified("lab", "ws_1"), "machine:bGFi:workspace:d3NfMQ==");
    assert_eq!(settings_key("local", "ws_1", "local"), "ws_1");
    assert_eq!(settings_key("lab", "ws_1", "local"), qualified("lab", "ws_1"));
    let keys = BTreeSet::from([
        qualified("lab", "ws_1"),
        "machine:bGFi:workspace:!!".to_owned(),
        "ws_2".to_owned(),
    ]);
    assert_eq!(
        workspace_ids(&keys, "lab", "local", &BTreeSet::new()),
        BTreeSet::from(["ws_1".to_owned(), "ws_2".to_owned()]),
        "a bad encoding is dropped"
    );
    assert_eq!(workspace_ids(&keys, "local", "local", &BTreeSet::new()), keys);
    assert!(mutes(&keys, "lab", "ws_1", "local", &BTreeSet::new()));
}

// MARK: Schema

/// The defaults and ranges here are the schema's (the Swift constants are generated from it).
#[test]
fn defaults_and_ranges_match_the_schema_source() {
    let source: Value = serde_json::from_str(include_str!(
        "../../../../../schemas/settings/source/notifications.json"
    ))
    .unwrap();
    let rows: BTreeMap<&str, &Value> = source["lists"]
        .as_array()
        .unwrap()
        .iter()
        .flat_map(|list| list["rows"].as_array().unwrap())
        .map(|row| (row["key"].as_str().unwrap(), row))
        .collect();
    let number = |key: &str, default: f64, (lo, hi): (f64, f64)| {
        let row = rows[key];
        assert_eq!(row["default"].as_f64(), Some(default), "{key} default");
        assert_eq!(
            (row["range"]["min"].as_f64(), row["range"]["max"].as_f64()),
            (Some(lo), Some(hi)),
            "{key} range"
        );
    };
    number("notifications.timeoutSeconds", defaults::TIMEOUT, defaults::TIMEOUT_RANGE);
    number("notifications.suppressWhileTypingSeconds", defaults::TYPING, defaults::TYPING_RANGE);
    number("notifications.sounds.volume", defaults::VOLUME, defaults::VOLUME_RANGE);
    number("notifications.sounds.maxSeconds", defaults::MAX_SECONDS, defaults::MAX_SECONDS_RANGE);
    number("notifications.sounds.cooldownSeconds", defaults::COOLDOWN, defaults::COOLDOWN_RANGE);
    let prefs = serde_json::to_value(Preferences::default()).unwrap();
    for (key, got) in [
        ("notifications.dismissal", &prefs["dismissal"]),
        ("notifications.desktop", &prefs["desktop"]),
        ("notifications.sound", &prefs["sound"]),
        ("notifications.dockBadge", &prefs["dockBadge"]),
        ("notifications.dockBounce", &prefs["dockBounce"]),
        ("notifications.showPreviews", &prefs["showPreviews"]),
        ("notifications.toast.style", &prefs["toastStyle"]),
        ("notifications.quietHours", &prefs["quietHours"]),
        ("notifications.mutedWorkspaces", &prefs["mutedWorkspaces"]),
        ("notifications.sounds.when", &prefs["sounds"]["when"]),
        ("feed.mirrorNotifications.agents", &prefs["feedMirror"]["agents"]),
        ("feed.mirrorNotifications.terminal", &prefs["feedMirror"]["terminal"]),
        ("feed.agentPermissionPrompts", &prefs["feedMirror"]["agentPermissionPrompts"]),
    ] {
        assert_eq!(&rows[key]["default"], got, "{key}");
    }
    for (key, names) in [
        (
            "notifications.dismissal",
            Dismissal::ALL.iter().map(|c| c.name()).collect::<BTreeSet<_>>(),
        ),
        ("notifications.desktop", DesktopMode::ALL.iter().map(|c| c.name()).collect()),
        ("notifications.dockBounce", DockBounce::ALL.iter().map(|c| c.name()).collect()),
        ("notifications.showPreviews", Previews::ALL.iter().map(|c| c.name()).collect()),
        ("notifications.toast.style", ToastStyle::ALL.iter().map(|c| c.name()).collect()),
        (
            "feed.mirrorNotifications.terminal",
            FeedTerminalMirror::ALL.iter().map(|c| c.name()).collect(),
        ),
        ("notifications.sounds.when", SoundTiming::ALL.iter().map(|c| c.name()).collect()),
    ] {
        let Some(choices) = rows[key]["choices"].as_array() else { continue };
        let schema: BTreeSet<&str> = choices.iter().map(|c| c["value"].as_str().unwrap()).collect();
        // The schema lists what the settings UI offers; the parse accepts every Swift case.
        assert!(schema.is_subset(&names), "{key} choices: {schema:?} not all in {names:?}");
    }
}
