//! LAST-WORKSPACE-CLOSES-SPACE (Lawrence 2026-11-15: "if you close the last
//! thing in a space, we should close that space. same for screens. same for
//! workspaces. same for panes. make it consistent").
//!
//! The one rule, at every level: **a close that takes the last item of a
//! container closes that container too, in the same commit, and one Reopen
//! Closed brings all of it back.** A tab's pane (the split collapses), a
//! pane's screen, a screen's workspace (LAST-TAB-CLOSES-WORKSPACE,
//! `mux/resource_topology/emptied_workspace.rs`), a workspace's space (here)
//! and, in the app, a workspace's window (`WindowManager.reconcileMembership`).
//! What never closes: the Default space (cmux always has one), the Home
//! workspace, a container that was empty before the close, and a container
//! whose content was lost rather than closed (a host loss).
//!
//! Here: every recorded close passes through `apply_resource_patch`, so this
//! runs for each of them (Cmd-W, the tab's x, close-pane, close-screen,
//! close-workspace, the CLI, a process end) in the closing transaction,
//! before the closed-history capture. A space is deleted when a workspace
//! this close takes was in it and no other workspace can show there:
//! - no other live workspace of this session is pinned to it, or, when it
//!   follows this session, shows in it unpinned;
//! - no workspace of another session is pinned to it, and it follows no
//!   other session: this daemon cannot see those workspaces, so it keeps
//!   the space.
//!
//! The delete is Delete Space's own (`WorkspaceRegistry::delete_profile_in`,
//! with the room's record in the close's closed group), so Cmd-Shift-T or
//! the close's Undo restores the space, its place, follows, groups and pins
//! with its workspace. The row keeps the workspace's name (`room_cascade`).
//! Skipped: a close that is already part of a space delete or other
//! announced group (a pending group), a whole-workspace stash (it is not a
//! close the person loses), an incognito workspace (its space is deleted
//! with its window and is never recorded), and unrecorded session-end closes
//! (`apply_resource_patch_unrecorded`: a space delete must be recoverable).
//!
//! Clients hear the change as `personal-changed`: the transaction leaves
//! [`CASCADE_META_KEY`] for [`take_cascaded_personal_revision`], which
//! `Mux::publish_resource_event` reads after the commit.

use std::collections::BTreeSet;

use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde_json::{Value, json};

use crate::state::closed_history_store::{new_closed_id, pend_group, queue_change};
use crate::state::personal::{all_groups, all_placements, all_rooms};
use crate::state::store::state_delete;
use crate::state::values::local_registry_id;
use crate::workspace_registry::WorkspaceRegistry;
use crate::workspace_registry::personal_mutations::room_archive;
use crate::workspace_registry::personal_store::{DEFAULT_PROFILE_ID, personal_revision};
use crate::workspace_registry::resource_store::{ResourceChange, ResourcePatch};

/// The meta row a cascade leaves: the personal revision its delete wrote.
pub(crate) const CASCADE_META_KEY: &str = "room_cascade_personal_revision";

/// Delete, in `transaction`, every space `patch`'s workspace closes empty.
/// Returns whether it announced a closed group (the caller flushes it after
/// the capture, so it never waits for a later close).
pub(crate) fn delete_emptied_rooms(
    transaction: &Transaction<'_>,
    patch: &ResourcePatch,
) -> anyhow::Result<bool> {
    let closing_ids = patch
        .changes
        .iter()
        .filter_map(|change| match change {
            ResourceChange::TombstoneWorkspace { workspace_id } => {
                Some(workspace_id.as_str().to_string())
            }
            _ => None,
        })
        .collect::<Vec<_>>();
    if closing_ids.is_empty() || !super::store::state_tables_ready(transaction)? {
        return Ok(false);
    }
    if exists(transaction, "SELECT EXISTS(SELECT 1 FROM closed_group_pending)")?
        || exists(transaction, "SELECT EXISTS(SELECT 1 FROM stash_capture_workspaces)")?
    {
        return Ok(false);
    }
    let local = local_registry_id(transaction)?;
    let mut closing_keys = BTreeSet::new();
    let mut candidates = BTreeSet::new();
    for id in &closing_ids {
        if super::closed_history_store::is_ephemeral(transaction, id)? {
            continue;
        }
        let Some(key) = transaction
            .query_row(
                "SELECT workspace_key FROM resource_workspaces
                 WHERE public_id = ?1 AND deleted_revision IS NULL",
                [id],
                |row| row.get::<_, String>(0),
            )
            .optional()?
        else {
            continue;
        };
        for room in room_archive::rooms_of(transaction, &local, &key)? {
            if room != DEFAULT_PROFILE_ID {
                candidates.insert(room);
            }
        }
        closing_keys.insert(key);
    }
    if candidates.is_empty() {
        return Ok(false);
    }
    let emptied = candidates
        .into_iter()
        .filter_map(|room| match still_shows(transaction, &room, &local, &closing_keys) {
            Ok(true) => None,
            Ok(false) => Some(Ok(room)),
            Err(error) => Some(Err(error)),
        })
        .collect::<anyhow::Result<Vec<_>>>()?;
    let Some((first, rest)) = emptied.split_first() else { return Ok(false) };
    // Each record is taken before its own delete, so its index is its place
    // among the spaces still there; a reopen puts them back in this order.
    let mut archives = Vec::with_capacity(emptied.len());
    for room in std::iter::once(first).chain(rest) {
        archives.push(room_archive::snapshot_room(transaction, room)?);
        WorkspaceRegistry::delete_profile_in(transaction, room, None)?;
        queue_change(transaction, &state_delete("room", room))?;
    }
    let mut archives = archives.into_iter();
    let mut extra = json!({"room": archives.next(), "room_cascade": true});
    let more = archives.collect::<Vec<_>>();
    if !more.is_empty() {
        extra["also_rooms"] = Value::Array(more);
    }
    pend_group(transaction, &new_closed_id(), &extra)?;
    for change in all_rooms(transaction)?
        .into_iter()
        .chain(all_groups(transaction)?)
        .chain(all_placements(transaction)?)
    {
        queue_change(transaction, &change)?;
    }
    transaction.execute(
        "INSERT INTO meta(key, value) VALUES(?1, ?2)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        params![CASCADE_META_KEY, personal_revision(transaction)?.to_string()],
    )?;
    Ok(true)
}

/// Whether `room` may still show a workspace once `closing` (keys of this
/// session `local`) closed.
fn still_shows(
    connection: &Connection,
    room: &str,
    local: &str,
    closing: &BTreeSet<String>,
) -> anyhow::Result<bool> {
    let foreign = "SELECT EXISTS(SELECT 1 FROM profile_pins WHERE profile_id = ?1 AND session_id <> ?2)
                   OR EXISTS(SELECT 1 FROM profile_follows WHERE profile_id = ?1 AND session_id <> ?2)";
    if connection.query_row(foreign, params![room, local], |row| row.get::<_, bool>(0))? {
        return Ok(true);
    }
    let pinned = connection
        .prepare(
            "SELECT p.workspace_key FROM profile_pins p
             JOIN workspaces w ON w.workspace_key = p.workspace_key AND w.tombstoned = 0
             WHERE p.profile_id = ?1 AND p.session_id = ?2",
        )?
        .query_map(params![room, local], |row| row.get::<_, String>(0))?
        .collect::<Result<Vec<_>, _>>()?;
    if pinned.iter().any(|key| !closing.contains(key)) {
        return Ok(true);
    }
    let follows_local = connection.query_row(
        "SELECT EXISTS(SELECT 1 FROM profile_follows WHERE profile_id = ?1 AND session_id = ?2)",
        params![room, local],
        |row| row.get::<_, bool>(0),
    )?;
    if !follows_local {
        return Ok(false);
    }
    let unpinned = connection
        .prepare(
            "SELECT w.workspace_key FROM workspaces w
             WHERE w.tombstoned = 0 AND NOT EXISTS(
               SELECT 1 FROM profile_pins p WHERE p.session_id = ?1 AND p.workspace_key = w.workspace_key)",
        )?
        .query_map([local], |row| row.get::<_, String>(0))?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(unpinned.iter().any(|key| !closing.contains(key)))
}

fn exists(connection: &Connection, query: &str) -> anyhow::Result<bool> {
    Ok(connection.query_row(query, [], |row| row.get::<_, bool>(0))?)
}

/// The personal revision a committed cascade left, taken once (None when no
/// cascade ran since the last take). One indexed read per resource commit; a
/// write only after a cascade.
pub(crate) fn take_cascaded_personal_revision(
    connection: &Connection,
) -> anyhow::Result<Option<u64>> {
    let value = connection
        .prepare_cached("SELECT value FROM meta WHERE key = ?1")?
        .query_row([CASCADE_META_KEY], |row| row.get::<_, String>(0))
        .optional()?;
    let Some(value) = value else { return Ok(None) };
    connection.execute("DELETE FROM meta WHERE key = ?1", [CASCADE_META_KEY])?;
    Ok(value.parse().ok())
}
