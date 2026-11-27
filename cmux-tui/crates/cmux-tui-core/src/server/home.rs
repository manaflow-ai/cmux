//! `workspace-kind-v1` in the raw tree: `Workspace.kind` is `"home"` for the
//! store's home workspace, `"app"` for an app workspace (`app-screens-v1`,
//! with `Workspace.app`), and `"normal"` otherwise.

use crate::workspace_registry::PresentationSnapshot;

pub(super) fn raw_workspace_kind(presentation: &PresentationSnapshot, key: &str) -> &'static str {
    if presentation.home_workspace.as_deref() == Some(key) {
        "home"
    } else if presentation.app_workspaces.contains_key(key) {
        "app"
    } else {
        "normal"
    }
}

/// `Workspace.recovered` (`workspace-recovered-v1`): the workspace has tabs and every one is a
/// terminal the daemon recovered from an orphaned host. A tab the person adds makes it theirs.
/// Free when the store has no recovered terminal (the common case).
pub(super) fn raw_workspace_recovered(
    state: &crate::model::State,
    workspace: &crate::model::Workspace,
    presentation: &PresentationSnapshot,
) -> bool {
    if presentation.recovered_terminals.is_empty() {
        return false;
    }
    let mut tabs = workspace
        .screens
        .iter()
        .flat_map(|screen| screen.root.pane_ids_vec())
        .filter_map(|pane| state.panes.get(&pane))
        .flat_map(|pane| pane.tabs.iter())
        .peekable();
    tabs.peek().is_some()
        && tabs.all(|surface| {
            state
                .surfaces
                .get(surface)
                .and_then(|surface| surface.terminal_host_identity())
                .is_some_and(|identity| {
                    presentation.recovered_terminals.contains(&identity.terminal_id)
                })
        })
}

/// `Workspace.app`: the app of an app workspace.
pub(super) fn raw_workspace_app<'a>(
    presentation: &'a PresentationSnapshot,
    key: &str,
) -> Option<&'a str> {
    presentation.app_workspaces.get(key).map(String::as_str)
}
