use super::*;

fn ask(scope: &str, property: Option<&str>, set: bool) -> AppearanceAsk {
    AppearanceAsk { scope: Some(scope.to_owned()), property: property.map(str::to_owned), set }
}

fn apply(level: &str, theme_action: Option<&'static str>, properties: &[&str]) -> Appearance {
    Appearance::Apply {
        level: level.to_owned(),
        theme_action,
        properties: properties.iter().map(|property| (*property).to_owned()).collect(),
    }
}

#[test]
fn a_scope_must_be_a_verbs_level_and_a_property_known() {
    for scope in ["app", "rule", "screen"] {
        assert_eq!(
            appearance(ask(scope, Some("tint"), true)),
            Appearance::Refused { refusal: AppearanceRefusal::BadProperty }
        );
    }
    assert_eq!(
        appearance(ask("pane", Some("glow"), false)),
        Appearance::Refused { refusal: AppearanceRefusal::BadProperty }
    );
    assert_eq!(
        appearance(AppearanceAsk::default()),
        Appearance::Refused { refusal: AppearanceRefusal::BadProperty }
    );
}

#[test]
fn set_needs_a_property_set_at_the_level() {
    assert_eq!(
        appearance(ask("pane", None, true)),
        Appearance::Refused { refusal: AppearanceRefusal::BadProperty }
    );
    assert_eq!(
        appearance(ask("tab", Some("background"), true)),
        Appearance::Refused { refusal: AppearanceRefusal::NotAtLevel }
    );
    assert_eq!(appearance(ask("pane", Some("tint"), true)), apply("pane", None, &["tint"]));
}

#[test]
fn a_levels_theme_goes_through_its_theme_action() {
    assert_eq!(
        appearance(ask("window", Some("theme"), true)),
        apply("window", Some("space.setTheme"), &[])
    );
    assert_eq!(appearance(ask("pane", Some("theme"), true)), apply("pane", None, &["theme"]));
    assert_eq!(
        appearance(ask("tab", Some("theme"), false)),
        apply("tab", Some("terminal.clearTheme"), &[])
    );
}

#[test]
fn reset_with_no_property_resets_every_one_and_forwards_the_theme() {
    assert_eq!(
        appearance(ask("workspace", None, false)),
        apply(
            "workspace",
            Some("workspace.clearTheme"),
            &["background", "tint", "opacity", "fontSize", "cursorStyle"]
        )
    );
    assert_eq!(
        appearance(ask("pane", None, false)),
        apply("pane", None, &["theme", "background", "tint", "opacity", "fontSize", "cursorStyle"])
    );
    assert_eq!(appearance(ask("window", Some("tint"), false)), apply("window", None, &["tint"]));
}

#[test]
fn a_reset_skips_a_property_not_set_at_the_level() {
    assert_eq!(appearance(ask("tab", Some("background"), false)), apply("tab", None, &[]));
    assert_eq!(appearance(ask("workspace", Some("blur"), false)), apply("workspace", None, &[]));
    assert_eq!(
        appearance(ask("workspace", Some("blur"), true)),
        Appearance::Refused { refusal: AppearanceRefusal::NotAtLevel }
    );
}

#[test]
fn theme_actions_per_level() {
    assert_eq!(theme_action("window", true), Some("space.setTheme"));
    assert_eq!(theme_action("workspace", false), Some("workspace.clearTheme"));
    assert_eq!(theme_action("tab", true), Some("terminal.setTheme"));
    assert_eq!(theme_action("pane", true), None);
}

#[test]
fn a_style_turns_a_ring_that_was_off_on() {
    assert_eq!(
        focus_ring_style("glow", true),
        vec![Edit { path: vec!["focusRing", "style"], value: EditValue::Text("glow".to_owned()) }]
    );
    assert_eq!(
        focus_ring_style("ring", false)[1],
        Edit { path: vec!["focusRing", "enabled"], value: EditValue::Flag(true) }
    );
}

#[test]
fn the_keymap_toast_says_what_changed() {
    assert_eq!(
        keymap_toast("tmux", &[]),
        KeymapToast {
            lines: vec![KeymapLine::Title, KeymapLine::NoChanges],
            undo: false,
            seconds: 6
        }
    );
    let changed = vec!["selectSurfaceByNumber".to_owned()];
    assert_eq!(
        keymap_toast("iterm2", &changed),
        KeymapToast {
            lines: vec![KeymapLine::Title, KeymapLine::ITerm2Numbers],
            undo: true,
            seconds: 10
        }
    );
    assert_eq!(keymap_toast("tmux", &changed).lines, vec![KeymapLine::Title]);
}
