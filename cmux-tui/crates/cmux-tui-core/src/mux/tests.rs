//! Unit tests for the `Mux` coordinator. Topic suites live in `mux/tests/`;
//! this module holds their shared fixtures.

use super::*;
use std::collections::HashMap;

mod agent_hook_fences;
mod agent_hook_retry;
mod agent_reports;
mod agent_roster_restore;
mod cell_pixel_fanout;
mod cell_pixels;
mod column_update;
mod diagnostics;
mod dock_columns;
mod journal_roster;
mod kitty_budget;
mod kitty_reservation;
mod layout_apply_focus;
mod layout_undo;
mod layout_undo_commit;
mod notifications;
mod pane_close;
mod resource_effects;
mod resource_restore;
mod resource_selectors;
mod restart;
mod rows;
mod signaled_mutex;
mod split_ratio;
mod stack_layout;
mod surface_notifications;
mod tab_workspace_move;
mod tabs;
mod terminal_exit_restart;
mod terminal_moves;
mod terminal_registry;
mod terminal_views;
mod view_close_replay;
mod viewport_columns;
mod workspace_materialize;
mod workspaces;
mod writer_lock_order;

use crate::layout::{DEFAULT_VIEWPORT_PANE_WIDTH, VirtualRect};
use crate::resource::{BrowserPublicId, MachinePublicId, SessionPublicId, TabPublicId};
use crate::workspace_registry::{
    RegistryPane, RegistryScreen, RegistryViewportColumn, ResourceChange, ResourcePatch,
};

fn test_mux() -> Arc<Mux> {
    Mux::new_for_test("test", SurfaceOptions::default())
}

fn open_persistent_test_mux(session: &str, state_root: &Path) -> Arc<Mux> {
    let registry = WorkspaceRegistry::open(state_root, session).unwrap();
    Mux::from_workspace_registry(
        session.to_owned(),
        SurfaceOptions::default(),
        registry,
        ProviderWorkspaceState::default(),
        true,
    )
    .unwrap()
}

fn assert_terminal_view_detached(mux: &Mux, surface: SurfaceId) {
    assert!(!mux.with_state(|state| state.surfaces.contains_key(&surface)));
    assert!(mux.surface(surface).is_some(), "terminal runtime must remain catalog-owned");
}

fn wait_for_kitty_image_budget(mux: &Mux) {
    // The stress cases create every process-budget owner while the rest
    // of this 800-test binary is also scheduling worker threads. Wait on
    // the worker's state transition instead of polling CPU progress.
    assert!(
        mux.wait_for_kitty_image_budget_idle_for_test(
            crate::terminal_host_runtime::CONTROL_RESPONSE_TIMEOUT.saturating_mul(15),
        ),
        "Kitty image budget worker did not converge"
    );
}

fn close_terminal_runtime_for_test(mux: &Mux, surface: &Surface) {
    let identity =
        mux.resource_terminal_host_identity(surface).expect("test terminal has a host identity");
    mux.close_terminal(&identity.terminal_id, &identity.incarnation).unwrap();
}

fn public_request(
    mux: &Arc<Mux>,
    id: &str,
    operation: &str,
    params: Value,
    idempotency_key: Option<&str>,
) -> Value {
    let mut request = serde_json::json!({
        "protocol":"cmux.protocol/2",
        "type":"request",
        "id":id,
        "operation":operation,
        "params":params,
    });
    if let Some(idempotency_key) = idempotency_key {
        request["idempotency_key"] = Value::String(idempotency_key.to_string());
    }
    crate::resource_router::handle_resource_message(mux, &request.to_string()).unwrap()
}

fn state_topology_fingerprint(state: &State) -> String {
    let workspaces = state
        .workspaces
        .iter()
        .map(|workspace| {
            (
                workspace.id,
                workspace.public_id.clone(),
                workspace.key.clone(),
                workspace.name.clone(),
                workspace.active_screen,
                workspace
                    .screens
                    .iter()
                    .map(|screen| {
                        (
                            screen.id,
                            screen.public_id.clone(),
                            screen.layout_revision,
                            format!("{:?}", screen.layout_snapshot()),
                            format!("{:?}", screen.layout_undo),
                        )
                    })
                    .collect::<Vec<_>>(),
            )
        })
        .collect::<Vec<_>>();
    let mut panes = state
        .panes
        .iter()
        .map(|(id, pane)| (*id, pane.tabs.clone(), pane.active_tab))
        .collect::<Vec<_>>();
    panes.sort_by_key(|(id, _, _)| *id);
    let mut surfaces = state.surfaces.keys().copied().collect::<Vec<_>>();
    surfaces.sort_unstable();
    format!(
        "{:?}",
        (
            state.resource_revision,
            state.workspace_revision,
            state.active_workspace,
            workspaces,
            panes,
            surfaces,
        )
    )
}

fn restore_workspace_id(value: u128) -> WorkspacePublicId {
    WorkspacePublicId::parse(format!("ws_{value:032x}")).unwrap()
}

fn restore_screen_id(value: u128) -> ScreenPublicId {
    ScreenPublicId::parse(format!("screen_{value:032x}")).unwrap()
}

fn restore_pane_id(value: u128) -> PanePublicId {
    PanePublicId::parse(format!("pane_{value:032x}")).unwrap()
}

fn restore_tab_id(value: u128) -> TabPublicId {
    TabPublicId::parse(format!("tab_{value:032x}")).unwrap()
}

fn restore_browser_id(value: u128) -> BrowserPublicId {
    BrowserPublicId::parse(format!("browser_{value:032x}")).unwrap()
}

fn restore_terminal_id(value: u128) -> TerminalPublicId {
    TerminalPublicId::parse(format!("term_{value:032x}")).unwrap()
}

fn restore_split_id(value: u128) -> SplitPublicId {
    SplitPublicId::parse(format!("split_{value:032x}")).unwrap()
}

fn resource_restore_fixture() -> (RegistrySnapshot, ResourceTopologySnapshot) {
    let first_workspace = RegistryWorkspace {
        id: 10,
        public_id: restore_workspace_id(1),
        key: "first".into(),
        name: "Duplicate".into(),
        group_key: "test".into(),
    };
    let empty_workspace = RegistryWorkspace {
        id: 20,
        public_id: restore_workspace_id(2),
        key: "empty".into(),
        name: "Duplicate".into(),
        group_key: "test".into(),
    };
    let first_screen = restore_screen_id(1);
    let second_screen = restore_screen_id(2);
    let panes = (1..=5).map(restore_pane_id).collect::<Vec<_>>();
    let tabs = (1..=6).map(restore_tab_id).collect::<Vec<_>>();
    let internal_split = restore_split_id(1);
    let boundary_split = restore_split_id(2);
    let base_column = restore_split_id(3);
    let first_column_layout = RegistryLayoutNode::Split {
        split: internal_split,
        direction: "down".into(),
        ratio: 0.6,
        first: Box::new(RegistryLayoutNode::Stack {
            panes: vec![panes[0].clone(), panes[1].clone()],
            expanded: panes[1].clone(),
        }),
        second: Box::new(RegistryLayoutNode::Leaf { pane: panes[2].clone() }),
    };
    let first_layout = RegistryLayoutNode::Split {
        split: boundary_split.clone(),
        direction: "right".into(),
        ratio: 0.8 / (0.8 + 0.4),
        first: Box::new(first_column_layout.clone()),
        second: Box::new(RegistryLayoutNode::Leaf { pane: panes[3].clone() }),
    };
    let screens = vec![
        RegistryScreen {
            public_id: first_screen.clone(),
            workspace_id: first_workspace.public_id.clone(),
            position: 0,
            name: Some("Columns".into()),
            layout: first_layout,
            active_pane: panes[2].clone(),
            zoomed_pane: Some(panes[2].clone()),
            auto_layout: None,
            viewport: RegistryViewport {
                base_width: Some(0.8),
                columns: vec![
                    RegistryViewportColumn {
                        id: base_column,
                        width: 0.8,
                        layout: first_column_layout,
                        auto_layout: None,
                        dock: None,
                        rows: Vec::new(),
                    },
                    RegistryViewportColumn {
                        id: boundary_split,
                        width: 0.4,
                        layout: RegistryLayoutNode::Leaf { pane: panes[3].clone() },
                        auto_layout: Some(vec![panes[3].clone()]),
                        dock: None,
                        rows: Vec::new(),
                    },
                ],
            },
        },
        RegistryScreen {
            public_id: second_screen.clone(),
            workspace_id: first_workspace.public_id.clone(),
            position: 1,
            name: Some("Selected".into()),
            layout: RegistryLayoutNode::Leaf { pane: panes[4].clone() },
            active_pane: panes[4].clone(),
            zoomed_pane: Some(panes[4].clone()),
            auto_layout: Some(vec![panes[4].clone()]),
            viewport: RegistryViewport::default(),
        },
    ];
    let registry_panes = vec![
        RegistryPane {
            public_id: panes[0].clone(),
            screen_id: first_screen.clone(),
            name: Some("one".into()),
            active_tab: Some(tabs[0].clone()),
            creation_ordinal: 1,
        },
        RegistryPane {
            public_id: panes[1].clone(),
            screen_id: first_screen.clone(),
            name: Some("two".into()),
            active_tab: Some(tabs[1].clone()),
            creation_ordinal: 2,
        },
        RegistryPane {
            public_id: panes[2].clone(),
            screen_id: first_screen.clone(),
            name: Some("three".into()),
            active_tab: Some(tabs[2].clone()),
            creation_ordinal: 3,
        },
        RegistryPane {
            public_id: panes[3].clone(),
            screen_id: first_screen,
            name: Some("four".into()),
            active_tab: Some(tabs[3].clone()),
            creation_ordinal: 4,
        },
        RegistryPane {
            public_id: panes[4].clone(),
            screen_id: second_screen.clone(),
            name: Some("five".into()),
            active_tab: Some(tabs[5].clone()),
            creation_ordinal: 5,
        },
    ];
    let registry_tabs = tabs
        .iter()
        .enumerate()
        .map(|(index, tab)| {
            let pane_index = index.min(4);
            RegistryTab {
                name_source: Default::default(),
                name_revision: 0,
                public_id: tab.clone(),
                pane_id: panes[pane_index].clone(),
                position: usize::from(index == 5),
                content_id: ContentPublicId::Browser(restore_browser_id(index as u128 + 1)),
                name: Some(format!("tab-{index}")),
                browser_url: Some(format!("about:blank#{index}")),
                terminal_id: None,
            }
        })
        .collect::<Vec<_>>();
    let browsers = registry_tabs
        .iter()
        .enumerate()
        .map(|(index, tab)| {
            let ContentPublicId::Browser(public_id) = &tab.content_id else {
                unreachable!("restart fixture uses browser tabs");
            };
            RegistryBrowser {
                public_id: public_id.clone(),
                url: tab.browser_url.clone().unwrap(),
                source: if index % 2 == 0 {
                    crate::workspace_registry::RegistryBrowserSource::Launched
                } else {
                    crate::workspace_registry::RegistryBrowserSource::External
                },
                launch: if index % 2 == 0 {
                    crate::workspace_registry::RegistryBrowserLaunch::Create
                } else {
                    crate::workspace_registry::RegistryBrowserLaunch::Adopted
                },
                reconnect: RegistryBrowserReconnect::Recreate,
                status: if index % 2 == 0 {
                    crate::workspace_registry::RegistryBrowserStatus::Live
                } else {
                    crate::workspace_registry::RegistryBrowserStatus::Failed
                },
                cols: 90 + index as u16,
                rows: 30 + index as u16,
            }
        })
        .collect();
    let session_id = SessionPublicId::parse("session_00000000000000000000000000000001").unwrap();
    (
        RegistrySnapshot {
            registry_id: "registry".into(),
            generation: "generation".into(),
            revision: 1,
            resource_revision: 1,
            session_id: session_id.clone(),
            next_numeric_id: 100,
            workspaces: vec![first_workspace.clone(), empty_workspace.clone()],
        },
        ResourceTopologySnapshot {
            session_id,
            generation: "generation".into(),
            revision: 1,
            active_workspace: Some(empty_workspace.public_id.clone()),
            active_screens: vec![
                (first_workspace.public_id, Some(second_screen)),
                (empty_workspace.public_id, None),
            ],
            screens,
            panes: registry_panes,
            tabs: registry_tabs,
            browsers,
        },
    )
}

fn resource_restore_patch(
    snapshot: &RegistrySnapshot,
    topology: &ResourceTopologySnapshot,
) -> ResourcePatch {
    let active_screens = topology.active_screens.iter().cloned().collect::<HashMap<_, _>>();
    let mut changes = Vec::new();
    for (position, workspace) in snapshot.workspaces.iter().enumerate() {
        changes.push(ResourceChange::UpsertWorkspace {
            workspace: workspace.clone(),
            position,
            active_screen: active_screens.get(&workspace.public_id).cloned().flatten(),
        });
    }
    changes.extend(topology.screens.iter().cloned().map(ResourceChange::UpsertScreen));
    changes.extend(topology.panes.iter().cloned().map(ResourceChange::UpsertPane));
    changes.extend(topology.browsers.iter().cloned().map(ResourceChange::UpsertBrowser));
    for tab in &topology.tabs {
        let ContentPublicId::Browser(_) = &tab.content_id else {
            panic!("restart fixture uses browser tabs");
        };
        changes.push(ResourceChange::UpsertTab(tab.clone()));
    }
    changes.push(ResourceChange::SetWorkspaceOrder {
        workspace_ids: snapshot
            .workspaces
            .iter()
            .map(|workspace| workspace.public_id.clone())
            .collect(),
    });
    for workspace in &snapshot.workspaces {
        changes.push(ResourceChange::SetScreenOrder {
            workspace_id: workspace.public_id.clone(),
            screen_ids: topology
                .screens
                .iter()
                .filter(|screen| screen.workspace_id == workspace.public_id)
                .map(|screen| screen.public_id.clone())
                .collect(),
        });
    }
    for pane in &topology.panes {
        changes.push(ResourceChange::SetTabOrder {
            pane_id: pane.public_id.clone(),
            tab_ids: topology
                .tabs
                .iter()
                .filter(|tab| tab.pane_id == pane.public_id)
                .map(|tab| tab.public_id.clone())
                .collect(),
        });
    }
    changes.push(ResourceChange::SetActiveWorkspace {
        workspace_id: topology.active_workspace.clone(),
    });
    ResourcePatch { changes }
}

#[cfg(unix)]
fn insert_running_terminal_identity_surface(
    mux: &Arc<Mux>,
    terminal_id: &str,
    incarnation: &str,
    workspace_key: &str,
) -> Arc<Surface> {
    let surface =
        mux.seed_running_terminal_for_test(terminal_id, incarnation, workspace_key).unwrap();
    mux.surface(surface).unwrap()
}

/// The public agent rows the hook projector wrote. Tests that drive
/// `apply_agent_hook_record` directly (to reorder or replay sequences)
/// bypass the journal append, so the journal-folded roster behind
/// `list_agents` never sees those events; the projector's fences and
/// its durable projection are what they exercise.
fn hook_projected_agents(mux: &Mux) -> Vec<Value> {
    crate::resource_api::public_session_snapshot(mux).unwrap()["agents"].as_array().unwrap().clone()
}

/// Append one hook event through the real journal ingress path, which
/// runs the hook projector (public agent rows) and the roster fold
/// (`list_agents`, the TUI and raw `agents`) exactly as a hook helper does.
fn append_journal_hook(
    mux: &Arc<Mux>,
    terminal_id: &TerminalPublicId,
    event: &str,
    session_id: Option<&str>,
) {
    let native = match session_id {
        Some(session_id) => serde_json::json!({ "session_id": session_id }),
        None => serde_json::json!({}),
    };
    let ingress = crate::agent_hooks::agent_hook_journal_ingress(
        "claude",
        event,
        Some(terminal_id.as_str()),
        native,
    )
    .unwrap();
    let key = format!("roster-fence-{}", crate::workspace_registry::new_uuid_v4());
    mux.append_journal_ingress(&ingress, "test", &key).unwrap();
}

fn roster_agent_state(mux: &Mux, terminal_id: &TerminalPublicId) -> Option<String> {
    mux.agent_roster
        .lock()
        .unwrap()
        .roster
        .entries
        .get(terminal_id.as_str())
        .map(|entry| entry.state.clone())
}

fn seed_split_ratio_tree(mux: &Arc<Mux>) -> (PaneId, PaneId, PaneId, SplitId, SplitId) {
    let first = mux.new_workspace(None, None).unwrap();
    let p1 = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let second = mux.split(p1, SplitDir::Right, None).unwrap();
    let p2 = mux.with_state(|state| state.pane_of(second.id).unwrap());
    let third = mux.split(p1, SplitDir::Right, None).unwrap();
    let p3 = mux.with_state(|state| state.pane_of(third.id).unwrap());
    let (root_split, inner_split) = mux.with_state(|state| {
        let Node::Split { id: root, a, .. } = &state.workspaces[0].screens[0].root else {
            panic!("root should be split");
        };
        let Node::Split { id: inner, .. } = a.as_ref() else {
            panic!("first child should be split");
        };
        (*root, *inner)
    });
    (p1, p2, p3, root_split, inner_split)
}

fn split_spec(dir: SplitDir, ratio: f32, a: LayoutSpec, b: LayoutSpec) -> LayoutSpec {
    LayoutSpec::Split { dir, ratio, a: Box::new(a), b: Box::new(b) }
}

#[cfg(unix)]
#[test]
fn live_authority_install_and_rotation_preserve_open_pty() {
    const MUX_GENERATION: &str = "0123456789abcdef0123456789abcdef";
    const AUTHORITY_ONE: &str = "live-authority-one-00000000000000000001";
    const AUTHORITY_TWO: &str = "live-authority-two-00000000000000000002";

    fn wait_for_text(surface: &Surface, needle: &str) {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let text = surface.with_terminal(|terminal| terminal.plain_text()).unwrap().unwrap();
            if text.contains(needle) {
                return;
            }
            assert!(Instant::now() < deadline, "PTY did not emit {needle:?}; output: {text:?}");
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    let mux = Mux::new_provider_managed_pending(
        "authority-pty-test",
        SurfaceOptions::default(),
        MUX_GENERATION,
    )
    .unwrap();
    let workspace = mux.create_empty_workspace(Some("pty".into()), None, None).unwrap();
    let (surface, _) = mux
        .create_terminal_surface_in_workspace(
            &Actor::Daemon,
            workspace.workspace,
            Some(vec![
                "sh".into(),
                "-c".into(),
                "while IFS= read -r line; do printf 'authority-test:%s\\n' \"$line\"; done".into(),
            ]),
            None,
            None,
            Some((80, 24)),
        )
        .unwrap();
    let process_id = surface.process_id();
    surface.write_bytes(b"before\n").unwrap();
    wait_for_text(&surface, "authority-test:before");

    mux.install_or_rotate_provider_workspace_authority(
        MUX_GENERATION,
        0,
        41,
        ProviderWorkspaceAuthority::new(AUTHORITY_ONE).unwrap(),
    )
    .unwrap();
    mux.install_or_rotate_provider_workspace_authority(
        MUX_GENERATION,
        41,
        42,
        ProviderWorkspaceAuthority::new(AUTHORITY_TWO).unwrap(),
    )
    .unwrap();

    surface.write_bytes(b"after\n").unwrap();
    wait_for_text(&surface, "authority-test:after");
    assert_eq!(surface.process_id(), process_id);
    assert!(!surface.is_dead());
    mux.shutdown();
}

mod authority_rotation_tests;

#[test]
fn initial_bootstrap_lock_serializes_concurrent_callers() {
    use std::sync::{Arc, Barrier, mpsc};
    use std::thread;

    let mux = Mux::new("bootstrap-lock-test", SurfaceOptions::default());
    let barrier = Arc::new(Barrier::new(2));
    let (event_tx, event_rx) = mpsc::sync_channel(0);
    let (release_tx, release_rx) = mpsc::sync_channel(0);
    thread::scope(|scope| {
        let first_barrier = barrier.clone();
        let first_mux = mux.clone();
        let first_event_tx = event_tx.clone();
        scope.spawn(move || {
            let _guard = first_mux.lock_initial_bootstrap();
            first_event_tx.send(()).unwrap();
            first_barrier.wait();
            release_rx.recv().unwrap();
        });

        let second_barrier = barrier.clone();
        let second_mux = mux.clone();
        scope.spawn(move || {
            second_barrier.wait();
            let _guard = second_mux.lock_initial_bootstrap();
            event_tx.send(()).unwrap();
        });

        // The first caller holds the lock while the second caller attempts to
        // acquire it. The second event must therefore remain blocked until
        // the first caller is released.
        event_rx.recv().unwrap();
        assert!(event_rx.try_recv().is_err());
        release_tx.send(()).unwrap();
        event_rx.recv().unwrap();
    });
}
