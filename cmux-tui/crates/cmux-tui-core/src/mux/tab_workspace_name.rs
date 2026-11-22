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

#[cfg(test)]
mod tests {
    use super::*;

    fn tabs(mux: &Mux, pane: PaneId) -> Vec<SurfaceId> {
        mux.with_state(|state| state.panes.get(&pane).map(|pane| pane.tabs.clone()))
            .unwrap_or_default()
    }

    fn pane_of(mux: &Mux, surface: SurfaceId) -> PaneId {
        mux.with_state(|state| state.pane_of(surface)).unwrap()
    }

    #[test]
    fn cmux_next_tab_to_new_workspace_takes_the_given_name() {
        let mux = Mux::new_for_test("tab-drag-workspace-name", SurfaceOptions::default());
        let first = mux.new_workspace(None, None).unwrap().id;
        let origin = pane_of(&mux, first);
        let second = mux.new_tab(Some(origin), None, None).unwrap().id;
        let third = mux.new_tab(Some(origin), None, None).unwrap().id;
        let too_long = "x".repeat(WORKSPACE_NAME_MAX_BYTES + 1);
        assert!(mux.move_tab_to_new_workspace(second, None, None, Some(too_long)).is_err());
        assert_eq!(tabs(&mux, origin), vec![first, second, third]);
        let named =
            mux.move_tab_to_new_workspace(second, None, None, Some("vim notes".into())).unwrap();
        let unnamed = mux.move_tab_to_new_workspace(third, None, None, None).unwrap();
        let name = |id| mux.with_state(|state| state.workspace_by_id(id).map(|w| w.name.clone()));
        assert_eq!(name(named).as_deref(), Some("vim notes"));
        assert!(name(unnamed).is_some_and(|name| name.starts_with("workspace-")));
    }
}
