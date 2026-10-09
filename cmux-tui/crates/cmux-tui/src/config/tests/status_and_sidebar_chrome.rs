//! Tests for borders, status bar segments, chips and sidebar buttons.

use super::*;

#[test]
fn border_style_parses_every_name_and_defaults_to_single() {
    assert_eq!(Theme::default().border_style, BorderStyle::Single);
    for (name, style) in [
        ("single", BorderStyle::Single),
        ("rounded", BorderStyle::Rounded),
        ("thick", BorderStyle::Thick),
        ("double", BorderStyle::Double),
        ("none", BorderStyle::None),
    ] {
        let raw: RawConfig =
            serde_json::from_str(&format!(r#"{{"theme":{{"border_style":"{name}"}}}}"#))
                .unwrap();
        assert_eq!(raw.theme.border_style, Some(style), "{name} did not parse");
    }
    let hidden = BorderStyle::None.glyphs();
    for glyph in [
        hidden.horizontal,
        hidden.vertical,
        hidden.top_left,
        hidden.top_right,
        hidden.bottom_left,
        hidden.bottom_right,
    ] {
        assert_eq!(glyph, " ");
    }
}

#[test]
fn status_bar_segments_parse_validate_and_cap() {
    let raw: RawConfig = serde_json::from_value(json!({
        "status_bar": {
            "show_screens": false,
            "show_session": false,
            "left": [
                {"text": " {session} ", "fg": "#87d787", "bg": 236},
                {"text": "x", "run": ["true"]},
                {"run": []},
                {}
            ],
            "right": [
                {"run": ["date", "+%H:%M"], "interval": 0},
                {"text": "{workspace}"}
            ]
        }
    }))
    .unwrap();
    let left = resolve_status_segments(raw.status_bar.left.unwrap(), "left");
    assert_eq!(left.len(), 1, "text+run, empty run, and empty segments are rejected");
    assert_eq!(left[0].content, StatusSegmentContent::Text(" {session} ".to_string()));
    assert!(left[0].fg.is_some() && left[0].bg.is_some());
    let right = resolve_status_segments(raw.status_bar.right.unwrap(), "right");
    assert_eq!(right.len(), 2);
    assert_eq!(
        right[0].content,
        StatusSegmentContent::Command {
            argv: vec!["date".to_string(), "+%H:%M".to_string()],
            interval: Duration::from_secs(1),
        },
        "interval clamps to at least one second"
    );

    let options = StatusBarOptions { left, right, ..StatusBarOptions::default() };
    let commands = options.command_segments();
    assert_eq!(commands.len(), 1);
    assert_eq!(commands[0].0, 1, "command index counts left segments first");

    let overflow: Vec<RawStatusSegment> = (0..MAX_STATUS_SEGMENTS + 3)
        .map(|index| RawStatusSegment {
            text: Some(format!("{index}")),
            ..RawStatusSegment::default()
        })
        .collect();
    assert_eq!(resolve_status_segments(overflow, "left").len(), MAX_STATUS_SEGMENTS);
}

#[test]
fn status_text_cap_uses_terminal_cells_without_splitting_graphemes() {
    let text = format!("{}e\u{301}abc", "界".repeat(130));
    let raw = vec![RawStatusSegment { text: Some(text), ..RawStatusSegment::default() }];
    let resolved = resolve_status_segments(raw, "left");
    let StatusSegmentContent::Text(text) = &resolved[0].content else {
        panic!("literal status text did not resolve as text");
    };
    assert_eq!(usize::from(text.cell_width()), MAX_STATUS_SEGMENT_TEXT);
    assert_eq!(text, &"界".repeat(MAX_STATUS_SEGMENT_TEXT / 2));
}

#[test]
#[allow(clippy::unicode_not_nfc)]
fn status_text_cap_uses_terminal_cells_for_halfwidth_dakuten() {
    let raw = vec![RawStatusSegment {
        text: Some("界ﾞ".repeat(100)),
        ..RawStatusSegment::default()
    }];
    let resolved = resolve_status_segments(raw, "left");
    let StatusSegmentContent::Text(text) = &resolved[0].content else {
        panic!("literal status text did not resolve as text");
    };
    assert_eq!(text, &"界ﾞ".repeat(85));
}

#[test]
fn chip_styles_and_separators_parse() {
    let raw: RawConfig = serde_json::from_value(json!({
        "tabs": {"style": "pill"},
        "status_bar": {
            "left_separator": "\u{e0b0}",
            "right_separator": "\u{e0b2}",
            "screens_style": "slant"
        }
    }))
    .unwrap();
    assert_eq!(raw.tabs.style, Some(ChipStyle::Pill));
    assert_eq!(raw.status_bar.screens_style, Some(ChipStyle::Slant));
    assert_eq!(raw.status_bar.left_separator.as_deref(), Some("\u{e0b0}"));
    assert!(ChipStyle::Block.caps().is_none());
    let (left, right) = ChipStyle::Pill.caps().unwrap();
    assert!(!left.is_empty() && !right.is_empty());
}

#[test]
fn sidebar_buttons_accept_labels_positions_and_command_references() {
    let views = vec![RawSidebarView {
        id: "ws".to_string(),
        levels: vec!["workspaces".to_string()],
        actions: Some(vec![
            RawSidebarAction::Detailed {
                action: "new-workspace".to_string(),
                label: Some("new".to_string()),
            },
            RawSidebarAction::Name("command:lazygit".to_string()),
            RawSidebarAction::Name("command:unknown".to_string()),
            RawSidebarAction::Name("new-tab".to_string()),
        ]),
        actions_position: Some(ActionsPosition::Top),
        width: None,
        max_width: None,
        collapse_priority: None,
    }];
    let command_ids = vec!["lazygit".to_string()];
    let resolved = resolve_sidebar_view_specs(&views, 22, 0, 22, 0, "sidebar", &command_ids);
    assert_eq!(resolved.len(), 1);
    assert_eq!(resolved[0].actions_position, ActionsPosition::Top);
    assert_eq!(
        resolved[0].actions,
        vec![
            SidebarActionSpec { action: Action::NewWorkspace, label: Some("new".to_string()) },
            SidebarActionSpec::plain(Action::user_command(0).unwrap()),
            SidebarActionSpec::plain(Action::NewTab),
        ],
        "unknown command references drop, known ones bind by id"
    );
}

#[test]
fn sidebar_row_metrics_glyph_and_label_template_parse() {
    let raw: RawConfig = serde_json::from_value(json!({
        "sidebar": {
            "row_height": 1,
            "row_gap": 0,
            "rail_glyph": "none",
            "workspace_label": "{index} · {name}"
        }
    }))
    .unwrap();
    assert_eq!(raw.sidebar.row_height, Some(1));
    assert_eq!(raw.sidebar.row_gap, Some(0));
    assert_eq!(raw.sidebar.rail_glyph.as_deref(), Some("none"));
    assert_eq!(raw.sidebar.workspace_label.as_deref(), Some("{index} · {name}"));
}

#[test]
#[allow(clippy::unicode_not_nfc)]
fn rail_glyph_accepts_standalone_halfwidth_sound_marks() {
    let _guard = CONFIG_ENV_LOCK.lock().unwrap();
    let old_cmux_tui_config = std::env::var_os("CMUX_TUI_CONFIG");
    let dir = TestDirectory::new("rail-glyph-halfwidth-sound-marks");
    let path = dir.path.join("cmux-tui.json");
    for glyph in ["\u{ff9e}", "\u{ff9f}"] {
        std::fs::write(&path, format!(r#"{{"sidebar":{{"rail_glyph":"{glyph}"}}}}"#)).unwrap();
        // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
        unsafe { std::env::set_var("CMUX_TUI_CONFIG", &path) };

        let config = load();
        restore_env_var("CMUX_TUI_CONFIG", old_cmux_tui_config.clone());

        assert_eq!(config.sidebar.rail_glyph, glyph);
    }

    std::fs::write(&path, r#"{"sidebar":{"rail_glyph":"\n"}}"#).unwrap();
    // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
    unsafe { std::env::set_var("CMUX_TUI_CONFIG", &path) };

    let config = load();
    restore_env_var("CMUX_TUI_CONFIG", old_cmux_tui_config);

    assert_eq!(config.sidebar.rail_glyph, Config::default().sidebar.rail_glyph);
}

#[test]
fn plus_buttons_parse_labels_actions_and_menus() {
    let raw: RawConfig = serde_json::from_value(json!({
        "tabs": {"plus": {
            "label": " new ",
            "action": "command:top",
            "menu": [
                "new-tab",
                {"action": "new-browser-tab", "label": "browser"},
                "command:top",
                "command:unknown"
            ]
        }},
        "status_bar": {"screens_plus": {"label": " ⊕ "}}
    }))
    .unwrap();
    let command_ids = vec!["top".to_string()];
    let plus = resolve_plus_button(raw.tabs.plus.unwrap(), &command_ids, "tabs");
    assert_eq!(plus.label, " new ");
    assert_eq!(plus.action, Action::user_command(0));
    assert_eq!(
        plus.menu,
        vec![
            SidebarActionSpec::plain(Action::NewTab),
            SidebarActionSpec {
                action: Action::NewBrowserTab,
                label: Some("browser".to_string()),
            },
            SidebarActionSpec::plain(Action::user_command(0).unwrap()),
        ],
        "unknown command references drop from plus menus"
    );
    let screens =
        resolve_plus_button(raw.status_bar.screens_plus.unwrap(), &command_ids, "status_bar");
    assert_eq!(screens.label, " ⊕ ");
    assert_eq!(screens.action, None);
    assert!(screens.menu.is_empty());
    // A blank label keeps the clickable default.
    let blank = resolve_plus_button(
        RawPlusButton { label: Some("   ".to_string()), action: None, menu: None },
        &command_ids,
        "tabs",
    );
    assert_eq!(blank.label, " + ");
}
