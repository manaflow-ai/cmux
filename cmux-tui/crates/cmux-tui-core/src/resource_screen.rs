//! One public screen representation for snapshots, event deltas and journal
//! restatements.
//!
//! The session snapshot, the topology and effect projections behind
//! `session.events`, and registry-side journal batches (such as the startup
//! repair) all build screen values here from durable registry rows, so an
//! event-feed client that applies a screen upsert holds exactly what a fresh
//! snapshot would show (projection convergence).
use std::collections::HashMap;

use serde_json::{Value, json};

use crate::resource::PanePublicId;
use crate::workspace_registry::{
    RegistryLayoutNode, RegistryPane, RegistryScreen, RegistryTab, RegistryViewport,
    ResourceTopologySnapshot,
};

/// The public value of one live screen: identity, order, focus and layout.
pub(crate) fn public_screen_value(
    topology: &ResourceTopologySnapshot,
    screen: &RegistryScreen,
    tabs_by_pane: &HashMap<&PanePublicId, Vec<&RegistryTab>>,
    panes_by_id: &HashMap<&PanePublicId, &RegistryPane>,
) -> anyhow::Result<Value> {
    let focused = topology.active_workspace.as_ref() == Some(&screen.workspace_id)
        && topology.active_screens.iter().any(|(workspace, active)| {
            workspace == &screen.workspace_id && active.as_ref() == Some(&screen.public_id)
        });
    screen_value(screen, focused, tabs_by_pane, panes_by_id)
}

/// The one builder of a published screen value. Every path that publishes a
/// screen (snapshot, event deltas, journal restatements) calls it, so an event
/// upsert and a snapshot at the same revision are equal.
pub(crate) fn screen_value(
    screen: &RegistryScreen,
    focused: bool,
    tabs_by_pane: &HashMap<&PanePublicId, Vec<&RegistryTab>>,
    panes_by_id: &HashMap<&PanePublicId, &RegistryPane>,
) -> anyhow::Result<Value> {
    let index = u32::try_from(screen.position)
        .map_err(|_| anyhow::anyhow!("resource index exceeds uint32"))?;
    Ok(json!({
        "id": screen.public_id,
        "workspace_id": screen.workspace_id,
        "name": screen.name,
        "index": index,
        "focused": focused,
        "layout": public_layout_document(screen, tabs_by_pane, panes_by_id)?,
    }))
}

pub(crate) fn panes_by_id(panes: &[RegistryPane]) -> HashMap<&PanePublicId, &RegistryPane> {
    panes.iter().map(|pane| (&pane.public_id, pane)).collect()
}

pub(crate) fn tabs_by_pane(tabs: &[RegistryTab]) -> HashMap<&PanePublicId, Vec<&RegistryTab>> {
    let mut by_pane = HashMap::<_, Vec<_>>::new();
    for tab in tabs {
        by_pane.entry(&tab.pane_id).or_default().push(tab);
    }
    for pane_tabs in by_pane.values_mut() {
        pane_tabs.sort_by_key(|tab| tab.position);
    }
    by_pane
}

pub(crate) fn public_layout_document(
    screen: &RegistryScreen,
    tabs_by_pane: &HashMap<&PanePublicId, Vec<&RegistryTab>>,
    panes_by_id: &HashMap<&PanePublicId, &RegistryPane>,
) -> anyhow::Result<Value> {
    let root = if screen.viewport.columns.is_empty() {
        public_layout_node(&screen.layout, tabs_by_pane, panes_by_id)?
    } else {
        public_viewport_node(&screen.viewport, tabs_by_pane, panes_by_id)?
    };
    Ok(json!({
        "version": 1,
        "screen_id": screen.public_id,
        "active_pane_id": screen.active_pane,
        "zoomed_pane_id": screen.zoomed_pane,
        "root": root,
    }))
}

fn public_viewport_node(
    viewport: &RegistryViewport,
    tabs_by_pane: &HashMap<&PanePublicId, Vec<&RegistryTab>>,
    panes_by_id: &HashMap<&PanePublicId, &RegistryPane>,
) -> anyhow::Result<Value> {
    let base_width =
        viewport.base_width.ok_or_else(|| anyhow::anyhow!("viewport has no base width"))?;
    anyhow::ensure!(base_width.is_finite(), "viewport base width is not finite");
    let columns = viewport
        .columns
        .iter()
        .map(|column| {
            anyhow::ensure!(column.width.is_finite(), "viewport column width is not finite");
            Ok(json!({
                "column_id": column.id,
                "width": f64::from(column.width),
                "root": public_layout_node(&column.layout, tabs_by_pane, panes_by_id)?,
            }))
        })
        .collect::<anyhow::Result<Vec<_>>>()?;
    Ok(json!({
        "kind": "viewport",
        "base_width": f64::from(base_width),
        "columns": columns,
    }))
}

fn public_layout_node(
    node: &RegistryLayoutNode,
    tabs_by_pane: &HashMap<&PanePublicId, Vec<&RegistryTab>>,
    panes_by_id: &HashMap<&PanePublicId, &RegistryPane>,
) -> anyhow::Result<Value> {
    match node {
        RegistryLayoutNode::Leaf { pane } => {
            let tabs = tabs_by_pane.get(pane).cloned().unwrap_or_default();
            let pane_record = panes_by_id
                .get(pane)
                .ok_or_else(|| anyhow::anyhow!("layout leaf is missing pane"))?;
            let mut leaf = json!({
                "kind": "leaf",
                "pane_id": pane,
                "tab_ids": tabs.iter().map(|tab| &tab.public_id).collect::<Vec<_>>(),
            });
            if let Some(active_tab) = &pane_record.active_tab {
                leaf["active_tab_id"] = json!(active_tab);
            }
            Ok(leaf)
        }
        RegistryLayoutNode::Split { split, direction, ratio, first, second } => {
            anyhow::ensure!(ratio.is_finite(), "layout split ratio is not finite");
            let direction = match direction.as_str() {
                "right" | "horizontal" => "horizontal",
                "down" | "vertical" => "vertical",
                other => anyhow::bail!("unsupported layout split direction {other:?}"),
            };
            Ok(json!({
                "kind": "split",
                "split_id": split,
                "direction": direction,
                "ratio": f64::from(*ratio),
                "first": public_layout_node(first, tabs_by_pane, panes_by_id)?,
                "second": public_layout_node(second, tabs_by_pane, panes_by_id)?,
            }))
        }
        RegistryLayoutNode::Stack { panes, expanded } => Ok(json!({
            "kind": "stack",
            "pane_ids": panes,
            "expanded_pane_id": expanded,
        })),
    }
}
