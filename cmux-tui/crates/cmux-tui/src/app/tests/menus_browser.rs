//! Tests: remote command keys, context menu resources, browser surfaces and
//! the omnibar, client size menus and tabs.

use super::*;

#[test]
fn remote_command_k_uses_authoritative_screen_and_keyboard_modes() {
    let mux = Mux::new(
        "remote-command-k-authority-test",
        SurfaceOptions {
            command: Some(vec![
                "/bin/sh".to_string(),
                "-c".to_string(),
                "stty raw -echo; printf ready; exec cat".to_string(),
            ]),
            cols: 20,
            rows: 8,
            ..Default::default()
        },
    );
    let surface = mux.new_workspace(Some("work".to_string()), Some((20, 8))).unwrap();
    let attach = surface.attach_stream().unwrap();
    let deadline = Instant::now() + Duration::from_secs(1);
    let mut output = attach.replay.to_vec();
    while !output.windows(5).any(|window| window == b"ready") {
        match attach.stream.recv_timeout(Duration::from_millis(20)) {
            Ok(cmux_tui_core::AttachFrame::Output(bytes)) => output.extend_from_slice(&bytes),
            Ok(cmux_tui_core::AttachFrame::OutputWithColors { output: bytes, .. }) => {
                output.extend_from_slice(&bytes);
            }
            Ok(cmux_tui_core::AttachFrame::Resized { .. })
            | Ok(cmux_tui_core::AttachFrame::ResizedWithColors { .. })
            | Ok(cmux_tui_core::AttachFrame::ColorsChanged(_)) => {}
            Err(_) if Instant::now() < deadline => {}
            Err(error) => {
                panic!("remote alternate-screen helper did not become ready: {error}")
            }
        }
    }

    let dir = PathBuf::from(format!(
        "/tmp/cmux-k-auth-{}-{:?}",
        std::process::id(),
        std::thread::current().id()
    ));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("mux.sock");
    server::serve(mux.clone(), Some(socket.clone())).unwrap();
    let remote = RemoteSession::connect(&socket).unwrap();
    let session = Session::Remote(remote);
    let tree = session.refresh_tree().unwrap();
    let SurfaceAttach::Attached(mirror) =
        session.try_surface_sized(surface.id, Some((20, 8))).unwrap()
    else {
        panic!("authoritative surface did not attach");
    };
    assert_eq!(mirror.with_terminal(|terminal| terminal.active_screen()), Some(Screen::Primary));

    // This bypasses the attach stream to model a remote mirror that has
    // not received the server's authoritative screen or keyboard-mode
    // transitions yet.
    surface.with_terminal(|terminal| terminal.vt_write(b"\x1b[?1049h\x1b[>1u"));
    assert_eq!(surface.with_terminal(|terminal| terminal.active_screen()), Some(Screen::Alternate));

    let (mut app, _events) = test_app_with_events(session);
    app.sidebar_visible = false;
    app.replace_tree(tree);
    let action = app.handle_key(KeyEvent::new(KeyCode::Char('k'), KeyModifiers::SUPER)).unwrap();
    assert_eq!(action, RenderAction::None);
    assert!(app.pty_input.shutdown(Duration::from_secs(1)));

    let expected = b"\x1b[107;9u";
    let deadline = Instant::now() + Duration::from_secs(1);
    output.clear();
    while !output.windows(expected.len()).any(|window| window == expected) {
        match attach.stream.recv_timeout(Duration::from_millis(20)) {
            Ok(cmux_tui_core::AttachFrame::Output(bytes)) => output.extend_from_slice(&bytes),
            Ok(cmux_tui_core::AttachFrame::OutputWithColors { output: bytes, .. }) => {
                output.extend_from_slice(&bytes);
            }
            Ok(cmux_tui_core::AttachFrame::Resized { .. })
            | Ok(cmux_tui_core::AttachFrame::ResizedWithColors { .. })
            | Ok(cmux_tui_core::AttachFrame::ColorsChanged(_)) => {}
            Err(_) if Instant::now() < deadline => {}
            Err(error) => {
                panic!("authoritative alternate-screen app did not receive Command-K: {error}")
            }
        }
    }

    mux.close_surface(surface.id).unwrap();
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn clear_history_is_a_noop_for_browser_surfaces() {
    let mux = Mux::new("clear-history-browser-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux.clone()));
    let surface = 73;
    app.tree = browser_completion_tree(surface, surface);
    app.render_states.insert(surface, RenderState::new().unwrap());
    app.selection = Some(Selection { surface, anchor: (1, 1), head: (2, 1) });

    let action = app.run_action(Action::ClearHistory).unwrap();

    assert_eq!(action, RenderAction::None);
    assert!(!app.session.has_pending_mutations());
    assert!(app.render_states.contains_key(&surface));
    assert!(app.selection.is_some_and(|selection| selection.surface == surface));
    assert!(app.status_message.is_none());
    mux.shutdown();
}

#[test]
fn vertical_split_drag_keeps_nested_pane_tab_bars_visible() {
    let mux = Mux::new("nested-pane-minimum-height-test", SurfaceOptions::default());
    mux.new_workspace(None, Some((80, 18))).unwrap();
    let first = Session::Local(mux.clone()).tree().active_screen().unwrap().active_pane;
    mux.split(first, SplitDir::Down, Some((80, 9))).unwrap();
    assert!(mux.focus_pane(first));
    mux.split(first, SplitDir::Down, Some((80, 5))).unwrap();
    let nested_bottom = Session::Local(mux.clone()).tree().active_screen().unwrap().active_pane;

    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    app.sidebar_visible = false;
    app.replace_tree(app.session.tree());
    app.sync_layout((80, 19));
    while app.session.has_pending_mutations() {
        app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
    }

    for y in [0, 17] {
        let target = app
            .resolve_pane_resize_drag(nested_bottom, PaneEdge::Bottom)
            .expect("nested split divider must remain draggable");
        app.resize_drag_target(target, 0, y);
        app.session.settle_split_ratio();
        while app.session.has_pending_mutations() {
            app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
        }
        app.sync_layout((80, 19));

        assert_eq!(app.pane_areas.len(), 3);
        assert!(
            app.pane_areas.iter().all(|area| area.rect.height >= 3 && area.bar.is_some()),
            "every pane must retain its tab bar after dragging to y={y}: {:?}",
            app.pane_areas.iter().map(|area| (area.pane, area.rect, area.bar)).collect::<Vec<_>>()
        );

        while app.session.has_pending_mutations() {
            app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
        }
    }

    let surfaces = mux.with_state(|state| state.surfaces.keys().copied().collect::<Vec<_>>());
    for surface in surfaces {
        mux.close_surface(surface).unwrap();
    }
}

#[test]
fn ancestor_split_minimum_accounts_for_descendant_ratios() {
    let root = Node::Split {
        id: 1,
        dir: SplitDir::Down,
        ratio: 0.5,
        a: Box::new(Node::Split {
            id: 2,
            dir: SplitDir::Down,
            ratio: 0.05,
            a: Box::new(Node::Leaf(1)),
            b: Box::new(Node::Leaf(2)),
        }),
        b: Box::new(Node::Leaf(3)),
    };
    let clamped = clamp_split_ratio_for_tab_bars(&root, 1, 100, 0.05);
    let mut resized = root;
    let Node::Split { ratio, .. } = &mut resized else {
        unreachable!();
    };
    *ratio = clamped;

    let layout = layout_screen(&resized, Rect { x: 0, y: 0, width: 80, height: 100 }, Some(1));
    assert!(
        layout.panes.iter().all(|(_, rect)| rect.height >= 3),
        "nested ratios must preserve every pane minimum: {:?}",
        layout.panes
    );
}

#[test]
fn infeasible_full_minimum_falls_back_to_bar_only_minimums() {
    let root = Node::Split {
        id: 1,
        dir: SplitDir::Down,
        ratio: 0.5,
        a: Box::new(Node::Split {
            id: 2,
            dir: SplitDir::Down,
            ratio: 0.5,
            a: Box::new(Node::Leaf(1)),
            b: Box::new(Node::Leaf(2)),
        }),
        b: Box::new(Node::Leaf(3)),
    };
    let clamped = clamp_split_ratio_for_tab_bars(&root, 1, 8, 0.05);
    let mut resized = root;
    let Node::Split { ratio, .. } = &mut resized else {
        unreachable!();
    };
    *ratio = clamped;

    let layout = layout_screen(&resized, Rect { x: 0, y: 0, width: 80, height: 8 }, Some(1));
    assert!(
        layout.panes.iter().all(|(_, rect)| rect.height >= 1),
        "bar-only fallback must keep every pane visible: {:?}",
        layout.panes
    );
}

#[test]
fn alt_n_rejects_a_new_pane_with_no_visible_content() {
    let (mux, _) = test_mux("alt-n-zero-content-test", None);
    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    app.sidebar_visible = false;
    app.replace_tree(app.session.tree());

    for _ in 0..3 {
        app.sync_layout((200, 40));
        app.handle_key(KeyEvent::new(KeyCode::Char('n'), KeyModifiers::ALT)).unwrap();
        while app.session.has_pending_mutations() {
            let event = events.recv_timeout(Duration::from_secs(5)).unwrap();
            app.handle(event).unwrap();
        }
    }
    let before = app.tree.active_screen().unwrap().clone();
    let mut before_panes = Vec::new();
    before.layout.pane_ids(&mut before_panes);
    assert_eq!(before_panes.len(), 4);

    app.sync_layout((200, 4));
    app.handle_key(KeyEvent::new(KeyCode::Char('n'), KeyModifiers::ALT)).unwrap();
    while app.session.has_pending_mutations() {
        let event = events.recv_timeout(Duration::from_secs(5)).unwrap();
        app.handle(event).unwrap();
    }

    let after = app.tree.active_screen().unwrap();
    let mut after_panes = Vec::new();
    after.layout.pane_ids(&mut after_panes);
    assert_eq!(after_panes, before_panes);
    assert_eq!(after.active_pane, before.active_pane);

    let surfaces = mux.with_state(|state| state.surfaces.keys().copied().collect::<Vec<_>>());
    for surface in surfaces {
        mux.close_surface(surface).unwrap();
    }
}

#[test]
fn context_menu_selection_and_hit_testing_skip_separators() {
    let mut menu = ContextMenu::at(
        10,
        5,
        vec![
            vec![MenuAction::RenameTab(7), MenuAction::CloseTab(7)],
            Vec::new(),
            vec![MenuAction::NewTab(7)],
        ],
    );

    assert_eq!(menu.item_at(10, 5), Some(0));
    assert_eq!(menu.item_at(10, 7), None);
    assert_eq!(menu.item_at(10, 8), Some(3));
    assert_eq!(menu.selected_action(), Some(MenuAction::RenameTab(7)));

    menu.select_next();
    assert_eq!(menu.selected_action(), Some(MenuAction::CloseTab(7)));
    menu.select_next();
    assert_eq!(menu.selected_action(), Some(MenuAction::NewTab(7)));
    menu.select_next();
    assert_eq!(menu.selected_action(), Some(MenuAction::NewTab(7)));
    menu.select_previous();
    assert_eq!(menu.selected_action(), Some(MenuAction::CloseTab(7)));

    menu.select_last();
    assert_eq!(menu.selected_action(), Some(MenuAction::NewTab(7)));
    menu.select_first();
    assert_eq!(menu.selected_action(), Some(MenuAction::RenameTab(7)));

    menu.levels[0].selected = usize::MAX;
    menu.select_previous();
    menu.select_next();
    assert_eq!(menu.levels[0].selected, usize::MAX);
    assert_eq!(menu.selected_action(), None);

    let mut empty = ContextMenu::at(10, 5, Vec::new());
    empty.select_previous();
    empty.select_next();
    assert_eq!(empty.selected_action(), None);
}

#[test]
fn context_menu_home_and_end_keys_jump_to_action_rows() {
    let mux = Mux::new("context-menu-home-end-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.menu = Some(ContextMenu::at(
        10,
        5,
        vec![
            vec![MenuAction::RenameTab(7), MenuAction::CloseTab(7)],
            Vec::new(),
            vec![MenuAction::NewTab(7)],
        ],
    ));

    app.handle_menu_key(KeyEvent::new(KeyCode::End, KeyModifiers::NONE)).unwrap();
    assert_eq!(
        app.menu.as_ref().and_then(ContextMenu::selected_action),
        Some(MenuAction::NewTab(7))
    );

    app.handle_menu_key(KeyEvent::new(KeyCode::Home, KeyModifiers::NONE)).unwrap();
    assert_eq!(
        app.menu.as_ref().and_then(ContextMenu::selected_action),
        Some(MenuAction::RenameTab(7))
    );
}

#[test]
fn context_menu_supports_arbitrarily_nested_submenus() {
    let mut menu = ContextMenu::with_groups(
        10,
        5,
        vec![vec![MenuItem::Submenu {
            label: "Clients".to_string(),
            items: vec![MenuItem::Submenu {
                label: "client 7 · 80×24".to_string(),
                items: vec![MenuItem::Action(MenuAction::DisconnectClient(7))],
            }],
        }]],
    );

    assert_eq!(menu.action_at(0, 0), None);
    assert!(menu.open_selected_submenu());
    assert_eq!(menu.levels.len(), 2);
    assert!(menu.open_selected_submenu());
    assert_eq!(menu.levels.len(), 3);
    assert_eq!(menu.selected_action(), Some(MenuAction::DisconnectClient(7)));
    assert!(menu.close_submenu());
    assert_eq!(menu.levels.len(), 2);
    assert!(menu.close_submenu());
    assert_eq!(menu.levels.len(), 1);
    assert!(!menu.close_submenu());
}

#[test]
fn searchable_context_menu_filters_large_catalogs_and_keeps_fallback() {
    let items = (0..4_096)
        .map(|index| MenuItem::LabeledAction {
            label: format!("cloud-mac-{index:04}"),
            action: MenuAction::ConnectMachineTarget(index),
        })
        .collect::<Vec<_>>();
    let mut menu = ContextMenu::searchable(
        10,
        5,
        "SSH hosts",
        "type to filter",
        items,
        vec![MenuItem::Action(MenuAction::ConnectOtherMachine)],
    );

    assert_eq!(menu.actions().len(), 4_097);
    assert_eq!(menu.levels[0].items[0].action(), Some(MenuAction::ConnectOtherMachine));
    assert_eq!(menu.levels[0].items[1], MenuItem::Separator);
    assert_eq!(menu.levels[0].items[2].label(), Some("cloud-mac-0000"));
    assert!(menu.insert_search_text("3999"));
    assert_eq!(menu.levels[0].items.len(), 3);
    assert_eq!(menu.levels[0].items[0].action(), Some(MenuAction::ConnectOtherMachine));
    assert_eq!(menu.levels[0].items[1], MenuItem::Separator);
    assert_eq!(menu.levels[0].items[2].label(), Some("cloud-mac-3999"));
    assert_eq!(menu.selected_action(), Some(MenuAction::ConnectMachineTarget(3_999)));

    assert!(menu.handle_search_key(&KeyEvent::new(KeyCode::Char('c'), KeyModifiers::CONTROL,)));
    assert_eq!(menu.levels[0].items.len(), 4_098);
}

#[test]
fn overflowing_connect_machine_menu_draws_and_wheels_a_scrollbar() {
    let mux = Mux::new("connect-menu-scrollbar-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    let mut ui = MachineUiState::new(MachineSnapshot {
        machines: Vec::new(),
        active: None,
        capabilities: MachineCapabilities { create: false, connect: true },
    });
    ui.connection_targets = (0..40)
        .map(|index| MachineConnectionTarget {
            target: format!("ssh-host-{index:02}"),
            name: format!("ssh-host-{index:02}"),
        })
        .collect();
    app.machine_ui = Some(ui);
    app.open_machine_connection_menu(1, 3);

    let mut terminal = Terminal::new(TestBackend::new(40, 8)).unwrap();
    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
    let rect = app.menu.as_ref().unwrap().levels[0].rect;
    let track_x = rect.x + rect.width.saturating_sub(2);
    let buffer = terminal.backend().buffer();
    assert!(
        (rect.y + 1..rect.y + rect.height.saturating_sub(1))
            .any(|y| matches!(buffer[(track_x, y)].symbol(), "▕" | "▐")),
        "overflowing SSH host picker must render its scrollbar thumb"
    );

    let action = app.handle_scroll(track_x, rect.y + 1, true, KeyModifiers::NONE).unwrap();
    assert_eq!(action, RenderAction::Draw);
    assert!(app.menu.as_ref().unwrap().levels[0].scroll_offset > 0);
}

#[test]
fn context_menu_scrollbar_track_clicks_and_drags() {
    let mux = Mux::new("context-menu-scrollbar-pointer-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    let items = (0..40)
        .map(|index| MenuItem::LabeledAction {
            label: format!("ssh-host-{index:02}"),
            action: MenuAction::ConnectMachineTarget(index),
        })
        .collect();
    app.menu = Some(ContextMenu::searchable(
        1,
        3,
        "SSH hosts",
        "type to filter",
        items,
        vec![MenuItem::Action(MenuAction::ConnectOtherMachine)],
    ));
    let mut terminal = Terminal::new(TestBackend::new(40, 8)).unwrap();
    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
    let rect = app.menu.as_ref().unwrap().levels[0].rect;
    let track_x = rect.x + rect.width.saturating_sub(2);
    let track_top = rect.y + 1;
    let track_bottom = rect.y + rect.height.saturating_sub(2);

    app.handle_left_down(track_x, track_bottom, KeyModifiers::NONE).unwrap();
    assert!(app.menu.as_ref().unwrap().levels[0].scroll_offset > 0);
    app.handle_left_drag(track_x, track_top).unwrap();
    assert_eq!(app.menu.as_ref().unwrap().levels[0].scroll_offset, 0);
    app.handle_left_up(track_x, track_top).unwrap();
    assert!(app.menu.is_some());
}

#[test]
fn topmost_menu_chrome_blocks_hits_on_overlapped_parent_actions() {
    let mut menu = ContextMenu::with_groups(
        10,
        5,
        vec![vec![MenuItem::Submenu {
            label: "Clients".to_string(),
            items: vec![MenuItem::Action(MenuAction::RestoreAllClientSizing(31))],
        }]],
    );
    assert!(menu.open_selected_submenu());
    menu.levels[1].rect = Rect { x: 10, y: 5, width: 20, height: 3 };

    assert_eq!(menu.hit_at(10, 5), None);
    assert_eq!(menu.selected_action(), Some(MenuAction::RestoreAllClientSizing(31)));
}

#[test]
fn control_only_client_menu_offers_disconnect_without_sizing_actions() {
    let client = ClientInfo {
        client: 7,
        transport: "unix".to_string(),
        name: Some("control".to_string()),
        kind: Some("web".to_string()),
        connected_seconds: 1,
        attached: Vec::new(),
        sizes: Vec::new(),
        is_self: false,
    };
    let Some(MenuItem::Submenu { items, .. }) = client_menu_item(&[client], 31) else {
        panic!("expected connected clients submenu");
    };
    let MenuItem::Submenu { items, .. } = &items[2] else {
        panic!("expected client submenu");
    };
    assert_eq!(items, &vec![MenuItem::Action(MenuAction::DisconnectClient(7))]);
}

#[test]
fn current_client_size_action_is_immediately_above_restore_all() {
    let current = ClientInfo {
        client: 7,
        transport: "unix".to_string(),
        name: None,
        kind: Some("tui".to_string()),
        connected_seconds: 1,
        attached: vec![31],
        sizes: vec![ClientSizeInfo {
            surface: 31,
            cols: Some(80),
            rows: Some(24),
            size_participating: true,
        }],
        is_self: true,
    };
    let Some(MenuItem::Submenu { items, .. }) = client_menu_item(&[current], 31) else {
        panic!("expected connected clients submenu");
    };
    assert_eq!(
        &items[..2],
        &[
            MenuItem::Action(MenuAction::UseClientSize { surface: 31, client: 7 }),
            MenuItem::Action(MenuAction::RestoreAllClientSizing(31)),
        ]
    );
}

#[test]
fn disconnecting_this_client_uses_clean_detach_without_a_socket_round_trip() {
    let mux = Mux::new("self-disconnect-menu-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.clients = vec![ClientInfo {
        client: 7,
        transport: "unix".to_string(),
        name: Some("this tui".to_string()),
        kind: Some("tui".to_string()),
        connected_seconds: 1,
        attached: vec![],
        sizes: vec![],
        is_self: true,
    }];

    assert!(app.activate_menu(MenuAction::DisconnectClient(7)).is_ok());
    assert!(app.quit, "self-disconnect must take the same clean exit path as Ctrl-b d");

    assert!(app.activate_menu(MenuAction::DisconnectClient(7)).is_ok());
    assert!(app.quit, "repeated self-disconnect must remain idempotent");
}

#[test]
fn stale_peer_disconnect_is_an_idempotent_noop_without_quitting_the_tui() {
    let mux = Mux::new("stale-peer-disconnect-test", SurfaceOptions::default());
    let (mut app, events) = test_app_with_events(Session::Local(mux));
    app.clients = vec![ClientInfo {
        client: 7,
        transport: "unix".to_string(),
        name: Some("stale peer".to_string()),
        kind: Some("tui".to_string()),
        connected_seconds: 1,
        attached: vec![],
        sizes: vec![],
        is_self: false,
    }];

    assert!(app.activate_menu(MenuAction::DisconnectClient(7)).is_ok());
    assert!(!app.quit);
    let event = events.recv_timeout(crate::test_wait::EVENT).unwrap();
    assert!(matches!(
        event,
        AppEvent::SessionMutationSettled {
            outcome: crate::app::SessionMutationOutcome::Success { .. },
            ..
        }
    ));
    assert!(app.handle(event).is_ok());
    assert!(!app.quit);
    assert!(app.status_message.is_none());
}

fn sizing_test_state(mode: TerminalSizingMode) -> SurfaceSizeState {
    use cmux_tui_core::sizing_policy::{
        TerminalDeviceKind, TerminalGridSize, TerminalSizingEngine, TerminalSizingParticipant,
    };
    let mut engine = TerminalSizingEngine::new(
        TerminalGridSize::new(80, 24),
        TerminalSizingPolicy::new(mode, Vec::new(), None),
    );
    engine.attach(TerminalSizingParticipant {
        viewport: Some(TerminalGridSize::new(100, 40)),
        ..TerminalSizingParticipant::new("c0", TerminalDeviceKind::Tui)
    });
    engine.attach(TerminalSizingParticipant {
        display_name: Some("Maya Ortiz".into()),
        device_name: Some("Mac Studio".into()),
        viewport: Some(TerminalGridSize::new(118, 30)),
        ..TerminalSizingParticipant::new("c7", TerminalDeviceKind::Mac)
    });
    SurfaceSizeState { state: engine.state().clone(), self_participant: Some("c0".into()) }
}

#[test]
fn shared_size_menu_offers_the_five_modes_and_per_participant_controls() {
    let size = sizing_test_state(TerminalSizingMode::Smallest);
    let MenuItem::Submenu { label, items } = size_menu_item(&size, 31) else {
        panic!("expected the terminal size submenu");
    };
    assert_eq!(label, "Terminal size");
    let modes = items[..5]
        .iter()
        .map(|item| match item {
            MenuItem::LabeledAction {
                label,
                action: MenuAction::SetSizeMode { surface: 31, mode },
            } => (label.as_str(), *mode),
            other => panic!("expected a mode action, got {other:?}"),
        })
        .collect::<Vec<_>>();
    assert_eq!(
        modes,
        [
            ("✓ Fit everyone", TerminalSizingMode::Smallest),
            ("  Follow latest", TerminalSizingMode::Latest),
            ("  Largest window", TerminalSizingMode::Largest),
            ("  Priority", TerminalSizingMode::Priority),
            ("  Fixed", TerminalSizingMode::Fixed),
        ]
    );
    assert_eq!(items[5], MenuItem::Separator);
    let generation = size.state.generation;
    let MenuItem::Submenu { label, items: row } = &items[7] else {
        panic!("expected the Mac participant row");
    };
    assert_eq!(label, "Maya Ortiz · Mac Studio · 118×30 · sets size");
    assert_eq!(
        row,
        &vec![
            MenuItem::LabeledAction {
                label: "✓ Counts toward size".into(),
                action: MenuAction::SetSizeCounts {
                    surface: 31,
                    generation,
                    participant: 1,
                    counts: false,
                },
            },
            MenuItem::Separator,
            MenuItem::Action(MenuAction::DisconnectSizeParticipant {
                surface: 31,
                generation,
                participant: 1,
            }),
        ]
    );
    let MenuItem::Submenu { label, .. } = &items[6] else {
        panic!("expected this client's row");
    };
    assert_eq!(label, "this client · 100×40 · sets size");
}

#[test]
fn size_menu_commands_reach_the_shared_sizing_host() {
    let mux = Mux::new("size-menu-commands-test", crate::test_wait::quiet_surface());
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    mux.resize_surface_for_client(surface.id, 0, 100, 40).unwrap();
    mux.resize_surface_for_client(surface.id, 7, 118, 30).unwrap();
    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    let settle = |app: &mut App| {
        crate::test_wait::recv_until(&events, "SessionMutationSettled", |event| {
            let settled = matches!(event, AppEvent::SessionMutationSettled { .. });
            assert!(app.handle(event).is_ok());
            settled
        });
    };

    app.activate_menu(MenuAction::SetSizeMode {
        surface: surface.id,
        mode: TerminalSizingMode::Latest,
    })
    .unwrap();
    settle(&mut app);
    let state = mux.terminal_size_state(surface.id).unwrap();
    assert_eq!(state.policy.mode, TerminalSizingMode::Latest);

    let mac = state.participants.iter().position(|row| row.participant.id == "c7").unwrap();
    app.activate_menu(MenuAction::SetSizeCounts {
        surface: surface.id,
        generation: state.generation,
        participant: mac,
        counts: false,
    })
    .unwrap();
    settle(&mut app);
    let state = mux.terminal_size_state(surface.id).unwrap();
    assert!(!state.participant("c7").unwrap().counts);
    assert_eq!(state.size(), cmux_tui_core::sizing_policy::TerminalGridSize::new(100, 40));

    // A menu opened on an older state is stale and changes nothing.
    app.activate_menu(MenuAction::SetSizeCounts {
        surface: surface.id,
        generation: state.generation - 1,
        participant: mac,
        counts: true,
    })
    .unwrap();
    assert!(app.status_message.is_some());
    assert!(!mux.terminal_size_state(surface.id).unwrap().participant("c7").unwrap().counts);
    drop(app);
    mux.shutdown();
}

#[test]
fn peer_disconnect_uses_the_pointer_mutation_barrier() {
    let mux = Mux::new("disconnect-pointer-barrier-test", SurfaceOptions::default());
    let (mut app, events) = test_app_with_events(Session::Local(mux));
    let (started_tx, started_rx) = std::sync::mpsc::channel();
    let (release_tx, release_rx) = std::sync::mpsc::channel();
    app.session.operations.enqueue_session_mutation("block disconnect lane", false, move || {
        started_tx.send(()).unwrap();
        release_rx.recv().unwrap();
        Ok(())
    });
    started_rx.recv_timeout(Duration::from_secs(1)).unwrap();

    app.session.disconnect_client(7);

    let pointer_pending = app.session.has_pending_pointer_mutations();
    release_tx.send(()).unwrap();
    let settled = events.recv_timeout(crate::test_wait::EVENT).unwrap();
    app.handle(settled).unwrap();
    assert!(
        pointer_pending,
        "disconnect can resize surfaces and must block pointer routing until it settles"
    );
    assert!(!app.session.has_pending_mutations());
}

#[test]
fn synthetic_local_client_cannot_be_disconnected_from_the_menu() {
    let local = ClientInfo {
        client: 0,
        transport: "local".to_string(),
        name: Some("local tui".to_string()),
        kind: Some("tui".to_string()),
        connected_seconds: 1,
        attached: vec![31],
        sizes: vec![ClientSizeInfo {
            surface: 31,
            cols: Some(80),
            rows: Some(24),
            size_participating: true,
        }],
        is_self: true,
    };
    let Some(MenuItem::Submenu { items, .. }) = client_menu_item(&[local], 31) else {
        panic!("expected connected clients submenu");
    };
    assert!(!items.iter().any(|item| matches!(
        item,
        MenuItem::Submenu { items, .. }
            if items.iter().any(|action| matches!(
                action,
                MenuItem::Action(MenuAction::DisconnectClient(0))
            ))
    )));
}

#[test]
fn browser_context_menu_keeps_browser_actions_in_their_own_group() {
    let pane = 7;
    let groups = pane_context_menu_groups(pane, true, true);

    assert_eq!(
        groups[2],
        vec![
            MenuAction::BrowserBack(pane),
            MenuAction::BrowserForward(pane),
            MenuAction::BrowserReload(pane),
            MenuAction::BrowserEditUrl(pane),
            MenuAction::BrowserCopyUrl(pane),
            MenuAction::BrowserActivate(pane),
        ]
    );
}

#[test]
fn context_menu_drops_only_overflowing_separators_and_restores_them_after_resize() {
    let pane = 7;
    let mut menu = ContextMenu::at(10, 5, pane_context_menu_groups(pane, true, true));
    menu.levels[0].selected = menu.levels[0]
        .items
        .iter()
        .position(|item| item.action() == Some(MenuAction::CopyPaneId(pane)))
        .unwrap();

    assert_eq!(menu.levels[0].items.len(), 20);
    assert_eq!(menu.levels[0].items.iter().filter(|item| **item == MenuItem::Separator).count(), 4);
    menu.fit_to_rows(18);
    assert_eq!(menu.levels[0].items.len(), 18);
    assert_eq!(menu.levels[0].items.iter().filter(|item| **item == MenuItem::Separator).count(), 2);
    assert_eq!(menu.selected_action(), Some(MenuAction::CopyPaneId(pane)));
    assert_eq!(menu.levels[0].rect.height, 20);

    menu.fit_to_rows(20);
    assert_eq!(menu.levels[0].items.len(), 20);
    assert_eq!(menu.levels[0].items.iter().filter(|item| **item == MenuItem::Separator).count(), 4);
    assert_eq!(menu.selected_action(), Some(MenuAction::CopyPaneId(pane)));
}

#[test]
fn context_menu_scrolls_selection_and_hit_testing_through_tall_client_lists() {
    let mut menu = ContextMenu::at(
        10,
        5,
        vec![((1..=8).map(|client| MenuAction::UseClientSize { surface: 31, client }).collect())],
    );

    menu.fit_to_rows(3);
    assert_eq!(menu.levels[0].rect.height, 5);
    assert_eq!(menu.levels[0].scroll_offset, 0);

    for _ in 0..4 {
        menu.select_next();
    }

    assert_eq!(menu.selected_action(), Some(MenuAction::UseClientSize { surface: 31, client: 5 }));
    assert_eq!(menu.levels[0].scroll_offset, 2);
    assert_eq!(menu.item_at(10, 5), Some(2));
    assert_eq!(menu.item_at(10, 7), Some(4));
}

#[test]
fn browser_omnibar_reduces_content_rect_for_graphics_and_input() {
    let rect = Rect { x: 10, y: 4, width: 80, height: 24 };
    let (_bar, omnibar, content, track) =
        pane_parts_for_rect(rect, ScrollbarPosition::Column, 0, true);
    assert_eq!(omnibar, Some(Rect { x: 11, y: 5, width: 77, height: 1 }));
    assert_eq!(content, Rect { x: 11, y: 6, width: 77, height: 21 });
    assert_eq!(track, Some(Rect { x: 88, y: 5, width: 1, height: 22 }));
}

#[test]
fn pane_padding_insets_content_and_keeps_at_least_one_cell() {
    let rect = Rect { x: 10, y: 4, width: 80, height: 24 };
    let (bar, _, content, track) = pane_parts_for_rect(rect, ScrollbarPosition::Column, 2, false);
    // Bar and track keep the border geometry; only content is inset.
    assert_eq!(bar, Some(Rect { x: 10, y: 4, width: 80, height: 1 }));
    assert_eq!(track, Some(Rect { x: 88, y: 5, width: 1, height: 22 }));
    assert_eq!(content, Rect { x: 13, y: 7, width: 73, height: 18 });

    // A tiny pane never pads itself out of existence.
    let tiny = Rect { x: 0, y: 0, width: 5, height: 4 };
    let (_, _, content, _) = pane_parts_for_rect(tiny, ScrollbarPosition::Border, 4, false);
    assert!(content.width >= 1 && content.height >= 1, "content survived: {content:?}");

    // Padded content sizes drive PTY sizing through the same helper.
    assert_eq!(content_size_for_rect(rect, ScrollbarPosition::Column, 0), Some((77, 22)));
    assert_eq!(content_size_for_rect(rect, ScrollbarPosition::Column, 2), Some((73, 18)));
}

#[test]
fn hidden_status_bar_gives_the_bottom_row_to_panes() {
    let mut config = Config::default();
    let overrides = SidebarWidthOverrides::default();
    let visible = sidebar_layout_for(&config, true, false, false, (100, 30), overrides);
    assert_eq!(visible.content.height, 29);
    config.status_bar.visible = false;
    let hidden = sidebar_layout_for(&config, true, false, false, (100, 30), overrides);
    assert_eq!(hidden.content.height, 30);
}

#[test]
fn clipped_browser_omnibar_keeps_logical_hit_coordinates() {
    let mux = Mux::new("clipped-browser-omnibar-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.replace_tree(browser_completion_tree(41, 41));
    app.pane_areas.push(PaneArea {
        pane: 2,
        surface: 41,
        rect: Rect { x: 20, y: 4, width: 10, height: 8 },
        bar: Some(Rect { x: 20, y: 4, width: 10, height: 1 }),
        omnibar: Some(Rect { x: 20, y: 5, width: 8, height: 1 }),
        content: Rect { x: 20, y: 6, width: 8, height: 5 },
        track: None,
        viewport: Some(PaneViewportClip {
            rect_source_x: 4,
            full_rect_width: 40,
            omnibar_source_x: 4,
            full_omnibar_width: 38,
            content_source_x: 4,
            full_content_width: 38,
        }),
    });

    assert_eq!(app.omnibar_hit_at(21, 5), Some((2, OmnibarHit::Reload)));
    assert_eq!(app.omnibar_hit_at(23, 5), Some((2, OmnibarHit::Edit)));
    assert_eq!(app.omnibar_hit_at(20, 5), None);
}

#[test]
fn clipped_browser_omnibar_keeps_editing_and_clicks_visible() {
    let mux = Mux::new("clipped-browser-omnibar-edit-test", SurfaceOptions::default());
    let surface = mux.new_browser_tab("about:blank".to_string(), None, Some((38, 5))).unwrap();
    let mut app = test_app(Session::Local(mux.clone()));
    app.replace_tree(app.session.tree());
    let pane = app.tree.active_screen().expect("active screen").active_pane;
    let area = PaneArea {
        pane,
        surface: surface.id,
        rect: Rect { x: 20, y: 4, width: 10, height: 8 },
        bar: Some(Rect { x: 20, y: 4, width: 10, height: 1 }),
        omnibar: Some(Rect { x: 20, y: 5, width: 8, height: 1 }),
        content: Rect { x: 20, y: 6, width: 8, height: 5 },
        track: None,
        viewport: Some(PaneViewportClip {
            rect_source_x: 4,
            full_rect_width: 40,
            omnibar_source_x: 4,
            full_omnibar_width: 38,
            content_source_x: 4,
            full_content_width: 38,
        }),
    };
    app.pane_areas.push(area);
    app.omnibar = Some(OmnibarState {
        pane,
        surface: surface.id,
        input: TextInput::new("x".to_string()),
        select_all: false,
    });

    let mut terminal = Terminal::new(TestBackend::new(40, 12)).unwrap();
    let mut cursor = None;
    terminal
        .draw(|frame| {
            cursor = crate::ui::omnibar::draw(&mut app, frame, &area);
        })
        .unwrap();
    assert_eq!(terminal.backend().buffer()[(20, 5)].symbol(), "x");
    assert_eq!(cursor, Some((21, 5)));

    app.omnibar.as_mut().unwrap().input = TextInput::new("0123456789".to_string());
    app.handle_left_down(22, 5, KeyModifiers::NONE).unwrap();
    assert_eq!(
        app.omnibar.as_mut().unwrap().input.visible_text_and_cursor(38).1,
        2,
        "a click must use the visible editor column, not the cropped logical column"
    );
    mux.shutdown();
}

#[test]
fn browser_omnibar_places_stall_suffix_after_emoji_display_cells() {
    let mux = Mux::new("emoji-browser-omnibar-test", SurfaceOptions::default());
    let surface = mux.new_browser_tab("emoji:👩‍💻".to_string(), None, Some((48, 8))).unwrap();
    let mut app = test_app(Session::Local(mux.clone()));
    app.sidebar_visible = false;
    app.replace_tree(app.session.tree());
    app.sync_layout((50, 12));
    let pane = app.tree.active_screen().unwrap().active_pane;
    let tab = app
        .tree
        .active_workspace_mut_screen()
        .unwrap()
        .panes
        .iter_mut()
        .find(|candidate| candidate.id == pane)
        .unwrap()
        .tabs
        .first_mut()
        .unwrap();
    tab.browser_frames_stalled = true;
    let area = *app.pane_areas.iter().find(|area| area.pane == pane).unwrap();
    let omnibar = area.omnibar.unwrap();
    let handle = app.session.surface(surface.id).unwrap();
    let mut label = handle.browser_url().unwrap();
    if matches!(handle.browser_status(), Some(BrowserStatus::Starting))
        || (matches!(handle.browser_status(), Some(BrowserStatus::Live))
            && !handle.has_browser_frame())
    {
        label.push('…');
    }
    let suffix = " ⏸ chrome tab hidden";
    let max = omnibar.width.saturating_sub(9) as usize;
    let label_max = max - suffix.width();
    let text = crate::ui::truncate(&label, label_max);
    let expected_icon_x = omnibar.x + 9 + text.width() as u16 + 1;

    let mut terminal = Terminal::new(TestBackend::new(50, 12)).unwrap();
    terminal
        .draw(|frame| {
            crate::ui::omnibar::draw(&mut app, frame, &area);
        })
        .unwrap();
    assert_eq!(
        terminal.backend().buffer()[(expected_icon_x, omnibar.y)].symbol(),
        "⏸",
        "the stall suffix must start after the label's display cells"
    );

    mux.shutdown();
}

#[test]
fn browser_omnibar_degrades_gracefully_with_one_content_row() {
    let rect = Rect { x: 0, y: 0, width: 20, height: 3 };
    let (_bar, omnibar, content, _track) =
        pane_parts_for_rect(rect, ScrollbarPosition::Border, 0, true);
    assert_eq!(omnibar, None);
    assert_eq!(content, Rect { x: 1, y: 1, width: 18, height: 1 });
}

#[test]
fn tiny_pane_reserves_its_first_row_for_the_tab_bar() {
    for height in [1, 2] {
        let rect = Rect { x: 4, y: 5, width: 20, height };
        let (bar, omnibar, content, track) =
            pane_parts_for_rect(rect, ScrollbarPosition::Border, 0, false);

        assert_eq!(bar, Some(Rect { height: 1, ..rect }));
        assert_eq!(omnibar, None);
        assert_eq!(content.height, 0);
        assert_eq!(track, None);
    }
}

#[test]
fn narrow_tall_pane_keeps_unboxed_terminal_content() {
    let rect = Rect { x: 4, y: 5, width: 2, height: 20 };
    let (bar, omnibar, content, track) =
        pane_parts_for_rect(rect, ScrollbarPosition::Border, 0, false);

    assert_eq!(bar, None);
    assert_eq!(omnibar, None);
    assert_eq!(content, rect);
    assert_eq!(track, None);
}

#[test]
fn browser_tab_size_hint_uses_omnibar_reduced_content() {
    let rect = Rect { x: 10, y: 4, width: 80, height: 24 };
    assert_eq!(browser_content_size_for_rect(rect, ScrollbarPosition::Column, 0), Some((77, 21)));
}

#[test]
fn hover_forwarding_only_runs_for_live_non_editing_browser() {
    assert!(browser_hover_forward_allowed(Some(BrowserStatus::Live), false));
    assert!(!browser_hover_forward_allowed(Some(BrowserStatus::Live), true));
    assert!(!browser_hover_forward_allowed(Some(BrowserStatus::Starting), false));
    assert!(!browser_hover_forward_allowed(Some(BrowserStatus::Failed("boom".to_string())), false));
    assert!(!browser_hover_forward_allowed(None, false));
}

#[test]
fn browser_hover_deduplication_is_scoped_to_pointer_authority() {
    let surface_id = 7;
    let mut app = test_app(crate::session::test_remote_session_with_live_browser(surface_id, 41));
    app.replace_tree(browser_completion_tree(surface_id, surface_id));
    let area = browser_completion_area(surface_id);
    app.pane_areas = vec![area];
    app.rendered_pointer_frame.pane_content_generations =
        Arc::new(HashMap::from([(surface_id, PaneContentGeneration::Browser(41))]));
    let (dispatcher, blocked) = BrowserInputDispatcher::blocked(4);
    app.browser_input = dispatcher;
    let motion = MouseEvent {
        kind: MouseEventKind::Moved,
        column: area.content.x + 2,
        row: area.content.y + 1,
        modifiers: KeyModifiers::NONE,
    };

    app.handle_mouse(motion).unwrap();
    let first = blocked.recv_timeout(Duration::from_secs(1)).expect("initial browser hover");
    app.handle_mouse(motion).unwrap();
    let duplicate = blocked.recv_timeout(Duration::from_millis(20));
    app.rendered_pointer_frame.pane_content_generations =
        Arc::new(HashMap::from([(surface_id, PaneContentGeneration::Browser(42))]));
    app.handle_mouse(motion).unwrap();
    let rotated = blocked.recv_timeout(Duration::from_secs(1)).expect("rotated-authority hover");

    let frame_seq = |event: BrowserInputEvent| match event.kind {
        BrowserInputKind::Mouse { frame_seq, .. } => frame_seq,
        _ => panic!("expected browser mouse input"),
    };
    assert_eq!(frame_seq(first), 41);
    assert!(
        duplicate.is_none(),
        "same-cell hover must be deduplicated within one pointer authority"
    );
    assert!(
        frame_seq(rotated) == 42,
        "same-cell hover must be forwarded again when pointer authority changes"
    );
}

#[test]
fn final_browser_pointer_admission_accepts_exact_presented_frame() {
    let surface_id = 7;
    let mut app = test_app(crate::session::test_remote_session_with_browser_pointer_range(
        surface_id, 41, 42,
    ));
    app.replace_tree(browser_completion_tree(surface_id, surface_id));
    app.sidebar_visible = false;
    let area = browser_completion_area(surface_id);
    app.outer_size = (40, 12);
    app.pane_areas = vec![area];
    app.rendered_pane_content_generations.insert(surface_id, PaneContentGeneration::Browser(41));
    app.commit_rendered_pointer_frame();
    assert!(app.session.inner.take_remote_tree_stale());
    let (dispatcher, blocked) = BrowserInputDispatcher::blocked(4);
    app.browser_input = dispatcher;
    let motion = MouseEvent {
        kind: MouseEventKind::Moved,
        column: area.content.x + 2,
        row: area.content.y + 1,
        modifiers: KeyModifiers::NONE,
    };

    app.handle(AppEvent::Input(Event::Mouse(motion))).unwrap();

    let forwarded = blocked.recv_timeout(Duration::from_secs(1)).expect("rendered browser hover");
    let BrowserInputKind::Mouse { frame_seq, .. } = forwarded.kind else {
        panic!("expected browser mouse input");
    };
    assert_eq!(
        frame_seq, 41,
        "final admission must preserve the exact acknowledged presentation token"
    );
}

#[test]
fn pty_mouse_tracking_forwards_click_release_and_wheel_with_shift_override() {
    let mux = Mux::new(
        "mouse-passthrough-test",
        SurfaceOptions {
            command: Some(vec!["/bin/sh".to_string(), "-c".to_string(), "sleep 30".to_string()]),
            ..Default::default()
        },
    );
    let surface = mux.new_workspace(Some("work".to_string()), Some((20, 8))).unwrap();
    surface.with_terminal(|terminal| terminal.vt_write(b"\x1b[?1002h\x1b[?1006h"));

    let mut app = test_app(Session::Local(mux.clone()));
    app.replace_tree(app.session.tree());
    let pane = app.tree.active_screen().unwrap().active_pane;
    let content = Rect { x: 2, y: 3, width: 20, height: 8 };
    app.pane_areas.push(PaneArea {
        pane,
        surface: surface.id,
        rect: Rect { x: 1, y: 2, width: 23, height: 10 },
        bar: Some(Rect { x: 1, y: 2, width: 23, height: 1 }),
        omnibar: None,
        content,
        track: None,
        viewport: None,
    });
    app.rendered_terminal_bounds.insert(surface.id, content);

    let event =
        |kind, modifiers| MouseEvent { kind, column: content.x + 4, row: content.y + 2, modifiers };

    app.handle_mouse(event(MouseEventKind::Down(MouseButton::Left), KeyModifiers::NONE)).unwrap();
    assert_eq!(app.encode_buf, b"\x1b[<0;5;3M");
    assert!(app.selection.is_none());
    assert!(matches!(app.drag, Some(Drag::PtyMouse { button: MouseButton::Left, .. })));

    surface.with_terminal(|terminal| terminal.vt_write(b"\x1b[?1002l\x1b[?1006l"));
    app.encode_buf.clear();
    app.handle_mouse(event(MouseEventKind::Up(MouseButton::Left), KeyModifiers::NONE)).unwrap();
    assert_eq!(app.encode_buf, b"\x1b[<0;5;3m");
    assert!(app.drag.is_none());
    surface.with_terminal(|terminal| terminal.vt_write(b"\x1b[?1002h\x1b[?1006h"));

    app.handle_mouse(event(MouseEventKind::ScrollDown, KeyModifiers::NONE)).unwrap();
    assert_eq!(app.encode_buf, b"\x1b[<65;5;3M");

    app.content_area = content;
    app.viewport_virtual_width = u64::from(content.width) * 2;
    app.encode_buf.clear();
    app.handle_mouse(event(MouseEventKind::ScrollLeft, KeyModifiers::NONE)).unwrap();
    assert!(app.encode_buf.is_empty());

    app.handle_mouse(event(MouseEventKind::ScrollRight, KeyModifiers::NONE)).unwrap();
    assert!(app.encode_buf.is_empty());
    let screen = app.active_screen_id().unwrap();
    assert!(app.viewport_states[&screen].target > 0.0);

    app.open_context_menu(content.x + 4, content.y + 2);
    app.handle_mouse(event(MouseEventKind::ScrollDown, KeyModifiers::NONE)).unwrap();
    assert!(app.encode_buf.is_empty());
    app.menu = None;

    app.focus = FocusTarget::WorkspaceRail;
    app.handle_mouse(event(MouseEventKind::Down(MouseButton::Right), KeyModifiers::NONE)).unwrap();
    assert!(!app.workspace_sidebar_focused());
    assert_eq!(app.encode_buf, b"\x1b[<2;5;3M");
    app.handle_mouse(event(MouseEventKind::Down(MouseButton::Left), KeyModifiers::NONE)).unwrap();
    assert!(matches!(app.drag, Some(Drag::PtyMouse { button: MouseButton::Right, .. })));
    assert_eq!(app.encode_buf, b"\x1b[<2;5;3M");
    assert_eq!(
        app.handle_mouse(event(MouseEventKind::Drag(MouseButton::Left), KeyModifiers::NONE))
            .unwrap(),
        RenderAction::None
    );
    assert!(app.encode_buf.is_empty());
    app.handle_mouse(event(MouseEventKind::Up(MouseButton::Left), KeyModifiers::NONE)).unwrap();
    assert!(app.encode_buf.is_empty());
    assert!(matches!(app.drag, Some(Drag::PtyMouse { button: MouseButton::Right, .. })));
    app.handle_mouse(event(MouseEventKind::Up(MouseButton::Right), KeyModifiers::NONE)).unwrap();
    assert_eq!(app.encode_buf, b"\x1b[<2;5;3m");
    assert!(app.drag.is_none());

    app.handle_mouse(event(MouseEventKind::Down(MouseButton::Right), KeyModifiers::NONE)).unwrap();
    assert_eq!(app.encode_buf, b"\x1b[<2;5;3M");
    app.handle_mouse(event(MouseEventKind::Up(MouseButton::Left), KeyModifiers::NONE)).unwrap();
    assert_eq!(app.encode_buf, b"\x1b[<2;5;3M");
    assert!(matches!(app.drag, Some(Drag::PtyMouse { button: MouseButton::Right, .. })));
    app.handle_mouse(event(MouseEventKind::Up(MouseButton::Right), KeyModifiers::NONE)).unwrap();
    assert_eq!(app.encode_buf, b"\x1b[<2;5;3m");
    assert!(app.drag.is_none());

    app.encode_buf.clear();
    app.handle_mouse(event(MouseEventKind::Down(MouseButton::Right), KeyModifiers::SHIFT)).unwrap();
    assert!(app.encode_buf.is_empty(), "Shift-right-click must bypass PTY mouse reporting");
    assert!(app.drag.is_none());
    assert!(app.menu.is_some(), "Shift-right-click must open the cmux context menu");
    app.menu = None;

    app.encode_buf.clear();
    app.handle_mouse(event(MouseEventKind::Down(MouseButton::Right), KeyModifiers::ALT)).unwrap();
    assert!(app.encode_buf.is_empty(), "Option-right-click must bypass PTY mouse reporting");
    assert!(app.drag.is_none());
    assert!(app.menu.is_some(), "Option-right-click must open the cmux context menu");
    app.menu = None;

    app.handle_mouse(event(MouseEventKind::Down(MouseButton::Left), KeyModifiers::NONE)).unwrap();
    app.pane_areas[0].content.x += 3;
    let moved_content = app.pane_areas[0].content;
    app.rendered_terminal_bounds.insert(surface.id, moved_content);
    let moved_event = MouseEvent {
        kind: MouseEventKind::Drag(MouseButton::Left),
        column: moved_content.x + 4,
        row: moved_content.y + 2,
        modifiers: KeyModifiers::NONE,
    };
    app.handle_mouse(moved_event).unwrap();
    assert!(app.encode_buf.is_empty());
    app.handle_mouse(MouseEvent { kind: MouseEventKind::Up(MouseButton::Left), ..moved_event })
        .unwrap();
    assert_eq!(app.encode_buf, b"\x1b[<0;5;3m");
    app.pane_areas[0].content = content;
    app.rendered_terminal_bounds.insert(surface.id, content);

    app.handle_mouse(event(MouseEventKind::Down(MouseButton::Left), KeyModifiers::NONE)).unwrap();
    app.open_rename_tab_prompt(Some(pane));
    assert_eq!(app.encode_buf, b"\x1b[<0;5;3m");
    assert!(app.drag.is_none());
    assert!(app.prompt.is_some());
    app.prompt = None;

    app.handle_mouse(event(MouseEventKind::Down(MouseButton::Left), KeyModifiers::NONE)).unwrap();
    surface.with_terminal(|terminal| terminal.vt_write(b"\x1b[?1002l\x1b[?1006l"));
    app.handle(AppEvent::Input(Event::FocusLost)).unwrap();
    assert_eq!(app.encode_buf, b"\x1b[<0;5;3m");
    assert!(app.drag.is_none());

    app.encode_buf.clear();
    app.handle_mouse(event(MouseEventKind::Down(MouseButton::Left), KeyModifiers::SHIFT)).unwrap();
    assert!(app.encode_buf.is_empty());
    assert!(app.selection.is_some());
    assert!(matches!(app.drag, Some(Drag::Select { .. })));

    mux.close_surface(surface.id).unwrap();
}

#[test]
fn alt_left_and_middle_clicks_preserve_pty_mouse_reporting() {
    let mux = Mux::new(
        "alt-mouse-passthrough-test",
        SurfaceOptions {
            command: Some(vec!["/bin/sh".to_string(), "-c".to_string(), "sleep 30".to_string()]),
            ..Default::default()
        },
    );
    let surface = mux.new_workspace(Some("work".to_string()), Some((20, 8))).unwrap();
    surface.with_terminal(|terminal| terminal.vt_write(b"\x1b[?1002h\x1b[?1006h"));

    let mut app = test_app(Session::Local(mux.clone()));
    app.replace_tree(app.session.tree());
    let pane = app.tree.active_screen().unwrap().active_pane;
    let content = Rect { x: 2, y: 3, width: 20, height: 8 };
    app.pane_areas.push(PaneArea {
        pane,
        surface: surface.id,
        rect: Rect { x: 1, y: 2, width: 23, height: 10 },
        bar: Some(Rect { x: 1, y: 2, width: 23, height: 1 }),
        omnibar: None,
        content,
        track: None,
        viewport: None,
    });
    app.rendered_terminal_bounds.insert(surface.id, content);

    let event =
        |kind, modifiers| MouseEvent { kind, column: content.x + 4, row: content.y + 2, modifiers };

    app.handle_mouse(event(MouseEventKind::Down(MouseButton::Left), KeyModifiers::ALT)).unwrap();
    assert_eq!(app.encode_buf, b"\x1b[<8;5;3M");
    assert!(matches!(app.drag, Some(Drag::PtyMouse { button: MouseButton::Left, .. })));
    app.handle_mouse(event(MouseEventKind::Up(MouseButton::Left), KeyModifiers::ALT)).unwrap();
    assert_eq!(app.encode_buf, b"\x1b[<8;5;3m");
    assert!(app.drag.is_none());

    app.encode_buf.clear();
    app.handle_mouse(event(MouseEventKind::Down(MouseButton::Middle), KeyModifiers::ALT)).unwrap();
    assert_eq!(app.encode_buf, b"\x1b[<9;5;3M");
    assert!(matches!(app.drag, Some(Drag::PtyMouse { button: MouseButton::Middle, .. })));
    app.handle_mouse(event(MouseEventKind::Up(MouseButton::Middle), KeyModifiers::ALT)).unwrap();
    assert_eq!(app.encode_buf, b"\x1b[<9;5;3m");
    assert!(app.drag.is_none());

    mux.close_surface(surface.id).unwrap();
}
