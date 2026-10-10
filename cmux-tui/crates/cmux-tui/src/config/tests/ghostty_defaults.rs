//! Tests for Ghostty color, cursor and scrollback defaults parsing and resolution.

use super::*;

#[test]
fn parses_hex_and_indexed_colors() {
    assert_eq!(parse_color("#3a3a3a"), Some(Color::Rgb(0x3a, 0x3a, 0x3a)));
    assert_eq!(parse_color("#fff"), Some(Color::Rgb(255, 255, 255)));
    assert_eq!(parse_color("110"), Some(Color::Indexed(110)));
    assert_eq!(parse_color("not-a-color"), None);
    assert_eq!(parse_color("#12345"), None);
}

#[test]
fn parses_ghostty_cursor_defaults_with_later_entry_wins() {
    let defaults = parse_ghostty_defaults(
        "cursor-style = block\n\
         cursor-style-blink = true\n\
         cursor-style = bar\n\
         cursor-style-blink = false\n",
    );
    assert_eq!(defaults.cursor_style, Some(CursorShape::Bar));
    assert_eq!(defaults.cursor_blink, Some(false));

    assert_eq!(
        parse_scrollback_limit_bytes(
            "scrollback-limit-lines = 12\n\
             scrollback-limit = invalid\n\
             scrollback-limit-bytes = 8_000_000\n"
        ),
        Some(Some(8_000_000))
    );
    assert_eq!(parse_scrollback_limit_bytes("scrollback-limit = \"\"\n"), Some(None));
    assert_eq!(parse_scrollback_limit_bytes("scrollback-limit-lines = 12\n"), None);
    assert_eq!(parse_scrollback_limit_bytes("scrollback-limit = 4096#note\n"), None);

    let invalid = parse_ghostty_defaults(
        "cursor-style = underline\n\
         cursor-style-blink = true\n\
         cursor-style = beam\n\
         cursor-style-blink = sometimes\n",
    );
    assert_eq!(invalid.cursor_style, Some(CursorShape::Underline));
    assert_eq!(invalid.cursor_blink, Some(true));

    let quoted = parse_ghostty_defaults(
        "cursor-style = \"bar\"\n\
         cursor-style-blink = \"false\"\n",
    );
    assert_eq!(quoted.cursor_style, Some(CursorShape::Bar));
    assert_eq!(quoted.cursor_blink, Some(false));

    let hollow = parse_ghostty_defaults("cursor-style = block_hollow\n");
    assert_eq!(hollow.cursor_style, Some(CursorShape::BlockHollow));
}

#[test]
fn scrollback_config_outcomes_preserve_precedence_and_timeout() {
    let dir = TestDirectory::new("scrollback-outcomes");
    let value_path = dir.path.join("value.conf");
    let empty_path = dir.path.join("empty.conf");
    let absent_path = dir.path.join("absent.conf");
    std::fs::write(&value_path, "scrollback-limit = 123_456\n").unwrap();
    std::fs::write(&empty_path, "scrollback-limit = \"\"\n").unwrap();
    std::fs::write(&absent_path, "foreground = #010203\n").unwrap();

    assert_eq!(
        parse_scrollback_limit_from_root(&value_path, Instant::now() + Duration::from_secs(1)),
        ScrollbackConfigOutcome::Parsed(Some(Some(123_456)))
    );
    assert_eq!(
        parse_scrollback_limit_from_root(&absent_path, Instant::now() + Duration::from_secs(1)),
        ScrollbackConfigOutcome::Parsed(None)
    );
    assert_eq!(
        parse_scrollback_limit_from_root(&empty_path, Instant::now() + Duration::from_secs(1)),
        ScrollbackConfigOutcome::Parsed(Some(None))
    );
    assert_eq!(
        parse_scrollback_limit_from_root(&value_path, Instant::now() - Duration::from_secs(1)),
        ScrollbackConfigOutcome::TimedOut
    );
}

#[test]
fn scrollback_include_order_matches_ghostty_recursive_loading() {
    let dir = TestDirectory::new("scrollback-include-order");
    let root = dir.path.join("config");
    let first = dir.path.join("first.conf");
    let second = dir.path.join("second.conf");
    let nested = dir.path.join("nested.conf");
    std::fs::write(
        &root,
        "config-file = first.conf\n\
         scrollback-limit = 1\n\
         config-file = second.conf\n",
    )
    .unwrap();
    std::fs::write(&first, "scrollback-limit = 2\nconfig-file = nested.conf\n").unwrap();
    std::fs::write(&second, "scrollback-limit = 3\n").unwrap();
    std::fs::write(&nested, "scrollback-limit = 4\n").unwrap();

    assert_eq!(
        parse_scrollback_limit_from_root(&root, Instant::now() + Duration::from_secs(1)),
        ScrollbackConfigOutcome::Parsed(Some(Some(4)))
    );
}

#[test]
fn combined_snapshot_preserves_color_dfs_and_scrollback_bfs_precedence() {
    let dir = TestDirectory::new("combined-include-precedence");
    let root = dir.path.join("config");
    let first = dir.path.join("first.conf");
    let second = dir.path.join("second.conf");
    let nested = dir.path.join("nested.conf");
    std::fs::write(&root, "config-file = first.conf\nconfig-file = second.conf\n").unwrap();
    std::fs::write(
        &first,
        "foreground = #010203\nscrollback-limit-bytes = 2\nconfig-file = nested.conf\n",
    )
    .unwrap();
    std::fs::write(&second, "foreground = #040506\nscrollback-limit-bytes = 3\n").unwrap();
    std::fs::write(&nested, "foreground = #070809\nscrollback-limit-bytes = 4\n").unwrap();

    let mut scrollback = None;
    let outcome = parse_ghostty_defaults_from_path_result_until_with_scrollback(
        &root,
        &[],
        Some(Instant::now() + Duration::from_secs(1)),
        Some(&mut scrollback),
    );
    let GhosttyConfigParseOutcome::Parsed(colors) = outcome else {
        panic!("snapshot should parse");
    };

    assert_eq!(colors.fg, Some(Rgb { r: 4, g: 5, b: 6 }));
    assert_eq!(scrollback, Some(Some(4)));
}

#[test]
fn scrollback_config_rejects_truncated_include_snapshot() {
    let dir = TestDirectory::new("scrollback-truncated-include");
    for depth in 0..=GHOSTTY_CONFIG_MAX_DEPTH + 1 {
        let path = dir.path.join(format!("config-{depth}"));
        let include = if depth <= GHOSTTY_CONFIG_MAX_DEPTH {
            format!("config-file = config-{}\n", depth + 1)
        } else {
            "scrollback-limit-bytes = 999999\n".to_owned()
        };
        std::fs::write(path, include).unwrap();
    }
    let root = dir.path.join("config-0");
    std::fs::write(&root, "foreground = #010203\nconfig-file = config-1\n").unwrap();

    assert_eq!(
        parse_scrollback_limit_from_root(&root, Instant::now() + Duration::from_secs(1)),
        ScrollbackConfigOutcome::TimedOut
    );

    let mut scrollback = None;
    let outcome = parse_ghostty_defaults_from_path_result_until_with_scrollback(
        &root,
        &[],
        Some(Instant::now() + Duration::from_secs(1)),
        Some(&mut scrollback),
    );
    let GhosttyConfigParseOutcome::Partial(colors) = outcome else {
        panic!("truncated snapshot should preserve parsed colors");
    };
    assert_eq!(colors.fg, Some(Rgb { r: 1, g: 2, b: 3 }));

    let outcome = parse_ghostty_application_defaults_from_paths_result(vec![root], Vec::new());
    let GhosttyApplicationDefaultsParseOutcome::Partial(defaults) = outcome else {
        panic!("truncated application snapshot should remain explicitly partial");
    };
    assert_eq!(defaults.scrollback_limit_bytes, None);
}

#[test]
fn application_defaults_snapshot_resolves_colors_and_scrollback_together() {
    let dir = TestDirectory::new("application-defaults-snapshot");
    let root = dir.path.join("config");
    let include = dir.path.join("scrollback.conf");
    std::fs::write(&root, "foreground = #010203\nconfig-file = scrollback.conf\n").unwrap();
    std::fs::write(&include, "scrollback-limit-bytes = 654321\n").unwrap();

    let mut scrollback = None;
    let outcome = parse_ghostty_defaults_from_path_result_until_with_scrollback(
        &root,
        &[],
        Some(Instant::now() + Duration::from_secs(1)),
        Some(&mut scrollback),
    );
    let GhosttyConfigParseOutcome::Parsed(colors) = outcome else {
        panic!("snapshot should parse");
    };
    assert_eq!(colors.fg, Some(Rgb { r: 1, g: 2, b: 3 }));
    assert_eq!(scrollback, Some(Some(654321)));
}

#[test]
fn application_defaults_overlay_later_config_and_resolve_fallbacks() {
    let dir = TestDirectory::new("application-defaults-overlay");
    let legacy = dir.path.join("config");
    let current = dir.path.join("config.ghostty");
    std::fs::write(&legacy, "foreground = #010203\n").unwrap();
    std::fs::write(&current, "foreground = #070809\nbackground = #040506\n").unwrap();

    let defaults = parse_ghostty_application_defaults_from_paths(vec![legacy, current], Vec::new())
        .expect("config files should parse");
    assert_eq!(defaults.colors.fg, Some(Rgb { r: 7, g: 8, b: 9 }));
    assert_eq!(defaults.colors.bg, Some(Rgb { r: 4, g: 5, b: 6 }));
    assert_eq!(defaults.colors.cursor_style, Some(CursorShape::Block));
}

#[test]
fn effective_scrollback_limit_is_bounded() {
    let mut config = Config::default();
    assert_eq!(config.scrollback_limit_bytes(), DEFAULT_SCROLLBACK_LIMIT_BYTES);

    config.scrollback_limit_bytes = Some(usize::MAX);
    assert_eq!(config.scrollback_limit_bytes(), MAX_SCROLLBACK_LIMIT_BYTES);

    config.scrollback_limit_bytes = Some(0);
    assert_eq!(config.scrollback_limit_bytes(), 0);
}

#[test]
fn resolves_ghostty_cursor_defaults_without_erasing_nullable_blink_semantics() {
    let absent = resolve_ghostty_application_defaults(parse_ghostty_defaults(""));
    assert_eq!(absent.cursor_style, Some(CursorShape::Block));
    assert_eq!(absent.cursor_blink, None);

    for (value, expected) in [("true", true), ("false", false)] {
        let explicit = resolve_ghostty_application_defaults(parse_ghostty_defaults(&format!(
            "cursor-style-blink = {value}\n"
        )));
        assert_eq!(explicit.cursor_blink, Some(expected));
    }
}

#[test]
fn parses_ghostty_terminal_colors_and_palette_with_later_valid_entry_wins() {
    let defaults = parse_ghostty_defaults(
        "foreground = #010203\n\
         background = 131415\n\
         selection-background = #223344\n\
         selection-foreground = GhostWhite\n\
         palette = 1=#112233\n\
         palette = 15=#abcdef\n\
         palette = 1=#445566\n\
         palette = 1=not-a-color\n\
         palette = 256=#ffffff\n\
         palette = malformed\n",
    );

    assert_eq!(defaults.fg, Some(Rgb { r: 0x01, g: 0x02, b: 0x03 }));
    assert_eq!(defaults.bg, Some(Rgb { r: 0x13, g: 0x14, b: 0x15 }));
    assert_eq!(defaults.selection_bg, Some(Rgb { r: 0x22, g: 0x33, b: 0x44 }));
    assert_eq!(defaults.selection_fg, Some(Rgb { r: 0xf8, g: 0xf8, b: 0xff }));
    assert_eq!(defaults.palette[1], Some(Rgb { r: 0x44, g: 0x55, b: 0x66 }));
    assert_eq!(defaults.palette[15], Some(Rgb { r: 0xab, g: 0xcd, b: 0xef }));
    assert!(defaults.palette[2..15].iter().all(Option::is_none));
    assert!(defaults.palette[16..].iter().all(Option::is_none));
}

#[test]
fn parses_resolved_ghostty_show_config_output() {
    let defaults = parse_resolved_ghostty_defaults(
        "# Ghostty resolved configuration\n\
         theme = \"Monokai Classic\"\n\
         background = #272822\n\
         foreground = #fdfff1\n\
         selection-background = #57584f\n\
         selection-foreground = #fdfff1\n\
         cursor-color = #c0c1b5\n\
         cursor-style = bar\n\
         cursor-style-blink = false\n\
         palette = 0=#272822\n\
         palette = 1=#f92672\n\
         palette = 15=#fdfff1\n",
    );

    assert_eq!(defaults.bg, Some(Rgb { r: 0x27, g: 0x28, b: 0x22 }));
    assert_eq!(defaults.fg, Some(Rgb { r: 0xfd, g: 0xff, b: 0xf1 }));
    assert_eq!(defaults.selection_bg, Some(Rgb { r: 0x57, g: 0x58, b: 0x4f }));
    assert_eq!(defaults.selection_fg, Some(Rgb { r: 0xfd, g: 0xff, b: 0xf1 }));
    assert_eq!(defaults.cursor, Some(Rgb { r: 0xc0, g: 0xc1, b: 0xb5 }));
    assert_eq!(defaults.cursor_style, Some(CursorShape::Bar));
    assert_eq!(defaults.cursor_blink, Some(false));
    assert_eq!(defaults.palette[0], Some(Rgb { r: 0x27, g: 0x28, b: 0x22 }));
    assert_eq!(defaults.palette[1], Some(Rgb { r: 0xf9, g: 0x26, b: 0x72 }));
    assert_eq!(defaults.palette[15], Some(Rgb { r: 0xfd, g: 0xff, b: 0xf1 }));
}

#[cfg(unix)]
#[test]
fn packaged_ghostty_resolver_receives_matching_resources() {
    let root = std::env::temp_dir().join(format!(
        "cmux-tui-ghostty-resolver-{}-{}",
        std::process::id(),
        SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
    ));
    let resources = root.join("ghostty");
    let binary = root.join("ghostty-config-helper");
    std::fs::create_dir_all(&resources).unwrap();
    write_executable(
        &binary,
        "#!/bin/sh\n\
         printf 'resource-path = %s\\n' \"$GHOSTTY_RESOURCES_DIR\"\n\
         printf 'background = #272822\\nforeground = #fdfff1\\n'\n",
    );

    let output = ghostty_show_config_command(&platform::GhosttyInstallation {
        binary,
        resources_dir: Some(resources.clone()),
    })
    .output()
    .unwrap();
    assert!(output.status.success());
    let output = String::from_utf8(output.stdout).unwrap();
    assert!(output.contains(&format!("resource-path = {}", resources.display())));
    let defaults = parse_resolved_ghostty_defaults(&output);
    assert_eq!(defaults.bg, Some(Rgb { r: 0x27, g: 0x28, b: 0x22 }));
    assert_eq!(defaults.fg, Some(Rgb { r: 0xfd, g: 0xff, b: 0xf1 }));
    let _ = std::fs::remove_dir_all(root);
}

#[cfg(unix)]
#[test]
fn ghostty_resolver_drains_output_while_the_child_is_running() {
    let root = std::env::temp_dir().join(format!(
        "cmux-tui-ghostty-large-output-{}-{}",
        std::process::id(),
        SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
    ));
    let binary = root.join("ghostty-config-helper");
    std::fs::create_dir_all(&root).unwrap();
    write_executable(
        &binary,
        "#!/bin/sh\n\
         i=0\n\
         while [ \"$i\" -lt 2048 ]; do\n\
           printf 'palette = 1=#010203\\n'\n\
           i=$((i + 1))\n\
         done\n\
         printf 'background = #272822\\nforeground = #fdfff1\\n'\n",
    );

    let mut command = Command::new(&binary);
    command.stdout(Stdio::piped()).stderr(Stdio::null());
    let defaults = match ghostty_defaults_from_helper_command(command, Duration::from_secs(2)) {
        GhosttyHelperDefaults::Resolved(defaults) => defaults.colors,
        GhosttyHelperDefaults::Unavailable => panic!("helper output was not parsed"),
        GhosttyHelperDefaults::TimedOut => panic!("helper output timed out"),
    };
    assert_eq!(defaults.bg, Some(Rgb { r: 0x27, g: 0x28, b: 0x22 }));
    assert_eq!(defaults.fg, Some(Rgb { r: 0xfd, g: 0xff, b: 0xf1 }));
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn unusable_packaged_ghostty_resolver_falls_through() {
    let broken = PathBuf::from("/cmux-test/copied-app-binary");
    let working = PathBuf::from("/cmux-test/standalone-cli-helper");
    let installations = [
        platform::GhosttyInstallation { binary: broken.clone(), resources_dir: None },
        platform::GhosttyInstallation { binary: working.clone(), resources_dir: None },
    ];
    let mut visited = Vec::new();
    let defaults = resolved_ghostty_defaults_from_with(&installations, |installation| {
        visited.push(installation.binary.clone());
        if installation.binary == broken {
            Some(String::new())
        } else {
            Some("background = #272822\nforeground = #fdfff1\n".to_owned())
        }
    })
    .unwrap();

    assert_eq!(visited, vec![broken, working]);
    assert_eq!(defaults.bg, Some(Rgb { r: 0x27, g: 0x28, b: 0x22 }));
    assert_eq!(defaults.fg, Some(Rgb { r: 0xfd, g: 0xff, b: 0xf1 }));
}

#[test]
fn fallback_theme_selection_matches_ghostty_first_theme_wins() {
    let dir = std::env::temp_dir().join(format!(
        "cmux-tui-ghostty-theme-{}-{}",
        std::process::id(),
        SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(
        dir.join("Monokai Classic"),
        "background = #272822\nforeground = #fdfff1\npalette = 1=#f92672\n",
    )
    .unwrap();
    std::fs::write(
        dir.join("Aizen Light"),
        "background = #f0f2f6\nforeground = #1f2329\npalette = 1=#cc3768\n",
    )
    .unwrap();

    let defaults = parse_ghostty_defaults_with_theme_dirs(
        "theme = \"Monokai Classic\"\ntheme = \"Aizen Light\"\n",
        std::slice::from_ref(&dir),
    );

    assert_eq!(defaults.bg, Some(Rgb { r: 0x27, g: 0x28, b: 0x22 }));
    assert_eq!(defaults.fg, Some(Rgb { r: 0xfd, g: 0xff, b: 0xf1 }));
    assert_eq!(defaults.palette[1], Some(Rgb { r: 0xf9, g: 0x26, b: 0x72 }));
    let _ = std::fs::remove_dir_all(dir);
}

#[cfg(unix)]
#[test]
fn injected_ghostty_defaults_drive_headless_render_state() {
    use std::io::{BufRead, BufReader, Write};
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::Duration;

    use cmux_tui_core::platform::transport;
    use cmux_tui_core::{Mux, SurfaceOptions, server};

    static NEXT: AtomicU64 = AtomicU64::new(1);
    let defaults = parse_ghostty_defaults(
        "foreground = #010203\n\
         background = #131415\n\
         selection-background = #223344\n\
         selection-foreground = #fefefe\n\
         cursor-color = #c0c1b5\n\
         cursor-style = bar\n\
         cursor-style-blink = false\n\
         palette = 1=#445566\n",
    );
    let session = format!(
        "headless-config-test-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    );
    let mux = Mux::new(
        session,
        SurfaceOptions { command: Some(vec!["/bin/cat".to_string()]), ..Default::default() },
    );
    mux.set_default_colors(defaults);
    let surface = mux.new_workspace(None, Some((20, 4))).unwrap();
    surface
        .try_with_terminal(|term| {
            term.vt_write(b"\x1b[31mR");
            term.vt_write(b"\x1b_Ga=T,t=d,f=32,i=75,p=1,s=1,v=1,c=1,r=1,q=2;/wAAfw==\x1b\\");
        })
        .unwrap();
    // Re-applying through the mux exercises the existing-surface path and
    // publishes a fresh immutable render frame for the protocol server.
    mux.set_default_colors(defaults);

    let socket = server::serve(mux.clone(), None).unwrap();
    let stream = transport::connect(&socket).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    writeln!(
        writer,
        r#"{{"id":1,"cmd":"attach-surface","surface":{},"mode":"render"}}"#,
        surface.id
    )
    .unwrap();

    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    let state: Value = serde_json::from_str(&line).unwrap();
    assert_eq!(state["event"], "render-state");
    assert_eq!(state["default_fg"], "#010203");
    assert_eq!(state["default_bg"], "#131415");
    assert_eq!(state["cursor"]["color"], "#c0c1b5");
    assert_eq!(state["cursor"]["style"], "bar");
    assert_eq!(state["cursor"]["blink"], false);
    let red_run = state["rows"]
        .as_array()
        .unwrap()
        .iter()
        .flat_map(|row| row["runs"].as_array().into_iter().flatten())
        .find(|run| run["text"].as_str().is_some_and(|text| text.contains('R')))
        .expect("configured palette run");
    assert_eq!(red_run["fg"], "#445566");
    assert_eq!(state["graphics"]["images"][0]["id"], 75);
    assert_eq!(state["graphics"]["images"][0]["format"], "rgba");
    assert_eq!(state["graphics"]["images"][0]["data"], "/wAAfw==");
    assert_eq!(state["graphics"]["placements"][0]["image_id"], 75);

    let colors = surface.attach_stream().unwrap().colors;
    assert_eq!(colors.selection_bg, Some(Rgb { r: 0x22, g: 0x33, b: 0x44 }));
    assert_eq!(colors.selection_fg, Some(Rgb { r: 0xfe, g: 0xfe, b: 0xfe }));

    mux.close_surface(surface.id).unwrap();
    mux.shutdown();
    server::cleanup(&socket);
}

#[test]
fn omitted_ghostty_cursor_blink_remains_unspecified() {
    let _guard = CONFIG_ENV_LOCK.lock().unwrap();
    let old_mux_config = std::env::var_os("CMUX_MUX_CONFIG");
    let old_xdg_config_home = std::env::var_os("XDG_CONFIG_HOME");
    let dir =
        std::env::temp_dir().join(format!("mux-ghostty-cursor-default-{}", std::process::id()));
    let ghostty_dir = dir.join("ghostty");
    std::fs::create_dir_all(&ghostty_dir).unwrap();
    std::fs::write(ghostty_dir.join("config"), "cursor-style = \"bar\"\n").unwrap();
    // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
    unsafe { std::env::remove_var("CMUX_MUX_CONFIG") };
    // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
    unsafe { std::env::set_var("XDG_CONFIG_HOME", &dir) };

    let config = load();

    restore_env_var("CMUX_MUX_CONFIG", old_mux_config);
    restore_env_var("XDG_CONFIG_HOME", old_xdg_config_home);
    let _ = std::fs::remove_dir_all(&dir);

    assert_eq!(config.terminal_defaults.cursor_style, Some(CursorShape::Bar));
    assert_eq!(config.terminal_defaults.cursor_blink, None);
    assert_eq!(config.cursor_blink, None);
}
