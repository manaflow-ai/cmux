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

/// `Workspace.app`: the app of an app workspace.
pub(super) fn raw_workspace_app<'a>(
    presentation: &'a PresentationSnapshot,
    key: &str,
) -> Option<&'a str> {
    presentation.app_workspaces.get(key).map(String::as_str)
}
