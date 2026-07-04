//! Pure layout math shared by frontends: a screen's split tree plus a
//! rectangle produce pane rects and separator segments.

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

/// A one-cell-thick divider line between two panes.
#[derive(Debug, Clone, Copy)]
pub struct Separator {
    pub rect: Rect,
    pub vertical: bool,
}

#[derive(Debug, Default)]
pub struct LayoutResult {
    pub panes: Vec<(PaneId, Rect)>,
    pub separators: Vec<Separator>,
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

/// Compute pane rects for a screen, reserving one cell per divider.
pub fn layout_screen(root: &Node, area: Rect) -> LayoutResult {
    let mut result = LayoutResult::default();
    walk(root, area, &mut result);
    result
}

fn walk(node: &Node, area: Rect, out: &mut LayoutResult) {
    match node {
        Node::Leaf(id) => out.panes.push((*id, area)),
        Node::Split { dir, ratio, a, b } => {
            // Too small to hold two panes plus a divider: give the whole
            // area to the first side and zero-size the second (frontends
            // draw nothing for empty rects; pane sizes clamp to 1).
            let too_small = match dir {
                SplitDir::Right => area.width < 3,
                SplitDir::Down => area.height < 3,
            };
            if too_small {
                walk(a, area, out);
                walk(b, Rect { width: 0, height: 0, ..area }, out);
                return;
            }
            walk_split(*dir, *ratio, a, b, area, out);
        }
    }
}

/// The rects a split of `area` produces: the first side, the one-cell
/// separator, and the second side. Shared by the layout walk and by
/// frontends predicting the size of a pane about to be created.
pub fn split_sides(area: Rect, dir: SplitDir, ratio: f32) -> (Rect, Rect, Rect) {
    match dir {
        SplitDir::Right => {
            let usable = area.width.saturating_sub(1);
            let a_w = ((usable as f32) * ratio).round() as u16;
            let a_w = a_w.clamp(1, usable.saturating_sub(1).max(1));
            (
                Rect { width: a_w, ..area },
                Rect { x: area.x + a_w, y: area.y, width: 1, height: area.height },
                Rect { x: area.x + a_w + 1, width: usable - a_w, ..area },
            )
        }
        SplitDir::Down => {
            let usable = area.height.saturating_sub(1);
            let a_h = ((usable as f32) * ratio).round() as u16;
            let a_h = a_h.clamp(1, usable.saturating_sub(1).max(1));
            (
                Rect { height: a_h, ..area },
                Rect { x: area.x, y: area.y + a_h, width: area.width, height: 1 },
                Rect { y: area.y + a_h + 1, height: usable - a_h, ..area },
            )
        }
    }
}

fn walk_split(dir: SplitDir, ratio: f32, a: &Node, b: &Node, area: Rect, out: &mut LayoutResult) {
    let (a_rect, sep, b_rect) = split_sides(area, dir, ratio);
    out.separators.push(Separator { rect: sep, vertical: matches!(dir, SplitDir::Right) });
    walk(a, a_rect, out);
    walk(b, b_rect, out);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_reserve_separator() {
        let root = Node::Split {
            dir: SplitDir::Right,
            ratio: 0.5,
            a: Box::new(Node::Leaf(1)),
            b: Box::new(Node::Leaf(2)),
        };
        let layout = layout_screen(&root, Rect { x: 0, y: 0, width: 81, height: 24 });
        let r1 = layout.rect_of(1).unwrap();
        let r2 = layout.rect_of(2).unwrap();
        assert_eq!(r1.width, 40);
        assert_eq!(r2.width, 40);
        assert_eq!(r2.x, 41);
        assert_eq!(layout.separators.len(), 1);
        assert_eq!(layout.separators[0].rect.x, 40);
        assert_eq!(layout.pane_at(39, 0), Some(1));
        assert_eq!(layout.pane_at(41, 0), Some(2));
        assert_eq!(layout.pane_at(40, 0), None);
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
