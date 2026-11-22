//! W1-A: agent state is visible by default. The workspace row and the tab
//! chip show the agent's status glyph, the agents section lists every agent
//! most urgent first and a click there focuses the agent's tab, and a turn
//! that finished in the tab the person views is seen (idle), not done.

use std::time::{Duration, Instant};

use super::*;
use cmux_tui_core::NotificationLevel;

/// How long a test waits for the roster and the notification marker.
const EVENT_WAIT: Duration = Duration::from_secs(10);

/// An app showing the workspace rail. `host_focused` is set before the
/// first layout frame, which may already ack a done tab the person views.
fn rendered_app(mux: &Arc<Mux>, host_focused: bool) -> (App, Terminal<TestBackend>) {
    let mut app = test_app(Session::Local(mux.clone()));
    app.sidebar_view = SidebarView::Workspaces;
    app.host_focused = host_focused;
    app.replace_tree(app.session.tree());
    app.sync_layout((100, 20));
    let terminal = Terminal::new(TestBackend::new(100, 20)).unwrap();
    (app, terminal)
}

fn draw(app: &mut App, terminal: &mut Terminal<TestBackend>) {
    app.sync_layout((100, 20));
    terminal.draw(|frame| crate::ui::draw(app, frame)).unwrap();
}

fn row_text(terminal: &Terminal<TestBackend>, rect: Rect) -> String {
    let buffer = terminal.backend().buffer();
    (rect.x..rect.x + rect.width).map(|x| buffer[(x, rect.y)].symbol()).collect()
}

fn hit_rect(app: &App, wanted: impl Fn(&crate::app::Hit) -> bool) -> Option<Rect> {
    app.hits.iter().find_map(|(rect, hit)| wanted(hit).then_some(*rect))
}

/// Re-runs layout frames until the agent of `surface` shows `wanted`; the
/// roster and the notification marker reach the tree asynchronously.
fn wait_for_status(
    app: &mut App,
    terminal: &mut Terminal<TestBackend>,
    surface: SurfaceId,
    wanted: Option<cmux_tui_core::AgentStatus>,
) {
    let deadline = Instant::now() + EVENT_WAIT;
    loop {
        draw(app, terminal);
        let status = app.sidebar_status.tab(surface);
        if status == wanted {
            return;
        }
        assert!(Instant::now() < deadline, "the tab never showed {wanted:?}; it shows {status:?}");
        std::thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn a_blocked_agent_shows_on_its_workspace_row_and_tops_the_agents_section() {
    let (mux, agent_tab) = test_mux("agent-sidebar-blocked-row-test", None);
    let other = mux.new_workspace(Some("other".into()), Some((20, 8))).unwrap();
    mux.report_agent(agent_tab.id, AgentState::Blocked, AgentSource::Hook, Some("s1".into()))
        .unwrap();
    let (mut app, mut terminal) = rendered_app(&mux, true);
    wait_for_status(
        &mut app,
        &mut terminal,
        agent_tab.id,
        Some(cmux_tui_core::AgentStatus::Blocked),
    );
    let work = app.tree.workspaces().iter().position(|ws| ws.name == "work").unwrap();
    let work_id = app.tree.workspaces()[work].id;
    // Show the other workspace so a click has somewhere to move from.
    let other_index = app.tree.workspaces().iter().position(|ws| ws.name == "other").unwrap();
    app.activate_projection_target(crate::sidebar_projection::ProjectionTarget::Workspace {
        index: other_index,
        id: app.tree.workspaces()[other_index].id,
    })
    .unwrap();
    draw(&mut app, &mut terminal);
    assert_ne!(app.tree.active_workspace().map(|ws| ws.id), Some(work_id));

    let workspace_row = hit_rect(
        &app,
        |hit| matches!(hit, crate::app::Hit::Workspace { id, .. } if *id == work_id),
    )
    .expect("the work workspace has a rail row");
    let workspace_line = row_text(&terminal, workspace_row);
    assert!(workspace_line.contains('!'), "workspace row: {workspace_line:?}");

    let agent_row = hit_rect(
        &app,
        |hit| matches!(hit, crate::app::Hit::AgentRow { surface, .. } if *surface == agent_tab.id),
    )
    .expect("the agents section lists the blocked agent");
    let agent_line = row_text(&terminal, agent_row);
    assert!(agent_line.contains('!'), "agents section row: {agent_line:?}");
    assert!(agent_row.y > workspace_row.y, "the agents section sits below the workspaces");

    app.handle_left_down(agent_row.x + 1, agent_row.y, KeyModifiers::NONE).unwrap();
    app.handle_left_up(agent_row.x + 1, agent_row.y).unwrap();
    assert_eq!(app.tree.active_workspace().map(|ws| ws.id), Some(work_id));
    assert_eq!(app.active_surface(), Some(agent_tab.id));
    assert_eq!(app.focus, FocusTarget::Pane);

    // Turned off in config, the section is gone and the row keeps its glyph.
    app.config.sidebar.agents = false;
    draw(&mut app, &mut terminal);
    assert!(hit_rect(&app, |hit| matches!(hit, crate::app::Hit::AgentRow { .. })).is_none());

    for surface in [agent_tab.id, other.id] {
        mux.close_surface(surface).unwrap();
    }
}

#[test]
fn a_finished_turn_stays_done_until_the_person_views_its_tab() {
    let (mux, agent_tab) = test_mux("agent-sidebar-done-until-seen-test", None);
    mux.report_agent(agent_tab.id, AgentState::Idle, AgentSource::Hook, Some("s1".into())).unwrap();
    mux.post_notification(
        "Claude finished".into(),
        String::new(),
        NotificationLevel::Info,
        Some(agent_tab.id),
    )
    .unwrap();
    // The host terminal is in the background: the turn is not seen.
    let (mut app, mut terminal) = rendered_app(&mux, false);
    wait_for_status(&mut app, &mut terminal, agent_tab.id, Some(cmux_tui_core::AgentStatus::Done));
    draw(&mut app, &mut terminal);
    assert_eq!(app.sidebar_status.tab(agent_tab.id), Some(cmux_tui_core::AgentStatus::Done));
    let chip = hit_rect(&app, |hit| matches!(hit, crate::app::Hit::Tab { index: 0, .. }))
        .expect("the agent's tab has a chip");
    let chip_text = row_text(&terminal, chip);
    assert!(chip_text.contains('✓'), "tab chip: {chip_text:?}");

    // The person brings the terminal to the front: the tab is seen.
    app.dispatch_terminal_input(TerminalInput::FocusGained, None, None, None, None, None).unwrap();
    wait_for_status(&mut app, &mut terminal, agent_tab.id, Some(cmux_tui_core::AgentStatus::Idle));

    mux.close_surface(agent_tab.id).unwrap();
}
