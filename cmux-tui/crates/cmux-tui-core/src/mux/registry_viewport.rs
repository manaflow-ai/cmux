//! Restoring a screen's viewport columns, with their `dock-columns-v1`
//! flags and `rows-v1` rows, from the workspace registry, and the registry
//! form of a column's rows.

use super::*;
use crate::model::LayoutRow;
use crate::workspace_registry::RegistryRow;

pub(super) fn restore_registry_viewport(
    viewport: &RegistryViewport,
    panes: &HashMap<PanePublicId, PaneId>,
    splits: &mut HashMap<SplitPublicId, SplitId>,
    allocate: &mut impl FnMut() -> anyhow::Result<u64>,
) -> anyhow::Result<RestoredViewport> {
    if viewport.columns.is_empty() {
        return Ok((Default::default(), None, Vec::new()));
    }
    let mut columns = Vec::with_capacity(viewport.columns.len());
    for (index, column) in viewport.columns.iter().enumerate() {
        let id = match splits.get(&column.id).copied() {
            Some(id) => id,
            None if index == 0 => {
                let id = allocate()?;
                splits.insert(column.id.clone(), id);
                id
            }
            None => anyhow::bail!("viewport references unknown boundary split {}", column.id),
        };
        let root = restore_layout_node_from_known_splits(&column.layout, panes, splits)?;
        let zellij_auto_layout = column
            .auto_layout
            .as_ref()
            .map(|members| {
                members
                    .iter()
                    .map(|pane| {
                        panes.get(pane).copied().ok_or_else(|| {
                            anyhow::anyhow!("viewport auto-layout has unknown pane {pane}")
                        })
                    })
                    .collect::<anyhow::Result<Vec<_>>>()
            })
            .transpose()?;
        let mut restored = LayoutColumn::new(id, column.width, root, zellij_auto_layout);
        restored.dock = column.dock;
        restored.rows = restore_rows(&column.rows, splits, allocate)?;
        columns.push(restored);
    }
    // Every writer stores normalized flags and rows. The registry does not
    // reject inconsistent flags, so a damaged record still loads; it is
    // repaired here instead of producing a screen with no scrolling column.
    // The rows were checked against the chain at load; normalizing rewrites
    // the chain ratios from the heights.
    let lone = columns.len() == 1;
    crate::model::project_layout_columns(&mut columns);
    anyhow::ensure!(!lone || columns.len() == 1, "a lone viewport column restored without rows");
    let viewport_splits = columns.iter().skip(1).map(|column| (column.id, column.width)).collect();
    Ok((viewport_splits, viewport.base_width, columns))
}

/// Row ids from the registry: row 1's id is in no tree (allocate it when it
/// is new to this restore); rows 2..n are the column chain's splits.
fn restore_rows(
    rows: &[RegistryRow],
    splits: &mut HashMap<SplitPublicId, SplitId>,
    allocate: &mut impl FnMut() -> anyhow::Result<u64>,
) -> anyhow::Result<Vec<LayoutRow>> {
    let mut restored = Vec::with_capacity(rows.len());
    for (index, row) in rows.iter().enumerate() {
        let id = match splits.get(&row.id).copied() {
            Some(id) => id,
            None if index == 0 => {
                let id = allocate()?;
                splits.insert(row.id.clone(), id);
                id
            }
            None => anyhow::bail!("viewport row references unknown chain split {}", row.id),
        };
        restored.push(LayoutRow::new(id, row.height));
    }
    Ok(restored)
}

/// The registry form of a column's rows (empty without rows).
pub(super) fn registry_rows(
    state: &State,
    column: &LayoutColumn,
) -> anyhow::Result<Vec<RegistryRow>> {
    column
        .rows
        .iter()
        .map(|row| {
            let id = state
                .resource_indexes
                .split_ids
                .get(&row.id)
                .cloned()
                .with_context(|| format!("row {} has no public identity", row.id))?;
            Ok(RegistryRow { id, height: row.height })
        })
        .collect()
}

/// A stored split tree with new split slots from `allocate`.
pub(super) fn restore_layout_node(
    node: &RegistryLayoutNode,
    panes: &HashMap<PanePublicId, PaneId>,
    splits: &mut HashMap<SplitPublicId, SplitId>,
    allocate: &mut impl FnMut() -> anyhow::Result<u64>,
) -> anyhow::Result<Node> {
    Ok(match node {
        RegistryLayoutNode::Leaf { pane } => Node::Leaf(
            *panes.get(pane).ok_or_else(|| anyhow::anyhow!("layout has unknown pane {pane}"))?,
        ),
        RegistryLayoutNode::Split { split, direction, ratio, first, second } => {
            anyhow::ensure!(!splits.contains_key(split), "split {split} appears more than once");
            let id = allocate()?;
            splits.insert(split.clone(), id);
            let dir = match direction.as_str() {
                "right" => SplitDir::Right,
                "down" => SplitDir::Down,
                _ => anyhow::bail!("split {split} has invalid direction {direction:?}"),
            };
            Node::Split {
                id,
                dir,
                ratio: *ratio,
                a: Box::new(restore_layout_node(first, panes, splits, allocate)?),
                b: Box::new(restore_layout_node(second, panes, splits, allocate)?),
            }
        }
        RegistryLayoutNode::Stack { panes: members, expanded } => {
            let members = members
                .iter()
                .map(|pane| {
                    panes
                        .get(pane)
                        .copied()
                        .ok_or_else(|| anyhow::anyhow!("stack has unknown pane {pane}"))
                })
                .collect::<anyhow::Result<Vec<_>>>()?;
            let expanded = *panes
                .get(expanded)
                .ok_or_else(|| anyhow::anyhow!("stack has unknown expanded pane {expanded}"))?;
            Node::stack_with_expanded(members, expanded)
                .ok_or_else(|| anyhow::anyhow!("stored stack is empty or has invalid selection"))?
        }
    })
}

fn restore_layout_node_from_known_splits(
    node: &RegistryLayoutNode,
    panes: &HashMap<PanePublicId, PaneId>,
    splits: &HashMap<SplitPublicId, SplitId>,
) -> anyhow::Result<Node> {
    Ok(match node {
        RegistryLayoutNode::Leaf { pane } => Node::Leaf(
            *panes.get(pane).ok_or_else(|| anyhow::anyhow!("layout has unknown pane {pane}"))?,
        ),
        RegistryLayoutNode::Split { split, direction, ratio, first, second } => {
            let id = *splits
                .get(split)
                .ok_or_else(|| anyhow::anyhow!("layout has unknown split {split}"))?;
            let dir = match direction.as_str() {
                "right" => SplitDir::Right,
                "down" => SplitDir::Down,
                _ => anyhow::bail!("split {split} has invalid direction {direction:?}"),
            };
            Node::Split {
                id,
                dir,
                ratio: *ratio,
                a: Box::new(restore_layout_node_from_known_splits(first, panes, splits)?),
                b: Box::new(restore_layout_node_from_known_splits(second, panes, splits)?),
            }
        }
        RegistryLayoutNode::Stack { panes: members, expanded } => {
            let members = members
                .iter()
                .map(|pane| {
                    panes
                        .get(pane)
                        .copied()
                        .ok_or_else(|| anyhow::anyhow!("stack has unknown pane {pane}"))
                })
                .collect::<anyhow::Result<Vec<_>>>()?;
            let expanded = *panes
                .get(expanded)
                .ok_or_else(|| anyhow::anyhow!("stack has unknown expanded pane {expanded}"))?;
            Node::stack_with_expanded(members, expanded)
                .ok_or_else(|| anyhow::anyhow!("stored stack is empty or has invalid selection"))?
        }
    })
}
