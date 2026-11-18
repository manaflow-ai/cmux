//! A screen's floating panes (`floating-panes-v1`) in `resource_floating_panes`.
//!
//! The list is not written into `layout_json`: a floating pane stays a leaf
//! of the stored layout, so a build without the capability reads the screen
//! as it is and shows the pane tiled. The table has its own `CREATE TABLE IF
//! NOT EXISTS` that older builds ignore: one record per floating pane, with
//! its place in the list (back to front) and its frame in millionths of the
//! screen's pane area. It is written in the same transaction as the screen
//! row and overlaid at load. Closing a screen deletes its records.
//!
//! A build without the capability may have rewritten the screen meanwhile (a
//! pane closed, or moved to another screen). Load keeps a record only while
//! its pane is still a pane of the stored layout and has no place where a
//! pane never floats (a stack, a docked column, a column with rows), and
//! applies the rules of the list again
//! (`cmux_layout_reducer::floating_panes::normalized`), so a screen always
//! loads with at least one tiled pane. A dropped record goes on the screen's
//! next write. Load also ends the zoom of a pane that floats: a floating pane
//! is never zoomed.
//!
//! The column types of the table are affinities only: SQLite keeps a REAL, a
//! TEXT or a BLOB where the table says `INTEGER`. This build writes integers
//! only. A record with another value is not a record of this build: load
//! ignores it with one log line and goes on, and the screen's next write
//! takes it out of the table.
//!
//! Load reads the records of the screens that it loads, by their ids, in one
//! statement: a load of one workspace reads no record of another workspace.

use cmux_layout_reducer::floating_panes::{FloatFrame, Floating, normalized};

use super::*;

pub(super) fn create_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS resource_floating_panes (
           screen_id TEXT NOT NULL,
           pane_id TEXT NOT NULL,
           position INTEGER NOT NULL,
           x INTEGER NOT NULL,
           y INTEGER NOT NULL,
           w INTEGER NOT NULL,
           h INTEGER NOT NULL,
           PRIMARY KEY (screen_id, pane_id)
         );",
    )?;
    Ok(())
}

/// `(pane id, [x, y, w, h])` of every record, back to front.
type Records = Vec<(String, [i64; 4])>;

/// The records the screen's list asks for. A second entry of one pane is left out, as the rules of the list
/// drop it: the table has one record for each pane.
fn desired(screen: &RegistryScreen) -> Records {
    let mut records: Records = Vec::with_capacity(screen.floating.len());
    for entry in &screen.floating {
        let pane = entry.pane.to_string();
        if records.iter().any(|(seen, _)| *seen == pane) {
            continue;
        }
        let frame = entry.frame;
        records.push((pane, [frame.x, frame.y, frame.w, frame.h].map(i64::from)));
    }
    records
}

/// The pane id and the four values of the record in `row`, whose pane id is at column `pane` and whose values
/// follow it. `None` when the pane id is not a text or one of the values is not an integer.
fn record(row: &rusqlite::Row<'_>, pane: usize) -> rusqlite::Result<Option<(String, [i64; 4])>> {
    let Ok(id) = row.get_ref(pane)?.as_str() else {
        return Ok(None);
    };
    let mut frame = [0_i64; 4];
    for (offset, value) in frame.iter_mut().enumerate() {
        let Ok(stored) = row.get_ref(pane + 1 + offset)?.as_i64() else {
            return Ok(None);
        };
        *value = stored;
    }
    Ok(Some((id.to_owned(), frame)))
}

/// The screen's records, back to front. `None` when one of them is not valid ([`record`]).
fn stored(connection: &Connection, screen_id: &str) -> anyhow::Result<Option<Records>> {
    let mut statement = connection.prepare(
        "SELECT pane_id, x, y, w, h FROM resource_floating_panes
         WHERE screen_id = ?1 ORDER BY position",
    )?;
    let records = statement
        .query_map(params![screen_id], |row| record(row, 0))?
        .collect::<Result<Option<Vec<_>>, _>>()?;
    Ok(records)
}

/// Whether the table already holds exactly the screen's list (a change of
/// the list alone leaves the screen's row unchanged). A record that is not
/// valid makes this false, so the write that follows takes it out.
pub(super) fn matches(
    transaction: &Transaction<'_>,
    screen: &RegistryScreen,
) -> anyhow::Result<bool> {
    Ok(stored(transaction, screen.public_id.as_str())?
        .is_some_and(|records| records == desired(screen)))
}

pub(super) fn write(transaction: &Transaction<'_>, screen: &RegistryScreen) -> anyhow::Result<()> {
    transaction.execute(
        "DELETE FROM resource_floating_panes WHERE screen_id = ?1",
        params![screen.public_id.as_str()],
    )?;
    for (position, (pane, [x, y, w, h])) in desired(screen).into_iter().enumerate() {
        transaction.execute(
            "INSERT INTO resource_floating_panes(screen_id, pane_id, position, x, y, w, h)
             VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            params![screen.public_id.as_str(), pane, position as i64, x, y, w, h],
        )?;
    }
    Ok(())
}

/// Overlays the stored list of each of `screens`: one statement reads the
/// records of these screens only, and none runs for an empty `screens`. A
/// record with a value that is not valid (a value that is not an integer, a
/// frame value that is not a `u32`, a pane id that is not a pane id) is
/// ignored with one log line. A record of a pane that is no longer a pane of
/// the screen's layout is ignored too; the rules of the list then apply to
/// what is left.
pub(super) fn overlay(
    connection: &Connection,
    screens: &mut [RegistryScreen],
) -> anyhow::Result<()> {
    if screens.is_empty() {
        return Ok(());
    }
    let ids = screens.iter().map(|screen| screen.public_id.as_str()).collect::<Vec<_>>();
    let ids = serde_json::to_string(&ids)?;
    let mut statement = connection.prepare(
        "SELECT screen_id, pane_id, x, y, w, h FROM resource_floating_panes
         WHERE screen_id IN (SELECT value FROM json_each(?1))
         ORDER BY screen_id, position",
    )?;
    let records = statement
        .query_map(params![ids], |row| {
            let screen_id = row.get_ref(0)?.as_str().unwrap_or_default().to_owned();
            Ok((screen_id, record(row, 1)?))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    let mut touched: Vec<usize> = Vec::new();
    for (screen_id, record) in records {
        let found = screens
            .iter_mut()
            .enumerate()
            .find(|(_, screen)| screen.public_id.as_str() == screen_id);
        let Some((index, screen)) = found else {
            continue;
        };
        let entry = record.and_then(|(pane, frame)| {
            Some(Floating { pane: PanePublicId::parse(pane).ok()?, frame: stored_frame(frame)? })
        });
        let Some(entry) = entry else {
            eprintln!("cmux-tui: ignoring a floating pane record of {screen_id}: it is not valid");
            continue;
        };
        screen.floating.push(entry);
        if !touched.contains(&index) {
            touched.push(index);
        }
    }
    for (_, screen) in screens.iter_mut().enumerate().filter(|(index, _)| touched.contains(index)) {
        let mut panes = Vec::new();
        layout_panes(&screen.layout, &mut panes);
        let kept = screen
            .floating
            .iter()
            .filter(|entry| !never_floats(screen, &entry.pane))
            .cloned()
            .collect::<Vec<_>>();
        screen.floating = normalized(&panes, &kept);
        // A floating pane is never zoomed: a build without the capability may have zoomed the pane.
        screen.zoomed_pane = crate::model::Screen::zoom_beside_floating_panes(
            screen.zoomed_pane.take(),
            &screen.floating,
        );
    }
    Ok(())
}

/// Whether `pane` never floats in the stored `screen`: a member of a stack, and a pane of a docked column or of
/// a column with rows. The same rule as the live screen's (`Screen::settled_floating_panes`), on the stored
/// layout with its docks and rows overlaid: a build without the capability may have given the pane such a
/// place.
fn never_floats(screen: &RegistryScreen, pane: &PanePublicId) -> bool {
    in_stack(&screen.layout, pane)
        || screen.viewport.columns.iter().any(|column| {
            let mut panes = Vec::new();
            layout_panes(&column.layout, &mut panes);
            panes.contains(pane)
                && (column.dock.is_some()
                    || !column.rows.is_empty()
                    || in_stack(&column.layout, pane))
        })
}

/// Whether `pane` is a member of a stack of the stored layout `node`.
fn in_stack(node: &RegistryLayoutNode, pane: &PanePublicId) -> bool {
    match node {
        RegistryLayoutNode::Leaf { .. } => false,
        RegistryLayoutNode::Split { first, second, .. } => {
            in_stack(first, pane) || in_stack(second, pane)
        }
        RegistryLayoutNode::Stack { panes, .. } => panes.contains(pane),
    }
}

/// The frame of four stored values; `None` when one is not a `u32`.
fn stored_frame([x, y, w, h]: [i64; 4]) -> Option<FloatFrame> {
    let value = |value: i64| u32::try_from(value).ok();
    Some(FloatFrame { x: value(x)?, y: value(y)?, w: value(w)?, h: value(h)? })
}

/// Every pane of a stored layout, each once, in tree order.
fn layout_panes(node: &RegistryLayoutNode, panes: &mut Vec<PanePublicId>) {
    match node {
        RegistryLayoutNode::Leaf { pane } => panes.push(pane.clone()),
        RegistryLayoutNode::Split { first, second, .. } => {
            layout_panes(first, panes);
            layout_panes(second, panes);
        }
        RegistryLayoutNode::Stack { panes: members, .. } => panes.extend(members.iter().cloned()),
    }
}
