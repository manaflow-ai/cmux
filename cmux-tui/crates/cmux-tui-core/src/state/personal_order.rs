//! `personal-mixed-order-v1`: the personal sidebar order as clients show it,
//! and the personal row every new workspace of this session gets in the
//! commit that creates it.
//!
//! Sidebar order: the personal workspace rows by position; a group shows
//! right before the row at its `top_index` (a group before a workspace on
//! the same slot), with its members in position order; groups without a
//! slot (or past the last row) follow every loose workspace, in group
//! order. Rows whose group no longer exists count as loose.

use std::collections::HashSet;

use rusqlite::{Connection, OptionalExtension, Transaction, params};

use super::values::{local_registry_id, workspace_public_id_for_key};
use crate::workspace_registry::personal_store::{
    bump_personal_revision, next_workspace_position, read_groups, read_workspaces,
};
use crate::workspace_registry::{ResourceChange, ResourcePatch};

/// Advertises `workspace_group.update {top_index}`, `top_index` on group
/// snapshots, `workspace.list {order}` and the create-time personal row.
pub(crate) const PERSONAL_MIXED_ORDER_CAPABILITY: &str = "personal-mixed-order-v1";

/// The live public ids of this session's workspaces in the personal sidebar
/// order. Workspaces without a personal row are not listed.
pub(crate) fn sidebar_workspace_ids(connection: &Connection) -> anyhow::Result<Vec<String>> {
    let local = local_registry_id(connection)?;
    let rows = read_workspaces(connection)?;
    let groups = read_groups(connection)?;
    let known = groups.iter().map(|group| group.id.as_str()).collect::<HashSet<_>>();
    let mut order = Vec::with_capacity(rows.len());
    let members = |group: &str, order: &mut Vec<usize>| {
        order.extend(
            rows.iter()
                .enumerate()
                .filter(|(_, row)| row.group.as_deref() == Some(group))
                .map(|(index, _)| index),
        );
    };
    for (index, row) in rows.iter().enumerate() {
        for group in groups.iter().filter(|group| group.top_index == Some(index)) {
            members(&group.id, &mut order);
        }
        if row.group.as_deref().is_none_or(|group| !known.contains(group)) {
            order.push(index);
        }
    }
    for group in groups.iter().filter(|group| group.top_index.is_none_or(|top| top >= rows.len())) {
        members(&group.id, &mut order);
    }
    let mut ids = Vec::with_capacity(order.len());
    for index in order {
        let row = &rows[index];
        if row.session_id == local
            && let Some(id) = workspace_public_id_for_key(connection, &row.workspace_key)?
        {
            ids.push(id);
        }
    }
    Ok(ids)
}

/// The keys of the workspaces `patch` creates (no live resource row yet).
/// Read before the patch applies.
pub(crate) fn created_workspaces(
    transaction: &Transaction<'_>,
    patch: &ResourcePatch,
) -> anyhow::Result<Vec<String>> {
    let mut created = Vec::new();
    for change in &patch.changes {
        if let ResourceChange::UpsertWorkspace { workspace, .. } = change {
            let live = transaction
                .query_row(
                    "SELECT 1 FROM resource_workspaces
                     WHERE public_id = ?1 AND deleted_revision IS NULL",
                    [workspace.public_id.as_str()],
                    |_| Ok(()),
                )
                .optional()?
                .is_some();
            if !live {
                created.push(workspace.key.clone());
            }
        }
    }
    Ok(created)
}

/// Give each created workspace its personal row, last and ungrouped,
/// unless it already has one (a reopened workspace keeps its old place).
/// The row is part of the creation's fact, so it writes no personal journal
/// record of its own (one record per commit); it bumps `personal_revision`,
/// and the placement change joins the creating commit's `session.events`
/// batch so clients that rebuild from events see it.
pub(crate) fn place_created_workspaces(
    transaction: &Transaction<'_>,
    keys: &[String],
) -> anyhow::Result<()> {
    if keys.is_empty() || !super::store::state_tables_ready(transaction)? {
        return Ok(());
    }
    let local = local_registry_id(transaction)?;
    let rows = read_workspaces(transaction)?;
    let mut placed = false;
    for key in keys {
        if rows.iter().any(|row| row.session_id == local && row.workspace_key == *key) {
            continue;
        }
        transaction.execute(
            "INSERT INTO personal_workspaces(session_id, workspace_key, position)
             VALUES(?1, ?2, ?3)",
            params![local, key, next_workspace_position(transaction)?],
        )?;
        placed = true;
        let placement = super::personal_state_store::placement_snapshot(transaction, &local, key)?;
        let id = super::personal_state_store::placement_id(&local, key);
        let change = super::store::state_upsert("workspace_placement", &id, placement);
        super::closed_history_store::queue_change(transaction, &change)?;
    }
    if placed {
        bump_personal_revision(transaction)?;
    }
    Ok(())
}
