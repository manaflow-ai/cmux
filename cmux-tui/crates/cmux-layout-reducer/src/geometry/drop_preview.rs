//! The layout a pane-edge drop produces (Swift `DropPreviewLayout`) and the even ratios a close sends
//! (`CloseSizing.splitChanges(closing:)`), so the preview and the ratios the drop sends come from one
//! prediction.

use super::SplitAxis;
use super::drop_zones::PaneDropZone;
use super::screen::ScreenLayout;
use super::split_layout::{
    SPLIT_RATIO_RANGE, SplitNode, SplitRatioChange, even_ratios_equalizing, even_ratios_splitting,
};
use super::{swift_max, swift_min};
use serde::Serialize;
use std::collections::BTreeSet;

/// `DropPreviewLayout.newPane`: the placeholder id of the pane the drop creates.
pub const NEW_PANE: &str = "__drop-preview-pane";
/// `DropPreviewLayout.newSplit`.
pub const NEW_SPLIT: &str = "__drop-preview-split";

/// `DropPreviewLayout`: the layout after the drop and the ratio intents it sends once its move
/// landed.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DropPreview {
    pub layout: ScreenLayout,
    pub ratio_changes: Vec<SplitRatioChange>,
}

/// `DropPreviewLayout.init?(splitting:zone:in:removing:evenSizing:equalizesClose:)`: `pane` splits
/// along `zone`'s axis at 0.5 with the new pane on the zone's side, after the pane the drag empties
/// (`removing`) leaves; with `even_sizing`, the close sizing (unless `equalizes_close` is false) and
/// then the split's own even sizing, which wins. None for the center zone, a pane not on this screen
/// or a column with rows.
pub fn drop_preview(
    pane: &str,
    zone: PaneDropZone,
    layout: &ScreenLayout,
    removing: Option<&str>,
    even_sizing: bool,
    equalizes_close: bool,
) -> Option<DropPreview> {
    let axis = zone.split_axis()?;
    let first = matches!(zone, PaneDropZone::Left | PaneDropZone::Top);
    let removing = removing.filter(|removing| *removing != pane);
    let mut split_changes: Vec<SplitRatioChange> = vec![];
    let mut split = |root: &SplitNode| -> SplitNode {
        let tree =
            removing.and_then(|removing| root.removing(removing)).unwrap_or_else(|| root.clone());
        if even_sizing {
            split_changes = even_ratios_splitting(pane, axis, &tree);
        }
        tree.replacing_leaf(pane, &|leaf| {
            let new = SplitNode::Leaf { pane: NEW_PANE.to_owned() };
            let (a, b) = if first { (new, leaf.clone()) } else { (leaf.clone(), new) };
            SplitNode::Split {
                split: NEW_SPLIT.to_owned(),
                axis,
                ratio: 0.5,
                a: Box::new(a),
                b: Box::new(b),
            }
        })
    };
    let moved = match layout {
        ScreenLayout::Splits(root) => {
            if !root.contains(pane) {
                return None;
            }
            ScreenLayout::Splits(split(root))
        }
        ScreenLayout::Columns(columns) => {
            if !columns.iter().any(|column| column.root.contains(pane)) {
                return None;
            }
            let mut result = vec![];
            for column in columns {
                let holds_target = column.root.contains(pane);
                let holds_source = removing.is_some_and(|removing| column.root.contains(removing));
                if !holds_target && !holds_source {
                    result.push(column.clone());
                    continue;
                }
                // A row's tree is not the column's root: the daemon splits inside the row.
                if column.has_rows() {
                    return None;
                }
                let mut column = column.clone();
                if holds_target {
                    column.root = split(&column.root);
                } else if let Some(removing) = removing {
                    // The emptied column closes.
                    let Some(rest) = column.root.removing(removing) else { continue };
                    column.root = rest;
                }
                result.push(column);
            }
            ScreenLayout::Columns(result)
        }
    };
    let close_changes = match removing {
        Some(removing) if even_sizing && equalizes_close => {
            close_split_changes(layout, &moved, removing)
        }
        _ => vec![],
    };
    // One change per split, the split's own sizing last (it wins), clamped as the model clamps.
    let mut changes: Vec<SplitRatioChange> = vec![];
    for change in close_changes.into_iter().chain(split_changes) {
        if change.split == NEW_SPLIT {
            continue;
        }
        let ratio = swift_min(swift_max(change.ratio, SPLIT_RATIO_RANGE.0), SPLIT_RATIO_RANGE.1);
        changes.retain(|kept| kept.split != change.split);
        changes.push(SplitRatioChange { split: change.split, ratio });
    }
    let layout = changes
        .iter()
        .fold(moved, |layout, change| layout.setting_ratio(change.ratio, &change.split));
    Some(DropPreview { layout, ratio_changes: changes })
}

/// `CloseSizing(old:new:).splitChanges(closing:)`: the even ratios of the same-axis run the closed
/// pane's sibling joins, read on the tree that arrives without it.
pub fn close_split_changes(
    old: &ScreenLayout,
    new: &ScreenLayout,
    pane: &str,
) -> Vec<SplitRatioChange> {
    let Some(old_tree) = tree_holding(old, pane) else { return vec![] };
    let Some((axis, sibling)) = parent(pane, old_tree) else { return vec![] };
    let Some(neighbor) = sibling.panes().into_iter().next() else { return vec![] };
    let Some(new_tree) = tree_holding(new, &neighbor) else { return vec![] };
    let kept: BTreeSet<String> = sibling.panes().into_iter().collect();
    let mut path = vec![];
    let Some(place) = node_with_panes(new_tree, &kept, &mut path) else { return vec![] };
    // The highest node of the same-axis run directly above the sibling's place, else the place itself.
    let mut top = (split_axis(place) == Some(axis)).then_some(place);
    for node in path.into_iter().rev() {
        if split_axis(node) != Some(axis) {
            break;
        }
        top = Some(node);
    }
    top.map(|top| even_ratios_equalizing(top, axis)).unwrap_or_default()
}

/// `CloseSizing.tree(in:holding:)`.
fn tree_holding<'a>(layout: &'a ScreenLayout, pane: &str) -> Option<&'a SplitNode> {
    match layout {
        ScreenLayout::Splits(root) => root.contains(pane).then_some(root),
        ScreenLayout::Columns(_) => layout.column_containing(pane)?.tree_containing(pane),
    }
}

fn split_axis(node: &SplitNode) -> Option<SplitAxis> {
    match node {
        SplitNode::Split { axis, .. } => Some(*axis),
        SplitNode::Leaf { .. } => None,
    }
}

fn is_leaf(node: &SplitNode, pane: &str) -> bool {
    matches!(node, SplitNode::Leaf { pane: leaf } if leaf == pane)
}

/// `CloseSizing.parent(of:in:)`: the axis of `pane`'s parent split and `pane`'s sibling.
pub fn parent<'a>(pane: &str, node: &'a SplitNode) -> Option<(SplitAxis, &'a SplitNode)> {
    let SplitNode::Split { axis, a, b, .. } = node else { return None };
    if is_leaf(a, pane) {
        return Some((*axis, b));
    }
    if is_leaf(b, pane) {
        return Some((*axis, a));
    }
    parent(pane, a).or_else(|| parent(pane, b))
}

/// `CloseSizing.node(in:panes:path:)`: the first node (preorder) holding exactly `panes`, with the
/// splits above it in `path`.
fn node_with_panes<'a>(
    node: &'a SplitNode,
    panes: &BTreeSet<String>,
    path: &mut Vec<&'a SplitNode>,
) -> Option<&'a SplitNode> {
    if node.panes().into_iter().collect::<BTreeSet<_>>() == *panes {
        return Some(node);
    }
    let SplitNode::Split { a, b, .. } = node else { return None };
    path.push(node);
    if let Some(found) = node_with_panes(a, panes, path).or_else(|| node_with_panes(b, panes, path))
    {
        return Some(found);
    }
    path.pop();
    None
}
