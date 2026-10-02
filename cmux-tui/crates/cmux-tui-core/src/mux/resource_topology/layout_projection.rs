//! The compatibility split tree of a layout snapshot whose viewport columns
//! changed, after `sticky-columns-v1` flags are normalized.

use super::*;

pub(super) fn sync_layout_column_projection(layout: &mut ScreenLayoutSnapshot) {
    crate::model::normalize_sticky_columns(&mut layout.layout_columns);
    let Some(first) = layout.layout_columns.first() else {
        layout.viewport_splits.clear();
        layout.viewport_base_width = None;
        return;
    };
    layout.viewport_splits.clear();
    layout.viewport_base_width = Some(first.width);
    layout.zellij_auto_layout = None;
    let mut root = first.root.clone();
    let mut width_before = first.width;
    for column in layout.layout_columns.iter().skip(1) {
        let ratio = width_before / (width_before + column.width);
        root = Node::Split {
            id: column.id,
            dir: SplitDir::Right,
            ratio,
            a: Box::new(root),
            b: Box::new(column.root.clone()),
        };
        layout.viewport_splits.insert(column.id, column.width);
        width_before += column.width;
    }
    layout.root = root;
}
