use super::*;

pub(crate) fn tab_public_id(state: &State, surface: SurfaceId) -> anyhow::Result<String> {
    state
        .resource_indexes
        .tab_ids
        .get(&surface)
        .map(|tab| tab.as_str().to_string())
        .with_context(|| format!("surface {surface} has no tab identity"))
}

pub(crate) fn pane_public_id(state: &State, pane: PaneId) -> anyhow::Result<String> {
    state
        .resource_indexes
        .pane_ids
        .get(&pane)
        .map(|id| id.as_str().to_string())
        .with_context(|| format!("unknown pane {pane}"))
}

pub(crate) fn pane_by_public_id(state: &State, pane: &str) -> Option<PaneId> {
    state
        .resource_indexes
        .panes
        .iter()
        .find_map(|(id, slot)| (id.as_str() == pane).then_some(*slot))
}

pub(crate) fn is_pinned(
    state: &State,
    presentation: &PresentationSnapshot,
    surface: SurfaceId,
) -> bool {
    state
        .resource_indexes
        .tab_ids
        .get(&surface)
        .is_some_and(|tab| presentation.pinned_tabs.contains(tab.as_str()))
}
