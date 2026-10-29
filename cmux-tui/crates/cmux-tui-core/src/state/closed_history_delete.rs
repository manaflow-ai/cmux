//! `closed.delete`: Delete Permanently and Clear Recently Closed
//! (plans/cmux-next/reopen-closed.md, S1b). A group, chosen members of a
//! group, every group, or every group closed at or after `since_ms` leave
//! the history for good: they cannot be reopened, and their terminal
//! archives go with them. Retention uses the same op: `before_ms` deletes
//! the groups closed before it and `keep_newest` every group but the newest
//! N, or both in one pass (the app is to apply `history.closed.maxAgeDays`
//! and `maxGroups` through them, like `history.commandRetentionDays`). The
//! resource and session journals keep what they already recorded (names,
//! screen output) until their own retention. The request's key records the
//! result, so a retry replays it.

use rusqlite::{Transaction, params};
use serde_json::Map;

use crate::mux::*;
use crate::panic_free::JsonFields;
use crate::state::closed_history_query::{closed_record, keep_members, remove_closed};
use crate::state::commit::{StateEffects, state_not_found};
use crate::state::prelude::*;
use crate::state::store::{StateChanges, StateCommit, state_delete, state_upsert};

const OPERATION: &str = "closed.delete";

/// What a `closed.delete` request names: exactly one of `closed` (with
/// optional `members`) or `all` (with optional `since_ms`, `before_ms` and
/// `keep_newest`).
#[derive(Default)]
pub(crate) struct DeleteRequest {
    pub(crate) closed: Option<String>,
    pub(crate) all: bool,
    pub(crate) members: Option<Vec<usize>>,
    pub(crate) since_ms: Option<i64>,
    pub(crate) before_ms: Option<i64>,
    pub(crate) keep_newest: Option<u32>,
}

impl DeleteRequest {
    /// The request a `closed.delete` call's fields name.
    pub(crate) fn from_fields(fields: &Map<String, Value>) -> Result<Self, ResourceError> {
        let decimal = |name: &'static str| match fields.get(name).and_then(Value::as_str) {
            Some(text) => text.parse::<i64>().map(Some).map_err(|_| {
                ResourceError::validation_invalid(None, format!("{name} must be a decimal"))
            }),
            None => Ok(None),
        };
        let members = match fields.get("members").and_then(Value::as_array) {
            Some(members) => Some(
                members
                    .iter()
                    .map(|member| {
                        member.as_u64().and_then(|m| usize::try_from(m).ok()).ok_or_else(|| {
                            ResourceError::validation_invalid(
                                Some("members"),
                                "members must be member indexes",
                            )
                        })
                    })
                    .collect::<Result<Vec<_>, _>>()?,
            ),
            None => None,
        };
        let keep_newest = match fields.get("keep_newest") {
            Some(keep) => Some(
                keep.as_u64()
                    .and_then(|keep| u32::try_from(keep).ok())
                    .filter(|keep| *keep >= 1)
                    .ok_or_else(|| {
                    ResourceError::validation_invalid(
                        Some("keep_newest"),
                        "keep_newest must be a whole number of at least 1",
                    )
                })?,
            ),
            None => None,
        };
        Ok(Self {
            closed: fields.get("closed").and_then(Value::as_str).map(str::to_string),
            all: fields.get("all").and_then(Value::as_bool).unwrap_or(false),
            members,
            since_ms: decimal("since_ms")?,
            before_ms: decimal("before_ms")?,
            keep_newest,
        })
    }

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
        anyhow::ensure!(self.before_ms.is_none() || self.all, "bad request: before_ms needs all");
        anyhow::ensure!(
            self.keep_newest.is_none() || self.all,
            "bad request: keep_newest needs all"
        );
        anyhow::ensure!(
            self.keep_newest.is_none() || self.since_ms.is_none(),
            "bad request: keep_newest cannot be combined with since_ms"
        );
        anyhow::ensure!(self.keep_newest != Some(0), "bad request: keep_newest must be at least 1");
        Ok(())
    }

    /// Members in order, once each: `[1, 0]` and `[0, 1]` are one request.
    fn fingerprint(&self) -> Value {
        let members = self.members.as_ref().map(|members| {
            let mut members = members.clone();
            members.sort_unstable();
            members.dedup();
            members
        });
        serde_json::json!({
            "operation": OPERATION,
            "closed": self.closed,
            "all": self.all,
            "members": members,
            "since_ms": self.since_ms,
            "before_ms": self.before_ms,
            "keep_newest": self.keep_newest,
        })
    }
}

/// Deleted and partly deleted group ids, and their public changes.
#[derive(Default)]
struct Deleted {
    deleted: Vec<String>,
    updated: Vec<String>,
    changes: Vec<Value>,
    /// Workspace keys of the deleted workspace members (their agent-home folders go).
    keys: Vec<String>,
}

/// The groups an `all` request deletes: those closed at or after `since_ms`
/// and before `before_ms` (newest first), then, with `keep_newest`, the rest
/// of every group but the newest N. With neither bound nor `keep_newest`:
/// every group.
fn groups_to_clear(
    transaction: &Transaction<'_>,
    request: &DeleteRequest,
) -> anyhow::Result<Vec<String>> {
    let mut ids = Vec::new();
    if request.keep_newest.is_none() || request.before_ms.is_some() {
        let mut statement = transaction.prepare(
            "SELECT closed_id FROM closed_groups WHERE closed_at_ms >= ?1 AND closed_at_ms < ?2
             ORDER BY seq DESC",
        )?;
        ids = statement
            .query_map(
                params![request.since_ms.unwrap_or(0), request.before_ms.unwrap_or(i64::MAX)],
                |row| row.get::<_, String>(0),
            )?
            .collect::<Result<Vec<_>, _>>()?;
    }
    if let Some(keep) = request.keep_newest {
        let mut statement = transaction
            .prepare("SELECT closed_id FROM closed_groups ORDER BY seq DESC LIMIT -1 OFFSET ?1")?;
        let excess = statement
            .query_map(params![i64::from(keep)], |row| row.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?;
        for id in excess {
            if !ids.contains(&id) {
                ids.push(id);
            }
        }
    }
    Ok(ids)
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
    let all = record.field("members").as_array().cloned().unwrap_or_default();
    let removed = match members {
        None => all.clone(),
        Some(chosen) => all
            .iter()
            .enumerate()
            .filter(|(index, _)| chosen.contains(index))
            .map(|(_, member)| member.clone())
            .collect(),
    };
    out.keys.extend(super::agent_home_moves::member_keys(&removed));
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
    // Deleting the last members of a deleted space or workspace group keeps
    // its restore record (a valid zero-member group); only deleting the group
    // itself removes it.
    let restores_container =
        ["room", "group"].iter().any(|key| record.get(*key).is_some_and(Value::is_object));
    if keep.is_empty() && !(members.is_some() && restores_container) {
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
    keys: &std::sync::Mutex<Vec<String>>,
) -> anyhow::Result<StateChanges> {
    let mut out = Deleted::default();
    match &request.closed {
        Some(closed_id) => {
            delete_one(transaction, closed_id, request.members.as_deref(), &mut out)?;
        }
        None => {
            for closed_id in groups_to_clear(transaction, request)? {
                delete_one(transaction, &closed_id, None, &mut out)?;
            }
        }
    }
    *keys.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = out.keys;
    Ok(StateChanges::new(
        serde_json::json!({"deleted": out.deleted, "updated": out.updated}),
        out.changes,
    ))
}

impl Mux {
    #[track_caller]
    pub(crate) fn state_delete_closed(
        self: &Arc<Self>,
        mutation: &WorkspaceMutation,
        expected_revision: Option<u64>,
        request: &DeleteRequest,
    ) -> anyhow::Result<StateCommit> {
        request.validate()?;
        // Serialized with closed.reopen: a delete between a reopen's group
        // read and its commit would fail that reopen after its tabs exist.
        let _serial =
            super::closed_history::REOPEN.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let fingerprint = request.fingerprint();
        if let Some(replay) = self
            .workspace_registry
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .replay_resource_patch(mutation, OPERATION, &fingerprint)?
        {
            return Ok(replay.into());
        }
        let keys = std::sync::Mutex::new(Vec::new());
        let commit = self.commit_state(
            mutation,
            OPERATION,
            &fingerprint,
            expected_revision,
            StateEffects::EVENTS_ONLY,
            |transaction, _| delete_in(transaction, request, &keys),
        )?;
        // The deleted workspaces' agent-home folders go to the app's Trash
        // (never one a live workspace uses).
        let keys = keys.into_inner().unwrap_or_else(std::sync::PoisonError::into_inner);
        if !keys.is_empty() {
            let live = |key: &str| {
                self.with_state(|state| {
                    state.workspaces.iter().any(|workspace| workspace.key == key)
                })
            };
            super::agent_home_moves::retire(&keys, &live);
        }
        Ok(commit)
    }
}
