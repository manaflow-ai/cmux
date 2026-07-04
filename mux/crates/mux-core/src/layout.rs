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
