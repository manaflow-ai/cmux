//! The resource record of a commit, as the commit paths append it.
//!
//! A resource record states the public changes of one resource revision. Each upsert in it
//! carries the state fields that a fresh snapshot shows (`state/values.rs`), read in the commit's
//! transaction, and the record also takes the state changes that the transaction queued
//! (`state/closed_history_store.rs`). So the changes that the record states are not the changes
//! that the caller gave: [`journal_resource_record`] gives them back, for a caller that keeps a
//! copy of what the journal states (the public fold, `workspace_registry/public_fold.rs`) and
//! must not read the state rows a second time.

use rusqlite::Transaction;
use serde_json::Value;

use super::{append_resource_journal_record_at, unix_epoch_ms};
use crate::workspace_registry::ResourcePatch;

/// Append the resource record of `revision` with the state as it is now in `transaction`.
#[allow(clippy::too_many_arguments)]
pub(crate) fn append_resource_journal_record(
    transaction: &Transaction<'_>,
    revision: u64,
    previous_revision: u64,
    origin: &str,
    idempotency_key: &str,
    operation: &str,
    patch: Option<&ResourcePatch>,
    result: &Value,
    changes: &Value,
) -> anyhow::Result<()> {
    journal_resource_record(
        transaction,
        revision,
        previous_revision,
        origin,
        idempotency_key,
        operation,
        patch,
        result,
        changes,
    )?;
    Ok(())
}

/// [`append_resource_journal_record`], and gives the changes as the record states them: `changes`
/// with the state fields of each upsert and with the state changes that the transaction queued.
#[allow(clippy::too_many_arguments)]
pub(crate) fn journal_resource_record(
    transaction: &Transaction<'_>,
    revision: u64,
    previous_revision: u64,
    origin: &str,
    idempotency_key: &str,
    operation: &str,
    patch: Option<&ResourcePatch>,
    result: &Value,
    changes: &Value,
) -> anyhow::Result<Value> {
    append_resource_journal_record_at(
        transaction,
        revision,
        previous_revision,
        origin,
        idempotency_key,
        operation,
        patch,
        result,
        changes,
        unix_epoch_ms()?,
        true,
    )
}
