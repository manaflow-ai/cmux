//! A screen's row in `resource_screens`, its top and bottom docks
//! (`edge-docks-v1`, plans/cmux-next/layout-model.md), and its column rows
//! (`rows-v1`, plans/cmux-next/rows.md).
//!
//! Top and bottom docks are not written into `viewport_json`: the stored
//! viewport column denies unknown fields and its edge is a closed enum, so
//! a build older than `edge-docks-v1` would fail to read the screen. They go
//! into `resource_column_docks`, a table with its own `CREATE TABLE IF NOT
//! EXISTS` that older builds ignore (they read such a column as an ordinary
//! one). It is written in the same transaction as the screen row and
//! overlaid on the viewport at load. Closing a screen deletes its rows.
//!
//! Column rows follow the same rule in `resource_screen_rows`: one record per
//! row of a column with two or more rows. `viewport_json` keeps its shape and
//! each column's `layout` there is the compat chain. A lone column with rows
//! is written as no viewport at all ([`RegistryViewport::durable`]), so a
//! build without `rows-v1` loads its panes as vertical splits; its id is the
//! rows' `column_id` and it fills the screen width. Load keeps a column's
//! rows only while the stored chain still matches them (a build
//! without `rows-v1` may have rewritten the screen); otherwise they are
//! dropped and the column loads as one row.
//!
//! Split identities of ids that only these tables name are in [`identities`].

use super::*;
use crate::model::{ColumnDock, DockEdge, DockMode};

mod identities;
pub(super) use identities::validate_screen_splits;

/// The repairs every registry open runs before it validates the store.
pub(crate) fn repair_resources_at_open(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    repair_dangling_terminal_resources(transaction)?;
    identities::repair_side_split_identities(transaction)
}

pub(super) fn create_column_dock_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS resource_column_docks (
           screen_id TEXT NOT NULL,
           column_id TEXT NOT NULL,
           edge TEXT NOT NULL,
           mode TEXT NOT NULL,
           PRIMARY KEY (screen_id, column_id)
         );
         CREATE TABLE IF NOT EXISTS resource_screen_rows (
           screen_id TEXT NOT NULL,
           column_id TEXT NOT NULL,
           position INTEGER NOT NULL,
           row_id TEXT NOT NULL,
           height_permille INTEGER NOT NULL,
           PRIMARY KEY (screen_id, column_id, position)
         );
         CREATE TABLE IF NOT EXISTS resource_parked_splits (
           public_id TEXT PRIMARY KEY NOT NULL,
           screen_id TEXT NOT NULL
         );",
    )?;
    crate::state::app_screens_store::create_screen_kind_schema(transaction)
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
        let Some(dock) = column.dock.filter(|dock| dock.edge.is_band()) else { continue };
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

/// Deletes a closed screen's docks and rows, in the transaction that closes
/// it, and truly tombstones the split identities that only its rows named.
pub(super) fn delete_side_tables(
    transaction: &Transaction<'_>,
    screen_id: &str,
    revision: i64,
) -> anyhow::Result<()> {
    identities::retire_side_splits(transaction, screen_id, revision)?;
    crate::state::app_screens_store::delete_screen_app(transaction, screen_id)?;
    for table in ["resource_column_docks", "resource_screen_rows"] {
        transaction
            .execute(&format!("DELETE FROM {table} WHERE screen_id = ?1"), params![screen_id])?;
    }
    Ok(())
}

fn write_screen_rows(transaction: &Transaction<'_>, screen: &RegistryScreen) -> anyhow::Result<()> {
    transaction.execute(
        "DELETE FROM resource_screen_rows WHERE screen_id = ?1",
        params![screen.public_id.as_str()],
    )?;
    for (column, position, row) in desired_rows(screen) {
        transaction.execute(
            "INSERT INTO resource_screen_rows(
               screen_id, column_id, position, row_id, height_permille
             ) VALUES(?1, ?2, ?3, ?4, ?5)",
            params![screen.public_id.as_str(), column, position, row.0, row.1],
        )?;
    }
    Ok(())
}

/// `(column id, position, (row id, height))` of every row record, in
/// column then position order.
fn desired_rows(screen: &RegistryScreen) -> Vec<(String, i64, (String, i64))> {
    let mut rows = Vec::new();
    for column in screen.viewport.columns.iter().filter(|column| column.rows.len() >= 2) {
        for (position, row) in column.rows.iter().enumerate() {
            let record = (row.id.to_string(), i64::from(row.height));
            rows.push((column.id.to_string(), position as i64, record));
        }
    }
    rows.sort();
    rows
}

/// Whether both side tables already hold exactly the screen's docks and
/// rows (a dock-only or row-only change leaves `viewport_json` unchanged).
pub(super) fn side_tables_match(
    transaction: &Transaction<'_>,
    screen: &RegistryScreen,
) -> anyhow::Result<bool> {
    let mut statement = transaction.prepare(
        "SELECT column_id, position, row_id, height_permille FROM resource_screen_rows
         WHERE screen_id = ?1 ORDER BY column_id, position",
    )?;
    let stored = statement
        .query_map(params![screen.public_id.as_str()], |row| {
            let record = (row.get::<_, String>(2)?, row.get::<_, i64>(3)?);
            Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?, record))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(stored == desired_rows(screen) && column_docks_match(transaction, screen)?)
}

/// `((screen id, column id), [(row id, height)])` as read from the table.
type StoredColumnRows = ((String, String), Vec<(String, i64)>);

/// `screens` with docks ([`with_column_docks`]) and rows overlaid.
pub(super) fn with_side_tables(
    connection: &Connection,
    screens: Vec<RegistryScreen>,
) -> anyhow::Result<Vec<RegistryScreen>> {
    let mut screens = with_column_docks(connection, screens)?;
    let mut statement = connection.prepare(
        "SELECT screen_id, column_id, row_id, height_permille FROM resource_screen_rows
         ORDER BY screen_id, column_id, position",
    )?;
    let records = statement
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, i64>(3)?,
            ))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    let mut columns: Vec<StoredColumnRows> = Vec::new();
    for (screen, column, row, height) in records {
        match columns.last_mut() {
            Some((key, rows)) if key.0 == screen && key.1 == column => rows.push((row, height)),
            _ => columns.push(((screen, column), vec![(row, height)])),
        }
    }
    for ((screen_id, column_id), rows) in columns {
        let Some(screen) = screens.iter_mut().find(|screen| screen.public_id.as_str() == screen_id)
        else {
            continue;
        };
        overlay_column_rows(screen, &column_id, &rows);
    }
    Ok(screens)
}

/// Attaches stored rows to their column when they are valid and the stored
/// chain still matches them; anything else is dropped (the column then loads
/// as one row, and its records go on the screen's next write). A lone
/// column fills the screen width.
fn overlay_column_rows(screen: &mut RegistryScreen, column_id: &str, rows: &[(String, i64)]) {
    let Some(rows) = rows
        .iter()
        .map(|(id, height)| {
            let height = u16::try_from(*height)
                .ok()
                .filter(|height| crate::model::ROW_HEIGHT_PERMILLE.contains(height))?;
            Some(RegistryRow { id: SplitPublicId::parse(id.clone()).ok()?, height })
        })
        .collect::<Option<Vec<_>>>()
    else {
        return;
    };
    if rows.len() < 2 {
        return;
    }
    let lone = screen.viewport.columns.is_empty();
    let layout = match screen.viewport.columns.iter().find(|column| column.id.as_str() == column_id)
    {
        Some(column) => &column.layout,
        // A lone column with rows is stored as the screen layout itself.
        None if lone && screen.auto_layout.is_none() => &screen.layout,
        None => return,
    };
    if !chain_matches(layout, &rows) {
        return;
    }
    if lone {
        let Ok(id) = SplitPublicId::parse(column_id.to_string()) else { return };
        let column = RegistryViewportColumn::new(id, 1.0, screen.layout.clone(), None, None);
        screen.viewport = RegistryViewport { base_width: Some(1.0), columns: vec![column] };
    }
    let column = screen
        .viewport
        .columns
        .iter_mut()
        .find(|column| column.id.as_str() == column_id)
        .expect("the column was found or created above");
    column.rows = rows;
}

/// Whether `layout` is the compat chain of `rows`: from the outside in, one
/// `down` split per row n..2 carrying that row's id. Ratios are not compared;
/// load rewrites them from the heights.
fn chain_matches(layout: &RegistryLayoutNode, rows: &[RegistryRow]) -> bool {
    let mut node = layout;
    for row in rows[1..].iter().rev() {
        let RegistryLayoutNode::Split { split, direction, first, .. } = node else {
            return false;
        };
        if split != &row.id || direction != "down" {
            return false;
        }
        node = &**first;
    }
    rows.iter().enumerate().all(|(index, row)| rows[..index].iter().all(|seen| seen.id != row.id))
}

/// The screen's top and bottom docks as `(column id, edge, mode)`, sorted.
fn desired_docks(screen: &RegistryScreen) -> Vec<(String, String, String)> {
    let mut docks: Vec<_> = screen
        .viewport
        .columns
        .iter()
        .filter_map(|column| {
            let dock = column.dock.filter(|dock| dock.edge.is_band())?;
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
///
/// An older build reads a docked column as an ordinary one and may pin
/// other columns meanwhile. A dock is restored only while its edge is free
/// and another column still scrolls; otherwise the dock is dropped (and its
/// row on the screen's next write), never a side pin the older build set.
fn with_column_docks(
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
        let (Some(edge), Some(mode)) = (DockEdge::parse(&edge), DockMode::parse(&mode)) else {
            continue;
        };
        if !edge.is_band() {
            continue;
        }
        let Some(screen) = screens.iter_mut().find(|screen| screen.public_id.as_str() == screen_id)
        else {
            continue;
        };
        let columns = &mut screen.viewport.columns;
        let edge_taken = columns.iter().any(|column| column.dock.is_some_and(|s| s.edge == edge));
        let Some(index) = columns.iter().position(|column| column.id.as_str() == column_id) else {
            continue;
        };
        let other_scrolls = columns
            .iter()
            .enumerate()
            .any(|(other, column)| other != index && column.dock.is_none());
        if columns[index].dock.is_none() && !edge_taken && other_scrolls {
            columns[index].dock = Some(ColumnDock { edge, mode });
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
    let old_side_splits = identities::stored_side_splits(transaction, screen.public_id.as_str())?;
    upsert_resource_identity(transaction, screen.public_id.as_str(), "screen", revision)?;
    let durable_viewport = screen.viewport.durable();
    let mut desired_splits = Vec::new();
    collect_screen_split_public_ids(&screen.layout, &durable_viewport, &mut desired_splits);
    identities::register_screen_splits(
        transaction,
        screen.public_id.as_str(),
        identities::ScreenSplits { projection: old_splits, side: old_side_splits },
        identities::ScreenSplits {
            projection: desired_splits,
            side: identities::side_splits(screen),
        },
        revision,
    )?;
    let layout = canonical_json(&serde_json::to_value(&screen.layout)?)?;
    let auto_layout = screen
        .auto_layout
        .as_ref()
        .map(|value| canonical_json(&serde_json::to_value(value)?))
        .transpose()?;
    let viewport = canonical_json(&serde_json::to_value(&durable_viewport)?)?;
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
    write_column_docks(transaction, screen)?;
    write_screen_rows(transaction, screen)
}
