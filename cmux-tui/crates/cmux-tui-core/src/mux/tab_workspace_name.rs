//! The name of a workspace a tab move creates (`tab-workspace-name-v1`):
//! `move-tab-to-new-workspace` may carry it, so the workspace is named in
//! the move's own commit.

use super::*;

impl Mux {
    /// The caller's name, else the default `workspace-N`.
    pub(super) fn moved_tab_workspace_name(name: Option<&str>, state: &State) -> String {
        name.map_or_else(|| Self::default_workspace_name(state), str::to_owned)
    }
}
