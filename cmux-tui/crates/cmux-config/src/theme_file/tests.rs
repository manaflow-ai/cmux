//! The cases of Swift `ThemeFileTests` (CmuxNextSettingsTests), so both
//! readers agree, and the render round trip.

use std::collections::BTreeSet;
use std::path::Path;

use serde_json::{Value, json};

use super::render::{RenderOptions, render};
use super::*;
use crate::schema::Schema;
use crate::value::value_at;

fn read(text: &str, base: &Value) -> ThemeFile {
    ThemeFile::read("tokyo", Some(Ok(text)), base, None, Schema::embedded(), &Domains::default())
}

fn overlay(text: &str) -> ThemeFile {
    read(text, &json!({}))
}

fn at<'a>(root: &'a Value, dotted: &str) -> Option<&'a Value> {
    value_at(root, &key_path(dotted))
}

fn none() -> BTreeSet<String> {
    BTreeSet::new()
}

#[test]
fn a_theme_file_sets_look_settings_nested_or_dotted() {
    let file = overlay(
        r#"{ "appearance": { "accent": "blue" }, "appearance.borders": "none" } // a look"#,
    );
    assert!(file.is_loaded);
    assert!(file.diagnostics.is_empty(), "{:?}", file.diagnostics);
    let root =
        file.applied(&json!({"appearance": {"accent": "red", "density": "compact"}}), &none());
    assert_eq!(at(&root, "appearance.accent"), Some(&json!("blue")));
    assert_eq!(at(&root, "appearance.borders"), Some(&json!("none")));
    assert_eq!(at(&root, "appearance.density"), Some(&json!("compact")));
}

#[test]
fn a_refused_value_is_dropped_and_names_the_file_line_and_key() {
    let file = overlay(
        "{\n  \"appearance\": { \"accent\": \"purple\", \"borders\": \"none\" },\n  \"terminal.term\": \"xterm\",\n  \"nope\": 1\n}",
    );
    assert_eq!(file.keys(), vec!["appearance.borders"]);
    let accent =
        file.diagnostics.iter().find(|d| d.path == "appearance.accent").expect("accent refused");
    assert_eq!(accent.file.as_deref(), Some("themes/tokyo.json"));
    assert_eq!(accent.line, Some(2));
    assert_eq!(accent.value.as_deref(), Some("\"purple\""));
    assert!(accent.message.starts_with("expected one of"), "{}", accent.message);
    assert!(
        accent
            .display()
            .starts_with("themes/tokyo.json:2: appearance.accent = \"purple\": expected one of")
    );
    assert!(file.diagnostics.iter().any(|d| d.path == "terminal.term"
        && d.message == "a theme file sets only look settings"
        && d.line == Some(3)));
    assert!(file.diagnostics.iter().any(|d| d.path == "nope" && d.message == "not a cmux setting"));
}

#[test]
fn a_missing_or_broken_file_is_reported_and_the_last_good_one_applies() {
    let schema = Schema::embedded();
    let domains = Domains::default();
    let missing = ThemeFile::read("gone", None, &json!({}), None, schema, &domains);
    assert!(!missing.is_loaded);
    assert_eq!(
        missing.diagnostics.iter().map(|d| d.path.as_str()).collect::<Vec<_>>(),
        [SETTING_KEY]
    );
    assert_eq!(missing.diagnostics[0].file, None);

    let broken = overlay("{\n  \"appearance.accent\": \"blue\",\n  \"appearance.borders\": \n}");
    assert!(!broken.is_loaded && broken.is_unparsable);
    assert_eq!(broken.diagnostics[0].kind, ThemeDiagnosticKind::UnreadableFile);
    assert_eq!(broken.diagnostics[0].file.as_deref(), Some("themes/tokyo.json"));
    // A half-saved file keeps the last good look, with its problem noted.
    let kept = broken.or_last_good(
        Some(r#"{ "appearance.accent": "blue" }"#),
        &json!({}),
        None,
        schema,
        &domains,
    );
    assert!(kept.is_loaded);
    assert_eq!(kept.keys(), vec!["appearance.accent"]);
    assert_eq!(kept.diagnostics.len(), 1);
    assert_eq!(kept.diagnostics[0].kind, ThemeDiagnosticKind::UnreadableFile);
}

#[test]
fn colors_edit_the_terminal_theme_the_file_names_and_keep_other_edits() {
    let base = json!({"appearance": {"themeEdits": {"Nord/background": "#2e3440"}}});
    let file = read(
        r##"{ "appearance.theme": "Rose Pine", "colors": { "background": "#191724", "foreground": "#e0def4", "palette": ["#26233a"] } }"##,
        &base,
    );
    assert!(file.diagnostics.is_empty(), "{:?}", file.diagnostics);
    let root = file.applied(&base, &none());
    assert_eq!(
        at(&root, "appearance.themeEdits"),
        Some(&json!({
            "Nord/background": "#2e3440", "Rose Pine/background": "#191724",
            "Rose Pine/foreground": "#e0def4", "Rose Pine/0": "#26233a",
        }))
    );
}

#[test]
fn a_ghostty_block_is_read_as_a_ghostty_theme_file() {
    let file = overlay(
        r#"{ "appearance.theme": "Nord", "ghostty": ["background = #2e3440", "foreground = #d8dee9", "palette = 4=#81a1c1"] }"#,
    );
    let root = file.applied(&json!({}), &none());
    let edits = at(&root, "appearance.themeEdits").expect("edits");
    assert_eq!(edits["Nord/background"], json!("#2e3440"));
    assert_eq!(edits["Nord/4"], json!("#81a1c1"));
    let refused = overlay(r#"{ "ghostty": "background = #2e3440" }"#);
    assert_eq!(
        refused.diagnostics.iter().map(|d| d.path.as_str()).collect::<Vec<_>>(),
        ["ghostty"]
    );
}

#[test]
fn low_contrast_text_is_corrected_and_says_so() {
    let file = overlay(
        r##"{ "appearance.theme": "Nord", "colors": { "background": "#222222", "foreground": "#333333" } }"##,
    );
    assert_eq!(file.corrected, vec!["foreground"]);
    let notice = &file.diagnostics[0];
    assert_eq!(notice.kind, ThemeDiagnosticKind::CorrectedValue);
    assert_eq!(notice.path, SETTING_KEY);
    let root = file.applied(&json!({}), &none());
    let foreground =
        at(&root, "appearance.themeEdits").and_then(|e| e["Nord/foreground"].as_str()).expect("fg");
    let ratio = cmux_theme_tokens::parse_color(foreground)
        .expect("color")
        .contrast(cmux_theme_tokens::parse_color("#222222").expect("color"));
    assert!(ratio >= 4.5, "{foreground} {ratio}");
    let fine = overlay(
        r##"{ "appearance.theme": "Nord", "colors": { "background": "#222222", "foreground": "#eeeeee" } }"##,
    );
    assert!(fine.corrected.is_empty());
}

#[test]
fn the_skill_example_applies_with_no_refusals() {
    let file = overlay(
        r##"{
          "appearance.theme": "TokyoNight",
          "appearance.appTheme": "TokyoNight",
          "appearance.accent": "magenta",
          "appearance.background": "none",
          "appearance.backgroundOpacity": 0.85,
          "appearance.borders": "none",
          "appearance.glassTransparency": 0.6,
          "ui.animationSpeed": "fast",
          "colors": { "background": "#16161e", "foreground": "#c0caf5", "accent": "#bb9af7" },
        }"##,
    );
    assert!(file.is_loaded);
    assert!(file.diagnostics.is_empty(), "{:?}", file.diagnostics);
    assert_eq!(file.values.len(), 9);
}

#[test]
fn a_theme_file_sets_the_terminal_font_and_the_sidebar_shape() {
    let file = overlay(
        r#"{ "terminal.fontFamily": "Menlo", "terminal.fontSize": 14, "sidebar.border": true, "sidebar.sectionLook": "card", "sidebar.showChats": false }"#,
    );
    assert_eq!(
        file.keys(),
        ["sidebar.border", "sidebar.sectionLook", "terminal.fontFamily", "terminal.fontSize"]
    );
    assert_eq!(
        file.diagnostics.iter().map(|d| d.path.as_str()).collect::<Vec<_>>(),
        ["sidebar.showChats"]
    );
}

#[test]
fn a_relative_picture_resolves_against_the_themes_folder() {
    let folder = Path::new("/tmp/cmux-config/themes");
    let background = |value: &str, folder: Option<&Path>| {
        let text = format!(r#"{{ "appearance.background": "{value}" }}"#);
        let file = ThemeFile::read(
            "harbor",
            Some(Ok(&text)),
            &json!({}),
            folder,
            Schema::embedded(),
            &Domains::default(),
        );
        at(&file.applied(&json!({}), &none()), "appearance.background").cloned()
    };
    assert_eq!(
        background("file:harbor.jpg", Some(folder)),
        Some(json!("file:/tmp/cmux-config/themes/harbor.jpg"))
    );
    assert_eq!(
        background("folder:walls/", Some(folder)),
        Some(json!("folder:/tmp/cmux-config/themes/walls"))
    );
    assert_eq!(
        background("file:../shared/sea.png", Some(folder)),
        Some(json!("file:/tmp/cmux-config/shared/sea.png"))
    );
    assert_eq!(
        background("file:/Users/me/sea.png", Some(folder)),
        Some(json!("file:/Users/me/sea.png"))
    );
    assert_eq!(
        background("velde-small-ship-storm", Some(folder)),
        Some(json!("velde-small-ship-storm"))
    );
    assert_eq!(background("file:harbor.jpg", None), None);
}

#[test]
fn the_shipped_theme_files_apply_with_no_refusals() {
    let shipped = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../Resources/theme-files");
    let home = std::env::temp_dir().join(format!("cmux-theme-file-test-{}", std::process::id()));
    let list = names(&home, Some(&shipped));
    for look in ["harbor", "classic-desktop", "phosphor", "claude-desktop", "charcoal"] {
        assert!(list.iter().any(|name| name == look), "{look} in {list:?}");
    }
    for name in &list {
        let text = source(&home, name, Some(&shipped)).expect("a file").expect("readable");
        let file = ThemeFile::read(
            name,
            Some(Ok(&text)),
            &json!({}),
            None,
            Schema::embedded(),
            &Domains::default(),
        );
        assert!(file.is_loaded, "{name}");
        assert!(file.diagnostics.is_empty(), "{name}: {:?}", file.diagnostics);
    }
}

#[test]
fn names_are_plain_file_names() {
    assert!(is_valid_name("tokyo night"));
    for bad in ["", ".hidden", "a/b", "a:b", "tokyo.json", " padded", "tab\tname"] {
        assert!(!is_valid_name(bad), "{bad:?}");
    }
    assert_eq!(name_in(&json!({"appearance": {"themeFile": "tokyo"}})), Some("tokyo"));
    assert_eq!(name_in(&json!({"appearance": {"themeFile": "../x"}})), None);
}

/// The generated file is the look it was made from: read back over the same
/// root it sets exactly the keys the root sets, to the same values, with no
/// refusals, so applying it changes nothing on screen.
#[test]
fn the_rendered_current_look_reads_back_as_the_same_look() {
    let schema = Schema::embedded();
    let domains = Domains::default();
    for root in [
        json!({}),
        json!({
            "appearance": { "accent": "blue", "borders": "none", "backgroundOpacity": 0.85, "glassTransparency": 0.4,
                            "themeEdits": { "Nord/background": "#2e3440" }, "metrics": { "chromeFontSize": 13 } },
            "terminal": { "fontSize": 14, "term": "xterm-256color" },
            "sidebar": { "border": true, "showChats": false },
        }),
    ] {
        let text =
            render(&root, schema, &domains, &RenderOptions { name: "Current", description: "" });
        let file = ThemeFile::read("current", Some(Ok(&text)), &root, None, schema, &domains);
        assert!(file.is_loaded, "{text}");
        assert!(file.diagnostics.is_empty(), "{:?}\n{text}", file.diagnostics);
        assert_eq!(file.applied(&root, &none()), root, "{text}");
        let looks: Vec<String> = look_rows(schema)
            .filter(|row| value_at(&root, &row.path).is_some())
            .map(|row| row.key.clone())
            .collect();
        assert_eq!(file.keys(), looks);
    }
    // Every look key is in the file, live or as a comment.
    let text =
        render(&json!({}), schema, &domains, &RenderOptions { name: "Default", description: "" });
    for row in look_rows(schema) {
        assert!(text.contains(&format!("\"{}\":", row.key)), "{}", row.key);
    }
}

#[test]
fn the_theme_file_schema_takes_the_shipped_files_and_flags_others() {
    let schema = Schema::embedded().theme_file_json_schema(is_look);
    let validator = jsonschema::validator_for(&schema).expect("a valid schema");
    let shipped = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../Resources/theme-files");
    for name in names(Path::new("/nonexistent"), Some(&shipped)) {
        let text =
            source(Path::new("/nonexistent"), &name, Some(&shipped)).expect("file").expect("text");
        let value = crate::jsonc::parse(&text).expect("jsonc");
        assert!(validator.is_valid(&value), "{name}");
    }
    assert!(!validator.is_valid(&json!({"terminal.term": "xterm"})));
    assert!(!validator.is_valid(&json!({"colors": {"background": "blue"}})));
}
