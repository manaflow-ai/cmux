//! The app's side of an `optimistic` split, dock or pane removal, as a reference for the Swift
//! store: the generic walks that turn the whole screen into a request (found nodes and facts),
//! and the generic splice that writes the answer's patch back into the screen. A screen, column
//! or row here is the whole record the app holds; the request carries none of them.

#![allow(dead_code)]

use cmux_layout_reducer::optimistic::{ColumnEdit, Node, Part, Patch, RowEdit};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

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

/// A screen's records: its tree, its columns, its zoomed pane and its panes' order.
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

/// What the screen shows once a patch is in (the old whole-screen answer).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct View {
    pub layout: Node,
    pub columns: Vec<Column>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pane_at: Option<usize>,
}

/// What `find` looks for.
#[derive(Clone, Copy, Debug)]
pub enum Match {
    /// A leaf showing this pane.
    Leaf(u64),
    /// A split with this daemon handle.
    Split(u64),
    /// A leaf showing this pane, or a stack holding it.
    Holding(u64),
}

pub fn contains(node: &Node, pane: u64) -> bool {
    match node {
        Node::Leaf { pane: leaf } => *leaf == pane,
        Node::Split { a, b, .. } => contains(a, pane) || contains(b, pane),
        Node::Stack { panes, .. } => panes.contains(&pane),
        Node::Unknown => false,
    }
}

fn matches(node: &Node, want: Match) -> bool {
    match (node, want) {
        (Node::Leaf { pane }, Match::Leaf(p) | Match::Holding(p)) => *pane == p,
        (Node::Split { split, .. }, Match::Split(h)) => *split == Some(h),
        (Node::Stack { panes, .. }, Match::Holding(p)) => panes.contains(&p),
        _ => false,
    }
}

/// The first node, depth-first from the root through splits only (`a` before `b`), that `want`
/// names, and its path (`false`: `a`, `true`: `b`).
pub fn find(node: &Node, want: Match) -> Option<(&Node, Vec<bool>)> {
    fn walk<'a>(node: &'a Node, want: Match, path: &mut Vec<bool>) -> Option<&'a Node> {
        if matches(node, want) {
            return Some(node);
        }
        let Node::Split { a, b, .. } = node else { return None };
        for (side, child) in [(false, a), (true, b)] {
            path.push(side);
            if let Some(found) = walk(child, want, path) {
                return Some(found);
            }
            path.pop();
        }
        None
    }
    let mut path = Vec::new();
    walk(node, want, &mut path).map(|found| (found, path))
}

pub fn last_pane(node: &Node) -> Option<u64> {
    match node {
        Node::Leaf { pane } => Some(*pane),
        Node::Split { b, .. } => last_pane(b),
        Node::Stack { expanded, .. } => Some(*expanded),
        Node::Unknown => None,
    }
}

/// The first and last index in `panes` of a pane `tree` holds.
pub fn span(tree: &Node, panes: &[u64]) -> Option<[usize; 2]> {
    let first = panes.iter().position(|p| contains(tree, *p))?;
    let last = panes.iter().rposition(|p| contains(tree, *p))?;
    Some([first, last])
}

/// A tree of the screen: its own, a column's, or a column's row's.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Tree {
    Screen,
    Column(usize),
    Row(usize, usize),
}

/// A spot's tree and the found node's path there (none when the tree holds no such node).
pub type Found = (Tree, Option<Vec<bool>>);

/// A request and, for each of its spots, the tree it names and the found node's path there.
#[derive(Clone, Debug)]
pub struct Built {
    pub request: Value,
    pub spots: Vec<Found>,
}

fn tree(screen: &Screen, at: Tree) -> &Node {
    match at {
        Tree::Screen => &screen.layout,
        Tree::Column(c) => &screen.columns[c].layout,
        Tree::Row(c, r) => &screen.columns[c].rows[r].layout,
    }
}

fn tree_mut(screen: &mut Screen, at: Tree) -> &mut Node {
    match at {
        Tree::Screen => &mut screen.layout,
        Tree::Column(c) => &mut screen.columns[c].layout,
        Tree::Row(c, r) => &mut screen.columns[c].rows[r].layout,
    }
}

fn spot_node(node: &Node) -> Value {
    match node {
        Node::Leaf { pane } => json!({"type": "leaf", "pane": pane}),
        Node::Split { split, .. } => {
            let mut out = Map::new();
            out.insert("type".into(), json!("split"));
            if let Some(split) = split {
                out.insert("split".into(), json!(split));
            }
            if let Some(last) = last_pane(node) {
                out.insert("last_pane".into(), json!(last));
            }
            Value::Object(out)
        }
        Node::Stack { panes, expanded } => {
            json!({"type": "stack", "panes": panes, "expanded": expanded})
        }
        Node::Unknown => Value::Null,
    }
}

/// The screen's tree, then each column whose tree holds `pane` and each of its rows that does.
fn spots(screen: &Screen, pane: u64, want: Match) -> (Vec<Value>, Vec<Found>) {
    let mut trees = vec![Tree::Screen];
    for (c, column) in screen.columns.iter().enumerate() {
        if !contains(&column.layout, pane) {
            continue;
        }
        trees.push(Tree::Column(c));
        for (r, row) in column.rows.iter().enumerate() {
            if contains(&row.layout, pane) {
                trees.push(Tree::Row(c, r));
            }
        }
    }
    let mut out = Vec::new();
    let mut found = Vec::new();
    for at in trees {
        let mut spot = Map::new();
        match at {
            Tree::Screen => {}
            Tree::Column(c) => {
                spot.insert("column".into(), json!(c));
            }
            Tree::Row(c, r) => {
                spot.insert("column".into(), json!(c));
                spot.insert("row".into(), json!(r));
            }
        }
        match find(tree(screen, at), want) {
            Some((node, path)) => {
                if path.is_empty() {
                    spot.insert("root".into(), json!(true));
                }
                spot.insert("node".into(), spot_node(node));
                found.push((at, Some(path)));
            }
            None => {
                spot.insert("node".into(), Value::Null);
                found.push((at, None));
            }
        }
        out.push(Value::Object(spot));
    }
    (out, found)
}

fn index_of(panes: &[u64], pane: u64) -> Value {
    panes.iter().position(|p| *p == pane).map_or(Value::Null, |i| json!(i))
}

/// The request the app sends for `intent` (a `split`, `dock` or `remove_pane` request without
/// its facts and spots) on `screen`; none for any other op.
pub fn request(screen: &Screen, intent: &Value) -> Option<Built> {
    let mut request = intent.as_object()?.clone();
    request.remove("screen");
    request.remove("facts");
    request.remove("spots");
    let number = |key: &str| intent.get(key).and_then(Value::as_u64);
    let set = |key: &str| intent.get(key).is_some_and(|v| !v.is_null());
    let mut facts = Map::new();
    let found = match intent.get("op")?.as_str()? {
        "split" => {
            let (target, leaf) = (number("target")?, number("leaf")?);
            let (column, row) = (set("column"), set("row"));
            // A New Column or New Row reads the target's leaf, whatever `around` says.
            let want = match number("around") {
                Some(around) if !column && !row => Match::Split(around),
                _ => Match::Leaf(target),
            };
            facts.insert("leaf_placed".into(), json!(contains(&screen.layout, leaf)));
            if column || row {
                facts.insert("zoomed".into(), json!(screen.zoomed_pane.is_some()));
            }
            facts.insert("columns".into(), json!(screen.columns.len()));
            facts.insert("panes".into(), json!(screen.panes.len()));
            if !column {
                facts.insert("target_index".into(), index_of(&screen.panes, target));
            }
            if column || row {
                let in_screen = contains(&screen.layout, target);
                facts.insert("in_screen".into(), json!(in_screen));
                let at = screen.columns.iter().position(|c| contains(&c.layout, target));
                facts.insert("column".into(), at.map_or(Value::Null, |i| json!(i)));
                if column {
                    let tree = match at {
                        Some(i) => Some(&screen.columns[i].layout),
                        None if screen.columns.is_empty() => Some(&screen.layout),
                        None => None,
                    };
                    let span = tree.and_then(|t| span(t, &screen.panes));
                    facts.insert("span".into(), span.map_or(Value::Null, |s| json!(s)));
                } else {
                    let rows = at.map_or(&[][..], |i| &screen.columns[i].rows[..]);
                    facts.insert("rows".into(), json!(rows.len()));
                    let row = rows.iter().position(|r| contains(&r.layout, target));
                    facts.insert("row".into(), row.map_or(Value::Null, |i| json!(i)));
                }
            }
            let (spots, found) = spots(screen, target, want);
            request.insert("facts".into(), Value::Object(facts));
            request.insert("spots".into(), Value::Array(spots));
            found
        }
        "dock" => {
            let leaf = number("leaf")?;
            facts.insert("leaf_placed".into(), json!(contains(&screen.layout, leaf)));
            facts.insert("zoomed".into(), json!(screen.zoomed_pane.is_some()));
            facts.insert("columns".into(), json!(screen.columns.len()));
            let edges: Vec<&str> = screen
                .columns
                .iter()
                .filter_map(|c| c.dock.as_ref()?.get("edge")?.as_str())
                .collect();
            facts.insert("dock_edges".into(), json!(edges));
            request.insert("facts".into(), Value::Object(facts));
            Vec::new()
        }
        "remove_pane" => {
            let pane = number("pane")?;
            let (spots, found) = spots(screen, pane, Match::Holding(pane));
            request.insert("spots".into(), Value::Array(spots));
            found
        }
        _ => return None,
    };
    Some(Built { request: Value::Object(request), spots: found })
}

/// The trees a part may name besides its own nodes.
struct Named<'a> {
    held: Option<&'a Node>,
    screen: &'a Node,
    column: Option<&'a Column>,
}

fn resolve(part: &Part, named: &Named<'_>) -> Node {
    match part {
        Part::Leaf { pane } => Node::Leaf { pane: *pane },
        Part::Split { split_id, dir, ratio, a, b } => Node::Split {
            split: None,
            split_id: split_id.clone(),
            dir: *dir,
            ratio: *ratio,
            a: Box::new(resolve(a, named)),
            b: Box::new(resolve(b, named)),
        },
        Part::Stack { panes, expanded } => {
            Node::Stack { panes: panes.clone(), expanded: *expanded }
        }
        Part::Held => named.held.expect("held outside a spot edit").clone(),
        Part::Screen => named.screen.clone(),
        Part::Column => named.column.expect("column outside a change").layout.clone(),
        Part::Row { row } => named.column.expect("row outside a change").rows[*row].layout.clone(),
    }
}

fn at_path<'a>(node: &'a mut Node, path: &[bool]) -> &'a mut Node {
    let Some((first, rest)) = path.split_first() else { return node };
    let Node::Split { a, b, .. } = node else { panic!("a path through a non-split") };
    at_path(if *first { b } else { a }, rest)
}

/// `screen` with `patch` spliced in: spot edits first, then the tree, then the column edits.
pub fn splice(screen: &Screen, built: &Built, patch: &Patch) -> View {
    let before = screen.layout.clone();
    let mut out = screen.clone();
    for edit in &patch.spots {
        let (at, path) = &built.spots[edit.spot];
        let path = path.as_deref().expect("an edit of a spot with no node");
        let tree = tree_mut(&mut out, *at);
        match &edit.node {
            Some(part) => {
                let node = at_path(tree, path);
                let held = node.clone();
                let named = Named { held: Some(&held), screen: &before, column: None };
                *node = resolve(part, &named);
            }
            None => {
                let (side, parent) = path.split_last().expect("a root that goes");
                let parent = at_path(tree, parent);
                let Node::Split { a, b, .. } = parent else { panic!("a parent that is no split") };
                let other = if *side { (**a).clone() } else { (**b).clone() };
                *parent = other;
            }
        }
    }
    if let Some(layout) = &patch.layout {
        out.layout = resolve(layout, &Named { held: None, screen: &before, column: None });
    }
    for edit in &patch.columns {
        match edit {
            ColumnEdit::Insert { at, id, width, layout, dock, rows } => {
                let named = Named { held: None, screen: &before, column: None };
                let rows = rows
                    .iter()
                    .map(|r| Row { id: r.id, height: r.height, layout: resolve(&r.layout, &named) })
                    .collect();
                let layout = resolve(layout, &named);
                out.columns.insert(
                    *at,
                    Column { id: *id, width: *width, layout, dock: dock.clone(), rows },
                );
            }
            ColumnEdit::Remove { at } => {
                out.columns.remove(*at);
            }
            ColumnEdit::Change { at, layout, rows } => {
                let was = out.columns[*at].clone();
                let named = Named { held: None, screen: &before, column: Some(&was) };
                let column = &mut out.columns[*at];
                if let Some(layout) = layout {
                    column.layout = resolve(layout, &named);
                }
                for row in rows {
                    match row {
                        RowEdit::Insert { at, id, height, layout } => {
                            let layout = resolve(layout, &named);
                            column.rows.insert(*at, Row { id: *id, height: *height, layout });
                        }
                        RowEdit::Remove { at } => {
                            column.rows.remove(*at);
                        }
                    }
                }
            }
        }
    }
    View { layout: out.layout, columns: out.columns, pane_at: patch.pane_at }
}
