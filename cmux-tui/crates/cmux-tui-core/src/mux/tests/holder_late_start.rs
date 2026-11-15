//! A daemon start while the terminal holder is slow to answer (a loaded
//! machine, a holder that is still starting): the holder still runs the
//! shell, so the start must keep the terminal and its tab.

use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixListener;

use super::*;

/// One workspace with one tab whose terminal runs (`incarnation`), as a
/// daemon that stopped left it.
fn registry_with_running_terminal(
    root: &Path,
    session: &str,
    terminal_id: &str,
    incarnation: &str,
) -> TabPublicId {
    let workspace = RegistryWorkspace {
        id: 1,
        public_id: restore_workspace_id(42),
        key: "workspace-held".into(),
        name: "Held".into(),
        name_source: Default::default(),
        name_revision: 0,
        group_key: session.into(),
    };
    let screen = restore_screen_id(42);
    let pane = restore_pane_id(42);
    let tab = restore_tab_id(42);
    let terminal_public_id = restore_terminal_id(42);
    let terminal = RegistryTerminal {
        terminal_id: terminal_id.into(),
        workspace_key: workspace.key.clone(),
        incarnation: None,
        lifecycle: TerminalLifecycle::Launching,
        launch_spec: serde_json::json!({"command":["/bin/sh"]}),
        exit: None,
        on_exit: TerminalOnExit::Close,
    };
    let mut registry = WorkspaceRegistry::open(root, session).unwrap();
    registry
        .commit_resource_patch(
            &WorkspaceMutation::daemon("seed-held-terminal", "test").unwrap(),
            "workspace.create",
            &serde_json::json!({"fixture":"held-terminal"}),
            None,
            Some(0),
            &ResourcePatch {
                changes: vec![
                    ResourceChange::UpsertWorkspace {
                        workspace: workspace.clone(),
                        position: 0,
                        active_screen: Some(screen.clone()),
                    },
                    ResourceChange::UpsertScreen(RegistryScreen {
                        public_id: screen.clone(),
                        workspace_id: workspace.public_id.clone(),
                        position: 0,
                        name: None,
                        layout: RegistryLayoutNode::Leaf { pane: pane.clone() },
                        active_pane: pane.clone(),
                        zoomed_pane: None,
                        auto_layout: None,
                        viewport: RegistryViewport::default(),
                    }),
                    ResourceChange::UpsertPane(RegistryPane {
                        public_id: pane.clone(),
                        screen_id: screen.clone(),
                        name: None,
                        active_tab: Some(tab.clone()),
                        creation_ordinal: 1,
                    }),
                    ResourceChange::UpsertTerminal {
                        public_id: terminal_public_id.clone(),
                        terminal,
                    },
                    ResourceChange::UpsertTab(RegistryTab {
                        name_source: Default::default(),
                        name_revision: 0,
                        public_id: tab.clone(),
                        pane_id: pane.clone(),
                        position: 0,
                        content_id: ContentPublicId::Terminal(terminal_public_id),
                        name: None,
                        browser_url: None,
                        terminal_id: Some(terminal_id.into()),
                    }),
                    ResourceChange::SetWorkspaceOrder {
                        workspace_ids: vec![workspace.public_id.clone()],
                    },
                    ResourceChange::SetScreenOrder {
                        workspace_id: workspace.public_id.clone(),
                        screen_ids: vec![screen],
                    },
                    ResourceChange::SetTabOrder { pane_id: pane, tab_ids: vec![tab.clone()] },
                    ResourceChange::SetActiveWorkspace { workspace_id: Some(workspace.public_id) },
                ],
            },
            &serde_json::json!({"created":true}),
            &serde_json::json!([{"kind":"fixture.created"}]),
        )
        .unwrap();
    commit_terminal_lifecycle(
        &mut registry,
        "terminal-ready",
        "seed-running-terminal",
        terminal_id,
        TerminalLifecycle::Running,
        Some(incarnation),
        None,
    )
    .unwrap();
    tab
}

#[test]
fn a_start_keeps_a_terminal_whose_holder_does_not_answer_in_time() {
    const TERMINAL: &str = "0000000000004000800000000000002b";
    const INCARNATION: &str = "1000000000004000800000000000002b";
    let root = std::env::temp_dir()
        .join(format!("cmux-mux-holder-late-start-{}", crate::workspace_registry::new_uuid_v4()));
    let session = "holder-late-start";
    let tab = registry_with_running_terminal(&root, session, TERMINAL, INCARNATION);

    let host_root = crate::terminal_host_runtime::terminal_host_root(&root, session);
    std::fs::create_dir_all(&host_root).unwrap();
    std::fs::set_permissions(&host_root, std::fs::Permissions::from_mode(0o700)).unwrap();
    // The holder of this session: its socket takes a connect and the HELLO,
    // and nothing reads them, as a holder that has no time for this daemon
    // yet. It still holds the shell of the terminal.
    let socket = crate::holder_runtime::HolderService::socket_for_test(&host_root).unwrap();
    let _ = std::fs::remove_file(&socket);
    let holder = UnixListener::bind(&socket).unwrap();

    let options =
        SurfaceOptions { terminal_host_root: Some(host_root), ..SurfaceOptions::default() };
    let mux = Mux::open_persistent(session, options, &root).unwrap();

    let resolved = mux.resolve_terminal(TERMINAL).unwrap().unwrap();
    assert!(
        resolved.terminal.exit.is_none(),
        "the start recorded an end for a terminal whose holder had not answered yet: {:?}",
        resolved.terminal.exit
    );
    assert!(
        matches!(
            resolved.terminal.lifecycle,
            TerminalLifecycle::Running | TerminalLifecycle::Adopting
        ),
        "the terminal is {:?} after the start; its holder had not answered yet",
        resolved.terminal.lifecycle
    );
    assert_eq!(
        resolved.terminal.incarnation.as_deref(),
        Some(INCARNATION),
        "the start replaced the shell that the holder still runs"
    );
    let tabs = mux.workspace_registry.lock().unwrap().resource_topology_snapshot().unwrap().tabs;
    assert!(
        tabs.iter().any(|kept| kept.public_id == tab),
        "the tab of the terminal is gone after the start"
    );

    mux.shutdown();
    drop(mux);
    drop(holder);
    let _ = std::fs::remove_file(&socket);
    std::fs::remove_dir_all(root).unwrap();
}
