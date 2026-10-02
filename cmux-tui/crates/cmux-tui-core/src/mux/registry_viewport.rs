//! Restoring a screen's viewport columns, with their `sticky-columns-v1`
//! flags, from the workspace registry.

use super::*;

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
        columns.push(LayoutColumn {
            id,
            width: column.width,
            root,
            zellij_auto_layout,
            sticky: column.sticky,
        });
    }
    // Every writer stores normalized flags. The registry does not reject
    // inconsistent flags, so a damaged record still loads; it is repaired
    // here instead of producing a screen with no scrolling column.
    crate::model::normalize_sticky_columns(&mut columns);
    let viewport_splits = columns.iter().skip(1).map(|column| (column.id, column.width)).collect();
    Ok((viewport_splits, viewport.base_width, columns))
}
