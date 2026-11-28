use serde_json::json;

use super::super::call as dispatch;

fn ok(op: &str, request: serde_json::Value) -> serde_json::Value {
    dispatch(op, &request).unwrap_or_else(|error| panic!("{op}: {error:?}"))
}

#[test]
fn the_editor_ops_answer_through_the_dispatcher() {
    assert_eq!(ok("import.editor_choice", json!({"setting": "zed"}))["editors"], json!(["zed"]));
    assert_eq!(ok("import.editor_choice", json!({}))["choice"], json!("auto"));
    let files = ok("import.editor_files", json!({"home": "/Users/me/", "choice": "zed"}));
    assert_eq!(
        files["files"],
        json!(["/Users/me/.config/zed/settings.json", "/Users/me/.config/zed/keymap.json"])
    );
    let settings = "/Users/me/Library/Application Support/Cursor/User/settings.json";
    let loaded = ok(
        "import.editor_load",
        json!({"home": "/Users/me", "choice": "auto", "texts": {settings: "{ // jsonc\n \"editor.fontSize\": 15 }"}}),
    );
    assert_eq!(loaded["editor"], json!("cursor"));
    assert_eq!(loaded["files"], json!([settings]));
    assert_eq!(loaded["section"]["fontSize"], json!(15));
    assert_eq!(
        ok("import.editor_load", json!({"home": "/Users/me", "choice": "none", "texts": {}})),
        json!({})
    );
    let mapped =
        ok("import.editor_map", json!({"editor": "vscode", "settings": {"editor.tabSize": 2}}));
    assert_eq!(mapped["section"]["tabSize"], json!(2));
    assert!(dispatch("import.editor_map", &json!({"editor": "emacs", "settings": {}})).is_err());
    let section = ok(
        "import.editor_section",
        json!({"imported": {"tabSize": 2, "fontSize": 15}, "own": {"tabSize": 8}}),
    );
    assert_eq!(section["section"]["tabSize"], json!(8));
    assert_eq!(section["section"]["fontSize"], json!(15));
}

#[test]
fn the_toggle_ops_flip_their_keys() {
    assert_eq!(ok("editor_toggle.all", json!({}))["toggles"][0]["key"], json!("editor.wordWrap"));
    let wrap = ok("editor_toggle.next", json!({"action": "toggleFileEditorWordWrap"}));
    assert_eq!(wrap, json!({"key": "editor.wordWrap", "value": "on"}));
    assert_eq!(ok("editor_toggle.next", json!({"action": "nope"})), json!({}));
}

#[test]
fn the_classic_ops_answer_edits() {
    let migrated =
        ok("migrate.classic", json!({"file": {"app": {"newWorkspacePlacement": "end"}}}));
    assert_eq!(
        migrated["edits"],
        json!([
            {"path": ["workspaces", "newPlacement"], "value": "bottom"},
            {"path": ["app", "newWorkspacePlacement"], "value": null},
        ])
    );
    let prefs = ok(
        "import.classic_preferences",
        json!({"done": [], "file": {}, "sources": [{"browserDisabledOverride": true}]}),
    );
    assert_eq!(
        prefs["edits"],
        json!([
            {"path": ["browser", "openLinksInCmuxBrowser"], "value": false},
            {"path": ["browser", "enabled"], "value": false},
        ])
    );
    assert_eq!(
        ok("import.classic_preferences_pending", json!({"done": prefs["done"]}))["pending"],
        json!(false)
    );
    let pending = ok("import.classic_preferences_pending", json!({}));
    assert_eq!(pending["pending"], json!(true));
    assert_eq!(pending["marker"], json!("classicPreferencesImported"));
    assert_eq!(pending["keys"].as_array().map(Vec::len), Some(4));
}

#[test]
fn the_renamed_key_ops() {
    assert_eq!(
        ok("migrate.legacy_path", json!({"path": ["appearance", "background"]})),
        json!({"legacy": ["appearance", "backdropArt"]})
    );
    assert_eq!(ok("migrate.legacy_path", json!({"path": ["editor", "fontSize"]})), json!({}));
    let renames = ok("migrate.legacy_paths", json!({}));
    assert!(renames["renames"].as_array().is_some_and(|renames| renames.len() >= 5));
    let root = json!({"computerUse": {"enabled": false}});
    assert_eq!(
        ok("migrate.legacy_value", json!({"path": ["computerUse", "mode"], "root": root})),
        json!({"value": "off"})
    );
}

#[test]
fn the_browser_ops_match_swift() {
    let custom = ok(
        "import.search_engine",
        json!({"engine": "custom", "search": "https://s.example/?q=%s"}),
    );
    assert_eq!(
        custom["writes"],
        json!([
            {"path": ["browser", "customSearchEngine", "search"], "value": "https://s.example/?q=%s"},
            {"path": ["browser", "customSearchEngine", "suggest"], "value": null},
            {"path": ["browser", "searchEngine"], "value": "custom"},
        ])
    );
    let plain = ok("import.search_engine", json!({"engine": "kagi", "search": "ignored"}));
    assert_eq!(plain["writes"], json!([{"path": ["browser", "searchEngine"], "value": "kagi"}]));
    assert_eq!(ok("import.browser_enabled", json!({"root": {}})), json!({"enabled": true}));
    let off =
        ok("import.browser_enabled", json!({"root": {"browser": {"import": {"enabled": false}}}}));
    assert_eq!(off, json!({"enabled": false}));
    let bad =
        ok("import.browser_enabled", json!({"root": {"browser": {"import": {"enabled": "no"}}}}));
    assert_eq!(bad["enabled"], json!(true));
    assert_eq!(bad["diagnostic"]["kind"], json!("invalidValue"));
}
