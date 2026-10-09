//! Tests for system appearance detection and conditional Ghostty themes.

use super::*;

#[test]
fn ghostty_automatic_window_theme_uses_detected_dark_mode_for_conditional_theme() {
    let _guard = CONFIG_ENV_LOCK.lock().unwrap();
    let old_apple_interface_style = std::env::var_os("AppleInterfaceStyle");
    let dir = std::env::temp_dir().join(format!(
        "cmux-tui-ghostty-theme-auto-{}-{}",
        std::process::id(),
        SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(
        dir.join("Light Auto Theme"),
        "background = #f0f1f2\nforeground = #f3f4f5\npalette = 1=#f6f7f8\n",
    )
    .unwrap();
    std::fs::write(
        dir.join("Dark Auto Theme"),
        "background = #101112\nforeground = #131415\npalette = 1=#161718\n",
    )
    .unwrap();
    // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
    unsafe { std::env::set_var("AppleInterfaceStyle", "Dark") };

    let defaults = parse_ghostty_defaults_with_theme_dirs(
        "window-theme = auto\n\
         theme = light:Light Auto Theme,dark:Dark Auto Theme\n",
        std::slice::from_ref(&dir),
    );

    restore_env_var("AppleInterfaceStyle", old_apple_interface_style);
    let _ = std::fs::remove_dir_all(dir);

    assert_eq!(defaults.bg, Some(Rgb { r: 0x10, g: 0x11, b: 0x12 }));
    assert_eq!(defaults.fg, Some(Rgb { r: 0x13, g: 0x14, b: 0x15 }));
    assert_eq!(defaults.palette[1], Some(Rgb { r: 0x16, g: 0x17, b: 0x18 }));
}

#[test]
fn ghostty_conditional_terminal_theme_ignores_ghostty_window_theme() {
    let _guard = CONFIG_ENV_LOCK.lock().unwrap();
    let old_apple_interface_style = std::env::var_os("AppleInterfaceStyle");
    let dir = std::env::temp_dir().join(format!(
        "cmux-tui-ghostty-theme-window-ghostty-{}-{}",
        std::process::id(),
        SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(
        dir.join("Light Window Theme"),
        "background = #f0f1f2\nforeground = #f3f4f5\npalette = 1=#f6f7f8\n",
    )
    .unwrap();
    std::fs::write(
        dir.join("Dark Window Theme"),
        "background = #101112\nforeground = #131415\npalette = 1=#161718\n",
    )
    .unwrap();
    // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
    unsafe { std::env::set_var("AppleInterfaceStyle", "Dark") };

    let defaults = parse_ghostty_defaults_with_theme_dirs(
        "window-theme = ghostty\n\
         theme = light:Light Window Theme,dark:Dark Window Theme\n",
        std::slice::from_ref(&dir),
    );

    restore_env_var("AppleInterfaceStyle", old_apple_interface_style);
    let _ = std::fs::remove_dir_all(dir);

    assert_eq!(defaults.bg, Some(Rgb { r: 0x10, g: 0x11, b: 0x12 }));
    assert_eq!(defaults.fg, Some(Rgb { r: 0x13, g: 0x14, b: 0x15 }));
    assert_eq!(defaults.palette[1], Some(Rgb { r: 0x16, g: 0x17, b: 0x18 }));
}

#[test]
fn ghostty_fixed_theme_selection_does_not_require_appearance_budget() {
    let expired = Instant::now().checked_sub(Duration::from_millis(1)).unwrap();
    let mut theme_mode = None;

    let selected = selected_ghostty_theme("Monokai", Some(expired), &mut theme_mode);

    assert_eq!(selected, "Monokai");
    assert_eq!(theme_mode, None);
}

#[test]
fn ghostty_conditional_theme_selection_reuses_cached_appearance_mode() {
    let _guard = CONFIG_ENV_LOCK.lock().unwrap();
    let old_apple_interface_style = std::env::var_os("AppleInterfaceStyle");
    let mut theme_mode = None;
    // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
    unsafe { std::env::set_var("AppleInterfaceStyle", "Dark") };

    let missing = selected_ghostty_theme(
        "light:Missing Light Theme,dark:Missing Dark Theme",
        None,
        &mut theme_mode,
    );
    // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
    unsafe { std::env::set_var("AppleInterfaceStyle", "Light") };
    let fallback = selected_ghostty_theme(
        "light:Light Fallback Theme,dark:Dark Fallback Theme",
        None,
        &mut theme_mode,
    );

    restore_env_var("AppleInterfaceStyle", old_apple_interface_style);

    assert_eq!(missing, "Missing Dark Theme");
    assert_eq!(fallback, "Dark Fallback Theme");
    assert_eq!(theme_mode, Some(GhosttyThemeMode::Dark));
}

#[test]
fn ghostty_system_theme_uses_platform_appearance() {
    let _guard = CONFIG_ENV_LOCK.lock().unwrap();
    let old_apple_interface_style = std::env::var_os("AppleInterfaceStyle");
    // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
    unsafe { std::env::remove_var("AppleInterfaceStyle") };

    let mode = system_ghostty_theme_mode_with_platform(|| Some(GhosttyThemeMode::Light));

    restore_env_var("AppleInterfaceStyle", old_apple_interface_style);

    assert_eq!(mode, GhosttyThemeMode::Light);
}

#[test]
fn ghostty_system_theme_uses_environment_before_platform_probe() {
    let _guard = CONFIG_ENV_LOCK.lock().unwrap();
    let old_apple_interface_style = std::env::var_os("AppleInterfaceStyle");
    let mut platform_calls = 0;
    // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
    unsafe { std::env::set_var("AppleInterfaceStyle", "Dark") };

    let mode = system_ghostty_theme_mode_with_platform(|| {
        platform_calls += 1;
        Some(GhosttyThemeMode::Light)
    });

    restore_env_var("AppleInterfaceStyle", old_apple_interface_style);

    assert_eq!(mode, GhosttyThemeMode::Dark);
    assert_eq!(platform_calls, 0);
}

#[test]
fn ghostty_background_luminance_matches_ghostty_threshold() {
    assert!(ghostty_background_is_light(Rgb { r: 255, g: 255, b: 255 }));
    assert!(!ghostty_background_is_light(Rgb { r: 0, g: 0, b: 0 }));
    assert!(!ghostty_background_is_light(Rgb { r: 0x28, g: 0x2c, b: 0x34 }));
}

#[test]
fn ghostty_non_macos_desktop_sources_detect_system_theme_mode() {
    assert_eq!(
        freedesktop_portal_color_scheme_theme_mode("(<'uint32 1'>,)"),
        Some(GhosttyThemeMode::Dark)
    );
    assert_eq!(
        freedesktop_portal_color_scheme_theme_mode("(<uint32 2>,)"),
        Some(GhosttyThemeMode::Light)
    );
    assert_eq!(
        gnome_color_scheme_output_theme_mode("'prefer-dark'\n"),
        Some(GhosttyThemeMode::Dark)
    );
    assert_eq!(gnome_color_scheme_output_theme_mode("'default'\n"), None);
    assert_eq!(
        gtk_settings_theme_mode("[Settings]\ngtk-application-prefer-dark-theme=1\n"),
        Some(GhosttyThemeMode::Dark)
    );
    assert_eq!(
        gtk_settings_theme_mode(
            "[Settings]\ngtk-application-prefer-dark-theme=false\ngtk-theme-name=Adwaita-dark\n"
        ),
        Some(GhosttyThemeMode::Dark)
    );
    assert_eq!(
        gtk_settings_theme_mode("[Settings]\ngtk-application-prefer-dark-theme=0\n"),
        None
    );
    assert_eq!(
        gtk_settings_theme_mode("[Settings]\ngtk-theme-name=Adwaita-dark\n"),
        Some(GhosttyThemeMode::Dark)
    );
    assert_eq!(gtk_theme_name_theme_mode("Adwaita:dark"), Some(GhosttyThemeMode::Dark));
    assert_eq!(gtk_theme_name_theme_mode("Yaru-light"), Some(GhosttyThemeMode::Light));
    assert_eq!(
        kde_globals_text_theme_mode("[General]\nColorScheme=BreezeDark\n"),
        Some(GhosttyThemeMode::Dark)
    );
}

#[test]
fn ghostty_window_theme_does_not_use_resolved_background_for_terminal_theme() {
    let _guard = CONFIG_ENV_LOCK.lock().unwrap();
    let old_apple_interface_style = std::env::var_os("AppleInterfaceStyle");
    let dir = std::env::temp_dir().join(format!(
        "cmux-tui-ghostty-theme-source-{}-{}",
        std::process::id(),
        SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(
        dir.join("Light Source Theme"),
        "background = #f0f1f2\nforeground = #f3f4f5\n",
    )
    .unwrap();
    std::fs::write(
        dir.join("Dark Source Theme"),
        "background = #101112\nforeground = #131415\n",
    )
    .unwrap();
    // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
    unsafe { std::env::set_var("AppleInterfaceStyle", "Light") };

    let system = parse_ghostty_defaults_with_theme_dirs(
        "window-theme = system\n\
         background = #101112\n\
         theme = light:Light Source Theme,dark:Dark Source Theme\n",
        std::slice::from_ref(&dir),
    );
    let ghostty = parse_ghostty_defaults_with_theme_dirs(
        "window-theme = ghostty\n\
         background = #101112\n\
         theme = light:Light Source Theme,dark:Dark Source Theme\n",
        std::slice::from_ref(&dir),
    );

    restore_env_var("AppleInterfaceStyle", old_apple_interface_style);
    let _ = std::fs::remove_dir_all(dir);

    assert_eq!(system.bg, Some(Rgb { r: 0x10, g: 0x11, b: 0x12 }));
    assert_eq!(system.fg, Some(Rgb { r: 0xf3, g: 0xf4, b: 0xf5 }));
    assert_eq!(ghostty.bg, Some(Rgb { r: 0x10, g: 0x11, b: 0x12 }));
    assert_eq!(ghostty.fg, Some(Rgb { r: 0xf3, g: 0xf4, b: 0xf5 }));
}
