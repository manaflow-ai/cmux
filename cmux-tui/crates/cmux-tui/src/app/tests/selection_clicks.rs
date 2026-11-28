//! Tests: sidebar widths, single, double and drag clicks, selection and
//! status message selection, and pane focus by click.

use super::*;

#[test]
fn compact_sidebar_width_and_action_preserve_the_full_width() {
    let mut config = Config::default();
    config.sidebar.width = 28;
    config.sidebar.compact_width = 10;
    let overrides =
        SidebarWidthOverrides { workspace: Some(35), ..SidebarWidthOverrides::default() };
    let full = sidebar_layout_for(&config, true, false, false, (100, 30), overrides);
    assert_eq!(full.workspace.map(|area| area.width), Some(35));
    let compact = sidebar_layout_for(&config, true, true, false, (100, 30), overrides);
    assert_eq!(compact.workspace.map(|area| area.width), Some(10));
    let hidden = sidebar_layout_for(&config, false, true, false, (100, 30), overrides);
    assert_eq!(hidden.workspace, None);

    let mux = Mux::new("compact-sidebar-action-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.sidebar_visible = false;
    assert!(app.run_action(Action::ToggleSidebarCompact).is_ok());
    assert!(app.sidebar_visible);
    assert!(app.sidebar_compact);
    assert!(app.run_action(Action::ToggleSidebarCompact).is_ok());
    assert!(!app.sidebar_compact);
}

#[test]
fn configured_column_stack_preserves_order_and_drops_low_priority_rails_first() {
    let mut config = Config::default();
    config.sidebar.columns_explicit = true;
    config.sidebar.columns = vec![
        crate::config::SidebarColumn { kind: SidebarColumnKind::Machines, width: 18, max_width: 0 },
        crate::config::SidebarColumn {
            kind: SidebarColumnKind::Workspaces,
            width: 22,
            max_width: 0,
        },
        crate::config::SidebarColumn { kind: SidebarColumnKind::Tabs, width: 24, max_width: 0 },
    ];
    config.sidebar.views = config
        .sidebar
        .columns
        .iter()
        .map(|column| SidebarViewSpec::legacy(column.kind, column.width, column.max_width))
        .collect();
    config.sidebar.views_explicit = true;

    let full =
        sidebar_layout_for(&config, true, false, true, (120, 30), SidebarWidthOverrides::default());
    assert_eq!(full.machine, Some(Rect { x: 0, y: 0, width: 18, height: 30 }));
    assert_eq!(full.workspace, Some(Rect { x: 18, y: 0, width: 22, height: 30 }));
    assert_eq!(full.tabs, Some(Rect { x: 40, y: 0, width: 24, height: 30 }));
    assert_eq!(full.content.x, 64);

    let medium =
        sidebar_layout_for(&config, true, false, true, (60, 30), SidebarWidthOverrides::default());
    assert_eq!(medium.machine, None);
    assert!(medium.workspace.is_some());
    assert!(medium.tabs.is_some());

    let narrow =
        sidebar_layout_for(&config, true, false, true, (50, 30), SidebarWidthOverrides::default());
    assert_eq!(narrow.machine, None);
    assert_eq!(narrow.tabs, None);
    assert_eq!(narrow.workspace.map(|rect| rect.width), Some(10));
    assert_eq!(narrow.content.width, 40);
}

#[test]
fn sidebar_collapse_equal_priorities_keep_first_configured_rail() {
    let mut config = Config::default();
    config.sidebar.views_explicit = true;
    config.sidebar.views = vec![
        SidebarViewSpec::legacy(SidebarColumnKind::Machines, 18, 0),
        SidebarViewSpec::legacy(SidebarColumnKind::Workspaces, 22, 0),
        SidebarViewSpec::legacy(SidebarColumnKind::Tabs, 24, 0),
    ];
    for view in &mut config.sidebar.views {
        view.collapse_priority = 10;
    }

    // 60 columns cannot fit three minimum rails and the content area,
    // but can fit the two rails that remain after the first collapse.
    // Equal priorities must collapse the first configured rail, matching
    // the previous `min_by_key` plus `remove(index)` behavior.
    let layout =
        sidebar_layout_for(&config, true, false, true, (60, 30), SidebarWidthOverrides::default());
    assert_eq!(layout.machine, None);
    assert_eq!(
        layout.ordered.iter().map(|placement| placement.kind).collect::<Vec<_>>(),
        vec![RailKind::Workspace, RailKind::Tabs]
    );
}

#[test]
fn context_menu_switches_sidebar_profiles_and_keeps_per_profile_visibility() {
    let mux = Mux::new("sidebar-profile-menu-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    let full = vec![
        SidebarViewSpec::legacy(SidebarColumnKind::Workspaces, 22, 0),
        SidebarViewSpec::legacy(SidebarColumnKind::Tabs, 22, 0),
    ];
    let focused = vec![SidebarViewSpec {
        id: "workspace-agents".into(),
        levels: vec![SidebarResourceKind::Workspaces, SidebarResourceKind::Agents],
        actions: vec![crate::config::SidebarActionSpec::plain(Action::NewWorkspace)],
        actions_position: crate::config::ActionsPosition::Bottom,
        width: 30,
        max_width: 0,
        collapse_priority: 30,
    }];
    app.config.sidebar.profiles = vec![
        SidebarProfileSpec { id: "full".into(), name: "Full".into(), views: full.clone() },
        SidebarProfileSpec { id: "focused".into(), name: "Focused".into(), views: focused.clone() },
    ];
    app.config.sidebar.active_profile = "full".into();
    app.config.sidebar.views = full;
    app.config.sidebar.views_explicit = true;
    app.sync_layout((120, 20));

    app.open_context_menu(100, 10);
    let actions = app.menu.as_ref().unwrap().actions();
    assert!(actions.contains(&MenuAction::ActivateSidebarProfile(1)));
    assert!(actions.contains(&MenuAction::SetSidebarViewVisible { view: 1, visible: false }));

    app.focus = FocusTarget::TabsRail;
    app.activate_menu(MenuAction::ActivateSidebarProfile(1)).unwrap();
    app.sync_layout((120, 20));
    assert_eq!(app.config.sidebar.views, focused);
    assert!(app.sidebar_layout.tabs.is_none());
    assert_eq!(app.focus, FocusTarget::Pane);

    app.activate_sidebar_profile(0);
    app.set_sidebar_view_visible(1, false);
    app.sync_layout((120, 20));
    assert!(app.sidebar_layout.tabs.is_none());
    app.activate_sidebar_profile(1);
    app.activate_sidebar_profile(0);
    app.sync_layout((120, 20));
    assert!(app.sidebar_layout.tabs.is_none());
}

#[test]
fn collapsed_rail_requires_hysteresis_before_reappearing() {
    let mut config = Config::default();
    config.sidebar.views = vec![
        SidebarViewSpec::legacy(SidebarColumnKind::Machines, 18, 0),
        SidebarViewSpec::legacy(SidebarColumnKind::Workspaces, 22, 0),
        SidebarViewSpec::legacy(SidebarColumnKind::Tabs, 24, 0),
    ];
    config.sidebar.views_explicit = true;
    let overrides = HashMap::new();
    let collapsed = sidebar_layout_for_state(
        &config,
        true,
        false,
        true,
        (69, 30),
        None,
        None,
        None,
        &overrides,
        &HashSet::new(),
        None,
    );
    assert!(collapsed.machine.is_none());

    let without_previous = sidebar_layout_for_state(
        &config,
        true,
        false,
        true,
        (70, 30),
        None,
        None,
        None,
        &overrides,
        &HashSet::new(),
        None,
    );
    assert!(without_previous.machine.is_some());

    let at_boundary = sidebar_layout_for_state(
        &config,
        true,
        false,
        true,
        (70, 30),
        None,
        None,
        None,
        &overrides,
        &HashSet::new(),
        Some(&collapsed),
    );
    assert!(at_boundary.machine.is_none());
    assert_eq!(
        at_boundary.ordered.iter().map(|placement| placement.kind).collect::<Vec<_>>(),
        vec![RailKind::Workspace, RailKind::Tabs]
    );
    let revealed = sidebar_layout_for_state(
        &config,
        true,
        false,
        true,
        (74, 30),
        None,
        None,
        None,
        &overrides,
        &HashSet::new(),
        Some(&at_boundary),
    );
    assert!(revealed.machine.is_some());
}

#[test]
fn single_surface_layout_uses_every_terminal_cell_without_chrome() {
    let (mux, surface) = test_mux("single-surface-layout-test", None);
    let mut app = test_app(Session::Local(mux.clone()));
    app.surface_only = Some(surface.id);

    app.sync_layout((80, 24));

    assert_eq!(app.sidebar_width, 0);
    assert_eq!(app.content_area, Rect { x: 0, y: 0, width: 80, height: 24 });
    assert_eq!(app.pane_areas.len(), 1);
    let area = app.pane_areas[0];
    assert_eq!(area.surface, surface.id);
    assert_eq!(area.rect, app.content_area);
    assert_eq!(area.content, app.content_area);
    assert!(area.bar.is_none());
    assert!(area.track.is_none());

    mux.close_surface(surface.id).unwrap();
}

#[test]
fn single_surface_status_overlays_the_terminal_without_a_status_bar() {
    let (mux, surface) = test_mux("single-surface-status-test", None);
    let mut app = test_app(Session::Local(mux.clone()));
    app.surface_only = Some(surface.id);
    app.status_message = Some("isolated attach error".to_string());
    app.sync_layout((40, 8));

    let mut terminal = Terminal::new(TestBackend::new(40, 8)).unwrap();
    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
    let rendered = buffer_text(terminal.backend().buffer());

    assert!(rendered.contains("isolated attach error"), "{rendered}");
    assert!(!rendered.contains("screens"), "{rendered}");
    assert_eq!(terminal.backend().buffer()[(0, 7)].fg, Color::Red);

    mux.close_surface(surface.id).unwrap();
}

#[test]
fn pane_focus_history_overlays_authoritative_recency() {
    let mut history = PaneFocusHistory::default();
    let mut tree = notify_tree(1, false);
    tree.workspaces_mut()[0].screens[0].panes[0].focused_at = 8;
    history.reconcile_membership(&tree);

    assert_eq!(history.recency(2), (false, 8));
    history.record(2);
    assert_eq!(history.recency(2), (true, 1));
    assert_eq!(history.recency(99), (false, 0));
}

#[test]
fn pane_focus_history_prunes_closed_panes() {
    let mut history = PaneFocusHistory::default();
    history.record(2);
    history.record(99);

    history.reconcile_membership(&notify_tree(1, false));

    assert_eq!(history.recency(2), (true, 1));
    assert_eq!(history.recency(99), (false, 0));
}

#[test]
fn pane_focus_history_freezes_remote_baseline_until_membership_changes() {
    let mut history = PaneFocusHistory::default();
    let mut initial = notify_tree(1, false);
    initial.workspaces_mut()[0].screens[0].panes[0].focused_at = 8;
    history.reconcile_membership(&initial);

    let mut peer_refresh = initial.clone();
    peer_refresh.workspaces_mut()[0].screens[0].panes[0].focused_at = 99;
    history.sync_membership(&peer_refresh);

    assert_eq!(history.recency(2), (false, 8));
}

#[test]
fn pane_focus_history_reconciles_exact_same_size_membership_changes() {
    let mut history = PaneFocusHistory::default();
    history.record(2);
    history.reconcile_membership(&notify_tree(1, false));

    let mut replacement = notify_tree(2, false);
    let screen = &mut replacement.workspaces_mut()[0].screens[0];
    screen.active_pane = 99;
    screen.layout = Node::Leaf(99);
    screen.panes[0].id = 99;
    screen.panes[0].focused_at = 5;
    replacement.pane_revision = Some(2);
    history.sync_membership(&replacement);

    assert_eq!(history.recency(2), (false, 0));
    assert_eq!(history.recency(99), (false, 5));
}

#[test]
fn directional_focus_uses_client_history_and_visible_geometry() {
    let mux = Mux::new("directional-focus-memory-test", SurfaceOptions::default());
    mux.new_workspace(None, Some((80, 30))).unwrap();
    let left = Session::Local(mux.clone()).tree().active_screen().unwrap().active_pane;
    mux.split(left, SplitDir::Right, Some((40, 30))).unwrap();
    let top_right = Session::Local(mux.clone()).tree().active_screen().unwrap().active_pane;
    mux.split(top_right, SplitDir::Down, Some((40, 15))).unwrap();
    let bottom_right = Session::Local(mux.clone()).tree().active_screen().unwrap().active_pane;
    assert!(mux.focus_pane(left));

    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    app.sidebar_visible = false;
    app.replace_tree(app.session.tree());
    app.sync_layout((80, 31));
    while app.session.has_pending_mutations() {
        let event = events.recv_timeout(crate::test_wait::EVENT).unwrap();
        app.handle(event).unwrap();
    }
    app.session.remote = true;

    app.move_focus(Direction::Right);
    assert_eq!(app.active_pane(), Some(bottom_right));
    app.move_focus(Direction::Left);
    assert_eq!(app.active_pane(), Some(left));
    app.focus_pane_after_input(top_right);
    app.move_focus(Direction::Left);
    app.move_focus(Direction::Right);
    assert_eq!(app.active_pane(), Some(top_right));

    app.tree.active_workspace_mut_screen().unwrap().zoomed_pane = Some(top_right);
    app.move_focus(Direction::Left);
    assert_eq!(app.active_pane(), Some(top_right));

    app.tree.active_workspace_mut_screen().unwrap().zoomed_pane = None;
    app.focus_pane_after_input(left);
    app.pane_areas.iter_mut().find(|area| area.pane == top_right).unwrap().content.height = 0;
    app.move_focus(Direction::Right);
    assert_eq!(app.active_pane(), Some(top_right));

    app.focus_pane_after_input(left);
    app.pane_areas.iter_mut().find(|area| area.pane == top_right).unwrap().rect.height = 0;
    app.move_focus(Direction::Right);
    assert_eq!(app.active_pane(), Some(bottom_right));
    while app.session.has_pending_mutations() {
        let event = events.recv_timeout(crate::test_wait::EVENT).unwrap();
        app.handle(event).unwrap();
    }
    assert_eq!(app.active_pane(), Some(bottom_right));
    // Focus reports only write the session's focus memory for later
    // attaches; the live shared focus never follows client navigation.
    assert_eq!(Session::Local(mux.clone()).tree().active_screen().unwrap().active_pane, left);
    assert_eq!(mux.session_focus().map(|(pane, _)| pane), Some(bottom_right));
    assert!(!app.session.has_pending_mutations());

    let surfaces = mux.with_state(|state| state.surfaces.keys().copied().collect::<Vec<_>>());
    for surface in surfaces {
        mux.close_surface(surface).unwrap();
    }
}

#[test]
fn viewport_pane_overflows_the_existing_tiled_layout() {
    let mux = Mux::new("viewport-pane-layout-test", SurfaceOptions::default());
    mux.new_workspace(None, Some((80, 24))).unwrap();
    let left = Session::Local(mux.clone()).tree().active_screen().unwrap().active_pane;
    mux.split(left, SplitDir::Right, Some((40, 24))).unwrap();
    let right = Session::Local(mux.clone()).tree().active_screen().unwrap().active_pane;

    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    app.sidebar_visible = false;
    app.viewport_states.insert(u64::MAX, ViewportMotion::new(Instant::now()));
    app.replace_tree(app.session.tree());
    assert!(
        !app.viewport_states.contains_key(&u64::MAX),
        "closed screens must not leave viewport animation state behind"
    );
    app.sync_layout((80, 25));
    while app.session.has_pending_mutations() {
        app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
    }
    assert!(app.tree.active_screen().unwrap().viewport_splits.is_empty());
    assert_eq!(app.horizontal_scrollbar_state(), None);
    assert_eq!(app.pane_areas.len(), 2);
    assert!(app.pane_areas.iter().all(|area| area.rect.width == 40));

    mux.new_pane_right(right, 2.0 / 3.0, Some((51, 22))).unwrap();
    app.replace_tree(app.session.tree());
    let appended = app
        .tree
        .active_screen()
        .unwrap()
        .panes
        .iter()
        .map(|pane| pane.id)
        .find(|pane| *pane != left && *pane != right)
        .unwrap();
    app.focus_pane_after_input(appended);
    app.config.viewport.animation = false;
    app.sync_layout((80, 25));
    while app.session.has_pending_mutations() {
        app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
    }

    let screen = app.tree.active_screen().unwrap();
    let screen_id = screen.id;
    assert_eq!(screen.active_pane, appended);
    assert_eq!(screen.viewport_splits.len(), 1);
    assert_eq!(app.horizontal_scrollbar_state(), Some((133, 80, 53)));
    assert_eq!(app.pane_areas.len(), 2);
    assert_eq!(
        app.pane_areas.iter().find(|area| area.pane == right).unwrap().rect,
        Rect { x: 0, y: 0, width: 27, height: 24 }
    );
    assert_eq!(
        app.pane_areas.iter().find(|area| area.pane == appended).unwrap().rect,
        Rect { x: 27, y: 0, width: 53, height: 24 }
    );

    let mut terminal = Terminal::new(TestBackend::new(80, 25)).unwrap();
    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
    let track = app
        .hits
        .iter()
        .find_map(|(rect, hit)| {
            matches!(hit, crate::app::Hit::HorizontalScrollbar { .. }).then_some(*rect)
        })
        .expect("overflow must render a horizontal track");

    let (content_width, viewport_width, initial_offset) = app.horizontal_scrollbar_state().unwrap();
    let (thumb_x, _) = crate::ui::horizontal_thumb_geometry(
        content_width,
        viewport_width,
        initial_offset,
        track.width,
    );
    app.handle_left_down(track.x + thumb_x, track.y, KeyModifiers::NONE).unwrap();
    assert_eq!(
        app.viewport_states[&screen_id].offset(),
        initial_offset,
        "grabbing the thumb must not jump the viewport"
    );
    app.handle_left_up(track.x + thumb_x, track.y).unwrap();

    app.handle_left_down(track.x, track.y, KeyModifiers::NONE).unwrap();
    assert!(matches!(app.drag, Some(Drag::HorizontalScrollbar { .. })));
    app.handle_left_drag(track.x + track.width - 1, track.y).unwrap();
    app.handle_left_up(track.x + track.width - 1, track.y).unwrap();
    assert!(app.drag.is_none());
    assert_eq!(app.viewport_states[&screen_id].offset(), 53);

    assert!(app.set_viewport_target(0, false));
    app.sync_layout((80, 25));
    let mut baseline = Terminal::new(TestBackend::new(80, 25)).unwrap();
    baseline.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
    let expected = (4..12)
        .map(|x| baseline.backend().buffer()[(x, 0)].symbol().to_string())
        .collect::<Vec<_>>();
    assert!(expected.iter().any(|symbol| symbol != "─"));

    assert!(app.set_viewport_target(1, false));
    app.sync_layout((80, 25));
    let border_only = app.pane_areas.iter().find(|area| area.pane == appended).unwrap();
    assert_eq!(border_only.rect.width, 1);
    assert_eq!(
        border_only.content,
        Rect { x: 79, y: 1, width: 0, height: 22 },
        "a border-only crop must retain the terminal content rows"
    );

    assert!(app.set_viewport_target(4, false));
    app.sync_layout((80, 25));
    let clipped = app.pane_areas.iter().find(|area| area.pane == left).unwrap();
    assert_eq!(clipped.viewport.unwrap().rect_source_x, 4);
    let mut cropped = Terminal::new(TestBackend::new(80, 25)).unwrap();
    cropped.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
    let actual =
        (0..8).map(|x| cropped.backend().buffer()[(x, 0)].symbol().to_string()).collect::<Vec<_>>();
    assert_eq!(actual, expected, "the tab bar must move through the viewport as one surface");

    let surfaces = mux.with_state(|state| state.surfaces.keys().copied().collect::<Vec<_>>());
    for surface in surfaces {
        mux.close_surface(surface).unwrap();
    }
}

#[test]
fn horizontal_status_bar_reserves_terminal_cells_for_wide_messages() {
    let (mux, first) = test_mux("wide-status-message-test", None);
    let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    mux.new_pane_right(first_pane, cmux_tui_core::DEFAULT_VIEWPORT_PANE_WIDTH, Some((51, 22)))
        .unwrap();
    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    app.sidebar_visible = false;
    app.config.viewport.animation = false;
    app.replace_tree(app.session.tree());
    app.sync_layout((80, 25));
    while app.session.has_pending_mutations() {
        app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
    }
    app.status_message = Some("復元失敗".to_string());

    let mut terminal = Terminal::new(TestBackend::new(80, 25)).unwrap();
    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
    let buffer = terminal.backend().buffer();
    let status = app.rendered_status_message.clone().expect("rendered status message");
    let expected = [
        (status.rect.x, "復"),
        (status.rect.x + 2, "元"),
        (status.rect.x + 4, "失"),
        (status.rect.x + 6, "敗"),
    ];
    for (x, symbol) in expected {
        assert_eq!(buffer[(x, 24)].symbol(), symbol);
    }
    let track = app
        .hits
        .iter()
        .find_map(|(rect, hit)| {
            matches!(hit, crate::app::Hit::HorizontalScrollbar { .. }).then_some(*rect)
        })
        .expect("wide viewport should render a horizontal scrollbar");
    assert!(
        track.x.saturating_add(track.width) <= status.rect.x.saturating_sub(1),
        "track must end before the status label"
    );

    app.status_message = Some("status failure details ".repeat(20));
    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
    let rendered = buffer_text(terminal.backend().buffer());
    let status_row = rendered.lines().last().unwrap();
    assert!(
        status_row.contains('…'),
        "an exact-fit truncated status label must remain visible: {status_row:?}"
    );

    let surfaces = mux.with_state(|state| state.surfaces.keys().copied().collect::<Vec<_>>());
    for surface in surfaces {
        mux.close_surface(surface).unwrap();
    }
}

#[test]
fn status_message_renders_and_is_selectable_without_a_workspace() {
    let mux = Mux::new("empty-status-message-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.sidebar_visible = false;
    app.status_message = Some("initial terminal launch failed".to_string());
    app.sync_layout((80, 25));

    let mut terminal = Terminal::new(TestBackend::new(80, 25)).unwrap();
    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
    let y = 24;
    let start = (0..80)
        .find(|x| terminal.backend().buffer()[(*x, y)].symbol() == "i")
        .expect("status message must render without an active workspace");

    app.handle_mouse(MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Left),
        column: start,
        row: y,
        modifiers: KeyModifiers::NONE,
    })
    .unwrap();

    assert!(matches!(app.drag, Some(Drag::StatusMessage { .. })));
}

fn selection_fixture(
    name: &str,
    text: &[u8],
) -> (App, Arc<Mux>, Arc<cmux_tui_core::Surface>, Rect) {
    let (mux, surface) = test_mux(name, None);
    surface.with_terminal(|terminal| terminal.vt_write(text));

    let mut app = test_app(Session::Local(mux.clone()));
    app.sidebar_visible = false;
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
    (app, mux, surface, content)
}

fn wrapped_selection_fixture(
    name: &str,
    text: &[u8],
) -> (App, Arc<Mux>, Arc<cmux_tui_core::Surface>, Rect) {
    let (mux, surface) = test_mux(name, None);
    surface.with_terminal(|terminal| {
        terminal.resize(4, 3, 8, 16).unwrap();
        terminal.vt_write(text);
    });

    let mut app = test_app(Session::Local(mux.clone()));
    app.sidebar_visible = false;
    app.replace_tree(app.session.tree());
    let pane = app.tree.active_screen().unwrap().active_pane;
    let content = Rect { x: 2, y: 3, width: 4, height: 3 };
    app.pane_areas.push(PaneArea {
        pane,
        surface: surface.id,
        rect: Rect { x: 1, y: 2, width: 7, height: 5 },
        bar: Some(Rect { x: 1, y: 2, width: 7, height: 1 }),
        omnibar: None,
        content,
        track: None,
        viewport: None,
    });
    app.rendered_terminal_bounds.insert(surface.id, content);
    (app, mux, surface, content)
}

#[test]
fn dragging_from_a_wrapped_wide_head_anchors_to_the_glyph_lead() {
    let (mut app, mux, surface, content) =
        wrapped_selection_fixture("wrapped-wide-cell-drag-selection-test", "ABC橋D".as_bytes());

    let press = MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Left),
        column: content.x + 3,
        row: content.y,
        modifiers: KeyModifiers::NONE,
    };
    app.handle_mouse(press).unwrap();
    app.handle_mouse(MouseEvent {
        kind: MouseEventKind::Drag(MouseButton::Left),
        column: content.x + 2,
        row: content.y + 1,
        modifiers: KeyModifiers::NONE,
    })
    .unwrap();

    let selection = app.selection.expect("dragging a wrapped glyph must create a selection");
    assert_eq!(selection.anchor, (0, 1));
    assert_eq!(selection.range(), ((0, 1), (2, 1)));

    mux.close_surface(surface.id).unwrap();
}

#[test]
fn double_clicking_a_wrapped_wide_head_selects_the_glyph_word() {
    let (mut app, mux, surface, content) =
        wrapped_selection_fixture("wrapped-wide-word-selection-test", "AB 橋".as_bytes());
    let click = MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Left),
        column: content.x + 3,
        row: content.y,
        modifiers: KeyModifiers::NONE,
    };

    app.handle_mouse(click).unwrap();
    app.handle_mouse(MouseEvent { kind: MouseEventKind::Up(MouseButton::Left), ..click }).unwrap();
    app.handle_mouse(click).unwrap();
    app.handle_mouse(MouseEvent { kind: MouseEventKind::Up(MouseButton::Left), ..click }).unwrap();

    assert_eq!(
        app.selection.map(|selection| selection.range()),
        Some(((0, 1), (0, 1))),
        "double-clicking a wrapped glyph head must select its word"
    );

    mux.close_surface(surface.id).unwrap();
}

#[test]
fn double_click_selects_a_complete_word() {
    let (mut app, mux, surface, content) =
        selection_fixture("double-click-word-selection-test", b"alpha beta gamma");

    let click = MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Left),
        column: content.x + 1,
        row: content.y,
        modifiers: KeyModifiers::NONE,
    };
    app.handle_mouse(click).unwrap();
    app.handle_mouse(MouseEvent { kind: MouseEventKind::Up(MouseButton::Left), ..click }).unwrap();
    app.handle_mouse(click).unwrap();
    app.handle_mouse(MouseEvent { kind: MouseEventKind::Up(MouseButton::Left), ..click }).unwrap();

    assert_eq!(
        app.selection.map(|selection| selection.range()),
        Some(((0, 0), (4, 0))),
        "a double click must highlight the complete word"
    );

    mux.close_surface(surface.id).unwrap();
}

#[test]
fn selection_for_click_returns_the_terminal_word_range() {
    let (app, mux, surface, _) =
        selection_fixture("selection-for-click-word-range-test", b"alpha beta");

    let selection = app
        .selection_for_click(surface.id, (1, 0), SelectionMode::Word)
        .expect("a word click must return the terminal selection range");
    assert_eq!(selection.range(), ((0, 0), (4, 0)));

    mux.close_surface(surface.id).unwrap();
}

#[test]
fn shift_double_click_selects_a_complete_word() {
    let (mut app, mux, surface, content) =
        selection_fixture("shift-double-click-word-selection-test", b"alpha beta gamma");

    let click = MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Left),
        column: content.x + 1,
        row: content.y,
        modifiers: KeyModifiers::SHIFT,
    };
    let now = Instant::now();
    app.handle_mouse_at(click, now).unwrap();
    app.handle_mouse_at(MouseEvent { kind: MouseEventKind::Up(MouseButton::Left), ..click }, now)
        .unwrap();
    app.handle_mouse_at(click, now).unwrap();
    app.handle_mouse_at(MouseEvent { kind: MouseEventKind::Up(MouseButton::Left), ..click }, now)
        .unwrap();

    assert_eq!(
        app.selection.map(|selection| selection.range()),
        Some(((0, 0), (4, 0))),
        "Shift double click must select the complete word when bypassing PTY mouse reporting"
    );

    mux.close_surface(surface.id).unwrap();
}

#[test]
fn shift_triple_click_selects_a_complete_line() {
    let (mut app, mux, surface, content) =
        selection_fixture("shift-triple-click-line-selection-test", b"alpha beta\ngamma");

    let click = MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Left),
        column: content.x + 1,
        row: content.y,
        modifiers: KeyModifiers::SHIFT,
    };
    let now = Instant::now();
    for _ in 0..3 {
        app.handle_mouse_at(click, now).unwrap();
        app.handle_mouse_at(
            MouseEvent { kind: MouseEventKind::Up(MouseButton::Left), ..click },
            now,
        )
        .unwrap();
    }

    assert_eq!(
        app.selection.map(|selection| selection.range()),
        Some(((0, 0), (9, 0))),
        "Shift triple click must select the complete line when bypassing PTY mouse reporting"
    );

    mux.close_surface(surface.id).unwrap();
}

#[test]
fn a_single_cell_press_does_not_store_a_zero_length_selection() {
    let (mut app, mux, surface, content) =
        selection_fixture("single-cell-press-selection-state-test", b"alpha beta");

    let click = MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Left),
        column: content.x + 1,
        row: content.y,
        modifiers: KeyModifiers::NONE,
    };
    app.handle_mouse(click).unwrap();

    assert!(app.selection.is_none(), "a single cell press must not retain a zero-length selection");

    app.handle_mouse(MouseEvent { kind: MouseEventKind::Up(MouseButton::Left), ..click }).unwrap();
    mux.close_surface(surface.id).unwrap();
}

#[test]
fn a_failed_word_lookup_downgrades_to_a_cell_gesture() {
    let (mut app, mux, surface, content) =
        selection_fixture("failed-word-lookup-selection-state-test", b"alpha");

    let click = MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Left),
        column: content.x + 10,
        row: content.y,
        modifiers: KeyModifiers::NONE,
    };
    app.handle_mouse(click).unwrap();
    app.handle_mouse(MouseEvent { kind: MouseEventKind::Up(MouseButton::Left), ..click }).unwrap();
    app.handle_mouse(click).unwrap();

    assert!(app.selection.is_none(), "a missing word must not retain an older selection");
    assert_eq!(
        app.selection_mode,
        SelectionMode::Cell,
        "a failed word lookup must not leave semantic drag mode active"
    );

    app.handle_mouse(MouseEvent { kind: MouseEventKind::Up(MouseButton::Left), ..click }).unwrap();
    app.handle_mouse(click).unwrap();
    assert!(
        app.selection.is_none(),
        "a click after a failed semantic lookup must not inherit its selection"
    );
    assert_eq!(
        app.selection_mode,
        SelectionMode::Cell,
        "a failed semantic lookup must invalidate the repeat count before the next click"
    );
    app.handle_mouse(MouseEvent { kind: MouseEventKind::Up(MouseButton::Left), ..click }).unwrap();
    mux.close_surface(surface.id).unwrap();
}

#[test]
fn double_click_selects_a_complete_whitespace_run() {
    let (mut app, mux, surface, content) =
        selection_fixture("double-click-whitespace-selection-test", b"alpha   beta");

    let click = MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Left),
        column: content.x + 6,
        row: content.y,
        modifiers: KeyModifiers::NONE,
    };
    app.handle_mouse(click).unwrap();
    app.handle_mouse(MouseEvent { kind: MouseEventKind::Up(MouseButton::Left), ..click }).unwrap();
    app.handle_mouse(click).unwrap();
    app.handle_mouse(MouseEvent { kind: MouseEventKind::Up(MouseButton::Left), ..click }).unwrap();

    assert_eq!(
        app.selection.map(|selection| selection.range()),
        Some(((5, 0), (7, 0))),
        "double click must select the full whitespace run between words"
    );

    mux.close_surface(surface.id).unwrap();
}

#[test]
fn double_click_drag_extends_selection_by_complete_words() {
    let (mut app, mux, surface, content) =
        selection_fixture("double-click-word-drag-selection-test", b"alpha beta gamma");

    let click = MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Left),
        column: content.x + 7,
        row: content.y,
        modifiers: KeyModifiers::NONE,
    };
    app.handle_mouse(click).unwrap();
    app.handle_mouse(MouseEvent { kind: MouseEventKind::Up(MouseButton::Left), ..click }).unwrap();
    app.handle_mouse(click).unwrap();
    app.handle_mouse(MouseEvent {
        kind: MouseEventKind::Drag(MouseButton::Left),
        column: content.x + 15,
        row: content.y,
        modifiers: KeyModifiers::NONE,
    })
    .unwrap();
    app.handle_mouse(MouseEvent {
        kind: MouseEventKind::Up(MouseButton::Left),
        column: content.x + 15,
        row: content.y,
        modifiers: KeyModifiers::NONE,
    })
    .unwrap();

    assert_eq!(
        app.selection.map(|selection| selection.range()),
        Some(((6, 0), (15, 0))),
        "double-click drag must start at the selected word and end at the whole target word"
    );

    mux.close_surface(surface.id).unwrap();
}

#[test]
fn double_click_drag_anchors_at_second_press() {
    let (mut app, mux, surface, content) =
        selection_fixture("double-click-second-press-anchor-test", b"a b c");

    let first_click = MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Left),
        column: content.x + 1,
        row: content.y,
        modifiers: KeyModifiers::NONE,
    };
    app.handle_mouse(first_click).unwrap();
    app.handle_mouse(MouseEvent { kind: MouseEventKind::Up(MouseButton::Left), ..first_click })
        .unwrap();

    let second_click = MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Left),
        column: content.x + 2,
        row: content.y,
        modifiers: KeyModifiers::NONE,
    };
    app.handle_mouse(second_click).unwrap();
    app.handle_mouse(MouseEvent {
        kind: MouseEventKind::Drag(MouseButton::Left),
        column: content.x + 4,
        row: content.y,
        modifiers: KeyModifiers::NONE,
    })
    .unwrap();
    app.handle_mouse(MouseEvent {
        kind: MouseEventKind::Up(MouseButton::Left),
        column: content.x + 4,
        row: content.y,
        modifiers: KeyModifiers::NONE,
    })
    .unwrap();

    assert_eq!(
        app.selection.map(|selection| selection.range()),
        Some(((2, 0), (4, 0))),
        "a double-click drag must use the second press as its word anchor"
    );

    mux.close_surface(surface.id).unwrap();
}

#[test]
fn double_click_drag_extends_backwards_by_complete_words() {
    let (mut app, mux, surface, content) =
        selection_fixture("double-click-word-reverse-drag-test", b"alpha beta gamma");

    let click = MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Left),
        column: content.x + 7,
        row: content.y,
        modifiers: KeyModifiers::NONE,
    };
    app.handle_mouse(click).unwrap();
    app.handle_mouse(MouseEvent { kind: MouseEventKind::Up(MouseButton::Left), ..click }).unwrap();
    app.handle_mouse(click).unwrap();
    app.handle_mouse(MouseEvent {
        kind: MouseEventKind::Drag(MouseButton::Left),
        column: content.x + 1,
        row: content.y,
        modifiers: KeyModifiers::NONE,
    })
    .unwrap();
    app.handle_mouse(MouseEvent {
        kind: MouseEventKind::Up(MouseButton::Left),
        column: content.x + 1,
        row: content.y,
        modifiers: KeyModifiers::NONE,
    })
    .unwrap();

    assert_eq!(
        app.selection.map(|selection| selection.range()),
        Some(((0, 0), (9, 0))),
        "reverse double-click drags must include both complete words"
    );

    mux.close_surface(surface.id).unwrap();
}

#[test]
fn failed_semantic_drag_does_not_keep_a_stale_selection() {
    let (mut app, mux, surface, content) =
        selection_fixture("failed-semantic-drag-selection-test", b"alpha beta gamma");

    let click = MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Left),
        column: content.x + 1,
        row: content.y,
        modifiers: KeyModifiers::NONE,
    };
    app.handle_mouse(click).unwrap();
    app.handle_mouse(MouseEvent { kind: MouseEventKind::Up(MouseButton::Left), ..click }).unwrap();
    app.handle_mouse(click).unwrap();
    assert_eq!(
        app.selection.map(|selection| selection.range()),
        Some(((0, 0), (4, 0))),
        "the second press must establish the semantic selection before the drag"
    );

    // Leave the rendered pane geometry unchanged, but shrink Ghostty's
    // grid so the next pointer cell is no longer a valid semantic point.
    surface
        .with_terminal(|terminal| terminal.resize(2, 8, 8, 16).unwrap())
        .expect("selection fixture surface must remain a PTY");
    let invalid_drag = MouseEvent {
        kind: MouseEventKind::Drag(MouseButton::Left),
        column: content.x + 15,
        row: content.y,
        modifiers: KeyModifiers::NONE,
    };
    app.handle_mouse(invalid_drag).unwrap();
    assert!(
        app.selection.is_none(),
        "a failed semantic drag must clear the old selection before release"
    );
    app.handle_mouse(MouseEvent { kind: MouseEventKind::Up(MouseButton::Left), ..invalid_drag })
        .unwrap();
    assert!(app.selection.is_none(), "release must not copy or retain stale semantic text");

    mux.close_surface(surface.id).unwrap();
}

#[test]
fn single_click_drag_does_not_seed_a_double_click() {
    let (mut app, mux, surface, content) =
        selection_fixture("single-click-drag-repeat-test", b"alpha beta gamma");

    let click = MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Left),
        column: content.x + 1,
        row: content.y,
        modifiers: KeyModifiers::NONE,
    };
    app.handle_mouse(click).unwrap();
    app.handle_mouse(MouseEvent {
        kind: MouseEventKind::Drag(MouseButton::Left),
        column: content.x + 3,
        row: content.y,
        modifiers: KeyModifiers::NONE,
    })
    .unwrap();
    app.handle_mouse(MouseEvent {
        kind: MouseEventKind::Up(MouseButton::Left),
        column: content.x + 3,
        row: content.y,
        modifiers: KeyModifiers::NONE,
    })
    .unwrap();

    app.handle_mouse(click).unwrap();
    app.handle_mouse(MouseEvent { kind: MouseEventKind::Up(MouseButton::Left), ..click }).unwrap();

    assert!(app.selection.is_none(), "a click after a selection drag must remain a plain click");

    mux.close_surface(surface.id).unwrap();
}

#[test]
fn single_click_drag_into_padding_does_not_seed_a_double_click() {
    let (mut app, mux, surface, content) =
        selection_fixture("single-click-padding-drag-repeat-test", b"alpha beta gamma");

    let click = MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Left),
        column: content.x,
        row: content.y,
        modifiers: KeyModifiers::NONE,
    };
    app.handle_mouse(click).unwrap();
    app.handle_mouse(MouseEvent {
        kind: MouseEventKind::Drag(MouseButton::Left),
        column: content.x - 1,
        row: content.y,
        modifiers: KeyModifiers::NONE,
    })
    .unwrap();
    app.handle_mouse(MouseEvent {
        kind: MouseEventKind::Up(MouseButton::Left),
        column: content.x - 1,
        row: content.y,
        modifiers: KeyModifiers::NONE,
    })
    .unwrap();

    app.handle_mouse(click).unwrap();
    app.handle_mouse(MouseEvent { kind: MouseEventKind::Up(MouseButton::Left), ..click }).unwrap();

    assert!(
        app.selection.is_none(),
        "a padding drag must prevent the next click from becoming a double click"
    );

    mux.close_surface(surface.id).unwrap();
}

#[test]
fn triple_click_drag_extends_to_a_blank_line() {
    let (mut app, mux, surface, content) =
        selection_fixture("triple-click-blank-line-drag-test", b"alpha\n\nbeta");

    let click = MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Left),
        column: content.x + 1,
        row: content.y,
        modifiers: KeyModifiers::NONE,
    };
    for _ in 0..2 {
        app.handle_mouse(click).unwrap();
        app.handle_mouse(MouseEvent { kind: MouseEventKind::Up(MouseButton::Left), ..click })
            .unwrap();
    }
    app.handle_mouse(click).unwrap();
    app.handle_mouse(MouseEvent {
        kind: MouseEventKind::Drag(MouseButton::Left),
        column: content.x + 1,
        row: content.y + 1,
        modifiers: KeyModifiers::NONE,
    })
    .unwrap();
    app.handle_mouse(MouseEvent {
        kind: MouseEventKind::Up(MouseButton::Left),
        column: content.x + 1,
        row: content.y + 1,
        modifiers: KeyModifiers::NONE,
    })
    .unwrap();

    assert!(
        app.selection.is_some_and(|selection| selection.range().1.1 == 1),
        "triple-click drag must extend the line selection onto a blank line"
    );

    mux.close_surface(surface.id).unwrap();
}

#[test]
fn status_message_drag_selection_highlights_the_visible_text() {
    let (mux, _) = test_mux("status-message-selection-test", None);
    let mut app = test_app(Session::Local(mux.clone()));
    app.sidebar_visible = false;
    app.status_message = Some("attach failed".to_string());
    app.sync_layout((80, 25));

    let mut terminal = Terminal::new(TestBackend::new(80, 25)).unwrap();
    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
    let y = 24;
    let start = (0..80)
        .find(|x| terminal.backend().buffer()[(*x, y)].symbol() == "a")
        .expect("status message must render on the final row");

    app.handle_mouse(MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Left),
        column: start,
        row: y,
        modifiers: KeyModifiers::NONE,
    })
    .unwrap();
    app.handle_mouse(MouseEvent {
        kind: MouseEventKind::Drag(MouseButton::Left),
        column: start + 5,
        row: y,
        modifiers: KeyModifiers::NONE,
    })
    .unwrap();
    app.handle_mouse(MouseEvent {
        kind: MouseEventKind::Up(MouseButton::Left),
        column: start + 5,
        row: y,
        modifiers: KeyModifiers::NONE,
    })
    .unwrap();

    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
    for x in start..=start + 5 {
        assert_eq!(
            terminal.backend().buffer()[(x, y)].bg,
            app.config.theme.selection_bg,
            "status cell {x} must retain the native selection highlight"
        );
    }

    let surfaces = mux.with_state(|state| state.surfaces.keys().copied().collect::<Vec<_>>());
    for surface in surfaces {
        mux.close_surface(surface).unwrap();
    }
}

#[test]
fn status_message_context_menu_offers_full_message_copy() {
    let (mux, _) = test_mux("status-message-copy-menu-test", None);
    let mut app = test_app(Session::Local(mux.clone()));
    app.sidebar_visible = false;
    let message = "attach failed with details beyond the visible label";
    app.status_message = Some(message.to_string());
    app.sync_layout((80, 25));

    let mut terminal = Terminal::new(TestBackend::new(80, 25)).unwrap();
    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
    let y = 24;
    let x = (0..80)
        .find(|x| terminal.backend().buffer()[(*x, y)].symbol() == "a")
        .expect("status message must render on the final row");
    app.handle_mouse(MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Right),
        column: x,
        row: y,
        modifiers: KeyModifiers::NONE,
    })
    .unwrap();

    let labels = app
        .menu
        .as_ref()
        .expect("right-clicking the status message must open a menu")
        .actions()
        .into_iter()
        .map(|action| action.label())
        .collect::<Vec<_>>();
    assert!(labels.contains(&"Copy message"), "status menu actions: {labels:?}");

    app.handle_mouse(MouseEvent {
        kind: MouseEventKind::Up(MouseButton::Right),
        column: x,
        row: y,
        modifiers: KeyModifiers::NONE,
    })
    .unwrap();
    app.handle_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE)).unwrap();
    assert_eq!(app.status_message.as_deref(), Some(message));
    assert_eq!(app.toast.as_ref().map(|toast| toast.text.as_str()), Some("Copied"));

    let surfaces = mux.with_state(|state| state.surfaces.keys().copied().collect::<Vec<_>>());
    for surface in surfaces {
        mux.close_surface(surface).unwrap();
    }
}

#[test]
fn status_message_has_a_visible_copy_control_and_hover_pins_it() {
    let mux = Mux::new("status-message-copy-button-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.sidebar_visible = false;
    app.status_message = Some("SSH connection failed".to_string());
    app.sync_layout((80, 25));

    let mut terminal = Terminal::new(TestBackend::new(80, 25)).unwrap();
    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
    let rendered = buffer_text(terminal.backend().buffer());
    assert!(rendered.lines().last().unwrap().contains("Copy"), "{rendered}");
    let status = app.rendered_status_message.clone().expect("rendered status message");
    app.handle_mouse(MouseEvent {
        kind: MouseEventKind::Moved,
        column: status.rect.x,
        row: status.rect.y,
        modifiers: KeyModifiers::NONE,
    })
    .unwrap();
    app.handle_key(KeyEvent::new(KeyCode::Char('x'), KeyModifiers::ALT)).unwrap();

    assert_eq!(app.status_message.as_deref(), Some("SSH connection failed"));
    app.run_action(Action::ToggleSidebarCompact).unwrap();
    assert_eq!(app.status_message.as_deref(), Some("SSH connection failed"));
}

#[test]
fn expired_toast_is_consumed_once() {
    let mux = Mux::new("expired-toast-once-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.toast = Some(Toast {
        text: "expired".to_string(),
        deadline: Instant::now() - Duration::from_millis(1),
    });

    assert!(app.expire_toast());
    assert!(!app.expire_toast());
    assert!(app.toast.is_none());
}

#[test]
fn viewport_columns_resize_with_shortcuts_and_mouse_drag() {
    let mux = Mux::new("viewport-pane-resize-test", SurfaceOptions::default());
    mux.new_workspace(None, Some((80, 24))).unwrap();
    let base = Session::Local(mux.clone()).tree().active_screen().unwrap().active_pane;
    let appended_surface = mux
        .new_pane_right(base, cmux_tui_core::DEFAULT_VIEWPORT_PANE_WIDTH, Some((51, 22)))
        .unwrap();
    let appended = mux.with_state(|state| state.pane_of(appended_surface.id).unwrap());
    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    app.sidebar_visible = false;
    app.config.viewport.animation = false;
    app.replace_tree(app.session.tree());
    app.sync_layout((80, 25));

    app.resize_focused_split(-0.05);
    while app.session.has_pending_mutations() {
        app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
    }
    let screen = app.tree.active_screen().unwrap();
    let appended_split =
        match screen.layout.viewport_column_owner(appended, &screen.viewport_splits).unwrap() {
            cmux_tui_core::ViewportColumn::Split(split) => split,
            cmux_tui_core::ViewportColumn::Base => {
                panic!("appended pane must be its own column")
            }
        };
    assert!(
        (screen.viewport_splits[&appended_split]
            - (cmux_tui_core::DEFAULT_VIEWPORT_PANE_WIDTH - 0.05))
            .abs()
            < f32::EPSILON
    );

    app.sync_layout((80, 25));
    let appended_area = *app.pane_areas.iter().find(|area| area.pane == appended).unwrap();
    let drag_x = appended_area.rect.x.saturating_sub(8).max(app.content_area.x);
    let virtual_boundary =
        app.viewport_offset.saturating_add(u64::from(drag_x.saturating_sub(app.content_area.x)));
    let expected_base_width = (virtual_boundary as f64 / f64::from(app.content_area.width)) as f32;
    let mut terminal = Terminal::new(TestBackend::new(80, 25)).unwrap();
    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
    let handle = app
        .hits
        .iter()
        .find_map(|(rect, hit)| {
            matches!(
                hit,
                crate::app::Hit::PaneResize {
                    horizontal: Some((pane, PaneEdge::Left)),
                    vertical: None,
                } if *pane == appended
            )
            .then_some(*rect)
        })
        .expect("the viewport divider must expose a drag handle");
    app.handle_left_down(handle.x, handle.y, KeyModifiers::NONE).unwrap();
    assert!(matches!(app.drag, Some(Drag::ResizeSplit { .. })));
    app.handle_left_drag(drag_x, handle.y).unwrap();
    app.handle_left_up(drag_x, handle.y).unwrap();
    while app.session.has_pending_mutations() {
        app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
    }
    assert!(
        (app.tree.active_screen().unwrap().viewport_base_width.unwrap() - expected_base_width)
            .abs()
            < 0.001
    );

    let surfaces = mux.with_state(|state| state.surfaces.keys().copied().collect::<Vec<_>>());
    for surface in surfaces {
        mux.close_surface(surface).unwrap();
    }
}
