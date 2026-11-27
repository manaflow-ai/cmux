//! The Mac app's `LayoutModel` rules (`CmuxNextLayout/Model`), with the app's string ids: the
//! transitions and computations the `@Observable` class runs, as values in and values out. The
//! class keeps its observation plumbing, settings and views; what it decides is here:
//!
//! - [`Model`]: the screens shown, the daemon's last snapshot, the active screen, the focused pane
//!   and its ring, the gesture overrides ([`GestureOverride`]) and their replies
//!   ([`TransactionReplies`]). [`Model::apply`] takes a daemon snapshot (`apply(screens:)`), the
//!   gesture setters show and send a divider ratio or column width, [`Model::settle`] and
//!   [`Model::reject`] answer a transaction, [`Model::focus`] and [`Model::select_screen`] move the
//!   focus. Each returns the [`Intent`]s the class emits, in its order.
//! - [`EndedValues`]: a key press's or drag release's values, sent as one change, all or nothing.
//! - The `ScreenLayout` and `LayoutScreen` queries not in [`crate::screen_layout`] yet
//!   ([`visual_panes`], [`tree_with_split`], [`has_same_structure`], [`setting_row_heights`],
//!   [`setting_dock`], [`Screen`]).
//! - `LayoutFloatingPane`'s geometry in points ([`Rect`]; the daemon's millionths rules are
//!   [`crate::floating_panes`]), `DividerInsertPlan` on the app's tree (the daemon tree's rule is
//!   [`crate::divider_insert`]) and the layout cache's view of the shown screen
//!   ([`cache_node`], [`cache_live`], [`cache_drift`]).
//!
//! A pending pane close ([`crate::pane_close`]) is overlaid first, as `overlaid(_:)` does: the
//! model carries the closes the class holds ([`PaneCloses`]); noting and resolving them stays
//! `pane_close`'s.
//!
//! Every comparison is the Swift one (`Swift.min`/`max` as [`swift_min`]/[`swift_max`]);
//! `schemas/layout-model/vectors.json` pins the Swift rules' answers from before the move.

use crate::pane_close::{
    COLUMN_WIDTH_MAX, COLUMN_WIDTH_MIN, Landed, RatioChange, Sizing, clamped_ratio,
    overlaying_pane_closes,
};
use crate::screen_layout::{AGENT_CHAT, Axis, Column, Dock, Layout, Node};
use crate::scroll::{swift_max, swift_min};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};

/// An ended override whose value the daemon reports within this is confirmed (`overlaid`).
pub const CONFIRM_TOLERANCE: f64 = 0.002;

// MARK: ScreenLayout and LayoutScreen

/// `SplitNode.node(for:)`: the axis and sides of `split`.
pub fn node_for<'a>(node: &'a Node, split: &str) -> Option<(Axis, &'a Node, &'a Node)> {
    match node {
        Node::Leaf { .. } => None,
        Node::Split { split: id, axis, a, b, .. } => {
            if id == split {
                return Some((*axis, a, b));
            }
            node_for(a, split).or_else(|| node_for(b, split))
        }
    }
}

/// `SplitNode.hasSameShape`: same panes and splits in the same places; ratios may differ.
pub fn same_shape(x: &Node, y: &Node) -> bool {
    match (x, y) {
        (Node::Leaf { pane: x }, Node::Leaf { pane: y }) => x == y,
        (
            Node::Split { split: x_id, axis: x_axis, a: xa, b: xb, .. },
            Node::Split { split: y_id, axis: y_axis, a: ya, b: yb, .. },
        ) => x_id == y_id && x_axis == y_axis && same_shape(xa, ya) && same_shape(xb, yb),
        _ => false,
    }
}

/// `LayoutColumn.trees`: each row's tree, or the column's own.
pub fn trees(column: &Column) -> Vec<&Node> {
    if column.has_rows() {
        column.rows.iter().map(|row| &row.root).collect()
    } else {
        vec![&column.root]
    }
}

/// `LayoutColumn.hasSameRows`: same rows with the same tree shapes; heights may differ.
fn same_rows(x: &Column, y: &Column) -> bool {
    x.rows.len() == y.rows.len()
        && x.rows.iter().zip(&y.rows).all(|(x, y)| x.id == y.id && same_shape(&x.root, &y.root))
}

/// `ScreenLayout.visualPanes`: panes in the order the person sees them (docks at their edges).
pub fn visual_panes(layout: &Layout) -> Vec<String> {
    match layout {
        Layout::Splits(root) => root.panes(),
        Layout::Columns(_) => {
            layout.visual_columns().iter().flat_map(|column| column.root.panes()).collect()
        }
    }
}

/// `ScreenLayout.tree(containing: split)`: the split tree holding `split`.
pub fn tree_with_split<'a>(layout: &'a Layout, split: &str) -> Option<&'a Node> {
    match layout {
        Layout::Splits(root) => node_for(root, split).map(|_| root),
        Layout::Columns(columns) => columns.iter().find_map(|column| {
            trees(column).into_iter().find(|tree| node_for(tree, split).is_some())
        }),
    }
}

/// `ScreenLayout.hasSameStructure`: same panes, splits and columns in the same places.
pub fn has_same_structure(x: &Layout, y: &Layout) -> bool {
    match (x, y) {
        (Layout::Splits(x), Layout::Splits(y)) => same_shape(x, y),
        (Layout::Columns(x), Layout::Columns(y)) => {
            x.len() == y.len()
                && x.iter().zip(y).all(|(x, y)| {
                    x.id == y.id
                        && x.dock == y.dock
                        && same_shape(&x.root, &y.root)
                        && same_rows(x, y)
                })
        }
        _ => false,
    }
}

/// `RowHeight`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct RowHeight {
    pub row: String,
    pub height: i64,
}

/// `ScreenLayout.settingRowHeights`: `column`'s named rows at new heights (the last of a row wins).
pub fn setting_row_heights(layout: &Layout, heights: &[RowHeight], column: &str) -> Layout {
    let Layout::Columns(columns) = layout else { return layout.clone() };
    let by_row: BTreeMap<&str, i64> =
        heights.iter().map(|height| (height.row.as_str(), height.height)).collect();
    Layout::Columns(
        columns
            .iter()
            .map(|entry| {
                let mut entry = entry.clone();
                if entry.id == column {
                    for row in &mut entry.rows {
                        row.height = by_row.get(row.id.as_str()).copied().unwrap_or(row.height);
                    }
                }
                entry
            })
            .collect(),
    )
}

/// `ScreenLayout.settingDock`: `column` docked (or scrolling for None); another column on the same
/// edge scrolls again.
pub fn setting_dock(layout: &Layout, dock: Option<&Dock>, column: &str) -> Layout {
    let Layout::Columns(columns) = layout else { return layout.clone() };
    Layout::Columns(
        columns
            .iter()
            .map(|entry| {
                let mut entry = entry.clone();
                if entry.id == column {
                    entry.dock = dock.cloned();
                } else if let Some(dock) = dock
                    && entry.dock.as_ref().is_some_and(|own| own.edge == dock.edge)
                {
                    entry.dock = None;
                }
                entry
            })
            .collect(),
    )
}

/// `LayoutScreen`: one screen of a workspace.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Screen {
    pub id: String,
    #[serde(default)]
    pub name: String,
    pub layout: Layout,
    #[serde(default)]
    pub zoomed: bool,
    #[serde(default)]
    pub presented: bool,
    #[serde(default)]
    pub hidden_dividers: BTreeSet<String>,
    /// Back to front; `layout` has none of them.
    #[serde(default)]
    pub floating: Vec<FloatingPane>,
}

impl Screen {
    /// The tiled panes, then the floating panes back to front.
    pub fn panes(&self) -> Vec<String> {
        let mut panes = self.layout.panes();
        panes.extend(self.floating.iter().map(|floating| floating.pane.clone()));
        panes
    }

    /// The panes in visual order, then the floating panes back to front.
    pub fn visual_panes(&self) -> Vec<String> {
        let mut panes = visual_panes(&self.layout);
        panes.extend(self.floating.iter().map(|floating| floating.pane.clone()));
        panes
    }

    /// Whether `pane` is a pane of the screen, tiled or floating.
    pub fn contains(&self, pane: &str) -> bool {
        self.layout.contains(pane) || self.floats(pane)
    }

    pub fn floats(&self, pane: &str) -> bool {
        self.floating.iter().any(|floating| floating.pane == pane)
    }

    /// `floatingPanes`: the set of the floating panes.
    pub fn floating_panes(&self) -> BTreeSet<String> {
        self.floating.iter().map(|floating| floating.pane.clone()).collect()
    }

    /// The id of the one implicit column of a screen stored as one split tree.
    pub fn implicit_column_id(&self) -> String {
        format!("implicit:{}", self.id)
    }

    /// `column(containing:)`: a stored column, or the implicit column of a split tree.
    pub fn column_containing(&self, pane: &str) -> Option<Column> {
        match &self.layout {
            Layout::Splits(root) => root.contains(pane).then(|| self.implicit(root.clone())),
            Layout::Columns(_) => self.layout.column_containing(pane).cloned(),
        }
    }

    /// `inAgentChatDock`: `pane` is in a docked column with the agent chat role.
    pub fn in_agent_chat_dock(&self, pane: &str) -> bool {
        self.column_containing(pane)
            .and_then(|column| column.dock)
            .is_some_and(|dock| dock.role.as_deref() == Some(AGENT_CHAT))
    }

    /// `column(id:)`, including the implicit one.
    pub fn column_by_id(&self, id: &str) -> Option<Column> {
        match &self.layout {
            Layout::Splits(root) => {
                (id == self.implicit_column_id()).then(|| self.implicit(root.clone()))
            }
            Layout::Columns(columns) => columns.iter().find(|column| column.id == id).cloned(),
        }
    }

    fn implicit(&self, root: Node) -> Column {
        Column { id: self.implicit_column_id(), width: 1.0, root, dock: None, rows: Vec::new() }
    }
}

// MARK: Floating panes

/// A `CGRect`, origin at the top left.
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Rect {
    pub const UNIT: Rect = Rect { x: 0.0, y: 0.0, width: 1.0, height: 1.0 };

    pub fn new(x: f64, y: f64, width: f64, height: f64) -> Rect {
        Rect { x, y, width, height }
    }

    /// `CGRect.minX` (a negative width counts from the far edge).
    pub fn min_x(&self) -> f64 {
        swift_min(self.x, self.x + self.width)
    }

    pub fn max_x(&self) -> f64 {
        swift_max(self.x, self.x + self.width)
    }

    pub fn min_y(&self) -> f64 {
        swift_min(self.y, self.y + self.height)
    }

    pub fn max_y(&self) -> f64 {
        swift_max(self.y, self.y + self.height)
    }

    /// `CGRect.width`: never negative.
    pub fn abs_width(&self) -> f64 {
        self.width.abs()
    }

    pub fn abs_height(&self) -> f64 {
        self.height.abs()
    }
}

/// `LayoutFloatingPane`: a pane above the tiled ones, its frame fractions of the pane area.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct FloatingPane {
    pub pane: String,
    pub frame: Rect,
}

/// The smallest width and height of a floating pane, a fraction of the pane area.
pub const FLOATING_MINIMUM_EXTENT: f64 = 0.15;
/// The bar at a card's top that moves the pane, and the rim on its other sides that resizes it.
pub const FLOATING_BAR_HEIGHT: f64 = 14.0;
pub const FLOATING_RIM_WIDTH: f64 = 5.0;

/// `LayoutFloatingPane.clamped`: `frame` in the unit square, no smaller than the minimum extent
/// (the size first, then the corner).
pub fn floating_clamped(frame: Rect) -> Rect {
    let width = swift_min(swift_max(frame.abs_width(), FLOATING_MINIMUM_EXTENT), 1.0);
    let height = swift_min(swift_max(frame.abs_height(), FLOATING_MINIMUM_EXTENT), 1.0);
    Rect::new(
        swift_min(swift_max(frame.min_x(), 0.0), 1.0 - width),
        swift_min(swift_max(frame.min_y(), 0.0), 1.0 - height),
        width,
        height,
    )
}

/// `LayoutFloatingPane.rect(in:scale:)`: the frame in a pane area of `size`, each edge on the
/// pixel grid of `scale`.
pub fn floating_rect(frame: Rect, width: f64, height: f64, scale: f64) -> Rect {
    let snap = |value: f64| if scale > 0.0 { (value * scale).round() / scale } else { value };
    let min_x = snap(frame.min_x() * width);
    let min_y = snap(frame.min_y() * height);
    let max_x = snap(frame.max_x() * width);
    let max_y = snap(frame.max_y() * height);
    Rect::new(min_x, min_y, swift_max(0.0, max_x - min_x), swift_max(0.0, max_y - min_y))
}

/// `LayoutFloatingPane.paneRect(inCard:)`: below the bar and inside the rim.
pub fn floating_pane_rect(card: Rect) -> Rect {
    Rect::new(
        card.min_x() + FLOATING_RIM_WIDTH,
        card.min_y() + FLOATING_BAR_HEIGHT,
        swift_max(0.0, card.abs_width() - FLOATING_RIM_WIDTH * 2.0),
        swift_max(0.0, card.abs_height() - FLOATING_BAR_HEIGHT - FLOATING_RIM_WIDTH),
    )
}

/// `LayoutFloatingPane.cardRect(aroundPane:)`: the inverse of [`floating_pane_rect`].
pub fn floating_card_rect(pane: Rect) -> Rect {
    Rect::new(
        pane.min_x() - FLOATING_RIM_WIDTH,
        pane.min_y() - FLOATING_BAR_HEIGHT,
        pane.abs_width() + FLOATING_RIM_WIDTH * 2.0,
        pane.abs_height() + FLOATING_BAR_HEIGHT + FLOATING_RIM_WIDTH,
    )
}

/// `LayoutFloatingPane.fractions(of:in:)`: the fractions of a pane area of `size` that `rect`
/// covers; the unit square for an empty area.
pub fn floating_fractions(rect: Rect, width: f64, height: f64) -> Rect {
    if !(width > 0.0 && height > 0.0) {
        return Rect::UNIT;
    }
    Rect::new(
        rect.min_x() / width,
        rect.min_y() / height,
        rect.abs_width() / width,
        rect.abs_height() / height,
    )
}

/// `LayoutFloatingPane.raise`: the intent that brings a focused floating pane to the front; None
/// for a tiled pane, the front pane and a focus a scroll moved.
pub fn floating_raise(
    pane: &str,
    floating: &[FloatingPane],
    source: FocusSource,
) -> Option<Intent> {
    if source == FocusSource::Scroll
        || floating.last().is_some_and(|last| last.pane == pane)
        || !floating.iter().any(|entry| entry.pane == pane)
    {
        return None;
    }
    Some(Intent::RaiseFloatingPane { pane: pane.to_owned() })
}

// MARK: Divider insert

/// `DividerInsertPlan.dividerRatio`.
pub const DIVIDER_RATIO: f64 = 2.0 / 3.0;

/// `DividerInsertPlan`: where Insert New at a split's divider puts its pane.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct DividerInsertPlan {
    /// `a`'s last pane, which touches the divider.
    pub target: String,
    /// `a`'s split when `a` is more than one pane.
    pub around: Option<String>,
    pub axis: Axis,
    pub sizing: Vec<RatioChange>,
}

/// `SplitNode.dividerInsertPlan(at:)`.
pub fn divider_insert_plan(tree: &Node, split: &str) -> Option<DividerInsertPlan> {
    let (axis, a, _) = node_for(tree, split)?;
    let target = a.panes().last()?.clone();
    let around = match a {
        Node::Split { split: id, .. } => Some(id.clone()),
        Node::Leaf { .. } => None,
    };
    Some(DividerInsertPlan {
        target,
        around,
        axis,
        sizing: vec![RatioChange { split: split.to_owned(), ratio: DIVIDER_RATIO }],
    })
}

/// `SplitNode.divider(beside:)`: the innermost split with `pane` on its first side, else the
/// innermost split holding it.
pub fn divider_beside(tree: &Node, pane: &str) -> Option<String> {
    let Node::Split { split: id, a, b, .. } = tree else { return None };
    if !tree.contains(pane) {
        return None;
    }
    if a.contains(pane) {
        return Some(divider_after(a, pane).unwrap_or_else(|| id.clone()));
    }
    Some(divider_beside(b, pane).unwrap_or_else(|| id.clone()))
}

fn divider_after(tree: &Node, pane: &str) -> Option<String> {
    let Node::Split { split: id, a, b, .. } = tree else { return None };
    if a.contains(pane) {
        return Some(divider_after(a, pane).unwrap_or_else(|| id.clone()));
    }
    divider_after(b, pane)
}

/// `LayoutModel.dividerInsertPlan(at:)`: on any screen that shows `split`.
pub fn screens_divider_insert_plan(screens: &[Screen], split: &str) -> Option<DividerInsertPlan> {
    screens.iter().find_map(|screen| {
        tree_with_split(&screen.layout, split).and_then(|tree| divider_insert_plan(tree, split))
    })
}

/// `LayoutModel.divider(beside:)`: on the screen holding `pane`.
pub fn screens_divider_beside(screens: &[Screen], pane: &str) -> Option<String> {
    let layout = &screens.iter().find(|screen| screen.contains(pane))?.layout;
    let tree = match layout {
        Layout::Splits(root) => Some(root),
        Layout::Columns(_) => {
            layout.column_containing(pane).and_then(|column| column.tree_containing(pane))
        }
    };
    tree.and_then(|tree| divider_beside(tree, pane))
}

/// `LayoutModel.dividerHidden`.
pub fn divider_hidden(screens: &[Screen], split: &str) -> bool {
    screens.iter().any(|screen| screen.hidden_dividers.contains(split))
}

// MARK: Intents

/// `LayoutGesturePhase`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Phase {
    Changed,
    Ended,
}

/// `ColumnFocusSource`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum FocusSource {
    Keyboard,
    Pointer,
    #[default]
    Programmatic,
    Scroll,
}

/// `LayoutIntent.SizeValue`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum SizeValue {
    Ratio {
        split: String,
        ratio: f64,
    },
    #[serde(rename_all = "camelCase")]
    Width {
        column: String,
        any_pane: String,
        width: f64,
    },
}

/// `DividerDragValue`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum DragValue {
    Ratio { split: String, ratio: f64 },
    Width { column: String, width: f64 },
}

/// The `LayoutIntent`s these rules emit.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "intent", rename_all = "camelCase")]
pub enum Intent {
    Focus {
        pane: String,
    },
    SetSplitRatio {
        split: String,
        ratio: f64,
        transaction: String,
        phase: Phase,
    },
    #[serde(rename_all = "camelCase")]
    SetColumnWidth {
        column: String,
        any_pane: String,
        width: f64,
        transaction: String,
        phase: Phase,
    },
    SetLayoutSizes {
        values: Vec<SizeValue>,
        transaction: String,
    },
    SelectScreen {
        screen: String,
    },
    RaiseFloatingPane {
        pane: String,
    },
    CancelGesture {
        transaction: String,
    },
}

impl Intent {
    /// `LayoutIntent.sizes`: the size values and their transaction.
    pub fn sizes(&self) -> Option<(Vec<SizeValue>, &str)> {
        match self {
            Intent::SetSplitRatio { split, ratio, transaction, .. } => {
                Some((vec![SizeValue::Ratio { split: split.clone(), ratio: *ratio }], transaction))
            }
            Intent::SetColumnWidth { column, any_pane, width, transaction, .. } => Some((
                vec![SizeValue::Width {
                    column: column.clone(),
                    any_pane: any_pane.clone(),
                    width: *width,
                }],
                transaction,
            )),
            Intent::SetLayoutSizes { values, transaction } => Some((values.clone(), transaction)),
            _ => None,
        }
    }
}

// MARK: Transactions

/// `TransactionReplies`: the replies each transaction's values wait for, and the changes going out.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct TransactionReplies {
    pub unanswered: BTreeMap<String, u64>,
    /// Innermost last; each notes whether its transaction was refused meanwhile.
    pub sending: Vec<Sending>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Sending {
    pub transaction: String,
    pub refused: bool,
}

impl TransactionReplies {
    pub fn await_reply(&mut self, transaction: &str) {
        *self.unanswered.entry(transaction.to_owned()).or_insert(0) += 1;
    }

    /// True when it was the last reply the transaction's values wait for (or one nobody counted).
    pub fn answered(&mut self, transaction: &str) -> bool {
        match self.unanswered.get(transaction).copied() {
            Some(left) if left > 1 => {
                self.unanswered.insert(transaction.to_owned(), left - 1);
                false
            }
            _ => {
                self.unanswered.remove(transaction);
                true
            }
        }
    }

    pub fn forget(&mut self, transaction: &str) {
        self.unanswered.remove(transaction);
        for sending in &mut self.sending {
            if sending.transaction == transaction {
                sending.refused = true;
            }
        }
    }

    pub fn begin_sending(&mut self, transaction: &str) {
        self.sending.push(Sending { transaction: transaction.to_owned(), refused: false });
    }

    /// Whether the innermost change's transaction was refused while it went out.
    pub fn end_sending(&mut self) -> bool {
        self.sending.pop().is_some_and(|sending| sending.refused)
    }
}

/// `GestureOverride`: a value a gesture set locally, shown over snapshots until its reply.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct GestureOverride {
    pub value: f64,
    pub transaction: String,
    #[serde(default)]
    pub ended: bool,
    #[serde(default)]
    pub settled: bool,
}

/// The pane closes the class holds (`orderedPaneCloses`, `landedCloseRatios`/`Widths`, the
/// sizing settings), overlaid before the gesture overrides.
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(default)]
pub struct PaneCloses {
    pub closes: Vec<String>,
    pub landed: Landed,
    pub sizing: Sizing,
}

// MARK: The model

/// The state `LayoutModel`'s rules read and write.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Model {
    pub screens: Vec<Screen>,
    #[serde(default)]
    pub daemon_screens: Vec<Screen>,
    #[serde(default)]
    pub active_screen: Option<String>,
    #[serde(default)]
    pub focused_pane: Option<String>,
    #[serde(default)]
    pub last_focus_source: FocusSource,
    #[serde(default)]
    pub focus_ring_earned: bool,
    #[serde(default)]
    pub split_overrides: BTreeMap<String, GestureOverride>,
    #[serde(default)]
    pub width_overrides: BTreeMap<String, GestureOverride>,
    #[serde(default)]
    pub replies: TransactionReplies,
    /// `intentHandler != nil`: an ended value waits for a reply only when the app hears it.
    #[serde(default = "yes")]
    pub has_handler: bool,
    /// Read on each overlay; the class sends its own (never written back).
    #[serde(default, skip_serializing)]
    pub pane_closes: PaneCloses,
}

fn yes() -> bool {
    true
}

/// What a focus change asks of the class besides its intents.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FocusEffects {
    pub intents: Vec<Intent>,
    /// `enterAttention(pane)`.
    pub entered: Option<String>,
    /// `revealOnCanvas(pane, screen:)`: the screen.
    pub reveal_on_canvas: Option<String>,
}

impl Model {
    /// `LayoutModel.init(screens:activeScreenID:focusedPane:)`.
    pub fn new(
        screens: Vec<Screen>,
        active_screen: Option<String>,
        focused_pane: Option<String>,
    ) -> Model {
        let active_screen =
            active_screen.or_else(|| screens.first().map(|screen| screen.id.clone()));
        let focused_pane = focused_pane
            .or_else(|| screens.first().and_then(|screen| screen.layout.panes().first().cloned()));
        Model {
            daemon_screens: screens.clone(),
            screens,
            active_screen,
            focused_pane,
            last_focus_source: FocusSource::Programmatic,
            focus_ring_earned: false,
            split_overrides: BTreeMap::new(),
            width_overrides: BTreeMap::new(),
            replies: TransactionReplies::default(),
            has_handler: true,
            pane_closes: PaneCloses::default(),
        }
    }

    /// `activeScreen`.
    pub fn active(&self) -> Option<&Screen> {
        self.screens.iter().find(|screen| Some(&screen.id) == self.active_screen.as_ref())
    }

    /// `screen(containing:)`.
    pub fn screen_containing(&self, pane: &str) -> Option<&Screen> {
        self.screens.iter().find(|screen| screen.contains(pane))
    }

    /// `apply(screens:)`, past the pane-close bookkeeping: drops settled overrides, shows the
    /// snapshot with the overrides on it, keeps the active screen and focus while they exist, and
    /// stands a closed focused pane's nearest survivor in for it.
    pub fn apply(&mut self, new_screens: Vec<Screen>) {
        let previous = std::mem::replace(&mut self.daemon_screens, new_screens);
        self.split_overrides.retain(|_, value| !value.settled);
        self.width_overrides.retain(|_, value| !value.settled);
        let source = self.daemon_screens.clone();
        self.screens = self.overlaid(&source);
        if self.active().is_none() {
            self.active_screen = self.screens.first().map(|screen| screen.id.clone());
        }
        if let Some(focused) = &self.focused_pane
            && self.screens.iter().any(|screen| screen.contains(focused))
        {
            return;
        }
        let active = self.active();
        let fallback = self
            .focused_pane
            .as_deref()
            .and_then(|closed| neighbor(closed, &previous, active))
            .or_else(|| active.and_then(|screen| screen.layout.panes().first().cloned()));
        if self.focused_pane != fallback {
            self.focus_ring_earned = false;
            self.focused_pane = fallback;
        }
    }

    /// `overlaid(_:)`: the pending closes, then the live and unconfirmed overrides on `source`; an
    /// ended override the daemon already reports is dropped.
    pub fn overlaid(&mut self, source: &[Screen]) -> Vec<Screen> {
        let mut result = source.to_vec();
        for screen in &mut result {
            let closes = &self.pane_closes;
            let mut layout = overlaying_pane_closes(
                &screen.layout,
                &closes.closes,
                &closes.landed,
                closes.sizing,
            );
            for (split, value) in self.split_overrides.clone() {
                let Some(incoming) = layout.ratio_of(&split) else { continue };
                if (incoming - value.value).abs() < CONFIRM_TOLERANCE {
                    if value.ended {
                        self.split_overrides.remove(&split);
                    }
                } else {
                    layout = layout.setting_ratio(value.value, &split);
                }
            }
            for (column, value) in self.width_overrides.clone() {
                let Some(incoming) = layout
                    .columns()
                    .iter()
                    .find(|entry| entry.id == column)
                    .map(|entry| entry.width)
                else {
                    continue;
                };
                if (incoming - value.value).abs() < CONFIRM_TOLERANCE {
                    if value.ended {
                        self.width_overrides.remove(&column);
                    }
                } else {
                    layout = layout.setting_width(value.value, &column);
                }
            }
            screen.layout = layout;
        }
        result
    }

    /// `showOverlaid()`: the last daemon snapshot with every override and pending close on it.
    pub fn show_overlaid(&mut self) {
        let source = self.daemon_screens.clone();
        self.screens = self.overlaid(&source);
    }

    /// `settleTransaction`: at its last reply, an ended override of `transaction` yields to the
    /// next snapshot.
    pub fn settle(&mut self, transaction: &str) {
        if !self.replies.answered(transaction) {
            return;
        }
        for value in self.split_overrides.values_mut().chain(self.width_overrides.values_mut()) {
            if value.transaction == transaction && value.ended {
                value.settled = true;
            }
        }
    }

    /// `rejectTransaction`: drops `transaction`'s overrides and shows the daemon's values. True
    /// when an override went (the class then shows the overlay and reconciles its canvases).
    pub fn reject(&mut self, transaction: &str) -> bool {
        self.replies.forget(transaction);
        let (splits, widths) = (self.split_overrides.len(), self.width_overrides.len());
        self.split_overrides.retain(|_, value| value.transaction != transaction);
        self.width_overrides.retain(|_, value| value.transaction != transaction);
        if splits == self.split_overrides.len() && widths == self.width_overrides.len() {
            return false;
        }
        self.show_overlaid();
        true
    }

    /// `cancelGesture`: rejects `transaction` and tells the app.
    pub fn cancel_gesture(&mut self, transaction: &str) -> (bool, Vec<Intent>) {
        let shown = self.reject(transaction);
        (shown, vec![Intent::CancelGesture { transaction: transaction.to_owned() }])
    }

    /// `expectReply`.
    pub fn expect_reply(&mut self, transaction: &str) {
        if self.has_handler {
            self.replies.await_reply(transaction);
        }
    }

    /// `updateScreen(where:_:)`: rewrites the first screen whose layout `owns` says.
    fn update_screen(
        &mut self,
        owns: impl Fn(&Layout) -> bool,
        transform: impl Fn(&Layout) -> Layout,
    ) {
        if let Some(screen) = self.screens.iter_mut().find(|screen| owns(&screen.layout)) {
            screen.layout = transform(&screen.layout);
        }
    }

    /// `setSplitRatio`: shows the clamped ratio; only the ended value is sent.
    pub fn set_split_ratio(
        &mut self,
        split: &str,
        ratio: f64,
        transaction: &str,
        phase: Phase,
    ) -> Vec<Intent> {
        let ratio = clamped_ratio(ratio);
        self.update_screen(
            |layout| layout.ratio_of(split).is_some(),
            |layout| layout.setting_ratio(ratio, split),
        );
        self.split_overrides.insert(
            split.to_owned(),
            GestureOverride {
                value: ratio,
                transaction: transaction.to_owned(),
                ended: phase == Phase::Ended,
                settled: false,
            },
        );
        if phase != Phase::Ended {
            return Vec::new();
        }
        self.expect_reply(transaction);
        vec![Intent::SetSplitRatio {
            split: split.to_owned(),
            ratio,
            transaction: transaction.to_owned(),
            phase,
        }]
    }

    /// `setColumnWidth`: shows the clamped width; only the ended value is sent. Nothing for a
    /// column no screen has.
    pub fn set_column_width(
        &mut self,
        column: &str,
        width: f64,
        transaction: &str,
        phase: Phase,
    ) -> Vec<Intent> {
        let width = swift_min(swift_max(width, COLUMN_WIDTH_MIN), COLUMN_WIDTH_MAX);
        let Some(any_pane) = self.any_pane(column) else { return Vec::new() };
        self.update_screen(
            |layout| layout.columns().iter().any(|entry| entry.id == column),
            |layout| layout.setting_width(width, column),
        );
        self.width_overrides.insert(
            column.to_owned(),
            GestureOverride {
                value: width,
                transaction: transaction.to_owned(),
                ended: phase == Phase::Ended,
                settled: false,
            },
        );
        if phase != Phase::Ended {
            return Vec::new();
        }
        self.expect_reply(transaction);
        vec![Intent::SetColumnWidth {
            column: column.to_owned(),
            any_pane,
            width,
            transaction: transaction.to_owned(),
            phase,
        }]
    }

    /// The first pane of the first screen column `column`.
    fn any_pane(&self, column: &str) -> Option<String> {
        self.screens.iter().find_map(|screen| {
            screen
                .layout
                .columns()
                .iter()
                .find(|entry| entry.id == column)
                .and_then(|entry| entry.root.panes().first().cloned())
        })
    }

    /// `supersedeSentRatios`: drops the ended overrides of `splits`.
    pub fn supersede_sent_ratios(&mut self, splits: &BTreeSet<String>) {
        self.split_overrides.retain(|split, value| !splits.contains(split) || !value.ended);
    }

    /// `supersedeSentWidths`: drops the ended overrides of `columns`.
    pub fn supersede_sent_widths(&mut self, columns: &BTreeSet<String>) {
        self.width_overrides.retain(|column, value| !columns.contains(column) || !value.ended);
    }

    /// `focus(_:notify:source:)`.
    pub fn focus(&mut self, pane: &str, notify: bool, source: FocusSource) -> FocusEffects {
        let mut effects = FocusEffects::default();
        let Some(screen) = self.screen_containing(pane).cloned() else { return effects };
        self.active_screen = Some(screen.id.clone());
        if self.focused_pane.as_deref() == Some(pane) {
            if matches!(source, FocusSource::Pointer | FocusSource::Scroll) {
                self.last_focus_source = source;
                self.focus_ring_earned = false;
            }
            return effects;
        }
        self.last_focus_source = source;
        self.focus_ring_earned = source == FocusSource::Keyboard;
        self.focused_pane = Some(pane.to_owned());
        effects.entered = Some(pane.to_owned());
        if !matches!(source, FocusSource::Pointer | FocusSource::Scroll) {
            effects.reveal_on_canvas = Some(screen.id.clone());
        }
        if let Some(raise) = floating_raise(pane, &screen.floating, source) {
            effects.intents.push(raise);
        }
        if notify {
            effects.intents.push(Intent::Focus { pane: pane.to_owned() });
        }
        effects
    }

    /// `dismissFocusRing()`.
    pub fn dismiss_focus_ring(&mut self) {
        self.focus_ring_earned = false;
    }

    /// `selectScreen`: shows screen `id`; a focus not on it moves to its first pane.
    pub fn select_screen(&mut self, id: &str) -> Vec<Intent> {
        if self.active_screen.as_deref() == Some(id) {
            return Vec::new();
        }
        let Some(screen) = self.screens.iter().find(|screen| screen.id == id).cloned() else {
            return Vec::new();
        };
        self.active_screen = Some(id.to_owned());
        if self.focused_pane.as_ref().is_none_or(|pane| !screen.contains(pane)) {
            self.focus_ring_earned = false;
            self.focused_pane = screen.layout.panes().first().cloned();
        }
        vec![Intent::SelectScreen { screen: id.to_owned() }]
    }
}

/// `neighbor(of:in:on:)`: the pane of `screen` nearest before `closed` in its old order, else the
/// nearest after it.
fn neighbor(closed: &str, old: &[Screen], screen: Option<&Screen>) -> Option<String> {
    let screen = screen?;
    let order = old.iter().find(|entry| entry.id == screen.id)?.layout.panes();
    let index = order.iter().position(|pane| pane == closed)?;
    let live: BTreeSet<String> = screen.layout.panes().into_iter().collect();
    order[..index]
        .iter()
        .rev()
        .find(|pane| live.contains(*pane))
        .or_else(|| order[index + 1..].iter().find(|pane| live.contains(*pane)))
        .cloned()
}

// MARK: Ended values

/// The splits and panes the app cannot send a command for now (`LayoutModel.sendsNow`,
/// `LayoutHandleMap.sendsNow`): a split with no handle, a pane the daemon has not made.
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Unsendable {
    pub splits: BTreeSet<String>,
    pub panes: BTreeSet<String>,
}

impl Unsendable {
    /// `sendsNow(intent)`.
    pub fn sends_now(&self, intent: &Intent) -> bool {
        match intent {
            Intent::SetSplitRatio { split, .. } => !self.splits.contains(split),
            Intent::SetColumnWidth { any_pane, .. } => !self.panes.contains(any_pane),
            _ => true,
        }
    }
}

/// `EndedValues`: the values a key press or a drag's release ends with, one change.
#[derive(Clone, Debug, PartialEq)]
pub struct EndedValues {
    pub values: Vec<DragValue>,
    pub transaction: String,
}

/// How [`EndedValues::send`] went before the app heard it.
#[derive(Clone, Debug, PartialEq)]
pub enum SendStart {
    /// Done: true when the values went (none to send), false when they could not all go and
    /// nothing of them shows.
    Done(bool),
    /// The values show and `intent` goes out now (None when no value ended); the app hears it,
    /// then [`end_sending`] says whether the change was refused meanwhile.
    Sending(Option<Intent>),
}

impl EndedValues {
    /// `canSend(in:)`: every value has its target and can go now.
    pub fn can_send(&self, model: &Model, unsendable: Option<&Unsendable>) -> bool {
        self.values.iter().all(|value| {
            self.target(value, model)
                .map(|target| {
                    unsendable.is_none_or(|unsendable| unsendable.sends_now(&self.intent(&target)))
                })
                .unwrap_or(false)
        })
    }

    /// `send(in:)` up to the emit: shows the values, marks them ended, expects the one reply and
    /// starts sending.
    pub fn send(&self, model: &mut Model, unsendable: Option<&Unsendable>) -> SendStart {
        if self.values.is_empty() {
            return SendStart::Done(true);
        }
        if !self.can_send(model, unsendable) {
            model.reject(&self.transaction);
            return SendStart::Done(false);
        }
        for value in &self.values {
            match value {
                DragValue::Ratio { split, ratio } => {
                    model.set_split_ratio(split, *ratio, &self.transaction, Phase::Changed);
                }
                DragValue::Width { column, width } => {
                    model.set_column_width(column, *width, &self.transaction, Phase::Changed);
                }
            }
        }
        let ended: Vec<SizeValue> =
            self.values.iter().filter_map(|value| self.end(value, model)).collect();
        if !ended.is_empty() {
            model.expect_reply(&self.transaction);
        }
        model.replies.begin_sending(&self.transaction);
        let intent = match ended.as_slice() {
            [] => None,
            [one] => Some(self.intent(one)),
            _ => Some(Intent::SetLayoutSizes {
                values: ended,
                transaction: self.transaction.clone(),
            }),
        };
        SendStart::Sending(intent)
    }

    fn target(&self, value: &DragValue, model: &Model) -> Option<SizeValue> {
        match value {
            DragValue::Ratio { split, ratio } => model
                .screens
                .iter()
                .any(|screen| screen.layout.ratio_of(split).is_some())
                .then(|| SizeValue::Ratio { split: split.clone(), ratio: *ratio }),
            DragValue::Width { column, width } => model.any_pane(column).map(|any_pane| {
                SizeValue::Width { column: column.clone(), any_pane, width: *width }
            }),
        }
    }

    fn intent(&self, value: &SizeValue) -> Intent {
        match value {
            SizeValue::Ratio { split, ratio } => Intent::SetSplitRatio {
                split: split.clone(),
                ratio: *ratio,
                transaction: self.transaction.clone(),
                phase: Phase::Ended,
            },
            SizeValue::Width { column, any_pane, width } => Intent::SetColumnWidth {
                column: column.clone(),
                any_pane: any_pane.clone(),
                width: *width,
                transaction: self.transaction.clone(),
                phase: Phase::Ended,
            },
        }
    }

    fn end(&self, value: &DragValue, model: &mut Model) -> Option<SizeValue> {
        let shown = match value {
            DragValue::Ratio { split, .. } => {
                let shown = model
                    .split_overrides
                    .get_mut(split)
                    .filter(|shown| shown.transaction == self.transaction)?;
                shown.ended = true;
                DragValue::Ratio { split: split.clone(), ratio: shown.value }
            }
            DragValue::Width { column, .. } => {
                let shown = model
                    .width_overrides
                    .get_mut(column)
                    .filter(|shown| shown.transaction == self.transaction)?;
                shown.ended = true;
                DragValue::Width { column: column.clone(), width: shown.value }
            }
        };
        self.target(&shown, model)
    }
}

/// The end of `EndedValues.send`: true when the values went (the app did not refuse the change
/// while it heard it).
pub fn end_sending(model: &mut Model) -> bool {
    !model.replies.end_sending()
}

// MARK: Layout cache

/// `layoutCacheNode(frame:)`: the active screen's tree as a cmux-layout-cache `PaneNode` (JSON),
/// each leaf at its frame in `frames` (zero when absent). None with no active screen or a column
/// strip of no width.
pub fn cache_node(model: &Model, frames: &BTreeMap<String, Rect>) -> Option<Value> {
    fn node(split: &Node, frames: &BTreeMap<String, Rect>) -> Value {
        match split {
            Node::Leaf { pane } => {
                let frame = frames.get(pane).copied().unwrap_or_default();
                json!({"type": "leaf", "pane_id": pane, "kind": "other", "frame": frame})
            }
            Node::Split { axis, ratio, a, b, .. } => json!({
                "type": "split",
                "axis": cache_axis(*axis == Axis::Horizontal),
                "fractions": [ratio, 1.0 - ratio],
                "children": [node(a, frames), node(b, frames)],
            }),
        }
    }
    match &model.active()?.layout {
        Layout::Splits(root) => Some(node(root, frames)),
        Layout::Columns(columns) => {
            let total = columns.iter().fold(0.0, |sum, column| sum + swift_max(0.0, column.width));
            if total.partial_cmp(&0.0) != Some(std::cmp::Ordering::Greater) {
                return None;
            }
            if columns.len() == 1 {
                return Some(node(&columns[0].root, frames));
            }
            let fractions: Vec<f64> =
                columns.iter().map(|column| swift_max(0.0, column.width) / total).collect();
            let children: Vec<Value> =
                columns.iter().map(|column| node(&column.root, frames)).collect();
            Some(
                json!({"type": "split", "axis": "h", "fractions": fractions, "children": children}),
            )
        }
    }
}

fn cache_axis(horizontal: bool) -> &'static str {
    if horizontal { "h" } else { "v" }
}

/// `layoutCacheLive(bounds:)`: the active screen's structure as a cmux-layout-cache `LiveTree`
/// (JSON), with the style's divider thickness.
pub fn cache_live(model: &Model, bounds: Option<Rect>, divider: f64) -> Option<Value> {
    fn node(split: &Node) -> Value {
        match split {
            Node::Leaf { pane } => json!({"type": "leaf", "pane_id": pane, "kind": "other"}),
            Node::Split { axis, a, b, .. } => json!({
                "type": "split",
                "axis": cache_axis(*axis == Axis::Horizontal),
                "children": [node(a), node(b)],
            }),
        }
    }
    let layout = &model.active()?.layout;
    let root = match layout {
        Layout::Splits(split) => Some(node(split)),
        Layout::Columns(columns) if columns.is_empty() => None,
        Layout::Columns(columns) if columns.len() == 1 => Some(node(&columns[0].root)),
        Layout::Columns(columns) => {
            let children: Vec<Value> = columns.iter().map(|column| node(&column.root)).collect();
            Some(json!({"type": "split", "axis": "h", "children": children}))
        }
    };
    Some(json!({"panes": layout.panes(), "root": root, "bounds": bounds, "divider": divider}))
}

/// `layoutCacheDrift`'s mark, from the cached tree and the counts of its `reconcile` against
/// [`cache_live`] (None when it had none): `layout_cache.exact` when the first frame was the
/// final one. None for a cached default leaf (nothing was cached).
pub fn cache_drift(cached: &Value, reconciled: Option<(usize, usize)>) -> Option<String> {
    if cached.get("type").and_then(Value::as_str) == Some("leaf")
        && cached.get("pane_id").and_then(Value::as_str).unwrap_or("").is_empty()
    {
        return None;
    }
    let (moved, transitions) = reconciled?;
    Some(if moved == 0 && transitions == 0 {
        "layout_cache.exact".to_owned()
    } else {
        format!("layout_cache.drift.moved_{moved}.transitions_{transitions}")
    })
}

#[cfg(test)]
#[path = "layout_model_tests.rs"]
mod tests;
