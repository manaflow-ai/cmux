//! The frames of a screen's split tree (Swift `SplitGeometry.layout` in CmuxNextLayout), with the
//! exact tiling check ([`crate::tiling`]) run on every layout it commits.
//!
//! A split gives its first child `ratio` of its extent less the divider, kept so both children
//! keep their minimum size, on the device-pixel grid of `scale`; the divider follows it and the
//! second child takes the rest. The tree is the daemon's wire shape ([`Node`], as the optimistic
//! rules read it): a `right` split puts `a` left of `b`, a `down` split puts `a` above `b`, and a
//! stack shows its expanded pane in its whole rect.
//!
//! Every comparison is the Swift one (`Swift.min`, `Swift.max`, `rounded()` half away from zero),
//! so a layout the solver gives is the app's, edge for edge.

use crate::optimistic::{Dir, Node};
use crate::tiling::{self, Checker, Frame, RectPt};

/// The metrics a split layout reads (Swift `LayoutStyle`: `dividerThickness`, `minimumPaneSize`).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SplitStyle {
    pub divider: f64,
    pub min_width: f64,
    pub min_height: f64,
}

impl Default for SplitStyle {
    /// The app's defaults: a 1 pt divider, a pane of 200 by 64 pt of content under a 28 pt tab strip.
    fn default() -> SplitStyle {
        SplitStyle { divider: 1.0, min_width: 200.0, min_height: 28.0 + 64.0 }
    }
}

/// The frames of one layout: each pane's, in tree order, and each divider's, in split order.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct SplitLayout {
    pub panes: Vec<(u64, RectPt)>,
    pub dividers: Vec<RectPt>,
}

/// The smallest size (width, height) of a split's first and second child.
type Minimums = ((f64, f64), (f64, f64));

fn swift_min(x: f64, y: f64) -> f64 {
    if y < x { y } else { x }
}

fn swift_max(x: f64, y: f64) -> f64 {
    if y >= x { y } else { x }
}

/// `SplitGeometry.roundToPixel`.
pub fn round_to_pixel(value: f64, scale: f64) -> f64 {
    if scale <= 0.0 { value } else { (value * scale).round() / scale }
}

fn ceil_to_pixel(value: f64, scale: f64) -> f64 {
    if scale <= 0.0 { value } else { (value * scale - 0.001).ceil() / scale }
}

fn floor_to_pixel(value: f64, scale: f64) -> f64 {
    if scale <= 0.0 { value } else { (value * scale + 0.001).floor() / scale }
}

/// The divider a split of `extent` shows: `thickness` on whole device pixels (at least one when it
/// is not 0), and never more than the split's own extent.
///
/// The token is in points, and at a scale such as 1.5 one point is 1.5 device pixels: the divider's
/// far edge, and every pane after it, sat half a pixel off the grid (F2), and the screen's
/// placement (`pixel_edges`) then showed it 1 or 2 pixels wide by where it fell. A split smaller
/// than its divider (a tree deeper than its window) drew the divider past its own rect, over its
/// neighbours and out of the viewport.
pub fn divider_thickness(thickness: f64, extent: f64, scale: f64) -> f64 {
    if thickness.is_nan() || thickness <= 0.0 {
        return 0.0;
    }
    let on_grid =
        if scale > 0.0 { swift_max(1.0, (thickness * scale).round()) / scale } else { thickness };
    swift_min(on_grid, swift_max(0.0, extent))
}

/// `SplitGeometry.firstExtent`: the extent of child `a`, `ratio` of `available` kept inside both
/// minimums and on the pixel grid; when both minimums do not fit, the room is shared in proportion
/// to them.
pub fn first_extent(ratio: f64, available: f64, min_a: f64, min_b: f64, scale: f64) -> f64 {
    let mut value = available * ratio;
    if available >= min_a + min_b {
        value = swift_min(swift_max(value, min_a), available - min_b);
        let rounded = round_to_pixel(value, scale);
        if rounded < min_a {
            return ceil_to_pixel(min_a, scale);
        }
        if available - rounded < min_b {
            return floor_to_pixel(available - min_b, scale);
        }
        return rounded;
    } else if min_a + min_b > 0.0 {
        value = available * min_a / (min_a + min_b);
    }
    round_to_pixel(swift_min(swift_max(0.0, value), available), scale)
}

/// The smallest size of each split's children, in pre-order, and the node's own.
fn minimums(node: &Node, style: &SplitStyle, out: &mut Vec<Minimums>) -> (f64, f64) {
    match node {
        Node::Leaf { .. } | Node::Stack { .. } => (style.min_width, style.min_height),
        Node::Unknown => (0.0, 0.0),
        Node::Split { dir, a, b, .. } => {
            let index = out.len();
            out.push(((0.0, 0.0), (0.0, 0.0)));
            let first = minimums(a, style, out);
            let second = minimums(b, style, out);
            if let Some(slot) = out.get_mut(index) {
                *slot = (first, second);
            }
            let t = style.divider;
            match dir {
                Dir::Right => (first.0 + t + second.0, swift_max(first.1, second.1)),
                Dir::Down => (swift_max(first.0, second.0), first.1 + t + second.1),
            }
        }
    }
}

/// The split solver with its buffers and its tiling check, reused from layout to layout.
#[derive(Clone, Debug, Default)]
pub struct SplitSolver {
    minimums: Vec<Minimums>,
    layout: SplitLayout,
    tiled: Vec<RectPt>,
    checker: Checker,
}

impl SplitSolver {
    pub fn new() -> SplitSolver {
        SplitSolver::default()
    }

    /// The frames of `node` filling a `width` by `height` pt viewport at `scale`, without the check.
    pub fn layout(
        &mut self,
        node: &Node,
        width: f64,
        height: f64,
        style: &SplitStyle,
        scale: f64,
    ) -> &SplitLayout {
        self.minimums.clear();
        self.layout.panes.clear();
        self.layout.dividers.clear();
        minimums(node, style, &mut self.minimums);
        let mut next = 0;
        place(
            node,
            RectPt::new(0.0, 0.0, width, height),
            style,
            scale,
            &self.minimums,
            &mut next,
            &mut self.layout,
        );
        &self.layout
    }

    /// The frames of `node` as [`SplitSolver::layout`] gives them, committed: the tiling check runs
    /// on them ([`tiling::commit`]: loud in a debug build, counted in a release build).
    pub fn solve(
        &mut self,
        node: &Node,
        width: f64,
        height: f64,
        style: &SplitStyle,
        scale: f64,
    ) -> &SplitLayout {
        self.layout(node, width, height, style, scale);
        self.tiled.clear();
        self.tiled.extend(self.layout.panes.iter().map(|(_, rect)| *rect));
        self.tiled.extend(self.layout.dividers.iter().copied());
        let frame = Frame { width, height, scale, tiled: &self.tiled, floating: &[] };
        let _ = tiling::commit(&mut self.checker, &frame);
        &self.layout
    }
}

fn place(
    node: &Node,
    rect: RectPt,
    style: &SplitStyle,
    scale: f64,
    minimums: &[Minimums],
    next: &mut usize,
    out: &mut SplitLayout,
) {
    match node {
        Node::Leaf { pane } => out.panes.push((*pane, rect)),
        Node::Stack { expanded, .. } => out.panes.push((*expanded, rect)),
        Node::Unknown => {}
        Node::Split { dir, ratio, a, b, .. } => {
            let index = *next;
            *next += 1;
            let (min_a, min_b) = minimums.get(index).copied().unwrap_or_default();
            let horizontal = *dir == Dir::Right;
            let extent = if horizontal { rect.w } else { rect.h };
            let t = divider_thickness(style.divider, extent, scale);
            let available = swift_max(0.0, extent - t);
            let (min_a, min_b) = if horizontal { (min_a.0, min_b.0) } else { (min_a.1, min_b.1) };
            let a_extent = first_extent(*ratio, available, min_a, min_b, scale);
            let (a_rect, divider, b_rect) = if horizontal {
                let divider = RectPt::new(rect.x + a_extent, rect.y, t, rect.h);
                let b_x = divider.x + divider.w;
                (
                    RectPt::new(rect.x, rect.y, a_extent, rect.h),
                    divider,
                    RectPt::new(b_x, rect.y, swift_max(0.0, rect.x + rect.w - b_x), rect.h),
                )
            } else {
                let divider = RectPt::new(rect.x, rect.y + a_extent, rect.w, t);
                let b_y = divider.y + divider.h;
                (
                    RectPt::new(rect.x, rect.y, rect.w, a_extent),
                    divider,
                    RectPt::new(rect.x, b_y, rect.w, swift_max(0.0, rect.y + rect.h - b_y)),
                )
            };
            out.dividers.push(divider);
            place(a, a_rect, style, scale, minimums, next, out);
            place(b, b_rect, style, scale, minimums, next, out);
        }
    }
}
