//! What a pane close shows in the key's turn, ported from the Mac app's Swift
//! (`CmuxNextLayout/Model/LayoutModel+PaneClose.swift`, `LayoutModel+CloseSizing.swift`, and
//! `Geometry/EvenSplitRatios.swift`'s close side) one function at a time.
//!
//! A closing pane leaves the shown screens at once ([`removing_split_pane`]): its sibling takes its
//! parent's place; a column's only pane takes its column with it ([`removing_column`]); in a column
//! with rows it leaves its row's tree, and a row it empties leaves the column
//! ([`removing_row_pane`], the daemon's compat chain refolded in `f32` as cmux-tui computes it). The
//! focus goes to [`successor`]. With `layout.splitSizing` even, the closed pane's same-axis chain
//! shares its space equally again ([`split_changes`]); with `layout.newColumnWidth` fitScreen, the
//! scrolling columns that fit the viewport share it again ([`column_resizes`]).
//!
//! A close's sizes are derived, never held per split or column: the shown sizes are the daemon's,
//! then the sizes of closes that landed while others were pending ([`Landed`]), then each pending
//! close in the order it was shown, its sizing taken against the layout before it
//! ([`overlaying_pane_closes`]). [`note_landed_closes`] adds a snapshot's landed closes to
//! [`Landed`]; [`flush_landed_close_sizes`] says which landed sizes go to the daemon once a screen
//! has no close pending; [`close_sizing`] is the sizing intents for panes that left between two
//! daemon trees.
//!
//! Every comparison and arithmetic step is the Swift one (`Swift.min`/`max` as
//! [`crate::scroll::swift_min`]/[`crate::scroll::swift_max`]); `schemas/pane-close/vectors.json`
//! pins the Swift rules' answers from before the move.

use crate::screen_layout::{AGENT_CHAT, Axis, Column, Layout, Node};
use crate::scroll::{swift_max, swift_min};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

/// `SplitRatio.range`.
pub const SPLIT_RATIO_MIN: f64 = 0.05;
pub const SPLIT_RATIO_MAX: f64 = 0.95;
/// `ColumnWidthPreset.widthRange`.
pub const COLUMN_WIDTH_MIN: f64 = 0.1;
pub const COLUMN_WIDTH_MAX: f64 = 1.0;
/// A landed size within this of the daemon's is not sent (`flushLandedCloseSizes`).
pub const FLUSH_TOLERANCE: f64 = 0.002;

/// One split's new ratio (`SplitRatioChange`).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct RatioChange {
    pub split: String,
    pub ratio: f64,
}

/// One column's new width (`ColumnResize`).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ColumnResize {
    pub column: String,
    pub width: f64,
}

/// The sizing settings a close reads.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Sizing {
    /// `layout.splitSizing == .even`.
    pub even: bool,
    /// `layout.newColumnWidth == .fitScreen`.
    pub fits: bool,
}

/// `LayoutModel.clampedRatio`: into `SplitRatio.range`.
pub fn clamped_ratio(ratio: f64) -> f64 {
    swift_min(swift_max(ratio, SPLIT_RATIO_MIN), SPLIT_RATIO_MAX)
}

// MARK: Removing a pane

/// `removingSplitPane`: `layout` without `pane`. None when `pane` is the screen's last pane, is not
/// in it, or is in a column with rows but in none of its rows.
pub fn removing_split_pane(pane: &str, layout: &Layout) -> Option<Layout> {
    match layout {
        Layout::Splits(root) => {
            if root.contains(pane) {
                root.removing(pane).map(Layout::Splits)
            } else {
                None
            }
        }
        Layout::Columns(columns) => {
            let mut columns = columns.clone();
            let index = columns.iter().position(|column| column.root.contains(pane))?;
            if columns[index].has_rows() {
                columns[index].row_index(pane)?;
                releasing_chat_role(&mut columns[index], pane);
                columns[index] = removing_row_pane(pane, &columns[index]);
                // A lone column left with one row is the screen's split tree again, unless it is a pinned dock.
                if columns.len() == 1 && !columns[0].has_rows() && !columns[0].pinned_dock() {
                    return Some(Layout::Splits(columns[0].root.clone()));
                }
                return Some(Layout::Columns(columns));
            }
            let Some(root) = columns[index].root.removing(pane) else {
                return if columns.len() > 1 {
                    Some(removing_column(index, &columns))
                } else {
                    None
                };
            };
            releasing_chat_role(&mut columns[index], pane);
            columns[index].root = root;
            Some(Layout::Columns(columns))
        }
    }
}

/// `removingRowPane`: `column` (two or more rows) without `pane`, as cmux-tui's tree shows it after
/// the close. The compat chain `root` is refolded from the rows: chain split k is row k's, its ratio
/// the heights above it over the heights through it, in `f32`.
pub fn removing_row_pane(pane: &str, column: &Column) -> Column {
    let Some(index) = column.row_index(pane) else { return column.clone() };
    let mut column = column.clone();
    // The chain's splits, top first: `chain[k - 1]` joins rows 0..<k above row k.
    let mut chain: Vec<String> = Vec::new();
    let mut node = &column.root;
    while chain.len() < column.rows.len() - 1 {
        let Node::Split { split, axis: Axis::Vertical, a, .. } = node else { break };
        chain.push(split.clone());
        node = a;
    }
    chain.reverse();
    if chain.len() != column.rows.len() - 1 {
        // Not the chain the daemon builds: the compat tree just loses the pane.
        column.root = column.root.removing(pane).unwrap_or_else(|| column.root.clone());
        match column.rows[index].root.removing(pane) {
            Some(root) => column.rows[index].root = root,
            None => {
                column.rows.remove(index);
            }
        }
        if column.rows.len() < 2 {
            column.rows.clear();
        }
        return column;
    }
    match column.rows[index].root.removing(pane) {
        Some(root) => column.rows[index].root = root,
        None => {
            // The emptied row's split goes; for the top row, the split under it.
            column.rows.remove(index);
            chain.remove(index.saturating_sub(1));
        }
    }
    if column.rows.len() < 2 {
        column.root = column.rows[0].root.clone();
        column.rows.clear();
        return column;
    }
    let mut root = column.rows[0].root.clone();
    let mut before = column.rows[0].height as f32;
    for (row, split) in column.rows.iter().skip(1).zip(&chain) {
        let height = row.height as f32;
        let ratio = clamped_ratio(f64::from(before / (before + height)));
        root = Node::split(split, Axis::Vertical, ratio, root, row.root.clone());
        before += height;
    }
    column.root = root;
    column
}

/// `releasingChatRole`: the agent chat's own pane (its dock's top pane) leaving: the dock stays on
/// its edge as a plain dock.
pub fn releasing_chat_role(column: &mut Column, pane: &str) {
    let top = column.root.first_pane() == pane;
    if let Some(dock) = column.dock.as_mut().filter(|dock| dock.role.as_deref() == Some(AGENT_CHAT))
        && top
    {
        dock.role = None;
    }
}

/// `removingColumn(at:from:)`: `columns` without the column at `index`, as cmux-tui's tree shows
/// it: a lone column with one row becomes the screen's split tree unless it is a pinned dock (which
/// keeps its dock and width); another lone column fills the width; when no scrolling column stays,
/// every dock but a pinned one scrolls again, and a lone column never docks.
pub fn removing_column(index: usize, columns: &[Column]) -> Layout {
    let mut columns = columns.to_vec();
    columns.remove(index);
    if columns.len() == 1 && columns[0].pinned_dock() {
        return Layout::Columns(columns);
    }
    if columns.len() == 1 && !columns[0].has_rows() {
        return Layout::Splits(columns[0].root.clone());
    }
    if columns.len() == 1 {
        columns[0].width = 1.0;
    }
    if columns.len() >= 2 && columns.iter().all(|column| column.dock.is_some()) {
        for column in &mut columns {
            if !column.pinned_dock() {
                column.dock = None;
            }
        }
    }
    if columns.len() < 2 || columns.iter().all(|column| column.dock.is_some()) {
        for column in &mut columns {
            column.dock = None;
        }
    }
    Layout::Columns(columns)
}

/// `successor(of:in:)`: the pane that takes the focus from `pane`: the first pane of its sibling in
/// its split tree (its row's, in a column with rows); for a row's only pane, the first pane of the
/// row above, else below; for a column's only pane, the first pane of the nearest column to its
/// left in visual order, else to its right.
pub fn successor(pane: &str, layout: &Layout) -> Option<String> {
    match layout {
        Layout::Splits(root) => {
            parent(pane, root).map(|(_, sibling)| sibling.first_pane().to_owned())
        }
        Layout::Columns(_) => {
            if let Some(column) = layout.column_containing(pane)
                && let Some(tree) = column.tree_containing(pane)
            {
                if let Some((_, sibling)) = parent(pane, tree) {
                    return Some(sibling.first_pane().to_owned());
                }
                if column.has_rows()
                    && let Some(index) = column.row_index(pane)
                {
                    let row =
                        if index > 0 { &column.rows[index - 1] } else { &column.rows[index + 1] };
                    return Some(row.root.first_pane().to_owned());
                }
            }
            let visual = layout.visual_columns();
            let index = visual.iter().position(|column| column.root.contains(pane))?;
            let neighbor = visual[..index].last().or_else(|| visual.get(index + 1));
            neighbor.map(|column| column.root.first_pane().to_owned())
        }
    }
}

// MARK: Close sizing

/// `CloseSizing.parent(of:in:)`: the axis of `pane`'s parent split and the sibling that takes its place.
pub fn parent<'a>(pane: &str, node: &'a Node) -> Option<(Axis, &'a Node)> {
    let Node::Split { axis, a, b, .. } = node else { return None };
    if a.is_leaf(pane) {
        return Some((*axis, b));
    }
    if b.is_leaf(pane) {
        return Some((*axis, a));
    }
    parent(pane, a).or_else(|| parent(pane, b))
}

/// `CloseSizing.tree(in:holding:)`: the split tree `pane` lives in (its column's, or its row's).
fn tree_holding<'a>(layout: &'a Layout, pane: &str) -> Option<&'a Node> {
    match layout {
        Layout::Splits(root) => Some(root).filter(|root| root.contains(pane)),
        Layout::Columns(_) => layout.column_containing(pane)?.tree_containing(pane),
    }
}

/// `CloseSizing.node(in:panes:path:)`: the node holding exactly `panes`, with the splits above it
/// in `path` (root first).
fn node_holding<'a>(
    node: &'a Node,
    panes: &BTreeSet<String>,
    path: &mut Vec<&'a Node>,
) -> Option<&'a Node> {
    if node.panes().into_iter().collect::<BTreeSet<_>>() == *panes {
        return Some(node);
    }
    let Node::Split { a, b, .. } = node else { return None };
    path.push(node);
    if let Some(found) = node_holding(a, panes, path).or_else(|| node_holding(b, panes, path)) {
        return Some(found);
    }
    path.pop();
    None
}

/// `CloseSizing.splitChanges(closing:)`: the even ratios of the closed pane's same-axis chain in
/// `new` (each nested group one cell per pane along the axis).
pub fn split_changes(old: &Layout, new: &Layout, pane: &str) -> Vec<RatioChange> {
    let Some(old_tree) = tree_holding(old, pane) else { return Vec::new() };
    let Some((axis, sibling)) = parent(pane, old_tree) else { return Vec::new() };
    let Some(new_tree) = tree_holding(new, sibling.first_pane()) else { return Vec::new() };
    let kept: BTreeSet<String> = sibling.panes().into_iter().collect();
    let mut path = Vec::new();
    let Some(place) = node_holding(new_tree, &kept, &mut path) else { return Vec::new() };
    // The highest node of the same-axis run directly above the sibling's place, else the place itself.
    let mut top = (place.split_axis() == Some(axis)).then_some(place);
    for node in path.iter().rev() {
        if node.split_axis() != Some(axis) {
            break;
        }
        top = Some(node);
    }
    top.map(|top| equalizing(top, axis)).unwrap_or_default()
}

/// `EvenSplitRatios.changes(equalizing:axis:)`: the ratios that give every cell of the same-axis
/// chain under `top` an equal share; unchanged splits are left out.
pub fn equalizing(top: &Node, axis: Axis) -> Vec<RatioChange> {
    let mut result = Vec::new();
    equalize(top, axis, &mut result);
    result
}

fn equalize(node: &Node, axis: Axis, result: &mut Vec<RatioChange>) {
    let Node::Split { split, axis: node_axis, ratio, a, b } = node else { return };
    if *node_axis != axis {
        return;
    }
    let wa = a.cell_count(axis) as f64;
    let wb = b.cell_count(axis) as f64;
    let even = wa / (wa + wb);
    if (even - ratio).abs() > 1e-6 {
        result.push(RatioChange { split: split.clone(), ratio: even });
    }
    equalize(a, axis, result);
    equalize(b, axis, result);
}

/// `CloseSizing.columnResizes()`: the scrolling columns share the viewport equally after a
/// scrolling column closed, while they fit it.
pub fn column_resizes(old: &Layout, new: &Layout) -> Vec<ColumnResize> {
    let before: Vec<&Column> =
        old.columns().iter().filter(|column| column.dock.is_none()).collect();
    let after: Vec<&Column> = new.columns().iter().filter(|column| column.dock.is_none()).collect();
    if after.len() >= before.len()
        || after.is_empty()
        || before.iter().fold(0.0, |sum, column| sum + column.width) > 1.001
    {
        return Vec::new();
    }
    let share = swift_min(swift_max(1.0 / after.len() as f64, COLUMN_WIDTH_MIN), COLUMN_WIDTH_MAX);
    after
        .into_iter()
        .filter(|column| (column.width - share).abs() > 0.001)
        .map(|column| ColumnResize { column: column.id.clone(), width: share })
        .collect()
}

/// `removing_split_pane` with the sizes the close leaves under `sizing` (one step of the overlay).
fn closing(
    pane: &str,
    layout: &Layout,
    sizing: Sizing,
    mut landed: Option<&mut Landed>,
) -> Option<Layout> {
    let mut after = removing_split_pane(pane, layout)?;
    if sizing.even {
        for change in split_changes(layout, &after, pane) {
            let ratio = clamped_ratio(change.ratio);
            if let Some(landed) = landed.as_deref_mut() {
                landed.ratios.insert(change.split.clone(), ratio);
            }
            after = after.setting_ratio(ratio, &change.split);
        }
    }
    if sizing.fits {
        for resize in column_resizes(layout, &after) {
            if let Some(landed) = landed.as_deref_mut() {
                landed.widths.insert(resize.column.clone(), resize.width);
            }
            after = after.setting_width(resize.width, &resize.column);
        }
    }
    Some(after)
}

// MARK: Showing a close

/// What showing `pane`'s close does (`showPaneClose`, `paneCloseShown`).
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Shown {
    /// The layout without the pane (no sizing: the overlay sizes it).
    pub after: Layout,
    /// The pane that takes the focus.
    pub successor: Option<String>,
    /// The splits whose sent, unacknowledged ratios this close supersedes (even sizing).
    pub splits: Vec<String>,
    /// The columns whose sent widths it supersedes (fit-screen): the resized ones and the gone ones.
    pub columns: Vec<String>,
}

/// `showPaneClose`'s rules for `pane` on a shown, unzoomed `layout`; None when the close cannot
/// show (nothing stays to take its space).
pub fn show(pane: &str, layout: &Layout, sizing: Sizing) -> Option<Shown> {
    let after = removing_split_pane(pane, layout)?;
    let successor = successor(pane, layout);
    let mut splits = Vec::new();
    if sizing.even {
        let set: BTreeSet<String> =
            split_changes(layout, &after, pane).into_iter().map(|c| c.split).collect();
        splits = set.into_iter().collect();
    }
    let mut columns = Vec::new();
    if sizing.fits {
        let kept: BTreeSet<&str> =
            after.columns().iter().map(|column| column.id.as_str()).collect();
        let gone = layout
            .columns()
            .iter()
            .map(|column| column.id.clone())
            .filter(|id| !kept.contains(id.as_str()));
        let set: BTreeSet<String> = column_resizes(layout, &after)
            .into_iter()
            .map(|resize| resize.column)
            .chain(gone)
            .collect();
        columns = set.into_iter().collect();
    }
    Some(Shown { after, successor, splits, columns })
}

// MARK: Landed sizes

/// The sizes of closes that landed while others were pending (`landedCloseRatios`,
/// `landedCloseWidths`), until the daemon has them.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Landed {
    pub ratios: BTreeMap<String, f64>,
    pub widths: BTreeMap<String, f64>,
}

/// `applyingLandedCloseSizes`: `layout` with the landed ratios of its splits and widths of its columns.
pub fn applying_landed_close_sizes(layout: &Layout, landed: &Landed) -> Layout {
    let mut layout = layout.clone();
    for (split, ratio) in &landed.ratios {
        if layout.ratio_of(split).is_some() {
            layout = layout.setting_ratio(*ratio, split);
        }
    }
    for (column, width) in &landed.widths {
        if layout.columns().iter().any(|entry| entry.id == *column) {
            layout = layout.setting_width(*width, column);
        }
    }
    layout
}

/// `overlayingPaneCloses`: `layout` with the landed close sizes, then each pending close in the
/// order it was shown (`closes`): its pane out and the sizes it leaves.
pub fn overlaying_pane_closes(
    layout: &Layout,
    closes: &[String],
    landed: &Landed,
    sizing: Sizing,
) -> Layout {
    let mut layout = applying_landed_close_sizes(layout, landed);
    for pane in closes {
        if !layout.contains(pane) {
            continue;
        }
        if let Some(after) = closing(pane, &layout, sizing, None) {
            layout = after;
        }
    }
    layout
}

/// One screen of a daemon snapshot, as the close rules read it.
#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Screen {
    pub id: String,
    #[serde(default)]
    pub zoomed: bool,
    pub layout: Layout,
}

/// `noteLandedCloses`: shown closes that landed (`landed` left the daemon's tree between `old` and
/// `new`) join `landed` with the sizes each screen's change leaves, one by one in show order
/// (`closes`) against a running tree.
pub fn note_landed_closes(
    old: &[Screen],
    new: &[Screen],
    closes: &[String],
    landed_panes: &BTreeSet<String>,
    landed: &mut Landed,
    sizing: Sizing,
) {
    if landed_panes.is_empty() {
        return;
    }
    for screen in new {
        let Some(before) = old.iter().find(|before| before.id == screen.id) else { continue };
        if before.zoomed
            || screen.zoomed
            || !landed_panes.iter().any(|pane| before.layout.contains(pane))
        {
            continue;
        }
        let mut current = applying_landed_close_sizes(&before.layout, landed);
        for pane in closes {
            if !landed_panes.contains(pane)
                || !current.contains(pane)
                || screen.layout.contains(pane)
            {
                continue;
            }
            if let Some(after) = closing(pane, &current, sizing, Some(landed)) {
                current = after;
            }
        }
    }
}

/// What `flushLandedCloseSizes` sends and keeps.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Flush {
    /// Ratios to send (each differs from the daemon's by more than [`FLUSH_TOLERANCE`]).
    pub ratios: Vec<RatioChange>,
    /// Widths to send.
    pub widths: Vec<ColumnResize>,
    /// The landed sizes still held.
    pub landed: Landed,
}

/// `flushLandedCloseSizes`: the landed close sizes of every daemon screen with no close pending
/// (`closing`), once; a size the daemon already has, or of a split or column gone, is dropped.
pub fn flush_landed_close_sizes(
    screens: &[Layout],
    closing: &BTreeSet<String>,
    landed: &Landed,
) -> Flush {
    let mut flush = Flush { landed: landed.clone(), ..Flush::default() };
    if landed.widths.is_empty() && landed.ratios.is_empty() {
        return flush;
    }
    for layout in screens {
        if closing.iter().any(|pane| layout.contains(pane)) {
            continue;
        }
        let ratios: Vec<(String, f64)> =
            flush.landed.ratios.iter().map(|(k, v)| (k.clone(), *v)).collect();
        for (split, ratio) in ratios {
            let Some(shown) = layout.ratio_of(&split) else { continue };
            flush.landed.ratios.remove(&split);
            if (ratio - shown).abs() > FLUSH_TOLERANCE {
                flush.ratios.push(RatioChange { split, ratio });
            }
        }
        for column in layout.columns() {
            let Some(width) = flush.landed.widths.remove(&column.id) else { continue };
            if (width - column.width).abs() > FLUSH_TOLERANCE {
                flush.widths.push(ColumnResize { column: column.id.clone(), width });
            }
        }
    }
    let columns: BTreeSet<&str> = screens
        .iter()
        .flat_map(|layout| layout.columns().iter().map(|column| column.id.as_str()))
        .collect();
    flush.landed.widths.retain(|column, _| columns.contains(column.as_str()));
    flush
        .landed
        .ratios
        .retain(|split, _| screens.iter().any(|layout| layout.ratio_of(split).is_some()));
    flush
}

/// The sizing intents for the panes that left between two daemon trees (`applyCloseSizing`).
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Intents {
    pub ratios: Vec<RatioChange>,
    pub widths: Vec<ColumnResize>,
}

/// `applyCloseSizing`: for each unzoomed screen that lost panes, the even ratios of each removed
/// pane's chain not among `landed` (shown closes' sizes were noted), and under fit-screen the
/// column widths when no removed pane is landed.
pub fn close_sizing(
    old: &[Screen],
    new: &[Screen],
    landed: &BTreeSet<String>,
    sizing: Sizing,
) -> Intents {
    let mut intents = Intents::default();
    for screen in new {
        let Some(before) = old.iter().find(|before| before.id == screen.id) else { continue };
        if before.zoomed || screen.zoomed {
            continue;
        }
        let stays: BTreeSet<String> = screen.layout.panes().into_iter().collect();
        let mut removed: Vec<String> = Vec::new();
        for pane in before.layout.panes() {
            if !stays.contains(&pane) && !removed.contains(&pane) {
                removed.push(pane);
            }
        }
        if removed.is_empty() {
            continue;
        }
        if sizing.even {
            for pane in removed.iter().filter(|pane| !landed.contains(*pane)) {
                intents.ratios.extend(split_changes(&before.layout, &screen.layout, pane));
            }
        }
        if sizing.fits && removed.iter().all(|pane| !landed.contains(pane)) {
            intents.widths.extend(column_resizes(&before.layout, &screen.layout));
        }
    }
    intents
}

#[cfg(test)]
#[path = "pane_close_tests.rs"]
mod tests;
