//! Tests for key bindings, chords and shortcut labels.

use super::*;

#[test]
fn macos_option_as_alt_is_an_explicit_input_mode() {
    let mut keys = Keys::default();
    assert!(keys.macos_option_as_alt);

    keys.apply(&HashMap::from([("macos_option_as_alt".to_string(), Value::Bool(false))]));
    assert!(!keys.macos_option_as_alt);

    keys.apply(&HashMap::from([(
        "macos_option_as_alt".to_string(),
        Value::String("guess".to_string()),
    )]));
    assert!(!keys.macos_option_as_alt);
}

#[test]
fn default_key_table_has_no_duplicate_chords_or_reserved_alt_words() {
    let keys = Keys::default();
    for (i, (left, _)) in keys.bindings.iter().enumerate() {
        assert!(
            !keys.bindings.iter().skip(i + 1).any(|(right, _)| left == right),
            "duplicate default chord: {left:?}"
        );
    }
    assert_eq!(
        keys.bindings
            .iter()
            .filter(|(chord, action)| chord == &keys.prefix && *action == Action::SendPrefix)
            .count(),
        1,
        "the prefix chord must resolve only to the send-prefix action"
    );
    for c in ['b', 'f', 'd', '.'] {
        assert_eq!(
            keys.modeless_action_for(&KeyEvent::new(KeyCode::Char(c), KeyModifiers::ALT)),
            None
        );
    }
}

#[test]
fn default_terminal_clear_shortcuts_keep_ctrl_l_child_owned() {
    let keys = Keys::default();
    let action = |code, modifiers| keys.modeless_action_for(&KeyEvent::new(code, modifiers));
    assert_eq!(action(KeyCode::Char('k'), KeyModifiers::SUPER), Some(Action::ClearHistory));
    assert_eq!(action(KeyCode::Char('l'), KeyModifiers::CONTROL), None);
    assert_eq!(action(KeyCode::Char('k'), KeyModifiers::SUPER | KeyModifiers::CONTROL), None);
    assert_eq!(action(KeyCode::Char('k'), KeyModifiers::SUPER | KeyModifiers::ALT), None);
    assert_eq!(action(KeyCode::Char('t'), KeyModifiers::SUPER), None);
    assert_eq!(action(KeyCode::Char('w'), KeyModifiers::SUPER), None);
    assert_eq!(action(KeyCode::Char('d'), KeyModifiers::SUPER), None);
}

#[test]
fn super_shortcuts_can_be_disabled_or_configured_explicitly() {
    let mut keys = Keys::default();
    keys.apply(&HashMap::from([("super_shortcuts".to_string(), Value::Bool(false))]));
    assert_eq!(
        keys.modeless_action_for(&KeyEvent::new(KeyCode::Char('k'), KeyModifiers::SUPER)),
        None
    );
    assert_eq!(
        keys.modeless_action_for(&KeyEvent::new(KeyCode::Char('l'), KeyModifiers::CONTROL)),
        None
    );

    keys.apply(&HashMap::from([(
        "clear-history".to_string(),
        Value::String("command+l".to_string()),
    )]));
    assert_eq!(
        keys.modeless_action_for(&KeyEvent::new(KeyCode::Char('l'), KeyModifiers::SUPER)),
        Some(Action::ClearHistory)
    );
    assert_eq!(
        parse_chord("cmd+shift+d"),
        Some(Chord { code: KeyCode::Char('D'), mods: KeyModifiers::SUPER })
    );
    assert_eq!(
        parse_chord("super+shift+["),
        Some(Chord { code: KeyCode::Char('{'), mods: KeyModifiers::SUPER })
    );
}

#[test]
fn ordinary_binding_collision_preserves_doubled_prefix_passthrough() {
    let mut keys = Keys::default();
    let mut raw = HashMap::new();
    raw.insert(
        "new-tab".to_string(),
        Value::Array(vec![Value::String("ctrl+b".to_string()), Value::String("f".to_string())]),
    );

    keys.apply(&raw);

    assert_eq!(
        keys.action_for(&KeyEvent::new(KeyCode::Char('b'), KeyModifiers::CONTROL)),
        Some(Action::SendPrefix)
    );
    assert_eq!(
        keys.action_for(&KeyEvent::new(KeyCode::Char('f'), KeyModifiers::NONE)),
        Some(Action::NewTab)
    );
}

#[test]
fn key_dispatch_refreshes_after_rebinding_and_keeps_modeless_fallback() {
    let mut keys = Keys::default();
    assert_eq!(
        keys.action_for(&KeyEvent::new(KeyCode::Char('g'), KeyModifiers::NONE)),
        Some(Action::NewPaneRight)
    );
    assert_eq!(
        keys.modeless_action_for(&KeyEvent::new(KeyCode::Char('t'), KeyModifiers::ALT)),
        Some(Action::NewTab)
    );

    keys.apply(&HashMap::from([
        ("new-tab".to_string(), Value::String("g".to_string())),
        ("new-pane-right".to_string(), Value::String("alt+h".to_string())),
    ]));

    // Rebinding steals the ordinary chord while preserving modeless
    // fallback lookup for the newly configured Alt chord.
    assert_eq!(
        keys.action_for(&KeyEvent::new(KeyCode::Char('g'), KeyModifiers::NONE)),
        Some(Action::NewTab)
    );
    assert_eq!(
        keys.modeless_action_for(&KeyEvent::new(KeyCode::Char('h'), KeyModifiers::ALT)),
        Some(Action::NewPaneRight)
    );
    assert_eq!(
        keys.modeless_action_for(&KeyEvent::new(KeyCode::Char('t'), KeyModifiers::ALT)),
        None
    );
}

#[test]
fn shifted_character_chords_match_enhanced_base_key_events() {
    let shifted_letter = parse_chord("super+shift+d").unwrap();
    assert!(
        shifted_letter
            .matches(
                &KeyEvent::new(KeyCode::Char('d'), KeyModifiers::SUPER | KeyModifiers::SHIFT,)
            )
    );

    let shifted_symbol = parse_chord("super+shift+[").unwrap();
    assert!(
        shifted_symbol
            .matches(
                &KeyEvent::new(KeyCode::Char('['), KeyModifiers::SUPER | KeyModifiers::SHIFT,)
            )
    );

    let plain_letter = parse_chord("super+d").unwrap();
    assert!(
        !plain_letter
            .matches(
                &KeyEvent::new(KeyCode::Char('d'), KeyModifiers::SUPER | KeyModifiers::SHIFT,)
            )
    );
}

#[test]
fn shift_is_preserved_without_a_shifted_ascii_character() {
    for (raw, character) in [("shift+space", ' '), ("shift+é", 'é')] {
        let chord = parse_chord(raw).unwrap();
        assert_eq!(chord, Chord { code: KeyCode::Char(character), mods: KeyModifiers::SHIFT });
        assert!(chord.matches(&KeyEvent::new(KeyCode::Char(character), KeyModifiers::SHIFT,)));
        assert!(!chord.matches(&KeyEvent::new(KeyCode::Char(character), KeyModifiers::NONE,)));
    }
}

#[test]
fn sidebar_view_defaults_parses_and_unknown_values_fall_back_with_warning() {
    assert_eq!(Sidebar::default().view, SidebarView::Workspaces);
    assert_eq!(parse_sidebar_view("files"), Ok(SidebarView::Files));
    assert_eq!(parse_sidebar_view("workspaces"), Ok(SidebarView::Workspaces));

    let warning = parse_sidebar_view("tree").unwrap_err();
    assert!(warning.contains("unknown sidebar.view \"tree\""));
    let mut sidebar = Sidebar::default();
    if let Ok(view) = parse_sidebar_view("tree") {
        sidebar.view = view;
    }
    assert_eq!(sidebar.view, SidebarView::Workspaces);
}

#[test]
fn close_tab_uses_the_primary_lowercase_binding() {
    let keys = Keys::default();
    assert_eq!(
        keys.action_for(&KeyEvent::new(KeyCode::Char('x'), KeyModifiers::NONE)),
        Some(Action::CloseTab)
    );
    assert_eq!(
        keys.action_for(&KeyEvent::new(KeyCode::Char('X'), KeyModifiers::SHIFT)),
        Some(Action::ClosePane)
    );
}

#[test]
fn close_tab_and_pane_bindings_are_configurable_independently() {
    let mut keys = Keys::default();
    let mut raw = HashMap::new();
    raw.insert("close-tab".to_string(), Value::String("q".to_string()));
    raw.insert("close-pane".to_string(), Value::String("Q".to_string()));
    keys.apply(&raw);

    assert_eq!(
        keys.action_for(&KeyEvent::new(KeyCode::Char('q'), KeyModifiers::NONE)),
        Some(Action::CloseTab)
    );
    assert_eq!(
        keys.action_for(&KeyEvent::new(KeyCode::Char('Q'), KeyModifiers::SHIFT)),
        Some(Action::ClosePane)
    );
    assert_eq!(keys.action_for(&KeyEvent::new(KeyCode::Char('x'), KeyModifiers::NONE)), None);
    assert_eq!(keys.action_for(&KeyEvent::new(KeyCode::Char('X'), KeyModifiers::SHIFT)), None);
}

#[test]
fn workspace_defaults_cover_previous_next_create_and_close() {
    let keys = Keys::default();
    assert_eq!(
        keys.action_for(&KeyEvent::new(KeyCode::Char('('), KeyModifiers::SHIFT)),
        Some(Action::PrevWorkspace)
    );
    assert_eq!(
        keys.action_for(&KeyEvent::new(KeyCode::Char(')'), KeyModifiers::SHIFT)),
        Some(Action::NextWorkspace)
    );
    assert_eq!(
        keys.modeless_action_for(&KeyEvent::new(
            KeyCode::Char('{'),
            KeyModifiers::ALT | KeyModifiers::SHIFT,
        )),
        Some(Action::PrevWorkspace)
    );
    assert_eq!(
        keys.modeless_action_for(&KeyEvent::new(
            KeyCode::Char('}'),
            KeyModifiers::ALT | KeyModifiers::SHIFT,
        )),
        Some(Action::NextWorkspace)
    );
    assert_eq!(
        keys.action_for(&KeyEvent::new(KeyCode::Char('W'), KeyModifiers::SHIFT)),
        Some(Action::NewWorkspace)
    );
    assert_eq!(
        keys.action_for(&KeyEvent::new(KeyCode::Char('D'), KeyModifiers::SHIFT)),
        Some(Action::CloseWorkspace)
    );
}

#[test]
fn layout_undo_has_a_default_prefix_binding() {
    let keys = Keys::default();
    assert_eq!(
        keys.action_for(&KeyEvent::new(KeyCode::Char('U'), KeyModifiers::SHIFT)),
        Some(Action::UndoLayout)
    );
}

#[test]
fn new_action_names_parse_from_config_overrides() {
    let cases = [
        ("zoom-pane", Action::ZoomPane),
        ("focus-next-pane", Action::FocusNextPane),
        ("swap-pane-prev", Action::SwapPanePrev),
        ("swap-pane-next", Action::SwapPaneNext),
        ("scroll-up", Action::ScrollUp),
        ("toggle-sidebar-compact", Action::ToggleSidebarCompact),
        ("provider-menu", Action::ProviderMenu),
        ("toggle-sidebar-view", Action::ToggleSidebarView),
        ("new-pane-right", Action::NewPaneRight),
        ("undo-layout", Action::UndoLayout),
        ("show-shortcuts", Action::ShowShortcuts),
        ("send-prefix", Action::SendPrefix),
        ("prev-workspace", Action::PrevWorkspace),
        ("close-workspace", Action::CloseWorkspace),
    ];
    for (name, action) in cases {
        let mut keys = Keys::default();
        let mut raw = HashMap::new();
        raw.insert(name.to_string(), Value::String("f".to_string()));
        keys.apply(&raw);
        assert_eq!(
            keys.action_for(&KeyEvent::new(KeyCode::Char('f'), KeyModifiers::NONE)),
            Some(action),
            "{name} did not parse"
        );
    }
}

#[test]
fn provider_menu_override_requires_a_valid_chord_or_none() {
    let cases = [
        (Value::String("not a chord".to_string()), false),
        (Value::String("ctrl+b".to_string()), false),
        (Value::String("none".to_string()), true),
        (Value::Array(vec![]), true),
        (Value::String("x".to_string()), true),
        (Value::Bool(true), false),
    ];
    for (value, expected) in cases {
        let mut keys = Keys::default();
        keys.apply(&HashMap::from([("provider-menu".to_string(), value)]));
        assert_eq!(keys.provider_menu_overridden, expected);
    }
}

#[test]
fn select_screen_action_names_round_trip_and_parse() {
    for number in 0..=9 {
        let action = Action::select_screen(number).unwrap();
        let name = format!("select-screen-{number}");
        assert_eq!(action.definition().config_key, name);
        assert!(action_definitions().iter().any(|definition| definition.action == action));

        let mut keys = Keys::default();
        let mut raw = HashMap::new();
        raw.insert(name.clone(), Value::String("f".to_string()));
        keys.apply(&raw);
        assert_eq!(
            keys.action_for(&KeyEvent::new(KeyCode::Char('f'), KeyModifiers::NONE)),
            Some(action),
            "{name} did not parse"
        );

        // The snake_case spelling is accepted as an alias.
        let mut keys = Keys::default();
        let mut raw = HashMap::new();
        raw.insert(format!("select_screen_{number}"), Value::String("g".to_string()));
        keys.apply(&raw);
        assert_eq!(
            keys.action_for(&KeyEvent::new(KeyCode::Char('g'), KeyModifiers::NONE)),
            Some(action),
            "select_screen_{number} alias did not parse"
        );
    }

    assert_eq!(Action::select_screen(0).unwrap().screen_index(), Some(0));
    assert_eq!(Action::select_screen(1).unwrap().screen_index(), Some(1));
    assert_eq!(Action::select_screen(9).unwrap().screen_index(), Some(9));
    assert!(Action::select_screen(10).is_none());
}

#[test]
fn chord_matches_requires_shift_for_non_char_codes() {
    let shift_left = Chord { code: KeyCode::Left, mods: KeyModifiers::SHIFT };
    assert!(shift_left.matches(&KeyEvent::new(KeyCode::Left, KeyModifiers::SHIFT)));
    assert!(!shift_left.matches(&KeyEvent::new(KeyCode::Left, KeyModifiers::NONE)));

    let plain_left = Chord { code: KeyCode::Left, mods: KeyModifiers::NONE };
    assert!(plain_left.matches(&KeyEvent::new(KeyCode::Left, KeyModifiers::NONE)));
    assert!(!plain_left.matches(&KeyEvent::new(KeyCode::Left, KeyModifiers::SHIFT)));
}

#[test]
fn shortcut_labels_follow_resolved_bindings_and_prefix() {
    let mut keys = Keys::default();
    assert_eq!(keys.shortcut_label(Action::SendPrefix).as_deref(), Some("Ctrl-b Ctrl-b"));
    assert_eq!(keys.shortcut_label(Action::ZoomPane).as_deref(), Some("Ctrl-b z"));
    assert_eq!(keys.shortcut_label(Action::NewPaneSmart).as_deref(), Some("Alt-n"));
    assert_eq!(keys.shortcut_label(Action::ClearHistory).as_deref(), Some("Super-k"));
    assert_eq!(keys.prefixed_key_label(Action::ClearHistory), None);
    assert_eq!(keys.prefixed_key_label(Action::ShowShortcuts).as_deref(), Some("?"));
    assert_eq!(
        keys.shortcut_labels(Action::FocusLeft),
        ["Ctrl-b h", "Ctrl-b Left", "Alt-h", "Alt-Left"]
    );

    let mut raw = HashMap::new();
    raw.insert("prefix".to_string(), Value::String("ctrl+a".to_string()));
    raw.insert("zoom-pane".to_string(), Value::String("f".to_string()));
    raw.insert("toggle-sidebar".to_string(), Value::String("none".to_string()));
    keys.apply(&raw);

    assert_eq!(keys.shortcut_label(Action::SendPrefix).as_deref(), Some("Ctrl-a Ctrl-a"));
    assert_eq!(keys.shortcut_label(Action::ZoomPane).as_deref(), Some("Ctrl-a f"));
    assert_eq!(keys.shortcut_label(Action::ToggleSidebar), None);
    assert!(
        keys.resolved_shortcuts()
            .iter()
            .all(|(definition, shortcuts)| definition.action != Action::ToggleSidebar
                && !shortcuts.is_empty())
    );

    let mut collision = Keys::default();
    let mut raw = HashMap::new();
    raw.insert("prefix".to_string(), Value::String("alt+n".to_string()));
    collision.apply(&raw);
    assert_eq!(
        collision.shortcut_labels(Action::NewPaneSmart),
        ["Alt-n N"],
        "the surviving uppercase prefix fallback must remain advertised"
    );
    assert_eq!(collision.shortcut_label(Action::SendPrefix).as_deref(), Some("Alt-n Alt-n"));
}
