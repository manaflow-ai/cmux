//! Part of `Hub`; see `hub/mod.rs`. Each tool call path a record names gets
//! its canonical form beside it (`crate::path_canon`), so a client compares
//! files by one spelling: the edited-files card lists a failed call and its
//! retry at another spelling once.

use super::*;
use crate::path_canon::canonical_path;

/// Sets `_meta.acpmux.canonicalPath` beside each path a `tool_call` or
/// `tool_call_update` record names: each of its `locations`, each `diff` in
/// its content, and the update itself for its input's `file_path`. Paths are
/// read from the session's cwd. A place that already carries one (a fork's copy
/// of its parent's record) keeps it, and nothing else in `_meta` changes.
/// Every record that passes here also gets a shell call's exit code and command
/// where clients read them (`tool_shell::add_shell_fields`).
pub(super) fn add_canonical_paths(session: &Session, kind: &str, msg: &mut Value) {
    if !matches!(kind.strip_suffix(".replay").unwrap_or(kind), "tool_call" | "tool_call_update") {
        return;
    }
    // A shell call's exit code and command where clients read them (`tool_shell.rs`).
    super::tool_shell::add_shell_fields(kind, msg);
    // The packages it installs, while Usage Patterns is on (`tool_installs.rs`).
    super::tool_installs::count_installs(&session.id, kind, msg);
    let Some(update) = msg.pointer_mut("/params/update").filter(|u| u.is_object()) else {
        return;
    };
    let cwd = session.meta.lock().unwrap_or_else(std::sync::PoisonError::into_inner).cwd.clone();
    let canonical = |path: Option<&str>| path.and_then(|p| canonical_path(p, Some(&cwd)));
    if let Some(locations) = update.get_mut("locations").and_then(Value::as_array_mut) {
        for location in locations {
            let path = location.get("path").and_then(Value::as_str).map(str::to_owned);
            note(location, || canonical(path.as_deref()));
        }
    }
    if let Some(content) = update.get_mut("content").and_then(Value::as_array_mut) {
        for diff in content.iter_mut().filter(|item| item["type"] == "diff") {
            let path = diff.get("path").and_then(Value::as_str).map(str::to_owned);
            note(diff, || canonical(path.as_deref()));
        }
    }
    let input = update.pointer("/rawInput/file_path").and_then(Value::as_str).map(str::to_owned);
    if input.is_some() {
        note(update, || canonical(input.as_deref()));
    }
    // A finished read of an image file that returned no image gets the file's image
    // (`tool_read_images.rs`): Codex's View of a PNG drew as its bare path.
    super::tool_read_images::add_read_image(kind, msg, &cwd);
}

/// `target._meta.acpmux.canonicalPath` = `canonical()`, unless it has one or
/// its `_meta` is not an object.
fn note(target: &mut Value, canonical: impl FnOnce() -> Option<String>) {
    let Some(fields) = target.as_object_mut() else { return };
    if fields.get("_meta").and_then(|meta| meta.pointer("/acpmux/canonicalPath")).is_some() {
        return;
    }
    let Some(path) = canonical() else { return };
    let Some(meta) = fields.entry("_meta").or_insert_with(|| json!({})).as_object_mut() else {
        return;
    };
    if let Some(acpmux) = meta.entry("acpmux").or_insert_with(|| json!({})).as_object_mut() {
        acpmux.insert("canonicalPath".into(), json!(path));
    }
}

#[cfg(test)]
mod tests;
