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
        // Text the settings already show under 4.5:1: the file shows it the same.
        json!({ "appearance": { "theme": "Nord",
                                "themeEdits": { "Nord/background": "#222222", "Nord/foreground": "#333333" } } }),
    ] {
        let text =
            render(&root, schema, &domains, &RenderOptions { name: "Current", description: "" });
        let file = ThemeFile::read("current", Some(Ok(&text)), &root, None, schema, &domains);
        assert!(file.is_loaded, "{text}");
        assert!(file.diagnostics.is_empty(), "{:?}\n{text}", file.diagnostics);
        assert_eq!(file.applied(&root, &none()), root, "{text}");
        let mut looks: Vec<String> = look_rows(schema)
            .filter(|row| value_at(&root, &row.path).is_some())
            .map(|row| row.key.clone())
            .collect();
        looks.sort();
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

/// The daemon's settings owner applies the active theme file: over the
/// user's file and under managed values, live on save, and a half-saved file
/// keeps the last good look.
#[test]
fn the_settings_owner_applies_the_active_theme_file_live() {
    use crate::managed::{FixedManagedReader, ManagedPreferences};
    use crate::owner::ConfigStore;

    let dir = std::env::temp_dir().join(format!("cmux-theme-owner-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(dir.join("themes")).expect("dir");
    let settings = dir.join("cmux-next.json");
    let theme = dir.join("themes/tokyo.json");
    std::fs::write(&settings, r#"{ "appearance": { "themeFile": "tokyo", "accent": "red" } }"#)
        .expect("write");
    std::fs::write(&theme, r#"{ "appearance.accent": "blue", "appearance.borders": "none" }"#)
        .expect("write");
    let mut managed = ManagedPreferences::default();
    managed.forced.insert("appearance.borders".into(), json!("default"));
    let mut store =
        ConfigStore::open(settings.clone(), None, None, Box::new(FixedManagedReader(managed)));
    let effective = |store: &ConfigStore| store.state().effective().root.clone();
    assert_eq!(at(&effective(&store), "appearance.accent"), Some(&json!("blue")));
    // A managed value wins over the theme file; the user's file stays theirs.
    assert_eq!(at(&effective(&store), "appearance.borders"), Some(&json!("default")));
    assert_eq!(at(&store.state().effective().file_root, "appearance.accent"), Some(&json!("red")));
    assert!(store.watch_paths().contains(&theme));

    // A save reloads, and the change names the key.
    std::fs::write(&theme, r#"{ "appearance.accent": "green" }"#).expect("write");
    let change = store.reload().expect("a change");
    assert!(change.keys.iter().any(|key| key == "appearance.accent"), "{:?}", change.keys);
    assert_eq!(at(&effective(&store), "appearance.accent"), Some(&json!("green")));

    // A half-saved file: the last good look stays, and the problem is reported.
    std::fs::write(&theme, "{ \"appearance.accent\": ").expect("write");
    store.reload();
    assert_eq!(at(&effective(&store), "appearance.accent"), Some(&json!("green")));
    assert!(
        store
            .state()
            .effective()
            .diagnostics
            .iter()
            .any(|d| d.kind == crate::DiagnosticKind::UnreadableFile)
    );

    // A refused value: one diagnostic naming file and line; the rest applies.
    std::fs::write(
        &theme,
        "{\n  \"appearance.accent\": \"purple\",\n  \"appearance.borders\": \"none\"\n}",
    )
    .expect("write");
    store.reload();
    let problem = store
        .state()
        .effective()
        .diagnostics
        .iter()
        .find(|d| d.path == "appearance.accent")
        .expect("refused");
    assert!(problem.message.starts_with("themes/tokyo.json:2:"), "{}", problem.message);
    assert_eq!(at(&effective(&store), "appearance.accent"), Some(&json!("red")));

    // Unsetting the theme file is the stock look again.
    std::fs::write(&settings, r#"{ "appearance": { "accent": "red" } }"#).expect("write");
    store.reload();
    assert!(store.state().theme_file().is_none());
    assert!(!store.watch_paths().contains(&theme));
    let _ = std::fs::remove_dir_all(&dir);
}

/// No theme file: the effective settings are exactly what they were before
/// theme files reached the daemon.
#[test]
fn with_no_theme_file_nothing_changes() {
    use crate::store::{FileRead, State};
    let text = r#"{ "appearance": { "accent": "red" }, "terminal": { "fontSize": 13 } }"#;
    let state = State::new(
        Schema::embedded(),
        FileRead::Text(text.into()),
        crate::managed::ManagedPreferences::default(),
        crate::managed::TeamPolicyLayer::default(),
        Domains::default(),
        0,
    );
    let plain = crate::effective::EffectiveSettings::merge(
        &crate::jsonc::parse(text).expect("json"),
        &crate::managed::ManagedPreferences::default(),
        &crate::managed::TeamPolicyLayer::default(),
        Schema::embedded(),
    );
    assert_eq!(state.effective().root, plain.root);
    assert!(state.theme_file().is_none());
}

// Theme slots (`"slots"`, schemas/theme/slots.json): each slot is the setting
// `appearance.slots.<slot id>`, checked on its own.

const APPEARANCE_SOURCE: &str =
    include_str!("../../../../../schemas/settings/source/appearance.json");

/// The `appearance.slots.*` rows of the settings source, in source order.
fn slot_source_rows() -> Vec<Value> {
    let source: Value = serde_json::from_str(APPEARANCE_SOURCE).expect("appearance.json parses");
    source["lists"]
        .as_array()
        .expect("lists")
        .iter()
        .flat_map(|list| list["rows"].as_array().expect("rows").iter())
        .filter(|row| row["key"].as_str().is_some_and(|key| key.starts_with(slots::SETTING_PREFIX)))
        .cloned()
        .collect()
}

/// The embedded export with the slot rows its sources declare, so these tests
/// hold before the export is regenerated on a Mac: each missing row is
/// `appearance.borders` (a portable choice look row) with the slot's key and
/// choices.
fn slot_schema() -> &'static Schema {
    static SCHEMA: std::sync::OnceLock<Schema> = std::sync::OnceLock::new();
    SCHEMA.get_or_init(|| {
        let text = include_str!("../../../../../schemas/settings/settings-schema.json");
        let mut export: Value = serde_json::from_str(text).expect("export parses");
        let rows = export["rows"].as_array_mut().expect("rows");
        let template = rows
            .iter()
            .find(|row| row["key"] == "appearance.borders")
            .cloned()
            .expect("appearance.borders row");
        for source in slot_source_rows() {
            let key = source["key"].as_str().expect("key").to_string();
            if rows.iter().any(|row| row["key"] == key.as_str()) {
                continue;
            }
            let mut row = template.clone();
            let choices = source["choices"].clone();
            let values: Vec<Value> =
                choices.as_array().expect("choices").iter().map(|c| c["value"].clone()).collect();
            row["key"] = json!(key);
            row["path"] = json!(key_path(&key));
            row["choices"] = choices;
            row["accepts"] = json!(values);
            row["default"] = source["default"].clone();
            rows.push(row);
        }
        Schema::parse(&serde_json::to_string(&export).expect("export")).expect("schema")
    })
}

fn slot_overlay(text: &str) -> ThemeFile {
    ThemeFile::read("tokyo", Some(Ok(text)), &json!({}), None, slot_schema(), &Domains::default())
}

#[test]
fn every_shipped_slot_has_a_setting_whose_choices_are_its_variants() {
    let rows = slot_source_rows();
    assert!(!slots::shipped().is_empty());
    assert_eq!(rows.len(), slots::shipped().len(), "one appearance.slots.* row per slot");
    for slot in slots::shipped() {
        let key = slots::setting_key(&slot.id);
        let row = rows
            .iter()
            .find(|row| row["key"] == key.as_str())
            .unwrap_or_else(|| panic!("{key}: no row in schemas/settings/source/appearance.json"));
        let choices: Vec<&str> = row["choices"]
            .as_array()
            .expect("choices")
            .iter()
            .map(|choice| choice["value"].as_str().expect("value"))
            .collect();
        assert_eq!(choices, slot.variants, "{key}: choices are the slot's variants in order");
        assert_eq!(row["default"], json!(slot.default_variant), "{key}: default");
        let schema_row = slot_schema().row_at(&key_path(&key)).expect("row");
        assert!(is_look(schema_row), "{key}: a theme file may set it");
    }
}

#[test]
fn a_theme_file_picks_a_slot_variant() {
    let file = slot_overlay(
        r#"{ "slots": { "chat.thinkingIndicator": "counting-dots", "chat.jumpToBottom": "bob" } }"#,
    );
    assert!(file.diagnostics.is_empty(), "{:?}", file.diagnostics);
    assert_eq!(
        file.keys(),
        vec!["appearance.slots.chat.jumpToBottom", "appearance.slots.chat.thinkingIndicator"]
    );
    let root = file.applied(&json!({}), &none());
    assert_eq!(at(&root, "appearance.slots.chat.thinkingIndicator"), Some(&json!("counting-dots")));
    assert_eq!(at(&root, "appearance.slots.chat.jumpToBottom"), Some(&json!("bob")));
}

#[test]
fn the_slot_settings_read_nested_too() {
    let file = slot_overlay(
        r#"{ "appearance": { "slots": { "chat": { "thinkingIndicator": "caret" } } } }"#,
    );
    assert!(file.diagnostics.is_empty(), "{:?}", file.diagnostics);
    assert_eq!(file.keys(), vec!["appearance.slots.chat.thinkingIndicator"]);
}

#[test]
fn an_unknown_slot_or_variant_is_dropped_with_a_notice_and_the_rest_applies() {
    let file = slot_overlay(
        "{\n  \"appearance.accent\": \"blue\",\n  \"slots\": {\n    \"chat.thinkingIndicator\": \"sparkles\",\n    \"chat.nope\": \"pulse\",\n    \"chat.jumpToBottom\": \"cascade\"\n  }\n}",
    );
    assert_eq!(file.keys(), vec!["appearance.accent", "appearance.slots.chat.jumpToBottom"]);
    let lines: Vec<String> = file.diagnostics.iter().map(ThemeDiagnostic::display).collect();
    assert_eq!(file.diagnostics.len(), 2, "{lines:?}");
    assert!(file.diagnostics.iter().all(|d| d.kind == ThemeDiagnosticKind::InvalidValue));
    let unknown_slot = file.diagnostics.iter().find(|d| d.path == "slots.chat.nope").expect("slot");
    assert_eq!(unknown_slot.line, Some(5));
    assert!(unknown_slot.message.contains("no theme slot chat.nope"), "{lines:?}");
    assert!(unknown_slot.message.contains("chat.thinkingIndicator"), "{lines:?}");
    let unknown_variant = file
        .diagnostics
        .iter()
        .find(|d| d.path == "slots.chat.thinkingIndicator")
        .expect("variant");
    assert_eq!(unknown_variant.line, Some(4));
    assert_eq!(unknown_variant.value.as_deref(), Some("\"sparkles\""));
    assert_eq!(
        unknown_variant.message,
        "expected one of default, counting-dots, pulse, caret, blocks"
    );
    assert_eq!(
        unknown_variant.display(),
        "themes/tokyo.json:4: slots.chat.thinkingIndicator = \"sparkles\": expected one of default, counting-dots, pulse, caret, blocks"
    );
}

#[test]
fn slots_that_are_no_object_are_one_notice() {
    let file = slot_overlay(r#"{ "slots": "pulse", "appearance.accent": "blue" }"#);
    assert_eq!(file.keys(), vec!["appearance.accent"]);
    assert_eq!(file.diagnostics.len(), 1);
    assert_eq!(file.diagnostics[0].path, "slots");
    let number = slot_overlay(r#"{ "slots": { "chat.jumpToBottom": 3 } }"#);
    assert!(number.keys().is_empty());
    assert_eq!(number.diagnostics[0].path, "slots.chat.jumpToBottom");
}
