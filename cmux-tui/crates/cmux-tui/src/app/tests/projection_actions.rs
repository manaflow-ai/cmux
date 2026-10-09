//! Tests: projection rail targets, machine actions, session surfaces, menu
//! renames and exact targeting.

use super::*;

#[test]
fn projection_workspace_target_follows_id_after_tree_reorder() {
    let mux = Mux::new("projection-workspace-target-reorder-test", SurfaceOptions::default());
    let first = mux.new_workspace(Some("Alpha".into()), Some((80, 24))).unwrap();
    let second = mux.new_workspace(Some("Beta".into()), Some((80, 24))).unwrap();
    let mut app = test_app(Session::Local(mux.clone()));
    app.replace_tree(app.session.tree());

    let target = crate::sidebar_projection::ProjectionTarget::Workspace {
        index: 0,
        id: app.tree.workspaces()[0].id,
    };
    app.tree.workspaces_mut().swap(0, 1);
    app.activate_projection_target(target).unwrap();

    assert_eq!(app.tree.active_workspace, 1);
    assert_eq!(app.tree.active_workspace().map(|workspace| workspace.id), Some(target_id(target)));

    for surface in [first.id, second.id] {
        mux.close_surface(surface).unwrap();
    }
}

fn target_id(target: crate::sidebar_projection::ProjectionTarget) -> cmux_tui_core::WorkspaceId {
    match target {
        crate::sidebar_projection::ProjectionTarget::Workspace { id, .. } => id,
        _ => unreachable!("workspace target expected"),
    }
}

#[test]
fn empty_projection_uses_its_leaf_resource_label() {
    let mux = Mux::new("projection-empty-leaf-label-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.config.sidebar.columns.clear();
    app.config.sidebar.views = vec![SidebarViewSpec {
        id: "workspace-tabs".into(),
        levels: vec![SidebarResourceKind::Workspaces, SidebarResourceKind::Tabs],
        actions: Vec::new(),
        actions_position: crate::config::ActionsPosition::Bottom,
        width: 40,
        max_width: 0,
        collapse_priority: 30,
    }];
    app.config.sidebar.views_explicit = true;
    app.sync_layout((100, 12));

    let mut terminal = Terminal::new(TestBackend::new(100, 12)).unwrap();
    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
    let rendered = buffer_text(terminal.backend().buffer());

    assert!(rendered.contains("no tabs"), "{rendered}");
    assert!(!rendered.contains("no workspaces"), "{rendered}");
}

#[test]
fn workspace_keyboard_enter_returns_focus_to_pane() {
    let mux = Mux::new("workspace-keyboard-enter-focus-test", SurfaceOptions::default());
    let first = mux.new_workspace(Some("Alpha".into()), Some((80, 24))).unwrap();
    let second = mux.new_workspace(Some("Beta".into()), Some((80, 24))).unwrap();
    let mut app = test_app(Session::Local(mux.clone()));
    app.sidebar_view = SidebarView::Workspaces;
    app.replace_tree(app.session.tree());
    app.sync_layout((100, 20));
    app.sidebar_workspace_selection = 0;
    app.workspace_rail_selection = WorkspaceRailSelection::Workspace;
    app.focus = FocusTarget::WorkspaceRail;

    app.handle_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE)).unwrap();

    assert_eq!(app.focus, FocusTarget::Pane);

    for surface in [first.id, second.id] {
        mux.close_surface(surface).unwrap();
    }
}

#[test]
fn projection_enter_on_active_surface_returns_focus_to_pane() {
    let (mux, surface) = test_mux("projection-active-surface-enter-test", None);
    mux.report_agent(
        surface.id,
        AgentState::Working,
        AgentSource::Hook,
        Some("agent-session".into()),
    )
    .unwrap();
    let mut app = test_app(Session::Local(mux.clone()));
    app.config.sidebar.columns.clear();
    app.config.sidebar.views = vec![SidebarViewSpec {
        id: "workspace-agents".into(),
        levels: vec![SidebarResourceKind::Workspaces, SidebarResourceKind::Agents],
        actions: Vec::new(),
        actions_position: crate::config::ActionsPosition::Bottom,
        width: 40,
        max_width: 0,
        collapse_priority: 30,
    }];
    app.config.sidebar.views_explicit = true;
    app.replace_tree(app.session.tree());
    app.sync_layout((100, 20));
    app.projection_rail_state_mut(0).selected = 1;
    app.focus = FocusTarget::ProjectionRail(0);

    app.handle_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE)).unwrap();

    assert_eq!(app.tree.active_surface(), Some(surface.id));
    assert_eq!(app.focus, FocusTarget::Pane);

    mux.close_surface(surface.id).unwrap();
}

#[test]
fn projection_stale_action_selection_does_not_retarget_resource_row() {
    let (mux, surface) = test_mux("projection-stale-action-selection-test", None);
    mux.report_agent(
        surface.id,
        AgentState::Working,
        AgentSource::Hook,
        Some("agent-session".into()),
    )
    .unwrap();
    let mut app = test_app(Session::Local(mux.clone()));
    app.config.sidebar.columns.clear();
    app.config.sidebar.views = vec![SidebarViewSpec {
        id: "workspace-agents".into(),
        levels: vec![SidebarResourceKind::Workspaces, SidebarResourceKind::Agents],
        actions: Vec::new(),
        actions_position: crate::config::ActionsPosition::Bottom,
        width: 40,
        max_width: 0,
        collapse_priority: 30,
    }];
    app.config.sidebar.views_explicit = true;
    app.replace_tree(app.session.tree());
    let state = app.projection_rail_state_mut(0);
    state.selected = 0;
    state.selected_action = Some(99);
    app.focus = FocusTarget::ProjectionRail(0);

    app.handle_key(KeyEvent::new(KeyCode::Left, KeyModifiers::NONE)).unwrap();

    assert!(
        app.projection_rail_state_mut(0).collapsed.is_empty(),
        "stale action selection must not collapse the selected resource row"
    );

    mux.close_surface(surface.id).unwrap();
}

#[test]
fn projection_agent_rows_hide_finished_reports() {
    let (mux, surface) = test_mux("projection-finished-agent-test", None);
    mux.report_agent(surface.id, AgentState::Done, AgentSource::Hook, Some("agent-session".into()))
        .unwrap();
    let mut app = test_app(Session::Local(mux.clone()));
    app.config.sidebar.columns.clear();
    app.config.sidebar.views = vec![SidebarViewSpec {
        id: "agents".into(),
        levels: vec![SidebarResourceKind::Agents],
        actions: Vec::new(),
        actions_position: crate::config::ActionsPosition::Bottom,
        width: 40,
        max_width: 0,
        collapse_priority: 30,
    }];
    app.config.sidebar.views_explicit = true;
    app.replace_tree(app.session.tree());

    assert!(app.projection_rows(0).is_empty(), "finished reports must not leave stale agent rows");

    mux.close_surface(surface.id).unwrap();
}

#[test]
fn tabs_column_context_menu_renames_the_exact_clicked_tab() {
    let (mux, first) = test_mux("tabs-column-rename-test", None);
    let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let second = mux.new_tab(Some(pane), None, Some((80, 24))).unwrap();
    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    app.config.sidebar.columns_explicit = true;
    app.config.sidebar.columns = vec![
        crate::config::SidebarColumn {
            kind: SidebarColumnKind::Workspaces,
            width: 22,
            max_width: 0,
        },
        crate::config::SidebarColumn { kind: SidebarColumnKind::Tabs, width: 24, max_width: 0 },
    ];
    app.config.sidebar.views = app
        .config
        .sidebar
        .columns
        .iter()
        .map(|column| SidebarViewSpec::legacy(column.kind, column.width, column.max_width))
        .collect();
    app.config.sidebar.views_explicit = true;
    app.sidebar_view = SidebarView::Workspaces;
    app.replace_tree(app.session.tree());
    app.sync_layout((100, 20));

    let mut terminal = Terminal::new(TestBackend::new(100, 20)).unwrap();
    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
    assert_eq!(app.tree.active_surface(), Some(second.id));
    let clicked = app
        .hits
        .iter()
        .find_map(|(rect, hit)| {
            matches!(hit, crate::app::Hit::SidebarTab { surface, .. } if *surface == first.id)
                .then_some(*rect)
        })
        .unwrap();

    app.open_context_menu(clicked.x, clicked.y);
    assert!(
        app.menu.as_ref().unwrap().levels[0]
            .items
            .iter()
            .any(|item| item.action() == Some(MenuAction::RenameSurface(first.id)))
    );
    app.activate_menu(MenuAction::RenameSurface(first.id)).unwrap();
    assert_eq!(
        app.prompt.as_ref().map(|prompt| prompt.target),
        Some(PromptTarget::Surface(first.id))
    );
    app.prompt.as_mut().unwrap().input.insert_str("first renamed");
    app.commit_prompt();
    while app.session.has_pending_mutations() {
        app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
    }

    let tree = app.session.tree();
    let renamed = tree
        .workspaces()
        .iter()
        .flat_map(|workspace| workspace.screens.iter())
        .flat_map(|screen| screen.panes.iter())
        .flat_map(|pane| pane.tabs.iter())
        .find(|tab| tab.surface == first.id)
        .and_then(|tab| tab.name.as_deref());
    assert_eq!(renamed, Some("first renamed"));
    assert_eq!(mux.active_surface(), Some(second.id));
}

#[test]
fn pane_tab_context_menu_renames_the_exact_inactive_tab() {
    let (mux, first) = test_mux("pane-tab-rename-test", None);
    let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let second = mux.new_tab(Some(pane), None, Some((80, 24))).unwrap();
    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    app.sidebar_visible = false;
    app.replace_tree(app.session.tree());
    app.sync_layout((100, 20));

    let mut terminal = Terminal::new(TestBackend::new(100, 20)).unwrap();
    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
    assert_eq!(app.tree.active_surface(), Some(second.id));
    let clicked = app
        .hits
        .iter()
        .find_map(|(rect, hit)| {
            matches!(hit, crate::app::Hit::Tab { pane: hit_pane, index: 0 } if *hit_pane == pane)
                .then_some(*rect)
        })
        .unwrap();

    app.open_context_menu(clicked.x, clicked.y);
    assert!(
        app.menu.as_ref().unwrap().levels[0]
            .items
            .iter()
            .any(|item| item.action() == Some(MenuAction::RenameSurface(first.id)))
    );
    app.activate_menu(MenuAction::RenameSurface(first.id)).unwrap();
    app.prompt.as_mut().unwrap().input.insert_str("inactive renamed");
    app.commit_prompt();
    while app.session.has_pending_mutations() {
        app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
    }

    let tree = app.session.tree();
    let renamed = tree
        .workspaces()
        .iter()
        .flat_map(|workspace| workspace.screens.iter())
        .flat_map(|screen| screen.panes.iter())
        .flat_map(|pane| pane.tabs.iter())
        .find(|tab| tab.surface == first.id)
        .and_then(|tab| tab.name.as_deref());
    assert_eq!(renamed, Some("inactive renamed"));
    assert_eq!(mux.active_surface(), Some(second.id));
}

#[test]
fn workspace_agent_tree_renders_collapses_and_renames_the_exact_surface() {
    let (mux, surface) = test_mux("workspace-agent-tree-test", None);
    mux.report_agent(
        surface.id,
        AgentState::Working,
        AgentSource::Hook,
        Some("agent-session".into()),
    )
    .unwrap();
    let mut app = test_app(Session::Local(mux.clone()));
    app.config.sidebar.columns.clear();
    app.config.sidebar.views = vec![SidebarViewSpec {
        id: "workspace-agents".into(),
        levels: vec![SidebarResourceKind::Workspaces, SidebarResourceKind::Agents],
        actions: vec![crate::config::SidebarActionSpec::plain(Action::NewWorkspace)],
        actions_position: crate::config::ActionsPosition::Bottom,
        width: 40,
        max_width: 0,
        collapse_priority: 30,
    }];
    app.config.sidebar.views_explicit = true;
    app.replace_tree(app.session.tree());
    app.sync_layout((100, 20));

    let mut terminal = Terminal::new(TestBackend::new(100, 20)).unwrap();
    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
    let rendered = buffer_text(terminal.backend().buffer());
    assert!(rendered.contains("working · agent-session"), "{rendered}");
    assert!(
        rendered.contains("+ new workspace"),
        "a configured workspace representation must preserve its native creation action: {rendered}"
    );
    assert!(app.hits.iter().any(|(_, hit)| matches!(
        hit,
        crate::app::Hit::SidebarAction {
            view: 0,
            action: SidebarActionTarget::CreateWorkspace(None),
        }
    )));
    let surface_row = app
        .hits
        .iter()
        .find_map(|(rect, hit)| {
            matches!(
                hit,
                crate::app::Hit::ProjectionRow {
                    target: crate::sidebar_projection::ProjectionTarget::Surface {
                        surface: hit_surface,
                        ..
                    },
                    ..
                } if *hit_surface == surface.id
            )
            .then_some(*rect)
        })
        .unwrap();
    app.open_context_menu(surface_row.x, surface_row.y);
    assert!(
        app.menu.as_ref().unwrap().levels[0]
            .items
            .iter()
            .any(|item| item.action() == Some(MenuAction::RenameSurface(surface.id)))
    );

    app.menu = None;
    let disclosure = app
        .hits
        .iter()
        .find_map(|(rect, hit)| {
            matches!(
                hit,
                crate::app::Hit::ProjectionToggle {
                    branch: crate::sidebar_projection::ProjectionBranch::Workspace(_),
                    ..
                }
            )
            .then_some(*rect)
        })
        .unwrap();
    app.handle_left_down(disclosure.x, disclosure.y, KeyModifiers::NONE).unwrap();
    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
    assert_eq!(app.focus, FocusTarget::Pane);
    assert!(!app.hits.iter().any(|(_, hit)| matches!(
        hit,
        crate::app::Hit::ProjectionRow {
            target: crate::sidebar_projection::ProjectionTarget::Surface {
                surface: hit_surface,
                ..
            },
            ..
        } if *hit_surface == surface.id
    )));

    let area = app.sidebar_layout.rail(RailKind::Projection(0)).unwrap();
    app.handle_left_down(area.x + 1, area.y + 10, KeyModifiers::NONE).unwrap();
    assert_eq!(app.focus, FocusTarget::Pane);
    app.handle_left_down(area.x + 1, area.y, KeyModifiers::NONE).unwrap();
    assert_eq!(app.focus, FocusTarget::ProjectionRail(0));
    app.handle_key(KeyEvent::new(KeyCode::Right, KeyModifiers::ALT)).unwrap();
    assert_eq!(app.focus, FocusTarget::Pane);

    mux.close_surface(surface.id).unwrap();
}

#[test]
fn workspace_projection_actions_expand_provider_capabilities_and_can_be_hidden() {
    let mux = Mux::new("workspace-projection-action-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.machine_ui = Some(provider_machine_ui());
    app.config.sidebar.columns.clear();
    app.config.sidebar.views = vec![SidebarViewSpec {
        id: "workspace-agents".into(),
        levels: vec![SidebarResourceKind::Workspaces, SidebarResourceKind::Agents],
        actions: vec![crate::config::SidebarActionSpec::plain(Action::NewWorkspace)],
        actions_position: crate::config::ActionsPosition::Bottom,
        width: 40,
        max_width: 0,
        collapse_priority: 30,
    }];
    app.config.sidebar.views_explicit = true;
    app.sync_layout((100, 12));

    let mut terminal = Terminal::new(TestBackend::new(100, 12)).unwrap();
    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
    let rendered = buffer_text(terminal.backend().buffer());
    assert!(rendered.contains("new isolated"), "{rendered}");
    assert!(rendered.contains("new shared"), "{rendered}");
    let isolated = app
        .hits
        .iter()
        .find_map(|(rect, hit)| {
            matches!(
                hit,
                crate::app::Hit::SidebarAction {
                    action: SidebarActionTarget::CreateWorkspace(Some(
                        WorkspaceCreationMode::Isolated
                    )),
                    ..
                }
            )
            .then_some(*rect)
        })
        .expect("isolated action hit");

    app.handle_left_down(isolated.x, isolated.y, KeyModifiers::NONE).unwrap();
    assert_eq!(app.focus, FocusTarget::Pane);
    assert_eq!(
        app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
        Some(&MachineRequest::CreateManagedIsolatedWorkspace(MachineKey(41)))
    );

    app.machine_ui.as_mut().unwrap().request = None;
    app.focus = FocusTarget::ProjectionRail(0);
    app.handle_key(KeyEvent::new(KeyCode::End, KeyModifiers::NONE)).unwrap();
    app.handle_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE)).unwrap();
    assert_eq!(
        app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
        Some(&MachineRequest::CreateManagedHostWorkspace(MachineKey(41)))
    );

    app.config.sidebar.views[0].actions.clear();
    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
    let rendered = buffer_text(terminal.backend().buffer());
    assert!(!rendered.contains("new isolated"), "{rendered}");
    assert!(!rendered.contains("new shared"), "{rendered}");
    assert!(!app.hits.iter().any(|(_, hit)| matches!(hit, crate::app::Hit::SidebarAction { .. })));
}

#[test]
fn client_machine_context_menu_renames_without_provider_mutation() {
    let mux = Mux::new("client-machine-rename-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    let key = MachineKey(7);
    let mut ui = MachineUiState::new(MachineSnapshot {
        machines: vec![MachineDescriptor {
            key,
            id: "current".into(),
            name: "Build host".into(),
            subtitle: "local".into(),
            status: MachineStatus::Running,
        }],
        active: Some(key),
        capabilities: MachineCapabilities { create: false, connect: true },
    });
    ui.set_client_renamable_machines([key]);
    app.machine_ui = Some(ui);
    app.sync_layout((100, 14));
    let mut terminal = Terminal::new(TestBackend::new(100, 14)).unwrap();
    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
    let clicked = app
        .hits
        .iter()
        .find_map(|(rect, hit)| {
            matches!(hit, crate::app::Hit::Machine { key: hit_key, .. } if *hit_key == key)
                .then_some(*rect)
        })
        .unwrap();

    app.open_context_menu(clicked.x, clicked.y);
    assert!(
        app.menu.as_ref().unwrap().levels[0]
            .items
            .iter()
            .any(|item| item.action() == Some(MenuAction::RenameClientMachine(key)))
    );
    app.activate_menu(MenuAction::RenameClientMachine(key)).unwrap();
    assert_eq!(
        app.prompt.as_ref().map(|prompt| prompt.target),
        Some(PromptTarget::ClientMachine(key))
    );
    app.prompt.as_mut().unwrap().input.clear();
    app.prompt.as_mut().unwrap().input.insert_str("Renamed host");
    app.commit_prompt();
    assert_eq!(
        app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
        Some(&MachineRequest::RenameClientMachine { machine: key, name: "Renamed host".into() })
    );
}

#[test]
fn ssh_config_connection_menu_binds_the_selected_alias() {
    let mux = Mux::new("ssh-config-picker-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    let mut ui = MachineUiState::new(MachineSnapshot {
        machines: Vec::new(),
        active: None,
        capabilities: MachineCapabilities { create: false, connect: true },
    });
    ui.connection_targets = vec![
        MachineConnectionTarget { target: "buildbox".into(), name: "buildbox".into() },
        MachineConnectionTarget { target: "mini".into(), name: "mini".into() },
    ];
    app.machine_ui = Some(ui);

    app.open_machine_connection_menu(1, 3);
    let items = &app.menu.as_ref().unwrap().levels[0].items;
    assert_eq!(items[0].label(), Some("Add SSH host…"));
    assert_eq!(items[1], MenuItem::Separator);
    assert_eq!(items[2].label(), Some("buildbox"));
    assert_eq!(items.last().and_then(MenuItem::label), Some("mini"));
    assert_eq!(
        app.menu.as_ref().and_then(|menu| menu.search.as_ref()).map(|search| search.label.as_str()),
        Some("SSH hosts")
    );
    assert!(matches!(
        app.menu
            .as_ref()
            .and_then(|menu| menu.captured_resource(MenuAction::ConnectMachineTarget(0))),
        Some(Some(crate::app::MenuActionResource::MachineConnectionTarget(target)))
            if target == "buildbox"
    ));
    for character in "mini".chars() {
        app.handle_key(KeyEvent::new(KeyCode::Char(character), KeyModifiers::NONE)).unwrap();
    }
    let items = &app.menu.as_ref().unwrap().levels[0].items;
    assert_eq!(items[0].label(), Some("Add SSH host…"));
    assert_eq!(items[1], MenuItem::Separator);
    assert_eq!(items[2].label(), Some("mini"));
    app.handle_menu_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE)).unwrap();
    assert_eq!(
        app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
        Some(&MachineRequest::Connect { target: "mini".into(), route: MachineConnectRoute::Local })
    );

    app.machine_ui.as_mut().unwrap().request = None;
    app.activate_menu(MenuAction::ConnectOtherMachine).unwrap();
    assert_eq!(
        app.prompt.as_ref().map(|prompt| prompt.target),
        Some(PromptTarget::ConnectMachine(MachineConnectRoute::Local))
    );
}

#[test]
fn catalog_refresh_preserves_machine_and_workspace_selection_identity_and_scroll() {
    let descriptor = |key| MachineDescriptor {
        key: MachineKey(key),
        id: key.to_string(),
        name: format!("machine-{key}"),
        subtitle: "cloud".into(),
        status: MachineStatus::Running,
    };
    let mux = Mux::new("rail-refresh-test", SurfaceOptions::default());
    mux.new_workspace(Some("first".into()), None).unwrap();
    mux.new_workspace(Some("second".into()), None).unwrap();
    let mut app = test_app(Session::Local(mux));
    app.replace_tree(app.session.tree());
    app.sidebar_workspace_selection = 1;
    app.workspace_rail_scroll = 3;
    let selected_workspace = app.tree.workspaces()[1].id;
    let mut initial = MachineUiState::new(MachineSnapshot {
        machines: vec![descriptor(1), descriptor(2), descriptor(3)],
        active: Some(MachineKey(1)),
        capabilities: MachineCapabilities::default(),
    });
    initial.select_rail_target(crate::machine::MachineRailTarget::Machine(MachineKey(2)));
    app.machine_ui = Some(initial);
    app.machine_rail_scroll = 6;

    let update = MachineUiState::new(MachineSnapshot {
        machines: vec![descriptor(3), descriptor(2), descriptor(1)],
        active: Some(MachineKey(1)),
        capabilities: MachineCapabilities::default(),
    });
    app.apply_machine_ui_update(update);
    let mut reordered = app.tree.clone();
    reordered.workspaces_mut().swap(0, 1);
    app.replace_tree(reordered);

    assert_eq!(
        app.machine_ui.as_ref().and_then(MachineUiState::rail_target),
        Some(crate::machine::MachineRailTarget::Machine(MachineKey(2)))
    );
    assert_eq!(app.machine_rail_scroll, 6);
    assert_eq!(app.tree.workspaces()[app.sidebar_workspace_selection].id, selected_workspace);
    assert_eq!(app.workspace_rail_scroll, 3);
}

impl MachineController for FakeMachineController {
    fn perform(&mut self, request: MachineRequest) -> anyhow::Result<MachineActionResult> {
        self.requests.lock().unwrap().push(request);
        match self.actions.pop_front().expect("fake machine action") {
            FakeMachineAction::Return(result) => Ok(*result),
            FakeMachineAction::Fail(message) => anyhow::bail!(message),
        }
    }
}

fn unused_machine_preparation() -> crate::app::MachineSessionPreparation {
    let dispatcher = PtyInputDispatcher::spawn(|_| {}).unwrap();
    crate::app::MachineSessionPreparation {
        initial_size: None,
        generation: 2,
        pty_input: dispatcher.sender(),
        surface_filter: None,
    }
}

struct BlockingMachineController {
    release: StdReceiver<()>,
}

impl MachineController for BlockingMachineController {
    fn perform(&mut self, _request: MachineRequest) -> anyhow::Result<MachineActionResult> {
        self.release.recv().expect("release blocked machine action");
        Ok(MachineActionResult::ui(provider_machine_ui()))
    }
}

struct AckMachineController {
    acknowledgements: std::sync::mpsc::Sender<DurableNoticeDelivery>,
    fail: bool,
}

impl MachineController for AckMachineController {
    fn perform(&mut self, _request: MachineRequest) -> anyhow::Result<MachineActionResult> {
        unreachable!("ack controller does not perform machine actions")
    }

    fn acknowledge_durable_notice(
        &mut self,
        delivery: &DurableNoticeDelivery,
    ) -> anyhow::Result<()> {
        self.acknowledgements.send(delivery.clone()).unwrap();
        if self.fail {
            anyhow::bail!("ack failed");
        }
        Ok(())
    }
}

#[test]
fn machine_worker_preserves_exact_durable_notice_ack_result() {
    for fail in [false, true] {
        let (events, event_receiver) = crossbeam_channel::bounded(4);
        let (acknowledgements, acknowledged) = std::sync::mpsc::channel();
        let mut worker = MachineActionWorker::spawn(
            Box::new(AckMachineController { acknowledgements, fail }),
            events,
        )
        .unwrap();
        let delivery = DurableNoticeDelivery { notice_id: format!("notice-{fail}"), sequence: 41 };

        worker.acknowledge_durable_notice(delivery.clone()).unwrap();

        assert_eq!(acknowledged.recv_timeout(Duration::from_secs(1)).unwrap(), delivery);
        let AppEvent::MachineControllerCompleted(completion) =
            event_receiver.recv_timeout(Duration::from_secs(1)).unwrap()
        else {
            panic!("expected durable notice acknowledgement completion");
        };
        match *completion {
            crate::app::MachineControllerCompletion::DurableNoticeAcknowledged {
                delivery: completed,
                result,
            } => {
                assert_eq!(completed, delivery);
                assert_eq!(result.is_err(), fail);
            }
            _ => panic!("expected durable notice acknowledgement completion"),
        }
        worker.shutdown();
    }
}

#[test]
fn durable_notice_ack_waits_for_machine_action_settlement() {
    let mux = Mux::new("durable-ack-action-order", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    let (acknowledgements, acknowledged) = std::sync::mpsc::channel();
    install_machine_controller(
        &mut app,
        Box::new(AckMachineController { acknowledgements, fail: false }),
    );
    let delivery = DurableNoticeDelivery { notice_id: "usage-during-switch".into(), sequence: 42 };
    app.queue_durable_notice_ack(delivery.clone());
    app.machine_action_in_flight = true;

    app.submit_pending_durable_notice_ack();

    assert!(app.durable_notice_ack_in_flight.is_none());
    assert_eq!(app.pending_durable_notice_acks.front(), Some(&delivery));
    assert_eq!(
        acknowledged.recv_timeout(Duration::from_millis(20)),
        Err(std::sync::mpsc::RecvTimeoutError::Timeout)
    );

    app.machine_action_in_flight = false;
    app.submit_pending_durable_notice_ack();
    assert_eq!(acknowledged.recv_timeout(Duration::from_secs(1)).unwrap(), delivery);
    app.shutdown_background_workers();
}

struct OrderedBlockingMachineController {
    started: std::sync::mpsc::Sender<MachineKey>,
    release: StdReceiver<()>,
    closed: Option<std::sync::mpsc::Sender<()>>,
}

impl MachineController for OrderedBlockingMachineController {
    fn perform(&mut self, request: MachineRequest) -> anyhow::Result<MachineActionResult> {
        let MachineRequest::Switch(machine) = request else {
            panic!("ordered fake received a non-switch request");
        };
        self.started.send(machine).unwrap();
        self.release.recv().expect("release ordered machine action");
        Ok(MachineActionResult::ui(provider_machine_ui()))
    }

    fn close(&mut self) {
        if let Some(closed) = self.closed.take() {
            let _ = closed.send(());
        }
    }
}

#[test]
fn blocked_machine_action_does_not_block_the_app_event_loop() {
    let mux = Mux::new("machine-action-responsive", SurfaceOptions::default());
    let (mut app, _events) = test_app_with_events(Session::Local(mux));
    app.machine_ui = Some(provider_machine_ui());
    let (release, blocked) = std::sync::mpsc::channel();
    install_machine_controller(&mut app, Box::new(BlockingMachineController { release: blocked }));
    app.machine_ui.as_mut().unwrap().request = Some(MachineRequest::Switch(MachineKey(41)));
    let releaser = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(200));
        release.send(()).unwrap();
    });

    let started = Instant::now();
    let action = app.process_machine_requests();

    assert!(started.elapsed() < Duration::from_millis(50));
    assert_eq!(action, RenderAction::None);
    releaser.join().unwrap();
}

#[test]
fn machine_action_worker_serializes_requests_in_submission_order() {
    let (events, event_receiver) = crossbeam_channel::bounded(4);
    let (started, starts) = std::sync::mpsc::channel();
    let (release, releases) = std::sync::mpsc::channel();
    let mut worker = MachineActionWorker::spawn(
        Box::new(OrderedBlockingMachineController { started, release: releases, closed: None }),
        events,
    )
    .unwrap();

    worker.perform(MachineRequest::Switch(MachineKey(1)), unused_machine_preparation()).unwrap();

    assert_eq!(starts.recv_timeout(Duration::from_secs(1)).unwrap(), MachineKey(1));
    worker.perform(MachineRequest::Switch(MachineKey(2)), unused_machine_preparation()).unwrap();
    assert!(matches!(
        worker.perform(MachineRequest::Switch(MachineKey(3)), unused_machine_preparation()),
        Err(crate::app::MachineSubmitError::Busy(MachineRequest::Switch(MachineKey(3))))
    ));
    assert!(starts.try_recv().is_err(), "second action started before the first completed");
    release.send(()).unwrap();
    assert!(matches!(
        event_receiver.recv_timeout(Duration::from_secs(1)).unwrap(),
        AppEvent::MachineControllerCompleted(_)
    ));
    assert_eq!(starts.recv_timeout(Duration::from_secs(1)).unwrap(), MachineKey(2));
    release.send(()).unwrap();
    assert!(matches!(
        event_receiver.recv_timeout(Duration::from_secs(1)).unwrap(),
        AppEvent::MachineControllerCompleted(_)
    ));
    assert!(starts.try_recv().is_err(), "rejected stale action replayed after the queue drained");
    worker.shutdown();
}

#[test]
fn machine_action_worker_shutdown_never_joins_a_blocked_action() {
    let (events, _event_receiver) = crossbeam_channel::bounded(4);
    let (started, starts) = std::sync::mpsc::channel();
    let (release, releases) = std::sync::mpsc::channel();
    let (closed, closes) = std::sync::mpsc::channel();
    let mut worker = MachineActionWorker::spawn(
        Box::new(OrderedBlockingMachineController {
            started,
            release: releases,
            closed: Some(closed),
        }),
        events,
    )
    .unwrap();
    worker.perform(MachineRequest::Switch(MachineKey(1)), unused_machine_preparation()).unwrap();
    assert_eq!(starts.recv_timeout(Duration::from_secs(1)).unwrap(), MachineKey(1));

    let started_shutdown = Instant::now();
    worker.shutdown();

    assert!(started_shutdown.elapsed() < Duration::from_millis(50));
    release.send(()).unwrap();
    closes.recv_timeout(Duration::from_secs(1)).unwrap();
}

#[test]
fn canceling_machine_controller_completion_send_unblocks_when_queue_is_full() {
    let (events, receiver) = crossbeam_channel::bounded(1);
    events.send(AppEvent::Mux(MuxEvent::Empty)).unwrap();
    let cancellation = EventCancellation::new();
    let worker_cancellation = cancellation.clone();
    let (started_tx, started_rx) = std::sync::mpsc::sync_channel(1);
    let (completed_tx, completed_rx) = std::sync::mpsc::sync_channel(1);
    let worker = std::thread::spawn(move || {
        started_tx.send(()).unwrap();
        let completed = crate::app::send_machine_controller_completion(
            &events,
            crate::app::MachineControllerCompletion::Updates(Err("cancelled".into())),
            &worker_cancellation,
        );
        completed_tx.send(completed).unwrap();
    });

    started_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    assert!(matches!(
        completed_rx.recv_timeout(Duration::from_millis(50)),
        Err(std::sync::mpsc::RecvTimeoutError::Timeout)
    ));
    cancellation.cancel();
    assert!(!completed_rx.recv_timeout(Duration::from_secs(1)).unwrap());
    worker.join().unwrap();
    drop(receiver);
}

#[test]
fn in_place_machine_switch_preserves_rail_view_focus_and_widths() {
    let first = Mux::new("machine-switch-first", SurfaceOptions::default());
    first.new_workspace(None, None).unwrap();
    let second = Mux::new("machine-switch-second", SurfaceOptions::default());
    let (mut app, events) = test_app_with_events(Session::Local(first));
    app.replace_tree(app.session.tree());
    app.machine_ui = Some(provider_machine_ui());
    app.sidebar_view = SidebarView::Workspaces;
    app.focus = FocusTarget::MachineRail;
    app.sidebar_width_override = Some(27);
    app.machine_sidebar_width_override = Some(19);
    app.machine_rail_scroll = 3;
    app.workspace_rail_scroll = 6;

    let next_ui = provider_machine_ui();
    let (controller, requests) = fake_controller(FakeMachineAction::Return(Box::new(
        MachineActionResult::replace(next_ui, Session::Local(second), "second".into()),
    )));
    install_machine_controller(&mut app, controller);
    app.machine_ui.as_mut().unwrap().request = Some(MachineRequest::Switch(MachineKey(41)));

    assert!(matches!(settle_machine_action(&mut app, &events), RenderAction::Draw));
    assert_eq!(app.session_generation, 2);
    assert_eq!(app.session_label, "second");
    assert_eq!(app.sidebar_view, SidebarView::Workspaces);
    assert_eq!(app.focus, FocusTarget::MachineRail);
    assert_eq!(app.sidebar_width_override, Some(27));
    assert_eq!(app.machine_sidebar_width_override, Some(19));
    assert_eq!(app.machine_rail_scroll, 3);
    assert_eq!(app.workspace_rail_scroll, 6);
    assert!(!app.quit);
    assert_eq!(requests.lock().unwrap().as_slice(), &[MachineRequest::Switch(MachineKey(41))]);
}

#[test]
fn closing_connection_dialog_prevents_an_active_connect_from_replacing_the_session() {
    let first = Mux::new("connection-dialog-active-cancel-first", SurfaceOptions::default());
    first.new_workspace(None, None).unwrap();
    let second = Mux::new("connection-dialog-active-cancel-second", SurfaceOptions::default());
    second.new_workspace(None, None).unwrap();
    let (mut app, events) = test_app_with_events(Session::Local(first));
    app.replace_tree(app.session.tree());
    app.machine_ui = Some(provider_machine_ui());
    let (controller, requests) =
        fake_controller(FakeMachineAction::Return(Box::new(MachineActionResult::replace(
            provider_machine_ui(),
            Session::Local(second),
            "second".into(),
        ))));
    install_machine_controller(&mut app, controller);
    app.begin_machine_connection("mini.local".into(), MachineConnectRoute::Local);
    let request =
        MachineRequest::Connect { target: "mini.local".into(), route: MachineConnectRoute::Local };

    assert_eq!(app.process_machine_requests(), RenderAction::None);
    assert!(app.machine_action_in_flight);
    app.close_prompt();
    assert!(matches!(settle_machine_action(&mut app, &events), RenderAction::Draw));

    assert_eq!(app.session_generation, 1);
    assert_eq!(app.session_label, "test");
    assert!(app.prompt.is_none());
    assert!(app.connection_transaction.is_none());
    assert!(app.canceled_machine_connection_attempt.is_none());
    assert_eq!(requests.lock().unwrap().as_slice(), &[request]);
}

#[test]
fn machine_session_replacement_settles_pointer_capture_on_the_old_session() {
    let first = Mux::new("machine-pointer-reset-first", SurfaceOptions::default());
    first.new_workspace(None, None).unwrap();
    let second = Mux::new("machine-pointer-reset-second", SurfaceOptions::default());
    let (mut app, _events) = test_app_with_events(Session::Local(first));
    let (started_tx, started_rx) = std::sync::mpsc::channel();
    let (release_tx, release_rx) = std::sync::mpsc::channel();
    app.session.operations.enqueue_session_mutation(
        "block old session before pointer settlement",
        false,
        move || {
            started_tx.send(()).unwrap();
            release_rx.recv().unwrap();
            Ok(())
        },
    );
    started_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    app.drag = Some(Drag::ResizeSplit {
        horizontal: Some(PaneResizeDragTarget::ViewportColumn {
            pane: 1,
            edge: PaneEdge::Right,
            column_x: 0,
            viewport_x: 0,
            viewport_width: 1,
            viewport_offset: 0,
        }),
        vertical: None,
    });
    app.active_pointer_buttons.insert(MouseButton::Left);
    let old_pending_pointer_mutations = app.session.pending_pointer_mutations.clone();
    let (session, event_worker, mux_titles, mux_recovery_generation) = prepare_ordered_session(
        Session::Local(second),
        app.pty_input.sender(),
        app.app_events.clone(),
        2,
        None,
    )
    .unwrap();
    let tree = session.tree();

    app.install_prepared_machine_session(
        crate::app::PreparedMachineSession {
            session,
            event_worker,
            generation: 2,
            mux_titles,
            mux_recovery_generation,
            tree,
            label: "second".into(),
            session_available: true,
            machine: None,
        },
        true,
    );

    let pending_pointer_settlement = old_pending_pointer_mutations.load(Ordering::Acquire);
    release_tx.send(()).unwrap();
    assert_eq!(
        pending_pointer_settlement, 1,
        "the split settlement must be queued against the old session before replacement"
    );
    assert!(app.drag.is_none());
    assert!(app.active_pointer_buttons.is_empty());
}

#[test]
fn machine_session_replacement_preserves_only_the_old_browser_release() {
    let first = Mux::new("machine-browser-release-first", SurfaceOptions::default());
    let browser = first.new_browser_tab("about:blank".to_string(), None, Some((20, 8))).unwrap();
    let second = Mux::new("machine-browser-release-second", SurfaceOptions::default());
    let mut app = test_app(Session::Local(first.clone()));
    app.replace_tree(app.session.tree());
    assert!(app.tab_locations.contains_key(&browser.id));
    let (dispatcher, blocked) = BrowserInputDispatcher::blocked(2);
    app.browser_input = dispatcher;
    assert!(app.browser_input.enqueue(BrowserInputEvent {
        surface_id: browser.id,
        surface: app.session.surface(browser.id).unwrap(),
        kind: BrowserInputKind::Mouse {
            event_type: "mousePressed",
            x: 3.0,
            y: 2.0,
            button: Some("left"),
            click_count: Some(1),
            frame_seq: 1,
        },
    }));
    assert_eq!(blocked.drain_mouse_lifetimes(), vec![("mousePressed", false)]);
    assert!(app.browser_input.enqueue(BrowserInputEvent {
        surface_id: browser.id,
        surface: app.session.surface(browser.id).unwrap(),
        kind: BrowserInputKind::Mouse {
            event_type: "mouseMoved",
            x: 1.0,
            y: 1.0,
            button: Some("none"),
            click_count: None,
            frame_seq: 1,
        },
    }));
    app.drag = Some(Drag::Browser {
        surface: browser.id,
        content: Rect { x: 2, y: 3, width: 20, height: 8 },
        position: (5, 5),
        frame_seq: 1,
    });
    let (session, event_worker, mux_titles, mux_recovery_generation) = prepare_ordered_session(
        Session::Local(second),
        app.pty_input.sender(),
        app.app_events.clone(),
        2,
        None,
    )
    .unwrap();
    let tree = session.tree();

    app.install_prepared_machine_session(
        crate::app::PreparedMachineSession {
            session,
            event_worker,
            generation: 2,
            mux_titles,
            mux_recovery_generation,
            tree,
            label: "second".into(),
            session_available: true,
            machine: None,
        },
        true,
    );

    assert_eq!(
        blocked.drain_mouse_lifetimes(),
        vec![("mouseMoved", true), ("mouseReleased", false)],
        "session replacement must cancel stale browser input but preserve the release that closes the old press"
    );
    first.close_surface(browser.id).unwrap();
}

#[test]
fn replacement_provider_notice_cannot_mask_missing_workspace_mirror_error() {
    let first = Mux::new("machine-replacement-notice-first", SurfaceOptions::default());
    first.new_workspace(None, None).unwrap();
    let second = Mux::new("machine-replacement-notice-second", SurfaceOptions::default());
    second
        .create_empty_workspace(
            Some("work".into()),
            Some("00000000-0000-4000-8000-000000000004".into()),
            None,
        )
        .unwrap();
    let (mut app, events) = test_app_with_events(Session::Local(first));
    app.replace_tree(app.session.tree());
    app.apply_machine_ui_update(provider_machine_ui_with_lifecycle());
    let mut update = provider_machine_ui_with_lifecycle();
    update.notice = Some("provider accepted the rename".into());
    let result = MachineActionResult::replace(update, Session::Local(second), "second".into())
        .with_session_mutation(ManagedWorkspaceSessionMutation::Rename {
            workspace_key: "00000000-0000-4000-8000-000000000099".into(),
            name: "renamed".into(),
        });
    let (controller, _) = fake_controller(FakeMachineAction::Return(Box::new(result)));
    install_machine_controller(&mut app, controller);
    app.machine_ui.as_mut().unwrap().request = Some(MachineRequest::Switch(MachineKey(41)));

    settle_machine_action(&mut app, &events);

    assert_eq!(
        app.status_message.as_deref(),
        Some(localization::catalog().sidebar.managed_workspace_unavailable)
    );
}

#[test]
fn replaced_session_ignores_old_surface_lane_completion() {
    let first = Mux::new("surface-lane-generation-first", SurfaceOptions::default());
    let first_surface = first.new_workspace(None, Some((80, 24))).unwrap();
    let second = Mux::new("surface-lane-generation-second", SurfaceOptions::default());
    let second_surface = second.new_workspace(None, Some((80, 24))).unwrap();
    assert_eq!(first_surface.id, second_surface.id, "test requires a reused surface id");
    let (mut app, _events) = test_app_with_events(Session::Local(first.clone()));
    let (started_tx, started_rx) = std::sync::mpsc::channel();
    let (release_tx, release_rx) = std::sync::mpsc::channel();

    assert_eq!(
        app.session.operations.enqueue_surface_operation_with_retained_bytes(
            "old session clear",
            first_surface.id,
            false,
            0,
            move || {
                started_tx.send(()).unwrap();
                release_rx.recv().unwrap();
                Err(anyhow::anyhow!("ambiguous old session completion"))
            },
        ),
        PtyInputEnqueueResult::Accepted
    );
    started_rx.recv_timeout(Duration::from_secs(1)).unwrap();

    let (session, event_worker, mux_titles, mux_recovery_generation) = prepare_ordered_session(
        Session::Local(second.clone()),
        app.pty_input.sender(),
        app.app_events.clone(),
        2,
        None,
    )
    .unwrap();
    let tree = session.tree();
    app.install_prepared_machine_session(
        crate::app::PreparedMachineSession {
            session,
            event_worker,
            generation: 2,
            mux_titles,
            mux_recovery_generation,
            tree,
            label: "second".into(),
            session_available: true,
            machine: None,
        },
        true,
    );

    release_tx.send(()).unwrap();
    let deadline = Instant::now() + Duration::from_secs(1);
    while app.pty_failures.state.lock().unwrap().failures.is_empty() && Instant::now() < deadline {
        std::thread::yield_now();
    }
    assert!(!app.pty_failures.state.lock().unwrap().failures.is_empty());
    app.apply_pty_failures();

    let forwarded = app.enqueue_pty_bytes(
        second_surface.id,
        app.session.surface(second_surface.id).unwrap(),
        PtyInputBytes::from_slice(b"x"),
        PtyInputKind::Ordered,
    );
    assert!(forwarded.accepted, "old session lane state blocked the replacement session");
    assert!(
        app.status_message.is_none(),
        "old session completion surfaced an error in the replacement session"
    );

    let _ = first.close_surface(first_surface.id);
    let _ = second.close_surface(second_surface.id);
}

#[test]
fn retiring_surface_state_releases_its_failed_input_lane() {
    let mux = Mux::new("retired-surface-input-lane-test", SurfaceOptions::default());
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let (mut app, _events) = test_app_with_events(Session::Local(mux.clone()));

    assert_eq!(
        app.session.operations.enqueue_coalescing_surface_operation(
            "failed surface operation",
            surface.id,
            false,
            || Err(anyhow::anyhow!("ambiguous delivery")),
        ),
        PtyInputEnqueueResult::Accepted
    );
    let deadline = Instant::now() + Duration::from_secs(1);
    while app.pty_failures.state.lock().unwrap().failures.is_empty() && Instant::now() < deadline {
        std::thread::yield_now();
    }
    assert!(!app.pty_failures.state.lock().unwrap().failures.is_empty());
    assert!(
        !app.enqueue_pty_bytes(
            surface.id,
            app.session.surface(surface.id).unwrap(),
            PtyInputBytes::from_slice(b"x"),
            PtyInputKind::Ordered,
        )
        .accepted
    );

    app.retire_surface_state(surface.id);

    assert!(
        app.enqueue_pty_bytes(
            surface.id,
            app.session.surface(surface.id).unwrap(),
            PtyInputBytes::from_slice(b"x"),
            PtyInputKind::Ordered,
        )
        .accepted
    );
    assert!(app.pty_input.shutdown(Duration::from_secs(1)));
    mux.close_surface(surface.id).unwrap();
}

#[test]
fn terminal_input_failure_statuses_use_the_selected_locale() {
    const CHILD_ENV: &str = "CMUX_TERMINAL_INPUT_FAILURE_LOCALE_CHILD";
    if std::env::var_os(CHILD_ENV).is_none() {
        let output = std::process::Command::new(std::env::current_exe().unwrap())
            .arg("app::tests::terminal_input_failure_statuses_use_the_selected_locale")
            .arg("--exact")
            .arg("--nocapture")
            .env(CHILD_ENV, "1")
            .env("LC_ALL", "ja_JP.UTF-8")
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "Japanese terminal input failure child failed:\nstdout:\n{}\nstderr:\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        return;
    }

    let mux = Mux::new("terminal-input-failure-locale", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    let oversized = "x".repeat(
        crate::app::MAX_DEFERRED_INPUT_BYTES - crate::app::BRACKETED_PASTE_MARKER_BYTES + 1,
    );
    app.handle(AppEvent::Input(Event::Paste(oversized))).unwrap();
    assert_eq!(
        app.status_message.as_deref(),
        Some("貼り付けテキストが 4 MiB の PTY バッファ上限を超えています")
    );

    let half = "x".repeat(crate::app::MAX_DEFERRED_INPUT_BYTES / 2);
    app.defer_input(TerminalInput::Paste(half.clone()));
    app.defer_input(TerminalInput::Paste(half));
    assert_eq!(
        app.status_message.as_deref(),
        Some("セッション変更の保留中に入力キューのバイト上限に達しました")
    );

    let motion = MouseEvent {
        kind: MouseEventKind::Moved,
        column: 9,
        row: 3,
        modifiers: KeyModifiers::NONE,
    };
    app.session.pending_pointer_mutations.store(1, Ordering::Release);
    app.handle(AppEvent::Input(Event::Mouse(motion))).unwrap();
    app.session.pending_pointer_mutations.store(0, Ordering::Release);
    assert_eq!(
        app.pending_pointer_motion.map(|pending| pending.event),
        Some(motion),
        "layout changes retain the latest pointer motion instead of discarding it"
    );

    for (result, expected) in [
        (PtyInputEnqueueResult::Oversized, "入力が 4 MiB の PTY バッファ上限を超えています"),
        (
            PtyInputEnqueueResult::Saturated,
            "PTY 入力キューがいっぱいのため、入力は送信されませんでした",
        ),
        (PtyInputEnqueueResult::Failed, "転送エラー後のため PTY 入力を使用できません"),
    ] {
        assert!(!app.handle_pty_enqueue_result(result));
        assert_eq!(app.status_message.as_deref(), Some(expected));
    }

    app.apply_pty_operation_failure(PtyOperationFailure {
        session_generation: 1,
        surface_id: Some(1),
        kind: None,
        reservation_id: None,
        label: "attach surface",
        error: "timeout detail".into(),
        lane_failed: true,
        delivery: PtyOperationDelivery::Ambiguous,
    });
    assert_eq!(
        app.status_message.as_deref(),
        Some(
            "サーフェスの接続結果を確認できません。入力を再開する前に切断して再接続してください: timeout detail"
        )
    );

    app.apply_pty_operation_failure(PtyOperationFailure {
        session_generation: 1,
        surface_id: Some(1),
        kind: Some(PtyInputKind::Ordered),
        reservation_id: None,
        label: "PTY input",
        error: "write failed".into(),
        lane_failed: false,
        delivery: PtyOperationDelivery::KnownNotDelivered,
    });
    assert_eq!(app.status_message.as_deref(), Some("ターミナル入力に失敗しました: write failed"));

    let destination_mux =
        Mux::new("deferred-destination-failure-locale", SurfaceOptions::default());
    let destination = destination_mux.new_workspace(None, None).unwrap();
    let mut destination_app = test_app(Session::Local(destination_mux));
    destination_app.replace_tree(destination_app.session.tree());
    destination_app.session.pending_mutations.store(1, Ordering::Release);
    destination_app
        .handle(AppEvent::Input(Event::Key(KeyEvent::new(KeyCode::Char('x'), KeyModifiers::NONE))))
        .unwrap();
    destination_app.session.pending_mutations.store(0, Ordering::Release);
    destination_app.replace_tree(notify_tree(destination.id + 1, false));
    destination_app.replay_deferred_input().unwrap();
    assert_eq!(
        destination_app.status_message.as_deref(),
        Some("遅延入力は送信先が変更されたため破棄されました")
    );
}
