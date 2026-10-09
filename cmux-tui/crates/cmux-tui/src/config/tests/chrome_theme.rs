//! Tests for chrome theme selection, light/dark defaults and selection colors.

use super::*;

#[test]
fn detects_light_background_from_luminance() {
    assert!(is_light_background(Rgb { r: 255, g: 255, b: 255 }));
    assert!(!is_light_background(Rgb { r: 0, g: 0, b: 0 }));
    assert!(!is_light_background(Rgb { r: 128, g: 128, b: 128 }));
    assert!(is_light_background(Rgb { r: 129, g: 129, b: 129 }));
}

#[test]
fn dark_chrome_matches_legacy_indices() {
    let chrome = ChromeTheme::dark();
    assert_eq!(chrome.selection_bg, Color::Rgb(0x3a, 0x3a, 0x3a));
    assert_eq!(chrome.selection_fg, None);
    assert_eq!(chrome.menu_bg, Color::Indexed(237));
    assert_eq!(chrome.menu_selected_bg, Color::Indexed(242));
    assert_eq!(chrome.prompt_bg, Color::Indexed(236));
    assert_eq!(chrome.status_bg, Color::Indexed(236));
    assert_eq!(chrome.status_active_bg, Color::Indexed(240));
    assert_eq!(chrome.tab_bar_bg, Color::Indexed(236));
    assert_eq!(chrome.tab_active_bg, Color::Indexed(240));
    assert_eq!(chrome.tab_active_unfocused_bg, Color::Indexed(238));
    assert_eq!(chrome.sidebar_selected_bg, Color::Indexed(236));
    assert_eq!(chrome.omnibar_edit_bg, Color::Indexed(236));
    assert_eq!(chrome.border_fg, Color::Indexed(238));
    assert_eq!(chrome.scrollbar_thumb_active_fg, Color::Indexed(252));
}

#[test]
fn light_chrome_replaces_default_selection() {
    let mut config = Config::default();
    config.apply_chrome_defaults(ChromeTheme::light());
    assert_eq!(config.theme.selection_bg, Color::Rgb(0xcc, 0xdd, 0xf5));
    assert_eq!(config.theme.selection_fg, None);
}

#[test]
fn mux_json_selection_survives_light_chrome_defaults() {
    let _guard = CONFIG_ENV_LOCK.lock().unwrap();
    let dir =
        std::env::temp_dir().join(format!("mux-config-test-selection-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("mux.json");
    std::fs::write(
        &path,
        r##"{"theme": {"selection_background": "#112233", "selection_foreground": "#ddeeff"}}"##,
    )
    .unwrap();
    // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
    unsafe { std::env::set_var("CMUX_MUX_CONFIG", &path) };
    let mut config = load();
    // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
    unsafe { std::env::remove_var("CMUX_MUX_CONFIG") };
    let _ = std::fs::remove_file(&path);
    config.apply_chrome_defaults(ChromeTheme::light());
    assert_eq!(config.theme.selection_bg, Color::Rgb(0x11, 0x22, 0x33));
    assert_eq!(config.theme.selection_fg, Some(Color::Rgb(0xdd, 0xee, 0xff)));
}

#[test]
fn ghostty_defaults_survive_light_chrome_defaults() {
    let _guard = CONFIG_ENV_LOCK.lock().unwrap();
    let old_mux_config = std::env::var_os("CMUX_MUX_CONFIG");
    let old_xdg_config_home = std::env::var_os("XDG_CONFIG_HOME");
    let dir =
        std::env::temp_dir().join(format!("mux-ghostty-selection-{}", std::process::id()));
    let ghostty_dir = dir.join("ghostty");
    std::fs::create_dir_all(&ghostty_dir).unwrap();
    std::fs::write(
        ghostty_dir.join("config"),
        "foreground = #010203\n\
         background = #131415\n\
         selection-background = #445566\n\
         selection-foreground = #abcdef\n\
         palette = 1=#778899\n\
         cursor-style = bar\n\
         cursor-style-blink = false\n",
    )
    .unwrap();
    // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
    unsafe { std::env::remove_var("CMUX_MUX_CONFIG") };
    // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
    unsafe { std::env::set_var("XDG_CONFIG_HOME", &dir) };

    let mut config = load();

    restore_env_var("CMUX_MUX_CONFIG", old_mux_config);
    restore_env_var("XDG_CONFIG_HOME", old_xdg_config_home);
    let _ = std::fs::remove_dir_all(&dir);

    config.apply_chrome_defaults(ChromeTheme::light());
    assert_eq!(config.theme.selection_bg, Color::Rgb(0x44, 0x55, 0x66));
    assert_eq!(config.theme.selection_fg, Some(Color::Rgb(0xab, 0xcd, 0xef)));
    assert_eq!(config.cursor_style, Some(CursorShape::Bar));
    assert_eq!(config.cursor_blink, Some(false));
    assert_eq!(config.terminal_defaults.fg, Some(Rgb { r: 1, g: 2, b: 3 }));
    assert_eq!(config.terminal_defaults.bg, Some(Rgb { r: 0x13, g: 0x14, b: 0x15 }));
    assert_eq!(config.terminal_defaults.palette[1], Some(Rgb { r: 0x77, g: 0x88, b: 0x99 }));
}

#[test]
fn chrome_theme_selection_honors_auto_and_overrides() {
    let light_defaults = DefaultColors {
        fg: None,
        bg: Some(Rgb { r: 240, g: 240, b: 240 }),
        ..Default::default()
    };
    let dark_defaults =
        DefaultColors { fg: None, bg: Some(Rgb { r: 20, g: 20, b: 20 }), ..Default::default() };
    assert_eq!(
        ChromeTheme::for_defaults(ChromeMode::Auto, light_defaults),
        ChromeTheme::light()
    );
    assert_eq!(ChromeTheme::for_defaults(ChromeMode::Auto, dark_defaults), ChromeTheme::dark());
    assert_eq!(
        ChromeTheme::for_defaults(ChromeMode::Auto, DefaultColors::default()),
        ChromeTheme::dark()
    );
    assert_eq!(
        ChromeTheme::for_defaults(ChromeMode::Dark, light_defaults),
        ChromeTheme::dark()
    );
    assert_eq!(
        ChromeTheme::for_defaults(ChromeMode::Light, dark_defaults),
        ChromeTheme::light()
    );
}

#[test]
fn parses_chrome_config_and_rejects_unknown_values() {
    let raw: RawConfig = serde_json::from_str(r##"{"theme": {"chrome": "light"}}"##).unwrap();
    assert_eq!(raw.theme.chrome, Some(ChromeMode::Light));

    let err = serde_json::from_str::<RawConfig>(r##"{"theme": {"chrome": "solarized"}}"##)
        .unwrap_err()
        .to_string();
    assert!(err.contains("unknown variant"), "{err}");
    assert!(err.contains("light"), "{err}");
    assert!(err.contains("dark"), "{err}");
    assert!(err.contains("auto"), "{err}");
}

#[test]
fn selection_foreground_absent_vs_null_are_distinct() {
    // Absent key: `Option<Option<_>>` outer is None, meaning "no
    // override" (the Ghostty-seeded value, if any, is kept).
    let absent: RawConfig = serde_json::from_str(r##"{"theme": {}}"##).unwrap();
    assert!(absent.theme.selection_foreground.is_none());

    // Explicit `null`: outer is `Some(None)`, meaning "clear it".
    let explicit_null: RawConfig =
        serde_json::from_str(r##"{"theme": {"selection_foreground": null}}"##).unwrap();
    assert!(matches!(explicit_null.theme.selection_foreground, Some(None)));
}

#[test]
fn selection_foreground_null_clears_ghostty_seeded_default() {
    let _guard = CONFIG_ENV_LOCK.lock().unwrap();
    let dir =
        std::env::temp_dir().join(format!("mux-config-test-selfg-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("mux.json");
    std::fs::write(&path, r##"{"theme": {"selection_foreground": null}}"##).unwrap();
    // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
    unsafe { std::env::set_var("CMUX_MUX_CONFIG", &path) };
    // `load()` always seeds `selection_fg` from the Ghostty selection
    // colors (or leaves it `None` if there aren't any) before applying
    // this override, so regardless of the ambient Ghostty config, an
    // explicit `null` here must land back on `None`.
    let config = load();
    // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
    unsafe { std::env::remove_var("CMUX_MUX_CONFIG") };
    let _ = std::fs::remove_file(&path);
    assert_eq!(config.theme.selection_fg, None);
}
