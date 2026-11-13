//! `window_record.put` and `window_record.delete`: compare-and-swap writes
//! of one window record (see `window_record_store` for the ownership and
//! migration rules).
//!
//! # What a put stores
//!
//! The app puts a window's whole record on every change, and the record
//! lists every workspace of the window (33 KB for 824 workspaces). A put
//! stores that record twice: the `window_records` row, and the `value` of
//! its `state_upsert` change in the journal record, which is what every
//! reader of `session.events`, the journal and a checkpoint replays. Nothing
//! else holds it:
//!
//! - The idempotency fingerprint names the record by the SHA-256 of its
//!   canonical JSON, not by value.
//! - The committed result (the ledger row's `result_json` and the journal
//!   payload's `result`) is `{id, revision}`. The answer to the caller is
//!   the record's snapshot, as before; a retry under the same key gets the
//!   same answer, read from the `state_upsert` change of the journal record
//!   the put committed ([`journaled_put`]).
//! - A put whose record equals the stored one commits nothing
//!   ([`StateChanges::unchanged`]): it answers the stored snapshot at its
//!   revision. `expected_revision` is still checked first.
//!
//! Rows of an older daemon stay readable: a retry of a put it committed has
//! the old fingerprint (the whole record) and a whole snapshot as its stored
//! result, and gets that result ([`legacy_put_fingerprint`]).

use serde_json::json;
use sha2::{Digest, Sha256};

use crate::mux::*;
use crate::state::closed_history_store as closed;
use crate::state::commit::StateEffects;
use crate::state::prelude::*;
use crate::state::store::{StateChanges, StateCommit, state_delete, state_upsert};
use crate::state::window_record_store::{
    self as store, MAX_RECORD_BYTES, PLACEHOLDER_INSTALL_ID, RESOURCE, record_id,
};
use crate::workspace_registry::canonical_json;
use crate::workspace_registry::resource_store::query_resource_event_changes_at;

/// Whether a window record says its window is open (`open`, default true).
fn is_open(record: &Value) -> bool {
    record.get("open").and_then(Value::as_bool) != Some(false)
}

/// Closed history of a put (reopen-closed.md 4): a window that was open and
/// now is not becomes a `window` group; a window that is open again (or
/// first written open) drops its window groups. A first put of a closed
/// window records nothing (the app restored it closed).
fn window_close_changes(
    transaction: &rusqlite::Transaction<'_>,
    id: &str,
    current: Option<&store::StoredRecord>,
    record_json: &str,
) -> anyhow::Result<Vec<Value>> {
    let record: Value = serde_json::from_str(record_json)?;
    if is_open(&record) {
        return closed::remove_window_groups(transaction, id);
    }
    let was_open = current.is_some_and(|current| is_open(&current.snapshot["record"]));
    if !was_open {
        return Ok(Vec::new());
    }
    let name = match record.get("workspace_key").and_then(Value::as_str) {
        Some(key) => closed::workspace_name(transaction, key)?,
        None => None,
    };
    let keys = record
        .get("workspace_key")
        .into_iter()
        .chain(record.get("workspace_keys").and_then(Value::as_array).into_iter().flatten())
        .filter_map(Value::as_str)
        .map(str::to_string)
        .collect::<Vec<_>>();
    Ok(closed::insert_window_group(transaction, id, name, &keys)?.into_iter().collect())
}

/// One write of a window record.
pub(crate) enum WindowRecordChange {
    Put { record: Value },
    Delete,
}

/// A record revision precondition that failed: `expected` (0 = absent) is
/// not the stored revision.
fn record_conflict(id: &str, expected: u64, current: u64) -> anyhow::Error {
    anyhow::Error::new(ResourceError::new(
        "revision.conflict",
        format!("window record {id} is at revision {current}"),
        json!({
            "expected": expected.to_string(),
            "actual": current.to_string(),
        }),
        true,
    ))
}

/// The idempotency fingerprint of a put as daemons wrote it before the
/// record was named by its hash: it carries the whole record.
fn legacy_put_fingerprint(
    operation: &str,
    install_id: &str,
    window_id: &str,
    expected: Option<u64>,
    record: &Value,
) -> Value {
    json!({
        "operation": operation,
        "install_id": install_id,
        "window_id": window_id,
        "expected_revision": expected,
        "record": record,
    })
}

/// The snapshot the put committed at resource revision `revision` answered:
/// the value of its `state_upsert` change of record `id` in the journal.
fn journaled_put(
    connection: &rusqlite::Connection,
    revision: u64,
    id: &str,
) -> anyhow::Result<Value> {
    let changes = query_resource_event_changes_at(connection, revision)?;
    changes
        .as_ref()
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .find(|change| {
            change["kind"] == "state_upsert" && change["resource"] == RESOURCE && change["id"] == id
        })
        .map(|change| change["value"].clone())
        .with_context(|| {
            format!("the journal has no put of window record {id} at revision {revision}")
        })
}

impl Mux {
    /// Put or delete the record `(install_id, window_id)`. `expected` is the
    /// record's own revision (0 = the record must not exist); a mismatch is
    /// `revision.conflict` and writes nothing. A put answers the record's
    /// snapshot; one equal to the stored record writes nothing (module docs).
    pub(crate) fn state_window_record(
        &self,
        mutation: &WorkspaceMutation,
        operation: &str,
        install_id: &str,
        window_id: &str,
        expected: Option<u64>,
        change: WindowRecordChange,
    ) -> anyhow::Result<StateCommit> {
        store::validate_key("install_id", install_id)?;
        store::validate_key("window_id", window_id)?;
        let record_json = match &change {
            WindowRecordChange::Put { record } => {
                anyhow::ensure!(
                    install_id != PLACEHOLDER_INSTALL_ID,
                    "bad request: install_id {PLACEHOLDER_INSTALL_ID} is reserved for unadopted records"
                );
                anyhow::ensure!(record.is_object(), "bad request: record must be an object");
                let json = serde_json::to_string(record)?;
                anyhow::ensure!(
                    json.len() <= MAX_RECORD_BYTES,
                    "bad request: record exceeds {MAX_RECORD_BYTES} bytes"
                );
                Some(json)
            }
            WindowRecordChange::Delete => None,
        };
        let put_record = match &change {
            WindowRecordChange::Put { record } => Some(record),
            WindowRecordChange::Delete => None,
        };
        let fingerprint = match put_record {
            Some(record) => {
                let record_sha256 =
                    format!("{:x}", Sha256::digest(canonical_json(record)?.as_bytes()));
                json!({
                    "operation": operation,
                    "install_id": install_id,
                    "window_id": window_id,
                    "expected_revision": expected,
                    "record_sha256": record_sha256,
                })
            }
            None => json!({
                "operation": operation,
                "install_id": install_id,
                "window_id": window_id,
                "expected_revision": expected,
            }),
        };
        let id = record_id(install_id, window_id);
        // The snapshot a put wrote: the answer of a put that committed.
        let written = std::cell::Cell::new(None::<Value>);
        let commit = self.commit_state(
            mutation,
            operation,
            &fingerprint,
            None,
            StateEffects::EVENTS_ONLY,
            |transaction, _| {
                let current = store::record(transaction, install_id, window_id)?;
                match record_json {
                    Some(record_json) => {
                        // A first put of a migrated window adopts the
                        // placeholder record: its revision continues.
                        let adopted = match current {
                            Some(_) => None,
                            None => store::record(transaction, PLACEHOLDER_INSTALL_ID, window_id)?,
                        };
                        let current_revision = current
                            .as_ref()
                            .or(adopted.as_ref())
                            .map_or(0, |record| record.revision);
                        if let Some(expected) = expected
                            && expected != current_revision
                        {
                            return Err(record_conflict(&id, expected, current_revision));
                        }
                        if let Some(current) = &current
                            && Some(&current.snapshot["record"]) == put_record
                        {
                            // The stored record is the one put: no row, no
                            // revision, no journal record.
                            return Ok(StateChanges::unchanged(current.snapshot.clone()));
                        }
                        let mut changes = Vec::new();
                        if adopted.is_some() {
                            store::delete_record(transaction, PLACEHOLDER_INSTALL_ID, window_id)?;
                            changes.push(state_delete(
                                RESOURCE,
                                &record_id(PLACEHOLDER_INSTALL_ID, window_id),
                            ));
                        }
                        let snapshot = store::write_record(
                            transaction,
                            install_id,
                            window_id,
                            current_revision + 1,
                            &record_json,
                            now_ms(),
                        )?;
                        changes.push(state_upsert(RESOURCE, &id, snapshot.clone()));
                        changes.extend(window_close_changes(
                            transaction,
                            &id,
                            current.as_ref(),
                            &record_json,
                        )?);
                        // The record is stored once more only, in the
                        // change above: the committed result names it.
                        let result = json!({"id": id, "revision": snapshot["revision"]});
                        written.set(Some(snapshot));
                        Ok(StateChanges::new(result, changes))
                    }
                    None => {
                        let Some(current) = current else {
                            return Err(crate::state::commit::state_not_found(RESOURCE, &id));
                        };
                        if let Some(expected) = expected
                            && expected != current.revision
                        {
                            return Err(record_conflict(&id, expected, current.revision));
                        }
                        store::delete_record(transaction, install_id, window_id)?;
                        // A window that is gone cannot be reopened.
                        let mut changes = vec![state_delete(RESOURCE, &id)];
                        changes.extend(closed::remove_window_groups(transaction, &id)?);
                        Ok(StateChanges::new(
                            json!({"id": id, "revision": current.revision.to_string()}),
                            changes,
                        ))
                    }
                }
            },
        );
        let Some(record) = put_record else { return commit };
        let mut commit = match commit {
            Ok(commit) => commit,
            // A retry of a put an older daemon committed: its ledger row has
            // the fingerprint that carries the record.
            Err(error) if error.to_string().starts_with("idempotency.conflict") => {
                let legacy =
                    legacy_put_fingerprint(operation, install_id, window_id, expected, record);
                match self.state_commit_replay(mutation, operation, &legacy, None) {
                    Ok(Some(replayed)) => replayed,
                    _ => return Err(error),
                }
            }
            Err(error) => return Err(error),
        };
        if let Some(snapshot) = written.take() {
            commit.result = snapshot;
        } else if commit.replayed && commit.result.get("record").is_none() {
            commit.result = self.read_registry_state(|connection| {
                journaled_put(connection, commit.revision, &id)
            })?;
        }
        Ok(commit)
    }
}
