//! `stored_defaults.*`: the rules of the launch pass that drops stored
//! copies of defaults (Swift `SettingsController+StoredDefaults`). The app
//! keeps the file reads and writes, the UserDefaults marks and the schema
//! walk; which keys a reader fills itself, what the record says and how a
//! write that removed fewer keys settles the report are decided here.
//! - `stored_defaults.unset_is_not_default` `{key}` answers `{is}`: whether a
//!   reader fills `key` with something other than the row's default when the
//!   file leaves it unset, so a written default stays stored.
//! - `stored_defaults.unset_is_not_default_keys` `{}` answers `{keys}`: each
//!   such key (or, ending in ".", key prefix) with that reader.
//! - `stored_defaults.record` `{dropped, kept, before}` answers `{text}`: the
//!   record kept beside the file (`cmux-next.json.defaults-forgotten.json`).
//! - `stored_defaults.settled` `{dropped, kept, candidates: [{id, path,
//!   value}], removed: [[key]], before}` answers `{dropped, kept}`: the report
//!   once the write removed only `removed`; each other candidate is kept, with
//!   its value in `before` (the file at the write), else the value read.

use serde_json::{Map, Value, json};

use super::{OpError, string};
use crate::jsonc as parser;
use crate::render::pretty;
use crate::value::value_at;

/// Keys (or, ending in ".", key prefixes) whose readers fill an unset key
/// with something other than the row's default, with that reader.
pub const UNSET_IS_NOT_DEFAULT_KEYS: &[(&str, &str)] = &[
    // `editor.importFrom` (FilePageLook), `LANGUAGE_DEFAULTS` in webviews'
    // `settingsForLanguage` (Markdown and commit messages wrap, Go and
    // Makefiles indent with tabs), and keys that follow another
    // (`autoClosingQuotes` follows `autoClosingBrackets`).
    ("editor.", "another editor's settings, the built-in per-language values, a key it follows"),
    // webviews' `resolveHarnessPlacement`: the Debug tunable
    // `agent.harnessPlacement` fills it.
    ("agentPane.display.harnessPlacement", "the Debug tunable agent.harnessPlacement"),
];

/// `editor.importFrom`, which is none of these although `editor.` names it.
const EDITOR_IMPORT_FROM: &str = "editor.importFrom";

const RECORD_NOTE: &str = "cmux dropped these stored copies of defaults once, so each key follows \
its default again. To keep one, set it again in Settings or copy it back from `before`.";

/// Runs a `stored_defaults.*` op; `None` when `op` is not one.
pub fn call(op: &str, request: &Value) -> Option<Result<Value, OpError>> {
    Some(match op {
        "stored_defaults.unset_is_not_default" => {
            string(request, "key").map(|key| json!({ "is": unset_is_not_default(key) }))
        }
        "stored_defaults.unset_is_not_default_keys" => {
            let keys: Map<String, Value> = UNSET_IS_NOT_DEFAULT_KEYS
                .iter()
                .map(|(key, reader)| ((*key).to_owned(), json!(reader)))
                .collect();
            Ok(json!({ "keys": keys }))
        }
        "stored_defaults.record" => string(request, "before").map(|before| {
            json!({ "text": record(&object(request, "dropped"), &object(request, "kept"), before) })
        }),
        "stored_defaults.settled" => string(request, "before").map(|before| settled(request, before)),
        _ => return None,
    })
}

/// Whether `UNSET_IS_NOT_DEFAULT_KEYS` names `key`.
pub fn unset_is_not_default(key: &str) -> bool {
    key != EDITOR_IMPORT_FROM
        && UNSET_IS_NOT_DEFAULT_KEYS
            .iter()
            .any(|(name, _)| if name.ends_with('.') { key.starts_with(name) } else { key == *name })
}

/// The record's text: what went, what stayed and the file's text before.
pub fn record(dropped: &Map<String, Value>, kept: &Map<String, Value>, before: &str) -> String {
    let record = json!({
        "note": RECORD_NOTE,
        "dropped": dropped,
        "kept": kept,
        "before": before,
    });
    pretty(&record, "") + "\n"
}

fn settled(request: &Value, before: &str) -> Value {
    let mut dropped = object(request, "dropped");
    let mut kept = object(request, "kept");
    let removed: Vec<&Value> =
        request.get("removed").and_then(Value::as_array).into_iter().flatten().collect();
    let root = parser::parse(before).ok();
    let candidates = request.get("candidates").and_then(Value::as_array).into_iter().flatten();
    for candidate in candidates {
        let (Some(id), Some(path)) = (
            candidate.get("id").and_then(Value::as_str),
            candidate.get("path").filter(|path| path.is_array()),
        ) else {
            continue;
        };
        if removed.contains(&path) {
            continue;
        }
        let keys: Vec<&str> =
            path.as_array().into_iter().flatten().filter_map(Value::as_str).collect();
        let now = root.as_ref().and_then(|root| value_at(root, &keys)).cloned();
        let read = candidate.get("value").cloned().unwrap_or(Value::Null);
        dropped.remove(id);
        kept.insert(id.to_owned(), now.unwrap_or(read));
    }
    json!({ "dropped": dropped, "kept": kept })
}

fn object(request: &Value, key: &str) -> Map<String, Value> {
    request.get(key).and_then(Value::as_object).cloned().unwrap_or_default()
}

#[cfg(test)]
#[path = "stored_defaults_tests.rs"]
mod tests;
