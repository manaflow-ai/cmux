//! The screen value of every topology screen upsert, built by the one screen
//! builder in `resource_screen` so a delta equals the session snapshot at its
//! revision.

use super::*;

pub(super) fn screen_value(
    screen: &RegistryScreen,
    topology: &ResourceTopologySnapshot,
    active_workspace: Option<&WorkspacePublicId>,
    active_screen: Option<&ScreenPublicId>,
) -> anyhow::Result<Value> {
    let focused =
        active_workspace == Some(&screen.workspace_id) && active_screen == Some(&screen.public_id);
    let tabs_by_pane = crate::resource_screen::tabs_by_pane(&topology.tabs);
    let panes_by_id = crate::resource_screen::panes_by_id(&topology.panes);
    crate::resource_screen::screen_value(screen, focused, &tabs_by_pane, &panes_by_id)
}
