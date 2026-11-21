//! The optimistic view's rules (`optimistic`): what a pending intent shows on top of the
//! confirmed mirror before the daemon settles it (plans/cmux-next/OWNERSHIP-PRINCIPLES.md,
//! "Clients are projections"). The app keeps the records and their identities; it asks these
//! rules where a provisional pane, column, row or dock goes, what a hidden pane leaves behind,
//! where a moved tab or workspace lands and which row heights a divider release writes, and
//! writes the answer into its records. Every rule is pure: the same request always answers the
//! same view, and a request the daemon would refuse answers `null` (the intent shows nothing).
//!
//! A split, dock or pane removal sends no whole screen: the app finds the target's node in each
//! tree with a generic walk and sends those nodes ([`Spot`]) and a few counts ([`Facts`]); the
//! answer is a [`Patch`] the app splices into its trees and columns, keeping every untouched
//! subtree. Request and answer stay the same size however large the layout is (a New Row's row
//! chain excepted). The node shapes are the daemon's wire shapes (`type`, `pane`, `split`,
//! `split_id`, `dir`, `ratio`, `a`, `b`, `panes`, `expanded`). One JSON operation (`optimistic`
//! of `cmux_layout_reducer_json`) answers every request, tagged by `op`.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// A provisional handle's bit (`ProvisionalPane`'s base): a column or row derived from a
/// provisional pane's handle carries it, so none can name a daemon object.
const PROVISIONAL_BIT: u64 = 1 << 62;
/// The second column or row a create makes at once (the split-tree screen's own column, a
/// column's first row) differs from the new one by this bit.
const SIBLING_BIT: u64 = 1 << 61;
/// A New Row on a split-tree screen makes its one column under the first row's id with this bit.
const ROW_COLUMN_BIT: u64 = 1 << 60;

/// A split's axis: `right` puts `a` left of `b`, `down` puts `a` above `b`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Dir {
    Right,
    Down,
}

/// One node of a screen's, column's or row's split tree.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Node {
    Leaf {
        pane: u64,
    },
    Split {
        /// The daemon's handle; none on a split the app shows before the daemon has it.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        split: Option<u64>,
        /// The split's public id (`split-client-split-id-v1`).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        split_id: Option<String>,
        dir: Dir,
        ratio: f64,
        a: Box<Node>,
        b: Box<Node>,
    },
    Stack {
        panes: Vec<u64>,
        expanded: u64,
    },
    /// A node type this client does not know. Its own fields are dropped, as the app's
    /// `LayoutNode.unknown` drops them when it decodes the daemon's tree; the node keeps its
    /// place, so a split or a removal elsewhere in the tree leaves it there.
    #[serde(other)]
    Unknown,
}

impl Node {
    fn leaf(pane: u64) -> Self {
        Node::Leaf { pane }
    }

    /// Whether `pane` is one of this tree's panes.
    pub fn contains(&self, pane: u64) -> bool {
        match self {
            Node::Leaf { pane: leaf } => *leaf == pane,
            Node::Split { a, b, .. } => a.contains(pane) || b.contains(pane),
            Node::Stack { panes, .. } => panes.contains(&pane),
            Node::Unknown => false,
        }
    }

    /// Pane ids in depth-first order.
    pub fn pane_ids(&self) -> Vec<u64> {
        let mut out = Vec::new();
        self.collect(&mut out);
        out
    }

    fn collect(&self, out: &mut Vec<u64>) {
        match self {
            Node::Leaf { pane } => out.push(*pane),
            Node::Split { a, b, .. } => {
                a.collect(out);
                b.collect(out);
            }
            Node::Stack { panes, .. } => out.extend(panes),
            Node::Unknown => {}
        }
    }
}

/// The node the app's walk found in one tree: the first node, depth-first through splits only,
/// that the request's match names (a split's `a` before its `b`).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum SpotNode {
    Leaf {
        pane: u64,
    },
    Split {
        /// The daemon's handle.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        split: Option<u64>,
        /// The split's last pane in depth-first order (`divider_insert::last_pane`).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        last_pane: Option<u64>,
    },
    Stack {
        panes: Vec<u64>,
        expanded: u64,
    },
}

/// One tree's found node: the screen's tree (`column` absent), a column's (`row` absent) or a
/// column's row's, indexed as the request's screen holds them. `root`: the node is the tree.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Spot {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub column: Option<usize>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub row: Option<usize>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub root: bool,
    /// None when the tree holds no such node.
    pub node: Option<SpotNode>,
}

/// What a rule reads of the screen besides the found nodes; each op sends what its rule reads.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Facts {
    /// The screen's tree already holds the request's `leaf`.
    pub leaf_placed: bool,
    /// The screen has a zoomed pane.
    pub zoomed: bool,
    /// The screen's column count.
    pub columns: usize,
    /// The screen's panes count (the records' `panes`).
    pub panes: usize,
    /// The target's index in the screen's panes.
    pub target_index: Option<usize>,
    /// The screen's tree holds the target.
    pub in_screen: bool,
    /// The first column whose tree holds the target.
    pub column: Option<usize>,
    /// The first and last index in the screen's panes of a pane that column's tree holds (the
    /// screen's tree when it has no columns).
    pub span: Option<[usize; 2]>,
    /// That column's row count.
    pub rows: usize,
    /// The first of that column's rows whose tree holds the target.
    pub row: Option<usize>,
    /// Every column's dock `edge`, in column order (columns without one skipped).
    pub dock_edges: Vec<String>,
}

/// A node of an answer's new trees. `held`, `screen`, `column` and `row` name trees the app
/// already holds, so the answer never repeats them.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Part {
    Leaf {
        pane: u64,
    },
    /// A new split, with no daemon handle yet.
    Split {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        split_id: Option<String>,
        dir: Dir,
        ratio: f64,
        a: Box<Part>,
        b: Box<Part>,
    },
    Stack {
        panes: Vec<u64>,
        expanded: u64,
    },
    /// The spot's node as it was (spot edits only).
    Held,
    /// The screen's tree as it was before the patch.
    Screen,
    /// The edited column's tree as it was before this edit (column `change` only).
    Column,
    /// The edited column's row `row` as it was before this edit (column `change` only).
    Row {
        row: usize,
    },
}

impl Part {
    /// An unnamed split (the compat trees the daemon keeps beside columns and rows).
    fn pair(dir: Dir, a: Part, b: Part) -> Self {
        Part::Split { split_id: None, dir, ratio: 0.5, a: Box::new(a), b: Box::new(b) }
    }

    fn named(split_id: &str, dir: Dir, ratio: f64, a: Part, b: Part) -> Self {
        Part::Split {
            split_id: Some(split_id.to_owned()),
            dir,
            ratio,
            a: Box::new(a),
            b: Box::new(b),
        }
    }
}

/// An edit of the request's spot `spot`: its node becomes `node`, or goes when none (its parent
/// split becomes the parent's other side, as it is).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct SpotEdit {
    pub spot: usize,
    pub node: Option<Part>,
}

/// A row an inserted column comes with.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct RowPart {
    pub id: u64,
    pub height: i64,
    pub layout: Part,
}

/// An edit of a column's rows; `at` indexes the rows as the edits before it left them.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "edit", rename_all = "snake_case")]
pub enum RowEdit {
    Insert { at: usize, id: u64, height: i64, layout: Part },
    Remove { at: usize },
}

/// An edit of the screen's columns; `at` indexes the columns as the edits before it left them.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "edit", rename_all = "snake_case")]
pub enum ColumnEdit {
    Insert {
        at: usize,
        id: u64,
        width: f64,
        layout: Part,
        /// The request's dock record.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        dock: Option<Value>,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        rows: Vec<RowPart>,
    },
    Remove {
        at: usize,
    },
    Change {
        at: usize,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        layout: Option<Part>,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        rows: Vec<RowEdit>,
    },
}

/// A split's, dock's or removal's answer. The app applies every `spots` edit (indices are the
/// request's), then `layout` (the screen's new tree), then `columns` in order. `pane_at`: where
/// the provisional pane goes in the screen's panes (used only when the records do not hold the
/// daemon's pane).
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Patch {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub spots: Vec<SpotEdit>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub layout: Option<Part>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub columns: Vec<ColumnEdit>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pane_at: Option<usize>,
}

/// New Column (`new-pane-right` with client-minted ids).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ColumnSpec {
    /// The provisional column's handle (`ProvisionalColumn.handle`).
    pub handle: u64,
    pub width: f64,
    #[serde(default)]
    pub left: bool,
}

/// New Row (`new-row` with client-minted ids).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct RowSpec {
    /// The provisional row's handle (`ProvisionalRow.handle`).
    pub handle: u64,
    pub height: i64,
}

/// A row's height in permille (`set-row-heights` `heights[]`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct RowHeight {
    pub row: u64,
    pub height: i64,
}

/// A row as the records hold it (its id and height).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct RowNow {
    pub id: u64,
    pub height: i64,
}

/// One tab a held close took out of the pane: its surface and its index there before.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct HeldTab {
    pub surface: u64,
    pub index: usize,
}

/// How a workspace intent places its workspace.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PlaceKind {
    /// `move-workspace`: to final daemon-order `index` (clamped), keeping its group.
    Move,
    /// `move-workspace-to-group` without an index: into `group`, keeping its place.
    Group,
    /// `move-workspace-to-group` with an index: into `group` at section index `index`.
    Place,
}

/// One request of the `optimistic` operation.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum Request {
    /// A split, New Column or New Row of `target`, showing `leaf` (the provisional pane, or the
    /// daemon's pane under the split's public id before its layout places it). `spots`: the
    /// screen's tree first, then each column whose tree holds `target` and each of its rows
    /// that does, matched by split `around` when set, else by leaf `target`.
    Split {
        target: u64,
        dir: Dir,
        ratio: f64,
        leaf: u64,
        split_id: String,
        #[serde(default)]
        column: Option<ColumnSpec>,
        #[serde(default)]
        row: Option<RowSpec>,
        /// `split-around-v1`: the new pane wraps this whole split, whose last pane is
        /// `target`, instead of splitting `target` alone (Insert New at a divider).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        around: Option<u64>,
        /// `split-before-v1` (Split Left, Split Up): `leaf` is the split's first side and is
        /// listed before `target` in the screen's panes.
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        before: bool,
        facts: Facts,
        spots: Vec<Spot>,
    },
    /// Insert New at the divider of split `split` in `layout` (the tree holding it): the split
    /// request to send and the divider's new ratio (`divider_insert`).
    InsertAtDivider { layout: Node, split: u64 },
    /// A lone tab docked into a new leading column holding `leaf`.
    Dock { leaf: u64, column: ColumnSpec, dock: Value, facts: Facts },
    /// A pane taken out of the visible records (a creation the person closed first). `spots`:
    /// the screen's tree first, then each column whose tree holds `pane` and each of its rows
    /// that does, matched by the leaf or stack holding `pane`.
    RemovePane { pane: u64, spots: Vec<Spot> },
    /// `move-tab`'s final index in the target pane.
    MoveTab { same_pane: bool, from: usize, index: i64, target_count: usize },
    /// A workspace move or regroup; `groups` is every workspace's group in daemon order.
    PlaceWorkspace {
        groups: Vec<Option<String>>,
        from: usize,
        kind: PlaceKind,
        #[serde(default)]
        group: Option<String>,
        #[serde(default)]
        index: i64,
    },
    /// `set-row-heights` on a column's rows.
    RowHeights { rows: Vec<RowNow>, heights: Vec<RowHeight> },
    /// `move-tab`'s index in the daemon's order while held closes keep tabs out of the visible
    /// order. `held`: each held close's tabs in this pane, oldest close first, each in removal
    /// order.
    DaemonMoveIndex { visible: Vec<u64>, moving: u64, index: i64, held: Vec<Vec<HeldTab>> },
}

/// `move-tab`'s answer.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct MoveTo {
    #[serde(rename = "final")]
    pub final_index: usize,
}

/// A workspace intent's answer: its new daemon-order index (its group is the request's).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PlaceAt {
    pub index: usize,
}

/// The row heights a divider release writes, in the column's row order.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Heights {
    pub heights: Vec<RowHeight>,
}

/// `daemon_move_index`'s answer.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct DaemonMove {
    #[serde(rename = "final")]
    pub final_index: usize,
    pub current: Option<usize>,
}

/// Answers one request: the view it shows, or `null` when it shows nothing.
pub fn respond(request: &Request) -> Value {
    fn json<T: Serialize>(value: Option<T>) -> Value {
        value.map_or(Value::Null, |v| serde_json::to_value(v).unwrap_or(Value::Null))
    }
    match request {
        Request::Split {
            target,
            dir,
            ratio,
            leaf,
            split_id,
            column,
            row,
            around,
            before,
            facts,
            spots,
        } => {
            let tree =
                SplitTree { target: *target, dir: *dir, ratio: *ratio, leaf: *leaf, split_id };
            let how = SplitHow { column: column.as_ref(), row: row.as_ref(), around: *around };
            json(split(&tree, how, *before, facts, spots))
        }
        Request::InsertAtDivider { layout, split } => {
            json(crate::divider_insert::plan(layout, *split))
        }
        Request::Dock { leaf, column, dock, facts } => {
            json(dock_column(*leaf, column, dock, facts))
        }
        Request::RemovePane { pane, spots } => json(remove_pane(*pane, spots)),
        Request::MoveTab { same_pane, from, index, target_count } => {
            json(move_tab(*same_pane, *from, *index, *target_count))
        }
        Request::PlaceWorkspace { groups, from, kind, group, index } => {
            json(place_workspace(groups, *from, *kind, group.as_deref(), *index))
        }
        Request::RowHeights { rows, heights } => json(row_heights(rows, heights)),
        Request::DaemonMoveIndex { visible, moving, index, held } => {
            json(Some(daemon_move_index(visible, *moving, *index, held)))
        }
    }
}

/// `node` with the leaf `target` replaced by a split of `target` and `new` under public id
/// `split_id`, or none when the leaf is not in it (or sits in a stack, which `split` turns into
/// its own layout).
pub fn split_leaf(
    node: &Node,
    target: u64,
    dir: Dir,
    ratio: f64,
    new: u64,
    split_id: &str,
) -> Option<Node> {
    split_leaf_as(node, target, dir, ratio, new, split_id, false)
}

/// [`split_leaf`], with `new` as the split's first side when `before` (`split {before: true}`,
/// Split Left and Split Up).
pub fn split_leaf_as(
    node: &Node,
    target: u64,
    dir: Dir,
    ratio: f64,
    new: u64,
    split_id: &str,
    before: bool,
) -> Option<Node> {
    match node {
        Node::Leaf { pane } if *pane == target => {
            let (a, b) = if before { (new, target) } else { (target, new) };
            Some(Node::Split {
                split: None,
                split_id: Some(split_id.to_owned()),
                dir,
                ratio,
                a: Box::new(Node::leaf(a)),
                b: Box::new(Node::leaf(b)),
            })
        }
        Node::Split { split, split_id: id, dir: d, ratio: r, a, b } => {
            let rebuilt = |a: Node, b: Node| Node::Split {
                split: *split,
                split_id: id.clone(),
                dir: *d,
                ratio: *r,
                a: Box::new(a),
                b: Box::new(b),
            };
            if let Some(a2) = split_leaf_as(a, target, dir, ratio, new, split_id, before) {
                return Some(rebuilt(a2, (**b).clone()));
            }
            split_leaf_as(b, target, dir, ratio, new, split_id, before)
                .map(|b2| rebuilt((**a).clone(), b2))
        }
        _ => None,
    }
}

/// `node` without `pane`: its sibling takes a split's place; none when the pane is the whole
/// tree. A split whose first side is only `pane` keeps its second side as it is.
pub fn removing(pane: u64, node: &Node) -> Option<Node> {
    match node {
        Node::Leaf { pane: leaf } => (*leaf != pane).then(|| node.clone()),
        Node::Split { split, split_id, dir, ratio, a, b } => {
            let Some(a2) = removing(pane, a) else { return Some((**b).clone()) };
            let Some(b2) = removing(pane, b) else { return Some(a2) };
            Some(Node::Split {
                split: *split,
                split_id: split_id.clone(),
                dir: *dir,
                ratio: *ratio,
                a: Box::new(a2),
                b: Box::new(b2),
            })
        }
        Node::Stack { panes, expanded } => {
            let rest: Vec<u64> = panes.iter().copied().filter(|p| *p != pane).collect();
            let first = *rest.first()?;
            Some(Node::Stack {
                expanded: if *expanded == pane { first } else { *expanded },
                panes: rest,
            })
        }
        Node::Unknown => Some(Node::Unknown),
    }
}

/// Where the new pane goes in the screen's panes: right after the target, or at it when
/// `before` (the daemon lists a screen's panes in its layout's order); at the end when the
/// target is not listed.
fn pane_at(facts: &Facts, before: bool) -> usize {
    let at = facts.target_index.map_or(facts.panes, |i| if before { i } else { i + 1 });
    at.min(facts.panes)
}

/// The plain split a `split` request asks for: `target` split along `dir` at `ratio`, showing
/// `leaf` under public id `split_id`.
pub struct SplitTree<'a> {
    pub target: u64,
    pub dir: Dir,
    pub ratio: f64,
    pub leaf: u64,
    pub split_id: &'a str,
}

/// Which split a `split` request makes: New Column (`column`), New Row (`row`), around the
/// whole split `around`, else a plain split of the target.
#[derive(Clone, Copy, Default)]
pub struct SplitHow<'a> {
    pub column: Option<&'a ColumnSpec>,
    pub row: Option<&'a RowSpec>,
    pub around: Option<u64>,
}

/// A split of `target` (`split_kind.rs`: the target's column tree and row tree take it too),
/// New Column (`column`), New Row (`row`), or a split around the whole split `around`
/// (`split-around-v1`, Insert New at a divider: cmux-tui's `split_around` wraps it, `leaf`
/// after it). `before` (`split-before-v1`) shows `leaf` as a plain split's first side and lists
/// it before `target`. None when cmux-tui would refuse it, or when the screen's tree already
/// places `leaf` (the daemon's layout placed its pane: the split has nothing left to show, and
/// showing it again would list the pane twice).
///
/// Every column tree and row tree that holds `target` takes the split; one that cannot (the
/// split `around` is not in it with `target` as its last pane) shows nothing. Around a split,
/// a screen with columns keeps its compat tree as it is when that tree does not name `around`.
pub fn split(
    tree: &SplitTree<'_>,
    how: SplitHow<'_>,
    before: bool,
    facts: &Facts,
    spots: &[Spot],
) -> Option<Patch> {
    let SplitTree { target, dir, ratio, leaf, split_id } = *tree;
    if facts.leaf_placed {
        return None;
    }
    if let Some(column) = how.column {
        return new_column(leaf, column, facts);
    }
    if let Some(row) = how.row {
        return new_row(target, leaf, split_id, row, facts, spots);
    }
    let takes = |spot: &Spot| match (&spot.node, how.around) {
        (Some(SpotNode::Split { split, last_pane }), Some(around)) => {
            *split == Some(around) && *last_pane == Some(target)
        }
        (Some(SpotNode::Leaf { pane }), None) => *pane == target,
        _ => false,
    };
    let node = match how.around {
        Some(_) => Part::named(split_id, dir, ratio, Part::Held, Part::Leaf { pane: leaf }),
        None if before => Part::named(
            split_id,
            dir,
            ratio,
            Part::Leaf { pane: leaf },
            Part::Leaf { pane: target },
        ),
        None => Part::named(
            split_id,
            dir,
            ratio,
            Part::Leaf { pane: target },
            Part::Leaf { pane: leaf },
        ),
    };
    let mut edits = Vec::with_capacity(spots.len());
    for (at, spot) in spots.iter().enumerate() {
        if takes(spot) {
            edits.push(SpotEdit { spot: at, node: Some(node.clone()) });
        } else if at > 0 || how.around.is_none() || facts.columns == 0 {
            return None;
        }
    }
    if spots.is_empty() {
        return None;
    }
    Some(Patch { spots: edits, pane_at: Some(pane_at(facts, before)), ..Patch::default() })
}

/// New Column (`new-pane-right`, cmux-tui `new_pane_right`): a column holding `leaf` right after
/// the target's column (before it for New Column Left), at its width; every other column keeps
/// its width (R3b). A split-tree screen becomes its tree at full width and the new column, as the
/// daemon wraps its root in a viewport split. A zoomed split-tree screen has nothing to open
/// beside.
fn new_column(leaf: u64, spec: &ColumnSpec, facts: &Facts) -> Option<Patch> {
    let mut columns = Vec::with_capacity(2);
    let index = if facts.columns == 0 {
        if facts.zoomed || !facts.in_screen {
            return None;
        }
        columns.push(ColumnEdit::Insert {
            at: 0,
            id: spec.handle | SIBLING_BIT,
            width: 1.0,
            layout: Part::Screen,
            dock: None,
            rows: Vec::new(),
        });
        0
    } else {
        facts.column?
    };
    columns.push(ColumnEdit::Insert {
        at: if spec.left { index } else { index + 1 },
        id: spec.handle,
        width: spec.width,
        layout: Part::Leaf { pane: leaf },
        dock: None,
        rows: Vec::new(),
    });
    let layout = if spec.left {
        Part::pair(Dir::Right, Part::Leaf { pane: leaf }, Part::Screen)
    } else {
        Part::pair(Dir::Right, Part::Screen, Part::Leaf { pane: leaf })
    };
    let at = match (spec.left, facts.span) {
        (true, span) => span.map_or(0, |[first, _]| first),
        (false, span) => span.map_or(facts.panes, |[_, last]| last + 1),
    };
    Some(Patch {
        layout: Some(layout),
        columns,
        pane_at: Some(at.min(facts.panes)),
        ..Patch::default()
    })
}

/// New Row (`new-row`, cmux-tui `new_row_with_options_as`): a row holding `leaf` right below the
/// target's row in its column, at its height. A split-tree screen becomes one column, and a
/// column without rows gets its tree as its first row (1000), as the daemon does. The column's
/// `layout` stays the compat chain of its rows.
fn new_row(
    target: u64,
    leaf: u64,
    split_id: &str,
    spec: &RowSpec,
    facts: &Facts,
    spots: &[Spot],
) -> Option<Patch> {
    if facts.zoomed {
        return None;
    }
    let first = spec.handle | SIBLING_BIT;
    let new = || Part::Leaf { pane: leaf };
    let column = if facts.columns == 0 {
        if !facts.in_screen {
            return None;
        }
        ColumnEdit::Insert {
            at: 0,
            id: first | ROW_COLUMN_BIT,
            width: 1.0,
            layout: Part::pair(Dir::Down, Part::Screen, new()),
            dock: None,
            rows: vec![
                RowPart { id: first, height: 1000, layout: Part::Screen },
                RowPart { id: spec.handle, height: spec.height, layout: new() },
            ],
        }
    } else {
        let at = facts.column?;
        if facts.rows == 0 {
            ColumnEdit::Change {
                at,
                layout: Some(Part::pair(Dir::Down, Part::Column, new())),
                rows: vec![
                    RowEdit::Insert { at: 0, id: first, height: 1000, layout: Part::Column },
                    RowEdit::Insert { at: 1, id: spec.handle, height: spec.height, layout: new() },
                ],
            }
        } else {
            let row = facts.row?;
            let mut parts: Vec<Part> = (0..facts.rows).map(|row| Part::Row { row }).collect();
            parts.insert(row + 1, new());
            let mut parts = parts.into_iter();
            let head = parts.next()?;
            let chain = parts.fold(head, |chain, next| Part::pair(Dir::Down, chain, next));
            ColumnEdit::Change {
                at,
                layout: Some(chain),
                rows: vec![RowEdit::Insert {
                    at: row + 1,
                    id: spec.handle,
                    height: spec.height,
                    layout: new(),
                }],
            }
        }
    };
    let mut patch =
        Patch { columns: vec![column], pane_at: Some(pane_at(facts, false)), ..Patch::default() };
    match spots.first() {
        Some(Spot { node: Some(SpotNode::Leaf { pane }), .. }) if *pane == target => {
            let node = Part::named(split_id, Dir::Down, 0.5, Part::Leaf { pane: target }, new());
            patch.spots.push(SpotEdit { spot: 0, node: Some(node) });
        }
        _ => patch.layout = Some(Part::pair(Dir::Down, Part::Screen, new())),
    }
    Some(patch)
}

/// A lone tab docked into a new column (`move-tab-to-column {dock}`): the column holding `leaf`
/// leads the screen's columns (cmux-tui's `commit_tab_drag` puts a left dock first). A zoomed
/// screen, or one with a dock on that edge already, waits for the daemon's layout:
/// `reduce_column_dock` there moves the old holder, which this view does not show. None too when
/// the screen's tree already places `leaf` (the daemon's layout placed the dock's pane). A dock
/// with no edge is taken by any column without a dock edge.
pub fn dock_column(leaf: u64, spec: &ColumnSpec, dock: &Value, facts: &Facts) -> Option<Patch> {
    let taken = match dock.get("edge").and_then(Value::as_str) {
        Some(edge) => facts.dock_edges.iter().any(|e| e == edge),
        None => facts.columns > facts.dock_edges.len(),
    };
    if facts.leaf_placed || facts.zoomed || taken {
        return None;
    }
    let mut columns = Vec::with_capacity(2);
    if facts.columns == 0 {
        columns.push(ColumnEdit::Insert {
            at: 0,
            id: spec.handle | SIBLING_BIT,
            width: 1.0,
            layout: Part::Screen,
            dock: None,
            rows: Vec::new(),
        });
    }
    columns.push(ColumnEdit::Insert {
        at: 0,
        id: spec.handle,
        width: spec.width,
        layout: Part::Leaf { pane: leaf },
        dock: Some(dock.clone()),
        rows: Vec::new(),
    });
    let layout = Part::pair(Dir::Right, Part::Leaf { pane: leaf }, Part::Screen);
    Some(Patch { layout: Some(layout), columns, ..Patch::default() })
}

/// The screen without `pane` (a creation the person closed before the daemon made it): a column
/// or row that is only this pane goes with it. None when the pane is the whole screen tree, or
/// a column or row tree it is in cannot lose it: it stays shown until its close.
pub fn remove_pane(pane: u64, spots: &[Spot]) -> Option<Patch> {
    let mut patch = Patch::default();
    // Column index, whether it goes, and the rows it loses.
    let mut columns: Vec<(usize, bool, Vec<usize>)> = Vec::new();
    for (at, spot) in spots.iter().enumerate() {
        let Some(node) = &spot.node else { continue };
        if let Some(column) = spot.column {
            if columns.iter().any(|(c, goes, _)| *c == column && *goes) {
                continue;
            }
            let alone = spot.root && matches!(node, SpotNode::Leaf { .. });
            if alone {
                match spot.row {
                    None => columns.push((column, true, Vec::new())),
                    Some(row) => match columns.iter_mut().find(|(c, _, _)| *c == column) {
                        Some((_, _, rows)) => rows.push(row),
                        None => columns.push((column, false, vec![row])),
                    },
                }
                continue;
            }
        }
        let rest = match node {
            SpotNode::Leaf { .. } => Vec::new(),
            SpotNode::Stack { panes, .. } => panes.iter().copied().filter(|p| *p != pane).collect(),
            SpotNode::Split { .. } => continue,
        };
        let edit = match (node, rest.first()) {
            (SpotNode::Stack { expanded, .. }, Some(first)) => Some(Part::Stack {
                expanded: if *expanded == pane { *first } else { *expanded },
                panes: rest,
            }),
            _ if spot.root => return None,
            _ => None,
        };
        patch.spots.push(SpotEdit { spot: at, node: edit });
    }
    columns.sort_unstable_by_key(|c| std::cmp::Reverse(c.0));
    for (at, goes, mut rows) in columns {
        if goes {
            patch.columns.push(ColumnEdit::Remove { at });
            continue;
        }
        rows.sort_unstable_by_key(|r| std::cmp::Reverse(*r));
        let rows = rows.into_iter().map(|at| RowEdit::Remove { at }).collect();
        patch.columns.push(ColumnEdit::Change { at, layout: None, rows });
    }
    Some(patch)
}

/// `move-tab` to display `index` of a pane holding `target_count` tabs (the moving one too when
/// it moves within its pane): the final index, clamped; none when it is where it was.
pub fn move_tab(same_pane: bool, from: usize, index: i64, target_count: usize) -> Option<MoveTo> {
    let last = if same_pane { target_count.saturating_sub(1) } else { target_count };
    let final_index = usize::try_from(index.max(0)).unwrap_or(usize::MAX).min(last);
    if same_pane && from == final_index {
        return None;
    }
    Some(MoveTo { final_index })
}

/// The workspace at `from` placed by `kind`: its new daemon-order index, or none when it stays
/// where it is in the group it is in.
pub fn place_workspace(
    groups: &[Option<String>],
    from: usize,
    kind: PlaceKind,
    group: Option<&str>,
    index: i64,
) -> Option<PlaceAt> {
    let current = groups.get(from)?.as_deref();
    let last = groups.len() - 1;
    let (index, group) = match kind {
        PlaceKind::Move => (clamp(index, last), current),
        PlaceKind::Group => (from, group),
        PlaceKind::Place => (section_placement(groups, from, group, index), group),
    };
    if index == from && current == group {
        return None;
    }
    Some(PlaceAt { index })
}

fn clamp(index: i64, last: usize) -> usize {
    usize::try_from(index.max(0)).unwrap_or(usize::MAX).min(last)
}

/// cmux-tui's `move-workspace-to-group` placement (presentation.rs `move_workspace_to_group`): a
/// section is the daemon order filtered by group, so the workspace goes before the member now at
/// section `index`, after the last member, or stays put in an empty section. A negative index
/// means the front.
pub fn section_placement(
    groups: &[Option<String>],
    old: usize,
    group: Option<&str>,
    index: i64,
) -> usize {
    let remaining: Vec<usize> = (0..groups.len()).filter(|i| *i != old).collect();
    let members: Vec<usize> = groups
        .iter()
        .enumerate()
        .filter(|(i, g)| *i != old && g.as_deref() == group)
        .map(|(i, _)| i)
        .collect();
    let position = |target: usize| remaining.iter().position(|i| *i == target).unwrap_or(old);
    let mut new = old;
    if let Some(&last) = members.last() {
        let at = usize::try_from(index.max(0)).unwrap_or(usize::MAX);
        new = members.get(at).map_or(position(last) + 1, |m| position(*m));
    }
    new.min(groups.len().saturating_sub(1))
}

/// `set-row-heights` on rows `rows`: the new heights in row order, or none when the column's
/// row set differs (the daemon refuses that, `row-set-stale`) or nothing changes. A row named
/// twice takes its last height.
pub fn row_heights(rows: &[RowNow], heights: &[RowHeight]) -> Option<Heights> {
    let mut by_row: Vec<RowHeight> = Vec::with_capacity(heights.len());
    for height in heights {
        match by_row.iter_mut().find(|h| h.row == height.row) {
            Some(known) => known.height = height.height,
            None => by_row.push(*height),
        }
    }
    let same_set = rows.len() == by_row.len()
        && rows.iter().all(|r| by_row.iter().any(|h| h.row == r.id))
        && by_row.iter().all(|h| rows.iter().any(|r| r.id == h.row));
    if !same_set {
        return None;
    }
    let next: Vec<RowHeight> = rows
        .iter()
        .map(|r| RowHeight {
            row: r.id,
            height: by_row.iter().find(|h| h.row == r.id).map_or(r.height, |h| h.height),
        })
        .collect();
    if next.iter().zip(rows).all(|(n, r)| n.height == r.height) {
        return None;
    }
    Some(Heights { heights: next })
}

/// `move-tab`'s final index and the tab's current index in the daemon's order of a pane, for a
/// move of `moving` to `index` of the visible tabs: each held close's tabs go back where they
/// were (newest close undone first, each close's last removed first), and the tab goes right
/// before the visible tab now at `index` (else last).
pub fn daemon_move_index(
    visible: &[u64],
    moving: u64,
    index: i64,
    held: &[Vec<HeldTab>],
) -> DaemonMove {
    let mut order = visible.to_vec();
    let others: Vec<u64> = visible.iter().copied().filter(|s| *s != moving).collect();
    for close in held.iter().rev() {
        for tab in close.iter().rev() {
            let at = tab.index.min(order.len());
            order.insert(at, tab.surface);
        }
    }
    let full: Vec<u64> = order.iter().copied().filter(|s| *s != moving).collect();
    let skip = usize::try_from(index.max(0)).unwrap_or(usize::MAX);
    let final_index =
        others.get(skip).and_then(|next| full.iter().position(|s| s == next)).unwrap_or(full.len());
    DaemonMove { final_index, current: order.iter().position(|s| *s == moving) }
}

/// Whether `handle` is a stand-in's (a provisional pane, column or row the daemon has not made).
pub fn is_provisional(handle: u64) -> bool {
    handle >= PROVISIONAL_BIT
}

/// The deepest JSON nesting an `optimistic` request may have. serde_json's default limit (128)
/// refused every request for a screen split into a chain of about 125 panes or more (each split
/// nests its sides one level deeper), so the app's intents there showed nothing. This bound admits
/// a 600-pane chain inside a column's rows and still refuses input nested past any layout a person
/// can make, before the recursive parse could exhaust the caller's stack.
pub const MAX_NESTING: usize = 640;

/// Whether `bytes` nests objects and arrays at most `limit` deep (strings skipped): a byte scan,
/// so the parse after it can run without serde_json's fixed recursion limit.
fn nesting_within(bytes: &[u8], limit: usize) -> bool {
    let (mut depth, mut in_string, mut escaped) = (0usize, false, false);
    for &byte in bytes {
        if in_string {
            if escaped {
                escaped = false;
            } else if byte == b'\\' {
                escaped = true;
            } else if byte == b'"' {
                in_string = false;
            }
            continue;
        }
        match byte {
            b'"' => in_string = true,
            b'{' | b'[' => {
                depth += 1;
                if depth > limit {
                    return false;
                }
            }
            b'}' | b']' => depth = depth.saturating_sub(1),
            _ => {}
        }
    }
    true
}

fn parse_bounded<T: serde::de::DeserializeOwned>(bytes: &[u8]) -> serde_json::Result<T> {
    if !nesting_within(bytes, MAX_NESTING) {
        return Err(serde::de::Error::custom(format!(
            "JSON nested deeper than {MAX_NESTING} levels"
        )));
    }
    let mut deserializer = serde_json::Deserializer::from_slice(bytes);
    deserializer.disable_recursion_limit();
    let value = T::deserialize(&mut deserializer)?;
    deserializer.end()?;
    Ok(value)
}

/// Reads one `optimistic` request (the JSON the app sends), nested up to [`MAX_NESTING`] deep.
pub fn parse_request(bytes: &[u8]) -> serde_json::Result<Request> {
    parse_bounded(bytes)
}

/// Reads any JSON value under the same rules as [`parse_request`] (an answer read back).
pub fn parse_value(bytes: &[u8]) -> serde_json::Result<Value> {
    parse_bounded(bytes)
}
