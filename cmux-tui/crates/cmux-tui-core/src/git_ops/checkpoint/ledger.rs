//! Checkpoint mutations in the session's `resource_mutations` ledger, with
//! the keying, replay, conflict and pruning every other resource mutation
//! has. A mutation's fingerprint binds its normalized arguments and the
//! repository and worktree its target resolved to, so a key reused for a
//! target that now resolves elsewhere is refused, never replayed.

use std::sync::Arc;

use rusqlite::OptionalExtension;
use serde_json::{Value, json};

use super::scan::refused;
use crate::Mux;
use crate::resource::ResourceError;
use crate::resource_router::{mutation_result, resource_operation_error};
use crate::workspace_registry::{ResourcePatch, WorkspaceMutation};

const ORIGIN: &str = "resource-api";

/// The resolved identity a fingerprint binds.
pub(super) struct Identity<'a> {
    pub repository_id: &'a str,
    pub worktree_id: &'a str,
}

/// The fingerprint of a mutation: its operation, selectors and fields, and
/// the identity they resolved to.
pub(super) fn fingerprint(
    operation: &str,
    selectors: &Value,
    fields: &Value,
    identity: &Identity<'_>,
) -> Value {
    json!({
        "operation": operation,
        "selectors": selectors,
        "fields": fields,
        "repository_id": identity.repository_id,
        "worktree_id": identity.worktree_id,
    })
}

/// A committed mutation's operation and fingerprint, read without a
/// transaction.
struct Committed {
    operation: String,
    fingerprint: Value,
    result: Value,
}

fn committed(mux: &Mux, key: &str, operation: &str) -> Result<Option<Committed>, ResourceError> {
    let registry = mux.workspace_registry.lock().unwrap_or_else(|poison| poison.into_inner());
    let row = registry
        .connection
        .query_row(
            "SELECT operation, fingerprint, result_json FROM resource_mutations
             WHERE idempotency_key = ?1",
            [key],
            |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?, row.get::<_, String>(2)?))
            },
        )
        .optional()
        .map_err(|error| store_failed(operation, &error.to_string()))?;
    let Some((stored_operation, fingerprint, result)) = row else { return Ok(None) };
    Ok(Some(Committed {
        operation: stored_operation,
        fingerprint: serde_json::from_str(&fingerprint).unwrap_or(Value::Null),
        result: serde_json::from_str(&result).unwrap_or(Value::Null),
    }))
}

/// The first result of `key`, when it was committed with this operation and
/// fingerprint; `idempotency.conflict` for other input, and
/// `repository_changed` when the same operation's target now resolves to
/// another repository or worktree.
pub(super) fn prior(
    mux: &Arc<Mux>,
    key: &str,
    operation: &'static str,
    fingerprint: &Value,
) -> Result<Option<Value>, ResourceError> {
    let Some(stored) = committed(mux, key, operation)? else { return Ok(None) };
    let bound = |field: &str| stored.fingerprint[field] != fingerprint[field];
    if stored.operation == operation && (bound("repository_id") || bound("worktree_id")) {
        let message = "the key was first used for another repository or worktree";
        let extra = json!({
            "repository_id": stored.fingerprint["repository_id"],
            "worktree_id": stored.fingerprint["worktree_id"],
        });
        return Err(refused(operation, "repository_changed", message, extra));
    }
    let mutation = mutation(key, operation)?;
    let replay = mux
        .workspace_registry
        .lock()
        .unwrap_or_else(|poison| poison.into_inner())
        .replay_resource_patch(&mutation, operation, fingerprint)
        .map_err(|error| registry_error(operation, error))?;
    match replay {
        Some(replay) => mutation_result(mux, replay.result, replay.revision, true).map(Some),
        None => Ok(None),
    }
}

/// The checkpoint a create committed under `key` for this repository and
/// worktree, for key lookup.
pub(super) fn created(
    mux: &Mux,
    key: &str,
    identity: &Identity<'_>,
) -> Result<Option<String>, ResourceError> {
    const CREATE: &str = "git.checkpoint.create";
    let Some(stored) = committed(mux, key, "git.checkpoint.get")? else { return Ok(None) };
    let same = stored.operation == CREATE
        && stored.fingerprint["repository_id"] == identity.repository_id
        && stored.fingerprint["worktree_id"] == identity.worktree_id;
    Ok(same.then(|| stored.result["checkpoint_id"].as_str().map(str::to_string)).flatten())
}

/// Commits `value` as the mutation's result at a new resource revision and
/// returns the mutation reply; `replayed` marks a reply for a retry that
/// finished an earlier attempt.
#[allow(clippy::too_many_arguments)]
pub(super) fn commit(
    mux: &Arc<Mux>,
    actor: &cmux_local_auth::Actor,
    key: &str,
    operation: &'static str,
    fingerprint: &Value,
    value: &Value,
    replayed: bool,
) -> Result<Value, ResourceError> {
    let mutation = mutation(key, operation)?.with_actor(actor.clone());
    let mut registry = mux.workspace_registry.lock().unwrap_or_else(|poison| poison.into_inner());
    let commit = registry
        .commit_resource_patch(
            &mutation,
            operation,
            fingerprint,
            None,
            None,
            &ResourcePatch { changes: Vec::new() },
            value,
            &json!([]),
        )
        .map_err(|error| registry_error(operation, error))?;
    if !commit.replayed {
        mux.state.lock().unwrap_or_else(|poison| poison.into_inner()).resource_revision =
            commit.revision;
    }
    drop(registry);
    if !commit.replayed {
        mux.publish_resource_event();
    }
    mutation_result(mux, commit.result, commit.revision, replayed || commit.replayed)
}

fn mutation(key: &str, operation: &'static str) -> Result<WorkspaceMutation, ResourceError> {
    WorkspaceMutation::new(key, ORIGIN).map_err(|error| registry_error(operation, error))
}

/// A conflict stays a conflict; any other registry failure is
/// `store_failed`.
fn registry_error(operation: &'static str, error: anyhow::Error) -> ResourceError {
    let mapped = resource_operation_error(error);
    if mapped.code == "idempotency.conflict" {
        return mapped;
    }
    store_failed(operation, &mapped.message)
}

fn store_failed(operation: &str, message: &str) -> ResourceError {
    let message = format!("the session's mutation ledger failed: {message}");
    refused(operation, "store_failed", message, Value::Null)
}
