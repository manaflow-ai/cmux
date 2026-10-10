//! In-place edits of keybindings.json for the editor's ops (set, remove,
//! reset). Comments and every entry the edit does not touch stay byte for
//! byte. A change to a default binding is written as a removal entry
//! (`"-<command>"`) plus, for a set, the new entry.

use serde_json::{Map, Value};

use super::{Entry, parse, stroke};
use crate::jsonc::{self, JsoncError};

/// One binding an edit names: command, keys (keybindings.json syntax) and
/// `when` as text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Target {
    pub command: String,
    pub key: String,
    pub when: Option<String>,
}

/// Why an edit was refused.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EditError {
    /// The file is not a readable array; nothing is written.
    Unreadable(String),
    InvalidKey(String),
}

impl From<JsoncError> for EditError {
    fn from(error: JsoncError) -> Self {
        EditError::Unreadable(error.to_string())
    }
}

fn strokes(key: &str) -> Result<Vec<String>, EditError> {
    key.split_whitespace()
        .map(|part| stroke::normalize(part).ok_or_else(|| EditError::InvalidKey(part.to_string())))
        .collect()
}

fn readable(source: &str) -> Result<Vec<Entry>, EditError> {
    let parsed = parse(source);
    if let Some(problem) = parsed.diagnostics.iter().find(|diagnostic| diagnostic.index.is_none()) {
        return Err(EditError::Unreadable(problem.message.clone()));
    }
    Ok(parsed.entries)
}

/// The file's own (non-removal) entry for `target`, if any.
fn user_entry(entries: &[Entry], target: &Target) -> Result<Option<usize>, EditError> {
    let keys = strokes(&target.key)?;
    Ok(entries
        .iter()
        .find(|entry| {
            !entry.removal
                && entry.command == target.command
                && entry.keys == keys
                && entry.when == target.when
        })
        .map(|entry| entry.index))
}

fn json(key: &str, command: &str, when: Option<&str>, args: Option<&Value>) -> Value {
    let mut object = Map::new();
    object.insert("key".into(), Value::String(key.into()));
    object.insert("command".into(), Value::String(command.into()));
    if let Some(when) = when {
        object.insert("when".into(), Value::String(when.into()));
    }
    if let Some(args) = args {
        object.insert("args".into(), args.clone());
    }
    Value::Object(object)
}

/// Binds `binding` (with `args`). With `replaces`, the old binding goes:
/// the file's own entry is replaced in place; a default gets a removal.
pub fn set(
    source: &str,
    binding: &Target,
    args: Option<&Value>,
    replaces: Option<&Target>,
) -> Result<String, EditError> {
    let entries = readable(source)?;
    let key = strokes(&binding.key)?.join(" ");
    let new = json(&key, &binding.command, binding.when.as_deref(), args);
    match replaces {
        Some(old) => match user_entry(&entries, old)? {
            Some(index) => Ok(jsonc::array_replace(source, index, &new)?),
            None => Ok(jsonc::array_append(&removal(source, old)?, &new)?),
        },
        None => Ok(jsonc::array_append(source, &new)?),
    }
}

/// Unbinds one binding: the file's own entry is deleted; a default gets a
/// removal entry.
pub fn remove(source: &str, target: &Target) -> Result<String, EditError> {
    let entries = readable(source)?;
    match user_entry(&entries, target)? {
        Some(index) => Ok(jsonc::array_remove(source, index)?),
        None => removal(source, target),
    }
}

fn removal(source: &str, target: &Target) -> Result<String, EditError> {
    let key = strokes(&target.key)?.join(" ");
    Ok(jsonc::array_append(
        source,
        &json(&key, &format!("-{}", target.command), target.when.as_deref(), None),
    )?)
}

/// Drops every entry and removal of `command`: its defaults come back.
pub fn reset(source: &str, command: &str) -> Result<String, EditError> {
    let entries = readable(source)?;
    let mut text = source.to_string();
    // From the end, so earlier indexes stay valid.
    for entry in entries.iter().rev().filter(|entry| entry.command == command) {
        text = jsonc::array_remove(&text, entry.index)?;
    }
    Ok(text)
}
