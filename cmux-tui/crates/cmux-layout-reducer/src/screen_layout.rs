//! The Mac app's shown layout model (`CmuxNextLayout/Model`: `SplitNode`, `ScreenLayout`,
//! `LayoutColumn`, `DockColumn`, `LayoutRow`), with the app's string ids, for the rules the app's
//! `LayoutModel` asks of Rust ([`crate::pane_close`]). It is the shape the app holds, not the
//! daemon's wire tree ([`crate::optimistic`]): a screen is one split tree or a strip of columns, a
//! column has its own tree, maybe a dock and maybe rows (with `root` then the daemon's compat chain
//! of the rows folded into vertical splits).
//!
//! JSON: a leaf is `{"pane": P}`, a split `{"split": S, "axis": "horizontal"|"vertical", "ratio": R,
//! "a": node, "b": node}`; a layout `{"splits": node}` or `{"columns": [column]}`; a column
//! `{"id", "width", "root", "dock"?, "rows"?}` (`dock` left out when it scrolls, `rows` when it has
//! none); a dock `{"edge", "mode", "role"?, "isPinned", "allowsTabs"}`; a row `{"id", "height", "root"}`.
//!
//! Every helper is the Swift one line for line (`SplitNode.swift`, `ScreenLayout.swift`,
//! `DockStripGeometry.docks`).

use serde::{Deserialize, Serialize};

/// `SplitAxis`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Axis {
    /// Children side by side; `a` is on the left.
    Horizontal,
    /// Children stacked; `a` is on top.
    Vertical,
}

/// `SplitNode`: a binary split tree whose leaves are panes.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum Node {
    Leaf {
        pane: String,
    },
    Split {
        split: String,
        axis: Axis,
        /// The fraction of the space given to `a`.
        ratio: f64,
        a: Box<Node>,
        b: Box<Node>,
    },
}

impl Node {
    pub fn leaf(pane: &str) -> Node {
        Node::Leaf { pane: pane.to_owned() }
    }

    pub fn split(id: &str, axis: Axis, ratio: f64, a: Node, b: Node) -> Node {
        Node::Split { split: id.to_owned(), axis, ratio, a: Box::new(a), b: Box::new(b) }
    }

    /// Whether this is the leaf `pane` (Swift `node == .leaf(pane)`).
    pub fn is_leaf(&self, pane: &str) -> bool {
        matches!(self, Node::Leaf { pane: leaf } if leaf == pane)
    }

    /// Leaves in visual order (left to right, top to bottom).
    pub fn panes(&self) -> Vec<String> {
        let mut result = Vec::new();
        self.collect_panes(&mut result);
        result
    }

    fn collect_panes(&self, result: &mut Vec<String>) {
        match self {
            Node::Leaf { pane } => result.push(pane.clone()),
            Node::Split { a, b, .. } => {
                a.collect_panes(result);
                b.collect_panes(result);
            }
        }
    }

    /// The first leaf (`panes.first`).
    pub fn first_pane(&self) -> &str {
        match self {
            Node::Leaf { pane } => pane,
            Node::Split { a, .. } => a.first_pane(),
        }
    }

    pub fn contains(&self, pane: &str) -> bool {
        match self {
            Node::Leaf { pane: leaf } => leaf == pane,
            Node::Split { a, b, .. } => a.contains(pane) || b.contains(pane),
        }
    }

    /// The ratio of `split`, if it is in this tree.
    pub fn ratio_of(&self, split: &str) -> Option<f64> {
        match self {
            Node::Leaf { .. } => None,
            Node::Split { split: id, ratio, a, b, .. } => {
                if id == split {
                    return Some(*ratio);
                }
                a.ratio_of(split).or_else(|| b.ratio_of(split))
            }
        }
    }

    /// A copy with `split`'s ratio replaced; unchanged if the split is absent.
    pub fn setting_ratio(&self, ratio: f64, split: &str) -> Node {
        match self {
            Node::Leaf { .. } => self.clone(),
            Node::Split { split: id, axis, ratio: old, a, b } => {
                if id == split {
                    return Node::Split {
                        split: id.clone(),
                        axis: *axis,
                        ratio,
                        a: a.clone(),
                        b: b.clone(),
                    };
                }
                Node::Split {
                    split: id.clone(),
                    axis: *axis,
                    ratio: *old,
                    a: Box::new(a.setting_ratio(ratio, split)),
                    b: Box::new(b.setting_ratio(ratio, split)),
                }
            }
        }
    }

    /// Equal cells this subtree gives along `axis`: a same-axis chain counts its leaves, a
    /// perpendicular subtree counts as one.
    pub fn cell_count(&self, along: Axis) -> usize {
        match self {
            Node::Leaf { .. } => 1,
            Node::Split { axis, a, b, .. } => {
                if *axis == along {
                    a.cell_count(along) + b.cell_count(along)
                } else {
                    1
                }
            }
        }
    }

    /// A copy without the leaf `pane`, its sibling in its parent's place. None when `pane` was the
    /// only leaf; unchanged when it is absent.
    pub fn removing(&self, pane: &str) -> Option<Node> {
        match self {
            Node::Leaf { pane: leaf } => (leaf != pane).then(|| self.clone()),
            Node::Split { split, axis, ratio, a, b } => {
                let Some(first) = a.removing(pane) else { return Some((**b).clone()) };
                let Some(second) = b.removing(pane) else { return Some((**a).clone()) };
                Some(Node::Split {
                    split: split.clone(),
                    axis: *axis,
                    ratio: *ratio,
                    a: Box::new(first),
                    b: Box::new(second),
                })
            }
        }
    }

    /// The split's axis, None for a leaf.
    pub fn split_axis(&self) -> Option<Axis> {
        match self {
            Node::Leaf { .. } => None,
            Node::Split { axis, .. } => Some(*axis),
        }
    }
}

/// `DockEdge`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Edge {
    Left,
    Right,
    Top,
    Bottom,
}

/// `DockColumn`: a column pinned to one edge of the viewport.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Dock {
    pub edge: Edge,
    /// `docked` or `overlay`.
    pub mode: String,
    /// `agentChat` for the agent chat dock.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub role: Option<String>,
    #[serde(default)]
    pub is_pinned: bool,
    #[serde(default)]
    pub allows_tabs: bool,
}

/// `DockRole.agentChat`'s raw value.
pub const AGENT_CHAT: &str = "agentChat";

/// `LayoutRow`: one row of a column, `height` permille of the column's viewport height.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Row {
    pub id: String,
    pub height: i64,
    pub root: Node,
}

/// `LayoutColumn`: one column of the strip, `width` a fraction of the viewport.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Column {
    pub id: String,
    pub width: f64,
    /// Every pane of the column; with `rows`, the daemon's compat chain of the rows.
    pub root: Node,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dock: Option<Dock>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub rows: Vec<Row>,
}

impl Column {
    /// Two or more rows (a single row is the column's own tree).
    pub fn has_rows(&self) -> bool {
        self.rows.len() > 1
    }

    /// The row index holding `pane`.
    pub fn row_index(&self, pane: &str) -> Option<usize> {
        self.rows.iter().position(|row| row.root.contains(pane))
    }

    /// The tree holding `pane`: its row's, or the column's own (`tree(containing:)`).
    pub fn tree_containing(&self, pane: &str) -> Option<&Node> {
        if self.has_rows() {
            self.rows.iter().map(|row| &row.root).find(|root| root.contains(pane))
        } else {
            Some(&self.root).filter(|root| root.contains(pane))
        }
    }

    /// A copy with `split`'s ratio replaced in the tree and in every row.
    pub fn setting_ratio(&self, ratio: f64, split: &str) -> Column {
        let mut column = self.clone();
        column.root = self.root.setting_ratio(ratio, split);
        for row in &mut column.rows {
            row.root = row.root.setting_ratio(ratio, split);
        }
        column
    }

    /// Whether this column is a pinned dock (`dock?.isPinned == true`).
    pub fn pinned_dock(&self) -> bool {
        self.dock.as_ref().is_some_and(|dock| dock.is_pinned)
    }
}

/// `ScreenLayout`: one split tree filling the viewport, or a strip of columns.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Layout {
    Splits(Node),
    Columns(Vec<Column>),
}

impl Layout {
    pub fn panes(&self) -> Vec<String> {
        match self {
            Layout::Splits(root) => root.panes(),
            Layout::Columns(columns) => {
                columns.iter().flat_map(|column| column.root.panes()).collect()
            }
        }
    }

    pub fn contains(&self, pane: &str) -> bool {
        match self {
            Layout::Splits(root) => root.contains(pane),
            Layout::Columns(columns) => columns.iter().any(|column| column.root.contains(pane)),
        }
    }

    /// The columns; none for a split tree.
    pub fn columns(&self) -> &[Column] {
        match self {
            Layout::Splits(_) => &[],
            Layout::Columns(columns) => columns,
        }
    }

    /// The column holding `pane`, in columns mode.
    pub fn column_containing(&self, pane: &str) -> Option<&Column> {
        self.columns().iter().find(|column| column.root.contains(pane))
    }

    /// Columns in the order the person sees them: the left dock, the top dock, the scrolling
    /// strip, the bottom dock, the right dock.
    pub fn visual_columns(&self) -> Vec<Column> {
        let parts = docks(self.columns());
        [parts.left, parts.top]
            .into_iter()
            .flatten()
            .chain(parts.scrolling)
            .chain([parts.bottom, parts.right].into_iter().flatten())
            .collect()
    }

    /// The ratio of `split`: the tree's, or the first column root's that has it (rows not read).
    pub fn ratio_of(&self, split: &str) -> Option<f64> {
        match self {
            Layout::Splits(root) => root.ratio_of(split),
            Layout::Columns(columns) => {
                columns.iter().find_map(|column| column.root.ratio_of(split))
            }
        }
    }

    pub fn setting_ratio(&self, ratio: f64, split: &str) -> Layout {
        match self {
            Layout::Splits(root) => Layout::Splits(root.setting_ratio(ratio, split)),
            Layout::Columns(columns) => Layout::Columns(
                columns.iter().map(|column| column.setting_ratio(ratio, split)).collect(),
            ),
        }
    }

    pub fn setting_width(&self, width: f64, column: &str) -> Layout {
        match self {
            Layout::Splits(_) => self.clone(),
            Layout::Columns(columns) => Layout::Columns(
                columns
                    .iter()
                    .map(|entry| {
                        let mut entry = entry.clone();
                        if entry.id == column {
                            entry.width = width;
                        }
                        entry
                    })
                    .collect(),
            ),
        }
    }
}

/// `DockStripGeometry.Parts`: each edge's dock and the scrolling columns.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Parts {
    pub left: Option<Column>,
    pub right: Option<Column>,
    pub top: Option<Column>,
    pub bottom: Option<Column>,
    pub scrolling: Vec<Column>,
}

/// `DockStripGeometry.docks`: the first dock on each edge holds it, every other column scrolls;
/// with no scrolling column a lone column scrolls at full width, else every column scrolls.
pub fn docks(columns: &[Column]) -> Parts {
    let mut parts = Parts::default();
    for column in columns {
        let slot = match column.dock.as_ref().map(|dock| dock.edge) {
            Some(Edge::Left) => &mut parts.left,
            Some(Edge::Right) => &mut parts.right,
            Some(Edge::Top) => &mut parts.top,
            Some(Edge::Bottom) => &mut parts.bottom,
            None => {
                parts.scrolling.push(column.clone());
                continue;
            }
        };
        if slot.is_none() {
            *slot = Some(column.clone());
        } else {
            parts.scrolling.push(column.clone());
        }
    }
    if parts.scrolling.is_empty() {
        if let [only] = columns {
            let mut lone = only.clone();
            lone.width = 1.0;
            return Parts { scrolling: vec![lone], ..Parts::default() };
        }
        return Parts { scrolling: columns.to_vec(), ..Parts::default() };
    }
    parts
}
