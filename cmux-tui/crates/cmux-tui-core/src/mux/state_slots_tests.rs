use super::*;
use crate::mux::Mux;
use crate::surface::SurfaceOptions;

#[test]
fn live_slots_resolve_and_stale_ones_are_typed_errors() {
    let mux = Mux::new_for_test("state-slots", SurfaceOptions::default());
    let surface = mux.new_workspace(None, None).unwrap().id;
    mux.with_state(|state| {
        let pane = state.pane_of(surface).unwrap();
        let (workspace, screen) = state.screen_of(pane).unwrap();
        assert_eq!(state.workspace_at(workspace).unwrap().id, state.workspaces[workspace].id);
        assert!(state.screen_at(workspace, screen).unwrap().root.contains(pane));
        assert_eq!(state.live_pane(pane).unwrap().id, pane);
        assert!(state.live_pane_public_id(pane).is_ok());
        assert!(state.live_tab_public_id(surface).is_ok());

        let past = state.workspaces.len();
        assert_eq!(state.workspace_at(past).unwrap_err(), StaleTopology::Workspace { index: past });
        assert_eq!(
            state.screen_at(workspace, 99).unwrap_err(),
            StaleTopology::Screen { workspace, screen: 99 }
        );
        assert_eq!(state.screen_at(past, 0).unwrap_err(), StaleTopology::Workspace { index: past });
        let gone: PaneId = PaneId::MAX;
        assert_eq!(state.live_pane(gone).unwrap_err(), StaleTopology::Pane { pane: gone });
        assert_eq!(
            state.live_pane_public_id(gone).unwrap_err(),
            StaleTopology::PanePublicId { pane: gone }
        );
        assert_eq!(
            state.live_tab_public_id(SurfaceId::MAX).unwrap_err(),
            StaleTopology::TabPublicId { surface: SurfaceId::MAX }
        );
    });
}

#[test]
fn stale_slots_mutate_nothing() {
    let mux = Mux::new_for_test("state-slots-mut", SurfaceOptions::default());
    mux.new_workspace(None, None).unwrap();
    let mut state = mux.with_state(State::clone);
    let before = state.workspaces.len();
    assert!(state.workspace_at_mut(before).is_err());
    assert!(state.screen_at_mut(0, 99).is_err());
    assert!(state.live_pane_mut(PaneId::MAX).is_err());
    assert_eq!(state.workspaces.len(), before);
}

#[test]
fn stale_topology_converts_into_the_request_error() {
    let error: anyhow::Error = StaleTopology::Screen { workspace: 2, screen: 5 }.into();
    assert_eq!(error.to_string(), "screen index 5 of workspace index 2 is not live");
    assert_eq!(
        error.downcast_ref::<StaleTopology>(),
        Some(&StaleTopology::Screen { workspace: 2, screen: 5 })
    );
}
