//! Bringing settings over from elsewhere, as JSON ops: another code editor's
//! settings.json, classic cmux's keys and preferences, and keys a newer key
//! renamed. The app reads the files and the UserDefaults domains and hands
//! their text and values here; these decide what next's file gets.
//!
//! - `import.editor_choice` `{setting?}` (`editor.importFrom`) answers
//!   `{choice, editors}`: `auto`, `none` or an editor id, and the ids it reads.
//! - `import.editor_files` `{home, choice}` answers `{files}`: every file the
//!   choice reads, to read and watch.
//! - `import.editor_load` `{home, choice, texts}` (`texts`: each read file's
//!   path and text) answers `{editor, name, files, section}` or `{}`.
//! - `import.editor_map` `{editor, settings, keys?}` answers `{section}`.
//! - `import.editor_section` `{imported, own}` answers `{section}`: cmux's own
//!   `editor` section over the imported one.
//! - `import.editor_copy` `{imported, file}` answers `{writes: [{path, value}]}`:
//!   the imported values of editor rows `file` leaves unset.
//! - `import.classic_preferences` `{done, file, sources}` answers `{edits,
//!   done}`; `import.classic_preferences_pending` `{done}` answers `{pending,
//!   keys, marker}`: whether one is left, the preference keys to read from each
//!   domain, and the key `done` is stored under.
//! - `import.search_engine` `{engine, search?, suggest?}` answers `{writes}`.
//! - `import.browser_enabled` `{root}` answers `{enabled, diagnostic?}`.
//! - `migrate.classic` `{file}` answers `{edits: [{path, value}]}` (`value`
//!   `null`: remove the key).
//! - `migrate.legacy_path` `{path}` answers `{legacy?}`;
//!   `migrate.legacy_paths` `{}` answers `{renames: [{path, legacy}]}`, every one;
//!   `migrate.legacy_value` `{path, root}` answers `{value?}`.
//! - `editor_toggle.all` `{}` answers `{toggles: [{action, key}]}`;
//!   `editor_toggle.next` `{action, section?}` answers `{key, value}` or `{}`.

use std::collections::BTreeSet;

use serde_json::{Map, Value, json};

use super::{OpError, string};
use crate::editor_import::{self, Choice, Editor};
use crate::migrations::{classic, renamed};
use crate::schema::Schema;
use crate::value::value_at;

/// The ops this area answers; `None` for an op of another area.
pub fn call(op: &str, request: &Value) -> Option<Result<Value, OpError>> {
    Some(match op {
        "import.editor_choice" => editor_choice(request),
        "import.editor_files" => editor_files(request),
        "import.editor_load" => editor_load(request),
        "import.editor_map" => editor_map(request),
        "import.editor_section" => editor_section(request),
        "import.editor_copy" => editor_copy(request),
        "import.classic_preferences" => classic_preferences(request),
        "import.classic_preferences_pending" => classic_preferences_pending(request),
        "import.search_engine" => search_engine(request),
        "import.browser_enabled" => browser_enabled(request),
        "migrate.classic" => migrate_classic(request),
        "migrate.legacy_path" => legacy_path(request),
        "migrate.legacy_paths" => Ok(legacy_paths()),
        "migrate.legacy_value" => legacy_value(request),
        "editor_toggle.all" => Ok(toggles()),
        "editor_toggle.next" => toggle_next(request),
        _ => return None,
    })
}

fn value<'a>(request: &'a Value, key: &str) -> Result<&'a Value, OpError> {
    request.get(key).ok_or_else(|| OpError::Invalid(format!("expected `{key}`")))
}

fn path(request: &Value, key: &str) -> Result<Vec<String>, OpError> {
    value(request, key)?
        .as_array()
        .and_then(|parts| parts.iter().map(|part| part.as_str().map(str::to_owned)).collect())
        .ok_or_else(|| OpError::Invalid(format!("expected an array of strings `{key}`")))
}

fn strings(request: &Value, key: &str) -> Result<BTreeSet<String>, OpError> {
    match request.get(key) {
        None | Some(Value::Null) => Ok(BTreeSet::new()),
        Some(Value::Array(items)) => items
            .iter()
            .map(|item| item.as_str().map(str::to_owned))
            .collect::<Option<_>>()
            .ok_or_else(|| OpError::Invalid(format!("expected an array of strings `{key}`"))),
        Some(_) => Err(OpError::Invalid(format!("expected an array of strings `{key}`"))),
    }
}

fn editor(request: &Value) -> Result<Editor, OpError> {
    let id = string(request, "editor")?;
    Editor::from_id(id).ok_or_else(|| OpError::Invalid(format!("unknown editor `{id}`")))
}

fn choice(request: &Value) -> Choice {
    Choice::from_setting(request.get("choice").and_then(Value::as_str))
}

fn writes(writes: Vec<(Vec<String>, Value)>) -> Value {
    let writes: Vec<Value> =
        writes.into_iter().map(|(path, value)| json!({"path": path, "value": value})).collect();
    json!({ "writes": writes })
}

fn editor_choice(request: &Value) -> Result<Value, OpError> {
    let choice = Choice::from_setting(request.get("setting").and_then(Value::as_str));
    let editors: Vec<&str> = choice.editors().into_iter().map(Editor::id).collect();
    Ok(json!({ "choice": choice.id(), "editors": editors }))
}

fn editor_files(request: &Value) -> Result<Value, OpError> {
    Ok(json!({ "files": editor_import::watched_files(string(request, "home")?, choice(request)) }))
}

fn editor_load(request: &Value) -> Result<Value, OpError> {
    let home = string(request, "home")?;
    let texts = request.get("texts").and_then(Value::as_object).cloned().unwrap_or_default();
    let read = |file: &str| texts.get(file).and_then(Value::as_str).map(str::to_owned);
    Ok(match editor_import::load(home, choice(request), read) {
        Some(found) => json!({
            "editor": found.editor.id(),
            "name": found.editor.name(),
            "files": found.files,
            "section": found.section,
        }),
        None => json!({}),
    })
}

fn editor_map(request: &Value) -> Result<Value, OpError> {
    let section = editor_import::map(
        editor(request)?,
        value(request, "settings")?,
        request.get("keys").filter(|keys| !keys.is_null()),
    );
    Ok(json!({ "section": section }))
}

fn editor_section(request: &Value) -> Result<Value, OpError> {
    let own = request.get("own").cloned().unwrap_or(Value::Null);
    Ok(json!({ "section": editor_import::section(value(request, "imported")?, &own) }))
}

fn editor_copy(request: &Value) -> Result<Value, OpError> {
    Ok(writes(editor_import::copy_writes(value(request, "imported")?, value(request, "file")?)))
}

fn classic_preferences(request: &Value) -> Result<Value, OpError> {
    let done = strings(request, "done")?;
    let file = request.get("file").cloned().unwrap_or_else(|| json!({}));
    let sources = match request.get("sources") {
        Some(Value::Array(sources)) => sources.clone(),
        None | Some(Value::Null) => Vec::new(),
        Some(_) => return Err(OpError::Invalid("expected an array `sources`".to_owned())),
    };
    let import = classic::preference_edits(&done, &file, &sources);
    let edits: Vec<Value> = import
        .edits
        .into_iter()
        .map(|(path, value)| json!({"path": path, "value": value}))
        .collect();
    Ok(json!({ "edits": edits, "done": import.done }))
}

fn classic_preferences_pending(request: &Value) -> Result<Value, OpError> {
    Ok(json!({
        "pending": classic::preferences_pending(&strings(request, "done")?),
        "keys": classic::PREFERENCE_KEYS,
        "marker": classic::IMPORTED_KEY,
    }))
}

/// Swift `BrowserOmnibarSetting.applyImported`: a custom engine's templates first, then the engine.
fn search_engine(request: &Value) -> Result<Value, OpError> {
    let engine = string(request, "engine")?;
    let mut out = Vec::new();
    if engine == "custom"
        && let Some(search) = request.get("search").and_then(Value::as_str)
    {
        let suggest = request
            .get("suggest")
            .and_then(Value::as_str)
            .map_or(Value::Null, |suggest| json!(suggest));
        out.push((
            vec!["browser".to_owned(), "customSearchEngine".to_owned(), "search".to_owned()],
            json!(search),
        ));
        out.push((
            vec!["browser".to_owned(), "customSearchEngine".to_owned(), "suggest".to_owned()],
            suggest,
        ));
    }
    out.push((vec!["browser".to_owned(), "searchEngine".to_owned()], json!(engine)));
    Ok(writes(out))
}

/// Swift `BrowserImportSetting.parse`: a missing key is the default with no
/// diagnostic; a bad value is the default plus a diagnostic.
fn browser_enabled(request: &Value) -> Result<Value, OpError> {
    let path = ["browser", "import", "enabled"];
    let fallback = Schema::embedded()
        .row("browser.import.enabled")
        .and_then(|row| row.default.as_ref())
        .and_then(Value::as_bool)
        .unwrap_or(true);
    let root = value(request, "root")?;
    Ok(match value_at(root, &path) {
        None => json!({ "enabled": fallback }),
        Some(Value::Bool(enabled)) => json!({ "enabled": enabled }),
        Some(_) => json!({
            "enabled": fallback,
            "diagnostic": {"kind": "invalidValue", "path": "browser.import.enabled", "message": "expected true or false"},
        }),
    })
}

fn migrate_classic(request: &Value) -> Result<Value, OpError> {
    let edits: Vec<Value> = classic::rename_edits(value(request, "file")?)
        .into_iter()
        .map(|(path, value)| json!({"path": path, "value": value}))
        .collect();
    Ok(json!({ "edits": edits }))
}

fn legacy_path(request: &Value) -> Result<Value, OpError> {
    let mut out = Map::new();
    if let Some(legacy) = renamed::legacy_path(&path(request, "path")?) {
        out.insert("legacy".to_owned(), json!(legacy));
    }
    Ok(Value::Object(out))
}

fn legacy_paths() -> Value {
    let renames: Vec<Value> = renamed::legacy_paths()
        .into_iter()
        .map(|(path, legacy)| json!({"path": path, "legacy": legacy}))
        .collect();
    json!({ "renames": renames })
}

fn legacy_value(request: &Value) -> Result<Value, OpError> {
    let mut out = Map::new();
    if let Some(found) = renamed::legacy_value(&path(request, "path")?, value(request, "root")?) {
        out.insert("value".to_owned(), found);
    }
    Ok(Value::Object(out))
}

fn toggles() -> Value {
    let toggles: Vec<Value> = editor_import::TOGGLES
        .iter()
        .map(|toggle| json!({"action": toggle.action, "key": toggle.key}))
        .collect();
    json!({ "toggles": toggles })
}

fn toggle_next(request: &Value) -> Result<Value, OpError> {
    let section = request.get("section").filter(|section| !section.is_null());
    Ok(match editor_import::toggle_next(string(request, "action")?, section) {
        Some((toggle, value)) => json!({ "key": toggle.key, "value": value }),
        None => json!({}),
    })
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::super::call as dispatch;

    fn ok(op: &str, request: serde_json::Value) -> serde_json::Value {
        dispatch(op, &request).unwrap_or_else(|error| panic!("{op}: {error:?}"))
    }

    #[test]
    fn the_editor_ops_answer_through_the_dispatcher() {
        assert_eq!(
            ok("import.editor_choice", json!({"setting": "zed"}))["editors"],
            json!(["zed"])
        );
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
        assert!(
            dispatch("import.editor_map", &json!({"editor": "emacs", "settings": {}})).is_err()
        );
        let section = ok(
            "import.editor_section",
            json!({"imported": {"tabSize": 2, "fontSize": 15}, "own": {"tabSize": 8}}),
        );
        assert_eq!(section["section"]["tabSize"], json!(8));
        assert_eq!(section["section"]["fontSize"], json!(15));
    }

    #[test]
    fn the_toggle_ops_flip_their_keys() {
        assert_eq!(
            ok("editor_toggle.all", json!({}))["toggles"][0]["key"],
            json!("editor.wordWrap")
        );
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
        assert_eq!(
            plain["writes"],
            json!([{"path": ["browser", "searchEngine"], "value": "kagi"}])
        );
        assert_eq!(ok("import.browser_enabled", json!({"root": {}})), json!({"enabled": true}));
        let off = ok(
            "import.browser_enabled",
            json!({"root": {"browser": {"import": {"enabled": false}}}}),
        );
        assert_eq!(off, json!({"enabled": false}));
        let bad = ok(
            "import.browser_enabled",
            json!({"root": {"browser": {"import": {"enabled": "no"}}}}),
        );
        assert_eq!(bad["enabled"], json!(true));
        assert_eq!(bad["diagnostic"]["kind"], json!("invalidValue"));
    }
}
