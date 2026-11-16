//! Insert New at a divider (`insert_at_divider` of the `optimistic` operation): a new pane opens
//! at a split's divider, between the two sides it separates, and takes its room from both.
//!
//! The model's splits are binary, so the divider of split `S = a | b` is S itself. The new pane
//! goes right after `a`, wrapping all of `a` (cmux-tui `split` with `around`, `split-around-v1`)
//! or splitting it when it is one pane, so `S` becomes `(a | new) | b`. The three then share S's
//! old extent in thirds: S's ratio becomes two thirds and the new split halves its two thirds.
//! Every other ratio stays, so the panes inside `a` and `b` keep their proportions.
//!
//! The answer names the split request the app sends (its `target`, `around` and `dir`) and the
//! divider's new ratio, which goes with the split as a held ratio intent (`showSplitSizing`), so
//! the window shows the new pane and its sizes in one layout before the daemon answers.

use serde::{Deserialize, Serialize};

use crate::optimistic::{Dir, Node};

/// S's new ratio: `a` and the new pane take two thirds, `b` the last third.
pub const DIVIDER_RATIO: f64 = 2.0 / 3.0;
/// The new split's ratio: `a` and the new pane share their two thirds evenly.
pub const NEW_SPLIT_RATIO: f64 = 0.5;

/// Where a pane inserted at a split's divider goes.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct DividerInsert {
    /// The pane the split request names: `a`'s last pane, which touches the divider.
    pub target: u64,
    /// `a`'s split handle when `a` is more than one pane: the new pane wraps it whole. None when
    /// `a` is one pane (a plain split of `target`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub around: Option<u64>,
    /// The divider's axis, which the new split takes.
    pub dir: Dir,
    /// The divider split's handle and its new ratio.
    pub split: u64,
    pub ratio: f64,
}

/// The insertion at the divider of split `split` (the daemon's handle) in `layout`, or none when
/// `layout` has no such split or the split's first side shows no pane to aim at.
pub fn plan(layout: &Node, split: u64) -> Option<DividerInsert> {
    let (dir, a) = find(layout, split)?;
    let target = last_pane(a)?;
    let around = match a {
        Node::Split { split: handle, .. } => Some((*handle)?),
        _ => None,
    };
    Some(DividerInsert { target, around, dir, split, ratio: DIVIDER_RATIO })
}

/// The split `handle`'s axis and first side.
fn find(node: &Node, handle: u64) -> Option<(Dir, &Node)> {
    match node {
        Node::Split { split, dir, a, b, .. } => {
            if *split == Some(handle) {
                return Some((*dir, a));
            }
            find(a, handle).or_else(|| find(b, handle))
        }
        _ => None,
    }
}

/// The last pane of `node` in depth-first order (a split's second side, a stack's shown pane):
/// the one beside a divider after it.
pub fn last_pane(node: &Node) -> Option<u64> {
    match node {
        Node::Leaf { pane } => Some(*pane),
        Node::Split { b, .. } => last_pane(b),
        Node::Stack { expanded, .. } => Some(*expanded),
        Node::Unknown => None,
    }
}

/// `node` with split `around` wrapped in a new split under public id `split_id`, `around` first
/// and `new` after it at `ratio`, when `around`'s last pane is `target` (cmux-tui
/// `Node::split_around` with the new pane after). None when no such split is in `node`.
pub fn split_around(
    node: &Node,
    around: u64,
    target: u64,
    dir: Dir,
    ratio: f64,
    new: u64,
    split_id: &str,
) -> Option<Node> {
    let Node::Split { split, split_id: id, dir: d, ratio: r, a, b } = node else { return None };
    if *split == Some(around) {
        return (last_pane(node) == Some(target)).then(|| Node::Split {
            split: None,
            split_id: Some(split_id.to_owned()),
            dir,
            ratio,
            a: Box::new(node.clone()),
            b: Box::new(Node::Leaf { pane: new }),
        });
    }
    let rebuilt = |a: Node, b: Node| Node::Split {
        split: *split,
        split_id: id.clone(),
        dir: *d,
        ratio: *r,
        a: Box::new(a),
        b: Box::new(b),
    };
    if let Some(a2) = split_around(a, around, target, dir, ratio, new, split_id) {
        return Some(rebuilt(a2, (**b).clone()));
    }
    split_around(b, around, target, dir, ratio, new, split_id).map(|b2| rebuilt((**a).clone(), b2))
}

/// `node` with split `handle`'s ratio set to `ratio`; unchanged when it has no such split.
pub fn with_ratio(node: &Node, handle: u64, ratio: f64) -> Node {
    match node {
        Node::Split { split, split_id, dir, ratio: r, a, b } => Node::Split {
            split: *split,
            split_id: split_id.clone(),
            dir: *dir,
            ratio: if *split == Some(handle) { ratio } else { *r },
            a: Box::new(with_ratio(a, handle, ratio)),
            b: Box::new(with_ratio(b, handle, ratio)),
        },
        other => other.clone(),
    }
}

/// What the window shows for `plan` before the daemon answers: the new pane `new` placed under
/// public id `split_id` and the divider at its new ratio. None when the plan does not fit
/// `layout`.
pub fn shown(layout: &Node, plan: &DividerInsert, new: u64, split_id: &str) -> Option<Node> {
    let placed = match plan.around {
        Some(around) => {
            split_around(layout, around, plan.target, plan.dir, NEW_SPLIT_RATIO, new, split_id)?
        }
        None => crate::optimistic::split_leaf(
            layout,
            plan.target,
            plan.dir,
            NEW_SPLIT_RATIO,
            new,
            split_id,
        )?,
    };
    Some(with_ratio(&placed, plan.split, plan.ratio))
}

#[cfg(test)]
#[path = "divider_insert_tests.rs"]
mod tests;
