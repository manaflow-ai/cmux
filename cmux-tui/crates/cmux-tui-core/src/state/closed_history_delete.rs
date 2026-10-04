//! `closed.delete`: Delete Permanently and Clear Recently Closed
//! (plans/cmux-next/reopen-closed.md, S1b). A group, chosen members of a
//! group, every group, or every group closed at or after `since_ms` leave
//! the history for good. The request's key records the result, so a retry
//! replays it.

use rusqlite::{Transaction, params};

use crate::mux::*;
use crate::state::closed_history_query::{closed_record, keep_members, remove_closed};
use crate::state::commit::{StateEffects, state_not_found};
use crate::state::prelude::*;
use crate::state::store::{StateChanges, StateCommit, state_delete, state_upsert};

const OPERATION: &str = "closed.delete";

/// What a `closed.delete` request names: exactly one of `closed` (with
/// optional `members`) or `all` (with optional `since_ms`).
#[derive(Default)]
pub(crate) struct DeleteRequest {
    pub(crate) closed: Option<String>,
    pub(crate) all: bool,
    pub(crate) members: Option<Vec<usize>>,
    pub(crate) since_ms: Option<i64>,
}

impl DeleteRequest {
    fn validate(&self) -> anyhow::Result<()> {
        anyhow::ensure!(
            self.closed.is_some() != self.all,
            "bad request: name exactly one of closed or all"
        );
        anyhow::ensure!(
            self.members.is_none() || self.closed.is_some(),
            "bad request: members needs closed"
        );
        anyhow::ensure!(self.since_ms.is_none() || self.all, "bad request: since_ms needs all");
        Ok(())
    }

    fn fingerprint(&self) -> Value {
        serde_json::json!({
            "operation": OPERATION,
            "closed": self.closed,
            "all": self.all,
            "members": self.members,
            "since_ms": self.since_ms,
        })
    }
}

/// Deleted and partly deleted group ids, and their public changes.
#[derive(Default)]
struct Deleted {
    deleted: Vec<String>,
    updated: Vec<String>,
    changes: Vec<Value>,
}

/// Every group closed at or after `since_ms` (None: every group).
fn groups_since(
    transaction: &Transaction<'_>,
    since_ms: Option<i64>,
) -> anyhow::Result<Vec<String>> {
    let mut statement = transaction.prepare(
        "SELECT closed_id FROM closed_groups WHERE closed_at_ms >= ?1 ORDER BY seq DESC",
    )?;
    Ok(statement
        .query_map(params![since_ms.unwrap_or(0)], |row| row.get::<_, String>(0))?
        .collect::<Result<Vec<_>, _>>()?)
}

/// Delete `members` (indexes) of one group, or the whole group.
fn delete_one(
    transaction: &Transaction<'_>,
    closed_id: &str,
    members: Option<&[usize]>,
    out: &mut Deleted,
) -> anyhow::Result<()> {
    let record = closed_record(transaction, closed_id)?
        .ok_or_else(|| state_not_found("closed", closed_id))?;
    let all = record["members"].as_array().cloned().unwrap_or_default();
    let keep = match members {
        None => Vec::new(),
        Some(chosen) => {
            if let Some(bad) = chosen.iter().find(|index| **index >= all.len()) {
                anyhow::bail!(
                    "bad request: member {bad} is out of range (the group has {})",
                    all.len()
                );
            }
            all.into_iter()
                .enumerate()
                .filter(|(index, _)| !chosen.contains(index))
                .map(|(_, member)| member)
                .collect()
        }
    };
    if keep.is_empty() {
        remove_closed(transaction, closed_id)?;
        out.deleted.push(closed_id.to_string());
        out.changes.push(state_delete("closed", closed_id));
    } else {
        let item = keep_members(transaction, closed_id, record, keep)?;
        out.updated.push(closed_id.to_string());
        out.changes.push(state_upsert("closed", closed_id, item));
    }
    Ok(())
}

fn delete_in(
    transaction: &Transaction<'_>,
    request: &DeleteRequest,
) -> anyhow::Result<StateChanges> {
    let mut out = Deleted::default();
    match &request.closed {
        Some(closed_id) => {
            delete_one(transaction, closed_id, request.members.as_deref(), &mut out)?
        }
        None => {
            for closed_id in groups_since(transaction, request.since_ms)? {
                delete_one(transaction, &closed_id, None, &mut out)?;
            }
        }
    }
    Ok(StateChanges::new(
        serde_json::json!({"deleted": out.deleted, "updated": out.updated}),
        out.changes,
    ))
}

impl Mux {
    pub(crate) fn state_delete_closed(
        self: &Arc<Self>,
        mutation: &WorkspaceMutation,
        expected_revision: Option<u64>,
        request: &DeleteRequest,
    ) -> anyhow::Result<StateCommit> {
        request.validate()?;
        let fingerprint = request.fingerprint();
        if let Some(replay) = self.workspace_registry.lock().unwrap().replay_resource_patch(
            mutation,
            OPERATION,
            &fingerprint,
        )? {
            return Ok(replay.into());
        }
        self.commit_state(
            mutation,
            OPERATION,
            &fingerprint,
            expected_revision,
            StateEffects::EVENTS_ONLY,
            |transaction, _| delete_in(transaction, request),
        )
    }
}
