//! 16-color scheme import and export (extensibility design 12.4, step 13):
//! base16 YAML, iTerm2 `.itermcolors`, Windows Terminal JSON, VS Code color
//! themes and Ghostty theme files, and a scheme from a background image held to the contrast
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

// MARK: VS Code

const VSCODE_DARK: &str = include_str!("fixtures/vscode-dark.jsonc");
const VSCODE_LIGHT: &str = include_str!("fixtures/vscode-light.json");

#[test]
fn vscode_dark_theme_with_comments_and_trailing_commas_reads_its_terminal_colors() {
    assert_eq!(SchemeFormat::detect("midnight.json", VSCODE_DARK), SchemeFormat::VsCode);
    assert_eq!(SchemeFormat::detect("midnight", VSCODE_DARK), SchemeFormat::VsCode);
    let s = Scheme::parse(VSCODE_DARK, "midnight.json", None).unwrap();
    assert_eq!(s.name.as_deref(), Some("Midnight Harbor"));
    assert_eq!(hex(s.background), 0x14161b, "editor.background");
    assert_eq!(hex(s.foreground), 0xc8ccd4, "editor.foreground");
    assert_eq!(s.cursor.map(hex), Some(0xffcc66), "editorCursor.foreground");
    assert_eq!(s.accent.map(hex), Some(0x5ccfe6), "focusBorder");
    // #3a405080 is 50% over the background.
    assert_eq!(
        s.selection_background.map(hex),
        Some(Rgb::hex(0x3a4050).mixed(Rgb::hex(0x14161b), 0.5 - 0.5 / 255.0).to_hex())
    );
    let expected = [
        0x1c1f26, 0xf07178, 0xbae67e, 0xffd580, 0x73d0ff, 0xd4bfff, 0x95e6cb, 0xc8ccd4, 0x5c6773,
        0xff8f95, 0xd5ff9e, 0xffe6a3, 0xa3e1ff, 0xe6d9ff, 0xb8f2df, 0xffffff,
    ];
    assert_eq!(s.palette.map(hex), expected);
}

#[test]
fn vscode_light_theme_without_terminal_colors_derives_them_from_token_colors() {
    assert_eq!(SchemeFormat::detect("paper.json", VSCODE_LIGHT), SchemeFormat::VsCode);
    let s = Scheme::parse(VSCODE_LIGHT, "paper.json", None).unwrap();
    assert_eq!(s.name.as_deref(), Some("Paper Mill"));
    assert_eq!(hex(s.background), 0xfafafa);
    assert_eq!(hex(s.foreground), 0x383a42);
    assert_eq!(s.cursor.map(hex), Some(0x526fff));
    assert_eq!(s.selection_background.map(hex), Some(0xe5e5e6));
    let p = s.palette.map(hex);
    // Each hue from the syntax color nearest it.
    assert_eq!(p[1], 0xe45649, "red: entity.name.tag");
    assert_eq!(p[2], 0x50a14f, "green: string");
    assert_eq!(p[3], 0xc18401, "yellow: constant");
    assert_eq!(p[4], 0x4078f2, "blue: function");
    assert_eq!(p[5], 0xa626a4, "magenta: keyword");
    assert_eq!(p[6], 0x0184bc, "cyan: property");
    // Light: black is the text, bright black the comment color.
    assert_eq!(p[0], 0x383a42);
    assert_eq!(p[8], 0xa0a1a7, "bright black: comment");
    // Bright hues lean toward the text; whites sit near the paper.
    for slot in 1..=6 {
        assert_ne!(p[slot + 8], p[slot], "slot {slot}");
    }
    assert!(s.palette[15].relative_luminance() > s.palette[7].relative_luminance());
    assert!(s.palette[0].contrast(s.background) > 4.5);
}

#[test]
fn vscode_theme_with_only_token_colors_falls_back_to_vscode_defaults() {
    let text = r##"{"type": "dark", "tokenColors": [
        {"settings": {"background": "#272822", "foreground": "#f8f8f2", "caret": "#f8f8f0"}},
        {"scope": "string", "settings": {"foreground": "#e6db74"}}
    ]}"##;
    let s = Scheme::parse(text, "mono.json", None).unwrap();
    assert_eq!(hex(s.background), 0x272822, "global entry background");
    assert_eq!(hex(s.foreground), 0xf8f8f2);
    assert_eq!(s.cursor.map(hex), Some(0xf8f8f0));
    assert_eq!(hex(s.palette[3]), 0xe6db74, "yellow: string");
    assert_eq!(hex(s.palette[4]), 0x2472c8, "blue: VS Code's default");
}

#[test]
fn vscode_round_trips_and_windows_terminal_json_stays_windows_terminal() {
    let wt = tomorrow().export(SchemeFormat::WindowsTerminal);
    assert_eq!(SchemeFormat::detect("t.json", &wt), SchemeFormat::WindowsTerminal);
    let text = tomorrow().export(SchemeFormat::VsCode);
    assert_eq!(SchemeFormat::detect("t.json", &text), SchemeFormat::VsCode);
    let back = Scheme::parse(&text, "t.json", None).unwrap();
    assert_eq!(back.palette, tomorrow().palette);
    assert_eq!(back.name.as_deref(), Some("Tomorrow Night"));
    assert_eq!(SchemeFormat::from_name("vscode"), Some(SchemeFormat::VsCode));
    // A cmux theme file's `colors` object (plain keys) is no VS Code theme.
    let cmux = r##"{"name": "Mine", "colors": {"accent": "#ff0000"}}"##;
    assert_eq!(SchemeFormat::detect("mine.json", cmux), SchemeFormat::WindowsTerminal);
}

#[test]
fn a_malformed_vscode_theme_names_the_file_and_line() {
    let bad = VSCODE_DARK.replace("\"#f07178\"", "\"#f07zz8\"");
    let line = bad.lines().position(|l| l.contains("terminal.ansiRed")).unwrap() + 1;
    let err = Scheme::parse(&bad, "midnight.json", None).unwrap_err();
    assert_eq!((err.file.as_str(), err.line), ("midnight.json", line), "{err}");
    let broken = VSCODE_DARK.replace("\"type\": \"dark\",", "\"type\": \"dark\" \"x\"");
    let err = Scheme::parse(&broken, "midnight.json", None).unwrap_err();
    assert_eq!(err.line, 6, "{err}");
    let err = Scheme::parse("{\"name\": \"x\"}", "x.json", Some(SchemeFormat::VsCode)).unwrap_err();
    assert!(err.message.contains("no colors"), "{err}");
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
