//! `personal-mixed-order-v1`: the personal sidebar order as clients show it,
//! and the personal row every new workspace of this session gets in the
//! commit that creates it.
//!
//! Sidebar order: the personal workspace rows by position; a group shows
//! right before the row at its `top_index` (a group before a workspace on
//! the same slot), with its members in position order; groups without a
//! slot (or past the last row) follow every loose workspace, in group
//! order. Rows whose group no longer exists count as loose.

use std::cell::RefCell;
use std::collections::HashSet;

use cmux_layout_reducer::sidebar_doc::{WorkspaceRef, machine_section_id};
use rusqlite::{Connection, OptionalExtension, Transaction, params};

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

/// Advertises `create-workspace {places_by_setting, current, placement}`: the
/// daemon places a client's new workspace against the client's current
/// workspace by the client's `workspaces.newPlacement` ([`ClientCurrent`]).
pub(crate) const CLIENT_CURRENT_CAPABILITY: &str = "workspace-create-current-v1";

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

/// The current workspace a creating client names for `workspaces.newPlacement`
/// (`create-workspace {places_by_setting, current}`): the key of the workspace
/// its window shows, or none (the window shows a top page). Its own focus
/// state holds it; the session's `active_workspace_id` is only a legacy default.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ClientCurrent {
    /// The workspace the window shows; None: a top page.
    pub(crate) current: Option<String>,
    /// The client's `workspaces.newPlacement`; None: this daemon's settings file.
    pub(crate) placement: Option<NewWorkspacePlacement>,
}

thread_local! {
    /// Set around a creation on this thread ([`with_client_current`]).
    static CLIENT_CURRENT: RefCell<Option<ClientCurrent>> = const { RefCell::new(None) };
}

/// Runs `body` with `current` as the current workspace of every workspace this
/// thread creates meanwhile, so the daemon places the new row where the client
/// does and the client's placement after it moves nothing. A commit that may
/// run on another thread captures it at prepare ([`client_current`]) and runs
/// its apply under this again, as `NewWorkspacePlacement::scoped` is carried.
pub(crate) fn with_client_current<T>(
    current: Option<ClientCurrent>,
    body: impl FnOnce() -> T,
) -> T {
    struct Restore(Option<ClientCurrent>);
    impl Drop for Restore {
        fn drop(&mut self) {
            CLIENT_CURRENT.with(|cell| *cell.borrow_mut() = self.0.take());
        }
    }
    let _restore = Restore(CLIENT_CURRENT.with(|cell| cell.replace(current)));
    body()
}

/// The client current set on this thread ([`with_client_current`]), for a
/// commit to carry to the thread that applies it.
pub(crate) fn client_current() -> Option<ClientCurrent> {
    CLIENT_CURRENT.with(|cell| cell.borrow().clone())
}

/// The workspaces a patch creates, read before it applies.
pub(crate) struct CreatedWorkspaces {
    /// Their keys (no live resource row yet), in patch order.
    keys: Vec<String>,
    /// The key of the "current" workspace of `workspaces.newPlacement`
    /// (`beforeCurrent`, `afterCurrent`): the one the creating client names,
    /// else the session's active workspace before the patch.
    current: Option<String>,
    /// `current` is the creating client's: `top` and `bottom` then keep the
    /// new row in the current workspace's group, as that client does.
    from_client: bool,
    /// The creating client's `workspaces.newPlacement`, so the daemon places
    /// the row by the value the client places it by, whatever its own file says.
    placement: Option<NewWorkspacePlacement>,
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
    let client = if keys.is_empty() { None } else { client_current() };
    if let Some(ClientCurrent { current, placement }) = client {
        return Ok(CreatedWorkspaces { keys, current, from_client: true, placement });
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
    Ok(CreatedWorkspaces { keys, current, from_client: false, placement: None })
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
    place_created_workspaces_at(
        transaction,
        created,
        created.placement.unwrap_or_else(NewWorkspacePlacement::current),
    )
}

pub(crate) fn place_created_workspaces_at(
    transaction: &Transaction<'_>,
    created: &CreatedWorkspaces,
    placement: NewWorkspacePlacement,
) -> anyhow::Result<()> {
    place_created_rows(transaction, created, placement)?;
    if !created.keys.is_empty() {
        // sidebar-doc-v1: the new workspaces are adopted into their machine
        // section at the place their personal rows got.
        super::sidebar_doc_sync::sync_from_legacy(transaction)?;
    }
    Ok(())
}

fn place_created_rows(
    transaction: &Transaction<'_>,
    created: &CreatedWorkspaces,
    placement: NewWorkspacePlacement,
) -> anyhow::Result<()> {
    if created.keys.is_empty() || !super::store::state_tables_ready(transaction)? {
        return Ok(());
    }
    let local = local_registry_id(transaction)?;
    let has_row = |key: &str| -> anyhow::Result<bool> {
        Ok(transaction
            .query_row(
                "SELECT 1 FROM personal_workspaces WHERE session_id = ?1 AND workspace_key = ?2",
                params![local, key],
                |_| Ok(()),
            )
            .optional()?
            .is_some())
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
    let current = created.current.as_deref();
    // The client's current workspace in a group: `top` first in it and
    // `bottom` last in that group, as the client places it.
    let in_group = if created.from_client {
        beside_current_slot(transaction, &local, &placed, current, true)?
            .filter(|(_, group)| group.is_some())
    } else {
        None
    };
    let slot = match placement {
        NewWorkspacePlacement::Bottom => match in_group {
            Some((_, group)) => Some(end_of_group_slot(transaction, &local, &placed, group)?),
            None => None,
        },
        NewWorkspacePlacement::Top => match in_group {
            Some((_, group)) => Some(start_of_group_slot(transaction, &local, &placed, group)?),
            None => Some(top_slot(transaction, &local, &placed)?),
        },
        NewWorkspacePlacement::BeforeCurrent | NewWorkspacePlacement::AfterCurrent => {
            let after = placement == NewWorkspacePlacement::AfterCurrent;
            match beside_current_slot(transaction, &local, &placed, current, after)? {
                Some(slot) => Some(slot),
                None => Some(top_slot(transaction, &local, &placed)?),
            }
        }
    };
    let Some((index, group)) = slot else {
        // Appended last: the new rows changed; the live workspaces with no
        // row, which follow every row, moved down by their count.
        for key in &placed {
            queue_placement(transaction, &local, key)?;
        }
        let rows: i64 =
            transaction
                .query_row("SELECT COUNT(*) FROM personal_workspaces", [], |row| row.get(0))?;
        super::placement_shift::queue(transaction, usize::try_from(rows)?, None)?;
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
    // The new rows changed; every row after them only moved down by the
    // count of new rows: it is not restated in the commit, only recorded as
    // a placement shift (a connection without `sidebar-doc-v1` gets those
    // rows restated when the batch is sent). Group slots after them moved
    // too: clients that rebuild from events get each of those.
    for key in &placed {
        queue_placement(transaction, &local, key)?;
    }
    super::placement_shift::queue(transaction, index + placed.len(), None)?;
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
    if placed.contains(&home) {
        return Ok((0, None));
    }
    // The home row's ordinal among the rows other than `placed` (the new
    // rows were appended last, so none of them is before it).
    let index = super::personal::row_index(transaction, local, &home)?.map_or(0, |home| home + 1);
    Ok((index, None))
}

/// First among the existing members of `group`, excluding the newly created rows.
fn start_of_group_slot(
    transaction: &Transaction<'_>,
    local: &str,
    placed: &[String],
    group: Option<String>,
) -> anyhow::Result<(usize, Option<String>)> {
    let rows = read_workspaces(transaction)?
        .into_iter()
        .filter(|row| !(row.session_id == local && placed.contains(&row.workspace_key)))
        .collect::<Vec<_>>();
    let first = rows.iter().position(|row| row.group == group).unwrap_or(rows.len());
    Ok((first, group))
}

/// Right after the last row of `group` (rows other than `placed`), in it.
fn end_of_group_slot(
    transaction: &Transaction<'_>,
    local: &str,
    placed: &[String],
    group: Option<String>,
) -> anyhow::Result<(usize, Option<String>)> {
    let rows = read_workspaces(transaction)?
        .into_iter()
        .filter(|row| !(row.session_id == local && placed.contains(&row.workspace_key)))
        .collect::<Vec<_>>();
    let last =
        rows.iter().rposition(|row| row.group == group).map_or(rows.len(), |index| index + 1);
    Ok((last, group))
}

/// `beforeCurrent` / `afterCurrent` (`after`): right before / after the
/// current workspace's row, in its group. None when there is no current
/// workspace, it has no row, or it is the home workspace.
fn beside_current_slot(
    transaction: &Transaction<'_>,
    local: &str,
    placed: &[String],
    current: Option<&str>,
    after: bool,
) -> anyhow::Result<Option<(usize, Option<String>)>> {
    let Some(current) = current.filter(|current| !placed.iter().any(|key| key == current)) else {
        return Ok(None);
    };
    if super::home_store::live_home(transaction)?.is_some_and(|(_, home)| home == current) {
        return Ok(None);
    }
    // Pinned and custom-section items retain their legacy personal rows. Only a current
    // workspace in this machine's document section may anchor a newly created machine row.
    if super::sidebar_doc_store::is_migrated(transaction)? {
        let Some(id) = workspace_public_id_for_key(transaction, current)? else { return Ok(None) };
        let in_machine = super::sidebar_doc_store::with_doc(transaction, |doc| {
            Ok(doc
                .workspace_item(&WorkspaceRef::new(local, &id))
                .is_some_and(|item| item.section == machine_section_id(local)))
        })?;
        if !in_machine {
            return Ok(None);
        }
    }
    let rows = read_workspaces(transaction)?
        .into_iter()
        .filter(|row| !(row.session_id == local && placed.contains(&row.workspace_key)))
        .collect::<Vec<_>>();
    let Some((index, row)) = rows
        .iter()
        .enumerate()
        .find(|(_, row)| row.session_id == local && row.workspace_key == current)
    else {
        return Ok(None);
    };
    let slot = if after { index + 1 } else { index };
    let Some(group) = row.group.clone() else { return Ok(Some((slot, None))) };
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
    Ok((!elsewhere).then_some((slot, Some(group))))
}
