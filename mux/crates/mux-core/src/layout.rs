//! Pure layout math shared by frontends: a screen's split tree plus a
//! rectangle produce pane rects that tile the area exactly.

use crate::{Node, PaneId, SplitDir};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Rect {
    pub x: u16,
    pub y: u16,
    pub width: u16,
    pub height: u16,
}

impl Rect {
    pub fn contains(&self, x: u16, y: u16) -> bool {
        x >= self.x && x < self.x + self.width && y >= self.y && y < self.y + self.height
    }

    fn center(&self) -> (i32, i32) {
        (self.x as i32 + self.width as i32 / 2, self.y as i32 + self.height as i32 / 2)
    }
}

#[derive(Debug, Default)]
pub struct LayoutResult {
    pub panes: Vec<(PaneId, Rect)>,
}

impl LayoutResult {
    pub fn rect_of(&self, pane: PaneId) -> Option<Rect> {
        self.panes.iter().find(|(id, _)| *id == pane).map(|(_, r)| *r)
    }

    pub fn pane_at(&self, x: u16, y: u16) -> Option<PaneId> {
        self.panes.iter().find(|(_, r)| r.contains(x, y)).map(|(id, _)| *id)
    }

    /// The nearest pane in a direction from `from`, judged by center
    /// distance among panes whose span overlaps perpendicular to the
    /// direction of travel.
    pub fn neighbor(&self, from: PaneId, dx: i32, dy: i32) -> Option<PaneId> {
        let from_rect = self.rect_of(from)?;
        let (fx, fy) = from_rect.center();
        self.panes
            .iter()
            .filter(|(id, _)| *id != from)
            .filter(|(_, r)| {
                let (cx, cy) = r.center();
                if dx != 0 {
                    (cx - fx) * dx > 0
                } else {
                    (cy - fy) * dy > 0
                }
            })
            .min_by_key(|(_, r)| {
                let (cx, cy) = r.center();
                // Weight travel axis normally, cross axis heavily.
                if dx != 0 {
                    (cx - fx).abs() + (cy - fy).abs() * 4
                } else {
                    (cy - fy).abs() + (cx - fx).abs() * 4
                }
            })
            .map(|(id, _)| *id)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SplitEdge {
    Left,
    Right,
    Top,
    Bottom,
}

impl SplitEdge {
    fn dir(self) -> SplitDir {
        match self {
            SplitEdge::Left | SplitEdge::Right => SplitDir::Right,
            SplitEdge::Top | SplitEdge::Bottom => SplitDir::Down,
        }
    }

    fn after_first(self) -> bool {
        matches!(self, SplitEdge::Right | SplitEdge::Bottom)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SplitResize {
    pub area: Rect,
    /// Pane id chosen so `Mux::set_ratio(pane, dir, ratio)` targets this split.
    pub set_pane: PaneId,
}

/// Compute pane rects for a screen. Panes tile the area exactly; each
/// pane draws its own border box inside its rect, so no divider cells
/// are reserved between siblings.
pub fn layout_screen(root: &Node, area: Rect) -> LayoutResult {
    let mut result = LayoutResult::default();
    walk(root, area, &mut result);
    result
}

fn walk(node: &Node, area: Rect, out: &mut LayoutResult) {
    match node {
        Node::Leaf(id) => out.panes.push((*id, area)),
        Node::Split { dir, ratio, a, b } => {
            // Too small to hold two panes: give the whole area to the
            // first side and zero-size the second (frontends draw nothing
            // for empty rects; pane sizes clamp to 1).
            let too_small = match dir {
                SplitDir::Right => area.width < 2,
                SplitDir::Down => area.height < 2,
            };
            if too_small {
                walk(a, area, out);
                walk(b, Rect { width: 0, height: 0, ..area }, out);
                return;
            }
            let (a_rect, b_rect) = split_sides(area, *dir, *ratio);
            walk(a, a_rect, out);
            walk(b, b_rect, out);
        }
    }
}

/// Split boundary matching a concrete pane border edge. Outer pane edges return
/// `None`; only visible boundaries shared with a sibling split produce a target.
pub fn split_for_pane_edge(
    root: &Node,
    area: Rect,
    pane: PaneId,
    edge: SplitEdge,
) -> Option<SplitResize> {
    let pane_rect = layout_screen(root, area).rect_of(pane)?;
    let mut best = None;
    split_for_pane_edge_walk(root, area, pane, pane_rect, edge, &mut best);
    best
}

fn split_for_pane_edge_walk(
    node: &Node,
    area: Rect,
    pane: PaneId,
    pane_rect: Rect,
    edge: SplitEdge,
    best: &mut Option<SplitResize>,
) {
    let Node::Split { dir, ratio, a, b } = node else { return };
    let too_small = match dir {
        SplitDir::Right => area.width < 2,
        SplitDir::Down => area.height < 2,
    };
    if too_small {
        return;
    }
    let (a_rect, b_rect) = split_sides(area, *dir, *ratio);
    if *dir == edge.dir() {
        let pane_in_a = a.contains(pane);
        let pane_in_b = b.contains(pane);
        let boundary = match dir {
            SplitDir::Right => b_rect.x,
            SplitDir::Down => b_rect.y,
        };
        let matches_boundary = match edge {
            SplitEdge::Right => pane_in_a && pane_rect.x + pane_rect.width == boundary,
            SplitEdge::Left => pane_in_b && pane_rect.x == boundary,
            SplitEdge::Bottom => pane_in_a && pane_rect.y + pane_rect.height == boundary,
            SplitEdge::Top => pane_in_b && pane_rect.y == boundary,
        };
        if matches_boundary {
            let first = leaf_without_crossing_dir(a, *dir);
            let second = leaf_without_crossing_dir(b, *dir);
            let set_pane = if edge.after_first() { second.or(first) } else { first.or(second) };
            if let Some(set_pane) = set_pane {
                *best = Some(SplitResize { area, set_pane });
            }
        }
    }
    if a.contains(pane) {
        split_for_pane_edge_walk(a, a_rect, pane, pane_rect, edge, best);
    } else if b.contains(pane) {
        split_for_pane_edge_walk(b, b_rect, pane, pane_rect, edge, best);
    }
}

fn leaf_without_crossing_dir(node: &Node, dir: SplitDir) -> Option<PaneId> {
    match node {
        Node::Leaf(id) => Some(*id),
        Node::Split { dir: split_dir, a, b, .. } => {
            if *split_dir == dir {
                None
            } else {
                leaf_without_crossing_dir(a, dir).or_else(|| leaf_without_crossing_dir(b, dir))
            }
        }
    }
}

/// The two rects a split of `area` produces. Shared by the layout walk
/// and by frontends predicting the size of a pane about to be created.
pub fn split_sides(area: Rect, dir: SplitDir, ratio: f32) -> (Rect, Rect) {
    match dir {
        SplitDir::Right => {
            let a_w = ((area.width as f32) * ratio).round() as u16;
            let a_w = a_w.clamp(1, area.width.saturating_sub(1).max(1));
            (Rect { width: a_w, ..area }, Rect { x: area.x + a_w, width: area.width - a_w, ..area })
        }
        SplitDir::Down => {
            let a_h = ((area.height as f32) * ratio).round() as u16;
            let a_h = a_h.clamp(1, area.height.saturating_sub(1).max(1));
            (
                Rect { height: a_h, ..area },
                Rect { y: area.y + a_h, height: area.height - a_h, ..area },
            )
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_tile_exactly() {
        let root = Node::Split {
            dir: SplitDir::Right,
            ratio: 0.5,
            a: Box::new(Node::Leaf(1)),
            b: Box::new(Node::Leaf(2)),
        };
        let layout = layout_screen(&root, Rect { x: 0, y: 0, width: 80, height: 24 });
        let r1 = layout.rect_of(1).unwrap();
        let r2 = layout.rect_of(2).unwrap();
        assert_eq!(r1.width, 40);
        assert_eq!(r2.width, 40);
        assert_eq!(r2.x, 40);
        // Panes tile without gaps: every cell belongs to exactly one pane.
        assert_eq!(layout.pane_at(39, 0), Some(1));
        assert_eq!(layout.pane_at(40, 0), Some(2));
    }

    #[test]
    fn split_for_pane_edge_avoids_nested_same_direction_representatives() {
        let area = Rect { x: 0, y: 0, width: 100, height: 20 };
        let mut one_nested_side = Node::Split {
            dir: SplitDir::Right,
            ratio: 0.5,
            a: Box::new(Node::Split {
                dir: SplitDir::Right,
                ratio: 0.5,
                a: Box::new(Node::Leaf(1)),
                b: Box::new(Node::Leaf(3)),
            }),
            b: Box::new(Node::Leaf(2)),
        };
        let target = split_for_pane_edge(&one_nested_side, area, 3, SplitEdge::Right).unwrap();
        assert_eq!(target.area, area);
        assert_eq!(target.set_pane, 2);
        assert!(one_nested_side.set_deepest_ratio(target.set_pane, SplitDir::Right, 0.7));
        let Node::Split { ratio: root_ratio, a, .. } = &one_nested_side else {
            panic!("root should be split");
        };
        assert_eq!(*root_ratio, 0.7);
        let Node::Split { ratio: inner_ratio, .. } = a.as_ref() else {
            panic!("left child should be split");
        };
        assert_eq!(*inner_ratio, 0.5);

        let mut nested_both_sides = Node::Split {
            dir: SplitDir::Right,
            ratio: 0.5,
            a: Box::new(Node::Split {
                dir: SplitDir::Right,
                ratio: 0.5,
                a: Box::new(Node::Leaf(1)),
                b: Box::new(Node::Leaf(3)),
            }),
            b: Box::new(Node::Split {
                dir: SplitDir::Right,
                ratio: 0.5,
                a: Box::new(Node::Leaf(2)),
                b: Box::new(Node::Leaf(4)),
            }),
        };
        assert!(split_for_pane_edge(&nested_both_sides, area, 3, SplitEdge::Right).is_none());
        assert!(split_for_pane_edge(&nested_both_sides, area, 2, SplitEdge::Left).is_none());

        let left_inner =
            split_for_pane_edge(&nested_both_sides, area, 1, SplitEdge::Right).unwrap();
        assert_eq!(left_inner.area, Rect { x: 0, y: 0, width: 50, height: 20 });
        assert!(nested_both_sides.set_deepest_ratio(left_inner.set_pane, SplitDir::Right, 0.3));

        let right_inner =
            split_for_pane_edge(&nested_both_sides, area, 2, SplitEdge::Right).unwrap();
        assert_eq!(right_inner.area, Rect { x: 50, y: 0, width: 50, height: 20 });
        assert!(nested_both_sides.set_deepest_ratio(right_inner.set_pane, SplitDir::Right, 0.8));

        let Node::Split { ratio: root_ratio, a, b, .. } = &nested_both_sides else {
            panic!("root should be split");
        };
        assert_eq!(*root_ratio, 0.5);
        let Node::Split { ratio: left_ratio, .. } = a.as_ref() else {
            panic!("left child should be split");
        };
        let Node::Split { ratio: right_ratio, .. } = b.as_ref() else {
            panic!("right child should be split");
        };
        assert_eq!(*left_ratio, 0.3);
        assert_eq!(*right_ratio, 0.8);
    }

    #[test]
    fn degenerate_areas_do_not_underflow() {
        let root = Node::Split {
            dir: SplitDir::Right,
            ratio: 0.5,
            a: Box::new(Node::Leaf(1)),
            b: Box::new(Node::Split {
                dir: SplitDir::Down,
                ratio: 0.5,
                a: Box::new(Node::Leaf(2)),
                b: Box::new(Node::Leaf(3)),
            }),
        };
        for w in 0..5u16 {
            for h in 0..5u16 {
                let layout = layout_screen(&root, Rect { x: 0, y: 0, width: w, height: h });
                assert_eq!(layout.panes.len(), 3, "{w}x{h}");
            }
        }
    }

    #[test]
    fn neighbor_directional() {
        let root = Node::Split {
            dir: SplitDir::Right,
            ratio: 0.5,
            a: Box::new(Node::Leaf(1)),
            b: Box::new(Node::Split {
                dir: SplitDir::Down,
                ratio: 0.5,
                a: Box::new(Node::Leaf(2)),
                b: Box::new(Node::Leaf(3)),
            }),
        };
        let layout = layout_screen(&root, Rect { x: 0, y: 0, width: 80, height: 24 });
        assert_eq!(layout.neighbor(1, 1, 0), Some(2));
        assert_eq!(layout.neighbor(2, 0, 1), Some(3));
        assert_eq!(layout.neighbor(3, 0, -1), Some(2));
        assert_eq!(layout.neighbor(2, -1, 0), Some(1));
        assert_eq!(layout.neighbor(1, -1, 0), None);
    }
}
