//! The optimistic view's rules (`optimistic`): what a pending intent shows on top of the
//! confirmed mirror before the daemon settles it (plans/cmux-next/OWNERSHIP-PRINCIPLES.md,
//! "Clients are projections"). The app keeps the records and their identities; it asks these
//! rules where a provisional pane, column, row or dock goes, what a hidden pane leaves behind,
//! where a moved tab or workspace lands and which row heights a divider release writes, and
//! writes the answer into its records. Every rule is pure: the same request always answers the
//! same view, and a request the daemon would refuse answers `null` (the intent shows nothing).
//!
//! The layout shapes are the daemon's wire shapes (`type`, `pane`, `split`, `split_id`, `dir`,
//! `ratio`, `a`, `b`, `panes`, `expanded`; columns `id`, `width`, `layout`, `dock`, `rows`),
//! so the app encodes its snapshots as it decodes them. One JSON operation (`optimistic` of
//! `cmux_layout_reducer_json`) answers every request, tagged by `op`.

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
    /// A node type this client does not know: kept as it is.
    #[serde(other)]
    Unknown,
}

impl Node {
    fn leaf(pane: u64) -> Self {
        Node::Leaf { pane }
    }

    /// An unnamed split (the compat trees the daemon keeps beside columns and rows).
    fn pair(dir: Dir, a: Node, b: Node) -> Self {
        Node::Split { split: None, split_id: None, dir, ratio: 0.5, a: Box::new(a), b: Box::new(b) }
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

/// One row of a column (`rows-v1`): `height` in permille.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Row {
    pub id: u64,
    pub height: i64,
    pub layout: Node,
}

/// One column of a screen (`viewport-splits-v1`); `dock` is the daemon's dock record as sent.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Column {
    pub id: u64,
    pub width: f64,
    pub layout: Node,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dock: Option<Value>,
    #[serde(default)]
    pub rows: Vec<Row>,
}

impl Column {
    fn plain(id: u64, width: f64, layout: Node) -> Self {
        Column { id, width, layout, dock: None, rows: Vec::new() }
    }

    fn dock_edge(&self) -> Option<&str> {
        self.dock.as_ref()?.get("edge")?.as_str()
    }
}

/// What the rules read of a screen: its tree, its columns, its zoomed pane and its panes'
/// order (the records' `panes`).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Screen {
    pub layout: Node,
    #[serde(default)]
    pub columns: Vec<Column>,
    #[serde(default)]
    pub zoomed_pane: Option<u64>,
    #[serde(default)]
    pub panes: Vec<u64>,
}

/// A screen's new tree and columns.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Shown {
    pub layout: Node,
    pub columns: Vec<Column>,
}

/// A split's, column's or row's answer: the new tree and columns, and where the provisional
/// pane goes in the screen's panes (used only when the records do not hold the daemon's pane).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Placed {
    pub layout: Node,
    pub columns: Vec<Column>,
    pub pane_at: usize,
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
    /// daemon's pane under the split's public id before its layout places it).
    Split {
        screen: Screen,
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
    },
    /// Insert New at the divider of split `split` in `layout` (the tree holding it): the split
    /// request to send and the divider's new ratio (`divider_insert`).
    InsertAtDivider { layout: Node, split: u64 },
    /// A lone tab docked into a new leading column holding `leaf`.
    Dock { screen: Screen, leaf: u64, column: ColumnSpec, dock: Value },
    /// A pane taken out of the visible records (a creation the person closed first).
    RemovePane { screen: Screen, pane: u64 },
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
        Request::Split { screen, target, dir, ratio, leaf, split_id, column, row, around } => {
            json(match around {
                Some(around) => {
                    split_around_target(screen, *around, *target, *dir, *ratio, *leaf, split_id)
                }
                None => split(
                    screen,
                    *target,
                    *dir,
                    *ratio,
                    *leaf,
                    split_id,
                    column.as_ref(),
                    row.as_ref(),
                ),
            })
        }
        Request::InsertAtDivider { layout, split } => {
            json(crate::divider_insert::plan(layout, *split))
        }
        Request::Dock { screen, leaf, column, dock } => {
            json(dock_column(screen, *leaf, column, dock))
        }
        Request::RemovePane { screen, pane } => json(remove_pane(screen, *pane)),
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
    match node {
        Node::Leaf { pane } if *pane == target => Some(Node::Split {
            split: None,
            split_id: Some(split_id.to_owned()),
            dir,
            ratio,
            a: Box::new(Node::leaf(target)),
            b: Box::new(Node::leaf(new)),
        }),
        Node::Split { split, split_id: id, dir: d, ratio: r, a, b } => {
            let rebuilt = |a: Node, b: Node| Node::Split {
                split: *split,
                split_id: id.clone(),
                dir: *d,
                ratio: *r,
                a: Box::new(a),
                b: Box::new(b),
            };
            if let Some(a2) = split_leaf(a, target, dir, ratio, new, split_id) {
                return Some(rebuilt(a2, (**b).clone()));
            }
            split_leaf(b, target, dir, ratio, new, split_id).map(|b2| rebuilt((**a).clone(), b2))
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

/// Where the new pane goes in the screen's panes: right after `target` (at the end when the
/// target is not listed).
fn after_target(panes: &[u64], target: u64) -> usize {
    let at = panes.iter().position(|p| *p == target).map_or(panes.len(), |i| i + 1);
    at.min(panes.len())
}

/// A split of `target` (`split_kind.rs`: the target's column tree and row tree take it too),
/// New Column (`column`) or New Row (`row`). None when cmux-tui would refuse it.
#[allow(clippy::too_many_arguments)]
pub fn split(
    screen: &Screen,
    target: u64,
    dir: Dir,
    ratio: f64,
    leaf: u64,
    split_id: &str,
    column: Option<&ColumnSpec>,
    row: Option<&RowSpec>,
) -> Option<Placed> {
    if let Some(column) = column {
        return new_column(screen, target, leaf, column);
    }
    if let Some(row) = row {
        return new_row(screen, target, leaf, split_id, row);
    }
    let layout = split_leaf(&screen.layout, target, dir, ratio, leaf, split_id)?;
    let mut columns = Vec::with_capacity(screen.columns.len());
    for column in &screen.columns {
        if !column.layout.contains(target) {
            columns.push(column.clone());
            continue;
        }
        let mut column = column.clone();
        column.layout = split_leaf(&column.layout, target, dir, ratio, leaf, split_id)?;
        for row in &mut column.rows {
            if row.layout.contains(target) {
                row.layout = split_leaf(&row.layout, target, dir, ratio, leaf, split_id)?;
            }
        }
        columns.push(column);
    }
    Some(Placed { layout, columns, pane_at: after_target(&screen.panes, target) })
}

/// A split of `target` around the whole split `around` (`split-around-v1`, Insert New at a
/// divider): every tree that holds `around` (the screen's, its column's, its row's) wraps it, as
/// cmux-tui's `split_around` does. None when no tree holds `around` with `target` as its last pane.
fn split_around_target(
    screen: &Screen,
    around: u64,
    target: u64,
    dir: Dir,
    ratio: f64,
    leaf: u64,
    split_id: &str,
) -> Option<Placed> {
    use crate::divider_insert::split_around;
    let wrap = |node: &Node| split_around(node, around, target, dir, ratio, leaf, split_id);
    let mut placed = false;
    let layout = match wrap(&screen.layout) {
        Some(layout) => {
            placed = true;
            layout
        }
        None => screen.layout.clone(),
    };
    let mut columns = screen.columns.clone();
    for column in &mut columns {
        if let Some(wrapped) = wrap(&column.layout) {
            column.layout = wrapped;
            placed = true;
        }
        for row in &mut column.rows {
            if let Some(wrapped) = wrap(&row.layout) {
                row.layout = wrapped;
                placed = true;
            }
        }
    }
    placed.then(|| Placed { layout, columns, pane_at: after_target(&screen.panes, target) })
}

/// New Column (`new-pane-right`, cmux-tui `new_pane_right`): a column holding `leaf` right after
/// the target's column (before it for New Column Left), at its width; every other column keeps
/// its width (R3b). A split-tree screen becomes its tree at full width and the new column, as the
/// daemon wraps its root in a viewport split. A zoomed split-tree screen has nothing to open
/// beside.
fn new_column(screen: &Screen, target: u64, leaf: u64, spec: &ColumnSpec) -> Option<Placed> {
    let mut columns = screen.columns.clone();
    if columns.is_empty() {
        if screen.zoomed_pane.is_some() {
            return None;
        }
        columns.push(Column::plain(spec.handle | SIBLING_BIT, 1.0, screen.layout.clone()));
    }
    let index = columns.iter().position(|c| c.layout.contains(target))?;
    let anchor = columns.get(index)?.layout.pane_ids();
    columns.insert(
        if spec.left { index } else { index + 1 },
        Column::plain(spec.handle, spec.width, Node::leaf(leaf)),
    );
    let layout = if spec.left {
        Node::pair(Dir::Right, Node::leaf(leaf), screen.layout.clone())
    } else {
        Node::pair(Dir::Right, screen.layout.clone(), Node::leaf(leaf))
    };
    let panes = &screen.panes;
    let at = if spec.left {
        panes.iter().position(|p| anchor.contains(p)).unwrap_or(0)
    } else {
        panes.iter().rposition(|p| anchor.contains(p)).map_or(panes.len(), |i| i + 1)
    };
    Some(Placed { layout, columns, pane_at: at.min(panes.len()) })
}

/// New Row (`new-row`, cmux-tui `new_row_with_options_as`): a row holding `leaf` right below the
/// target's row in its column, at its height. A split-tree screen becomes one column, and a
/// column without rows gets its tree as its first row (1000), as the daemon does. The column's
/// `layout` stays the compat chain of its rows.
fn new_row(
    screen: &Screen,
    target: u64,
    leaf: u64,
    split_id: &str,
    spec: &RowSpec,
) -> Option<Placed> {
    if screen.zoomed_pane.is_some() {
        return None;
    }
    let first_handle = spec.handle | SIBLING_BIT;
    let mut columns = screen.columns.clone();
    if columns.is_empty() {
        columns.push(Column::plain(first_handle | ROW_COLUMN_BIT, 1.0, screen.layout.clone()));
    }
    let index = columns.iter().position(|c| c.layout.contains(target))?;
    let column = columns.get_mut(index)?;
    let mut rows = if column.rows.is_empty() {
        vec![Row { id: first_handle, height: 1000, layout: column.layout.clone() }]
    } else {
        column.rows.clone()
    };
    let at = rows.iter().position(|r| r.layout.contains(target))?;
    rows.insert(at + 1, Row { id: spec.handle, height: spec.height, layout: Node::leaf(leaf) });
    let mut chain: Option<Node> = None;
    for next in &rows {
        chain = Some(match chain {
            None => next.layout.clone(),
            Some(chain) => Node::pair(Dir::Down, chain, next.layout.clone()),
        });
    }
    let chain = chain?;
    column.layout = chain;
    column.rows = rows;
    let layout = split_leaf(&screen.layout, target, Dir::Down, 0.5, leaf, split_id)
        .unwrap_or_else(|| Node::pair(Dir::Down, screen.layout.clone(), Node::leaf(leaf)));
    Some(Placed { layout, columns, pane_at: after_target(&screen.panes, target) })
}

/// A lone tab docked into a new column (`move-tab-to-column {dock}`): the column holding `leaf`
/// leads the screen's columns (cmux-tui's `commit_tab_drag` puts a left dock first). A zoomed
/// screen, or one with a dock on that edge already, waits for the daemon's layout:
/// `reduce_column_dock` there moves the old holder, which this view does not show.
pub fn dock_column(screen: &Screen, leaf: u64, spec: &ColumnSpec, dock: &Value) -> Option<Shown> {
    let edge = dock.get("edge").and_then(Value::as_str);
    if screen.zoomed_pane.is_some() || screen.columns.iter().any(|c| c.dock_edge() == edge) {
        return None;
    }
    let mut columns = screen.columns.clone();
    if columns.is_empty() {
        columns.push(Column::plain(spec.handle | SIBLING_BIT, 1.0, screen.layout.clone()));
    }
    let mut docked = Column::plain(spec.handle, spec.width, Node::leaf(leaf));
    docked.dock = Some(dock.clone());
    columns.insert(0, docked);
    Some(Shown { layout: Node::pair(Dir::Right, Node::leaf(leaf), screen.layout.clone()), columns })
}

/// The screen without `pane` (a creation the person closed before the daemon made it): a column
/// or row that is only this pane goes with it. None when the pane is the whole screen tree, or
/// a column or row tree it is in cannot lose it: it stays shown until its close.
pub fn remove_pane(screen: &Screen, pane: u64) -> Option<Shown> {
    let layout = removing(pane, &screen.layout)?;
    let alone = Node::leaf(pane);
    let mut columns = Vec::with_capacity(screen.columns.len());
    for column in screen.columns.iter().filter(|c| c.layout != alone) {
        if !column.layout.contains(pane) {
            columns.push(column.clone());
            continue;
        }
        let mut column = column.clone();
        column.layout = removing(pane, &column.layout)?;
        let mut rows = Vec::with_capacity(column.rows.len());
        for row in column.rows.iter().filter(|r| r.layout != alone) {
            let mut row = row.clone();
            if row.layout.contains(pane) {
                row.layout = removing(pane, &row.layout)?;
            }
            rows.push(row);
        }
        column.rows = rows;
        columns.push(column);
    }
    Some(Shown { layout, columns })
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
