//! keybindings.json, the user's key bindings next to cmux.json (R59, K3,
//! K-T6): a JSONC array of `{ "key", "command", "when"?, "args"? }` in the
//! common editor format. A `command` that starts with `-` removes a default
//! binding. This module reads the file into entries with per-entry
//! diagnostics (a bad entry is left out, the others load, the file never
//! fails as a whole unless it is not JSONC) and edits it in place
//! ([`edit`]). The app validates commands, `when` and `args` against its
//! action catalog.

pub mod edit;
pub mod stroke;

use serde::Serialize;
use serde_json::Value;

use crate::jsonc;

/// At most this many strokes per binding.
pub const MAX_STROKES: usize = 4;

/// One valid entry.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Entry {
    /// Position in the file's array (diagnostics and edits name it).
    pub index: usize,
    /// Normalized strokes, `["ctrl+k", "s"]`; empty for a removal of every
    /// key of the command.
    pub keys: Vec<String>,
    /// The action id, without a removal's `-`.
    pub command: String,
    /// The `when` text as written (the app parses it).
    pub when: Option<String>,
    pub args: Option<Value>,
    pub removal: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Problem {
    /// The file is not JSONC or its root is not an array; nothing loads.
    UnreadableFile,
    NotAnObject,
    MissingCommand,
    MissingKey,
    InvalidKey,
    TooManyKeys,
    /// The first stroke has neither cmd nor ctrl.
    FirstKeyNeedsCommandOrControl,
    InvalidWhen,
    InvalidArgs,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct EntryDiagnostic {
    /// The entry's position, or `None` for the whole file.
    pub index: Option<usize>,
    pub problem: Problem,
    pub message: String,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct Parsed {
    pub entries: Vec<Entry>,
    pub diagnostics: Vec<EntryDiagnostic>,
}

/// Reads keybindings.json text. An empty or comment-only file has no entries.
pub fn parse(source: &str) -> Parsed {
    let value = match jsonc::strip(source) {
        Ok(strict) if strict.trim().is_empty() => return Parsed::default(),
        Ok(strict) => serde_json::from_str::<Value>(&strict).map_err(|error| error.to_string()),
        Err(error) => Err(error.to_string()),
    };
    let items = match value {
        Ok(Value::Array(items)) => items,
        Ok(_) => return unreadable("the file must be a JSON array of bindings".into()),
        Err(message) => return unreadable(message),
    };
    let mut parsed = Parsed::default();
    for (index, item) in items.iter().enumerate() {
        match entry(index, item) {
            Ok(entry) => parsed.entries.push(entry),
            Err((problem, message)) => {
                parsed.diagnostics.push(EntryDiagnostic { index: Some(index), problem, message });
            }
        }
    }
    parsed
}

fn unreadable(message: String) -> Parsed {
    Parsed {
        entries: vec![],
        diagnostics: vec![EntryDiagnostic {
            index: None,
            problem: Problem::UnreadableFile,
            message,
        }],
    }
}

fn entry(index: usize, item: &Value) -> Result<Entry, (Problem, String)> {
    let object =
        item.as_object().ok_or((Problem::NotAnObject, "an entry must be an object".to_string()))?;
    let raw = object.get("command").and_then(Value::as_str).filter(|text| !text.trim().is_empty());
    let raw = raw.ok_or((Problem::MissingCommand, "\"command\" is required".to_string()))?;
    let (removal, command) = match raw.strip_prefix('-') {
        Some(rest) => (true, rest.to_string()),
        None => (false, raw.to_string()),
    };
    let keys = match object.get("key") {
        None | Some(Value::Null) if removal => vec![],
        Some(Value::String(text)) => keys(text)?,
        _ => {
            return Err((
                Problem::MissingKey,
                "\"key\" must be a string such as \"ctrl+k s\"".into(),
            ));
        }
    };
    if !removal && keys.is_empty() {
        return Err((Problem::MissingKey, "\"key\" must name at least one stroke".into()));
    }
    let when = match object.get("when") {
        None | Some(Value::Null) => None,
        Some(Value::String(text)) => Some(text.clone()),
        Some(_) => return Err((Problem::InvalidWhen, "\"when\" must be a string".into())),
    };
    let args = match object.get("args") {
        None | Some(Value::Null) => None,
        Some(value @ Value::Object(_)) => Some(value.clone()),
        Some(_) => return Err((Problem::InvalidArgs, "\"args\" must be an object".into())),
    };
    Ok(Entry { index, keys, command, when, args, removal })
}

/// `"ctrl+k s"` -> normalized strokes, checked.
fn keys(text: &str) -> Result<Vec<String>, (Problem, String)> {
    let strokes = text
        .split_whitespace()
        .map(|part| {
            stroke::normalize(part)
                .ok_or((Problem::InvalidKey, format!("\"{part}\" is not a key stroke")))
        })
        .collect::<Result<Vec<_>, _>>()?;
    if strokes.len() > MAX_STROKES {
        return Err((Problem::TooManyKeys, format!("at most {MAX_STROKES} strokes")));
    }
    if let Some(first) = strokes.first()
        && !stroke::has_command_or_control(first)
    {
        return Err((
            Problem::FirstKeyNeedsCommandOrControl,
            "the first stroke needs cmd or ctrl".into(),
        ));
    }
    Ok(strokes)
}

#[cfg(test)]
mod tests;
