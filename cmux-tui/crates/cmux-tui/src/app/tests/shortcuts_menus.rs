//! Tests: prefix keys, shortcut help, context menu contents and actions,
//! splits and tabs from menus, and the status line.

use super::*;

#[test]
fn every_context_menu_exposes_sidebar_visibility() {
    let (mux, _) = test_mux("global-sidebar-context-menu-test", None);
    let mut app = test_app(Session::Local(mux.clone()));
    app.sidebar_visible = false;
    app.replace_tree(app.session.tree());
    app.sync_layout((80, 20));
    let content = app.pane_areas[0].content;

    for point in [(content.x, content.y), (79, 19)] {
        app.open_context_menu(point.0, point.1);
        assert!(
            app.menu.as_ref().is_some_and(|menu| {
                menu.levels[0]
                    .items
                    .iter()
                    .any(|item| item.action() == Some(MenuAction::ToggleSidebar { visible: false }))
            }),
            "right-click at {point:?} must offer Show Sidebar"
        );
    }

    let surfaces = mux.with_state(|state| state.surfaces.keys().copied().collect::<Vec<_>>());
    for surface in surfaces {
        mux.close_surface(surface).unwrap();
    }
}

#[test]
fn prefix_pane_shortcuts_create_and_resize_without_alt() {
    let (mux, _) = test_mux("prefix-pane-shortcuts-test", None);
    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    app.sidebar_visible = false;
    app.config
        .keys
        .apply_for_test(&HashMap::from([("alt_shortcuts".to_string(), serde_json::json!(false))]));
    app.replace_tree(app.session.tree());
    app.sync_layout((120, 30));

    // Exercise legacy character reports and enhanced Shift+base-key reports.
    let sequences = [
        (KeyEvent::new(KeyCode::Char('N'), KeyModifiers::NONE), 2),
        (KeyEvent::new(KeyCode::Char('n'), KeyModifiers::SHIFT), 3),
    ];
    for (key, pane_count) in sequences {
        app.handle_key(KeyEvent::new(KeyCode::Char('b'), KeyModifiers::CONTROL)).unwrap();
        app.handle_key(key).unwrap();
        while app.session.has_pending_mutations() {
            app.handle(events.recv_timeout(Duration::from_secs(5)).unwrap()).unwrap();
        }
        assert!(!app.prefix_armed);
        assert_eq!(app.tree.active_screen().unwrap().panes.len(), pane_count);
    }

    app.sync_layout((120, 30));
    let pane = app.active_pane().unwrap();
    for grow_key in [
        KeyEvent::new(KeyCode::Char('+'), KeyModifiers::NONE),
        KeyEvent::new(KeyCode::Char('='), KeyModifiers::SHIFT),
    ] {
        let initial = app.pane_areas.iter().find(|area| area.pane == pane).unwrap().rect;
        app.handle_key(KeyEvent::new(KeyCode::Char('b'), KeyModifiers::CONTROL)).unwrap();
        app.handle_key(grow_key).unwrap();
        while app.session.has_pending_mutations() {
            app.handle(events.recv_timeout(Duration::from_secs(5)).unwrap()).unwrap();
        }
        app.sync_layout((120, 30));
        let grown = app.pane_areas.iter().find(|area| area.pane == pane).unwrap().rect;
        assert!(grown.width > initial.width || grown.height > initial.height);

        app.handle_key(KeyEvent::new(KeyCode::Char('b'), KeyModifiers::CONTROL)).unwrap();
        app.handle_key(KeyEvent::new(KeyCode::Char('-'), KeyModifiers::NONE)).unwrap();
        while app.session.has_pending_mutations() {
            app.handle(events.recv_timeout(Duration::from_secs(5)).unwrap()).unwrap();
        }
        app.sync_layout((120, 30));
        let shrunk = app.pane_areas.iter().find(|area| area.pane == pane).unwrap().rect;
        assert!(shrunk.width < grown.width || shrunk.height < grown.height);
    }

    let surfaces = mux.with_state(|state| state.surfaces.keys().copied().collect::<Vec<_>>());
    for surface in surfaces {
        mux.close_surface(surface).unwrap();
    }
}

#[test]
fn tab_workspace_menu_moves_the_clicked_inactive_tab_and_drag_creates_workspace() {
    let (mux, first) = test_mux("tab-workspace-move-test", None);
    let second = mux.new_tab(None, None, Some((80, 24))).unwrap();
    let target = mux.new_workspace(Some("destination".into()), Some((80, 24))).unwrap();
    let destination = mux.with_state(|state| state.workspaces[state.active_workspace].id);
    mux.select_workspace(Some(0), None);
    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    app.sidebar_view = SidebarView::Workspaces;
    app.replace_tree(app.session.tree());
    app.sync_layout((120, 30));
    let mut terminal = Terminal::new(TestBackend::new(120, 30)).unwrap();
    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
    let first_pane = app.tab_location(first.id).unwrap().0;
    let chip = app
        .hits
        .iter()
        .find_map(|(rect, hit)| {
            matches!(hit, crate::app::Hit::Tab { pane, index: 0 } if *pane == first_pane)
                .then_some(*rect)
        })
        .expect("inactive tab chip");
    app.open_context_menu(chip.x, chip.y);
    let move_existing =
        MenuAction::MoveTabToWorkspace { surface: first.id, workspace: Some(destination) };
    assert!(app.menu.as_ref().unwrap().actions().contains(&move_existing));
    app.activate_menu(move_existing).unwrap();
    while app.session.has_pending_mutations() {
        app.handle(events.recv_timeout(Duration::from_secs(5)).unwrap()).unwrap();
    }
    assert_eq!(
        mux.with_state(|state| state.pane_of(first.id)),
        mux.with_state(|state| state.pane_of(target.id))
    );
    assert_ne!(
        mux.with_state(|state| state.pane_of(first.id)),
        mux.with_state(|state| state.pane_of(second.id))
    );
    assert_eq!(app.tree.active_surface(), Some(first.id));
    app.menu = None;
    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
    let footer = app
        .hits
        .iter()
        .find_map(|(rect, hit)| {
            matches!(
                hit,
                crate::app::Hit::CreateWorkspace { mode: None }
                    | crate::app::Hit::SidebarAction {
                        action: SidebarActionTarget::CreateWorkspace(None),
                        ..
                    }
            )
            .then_some(*rect)
        })
        .expect("new workspace footer");
    let before = app.tree.workspaces().len();
    app.drag = Some(Drag::Tab { surface: first.id, target: None });
    app.handle_left_up(footer.x, footer.y).unwrap();
    while app.session.has_pending_mutations() {
        app.handle(events.recv_timeout(Duration::from_secs(5)).unwrap()).unwrap();
    }
    assert_eq!(app.tree.workspaces().len(), before + 1);
    assert_eq!(app.tree.active_screen().unwrap().panes[0].tabs[0].surface, first.id);
    assert!(Arc::ptr_eq(&first, &mux.surface(first.id).unwrap()));
    for surface in [first.id, second.id, target.id] {
        mux.close_surface(surface).unwrap();
    }
}

#[test]
fn pane_context_new_pane_runs_the_same_smart_layout_action_as_alt_n() {
    let (mux, _) = test_mux("context-new-pane-test", None);
    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    app.sidebar_visible = false;
    app.replace_tree(app.session.tree());
    app.sync_layout((120, 30));
    let pane = app.active_pane().unwrap();
    let before = app.tree.active_screen().unwrap().panes.len();
    let content = app.pane_areas.iter().find(|area| area.pane == pane).unwrap().content;

    app.open_context_menu(content.x, content.y);
    assert!(
        app.menu.as_ref().unwrap().levels[0]
            .items
            .iter()
            .any(|item| item.action() == Some(MenuAction::NewPaneSmart(pane)))
    );
    app.activate_menu(MenuAction::NewPaneSmart(pane)).unwrap();
    while app.session.has_pending_mutations() {
        let event = events.recv_timeout(Duration::from_secs(5)).unwrap();
        app.handle(event).unwrap();
    }

    assert_eq!(app.tree.active_screen().unwrap().panes.len(), before + 1);
    let surfaces = mux.with_state(|state| state.surfaces.keys().copied().collect::<Vec<_>>());
    for surface in surfaces {
        mux.close_surface(surface).unwrap();
    }
}

#[test]
fn pane_context_maximize_focuses_the_explicit_inactive_pane() {
    let (mux, first) = test_mux("context-maximize-focus-test", None);
    let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let second = mux.split(first_pane, SplitDir::Right, Some((40, 24))).unwrap();
    let second_pane = mux.with_state(|state| state.pane_of(second.id).unwrap());
    assert_eq!(mux.with_state(|state| state.active_pane()), Some(second_pane));
    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    app.replace_tree(app.session.tree());
    app.session.remote = true;

    app.activate_menu(MenuAction::TogglePaneZoom { pane: first_pane, zoomed: false }).unwrap();
    while app.session.has_pending_mutations() {
        let event = events.recv_timeout(Duration::from_secs(5)).unwrap();
        app.handle(event).unwrap();
    }
    let active_pane = app.tree.active_screen().unwrap().active_pane;
    let zoomed_pane = app.session.tree().active_screen().unwrap().zoomed_pane;
    let surfaces = mux.with_state(|state| state.surfaces.keys().copied().collect::<Vec<_>>());
    for surface in surfaces {
        mux.close_surface(surface).unwrap();
    }
    assert_eq!(zoomed_pane, Some(first_pane));
    assert_eq!(active_pane, first_pane);
}

#[test]
fn pane_context_maximize_preserves_its_explicit_intent_after_remote_state_changes() {
    let (mux, first) = test_mux("context-maximize-intent-test", None);
    let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let second = mux.split(first_pane, SplitDir::Right, Some((40, 24))).unwrap();
    let second_pane = mux.with_state(|state| state.pane_of(second.id).unwrap());
    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    app.replace_tree(app.session.tree());

    let menu_intent = MenuAction::TogglePaneZoom { pane: second_pane, zoomed: false };
    mux.zoom_pane(Some(second_pane), ZoomMode::On).unwrap();
    app.activate_menu(menu_intent).unwrap();
    while app.session.has_pending_mutations() {
        let event = events.recv_timeout(Duration::from_secs(5)).unwrap();
        app.handle(event).unwrap();
    }

    let zoomed_pane = app.session.tree().active_screen().unwrap().zoomed_pane;
    let surfaces = mux.with_state(|state| state.surfaces.keys().copied().collect::<Vec<_>>());
    for surface in surfaces {
        mux.close_surface(surface).unwrap();
    }
    assert_eq!(zoomed_pane, Some(second_pane));
}

#[test]
fn surface_only_context_menu_omits_client_management() {
    let (mux, surface) = test_mux("surface-only-context-clients-test", None);
    let mut app = test_app(Session::Local(mux.clone()));
    app.surface_only = Some(surface.id);
    app.sidebar_visible = false;
    app.clients = vec![ClientInfo {
        client: 7,
        transport: "unix".to_string(),
        name: Some("peer".to_string()),
        kind: Some("tui".to_string()),
        connected_seconds: 1,
        attached: vec![surface.id],
        sizes: vec![ClientSizeInfo {
            surface: surface.id,
            cols: Some(80),
            rows: Some(24),
            size_participating: true,
        }],
        is_self: false,
    }];
    app.replace_tree(app.session.tree());
    app.sync_layout((120, 30));
    let content = app.pane_areas[0].content;

    app.open_context_menu(content.x, content.y);

    assert!(!app.menu.as_ref().unwrap().levels[0].items.iter().any(|item| {
        matches!(item, MenuItem::Submenu { label, .. } if label.starts_with("Connected clients"))
    }));
    assert!(
        !app.menu.as_ref().unwrap().levels[0].items.iter().any(|item| {
            matches!(
                item.action(),
                Some(
                    MenuAction::NewPaneSmart(_)
                        | MenuAction::NewTab(_)
                        | MenuAction::NewBrowserTab(_)
                        | MenuAction::SplitRight(_)
                        | MenuAction::SplitDown(_)
                )
            )
        }),
        "single-surface context menu exposed a topology-creating action"
    );

    app.run_action(Action::ShowShortcuts).unwrap();
    let target_local = |action| {
        matches!(
            action,
            Action::SendPrefix
                | Action::CloseTab
                | Action::RenameTab
                | Action::ScrollUp
                | Action::ScrollDown
                | Action::ClearHistory
                | Action::ShowShortcuts
                | Action::Detach
        )
    };
    for definition in action_definitions() {
        let action = definition.action;
        assert_eq!(
            action_available_in_mode(action, true),
            target_local(action),
            "single-surface action policy mismatched {}",
            definition.label_en
        );
        if target_local(action) {
            continue;
        }
        assert!(
            !app.shortcut_help
                .as_ref()
                .unwrap()
                .rows
                .iter()
                .any(|(candidate, _)| { *candidate == action }),
            "single-surface shortcut help exposed {}",
            action.definition().label_en
        );
    }
    mux.close_surface(surface.id).unwrap();
}

#[test]
fn single_surface_client_rejects_hidden_pane_closure() {
    let (mux, attached) = test_mux("single-surface-close-pane-test", None);
    let pane = mux.with_state(|state| state.pane_of(attached.id).unwrap());
    let hidden = mux.new_tab(Some(pane), None, Some((80, 24))).unwrap();
    mux.select_tab(Some(pane), Some(0), None);
    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    app.surface_only = Some(attached.id);
    app.replace_tree(app.session.tree());

    app.run_action_for_pane(Action::ClosePane, Some(pane)).unwrap();
    while app.session.has_pending_mutations() {
        let event = events.recv_timeout(Duration::from_secs(5)).unwrap();
        app.handle(event).unwrap();
    }

    assert!(mux.surface(attached.id).is_some());
    assert!(mux.surface(hidden.id).is_some());
    mux.close_surface(attached.id).unwrap();
    mux.close_surface(hidden.id).unwrap();
}

#[cfg(unix)]
#[test]
fn status_command_runner_returns_last_clean_line() {
    let run = StatusWorkerStop::new();
    let (output, _) = run_status_command(
        &["/bin/sh".to_string(), "-c".to_string(), "printf 'one\\ntwo\\n\\n'".to_string()],
        Duration::from_secs(5),
        &run,
    );
    assert_eq!(output, "two", "the last nonempty line wins");
    let (colored, _) = run_status_command(
        &[
            "/bin/sh".to_string(),
            "-c".to_string(),
            "printf '\\033[31mred\\033[0m done'".to_string(),
        ],
        Duration::from_secs(5),
        &run,
    );
    assert_eq!(colored, "red done", "escape sequences are stripped");
    assert_eq!(
        run_status_command(&["/nonexistent-status-cmd".to_string()], Duration::from_secs(1), &run,)
            .0,
        "",
        "spawn failures resolve to an empty segment"
    );
}

#[cfg(unix)]
#[test]
fn status_command_timeout_kills_the_process_tree_and_keeps_partial_output() {
    let started = Instant::now();
    let run = StatusWorkerStop::new();
    let (output, stuck) = run_status_command(
        &["/bin/sh".to_string(), "-c".to_string(), "echo early; sleep 60".to_string()],
        Duration::from_secs(1),
        &run,
    );
    assert_eq!(output, "early", "output before the timeout survives the group kill");
    assert!(stuck.is_none(), "a killable command is reaped within the bound");
    assert!(
        started.elapsed() < Duration::from_secs(10),
        "the runtime bound is real: {:?}",
        started.elapsed()
    );

    // A raised stop flag makes the capture return within one poll tick
    // instead of running out the timeout, so config reloads and app
    // shutdown never wait on a slow command.
    let stopped = StatusWorkerStop::new();
    stopped.raise();
    let started = Instant::now();
    let (output, _) = run_status_command(
        &["/bin/sh".to_string(), "-c".to_string(), "sleep 60".to_string()],
        Duration::from_secs(60),
        &stopped,
    );
    assert_eq!(output, "");
    assert!(
        started.elapsed() < Duration::from_secs(5),
        "stop preempts the timeout: {:?}",
        started.elapsed()
    );
}

#[test]
fn status_token_expansion_never_rescans_inserted_values() {
    let values = StatusTemplateValues {
        session: "s",
        workspace: "{screens}",
        screen: "main",
        screens: "3",
        title: "{user}",
        user: "lawrence",
    };
    assert_eq!(
        expand_status_tokens("{workspace} of {screens} · {title}", &values),
        "{screens} of 3 · {user}",
        "inserted values stay literal"
    );
    assert_eq!(
        expand_status_tokens("{unknown} {session", &values),
        "{unknown} {session",
        "unknown tokens and unterminated braces stay literal"
    );
    assert_eq!(expand_status_tokens("plain", &values), "plain");
}

#[test]
fn status_segments_expand_variables_and_read_command_outputs() {
    let (mux, _surface) = test_mux("status-segments-test", None);
    let (mut app, _events) = test_app_with_events(Session::Local(mux.clone()));
    app.replace_tree(app.session.tree());
    app.config.status_bar.left = vec![crate::config::StatusSegment {
        content: crate::config::StatusSegmentContent::Text(
            " {session} {workspace} {screens} ".to_string(),
        ),
        fg: None,
        bg: None,
    }];
    app.config.status_bar.right = vec![crate::config::StatusSegment {
        content: crate::config::StatusSegmentContent::Command {
            argv: vec!["true".to_string()],
            interval: Duration::from_secs(5),
        },
        fg: Some(Color::Indexed(114)),
        bg: None,
    }];
    app.status_command_outputs.lock().unwrap().insert(1, "widget".to_string());

    let segments = app.resolved_status_segments();
    let (left, right) = (&segments.0, &segments.1);
    assert_eq!(left.len(), 1);
    assert!(
        left[0].text.contains(" work 1 "),
        "workspace and screen count expand: {:?}",
        left[0].text
    );
    assert!(!left[0].text.contains('{'), "no unexpanded braces: {:?}", left[0].text);
    assert_eq!(right[0].text, "widget", "command segments read the worker output");
    assert_eq!(right[0].fg, Some(Color::Indexed(114)));

    for surface in mux.with_state(|state| state.surfaces.keys().copied().collect::<Vec<_>>()) {
        mux.close_surface(surface).unwrap();
    }
}

#[cfg(unix)]
#[test]
fn user_command_action_runs_configured_argv_in_a_new_tab() {
    let (mux, _surface) = test_mux("user-command-run-test", None);
    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    app.replace_tree(app.session.tree());
    app.config.commands = vec![crate::config::UserCommandConfig {
        id: "sleeper".to_string(),
        name: "Sleeper".to_string(),
        run: vec!["/bin/sh".to_string(), "-c".to_string(), "sleep 30".to_string()],
        cwd: None,
    }];
    let pane = app.tree.active_screen().unwrap().active_pane;
    let initial_surfaces = mux.with_state(|state| state.surfaces.len());

    app.run_action_for_pane(Action::user_command(0).unwrap(), Some(pane)).unwrap();
    while app.session.has_pending_mutations() {
        let event = events.recv_timeout(Duration::from_secs(5)).unwrap();
        app.handle(event).unwrap();
    }
    assert_eq!(mux.with_state(|state| state.surfaces.len()), initial_surfaces + 1);

    // An index without a configured command is a no-op.
    app.run_action_for_pane(Action::user_command(1).unwrap(), Some(pane)).unwrap();
    while app.session.has_pending_mutations() {
        let event = events.recv_timeout(Duration::from_secs(5)).unwrap();
        app.handle(event).unwrap();
    }
    assert_eq!(mux.with_state(|state| state.surfaces.len()), initial_surfaces + 1);

    // The shortcut modal shows the configured display name.
    assert_eq!(app.action_display_label(Action::user_command(0).unwrap()), "Sleeper");

    for surface in mux.with_state(|state| state.surfaces.keys().copied().collect::<Vec<_>>()) {
        mux.close_surface(surface).unwrap();
    }
}

#[test]
fn single_surface_client_rejects_hidden_browser_creation() {
    let (mux, surface) = test_mux("single-surface-browser-creation-test", None);
    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    app.surface_only = Some(surface.id);
    app.replace_tree(app.session.tree());
    let pane = app.tree.active_screen().unwrap().active_pane;
    let initial_surfaces = mux.with_state(|state| state.surfaces.len());

    app.run_action_for_pane(Action::NewBrowserTab, Some(pane)).unwrap();
    while app.session.has_pending_mutations() {
        let event = events.recv_timeout(Duration::from_secs(5)).unwrap();
        app.handle(event).unwrap();
    }

    let surfaces = mux.with_state(|state| state.surfaces.keys().copied().collect::<Vec<_>>());
    assert_eq!(surfaces.len(), initial_surfaces);
    for surface in surfaces {
        mux.close_surface(surface).unwrap();
    }
}

#[test]
fn close_tab_action_honors_its_explicit_pane_target() {
    let mux = Mux::new("explicit-close-tab-target-test", SurfaceOptions::default());
    let first = mux.new_workspace(None, Some((80, 24))).unwrap();
    let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let second = mux.split(first_pane, SplitDir::Right, Some((40, 24))).unwrap();
    assert_eq!(mux.active_surface(), Some(second.id));
    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    app.replace_tree(app.session.tree());

    app.run_action_for_pane(Action::CloseTab, Some(first_pane)).unwrap();
    while app.session.has_pending_mutations() {
        let event = events.recv_timeout(Duration::from_secs(5)).unwrap();
        app.handle(event).unwrap();
    }

    assert!(app.session.has_surface(first.id));
    assert!(app.session.has_surface(second.id));
    assert!(!app.tab_locations.contains_key(&first.id));
    assert!(app.tab_locations.contains_key(&second.id));
    mux.with_state(|state| {
        assert!(!state.surfaces.contains_key(&first.id));
        assert!(state.surfaces.contains_key(&second.id));
    });
    let surfaces = mux.with_state(|state| state.surfaces.keys().copied().collect::<Vec<_>>());
    for surface in surfaces {
        mux.close_surface(surface).unwrap();
    }
}

#[test]
fn doubled_prefix_runs_the_shared_send_prefix_action() {
    let (mux, _) = test_mux("send-prefix-test", None);
    let mut app = test_app(Session::Local(mux.clone()));
    app.replace_tree(app.session.tree());
    let prefix = KeyEvent::new(KeyCode::Char('b'), KeyModifiers::CONTROL);

    app.handle_key(prefix).unwrap();
    assert!(app.prefix_armed);
    app.handle_key(prefix).unwrap();

    assert!(!app.prefix_armed);
    assert_eq!(app.encode_buf, b"\x02");

    let surfaces = mux.with_state(|state| state.surfaces.keys().copied().collect::<Vec<_>>());
    for surface in surfaces {
        mux.close_surface(surface).unwrap();
    }
}

#[test]
fn prefix_chord_is_resolved_before_deferred_session_barrier() {
    let (mux, _) = test_mux("semantic-prefix-barrier-test", None);
    let mut app = test_app(Session::Local(mux.clone()));
    app.replace_tree(app.session.tree());
    app.session.pending_mutations.store(1, Ordering::Release);

    app.handle(AppEvent::Input(Event::Key(KeyEvent::new(
        KeyCode::Char('b'),
        KeyModifiers::CONTROL,
    ))))
    .unwrap();
    app.handle(AppEvent::Input(Event::EnhancedKey(EnhancedKeyEvent {
        key_event: KeyEvent::new(KeyCode::Char('5'), KeyModifiers::SHIFT),
        shifted_key: Some('%'),
        base_layout_key: Some('5'),
        text: "%".to_string(),
    })))
    .unwrap();

    assert!(
        !app.prefix_armed,
        "the completed chord must become an immutable split intent at ingress"
    );
    assert_eq!(app.deferred_input.len(), 1);

    app.session.pending_mutations.store(0, Ordering::Release);
    let surfaces = mux.with_state(|state| state.surfaces.keys().copied().collect::<Vec<_>>());
    for surface in surfaces {
        mux.close_surface(surface).unwrap();
    }
}

#[test]
fn rapid_split_close_input_is_retained_past_the_old_deferred_queue_limit() {
    let mux = Mux::new("semantic-split-close-burst-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.session.pending_mutations.store(1, Ordering::Release);
    let cycles = DEFERRED_INPUT_CAPACITY / 2 + 44;

    for _ in 0..cycles {
        app.handle(AppEvent::Input(Event::Key(KeyEvent::new(
            KeyCode::Char('b'),
            KeyModifiers::CONTROL,
        ))))
        .unwrap();
        app.handle(AppEvent::Input(Event::EnhancedKey(EnhancedKeyEvent {
            key_event: KeyEvent::new(KeyCode::Char('5'), KeyModifiers::SHIFT),
            shifted_key: Some('%'),
            base_layout_key: Some('5'),
            text: "%".to_string(),
        })))
        .unwrap();
        app.handle(AppEvent::Input(Event::Key(KeyEvent::new(
            KeyCode::Char('d'),
            KeyModifiers::CONTROL,
        ))))
        .unwrap();
    }

    assert!(!app.prefix_armed);
    assert_eq!(
        app.deferred_input.len(),
        cycles * 2,
        "every split intent and dependent Ctrl-D must remain ordered under burst input"
    );
    assert_ne!(
        app.status_message.as_deref(),
        Some(localization::catalog().terminal.deferred_input_queue_full)
    );
}

#[test]
fn failed_semantic_destination_discards_only_its_dependent_input() {
    let (mux, surface) = test_mux("semantic-failure-scope-test", None);
    let mut app = test_app(Session::Local(mux.clone()));
    app.replace_tree(app.session.tree());
    app.semantic_destination_outcomes.insert(1, crate::app::SemanticDestinationOutcome::Failed);

    let mut dependent = queued_input(
        Event::Key(KeyEvent::new(KeyCode::Char('d'), KeyModifiers::CONTROL)),
        Some(surface.id),
        1,
    );
    dependent.admission.semantic_dependency = Some(1);
    let prefix = KeyEvent::new(KeyCode::Char('b'), KeyModifiers::CONTROL);
    let mut frontend_local = queued_input(
        TerminalInput::FrontendAction { action: Action::ShowShortcuts, prefix },
        None,
        2,
    );
    frontend_local.admission.client_owned = true;
    app.deferred_input.push_back(dependent);
    app.deferred_input.push_back(frontend_local);

    app.replay_deferred_input().unwrap();

    assert!(app.deferred_input.is_empty());
    assert!(app.shortcut_help.is_some(), "an unrelated frontend-local action was discarded");
    assert_eq!(
        app.status_message.as_deref(),
        Some(localization::catalog().terminal.deferred_input_destination_changed)
    );
    mux.close_surface(surface.id).unwrap();
}

#[test]
fn repeated_split_then_ctrl_d_is_receipt_ordered_without_prefix_leaks() {
    let mux = Mux::new(
        "semantic-split-close-chain-test",
        SurfaceOptions {
            command: Some(vec![
                "/bin/sh".to_string(),
                "-c".to_string(),
                "IFS= read -r line".to_string(),
            ]),
            ..Default::default()
        },
    );
    let original = mux.new_workspace(Some("work".to_string()), Some((20, 8))).unwrap();
    let mux_events = mux.subscribe();
    let (mut app, session_events) = test_app_with_events(Session::Local(mux.clone()));
    app.replace_tree(app.session.tree());

    let (writes_tx, writes_rx) = std::sync::mpsc::sync_channel(16);
    let observer_mux = mux.clone();
    app.pty_input.set_delivered_write_observer(Some(Arc::new(move |surface, bytes| {
        writes_tx.send((surface, bytes.to_vec())).unwrap();
        let deadline = Instant::now() + Duration::from_secs(1);
        while observer_mux.surface(surface).is_some() {
            assert!(
                Instant::now() < deadline,
                "Ctrl-D target did not exit before the next queued creation"
            );
            std::thread::yield_now();
        }
    })));
    let (barrier_started_tx, barrier_started_rx) = std::sync::mpsc::sync_channel(1);
    let (release_barrier_tx, release_barrier_rx) = std::sync::mpsc::sync_channel(1);
    app.session.enqueue("block semantic input chain", move |_| {
        barrier_started_tx.send(()).unwrap();
        release_barrier_rx.recv().unwrap();
        Ok(())
    });
    barrier_started_rx.recv_timeout(Duration::from_secs(1)).unwrap();

    for _ in 0..2 {
        app.handle(AppEvent::Input(Event::Key(KeyEvent::new(
            KeyCode::Char('b'),
            KeyModifiers::CONTROL,
        ))))
        .unwrap();
        app.handle(AppEvent::Input(Event::EnhancedKey(EnhancedKeyEvent {
            key_event: KeyEvent::new(KeyCode::Char('5'), KeyModifiers::SHIFT),
            shifted_key: Some('%'),
            base_layout_key: Some('5'),
            text: "%".to_string(),
        })))
        .unwrap();
        app.handle(AppEvent::Input(Event::Key(KeyEvent::new(
            KeyCode::Char('d'),
            KeyModifiers::CONTROL,
        ))))
        .unwrap();
    }

    assert!(!app.prefix_armed);
    assert_eq!(app.deferred_input.len(), 4);
    release_barrier_tx.send(()).unwrap();

    let deadline = Instant::now() + Duration::from_secs(5);
    let mut created = Vec::new();
    while app.session.has_pending_mutations() || !app.deferred_input.is_empty() {
        if !app.session.has_pending_mutations() {
            app.replay_deferred_input().unwrap();
            continue;
        }
        let event = session_events
            .recv_timeout(deadline.saturating_duration_since(Instant::now()))
            .expect("semantic input chain did not settle");
        if let AppEvent::SessionMutationSettled { outcome, .. } = &event {
            let outcome = match outcome {
                crate::app::SessionMutationOutcome::SemanticIntent { outcome, .. } => {
                    outcome.as_ref()
                }
                outcome => outcome,
            };
            if let crate::app::SessionMutationOutcome::AuthoritativeMutationSucceeded {
                completion:
                    Some(SessionCompletion {
                        action: SessionCompletionAction::SurfaceCreated { surface },
                        ..
                    }),
                ..
            } = outcome
            {
                created.push(*surface);
            }
        }
        app.handle(event).unwrap();
    }
    assert_eq!(created.len(), 2);
    assert!(app.pty_input.shutdown(Duration::from_secs(2)));

    let writes = writes_rx.try_iter().collect::<Vec<_>>();
    assert_eq!(
        writes,
        vec![(created[0], vec![0x04]), (created[1], vec![0x04])],
        "each Ctrl-D must follow the exact split receipt, with no Ctrl-B or percent bytes"
    );

    let mut exited = HashSet::new();
    while exited.len() < created.len() {
        match mux_events.recv_timeout(deadline.saturating_duration_since(Instant::now())) {
            Ok(MuxEvent::SurfaceExited(surface)) if created.contains(&surface) => {
                exited.insert(surface);
            }
            Ok(_) => {}
            Err(error) => panic!("created surfaces did not exit after Ctrl-D: {error}"),
        }
    }
    let tree = app.session.tree();
    assert_eq!(tree.workspaces()[0].screens[0].panes.len(), 1);
    assert_eq!(tree.active_surface(), Some(original.id));
    mux.close_surface(original.id).unwrap();
}

#[test]
fn immediate_split_receipt_routes_following_input_past_later_creation() {
    let mux = Mux::new(
        "semantic-immediate-split-route-test",
        SurfaceOptions {
            command: Some(vec![
                "/bin/sh".to_string(),
                "-c".to_string(),
                "IFS= read -r line".to_string(),
            ]),
            ..Default::default()
        },
    );
    let original = mux.new_workspace(Some("work".to_string()), Some((20, 8))).unwrap();
    let (mut app, session_events) = test_app_with_events(Session::Local(mux.clone()));
    app.replace_tree(app.session.tree());

    let (writes_tx, writes_rx) = std::sync::mpsc::sync_channel(4);
    app.pty_input.set_delivered_write_observer(Some(Arc::new(move |surface, bytes| {
        writes_tx.send((surface, bytes.to_vec())).unwrap();
    })));

    app.handle(AppEvent::Input(Event::Key(KeyEvent::new(
        KeyCode::Char('b'),
        KeyModifiers::CONTROL,
    ))))
    .unwrap();
    app.handle(AppEvent::Input(Event::EnhancedKey(EnhancedKeyEvent {
        key_event: KeyEvent::new(KeyCode::Char('5'), KeyModifiers::SHIFT),
        shifted_key: Some('%'),
        base_layout_key: Some('5'),
        text: "%".to_string(),
    })))
    .unwrap();

    app.session.new_screen_for_semantic_intent(None, Some((20, 8)), None).unwrap();
    app.handle(AppEvent::Input(Event::Key(KeyEvent::new(
        KeyCode::Char('d'),
        KeyModifiers::CONTROL,
    ))))
    .unwrap();

    let deadline = Instant::now() + Duration::from_secs(5);
    let mut created = Vec::new();
    while app.session.has_pending_mutations() || !app.deferred_input.is_empty() {
        if !app.session.has_pending_mutations() {
            app.replay_deferred_input().unwrap();
            continue;
        }
        let event = session_events
            .recv_timeout(deadline.saturating_duration_since(Instant::now()))
            .expect("competing destination creations did not settle");
        if let AppEvent::SessionMutationSettled { outcome, .. } = &event {
            let outcome = match outcome {
                crate::app::SessionMutationOutcome::SemanticIntent { outcome, .. } => {
                    outcome.as_ref()
                }
                outcome => outcome,
            };
            if let crate::app::SessionMutationOutcome::AuthoritativeMutationSucceeded {
                completion:
                    Some(SessionCompletion {
                        action: SessionCompletionAction::SurfaceCreated { surface },
                        ..
                    }),
                ..
            } = outcome
            {
                created.push(*surface);
            }
        }
        app.handle(event).unwrap();
    }
    assert_eq!(created.len(), 2);
    assert!(app.pty_input.shutdown(Duration::from_secs(2)));
    assert_eq!(
        writes_rx.try_iter().collect::<Vec<_>>(),
        vec![(created[0], vec![0x04])],
        "input admitted after the split must target its receipt, not a later creation"
    );

    let surfaces = mux.with_state(|state| state.surfaces.keys().copied().collect::<Vec<_>>());
    for surface in surfaces {
        let _ = mux.close_surface(surface);
    }
    assert!(!mux.with_state(|state| state.surfaces.contains_key(&original.id)));
}

#[test]
fn enhanced_prefixed_split_survives_pointer_mutation_and_focus_refresh() {
    let (mux, _) = test_mux("enhanced-prefix-split-test", None);
    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    app.replace_tree(app.session.tree());
    app.session.pending_mutations.store(1, Ordering::Release);
    app.session.pending_pointer_mutations.store(1, Ordering::Release);

    app.handle(AppEvent::Input(Event::Key(KeyEvent::new(
        KeyCode::Char('b'),
        KeyModifiers::CONTROL,
    ))))
    .unwrap();
    assert!(app.prefix_armed);

    app.handle(AppEvent::Input(Event::EnhancedKey(EnhancedKeyEvent {
        key_event: KeyEvent::new(KeyCode::Char('5'), KeyModifiers::SHIFT),
        shifted_key: Some('%'),
        base_layout_key: None,
        text: "%".to_string(),
    })))
    .unwrap();

    assert!(!app.prefix_armed);
    assert_eq!(app.deferred_input.len(), 1);
    assert!(!app.deferred_input.front().unwrap().admission.client_owned);
    app.focus = FocusTarget::WorkspaceRail;
    app.session.settle_pending_mutation(MutationImpact::PointerMap);
    app.replay_deferred_input().unwrap();
    assert!(!app.prefix_armed);
    assert!(app.deferred_input.is_empty());
    assert_ne!(
        app.status_message.as_deref(),
        Some(localization::catalog().terminal.deferred_input_destination_changed)
    );
    while app.session.has_pending_mutations() {
        app.handle(events.recv_timeout(Duration::from_secs(5)).unwrap()).unwrap();
    }
    assert_eq!(app.tree.active_screen().unwrap().panes.len(), 2);

    let surfaces = mux.with_state(|state| state.surfaces.keys().copied().collect::<Vec<_>>());
    for surface in surfaces {
        mux.close_surface(surface).unwrap();
    }
}

#[test]
fn modifier_only_presses_do_not_consume_prefix_before_shifted_binding() {
    let (mux, _) = test_mux("modifier-prefix-split-test", None);
    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    app.replace_tree(app.session.tree());

    app.handle(AppEvent::Input(Event::Key(KeyEvent::new(
        KeyCode::Char('b'),
        KeyModifiers::CONTROL,
    ))))
    .unwrap();
    assert!(app.prefix_armed);

    for (modifier, modifiers) in [
        (ModifierKeyCode::LeftShift, KeyModifiers::SHIFT),
        (ModifierKeyCode::RightShift, KeyModifiers::SHIFT),
        (ModifierKeyCode::LeftControl, KeyModifiers::CONTROL),
        (ModifierKeyCode::RightControl, KeyModifiers::CONTROL),
        (ModifierKeyCode::LeftAlt, KeyModifiers::ALT),
        (ModifierKeyCode::RightAlt, KeyModifiers::ALT),
        (ModifierKeyCode::LeftSuper, KeyModifiers::SUPER),
        (ModifierKeyCode::RightSuper, KeyModifiers::SUPER),
        (ModifierKeyCode::LeftHyper, KeyModifiers::HYPER),
        (ModifierKeyCode::RightHyper, KeyModifiers::HYPER),
        (ModifierKeyCode::LeftMeta, KeyModifiers::META),
        (ModifierKeyCode::RightMeta, KeyModifiers::META),
        (ModifierKeyCode::IsoLevel3Shift, KeyModifiers::NONE),
        (ModifierKeyCode::IsoLevel5Shift, KeyModifiers::NONE),
    ] {
        app.handle(AppEvent::Input(Event::Key(KeyEvent::new(
            KeyCode::Modifier(modifier),
            modifiers,
        ))))
        .unwrap();
        assert!(app.prefix_armed, "{modifier:?} consumed the pending prefix");
    }

    app.handle(AppEvent::Input(Event::EnhancedKey(EnhancedKeyEvent {
        key_event: KeyEvent::new(KeyCode::Char('5'), KeyModifiers::SHIFT),
        shifted_key: Some('%'),
        base_layout_key: Some('5'),
        text: "%".to_string(),
    })))
    .unwrap();

    while app.session.has_pending_mutations() {
        app.handle(events.recv_timeout(Duration::from_secs(5)).unwrap()).unwrap();
    }
    assert!(!app.prefix_armed);
    assert_eq!(app.tree.active_screen().unwrap().panes.len(), 2);

    let surfaces = mux.with_state(|state| state.surfaces.keys().copied().collect::<Vec<_>>());
    for surface in surfaces {
        mux.close_surface(surface).unwrap();
    }
}

#[test]
fn modifier_only_press_preserves_selection_and_durable_notice() {
    let (mux, surface) = test_mux("modifier-ui-state-test", None);
    let mut app = test_app(Session::Local(mux.clone()));
    app.replace_tree(app.session.tree());
    let selection = Selection { surface: surface.id, anchor: (1, 1), head: (2, 1) };
    app.selection = Some(selection);
    let notice = durable_notice("modifier-notice", 1, "notice");
    app.accept_durable_notice(notice.clone());
    app.record_durable_notice_painted(notice.delivery.clone());
    app.commit_successful_durable_notice_paint();

    app.handle(AppEvent::Input(Event::Key(KeyEvent::new(
        KeyCode::Modifier(ModifierKeyCode::LeftShift),
        KeyModifiers::SHIFT,
    ))))
    .unwrap();

    assert_eq!(app.selection, Some(selection));
    assert_eq!(app.durable_notice().map(|notice| &notice.delivery), Some(&notice.delivery));

    let surfaces = mux.with_state(|state| state.surfaces.keys().copied().collect::<Vec<_>>());
    for surface in surfaces {
        mux.close_surface(surface).unwrap();
    }
}

#[test]
fn doubled_prefix_keeps_the_focused_sidebar_plugin_target() {
    let (mux, sidebar_surface) = test_mux("sidebar-send-prefix-test", None);
    mux.new_workspace(Some("pane".to_string()), Some((20, 8))).unwrap();
    let mut app = test_app(Session::Local(mux.clone()));
    app.replace_tree(app.session.tree());
    app.config.sidebar.plugin = Some(cmux_tui_core::SidebarPluginOptions {
        command: vec!["unused".to_string()],
        cwd: None,
    });
    app.sidebar_plugin_surface = Some(sidebar_surface.id);
    app.focus = FocusTarget::WorkspaceRail;
    let prefix = KeyEvent::new(KeyCode::Char('b'), KeyModifiers::CONTROL);

    app.handle_key(prefix).unwrap();
    app.handle_key(prefix).unwrap();

    assert_eq!(app.focus, FocusTarget::WorkspaceRail);
    assert_eq!(app.sidebar_plugin_surface, Some(sidebar_surface.id));
    assert_eq!(app.encode_buf, b"\x02");

    let surfaces = mux.with_state(|state| state.surfaces.keys().copied().collect::<Vec<_>>());
    for surface in surfaces {
        mux.close_surface(surface).unwrap();
    }
}

#[test]
fn shortcut_help_occludes_overlapping_browser_graphics() {
    let mux = Mux::new("shortcut-help-graphics-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    let browser_rect = Rect { x: 10, y: 5, width: 40, height: 20 };

    assert!(!app.browser_graphic_occluded(browser_rect));
    app.shortcut_help = Some(ShortcutHelp {
        rect: Rect { x: 20, y: 10, width: 30, height: 10 },
        ..ShortcutHelp::default()
    });
    assert!(app.browser_graphic_occluded(browser_rect));

    app.shortcut_help.as_mut().unwrap().rect = Rect { x: 60, y: 10, width: 10, height: 10 };
    assert!(!app.browser_graphic_occluded(browser_rect));
}

#[test]
fn shortcut_help_closes_when_the_terminal_cannot_render_it() {
    let mux = Mux::new("shortcut-help-small-terminal-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.shortcut_help = Some(ShortcutHelp::default());
    let mut terminal = Terminal::new(TestBackend::new(23, 6)).unwrap();

    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();

    assert!(app.shortcut_help.is_none());
}

#[test]
fn shortcut_help_mouse_repaints_only_when_modal_state_changes() {
    let mux = Mux::new("shortcut-help-mouse-render-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.run_action(Action::ShowShortcuts).unwrap();
    let mut terminal = Terminal::new(TestBackend::new(80, 12)).unwrap();
    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
    let help = app.shortcut_help.as_ref().unwrap();
    let content_x = help.rect.x + 2;
    let content_y = help.rect.y + 3;

    assert_eq!(
        app.handle_shortcut_help_mouse(MouseEvent {
            kind: MouseEventKind::Moved,
            column: content_x,
            row: content_y,
            modifiers: KeyModifiers::NONE,
        }),
        RenderAction::None
    );

    let previous_offset = app.shortcut_help.as_ref().unwrap().scroll_offset;
    assert_eq!(
        app.handle_shortcut_help_mouse(MouseEvent {
            kind: MouseEventKind::ScrollDown,
            column: content_x,
            row: content_y,
            modifiers: KeyModifiers::NONE,
        }),
        RenderAction::Paint
    );
    assert!(app.shortcut_help.as_ref().unwrap().scroll_offset > previous_offset);
}

#[test]
fn opening_shortcut_help_releases_an_active_pty_mouse_press() {
    let mux = Mux::new("shortcut-help-pty-release-test", SurfaceOptions::default());
    let surface = mux.new_workspace(None, Some((20, 8))).unwrap();
    let mut app = test_app(Session::Local(mux.clone()));
    app.drag = Some(Drag::PtyMouse {
        surface: surface.id,
        handle: None,
        reservation_id: 41,
        release_bytes: PtyInputBytes::from_slice(b"fallback-release"),
        semantics: None,
        content: Rect { x: 1, y: 1, width: 20, height: 8 },
        button: MouseButton::Left,
        position: (4, 3),
        modifiers: KeyModifiers::NONE,
    });

    app.run_action(Action::ShowShortcuts).unwrap();

    assert!(app.shortcut_help.is_some());
    assert!(app.drag.is_none());
    assert_eq!(app.encode_buf, b"fallback-release");
    mux.close_surface(surface.id).unwrap();
}

#[test]
fn opening_shortcut_help_releases_an_active_browser_mouse_press() {
    let mux = Mux::new(
        format!("shortcut-help-browser-release-test-{}", std::process::id()),
        SurfaceOptions::default(),
    );
    let surface = mux.new_workspace(None, Some((20, 8))).unwrap();
    let mut app = test_app(Session::Local(mux.clone()));
    let (dispatcher, received) = BrowserInputDispatcher::blocked(1);
    app.browser_input = dispatcher;
    let content = Rect { x: 1, y: 1, width: 20, height: 8 };
    assert!(app.browser_input.enqueue(BrowserInputEvent {
        surface_id: surface.id,
        surface: app.session.surface(surface.id).unwrap(),
        kind: BrowserInputKind::Mouse {
            event_type: "mousePressed",
            x: 3.0,
            y: 2.0,
            button: Some("left"),
            click_count: Some(1),
            frame_seq: 1,
        },
    }));
    assert!(matches!(
        received.recv_timeout(Duration::from_secs(1)).map(|event| event.kind),
        Some(BrowserInputKind::Mouse { event_type: "mousePressed", .. })
    ));
    app.drag = Some(Drag::Browser { surface: surface.id, content, position: (5, 4), frame_seq: 1 });

    app.run_action(Action::ShowShortcuts).unwrap();

    assert!(app.shortcut_help.is_some());
    assert!(app.drag.is_none());
    assert!(matches!(
        received.recv_timeout(Duration::from_secs(1)).map(|event| event.kind),
        Some(BrowserInputKind::Mouse { event_type: "mouseReleased", .. })
    ));
    mux.close_surface(surface.id).unwrap();
}

#[test]
fn opening_shortcut_help_finishes_an_active_split_resize() {
    let mux = Mux::new("shortcut-help-split-release-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
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

    app.run_action(Action::ShowShortcuts).unwrap();

    assert!(app.shortcut_help.is_some());
    assert!(app.drag.is_none());
}

#[test]
fn prefix_bar_and_shortcut_modal_use_the_resolved_action_catalog() {
    let (mux, _) = test_mux("shortcut-help-test", None);
    let mut app = test_app(Session::Local(mux.clone()));
    app.sidebar_visible = false;
    app.replace_tree(app.session.tree());
    app.sync_layout((180, 30));

    app.handle_key(KeyEvent::new(KeyCode::Char('b'), KeyModifiers::CONTROL)).unwrap();
    assert!(app.prefix_armed);
    let mut terminal = Terminal::new(TestBackend::new(180, 30)).unwrap();
    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
    let rendered = buffer_text(terminal.backend().buffer());
    let mut lines = rendered.lines().rev();
    let status = lines.next().unwrap();
    let guide = lines.next().unwrap();
    assert!(status.contains("screens"), "{status}");
    assert!(guide.contains("Ctrl-b"), "{guide}");
    assert!(guide.contains("Send prefix"), "{guide}");
    assert!(guide.contains("?  Keyboard shortcuts"), "{guide}");
    assert!(guide.contains("x  Close tab"), "{guide}");
    let prefix_x = guide.find("Ctrl-b").unwrap() as u16;
    let prefix_label_x = guide.find("Send prefix").unwrap() as u16;
    let prefix_cell = &terminal.backend().buffer()[(prefix_x, 28)];
    let prefix_label_cell = &terminal.backend().buffer()[(prefix_label_x, 28)];
    assert_eq!(prefix_cell.bg, prefix_label_cell.bg);
    assert_eq!(prefix_cell.fg, app.config.theme.border_active);

    app.handle_key(KeyEvent::new(KeyCode::Char('?'), KeyModifiers::SHIFT)).unwrap();
    assert!(app.shortcut_help.is_some());
    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
    let rendered = buffer_text(terminal.backend().buffer());
    assert!(rendered.contains("Keyboard shortcuts"), "{rendered}");
    assert!(rendered.contains("New pane"), "{rendered}");
    assert!(rendered.contains("Alt-n"), "{rendered}");
    assert!(rendered.contains("[Esc close]"), "{rendered}");
    assert!(!rendered.contains('×'), "{rendered}");
    let help_rect = app.shortcut_help.as_ref().unwrap().rect;
    let buffer = terminal.backend().buffer();
    let find_in_help = |needle: &str| {
        let symbols = needle.chars().map(|symbol| symbol.to_string()).collect::<Vec<_>>();
        (help_rect.y..help_rect.y + help_rect.height).find_map(|y| {
            let last_x = help_rect.x + help_rect.width.saturating_sub(symbols.len() as u16);
            (help_rect.x..=last_x)
                .find(|x| {
                    symbols.iter().enumerate().all(|(offset, symbol)| {
                        buffer[(*x + offset as u16, y)].symbol() == symbol.as_str()
                    })
                })
                .map(|x| (y, x))
        })
    };
    let (shortcut_y, shortcut_x) = find_in_help("Alt-n").unwrap();
    let (_, shortcut_label_x) = find_in_help("New pane").unwrap();
    let shortcut_cell = &terminal.backend().buffer()[(shortcut_x, shortcut_y)];
    let shortcut_label_cell = &terminal.backend().buffer()[(shortcut_label_x, shortcut_y)];
    assert_eq!(shortcut_cell.bg, shortcut_label_cell.bg);
    assert_eq!(shortcut_cell.fg, app.chrome.prompt_title_fg);
    let help = app.shortcut_help.as_ref().unwrap();
    assert!(help.scrollbar_track.height > 0);
    assert!(help.scrollbar_thumb.height > 0);
    assert_eq!(
        terminal.backend().buffer()[(help.scrollbar_thumb.x, help.scrollbar_thumb.y)].symbol(),
        "▕"
    );
    let track = help.scrollbar_track;
    app.handle_mouse(MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Left),
        column: track.x,
        row: track.y + track.height - 1,
        modifiers: KeyModifiers::NONE,
    })
    .unwrap();
    let jumped = app.shortcut_help.as_ref().unwrap().scroll_offset;
    assert!(jumped > 0);
    app.handle_mouse(MouseEvent {
        kind: MouseEventKind::Drag(MouseButton::Left),
        column: track.x,
        row: track.y,
        modifiers: KeyModifiers::NONE,
    })
    .unwrap();
    assert!(app.shortcut_help.as_ref().unwrap().scroll_offset < jumped);
    app.handle_mouse(MouseEvent {
        kind: MouseEventKind::Up(MouseButton::Left),
        column: track.x,
        row: track.y,
        modifiers: KeyModifiers::NONE,
    })
    .unwrap();

    app.handle_key(KeyEvent::new(KeyCode::End, KeyModifiers::NONE)).unwrap();
    assert!(app.shortcut_help.as_ref().unwrap().scroll_offset > 0);
    let close = app.shortcut_help.as_ref().unwrap().close_button;
    app.handle_mouse(MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Left),
        column: close.x + 1,
        row: close.y,
        modifiers: KeyModifiers::NONE,
    })
    .unwrap();
    assert!(app.shortcut_help.is_none());

    app.run_action(Action::ShowShortcuts).unwrap();
    let tall_height = app.shortcut_help.as_ref().unwrap().rows.len() as u16 + 6;
    let mut tall_terminal = Terminal::new(TestBackend::new(180, tall_height)).unwrap();
    tall_terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
    let help = app.shortcut_help.as_ref().unwrap();
    assert_eq!(help.scrollbar_track, Rect::default());
    assert_eq!(help.scrollbar_thumb, Rect::default());
    let scrollbar_x = help.rect.x + help.rect.width - 2;
    assert!((help.rect.y + 2..help.rect.y + help.rect.height - 2).all(|y| {
        !matches!(tall_terminal.backend().buffer()[(scrollbar_x, y)].symbol(), "▕" | "▐")
    }));
    app.handle_key(KeyEvent::new(KeyCode::Esc, KeyModifiers::NONE)).unwrap();
    assert!(app.shortcut_help.is_none());

    let surfaces = mux.with_state(|state| state.surfaces.keys().copied().collect::<Vec<_>>());
    for surface in surfaces {
        mux.close_surface(surface).unwrap();
    }
}

#[test]
fn focused_sidebar_uses_an_accent_divider() {
    let (mux, _) = test_mux("focused-sidebar-style-test", None);
    let mut app = test_app(Session::Local(mux.clone()));
    app.replace_tree(app.session.tree());
    app.config.sidebar.width = 20;
    app.sidebar_view = SidebarView::Workspaces;
    app.sync_layout((60, 12));

    let mut terminal = Terminal::new(TestBackend::new(60, 12)).unwrap();
    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
    assert_eq!(terminal.backend().buffer()[(19, 0)].symbol(), "│");

    app.focus = FocusTarget::WorkspaceRail;
    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
    let divider = &terminal.backend().buffer()[(19, 0)];
    assert_eq!(divider.symbol(), "┃");
    assert_eq!(divider.fg, app.config.theme.border_active);
    assert!(divider.modifier.contains(Modifier::BOLD));

    let surfaces = mux.with_state(|state| state.surfaces.keys().copied().collect::<Vec<_>>());
    for surface in surfaces {
        mux.close_surface(surface).unwrap();
    }
}
