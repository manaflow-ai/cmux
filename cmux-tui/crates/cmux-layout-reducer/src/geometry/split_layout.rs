//! A split tree's pane frames, dividers and minimums (Swift `SplitGeometry`), the ratios a pointer
//! drag sets (`SplitGeometry.ratio(forPointer:)`), the even ratios a new split or an equalize sets
//! (`EvenSplitRatios`) and an option-drag that pushes the column wider (`PushResize`).

use super::divider_band::DividerBand;
use super::{
    Rect, Size, SplitAxis, ceil_to_pixel, floor_to_pixel, round_to_pixel, swift_max, swift_min,
};
use crate::shown_resize::{fraction, pixel_width};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap, HashSet};

/// `SplitRatio.range`: the ratios the daemon accepts.
pub const SPLIT_RATIO_RANGE: (f64, f64) = (0.05, 0.95);
/// `ColumnWidthPreset.widthRange`.
pub const WIDTH_RANGE: (f64, f64) = (0.1, 1.0);

/// A split tree (Swift `SplitNode`): `{"pane": id}` or `{"split": id, "axis", "ratio", "a", "b"}`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum SplitNode {
    Leaf { pane: String },
    Split { split: String, axis: SplitAxis, ratio: f64, a: Box<SplitNode>, b: Box<SplitNode> },
}

impl SplitNode {
    /// `contains(_:)`.
    pub fn contains(&self, pane: &str) -> bool {
        match self {
            SplitNode::Leaf { pane: leaf } => leaf == pane,
            SplitNode::Split { a, b, .. } => a.contains(pane) || b.contains(pane),
        }
    }

    /// `panes`: the leaves in preorder.
    pub fn panes(&self) -> Vec<String> {
        match self {
            SplitNode::Leaf { pane } => vec![pane.clone()],
            SplitNode::Split { a, b, .. } => {
                let mut panes = a.panes();
                panes.extend(b.panes());
                panes
            }
        }
    }

    /// `splits`: the split ids in preorder.
    pub fn splits(&self) -> Vec<String> {
        match self {
            SplitNode::Leaf { .. } => Vec::new(),
            SplitNode::Split { split, a, b, .. } => {
                let mut splits = vec![split.clone()];
                splits.extend(a.splits());
                splits.extend(b.splits());
                splits
            }
        }
    }

    /// `removing(_:)`: the tree without `pane`, its sibling taking the parent's place; `None` when the
    /// tree was that one leaf.
    pub fn removing(&self, pane: &str) -> Option<SplitNode> {
        match self {
            SplitNode::Leaf { pane: leaf } => (leaf != pane).then(|| self.clone()),
            SplitNode::Split { split, axis, ratio, a, b } => {
                let Some(kept_a) = a.removing(pane) else { return Some((**b).clone()) };
                let Some(kept_b) = b.removing(pane) else { return Some((**a).clone()) };
                Some(SplitNode::Split {
                    split: split.clone(),
                    axis: *axis,
                    ratio: *ratio,
                    a: Box::new(kept_a),
                    b: Box::new(kept_b),
                })
            }
        }
    }

    /// `replacingLeaf(_:with:)`: `pane`'s leaf replaced by `transform` of it.
    pub fn replacing_leaf(
        &self,
        pane: &str,
        transform: &dyn Fn(&SplitNode) -> SplitNode,
    ) -> SplitNode {
        match self {
            SplitNode::Leaf { pane: leaf } if leaf == pane => transform(self),
            SplitNode::Leaf { .. } => self.clone(),
            SplitNode::Split { split, axis, ratio, a, b } => SplitNode::Split {
                split: split.clone(),
                axis: *axis,
                ratio: *ratio,
                a: Box::new(a.replacing_leaf(pane, transform)),
                b: Box::new(b.replacing_leaf(pane, transform)),
            },
        }
    }

    /// `cellCount(along:)`: the cells of this node's same-axis chain; another axis counts as one.
    pub fn cell_count(&self, axis: SplitAxis) -> usize {
        match self {
            SplitNode::Leaf { .. } => 1,
            SplitNode::Split { axis: node_axis, a, b, .. } => {
                if *node_axis == axis {
                    a.cell_count(axis) + b.cell_count(axis)
                } else {
                    1
                }
            }
        }
    }

    /// `settingRatio(_:for:)`: a copy with `id`'s ratio replaced.
    #[must_use]
    pub fn setting_ratio(&self, value: f64, id: &str) -> SplitNode {
        match self {
            SplitNode::Leaf { .. } => self.clone(),
            SplitNode::Split { split, axis, ratio, a, b } => {
                if split == id {
                    return SplitNode::Split {
                        split: split.clone(),
                        axis: *axis,
                        ratio: value,
                        a: a.clone(),
                        b: b.clone(),
                    };
                }
                SplitNode::Split {
                    split: split.clone(),
                    axis: *axis,
                    ratio: *ratio,
                    a: Box::new(a.setting_ratio(value, id)),
                    b: Box::new(b.setting_ratio(value, id)),
                }
            }
        }
    }

    /// `node(for:) != nil`.
    pub fn has_split(&self, id: &str) -> bool {
        match self {
            SplitNode::Leaf { .. } => false,
            SplitNode::Split { split, a, b, .. } => {
                split == id || a.has_split(id) || b.has_split(id)
            }
        }
    }

    /// `horizontalPath(to:)`: the horizontal splits from this node down to `split`, each with whether
    /// the path goes through its leading child; `None` when `split` is not here or is vertical.
    pub fn horizontal_path(&self, target: &str) -> Option<Vec<(String, bool)>> {
        let SplitNode::Split { split, axis, a, b, .. } = self else { return None };
        if split == target {
            return (*axis == SplitAxis::Horizontal).then(|| vec![(split.clone(), true)]);
        }
        for (child, leading) in [(a, true), (b, false)] {
            let Some(rest) = child.horizontal_path(target) else { continue };
            if *axis == SplitAxis::Horizontal {
                let mut path = vec![(split.clone(), leading)];
                path.extend(rest);
                return Some(path);
            }
            return Some(rest);
        }
        None
    }
}

/// The `LayoutStyle` values split geometry reads.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SplitStyle {
    pub divider_thickness: f64,
    pub divider_hit_thickness: f64,
    pub pane_padding: f64,
    pub pane_chrome_height: f64,
    pub minimum_pane_content_size: Size,
}

impl Default for SplitStyle {
    fn default() -> Self {
        Self {
            divider_thickness: 1.,
            divider_hit_thickness: 7.,
            pane_padding: 0.,
            pane_chrome_height: 28.,
            minimum_pane_content_size: Size { width: 200., height: 64. },
        }
    }
}

impl SplitStyle {
    /// `minimumPaneSize`: the minimum content plus the chrome above it and the padding around both.
    pub fn minimum_pane_size(&self) -> Size {
        Size {
            width: self.minimum_pane_content_size.width + self.pane_padding * 2.,
            height: self.pane_chrome_height
                + self.minimum_pane_content_size.height
                + self.pane_padding * 2.,
        }
    }

    /// `effectiveDividerHitThickness`.
    pub fn effective_divider_hit_thickness(&self) -> f64 {
        swift_max(self.divider_hit_thickness, self.pane_padding * 2. + self.divider_thickness)
    }
}

fn extent(size: Size, axis: SplitAxis) -> f64 {
    match axis {
        SplitAxis::Horizontal => size.width,
        SplitAxis::Vertical => size.height,
    }
}

/// One split's divider (Swift `DividerGeometry`).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DividerGeometry {
    pub id: String,
    pub axis: SplitAxis,
    pub frame: Rect,
    pub hit_frame: Rect,
    pub container: Rect,
    #[serde(default)]
    pub minimum_a: f64,
    #[serde(default)]
    pub minimum_b: f64,
}

/// `SplitLayoutResult`: each pane's frame and every divider in tree order.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct SplitLayout {
    pub panes: BTreeMap<String, Rect>,
    pub dividers: Vec<DividerGeometry>,
}

type Minimums = HashMap<String, (Size, Size)>;

/// `SplitGeometry.layout(_:in:style:scale:)`.
pub fn layout(node: &SplitNode, rect: Rect, style: &SplitStyle, scale: f64) -> SplitLayout {
    let mut result = SplitLayout::default();
    let mut minimums = Minimums::new();
    let mut repeated = HashSet::new();
    collect_minimums(node, style, &mut minimums, &mut repeated);
    for id in &repeated {
        minimums.remove(id);
    }
    layout_into(node, rect, style, scale, &minimums, &mut result);
    result
}

fn collect_minimums(
    node: &SplitNode,
    style: &SplitStyle,
    minimums: &mut Minimums,
    repeated: &mut HashSet<String>,
) -> Size {
    match node {
        SplitNode::Leaf { .. } => style.minimum_pane_size(),
        SplitNode::Split { split, axis, a, b, .. } => {
            let first = collect_minimums(a, style, minimums, repeated);
            let second = collect_minimums(b, style, minimums, repeated);
            if minimums.insert(split.clone(), (first, second)).is_some() {
                repeated.insert(split.clone());
            }
            combine(first, second, *axis, style.divider_thickness)
        }
    }
}

fn combine(first: Size, second: Size, axis: SplitAxis, t: f64) -> Size {
    match axis {
        SplitAxis::Horizontal => Size {
            width: first.width + t + second.width,
            height: swift_max(first.height, second.height),
        },
        SplitAxis::Vertical => Size {
            width: swift_max(first.width, second.width),
            height: first.height + t + second.height,
        },
    }
}

fn layout_into(
    node: &SplitNode,
    rect: Rect,
    style: &SplitStyle,
    scale: f64,
    minimums: &Minimums,
    result: &mut SplitLayout,
) {
    match node {
        SplitNode::Leaf { pane } => {
            result.panes.insert(pane.clone(), rect);
        }
        SplitNode::Split { split, axis, ratio, a, b } => {
            let t = style.divider_thickness;
            let horizontal = *axis == SplitAxis::Horizontal;
            let available =
                swift_max(0., if horizontal { rect.width() } else { rect.height() } - t);
            let (child_a, child_b) = minimums
                .get(split)
                .copied()
                .unwrap_or_else(|| (minimum_size(a, style), minimum_size(b, style)));
            let minimum_a = extent(child_a, *axis);
            let minimum_b = extent(child_b, *axis);
            let a_extent = first_extent(*ratio, available, minimum_a, minimum_b, scale);
            let (a_rect, divider, b_rect) = if horizontal {
                let divider = Rect::new(rect.min_x() + a_extent, rect.min_y(), t, rect.height());
                (
                    Rect::new(rect.min_x(), rect.min_y(), a_extent, rect.height()),
                    divider,
                    Rect::new(
                        divider.max_x(),
                        rect.min_y(),
                        swift_max(0., rect.max_x() - divider.max_x()),
                        rect.height(),
                    ),
                )
            } else {
                let divider = Rect::new(rect.min_x(), rect.min_y() + a_extent, rect.width(), t);
                (
                    Rect::new(rect.min_x(), rect.min_y(), rect.width(), a_extent),
                    divider,
                    Rect::new(
                        rect.min_x(),
                        divider.max_y(),
                        rect.width(),
                        swift_max(0., rect.max_y() - divider.max_y()),
                    ),
                )
            };
            let hit = DividerBand::new(
                *axis,
                if horizontal { divider.mid_x() } else { divider.mid_y() },
                t,
                style.effective_divider_hit_thickness(),
                if horizontal { rect.min_y() } else { rect.min_x() },
                if horizontal { rect.height() } else { rect.width() },
                scale,
            )
            .hit;
            result.dividers.push(DividerGeometry {
                id: split.clone(),
                axis: *axis,
                frame: divider,
                hit_frame: hit,
                container: rect,
                minimum_a,
                minimum_b,
            });
            layout_into(a, a_rect, style, scale, minimums, result);
            layout_into(b, b_rect, style, scale, minimums, result);
        }
    }
}

/// `SplitGeometry.minimumSize(of:style:)`: the smallest frame that fits every pane at its minimum.
pub fn minimum_size(node: &SplitNode, style: &SplitStyle) -> Size {
    match node {
        SplitNode::Leaf { .. } => style.minimum_pane_size(),
        SplitNode::Split { axis, a, b, .. } => {
            combine(minimum_size(a, style), minimum_size(b, style), *axis, style.divider_thickness)
        }
    }
}

/// `SplitGeometry.firstExtent`: the first child's extent, on a device pixel, never taking a pixel
/// from either minimum when both fit.
pub fn first_extent(ratio: f64, available: f64, minimum_a: f64, minimum_b: f64, scale: f64) -> f64 {
    let mut value = available * ratio;
    if available >= minimum_a + minimum_b {
        value = swift_min(swift_max(value, minimum_a), available - minimum_b);
        let rounded = round_to_pixel(value, scale);
        if rounded < minimum_a {
            return ceil_to_pixel(minimum_a, scale);
        }
        if available - rounded < minimum_b {
            return floor_to_pixel(available - minimum_b, scale);
        }
        return rounded;
    } else if minimum_a + minimum_b > 0. {
        value = available * minimum_a / (minimum_a + minimum_b);
    }
    round_to_pixel(swift_min(swift_max(0., value), available), scale)
}

/// `SplitGeometry.ratio(forPointer:...)`'s inputs past the pointer.
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct PointerRatio {
    pub grab_offset: f64,
    pub minimum_a: Option<f64>,
    pub minimum_b: Option<f64>,
    pub snaps: Vec<f64>,
    pub snap_distance: f64,
}

/// `SplitGeometry.ratio(forPointer:...)`: the ratio that puts the divider under the pointer, kept
/// off both minimums and snapped to the nearest snap within `snap_distance`.
pub fn ratio_for_pointer(
    pointer: f64,
    container: Rect,
    axis: SplitAxis,
    style: &SplitStyle,
    options: &PointerRatio,
) -> f64 {
    let horizontal = axis == SplitAxis::Horizontal;
    let start = if horizontal { container.min_x() } else { container.min_y() };
    let extent_ = if horizontal { container.width() } else { container.height() };
    let available = extent_ - style.divider_thickness;
    if available <= 0. {
        return 0.5;
    }
    let leaf = extent(style.minimum_pane_size(), axis);
    let min_a = options.minimum_a.unwrap_or(leaf);
    let min_b = options.minimum_b.unwrap_or(leaf);
    let mut a_extent = pointer - options.grab_offset - start;
    if available >= min_a + min_b {
        a_extent = swift_min(swift_max(a_extent, min_a), available - min_b);
    }
    let mut snap: Option<(f64, f64)> = None;
    for &ratio in &options.snaps {
        let at = ratio * available;
        if (at - a_extent).abs() <= options.snap_distance
            && at >= min_a
            && available - at >= min_b
            && snap.is_none_or(|(_, best)| (at - a_extent).abs() < (best - a_extent).abs())
        {
            snap = Some((ratio, at));
        }
    }
    let ratio = snap.map_or(a_extent / available, |(ratio, _)| ratio);
    swift_min(swift_max(ratio, SPLIT_RATIO_RANGE.0), SPLIT_RATIO_RANGE.1)
}

/// `SplitRatioChange`.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct SplitRatioChange {
    pub split: String,
    pub ratio: f64,
}

/// `EvenSplitRatios.changes(splitting:axis:in:)`: the ratios that make every cell of `pane`'s
/// same-axis chain equal once `pane` splits in two along `axis`.
pub fn even_ratios_splitting(
    pane: &str,
    axis: SplitAxis,
    root: &SplitNode,
) -> Vec<SplitRatioChange> {
    let Some(top) = chain_top(pane, axis, root) else { return vec![] };
    let mut result = vec![];
    collect_even(top, Some(pane), axis, &mut result);
    result
}

/// `EvenSplitRatios.changes(equalizing:axis:)`: the ratios that make every cell of `top`'s chain
/// equal.
pub fn even_ratios_equalizing(top: &SplitNode, axis: SplitAxis) -> Vec<SplitRatioChange> {
    let mut result = vec![];
    collect_even(top, None, axis, &mut result);
    result
}

/// `equalize` (no pane) and `collect` (the pane adds a cell to the side holding it) in one walk.
fn collect_even(
    node: &SplitNode,
    pane: Option<&str>,
    axis: SplitAxis,
    result: &mut Vec<SplitRatioChange>,
) {
    let SplitNode::Split { split, axis: node_axis, ratio, a, b } = node else { return };
    if *node_axis != axis {
        return;
    }
    let weight = |child: &SplitNode| {
        (child.cell_count(axis) + usize::from(pane.is_some_and(|pane| child.contains(pane)))) as f64
    };
    let (wa, wb) = (weight(a), weight(b));
    let even = wa / (wa + wb);
    if (even - ratio).abs() > 1e-6 {
        result.push(SplitRatioChange { split: split.clone(), ratio: even });
    }
    collect_even(a, pane, axis, result);
    collect_even(b, pane, axis, result);
}

fn chain_top<'a>(pane: &str, axis: SplitAxis, root: &'a SplitNode) -> Option<&'a SplitNode> {
    let mut path = vec![];
    if !ancestors(pane, root, &mut path) {
        return None;
    }
    let mut top = None;
    for node in path.into_iter().rev() {
        let SplitNode::Split { axis: node_axis, .. } = node else { break };
        if *node_axis != axis {
            break;
        }
        top = Some(node);
    }
    top
}

fn ancestors<'a>(pane: &str, node: &'a SplitNode, path: &mut Vec<&'a SplitNode>) -> bool {
    let SplitNode::Split { a, b, .. } = node else { return false };
    path.push(node);
    let is_leaf =
        |child: &SplitNode| matches!(child, SplitNode::Leaf { pane: leaf } if leaf == pane);
    if is_leaf(a) || is_leaf(b) {
        return true;
    }
    if ancestors(pane, a, path) || ancestors(pane, b, path) {
        return true;
    }
    path.pop();
    false
}

/// A value a divider drag sets (Swift `DividerDragValue`): a split's ratio or a column's width.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum DividerDragValue {
    Ratio { id: String, value: f64 },
    Width { id: String, value: f64 },
}

/// One horizontal split above the dragged one (`PushResize.Ancestor`).
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PushAncestor {
    pub split: String,
    pub leading: f64,
    pub available: f64,
    pub grows_leading: bool,
}

/// `PushResize`: an option-drag of a split divider that grows the column and only the pane before
/// the divider.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PushResize {
    pub column: String,
    pub column_width: f64,
    pub ancestors: Vec<PushAncestor>,
    pub minimum_delta: f64,
    pub maximum_delta: f64,
    pub viewport: f64,
    pub gap: f64,
}

impl PushResize {
    /// `PushResize.init?(split:column:...)`: `trees` is the column's `trees` and `docked` whether it
    /// has a dock; `None` for a docked column, a vertical divider or a divider with no geometry.
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        split: &str,
        column: &str,
        docked: bool,
        trees: &[SplitNode],
        column_width: f64,
        dividers: &[DividerGeometry],
        viewport: f64,
        gap: f64,
        divider_thickness: f64,
    ) -> Option<Self> {
        if docked {
            return None;
        }
        let tree = trees.iter().find(|tree| tree.has_split(split))?;
        let path = tree.horizontal_path(split)?;
        if path.is_empty() {
            return None;
        }
        // `Dictionary(uniquingKeysWith: first)`: the first divider with an id wins.
        let frame = |id: &str| dividers.iter().find(|divider| divider.id == id);
        let mut ancestors = vec![];
        for (step, grows_leading) in path {
            let divider = frame(&step)?;
            ancestors.push(PushAncestor {
                leading: divider.frame.min_x() - divider.container.min_x(),
                available: swift_max(1., divider.container.width() - divider_thickness),
                split: step,
                grows_leading,
            });
        }
        let dragged = frame(split)?;
        let narrowest = pixel_width(WIDTH_RANGE.0, viewport, gap);
        let widest = pixel_width(WIDTH_RANGE.1, viewport, gap);
        Some(Self {
            column: column.to_string(),
            column_width,
            ancestors,
            minimum_delta: swift_min(
                0.,
                swift_max(
                    dragged.minimum_a - (dragged.frame.min_x() - dragged.container.min_x()),
                    narrowest - column_width,
                ),
            ),
            maximum_delta: swift_max(0., widest - column_width),
            viewport,
            gap,
        })
    }

    /// `targets(delta:)`: the column's new width, then each ancestor's ratio.
    pub fn targets(&self, delta: f64) -> Vec<DividerDragValue> {
        let delta = swift_min(swift_max(delta, self.minimum_delta), self.maximum_delta);
        let width = fraction(self.column_width + delta, self.viewport, self.gap);
        let mut result = vec![DividerDragValue::Width { id: self.column.clone(), value: width }];
        for step in &self.ancestors {
            let leading = step.leading + if step.grows_leading { delta } else { 0. };
            let ratio = leading / (step.available + delta);
            result.push(DividerDragValue::Ratio {
                id: step.split.clone(),
                value: swift_min(swift_max(ratio, SPLIT_RATIO_RANGE.0), SPLIT_RATIO_RANGE.1),
            });
        }
        result
    }
}
