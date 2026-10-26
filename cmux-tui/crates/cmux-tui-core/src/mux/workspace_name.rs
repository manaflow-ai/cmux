//! The name of the next automatically created workspace (moved out of
//! mux.rs, behavior unchanged).

use super::*;

impl Mux {
    #[track_caller]
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
        let home = self.presentation_snapshot().home_workspace.clone();
        let counted = state
            .workspaces
            .iter()
            .filter(|workspace| Some(&workspace.key) != home.as_ref())
            .count();
        let highest = state
            .workspaces
            .iter()
            .filter_map(|workspace| {
                workspace.name.strip_prefix("workspace-")?.parse::<usize>().ok()
            })
            .max()
            .unwrap_or(0);
        let next = highest.max(counted).saturating_add(1);
        format!("workspace-{next}")
    }
}
