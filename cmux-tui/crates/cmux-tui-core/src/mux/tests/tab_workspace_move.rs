//! Moving a tab to another workspace: one revision, and a failed commit keeps memory and durable topology.

use super::*;

#[test]
fn tab_workspace_move_preserves_surface_and_commits_one_revision() {
    let mux = test_mux();
    let first = mux.new_workspace(Some("source".into()), Some((80, 24))).unwrap();
    let second = mux.new_tab(None, None, Some((80, 24))).unwrap();
    let before = mux.with_state(|state| state.resource_revision);
    mux.move_tab_to_workspace(second.id, None).unwrap();
    mux.with_state(|state| {
        assert_eq!(state.workspaces.len(), 2);
        assert_eq!(state.resource_revision, before + 1);
        assert_eq!(
            state.active_pane().and_then(|id| state.panes[&id].active_surface()),
            Some(second.id)
        );
        assert!(state.pane_of(first.id).is_some());
    });
    assert!(Arc::ptr_eq(&second, &mux.surface(second.id).unwrap()));
    let empty = mux.create_empty_workspace(Some("empty".into()), None, None).unwrap();
    mux.move_tab_to_workspace(second.id, Some(empty.workspace)).unwrap();
    assert_eq!(
        mux.with_state(|state| state.workspaces[state.active_workspace].id),
        empty.workspace
    );
    assert!(Arc::ptr_eq(&second, &mux.surface(second.id).unwrap()));
    let before = mux.with_state(|state| (state.workspaces.len(), state.resource_revision));
    assert!(mux.move_tab_to_workspace(second.id, Some(u64::MAX)).is_err());
    assert_eq!(mux.with_state(|state| (state.workspaces.len(), state.resource_revision)), before);
    let third = mux.new_tab(None, None, Some((80, 24))).unwrap();
    let source = mux.with_state(|state| state.workspaces[0].id);
    mux.move_tab_to_workspace(second.id, Some(source)).unwrap();
    let key = mux.with_state(|state| state.workspaces[0].key.clone());
    {
        let registry = mux.workspace_registry.lock().unwrap();
        let topology = registry.resource_topology_snapshot().unwrap();
        let tab_id = &second.resource_identity().unwrap().tab_id;
        let tab = topology.tabs.iter().find(|tab| &tab.public_id == tab_id).unwrap();
        assert_eq!(
            registry
                .terminal_record(tab.terminal_id.as_deref().unwrap())
                .unwrap()
                .unwrap()
                .workspace_key,
            key
        );
        restore_resource_state(registry.snapshot().unwrap(), topology).unwrap();
    }
    mux.close_surface(third.id).unwrap();
    mux.close_surface(first.id).unwrap();
    mux.close_surface(second.id).unwrap();
}

#[test]
fn tab_workspace_failed_commit_keeps_both_memory_and_durable_topology() {
    let mux = test_mux();
    let tab = mux.new_workspace(None, Some((80, 24))).unwrap();
    let before = mux.with_state(state_topology_fingerprint);
    let durable = mux.workspace_registry.lock().unwrap().resource_topology_snapshot().unwrap();
    mux.workspace_registry.lock().unwrap().set_resource_patch_failure(true).unwrap();
    assert!(mux.move_tab_to_workspace(tab.id, None).is_err());
    assert_eq!(mux.with_state(state_topology_fingerprint), before);
    {
        let registry = mux.workspace_registry.lock().unwrap();
        assert_eq!(registry.resource_topology_snapshot().unwrap(), durable);
        registry.set_resource_patch_failure(false).unwrap();
    }
    assert!(Arc::ptr_eq(&tab, &mux.surface(tab.id).unwrap()));
    mux.close_surface(tab.id).unwrap();
}
