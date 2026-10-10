//! History mutations in the session's mutation ledger: a retry with the
//! same idempotency key answers the first result (the same restore id)
//! and deletes nothing again; the same key with other input is
//! `idempotency.conflict`.

use std::sync::Arc;

use rusqlite::OptionalExtension;
use serde_json::{Value, json};

use crate::Mux;
use crate::resource::ResourceError;
use crate::resource_router::{mutation_result, resource_operation_error};
use crate::workspace_registry::{ResourcePatch, WorkspaceMutation};

const ORIGIN: &str = "resource-api";

/// The operation and its normalized fields.
pub(super) fn fingerprint(operation: &str, fields: &serde_json::Map<String, Value>) -> Value {
    json!({"operation": operation, "fields": fields})
}

fn store_failed(operation: &str, message: &str) -> ResourceError {
    ResourceError::operation_failed(
        operation,
        format!("the session's mutation ledger failed: {message}"),
        json!({}),
    )
}

fn registry_error(operation: &str, error: anyhow::Error) -> ResourceError {
    let mapped = resource_operation_error(error);
    if mapped.code == "idempotency.conflict" {
        return mapped;
    }
    store_failed(operation, &mapped.message)
}

/// Whether `key` was committed before (then [`commit`] replays it or
/// refuses other input, without running the operation again).
pub(super) fn seen(mux: &Mux, key: &str, operation: &str) -> Result<bool, ResourceError> {
    let registry = mux.workspace_registry.lock().unwrap_or_else(|poison| poison.into_inner());
    registry
        .connection
        .query_row("SELECT 1 FROM resource_mutations WHERE idempotency_key = ?1", [key], |_| Ok(()))
        .optional()
        .map(|row| row.is_some())
        .map_err(|error| store_failed(operation, &error.to_string()))
}

/// Records `value` as the result of `key` and answers the mutation result
/// (the first result when `key` was committed before).
pub(super) fn commit(
    mux: &Arc<Mux>,
    key: &str,
    operation: &str,
    fingerprint: &Value,
    value: &Value,
    actor: &crate::workspace_registry::Actor,
) -> Result<Value, ResourceError> {
    let mutation = WorkspaceMutation::new(key, ORIGIN, actor.clone())
        .map_err(|e| registry_error(operation, e))?;
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
    mutation_result(mux, commit.result, commit.revision, commit.replayed)
}
