//! CLOSE-IF-EMPTY (cx-nsiyx, `close-workspace-if-empty-v1`): a
//! `close-workspace` with `if_empty` closes the workspace only when it has
//! no tab at commit time.
//!
//! A client that moved the last tab out of a workspace and then closes the
//! emptied source cannot use `expected_revision` for this: the workspace
//! registry revision orders the workspace list, and a tab added to an
//! existing workspace does not advance it. Another client (a Cmd+T, a CLI
//! `new-tab`, an agent) can open a tab there between the move and the close,
//! and an unguarded close deletes that tab. The guard is checked under the
//! state lock that every tab change takes, in the same step that commits the
//! close, so no tab can arrive between the check and the removal.

use super::*;

/// `workspace_not_empty`: `close-workspace` with `if_empty` found a tab.
#[derive(Debug)]
pub(crate) struct WorkspaceNotEmpty {
    key: String,
    tabs: usize,
}

impl WorkspaceNotEmpty {
    pub(crate) const CODE: &'static str = "workspace_not_empty";
}

impl fmt::Display for WorkspaceNotEmpty {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            formatter,
            "{}: workspace {} has {} tab(s); close-workspace with if_empty does not close it",
            Self::CODE,
            self.key,
            self.tabs
        )
    }
}

impl std::error::Error for WorkspaceNotEmpty {}

/// The raw `error_code` of an `if_empty` refusal, read from the whole chain.
pub(crate) fn workspace_not_empty_code(error: &anyhow::Error) -> Option<String> {
    error
        .chain()
        .any(|cause| cause.downcast_ref::<WorkspaceNotEmpty>().is_some())
        .then(|| WorkspaceNotEmpty::CODE.to_string())
}

impl Mux {
    /// With `if_empty`, refuses (`workspace_not_empty`) when the workspace at
    /// `index` holds any tab. Call it with the state lock held, in the step
    /// that commits the close.
    pub(super) fn require_empty_workspace_for_close(
        state: &State,
        index: usize,
        if_empty: bool,
    ) -> anyhow::Result<()> {
        if !if_empty {
            return Ok(());
        }
        let workspace = state.workspace_at(index)?;
        let mut panes = Vec::new();
        for screen in &workspace.screens {
            screen.root.pane_ids(&mut panes);
        }
        let tabs: usize =
            panes.iter().filter_map(|pane| state.panes.get(pane)).map(|pane| pane.tabs.len()).sum();
        if tabs > 0 {
            return Err(WorkspaceNotEmpty { key: workspace.key.clone(), tabs }.into());
        }
        Ok(())
    }
}
