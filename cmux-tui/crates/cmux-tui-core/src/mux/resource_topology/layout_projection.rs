//! The compatibility split tree of a layout snapshot whose viewport columns
//! changed, after the row and `sticky-columns-v1` invariants are restored
//! ([`crate::model::project_layout_columns`]), and pane removal from such a
//! snapshot.

use super::*;
use crate::model::ColumnProjection;

pub(super) fn sync_layout_column_projection(layout: &mut ScreenLayoutSnapshot) {
    match crate::model::project_layout_columns(&mut layout.layout_columns) {
        ColumnProjection::Unchanged => {
            layout.viewport_splits.clear();
            layout.viewport_base_width = None;
        }
        ColumnProjection::Tree { root, zellij_auto_layout } => {
            layout.root = root;
            layout.zellij_auto_layout = zellij_auto_layout;
            layout.viewport_splits.clear();
            layout.viewport_base_width = None;
        }
        ColumnProjection::Columns { root, viewport_splits, base_width } => {
            layout.root = root;
            layout.viewport_splits = viewport_splits;
            layout.viewport_base_width = Some(base_width);
            layout.zellij_auto_layout = None;
        }
    }
}

/// Removes `pane` from `layout`. An emptied row or column goes in the same
/// step, and a screen left with one column without rows becomes a split
/// tree. False when the screen has no pane left.
pub(super) fn remove_pane_from_layout(layout: &mut ScreenLayoutSnapshot, pane: PaneId) -> bool {
    layout.zellij_auto_layout = None;
    if layout.layout_columns.is_empty() {
        let root = std::mem::replace(&mut layout.root, Node::Leaf(0));
        let Some(root) = root.remove_leaf(pane) else {
            return false;
        };
        layout.root = root;
        return true;
    }
    let Some(index) = layout.layout_columns.iter().position(|column| column.root.contains(pane))
    else {
        return true;
    };
    let column = &mut layout.layout_columns[index];
    column.zellij_auto_layout = None;
    let root = std::mem::replace(&mut column.root, Node::Leaf(0));
    if let Some(root) = root.remove_leaf(pane) {
        column.root = root;
    } else {
        layout.layout_columns.remove(index);
    }
    if layout.layout_columns.is_empty() {
        return false;
    }
    sync_layout_column_projection(layout);
    true
}
