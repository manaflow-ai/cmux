//! keybindings.json stacks one binding at a time, not as one file.
//!
//! A profile's keybindings.json is a set of bindings to add, the way its
//! settings are a set of keys: `use` merges them into the file you have,
//! and the library's stacked file is your own file (the base) with every
//! on entry's bindings in it, the higher entry winning for the same binding.
//! A binding is its key (strokes as cmux reads them) and its `when`; a
//! removal (`"-command"`) is its own binding, so removing a default and
//! binding the same key elsewhere both hold. Turning an entry off takes out
//! only its bindings and puts back the base's own for the same key; with no
//! entry on, the file is the base byte for byte.

use cmux_config::jsonc;
use cmux_config::keybindings::stroke;
use serde_json::Value;

use crate::Error;

/// The file's logical path.
pub const KEYBINDINGS: &str = "keybindings.json";

/// The stack key of one binding: `ctrl+cmd+h`, `ctrl+k s when terminalFocus`,
/// `cmd+w -closeTab`, `-closeTab`. `None` for an element that is no binding.
pub fn id(item: &Value) -> Option<String> {
    let object = item.as_object()?;
    let command = object.get("command")?.as_str()?.trim();
    if command.is_empty() {
        return None;
    }
    let key = object.get("key").and_then(Value::as_str).map(normal_key).unwrap_or_default();
    let mut id = match (key.is_empty(), command.starts_with('-')) {
        (true, true) => command.to_owned(),
        (true, false) => return None,
        (false, true) => format!("{key} {command}"),
        (false, false) => key,
    };
    if let Some(when) = object.get("when").and_then(Value::as_str).map(str::trim)
        && !when.is_empty()
    {
        id.push_str(" when ");
        id.push_str(&when.split_whitespace().collect::<Vec<_>>().join(" "));
    }
    Some(id)
}

/// `"Ctrl+Cmd+H  s"` as cmux reads it (`cmd+ctrl+h s`); a stroke cmux does
/// not read stays as written, lowercased.
fn normal_key(text: &str) -> String {
    text.split_whitespace()
        .map(|part| stroke::normalize(part).unwrap_or_else(|| part.to_lowercase()))
        .collect::<Vec<_>>()
        .join(" ")
}

/// The file's elements, in order, with their stack keys (`None`: no
/// binding). `Err` when the text is not a JSONC array.
fn elements(text: &str) -> Result<Vec<(Option<String>, Value)>, ()> {
    let spans = jsonc::array_spans(text).map_err(|_| ())?;
    spans
        .into_iter()
        .map(|(start, end)| {
            let value = jsonc::parse(text.get(start..end).ok_or(())?).map_err(|_| ())?;
            Ok((id(&value), value))
        })
        .collect()
}

/// The bindings of a keybindings.json text, in file order (a later one for
/// the same key wins, as cmux reads the file). Unreadable text has none.
pub fn bindings(text: &str) -> Vec<(String, Value)> {
    let mut out: Vec<(String, Value)> = Vec::new();
    for (id, value) in elements(text).unwrap_or_default() {
        let Some(id) = id else { continue };
        match out.iter_mut().find(|(have, _)| *have == id) {
            Some(slot) => slot.1 = value,
            None => out.push((id, value)),
        }
    }
    out
}

/// Whether `text` is a keybindings file the library can merge into.
pub fn readable(text: &str) -> bool {
    text.trim().is_empty() || elements(text).is_ok()
}

/// The winning binding for every key the given files bind, `files` top
/// first: the highest file's binding wins, and the order is the lowest
/// file's first (the order they were added), so a stack that was built one
/// `use` at a time composes to the file those uses wrote.
pub fn winners<'a>(files: impl DoubleEndedIterator<Item = &'a str>) -> Vec<(String, Value)> {
    let mut out: Vec<(String, Value)> = Vec::new();
    for text in files.rev() {
        for (id, value) in bindings(text) {
            match out.iter_mut().find(|(have, _)| *have == id) {
                Some(slot) => slot.1 = value,
                None => out.push((id, value)),
            }
        }
    }
    out
}

/// `base` with `winners` in it: a base binding for the same key is
/// replaced where it is, the rest are appended. No winners: `base` exactly.
pub fn compose(base: Option<&str>, winners: &[(String, Value)]) -> Result<Option<String>, Error> {
    if winners.is_empty() {
        return Ok(base.map(str::to_owned));
    }
    let unmergeable = || {
        Error::Library(
            "your keybindings.json is not a list of bindings; fix its syntax first".to_owned(),
        )
    };
    let mut text = base.unwrap_or_default().to_owned();
    let items = if text.trim().is_empty() {
        text.clear();
        Vec::new()
    } else {
        elements(&text).map_err(|()| unmergeable())?
    };
    let mut placed = vec![false; winners.len()];
    for (index, (id, value)) in items.iter().enumerate() {
        let Some(id) = id else { continue };
        let Some(at) = winners.iter().position(|(have, _)| have == id) else { continue };
        let (Some(slot), Some((_, want))) = (placed.get_mut(at), winners.get(at)) else { continue };
        *slot = true;
        if want != value {
            text = jsonc::array_replace(&text, index, want).map_err(|_| unmergeable())?;
        }
    }
    for ((_, value), placed) in winners.iter().zip(placed) {
        if !placed {
            text = jsonc::array_append(&text, value).map_err(|_| unmergeable())?;
        }
    }
    Ok(Some(text))
}

/// What the base is now, given a live file the person may have edited by
/// hand since the library composed it from `base` and `winners`: the live
/// file with each library binding still as the library wrote it taken out
/// (the base's own for that key put back). Their own edits stay.
pub fn uncompose(
    live: Option<&str>,
    base: Option<&str>,
    winners: &[(String, Value)],
) -> Option<String> {
    let live = live?;
    let Ok(items) = elements(live) else { return Some(live.to_owned()) };
    let base_items = base.and_then(|base| elements(base).ok()).unwrap_or_default();
    let mut text = live.to_owned();
    // Back to front, so the indexes before each edit stay where they are.
    for (index, (id, value)) in items.iter().enumerate().rev() {
        let Some(id) = id else { continue };
        if !winners.iter().any(|(have, wins)| have == id && wins == value) {
            continue;
        }
        let under = base_items.iter().find(|(have, _)| have.as_deref() == Some(id.as_str()));
        let edited = match under {
            Some((_, under)) => jsonc::array_replace(&text, index, under),
            None => jsonc::array_remove(&text, index),
        };
        if let Ok(edited) = edited {
            text = edited;
        }
    }
    // Nothing was there before, and nothing of the person's is there now.
    if base.is_none() && elements(&text).is_ok_and(|items| items.is_empty()) {
        let bare: String = text.chars().filter(|c| !c.is_whitespace()).collect();
        if bare == "[]" {
            return None;
        }
    }
    Some(text)
}

/// The bindings `new` has that `old` does not have as they are: what an
/// apply that changed keybindings.json added or changed, as a file.
pub fn added(old: &str, new: &str) -> Option<String> {
    let before = bindings(old);
    let mut text = String::new();
    for (id, value) in bindings(new) {
        if before.iter().any(|(have, was)| *have == id && *was == value) {
            continue;
        }
        text = jsonc::array_append(&text, &value).ok()?;
    }
    (!text.is_empty()).then_some(text)
}

#[cfg(test)]
#[path = "keys_tests.rs"]
mod tests;
