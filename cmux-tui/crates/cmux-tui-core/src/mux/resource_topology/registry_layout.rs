//! Registry layout conversion: registry screens and layout nodes from live layouts, split ratio and pane swap edits, and layout snapshots.

use super::*;

pub(super) fn registry_screen_from_layout(
    state: &State,
    workspace_index: usize,
    screen_index: usize,
    layout: &ScreenLayoutSnapshot,
    topology: &ResourceTopologySnapshot,
    name: Option<String>,
) -> anyhow::Result<RegistryScreen> {
    let workspace = &state.workspaces[workspace_index];
    let screen = &workspace.screens[screen_index];
    let public_pane = |pane: PaneId| {
        state
            .resource_indexes
            .pane_ids
            .get(&pane)
            .cloned()
            .with_context(|| format!("pane {pane} has no public identity"))
    };
    let layout_node = registry_layout_node(state, &layout.root)?;
    let auto_layout = layout
        .creation_order_auto_layout
        .as_ref()
        .map(|panes| {
            panes.iter().map(|pane| public_pane(*pane)).collect::<anyhow::Result<Vec<_>>>()
        })
        .transpose()?;
    let columns = layout
        .layout_columns
        .iter()
        .map(|column| {
            Ok(RegistryViewportColumn {
                id: state
                    .resource_indexes
                    .split_ids
                    .get(&column.id)
                    .cloned()
                    .with_context(|| format!("column {} has no public identity", column.id))?,
                width: column.width,
                layout: registry_layout_node(state, &column.root)?,
                auto_layout: column
                    .creation_order_auto_layout
                    .as_ref()
                    .map(|panes| {
                        panes
                            .iter()
                            .map(|pane| public_pane(*pane))
                            .collect::<anyhow::Result<Vec<_>>>()
                    })
                    .transpose()?,
                dock: column.dock,
                rows: registry_viewport::registry_rows(state, column)?,
            })
        })
        .collect::<anyhow::Result<Vec<_>>>()?;
    let durable = RegistryScreen {
        public_id: screen.public_id.clone(),
        workspace_id: workspace.public_id.clone(),
        position: screen_index,
        name,
        layout: layout_node,
        active_pane: public_pane(layout.active_pane)?,
        zoomed_pane: layout.zoomed_pane.map(public_pane).transpose()?,
        auto_layout,
        viewport: RegistryViewport { base_width: layout.viewport_base_width, columns },
    };
    let expected_panes = topology
        .panes
        .iter()
        .filter(|pane| pane.screen_id == durable.public_id)
        .map(|pane| pane.public_id.clone())
        .collect::<HashSet<_>>();
    crate::workspace_registry::validate_registry_screen_projection(&durable, &expected_panes)?;
    Ok(durable)
}

pub(super) fn registry_layout_node(
    state: &State,
    node: &Node,
) -> anyhow::Result<RegistryLayoutNode> {
    Ok(match node {
        Node::Leaf(pane) => RegistryLayoutNode::Leaf {
            pane: state
                .resource_indexes
                .pane_ids
                .get(pane)
                .cloned()
                .with_context(|| format!("pane {pane} has no public identity"))?,
        },
        Node::Split { id, dir, ratio, a, b } => RegistryLayoutNode::Split {
            split: state
                .resource_indexes
                .split_ids
                .get(id)
                .cloned()
                .with_context(|| format!("split {id} has no public identity"))?,
            direction: match dir {
                SplitDir::Right => "right",
                SplitDir::Down => "down",
            }
            .to_string(),
            ratio: *ratio,
            first: Box::new(registry_layout_node(state, a)?),
            second: Box::new(registry_layout_node(state, b)?),
        },
        Node::Stack { panes, expanded } => RegistryLayoutNode::Stack {
            panes: panes
                .iter()
                .map(|pane| {
                    state
                        .resource_indexes
                        .pane_ids
                        .get(pane)
                        .cloned()
                        .with_context(|| format!("pane {pane} has no public identity"))
                })
                .collect::<anyhow::Result<Vec<_>>>()?,
            expanded: state
                .resource_indexes
                .pane_ids
                .get(expanded)
                .cloned()
                .with_context(|| format!("pane {expanded} has no public identity"))?,
        },
    })
}

pub(super) fn set_layout_split_ratio(
    layout: &mut ScreenLayoutSnapshot,
    split: SplitId,
    ratio: f32,
) -> anyhow::Result<()> {
    if let Some(index) = layout
        .layout_columns
        .iter()
        .position(|column| column.id == split)
        .filter(|index| *index > 0)
    {
        let width_before =
            layout.layout_columns[..index].iter().map(|column| column.width).sum::<f32>();
        let width = width_before * (1.0 - ratio) / ratio;
        anyhow::ensure!(
            width.is_finite()
                && (MIN_VIEWPORT_PANE_WIDTH..=MAX_VIEWPORT_PANE_WIDTH).contains(&width),
            "split ratio implies an invalid viewport width"
        );
        layout.layout_columns[index].width = width;
        sync_layout_column_widths(layout);
        return Ok(());
    }
    let changed = if layout.layout_columns.is_empty() {
        layout.root.set_split_ratio(split, ratio)
    } else {
        let changed = layout
            .layout_columns
            .iter_mut()
            .any(|column| column.root.set_split_ratio(split, ratio));
        if changed {
            layout.root.set_split_ratio(split, ratio);
        }
        changed
    };
    anyhow::ensure!(changed, "unknown split");
    layout.creation_order_auto_layout = None;
    Ok(())
}

pub(super) fn swap_layout_panes(
    layout: &mut ScreenLayoutSnapshot,
    first: PaneId,
    second: PaneId,
    both_present: bool,
) -> anyhow::Result<()> {
    if both_present {
        anyhow::ensure!(
            layout.root.contains(first) && layout.root.contains(second),
            "pane swap targets changed"
        );
    } else {
        anyhow::ensure!(
            layout.root.contains(first) || layout.root.contains(second),
            "pane swap target changed"
        );
    }
    layout.root.swap_leaf_ids(first, second);
    for column in &mut layout.layout_columns {
        if column.root.contains(first) || column.root.contains(second) {
            column.root.swap_leaf_ids(first, second);
            column.creation_order_auto_layout = None;
        }
    }
    if !layout.layout_columns.is_empty() {
        sync_layout_column_projection(layout);
    }
    layout.creation_order_auto_layout = None;
    if !both_present {
        if layout.active_pane == first {
            layout.active_pane = second;
        } else if layout.active_pane == second {
            layout.active_pane = first;
        }
        if layout.zoomed_pane == Some(first) {
            layout.zoomed_pane = Some(second);
        } else if layout.zoomed_pane == Some(second) {
            layout.zoomed_pane = Some(first);
        }
    }
    Ok(())
}

pub(super) fn apply_layout_snapshot(screen: &mut Screen, layout: ScreenLayoutSnapshot) {
    let before = screen.layout_snapshot();
    overwrite_layout_snapshot(screen, layout);
    screen.record_layout_change(before, Vec::new(), None);
}

pub(super) fn overwrite_layout_snapshot(screen: &mut Screen, layout: ScreenLayoutSnapshot) {
    screen.root = layout.root;
    screen.active_pane = layout.active_pane;
    screen.zoomed_pane = layout.zoomed_pane;
    screen.creation_order_auto_layout = layout.creation_order_auto_layout;
    screen.viewport_splits = layout.viewport_splits;
    screen.viewport_base_width = layout.viewport_base_width;
    screen.layout_columns = layout.layout_columns;
}

pub(super) fn sync_layout_column_widths(layout: &mut ScreenLayoutSnapshot) {
    let Some(first) = layout.layout_columns.first() else {
        layout.viewport_splits.clear();
        layout.viewport_base_width = None;
        return;
    };
    layout.viewport_splits.clear();
    layout.viewport_base_width = Some(first.width);
    let mut ratios = std::collections::BTreeMap::new();
    let mut before = first.width;
    for column in layout.layout_columns.iter().skip(1) {
        ratios.insert(column.id, before / (before + column.width));
        layout.viewport_splits.insert(column.id, column.width);
        before += column.width;
    }
    set_node_split_ratios(&mut layout.root, &ratios);
}

pub(super) fn set_node_split_ratios(
    node: &mut Node,
    ratios: &std::collections::BTreeMap<SplitId, f32>,
) {
    match node {
        Node::Leaf(_) | Node::Stack { .. } => {}
        Node::Split { id, ratio, a, b, .. } => {
            if let Some(next) = ratios.get(id) {
                *ratio = *next;
            }
            set_node_split_ratios(a, ratios);
            set_node_split_ratios(b, ratios);
        }
    }
}
