//! Placing a block of tabs in a pane (moved out of tab_groups.rs, behavior unchanged).

use super::*;

/// Reorder `pane` so `block` sits contiguously starting at insertion index
/// `index` among the pane's other tabs. The active tab stays active.
pub(crate) fn place_block(state: &mut State, pane: PaneId, block: &[SurfaceId], index: usize) {
    let Some(record) = state.panes.get_mut(&pane) else { return };
    let active = record.active_surface();
    let mut rest =
        record.tabs.iter().copied().filter(|surface| !block.contains(surface)).collect::<Vec<_>>();
    let index = index.min(rest.len());
    rest.splice(index..index, block.iter().copied());
    record.tabs = rest;
    if let Some(active) = active {
        record.active_tab =
            record.tabs.iter().position(|surface| *surface == active).unwrap_or(record.active_tab);
    }
    for surface in block {
        state.resource_indexes.tab_pane.insert(*surface, pane);
    }
}
