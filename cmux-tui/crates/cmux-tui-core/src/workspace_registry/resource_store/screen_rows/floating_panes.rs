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
//! its pane is still a pane of the stored layout, and applies the rules of
//! the list again (`cmux_layout_reducer::floating_panes::normalized`), so a
//! screen always loads with at least one tiled pane. A dropped record goes on
//! the screen's next write.

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

fn desired(screen: &RegistryScreen) -> Records {
    screen
        .floating
        .iter()
        .map(|entry| {
            let frame = entry.frame;
            (entry.pane.to_string(), [frame.x, frame.y, frame.w, frame.h].map(i64::from))
        })
        .collect()
}

fn stored(connection: &Connection, screen_id: &str) -> anyhow::Result<Records> {
    let mut statement = connection.prepare(
        "SELECT pane_id, x, y, w, h FROM resource_floating_panes
         WHERE screen_id = ?1 ORDER BY position",
    )?;
    let records = statement
        .query_map(params![screen_id], |row| {
            let frame: [i64; 4] = [row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?];
            Ok((row.get::<_, String>(0)?, frame))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(records)
}

/// Whether the table already holds exactly the screen's list (a change of
/// the list alone leaves the screen's row unchanged).
pub(super) fn matches(
    transaction: &Transaction<'_>,
    screen: &RegistryScreen,
) -> anyhow::Result<bool> {
    Ok(stored(transaction, screen.public_id.as_str())? == desired(screen))
}

pub(super) fn write(transaction: &Transaction<'_>, screen: &RegistryScreen) -> anyhow::Result<()> {
    // Not written yet: the tests of the store fail.
    let _ = (transaction, screen);
    Ok(())
}

/// Overlays each screen's stored list. A record of a pane that is no longer
/// a pane of the screen's layout, or with a value that is not a frame, is
/// ignored; the rules of the list then apply to what is left.
pub(super) fn overlay(
    connection: &Connection,
    screens: &mut [RegistryScreen],
) -> anyhow::Result<()> {
    let mut statement = connection.prepare(
        "SELECT screen_id, pane_id, x, y, w, h FROM resource_floating_panes
         ORDER BY screen_id, position",
    )?;
    let records = statement
        .query_map([], |row| {
            let frame: [i64; 4] = [row.get(2)?, row.get(3)?, row.get(4)?, row.get(5)?];
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?, frame))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    if records.is_empty() {
        return Ok(());
    }
    let mut touched: Vec<usize> = Vec::new();
    for (screen_id, pane_id, frame) in records {
        let Some(index) = screens.iter().position(|screen| screen.public_id.as_str() == screen_id)
        else {
            continue;
        };
        let (Ok(pane), Some(frame)) = (PanePublicId::parse(pane_id), stored_frame(frame)) else {
            continue;
        };
        screens[index].floating.push(Floating { pane, frame });
        if !touched.contains(&index) {
            touched.push(index);
        }
    }
    for index in touched {
        let screen = &mut screens[index];
        let mut panes = Vec::new();
        layout_panes(&screen.layout, &mut panes);
        screen.floating = normalized(&panes, &screen.floating);
    }
    Ok(())
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
