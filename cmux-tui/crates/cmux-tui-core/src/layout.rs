//! Pure layout math shared by frontends: a screen's split tree plus a
//! rectangle produce pane rects that tile the area exactly.

use std::collections::HashSet;

use crate::{Node, PaneId, SplitDir, SplitId};

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
}

#[derive(Debug, Default)]
pub struct LayoutResult {
    pub panes: Vec<(PaneId, Rect)>,
    /// Pane rows that represent collapsed Zellij stack headers rather than
    /// terminal content.
    pub stacked_headers: HashSet<PaneId>,
}

impl LayoutResult {
    pub fn rect_of(&self, pane: PaneId) -> Option<Rect> {
        self.panes.iter().find(|(id, _)| *id == pane).map(|(_, r)| *r)
    }

    pub fn pane_at(&self, x: u16, y: u16) -> Option<PaneId> {
        self.panes.iter().find(|(_, r)| r.contains(x, y)).map(|(id, _)| *id)
    }

    /// Best pane in a direction from `from`, matching the cmux app's
    /// bonsplit neighbor heuristic: greater perpendicular overlap wins,
    /// then smaller axial gap. No wraparound.
    pub fn neighbor(&self, from: PaneId, dx: i32, dy: i32) -> Option<PaneId> {
        directional_neighbor(&self.panes, from, dx, dy)
    }

    /// Zellij-style directional focus: among panes that share the requested
    /// edge, return the one focused most recently.
    pub fn neighbor_by_recency<R: Ord>(
        &self,
        from: PaneId,
        dx: i32,
        dy: i32,
        recency: impl Fn(PaneId) -> R,
    ) -> Option<PaneId> {
        directional_neighbor_by_recency(&self.panes, from, dx, dy, recency)
    }
}

pub fn directional_neighbor(
    panes: &[(PaneId, Rect)],
    from: PaneId,
    dx: i32,
    dy: i32,
) -> Option<PaneId> {
    let cur = panes.iter().find(|(id, _)| *id == from).map(|(_, rect)| *rect)?;
    let direction = if dx < 0 {
        Direction::Left
    } else if dx > 0 {
        Direction::Right
    } else if dy < 0 {
        Direction::Up
    } else if dy > 0 {
        Direction::Down
    } else {
        return None;
    };
    panes
        .iter()
        .copied()
        .enumerate()
        .filter(|(_, (id, rect))| *id != from && rect.width > 0 && rect.height > 0)
        .filter_map(|(order, (id, rect))| {
            direction.score(cur, rect).map(|score| (order, id, score))
        })
        .min_by_key(|(order, _, score)| (std::cmp::Reverse(score.overlap), score.distance, *order))
        .map(|(_, id, _)| id)
}

pub fn directional_neighbor_by_recency<R: Ord>(
    panes: &[(PaneId, Rect)],
    from: PaneId,
    dx: i32,
    dy: i32,
    recency: impl Fn(PaneId) -> R,
) -> Option<PaneId> {
    let cur = panes.iter().find(|(id, _)| *id == from).map(|(_, rect)| *rect)?;
    let direction = Direction::from_delta(dx, dy)?;
    panes
        .iter()
        .copied()
        .enumerate()
        .filter(|(_, (id, rect))| *id != from && rect.width > 0 && rect.height > 0)
        .filter_map(|(order, (id, rect))| {
            direction
                .score(cur, rect)
                .filter(|score| score.distance == 0 && score.overlap > 0)
                .map(|_| (recency(id), order, id))
        })
        .max_by(|(a_recency, a_order, _), (b_recency, b_order, _)| {
            a_recency.cmp(b_recency).then_with(|| b_order.cmp(a_order))
        })
        .map(|(_, _, id)| id)
}

#[derive(Clone, Copy)]
enum Direction {
    Left,
    Right,
    Up,
    Down,
}

#[derive(Clone, Copy)]
struct NeighborScore {
    overlap: u16,
    distance: u16,
}

impl Direction {
    fn from_delta(dx: i32, dy: i32) -> Option<Self> {
        if dx < 0 {
            Some(Direction::Left)
        } else if dx > 0 {
            Some(Direction::Right)
        } else if dy < 0 {
            Some(Direction::Up)
        } else if dy > 0 {
            Some(Direction::Down)
        } else {
            None
        }
    }

    fn score(self, cur: Rect, cand: Rect) -> Option<NeighborScore> {
        let (overlap, distance) = match self {
            Direction::Left => {
                let cur_min = cur.x;
                let cand_max = cand.x.saturating_add(cand.width);
                if cand_max > cur_min {
                    return None;
                }
                (overlap_len(cur.y, cur.height, cand.y, cand.height), cur_min - cand_max)
            }
            Direction::Right => {
                let cur_max = cur.x.saturating_add(cur.width);
                if cand.x < cur_max {
                    return None;
                }
                (overlap_len(cur.y, cur.height, cand.y, cand.height), cand.x - cur_max)
            }
            Direction::Up => {
                let cur_min = cur.y;
                let cand_max = cand.y.saturating_add(cand.height);
                if cand_max > cur_min {
                    return None;
                }
                (overlap_len(cur.x, cur.width, cand.x, cand.width), cur_min - cand_max)
            }
            Direction::Down => {
                let cur_max = cur.y.saturating_add(cur.height);
                if cand.y < cur_max {
                    return None;
                }
                (overlap_len(cur.x, cur.width, cand.x, cand.width), cand.y - cur_max)
            }
        };
        (overlap > 0).then_some(NeighborScore { overlap, distance })
    }
}

fn overlap_len(a_start: u16, a_len: u16, b_start: u16, b_len: u16) -> u16 {
    let start = a_start.max(b_start);
    let end = a_start.saturating_add(a_len).min(b_start.saturating_add(b_len));
    end.saturating_sub(start)
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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ExactSplitResize {
    pub area: Rect,
    pub split: SplitId,
}

/// Compute pane rects for a screen. Panes tile the area exactly; each
/// pane draws its own border box inside its rect, so no divider cells
/// are reserved between siblings.
pub fn layout_screen(root: &Node, area: Rect, active_pane: Option<PaneId>) -> LayoutResult {
    let mut result = LayoutResult::default();
    walk(root, area, active_pane, &mut result);
    result
}

/// Reproduce Zellij's default auto-layout sequence for panes in creation
/// order. Through twelve panes, the `vertical` family fills columns of four.
/// Above twelve panes, Zellij advances to `stacked`: the first pane stays
/// full-height on the left while the remaining panes stack on the right.
pub fn zellij_default_pane_layout(panes: &[PaneId]) -> Option<Node> {
    let mut next_split_id = 1;
    zellij_default_pane_layout_with_ids(panes, &mut || {
        let id = next_split_id;
        next_split_id += 1;
        id
    })
}

pub(crate) fn zellij_default_pane_layout_with_ids(
    panes: &[PaneId],
    next_split_id: &mut impl FnMut() -> SplitId,
) -> Option<Node> {
    match panes {
        [] => None,
        [pane] => Some(Node::Leaf(*pane)),
        panes if panes.len() > 12 => Some(zellij_stacked_layout(panes, next_split_id)),
        _ => {
            let first_column_len = if panes.len() <= 5 {
                1
            } else {
                let remainder = panes.len() % 4;
                if remainder == 0 { 4 } else { remainder }
            };
            let mut columns = Vec::new();
            columns.push(equal_split(&panes[..first_column_len], SplitDir::Down, next_split_id));
            for column in panes[first_column_len..].chunks(4) {
                columns.push(equal_split(column, SplitDir::Down, next_split_id));
            }
            Some(equal_nodes(columns, SplitDir::Right, next_split_id))
        }
    }
}

fn zellij_stacked_layout(panes: &[PaneId], next_split_id: &mut impl FnMut() -> SplitId) -> Node {
    debug_assert!(panes.len() > 1);
    Node::Split {
        id: next_split_id(),
        dir: SplitDir::Right,
        ratio: 0.5,
        a: Box::new(Node::Leaf(panes[0])),
        b: Box::new(
            Node::stack(panes[1..].to_vec()).expect("stacked layout requires at least one pane"),
        ),
    }
}

fn equal_split(
    panes: &[PaneId],
    dir: SplitDir,
    next_split_id: &mut impl FnMut() -> SplitId,
) -> Node {
    equal_nodes(panes.iter().copied().map(Node::Leaf).collect(), dir, next_split_id)
}

fn equal_nodes(
    mut nodes: Vec<Node>,
    dir: SplitDir,
    next_split_id: &mut impl FnMut() -> SplitId,
) -> Node {
    debug_assert!(!nodes.is_empty());
    if nodes.len() == 1 {
        return nodes.pop().unwrap();
    }
    let first = nodes.remove(0);
    let ratio = 1.0 / (nodes.len() + 1) as f32;
    Node::Split {
        id: next_split_id(),
        dir,
        ratio,
        a: Box::new(first),
        b: Box::new(equal_nodes(nodes, dir, next_split_id)),
    }
}

fn walk(node: &Node, area: Rect, active_pane: Option<PaneId>, out: &mut LayoutResult) {
    match node {
        Node::Leaf(id) => out.panes.push((*id, area)),
        Node::Split { dir, ratio, a, b, .. } => {
            // Too small to hold two panes: give the whole area to the
            // first side and zero-size the second (frontends draw nothing
            // for empty rects; pane sizes clamp to 1).
            let too_small = match dir {
                SplitDir::Right => area.width < 2,
                SplitDir::Down => area.height < 2,
            };
            if too_small {
                walk(a, area, active_pane, out);
                walk(b, Rect { width: 0, height: 0, ..area }, active_pane, out);
                return;
            }
            let (a_rect, b_rect) = split_sides(area, *dir, *ratio);
            walk(a, a_rect, active_pane, out);
            walk(b, b_rect, active_pane, out);
        }
        Node::Stack { panes, expanded } => {
            let panes = panes.as_slice();
            let expanded = active_pane.filter(|pane| panes.contains(pane)).unwrap_or(*expanded);
            walk_stack(panes, expanded, area, out);
        }
    }
}

fn walk_stack(panes: &[PaneId], expanded: PaneId, area: Rect, out: &mut LayoutResult) {
    let expanded_index = panes.iter().position(|pane| *pane == expanded).unwrap_or(panes.len() - 1);
    let visible_headers = usize::from(area.height.saturating_sub(1)).min(panes.len() - 1);
    let available_before = expanded_index;
    let available_after = panes.len() - expanded_index - 1;
    let mut headers_before = 0;
    let mut headers_after = 0;
    while headers_before + headers_after < visible_headers {
        let can_take_before = headers_before < available_before;
        let can_take_after = headers_after < available_after;
        if can_take_before && (!can_take_after || headers_before <= headers_after) {
            headers_before += 1;
        } else if can_take_after {
            headers_after += 1;
        } else {
            break;
        }
    }
    let expanded_height = area.height.saturating_sub((headers_before + headers_after) as u16);

    let mut y = area.y;
    for (index, pane) in panes.iter().copied().enumerate() {
        let height = if index == expanded_index {
            expanded_height
        } else if index >= expanded_index - headers_before && index < expanded_index
            || index > expanded_index && index <= expanded_index + headers_after
        {
            1
        } else {
            0
        };
        out.panes.push((pane, Rect { y, height, ..area }));
        if height == 1 && index != expanded_index {
            out.stacked_headers.insert(pane);
        }
        y = y.saturating_add(height);
    }
}

/// Split boundary matching a concrete pane border edge. Outer pane edges return
/// `None`; only visible boundaries shared with a sibling split produce a target.
pub fn split_for_pane_edge(
    root: &Node,
    area: Rect,
    active_pane: Option<PaneId>,
    pane: PaneId,
    edge: SplitEdge,
) -> Option<SplitResize> {
    let pane_rect = layout_screen(root, area, active_pane).rect_of(pane)?;
    let mut best = None;
    split_for_pane_edge_walk(root, area, active_pane, pane, pane_rect, edge, &mut best);
    best
}

/// Find the exact split node behind a concrete pane border edge.
///
/// Unlike [`split_for_pane_edge`], this remains unambiguous when both
/// sides contain nested splits in the same direction.
pub fn exact_split_for_pane_edge(
    root: &Node,
    area: Rect,
    active_pane: Option<PaneId>,
    pane: PaneId,
    edge: SplitEdge,
) -> Option<ExactSplitResize> {
    let pane_rect = layout_screen(root, area, active_pane).rect_of(pane)?;
    let mut best = None;
    exact_split_for_pane_edge_walk(root, area, pane, pane_rect, edge, &mut best);
    best
}

fn exact_split_for_pane_edge_walk(
    node: &Node,
    area: Rect,
    pane: PaneId,
    pane_rect: Rect,
    edge: SplitEdge,
    best: &mut Option<ExactSplitResize>,
) {
    let Node::Split { id, dir, ratio, a, b } = node else { return };
    let too_small = match dir {
        SplitDir::Right => area.width < 2,
        SplitDir::Down => area.height < 2,
    };
    if too_small {
        return;
    }
    let (a_rect, b_rect) = split_sides(area, *dir, *ratio);
    let pane_in_a = a.contains(pane);
    let pane_in_b = b.contains(pane);
    if *dir == edge.dir() {
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
            *best = Some(ExactSplitResize { area, split: *id });
        }
    }
    if pane_in_a {
        exact_split_for_pane_edge_walk(a, a_rect, pane, pane_rect, edge, best);
    } else if pane_in_b {
        exact_split_for_pane_edge_walk(b, b_rect, pane, pane_rect, edge, best);
    }
}

fn split_for_pane_edge_walk(
    node: &Node,
    area: Rect,
    active_pane: Option<PaneId>,
    pane: PaneId,
    pane_rect: Rect,
    edge: SplitEdge,
    best: &mut Option<SplitResize>,
) {
    let Node::Split { dir, ratio, a, b, .. } = node else { return };
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
            let first = leaf_without_crossing_dir(a, *dir, active_pane);
            let second = leaf_without_crossing_dir(b, *dir, active_pane);
            let set_pane = if edge.after_first() { second.or(first) } else { first.or(second) };
            if let Some(set_pane) = set_pane {
                *best = Some(SplitResize { area, set_pane });
            }
        }
    }
    if a.contains(pane) {
        split_for_pane_edge_walk(a, a_rect, active_pane, pane, pane_rect, edge, best);
    } else if b.contains(pane) {
        split_for_pane_edge_walk(b, b_rect, active_pane, pane, pane_rect, edge, best);
    }
}

fn leaf_without_crossing_dir(
    node: &Node,
    dir: SplitDir,
    active_pane: Option<PaneId>,
) -> Option<PaneId> {
    match node {
        Node::Leaf(id) => Some(*id),
        Node::Split { dir: split_dir, a, b, .. } => {
            if *split_dir == dir {
                None
            } else {
                leaf_without_crossing_dir(a, dir, active_pane)
                    .or_else(|| leaf_without_crossing_dir(b, dir, active_pane))
            }
        }
        Node::Stack { panes, expanded } => {
            active_pane.filter(|pane| panes.contains(pane)).or(Some(*expanded))
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
            id: 10,
            dir: SplitDir::Right,
            ratio: 0.5,
            a: Box::new(Node::Leaf(1)),
            b: Box::new(Node::Leaf(2)),
        };
        let layout = layout_screen(&root, Rect { x: 0, y: 0, width: 80, height: 24 }, None);
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
    fn zellij_default_layout_fills_right_column_before_adding_another() {
        let root = zellij_default_pane_layout(&[1, 2, 3, 4, 5]).unwrap();
        let layout = layout_screen(&root, Rect { x: 0, y: 0, width: 200, height: 40 }, None);

        assert_eq!(
            layout.panes,
            vec![
                (1, Rect { x: 0, y: 0, width: 100, height: 40 }),
                (2, Rect { x: 100, y: 0, width: 100, height: 10 }),
                (3, Rect { x: 100, y: 10, width: 100, height: 10 }),
                (4, Rect { x: 100, y: 20, width: 100, height: 10 }),
                (5, Rect { x: 100, y: 30, width: 100, height: 10 }),
            ]
        );
    }

    #[test]
    fn zellij_default_layout_balances_completed_columns_of_four() {
        for count in [8, 12] {
            let panes = (1..=count).collect::<Vec<_>>();
            let root = zellij_default_pane_layout(&panes).unwrap();
            let layout = layout_screen(
                &root,
                Rect { x: 0, y: 0, width: (count / 4 * 40) as u16, height: 40 },
                None,
            );

            assert_eq!(layout.panes.iter().map(|(pane, _)| *pane).collect::<Vec<_>>(), panes);
            assert!(layout.panes.iter().all(|(_, rect)| rect.width == 40 && rect.height == 10));
        }
    }

    #[test]
    fn zellij_default_layout_keeps_a_leading_pane_beside_the_stack() {
        let panes = (1..=13).collect::<Vec<_>>();
        let root = zellij_default_pane_layout(&panes).unwrap();
        let layout = layout_screen(&root, Rect { x: 0, y: 0, width: 120, height: 40 }, Some(13));

        assert_eq!(layout.panes.iter().map(|(pane, _)| *pane).collect::<Vec<_>>(), panes);
        assert_eq!(layout.panes[0].1, Rect { x: 0, y: 0, width: 60, height: 40 });
        for (index, (_, rect)) in layout.panes[1..12].iter().enumerate() {
            assert_eq!(*rect, Rect { x: 60, y: index as u16, width: 60, height: 1 });
        }
        assert_eq!(layout.stacked_headers.len(), 11);
        assert!(panes[1..12].iter().all(|pane| layout.stacked_headers.contains(pane)));
        assert_eq!(layout.panes[12].1, Rect { x: 60, y: 11, width: 60, height: 29 });
    }

    #[test]
    fn zellij_stacked_layout_keeps_the_leading_pane_full_height() {
        let panes = (1..=13).collect::<Vec<_>>();
        let root = zellij_default_pane_layout(&panes).unwrap();
        let layout = layout_screen(&root, Rect { x: 0, y: 0, width: 80, height: 5 }, Some(1));
        assert_eq!(layout.rect_of(1), Some(Rect { x: 0, y: 0, width: 40, height: 5 }));
        assert!(!layout.stacked_headers.contains(&1));
        assert_eq!(layout.stacked_headers.len(), 4);
    }

    #[test]
    fn short_stack_keeps_neighbors_reachable_on_both_sides() {
        let root = Node::stack(vec![1, 2, 3, 4, 5]).unwrap();
        let layout = layout_screen(&root, Rect { x: 0, y: 0, width: 80, height: 3 }, Some(4));

        assert_eq!(layout.rect_of(1).unwrap().height, 0);
        assert_eq!(layout.rect_of(2).unwrap().height, 0);
        assert_eq!(layout.rect_of(3), Some(Rect { x: 0, y: 0, width: 80, height: 1 }));
        assert_eq!(layout.rect_of(4), Some(Rect { x: 0, y: 1, width: 80, height: 1 }));
        assert_eq!(layout.rect_of(5), Some(Rect { x: 0, y: 2, width: 80, height: 1 }));
        assert_eq!(layout.stacked_headers, HashSet::from([3, 5]));
    }

    #[test]
    fn split_for_pane_edge_avoids_nested_same_direction_representatives() {
        let area = Rect { x: 0, y: 0, width: 100, height: 20 };
        let mut one_nested_side = Node::Split {
            id: 10,
            dir: SplitDir::Right,
            ratio: 0.5,
            a: Box::new(Node::Split {
                id: 11,
                dir: SplitDir::Right,
                ratio: 0.5,
                a: Box::new(Node::Leaf(1)),
                b: Box::new(Node::Leaf(3)),
            }),
            b: Box::new(Node::Leaf(2)),
        };
        let target =
            split_for_pane_edge(&one_nested_side, area, None, 3, SplitEdge::Right).unwrap();
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
            id: 20,
            dir: SplitDir::Right,
            ratio: 0.5,
            a: Box::new(Node::Split {
                id: 21,
                dir: SplitDir::Right,
                ratio: 0.5,
                a: Box::new(Node::Leaf(1)),
                b: Box::new(Node::Leaf(3)),
            }),
            b: Box::new(Node::Split {
                id: 22,
                dir: SplitDir::Right,
                ratio: 0.5,
                a: Box::new(Node::Leaf(2)),
                b: Box::new(Node::Leaf(4)),
            }),
        };
        assert!(split_for_pane_edge(&nested_both_sides, area, None, 3, SplitEdge::Right).is_none());
        assert!(split_for_pane_edge(&nested_both_sides, area, None, 2, SplitEdge::Left).is_none());
        assert_eq!(
            exact_split_for_pane_edge(&nested_both_sides, area, None, 3, SplitEdge::Right),
            Some(ExactSplitResize { area, split: 20 })
        );
        assert_eq!(
            exact_split_for_pane_edge(&nested_both_sides, area, None, 2, SplitEdge::Left),
            Some(ExactSplitResize { area, split: 20 })
        );

        let left_inner =
            split_for_pane_edge(&nested_both_sides, area, None, 1, SplitEdge::Right).unwrap();
        assert_eq!(left_inner.area, Rect { x: 0, y: 0, width: 50, height: 20 });
        assert!(nested_both_sides.set_deepest_ratio(left_inner.set_pane, SplitDir::Right, 0.3));

        let right_inner =
            split_for_pane_edge(&nested_both_sides, area, None, 2, SplitEdge::Right).unwrap();
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
    fn split_for_pane_edge_uses_the_active_stack_member_as_its_representative() {
        let root = Node::Split {
            id: 1,
            dir: SplitDir::Right,
            ratio: 0.5,
            a: Box::new(Node::stack(vec![1, 2, 3]).unwrap()),
            b: Box::new(Node::Leaf(4)),
        };

        let target = split_for_pane_edge(
            &root,
            Rect { x: 0, y: 0, width: 100, height: 20 },
            Some(2),
            4,
            SplitEdge::Left,
        )
        .unwrap();

        assert_eq!(target.set_pane, 2);
    }

    #[test]
    fn degenerate_areas_do_not_underflow() {
        let root = Node::Split {
            id: 30,
            dir: SplitDir::Right,
            ratio: 0.5,
            a: Box::new(Node::Leaf(1)),
            b: Box::new(Node::Split {
                id: 31,
                dir: SplitDir::Down,
                ratio: 0.5,
                a: Box::new(Node::Leaf(2)),
                b: Box::new(Node::Leaf(3)),
            }),
        };
        for w in 0..5u16 {
            for h in 0..5u16 {
                let layout = layout_screen(&root, Rect { x: 0, y: 0, width: w, height: h }, None);
                assert_eq!(layout.panes.len(), 3, "{w}x{h}");
            }
        }
    }

    #[test]
    fn neighbor_directional() {
        let root = Node::Split {
            id: 40,
            dir: SplitDir::Right,
            ratio: 0.5,
            a: Box::new(Node::Leaf(1)),
            b: Box::new(Node::Split {
                id: 41,
                dir: SplitDir::Down,
                ratio: 0.5,
                a: Box::new(Node::Leaf(2)),
                b: Box::new(Node::Leaf(3)),
            }),
        };
        let layout = layout_screen(&root, Rect { x: 0, y: 0, width: 80, height: 24 }, None);
        assert_eq!(layout.neighbor(1, 1, 0), Some(2));
        assert_eq!(layout.neighbor(2, 0, 1), Some(3));
        assert_eq!(layout.neighbor(3, 0, -1), Some(2));
        assert_eq!(layout.neighbor(2, -1, 0), Some(1));
        assert_eq!(layout.neighbor(1, -1, 0), None);
    }

    fn r(x: u16, y: u16, width: u16, height: u16) -> Rect {
        Rect { x, y, width, height }
    }

    fn dir(panes: &[(PaneId, Rect)], from: PaneId, dx: i32, dy: i32) -> Option<PaneId> {
        directional_neighbor(panes, from, dx, dy)
    }

    #[test]
    fn directional_focus_user_reported_layout_prefers_tall_top_by_overlap() {
        let panes = vec![
            (1, r(0, 0, 40, 30)),
            (2, r(40, 0, 40, 18)),
            (3, r(40, 18, 20, 12)),
            (4, r(60, 18, 20, 12)),
        ];
        assert_eq!(dir(&panes, 1, 1, 0), Some(2));
    }

    #[test]
    fn directional_focus_by_recency_returns_last_used_adjacent_pane() {
        let panes = vec![(1, r(0, 0, 40, 30)), (2, r(40, 0, 40, 18)), (3, r(40, 18, 40, 12))];
        let active_at = |pane| match pane {
            2 => 4,
            3 => 9,
            _ => 0,
        };

        assert_eq!(directional_neighbor_by_recency(&panes, 1, 1, 0, active_at), Some(3));
    }

    #[test]
    fn directional_focus_by_recency_requires_a_shared_edge() {
        let panes = vec![(1, r(10, 0, 10, 10)), (2, r(0, 0, 5, 10))];

        assert_eq!(directional_neighbor_by_recency(&panes, 1, -1, 0, |_| 1), None);
    }

    #[test]
    fn directional_focus_by_recency_excludes_zero_overlap_at_shared_axis() {
        let panes = vec![(1, r(0, 0, 40, 10)), (2, r(40, 0, 40, 10)), (3, r(40, 10, 40, 20))];
        let recency = |pane| if pane == 3 { 9 } else { 4 };

        assert_eq!(directional_neighbor_by_recency(&panes, 1, 1, 0, recency), Some(2));
    }

    #[test]
    fn directional_focus_by_recency_preserves_layout_order_on_a_tie() {
        let panes = vec![(1, r(0, 0, 40, 30)), (2, r(40, 0, 40, 18)), (3, r(40, 18, 40, 12))];

        assert_eq!(directional_neighbor_by_recency(&panes, 1, 1, 0, |_| 7), Some(2));
    }

    #[test]
    fn directional_focus_equal_overlap_nearest_wins() {
        let panes = vec![(1, r(10, 0, 10, 10)), (2, r(0, 0, 5, 10)), (3, r(2, 0, 5, 10))];
        assert_eq!(dir(&panes, 1, -1, 0), Some(3));
    }

    #[test]
    fn directional_focus_zero_overlap_excluded() {
        let panes = vec![(1, r(0, 0, 10, 10)), (2, r(10, 10, 10, 5))];
        assert_eq!(dir(&panes, 1, 1, 0), None);
    }

    #[test]
    fn directional_focus_edge_half_plane_noops() {
        let panes = vec![(1, r(0, 0, 10, 10)), (2, r(2, 0, 3, 10))];
        assert_eq!(dir(&panes, 1, 1, 0), None);
        assert_eq!(dir(&panes, 1, -1, 0), None);
    }

    #[test]
    fn directional_focus_up_down_symmetry() {
        let panes = vec![(1, r(0, 10, 10, 10)), (2, r(0, 0, 10, 10)), (3, r(0, 20, 10, 10))];
        assert_eq!(dir(&panes, 1, 0, -1), Some(2));
        assert_eq!(dir(&panes, 1, 0, 1), Some(3));
    }

    #[test]
    fn directional_focus_single_pane_noop() {
        let panes = vec![(1, r(0, 0, 10, 10))];
        assert_eq!(dir(&panes, 1, 1, 0), None);
        assert_eq!(dir(&panes, 1, 0, 1), None);
    }

    #[test]
    fn directional_focus_nested_grid_greatest_overlap_wins_over_nearest() {
        let panes = vec![(1, r(0, 0, 30, 30)), (2, r(30, 0, 5, 8)), (3, r(40, 0, 10, 30))];
        assert_eq!(dir(&panes, 1, 1, 0), Some(3));
    }

    #[test]
    fn directional_focus_round_trip_left_right_when_geometry_allows() {
        let panes = vec![(1, r(0, 0, 30, 20)), (2, r(30, 0, 30, 20))];
        assert_eq!(dir(&panes, 1, 1, 0), Some(2));
        assert_eq!(dir(&panes, 2, -1, 0), Some(1));
    }

    #[test]
    fn directional_focus_round_trip_up_down_when_geometry_allows() {
        let panes = vec![(1, r(0, 0, 30, 10)), (2, r(0, 10, 30, 10))];
        assert_eq!(dir(&panes, 1, 0, 1), Some(2));
        assert_eq!(dir(&panes, 2, 0, -1), Some(1));
    }

    #[test]
    fn directional_focus_touching_edges_are_candidates() {
        let panes = vec![(1, r(0, 0, 10, 10)), (2, r(10, 0, 10, 10))];
        assert_eq!(dir(&panes, 1, 1, 0), Some(2));
    }

    #[test]
    fn directional_focus_ignores_zero_size_panes() {
        let panes = vec![(1, r(0, 0, 10, 10)), (2, r(10, 0, 0, 10)), (3, r(12, 0, 10, 10))];
        assert_eq!(dir(&panes, 1, 1, 0), Some(3));
    }
}
