//! The Mac app's `LayoutModel` sizing and placement rules in Rust, ported from its Swift one
//! function at a time (`CmuxNextLayout/Model`): the rest of `SplitNode.swift` (the helpers
//! [`crate::screen_layout`] did not have yet), `LayoutModel+SplitSizing.swift` with
//! `Geometry/EvenSplitRatios.swift`'s split side, `LayoutModel+Equalize.swift` with
//! `Geometry/ColumnEqualizer.swift`, `LayoutModel+NewColumn.swift` with `NewColumnWidth.swift`
//! and `NewColumnWidth+Modes.swift`, `PanePlacement.swift`, `MainPaneLayout.swift` and
//! `ChatPlacement.swift`.
//!
//! Every comparison and arithmetic step is the Swift one (`Swift.min`/`max` as
//! [`crate::scroll::swift_min`]/[`crate::scroll::swift_max`]); `schemas/layout-model/vectors.json`
//! pins the Swift rules' answers from before the move. The model state these rules read (the
//! screen holding a pane, the panes the window shows, the live settings) is the caller's: each
//! rule takes it as arguments.

use crate::pane_close::{COLUMN_WIDTH_MAX, COLUMN_WIDTH_MIN, ColumnResize, RatioChange};
use crate::screen_layout::{Axis, Column, Layout, Node, docks};
use crate::scroll::{swift_max, swift_min};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

/// `ColumnWidthPreset.defaultWidth`.
pub const DEFAULT_COLUMN_WIDTH: f64 = 0.5;
/// `DockStripGeometry.maxShare`: the most of the viewport one side dock takes.
pub const DOCK_MAX_SHARE: f64 = 0.75;
/// `DockStripGeometry.maxShareBoth`: the most each takes with a dock on both sides.
pub const DOCK_MAX_SHARE_BOTH: f64 = 0.4;

// MARK: SplitNode

impl Node {
    /// Every split id in the tree, depth first (`splits`).
    pub fn splits(&self) -> Vec<String> {
        match self {
            Node::Leaf { .. } => Vec::new(),
            Node::Split { split, a, b, .. } => {
                let mut result = vec![split.clone()];
                result.extend(a.splits());
                result.extend(b.splits());
                result
            }
        }
    }

    /// Same leaves, splits and axes in the same places; ratios may differ (`hasSameShape(as:)`).
    pub fn has_same_shape(&self, other: &Node) -> bool {
        match (self, other) {
            (Node::Leaf { pane: x }, Node::Leaf { pane: y }) => x == y,
            (
                Node::Split { split: x_id, axis: x_axis, a: xa, b: xb, .. },
                Node::Split { split: y_id, axis: y_axis, a: ya, b: yb, .. },
            ) => x_id == y_id && x_axis == y_axis && xa.has_same_shape(ya) && xb.has_same_shape(yb),
            _ => false,
        }
    }

    /// Axis and children of `split`, if it is in this tree (`node(for:)`).
    pub fn node_for(&self, split: &str) -> Option<(Axis, &Node, &Node)> {
        match self {
            Node::Leaf { .. } => None,
            Node::Split { split: id, axis, a, b, .. } => {
                if id == split {
                    return Some((*axis, a, b));
                }
                a.node_for(split).or_else(|| b.node_for(split))
            }
        }
    }

    /// The ratio for `split` that gives every cell in its same-axis chain equal size
    /// (`equalizedRatio(for:)`).
    pub fn equalized_ratio(&self, split: &str) -> Option<f64> {
        let (axis, a, b) = self.node_for(split)?;
        let a = a.cell_count(axis) as f64;
        let b = b.cell_count(axis) as f64;
        Some(a / (a + b))
    }

    /// A copy with the leaf `pane` replaced by `transform(leaf)` (`replacingLeaf(_:with:)`).
    pub fn replacing_leaf(&self, pane: &str, transform: &dyn Fn(&Node) -> Node) -> Node {
        match self {
            Node::Leaf { pane: leaf } => {
                if leaf == pane {
                    transform(self)
                } else {
                    self.clone()
                }
            }
            Node::Split { split, axis, ratio, a, b } => Node::Split {
                split: split.clone(),
                axis: *axis,
                ratio: *ratio,
                a: Box::new(a.replacing_leaf(pane, transform)),
                b: Box::new(b.replacing_leaf(pane, transform)),
            },
        }
    }
}

impl Column {
    /// The column's trees: its rows', or its own (`trees`).
    pub fn trees(&self) -> Vec<&Node> {
        if self.has_rows() {
            self.rows.iter().map(|row| &row.root).collect()
        } else {
            vec![&self.root]
        }
    }
}

/// `ScreenLayout.tree(containing split:)`: the split tree that holds `split`.
pub fn tree_holding_split<'a>(layout: &'a Layout, split: &str) -> Option<&'a Node> {
    match layout {
        Layout::Splits(root) => root.node_for(split).map(|_| root),
        Layout::Columns(columns) => columns.iter().find_map(|column| {
            column.trees().into_iter().find(|tree| tree.node_for(split).is_some())
        }),
    }
}

// MARK: Split sizing

/// `EvenSplitRatios.changes(splitting:axis:in:)`: the ratio changes for splitting `pane` along
/// `axis` in `root`: every split of the same-axis chain that will hold the new split, set so each
/// cell of that chain (the split pane counting as two) gets an equal share. Unchanged splits are
/// left out.
pub fn even_split_changes(pane: &str, axis: Axis, root: &Node) -> Vec<RatioChange> {
    let Some(top) = chain_top(pane, axis, root) else { return Vec::new() };
    let mut result = Vec::new();
    collect(top, pane, axis, &mut result);
    result
}

/// `EvenSplitRatios.chainTop`: the highest node of the same-axis chain directly above `pane`; None
/// when the pane's parent splits across the other axis (or it is the root).
fn chain_top<'a>(pane: &str, axis: Axis, root: &'a Node) -> Option<&'a Node> {
    let mut path: Vec<&Node> = Vec::new();
    if !ancestors(pane, root, &mut path) {
        return None;
    }
    let mut top = None;
    for node in path.into_iter().rev() {
        if node.split_axis() != Some(axis) {
            break;
        }
        top = Some(node);
    }
    top
}

/// `EvenSplitRatios.ancestors`: fills `path` with the split nodes from `node` down to `pane`'s parent.
fn ancestors<'a>(pane: &str, node: &'a Node, path: &mut Vec<&'a Node>) -> bool {
    let Node::Split { a, b, .. } = node else { return false };
    path.push(node);
    if a.is_leaf(pane) || b.is_leaf(pane) {
        return true;
    }
    if ancestors(pane, a, path) || ancestors(pane, b, path) {
        return true;
    }
    path.pop();
    false
}

/// `EvenSplitRatios.weight`: cells along `axis`, the split pane counting as two.
fn weight(node: &Node, pane: &str, axis: Axis) -> f64 {
    (node.cell_count(axis) + usize::from(node.contains(pane))) as f64
}

fn collect(node: &Node, pane: &str, axis: Axis, result: &mut Vec<RatioChange>) {
    let Node::Split { split, axis: node_axis, ratio, a, b } = node else { return };
    if *node_axis != axis {
        return;
    }
    let wa = weight(a, pane, axis);
    let wb = weight(b, pane, axis);
    let even = wa / (wa + wb);
    if (even - ratio).abs() > 1e-6 {
        result.push(RatioChange { split: split.clone(), ratio: even });
    }
    collect(a, pane, axis, result);
    collect(b, pane, axis, result);
}

/// `LayoutModel.splitSizingChanges(splitting:axis:removing:)` on `layout`, the layout of the screen
/// holding `pane`: the ratio changes splitting `pane` along `axis` needs (empty unless `even`, the
/// `layout.splitSizing` setting). `removing` is a pane the same move closes: the changes are
/// computed without it.
pub fn split_sizing_changes(
    layout: &Layout,
    pane: &str,
    axis: Axis,
    removing: Option<&str>,
    even: bool,
) -> Vec<RatioChange> {
    if !even {
        return Vec::new();
    }
    let tree: Option<&Node> = match layout {
        Layout::Splits(root) => Some(root),
        Layout::Columns(_) => {
            layout.column_containing(pane).and_then(|column| column.tree_containing(pane))
        }
    };
    let pruned: Option<Node> = removing
        .and_then(|removing| if removing == pane { None } else { tree?.removing(removing) })
        .or_else(|| tree.cloned());
    pruned.map(|root| even_split_changes(pane, axis, &root)).unwrap_or_default()
}

// MARK: Equalize

/// One value of an equalize change (`DividerDragValue`): a split's ratio or a column's width.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum EqualizeValue {
    Ratio { split: String, ratio: f64 },
    Width { column: String, width: f64 },
}

/// What equalizing a screen asks for (`EqualizeResult`, before the app sends it).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum EqualizeOutcome {
    /// Neither a split nor two columns side by side.
    NothingToEqualize,
    /// These values go out as one change (none when all were equal already).
    Equalize(Vec<EqualizeValue>),
}

/// The screen `equalize(screen:viewportWidth:)` reads.
#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EqualizeScreen {
    pub layout: Layout,
    #[serde(default)]
    pub zoomed: bool,
    /// The panes the window shows (`visiblePanes`).
    #[serde(default)]
    pub visible_panes: BTreeSet<String>,
    /// The screen's width in points; None keeps every dock's width.
    #[serde(default)]
    pub viewport_width: Option<f64>,
    /// `LayoutStyle.stripGap`.
    #[serde(default)]
    pub gap: f64,
    /// Each column's minimum width in points (`LayoutColumn.minimumSize(style:).width`).
    #[serde(default)]
    pub minimum_widths: BTreeMap<String, f64>,
}

/// `LayoutModel.equalize(screen:viewportWidth:)`'s rules: even ratios for every split and, on an
/// unzoomed columns screen, the same width for every column the window shows side by side.
pub fn equalize(screen: &EqualizeScreen) -> EqualizeOutcome {
    let trees: Vec<&Node> = match &screen.layout {
        Layout::Splits(root) => vec![root],
        Layout::Columns(columns) => columns.iter().flat_map(Column::trees).collect(),
    };
    let mut values = Vec::new();
    let mut has_splits = false;
    for tree in trees {
        for split in tree.splits() {
            has_splits = true;
            if let (Some(ratio), Some(current)) =
                (tree.equalized_ratio(&split), tree.ratio_of(&split))
                && (current - ratio).abs() > 1e-6
            {
                values.push(EqualizeValue::Ratio { split, ratio });
            }
        }
    }
    let mut has_columns = false;
    if !screen.zoomed
        && let Layout::Columns(columns) = &screen.layout
    {
        let visible: BTreeSet<String> = columns
            .iter()
            .filter(|column| {
                column.root.panes().iter().any(|pane| screen.visible_panes.contains(pane))
            })
            .map(|column| column.id.clone())
            .collect();
        let equalizer = ColumnEqualizer {
            columns,
            visible: &visible,
            viewport_width: screen.viewport_width.unwrap_or(0.0),
            gap: screen.gap,
            minimum_widths: &screen.minimum_widths,
        };
        let shared = docks(columns);
        let strip = shared.scrolling.iter().filter(|column| column.dock.is_none()).count();
        let sides = [&shared.left, &shared.right]
            .into_iter()
            .flatten()
            .filter(|column| column.dock.as_ref().is_some_and(|dock| dock.mode == "docked"))
            .count();
        has_columns = strip + sides > 1;
        values.extend(
            equalizer
                .resizes()
                .into_iter()
                .map(|resize| EqualizeValue::Width { column: resize.column, width: resize.width }),
        );
    }
    if !has_splits && !has_columns {
        return EqualizeOutcome::NothingToEqualize;
    }
    EqualizeOutcome::Equalize(values)
}

/// `LayoutModel.equalizeSplit(_:)`: the ratio that evens `split`'s same-axis chain, from the first
/// of `layouts` (the screens in order) whose tree holds it.
pub fn equalize_split(layouts: &[Layout], split: &str) -> Option<f64> {
    let tree = layouts.iter().find_map(|layout| tree_holding_split(layout, split))?;
    tree.equalized_ratio(split)
}

/// `ColumnEqualizer`: the column widths Equalize Splits gives a columns screen.
pub struct ColumnEqualizer<'a> {
    /// The screen's columns, in daemon order.
    pub columns: &'a [Column],
    /// The strip columns the window shows now; empty when unknown.
    pub visible: &'a BTreeSet<String>,
    /// The screen's viewport width in points.
    pub viewport_width: f64,
    /// The strip gap.
    pub gap: f64,
    /// Each column's minimum width in points (0 when absent).
    pub minimum_widths: &'a BTreeMap<String, f64>,
}

impl ColumnEqualizer<'_> {
    fn minimum_width(&self, column: &Column) -> f64 {
        self.minimum_widths.get(&column.id).copied().unwrap_or(0.0)
    }

    /// `equalWidth(stripColumns:)`: the width each of `count` strip columns and the docked sides get.
    fn equal_width(&self, sides: usize, count: usize) -> f64 {
        let total = (sides + count) as f64;
        (self.viewport_width - (total + 1.0) * self.gap) / total
    }

    /// `resizes`: the widths that differ from the ones the columns have; empty when equal already.
    pub fn resizes(&self) -> Vec<ColumnResize> {
        let parts = docks(self.columns);
        let strip: Vec<&Column> =
            parts.scrolling.iter().filter(|column| column.dock.is_none()).collect();
        if strip.is_empty() {
            return Vec::new();
        }
        let clamped = |value: f64| swift_min(swift_max(value, COLUMN_WIDTH_MIN), COLUMN_WIDTH_MAX);
        let mut result = Vec::new();
        let mut set = |column: &Column, width: f64| {
            if (column.width - width).abs() > 0.001 {
                result.push(ColumnResize { column: column.id.clone(), width });
            }
        };
        let sides: Vec<&Column> = [&parts.left, &parts.right]
            .into_iter()
            .flatten()
            .filter(|column| column.dock.as_ref().is_some_and(|dock| dock.mode == "docked"))
            .collect();
        let widest =
            strip.iter().map(|column| self.minimum_width(column)).reduce(swift_max).unwrap_or(0.0);
        let fits_all = 1.0 / strip.len() as f64 >= COLUMN_WIDTH_MIN
            && (self.viewport_width <= 0.0 || self.equal_width(sides.len(), strip.len()) >= widest);
        let shown = strip.iter().filter(|column| self.visible.contains(&column.id)).count();
        let strip_count = if fits_all || shown == 0 { strip.len() } else { shown };
        if !sides.is_empty() && self.viewport_width > self.gap {
            let equal = self.equal_width(sides.len(), strip_count);
            let share = if parts.left.is_some() && parts.right.is_some() {
                DOCK_MAX_SHARE_BOTH
            } else {
                DOCK_MAX_SHARE
            } * self.viewport_width;
            for dock in &sides {
                let width = swift_min(swift_max(equal, self.minimum_width(dock)), share);
                set(dock, clamped(fraction_for_pixel_width(width, self.viewport_width, self.gap)));
            }
        }
        let each = clamped(1.0 / strip_count as f64);
        for column in strip {
            set(column, each);
        }
        result
    }
}

/// `ColumnStripGeometry.fraction(forPixelWidth:viewportWidth:gap:)`: the width fraction that shows
/// a column `width` points wide.
pub fn fraction_for_pixel_width(width: f64, viewport_width: f64, gap: f64) -> f64 {
    let denominator = viewport_width - gap;
    if denominator.is_nan() || denominator <= 0.0 {
        return DEFAULT_COLUMN_WIDTH;
    }
    let value = (width + gap) / denominator;
    swift_min(swift_max(value, COLUMN_WIDTH_MIN), COLUMN_WIDTH_MAX)
}

// MARK: New column

/// `NewColumnWidthMode` (`layout.newColumnWidth`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum NewColumnWidthMode {
    /// The width of the column it opens next to.
    MatchCurrent,
    /// The visible scrolling columns and the new one share the strip.
    FitScreen,
    /// `layout.defaultColumnWidth`.
    Fixed,
}

/// `NewColumnWidth.plan(width:)`: `width` clamped to the daemon's range.
pub fn new_column_plan_width(width: f64) -> f64 {
    swift_min(swift_max(width, COLUMN_WIDTH_MIN), COLUMN_WIDTH_MAX)
}

/// `NewColumnWidth.plan(mode:columns:anchor:visible:fixedWidth:removing:)`: the width of a column
/// opening next to `anchor`. A screen with no scrolling column left gives it the whole strip.
pub fn new_column_plan(
    mode: NewColumnWidthMode,
    columns: &[Column],
    anchor: Option<&str>,
    visible: &[String],
    fixed_width: f64,
    removing: Option<&str>,
) -> f64 {
    let scrolling_stays = columns.iter().any(|column| {
        column.dock.is_none()
            && column.root.panes().iter().any(|pane| Some(pane.as_str()) != removing)
    });
    if !columns.is_empty() && !scrolling_stays {
        return 1.0;
    }
    match mode {
        NewColumnWidthMode::Fixed => new_column_plan_width(fixed_width),
        NewColumnWidthMode::MatchCurrent => new_column_plan_width(
            anchor
                .and_then(|id| {
                    columns.iter().find(|column| column.id == id).map(|column| column.width)
                })
                .unwrap_or(1.0),
        ),
        NewColumnWidthMode::FitScreen => {
            let scrolling: BTreeSet<&str> = columns
                .iter()
                .filter(|column| column.dock.is_none())
                .map(|column| column.id.as_str())
                .collect();
            let mut shared: Vec<&str> =
                visible.iter().map(String::as_str).filter(|id| scrolling.contains(id)).collect();
            if let Some(anchor) = anchor
                && scrolling.contains(anchor)
                && !shared.contains(&anchor)
            {
                shared.push(anchor);
            }
            new_column_plan_width(1.0 / (shared.len() + 1) as f64)
        }
    }
}

/// `LayoutModel.newColumnWidth(nextTo:removing:)` on `layout`, the layout of the screen holding
/// `pane` (None when no screen holds it): a split-tree screen counts as one full-width column.
pub fn new_column_width(
    layout: Option<&Layout>,
    pane: &str,
    visible_panes: &BTreeSet<String>,
    mode: NewColumnWidthMode,
    fixed_width: f64,
    removing: Option<&str>,
) -> f64 {
    let columns: Vec<Column> = match layout {
        Some(Layout::Splits(root)) => vec![Column {
            id: "unscrolled".to_owned(),
            width: 1.0,
            root: root.clone(),
            dock: None,
            rows: Vec::new(),
        }],
        Some(Layout::Columns(columns)) => columns.clone(),
        None => Vec::new(),
    };
    let anchor =
        columns.iter().find(|column| column.root.contains(pane)).map(|column| column.id.as_str());
    let visible: Vec<String> = columns
        .iter()
        .filter(|column| column.root.panes().iter().any(|pane| visible_panes.contains(pane)))
        .map(|column| column.id.clone())
        .collect();
    new_column_plan(mode, &columns, anchor, &visible, fixed_width, removing)
}

// MARK: Pane placement

/// A pane's frame (`CGRect`), in points.
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Frame {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Frame {
    /// `CGRect.width`: standardized, never negative.
    fn shown_width(&self) -> f64 {
        self.width.abs()
    }

    /// `CGRect.height`: standardized, never negative.
    fn shown_height(&self) -> f64 {
        self.height.abs()
    }
}

/// `PanePlacement.Split`: the pane Auto Layout splits and the axis.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct AutoSplit {
    pub pane: String,
    pub axis: Axis,
}

/// `PanePlacement.Plan`: what opening a new terminal or browser does.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PanePlan {
    /// A tab in this pane.
    Tab(String),
    /// A new pane splitting this one along the axis.
    Split(AutoSplit),
}

/// `NewPanePlacement` (`layout.newPanePlacement`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum NewPanePlacement {
    Tab,
    Split,
}

/// `PanePlacement.plan(layout:focused:recent:frames:placement:tiles:)`.
pub fn pane_plan(
    layout: &Layout,
    focused: &str,
    recent: &[String],
    frames: &BTreeMap<String, Frame>,
    placement: NewPanePlacement,
    tiles: bool,
) -> PanePlan {
    if placement == NewPanePlacement::Split
        && tiles
        && let Some(split) = auto_split(layout, frames, recent)
    {
        return PanePlan::Split(split);
    }
    PanePlan::Tab(focused.to_owned())
}

/// `PanePlacement.autoSplit(layout:frames:recent:)`: the largest shown pane of a scrolling column,
/// split along its longer side (width first on a tie). Equal areas prefer the most recently
/// focused pane, then visual order. With no scrolling pane shown, the most recent scrolling pane
/// (else the first) splits along its width. None only when the screen has no scrolling pane.
pub fn auto_split(
    layout: &Layout,
    frames: &BTreeMap<String, Frame>,
    recent: &[String],
) -> Option<AutoSplit> {
    let candidates: Vec<String> = match layout {
        Layout::Splits(root) => root.panes(),
        Layout::Columns(columns) => columns
            .iter()
            .filter(|column| column.dock.is_none())
            .flat_map(|column| column.root.panes())
            .collect(),
    };
    let mut best: Option<(&str, Frame, usize)> = None;
    for (order, pane) in candidates.iter().enumerate() {
        let Some(frame) = frames.get(pane) else { continue };
        if !(frame.shown_width() > 0.0 && frame.shown_height() > 0.0) {
            continue;
        }
        let rank = recent.iter().position(|id| id == pane).unwrap_or(recent.len() + order);
        let area = frame.shown_width() * frame.shown_height();
        if let Some((_, current, current_rank)) = best {
            let current_area = current.shown_width() * current.shown_height();
            if !(area > current_area || (area == current_area && rank < current_rank)) {
                continue;
            }
        }
        best = Some((pane, *frame, rank));
    }
    if let Some((pane, frame, _)) = best {
        let axis = if frame.shown_width() >= frame.shown_height() {
            Axis::Horizontal
        } else {
            Axis::Vertical
        };
        return Some(AutoSplit { pane: pane.to_owned(), axis });
    }
    let fallback = recent.iter().find(|pane| candidates.contains(pane)).or(candidates.first())?;
    Some(AutoSplit { pane: fallback.clone(), axis: Axis::Horizontal })
}

// MARK: Main pane, chat placement

/// `MainPaneOverride`: Debug Settings' choice for main pane layout.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum MainPaneOverride {
    Setting,
    On,
    Off,
}

/// `MainPaneLayout.isOn(setting:override:)`: the Debug override, else the setting.
pub fn main_pane_is_on(setting: bool, override_: MainPaneOverride) -> bool {
    match override_ {
        MainPaneOverride::Setting => setting,
        MainPaneOverride::On => true,
        MainPaneOverride::Off => false,
    }
}

/// `ChatColumnPlacement`: where a person's new tab opened from an agent chat goes.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ChatColumnPlacement {
    Here,
    Tab(String),
    DockChat,
    BesideDock,
}

/// `MainPaneLayout.side(of:)`: `placement` when it puts the new tab beside the chat.
pub fn main_pane_side(placement: &ChatColumnPlacement) -> Option<ChatColumnPlacement> {
    match placement {
        ChatColumnPlacement::Tab(_) | ChatColumnPlacement::DockChat => Some(placement.clone()),
        ChatColumnPlacement::Here | ChatColumnPlacement::BesideDock => None,
    }
}

/// `ChatColumnPlacement.DockPick`: what a pick on a New Tab page in the chat dock does.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum DockPick {
    /// The usual route (nothing beside the dock).
    Usual,
    /// The pick opens in the strip beside the dock.
    #[serde(rename_all = "camelCase")]
    Beside { closes_page: bool },
}

/// `DockPick.resolve(hasStrip:keep:)`.
pub fn dock_pick(has_strip: bool, keep: bool) -> DockPick {
    if has_strip { DockPick::Beside { closes_page: !keep } } else { DockPick::Usual }
}

/// `ChatColumnPlacement.columns(of:containing:)`: the screen's columns in strip order; a screen
/// stored as one split tree is one implicit column (`implicit:<screen>`) when it holds `pane`.
pub fn chat_columns(screen_id: &str, layout: &Layout, pane: &str) -> Vec<Column> {
    if !layout.columns().is_empty() {
        return layout.columns().to_vec();
    }
    match layout {
        Layout::Splits(root) if root.contains(pane) => vec![Column {
            id: format!("implicit:{screen_id}"),
            width: 1.0,
            root: root.clone(),
            dock: None,
            rows: Vec::new(),
        }],
        Layout::Splits(_) => Vec::new(),
        Layout::Columns(_) => layout.column_containing(pane).cloned().into_iter().collect(),
    }
}

#[cfg(test)]
#[path = "layout_model_tests.rs"]
mod tests;
