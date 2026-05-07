//! Binary-tree pane layout.
//!
//! Matches cmux's bonsplit semantics: every non-leaf node is a split with a
//! direction and a ratio, and every leaf owns a pane id. This module is pure
//! data + geometry — no I/O, no libghostty-vt, no server coupling — so it's
//! cheap to test in isolation and reusable by the compositor landing later.
//!
//! M4 status: data model + rect computation + kill/split tested here.
//! Wiring this into the live server so `SplitRight` et al. actually
//! rearrange runtime panes is a follow-up milestone.

use std::collections::HashMap;

/// Opaque pane identifier. The server allocates these when spawning PTYs.
pub type PaneId = u64;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SplitDir {
    /// Two panes side by side: left is "first", right is "second".
    Horizontal,
    /// Two panes stacked: top is "first", bottom is "second".
    Vertical,
}

/// A binary-tree layout node. The tree root lives on [`Layout`].
#[derive(Debug, Clone, PartialEq)]
pub enum Node {
    Leaf(PaneId),
    Split {
        dir: SplitDir,
        /// Fraction of the enclosing rect given to the `first` child.
        /// Clamped to `[0.05, 0.95]` to prevent zero-size panes.
        ratio: f32,
        first: Box<Node>,
        second: Box<Node>,
    },
}

impl Node {
    /// Collect every leaf in depth-first order (first-child before second).
    pub fn leaves_into(&self, out: &mut Vec<PaneId>) {
        match self {
            Node::Leaf(id) => out.push(*id),
            Node::Split { first, second, .. } => {
                first.leaves_into(out);
                second.leaves_into(out);
            }
        }
    }

    /// Replace the given leaf (if it's in this subtree) with a new split.
    /// Returns true on success. The original leaf becomes the "first" side;
    /// the new pane id is placed second.
    fn split_leaf(&mut self, target: PaneId, new_id: PaneId, dir: SplitDir) -> bool {
        if let Node::Leaf(id) = self
            && *id == target
        {
            let old = *id;
            *self = Node::Split {
                dir,
                ratio: 0.5,
                first: Box::new(Node::Leaf(old)),
                second: Box::new(Node::Leaf(new_id)),
            };
            return true;
        }
        if let Node::Split { first, second, .. } = self {
            first.split_leaf(target, new_id, dir) || second.split_leaf(target, new_id, dir)
        } else {
            false
        }
    }

    /// Remove a leaf from this subtree. When the leaf is one side of a
    /// split, the sibling takes the parent's slot.
    fn remove_leaf(&mut self, target: PaneId) -> bool {
        match self {
            Node::Leaf(_) => false,
            Node::Split { first, second, .. } => {
                // Child is a leaf matching target → collapse.
                if matches!(first.as_ref(), Node::Leaf(id) if *id == target) {
                    let sibling = std::mem::replace(second.as_mut(), Node::Leaf(0));
                    *self = sibling;
                    return true;
                }
                if matches!(second.as_ref(), Node::Leaf(id) if *id == target) {
                    let sibling = std::mem::replace(first.as_mut(), Node::Leaf(0));
                    *self = sibling;
                    return true;
                }
                first.remove_leaf(target) || second.remove_leaf(target)
            }
        }
    }
}

/// Screen rectangle in cell coordinates. Row/col are the top-left cell;
/// rows/cols are the size.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Rect {
    pub col: u16,
    pub row: u16,
    pub cols: u16,
    pub rows: u16,
}

/// A full pane tree for a workspace.
#[derive(Debug, Clone)]
pub struct Layout {
    root: Node,
    next_id: PaneId,
}

impl Layout {
    /// Start with a single leaf holding `PaneId(0)`.
    #[must_use]
    pub fn new() -> Self {
        Self {
            root: Node::Leaf(0),
            next_id: 1,
        }
    }

    #[must_use]
    pub fn root(&self) -> &Node {
        &self.root
    }

    /// All leaves in depth-first order.
    #[must_use]
    pub fn leaves(&self) -> Vec<PaneId> {
        let mut v = Vec::new();
        self.root.leaves_into(&mut v);
        v
    }

    /// Split the given pane in `dir`. The new pane id is returned.
    /// Returns `None` if `target` doesn't exist.
    pub fn split(&mut self, target: PaneId, dir: SplitDir) -> Option<PaneId> {
        let new_id = self.next_id;
        if self.root.split_leaf(target, new_id, dir) {
            self.next_id += 1;
            Some(new_id)
        } else {
            None
        }
    }

    /// Remove a pane. Refuses to remove the root leaf (would leave the
    /// layout empty). Returns true if removed.
    pub fn remove(&mut self, target: PaneId) -> bool {
        if matches!(&self.root, Node::Leaf(id) if *id == target) {
            return false;
        }
        self.root.remove_leaf(target)
    }

    /// Compute the cell rect for every leaf given a client viewport.
    /// Reserved chrome (sidebar, status bar) is the caller's concern —
    /// they shrink the viewport before passing it in.
    #[must_use]
    pub fn rects(&self, viewport: Rect) -> HashMap<PaneId, Rect> {
        let mut out = HashMap::new();
        layout_walk(&self.root, viewport, &mut out);
        out
    }
}

impl Default for Layout {
    fn default() -> Self {
        Self::new()
    }
}

fn layout_walk(node: &Node, rect: Rect, out: &mut HashMap<PaneId, Rect>) {
    match node {
        Node::Leaf(id) => {
            out.insert(*id, rect);
        }
        Node::Split {
            dir,
            ratio,
            first,
            second,
        } => {
            let clamped = ratio.clamp(0.05, 0.95);
            match dir {
                SplitDir::Horizontal => {
                    let first_cols = split_extent(rect.cols, clamped);
                    let first_rect = Rect {
                        col: rect.col,
                        row: rect.row,
                        cols: first_cols,
                        rows: rect.rows,
                    };
                    let second_rect = Rect {
                        col: rect.col + first_cols,
                        row: rect.row,
                        cols: rect.cols.saturating_sub(first_cols),
                        rows: rect.rows,
                    };
                    layout_walk(first, first_rect, out);
                    layout_walk(second, second_rect, out);
                }
                SplitDir::Vertical => {
                    let first_rows = split_extent(rect.rows, clamped);
                    let first_rect = Rect {
                        col: rect.col,
                        row: rect.row,
                        cols: rect.cols,
                        rows: first_rows,
                    };
                    let second_rect = Rect {
                        col: rect.col,
                        row: rect.row + first_rows,
                        cols: rect.cols,
                        rows: rect.rows.saturating_sub(first_rows),
                    };
                    layout_walk(first, first_rect, out);
                    layout_walk(second, second_rect, out);
                }
            }
        }
    }
}

fn split_extent(extent: u16, ratio: f32) -> u16 {
    if extent < 2 {
        return extent;
    }
    (((extent as f32) * ratio).round() as u16).clamp(1, extent - 1)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn viewport() -> Rect {
        Rect {
            col: 0,
            row: 0,
            cols: 80,
            rows: 24,
        }
    }

    #[test]
    fn single_leaf_fills_viewport() {
        let layout = Layout::new();
        let rects = layout.rects(viewport());
        assert_eq!(rects.len(), 1);
        assert_eq!(rects.get(&0).copied(), Some(viewport()));
    }

    #[test]
    fn horizontal_split_divides_cols() {
        let mut layout = Layout::new();
        let b = layout.split(0, SplitDir::Horizontal).unwrap();
        let rects = layout.rects(viewport());
        let left = rects[&0];
        let right = rects[&b];
        assert_eq!(left.col, 0);
        assert_eq!(left.rows, 24);
        assert_eq!(right.col, left.cols);
        assert_eq!(left.cols + right.cols, 80);
    }

    #[test]
    fn vertical_split_divides_rows() {
        let mut layout = Layout::new();
        let b = layout.split(0, SplitDir::Vertical).unwrap();
        let rects = layout.rects(viewport());
        let top = rects[&0];
        let bot = rects[&b];
        assert_eq!(top.row, 0);
        assert_eq!(top.cols, 80);
        assert_eq!(bot.row, top.rows);
        assert_eq!(top.rows + bot.rows, 24);
    }

    #[test]
    fn nested_split_gives_four_leaves() {
        let mut layout = Layout::new();
        let right = layout.split(0, SplitDir::Horizontal).unwrap(); // 0 | right
        let bot_right = layout.split(right, SplitDir::Vertical).unwrap(); // bot_right under right
        let bot_left = layout.split(0, SplitDir::Vertical).unwrap(); // bot_left under 0
        let leaves = layout.leaves();
        assert_eq!(leaves.len(), 4, "leaves: {leaves:?}");
        for id in [0, bot_left, right, bot_right] {
            assert!(leaves.contains(&id));
        }
        let rects = layout.rects(viewport());
        assert_eq!(rects.len(), 4);
    }

    #[test]
    fn remove_collapses_sibling() {
        let mut layout = Layout::new();
        let right = layout.split(0, SplitDir::Horizontal).unwrap();
        assert!(layout.remove(right));
        assert_eq!(layout.leaves(), vec![0]);
        // Root leaf cannot be removed.
        assert!(!layout.remove(0));
    }

    #[test]
    fn split_missing_leaf_returns_none() {
        let mut layout = Layout::new();
        assert!(layout.split(999, SplitDir::Horizontal).is_none());
    }

    #[test]
    fn rects_handle_extreme_ratio() {
        // Programmatically tweak the ratio to 0.02; rects should still clamp.
        let mut layout = Layout::new();
        let _ = layout.split(0, SplitDir::Horizontal);
        if let Node::Split { ratio, .. } = &mut layout.root {
            *ratio = 0.02;
        }
        let rects = layout.rects(viewport());
        // Neither side should be 0 cols.
        for rect in rects.values() {
            assert!(rect.cols > 0, "zero-width pane: {rect:?}");
        }
    }

    #[test]
    fn split_keeps_both_children_visible_in_tiny_viewports() {
        let mut horizontal = Layout::new();
        let right = horizontal.split(0, SplitDir::Horizontal).unwrap();
        let rects = horizontal.rects(Rect {
            col: 0,
            row: 0,
            cols: 2,
            rows: 1,
        });
        assert_eq!(rects[&0].cols, 1);
        assert_eq!(rects[&right].cols, 1);

        let mut vertical = Layout::new();
        let bottom = vertical.split(0, SplitDir::Vertical).unwrap();
        let rects = vertical.rects(Rect {
            col: 0,
            row: 0,
            cols: 1,
            rows: 2,
        });
        assert_eq!(rects[&0].rows, 1);
        assert_eq!(rects[&bottom].rows, 1);
    }
}
