//! `workspace-kind-v1` in the raw tree: `Workspace.kind` is `"home"` for the
//! store's home workspace and `"normal"` otherwise.

use crate::workspace_registry::PresentationSnapshot;

pub(super) fn raw_workspace_kind(presentation: &PresentationSnapshot, key: &str) -> &'static str {
    if presentation.home_workspace.as_deref() == Some(key) { "home" } else { "normal" }
}
