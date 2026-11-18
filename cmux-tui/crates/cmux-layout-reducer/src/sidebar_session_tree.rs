//! The sidebar's nested sessions (`sidebar.nestedSessions`, Claude desktop's Code tab): which rows
//! draw under which, how deep, which carry a fold chevron, and what a folded parent's status mark
//! shows for the sessions under it. The app hands one list's rows in its own order, each with the
//! row it hangs under (a workspace an agent started, a chat's sub-session) and its state; this
//! answers the drawn order. The app reaches it through `cmux_layout_reducer_json`
//! (`sidebar_session_tree`), and the fold toggle through `sidebar_session_tree_fold`.
//!
//! Rules:
//! - A row whose parent is in the list draws right after it, one level deeper, before the
//!   parent's next sibling, at any depth. Siblings keep the list's order.
//! - A parent missing from the list, or a parent chain that runs in a cycle, leaves the row a root.
//! - A parent is folded unless the person opened it (`expanded`), or `expandedByDefault` and the
//!   person did not fold it (`collapsed`). A filter draws every fold open.
//! - A folded parent's descendants do not draw; its status mark shows the most urgent of its own
//!   state and theirs (needs input, then failed, then running), and its roll-up counts them.
//! - No shift: folding or opening a row never moves a row above it, and the rows past its
//!   subtree keep their order and depth (`sidebar_session_tree_tests.rs` checks every case).

use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};

/// What a row's session is doing, least to most urgent.
#[derive(
    Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize,
)]
#[serde(rename_all = "camelCase")]
pub enum State {
    #[default]
    Idle,
    Done,
    Running,
    Failed,
    NeedsInput,
}

impl State {
    /// Whether a folded parent's mark takes this state from a child.
    fn rolls_up(self) -> bool {
        matches!(self, Self::Running | Self::Failed | Self::NeedsInput)
    }
}

/// One row of the list, in the list's order.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Row {
    pub id: String,
    /// The row it hangs under; none for a root.
    pub parent: Option<String>,
    pub state: State,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Request {
    pub rows: Vec<Row>,
    /// Parents the person opened.
    pub expanded: Vec<String>,
    /// Parents the person folded.
    pub collapsed: Vec<String>,
    /// A parent nobody folded or opened draws open.
    pub expanded_by_default: bool,
    /// A filter shows: every fold draws open.
    pub filtering: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Fold {
    Expanded,
    Collapsed,
}

/// A folded parent's hidden sessions, counted by what they do.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RollUp {
    pub needs_input: u32,
    pub failed: u32,
    pub running: u32,
    pub hidden: u32,
}

/// One drawn row.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DrawnRow {
    /// Its index in the request's rows.
    pub index: usize,
    pub depth: u32,
    /// Its chevron: none on a row without children.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fold: Option<Fold>,
    /// What its status mark shows: its own state, or on a folded parent the most urgent of its
    /// own and its hidden sessions'.
    pub mark: State,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub roll_up: Option<RollUp>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Response {
    pub rows: Vec<DrawnRow>,
}

/// Each row's children (indices, in list order). A row is a child only when its parent is in the
/// list and its parent chain reaches a root without a cycle. One pass: each answer is kept.
fn children(rows: &[Row]) -> HashMap<usize, Vec<usize>> {
    let index: HashMap<&str, usize> =
        rows.iter().enumerate().rev().map(|(i, row)| (row.id.as_str(), i)).collect();
    let parent_of = |i: usize| -> Option<usize> {
        let parent = rows[i].parent.as_deref()?;
        index.get(parent).copied().filter(|p| *p != i)
    };
    // Some(true): reaches a root; Some(false): on or under a cycle.
    let mut rooted: Vec<Option<bool>> = vec![None; rows.len()];
    for start in 0..rows.len() {
        let mut path = Vec::new();
        let mut on_path = HashSet::new();
        let mut next = Some(start);
        let mut answer = true;
        while let Some(current) = next {
            if let Some(known) = rooted[current] {
                answer = known;
                break;
            }
            if !on_path.insert(current) {
                answer = false;
                break;
            }
            path.push(current);
            next = parent_of(current);
        }
        for node in path {
            rooted[node] = Some(answer);
        }
    }
    let mut children: HashMap<usize, Vec<usize>> = HashMap::new();
    for (i, row) in rows.iter().enumerate() {
        // A repeated id keeps its first row; a later one is a root.
        if index.get(row.id.as_str()) != Some(&i) {
            continue;
        }
        if let Some(parent) = parent_of(i).filter(|_| rooted[i] == Some(true)) {
            children.entry(parent).or_default().push(i);
        }
    }
    children
}

/// The drawn rows of `request`.
pub fn respond(request: &Request) -> Response {
    let rows = &request.rows;
    let children = children(rows);
    let nested: HashSet<usize> = children.values().flatten().copied().collect();
    let expanded: HashSet<&str> = request.expanded.iter().map(String::as_str).collect();
    let collapsed: HashSet<&str> = request.collapsed.iter().map(String::as_str).collect();
    let is_open = |id: &str| {
        request.filtering
            || expanded.contains(id)
            || (request.expanded_by_default && !collapsed.contains(id))
    };
    let mut drawn = Vec::with_capacity(rows.len());
    // Depth-first, without recursion (a chain can be as long as the list).
    let mut stack: Vec<(usize, u32)> = Vec::new();
    for root in (0..rows.len()).rev().filter(|i| !nested.contains(i)) {
        stack.push((root, 0));
    }
    while let Some((i, depth)) = stack.pop() {
        let row = &rows[i];
        let kids = children.get(&i).map_or(&[][..], Vec::as_slice);
        let mut out = DrawnRow { index: i, depth, fold: None, mark: row.state, roll_up: None };
        if !kids.is_empty() {
            if is_open(&row.id) {
                out.fold = Some(Fold::Expanded);
                for &kid in kids.iter().rev() {
                    stack.push((kid, depth + 1));
                }
            } else {
                out.fold = Some(Fold::Collapsed);
                let mut roll = RollUp::default();
                let mut below: Vec<usize> = kids.to_vec();
                while let Some(k) = below.pop() {
                    roll.hidden += 1;
                    let state = rows[k].state;
                    match state {
                        State::NeedsInput => roll.needs_input += 1,
                        State::Failed => roll.failed += 1,
                        State::Running => roll.running += 1,
                        State::Idle | State::Done => {}
                    }
                    if state.rolls_up() && state > out.mark {
                        out.mark = state;
                    }
                    below.extend(children.get(&k).into_iter().flatten().copied());
                }
                out.roll_up = Some(roll);
            }
        }
        drawn.push(out);
    }
    Response { rows: drawn }
}

/// The person's folds after a click on `id`'s chevron (or a Left/Right arrow on it).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct FoldRequest {
    pub expanded: Vec<String>,
    pub collapsed: Vec<String>,
    pub expanded_by_default: bool,
    pub id: String,
    /// Open it (true), fold it (false), or flip it (none).
    pub open: Option<bool>,
    /// Every row that has children now: a fold of a row that is no longer a parent is dropped,
    /// so the saved folds never outgrow the tree. Empty keeps every fold (the tree is not loaded).
    pub parents: Vec<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FoldResponse {
    /// Sorted, as saved.
    pub expanded: Vec<String>,
    pub collapsed: Vec<String>,
    /// Whether `id` draws open now.
    pub open: bool,
}

/// `request`'s folds with `id` opened, folded or flipped. Only the side that differs from the
/// default is kept for `id`: the person's choice persists per row, and a row back at the default
/// keeps nothing.
pub fn fold(request: &FoldRequest) -> FoldResponse {
    let mut expanded: HashSet<String> = request.expanded.iter().cloned().collect();
    let mut collapsed: HashSet<String> = request.collapsed.iter().cloned().collect();
    let id = request.id.clone();
    let was_open =
        expanded.contains(&id) || (request.expanded_by_default && !collapsed.contains(&id));
    let open = request.open.unwrap_or(!was_open);
    expanded.remove(&id);
    collapsed.remove(&id);
    if open != request.expanded_by_default {
        if open {
            expanded.insert(id)
        } else {
            collapsed.insert(id)
        };
    }
    if !request.parents.is_empty() {
        let live: HashSet<&str> = request.parents.iter().map(String::as_str).collect();
        expanded.retain(|id| live.contains(id.as_str()));
        collapsed.retain(|id| live.contains(id.as_str()));
    }
    let sorted = |set: HashSet<String>| {
        let mut list: Vec<String> = set.into_iter().collect();
        list.sort();
        list
    };
    FoldResponse { expanded: sorted(expanded), collapsed: sorted(collapsed), open }
}

#[cfg(test)]
#[path = "sidebar_session_tree_tests.rs"]
mod tests;
