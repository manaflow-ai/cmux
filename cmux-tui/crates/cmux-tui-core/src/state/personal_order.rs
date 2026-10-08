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
use serde_json::Value;

use super::values::{local_registry_id, workspace_public_id_for_key};
use crate::user_settings::NewWorkspacePlacement;
use crate::workspace_registry::personal_store::{
    PersonalGroup, bump_personal_revision, next_workspace_position, read_groups, read_pins,
    read_workspaces,
};
use crate::workspace_registry::{ResourceChange, ResourcePatch, WorkspaceRegistry};

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

/// The workspaces a patch creates, read before it applies.
pub(crate) struct CreatedWorkspaces {
    /// Their keys (no live resource row yet), in patch order.
    keys: Vec<String>,
    /// The key of the session's active workspace before the patch: the
    /// "current" workspace of `workspaces.newPlacement = afterCurrent`.
    current: Option<String>,
}

/// The workspaces `patch` creates (no live resource row yet). Read before
/// the patch applies.
pub(crate) fn created_workspaces(
    transaction: &Transaction<'_>,
    patch: &ResourcePatch,
) -> anyhow::Result<CreatedWorkspaces> {
    let mut keys = Vec::new();
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
                keys.push(workspace.key.clone());
            }
        }
    }
    let current = if keys.is_empty() {
        None
    } else {
        match crate::workspace_registry::meta_value(transaction, "active_workspace_id")? {
            Some(id) => transaction
                .query_row(
                    "SELECT workspace_key FROM resource_workspaces
                     WHERE public_id = ?1 AND deleted_revision IS NULL",
                    [id.as_str()],
                    |row| row.get::<_, String>(0),
                )
                .optional()?,
            None => None,
        }
    };
    Ok(CreatedWorkspaces { keys, current })
}

/// Give each created workspace its personal row, unless it already has one
/// (a reopened workspace keeps its old place), at the place cmux.json
/// `workspaces.newPlacement` names (`NewWorkspacePlacement`; default top),
/// so a workspace made by any client (the app, iOS, the TUI, the CLI, an
/// agent) lands in the same place. A caller that wants another place moves
/// it after the creation (`workspace.place`, `set-personal-workspace`);
/// that later write wins.
///
/// The row is part of the creation's fact, so it writes no personal journal
/// record of its own (one record per commit); it bumps `personal_revision`,
/// and the placement changes join the creating commit's `session.events`
/// batch so clients that rebuild from events see them.
pub(crate) fn place_created_workspaces(
    transaction: &Transaction<'_>,
    created: &CreatedWorkspaces,
) -> anyhow::Result<()> {
    if created.keys.is_empty() {
        return Ok(());
    }
    place_created_workspaces_at(transaction, created, NewWorkspacePlacement::current())
}

pub(crate) fn place_created_workspaces_at(
    transaction: &Transaction<'_>,
    created: &CreatedWorkspaces,
    placement: NewWorkspacePlacement,
) -> anyhow::Result<()> {
    if created.keys.is_empty() || !super::store::state_tables_ready(transaction)? {
        return Ok(());
    }
    let local = local_registry_id(transaction)?;
    let has_row = |key: &str| -> anyhow::Result<bool> {
        Ok(read_workspaces(transaction)?
            .iter()
            .any(|row| row.session_id == local && row.workspace_key == key))
    };
    let mut placed = Vec::new();
    for key in &created.keys {
        if has_row(key)? {
            continue;
        }
        transaction.execute(
            "INSERT INTO personal_workspaces(session_id, workspace_key, position)
             VALUES(?1, ?2, ?3)",
            params![local, key, next_workspace_position(transaction)?],
        )?;
        placed.push(key.clone());
    }
    if placed.is_empty() {
        return Ok(());
    }
    bump_personal_revision(transaction)?;
    // The slot of the first new row; the others follow it in creation order.
    let slot = match placement {
        NewWorkspacePlacement::Bottom => None,
        NewWorkspacePlacement::Top => Some(top_slot(transaction, &local, &placed)?),
        NewWorkspacePlacement::AfterCurrent => {
            match after_current_slot(transaction, &local, &placed, created.current.as_deref())? {
                Some(slot) => Some(slot),
                None => Some(top_slot(transaction, &local, &placed)?),
            }
        }
    };
    let Some((index, group)) = slot else {
        // Appended last: only the new rows changed.
        for key in &placed {
            queue_placement(transaction, &local, key)?;
        }
        return Ok(());
    };
    let groups_before = read_groups(transaction)?;
    for (offset, key) in placed.iter().enumerate() {
        WorkspaceRegistry::move_personal_row_in(transaction, &local, key, index + offset)?;
        if group.is_some() {
            transaction.execute(
                "UPDATE personal_workspaces SET group_id = ?3
                 WHERE session_id = ?1 AND workspace_key = ?2",
                params![local, key, group],
            )?;
        }
    }
    // The new rows and every row after them moved, and group slots after
    // them: clients that rebuild from events get each of those.
    let moved =
        |change: &Value| change["value"]["index"].as_u64().is_some_and(|row| row >= index as u64);
    for change in super::personal::all_placements(transaction)?.into_iter().filter(moved) {
        super::closed_history_store::queue_change(transaction, &change)?;
    }
    let slots = read_groups(transaction)?;
    for change in super::personal::all_groups(transaction)?.into_iter().filter(|change| {
        let id = change["id"].as_str();
        let slot = |groups: &[PersonalGroup]| {
            groups.iter().find(|group| Some(group.id.as_str()) == id).map(|group| group.top_index)
        };
        slot(&groups_before) != slot(&slots)
    }) {
        super::closed_history_store::queue_change(transaction, &change)?;
    }
    Ok(())
}

fn queue_placement(transaction: &Transaction<'_>, local: &str, key: &str) -> anyhow::Result<()> {
    let placement = super::personal_state_store::placement_snapshot(transaction, local, key)?;
    let id = super::personal_state_store::placement_id(local, key);
    let change = super::store::state_upsert("workspace_placement", &id, placement);
    super::closed_history_store::queue_change(transaction, &change)
}

/// `top`: right after this session's home row (Home stays first), else
/// first; loose, so above every group placed at that slot.
fn top_slot(
    transaction: &Transaction<'_>,
    local: &str,
    placed: &[String],
) -> anyhow::Result<(usize, Option<String>)> {
    let Some((_, home)) = super::home_store::live_home(transaction)? else {
        return Ok((0, None));
    };
    let index = others(transaction, placed)?
        .iter()
        .position(|(session, key)| session == local && *key == home)
        .map_or(0, |home| home + 1);
    Ok((index, None))
}

/// `afterCurrent`: right after the current workspace's row, in its group.
/// None when there is no current workspace, it has no row, or it is the
/// home workspace.
fn after_current_slot(
    transaction: &Transaction<'_>,
    local: &str,
    placed: &[String],
    current: Option<&str>,
) -> anyhow::Result<Option<(usize, Option<String>)>> {
    let Some(current) = current.filter(|current| !placed.iter().any(|key| key == current)) else {
        return Ok(None);
    };
    if super::home_store::live_home(transaction)?.is_some_and(|(_, home)| home == current) {
        return Ok(None);
    }
    let rows = read_workspaces(transaction)?
        .into_iter()
        .filter(|row| !(row.session_id == local && placed.contains(&row.workspace_key)))
        .collect::<Vec<_>>();
    let Some(index) =
        rows.iter().position(|row| row.session_id == local && row.workspace_key == current)
    else {
        return Ok(None);
    };
    let Some(group) = rows[index].group.clone() else { return Ok(Some((index + 1, None))) };
    // Into the group only when the new workspace shows in the group's room:
    // a workspace pinned to another room (the app pins before it creates)
    // goes to the top instead.
    let room = read_groups(transaction)?.into_iter().find(|candidate| candidate.id == group);
    let pins = read_pins(transaction)?;
    let elsewhere = placed.iter().any(|key| {
        pins.iter().any(|pin| {
            pin.session_id == local
                && pin.workspace_key == *key
                && room.as_ref().is_some_and(|room| room.profile != pin.profile)
        })
    });
    Ok((!elsewhere).then_some((index + 1, Some(group))))
}

/// The personal rows other than `placed`, as `(session, key)` in order.
fn others(
    transaction: &Transaction<'_>,
    placed: &[String],
) -> anyhow::Result<Vec<(String, String)>> {
    let local = local_registry_id(transaction)?;
    Ok(read_workspaces(transaction)?
        .into_iter()
        .filter(|row| !(row.session_id == local && placed.contains(&row.workspace_key)))
        .map(|row| (row.session_id, row.workspace_key))
        .collect())
}
