//! Binding a created hosted terminal finds its catalog owner without a scan
//! of every terminal (nx-scale W2: the scan made each create O(terminals)).

use super::*;

const WORKSPACE: &str = "018f6e21-7b70-7e70-8000-000000002001";

fn hosted_terminal(mux: &Arc<Mux>, workspace_key: &str, index: u32) -> Arc<Surface> {
    let terminal = format!("00000000000040008000{index:012x}");
    let incarnation = format!("10000000000040008000{index:012x}");
    let mut registry = mux.workspace_registry.lock().unwrap();
    commit_terminal_transition(
        &mut registry,
        "terminal-reserved",
        "reserve-terminal",
        &RegistryTerminal {
            terminal_id: terminal.clone(),
            workspace_key: workspace_key.into(),
            incarnation: None,
            lifecycle: TerminalLifecycle::Launching,
            launch_spec: serde_json::json!({}),
            exit: None,
            on_exit: TerminalOnExit::Close,
        },
    )
    .unwrap();
    commit_terminal_lifecycle(
        &mut registry,
        "terminal-ready",
        "terminal-ready",
        &terminal,
        TerminalLifecycle::Running,
        Some(&incarnation),
        None,
    )
    .unwrap();
    drop(registry);
    let surface = Surface::exited_terminal_placeholder(
        mux.next_id(),
        mux.surface_options.lock().unwrap().clone(),
        Arc::downgrade(mux),
        TerminalHostIdentity { terminal_id: terminal, incarnation },
    )
    .unwrap();
    insert_surface_checked(&mut mux.state.lock().unwrap(), surface.clone()).unwrap();
    surface
}

#[cfg(unix)]
#[test]
fn binding_a_created_terminal_scans_no_catalog() {
    let mux = Mux::new_for_test("catalog-index", SurfaceOptions::default());
    let workspace = mux.create_empty_workspace(None, Some(WORKSPACE.into()), None).unwrap();
    let scans = catalog_scans_for_test();
    for index in 1..=6 {
        let surface = hosted_terminal(&mux, &workspace.key, index);
        let (placement, canonical, _, _) =
            mux.bind_running_terminal_to_canonical_workspace(&surface).unwrap();
        assert_eq!(canonical, workspace.key);
        assert_eq!(placement.workspace, workspace.workspace);
    }
    assert_eq!(catalog_scans_for_test(), scans, "a bind scanned the terminal catalog");
}

#[cfg(unix)]
#[test]
fn a_closed_terminal_leaves_no_host_index_entry() {
    let mux = Mux::new_for_test("catalog-index-close", SurfaceOptions::default());
    let workspace = mux.create_empty_workspace(None, Some(WORKSPACE.into()), None).unwrap();
    let surface = hosted_terminal(&mux, &workspace.key, 1);
    mux.bind_running_terminal_to_canonical_workspace(&surface).unwrap();
    let public_id = surface.terminal_public_id().unwrap().clone();
    let host = surface.terminal_host_identity().unwrap().terminal_id;
    mux.with_state(|state| assert!(mux.catalog_terminal_by_host(state, &host).unwrap().is_some()));
    remove_terminal_content_from_state(&mux, &mut mux.state.lock().unwrap(), &public_id);
    mux.with_state(|state| {
        assert!(mux.catalog_terminal_by_host(state, &host).unwrap().is_none());
        assert!(state.terminal_catalog_by_host.is_empty(), "the host index kept a closed terminal");
    });
}
