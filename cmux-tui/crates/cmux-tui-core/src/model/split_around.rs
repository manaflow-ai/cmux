//! A new pane split off a whole subtree rather than one leaf: a closed pane
//! reopened beside the sibling split it left (`A | (B / C)` closes A and
//! reopens as `A | (B / C)`, not `(A | B) / C`).

use super::Node;
use crate::{PaneId, SplitDir, SplitId};

impl Node {
    /// Wrap split `target` in a new split `split_id` with `new_pane` before
    /// (`before`) or after it, when `target` is in this tree and `edge` is
    /// the leaf of `target` that touches the new pane (its first leaf when
    /// `before`, else its last). False, with nothing changed, otherwise.
    pub(crate) fn split_around(
        &mut self,
        target: SplitId,
        edge: PaneId,
        split_id: SplitId,
        dir: SplitDir,
        new_pane: PaneId,
        before: bool,
    ) -> bool {
        match self {
            Node::Split { id, .. } if *id == target => {
                if self.edge_pane(before) != Some(edge) {
                    return false;
                }
                let old = std::mem::replace(self, Node::Leaf(new_pane));
                let (a, b) =
                    if before { (Node::Leaf(new_pane), old) } else { (old, Node::Leaf(new_pane)) };
                *self = Node::Split {
                    id: split_id,
                    dir,
                    ratio: 0.5,
                    a: Box::new(a),
                    b: Box::new(b),
                    divider_hidden: false,
                };
                true
            }
            Node::Split { a, b, .. } => {
                a.split_around(target, edge, split_id, dir, new_pane, before)
                    || b.split_around(target, edge, split_id, dir, new_pane, before)
            }
            Node::Leaf(_) | Node::Stack { .. } => false,
        }
    }

    /// Whether split `target` is in this tree and `pane` is its last leaf
    /// (what [`Self::split_around`] needs to wrap it with a pane after it).
    pub(crate) fn split_ends_at(&self, target: SplitId, pane: PaneId) -> bool {
        match self {
            Node::Split { id, .. } if *id == target => self.edge_pane(false) == Some(pane),
            Node::Split { a, b, .. } => {
                a.split_ends_at(target, pane) || b.split_ends_at(target, pane)
            }
            Node::Leaf(_) | Node::Stack { .. } => false,
        }
    }

    /// The first (or last) leaf of this node; a stack's shown pane.
    fn edge_pane(&self, first: bool) -> Option<PaneId> {
        match self {
            Node::Leaf(pane) => Some(*pane),
            Node::Stack { expanded, .. } => Some(*expanded),
            Node::Split { a, b, .. } => (if first { a } else { b }).edge_pane(first),
        }
    }
}
