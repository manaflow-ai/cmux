//! The name of the next automatically created workspace (moved out of
//! mux.rs).

use super::*;

impl Mux {
    pub(super) fn default_workspace_name(&self, state: &State) -> String {
        // Provider-created workspaces use a stable, human-readable sequence.
        // Existing names (including user-renamed workspaces) are left untouched;
        // only the next automatically generated name is derived here. The
        // sequence never restarts below the number of workspaces that exist:
        // renaming `workspace-1` to `shell` and creating another one yields
        // `workspace-2` (the second workspace), not a second `workspace-1`.
        // The app's hidden home is not one of the user's workspaces, so it
        // never counts: the first one after it is `workspace-1`. (The
        // presentation lock is a leaf, safe under the state lock.)
        // The count and the highest number come from the indexes (`State::workspace_name_numbers`),
        // not a walk of the list. A build that cross-checks walks it too and keeps the walked
        // answer, so a name written past `State::set_workspace_name` stays correct there and
        // shows up on stderr.
        let home = self.presentation_snapshot().home_workspace.clone();
        let home_counted =
            home.as_deref().is_some_and(|home| state.workspace_by_key(home).is_some());
        let mut counted = state.workspaces.len() - usize::from(home_counted);
        let mut highest = state.workspace_name_numbers.highest();
        if resource_content::crosscheck_enabled() {
            #[cfg(test)]
            crate::walk_counters::workspace_list_walked(state.workspaces.len());
            let walked_counted = state
                .workspaces
                .iter()
                .filter(|workspace| Some(&workspace.key) != home.as_ref())
                .count();
            let walked_highest = state
                .workspaces
                .iter()
                .filter_map(|workspace| crate::model::WorkspaceNameNumbers::number(&workspace.name))
                .max()
                .unwrap_or(0);
            if (walked_counted, walked_highest) != (counted, highest) {
                eprintln!(
                    "cmux-tui: default workspace name: the indexes say {counted} workspaces up to \
                     workspace-{highest}, the list {walked_counted} up to workspace-{walked_highest}"
                );
                (counted, highest) = (walked_counted, walked_highest);
            }
        }
        let next = highest.max(counted).saturating_add(1);
        format!("workspace-{next}")
    }
}
