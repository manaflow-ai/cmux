//! `window_record.put` and `window_record.delete`: compare-and-swap writes
//! of one window record (see `window_record_store` for the ownership and
//! migration rules).

use serde_json::json;

use crate::mux::*;
use crate::state::commit::StateEffects;
use crate::state::prelude::*;
use crate::state::store::{StateChanges, StateCommit, state_delete, state_upsert};
use crate::state::window_record_store::{
    self as store, MAX_RECORD_BYTES, PLACEHOLDER_INSTALL_ID, RESOURCE, record_id,
};

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

impl Mux {
    /// Put or delete the record `(install_id, window_id)`. `expected` is the
    /// record's own revision (0 = the record must not exist); a mismatch is
    /// `revision.conflict` and writes nothing.
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
        let fingerprint = match &change {
            WindowRecordChange::Put { record } => json!({
                "operation": operation,
                "install_id": install_id,
                "window_id": window_id,
                "expected_revision": expected,
                "record": record,
            }),
            WindowRecordChange::Delete => json!({
                "operation": operation,
                "install_id": install_id,
                "window_id": window_id,
                "expected_revision": expected,
            }),
        };
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
        self.commit_state(
            mutation,
            operation,
            &fingerprint,
            None,
            StateEffects::EVENTS_ONLY,
            |transaction, _| {
                let id = record_id(install_id, window_id);
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
                        Ok(StateChanges::new(snapshot, changes))
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
                        Ok(StateChanges::new(
                            json!({"id": id, "revision": current.revision.to_string()}),
                            vec![state_delete(RESOURCE, &id)],
                        ))
                    }
                }
            },
        )
    }
}
