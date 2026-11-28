//! Tests: provider workspace policies, new workspace and context menu actions
//! for provider-managed workspaces, and actions that a policy blocks.

use super::*;

/// Draw the app and open the context menu on the "+ new vm" row - the
/// home of the provider scope and action entries now that their rail
/// rows are gone.
fn open_new_vm_context_menu(app: &mut App) {
    app.sync_layout((100, 16));
    let mut terminal = Terminal::new(TestBackend::new(100, 16)).unwrap();
    terminal.draw(|frame| crate::ui::draw(app, frame)).unwrap();
    let rect = app
        .hits
        .iter()
        .find_map(|(rect, hit)| matches!(hit, crate::app::Hit::NewVm).then_some(*rect))
        .expect("new vm row");
    app.open_context_menu(rect.x, rect.y);
}

#[test]
fn provider_scope_switches_from_the_new_vm_context_menu() {
    let mux = Mux::new("provider-scope-keyboard-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.machine_ui = Some(provider_controls_ui());
    open_new_vm_context_menu(&mut app);

    let menu = app.menu.as_ref().expect("new vm context menu");
    assert_eq!(
        menu.levels[0].items.first(),
        Some(&MenuItem::LabeledAction {
            label: "  Personal (personal)".into(),
            action: MenuAction::SelectProviderScope(0),
        })
    );
    // The ACTIVE scope starts selected, so Enter alone changes nothing.
    assert_eq!(
        app.menu.as_ref().and_then(ContextMenu::selected_action),
        Some(MenuAction::SelectProviderScope(1))
    );
    app.handle_menu_key(KeyEvent::new(KeyCode::Up, KeyModifiers::NONE)).unwrap();
    app.handle_menu_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE)).unwrap();
    assert_eq!(
        app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
        Some(&MachineRequest::SelectProviderScope("personal".into()))
    );
    assert!(!app.quit);
}

#[test]
fn provider_actions_and_prompt_are_reachable_from_the_new_vm_menu() {
    let mux = Mux::new("provider-actions-mouse-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.machine_ui = Some(provider_controls_ui());
    open_new_vm_context_menu(&mut app);

    let menu = app.menu.as_ref().expect("new vm context menu");
    let invite = MenuItem::LabeledAction {
        label: "Invite member".into(),
        action: MenuAction::InvokeProviderAction(0),
    };
    let index = menu.levels[0]
        .items
        .iter()
        .position(|item| *item == invite)
        .expect("provider action in the new vm menu");
    let item_x = menu.levels[0].rect.x + 2;
    let item_y = menu.levels[0].rect.y + 1 + index as u16;
    app.handle_left_down(item_x, item_y, KeyModifiers::NONE).unwrap();
    assert_eq!(app.prompt.as_ref().map(|prompt| prompt.label.as_str()), Some("Member email"));

    app.prompt.as_mut().unwrap().input.insert_str("invalid");
    app.commit_prompt();
    assert!(app.prompt.is_some(), "invalid input keeps the editable prompt open");
    assert_eq!(
        app.status_message.as_deref(),
        Some(localization::catalog().sidebar.action_invalid_email)
    );

    let prompt = app.prompt.as_mut().unwrap();
    prompt.input.clear();
    prompt.input.insert_str("person@example.com");
    app.commit_prompt();
    assert_eq!(
        app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
        Some(&MachineRequest::InvokeProviderAction {
            action_id: "invite-member".into(),
            values: BTreeMap::from([(
                "email".into(),
                ProviderActionValue::Text("person@example.com".into())
            )]),
            machine_id: None,
            workspace_id: None,
        })
    );
    assert!(!app.quit);
}

#[test]
fn destructive_workspace_action_binds_context_before_confirmation() {
    let mux = Mux::new("provider-workspace-action-test", SurfaceOptions::default());
    let workspace_key = "00000000-0000-4000-8000-000000000123";
    mux.create_empty_workspace(Some("ports".into()), Some(workspace_key.into()), None).unwrap();
    let mut app = test_app(Session::Local(mux));
    app.replace_tree(app.session.tree());
    let mut ui = provider_controls_ui();
    ui.provider.as_mut().unwrap().actions.push(ProviderActionDescriptor {
        id: "workspace.port.make_public".into(),
        label: "Make workspace port public".into(),
        target: ProviderActionTarget::SelectedWorkspace,
        destructive: true,
        fields: vec![ProviderActionFieldDescriptor {
            id: "port".into(),
            label: "Port".into(),
            kind: ProviderActionFieldKind::Integer,
            required: true,
            max_length: None,
            minimum: Some(1),
            maximum: Some(i64::from(u16::MAX)),
            placeholder: None,
        }],
    });
    ui.set_managed_workspaces(
        MachineKey(41),
        vec![ManagedWorkspaceDescriptor {
            id: workspace_key.into(),
            name: "ports".into(),
            mode: WorkspaceCreationMode::Isolated,
            status: ManagedWorkspaceStatus::Active,
            version: 1,
            recoverable_until: None,
            capabilities: ManagedWorkspaceCapabilities::default(),
        }],
    );
    ui.session_available = true;
    app.machine_ui = Some(ui);

    app.begin_provider_action(2);
    let mut terminal = Terminal::new(TestBackend::new(100, 20)).unwrap();
    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
    let input = app.prompt.as_ref().unwrap().input_rect;
    terminal.backend_mut().assert_cursor_position((input.x, input.y));
    app.prompt.as_mut().unwrap().input.insert_str("3000");
    app.handle_prompt_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE)).unwrap();
    assert!(matches!(
        app.prompt.as_ref().map(|prompt| &prompt.target),
        Some(PromptTarget::ConfirmProviderAction)
    ));
    assert!(
        app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()).is_none(),
        "destructive action must wait for explicit confirmation"
    );

    app.prompt.as_mut().unwrap().input.insert_str("CONFIRM");
    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
    let ok = app.prompt.as_ref().unwrap().ok;
    app.handle_prompt_click(ok.x, ok.y).unwrap();
    assert_eq!(
        app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
        Some(&MachineRequest::InvokeProviderAction {
            action_id: "workspace.port.make_public".into(),
            values: BTreeMap::from([("port".into(), ProviderActionValue::Integer(3_000))]),
            machine_id: Some("managed-41".into()),
            workspace_id: Some(workspace_key.into()),
        })
    );
}

#[test]
fn provider_action_context_excludes_a_client_local_overlay_machine() {
    let mux = Mux::new("provider-action-local-overlay-test", SurfaceOptions::default());
    mux.create_empty_workspace(
        Some("local".into()),
        Some("00000000-0000-4000-8000-000000000123".into()),
        None,
    )
    .unwrap();
    let mut app = test_app(Session::Local(mux));
    app.replace_tree(app.session.tree());
    let mut ui = provider_controls_ui();
    let local_key = MachineKey(crate::machine_runtime::CLIENT_MACHINE_KEY_START);
    ui.snapshot.machines.push(MachineDescriptor {
        key: local_key,
        id: "managed-41".into(),
        name: "Local".into(),
        subtitle: "client local".into(),
        status: MachineStatus::Running,
    });
    ui.snapshot.active = Some(local_key);
    ui.selection = ui.snapshot.active_index().unwrap();
    ui.session_available = true;
    app.machine_ui = Some(ui);

    assert_eq!(app.provider_action_context(), ProviderActionContext::default());
}

#[test]
fn provider_action_context_binds_only_the_active_provider_session_workspace() {
    let mux = Mux::new("provider-action-workspace-ownership-test", SurfaceOptions::default());
    let session_workspace = "00000000-0000-4000-8000-000000000123";
    mux.create_empty_workspace(Some("active".into()), Some(session_workspace.into()), None)
        .unwrap();
    let mut app = test_app(Session::Local(mux));
    app.replace_tree(app.session.tree());
    let mut ui = provider_controls_ui();
    ui.session_available = false;
    app.machine_ui = Some(ui.clone());

    assert_eq!(
        app.provider_action_context(),
        ProviderActionContext { machine_id: Some("managed-41".into()), workspace_id: None }
    );

    ui.session_available = true;
    app.machine_ui = Some(ui);
    assert_eq!(
        app.provider_action_context(),
        ProviderActionContext {
            machine_id: Some("managed-41".into()),
            workspace_id: Some(session_workspace.into()),
        }
    );
}

#[test]
fn provider_snapshot_update_invalidates_stale_menu_and_prompt() {
    let mux = Mux::new("provider-overlay-invalidation-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.machine_ui = Some(provider_controls_ui());
    open_new_vm_context_menu(&mut app);
    assert!(app.menu.as_ref().is_some_and(ContextMenu::targets_provider_state));

    let mut update = provider_controls_ui();
    update.provider.as_mut().unwrap().actions.remove(0);
    app.handle(AppEvent::MachineUiUpdated(Box::new(update))).unwrap();
    assert!(app.menu.is_none(), "a menu cannot retain provider action indexes across updates");

    app.machine_ui = Some(provider_controls_ui());
    app.begin_provider_action(0);
    assert!(matches!(
        app.prompt.as_ref().map(|prompt| &prompt.target),
        Some(PromptTarget::ProviderAction(0))
    ));

    let mut update = provider_controls_ui();
    update.provider.as_mut().unwrap().actions.swap(0, 1);
    app.handle(AppEvent::MachineUiUpdated(Box::new(update))).unwrap();
    assert!(app.prompt.is_none(), "a prompt cannot submit against a reordered action index");
}

#[test]
fn provider_action_menu_resource_blocks_index_retargeting() {
    let mux = Mux::new("provider-action-menu-identity-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.machine_ui = Some(provider_controls_ui());
    open_new_vm_context_menu(&mut app);

    let action = MenuAction::InvokeProviderAction(0);
    assert!(
        matches!(app.menu.as_ref().and_then(|menu| menu.captured_resource(action)), Some(Some(_))),
        "provider actions must capture the stable action behind their displayed index"
    );
    // The combined menu leads with scope entries; move the selection onto
    // the displayed action before the provider array changes.
    for _ in 0..16 {
        if app.menu.as_ref().and_then(ContextMenu::selected_action) == Some(action) {
            break;
        }
        app.handle_menu_key(KeyEvent::new(KeyCode::Down, KeyModifiers::NONE)).unwrap();
    }
    assert_eq!(app.menu.as_ref().and_then(ContextMenu::selected_action), Some(action));

    app.machine_ui.as_mut().unwrap().provider.as_mut().unwrap().actions.swap(0, 1);
    app.handle_menu_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE)).unwrap();

    assert!(
        app.machine_ui.as_ref().unwrap().request.is_none(),
        "the displayed action cannot retarget after the provider array changes"
    );
}

#[test]
fn provider_scope_menu_resource_blocks_index_retargeting() {
    let mux = Mux::new("provider-scope-menu-identity-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.machine_ui = Some(provider_controls_ui());
    open_new_vm_context_menu(&mut app);

    let action = MenuAction::SelectProviderScope(1);
    assert!(
        matches!(app.menu.as_ref().and_then(|menu| menu.captured_resource(action)), Some(Some(_))),
        "provider scopes must capture the stable scope behind their displayed index"
    );

    app.machine_ui.as_mut().unwrap().provider.as_mut().unwrap().scopes.swap(0, 1);
    app.handle_menu_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE)).unwrap();

    assert!(
        app.machine_ui.as_ref().unwrap().request.is_none(),
        "the displayed scope cannot retarget after the provider array changes"
    );
}

#[test]
fn recoverable_workspace_menu_resource_blocks_index_retargeting() {
    let mux = Mux::new("recoverable-workspace-menu-identity-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    let mut ui = provider_machine_ui_with_lifecycle();
    let mut workspaces = ui.managed_workspaces().to_vec();
    workspaces.push(ManagedWorkspaceDescriptor {
        id: "00000000-0000-4000-8000-000000000100".into(),
        name: "second-recoverable".into(),
        mode: WorkspaceCreationMode::Host,
        status: ManagedWorkspaceStatus::Recoverable,
        version: 13,
        recoverable_until: Some("2030-01-03T03:04:05Z".into()),
        capabilities: ManagedWorkspaceCapabilities {
            rename: false,
            delete: false,
            restore: true,
            purge: true,
        },
    });
    ui.set_managed_workspaces(MachineKey(41), workspaces.clone());
    app.machine_ui = Some(ui);
    app.sidebar_view = SidebarView::Workspaces;
    app.sidebar_width = 20;
    app.hits.push((
        Rect { x: 2, y: 2, width: 8, height: 1 },
        crate::app::Hit::RecoverableWorkspace { index: 0 },
    ));
    app.open_context_menu(2, 2);

    let action = MenuAction::RestoreManagedWorkspace(0);
    assert!(
        matches!(app.menu.as_ref().and_then(|menu| menu.captured_resource(action)), Some(Some(_))),
        "recoverable workspaces must capture the stable workspace behind their displayed index"
    );

    workspaces.swap(1, 2);
    app.machine_ui.as_mut().unwrap().set_managed_workspaces(MachineKey(41), workspaces);
    app.handle_menu_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE)).unwrap();

    assert!(
        app.machine_ui.as_ref().unwrap().request.is_none(),
        "the displayed workspace cannot retarget after the recoverable array changes"
    );
}

#[test]
fn unavailable_zero_machine_state_skips_initial_workspace_and_renders_both_rails() {
    let mux = Mux::new("provider-zero-state-test", SurfaceOptions::default());
    let unavailable = MachineUiState::new(MachineSnapshot {
        machines: Vec::new(),
        active: None,
        capabilities: MachineCapabilities { create: true, connect: true },
    });
    crate::app::ensure_initial_for_machine_ui(
        &Session::Local(mux.clone()),
        Some((40, 12)),
        Some(&unavailable),
    )
    .unwrap();
    assert!(Session::Local(mux.clone()).tree().workspaces().is_empty());

    let mut app = test_app(Session::Local(mux));
    app.sidebar_view = SidebarView::Workspaces;
    app.machine_ui = Some(MachineUiState::new(MachineSnapshot {
        machines: Vec::new(),
        active: None,
        capabilities: MachineCapabilities { create: true, connect: true },
    }));
    app.sync_layout((100, 16));
    assert!(app.sidebar_layout.machine.is_some());
    assert!(app.sidebar_layout.workspace.is_some());
    assert!(!app.session_available());

    let mut terminal = Terminal::new(TestBackend::new(100, 16)).unwrap();
    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
    let text = buffer_text(terminal.backend().buffer());
    assert!(text.contains("no machines"), "{text}");
    assert!(text.contains("+ new vm"), "{text}");
    assert!(text.contains("+ ssh host"), "{text}");
    assert!(!text.contains("+ +"), "the renderer owns the plus prefix: {text}");
    assert!(
        !app.hits.iter().any(|(_, hit)| { matches!(hit, crate::app::Hit::CreateWorkspace { .. }) })
    );

    app.focus = FocusTarget::MachineRail;
    app.handle_key(KeyEvent::new(KeyCode::End, KeyModifiers::NONE)).unwrap();
    app.handle_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE)).unwrap();
    assert!(app.machine_ui.as_ref().is_some_and(|ui| ui.request.is_none()));
    assert!(app.prompt.is_some(), "connect machine is keyboard reachable");
    assert_eq!(
        app.prompt.as_ref().map(|prompt| prompt.label.as_str()),
        Some(localization::catalog().sidebar.connect_host_prompt)
    );
    app.prompt = None;
    app.handle_key(KeyEvent::new(KeyCode::Right, KeyModifiers::NONE)).unwrap();
    assert_eq!(app.focus, FocusTarget::WorkspaceRail);
}

#[test]
fn machine_ui_survives_initial_pty_exhaustion_with_an_actionable_status() {
    let machine_ui = provider_machine_ui();
    let failure = anyhow::anyhow!(
        "remote command rejected: failed to open PTY: Device not configured (os error 6)"
    );

    let status = crate::app::recover_initial_workspace_failure(Err(failure), Some(&machine_ui))
        .unwrap()
        .expect("machine mode keeps the launch failure as status");
    assert_eq!(status, localization::catalog().runtime.terminal_capacity_exhausted);

    let plain_failure = anyhow::anyhow!("failed to open PTY: Device not configured");
    assert!(
        crate::app::recover_initial_workspace_failure(Err(plain_failure), None).is_err(),
        "plain mode must still fail before switching the host terminal into raw mode"
    );
}

#[test]
fn connect_machine_footer_captures_the_route_shown_by_each_entrypoint() {
    let mux = Mux::new("connect-machine-footer-input-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.sidebar_view = SidebarView::Workspaces;
    app.machine_ui = Some(provider_machine_ui());
    app.sync_layout((100, 16));
    let mut terminal = Terminal::new(TestBackend::new(100, 16)).unwrap();
    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();

    let connect = app
        .hits
        .iter()
        .find_map(|(rect, hit)| {
            matches!(hit, crate::app::Hit::ConnectMachine).then_some((rect.x, rect.y))
        })
        .unwrap();
    app.handle_left_down(connect.0, connect.1, KeyModifiers::NONE).unwrap();
    assert_eq!(
        app.prompt.as_ref().map(|prompt| prompt.label.as_str()),
        Some(localization::catalog().sidebar.connect_prompt)
    );
    app.prompt.as_mut().unwrap().input.insert_str("PAIR 4J7K");
    let mut update = app.machine_ui.clone().unwrap();
    update.connect_accepts_pairing_code = false;
    app.apply_machine_ui_update(update);
    app.commit_prompt();
    assert!(app.prompt.is_some(), "connection prompt must become a loading dialog");
    assert_eq!(
        app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
        Some(&MachineRequest::Connect {
            target: "PAIR 4J7K".into(),
            route: MachineConnectRoute::Provider,
        })
    );
    app.close_prompt();

    let machine = app.machine_ui.as_mut().unwrap();
    machine.request = None;
    machine.connect_accepts_pairing_code = false;
    app.focus = FocusTarget::MachineRail;
    app.handle_key(KeyEvent::new(KeyCode::End, KeyModifiers::NONE)).unwrap();
    app.handle_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE)).unwrap();
    assert_eq!(
        app.prompt.as_ref().map(|prompt| prompt.label.as_str()),
        Some(localization::catalog().sidebar.connect_host_prompt)
    );
    app.prompt.as_mut().unwrap().input.insert_str("mini.local");
    let mut update = app.machine_ui.clone().unwrap();
    update.connect_accepts_pairing_code = true;
    app.apply_machine_ui_update(update);
    app.commit_prompt();
    assert!(app.prompt.is_some(), "connection prompt must become a loading dialog");
    assert_eq!(
        app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
        Some(&MachineRequest::Connect {
            target: "mini.local".into(),
            route: MachineConnectRoute::Local,
        })
    );
}

#[test]
fn stale_connection_completion_cannot_settle_a_retry_to_the_same_host() {
    let mux = Mux::new("connection-attempt-correlation-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    let request =
        MachineRequest::Connect { target: "mini.local".into(), route: MachineConnectRoute::Local };
    app.connection_transaction = Some(crate::app::ConnectionTransaction {
        attempt: 2,
        target: "mini.local".into(),
        route: MachineConnectRoute::Local,
        phase: crate::app::ConnectionDialogPhase::Connecting,
    });

    app.report_machine_action_failure(Some(&request), Some(1), "old failure".into());
    assert_eq!(
        app.connection_transaction.as_ref().map(|transaction| &transaction.phase),
        Some(&crate::app::ConnectionDialogPhase::Connecting)
    );
    assert!(app.status_message.is_none());

    app.report_machine_action_failure(Some(&request), Some(2), "current failure".into());
    assert!(matches!(
        app.connection_transaction.as_ref().map(|transaction| &transaction.phase),
        Some(crate::app::ConnectionDialogPhase::Failed(error)) if error == "current failure"
    ));
    assert_eq!(app.status_message.as_deref(), Some("current failure"));
}

#[test]
fn connection_dialog_renders_loading_error_retry_and_copy_states() {
    let mux = Mux::new("connection-dialog-state-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.machine_ui = Some(provider_machine_ui());
    app.begin_machine_connection("mini.local".into(), MachineConnectRoute::Local);
    app.sync_layout((100, 24));
    let mut terminal = Terminal::new(TestBackend::new(100, 24)).unwrap();

    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
    let rendered = buffer_text(terminal.backend().buffer());
    assert!(rendered.contains("Connecting to mini.local"), "{rendered}");

    let request =
        MachineRequest::Connect { target: "mini.local".into(), route: MachineConnectRoute::Local };
    let attempt = app.connection_transaction.as_ref().unwrap().attempt;
    app.fail_connection_transaction(
        Some(&request),
        Some(attempt),
        "permission denied by remote host".into(),
    );
    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
    let rendered = buffer_text(terminal.backend().buffer());
    assert!(rendered.contains("Could not connect to mini.local"), "{rendered}");
    assert!(rendered.contains("permission denied by remote host"), "{rendered}");
    assert!(rendered.contains("Retry"), "{rendered}");
    assert!(rendered.contains("Copy message"), "{rendered}");
    let prompt = app.prompt.as_ref().unwrap();
    assert!(prompt.ok.width > 0);
    assert!(prompt.clear.width > 0);
}

#[test]
fn closing_connection_dialog_removes_the_queued_connect_request() {
    let mux = Mux::new("connection-dialog-queued-cancel-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.machine_ui = Some(provider_machine_ui());
    app.begin_machine_connection("mini.local".into(), MachineConnectRoute::Local);

    app.close_prompt();

    assert!(app.prompt.is_none());
    assert!(app.connection_transaction.is_none());
    assert!(app.machine_ui.as_ref().is_some_and(|ui| ui.request.is_none()));
    assert!(!app.machine_action_in_flight);
}

#[test]
fn provider_owned_workspace_policy_never_creates_an_untracked_session_workspace() {
    let mux = Mux::new("provider-owned-initial-workspace-test", SurfaceOptions::default());
    let mut ui = provider_machine_ui();
    ui.session_available = true;
    crate::app::ensure_initial_for_machine_ui(
        &Session::Local(mux.clone()),
        Some((40, 12)),
        Some(&ui),
    )
    .unwrap();
    assert!(Session::Local(mux).tree().workspaces().is_empty());
}

#[test]
fn unavailable_placeholder_blocks_session_mutations() {
    let mux = Mux::new("provider-mutation-guard-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux.clone()));
    app.machine_ui = Some(MachineUiState::new(MachineSnapshot {
        machines: Vec::new(),
        active: None,
        capabilities: MachineCapabilities::default(),
    }));

    app.run_action(Action::NewScreen).unwrap();

    assert!(Session::Local(mux).tree().workspaces().is_empty());
    assert_eq!(
        app.status_message.as_deref(),
        Some(localization::catalog().sidebar.no_active_session)
    );
}

#[test]
fn provider_workspace_keyboard_action_requests_isolated_workspace() {
    let mux = Mux::new("provider-workspace-key-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux.clone()));
    app.machine_ui = Some(provider_machine_ui());

    app.run_action(Action::NewWorkspace).unwrap();

    assert!(matches!(
        app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
        Some(MachineRequest::CreateManagedIsolatedWorkspace(MachineKey(41)))
    ));
    assert!(!app.quit);
    assert!(Session::Local(mux).tree().workspaces().is_empty());
}

#[test]
fn provider_workspace_footer_exposes_isolated_and_shared_mouse_actions() {
    let mux = Mux::new("provider-workspace-mouse-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.sidebar_view = SidebarView::Workspaces;
    app.machine_ui = Some(provider_machine_ui());
    app.sync_layout((100, 16));

    let mut terminal = Terminal::new(TestBackend::new(100, 16)).unwrap();
    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
    let text = buffer_text(terminal.backend().buffer());
    assert!(text.contains("new isolated"), "{text}");
    assert!(text.contains("new shared"), "{text}");
    let isolated = app
        .hits
        .iter()
        .find_map(|(rect, hit)| {
            matches!(
                hit,
                crate::app::Hit::CreateWorkspace { mode: Some(WorkspaceCreationMode::Isolated) }
            )
            .then_some(*rect)
        })
        .expect("isolated workspace action hit");
    let shared = app
        .hits
        .iter()
        .find_map(|(rect, hit)| {
            matches!(
                hit,
                crate::app::Hit::CreateWorkspace { mode: Some(WorkspaceCreationMode::Host) }
            )
            .then_some(*rect)
        })
        .expect("shared workspace action hit");

    app.handle_left_down(isolated.x, isolated.y, KeyModifiers::NONE).unwrap();
    assert!(matches!(
        app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
        Some(MachineRequest::CreateManagedIsolatedWorkspace(MachineKey(41)))
    ));

    app.quit = false;
    app.machine_ui.as_mut().unwrap().request = None;
    app.handle_left_down(shared.x, shared.y, KeyModifiers::NONE).unwrap();
    assert!(matches!(
        app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
        Some(MachineRequest::CreateManagedHostWorkspace(MachineKey(41)))
    ));
    assert!(!app.quit);
}

#[test]
fn provider_workspace_subset_and_default_drive_footer_and_new_workspace_action() {
    let mux = Mux::new("provider-workspace-subset-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.sidebar_view = SidebarView::Workspaces;
    app.machine_ui = Some(provider_machine_ui_with_policy(
        WorkspaceCreationMode::Host,
        vec![WorkspaceCreationMode::Host],
    ));
    app.sync_layout((100, 12));

    let mut terminal = Terminal::new(TestBackend::new(100, 12)).unwrap();
    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
    let text = buffer_text(terminal.backend().buffer());
    assert!(text.contains("new shared"), "{text}");
    assert!(!text.contains("new isolated"), "{text}");

    app.run_action(Action::NewWorkspace).unwrap();
    assert_eq!(
        app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
        Some(&MachineRequest::CreateManagedHostWorkspace(MachineKey(41)))
    );
}

#[test]
fn provider_workspace_default_is_independent_of_advertised_mode_order() {
    let mux = Mux::new("provider-workspace-default-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.sidebar_view = SidebarView::Workspaces;
    app.machine_ui = Some(provider_machine_ui_with_policy(
        WorkspaceCreationMode::Isolated,
        vec![WorkspaceCreationMode::Host, WorkspaceCreationMode::Isolated],
    ));
    app.sync_layout((100, 12));

    let mut terminal = Terminal::new(TestBackend::new(100, 12)).unwrap();
    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
    let host_y = app
        .hits
        .iter()
        .find_map(|(rect, hit)| {
            matches!(
                hit,
                crate::app::Hit::CreateWorkspace { mode: Some(WorkspaceCreationMode::Host) }
            )
            .then_some(rect.y)
        })
        .unwrap();
    let isolated_y = app
        .hits
        .iter()
        .find_map(|(rect, hit)| {
            matches!(
                hit,
                crate::app::Hit::CreateWorkspace { mode: Some(WorkspaceCreationMode::Isolated) }
            )
            .then_some(rect.y)
        })
        .unwrap();
    assert!(host_y < isolated_y, "provider mode order must be preserved");

    app.run_action(Action::NewWorkspace).unwrap();
    assert_eq!(
        app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
        Some(&MachineRequest::CreateManagedIsolatedWorkspace(MachineKey(41)))
    );
}

#[test]
fn keyboard_traverses_machine_controls_catalog_and_pinned_actions() {
    let mux = Mux::new("machine-rail-keyboard-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.machine_ui = Some(provider_controls_ui());
    app.focus = FocusTarget::MachineRail;
    app.sync_layout((100, 9));

    app.handle_key(KeyEvent::new(KeyCode::Home, KeyModifiers::NONE)).unwrap();
    assert!(matches!(
        app.machine_ui.as_ref().and_then(MachineUiState::rail_target),
        Some(crate::machine::MachineRailTarget::Machine(_))
    ));
    app.handle_key(KeyEvent::new(KeyCode::Down, KeyModifiers::NONE)).unwrap();
    assert_eq!(
        app.machine_ui.as_ref().and_then(MachineUiState::rail_target),
        Some(crate::machine::MachineRailTarget::NewVm)
    );
    app.handle_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE)).unwrap();
    assert_eq!(
        app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
        Some(&MachineRequest::Create)
    );

    app.machine_ui.as_mut().unwrap().request = None;
    app.handle_key(KeyEvent::new(KeyCode::End, KeyModifiers::NONE)).unwrap();
    app.handle_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE)).unwrap();
    assert_eq!(
        app.machine_ui.as_ref().and_then(MachineUiState::rail_target),
        Some(crate::machine::MachineRailTarget::ConnectMachine)
    );
    assert!(app.prompt.is_some());
}

#[test]
fn new_machine_opens_native_source_picker_and_routes_stable_source_id() {
    let mux = Mux::new("machine-source-picker-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    let mut ui = MachineUiState::new(MachineSnapshot {
        machines: vec![MachineDescriptor {
            key: MachineKey(1),
            id: "current".into(),
            name: "local".into(),
            subtitle: "local".into(),
            status: MachineStatus::Running,
        }],
        active: Some(MachineKey(1)),
        capabilities: MachineCapabilities { create: true, connect: false },
    });
    ui.creation_sources = vec![
        MachineCreationSource {
            id: "docker".into(),
            name: "Docker".into(),
            subtitle: "container prototype".into(),
        },
        MachineCreationSource {
            id: "firecracker".into(),
            name: "Firecracker".into(),
            subtitle: "microVM prototype".into(),
        },
    ];
    ui.rail_selection = MachineRailSelection::NewVm;
    app.machine_ui = Some(ui);
    app.focus = FocusTarget::MachineRail;
    app.sync_layout((100, 12));

    app.handle_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE)).unwrap();
    assert!(app.menu.is_some());
    app.handle_menu_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE)).unwrap();
    assert_eq!(
        app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
        Some(&MachineRequest::CreateFrom { source_id: "docker".into() })
    );
}

#[test]
fn keyboard_traverses_every_advertised_workspace_creation_mode() {
    let mux = Mux::new("workspace-rail-keyboard-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.sidebar_view = SidebarView::Workspaces;
    app.machine_ui = Some(provider_machine_ui_with_policy(
        WorkspaceCreationMode::Isolated,
        vec![WorkspaceCreationMode::Host, WorkspaceCreationMode::Isolated],
    ));
    app.focus = FocusTarget::WorkspaceRail;
    app.sync_layout((100, 6));

    app.handle_key(KeyEvent::new(KeyCode::Home, KeyModifiers::NONE)).unwrap();
    assert_eq!(
        app.workspace_rail_selection,
        workspace_creation_selection(Some(WorkspaceCreationMode::Host))
    );
    app.handle_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE)).unwrap();
    assert_eq!(
        app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
        Some(&MachineRequest::CreateManagedHostWorkspace(MachineKey(41)))
    );

    app.machine_ui.as_mut().unwrap().request = None;
    app.handle_key(KeyEvent::new(KeyCode::Down, KeyModifiers::NONE)).unwrap();
    assert_eq!(
        app.workspace_rail_selection,
        workspace_creation_selection(Some(WorkspaceCreationMode::Isolated))
    );
    app.handle_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE)).unwrap();
    assert_eq!(
        app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
        Some(&MachineRequest::CreateManagedIsolatedWorkspace(MachineKey(41)))
    );
}

#[test]
fn short_terminal_keeps_both_rails_footer_actions_clickable() {
    let mux = Mux::new("short-rail-footer-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.sidebar_view = SidebarView::Workspaces;
    app.machine_ui = Some(provider_machine_ui());
    app.sync_layout((100, 5));

    let mut terminal = Terminal::new(TestBackend::new(100, 5)).unwrap();
    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();

    assert!(app.hits.iter().any(|(_, hit)| matches!(hit, crate::app::Hit::NewVm)));
    assert!(app.hits.iter().any(|(_, hit)| matches!(hit, crate::app::Hit::ConnectMachine)));
    assert!(app.hits.iter().any(|(_, hit)| {
        matches!(
            hit,
            crate::app::Hit::CreateWorkspace { mode: Some(WorkspaceCreationMode::Isolated) }
        )
    }));
    assert!(app.hits.iter().any(|(_, hit)| {
        matches!(hit, crate::app::Hit::CreateWorkspace { mode: Some(WorkspaceCreationMode::Host) })
    }));
}

#[test]
fn alt_directional_focus_traverses_sidebar_at_the_pane_boundary() {
    let (mux, surface) = test_mux("alt-sidebar-boundary-test", None);
    let mut app = test_app(Session::Local(mux.clone()));
    let mut machine_ui = provider_machine_ui();
    machine_ui.session_available = true;
    app.machine_ui = Some(machine_ui);
    app.sidebar_view = SidebarView::Workspaces;
    app.replace_tree(app.session.tree());
    app.sync_layout((100, 16));

    app.handle_key(KeyEvent::new(KeyCode::Left, KeyModifiers::ALT)).unwrap();
    assert_eq!(app.focus, FocusTarget::WorkspaceRail);

    app.handle_key(KeyEvent::new(KeyCode::Char('h'), KeyModifiers::ALT)).unwrap();
    assert_eq!(app.focus, FocusTarget::MachineRail);
    app.handle_key(KeyEvent::new(KeyCode::Char('l'), KeyModifiers::ALT)).unwrap();
    assert_eq!(app.focus, FocusTarget::WorkspaceRail);

    app.handle_key(KeyEvent::new(KeyCode::Right, KeyModifiers::ALT)).unwrap();
    assert_eq!(app.focus, FocusTarget::Pane);

    app.sidebar_view = SidebarView::Files;
    app.focus = FocusTarget::WorkspaceRail;
    app.handle_key(KeyEvent::new(KeyCode::Right, KeyModifiers::ALT)).unwrap();
    assert_eq!(app.focus, FocusTarget::Pane);

    mux.close_surface(surface.id).unwrap();
}

#[test]
fn sidebar_top_pads_are_the_only_pointer_entrypoint_for_rail_focus() {
    let (mux, surface) = test_mux("sidebar-pointer-focus-test", None);
    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    let mut machine_ui = provider_machine_ui();
    machine_ui.session_available = true;
    app.machine_ui = Some(machine_ui);
    app.sidebar_view = SidebarView::Workspaces;
    app.replace_tree(app.session.tree());
    app.sync_layout((100, 16));

    let mut terminal = Terminal::new(TestBackend::new(100, 16)).unwrap();
    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
    let machine_row = app
        .hits
        .iter()
        .find_map(|(rect, hit)| matches!(hit, crate::app::Hit::Machine { .. }).then_some(*rect))
        .unwrap();
    let workspace_row = app
        .hits
        .iter()
        .find_map(|(rect, hit)| matches!(hit, crate::app::Hit::Workspace { .. }).then_some(*rect))
        .unwrap();
    let machine_area = app.sidebar_layout.machine.unwrap();
    let workspace_area = app.sidebar_layout.workspace.unwrap();

    app.focus = FocusTarget::WorkspaceRail;
    app.handle_left_down(workspace_row.x, workspace_row.y, KeyModifiers::NONE).unwrap();
    app.handle_left_up(workspace_row.x, workspace_row.y).unwrap();
    assert_eq!(app.focus, FocusTarget::Pane);
    while app.session.has_pending_mutations() {
        app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
    }

    app.handle_left_down(workspace_area.x + 1, workspace_area.y, KeyModifiers::NONE).unwrap();
    app.handle_left_up(workspace_area.x + 1, workspace_area.y).unwrap();
    assert_eq!(app.focus, FocusTarget::WorkspaceRail);

    app.handle_left_down(machine_row.x, machine_row.y, KeyModifiers::NONE).unwrap();
    app.handle_left_up(machine_row.x, machine_row.y).unwrap();
    assert_eq!(app.focus, FocusTarget::Pane);

    app.handle_left_down(machine_area.x + 1, machine_area.y, KeyModifiers::NONE).unwrap();
    app.handle_left_up(machine_area.x + 1, machine_area.y).unwrap();
    assert_eq!(app.focus, FocusTarget::MachineRail);

    mux.close_surface(surface.id).unwrap();
}

#[test]
fn mouse_drag_resizes_machine_and_workspace_rails_independently() {
    let mux = Mux::new("rail-mouse-resize-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.sidebar_view = SidebarView::Workspaces;
    app.machine_ui = Some(provider_machine_ui());
    app.sync_layout((100, 12));

    let mut terminal = Terminal::new(TestBackend::new(100, 12)).unwrap();
    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
    let divider = |app: &App, kind| {
        app.hits
            .iter()
            .find_map(|(rect, hit)| (*hit == crate::app::Hit::RailResize(kind)).then_some(*rect))
            .unwrap()
    };

    for kind in [RailKind::Machine, RailKind::Workspace] {
        let rect = divider(&app, kind);
        let target_x = rect.x + 3;
        let expected = rail_drag_width(&app.config, &app.sidebar_layout, kind, target_x).unwrap();
        app.handle_mouse(MouseEvent {
            kind: MouseEventKind::Down(MouseButton::Left),
            column: rect.x,
            row: rect.y + 1,
            modifiers: KeyModifiers::NONE,
        })
        .unwrap();
        app.handle_mouse(MouseEvent {
            kind: MouseEventKind::Drag(MouseButton::Left),
            column: target_x,
            row: rect.y + 1,
            modifiers: KeyModifiers::NONE,
        })
        .unwrap();
        app.handle_mouse(MouseEvent {
            kind: MouseEventKind::Up(MouseButton::Left),
            column: target_x,
            row: rect.y + 1,
            modifiers: KeyModifiers::NONE,
        })
        .unwrap();

        match kind {
            RailKind::Machine => {
                assert_eq!(app.machine_sidebar_width_override, Some(expected));
                assert_eq!(app.sidebar_width_override, None);
            }
            RailKind::Workspace => {
                assert_eq!(app.sidebar_width_override, Some(expected));
            }
            RailKind::Tabs => unreachable!("tabs rail is not configured in this test"),
            RailKind::Projection(_) => {
                unreachable!("projection rail is not configured in this test")
            }
        }
    }
}

#[test]
fn mouse_wheel_scrolls_machine_and_workspace_rail_viewports_independently() {
    let mux = Mux::new("rail-wheel-test", SurfaceOptions::default());
    for index in 0..6 {
        mux.new_workspace(Some(format!("workspace-{index}")), None).unwrap();
    }
    let mut app = test_app(Session::Local(mux));
    app.sidebar_view = SidebarView::Workspaces;
    app.replace_tree(app.session.tree());
    let machines = (0..6)
        .map(|index| MachineDescriptor {
            key: MachineKey(index + 1),
            id: format!("machine-{index}"),
            name: format!("machine-{index}"),
            subtitle: "cloud".into(),
            status: MachineStatus::Running,
        })
        .collect();
    app.machine_ui = Some(MachineUiState::new(MachineSnapshot {
        machines,
        active: Some(MachineKey(1)),
        capabilities: MachineCapabilities { create: true, connect: true },
    }));
    app.sync_layout((100, 10));

    let mut terminal = Terminal::new(TestBackend::new(100, 10)).unwrap();
    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
    let first_machine = app.hits.iter().find_map(|(_, hit)| match hit {
        crate::app::Hit::Machine { key, .. } => Some(*key),
        _ => None,
    });
    let first_workspace = app.hits.iter().find_map(|(_, hit)| match hit {
        crate::app::Hit::Workspace { id, .. } => Some(*id),
        _ => None,
    });
    let machine_area = app.sidebar_layout.machine.unwrap();
    let workspace_area = app.sidebar_layout.workspace.unwrap();

    app.focus = FocusTarget::MachineRail;
    app.handle_scroll(machine_area.x + 1, machine_area.y + 2, true, KeyModifiers::NONE).unwrap();
    app.focus = FocusTarget::WorkspaceRail;
    app.handle_scroll(workspace_area.x + 1, workspace_area.y + 2, true, KeyModifiers::NONE)
        .unwrap();
    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();

    let scrolled_machine = app.hits.iter().find_map(|(_, hit)| match hit {
        crate::app::Hit::Machine { key, .. } => Some(*key),
        _ => None,
    });
    let scrolled_workspace = app.hits.iter().find_map(|(_, hit)| match hit {
        crate::app::Hit::Workspace { id, .. } => Some(*id),
        _ => None,
    });
    assert_ne!(scrolled_machine, first_machine);
    assert_ne!(scrolled_workspace, first_workspace);
    assert!(app.machine_rail_scroll > 0);
    assert!(app.workspace_rail_scroll > 0);
}

#[test]
fn workspace_rail_scrollbar_is_visible_clickable_and_draggable() {
    let mux = Mux::new("workspace-rail-scrollbar-test", SurfaceOptions::default());
    for index in 0..6 {
        mux.new_workspace(Some(format!("workspace-{index}")), None).unwrap();
    }
    let mut app = test_app(Session::Local(mux));
    app.sidebar_view = SidebarView::Workspaces;
    app.replace_tree(app.session.tree());
    app.sync_layout((80, 10));

    let mut terminal = Terminal::new(TestBackend::new(80, 10)).unwrap();
    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
    let (track, total_rows, visible_rows) = app
        .hits
        .iter()
        .find_map(|(_, hit)| match hit {
            crate::app::Hit::WorkspaceScrollbar { track, total_rows, visible_rows } => {
                Some((*track, *total_rows, *visible_rows))
            }
            _ => None,
        })
        .unwrap();
    let divider = app
        .hits
        .iter()
        .find_map(|(rect, hit)| {
            (*hit == crate::app::Hit::RailResize(RailKind::Workspace)).then_some(*rect)
        })
        .unwrap();
    let (thumb_y, _) = crate::ui::viewport_thumb_geometry(
        total_rows,
        visible_rows,
        app.workspace_rail_scroll,
        track.height,
    );
    assert_eq!(track.x + 1, divider.x);
    assert_eq!(terminal.backend().buffer()[(track.x, track.y + thumb_y)].symbol(), "▕");

    app.handle_mouse(MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Left),
        column: track.x,
        row: track.y + track.height - 1,
        modifiers: KeyModifiers::NONE,
    })
    .unwrap();
    let jumped = app.workspace_rail_scroll;
    assert!(jumped > 0);
    assert!(!app.workspace_rail_follow_selection);
    assert_eq!(app.focus, FocusTarget::Pane);

    app.handle_mouse(MouseEvent {
        kind: MouseEventKind::Drag(MouseButton::Left),
        column: track.x,
        row: track.y,
        modifiers: KeyModifiers::NONE,
    })
    .unwrap();
    assert!(app.workspace_rail_scroll < jumped);
    app.handle_mouse(MouseEvent {
        kind: MouseEventKind::Up(MouseButton::Left),
        column: track.x,
        row: track.y,
        modifiers: KeyModifiers::NONE,
    })
    .unwrap();
}

#[test]
fn workspace_rail_hides_scrollbar_when_every_row_fits() {
    let mux = Mux::new("workspace-rail-no-scrollbar-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.sidebar_view = SidebarView::Workspaces;
    app.replace_tree(app.session.tree());
    app.sync_layout((80, 30));

    let mut terminal = Terminal::new(TestBackend::new(80, 30)).unwrap();
    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();

    assert!(
        !app.hits.iter().any(|(_, hit)| matches!(hit, crate::app::Hit::WorkspaceScrollbar { .. }))
    );
    let divider = app
        .hits
        .iter()
        .find_map(|(rect, hit)| {
            (*hit == crate::app::Hit::RailResize(RailKind::Workspace)).then_some(*rect)
        })
        .unwrap();
    let scrollbar_x = divider.x - 1;
    assert!(
        (1..29)
            .all(|y| !matches!(terminal.backend().buffer()[(scrollbar_x, y)].symbol(), "▕" | "▐"))
    );
}

#[test]
fn tabs_column_renders_selected_workspace_tabs_and_activates_through_native_focus() {
    let (mux, first) = test_mux("tabs-column-test", None);
    let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let second = mux.new_tab(Some(pane), None, Some((80, 24))).unwrap();
    let mut app = test_app(Session::Local(mux.clone()));
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
    assert!(app.sidebar_layout.tabs.is_some());
    assert_eq!(app.sidebar_tab_targets().len(), 2);
    assert!(app.hits.iter().any(|(_, hit)| {
        matches!(hit, crate::app::Hit::SidebarTab { surface, .. } if *surface == first.id)
    }));

    let first_row = app
        .hits
        .iter()
        .find_map(|(rect, hit)| {
            matches!(hit, crate::app::Hit::SidebarTab { surface, .. } if *surface == first.id)
                .then_some(*rect)
        })
        .unwrap();
    app.handle_left_down(first_row.x, first_row.y, KeyModifiers::NONE).unwrap();
    assert_eq!(app.tree.active_surface(), Some(first.id));
    assert_eq!(app.focus, FocusTarget::Pane);

    app.focus = FocusTarget::WorkspaceRail;
    app.handle_key(KeyEvent::new(KeyCode::Right, KeyModifiers::NONE)).unwrap();
    assert_eq!(app.focus, FocusTarget::TabsRail);
    app.tabs_rail_selection = 0;
    app.handle_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE)).unwrap();
    assert_eq!(app.tree.active_surface(), Some(first.id));
    assert_eq!(app.focus, FocusTarget::Pane);

    for surface in [first.id, second.id] {
        mux.close_surface(surface).unwrap();
    }
}

#[test]
fn projection_workspace_row_activates_on_mouse_down() {
    let mux = Mux::new("projection-workspace-mouse-down-test", SurfaceOptions::default());
    let first = mux.new_workspace(Some("Alpha".into()), Some((80, 24))).unwrap();
    let second = mux.new_workspace(Some("Beta".into()), Some((80, 24))).unwrap();
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

    let mut terminal = Terminal::new(TestBackend::new(100, 20)).unwrap();
    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
    assert_eq!(app.tree.active_workspace, 1);
    let first_row = app
        .hits
        .iter()
        .find_map(|(rect, hit)| {
            matches!(
                hit,
                crate::app::Hit::ProjectionRow {
                    target: crate::sidebar_projection::ProjectionTarget::Workspace { index: 0, .. },
                    ..
                }
            )
            .then_some(*rect)
        })
        .unwrap();

    app.handle_left_down(first_row.x, first_row.y, KeyModifiers::NONE).unwrap();

    assert_eq!(app.tree.active_workspace, 0);
    assert_eq!(app.focus, FocusTarget::Pane);

    for surface in [first.id, second.id] {
        mux.close_surface(surface).unwrap();
    }
}
