//! Tests for loading Ghostty config files, includes, themes and their limits.

use super::*;

#[cfg(unix)]
#[test]
fn load_uses_file_ghostty_defaults_without_invoking_external_resolver() {
    let _guard = CONFIG_ENV_LOCK.lock().unwrap();
    let old_ghostty_bin = std::env::var_os("GHOSTTY_BIN");
    let old_ghostty_resources = std::env::var_os("GHOSTTY_RESOURCES_DIR");
    let old_cmux_tui_config = std::env::var_os("CMUX_TUI_CONFIG");
    let old_mux_config = std::env::var_os("CMUX_MUX_CONFIG");
    let old_xdg_config_home = std::env::var_os("XDG_CONFIG_HOME");
    let old_apple_interface_style = std::env::var_os("AppleInterfaceStyle");
    let dir = std::env::temp_dir()
        .join(format!("mux-ghostty-startup-file-only-{}", std::process::id()));
    let ghostty_dir = dir.join("ghostty");
    let marker = dir.join("resolver-ran");
    let resolver = dir.join("ghostty-resolver");
    std::fs::create_dir_all(&ghostty_dir).unwrap();
    std::fs::write(ghostty_dir.join("config"), "foreground = #010203\n").unwrap();
    write_executable(
        &resolver,
        format!(
            "#!/bin/sh\n\
             printf marker > '{}'\n\
             printf 'foreground = #aabbcc\\nbackground = #ddeeff\\n'\n",
            marker.display()
        ),
    );
    // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
    unsafe { std::env::set_var("GHOSTTY_BIN", &resolver) };
    // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
    unsafe { std::env::remove_var("GHOSTTY_RESOURCES_DIR") };
    // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
    unsafe { std::env::remove_var("CMUX_TUI_CONFIG") };
    // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
    unsafe { std::env::remove_var("CMUX_MUX_CONFIG") };
    // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
    unsafe { std::env::set_var("XDG_CONFIG_HOME", &dir) };
    // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
    unsafe { std::env::set_var("AppleInterfaceStyle", "Light") };

    let config = load();

    restore_env_var("GHOSTTY_BIN", old_ghostty_bin);
    restore_env_var("GHOSTTY_RESOURCES_DIR", old_ghostty_resources);
    restore_env_var("CMUX_TUI_CONFIG", old_cmux_tui_config);
    restore_env_var("CMUX_MUX_CONFIG", old_mux_config);
    restore_env_var("XDG_CONFIG_HOME", old_xdg_config_home);
    restore_env_var("AppleInterfaceStyle", old_apple_interface_style);
    let resolver_ran = marker.exists();
    let _ = std::fs::remove_dir_all(&dir);

    assert!(!resolver_ran, "config load must not run ghostty +show-config at startup");
    assert_eq!(config.terminal_defaults.fg, Some(Rgb { r: 1, g: 2, b: 3 }));
    assert_eq!(config.terminal_defaults.bg, None);
}

#[cfg(unix)]
#[test]
fn load_resolves_ghostty_resource_theme_without_invoking_external_resolver() {
    let _guard = CONFIG_ENV_LOCK.lock().unwrap();
    let old_ghostty_bin = std::env::var_os("GHOSTTY_BIN");
    let old_ghostty_resources = std::env::var_os("GHOSTTY_RESOURCES_DIR");
    let old_cmux_tui_config = std::env::var_os("CMUX_TUI_CONFIG");
    let old_mux_config = std::env::var_os("CMUX_MUX_CONFIG");
    let old_xdg_config_home = std::env::var_os("XDG_CONFIG_HOME");
    let old_apple_interface_style = std::env::var_os("AppleInterfaceStyle");
    let dir = std::env::temp_dir()
        .join(format!("mux-ghostty-startup-resource-theme-{}", std::process::id()));
    let ghostty_dir = dir.join("ghostty");
    let resources = dir.join("resources");
    let themes = resources.join("themes");
    let marker = dir.join("resolver-ran");
    let resolver = dir.join("ghostty-resolver");
    std::fs::create_dir_all(&ghostty_dir).unwrap();
    std::fs::create_dir_all(&themes).unwrap();
    std::fs::write(
        ghostty_dir.join("config"),
        "window-theme = light\n\
         theme = dark:Dark Resource Theme, light:Light Resource Theme\n\
         background = #444444\n",
    )
    .unwrap();
    std::fs::write(
        themes.join("Light Resource Theme"),
        "foreground = #111111\nbackground = #222222\npalette = 1=#333333\n",
    )
    .unwrap();
    std::fs::write(
        themes.join("Dark Resource Theme"),
        "foreground = #aaaaaa\nbackground = #bbbbbb\npalette = 1=#cccccc\n",
    )
    .unwrap();
    write_executable(
        &resolver,
        format!(
            "#!/bin/sh\n\
             printf marker > '{}'\n\
             printf 'foreground = #ddeeff\\nbackground = #000000\\n'\n",
            marker.display()
        ),
    );
    // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
    unsafe { std::env::set_var("GHOSTTY_BIN", &resolver) };
    // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
    unsafe { std::env::set_var("GHOSTTY_RESOURCES_DIR", &resources) };
    // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
    unsafe { std::env::remove_var("CMUX_TUI_CONFIG") };
    // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
    unsafe { std::env::remove_var("CMUX_MUX_CONFIG") };
    // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
    unsafe { std::env::set_var("XDG_CONFIG_HOME", &dir) };
    // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
    unsafe { std::env::set_var("AppleInterfaceStyle", "Light") };
    let theme_dirs = platform::ghostty_theme_dirs();
    assert!(theme_dirs.contains(&themes), "{theme_dirs:?}");

    let config = load();

    restore_env_var("GHOSTTY_BIN", old_ghostty_bin);
    restore_env_var("GHOSTTY_RESOURCES_DIR", old_ghostty_resources);
    restore_env_var("CMUX_TUI_CONFIG", old_cmux_tui_config);
    restore_env_var("CMUX_MUX_CONFIG", old_mux_config);
    restore_env_var("XDG_CONFIG_HOME", old_xdg_config_home);
    restore_env_var("AppleInterfaceStyle", old_apple_interface_style);
    let resolver_ran = marker.exists();
    let _ = std::fs::remove_dir_all(&dir);

    assert!(!resolver_ran, "config load must not run ghostty +show-config at startup");
    assert_eq!(config.terminal_defaults.fg, Some(Rgb { r: 0x11, g: 0x11, b: 0x11 }));
    assert_eq!(config.terminal_defaults.bg, Some(Rgb { r: 0x44, g: 0x44, b: 0x44 }));
    assert_eq!(config.terminal_defaults.palette[1], Some(Rgb { r: 0x33, g: 0x33, b: 0x33 }));
}

#[cfg(unix)]
#[test]
fn load_applies_ghostty_config_file_after_root_and_respects_dark_theme_mode() {
    let _guard = CONFIG_ENV_LOCK.lock().unwrap();
    let old_ghostty_bin = std::env::var_os("GHOSTTY_BIN");
    let old_ghostty_resources = std::env::var_os("GHOSTTY_RESOURCES_DIR");
    let old_cmux_tui_config = std::env::var_os("CMUX_TUI_CONFIG");
    let old_mux_config = std::env::var_os("CMUX_MUX_CONFIG");
    let old_xdg_config_home = std::env::var_os("XDG_CONFIG_HOME");
    let old_apple_interface_style = std::env::var_os("AppleInterfaceStyle");
    let dir = std::env::temp_dir()
        .join(format!("mux-ghostty-startup-include-theme-{}", std::process::id()));
    let ghostty_dir = dir.join("ghostty");
    let resources = dir.join("resources");
    let themes = resources.join("themes");
    let marker = dir.join("resolver-ran");
    let resolver = dir.join("ghostty-resolver");
    std::fs::create_dir_all(&ghostty_dir).unwrap();
    std::fs::create_dir_all(&themes).unwrap();
    std::fs::write(
        ghostty_dir.join("config"),
        "foreground = #010101\n\
         config-file = colors.conf\n\
         background = #020202\n",
    )
    .unwrap();
    std::fs::write(
        ghostty_dir.join("colors.conf"),
        "window-theme = dark\n\
         theme = light:Light Include Theme,dark:Dark Include Theme\n\
         background = #444444\n",
    )
    .unwrap();
    std::fs::write(
        themes.join("Light Include Theme"),
        "foreground = #111111\nbackground = #222222\npalette = 1=#333333\n",
    )
    .unwrap();
    std::fs::write(
        themes.join("Dark Include Theme"),
        "foreground = #aaaaaa\nbackground = #bbbbbb\npalette = 1=#cccccc\n",
    )
    .unwrap();
    write_executable(
        &resolver,
        format!(
            "#!/bin/sh\n\
             printf marker > '{}'\n\
             printf 'foreground = #ddeeff\\nbackground = #000000\\n'\n",
            marker.display()
        ),
    );
    // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
    unsafe { std::env::set_var("GHOSTTY_BIN", &resolver) };
    // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
    unsafe { std::env::set_var("GHOSTTY_RESOURCES_DIR", &resources) };
    // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
    unsafe { std::env::remove_var("CMUX_TUI_CONFIG") };
    // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
    unsafe { std::env::remove_var("CMUX_MUX_CONFIG") };
    // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
    unsafe { std::env::set_var("XDG_CONFIG_HOME", &dir) };
    // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
    unsafe { std::env::set_var("AppleInterfaceStyle", "Dark") };

    let config = load();

    restore_env_var("GHOSTTY_BIN", old_ghostty_bin);
    restore_env_var("GHOSTTY_RESOURCES_DIR", old_ghostty_resources);
    restore_env_var("CMUX_TUI_CONFIG", old_cmux_tui_config);
    restore_env_var("CMUX_MUX_CONFIG", old_mux_config);
    restore_env_var("XDG_CONFIG_HOME", old_xdg_config_home);
    restore_env_var("AppleInterfaceStyle", old_apple_interface_style);
    let resolver_ran = marker.exists();
    let _ = std::fs::remove_dir_all(&dir);

    assert!(!resolver_ran, "config load must not run ghostty +show-config at startup");
    assert_eq!(config.terminal_defaults.fg, Some(Rgb { r: 0x01, g: 0x01, b: 0x01 }));
    assert_eq!(config.terminal_defaults.bg, Some(Rgb { r: 0x44, g: 0x44, b: 0x44 }));
    assert_eq!(config.terminal_defaults.palette[1], Some(Rgb { r: 0xcc, g: 0xcc, b: 0xcc }));
}

#[test]
fn ghostty_fallback_theme_selection_skips_unreadable_themes() {
    let _guard = CONFIG_ENV_LOCK.lock().unwrap();
    let dir = std::env::temp_dir().join(format!(
        "cmux-tui-ghostty-theme-missing-{}-{}",
        std::process::id(),
        SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(
        dir.join("Readable Theme"),
        "background = #101112\nforeground = #131415\npalette = 1=#161718\n",
    )
    .unwrap();

    let defaults = parse_ghostty_defaults_with_theme_dirs(
        "theme = Missing Theme\n\
         theme = Readable Theme\n",
        std::slice::from_ref(&dir),
    );

    let _ = std::fs::remove_dir_all(dir);

    assert_eq!(defaults.bg, Some(Rgb { r: 0x10, g: 0x11, b: 0x12 }));
    assert_eq!(defaults.fg, Some(Rgb { r: 0x13, g: 0x14, b: 0x15 }));
    assert_eq!(defaults.palette[1], Some(Rgb { r: 0x16, g: 0x17, b: 0x18 }));
}

#[test]
fn ghostty_included_config_cannot_replace_successful_root_theme() {
    let _guard = CONFIG_ENV_LOCK.lock().unwrap();
    let dir = std::env::temp_dir().join(format!(
        "cmux-tui-ghostty-theme-include-first-{}-{}",
        std::process::id(),
        SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
    ));
    let ghostty_dir = dir.join("ghostty");
    let themes = dir.join("themes");
    std::fs::create_dir_all(&ghostty_dir).unwrap();
    std::fs::create_dir_all(&themes).unwrap();
    std::fs::write(
        ghostty_dir.join("config"),
        "window-theme = light\n\
         theme = Root Theme\n\
         config-file = colors.conf\n",
    )
    .unwrap();
    std::fs::write(
        ghostty_dir.join("colors.conf"),
        "theme = Include Theme\n\
         foreground = #303132\n",
    )
    .unwrap();
    std::fs::write(
        themes.join("Root Theme"),
        "background = #202122\nforeground = #232425\npalette = 1=#262728\n",
    )
    .unwrap();
    std::fs::write(
        themes.join("Include Theme"),
        "background = #909192\nforeground = #939495\npalette = 1=#969798\n",
    )
    .unwrap();

    let defaults = parse_ghostty_defaults_from_path(&ghostty_dir.join("config"), &[themes])
        .expect("config parses");

    let _ = std::fs::remove_dir_all(dir);

    assert_eq!(defaults.bg, Some(Rgb { r: 0x20, g: 0x21, b: 0x22 }));
    assert_eq!(defaults.fg, Some(Rgb { r: 0x30, g: 0x31, b: 0x32 }));
    assert_eq!(defaults.palette[1], Some(Rgb { r: 0x26, g: 0x27, b: 0x28 }));
}

#[test]
fn ghostty_parent_explicit_color_wins_over_theme_loaded_by_include() {
    let _guard = CONFIG_ENV_LOCK.lock().unwrap();
    let dir = std::env::temp_dir().join(format!(
        "cmux-tui-ghostty-theme-include-overrides-{}-{}",
        std::process::id(),
        SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
    ));
    let ghostty_dir = dir.join("ghostty");
    let themes = dir.join("themes");
    std::fs::create_dir_all(&ghostty_dir).unwrap();
    std::fs::create_dir_all(&themes).unwrap();
    std::fs::write(
        ghostty_dir.join("config"),
        "window-theme = dark\n\
         foreground = #010203\n\
         config-file = colors.conf\n",
    )
    .unwrap();
    std::fs::write(ghostty_dir.join("colors.conf"), "theme = Include Theme\n").unwrap();
    std::fs::write(
        themes.join("Include Theme"),
        "background = #202122\nforeground = #a0a1a2\npalette = 1=#232425\n",
    )
    .unwrap();

    let defaults = parse_ghostty_defaults_from_path(&ghostty_dir.join("config"), &[themes])
        .expect("config parses");

    let _ = std::fs::remove_dir_all(dir);

    assert_eq!(defaults.fg, Some(Rgb { r: 0x01, g: 0x02, b: 0x03 }));
    assert_eq!(defaults.bg, Some(Rgb { r: 0x20, g: 0x21, b: 0x22 }));
    assert_eq!(defaults.palette[1], Some(Rgb { r: 0x23, g: 0x24, b: 0x25 }));
}

#[test]
fn ghostty_included_window_theme_does_not_control_parent_conditional_theme() {
    let _guard = CONFIG_ENV_LOCK.lock().unwrap();
    let old_apple_interface_style = std::env::var_os("AppleInterfaceStyle");
    let dir = std::env::temp_dir().join(format!(
        "cmux-tui-ghostty-theme-include-window-theme-{}-{}",
        std::process::id(),
        SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
    ));
    let ghostty_dir = dir.join("ghostty");
    let themes = dir.join("themes");
    std::fs::create_dir_all(&ghostty_dir).unwrap();
    std::fs::create_dir_all(&themes).unwrap();
    std::fs::write(
        ghostty_dir.join("config"),
        "theme = light:Root Light Theme,dark:Root Dark Theme\n\
         config-file = colors.conf\n",
    )
    .unwrap();
    std::fs::write(ghostty_dir.join("colors.conf"), "window-theme = dark\n").unwrap();
    std::fs::write(
        themes.join("Root Light Theme"),
        "background = #f0f1f2\nforeground = #f3f4f5\npalette = 1=#f6f7f8\n",
    )
    .unwrap();
    std::fs::write(
        themes.join("Root Dark Theme"),
        "background = #101112\nforeground = #131415\npalette = 1=#161718\n",
    )
    .unwrap();
    // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
    unsafe { std::env::set_var("AppleInterfaceStyle", "Light") };

    let defaults = parse_ghostty_defaults_from_path(&ghostty_dir.join("config"), &[themes])
        .expect("config parses");

    restore_env_var("AppleInterfaceStyle", old_apple_interface_style);
    let _ = std::fs::remove_dir_all(dir);

    assert_eq!(defaults.bg, Some(Rgb { r: 0xf0, g: 0xf1, b: 0xf2 }));
    assert_eq!(defaults.fg, Some(Rgb { r: 0xf3, g: 0xf4, b: 0xf5 }));
    assert_eq!(defaults.palette[1], Some(Rgb { r: 0xf6, g: 0xf7, b: 0xf8 }));
}

#[test]
fn ghostty_window_theme_does_not_control_conditional_terminal_theme() {
    let _guard = CONFIG_ENV_LOCK.lock().unwrap();
    let old_apple_interface_style = std::env::var_os("AppleInterfaceStyle");
    let dir = std::env::temp_dir().join(format!(
        "cmux-tui-ghostty-invalid-window-theme-{}-{}",
        std::process::id(),
        SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(
        dir.join("Light Theme"),
        "background = #f0f1f2\nforeground = #f3f4f5\npalette = 1=#f6f7f8\n",
    )
    .unwrap();
    std::fs::write(
        dir.join("Dark Theme"),
        "background = #101112\nforeground = #131415\npalette = 1=#161718\n",
    )
    .unwrap();
    // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
    unsafe { std::env::set_var("AppleInterfaceStyle", "Light") };

    let defaults = parse_ghostty_defaults_with_theme_dirs(
        "window-theme = dark\n\
         window-theme = drak\n\
         theme = light:Light Theme,dark:Dark Theme\n",
        std::slice::from_ref(&dir),
    );

    restore_env_var("AppleInterfaceStyle", old_apple_interface_style);
    let _ = std::fs::remove_dir_all(dir);

    assert_eq!(defaults.bg, Some(Rgb { r: 0xf0, g: 0xf1, b: 0xf2 }));
    assert_eq!(defaults.fg, Some(Rgb { r: 0xf3, g: 0xf4, b: 0xf5 }));
    assert_eq!(defaults.palette[1], Some(Rgb { r: 0xf6, g: 0xf7, b: 0xf8 }));
}

#[test]
fn ghostty_config_file_expands_required_and_optional_home_relative_paths() {
    let _guard = CONFIG_ENV_LOCK.lock().unwrap();
    let old_home = std::env::var_os("HOME");
    let dir = std::env::temp_dir().join(format!(
        "cmux-tui-ghostty-home-include-{}-{}",
        std::process::id(),
        SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
    ));
    let home = dir.join("home");
    let ghostty_dir = dir.join("ghostty");
    let include_dir = home.join(".config").join("ghostty");
    std::fs::create_dir_all(&ghostty_dir).unwrap();
    std::fs::create_dir_all(&include_dir).unwrap();
    std::fs::write(
        ghostty_dir.join("config"),
        "config-file = ~/.config/ghostty/colors.conf\n\
         config-file = ?~/.config/ghostty/missing.conf\n",
    )
    .unwrap();
    std::fs::write(
        include_dir.join("colors.conf"),
        "foreground = #010203\nbackground = #040506\n",
    )
    .unwrap();
    // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
    unsafe { std::env::set_var("HOME", &home) };

    let defaults = parse_ghostty_defaults_from_path(&ghostty_dir.join("config"), &[])
        .expect("config parses");

    restore_env_var("HOME", old_home);
    let _ = std::fs::remove_dir_all(dir);

    assert_eq!(defaults.fg, Some(Rgb { r: 0x01, g: 0x02, b: 0x03 }));
    assert_eq!(defaults.bg, Some(Rgb { r: 0x04, g: 0x05, b: 0x06 }));
}

#[test]
fn ghostty_relative_theme_path_uses_declaring_config_directory() {
    let _guard = CONFIG_ENV_LOCK.lock().unwrap();
    let dir = std::env::temp_dir().join(format!(
        "cmux-tui-ghostty-relative-theme-{}-{}",
        std::process::id(),
        SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
    ));
    let ghostty_dir = dir.join("ghostty");
    let nested_dir = ghostty_dir.join("nested");
    let nested_themes = nested_dir.join("themes");
    std::fs::create_dir_all(&nested_themes).unwrap();
    std::fs::write(ghostty_dir.join("config"), "config-file = nested/colors.conf\n").unwrap();
    std::fs::write(nested_dir.join("colors.conf"), "theme = ./themes/custom\n").unwrap();
    std::fs::write(
        nested_themes.join("custom"),
        "foreground = #111213\nbackground = #141516\npalette = 1=#171819\n",
    )
    .unwrap();

    let defaults = parse_ghostty_defaults_from_path(&ghostty_dir.join("config"), &[])
        .expect("config parses");

    let _ = std::fs::remove_dir_all(dir);

    assert_eq!(defaults.fg, Some(Rgb { r: 0x11, g: 0x12, b: 0x13 }));
    assert_eq!(defaults.bg, Some(Rgb { r: 0x14, g: 0x15, b: 0x16 }));
    assert_eq!(defaults.palette[1], Some(Rgb { r: 0x17, g: 0x18, b: 0x19 }));
}

#[test]
fn ghostty_config_file_skips_non_regular_includes() {
    let _guard = CONFIG_ENV_LOCK.lock().unwrap();
    let dir = std::env::temp_dir().join(format!(
        "cmux-tui-ghostty-nonregular-include-{}-{}",
        std::process::id(),
        SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
    ));
    let ghostty_dir = dir.join("ghostty");
    std::fs::create_dir_all(ghostty_dir.join("not-a-file")).unwrap();
    std::fs::write(
        ghostty_dir.join("config"),
        "config-file = not-a-file\n\
         config-file = colors.conf\n",
    )
    .unwrap();
    std::fs::write(ghostty_dir.join("colors.conf"), "foreground = #010203\n").unwrap();

    let defaults = parse_ghostty_defaults_from_path(&ghostty_dir.join("config"), &[])
        .expect("config parses");

    let _ = std::fs::remove_dir_all(dir);

    assert_eq!(defaults.fg, Some(Rgb { r: 0x01, g: 0x02, b: 0x03 }));
}

#[test]
fn ghostty_config_file_depth_limit_bounds_include_chain() {
    let _guard = CONFIG_ENV_LOCK.lock().unwrap();
    let dir = std::env::temp_dir().join(format!(
        "cmux-tui-ghostty-depth-limit-{}-{}",
        std::process::id(),
        SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
    ));
    let ghostty_dir = dir.join("ghostty");
    std::fs::create_dir_all(&ghostty_dir).unwrap();
    for index in 0..=(GHOSTTY_CONFIG_MAX_DEPTH + 2) {
        let color = 0x10 + index as u8;
        let include = if index < GHOSTTY_CONFIG_MAX_DEPTH + 2 {
            format!("config-file = file{}.conf\n", index + 1)
        } else {
            String::new()
        };
        std::fs::write(
            ghostty_dir.join(format!("file{index}.conf")),
            format!("foreground = #{color:02x}{color:02x}{color:02x}\n{include}"),
        )
        .unwrap();
    }

    let defaults = parse_ghostty_defaults_from_path(&ghostty_dir.join("file0.conf"), &[])
        .expect("config parses");

    let _ = std::fs::remove_dir_all(dir);
    let color = 0x10 + GHOSTTY_CONFIG_MAX_DEPTH as u8;

    assert_eq!(defaults.fg, Some(Rgb { r: color, g: color, b: color }));
}

#[test]
fn ghostty_config_file_count_limit_bounds_broad_include_graph() {
    let _guard = CONFIG_ENV_LOCK.lock().unwrap();
    let dir = std::env::temp_dir().join(format!(
        "cmux-tui-ghostty-file-count-limit-{}-{}",
        std::process::id(),
        SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
    ));
    let ghostty_dir = dir.join("ghostty");
    std::fs::create_dir_all(&ghostty_dir).unwrap();
    let include_count = GHOSTTY_CONFIG_MAX_FILES + 2;
    let mut root = String::new();
    for index in 0..include_count {
        root.push_str(&format!("config-file = colors{index}.conf\n"));
        let color = 0x10 + index as u8;
        std::fs::write(
            ghostty_dir.join(format!("colors{index}.conf")),
            format!("foreground = #{color:02x}{color:02x}{color:02x}\n"),
        )
        .unwrap();
    }
    std::fs::write(ghostty_dir.join("config"), root).unwrap();

    let defaults = parse_ghostty_defaults_from_path(&ghostty_dir.join("config"), &[])
        .expect("config parses");

    let _ = std::fs::remove_dir_all(dir);
    let expected_index = GHOSTTY_CONFIG_MAX_FILES - 2;
    let color = 0x10 + expected_index as u8;

    assert_eq!(defaults.fg, Some(Rgb { r: color, g: color, b: color }));
}

#[test]
fn ghostty_config_file_size_limit_skips_oversized_includes() {
    let _guard = CONFIG_ENV_LOCK.lock().unwrap();
    let dir = std::env::temp_dir().join(format!(
        "cmux-tui-ghostty-size-limit-{}-{}",
        std::process::id(),
        SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
    ));
    let ghostty_dir = dir.join("ghostty");
    std::fs::create_dir_all(&ghostty_dir).unwrap();
    std::fs::write(
        ghostty_dir.join("config"),
        "config-file = small.conf\n\
         config-file = large.conf\n\
         config-file = later.conf\n",
    )
    .unwrap();
    std::fs::write(ghostty_dir.join("small.conf"), "foreground = #010203\n").unwrap();
    std::fs::write(
        ghostty_dir.join("large.conf"),
        "background = #a0a1a2\n".repeat((GHOSTTY_CONFIG_MAX_BYTES as usize / 20) + 1),
    )
    .unwrap();
    std::fs::write(ghostty_dir.join("later.conf"), "background = #040506\n").unwrap();

    let defaults = parse_ghostty_defaults_from_path(&ghostty_dir.join("config"), &[])
        .expect("config parses");

    let _ = std::fs::remove_dir_all(dir);

    assert_eq!(defaults.fg, Some(Rgb { r: 0x01, g: 0x02, b: 0x03 }));
    assert_eq!(defaults.bg, Some(Rgb { r: 0x04, g: 0x05, b: 0x06 }));
}

#[test]
fn ghostty_config_parse_deadline_discards_partial_defaults() {
    let _guard = CONFIG_ENV_LOCK.lock().unwrap();
    let dir = std::env::temp_dir().join(format!(
        "cmux-tui-ghostty-deadline-{}-{}",
        std::process::id(),
        SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
    ));
    let ghostty_dir = dir.join("ghostty");
    std::fs::create_dir_all(&ghostty_dir).unwrap();
    std::fs::write(
        ghostty_dir.join("config"),
        "background = #010203\nconfig-file = colors.conf\n",
    )
    .unwrap();
    std::fs::write(ghostty_dir.join("colors.conf"), "foreground = #040506\n").unwrap();

    let mut theme_candidates = Vec::new();
    let outcome = parse_ghostty_config_file_with_deadline(
        &ghostty_dir.join("config"),
        &mut theme_candidates,
        Duration::ZERO,
    );
    let full = parse_ghostty_defaults_from_path(&ghostty_dir.join("config"), &[])
        .expect("config parses without deadline pressure");

    let _ = std::fs::remove_dir_all(dir);

    assert!(matches!(outcome, GhosttyConfigParseOutcome::TimedOut));
    assert_eq!(full.bg, Some(Rgb { r: 0x01, g: 0x02, b: 0x03 }));
    assert_eq!(full.fg, Some(Rgb { r: 0x04, g: 0x05, b: 0x06 }));
}

#[test]
fn ghostty_theme_deadline_keeps_parsed_overrides() {
    let _guard = CONFIG_ENV_LOCK.lock().unwrap();
    let dir = std::env::temp_dir().join(format!(
        "cmux-tui-ghostty-theme-deadline-{}-{}",
        std::process::id(),
        SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(
        dir.join("Dark Budget Theme"),
        "background = #101112\nforeground = #131415\npalette = 1=#161718\n",
    )
    .unwrap();
    let overrides = DefaultColors {
        fg: Some(Rgb { r: 0x01, g: 0x02, b: 0x03 }),
        bg: Some(Rgb { r: 0x04, g: 0x05, b: 0x06 }),
        ..Default::default()
    };

    let loaded = resolve_parsed_ghostty_defaults(
        vec![GhosttyThemeCandidate { value: "Dark Budget Theme".to_string(), base_dir: None }],
        std::slice::from_ref(&dir),
        overrides,
        None,
    );
    let expired = resolve_parsed_ghostty_defaults(
        vec![GhosttyThemeCandidate { value: "Dark Budget Theme".to_string(), base_dir: None }],
        std::slice::from_ref(&dir),
        overrides,
        Some(Instant::now().checked_sub(Duration::from_millis(1)).unwrap()),
    );

    let _ = std::fs::remove_dir_all(dir);

    assert_eq!(loaded.palette[1], Some(Rgb { r: 0x16, g: 0x17, b: 0x18 }));
    assert_eq!(expired.fg, Some(Rgb { r: 0x01, g: 0x02, b: 0x03 }));
    assert_eq!(expired.bg, Some(Rgb { r: 0x04, g: 0x05, b: 0x06 }));
    assert_eq!(expired.palette[1], None);
}

#[test]
fn ghostty_file_reader_enforces_byte_limit_during_read() {
    let text = "foreground = #010203\n";
    assert_eq!(
        read_ghostty_limited_string(text.as_bytes(), text.len() as u64),
        Some(text.to_string())
    );
    assert_eq!(read_ghostty_limited_string(text.as_bytes(), text.len() as u64 - 1), None);
}

#[test]
fn ghostty_theme_loader_skips_non_regular_and_oversized_candidates() {
    let _guard = CONFIG_ENV_LOCK.lock().unwrap();
    let dir = std::env::temp_dir().join(format!(
        "cmux-tui-ghostty-theme-size-limit-{}-{}",
        std::process::id(),
        SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
    ));
    let ghostty_dir = dir.join("ghostty");
    let themes = ghostty_dir.join("themes");
    std::fs::create_dir_all(themes.join("Theme Directory")).unwrap();
    std::fs::write(
        ghostty_dir.join("config"),
        "theme = Theme Directory\n\
         theme = Huge Theme\n\
         theme = Readable Theme\n",
    )
    .unwrap();
    std::fs::write(
        themes.join("Huge Theme"),
        "foreground = #a0a1a2\n".repeat((GHOSTTY_CONFIG_MAX_BYTES as usize / 20) + 1),
    )
    .unwrap();
    std::fs::write(
        themes.join("Readable Theme"),
        "foreground = #010203\nbackground = #040506\n",
    )
    .unwrap();

    let defaults = parse_ghostty_defaults_from_path(
        &ghostty_dir.join("config"),
        std::slice::from_ref(&themes),
    )
    .expect("config parses");

    let _ = std::fs::remove_dir_all(dir);

    assert_eq!(defaults.fg, Some(Rgb { r: 0x01, g: 0x02, b: 0x03 }));
    assert_eq!(defaults.bg, Some(Rgb { r: 0x04, g: 0x05, b: 0x06 }));
}
