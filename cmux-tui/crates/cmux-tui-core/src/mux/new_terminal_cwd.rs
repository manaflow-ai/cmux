//! Where a new terminal starts when its creator names no folder
//! (NEW-TERMINAL-INHERITS-CWD, cx-zld): the one resolver for new tabs,
//! splits, new screens and a workspace's next terminal, like Ghostty's
//! `window-`, `tab-` and `split-inherit-working-directory`.
//!
//! First match wins:
//! 1. The caller's folder (an explicit `cwd`; the app sends one when the
//!    person's Ghostty config turns inheritance off).
//! 2. The target pane's terminal: its selected tab, else its other tabs; a
//!    terminal's folder is its OSC 7 report, else the folder it started in
//!    (`Surface::local_cwd`).
//! 3. The workspace's last focused terminal: its other panes by focus order,
//!    newest first, each pane's selected tab before its other tabs. With no
//!    target pane, the active screen's active pane leads. A split of a
//!    browser tab still opens where the person works.
//! 4. None: the spawn default (`platform::default_terminal_cwd`: the daemon's
//!    launch folder, else the home folder).

use super::*;

impl Mux {
    /// The folder of a new terminal created next to `pane` (or in
    /// `workspace` when no pane is named). `explicit` always wins.
    pub(super) fn new_terminal_cwd(
        &self,
        explicit: Option<String>,
        pane: Option<PaneId>,
        workspace: Option<WorkspaceId>,
    ) -> Option<String> {
        if explicit.is_some() {
            return explicit;
        }
        // Collect the candidates under the state lock, read their folders
        // after it: `local_cwd` takes each surface's own locks.
        let candidates =
            self.with_state(|state| new_terminal_cwd_candidates(state, pane, workspace));
        candidates.into_iter().find_map(|surface| surface.local_cwd())
    }
}

/// The surfaces whose folder a new terminal may inherit, best first.
fn new_terminal_cwd_candidates(
    state: &State,
    pane: Option<PaneId>,
    workspace: Option<WorkspaceId>,
) -> Vec<Arc<Surface>> {
    let workspace = pane
        .and_then(|pane| state.screen_of(pane))
        .map(|(workspace, _)| workspace)
        .or_else(|| workspace.and_then(|id| state.workspace_index(id)))
        .and_then(|index| state.workspaces.get(index));
    let lead = pane.or_else(|| {
        workspace
            .and_then(|workspace| workspace.active_screen_ref())
            .map(|screen| screen.active_pane)
    });
    let mut panes: Vec<&Pane> = Vec::new();
    if let Some(workspace) = workspace {
        let mut ids = Vec::new();
        for screen in &workspace.screens {
            screen.root.pane_ids(&mut ids);
        }
        panes.extend(ids.iter().filter_map(|id| state.panes.get(id)));
        panes.sort_by_key(|pane| std::cmp::Reverse((pane.focused_at, pane.active_at)));
    }
    if let Some(lead) = lead.and_then(|lead| state.panes.get(&lead)) {
        panes.retain(|pane| pane.id != lead.id);
        panes.insert(0, lead);
    }
    let mut surfaces = Vec::new();
    for pane in panes {
        // Each pane's selected tab first, then its other tabs in order.
        let selected = pane.active_surface();
        let tabs = selected
            .into_iter()
            .chain(pane.tabs.iter().copied().filter(|tab| Some(*tab) != selected));
        surfaces.extend(
            tabs.filter_map(|tab| state.surfaces.get(&tab))
                .filter(|surface| matches!(surface.kind(), SurfaceKind::Pty))
                .cloned(),
        );
    }
    surfaces
}
