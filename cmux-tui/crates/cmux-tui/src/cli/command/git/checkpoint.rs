//! `git checkpoint create|get|list|pin|unpin`: capture-only repository
//! checkpoints the session host stores without changing HEAD, the index or
//! the worktree.

use cmux_tui_core::resource::ResourceOperation as Op;
use serde_json::{Map, Value};

use super::super::{
    CommandPlan, Flags, Selectors, UsageError, comma_separated, insert_bounded_u32, request, usage,
    validate_one_of,
};

const REASONS: &[&str] = &["manual", "handoff"];

/// `words` follow `git checkpoint`; `params` already names the repository.
pub(super) fn parse(
    words: &[&str],
    flags: &mut Flags,
    selectors: &Selectors,
    mut params: Map<String, Value>,
) -> Result<CommandPlan, UsageError> {
    let operation = match words {
        ["create", paths @ ..] => {
            create(paths, flags, &mut params)?;
            Op::GitCheckpointCreate
        }
        ["get", id] => {
            if flags.take("key").is_some() {
                return Err(UsageError::new("give a checkpoint id or --key, not both"));
            }
            params.insert("checkpoint_id".into(), text(id));
            Op::GitCheckpointGet
        }
        ["get"] => {
            let key = flags.required("key")?;
            params.insert("idempotency_key".into(), Value::String(key));
            Op::GitCheckpointGet
        }
        ["list"] => {
            if let Some(cursor) = flags.take("cursor") {
                params.insert("cursor".into(), Value::String(cursor));
            }
            if let Some(value) = flags.take("limit") {
                insert_bounded_u32(&mut params, "limit", "--limit", value, 1, 200)?;
            }
            if flags.boolean("candidates") {
                params.insert("include_candidates".into(), Value::Bool(true));
            }
            Op::GitCheckpointList
        }
        ["pin", id] => {
            params.insert("checkpoint_id".into(), text(id));
            params.insert("pin_id".into(), Value::String(flags.required("pin")?));
            params.insert("reason".into(), Value::String(flags.required("reason")?));
            Op::GitCheckpointPin
        }
        ["unpin", id] => {
            params.insert("checkpoint_id".into(), text(id));
            params.insert("pin_id".into(), Value::String(flags.required("pin")?));
            Op::GitCheckpointUnpin
        }
        _ => return usage("git checkpoint action"),
    };
    request(operation, selectors, flags, params)
}

fn create(
    paths: &[&str],
    flags: &mut Flags,
    params: &mut Map<String, Value>,
) -> Result<(), UsageError> {
    match flags.take("untracked") {
        Some(untracked) => {
            validate_one_of("--untracked", &untracked, &["eligible"])?;
            if !paths.is_empty() {
                return Err(UsageError::new(
                    "give --untracked eligible or untracked paths, not both",
                ));
            }
            params.insert("include_untracked".into(), Value::String(untracked));
        }
        None if !paths.is_empty() => {
            let paths = paths.iter().map(|path| text(path)).collect();
            params.insert("include_untracked".into(), Value::Array(paths));
        }
        None => {}
    }
    if let Some(exclude) = flags.take("exclude") {
        let paths = comma_separated("--exclude", &exclude)?.into_iter().map(Value::String);
        params.insert("exclude_paths".into(), Value::Array(paths.collect()));
    }
    if let Some(reason) = flags.take("reason") {
        validate_one_of("--reason", &reason, REASONS)?;
        params.insert("reason".into(), Value::String(reason));
    }
    for (flag, field) in [
        ("expected-repository", "expected_repository_id"),
        ("expected-worktree", "expected_worktree_id"),
    ] {
        if let Some(id) = flags.take(flag) {
            params.insert(field.into(), Value::String(id));
        }
    }
    let mut limits = Map::new();
    if let Some(value) = flags.take("max-bytes") {
        insert_bounded_u32(&mut limits, "max_bytes", "--max-bytes", value, 1, 1_073_741_824)?;
    }
    if let Some(value) = flags.take("max-files") {
        insert_bounded_u32(&mut limits, "max_files", "--max-files", value, 1, 5000)?;
    }
    if !limits.is_empty() {
        params.insert("limits".into(), Value::Object(limits));
    }
    Ok(())
}

fn text(value: &str) -> Value {
    Value::String(value.to_string())
}
