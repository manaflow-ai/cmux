//! Ephemeral content stays ephemeral when it moves (R102,
//! `resource-api-v2.md`). A workspace that a patch creates and fills with
//! content moved out of an ephemeral workspace is marked ephemeral in that
//! patch's transaction, so no read and no `session.events` change shows it
//! without the flag. Content never moves between an ephemeral workspace and
//! a normal workspace that already exists.
//!
//! The rule runs where every move path meets, the resource patch (as closed
//! history does), so the raw commands, the v2 operations and the CLI share
//! it. A tab moves when its live row names another pane; a pane, when it
//! names another screen; a screen, when it names another workspace.

use std::collections::{HashMap, HashSet};

use rusqlite::{OptionalExtension, Transaction};

use super::closed_history_store::is_ephemeral;
use crate::workspace_registry::resource_store::{ResourceChange, ResourcePatch};

/// The refusal for a move between an ephemeral and a normal workspace.
pub(crate) const MIXED_MOVE_ERROR: &str =
    "bad request: content cannot move between an ephemeral workspace and a normal one";

/// Carry the ephemeral flag into the workspaces `patch` creates for moved
/// content, and refuse a move between an ephemeral and a normal workspace.
/// Runs before the patch is applied, while the rows show the old places.
pub(crate) fn carry_ephemeral(
    transaction: &Transaction<'_>,
    patch: &ResourcePatch,
) -> anyhow::Result<()> {
    if !super::store::state_tables_ready(transaction)? {
        return Ok(());
    }
    let places = Places::of(patch);
    let mut moves = Vec::new();
    let mut created = HashSet::new();
    for change in &patch.changes {
        match change {
            ResourceChange::UpsertWorkspace { workspace, .. } => {
                let id = workspace.public_id.as_str();
                if live_row(transaction, "resource_workspaces", id)?.is_none() {
                    created.insert(id.to_string());
                }
            }
            ResourceChange::UpsertScreen(screen) => {
                let id = screen.public_id.as_str();
                let to = screen.workspace_id.as_str();
                if let Some(from) =
                    live_parent(transaction, "resource_screens", "workspace_id", id)?
                    && from != to
                {
                    moves.push((from, to.to_string()));
                }
            }
            ResourceChange::UpsertPane(pane) => {
                let id = pane.public_id.as_str();
                let to = pane.screen_id.as_str();
                if let Some(from) = live_parent(transaction, "resource_panes", "screen_id", id)?
                    && from != to
                {
                    moves.extend(
                        places
                            .workspace_of_screen(transaction, &from)?
                            .zip(places.workspace_of_screen(transaction, to)?),
                    );
                }
            }
            ResourceChange::UpsertTab(tab) => {
                let id = tab.public_id.as_str();
                let to = tab.pane_id.as_str();
                if let Some(from) = live_parent(transaction, "resource_tabs", "pane_id", id)?
                    && from != to
                {
                    moves.extend(
                        places
                            .workspace_of_pane(transaction, &from)?
                            .zip(places.workspace_of_pane(transaction, to)?),
                    );
                }
            }
            _ => {}
        }
    }
    moves.retain(|(from, to)| from != to);
    if moves.is_empty() {
        return Ok(());
    }
    // A new workspace that receives ephemeral content is ephemeral; then
    // every move must join two workspaces of the same kind.
    let mut flags = HashMap::new();
    for (from, to) in &moves {
        for id in [from, to] {
            if !flags.contains_key(id) {
                flags.insert(id.clone(), is_ephemeral(transaction, id)?);
            }
        }
    }
    let mut marked = HashSet::new();
    for (from, to) in &moves {
        if flags[from] && created.contains(to) {
            marked.insert(to.clone());
        }
    }
    for (from, to) in &moves {
        let target = flags[to] || marked.contains(to);
        anyhow::ensure!(flags[from] == target, MIXED_MOVE_ERROR);
    }
    for workspace in &marked {
        super::store::mark_workspace_ephemeral(transaction, workspace)?;
    }
    Ok(())
}

/// Where the patch puts panes and screens, before the rows say so.
struct Places<'a> {
    pane_screens: HashMap<&'a str, &'a str>,
    screen_workspaces: HashMap<&'a str, &'a str>,
}

impl<'a> Places<'a> {
    fn of(patch: &'a ResourcePatch) -> Self {
        let mut pane_screens = HashMap::new();
        let mut screen_workspaces = HashMap::new();
        for change in &patch.changes {
            match change {
                ResourceChange::UpsertPane(pane) => {
                    pane_screens.insert(pane.public_id.as_str(), pane.screen_id.as_str());
                }
                ResourceChange::UpsertScreen(screen) => {
                    screen_workspaces
                        .insert(screen.public_id.as_str(), screen.workspace_id.as_str());
                }
                _ => {}
            }
        }
        Self { pane_screens, screen_workspaces }
    }

    fn workspace_of_screen(
        &self,
        transaction: &Transaction<'_>,
        screen: &str,
    ) -> anyhow::Result<Option<String>> {
        if let Some(workspace) = self.screen_workspaces.get(screen) {
            return Ok(Some((*workspace).to_string()));
        }
        live_parent(transaction, "resource_screens", "workspace_id", screen)
    }

    fn workspace_of_pane(
        &self,
        transaction: &Transaction<'_>,
        pane: &str,
    ) -> anyhow::Result<Option<String>> {
        let screen = match self.pane_screens.get(pane) {
            Some(screen) => Some((*screen).to_string()),
            None => live_parent(transaction, "resource_panes", "screen_id", pane)?,
        };
        match screen {
            Some(screen) => self.workspace_of_screen(transaction, &screen),
            None => Ok(None),
        }
    }
}

/// The `column` of the live row `id` of `table` (its parent's public id).
fn live_parent(
    transaction: &Transaction<'_>,
    table: &'static str,
    column: &'static str,
    id: &str,
) -> anyhow::Result<Option<String>> {
    Ok(transaction
        .query_row(
            &format!(
                "SELECT {column} FROM {table} WHERE public_id = ?1 AND deleted_revision IS NULL"
            ),
            [id],
            |row| row.get::<_, String>(0),
        )
        .optional()?)
}

fn live_row(
    transaction: &Transaction<'_>,
    table: &'static str,
    id: &str,
) -> anyhow::Result<Option<String>> {
    live_parent(transaction, table, "public_id", id)
}
