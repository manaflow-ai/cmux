//! Ported from Swift `EditorSettingsImportTests` and `EditorPreferenceToggleTests`.

use std::collections::BTreeMap;

use serde_json::{Value, json};

use super::*;
use crate::jsonc;

const VSCODE_SETTINGS: &str = r##"
{
  // VS Code writes JSONC: comments and trailing commas.
  "editor.fontFamily": "JetBrains Mono, Menlo",
  "editor.fontSize": 14,
  "editor.tabSize": 2,
  "editor.wordWrap": "on",
  "editor.minimap.enabled": false,
  "editor.rulers": [80, {"column": 120, "color": "#ff0000"}],
  "editor.fontLigatures": "'ss01', 'calt'",
  "editor.fontWeight": "480",
  "editor.cursorStyle": "block",
  "editor.lineNumbers": "relative",
  "editor.autoClosingBrackets": "never",
  "editor.quickSuggestions": {"other": "on", "comments": "off"},
  "editor.wordBasedSuggestions": "off",
  "editor.guides.bracketPairs": "active",
  "editor.bogusKey": 1,
  "editor.lineHeight": 9999,
  "files.autoSave": "onFocusChange",
  "files.trimTrailingWhitespace": true,
  "workbench.colorTheme": "Default Dark+",
  "[python]": {"editor.tabSize": 4, "editor.insertSpaces": true, "editor.rulers": [88]},
  "[typescript][javascript]": {"editor.formatOnSave": true},
}
"##;

const VSCODE_KEYS: &str = r#"
[
  {"key": "cmd+shift+l", "command": "editor.action.selectHighlights", "when": "editorFocus"},
  {"key": "cmd+k cmd+0", "command": "-editor.foldAll"},
  {"key": "cmd+b", "command": "workbench.action.toggleSidebarVisibility"},
  {"key": "cmd+u", "command": "cursorUndo"},
]
"#;

const ZED_SETTINGS: &str = r#"
{
  "buffer_font_family": "Berkeley Mono",
  "buffer_font_size": 15,
  "buffer_font_weight": 400,
  "buffer_line_height": "comfortable",
  "tab_size": 2,
  "hard_tabs": true,
  "soft_wrap": "preferred_line_length",
  "preferred_line_length": 100,
  "wrap_guides": [100],
  "relative_line_numbers": true,
  "cursor_blink": false,
  "cursor_shape": "hollow",
  "show_whitespaces": "all",
  "minimap": {"show": "never"},
  "remove_trailing_whitespace_on_save": false,
  "autosave": {"after_delay": {"milliseconds": 500}},
  "vim_mode": true,
  "languages": {"Python": {"tab_size": 4}, "Shell Script": {"hard_tabs": true}},
}
"#;

const ZED_KEYMAP: &str = r#"
[
  {"context": "Editor", "bindings": {"cmd-shift-l": "editor::SelectAllMatches", "cmd-j": ["editor::Fold", {}], "cmd-y": "workspace::Unknown"}},
  {"context": "Terminal", "bindings": {"cmd-k": "editor::DeleteLine"}},
]
"#;

fn parsed(text: &str) -> Value {
    jsonc::parse(text).expect("fixture parses")
}

fn at<'a>(value: &'a Value, path: &[&str]) -> Option<&'a Value> {
    value_at(value, path)
}

#[test]
fn vscode_settings_map_to_the_editor_section() {
    let section = map(Editor::Vscode, &parsed(VSCODE_SETTINGS), Some(&parsed(VSCODE_KEYS)));
    assert_eq!(at(&section, &["fontFamily"]), Some(&json!("JetBrains Mono, Menlo")));
    assert_eq!(at(&section, &["fontSize"]), Some(&json!(14)));
    assert_eq!(at(&section, &["tabSize"]), Some(&json!(2)));
    assert_eq!(at(&section, &["wordWrap"]), Some(&json!("on")));
    assert_eq!(at(&section, &["minimap", "enabled"]), Some(&json!(false)));
    assert_eq!(at(&section, &["rulers"]), Some(&json!([80, 120])));
    assert_eq!(at(&section, &["fontLigatures"]), Some(&json!(true)));
    assert_eq!(
        at(&section, &["fontWeight"]),
        Some(&json!("500")),
        "480 maps to the nearest weight the row offers"
    );
    assert_eq!(at(&section, &["cursorStyle"]), Some(&json!("block")));
    assert_eq!(at(&section, &["lineNumbers"]), Some(&json!("relative")));
    assert_eq!(at(&section, &["autoClosingBrackets"]), Some(&json!(false)));
    assert_eq!(at(&section, &["quickSuggestions"]), Some(&json!(true)));
    assert_eq!(at(&section, &["wordBasedSuggestions"]), Some(&json!(false)));
    assert_eq!(at(&section, &["guides", "bracketPairs"]), Some(&json!(true)));
    assert_eq!(at(&section, &["bogusKey"]), None, "a key the editor does not read comes over");
    assert_eq!(at(&section, &["lineHeight"]), None, "a value outside the row's range comes over");
    assert_eq!(at(&section, &["autoSave"]), Some(&json!("afterDelay")));
    assert_eq!(at(&section, &["trimTrailingWhitespace"]), Some(&json!(true)));
    assert_eq!(at(&section, &["colorTheme"]), None);
    assert_eq!(at(&section, &["languages", "python", "tabSize"]), Some(&json!(4)));
    assert_eq!(at(&section, &["languages", "python", "rulers"]), Some(&json!([88])));
    assert_eq!(at(&section, &["languages", "typescript", "formatOnSave"]), Some(&json!(true)));
    assert_eq!(at(&section, &["languages", "javascript", "formatOnSave"]), Some(&json!(true)));
    let keys =
        at(&section, &["keybindings"]).and_then(Value::as_array).cloned().unwrap_or_default();
    let commands: Vec<&str> = keys.iter().filter_map(|key| key["command"].as_str()).collect();
    assert_eq!(
        commands,
        ["editor.action.selectHighlights", "-editor.foldAll", "cursorUndo"],
        "only editor commands come over"
    );
    assert_eq!(keys[0]["when"], json!("editorFocus"));
}

/// Every value the mapping makes is one the Settings row accepts, so copying
/// it into cmux-next.json loads without a diagnostic.
#[test]
fn every_mapped_value_is_one_its_row_accepts() {
    let section = map(Editor::Vscode, &parsed(VSCODE_SETTINGS), None);
    let domains = Domains::default();
    for row in Schema::embedded().rows_in(Some("editor")) {
        let Some(value) = value_at(&section, &row.path[1..]) else { continue };
        assert!(schema::accepts(row, value, &domains).is_ok(), "{} = {value}", row.key);
    }
}

#[test]
fn zed_settings_map_to_the_editor_section() {
    let section = map(Editor::Zed, &parsed(ZED_SETTINGS), Some(&parsed(ZED_KEYMAP)));
    assert_eq!(at(&section, &["fontFamily"]), Some(&json!("Berkeley Mono")));
    assert_eq!(at(&section, &["fontSize"]), Some(&json!(15)));
    assert_eq!(at(&section, &["fontWeight"]), Some(&json!("normal")));
    assert_eq!(at(&section, &["lineHeight"]), Some(&json!(1.618)));
    assert_eq!(at(&section, &["tabSize"]), Some(&json!(2)));
    assert_eq!(at(&section, &["insertSpaces"]), Some(&json!(false)));
    assert_eq!(at(&section, &["wordWrap"]), Some(&json!("wordWrapColumn")));
    assert_eq!(at(&section, &["wordWrapColumn"]), Some(&json!(100)));
    assert_eq!(at(&section, &["rulers"]), Some(&json!([100])));
    assert_eq!(at(&section, &["lineNumbers"]), Some(&json!("relative")));
    assert_eq!(at(&section, &["cursorBlinking"]), Some(&json!("solid")));
    assert_eq!(at(&section, &["cursorStyle"]), Some(&json!("block-outline")));
    assert_eq!(at(&section, &["renderWhitespace"]), Some(&json!("all")));
    assert_eq!(at(&section, &["minimap", "enabled"]), Some(&json!(false)));
    assert_eq!(at(&section, &["trimTrailingWhitespace"]), Some(&json!(false)));
    assert_eq!(at(&section, &["autoSave"]), Some(&json!("afterDelay")));
    assert_eq!(at(&section, &["autoSaveDelay"]), Some(&json!(500)));
    assert_eq!(at(&section, &["languages", "python", "tabSize"]), Some(&json!(4)));
    assert_eq!(at(&section, &["languages", "shellscript", "insertSpaces"]), Some(&json!(false)));
    let keys =
        at(&section, &["keybindings"]).and_then(Value::as_array).cloned().unwrap_or_default();
    assert!(
        keys.contains(&json!({"key": "cmd-shift-l", "command": "editor.action.selectHighlights"}))
    );
    assert!(keys.contains(&json!({"key": "cmd-j", "command": "editor.fold"})));
    assert_eq!(keys.len(), 2, "a Terminal binding or an action with no Monaco command came over");
}

/// The smaller rules: weights, rulers, bounds, autosave, the edges of ids and commands.
#[test]
fn the_value_rules_match_swift() {
    assert_eq!(font_weight(&json!(649.0)), Some(json!("600")));
    assert_eq!(font_weight(&json!(650)), Some(json!("600")), "a tie keeps the first weight");
    assert_eq!(font_weight(&json!("bold")), Some(json!("bold")));
    assert_eq!(font_weight(&json!("heavy")), None);
    assert_eq!(font_weight(&json!(true)), None);
    assert_eq!(
        rulers(&json!([0, 1.4, 1001, "80", 2, 3, 4, 5, 6, 7, 8, 9])),
        Some(json!([1, 2, 3, 4, 5, 6, 7, 8]))
    );
    assert_eq!(rulers(&json!(80)), None);
    assert!(is_editor_command("-editor.action.x"));
    assert!(is_editor_command("undo"));
    assert!(!is_editor_command("editor.action.é"));
    assert!(!is_editor_command(&format!("editor.{}", "a".repeat(122))));
    assert!(is_language_id("c++"));
    assert!(!is_language_id(""));
    assert!(!is_language_id("shell script"));
    let section = vscode(
        &json!({"files.autoSave": "off", "files.autoSaveDelay": 99, "editor.cursorSmoothCaretAnimation": true,
                "editor": {"tabSize": 4}, "editor.fontLigatures": ""}),
        None,
    );
    assert_eq!(section["autoSave"], json!("off"));
    assert_eq!(section.get("autoSaveDelay"), None);
    assert_eq!(section["cursorSmoothCaretAnimation"], json!("on"));
    assert_eq!(section["tabSize"], json!(4), "a nested editor object reads too");
    assert_eq!(section["fontLigatures"], json!(false));
    let zed_section = zed(
        &json!({"autosave": "on_focus_change", "buffer_line_height": {"custom": 1.5}, "format_on_save": "on",
                "gutter": {"line_numbers": false}, "relative_line_numbers": true, "minimap": {"show": "auto"}}),
        None,
    );
    assert_eq!(zed_section["autoSave"], json!("afterDelay"));
    assert_eq!(zed_section["lineHeight"], json!(1.5));
    assert_eq!(zed_section["formatOnSave"], json!(true));
    assert_eq!(zed_section["lineNumbers"], json!("off"));
    assert_eq!(zed_section["minimap"], json!({"enabled": true}));
}

/// A key set in cmux-next.json wins over the imported one; objects merge member by member.
#[test]
fn cmux_json_wins() {
    let imported = json!({"tabSize": 2, "minimap": {"enabled": true}, "wordWrap": "on"});
    let own = json!({"tabSize": 8, "minimap": {"side": "left"}});
    let section = section(&imported, &own);
    assert_eq!(section["tabSize"], json!(8));
    assert_eq!(section["wordWrap"], json!("on"));
    assert_eq!(section["minimap"], json!({"enabled": true, "side": "left"}));
    assert_eq!(super::section(&json!(3), &json!(null)), json!({}));
}

/// `auto` takes the first editor with a settings file, in the order VS Code,
/// Cursor, Windsurf, VSCodium, Zed; `none` reads nothing.
#[test]
fn sources_read_the_chosen_editor_only() {
    let home = "/Users/p";
    let mut texts: BTreeMap<String, String> = BTreeMap::new();
    let read = |texts: &BTreeMap<String, String>| {
        let texts = texts.clone();
        move |path: &str| texts.get(path).cloned()
    };
    assert_eq!(load(home, Choice::Auto, read(&texts)), None);
    let (zed_settings, _) = files(home, Editor::Zed);
    assert_eq!(zed_settings, "/Users/p/.config/zed/settings.json");
    texts.insert(zed_settings, ZED_SETTINGS.to_owned());
    let (cursor_settings, cursor_keys) = files(home, Editor::Cursor);
    assert_eq!(cursor_settings, "/Users/p/Library/Application Support/Cursor/User/settings.json");
    texts.insert(cursor_settings.clone(), r#"{"editor.tabSize": 3}"#.to_owned());
    // A settings file that is no object is skipped.
    texts.insert(files(home, Editor::Vscode).0, "[1]".to_owned());

    let found = load(home, Choice::Auto, read(&texts)).expect("cursor");
    assert_eq!(found.editor, Editor::Cursor);
    assert_eq!(found.files, std::slice::from_ref(&cursor_settings));
    assert_eq!(found.section["tabSize"], json!(3));
    assert_eq!(
        load(home, Choice::Editor(Editor::Zed), read(&texts)).expect("zed").section["tabSize"],
        json!(2)
    );
    assert_eq!(load(home, Choice::None, read(&texts)), None);
    assert_eq!(load(home, Choice::Editor(Editor::Vscode), read(&texts)), None);
    texts.insert(cursor_keys.clone(), "[]".to_owned());
    assert_eq!(
        load(home, Choice::Auto, read(&texts)).expect("cursor").files,
        [cursor_settings, cursor_keys]
    );

    assert_eq!(Choice::from_setting(Some("zed")), Choice::Editor(Editor::Zed));
    assert_eq!(Choice::from_setting(Some("emacs")), Choice::Auto);
    assert_eq!(Choice::from_setting(Some("none")), Choice::None);
    assert_eq!(Choice::from_setting(None), Choice::Auto);
    assert_eq!(watched_files(home, Choice::None), Vec::<String>::new());
    assert_eq!(watched_files(&format!("{home}/"), Choice::Auto).len(), 10);
    assert_eq!(Editor::Vscode.name(), "VS Code");
}

/// The copy writes only keys cmux-next.json does not have, never
/// `editor.importFrom`, and leaves language blocks live.
#[test]
fn the_copy_writes_only_unset_rows() {
    let imported = map(Editor::Vscode, &parsed(VSCODE_SETTINGS), None);
    let file = json!({"editor": {"tabSize": 8, "wordWrap": "on"}});
    let writes = copy_writes(&imported, &file);
    let keys: Vec<String> = writes.iter().map(|(path, _)| path.join(".")).collect();
    assert!(writes.len() > 5, "{keys:?}");
    assert!(
        !keys.contains(&"editor.tabSize".to_owned()),
        "the copy replaced a key cmux-next.json had"
    );
    assert!(!keys.contains(&"editor.wordWrap".to_owned()));
    assert!(keys.contains(&"editor.fontSize".to_owned()));
    assert!(
        keys.iter().all(|key| !key.starts_with("editor.languages")),
        "language blocks stay live, not copied"
    );
    let with_choice = copy_writes(&json!({"importFrom": "zed"}), &json!({}));
    assert!(with_choice.is_empty());
}

/// Ported from `EditorPreferenceToggleTests`.
#[test]
fn the_page_toggles_flip_their_keys() {
    let (wrap, value) = toggle_next("toggleFileEditorWordWrap", None).expect("word wrap");
    assert_eq!(wrap.key, "editor.wordWrap");
    assert_eq!(value, json!("on"));
    assert_eq!(
        toggle_next("toggleFileEditorWordWrap", Some(&json!({"wordWrap": "bounded"}))).unwrap().1,
        json!("off")
    );
    assert_eq!(
        toggle_next("toggleFileEditorWordWrap", Some(&json!({"wordWrap": "off"}))).unwrap().1,
        json!("on")
    );
    let (minimap, value) = toggle_next("toggleFileEditorMinimap", None).expect("minimap");
    assert_eq!(minimap.key, "editor.minimap.enabled");
    assert_eq!(value, json!(true));
    assert_eq!(
        toggle_next("toggleFileEditorMinimap", Some(&json!({"minimap": {"enabled": true}})))
            .unwrap()
            .1,
        json!(false)
    );
    assert_eq!(
        toggle_next("toggleFileEditorMinimap", Some(&json!({"minimap": false}))).unwrap().1,
        json!(true)
    );
    assert_eq!(toggle_next("nope", None), None);
}
