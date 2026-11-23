//! A get of one workspace, screen, pane or tab reads the workspace that
//! holds it, never the session.
//!
//! `workspace.get`, `screen.get`, `pane.get`, `tab.get` and
//! `pane.neighbor.get` built the whole session snapshot under the registry
//! and state locks to keep one row (70 to 97 ms of lock hold at 826
//! workspaces; an agent's CLI call with a `current` selector makes three of
//! them, and the person's split or new tab waits for those locks). The
//! reads here return the rows the session snapshot lists, from the same
//! builders and with the same decoration, on committed registry rows
//! (`read_committed_registry`): no state lock, and on a file registry no
//! registry lock.
//!
//! Committed rows can be behind the live session (a commit in flight) and
//! the item can close after its selector resolved. So a row the workspace
//! does not hold is not an answer, and neither is a scoped read that
//! fails (a row in flight that does not join, a busy read connection): the
//! read then takes the session snapshot, which waits for the writer, and
//! the caller gets the answer and the errors it got before.

use rusqlite::OptionalExtension as _;
use serde_json::{Value, json};

use super::{
    operation_failed, public_session_snapshot, public_workspace_topology, public_workspace_values,
    read_committed_registry,
};
use crate::resource::{PanePublicId, ResourceError, WorkspacePublicId};
use crate::resource_screen::{panes_by_id, public_screen_value, tabs_by_pane};
use crate::state::values::decorate_value;
use crate::{Mux, ResolvedResourcePath};

/// A snapshot whose `collection` (`workspaces`, `screens`, `panes` or
/// `tabs`) lists `id` as the session snapshot does: the rows of the path's
/// workspace alone when they hold it, else the session snapshot.
pub(crate) fn snapshot_holding(
    mux: &Mux,
    path: &ResolvedResourcePath,
    collection: &str,
    id: &str,
) -> Result<Value, ResourceError> {
    let scoped = match (&path.workspace, collection) {
        (Some(workspace), "workspaces") => {
            workspace_rows(mux, workspace).map(|rows| json!({"workspaces": rows}))
        }
        (Some(workspace), "screens") => {
            screen_rows(mux, workspace).map(|rows| json!({"screens": rows}))
        }
        (Some(workspace), "panes" | "tabs") => public_workspace_topology(mux, workspace),
        _ => return public_session_snapshot(mux),
    };
    holding(mux, scoped, collection, id)
}

/// A snapshot whose `panes` lists `pane` as the session snapshot does, from
/// the workspace whose stored rows hold the pane (`pane.neighbor.get`: the
/// neighbor comes from the live layout, with no resolved path of its own).
pub(crate) fn snapshot_holding_pane(
    mux: &Mux,
    pane: &PanePublicId,
) -> Result<Value, ResourceError> {
    let workspace = read_committed_registry(mux, |connection, _| {
        connection
            .query_row(
                "SELECT s.workspace_id
                 FROM resource_panes AS p
                 JOIN resource_screens AS s ON s.public_id = p.screen_id
                 WHERE p.public_id = ?1
                   AND p.deleted_revision IS NULL AND s.deleted_revision IS NULL",
                [pane.as_str()],
                |row| row.get::<_, String>(0),
            )
            .optional()?
            .map(WorkspacePublicId::parse)
            .transpose()
            .map_err(anyhow::Error::new)
    })
    .map_err(operation_failed);
    let Ok(Some(workspace)) = workspace else { return public_session_snapshot(mux) };
    holding(mux, public_workspace_topology(mux, &workspace), "panes", pane.as_str())
}

/// `scoped` when the read gave it and its `collection` lists `id`, else the
/// session snapshot (a scoped read that fails is a miss, not the answer).
fn holding(
    mux: &Mux,
    scoped: Result<Value, ResourceError>,
    collection: &str,
    id: &str,
) -> Result<Value, ResourceError> {
    match scoped {
        Ok(scoped)
            if scoped
                .get(collection)
                .and_then(Value::as_array)
                .is_some_and(|rows| rows.iter().any(|row| row["id"] == id)) =>
        {
            Ok(scoped)
        }
        _ => public_session_snapshot(mux),
    }
}

/// The session snapshot's `workspaces` row of `workspace` (none when it has
/// no live row). `public_workspaces` builds the same rows and decorates each
/// one (several point reads a workspace); a get decorates its own row only.
fn workspace_rows(mux: &Mux, workspace: &WorkspacePublicId) -> Result<Vec<Value>, ResourceError> {
    read_committed_registry(mux, |connection, ids| {
        let registry_snapshot = crate::workspace_registry::registry_snapshot_in(
            connection,
            &ids.registry_id,
            &ids.generation,
            &ids.session_id,
        )?;
        let frame = crate::workspace_registry::load_topology_frame(
            connection,
            ids.session_id.clone(),
            ids.generation.clone(),
        )?;
        anyhow::ensure!(
            registry_snapshot.generation == frame.generation
                && registry_snapshot.resource_revision == frame.revision,
            "resource projection changed while reading a workspace"
        );
        let mut rows = public_workspace_values(&registry_snapshot, &frame)?;
        rows.retain(|row| row["id"] == workspace.as_str());
        for row in &mut rows {
            decorate_value(connection, "workspace", row)?;
        }
        Ok(rows)
    })
    .map_err(operation_failed)
}

/// The session snapshot's `screens` rows of `workspace`, each with its
/// layout: the snapshot's builder (`public_screen_value`) and decoration on
/// the workspace's stored subtree. A screen's value names its own panes and
/// their tabs only, and the subtree holds all of them.
fn screen_rows(mux: &Mux, workspace: &WorkspacePublicId) -> Result<Vec<Value>, ResourceError> {
    read_committed_registry(mux, |connection, ids| {
        let topology = crate::workspace_registry::load_resource_topology_scoped(
            connection,
            ids.session_id.clone(),
            ids.generation.clone(),
            std::slice::from_ref(workspace),
        )?;
        let tabs_by_pane = tabs_by_pane(&topology.tabs);
        let panes_by_id = panes_by_id(&topology.panes);
        topology
            .screens
            .iter()
            .map(|screen| {
                let mut row = public_screen_value(&topology, screen, &tabs_by_pane, &panes_by_id)?;
                decorate_value(connection, "screen", &mut row)?;
                Ok(row)
            })
            .collect::<anyhow::Result<Vec<_>>>()
    })
    .map_err(operation_failed)
}
