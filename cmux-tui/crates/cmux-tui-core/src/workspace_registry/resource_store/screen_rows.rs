//! A screen's row in `resource_screens`, and its top and bottom docks
//! (`edge-docks-v1`, plans/cmux-next/layout-model.md).
//!
//! Top and bottom docks are not written into `viewport_json`: the stored
//! viewport column denies unknown fields and its edge is a closed enum, so
//! a build older than `edge-docks-v1` would fail to read the screen. They go
//! into `resource_column_docks`, a table with its own `CREATE TABLE IF NOT
//! EXISTS` that older builds ignore (they read such a column as an ordinary
//! one). It is written in the same transaction as the screen row and
//! overlaid on the viewport at load. Rows of closed screens are inert (the
//! load reads live screens only) and are replaced on the screen's next write.

use super::*;
use crate::model::{ColumnSticky, StickyEdge, StickyMode};

pub(super) fn create_column_dock_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS resource_column_docks (
           screen_id TEXT NOT NULL,
           column_id TEXT NOT NULL,
           edge TEXT NOT NULL,
           mode TEXT NOT NULL,
           PRIMARY KEY (screen_id, column_id)
         );",
    )?;
    Ok(())
}

fn write_column_docks(
    transaction: &Transaction<'_>,
    screen: &RegistryScreen,
) -> anyhow::Result<()> {
    transaction.execute(
        "DELETE FROM resource_column_docks WHERE screen_id = ?1",
        params![screen.public_id.as_str()],
    )?;
    for column in &screen.viewport.columns {
        let Some(dock) = column.sticky.filter(|sticky| sticky.edge.is_band()) else { continue };
        transaction.execute(
            "INSERT INTO resource_column_docks(screen_id, column_id, edge, mode)
             VALUES(?1, ?2, ?3, ?4)",
            params![
                screen.public_id.as_str(),
                column.id.as_str(),
                dock.edge.as_str(),
                dock.mode.as_str()
            ],
        )?;
    }
    Ok(())
}

/// The screen's top and bottom docks as `(column id, edge, mode)`, sorted.
fn desired_docks(screen: &RegistryScreen) -> Vec<(String, String, String)> {
    let mut docks: Vec<_> = screen
        .viewport
        .columns
        .iter()
        .filter_map(|column| {
            let dock = column.sticky.filter(|sticky| sticky.edge.is_band())?;
            Some((column.id.to_string(), dock.edge.as_str().into(), dock.mode.as_str().into()))
        })
        .collect();
    docks.sort();
    docks
}

/// Whether `resource_column_docks` already holds exactly the screen's docks.
/// A dock-only change leaves `viewport_json` unchanged, so the store's
/// "already applied" check must compare these rows too.
pub(super) fn column_docks_match(
    transaction: &Transaction<'_>,
    screen: &RegistryScreen,
) -> anyhow::Result<bool> {
    let mut statement = transaction.prepare(
        "SELECT column_id, edge, mode FROM resource_column_docks
         WHERE screen_id = ?1 ORDER BY column_id, edge, mode",
    )?;
    let stored = statement
        .query_map(params![screen.public_id.as_str()], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?, row.get::<_, String>(2)?))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(stored == desired_docks(screen))
}

/// `screens` with each column's top or bottom dock restored from
/// `resource_column_docks`. A row naming an unknown column or a bad value is
/// ignored, and a column that already carries a left or right flag keeps it.
pub(super) fn with_column_docks(
    connection: &Connection,
    mut screens: Vec<RegistryScreen>,
) -> anyhow::Result<Vec<RegistryScreen>> {
    let mut statement =
        connection.prepare("SELECT screen_id, column_id, edge, mode FROM resource_column_docks")?;
    let rows = statement
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, String>(3)?,
            ))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    for (screen_id, column_id, edge, mode) in rows {
        let (Some(edge), Some(mode)) = (StickyEdge::parse(&edge), StickyMode::parse(&mode)) else {
            continue;
        };
        if !edge.is_band() {
            continue;
        }
        let column = screens
            .iter_mut()
            .filter(|screen| screen.public_id.as_str() == screen_id)
            .flat_map(|screen| screen.viewport.columns.iter_mut())
            .find(|column| column.id.as_str() == column_id && column.sticky.is_none());
        if let Some(column) = column {
            column.sticky = Some(ColumnSticky { edge, mode });
        }
    }
    Ok(screens)
}

pub(super) fn upsert_resource_screen(
    transaction: &Transaction<'_>,
    screen: &RegistryScreen,
    revision: i64,
) -> anyhow::Result<()> {
    let old_splits = transaction
        .query_row(
            "SELECT layout_json, viewport_json FROM resource_screens WHERE public_id = ?1",
            [screen.public_id.as_str()],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
        )
        .optional()?
        .map(|(layout, viewport)| {
            let layout: RegistryLayoutNode = serde_json::from_str(&layout)?;
            let viewport: RegistryViewport = serde_json::from_str(&viewport)?;
            let mut splits = Vec::new();
            collect_screen_split_public_ids(&layout, &viewport, &mut splits);
            Ok::<_, anyhow::Error>(splits)
        })
        .transpose()?
        .unwrap_or_default();
    upsert_resource_identity(transaction, screen.public_id.as_str(), "screen", revision)?;
    let mut desired_splits = Vec::new();
    collect_screen_split_public_ids(&screen.layout, &screen.viewport, &mut desired_splits);
    for split in &desired_splits {
        upsert_resource_identity(transaction, split, "split", revision)?;
    }
    let desired_splits = desired_splits.into_iter().collect::<HashSet<_>>();
    for split in old_splits {
        if !desired_splits.contains(&split) {
            tombstone_resource_identity(transaction, &split, revision)?;
        }
    }
    let layout = canonical_json(&serde_json::to_value(&screen.layout)?)?;
    let auto_layout = screen
        .auto_layout
        .as_ref()
        .map(|value| canonical_json(&serde_json::to_value(value)?))
        .transpose()?;
    let viewport = canonical_json(&serde_json::to_value(&screen.viewport)?)?;
    transaction.execute(
        "INSERT INTO resource_screens(
           public_id, workspace_id, position, name, layout_json, active_pane_id,
           zoomed_pane_id, auto_layout_json, viewport_json,
           created_revision, updated_revision, deleted_revision
         ) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?10, NULL)
         ON CONFLICT(public_id) DO UPDATE SET
           workspace_id=excluded.workspace_id,
           position=excluded.position,
           name=excluded.name,
           layout_json=excluded.layout_json,
           active_pane_id=excluded.active_pane_id,
           zoomed_pane_id=excluded.zoomed_pane_id,
           auto_layout_json=excluded.auto_layout_json,
           viewport_json=excluded.viewport_json,
           updated_revision=excluded.updated_revision",
        params![
            screen.public_id.as_str(),
            screen.workspace_id.as_str(),
            i64::try_from(screen.position).context("screen position exceeds SQLite range")?,
            screen.name,
            layout,
            screen.active_pane.as_str(),
            screen.zoomed_pane.as_ref().map(PanePublicId::as_str),
            auto_layout,
            viewport,
            revision,
        ],
    )?;
    write_column_docks(transaction, screen)
}
