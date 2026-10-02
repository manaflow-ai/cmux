//! The resource API layout document of a durable screen (the `layout` of a
//! `ScreenSnapshot` and the result of `screen.layout.export`).

use super::*;

pub(super) fn layout_document(
    screen: &RegistryScreen,
    topology: &ResourceTopologySnapshot,
) -> anyhow::Result<Value> {
    let root = if screen.viewport.columns.is_empty() {
        layout_node_value(&screen.layout, topology)?
    } else {
        json!({
            "kind":"viewport",
            "base_width":screen.viewport.base_width.context("viewport has no base width")?,
            "columns":screen.viewport.columns.iter().map(|column| {
                Ok(json!({
                    "column_id":column.id,
                    "width":column.width,
                    "root":layout_node_value(&column.layout, topology)?,
                }))
            }).collect::<anyhow::Result<Vec<_>>>()?,
        })
    };
    Ok(json!({
        "version":1,
        "screen_id":screen.public_id,
        "active_pane_id":screen.active_pane,
        "zoomed_pane_id":screen.zoomed_pane,
        "root":root,
    }))
}

fn layout_node_value(
    node: &RegistryLayoutNode,
    topology: &ResourceTopologySnapshot,
) -> anyhow::Result<Value> {
    Ok(match node {
        RegistryLayoutNode::Leaf { pane } => {
            let record = topology_pane(topology, pane)?;
            let tabs = topology.tabs.iter().filter(|tab| &tab.pane_id == pane).collect::<Vec<_>>();
            let mut value = json!({
                "kind":"leaf",
                "pane_id":pane,
                "tab_ids":tabs.iter().map(|tab| &tab.public_id).collect::<Vec<_>>(),
            });
            if let Some(active) = &record.active_tab {
                value["active_tab_id"] = json!(active);
            }
            value
        }
        RegistryLayoutNode::Split { split, direction, ratio, first, second } => json!({
            "kind":"split",
            "split_id":split,
            "direction":match direction.as_str() {
                "right" | "horizontal" => "horizontal",
                "down" | "vertical" => "vertical",
                other => anyhow::bail!("invalid durable split direction {other:?}"),
            },
            "ratio":ratio,
            "first":layout_node_value(first, topology)?,
            "second":layout_node_value(second, topology)?,
        }),
        RegistryLayoutNode::Stack { panes, expanded } => json!({
            "kind":"stack",
            "pane_ids":panes,
            "expanded_pane_id":expanded,
        }),
    })
}
