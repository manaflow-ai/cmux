//! 16-color scheme import and export (extensibility design 12.4, step 13):
//! base16 YAML, iTerm2 `.itermcolors`, Windows Terminal JSON and Ghostty
//! theme files, and a scheme from a background image held to the contrast
//! floors.

use cmux_theme_tokens::*;

/// Tomorrow Night, as tinted-theming publishes it (nested under `palette:`).
const TOMORROW_NIGHT: &str = r##"system: "base16"
name: "Tomorrow Night"
author: "Chris Kempson (http://chriskempson.com)"
variant: "dark"
palette:
  base00: "#1d1f21"
  base01: "#282a2e"
  base02: "#373b41"
  base03: "#969896"
  base04: "#b4b7b4"
  base05: "#c5c8c6"
  base06: "#e0e0e0"
  base07: "#ffffff"
  base08: "#cc6666"
  base09: "#de935f"
  base0A: "#f0c674"
  base0B: "#b5bd68"
  base0C: "#8abeb7"
  base0D: "#81a2be"
  base0E: "#b294bb"
  base0F: "#a3685a"
"##;

/// The same scheme in the older flat layout (`scheme:`, no `#`).
const TOMORROW_NIGHT_FLAT: &str = r#"scheme: "Tomorrow Night"
author: "Chris Kempson"
base00: "1d1f21" # background
base01: "282a2e"
base02: "373b41"
base03: "969896"
base04: "b4b7b4"
base05: "c5c8c6"
base06: "e0e0e0"
base07: "ffffff"
base08: "cc6666"
base09: "de935f"
base0A: "f0c674"
base0B: "b5bd68"
base0C: "8abeb7"
base0D: "81a2be"
base0E: "b294bb"
base0F: "a3685a"
"#;

fn hex(c: Rgb) -> u32 {
    c.to_hex()
}

fn tomorrow() -> Scheme {
    Scheme::parse(TOMORROW_NIGHT, "tomorrow-night.yaml", None).unwrap()
}

#[test]
fn base16_maps_to_the_terminal_slots() {
    let s = tomorrow();
    assert_eq!(s.name.as_deref(), Some("Tomorrow Night"));
    assert_eq!(hex(s.background), 0x1d1f21, "base00 -> background");
    assert_eq!(hex(s.foreground), 0xc5c8c6, "base05 -> foreground");
    assert_eq!(s.cursor.map(hex), Some(0xc5c8c6), "base05 -> cursor");
    assert_eq!(s.selection_background.map(hex), Some(0x373b41), "base02 -> selection");
    // base16-shell: ANSI 0-7 base00 08 0B 0A 0D 0E 0C 05, 8-15 base03 08 0B 0A 0D 0E 0C 07.
    let expected = [
        0x1d1f21, 0xcc6666, 0xb5bd68, 0xf0c674, 0x81a2be, 0xb294bb, 0x8abeb7, 0xc5c8c6, 0x969896,
        0xcc6666, 0xb5bd68, 0xf0c674, 0x81a2be, 0xb294bb, 0x8abeb7, 0xffffff,
    ];
    assert_eq!(s.palette.map(hex), expected);
}

#[test]
fn base16_flat_and_nested_layouts_read_the_same() {
    let nested = tomorrow();
    let flat = Scheme::parse(TOMORROW_NIGHT_FLAT, "x.yaml", None).unwrap();
    assert_eq!(flat.palette, nested.palette);
    assert_eq!(flat.base16, nested.base16);
    assert_eq!(flat.name.as_deref(), Some("Tomorrow Night"));
}

#[test]
fn every_format_round_trips() {
    let mut scheme = tomorrow();
    scheme.accent = None;
    for format in SchemeFormat::ALL {
        let text = scheme.export(format);
        assert_eq!(SchemeFormat::detect(&format!("t.{}", format.extension()), &text), format);
        let back = Scheme::parse(&text, "t", Some(format))
            .unwrap_or_else(|e| panic!("{format}: {e}\n{text}"));
        assert_eq!(back.background, scheme.background, "{format}");
        assert_eq!(back.foreground, scheme.foreground, "{format}");
        assert_eq!(back.palette, scheme.palette, "{format}");
        assert_eq!(back.cursor, scheme.cursor, "{format}");
        assert_eq!(back.selection_background, scheme.selection_background, "{format}");
        // Detected from the text alone, too.
        assert_eq!(Scheme::parse(&text, "t", None).unwrap().palette, scheme.palette, "{format}");
    }
    // base16 in, base16 out is the same 16 colors and name.
    let again = Scheme::parse(&scheme.export(SchemeFormat::Base16), "t.yaml", None).unwrap();
    assert_eq!(again.base16, scheme.base16);
    assert_eq!(again.name, scheme.name);
}

#[test]
fn a_scheme_from_another_format_writes_base16_and_reads_back() {
    let scheme = Scheme::from_theme_input(&ThemeInput::GHOSTTY_DEFAULT);
    let base16 = scheme.export(SchemeFormat::Base16);
    let back = Scheme::parse(&base16, "t.yaml", None).unwrap();
    assert_eq!(back.background, scheme.background);
    assert_eq!(back.foreground, scheme.foreground);
    // base16 has one color per hue, so the normal colors and ANSI 8 and 15 survive.
    for i in [1usize, 2, 3, 4, 5, 6, 8, 15] {
        assert_eq!(back.palette[i], scheme.palette[i], "ANSI {i}");
    }
}

#[test]
fn ghostty_export_keeps_the_accent() {
    let mut scheme = tomorrow();
    scheme.accent = Some(Rgb::hex(0xde935f));
    let text = scheme.export(SchemeFormat::Ghostty);
    assert!(text.contains("# cmux-accent = #de935f"), "{text}");
    assert!(text.contains("palette = 4=#81a2be"), "{text}");
    let back = Scheme::parse(&text, "Tomorrow Night", None).unwrap();
    assert_eq!(back.accent, scheme.accent);
    assert_eq!(back.name.as_deref(), Some("Tomorrow Night"));
}

#[test]
fn a_malformed_base16_file_names_the_file_and_line() {
    let bad = TOMORROW_NIGHT.replace("\"#b294bb\"", "\"#b294zz\"");
    let err = Scheme::parse(&bad, "broken.yaml", None).unwrap_err();
    assert_eq!(err.file, "broken.yaml");
    assert_eq!(err.line, 20, "{err}");
    assert!(err.to_string().starts_with("broken.yaml:20: base0E"), "{err}");

    let missing = TOMORROW_NIGHT.replace("  base0D: \"#81a2be\"\n", "");
    let err = Scheme::parse(&missing, "short.yaml", None).unwrap_err();
    assert!(err.message.contains("base0D"), "{err}");
    assert!(err.line > 0, "{err}");

    let junk = format!("{TOMORROW_NIGHT}this is not yaml\n");
    let err = Scheme::parse(&junk, "junk.yaml", None).unwrap_err();
    assert_eq!(err.line, 22, "{err}");
}

#[test]
fn a_malformed_iterm2_file_names_the_file_and_line() {
    let good = tomorrow().export(SchemeFormat::Iterm2);
    let line = good.lines().position(|l| l.contains("<real>")).unwrap() + 1;
    let bad = good.replacen("<real>1</real>", "<real>one</real>", 1);
    let err = Scheme::parse(&bad, "x.itermcolors", None).unwrap_err();
    assert_eq!((err.file.as_str(), err.line), ("x.itermcolors", line), "{err}");

    let cut = good
        .replacen("</dict>", "", 1)
        .replace("<key>Ansi 1 Color</key>", "<key>Ansi 1 Color</key><string>");
    assert!(Scheme::parse(&cut, "x.itermcolors", None).is_err());
}

#[test]
fn a_malformed_windows_terminal_file_names_the_file_and_line() {
    let good = tomorrow().export(SchemeFormat::WindowsTerminal);
    let line = good.lines().position(|l| l.contains("\"blue\"")).unwrap() + 1;
    let bad = good.replace("\"blue\": \"#81A2BE\"", "\"blue\": \"#81A2ZZ\"");
    let err = Scheme::parse(&bad, "x.json", None).unwrap_err();
    assert_eq!(err.line, line, "{err}");

    let broken = good.replacen(",\n", "\n", 3);
    let err = Scheme::parse(&broken, "x.json", None).unwrap_err();
    assert!(err.line >= 2, "{err}");
}

#[test]
fn a_malformed_ghostty_theme_names_the_file_and_line() {
    let err = Scheme::parse("background = #000000\npalette = 3=nope\n", "Mine", None).unwrap_err();
    assert_eq!((err.file.as_str(), err.line), ("Mine", 2), "{err}");
    let err = Scheme::parse("# only a comment\nfont-size = 12\n", "Empty", None).unwrap_err();
    assert!(err.message.contains("no colors"), "{err}");
}

#[test]
fn windows_terminal_reads_a_settings_file_schemes_array() {
    let one = tomorrow().export(SchemeFormat::WindowsTerminal);
    let settings = format!("{{\"profiles\": {{}}, \"schemes\": [{one}]}}");
    let s = Scheme::parse(&settings, "settings.json", None).unwrap();
    assert_eq!(s.palette, tomorrow().palette);
    assert_eq!(s.name.as_deref(), Some("Tomorrow Night"));
}

// MARK: palette from image

/// A `w x h` RGB image: the left `split` columns `left`, the rest `right`.
fn two_tone(w: u32, h: u32, split: u32, left: [u8; 3], right: [u8; 3]) -> Vec<u8> {
    let mut data = Vec::new();
    for _ in 0..h {
        for x in 0..w {
            data.extend_from_slice(if x < split { &left } else { &right });
        }
    }
    data
}

fn floors() -> (f64, f64) {
    (MINIMUM_TEXT_CONTRAST, MINIMUM_MARK_CONTRAST)
}

#[test]
fn a_two_tone_image_gives_an_accent_meeting_the_contrast_floor() {
    let (text, mark) = floors();
    // Night navy with a dim orange band: the orange is the accent, pushed to read.
    let data = two_tone(200, 120, 140, [16, 24, 48], [120, 60, 20]);
    let pixels = Pixels { width: 200, height: 120, channels: 3, data: &data };
    let p = palette_from_image(&pixels, None).unwrap();
    assert_eq!(p.appearance, Appearance::Dark);
    let bg = p.scheme.background;
    assert!(p.accent.contrast(bg) >= mark, "accent {} on {}", p.accent.describe(), bg.describe());
    // The accent keeps the image's hue (orange: red > green > blue).
    assert!(p.accent.r > p.accent.g && p.accent.g > p.accent.b, "{}", p.accent.describe());
    assert_eq!(p.scheme.accent, Some(p.accent));
    assert!(p.scheme.foreground.contrast(bg) >= text);
    for (i, c) in p.scheme.palette.iter().enumerate().skip(1) {
        assert!(c.contrast(bg) >= mark, "ANSI {i} {} on {}", c.describe(), bg.describe());
    }
    // Through derive: the chrome text and accent hold the floors.
    let tokens = ThemeTokens::derive(&p.scheme.theme_input());
    assert!(tokens.text_primary.contrast(tokens.window_background.with_alpha(1.0)) >= text);
    assert!(tokens.accent.contrast(bg) >= mark);
    assert_eq!(p.glass_tint, tokens.glass_tint);
    assert_eq!(p.swatches.len(), 2);
    assert!((p.swatches[0].1 - 140.0 / 200.0).abs() < 0.02, "{:?}", p.swatches);
}

#[test]
fn a_light_image_gives_a_light_scheme_that_reads() {
    let (text, mark) = floors();
    let data = two_tone(64, 64, 48, [240, 236, 220], [250, 220, 90]);
    let pixels = Pixels { width: 64, height: 64, channels: 3, data: &data };
    let p = palette_from_image(&pixels, None).unwrap();
    assert_eq!(p.appearance, Appearance::Light);
    let bg = p.scheme.background;
    assert!(bg.relative_luminance() > p.scheme.foreground.relative_luminance());
    assert!(p.scheme.foreground.contrast(bg) >= text);
    // A pale yellow is pushed dark enough to read on the light page.
    assert!(p.accent.contrast(bg) >= mark, "{}", p.accent.describe());
}

#[test]
fn a_gray_image_still_gets_an_accent_and_is_deterministic() {
    let mark = MINIMUM_MARK_CONTRAST;
    let data = two_tone(50, 50, 25, [30, 30, 30], [90, 90, 90]);
    let pixels = Pixels { width: 50, height: 50, channels: 3, data: &data };
    let a = palette_from_image(&pixels, None).unwrap();
    let b = palette_from_image(&pixels, None).unwrap();
    assert_eq!(a, b);
    assert!(a.accent.contrast(a.scheme.background) >= mark);
}

#[test]
fn rgba_transparent_pixels_are_skipped_and_bad_buffers_refused() {
    let mut data = Vec::new();
    for i in 0..100u32 {
        data.extend_from_slice(if i < 50 { &[0, 0, 0, 0] } else { &[200, 40, 40, 255] });
    }
    let p = palette_from_image(
        &Pixels { width: 10, height: 10, channels: 4, data: &data },
        Some(Appearance::Dark),
    )
    .unwrap();
    assert_eq!(p.swatches.len(), 1);
    assert!(
        palette_from_image(&Pixels { width: 10, height: 10, channels: 3, data: &[0; 10] }, None)
            .is_err()
    );
    assert!(
        palette_from_image(&Pixels { width: 0, height: 0, channels: 3, data: &[] }, None).is_err()
    );
}

#[test]
fn a_ppm_decodes() {
    let data = two_tone(4, 2, 2, [1, 2, 3], [4, 5, 6]);
    let mut ppm = b"P6\n# made by a test\n4 2\n255\n".to_vec();
    ppm.extend_from_slice(&data);
    assert_eq!(decode_ppm(&ppm).unwrap(), (4, 2, data));
    assert!(decode_ppm(b"P3\n1 1\n255\n0 0 0").is_err());
    assert!(decode_ppm(b"P6\n2 2\n255\n\x00").is_err());
}

// MARK: installing

fn scratch(tag: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("cmux-theme-scheme-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

#[test]
fn an_imported_scheme_installs_as_a_ghostty_theme_the_loader_reads() {
    let home = scratch("install");
    let env =
        Env { home: Some(home.clone()), xdg_data_dirs: Some(String::new()), ..Env::default() };
    let path = install_scheme(&env, "Tomorrow Night Import", &tomorrow(), false).unwrap();
    assert_eq!(path, home.join(".config/ghostty/themes/Tomorrow Night Import"));
    assert_eq!(find_theme_file(&env, "Tomorrow Night Import"), Some(path));
    // A second install without replace is refused; with replace it writes.
    assert!(matches!(
        install_scheme(&env, "Tomorrow Night Import", &tomorrow(), false),
        Err(InstallError::Exists(_))
    ));
    install_scheme(&env, "Tomorrow Night Import", &tomorrow(), true).unwrap();
    // The loader applies it as `theme = Tomorrow Night Import`.
    let loaded =
        load(&env.clone().with_theme_override("Tomorrow Night Import").unwrap(), Appearance::Dark);
    assert_eq!(loaded.input.background.to_hex(), 0x1d1f21, "{:?}", loaded.diagnostics);
    assert_eq!(loaded.input.palette.map(hex), tomorrow().palette.map(hex));
    for bad in ["", "a/b", ".hidden", "light:x,dark:y", "x=y", " pad"] {
        assert!(
            matches!(install_scheme(&env, bad, &tomorrow(), true), Err(InstallError::InvalidName)),
            "{bad:?}"
        );
    }
    let _ = std::fs::remove_dir_all(&home);
}

#[test]
fn installing_never_shadows_a_shipped_theme() {
    let home = scratch("shipped");
    let resources = home.join("res");
    std::fs::create_dir_all(resources.join("themes")).unwrap();
    std::fs::write(resources.join("themes/Nord"), "background = #2e3440\n").unwrap();
    let env = Env {
        home: Some(home.clone()),
        ghostty_resources_dir: Some(resources),
        xdg_data_dirs: Some(String::new()),
        ..Env::default()
    };
    assert!(matches!(
        install_scheme(&env, "Nord", &tomorrow(), true),
        Err(InstallError::ShippedName(_))
    ));
    let _ = std::fs::remove_dir_all(&home);
}

/// A VS Code color theme as one is shipped: JSONC, with comments, a
/// trailing comma, an `#rrggbbaa` selection, `tokenColors` and three ANSI
/// colors left out (VS Code's own defaults fill them).
const VSCODE_THEME: &str = r##"{
    // Catppuccin-like, trimmed.
    "$schema": "vscode://schemas/color-theme",
    "name": "Mocha Test",
    "type": "dark",
    /* the terminal's colors */
    "colors": {
        "editor.background": "#1e1e2e",
        "editor.foreground": "#cdd6f4",
        "editor.selectionBackground": "#ffffff40",
        "terminalCursor.foreground": "#f5e0dc",
        "focusBorder": "#89b4fa",
        "terminal.ansiBlack": "#45475a",
        "terminal.ansiRed": "#f38ba8", // red
        "terminal.ansiGreen": "#a6e3a1",
        "terminal.ansiYellow": "#f9e2af",
        "terminal.ansiBlue": "#89b4fa",
        "terminal.ansiMagenta": "#f5c2e7",
        "terminal.ansiCyan": "#94e2d5",
        "terminal.ansiWhite": "#bac2de",
        "terminal.ansiBrightBlack": "#585b70",
        "terminal.ansiBrightRed": "#f38ba8",
        "terminal.ansiBrightGreen": "#a6e3a1",
        "terminal.ansiBrightYellow": "#f9e2af",
        "terminal.ansiBrightBlue": "#89b4fa",
        "terminal.url": "http://not/a // comment",
    },
    "tokenColors": [{ "scope": "comment", "settings": { "foreground": "#6c7086" } },],
}
"##;

#[test]
fn vscode_theme_reads_its_colors_map_through_comments_and_trailing_commas() {
    assert_eq!(SchemeFormat::detect("mocha-color-theme.json", VSCODE_THEME), SchemeFormat::VsCode);
    assert_eq!(SchemeFormat::detect("theme", VSCODE_THEME), SchemeFormat::VsCode);
    assert!(is_vscode_theme(VSCODE_THEME));
    let scheme = Scheme::parse(VSCODE_THEME, "mocha-color-theme.json", None).unwrap();
    assert_eq!(scheme.name.as_deref(), Some("Mocha Test"));
    assert_eq!(scheme.background.to_hex(), 0x1e1e2e, "terminal.background falls back to editor's");
    assert_eq!(scheme.foreground.to_hex(), 0xcdd6f4);
    assert_eq!(scheme.cursor.map(Rgb::to_hex), Some(0xf5e0dc));
    assert_eq!(scheme.accent.map(Rgb::to_hex), Some(0x89b4fa), "focusBorder is the accent");
    assert_eq!(scheme.palette[0].to_hex(), 0x45475a);
    assert_eq!(scheme.palette[1].to_hex(), 0xf38ba8);
    assert_eq!(scheme.palette[8].to_hex(), 0x585b70);
    // Left out: VS Code's dark defaults (brightMagenta, brightCyan, brightWhite).
    assert_eq!(scheme.palette[13].to_hex(), 0xd670d6);
    assert_eq!(scheme.palette[14].to_hex(), 0x29b8db);
    assert_eq!(scheme.palette[15].to_hex(), 0xe5e5e5);
    // #ffffff40 over #1e1e2e: a quarter of the way to white.
    let selection = scheme.selection_background.unwrap();
    let expected = Rgb::hex(0x1e1e2e).mixed(Rgb::WHITE, f64::from(0x40) / 255.0);
    assert_eq!(selection.to_hex(), expected.to_hex());
}

#[test]
fn vscode_theme_round_trips_through_its_own_export() {
    let scheme = Scheme::parse(VSCODE_THEME, "mocha.json", None).unwrap();
    let text = scheme.export(SchemeFormat::VsCode);
    assert!(text.contains("\"terminal.ansiBrightWhite\": \"#e5e5e5\""), "{text}");
    let back = Scheme::parse(&text, "out.json", None).unwrap();
    assert_eq!(back.palette, scheme.palette);
    assert_eq!(back.background, scheme.background);
    assert_eq!(back.foreground, scheme.foreground);
    assert_eq!(back.selection_background, scheme.selection_background);
    assert_eq!(back.accent, scheme.accent);
}

#[test]
fn vscode_theme_errors_name_the_line_and_light_themes_get_light_defaults() {
    let bad = "{\n  \"colors\": {\n    \"editor.background\": \"#fff\",\n    \"terminal.ansiRed\": \"red-ish\"\n  }\n}\n";
    let error = Scheme::parse(bad, "bad.json", Some(SchemeFormat::VsCode)).unwrap_err();
    assert_eq!(error.line, 4, "{error}");
    let none = Scheme::parse("{ \"colors\": {} }", "none.json", Some(SchemeFormat::VsCode));
    assert!(none.is_err());
    let light = Scheme::parse(
        "{ \"type\": \"light\", \"colors\": { \"editor.background\": \"#fafafa\", } }",
        "light.json",
        None,
    )
    .unwrap();
    assert_eq!(light.background.to_hex(), 0xfafafa);
    assert_eq!(light.palette[4].to_hex(), 0x0451a5, "VS Code's light blue");
    // A Windows Terminal scheme is still one, and may now carry comments too.
    let wt = Scheme::parse(
        &Scheme::parse(VSCODE_THEME, "m.json", None).unwrap().export(SchemeFormat::WindowsTerminal),
        "wt.json",
        None,
    )
    .unwrap();
    assert_eq!(SchemeFormat::from_name("vscode"), Some(SchemeFormat::VsCode));
    assert_eq!(wt.palette[1].to_hex(), 0xf38ba8);
}

#[test]
fn a_scheme_derives_from_a_canvas_and_an_accent_with_readable_text() {
    for (canvas, accent, appearance) in [
        (0x1e1e2e, 0x89b4fa, Appearance::Dark),
        (0x000000, 0xff0000, Appearance::Dark),
        (0xeff1f5, 0x1e66f5, Appearance::Light),
        (0xffffff, 0xffd700, Appearance::Light),
        // Mid gray: the hardest canvas for text.
        (0x777777, 0x40a0ff, Appearance::Light),
    ] {
        let derived = scheme_from_colors(Rgb::hex(canvas), Rgb::hex(accent));
        let s = &derived.scheme;
        let what = format!("canvas {canvas:06x} accent {accent:06x}");
        assert_eq!(derived.appearance, appearance, "{what}");
        assert_eq!(s.background.to_hex(), canvas, "{what}: the canvas is the background");
        let fg = s.foreground.contrast(s.background);
        assert!(fg >= 4.5, "{what}: foreground {fg:.2}:1");
        for (i, ansi) in s.palette.iter().enumerate() {
            let c = ansi.contrast(s.background);
            let minimum = match i {
                0 => 1.0,
                8 => 3.0,
                _ => 4.5,
            };
            assert!(c >= minimum - 1e-9, "{what}: ANSI {i} {c:.2}:1");
        }
        let accent_out = s.accent.unwrap();
        assert!(accent_out.contrast(s.background) >= 3.0, "{what}: accent");
        assert_eq!(s.cursor, Some(accent_out));
        let selection = s.selection_background.unwrap();
        assert_ne!(selection, s.background, "{what}: selection shows");
        let text = s.selection_foreground.unwrap_or(s.foreground);
        assert!(text.contrast(selection) >= 4.5, "{what}: selected text");
        // Every format takes it.
        let ghostty = s.export(SchemeFormat::Ghostty);
        assert!(ghostty.contains("# cmux-accent = #"), "{ghostty}");
        assert_eq!(
            Scheme::parse(&ghostty, "t", Some(SchemeFormat::Ghostty)).unwrap().palette,
            s.palette
        );
    }
    // The accent's hue lands on the nearest ANSI slot (blue).
    let derived = scheme_from_colors(Rgb::hex(0x1e1e2e), Rgb::hex(0x89b4fa));
    let blue = oklch(derived.scheme.palette[4]).h;
    let accent = oklch(Rgb::hex(0x89b4fa)).h;
    assert!((blue - accent).abs() < 3.0, "blue {blue} accent {accent}");
}
