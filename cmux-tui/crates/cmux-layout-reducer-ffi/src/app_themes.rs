//! `cmux-app-themes` over the JSON channel (ops `app_themes_*`): the macOS
//! app's theme, theme file, app-local store and layout template rules. The
//! app reads and writes the files, stats the paths, makes the ids and dates,
//! sends the facts and acts on the answer.

use std::collections::{BTreeMap, BTreeSet};

use cmux_app_themes::catalog;
use cmux_app_themes::kv_store::{self, File};
use cmux_app_themes::layout_templates;
use cmux_app_themes::theme_files::{self, Refusal};
use cmux_app_themes::theme_spec::ThemeSpec;
use serde::Deserialize;
use serde_json::{Value, json};

use crate::ERR_INVALID;

/// Whether `operation` is one of this module's.
pub(crate) fn handles(operation: &[u8]) -> bool {
    operation.starts_with(b"app_themes_")
}

fn read<'a, T: Deserialize<'a>>(request: &'a [u8]) -> Result<T, i32> {
    serde_json::from_slice(request).map_err(|_| ERR_INVALID)
}

fn encode(value: Value) -> Result<Vec<u8>, i32> {
    serde_json::to_vec(&value).map_err(|_| ERR_INVALID)
}

#[derive(Deserialize)]
struct Text {
    text: String,
}

#[derive(Deserialize)]
struct Name {
    name: String,
}

#[derive(Deserialize)]
struct Destination {
    name: String,
    #[serde(default)]
    shipped: bool,
    #[serde(default)]
    exists: bool,
    #[serde(default)]
    replace: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Save {
    name: String,
    base: String,
    base_text: String,
    #[serde(default)]
    edits: Vec<String>,
    accent: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Import {
    file_name: String,
    /// The file as UTF-8; None when it is not.
    text: Option<String>,
    size: usize,
}

#[derive(Deserialize)]
struct Classify {
    exists: bool,
    #[serde(default = "yes")]
    readable: bool,
    text: Option<String>,
}

fn yes() -> bool {
    true
}

#[derive(Deserialize)]
struct Load {
    #[serde(default)]
    loaded: BTreeMap<String, String>,
    #[serde(default)]
    current: BTreeMap<String, String>,
    complete: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct StoreSave {
    has_file: bool,
    keeps_file: bool,
    is_loaded: bool,
    is_empty: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Migratable {
    #[serde(default)]
    entries: BTreeMap<String, String>,
    keeps_file: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Stale {
    #[serde(default)]
    keys: Vec<String>,
    machine: String,
    #[serde(default)]
    live_tabs: BTreeSet<String>,
}

#[derive(Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
enum Key {
    Terminal { machine: String, tab: String },
    Workspace { session: String, workspace: String },
}

#[derive(Deserialize)]
struct Accepts {
    text: String,
    #[serde(default)]
    known: BTreeSet<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Put {
    #[serde(default)]
    templates: Vec<Value>,
    name: String,
    blueprint: Value,
    saved_at: Value,
    new_id: String,
}

#[derive(Deserialize)]
struct Rename {
    #[serde(default)]
    templates: Vec<Value>,
    id: String,
    name: String,
}

#[derive(Deserialize)]
struct Delete {
    #[serde(default)]
    templates: Vec<Value>,
    id: String,
}

#[derive(Deserialize)]
struct Find {
    #[serde(default)]
    templates: Vec<Value>,
    name: String,
}

fn refusal(refusal: Refusal) -> Value {
    json!({ "refusal": refusal })
}

fn templates(result: Result<Vec<Value>, layout_templates::Failure>) -> Value {
    match result {
        Ok(templates) => json!({ "templates": templates }),
        Err(failure) => json!({ "failure": failure }),
    }
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let answer = match operation {
        b"app_themes_spec_parse" => {
            let Text { text } = read(request)?;
            match ThemeSpec::parse(&text) {
                Some(spec) => json!({ "light": spec.light, "dark": spec.dark }),
                None => Value::Null,
            }
        }
        b"app_themes_file_name_valid" => {
            let Name { name } = read(request)?;
            json!({ "valid": theme_files::is_valid_name(&name) })
        }
        b"app_themes_file_destination" => {
            let request: Destination = read(request)?;
            json!({ "refusal": theme_files::destination_refusal(&request.name, request.shipped, request.exists, request.replace) })
        }
        b"app_themes_file_color_lines" => {
            let Text { text } = read(request)?;
            json!({ "lines": theme_files::color_lines(&text) })
        }
        b"app_themes_file_accent" => {
            let Text { text } = read(request)?;
            let accent = theme_files::color_lines(&text)
                .iter()
                .rev()
                .find_map(|line| theme_files::accent(line));
            json!({ "accent": accent })
        }
        b"app_themes_file_save" => {
            let request: Save = read(request)?;
            if !theme_files::is_valid_name(&request.base) {
                refusal(Refusal::UnknownBase)
            } else {
                let text = theme_files::saved_theme(
                    &request.name,
                    &request.base,
                    &request.base_text,
                    &request.edits,
                    request.accent.as_deref(),
                );
                json!({ "text": text })
            }
        }
        b"app_themes_file_import" => {
            let request: Import = read(request)?;
            let Some(text) = request.text else { return encode(refusal(Refusal::NotATheme)) };
            match theme_files::imported_theme(&request.file_name, &text, request.size) {
                Ok(imported) => json!({ "name": imported.name, "text": imported.text }),
                Err(error) => refusal(error),
            }
        }
        b"app_themes_store_classify" => {
            let request: Classify = read(request)?;
            let file = if !request.exists {
                File::Missing
            } else if !request.readable {
                File::Unreadable
            } else {
                File::Read(request.text.as_deref())
            };
            serde_json::to_value(kv_store::classify(file)).map_err(|_| ERR_INVALID)?
        }
        b"app_themes_store_load" => {
            let request: Load = read(request)?;
            serde_json::to_value(kv_store::load(request.loaded, request.current, request.complete))
                .map_err(|_| ERR_INVALID)?
        }
        b"app_themes_store_save" => {
            let request: StoreSave = read(request)?;
            json!({ "action": kv_store::save(request.has_file, request.keeps_file, request.is_loaded, request.is_empty) })
        }
        b"app_themes_store_migratable" => {
            let request: Migratable = read(request)?;
            json!({ "entries": kv_store::migratable(&request.entries, request.keeps_file) })
        }
        b"app_themes_store_stale" => {
            let request: Stale = read(request)?;
            let stale = kv_store::stale_keys(
                request.keys.iter().map(String::as_str),
                &request.machine,
                &request.live_tabs,
            );
            json!({ "stale": stale })
        }
        b"app_themes_store_key" => {
            let key = match read(request)? {
                Key::Terminal { machine, tab } => kv_store::terminal_key(&machine, &tab),
                Key::Workspace { session, workspace } => {
                    kv_store::workspace_key(&session, &workspace)
                }
            };
            json!({ "key": key })
        }
        b"app_themes_catalog_accepts" => {
            let request: Accepts = read(request)?;
            serde_json::to_value(catalog::accepts(&request.text, &request.known))
                .map_err(|_| ERR_INVALID)?
        }
        b"app_themes_templates_put" => {
            let request: Put = read(request)?;
            let list = layout_templates::put(
                request.templates,
                &request.name,
                request.blueprint,
                request.saved_at,
                &request.new_id,
            );
            json!({ "templates": list })
        }
        b"app_themes_templates_rename" => {
            let request: Rename = read(request)?;
            templates(layout_templates::rename(request.templates, &request.id, &request.name))
        }
        b"app_themes_templates_delete" => {
            let request: Delete = read(request)?;
            templates(layout_templates::delete(request.templates, &request.id))
        }
        b"app_themes_templates_find" => {
            let request: Find = read(request)?;
            json!({ "index": layout_templates::named(&request.templates, &request.name) })
        }
        _ => return Err(ERR_INVALID),
    };
    encode(answer)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ask(operation: &str, request: Value) -> Value {
        let bytes = respond(operation.as_bytes(), &serde_json::to_vec(&request).unwrap()).unwrap();
        serde_json::from_slice(&bytes).unwrap()
    }

    #[test]
    fn handles_only_its_prefix() {
        assert!(handles(b"app_themes_spec_parse"));
        assert!(!handles(b"window_close"));
        assert_eq!(respond(b"app_themes_nope", b"{}"), Err(ERR_INVALID));
        assert_eq!(respond(b"app_themes_spec_parse", b"not json"), Err(ERR_INVALID));
    }

    #[test]
    fn spec_and_catalog() {
        assert_eq!(
            ask("app_themes_spec_parse", json!({"text": "light:A,dark:B"})),
            json!({"light": "A", "dark": "B"})
        );
        assert_eq!(ask("app_themes_spec_parse", json!({"text": "a=b"})), Value::Null);
        assert_eq!(
            ask("app_themes_catalog_accepts", json!({"text": "A", "known": ["A"]})),
            json!({"verdict": "accept"})
        );
        assert_eq!(
            ask("app_themes_catalog_accepts", json!({"text": "Z", "known": ["A"]})),
            json!({"verdict": "refuse"})
        );
        assert_eq!(
            ask("app_themes_catalog_accepts", json!({"text": "/t/x", "known": ["A"]})),
            json!({"verdict": "acceptIfFiles", "paths": ["/t/x"]})
        );
    }

    #[test]
    fn theme_files() {
        assert_eq!(
            ask("app_themes_file_name_valid", json!({"name": "Mine"})),
            json!({"valid": true})
        );
        assert_eq!(
            ask("app_themes_file_name_valid", json!({"name": "a/b"})),
            json!({"valid": false})
        );
        assert_eq!(
            ask("app_themes_file_destination", json!({"name": "Mine"})),
            json!({"refusal": null})
        );
        assert_eq!(
            ask("app_themes_file_destination", json!({"name": "Mine", "exists": true})),
            json!({"refusal": "exists"})
        );
        assert_eq!(
            ask(
                "app_themes_file_color_lines",
                json!({"text": "background = #000000\ncommand = rm\n"})
            ),
            json!({"lines": ["background = #000000"]})
        );
        assert_eq!(
            ask("app_themes_file_save", json!({"name": "M", "base": "a/b", "baseText": ""})),
            json!({"refusal": "unknownBase"})
        );
        let saved = ask(
            "app_themes_file_save",
            json!({"name": "M", "base": "B", "baseText": "background = #000000", "edits": ["background = #ffffff"]}),
        );
        assert_eq!(
            saved["text"],
            json!("# M: B with edits, saved by cmux\nbackground = #ffffff\n")
        );
        assert_eq!(
            ask("app_themes_file_import", json!({"fileName": "x", "size": 3})),
            json!({"refusal": "notATheme"})
        );
        let imported = ask(
            "app_themes_file_import",
            json!({"fileName": "Dusk.conf", "text": "background = #111111\n", "size": 21}),
        );
        assert_eq!(imported["name"], json!("Dusk"));
        assert_eq!(
            ask("app_themes_file_import", json!({"fileName": "x", "text": "a = b", "size": 5})),
            json!({"refusal": "notATheme"})
        );
    }

    #[test]
    fn stores() {
        assert_eq!(
            ask("app_themes_store_classify", json!({"exists": false})),
            json!({"entries": {}, "complete": true, "moveAside": false})
        );
        assert_eq!(
            ask("app_themes_store_classify", json!({"exists": true, "readable": false})),
            json!({"entries": {}, "complete": false, "moveAside": false})
        );
        assert_eq!(
            ask(
                "app_themes_store_classify",
                json!({"exists": true, "text": "{\"a\":\"x\",\"b\":1}"})
            ),
            json!({"entries": {"a": "x"}, "complete": false, "moveAside": false})
        );
        assert_eq!(
            ask("app_themes_store_classify", json!({"exists": true})),
            json!({"entries": {}, "complete": true, "moveAside": true})
        );
        assert_eq!(
            ask(
                "app_themes_store_load",
                json!({"loaded": {"a": "1", "b": "1"}, "current": {"a": "2"}, "complete": true})
            ),
            json!({"entries": {"a": "2", "b": "1"}, "keepsFile": false})
        );
        assert_eq!(
            ask(
                "app_themes_store_save",
                json!({"hasFile": true, "keepsFile": false, "isLoaded": true, "isEmpty": true})
            ),
            json!({"action": "remove"})
        );
        assert_eq!(
            ask("app_themes_store_migratable", json!({"entries": {"a": "1"}, "keepsFile": true})),
            json!({"entries": {}})
        );
        assert_eq!(
            ask("app_themes_store_key", json!({"kind": "terminal", "machine": "m", "tab": "t"})),
            json!({"key": "m:t"})
        );
        assert_eq!(
            ask(
                "app_themes_store_key",
                json!({"kind": "workspace", "session": "s", "workspace": "w"})
            ),
            json!({"key": "s/w"})
        );
        assert_eq!(
            ask(
                "app_themes_store_stale",
                json!({"keys": ["m:a", "m:b", "n:a"], "machine": "m", "liveTabs": ["a"]})
            ),
            json!({"stale": ["m:b"]})
        );
    }

    #[test]
    fn templates() {
        let put = ask(
            "app_themes_templates_put",
            json!({"name": "Two up", "blueprint": 1, "savedAt": "d", "newId": "a"}),
        );
        let list = put["templates"].clone();
        assert_eq!(list, json!([{"id": "a", "name": "Two up", "blueprint": 1, "savedAt": "d"}]));
        let list = ask("app_themes_templates_put", json!({"templates": list, "name": "Solo", "blueprint": 2, "savedAt": "d", "newId": "b"}))["templates"].clone();
        assert_eq!(
            ask(
                "app_themes_templates_rename",
                json!({"templates": list, "id": "a", "name": "solo"})
            ),
            json!({"failure": "nameTaken"})
        );
        assert_eq!(
            ask("app_themes_templates_delete", json!({"templates": list, "id": "zz"})),
            json!({"failure": "notFound"})
        );
        assert_eq!(
            ask("app_themes_templates_delete", json!({"templates": list, "id": "a"}))["templates"]
                [0]["id"],
            json!("b")
        );
        assert_eq!(
            ask("app_themes_templates_find", json!({"templates": list, "name": " SOLO "})),
            json!({"index": 1})
        );
        assert_eq!(
            ask("app_themes_templates_find", json!({"templates": list, "name": "x"})),
            json!({"index": null})
        );
    }
}
