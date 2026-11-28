//! The settings controller's load and write decisions (Swift
//! `SettingsController`, `SettingsDiagnosticNotices`), as ops. The app keeps
//! the observable state and the file watch; what a load keeps, what an edit
//! does to the document and which refusals are announced are decided here.
//!
//! - `notices.update` `{diagnostics: [{kind, path, message, file?, value?}],
//!   file, managed?: [dotted], remembered?: [fingerprint], shown?}` answers
//!   `{announce: [{path, value?, message, file?, fingerprint}], cleared,
//!   remembered, shown?}`: the refusals not announced yet, in the load's
//!   order, whether the shown toast's refusal is gone, and the state after.
//! - `notices.announced` `{notices: [{fingerprint}], remembered?, shown?}`
//!   answers `{remembered, shown?}`: a toast showed `notices` (it names the
//!   first).
//! - `notices.fingerprint` `{kind?, path, value?, message, file?}` answers
//!   `{fingerprint}`.
//! - `notices.announces` `{kind}` answers `{announces}`.
//! - `controller.load_root` `{source? | error?, last_good}` answers `{root,
//!   problem?}`: the document a load reads. A text that does not parse or is
//!   not an object keeps `last_good`, with the problem; `error` is why the
//!   file could not be read, and neither means there is no file (`{}`).
//! - `controller.apply_edits` `{root, edits: [{op, path, value?}]}` answers
//!   `{root}`: the document after the edits, as the writer applies them.
//! - `controller.remove_pruned` `{path}` answers `{edits}`: the edits that
//!   remove `path` and the objects it empties.
//! - `controller.replace` `{root, path, value?}` answers `{root}`.
//! - `controller.theme_file_notes` `{root, file_keys: [dotted], density?,
//!   managed?: [dotted]}` answers `{diagnostics}`: the note at each key the
//!   active theme file sets (or the refusal of a name that is no theme file
//!   name). `file_keys` are the overlay's keys in its order; `density` says
//!   the file's own density applies.
//! - `controller.see_through` `{path, value}` answers `{see_through}`: the
//!   write asks for a see-through window.

use std::collections::BTreeSet;

use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};

use super::{OpError, jsonc, string};
use crate::jsonc as parser;
use crate::keypath::{dotted, key_path};
use crate::render::compact;
use crate::theme_file::{SETTING_KEY, name_in};
use crate::value::value_at;

/// The ops this area answers; `None` for an op of another area.
pub fn call(op: &str, request: &Value) -> Option<Result<Value, OpError>> {
    Some(match op {
        "notices.update" => update(request),
        "notices.announced" => announced(request),
        "notices.fingerprint" => fingerprint_op(request),
        "notices.announces" => {
            string(request, "kind").map(|kind| json!({ "announces": announces(kind) }))
        }
        "controller.load_root" => load_root(request),
        "controller.apply_edits" => apply_edits(request),
        "controller.remove_pruned" => {
            path_of(request).map(|path| json!({ "edits": removing_pruned(&path) }))
        }
        "controller.replace" => replace_op(request),
        "controller.theme_file_notes" => theme_file_notes(request),
        "controller.see_through" => see_through(request),
        _ => return None,
    })
}

// MARK: Notices

/// The kinds that mean the file's own value was dropped.
pub fn announces(kind: &str) -> bool {
    matches!(
        kind,
        "unreadableFile"
            | "invalidValue"
            | "unknownAction"
            | "unknownMetric"
            | "unsupportedChord"
            | "removedSetting"
    )
}

/// What the app remembers of a notice: the key, a digest of the value (never
/// the value itself) and the reason. A file that does not parse is one notice
/// whatever the parse error says.
#[allow(
    clippy::indexing_slicing,
    reason = "positions come from the value's own length or search, so they are in range"
)]
pub fn fingerprint(
    kind: &str,
    path: &str,
    value: Option<&str>,
    message: &str,
    file: Option<&str>,
) -> String {
    let mut parts: Vec<String> = file.map(str::to_owned).into_iter().collect();
    if kind == "unreadableFile" {
        parts.push(kind.to_owned());
    } else {
        let digest = value
            .map(|text| {
                Sha256::digest(text.as_bytes())[..12]
                    .iter()
                    .map(|byte| format!("{byte:02x}"))
                    .collect()
            })
            .unwrap_or_default();
        parts.extend([path.to_owned(), digest, message.to_owned()]);
    }
    parts.join("\0")
}

/// A key a managed layer sets, inside one, or holding one.
fn is_managed(path: &str, managed: &BTreeSet<String>) -> bool {
    !path.is_empty() && managed.iter().any(|key| overlaps(key, path))
}

fn overlaps(key: &str, path: &str) -> bool {
    key == path
        || path.strip_prefix(key).is_some_and(|rest| rest.starts_with('.'))
        || key.strip_prefix(path).is_some_and(|rest| rest.starts_with('.'))
}

#[allow(
    clippy::indexing_slicing,
    reason = "positions come from the value's own length or search, so they are in range"
)]
fn update(request: &Value) -> Result<Value, OpError> {
    let diagnostics = array(request, "diagnostics")?;
    let file = request.get("file").unwrap_or(&Value::Null);
    let managed = strings(request, "managed")?;
    let remembered = strings(request, "remembered")?;
    let shown = request.get("shown").and_then(Value::as_str);
    let mut seen = BTreeSet::new();
    let mut pending = Vec::new();
    for diagnostic in diagnostics {
        let kind = string(diagnostic, "kind")?;
        let path = string(diagnostic, "path")?;
        if !announces(kind) || is_managed(path, &managed) {
            continue;
        }
        let message = string(diagnostic, "message")?;
        let source = diagnostic.get("file").and_then(Value::as_str);
        // A theme file's refusal carries its own value; cmux-next.json's is read from the file.
        let value = if source.is_some() {
            diagnostic.get("value").and_then(Value::as_str).map(str::to_owned)
        } else if path.is_empty() {
            None
        } else {
            value_at(file, &key_path(path)).map(compact)
        };
        let print = fingerprint(kind, path, value.as_deref(), message, source);
        if !seen.insert(print.clone()) {
            continue;
        }
        if !remembered.contains(&print) {
            let mut notice = Map::new();
            notice.insert("path".into(), json!(path));
            if let Some(value) = value {
                notice.insert("value".into(), json!(value));
            }
            notice.insert("message".into(), json!(message));
            if let Some(source) = source {
                notice.insert("file".into(), json!(source));
            }
            notice.insert("fingerprint".into(), json!(print));
            pending.push(Value::Object(notice));
        }
    }
    let remembered: BTreeSet<&String> = remembered.intersection(&seen).collect();
    let cleared = shown.is_some_and(|shown| !seen.contains(shown));
    let mut answer = json!({ "announce": pending, "cleared": cleared, "remembered": remembered });
    if let Some(shown) = shown.filter(|_| !cleared) {
        answer["shown"] = json!(shown);
    }
    Ok(answer)
}

#[allow(
    clippy::indexing_slicing,
    reason = "positions come from the value's own length or search, so they are in range"
)]
fn announced(request: &Value) -> Result<Value, OpError> {
    let notices = array(request, "notices")?;
    let mut remembered = strings(request, "remembered")?;
    let mut shown = request.get("shown").and_then(Value::as_str).map(str::to_owned);
    let prints: Vec<String> = notices
        .iter()
        .map(|notice| string(notice, "fingerprint").map(str::to_owned))
        .collect::<Result<_, _>>()?;
    if let Some(first) = prints.first() {
        shown = Some(first.clone());
        remembered.extend(prints.iter().cloned());
    }
    let mut answer = json!({ "remembered": remembered });
    if let Some(shown) = shown {
        answer["shown"] = json!(shown);
    }
    Ok(answer)
}

fn fingerprint_op(request: &Value) -> Result<Value, OpError> {
    let kind = request.get("kind").and_then(Value::as_str).unwrap_or("invalidValue");
    let print = fingerprint(
        kind,
        string(request, "path")?,
        request.get("value").and_then(Value::as_str),
        string(request, "message")?,
        request.get("file").and_then(Value::as_str),
    );
    Ok(json!({ "fingerprint": print }))
}

// MARK: Load

const NOT_AN_OBJECT: &str = "root is not an object";

fn load_root(request: &Value) -> Result<Value, OpError> {
    let last_good = request.get("last_good").cloned().unwrap_or_else(|| json!({}));
    if let Some(error) = request.get("error").and_then(Value::as_str) {
        return Ok(json!({ "root": last_good, "problem": error }));
    }
    let Some(source) = request.get("source").and_then(Value::as_str) else {
        return Ok(json!({ "root": {} }));
    };
    Ok(match parser::parse(source) {
        Ok(root @ Value::Object(_)) => json!({ "root": root }),
        Ok(_) => json!({ "root": last_good, "problem": NOT_AN_OBJECT }),
        Err(error) => json!({ "root": last_good, "problem": jsonc::problem(&error, source) }),
    })
}

// MARK: Edits

/// `root` with `value` at `path`, or without the key when `value` is `None`;
/// the objects along the way are made either way (Swift
/// `SettingsController.replacing`).
pub fn replacing(path: &[String], value: Option<Value>, root: &Value) -> Value {
    let Some((key, rest)) = path.split_first() else { return value.unwrap_or(Value::Null) };
    let mut members = root.as_object().cloned().unwrap_or_default();
    if rest.is_empty() {
        match value {
            Some(value) => members.insert(key.clone(), value),
            None => members.remove(key),
        };
    } else {
        let child = members.get(key).cloned().unwrap_or_else(|| json!({}));
        members.insert(key.clone(), replacing(rest, value, &child));
    }
    Value::Object(members)
}

/// The edits that remove `path` and then each parent it leaves empty.
#[allow(
    clippy::indexing_slicing,
    reason = "positions come from the value's own length or search, so they are in range"
)]
pub fn removing_pruned(path: &[String]) -> Vec<Value> {
    let mut edits = vec![json!({ "op": "reset", "path": path })];
    for count in (1..path.len().max(1)).rev() {
        edits.push(json!({ "op": "reset_unchanged", "path": &path[..count], "value": {} }));
    }
    edits
}

/// Swift `JSONValue ==`: numbers compare as doubles, keys unordered.
fn same(a: Option<&Value>, b: Option<&Value>) -> bool {
    a.map(compact) == b.map(compact)
}

/// `root` after `edits`, as the writer applies them (an emptied parent is
/// left in place).
pub fn applying(edits: &[Value], root: &Value) -> Result<Value, OpError> {
    edits.iter().try_fold(root.clone(), |root, edit| {
        let op = string(edit, "op")?;
        let path = path_of(edit)?;
        let value = edit.get("value").cloned();
        let present = value_at(&root, &path);
        Ok(match op {
            "set" | "set_exact" => replacing(&path, value, &root),
            "set_unset" if present.is_none() => replacing(&path, value, &root),
            "reset" if present.is_some() => replacing(&path, None, &root),
            "reset_unchanged" if same(present, value.as_ref()) => replacing(&path, None, &root),
            "set_unset" | "reset" | "reset_unchanged" => root,
            other => return Err(OpError::Invalid(format!("unknown edit `{other}`"))),
        })
    })
}

fn apply_edits(request: &Value) -> Result<Value, OpError> {
    let root = request.get("root").unwrap_or(&Value::Null);
    Ok(json!({ "root": applying(array(request, "edits")?, root)? }))
}

fn replace_op(request: &Value) -> Result<Value, OpError> {
    let root = request.get("root").unwrap_or(&Value::Null);
    Ok(json!({ "root": replacing(&path_of(request)?, request.get("value").cloned(), root) }))
}

// MARK: Theme file notes

const DENSITY_ROWS: [&str; 2] = ["appearance.density", "appearance.customDensity"];

fn theme_file_notes(request: &Value) -> Result<Value, OpError> {
    let root = request.get("root").unwrap_or(&Value::Null);
    let Some(name) = name_in(root) else {
        let notes = if value_at(root, &key_path(SETTING_KEY)).is_some() {
            vec![json!({
                "kind": "invalidValue",
                "path": SETTING_KEY,
                "message": "expected a theme file name, such as \"tokyo\" for themes/tokyo.json",
            })]
        } else {
            Vec::new()
        };
        return Ok(json!({ "diagnostics": notes }));
    };
    let file_keys: Vec<String> = array(request, "file_keys")?
        .iter()
        .map(|key| key.as_str().map(str::to_owned))
        .collect::<Option<_>>()
        .ok_or_else(|| OpError::Invalid("expected a string array `file_keys`".to_owned()))?;
    let managed = strings(request, "managed")?;
    let density = request.get("density").and_then(Value::as_bool).unwrap_or(false);
    let exceptions = super::theme::exception_keys(root);
    let file = format!("themes/{name}.json");
    let density_rows = DENSITY_ROWS
        .into_iter()
        .filter(|row| density && !file_keys.iter().any(|key| key == row))
        .map(str::to_owned);
    let notes: Vec<Value> = file_keys
        .iter()
        .cloned()
        .chain(density_rows)
        .filter(|id| !managed.iter().any(|key| overlaps(key, id)))
        .map(|id| {
            let (kind, message) = if exceptions.contains(&id) {
                (
                    "overThemeFile",
                    "your value applies over the theme file's; Reset returns to the file's",
                )
            } else {
                ("setByThemeFile", "set by the theme file; a change here applies over it")
            };
            json!({ "kind": kind, "path": id, "message": message, "file": file })
        })
        .collect();
    Ok(json!({ "diagnostics": notes }))
}

// MARK: Window background

const OPACITY_KEY: &str = "appearance.backgroundOpacity";
const MATERIAL_KEY: &str = "appearance.backgroundBlur";

/// Whether writing `value` at `path` asks for a see-through window.
pub fn asks_for_see_through(path: &[String], value: &Value) -> bool {
    match dotted(path).as_str() {
        OPACITY_KEY => value.as_f64().unwrap_or(1.0) < 1.0,
        MATERIAL_KEY => value.as_str().is_some_and(|material| material != "none"),
        _ => false,
    }
}

fn see_through(request: &Value) -> Result<Value, OpError> {
    let value = request.get("value").unwrap_or(&Value::Null);
    Ok(json!({ "see_through": asks_for_see_through(&path_of(request)?, value) }))
}

// MARK: Request members

fn array<'a>(request: &'a Value, key: &str) -> Result<&'a [Value], OpError> {
    request
        .get(key)
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .ok_or_else(|| OpError::Invalid(format!("expected an array `{key}`")))
}

/// The string array `key` of `request`; absent is empty.
fn strings(request: &Value, key: &str) -> Result<BTreeSet<String>, OpError> {
    let Some(items) = request.get(key) else { return Ok(BTreeSet::new()) };
    items
        .as_array()
        .and_then(|items| items.iter().map(|item| item.as_str().map(str::to_owned)).collect())
        .ok_or_else(|| OpError::Invalid(format!("expected a string array `{key}`")))
}

fn path_of(request: &Value) -> Result<Vec<String>, OpError> {
    request
        .get("path")
        .and_then(Value::as_array)
        .and_then(|keys| keys.iter().map(|key| key.as_str().map(str::to_owned)).collect())
        .ok_or_else(|| OpError::Invalid("expected a string array `path`".to_owned()))
}

#[cfg(test)]
mod tests;
