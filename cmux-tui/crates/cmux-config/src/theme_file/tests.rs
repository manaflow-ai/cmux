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

/// A theme written for an older cmux: a key that was removed is left out
/// with a notice, not refused as unknown (schemas/settings/retired-keys.json).
#[test]
fn a_theme_file_names_a_removed_key_and_still_reads_clean() {
    let file =
        overlay(r##"{ "appearance.tabBarBackground": "#000000", "appearance.borders": "none" }"##);
    assert!(file.diagnostics.is_empty(), "{:?}", file.diagnostics);
    assert_eq!(file.keys(), vec!["appearance.borders".to_string()]);
    assert_eq!(file.notices.len(), 1);
    assert_eq!(file.notices[0].from, "appearance.tabBarBackground");
    assert_eq!(file.notices[0].kind, crate::migrations::NoticeKind::Removed);
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

/// The sidebar's rows are part of a look: density, text size, status icons,
/// grouping and the row's own elements, so one file restyles the sidebar. A
/// per-kind row override and what the sidebar holds (chats) stay out.
#[test]
fn a_theme_file_sets_how_the_sidebar_rows_draw() {
    let file = overlay(
        r#"{
          "sidebar.density": "compact", "sidebar.textSize": "large", "sidebar.detailedStatusIcons": true,
          "sidebar.showColors": false, "sidebar.groupBy": "none", "workspaceColors.indicatorStyle": "dot",
          "sidebar.workspaceRow.icon": false, "sidebar.workspaceRow.working": true,
          "sidebar.workspaceRow.secondLineOrder": ["branch"],
          "sidebar.workspaceRow.agent.icon": true, "sidebar.showChats": false
        }"#,
    );
    assert_eq!(
        file.keys(),
        [
            "sidebar.density",
            "sidebar.detailedStatusIcons",
            "sidebar.groupBy",
            "sidebar.showColors",
            "sidebar.textSize",
            "sidebar.workspaceRow.icon",
            "sidebar.workspaceRow.secondLineOrder",
            "sidebar.workspaceRow.working",
            "workspaceColors.indicatorStyle",
        ]
    );
    let mut refused: Vec<&str> = file.diagnostics.iter().map(|d| d.path.as_str()).collect();
    refused.sort();
    assert_eq!(refused, ["sidebar.showChats", "sidebar.workspaceRow.agent.icon"]);
}

/// The app's copy of the look lists (Swift `ThemeFileOverlay`) is this one:
/// a key one reader takes and the other refuses would apply in the app and
/// not in the CLI's `cmux theme check`, or the other way round.
#[test]
fn the_look_lists_match_the_apps() {
    let swift =
        std::fs::read_to_string(Path::new(env!("CARGO_MANIFEST_DIR")).join(
            "../../../Packages/macOS/CmuxNext/Sources/CmuxNextSettings/ThemeFileOverlay.swift",
        ))
        .expect("ThemeFileOverlay.swift");
    // The quoted strings of the Swift `static let NAME ... = [ ... ]` literal.
    let literal = |name: &str| -> BTreeSet<String> {
        let start = swift.find(&format!("static let {name}")).expect(name);
        let body = &swift[start..];
        let body = &body[body.find('[').expect("[") + 1..body.find(']').expect("]")];
        // `joined(separator: ".")` is the one quoted string that is no key.
        body.split('"').skip(1).step_by(2).filter(|s| *s != ".").map(str::to_owned).collect()
    };
    let set = |list: &[&str]| list.iter().map(|key| (*key).to_owned()).collect::<BTreeSet<_>>();
    assert_eq!(literal("lookKeys"), set(&LOOK_KEYS));
    assert_eq!(literal("lookPrefixes"), set(&LOOK_PREFIXES));
    // Swift names the theme file's own key and its exceptions key through their settings' `configPath`.
    let named: Vec<&str> = EXCLUDED_KEYS
        .iter()
        .copied()
        .filter(|key| ![SETTING_KEY, EXCEPTIONS_KEY].contains(key))
        .collect();
    assert_eq!(literal("excludedKeys"), set(&named));
    assert!(
        swift.contains("ThemeFileSetting.configPath")
            && swift.contains("ThemeFileExceptionsSetting.configPath")
    );
    assert!(swift.contains(&format!("static let rowPrefix = \"{ROW_PREFIX}\"")));
}

/// The shipped Minimal sessions file sets every key it writes, each to the
/// value it writes, with no refusal: read through the same reader the app's
/// copy uses, applied over an empty root, every value reads back.
#[test]
fn the_minimal_sessions_file_applies_every_value_it_writes() {
    let text = shipped("minimal-sessions").expect("minimal-sessions ships");
    let file = ThemeFile::read(
        "minimal-sessions",
        Some(Ok(text)),
        &json!({}),
        None,
        Schema::embedded(),
        &Domains::default(),
    );
    assert!(file.is_loaded);
    assert!(file.diagnostics.is_empty(), "{:?}", file.diagnostics);
    let Value::Object(written) = crate::jsonc::parse(text).expect("the file is JSONC") else {
        panic!("the file is no object");
    };
    let written: Vec<(&String, &Value)> =
        written.iter().filter(|(key, _)| !RESERVED_KEYS.contains(&key.as_str())).collect();
    // It restyles the sidebar as a whole: every row element, the status and the grouping.
    assert!(written.len() >= 20, "the file writes only {} keys", written.len());
    let mut keys: Vec<String> = written.iter().map(|(key, _)| (*key).clone()).collect();
    keys.sort();
    assert_eq!(file.keys(), keys, "every key it writes is taken, none twice");
    let root = file.applied(&json!({}), &none());
    for (key, value) in &written {
        assert_eq!(at(&root, key), Some(*value), "{key}");
    }
    // The ones that make it a minimal session list.
    assert_eq!(at(&root, "sidebar.workspaceRow.statusPlacement"), Some(&json!("leading")));
    assert_eq!(at(&root, "appearance.statusIndicator.iconSet"), Some(&json!("symbols")));
    assert_eq!(at(&root, "sidebar.workspaceRow.icon"), Some(&json!(false)));
    assert_eq!(at(&root, "sidebar.density"), Some(&json!("compact")));
    // A managed key keeps the managed value.
    let managed: BTreeSet<String> = ["sidebar.workspaceRow".to_string()].into();
    let kept = file.applied(&json!({"sidebar": {"workspaceRow": {"icon": true}}}), &managed);
    assert_eq!(at(&kept, "sidebar.workspaceRow.icon"), Some(&json!(true)));
    assert_eq!(at(&kept, "sidebar.workspaceRow.statusPlacement"), None);
}

/// A theme file of 5,000 keys, nearly all junk (per-kind row overrides, row
/// names no schema has, keys of no setting), still loads: every junk key is
/// refused by name, the valid ones apply, and nothing else is taken.
#[test]
fn a_theme_file_of_five_thousand_junk_keys_still_applies_its_valid_ones() {
    let valid: [(&str, Value); 6] = [
        ("sidebar.density", json!("compact")),
        ("sidebar.groupBy", json!("none")),
        ("sidebar.workspaceRow.statusPlacement", json!("leading")),
        ("sidebar.workspaceRow.icon", json!(false)),
        ("sidebar.showColors", json!(false)),
        ("appearance.statusIndicator.iconSet", json!("symbols")),
    ];
    let kinds = ["terminal", "agent", "browser", "mixed"];
    let mut junk: Vec<String> = Vec::new();
    for index in 0..(5_000 - valid.len()) {
        junk.push(match index % 3 {
            0 => format!("sidebar.workspaceRow.{}.j{index}", kinds[index % kinds.len()]),
            1 => format!("sidebar.workspaceRow.j{index}"),
            _ => format!("nope.j{index}"),
        });
    }
    let mut members: Vec<String> = junk.iter().map(|key| format!("  \"{key}\": true")).collect();
    for (offset, (key, value)) in valid.iter().enumerate() {
        // Spread the valid keys through the junk.
        members.insert(offset * 800, format!("  \"{key}\": {value}"));
    }
    let text = format!("{{\n{}\n}}", members.join(",\n"));
    assert!(text.len() <= MAXIMUM_BYTES, "{} bytes", text.len());
    let started = std::time::Instant::now();
    let file = overlay(&text);
    let elapsed = started.elapsed();
    assert!(file.is_loaded);
    let mut want: Vec<String> = valid.iter().map(|(key, _)| (*key).to_string()).collect();
    want.sort();
    assert_eq!(file.keys(), want);
    let refused: BTreeSet<&str> = file.diagnostics.iter().map(|d| d.path.as_str()).collect();
    for key in &junk {
        assert!(refused.contains(key.as_str()), "{key} was not refused");
    }
    for (key, _) in &valid {
        assert!(!refused.contains(key), "{key} was refused");
    }
    assert_eq!(file.diagnostics.len(), junk.len(), "one refusal per junk key");
    let root = file.applied(&json!({}), &none());
    for (key, value) in &valid {
        assert_eq!(at(&root, key), Some(value), "{key}");
    }
    // Each refusal looks up its line in the text: keep that from going quadratic.
    assert!(elapsed.as_secs_f64() < 5.0, "reading 5,000 keys took {elapsed:?}");
}

/// Leo, 2026-11-18: "you guys should be customizing the tabs/sidebars a lot
/// deeper too. prob likewise the session info and the top right buttons as
/// well". A theme sets the toolbar's buttons, Session Info and the sidebar's
/// buttons, and carries its own density (the app reads it), which the
/// schema checks.
#[test]
fn a_theme_file_sets_the_buttons_session_info_and_its_own_density() {
    let file = overlay(
        r#"{ "tabs.toolbarButtons": ["file.open"], "window.titlebarButtons": "always", "sidebar.showSearchButton": false, "agentPane.display.sessionInfo.placement": "overlay", "density": { "basedOn": "compact", "tokens": { "tabCornerRadius": 2 } } }"#,
    );
    assert!(file.diagnostics.is_empty(), "{:?}", file.diagnostics);
    assert_eq!(
        file.keys(),
        [
            "agentPane.display.sessionInfo.placement",
            "sidebar.showSearchButton",
            "tabs.toolbarButtons",
            "window.titlebarButtons"
        ]
    );
    let schema = Schema::embedded().theme_file_json_schema(is_look);
    let validator = jsonschema::validator_for(&schema).expect("a valid schema");
    assert!(
        validator
            .is_valid(&json!({"density": {"basedOn": "cozy", "tokens": {"sidebarWidth": 250}}}))
    );
    assert!(!validator.is_valid(&json!({"density": {"basedOn": "huge"}})));
    assert!(!validator.is_valid(&json!({"density": {"tokens": {"tabCornerRadius": "round"}}})));
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
    for look in [
        "harbor",
        "classic-desktop",
        "phosphor",
        "claude-desktop",
        "charcoal",
        "teal",
        "moss",
        "meadow",
        "lily-pond",
        "minimal-sessions",
        "miku",
    ] {
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
        // A look that names a terminal theme takes the window with it, over the person's own
        // App Theme (else a dark look sits in a light window).
        let value = crate::jsonc::parse(&text).expect("jsonc");
        if value.get("appearance.theme").is_some() {
            assert_eq!(value["appearance.appTheme"], json!("followTerminal"), "{name}");
        }
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

/// Leo's Claude desktop menu as a theme file fragment (a dark ~#2b2b2b panel, a 12 pt corner, a
/// subtle edge, 30 pt rows, an 8 pt hover corner, muted shortcuts and section labels, thin
/// separators, flush submenus, a muted second line, the usage popover's strong header and thicker
/// track): every `appearance.menu.*` and `appearance.popover.*` key is a look a theme file sets.
/// The look packs copy this fragment.
const CLAUDE_MENU_FRAGMENT: &str = r##"{
  "appearance.menu.cornerRadius": 12,
  "appearance.menu.borderOpacity": 0.1,
  "appearance.menu.shadow": "standard",
  "appearance.menu.fill": "#2b2b2b",
  "appearance.menu.padding": 8,
  "appearance.menu.highlightRadius": 8,
  "appearance.menu.rowHeight": 30,
  "appearance.menu.shortcuts": "muted",
  "appearance.menu.sectionLabel": "muted",
  "appearance.menu.separator": "subtle",
  "appearance.menu.destructiveInk": "standard",
  "appearance.menu.submenu": "flush",
  "appearance.menu.subtitle": "muted",
  "appearance.popover.padding": 12,
  "appearance.popover.header": "strong",
  "appearance.popover.progressHeight": 6,
  "appearance.popover.progressFill": "standard"
}"##;

#[test]
fn a_theme_file_sets_the_menu_and_popover_look() {
    let file = overlay(CLAUDE_MENU_FRAGMENT);
    assert!(file.diagnostics.is_empty(), "{:?}", file.diagnostics);
    assert_eq!(file.keys().len(), 17, "{:?}", file.keys());
    let root = file.applied(&json!({}), &none());
    assert_eq!(at(&root, "appearance.menu.cornerRadius"), Some(&json!(12)));
    assert_eq!(at(&root, "appearance.menu.fill"), Some(&json!("#2b2b2b")));
    assert_eq!(at(&root, "appearance.menu.submenu"), Some(&json!("flush")));
    assert_eq!(at(&root, "appearance.popover.progressHeight"), Some(&json!(6)));
    // Nested, as cmux-next.json writes it, reads the same.
    let nested = overlay(r#"{ "appearance": { "menu": { "rowHeight": 28, "shadow": "none" } } }"#);
    assert!(nested.diagnostics.is_empty(), "{:?}", nested.diagnostics);
    assert_eq!(nested.keys(), vec!["appearance.menu.rowHeight", "appearance.menu.shadow"]);
}

/// The schema rows refuse what the app cannot draw, as `cmux settings set` does: a choice the menu
/// does not know, a size past its range, a fill that is no color.
#[test]
fn a_theme_file_menu_look_refuses_bad_values() {
    let file = overlay(
        r#"{ "appearance.menu.shadow": "huge", "appearance.menu.rowHeight": 90, "appearance.menu.fill": 3, "appearance.menu.cornerRadius": 10 }"#,
    );
    assert_eq!(file.keys(), vec!["appearance.menu.cornerRadius"]);
    let shadow = file
        .diagnostics
        .iter()
        .find(|d| d.path == "appearance.menu.shadow")
        .expect("shadow refused");
    assert!(shadow.message.starts_with("expected one of"), "{}", shadow.message);
    let height = file
        .diagnostics
        .iter()
        .find(|d| d.path == "appearance.menu.rowHeight")
        .expect("row height refused");
    assert!(height.message.starts_with("expected a number from 18 to 40"), "{}", height.message);
    assert!(file.diagnostics.iter().any(|d| d.path == "appearance.menu.fill"));
}

/// Unset menu keys are today's look: a theme file without them adds none, so the app and the pages
/// draw exactly what they drew.
#[test]
fn a_theme_file_without_menu_keys_sets_none() {
    let file = overlay(r#"{ "appearance.accent": "blue" }"#);
    assert!(
        file.keys()
            .iter()
            .all(|key| !key.starts_with("appearance.menu.")
                && !key.starts_with("appearance.popover."))
    );
}

/// The transcript look rides in a theme file (docs/cmux-next/transcript-customization.md): the look
/// and its tokens apply, and a tokens object with an unknown token is refused with its key.
#[test]
fn a_theme_file_carries_the_transcript_look_and_its_tokens() {
    let file = overlay(
        r#"{ "agentPane.display.transcriptLook": "studio",
             "agentPane.display.transcriptTokens": { "userMessage.radius": 20, "timestamps": "always" } }"#,
    );
    assert!(file.diagnostics.is_empty(), "{:?}", file.diagnostics);
    let root = file.applied(&json!({}), &none());
    assert_eq!(at(&root, "agentPane.display.transcriptLook"), Some(&json!("studio")));
    assert_eq!(
        at(&root, "agentPane.display.transcriptTokens"),
        Some(&json!({"userMessage.radius": 20, "timestamps": "always"}))
    );
    let bad = overlay(r#"{ "agentPane.display.transcriptTokens": { "avatar": "on" } }"#);
    assert!(bad.keys().is_empty());
    assert!(bad.diagnostics.iter().any(|d| d.path == "agentPane.display.transcriptTokens"));
}

#[test]
fn a_theme_file_sets_the_chat_typography_and_its_faces_resolve_against_the_themes_folder() {
    let folder = Path::new("/tmp/cmux-config/themes");
    let text = r#"{
        "agentPane.display.font.uiFamily": "Pack Sans, system-ui",
        "agentPane.display.font.proseFamily": "Pack Serif",
        "agentPane.display.code.family": "Pack Mono",
        "agentPane.display.code.scale": 0.8,
        "agentPane.display.font.faces": {
            "Pack Sans": "file:../fonts/PackSans.woff2",
            "Pack Serif:italic": "file:/Library/Fonts/PackSerif-Italic.otf"
        }
    }"#;
    let file = ThemeFile::read(
        "pack",
        Some(Ok(text)),
        &json!({}),
        Some(folder),
        Schema::embedded(),
        &Domains::default(),
    );
    assert!(file.diagnostics.is_empty(), "{:?}", file.diagnostics);
    assert_eq!(
        file.keys(),
        [
            "agentPane.display.code.family",
            "agentPane.display.code.scale",
            "agentPane.display.font.faces",
            "agentPane.display.font.proseFamily",
            "agentPane.display.font.uiFamily",
        ]
    );
    let applied = file.applied(&json!({}), &none());
    assert_eq!(
        at(&applied, "agentPane.display.font.faces"),
        Some(&json!({
            "Pack Sans": "file:/tmp/cmux-config/fonts/PackSans.woff2",
            "Pack Serif:italic": "file:/Library/Fonts/PackSerif-Italic.otf"
        }))
    );
    // Missing files: the check names each face; the read never stats them.
    let faces = file.face_diagnostics();
    assert_eq!(
        faces.iter().map(|d| d.path.as_str()).collect::<Vec<_>>(),
        [
            "agentPane.display.font.faces.Pack Sans",
            "agentPane.display.font.faces.Pack Serif:italic"
        ]
    );
    assert!(faces[0].display().starts_with("themes/pack.json: "), "{}", faces[0].display());
}

#[test]
fn a_theme_file_still_refuses_chat_keys_that_are_no_look() {
    let file =
        overlay(r#"{ "agentPane.display.font.size": 15, "agentPane.display.minimap": "off" }"#);
    assert_eq!(file.keys(), ["agentPane.display.font.size"]);
    assert_eq!(
        file.diagnostics.iter().map(|d| d.path.as_str()).collect::<Vec<_>>(),
        ["agentPane.display.minimap"]
    );
}

/// #44894: a key the person changed in Settings while the theme file sets it
/// (`appearance.themeFileExceptions`) keeps the person's value; the file still
/// applies everywhere else, as the Mac app's `ThemeFileOverlay` does.
#[test]
fn the_settings_owner_keeps_the_keys_changed_over_the_theme_file() {
    use crate::managed::{FixedManagedReader, ManagedPreferences};
    use crate::owner::ConfigStore;

    let dir = std::env::temp_dir().join(format!("cmux-theme-exceptions-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(dir.join("themes")).expect("dir");
    let settings = dir.join("cmux-next.json");
    std::fs::write(
        &settings,
        r#"{ "ui": { "reducedBackgrounds": false },
             "appearance": { "themeFile": "tokyo", "backgroundOpacity": 0.6,
                             "themeFileExceptions": ["appearance.backgroundOpacity", "ui.reducedBackgrounds"] } }"#,
    )
    .expect("write");
    std::fs::write(
        dir.join("themes/tokyo.json"),
        r#"{ "ui.reducedBackgrounds": true, "appearance.backgroundOpacity": 0.85, "appearance.accent": "blue" }"#,
    )
    .expect("write");
    let store = ConfigStore::open(
        settings,
        None,
        None,
        Box::new(FixedManagedReader(ManagedPreferences::default())),
    );
    let root = store.state().effective().root.clone();
    assert_eq!(at(&root, "appearance.backgroundOpacity"), Some(&json!(0.6)));
    assert_eq!(at(&root, "ui.reducedBackgrounds"), Some(&json!(false)));
    assert_eq!(at(&root, "appearance.accent"), Some(&json!("blue")));
    // A theme file never sets the list itself.
    let file = overlay(r#"{ "appearance.themeFileExceptions": ["appearance.accent"] }"#);
    assert!(file.keys().is_empty(), "{:?}", file.keys());
    let _ = std::fs::remove_dir_all(&dir);
}

/// `appearance.twoTone` is a look key: a theme file may switch the two-tone on
/// (`theme_file::two_tone`), and a value outside the list is refused.
#[test]
fn a_theme_file_sets_the_two_tone_toggle() {
    let row =
        Schema::embedded().row(two_tone::SETTING_KEY).expect("the schema has appearance.twoTone");
    assert!(is_look(row));
    let file = overlay(r#"{ "appearance": { "twoTone": "inkSakura" } }"#);
    assert!(file.diagnostics.is_empty(), "{:?}", file.diagnostics);
    let root = file.applied(&json!({}), &none());
    assert_eq!(at(&root, two_tone::SETTING_KEY), Some(&json!("inkSakura")));
    let refused = overlay(r#"{ "appearance.twoTone": "neon" }"#);
    assert_eq!(refused.diagnostics.len(), 1, "{:?}", refused.diagnostics);
}

/// `appearance.cornerFlush` (Leo, 2026-11-18: the gooey look "we have as a
/// toggle maybe"): a theme file picks the corner treatment and keeps it; a
/// value that is no corner is refused with the choices.
#[test]
fn a_theme_file_keeps_the_corner_treatment() {
    let row = Schema::embedded().row("appearance.cornerFlush").expect("the cornerFlush row");
    assert!(is_look(row), "appearance.cornerFlush is a look setting");
    assert_eq!(row.default, Some(json!("flush")), "no goo by default");
    let file = overlay(r#"{ "appearance": { "cornerFlush": "flush-goo" } }"#);
    assert!(file.diagnostics.is_empty(), "{:?}", file.diagnostics);
    assert_eq!(file.keys(), vec!["appearance.cornerFlush"]);
    let root = file.applied(&json!({"appearance": {"cornerFlush": "off"}}), &none());
    assert_eq!(at(&root, "appearance.cornerFlush"), Some(&json!("flush-goo")));
    let bad = overlay(r#"{ "appearance.cornerFlush": "goo" }"#);
    assert!(bad.keys().is_empty());
    assert!(bad.diagnostics.iter().any(|d| d.path == "appearance.cornerFlush"
        && d.message.starts_with("expected one of")));
}

/// `appearance.tabShape` (block, rounded) is a look a theme file sets (the gooey look is `appearance.cornerFlush`); any other value is refused by the
/// schema's choices, as `cmux settings set` refuses it.
#[test]
fn a_theme_file_sets_the_tab_shape() {
    for shape in ["block", "rounded"] {
        let file = overlay(&format!(r#"{{ "appearance.tabShape": "{shape}" }}"#));
        assert!(file.diagnostics.is_empty(), "{shape}: {:?}", file.diagnostics);
        let root = file.applied(&json!({}), &none());
        assert_eq!(at(&root, "appearance.tabShape"), Some(&json!(shape)));
    }
    // "gooey" is the corner treatment's `flush-goo`, not a tab shape.
    let wobbly = overlay(r#"{ "appearance.tabShape": "gooey" }"#);
    assert!(wobbly.keys().is_empty());
    let refused =
        wobbly.diagnostics.iter().find(|d| d.path == "appearance.tabShape").expect("gooey refused");
    assert!(refused.message.starts_with("expected one of"), "{}", refused.message);
}
