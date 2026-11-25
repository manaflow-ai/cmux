//! Parity with the Swift tests these rules came from (`NotificationSoundTests`'s parsing cases),
//! plus each `NotificationConfigParser`, `ConfigFieldReader`, `NotificationSoundRule.parse`,
//! `QuietHours.minutes` and `ThemeRGB(cssHex:)` branch, case by case.

use super::*;
use serde_json::json;

fn notifications(value: Value) -> Parsed {
    parse(&json!({ "notifications": value }))
}

fn sounds_of(value: Value) -> Parsed {
    notifications(json!({ "sounds": value }))
}

fn paths(parsed: &Parsed) -> Vec<&str> {
    parsed.diagnostics.iter().map(|d| d.path.as_str()).collect()
}

fn message(parsed: &Parsed, path: &str) -> String {
    parsed
        .diagnostics
        .iter()
        .find(|d| d.path == path)
        .map(|d| d.message.clone())
        .unwrap_or_default()
}

fn rule(sound: Option<&str>, volume: Option<f64>, events: &[(&str, &str)]) -> SoundRule {
    SoundRule {
        sound: sound.map(Into::into),
        volume,
        events: events.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect(),
    }
}

// MARK: NotificationSoundTests

#[test]
fn sounds_parse_from_cmux_json() {
    let parsed = sounds_of(json!({
        "volume": 0.8, "when": "whenInactive", "cooldownSeconds": 3, "maxSeconds": 2.5,
        "events": {"needsInput": "Ping", "error": "Basso"},
        "groups": {"Agents & routing": {"sound": "Submarine", "volume": 0.5}},
        "workspaces": {"ws_1": "none"},
        "agents": {"codex": {"events": {"finished": "Hero"}}},
    }));
    assert!(parsed.diagnostics.is_empty(), "{:?}", parsed.diagnostics);
    let sounds = &parsed.prefs.sounds;
    assert_eq!(sounds.volume, 0.8);
    assert_eq!(sounds.when, "whenInactive");
    assert_eq!(sounds.cooldown_seconds, 3.0);
    assert_eq!(sounds.max_seconds, 2.5);
    assert_eq!(sounds.events.get("needsInput").map(String::as_str), Some("Ping"));
    assert_eq!(sounds.events.get("error").map(String::as_str), Some("Basso"));
    assert_eq!(sounds.events.len(), 2);
    assert_eq!(sounds.groups["Agents & routing"], rule(Some("Submarine"), Some(0.5), &[]));
    assert_eq!(sounds.workspaces["ws_1"], rule(Some("none"), None, &[]));
    assert_eq!(sounds.agents["codex"], rule(None, None, &[("finished", "Hero")]));
}

#[test]
fn a_bad_value_keeps_its_default_with_a_diagnostic() {
    let parsed = sounds_of(json!({
        "volume": "loud", "when": "sometimes", "maxSeconds": 90,
        "events": {"ringing": "Ping"},
        "workspaces": {"ws_1": 3, "ws_2": {"sound": "Pop", "volume": 4}},
    }));
    let sounds = &parsed.prefs.sounds;
    assert_eq!(sounds.volume, 1.0);
    assert_eq!(sounds.when, "unlessViewed");
    assert_eq!(sounds.max_seconds, 30.0, "a duration past the longest clamps to it");
    assert!(sounds.events.is_empty());
    assert!(!sounds.workspaces.contains_key("ws_1"));
    assert_eq!(
        sounds.workspaces["ws_2"],
        rule(Some("Pop"), Some(1.0), &[]),
        "an out-of-range volume clamps"
    );
    let found = paths(&parsed);
    for path in [
        "notifications.sounds.volume",
        "notifications.sounds.when",
        "notifications.sounds.events.ringing",
        "notifications.sounds.workspaces.ws_1",
        "notifications.sounds.workspaces.ws_2",
    ] {
        assert!(found.contains(&path), "{path} missing from {found:?}");
    }
    assert_eq!(message(&parsed, "notifications.sounds.volume"), "expected a number");
    assert_eq!(
        message(&parsed, "notifications.sounds.when"),
        "expected one of \"unlessViewed\", \"whenInactive\", \"always\""
    );
    assert_eq!(message(&parsed, "notifications.sounds.maxSeconds"), "clamped to 0.0...30.0");
    assert_eq!(
        message(&parsed, "notifications.sounds.events.ringing"),
        "unknown event; expected one of finished, needsInput, error, bell, message"
    );
    assert_eq!(
        message(&parsed, "notifications.sounds.workspaces.ws_1"),
        "expected a sound name or {\"sound\", \"volume\", \"events\"}"
    );
    assert_eq!(
        message(&parsed, "notifications.sounds.workspaces.ws_2"),
        "volume: clamped to 0...1"
    );
}

#[test]
fn a_rule_round_trips_through_its_json() {
    let value = json!({"sound": "Glass", "volume": 0.25, "events": {"needsInput": "Ping"}});
    let mut problems = Vec::new();
    assert_eq!(
        parse_sound_rule(&value, &mut problems),
        Some(rule(Some("Glass"), Some(0.25), &[("needsInput", "Ping")]))
    );
    assert!(problems.is_empty());
    assert!(accepts_sound_rule(&value));
    assert!(!accepts_sound_rule(&json!({"sound": 3})));
}

// MARK: The defaults

#[test]
fn no_notifications_key_keeps_every_default() {
    let parsed = parse(&json!({}));
    assert!(parsed.diagnostics.is_empty());
    assert_eq!(parsed.prefs, Prefs::default());
    let prefs = Prefs::default();
    assert_eq!(prefs.dismissal, "focus");
    assert_eq!(prefs.timeout_seconds, 30.0);
    assert_eq!(prefs.desktop, "unlessFocused");
    assert_eq!(prefs.sound, "default");
    assert_eq!(prefs.suppress_while_typing_seconds, 0.0);
    assert!(prefs.dock_badge);
    assert_eq!(prefs.dock_bounce, "once");
    assert_eq!(prefs.show_previews, "whenUnlocked");
    assert_eq!(prefs.toast_style, "standard");
    assert_eq!(prefs.sounds.cooldown_seconds, 1.5);
    assert_eq!(
        prefs.feed_mirror,
        FeedMirror { agents: true, terminal: "off".into(), agent_permission_prompts: false }
    );
}

#[test]
fn a_root_that_is_not_an_object_reads_as_no_settings() {
    for root in [json!(null), json!(3), json!([1])] {
        let parsed = parse(&root);
        assert!(parsed.diagnostics.is_empty());
        assert_eq!(parsed.prefs, Prefs::default());
    }
}

#[test]
fn notifications_that_is_not_an_object_is_one_diagnostic() {
    let parsed = notifications(json!("loud"));
    assert_eq!(
        parsed.diagnostics,
        vec![Diagnostic::invalid("notifications", "expected an object")]
    );
    assert_eq!(parsed.prefs, Prefs::default());
}

// MARK: The top-level fields

#[test]
fn every_top_level_field_parses() {
    let parsed = notifications(json!({
        "dismissal": "keystroke", "timeoutSeconds": 120, "desktop": "always", "sound": "Glass",
        "suppressWhileTypingSeconds": 4, "dockBadge": false, "dockBounce": "untilActive",
        "showPreviews": "never", "toast": {"style": "v2"},
        "quietHours": {"start": "22:00", "end": "07:30"},
        "mutedWorkspaces": ["ws_1", "ws_2", "ws_1"],
    }));
    assert!(parsed.diagnostics.is_empty(), "{:?}", parsed.diagnostics);
    let prefs = &parsed.prefs;
    assert_eq!(prefs.dismissal, "keystroke");
    assert_eq!(prefs.timeout_seconds, 120.0);
    assert_eq!(prefs.desktop, "always");
    assert_eq!(prefs.sound, "Glass");
    assert_eq!(prefs.suppress_while_typing_seconds, 4.0);
    assert!(!prefs.dock_badge);
    assert_eq!(prefs.dock_bounce, "untilActive");
    assert_eq!(prefs.show_previews, "never");
    assert_eq!(prefs.toast_style, "v2");
    assert_eq!(prefs.quiet_hours, Some(QuietHours { start: 22 * 60, end: 7 * 60 + 30 }));
    assert_eq!(prefs.muted_workspaces, ["ws_1".to_owned(), "ws_2".to_owned()].into());
}

#[test]
fn each_bad_top_level_field_keeps_its_default_in_reading_order() {
    let parsed = notifications(json!({
        "dismissal": "later", "timeoutSeconds": 0, "desktop": true, "sound": 3,
        "suppressWhileTypingSeconds": 61, "dockBadge": "yes", "dockBounce": "twice",
        "showPreviews": 1, "toast": {"style": "neon"},
    }));
    let expected = [
        (
            "notifications.dismissal",
            "expected one of \"focus\", \"keystroke\", \"click\", \"explicit\", \"timeout\", \"never\"",
        ),
        ("notifications.timeoutSeconds", "clamped to 1.0...86400.0"),
        (
            "notifications.desktop",
            "expected one of \"unlessFocused\", \"always\", \"whenInactive\", \"never\"",
        ),
        ("notifications.sound", "expected a string"),
        ("notifications.suppressWhileTypingSeconds", "clamped to 0.0...60.0"),
        ("notifications.dockBadge", "expected true or false"),
        ("notifications.dockBounce", "expected one of \"off\", \"once\", \"untilActive\""),
        ("notifications.showPreviews", "expected one of \"always\", \"whenUnlocked\", \"never\""),
        (
            "notifications.toast.style",
            "expected one of \"standard\", \"capsule\", \"compact\", \"iconCard\", \"filledAction\", \"hoverClose\", \"progressRing\", \"trailing\", \"accentTinted\", \"solid\", \"flat\", \"v2\"",
        ),
    ];
    let got: Vec<(&str, &str)> =
        parsed.diagnostics.iter().map(|d| (d.path.as_str(), d.message.as_str())).collect();
    assert_eq!(got, expected);
    assert!(parsed.diagnostics.iter().all(|d| d.kind == "invalidValue"));
    let prefs = &parsed.prefs;
    assert_eq!(
        prefs.timeout_seconds, 1.0,
        "an out-of-range number clamps rather than keeping its default"
    );
    assert_eq!(prefs.suppress_while_typing_seconds, 60.0);
    assert_eq!(prefs.dismissal, "focus");
    assert_eq!(prefs.sound, "default");
    assert!(prefs.dock_badge);
    assert_eq!(prefs.toast_style, "standard");
}

#[test]
fn toast_that_is_not_an_object_is_a_diagnostic_at_its_path() {
    let parsed = notifications(json!({"toast": "v2"}));
    assert_eq!(
        parsed.diagnostics,
        vec![Diagnostic::invalid("notifications.toast", "expected an object")]
    );
}

// MARK: Quiet hours

#[test]
fn quiet_hours_null_is_none_without_a_diagnostic() {
    let parsed = notifications(json!({"quietHours": null}));
    assert!(parsed.diagnostics.is_empty());
    assert_eq!(parsed.prefs.quiet_hours, None);
}

#[test]
fn bad_quiet_hours_are_one_diagnostic() {
    for value in [
        json!("22:00-07:00"),
        json!({"start": "22:00"}),
        json!({"start": "24:00", "end": "07:00"}),
        json!({"start": "22:00", "end": 7}),
    ] {
        let parsed = notifications(json!({ "quietHours": value }));
        assert_eq!(
            parsed.diagnostics,
            vec![Diagnostic::invalid(
                "notifications.quietHours",
                "expected {\"start\": \"HH:MM\", \"end\": \"HH:MM\"}"
            )],
            "{value}"
        );
        assert_eq!(parsed.prefs.quiet_hours, None);
    }
}

#[test]
fn quiet_hours_minutes_read_hh_mm() {
    assert_eq!(quiet_hours_minutes("00:00"), Some(0));
    assert_eq!(quiet_hours_minutes("23:59"), Some(23 * 60 + 59));
    assert_eq!(quiet_hours_minutes("7:05"), Some(7 * 60 + 5));
    assert_eq!(quiet_hours_minutes("24:00"), None);
    assert_eq!(quiet_hours_minutes("12:60"), None);
    assert_eq!(quiet_hours_minutes("12"), None);
    assert_eq!(quiet_hours_minutes("1:2:3"), None);
    assert_eq!(quiet_hours_minutes("ab:cd"), None);
    assert_eq!(quiet_hours_minutes(" 7:00"), None, "Int() takes no spaces");
    assert_eq!(quiet_hours_minutes(""), None);
}

#[test]
fn quiet_hours_minutes_keep_swifts_split_and_int() {
    // `split(separator:)` drops empty pieces; `Int("+7")` is 7, `Int("-0")` is 0.
    assert_eq!(quiet_hours_minutes("12::30"), Some(12 * 60 + 30));
    assert_eq!(quiet_hours_minutes(":12:30:"), Some(12 * 60 + 30));
    assert_eq!(quiet_hours_minutes("+7:00"), Some(7 * 60));
    assert_eq!(quiet_hours_minutes("-0:00"), Some(0));
    assert_eq!(quiet_hours_minutes("-1:00"), None);
    assert_eq!(quiet_hours_minutes("+:00"), None);
}

// MARK: Muted workspaces

#[test]
fn muted_workspaces_must_be_an_array() {
    let parsed = notifications(json!({"mutedWorkspaces": "ws_1"}));
    assert_eq!(
        parsed.diagnostics,
        vec![Diagnostic::invalid(
            "notifications.mutedWorkspaces",
            "expected an array of workspace ids"
        )]
    );
    assert!(parsed.prefs.muted_workspaces.is_empty());
}

#[test]
fn a_bad_muted_id_is_dropped_and_the_valid_ones_apply() {
    let parsed = notifications(json!({"mutedWorkspaces": ["ws_1", "", 3, null, "ws_2"]}));
    assert_eq!(
        parsed.diagnostics,
        vec![Diagnostic::invalid(
            "notifications.mutedWorkspaces",
            "expected workspace ids (non-empty strings)"
        )]
    );
    assert_eq!(parsed.prefs.muted_workspaces, ["ws_1".to_owned(), "ws_2".to_owned()].into());
}

// MARK: Sources

#[test]
fn each_source_reads_its_overrides() {
    let parsed = notifications(json!({"sources": {
        "cli": {"dismissal": "click", "color": "#ff8800", "sound": "Pop", "desktop": false},
        "terminal": {"color": "theme"},
        "agent": {"color": null},
    }}));
    assert!(parsed.diagnostics.is_empty(), "{:?}", parsed.diagnostics);
    let sources = &parsed.prefs.sources;
    assert_eq!(
        sources["cli"],
        SourceOverrides {
            dismissal: Some("click".into()),
            color: Some(Rgb { hex: 0xFF8800, alpha: 1.0 }),
            sound: Some("Pop".into()),
            desktop: Some(false),
        }
    );
    assert_eq!(sources["terminal"], SourceOverrides::default(), "\"theme\" is the theme's color");
    assert_eq!(sources["agent"], SourceOverrides::default(), "null is the theme's color");
}

#[test]
fn a_source_not_in_the_file_has_no_entry_and_an_unknown_source_is_ignored() {
    let parsed = notifications(json!({"sources": {"cli": {}, "robot": {"sound": 3}}}));
    assert!(parsed.diagnostics.is_empty());
    assert_eq!(parsed.prefs.sources.keys().collect::<Vec<_>>(), ["cli"]);
}

#[test]
fn bad_source_fields_are_diagnostics_in_source_order() {
    let parsed = notifications(json!({"sources": {
        "agent": {"color": "red", "desktop": "yes"},
        "cli": {"color": 3, "dismissal": "soon"},
        "terminal": "loud",
    }}));
    let got: Vec<(&str, &str)> =
        parsed.diagnostics.iter().map(|d| (d.path.as_str(), d.message.as_str())).collect();
    assert_eq!(
        got,
        [
            (
                "notifications.sources.cli.dismissal",
                "expected one of \"focus\", \"keystroke\", \"click\", \"explicit\", \"timeout\", \"never\""
            ),
            ("notifications.sources.cli.color", "expected a #RRGGBB color"),
            ("notifications.sources.terminal", "expected an object"),
            ("notifications.sources.agent.color", "expected a #RRGGBB color"),
            ("notifications.sources.agent.desktop", "expected true or false"),
        ]
    );
    assert_eq!(parsed.prefs.sources["cli"], SourceOverrides::default());
    assert!(!parsed.prefs.sources.contains_key("terminal"));
}

// MARK: Feed mirror

#[test]
fn the_feed_mirror_reads_outside_notifications() {
    let parsed = parse(&json!({
        "feed": {"agentPermissionPrompts": true, "mirrorNotifications": {"agents": false, "terminal": "full"}},
        "notifications": 3,
    }));
    assert_eq!(
        parsed.prefs.feed_mirror,
        FeedMirror { agents: false, terminal: "full".into(), agent_permission_prompts: true },
        "feed is read before notifications' early return"
    );
    assert_eq!(
        parsed.diagnostics,
        vec![Diagnostic::invalid("notifications", "expected an object")]
    );
}

#[test]
fn bad_feed_fields_keep_their_defaults() {
    let parsed = parse(&json!({
        "feed": {"agentPermissionPrompts": 1, "mirrorNotifications": {"agents": "no", "terminal": "some"}},
    }));
    let got: Vec<(&str, &str)> =
        parsed.diagnostics.iter().map(|d| (d.path.as_str(), d.message.as_str())).collect();
    assert_eq!(
        got,
        [
            ("feed.agentPermissionPrompts", "expected true or false"),
            ("feed.mirrorNotifications.agents", "expected true or false"),
            ("feed.mirrorNotifications.terminal", "expected one of \"off\", \"title\", \"full\""),
        ]
    );
    assert_eq!(parsed.prefs.feed_mirror, FeedMirror::default());
    let not_object = parse(&json!({"feed": {"mirrorNotifications": []}}));
    assert_eq!(
        not_object.diagnostics,
        vec![Diagnostic::invalid("feed.mirrorNotifications", "expected an object")]
    );
}

// MARK: Sounds

#[test]
fn sound_numbers_clamp_with_their_range_in_the_message() {
    let parsed = sounds_of(json!({"volume": -1, "cooldownSeconds": 61}));
    assert_eq!(parsed.prefs.sounds.volume, 0.0);
    assert_eq!(parsed.prefs.sounds.cooldown_seconds, 60.0);
    assert_eq!(message(&parsed, "notifications.sounds.volume"), "clamped to 0.0...1.0");
    assert_eq!(message(&parsed, "notifications.sounds.cooldownSeconds"), "clamped to 0.0...60.0");
}

#[test]
fn unknown_events_come_in_sorted_order_and_a_known_one_still_applies() {
    let parsed =
        sounds_of(json!({"events": {"zap": "Ping", "bell": "Tink", "alarm": "Pop", "error": 3}}));
    let got: Vec<(&str, &str)> =
        parsed.diagnostics.iter().map(|d| (d.path.as_str(), d.message.as_str())).collect();
    let unknown = "unknown event; expected one of finished, needsInput, error, bell, message";
    assert_eq!(
        got,
        [
            ("notifications.sounds.events.alarm", unknown),
            ("notifications.sounds.events.zap", unknown),
            ("notifications.sounds.events.error", "expected a string"),
        ],
        "unknown names first (in the loop), the reader's own diagnostics after it"
    );
    assert_eq!(parsed.prefs.sounds.events.len(), 1);
    assert_eq!(parsed.prefs.sounds.events["bell"], "Tink");
}

#[test]
fn a_level_map_that_is_not_an_object_is_a_diagnostic() {
    let parsed = sounds_of(json!({"groups": ["Agents"], "events": "Ping"}));
    assert_eq!(
        paths(&parsed),
        ["notifications.sounds.events", "notifications.sounds.groups"],
        "events is read before the level maps"
    );
    assert!(parsed.prefs.sounds.groups.is_empty());
}

#[test]
fn an_empty_rule_is_dropped_without_a_diagnostic() {
    let parsed = sounds_of(json!({"workspaces": {"ws_1": {}, "ws_2": {"events": {}}}}));
    assert!(parsed.diagnostics.is_empty());
    assert!(parsed.prefs.sounds.workspaces.is_empty());
}

#[test]
fn agent_names_are_lowercased_and_the_first_sorted_wins() {
    let parsed = sounds_of(json!({"agents": {"Codex": "Hero", "codex": "Pop", "CLAUDE": "Ping"}}));
    let agents = &parsed.prefs.sounds.agents;
    assert_eq!(agents.keys().collect::<Vec<_>>(), ["claude", "codex"]);
    assert_eq!(agents["codex"].sound.as_deref(), Some("Hero"), "\"Codex\" sorts before \"codex\"");
}

#[test]
fn the_sounds_object_itself_must_be_an_object() {
    let parsed = sounds_of(json!("Glass"));
    assert_eq!(
        parsed.diagnostics,
        vec![Diagnostic::invalid("notifications.sounds", "expected an object")]
    );
    assert_eq!(parsed.prefs.sounds, SoundPrefs::default());
}

// MARK: NotificationSoundRule.parse

#[test]
fn a_plain_string_is_a_sound_rule() {
    let mut problems = Vec::new();
    assert_eq!(
        parse_sound_rule(&json!("Glass"), &mut problems),
        Some(rule(Some("Glass"), None, &[]))
    );
    assert_eq!(parse_sound_rule(&json!(""), &mut problems), Some(rule(Some(""), None, &[])));
    assert!(problems.is_empty());
}

#[test]
fn each_bad_rule_member_is_a_problem_and_the_rest_apply() {
    let mut problems = Vec::new();
    let parsed = parse_sound_rule(
        &json!({
            "sound": 1, "volume": "loud", "events": {"bell": "Tink", "ring": "Pop", "error": false},
            "colour": "red",
        }),
        &mut problems,
    );
    assert_eq!(parsed, Some(rule(None, None, &[("bell", "Tink")])));
    assert_eq!(
        problems,
        [
            "colour: unknown key",
            "events.error: expected a string",
            "events.ring: unknown event; expected one of finished, needsInput, error, bell, message",
            "sound: expected a string",
            "volume: expected a number from 0 to 1",
        ]
    );
}

#[test]
fn a_rule_volume_clamps_and_events_must_be_an_object() {
    let mut problems = Vec::new();
    assert_eq!(
        parse_sound_rule(&json!({"volume": -0.5}), &mut problems),
        Some(rule(None, Some(0.0), &[]))
    );
    assert_eq!(
        parse_sound_rule(&json!({"events": "Ping"}), &mut problems),
        Some(SoundRule::default())
    );
    assert_eq!(problems, ["volume: clamped to 0...1", "events: expected an object"]);
}

#[test]
fn a_rule_that_is_neither_a_string_nor_an_object_is_refused() {
    for value in [json!(3), json!(null), json!(true), json!(["Glass"])] {
        let mut problems = Vec::new();
        assert_eq!(parse_sound_rule(&value, &mut problems), None);
        assert_eq!(problems, ["expected a sound name or {\"sound\", \"volume\", \"events\"}"]);
        assert!(!accepts_sound_rule(&value));
    }
}

#[test]
fn an_empty_rule_is_empty() {
    assert!(SoundRule::default().is_empty());
    assert!(!rule(Some("none"), None, &[]).is_empty());
    assert!(!rule(None, Some(0.0), &[]).is_empty());
    assert!(!rule(None, None, &[("bell", "Tink")]).is_empty());
    assert!(accepts_sound_rule(&json!({})), "an empty object parses with no problem");
}

// MARK: ThemeRGB(cssHex:)

#[test]
fn css_hex_reads_three_six_and_eight_digits() {
    assert_eq!(css_hex("#ff8800"), Some(Rgb { hex: 0xFF8800, alpha: 1.0 }));
    assert_eq!(css_hex("FF8800"), Some(Rgb { hex: 0xFF8800, alpha: 1.0 }), "the # is optional");
    assert_eq!(css_hex("#f80"), Some(Rgb { hex: 0xFF8800, alpha: 1.0 }), "each nibble doubles");
    assert_eq!(css_hex("#ff880080"), Some(Rgb { hex: 0xFF8800, alpha: 128.0 / 255.0 }));
    assert_eq!(css_hex("  #abc\t"), Some(Rgb { hex: 0xAABBCC, alpha: 1.0 }), "blanks trim");
}

#[test]
fn css_hex_refuses_anything_else() {
    for text in
        ["", "#", "#ff88", "#ff88001", "#gg8800", "##ff8800", "red", "#ff8800\n", "+f80", "#ｆ80"]
    {
        assert_eq!(css_hex(text), None, "{text:?}");
    }
}
