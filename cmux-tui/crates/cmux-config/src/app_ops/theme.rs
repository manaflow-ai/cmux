//! Theme files: Swift `ThemeFileOverlay`, `ThemeFileSetting`, `ThemeFileExceptionsSetting`.
//!
//! - `theme.valid_name` `{name}` answers `{valid}`.
//! - `theme.is_look` `{key}` (dotted) answers `{look}`: a theme file may set that row.
//! - `theme.name` `{root}` answers `{name}` (absent when unset or not a valid name).
//! - `theme.exceptions` `{root}` answers `{keys}`: the sorted dotted keys of the
//!   exceptions list that name a look a theme file may set and take an exception.
//! - `theme.exception_edit` `{writes: [{key, sets}], file_keys?, root}` answers
//!   `{change: false}` or `{change: true, value}`: the new list (`value` null
//!   removes the key). `file_keys` are the dotted keys the active theme file
//!   sets; absent when no theme file is active.
//! - `theme.read` `{name, text? | error?, base?, folder?}` answers `{loaded,
//!   unparsable, values: [{path, value}], diagnostics: [{kind, path, message,
//!   file?, value?}], corrected, density?, title?, fonts?}`: the settings,
//!   colors and contrast guard. `text` is the file's text, `error` the reason it
//!   could not be read (as the person reads it), neither when there is no file.
//!   `density`, `title` (the file's `name`) and `fonts` are the file's raw
//!   members, which the app reads itself.

use std::collections::BTreeSet;
use std::path::Path;

use serde_json::{Map, Value, json};

use super::{OpError, jsonc, string};
use crate::domains::Domains;
use crate::keypath::key_path;
use crate::schema::Schema;
use crate::theme_file::{
    SETTING_KEY, ThemeDiagnostic, ThemeDiagnosticKind, ThemeFile, exceptions_in, is_look,
    is_valid_name, name_in,
};

/// Keys whose theme file entries never take part in an exception: the theme
/// file's colors become `appearance.themeEdits` entries merged with the
/// person's, so a whole-map exception would drop the file's colors.
const UNEXCEPTIONABLE: [&str; 1] = ["appearance.themeEdits"];

/// The ops this area answers; `None` for an op of another area.
pub fn call(op: &str, request: &Value) -> Option<Result<Value, OpError>> {
    Some(match op {
        "theme.valid_name" => valid_name(request),
        "theme.is_look" => look(request),
        "theme.name" => name(request),
        "theme.exceptions" => exceptions(request),
        "theme.exception_edit" => exception_edit(request),
        "theme.read" => read(request),
        _ => return None,
    })
}

fn valid_name(request: &Value) -> Result<Value, OpError> {
    Ok(json!({ "valid": is_valid_name(string(request, "name")?) }))
}

fn look(request: &Value) -> Result<Value, OpError> {
    let key = string(request, "key")?;
    Ok(json!({ "look": Schema::embedded().row(key).is_some_and(is_look) }))
}

fn name(request: &Value) -> Result<Value, OpError> {
    Ok(match request.get("root").and_then(name_in) {
        Some(name) => json!({ "name": name }),
        None => json!({}),
    })
}

fn exception_keys(root: &Value) -> BTreeSet<String> {
    let schema = Schema::embedded();
    exceptions_in(root)
        .into_iter()
        .filter(|key| {
            !UNEXCEPTIONABLE.contains(&key.as_str())
                && schema.row_at(&key_path(key)).is_some_and(is_look)
        })
        .collect()
}

fn root_of(request: &Value) -> Result<&Value, OpError> {
    request.get("root").ok_or_else(|| OpError::Invalid("expected `root`".to_owned()))
}

fn exceptions(request: &Value) -> Result<Value, OpError> {
    Ok(json!({ "keys": exception_keys(root_of(request)?) }))
}

fn exception_edit(request: &Value) -> Result<Value, OpError> {
    let root = root_of(request)?;
    let writes: Vec<(&str, bool)> = request
        .get("writes")
        .and_then(Value::as_array)
        .and_then(|writes| {
            writes
                .iter()
                .map(|write| Some((write.get("key")?.as_str()?, write.get("sets")?.as_bool()?)))
                .collect()
        })
        .ok_or_else(|| OpError::Invalid("expected `writes` of {key, sets}".to_owned()))?;
    let file_keys: Option<BTreeSet<&str>> = match request.get("file_keys") {
        None | Some(Value::Null) => None,
        Some(keys) => Some(
            keys.as_array()
                .ok_or_else(|| OpError::Invalid("expected a list `file_keys`".to_owned()))?
                .iter()
                .filter_map(Value::as_str)
                .collect(),
        ),
    };
    let current = exception_keys(root);
    let mut next = current.clone();
    if writes.iter().any(|(key, _)| *key == SETTING_KEY) {
        next.clear();
    } else if let Some(file_keys) = &file_keys {
        for (key, sets) in writes.iter().filter(|(key, _)| !UNEXCEPTIONABLE.contains(key)) {
            if *sets {
                if file_keys.contains(key) {
                    next.insert((*key).to_owned());
                }
            } else {
                next.remove(*key);
            }
        }
    } else {
        for (key, _) in writes.iter().filter(|(_, sets)| !*sets) {
            next.remove(*key);
        }
    }
    if next == current {
        return Ok(json!({ "change": false }));
    }
    let value = if next.is_empty() { Value::Null } else { json!(next) };
    Ok(json!({ "change": true, "value": value }))
}

fn diagnostic(diagnostic: &ThemeDiagnostic, problem: Option<&str>) -> Value {
    let kind = match diagnostic.kind {
        ThemeDiagnosticKind::UnreadableFile => "unreadableFile",
        ThemeDiagnosticKind::InvalidValue => "invalidValue",
        ThemeDiagnosticKind::CorrectedValue => "correctedValue",
    };
    // The app words an unreadable file as cmux-next.json's problem, with no wrapper.
    let message = match (diagnostic.kind, problem) {
        (ThemeDiagnosticKind::UnreadableFile, Some(problem)) => problem,
        _ => &diagnostic.message,
    };
    let mut out = Map::new();
    out.insert("kind".to_owned(), json!(kind));
    out.insert("path".to_owned(), json!(diagnostic.path));
    out.insert("message".to_owned(), json!(message));
    if let Some(file) = &diagnostic.file {
        out.insert("file".to_owned(), json!(file));
    }
    if let Some(value) = &diagnostic.value {
        out.insert("value".to_owned(), json!(value));
    }
    Value::Object(out)
}

fn read(request: &Value) -> Result<Value, OpError> {
    let name = string(request, "name")?;
    let text = request.get("text").and_then(Value::as_str);
    let error = request.get("error").and_then(Value::as_str);
    let base = request.get("base").cloned().unwrap_or_else(|| json!({}));
    let folder = request.get("folder").and_then(Value::as_str).map(Path::new);
    let source = match (text, error) {
        (Some(text), _) => Some(Ok(text)),
        (None, Some(error)) => Some(Err(error.to_owned())),
        (None, None) => None,
    };
    let file =
        ThemeFile::read(name, source, &base, folder, Schema::embedded(), &Domains::default());
    let parsed = text.map(|text| (text, crate::jsonc::parse(text)));
    let problem = match (&parsed, error) {
        (Some((text, Err(failure))), _) => Some(jsonc::problem(failure, text)),
        (None, Some(error)) => Some(error.to_owned()),
        _ => None,
    };
    let members = match &parsed {
        Some((_, Ok(Value::Object(members)))) => Some(members),
        _ => None,
    };
    let member = |key: &str| members.and_then(|members| members.get(key));
    let mut reply = Map::new();
    reply.insert("loaded".to_owned(), json!(file.is_loaded));
    reply.insert("unparsable".to_owned(), json!(file.is_unparsable));
    reply.insert(
        "values".to_owned(),
        Value::Array(
            file.values
                .iter()
                .map(|(path, value)| json!({ "path": path, "value": value }))
                .collect(),
        ),
    );
    reply.insert(
        "diagnostics".to_owned(),
        Value::Array(file.diagnostics.iter().map(|d| diagnostic(d, problem.as_deref())).collect()),
    );
    reply.insert("corrected".to_owned(), json!(file.corrected));
    if file.is_loaded {
        for (key, member) in
            [("density", member("density")), ("title", member("name")), ("fonts", member("fonts"))]
        {
            if let Some(member) = member {
                reply.insert(key.to_owned(), member.clone());
            }
        }
    }
    Ok(Value::Object(reply))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ask(op: &str, request: Value) -> Value {
        call(op, &request).expect("a theme op").expect("answers")
    }

    #[test]
    fn other_areas_ops_are_not_ours() {
        assert!(call("jsonc.parse", &json!({})).is_none());
    }

    #[test]
    fn names_are_plain_file_names() {
        assert_eq!(ask("theme.valid_name", json!({"name": "tokyo night"})), json!({"valid": true}));
        for bad in ["", ".hidden", "a/b", "a:b", "tokyo.json", " padded", "tab\tname"] {
            assert_eq!(
                ask("theme.valid_name", json!({"name": bad})),
                json!({"valid": false}),
                "{bad:?}"
            );
        }
        let root = json!({"appearance": {"themeFile": "tokyo"}});
        assert_eq!(ask("theme.name", json!({"root": root})), json!({"name": "tokyo"}));
        assert_eq!(
            ask("theme.name", json!({"root": {"appearance": {"themeFile": "../x"}}})),
            json!({})
        );
    }

    #[test]
    fn only_look_settings_are_looks() {
        assert_eq!(
            ask("theme.is_look", json!({"key": "appearance.accent"})),
            json!({"look": true})
        );
        assert_eq!(ask("theme.is_look", json!({"key": SETTING_KEY})), json!({"look": false}));
        assert_eq!(ask("theme.is_look", json!({"key": "terminal.term"})), json!({"look": false}));
        assert_eq!(ask("theme.is_look", json!({"key": "nope"})), json!({"look": false}));
    }

    #[test]
    fn exceptions_keep_only_looks_that_take_one() {
        let root = json!({"appearance": {"themeFileExceptions": [
            "appearance.accent", "appearance", "appearance.themeEdits", "terminal.term", "appearance.accent", 3
        ]}});
        assert_eq!(
            ask("theme.exceptions", json!({"root": root})),
            json!({"keys": ["appearance.accent"]})
        );
        assert_eq!(ask("theme.exceptions", json!({"root": {}})), json!({"keys": []}));
    }

    #[test]
    fn a_write_edits_the_exceptions_list() {
        let root = json!({"appearance": {"themeFileExceptions": ["appearance.borders"]}});
        let edit = |writes: Value, file_keys: Value| {
            ask(
                "theme.exception_edit",
                json!({"writes": writes, "file_keys": file_keys, "root": root}),
            )
        };
        // A set the file also sets adds its key; one it does not set adds none.
        assert_eq!(
            edit(json!([{"key": "appearance.accent", "sets": true}]), json!(["appearance.accent"])),
            json!({"change": true, "value": ["appearance.accent", "appearance.borders"]})
        );
        assert_eq!(
            edit(json!([{"key": "appearance.accent", "sets": true}]), json!([])),
            json!({"change": false})
        );
        // A reset removes it; the last one removes the list.
        assert_eq!(
            edit(
                json!([{"key": "appearance.borders", "sets": false}]),
                json!(["appearance.borders"])
            ),
            json!({"change": true, "value": null})
        );
        // Choosing a theme file clears the list.
        assert_eq!(
            edit(json!([{"key": "appearance.themeFile", "sets": true}]), json!([])),
            json!({"change": true, "value": null})
        );
        // No active theme file: only resets count.
        let no_file = ask(
            "theme.exception_edit",
            json!({
                "writes": [{"key": "appearance.borders", "sets": false}, {"key": "appearance.accent", "sets": true}],
                "root": root,
            }),
        );
        assert_eq!(no_file, json!({"change": true, "value": null}));
        // The theme edits never take an exception.
        assert_eq!(
            edit(
                json!([{"key": "appearance.themeEdits", "sets": true}]),
                json!(["appearance.themeEdits"])
            ),
            json!({"change": false})
        );
    }

    #[test]
    fn a_theme_file_is_read_as_a_look() {
        let reply = ask(
            "theme.read",
            json!({
                "name": "tokyo",
                "text": r#"{ "name": "Tokyo", "appearance": { "accent": "blue", "x": 1 }, "density": {"basedOn": "compact"}, "fonts": [] }"#,
            }),
        );
        assert_eq!(reply["loaded"], json!(true));
        assert_eq!(reply["values"], json!([{"path": ["appearance", "accent"], "value": "blue"}]));
        assert_eq!(reply["diagnostics"][0]["path"], json!("appearance.x"));
        assert_eq!(reply["diagnostics"][0]["kind"], json!("invalidValue"));
        assert_eq!(reply["diagnostics"][0]["file"], json!("themes/tokyo.json"));
        assert_eq!(reply["title"], json!("Tokyo"));
        assert_eq!(reply["density"], json!({"basedOn": "compact"}));
        assert_eq!(reply["fonts"], json!([]));
    }

    #[test]
    fn a_missing_file_is_reported_at_the_setting() {
        let reply = ask("theme.read", json!({"name": "gone"}));
        assert_eq!(reply["loaded"], json!(false));
        assert_eq!(reply["unparsable"], json!(false));
        let first = &reply["diagnostics"][0];
        assert_eq!(first["path"], json!("appearance.themeFile"));
        assert_eq!(first["message"], json!("there is no file themes/gone.json"));
        assert!(first.get("file").is_none());
    }

    #[test]
    fn an_unreadable_file_says_why_as_the_app_words_it() {
        let broken = ask("theme.read", json!({"name": "t", "text": "{\n  \"a\": 1,\n  x\n}"}));
        assert_eq!(broken["unparsable"], json!(true));
        assert_eq!(broken["diagnostics"][0]["kind"], json!("unreadableFile"));
        assert_eq!(
            broken["diagnostics"][0]["message"],
            json!("the text is not valid JSON at line 3, column 3")
        );
        let list = ask("theme.read", json!({"name": "t", "text": "[1]"}));
        assert_eq!(list["diagnostics"][0]["message"], json!("root is not an object"));
        let denied = ask("theme.read", json!({"name": "t", "error": "permission denied"}));
        assert_eq!(denied["diagnostics"][0]["message"], json!("permission denied"));
        assert_eq!(denied["unparsable"], json!(true));
    }

    #[test]
    fn low_contrast_text_is_corrected() {
        let reply = ask(
            "theme.read",
            json!({
                "name": "t",
                "text": r##"{ "appearance.theme": "Nord", "colors": { "background": "#222222", "foreground": "#333333" } }"##,
            }),
        );
        assert_eq!(reply["corrected"], json!(["foreground"]));
        assert_eq!(reply["diagnostics"][0]["kind"], json!("correctedValue"));
    }
}
