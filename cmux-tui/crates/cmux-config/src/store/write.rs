//! `settings.set`, `settings.reset` and `settings.reset_all` on the file
//! text (Swift `setSetting`, `removePruning`, `resetAllSettings` and the
//! socket's `writeSetting`).

use serde_json::Value;

use super::replay::{Lookup, fingerprint};
use super::{Applied, Change, Op, Origin, Outcome, State, Target, WriteMeta, diff};
use crate::guard::{managed_key_for_path, managed_key_for_removal};
use crate::jsonc::{self, JsoncError};
use crate::keypath::{RESERVED_SHORTCUT_KEYS, dotted};
use crate::refusal::Refusal;
use crate::schema::{Row, accepts};
use crate::value::{canonical, is_empty_object, value_at};

pub(super) fn apply_write(state: &State, op: Op) -> Result<Applied, Refusal> {
    let meta = match &op {
        Op::Set { meta, .. } | Op::Reset { meta, .. } | Op::ResetAll { meta } => meta.clone(),
        _ => unreachable!("apply_write takes write ops only"),
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
                });
            }
            Lookup::Conflict => {
                return Err(Refusal::IdempotencyConflict { idempotency_key: key.clone() });
            }
            Lookup::Miss => {}
        }
    }
    if let Some(expected) = meta.if_revision
        && expected != state.revision
    {
        return Err(Refusal::RevisionConflict { expected, actual: state.revision });
    }
    let text = match op {
        Op::Set { target, value, meta } => set_text(state, &target, canonical(value), &meta)?,
        Op::Reset { target, meta } => reset_text(state, &target, &meta)?,
        Op::ResetAll { meta } => reset_all_text(state, &meta)?,
        _ => unreachable!("apply_write takes write ops only"),
    };
    let mut next = state.clone();
    let mut applied = if text == state.source {
        let outcome = Outcome { revision: state.revision, keys: Vec::new(), replayed: false };
        Applied { state: next, changes: Vec::new(), outcome, write: None }
    } else {
        next.read_file(super::FileRead::Text(text.clone()));
        if let Some(problem) = &next.file_problem {
            return Err(Refusal::FileUnreadable { message: problem.clone() });
        }
        next.recompute();
        next.revision = state.revision + 1;
        // Every applied write bumps the revision once, even when no value changed.
        let keys = diff::changed_keys(&state.effective, &next.effective);
        let change = Change { revision: next.revision, keys: keys.clone(), origin: meta.origin };
        let outcome = Outcome { revision: next.revision, keys, replayed: false };
        Applied { state: next, changes: vec![change], outcome, write: Some(text) }
    };
    if let Some(key) = meta.idempotency_key {
        applied.state.replay.insert(key, print, applied.outcome.clone());
    }
    Ok(applied)
}

fn writable_path(state: &State, target: &Target) -> Result<Vec<String>, Refusal> {
    if let Some(problem) = &state.file_problem {
        // Never rewrite a file the user left broken: they would lose it.
        return Err(Refusal::FileUnreadable { message: problem.clone() });
    }
    let path = target.path();
    if path.is_empty() {
        return Err(Refusal::InvalidParams { message: "invalid settings path ''".to_string() });
    }
    Ok(path)
}

/// Origin `mcp` may change only schema rows that are agent-settable.
fn check_agent(row: Option<&Row>, path: &[String], meta: &WriteMeta) -> Result<(), Refusal> {
    if meta.origin != Origin::Mcp {
        return Ok(());
    }
    match row {
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

fn set_text(
    state: &State,
    target: &Target,
    value: Value,
    meta: &WriteMeta,
) -> Result<String, Refusal> {
    let path = writable_path(state, target)?;
    let row = state.schema.row_at(&path);
    check_agent(row, &path, meta)?;
    if let Some(row) = row {
        accepts(row, &value, &state.domains)?;
    }
    check_managed(state, &path)?;
    jsonc::set(&state.source, &path, &value).map_err(unreadable)
}

fn reset_text(state: &State, target: &Target, meta: &WriteMeta) -> Result<String, Refusal> {
    let path = writable_path(state, target)?;
    let row = state.schema.row_at(&path);
    check_agent(row, &path, meta)?;
    check_managed(state, &path)?;
    if row.is_some() {
        remove_pruning(state.source.clone(), &path)
    } else {
        jsonc::remove(&state.source, &path).map_err(unreadable)
    }
}

/// Removes every schema key and every shortcut override. Custom actions,
/// tab bar buttons, keys the schema does not know, `kept_on_reset_all` rows
/// and managed keys stay.
fn reset_all_text(state: &State, meta: &WriteMeta) -> Result<String, Refusal> {
    if meta.origin == Origin::Mcp {
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
    let mut parent = path[..path.len() - 1].to_vec();
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
