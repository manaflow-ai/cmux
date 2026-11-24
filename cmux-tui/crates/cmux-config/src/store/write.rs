//! `settings.set`, `settings.reset`, `settings.reset_all` and
//! `settings.edit` on the file text (Swift `setSetting`, `removePruning`,
//! `resetAllSettings`, the socket's `writeSetting`, and `CmuxConfigFile`'s
//! `apply`, `setUnset` and `removeUnchanged`).

use serde_json::Value;

use super::replay::{Lookup, fingerprint};
use super::{
    Applied, Change, Edit, EditKind, MAX_EDITS, Op, Origin, Outcome, State, Target, WriteMeta, diff,
};
use crate::guard::{managed_key_for_path, managed_key_for_removal};
use crate::history::{self, HistoryEntry};
use crate::jsonc::{self, JsoncError};
use crate::keypath::{RESERVED_SHORTCUT_KEYS, dotted};
use crate::refusal::Refusal;
use crate::schema::{
    Row, accepts, normalize_backdrop, recents_of, record_recent, replaced_by_row, retired_keys,
    retired_reason,
};
use crate::value::{canonical, is_empty_object, value_at};

fn not_a_write() -> Refusal {
    Refusal::InvalidParams { message: "apply_write takes write ops only".to_string() }
}

pub(super) fn apply_write(
    state: &State,
    op: Op,
    history: &[HistoryEntry],
) -> Result<Applied, Refusal> {
    let meta = match &op {
        Op::Set { meta, .. }
        | Op::Reset { meta, .. }
        | Op::ResetAll { meta }
        | Op::Edit { meta, .. }
        | Op::Undo { meta }
        | Op::Restore { meta, .. }
        | Op::ResetGroup { meta, .. } => meta.clone(),
        _ => return Err(not_a_write()),
    };
    let print = fingerprint(&op);
    if let Some(key) = &meta.idempotency_key {
        match state.replay.lookup(key, &print) {
            Lookup::Replay(outcome) => {
                return Ok(Applied {
                    state: state.clone(),
                    changes: Vec::new(),
                    outcome,
                    write: None,
                    undoes: None,
                });
            }
            Lookup::Conflict(committed_operation) => {
                return Err(Refusal::IdempotencyConflict {
                    idempotency_key: key.clone(),
                    committed_operation,
                });
            }
            Lookup::Miss => {}
        }
    }
    if let Some(expected) = meta.if_revision
        && expected != state.revision
    {
        return Err(Refusal::RevisionConflict { expected, actual: state.revision });
    }
    let source = state.source.as_str();
    let mut undoes = None;
    let (text, applied_edits) = match op {
        Op::Set { target, value, meta } => {
            (set_text(state, source, &target, canonical(value), &meta, true)?, Vec::new())
        }
        Op::Reset { target, meta } => (reset_text(state, source, &target, &meta)?, Vec::new()),
        Op::ResetAll { meta } => (reset_all_text(state, &meta)?, Vec::new()),
        Op::Edit { edits, meta } => edit_text(state, &edits, &meta)?,
        Op::Undo { meta } => {
            writable(state)?;
            let entry =
                history::undo_pick(history, source).ok_or_else(|| Refusal::InvalidParams {
                    message: "nothing to undo: the settings history has no change to take back"
                        .to_string(),
                })?;
            undoes = Some(entry.revision);
            (restore_text(state, &entry.before, &meta)?, Vec::new())
        }
        Op::Restore { revision, meta } => {
            writable(state)?;
            let entry = history::find(history, revision).ok_or_else(|| Refusal::InvalidParams {
                message: format!(
                    "the settings history has no change with revision {revision} (see settings.history)"
                ),
            })?;
            (restore_text(state, &entry.before, &meta)?, Vec::new())
        }
        Op::ResetGroup { group, meta } => (reset_group_text(state, &group, &meta)?, Vec::new()),
        _ => return Err(not_a_write()),
    };
    let mut next = state.clone();
    let mut applied = if text == state.source {
        let outcome = Outcome {
            revision: state.revision,
            keys: Vec::new(),
            replayed: false,
            applied: applied_edits,
        };
        Applied { state: next, changes: Vec::new(), outcome, write: None, undoes: None }
    } else {
        next.read_file(super::FileRead::Text(text.clone()));
        if let Some(problem) = &next.file_problem {
            return Err(Refusal::FileUnreadable { message: problem.clone() });
        }
        next.recompute();
        // Once per write, so an edit batch records the background it started from.
        let text = match record_background(state, &next, text)? {
            Recorded::Same(text) => text,
            Recorded::Changed(text) => {
                next.read_file(super::FileRead::Text(text.clone()));
                next.recompute();
                text
            }
        };
        next.revision = state.revision + 1;
        // Every applied write bumps the revision once, even when no value changed.
        let keys = diff::changed_keys(&state.effective, &next.effective);
        let change = Change { revision: next.revision, keys: keys.clone(), origin: meta.origin };
        let outcome =
            Outcome { revision: next.revision, keys, replayed: false, applied: applied_edits };
        Applied { state: next, changes: vec![change], outcome, write: Some(text), undoes }
    };
    if let Some(key) = meta.idempotency_key {
        applied.state.replay.insert(key, print, applied.outcome.clone());
    }
    Ok(applied)
}

/// Never rewrite a file the user left broken: they would lose it.
fn writable(state: &State) -> Result<(), Refusal> {
    match &state.file_problem {
        Some(problem) => Err(Refusal::FileUnreadable { message: problem.clone() }),
        None => Ok(()),
    }
}

/// `settings.restore` and `settings.undo`: the earlier file `text` as it
/// stands. It must parse to an object (the write's own read checks again).
/// Managed keys are not checked: the file may hold any value for them and
/// the managed value still wins. An origin other than the person may change
/// only what `settings.set` lets it change: every row whose file value
/// differs passes [`check_agent`], and so does any other path that differs
/// (origin `mcp` may change no path outside the schema).
fn restore_text(state: &State, text: &str, meta: &WriteMeta) -> Result<String, Refusal> {
    writable(state)?;
    let root = match jsonc::parse(text) {
        Ok(root @ Value::Object(_)) => root,
        Ok(_) => {
            return Err(Refusal::FileUnreadable {
                message: "the earlier settings file's root is not an object".to_string(),
            });
        }
        Err(error) => return Err(unreadable(error)),
    };
    if !meta.origin.is_person() {
        let current = &state.file_root;
        for row in &state.schema.rows {
            if value_at(current, &row.path) != value_at(&root, &row.path) {
                check_agent(Some(row), &row.path, meta)?;
            }
        }
        let (current, earlier) = (without_rows(current, state), without_rows(&root, state));
        if let Some(path) = first_difference(&current, &earlier, &mut Vec::new()) {
            check_agent(None, &path, meta)?;
        }
    }
    Ok(text.to_string())
}

/// `root` without the values of schema rows (empty objects left pruned).
fn without_rows(root: &Value, state: &State) -> Value {
    let mut root = root.clone();
    for row in &state.schema.rows {
        remove_value(&mut root, &row.path);
    }
    root
}

/// Removes the member at `path`, and each object the removal left empty.
fn remove_value(value: &mut Value, path: &[String]) {
    let Value::Object(members) = value else { return };
    match path {
        [] => {}
        [last] => {
            members.remove(last);
        }
        [first, rest @ ..] => {
            if let Some(child) = members.get_mut(first) {
                remove_value(child, rest);
                if child.as_object().is_some_and(serde_json::Map::is_empty) {
                    members.remove(first);
                }
            }
        }
    }
}

/// The first path where `a` and `b` differ (objects compared member by member).
fn first_difference(a: &Value, b: &Value, path: &mut Vec<String>) -> Option<Vec<String>> {
    match (a, b) {
        (Value::Object(left), Value::Object(right)) => {
            for name in left.keys().chain(right.keys()) {
                path.push(name.clone());
                let found = match (left.get(name), right.get(name)) {
                    (Some(x), Some(y)) => first_difference(x, y, path),
                    (x, y) if x != y => Some(path.clone()),
                    _ => None,
                };
                path.pop();
                if found.is_some() {
                    return found;
                }
            }
            None
        }
        _ if a != b => Some(path.clone()),
        _ => None,
    }
}

/// `settings.reset_group`: removes every row of the group (or section) the
/// file sets, with the replaced old key, in one text; managed rows stay
/// (as in `settings.reset_all`), and each removed row passes the agent
/// check of `settings.reset`. Unlike reset_all, `kept_on_reset_all` rows of
/// the group reset too: the caller named this area.
fn reset_group_text(state: &State, group: &str, meta: &WriteMeta) -> Result<String, Refusal> {
    writable(state)?;
    let rows = state.schema.rows_in_group(group);
    if rows.is_empty() {
        return Err(Refusal::InvalidParams {
            message: format!(
                "unknown settings group '{group}'; groups are: {}",
                state.schema.group_names().join(", ")
            ),
        });
    }
    let managed = &state.effective.managed_keys;
    let file = &state.file_root;
    let mut text = state.source.clone();
    for row in rows {
        let replaced = replaced_by_row(&row.path)
            .is_some_and(|replaced| value_at(file, &replaced.old).is_some());
        if value_at(file, &row.path).is_none() && !replaced {
            continue;
        }
        if managed.contains_key(&row.key)
            || managed_key_for_removal(managed, row.path.as_slice()).is_some()
        {
            continue;
        }
        check_agent(Some(row), &row.path, meta)?;
        text = remove_pruning(without_replaced(text, &row.path)?, &row.path)?;
    }
    Ok(text)
}

fn writable_path(state: &State, target: &Target) -> Result<Vec<String>, Refusal> {
    writable(state)?;
    let path = target.path();
    if path.is_empty() {
        return Err(Refusal::InvalidParams { message: "invalid settings path ''".to_string() });
    }
    Ok(path)
}

/// A user-only row (`agent_settable: false`) changes only for origin `user`
/// or `app` (the person, through the app or `--origin user`), like the app
/// socket's user-only refusal. Origin `mcp` may change only agent-settable
/// rows. Origins are declared by the client: this stops cooperative agents
/// and scripts; sandboxed apps and remote peers are always `mcp`.
fn check_agent(row: Option<&Row>, path: &[String], meta: &WriteMeta) -> Result<(), Refusal> {
    if meta.origin.is_person() {
        return Ok(());
    }
    match row {
        None if meta.origin != Origin::Mcp => Ok(()),
        None => Err(Refusal::AgentRefused { key: dotted(path), reason: None }),
        Some(row) if !row.agent_settable => {
            Err(Refusal::AgentRefused { key: row.key.clone(), reason: row.agent_refusal.clone() })
        }
        Some(_) => Ok(()),
    }
}

fn check_managed(state: &State, path: &[String]) -> Result<(), Refusal> {
    match managed_key_for_path(&state.effective.managed_keys, path) {
        Some((key, source)) => {
            Err(Refusal::Managed { key: key.to_string(), source: source.clone() })
        }
        None => Ok(()),
    }
}

/// `settings.edit`: each edit on the text the edits before it left, with
/// the checks of `settings.set` and `settings.reset`; the managed keys, the
/// layers below the file and the domains are the state's. Returns the text
/// and the indexes of the edits that applied.
fn edit_text(
    state: &State,
    edits: &[Edit],
    meta: &WriteMeta,
) -> Result<(String, Vec<usize>), Refusal> {
    if edits.is_empty() || edits.len() > MAX_EDITS {
        return Err(Refusal::InvalidParams {
            message: format!("settings.edit takes 1 to {MAX_EDITS} edits, not {}", edits.len()),
        });
    }
    if let Some(problem) = &state.file_problem {
        // Never rewrite a file the user left broken, even when no condition holds.
        return Err(Refusal::FileUnreadable { message: problem.clone() });
    }
    let mut text = state.source.clone();
    let mut applied = Vec::new();
    for (index, edit) in edits.iter().enumerate() {
        let holds = match &edit.kind {
            EditKind::Set(_) | EditKind::SetExact(_) | EditKind::Reset => true,
            EditKind::SetUnset(_) => file_value(&text, &edit.target)?.is_none(),
            EditKind::ResetUnchanged(expected) => {
                file_value(&text, &edit.target)?.map(canonical) == Some(canonical(expected.clone()))
            }
        };
        if !holds {
            continue;
        }
        text = match &edit.kind {
            EditKind::Set(value) | EditKind::SetUnset(value) => {
                set_text(state, &text, &edit.target, canonical(value.clone()), meta, true)?
            }
            EditKind::SetExact(value) => {
                set_text(state, &text, &edit.target, canonical(value.clone()), meta, false)?
            }
            EditKind::Reset | EditKind::ResetUnchanged(_) => {
                reset_text(state, &text, &edit.target, meta)?
            }
        };
        applied.push(index);
    }
    Ok((text, applied))
}

/// The value `text` holds at the target's path, if any.
fn file_value(text: &str, target: &Target) -> Result<Option<Value>, Refusal> {
    let root = jsonc::parse(text).map_err(unreadable)?;
    Ok(value_at(&root, &target.path()).cloned())
}

/// `remove_default`: a schema row set to its default loses its key
/// (`settings.set`); `set_exact` passes false and keeps it.
fn set_text(
    state: &State,
    source: &str,
    target: &Target,
    value: Value,
    meta: &WriteMeta,
    remove_default: bool,
) -> Result<String, Refusal> {
    let path = writable_path(state, target)?;
    if let Some(reason) = retired_reason(&path) {
        return Err(Refusal::Removed { key: dotted(&path), reason: reason.to_string() });
    }
    let row = state.schema.row_at(&path);
    check_agent(row, &path, meta)?;
    check_managed(state, &path)?;
    // A pasted YouTube address in a background row is stored as its `youtube:` id.
    let value = match row {
        Some(row) => normalize_backdrop(row, value),
        None => value,
    };
    if let Some(row) = row {
        accepts(row, &value, &state.domains)?;
        // The default's own value removes the key, so it keeps following the default when a later
        // release changes it (Swift `isUnsetValue`); not when a layer below the file fills the key.
        if remove_default
            && row.default.clone().map(canonical).as_ref() == Some(&value)
            && !state.managed.recommended.contains_key(&row.key)
            && !state.team.defaults.contains_key(&row.key)
            && !overrides_group_background(state, source, row, &value)?
        {
            let text = remove_pruning(without_replaced(source.to_string(), &path)?, &path)?;
            return Ok(text);
        }
    }
    if row.is_none() {
        check_row_overlap(state, &path)?;
    }
    let text = without_replaced(source.to_string(), &path)?;
    jsonc::set(&text, &path, &value).map_err(unreadable)
}

fn overrides_group_background(
    state: &State,
    source: &str,
    row: &Row,
    value: &Value,
) -> Result<bool, Refusal> {
    if row.key != crate::sidebar_look::GROUP_BACKGROUND || source == state.source {
        return Ok(state.overrides_group_background(row, value));
    }
    // Earlier edits in this batch may have changed the selected look or its theme.
    let mut pending = state.clone();
    pending.file_root = jsonc::parse(source).map_err(unreadable)?;
    pending.recompute();
    Ok(pending.overrides_group_background(row, value))
}

const BACKGROUND: [&str; 2] = ["appearance", "background"];
const BACKGROUND_RECENTS: [&str; 2] = ["appearance", "backgroundRecents"];

enum Recorded {
    Same(String),
    Changed(String),
}

/// The background cmux shows: the effective value (theme, file, team defaults, recommended), else
/// the schema default.
fn shown_background(state: &State) -> Option<String> {
    let path = parts(&BACKGROUND);
    value_at(&state.effective.root, &path)
        .cloned()
        .or_else(|| state.schema.row_at(&path).and_then(|row| row.default.clone()))
        .and_then(|value| value.as_str().map(str::to_string))
}

/// After a write that changes the background shown, from any surface, the background it replaced
/// goes first in `appearance.backgroundRecents` (Leo, 2026-11-22: "it was cumbersome back then to
/// switch back"), and the new one leaves the list. Nothing is recorded when the shown value did
/// not change or a policy manages the recents.
fn record_background(state: &State, next: &State, text: String) -> Result<Recorded, Refusal> {
    let recents_path = parts(&BACKGROUND_RECENTS);
    if check_managed(state, &recents_path).is_err() {
        return Ok(Recorded::Same(text));
    }
    let (Some(previous), now) = (shown_background(state), shown_background(next)) else {
        return Ok(Recorded::Same(text));
    };
    if now.as_deref() == Some(previous.as_str()) {
        return Ok(Recorded::Same(text));
    }
    let root = jsonc::parse(&text).map_err(unreadable)?;
    let old = recents_of(value_at(&root, &recents_path));
    // The background now shown is not a recent one: the list is what one click goes back to.
    let mut recents = record_recent(&old, &previous);
    recents.retain(|recent| Some(recent) != now.as_ref());
    if recents == old {
        return Ok(Recorded::Same(text));
    }
    let value = Value::Array(recents.into_iter().map(Value::String).collect());
    Ok(Recorded::Changed(jsonc::set(&text, &recents_path, &value).map_err(unreadable)?))
}

/// `text` without the retired key the row at `path` replaced, so the old key
/// never applies behind a write or reset of the row (`schema::retired`).
fn without_replaced(text: String, path: &[String]) -> Result<String, Refusal> {
    let Some(replaced) = replaced_by_row(path) else { return Ok(text) };
    let root = jsonc::parse(&text).map_err(unreadable)?;
    if value_at(&root, &replaced.old).is_none() {
        return Ok(text);
    }
    remove_pruning(text, &replaced.old)
}

/// A non-row path may not hold or sit inside a row: writing an ancestor
/// object would replace rows without validating them, and writing below a
/// row would turn its value into an object.
fn check_row_overlap(state: &State, path: &[String]) -> Result<(), Refusal> {
    let overlapping = state
        .schema
        .rows
        .iter()
        .find(|row| row.path.iter().zip(path).all(|(row_part, part)| row_part == part));
    match overlapping {
        None => Ok(()),
        Some(row) => Err(Refusal::InvalidParams {
            message: format!(
                "'{}' overlaps the setting '{}'; set each setting by its own key",
                dotted(path),
                row.key
            ),
        }),
    }
}

fn reset_text(
    state: &State,
    source: &str,
    target: &Target,
    meta: &WriteMeta,
) -> Result<String, Refusal> {
    let path = writable_path(state, target)?;
    let row = state.schema.row_at(&path);
    check_agent(row, &path, meta)?;
    check_managed(state, &path)?;
    // A retired key may be removed from an old file (pruning like a row).
    let text = without_replaced(source.to_string(), &path)?;
    let text = if row.is_some() || retired_reason(&path).is_some() {
        remove_pruning(text, &path)?
    } else {
        jsonc::remove(&text, &path).map_err(unreadable)?
    };
    Ok(text)
}

/// Removes every schema key and every shortcut override. Custom actions,
/// tab bar buttons, keys the schema does not know, `kept_on_reset_all` rows
/// and managed keys stay.
fn reset_all_text(state: &State, meta: &WriteMeta) -> Result<String, Refusal> {
    if !meta.origin.is_person() {
        return Err(Refusal::AgentRefused {
            key: "settings.reset_all".to_string(),
            reason: Some("destructive".to_string()),
        });
    }
    writable_path(state, &Target::Key("settings".to_string()))?;
    let managed = &state.effective.managed_keys;
    let removable = |path: &[String]| managed_key_for_removal(managed, path).is_none();
    let mut text = state.source.clone();
    for row in &state.schema.rows {
        if managed.contains_key(&row.key)
            || row.kept_on_reset_all
            || !removable(row.path.as_slice())
        {
            continue;
        }
        text = remove_pruning(text, &row.path)?;
    }
    // Retired keys go too, as in Swift `resetAllSettings`: an old key a row
    // replaced would apply again behind the reset.
    for (key, _) in retired_keys() {
        let path: Vec<String> = key.split('.').map(str::to_string).collect();
        if removable(path.as_slice()) && !managed.contains_key(key) {
            text = remove_pruning(text, &path)?;
        }
    }
    let bindings = parts(&["shortcuts", "bindings"]);
    if removable(bindings.as_slice()) {
        text = jsonc::remove(&text, &bindings).map_err(unreadable)?;
    }
    let root = jsonc::parse(&text).map_err(unreadable)?;
    if let Some(Value::Object(members)) = value_at(&root, &["shortcuts"]) {
        for key in members.keys().filter(|key| !RESERVED_SHORTCUT_KEYS.contains(&key.as_str())) {
            let shortcut = parts(&["shortcuts", key.as_str()]);
            if removable(shortcut.as_slice()) {
                text = jsonc::remove(&text, &shortcut).map_err(unreadable)?;
            }
        }
    }
    prune_empty(&mut text, &parts(&["shortcuts"]))?;
    Ok(text)
}

/// Removes `path`, then each parent object that became empty.
fn remove_pruning(text: String, path: &[String]) -> Result<String, Refusal> {
    let mut text = jsonc::remove(&text, path).map_err(unreadable)?;
    let mut parent = path.split_last().map(|(_, parent)| parent.to_vec()).unwrap_or_default();
    while !parent.is_empty() && prune_empty(&mut text, &parent)? {
        parent.pop();
    }
    Ok(text)
}

/// Removes the object at `path` when it has no members. True when removed.
fn prune_empty(text: &mut String, path: &[String]) -> Result<bool, Refusal> {
    let root = jsonc::parse(text).map_err(unreadable)?;
    if !is_empty_object(value_at(&root, path)) {
        return Ok(false);
    }
    *text = jsonc::remove(text, path).map_err(unreadable)?;
    Ok(true)
}

fn parts(names: &[&str]) -> Vec<String> {
    names.iter().map(|name| name.to_string()).collect()
}

fn unreadable(error: JsoncError) -> Refusal {
    Refusal::FileUnreadable { message: error.to_string() }
}
