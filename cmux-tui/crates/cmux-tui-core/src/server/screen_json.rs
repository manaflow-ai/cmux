//! One screen of the tree JSON, including its viewport columns, their
//! `dock-columns-v1` flags and their `rows-v1` rows.

use super::*;
use crate::panic_free::JsonFields;

pub(super) fn screen_json(
    state: &State,
    screen: &Screen,
    active: bool,
    group: Option<&str>,
    short_ids: &HashMap<u64, String>,
    notifications: &TreeDecorations,
) -> Value {
    let mut pane_ids = Vec::new();
    screen.root.pane_ids(&mut pane_ids);
    let presentation = notifications.presentation.screens.screen(screen.public_id.as_str());
    let mut value = json!({
        "id": screen.id,
        "resource_id": screen.public_id,
        "short_id": short_ids.get(&screen.id).cloned().unwrap_or_default(),
        "name": screen.name,
        "color": presentation.and_then(|presentation| presentation.color.as_deref()),
        "icon": presentation.and_then(|presentation| presentation.icon.as_deref()),
        "pinned": presentation.is_some_and(|presentation| presentation.pinned),
        "group": group,
        "active": active,
        "panes": pane_ids.iter().map(|id| pane_json(state, *id, short_ids, notifications)).collect::<Vec<_>>(),
    });
    if let (Value::Object(value), Value::Object(layout)) =
        (&mut value, screen_layout_json(screen, &state.resource_indexes.split_ids))
    {
        value.extend(layout);
    }
    value
}

/// The layout fields of one `Screen` (`active_pane`, `zoomed_pane`,
/// `layout`, `viewport_splits`, `viewport_base_width`, `columns`): what a
/// `layout-delta-v1` `layout-changed` carries. O(the screen's split tree):
/// no panes, tabs or tree decorations.
pub(crate) fn screen_layout_json(
    screen: &Screen,
    split_ids: &HashMap<SplitId, crate::resource::SplitPublicId>,
) -> Value {
    let mut value = json!({
        "active_pane": screen.active_pane,
        "zoomed_pane": screen.zoomed_pane,
        "layout": node_json(&screen.root, screen.active_pane, split_ids),
    });
    if !screen.viewport_splits.is_empty() {
        value.insert(
            "viewport_splits",
            json!(
                screen
                    .viewport_splits
                    .iter()
                    .map(|(split, width)| json!({"split": split, "width": width}))
                    .collect::<Vec<_>>()
            ),
        );
        if let Some(width) = screen.viewport_base_width {
            value.insert("viewport_base_width", json!(width));
        }
    }
    if screen.layout_columns_active() {
        value.insert(
            "columns",
            json!(
                screen
                    .layout_columns
                    .iter()
                    .map(|column| {
                        let mut value = json!({
                            "id": column.id,
                            "width": column.width,
                            "layout": node_json(&column.root, screen.active_pane, split_ids),
                        });
                        // `dock-columns-v1`: every edge (top and bottom need
                        // `edge-docks-v1` too) as one optional `dock`.
                        if let Some(dock) = column.dock {
                            value.insert("dock", json!(dock));
                        }
                        // `rows-v1`: only for a column with two or more rows; its
                        // `layout` above is their compat chain.
                        let rows = column.row_trees();
                        if !rows.is_empty() {
                            value.insert(
                                "rows",
                                json!(
                            rows.iter()
                                .map(|(row, tree)| json!({
                                    "id": row.id,
                                    "height": row.height,
                                    "layout": node_json(tree, screen.active_pane, split_ids),
                                }))
                                .collect::<Vec<_>>()
                        ),
                            );
                        }
                        value
                    })
                    .collect::<Vec<_>>()
            ),
        );
    }
    value
}
