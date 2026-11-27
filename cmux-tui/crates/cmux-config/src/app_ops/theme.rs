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
        (Some((_, Ok(value))), _) if !value.is_object() => Some("root is not an object".to_owned()),
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
#[path = "theme_tests.rs"]
mod tests;
