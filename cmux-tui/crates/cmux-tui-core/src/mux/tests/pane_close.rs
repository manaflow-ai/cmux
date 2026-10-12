//! Tab removal indexes, discarded spawns, and pane or screen close detaching views.

use super::*;

#[test]
fn removing_many_tabs_preserves_reverse_indexes_and_tab_order() {
    let mux = test_mux();
    let first =
        mux.new_browser_tab("about:blank#index-stress-0".into(), None, Some((80, 24))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(first.id).expect("first tab has a pane"));
    let mut surfaces = vec![first];
    for index in 1..96 {
        surfaces.push(
            mux.new_browser_tab(
                format!("about:blank#index-stress-{index}"),
                Some(pane),
                Some((80, 24)),
            )
            .unwrap(),
        );
    }

    let expected = surfaces.iter().map(|surface| surface.id).collect::<Vec<_>>();
    mux.with_state(|state| {
        assert_eq!(state.resource_indexes.tab_pane.len(), surfaces.len());
        assert!(state.resource_indexes.pane_screen.contains_key(&pane));
    });
    for target in surfaces.iter().skip(1).step_by(2) {
        let mut state = mux.state.lock().unwrap();
        let (removed, split_index_dirty) = remove_surface(&mux, &mut state, target.id);
        assert!(removed.is_some(), "stress target should be present");
        if split_index_dirty {
            Mux::rebuild_split_screen_index(&mut state);
        }
        assert_eq!(state.resource_indexes.tab_pane.get(&target.id), None);
        assert_eq!(state.resource_indexes.tab_ids.get(&target.id), None);
        assert_eq!(state.resource_indexes.content_ids.get(&target.id), None);
        let remaining = expected
            .iter()
            .copied()
            .filter(|surface| state.surfaces.contains_key(surface))
            .collect::<Vec<_>>();
        assert_eq!(state.panes[&pane].tabs, remaining);
        for (surface, indexed_pane) in &state.resource_indexes.tab_pane {
            assert_eq!(*indexed_pane, pane);
            assert!(state.panes[&pane].tabs.contains(surface));
        }
        assert_eq!(
            state.resource_indexes.pane_screen.get(&pane).copied(),
            state.screen_of(pane).map(|(wi, si)| state.workspaces[wi].screens[si].id)
        );
    }

    for target in surfaces.iter().skip(2).step_by(2) {
        let mut state = mux.state.lock().unwrap();
        let (removed, split_index_dirty) = remove_surface(&mux, &mut state, target.id);
        assert!(removed.is_some(), "stress target should be present");
        if split_index_dirty {
            Mux::rebuild_split_screen_index(&mut state);
        }
    }
    let mut state = mux.state.lock().unwrap();
    let (removed, split_index_dirty) = remove_surface(&mux, &mut state, surfaces[0].id);
    assert!(removed.is_some(), "final stress target should be present");
    if split_index_dirty {
        Mux::rebuild_split_screen_index(&mut state);
    }
    assert!(!state.panes.contains_key(&pane));
    assert!(!state.resource_indexes.pane_screen.contains_key(&pane));
    assert!(state.workspaces.iter().all(|workspace| workspace.screens.is_empty()));
    drop(state);
    for surface in surfaces {
        surface.kill();
    }
    mux.shutdown();
}

#[cfg(unix)]
#[test]
fn discard_spawned_restores_unbound_running_terminal_when_registry_close_fails() {
    const TERMINAL: &str = "00000000000040008000000000000012";
    const INCARNATION: &str = "10000000000040008000000000000012";
    let mux = test_mux();
    let workspace = mux
        .create_empty_workspace(None, Some("018f6e21-7b70-7e70-8000-000000001012".into()), None)
        .unwrap();
    let surface =
        insert_running_terminal_identity_surface(&mux, TERMINAL, INCARNATION, &workspace.key);
    {
        let mut state = mux.state.lock().unwrap();
        let (removed, split_index_dirty) = remove_surface(&mux, &mut state, surface.id);
        if split_index_dirty {
            Mux::rebuild_split_screen_index(&mut state);
        }
        insert_surface_checked(
            &mut state,
            removed.expect("seeded terminal is removable from topology"),
        )
        .unwrap();
    }
    assert_eq!(mux.with_state(|state| state.pane_of(surface.id)), None);
    let events = mux.subscribe();
    mux.workspace_registry.lock().unwrap().set_terminal_close_failure(true).unwrap();

    mux.discard_spawned(&Actor::Daemon, vec![surface.clone()]);

    let restored = mux
        .with_state(|state| state.pane_of(surface.id))
        .expect("failed close must project the terminal back into reachable topology");
    assert_eq!(
        mux.workspace_registry
            .lock()
            .unwrap()
            .terminal_record(TERMINAL)
            .unwrap()
            .unwrap()
            .lifecycle,
        TerminalLifecycle::Running
    );
    assert!(events.try_iter().any(|event| {
        matches!(event, MuxEvent::Status(message)
                if message.contains("could not atomically close discarded terminals"))
    }));

    mux.workspace_registry.lock().unwrap().set_terminal_close_failure(false).unwrap();
    assert!(mux.close_pane_for_resource_effect(restored).unwrap());
}

#[cfg(unix)]
#[test]
fn close_pane_detaches_view_without_closing_terminal_host() {
    const TERMINAL: &str = "00000000000040008000000000000010";
    const INCARNATION: &str = "10000000000040008000000000000010";
    let mux = test_mux();
    let workspace = mux
        .create_empty_workspace(None, Some("018f6e21-7b70-7e70-8000-000000001002".into()), None)
        .unwrap();
    let surface =
        insert_running_terminal_identity_surface(&mux, TERMINAL, INCARNATION, &workspace.key);
    let pane = mux.with_state(|state| state.pane_of(surface.id).unwrap());
    mux.workspace_registry.lock().unwrap().set_terminal_close_failure(true).unwrap();

    assert!(mux.close_pane(pane).unwrap());
    assert_eq!(mux.with_state(|state| state.pane_of(surface.id)), None);
    assert!(mux.surface(surface.id).is_some());
    assert_eq!(
        mux.workspace_registry
            .lock()
            .unwrap()
            .terminal_record(TERMINAL)
            .unwrap()
            .unwrap()
            .lifecycle,
        TerminalLifecycle::Running
    );
    assert!(mux.close_terminal(TERMINAL, INCARNATION).is_err());

    mux.workspace_registry.lock().unwrap().set_terminal_close_failure(false).unwrap();
    mux.close_terminal(TERMINAL, INCARNATION).unwrap();
    assert!(mux.surface(surface.id).is_none());
    assert_eq!(
        mux.workspace_registry
            .lock()
            .unwrap()
            .terminal_record(TERMINAL)
            .unwrap()
            .unwrap()
            .lifecycle,
        TerminalLifecycle::Tombstoned
    );
}

#[cfg(unix)]
#[test]
fn close_screen_detaches_view_without_closing_terminal_host() {
    const TERMINAL: &str = "00000000000040008000000000000011";
    const INCARNATION: &str = "10000000000040008000000000000011";
    let mux = test_mux();
    let workspace = mux
        .create_empty_workspace(None, Some("018f6e21-7b70-7e70-8000-000000001003".into()), None)
        .unwrap();
    let surface =
        insert_running_terminal_identity_surface(&mux, TERMINAL, INCARNATION, &workspace.key);
    let screen = mux.with_state(|state| surface_screen_id(state, surface.id).unwrap());
    mux.workspace_registry.lock().unwrap().set_terminal_close_failure(true).unwrap();

    assert!(mux.close_screen(screen).unwrap());
    assert_eq!(mux.with_state(|state| surface_screen_id(state, surface.id)), None);
    assert!(mux.surface(surface.id).is_some());
    assert_eq!(
        mux.workspace_registry
            .lock()
            .unwrap()
            .terminal_record(TERMINAL)
            .unwrap()
            .unwrap()
            .lifecycle,
        TerminalLifecycle::Running
    );
    assert!(mux.close_terminal(TERMINAL, INCARNATION).is_err());

    mux.workspace_registry.lock().unwrap().set_terminal_close_failure(false).unwrap();
    mux.close_terminal(TERMINAL, INCARNATION).unwrap();
    assert!(mux.surface(surface.id).is_none());
    assert_eq!(
        mux.workspace_registry
            .lock()
            .unwrap()
            .terminal_record(TERMINAL)
            .unwrap()
            .unwrap()
            .lifecycle,
        TerminalLifecycle::Tombstoned
    );
}
