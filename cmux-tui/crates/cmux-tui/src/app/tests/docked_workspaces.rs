//! Tests: docked workspaces (plans/cmux-next/docked-workspace-DESIGN.md): the
//! frame around the stage, focus following a click into a dock, the dock
//! actions, and the client's record in its frontend projection.

use super::*;
use crate::app::window_docks::{PROJECTION_FRONTEND, PROJECTION_SCOPE, PROJECTION_SUBJECT_PREFIX};
use crate::app::window_frame::{DockEdge, DockMode};
use cmux_tui_core::PaneId;

/// A local mux with the workspaces `names` (the first is the test mux's
/// "work"), and an app with docked workspaces on and "work" active.
fn docked_app(test: &str, names: &[&str]) -> (Arc<Mux>, App, Receiver<AppEvent>) {
    let (mux, _surface) = test_mux(test, None);
    for name in names.iter().skip(1) {
        mux.new_workspace(Some((*name).to_string()), Some((20, 8))).unwrap();
    }
    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    app.sidebar_visible = false;
    app.config.viewport.docked_workspaces = true;
    app.client_focus_id = Some(format!("client-{test}"));
    app.replace_tree(app.session.tree());
    app.tree.active_workspace = workspace_index(&app, "work");
    (mux, app, events)
}

fn workspace_index(app: &App, name: &str) -> usize {
    app.tree.workspaces().iter().position(|workspace| workspace.name == name).unwrap()
}

fn workspace_pane(app: &App, name: &str) -> PaneId {
    let workspace = &app.tree.workspaces()[workspace_index(app, name)];
    workspace.active_screen_ref().unwrap().active_pane
}

fn pane_rect(app: &App, pane: PaneId) -> Option<Rect> {
    app.pane_areas.iter().find(|area| area.pane == pane).map(|area| area.rect)
}

fn stage_screen_of_workspace(app: &App, name: &str) -> Option<cmux_tui_core::ScreenId> {
    app.tree.workspaces()[workspace_index(app, name)].active_screen_ref().map(|screen| screen.id)
}

#[test]
fn docking_the_active_workspace_draws_it_on_its_edge_beside_the_stage() {
    let (_mux, mut app, _events) = docked_app("docked-left", &["work", "stage"]);

    app.run_action(Action::DockWorkspaceLeft).unwrap();
    app.sync_layout((100, 31));

    let content = app.content_area;
    // The default extent is 300 permille of the frame.
    let width = ((u32::from(content.width) * 300 + 500) / 1000) as u16;
    let dock = pane_rect(&app, workspace_pane(&app, "work")).expect("the dock draws its pane");
    let stage = pane_rect(&app, workspace_pane(&app, "stage")).expect("the stage draws its pane");
    assert_eq!(
        (dock.x, dock.y, dock.width, dock.height),
        (content.x, content.y, width, content.height)
    );
    assert_eq!((stage.x, stage.width), (content.x + width, content.width - width));
    // Focus stays in the docked workspace (W4); the stage shows the other one (W2).
    assert_eq!(app.tree.active_workspace, workspace_index(&app, "work"));
    assert_eq!(app.stage_screen_id(), stage_screen_of_workspace(&app, "stage"));
}

#[test]
fn a_click_in_a_dock_focuses_its_workspace_and_keeps_the_stage() {
    let (_mux, mut app, _events) = docked_app("docked-click", &["work", "stage"]);
    app.run_action(Action::DockWorkspaceLeft).unwrap();
    app.select_workspace_for_client(Some(workspace_index(&app, "stage")), None);
    app.sync_layout((100, 31));
    assert_eq!(app.stage_screen_id(), stage_screen_of_workspace(&app, "stage"));
    let stage_before = pane_rect(&app, workspace_pane(&app, "stage")).unwrap();
    let dock = pane_rect(&app, workspace_pane(&app, "work")).unwrap();

    app.handle_mouse(MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Left),
        column: dock.x + 3,
        row: dock.y + 3,
        modifiers: KeyModifiers::NONE,
    })
    .unwrap();
    app.sync_layout((100, 31));

    assert_eq!(app.tree.active_workspace, workspace_index(&app, "work"));
    assert_eq!(app.active_pane(), Some(workspace_pane(&app, "work")));
    assert_eq!(app.stage_screen_id(), stage_screen_of_workspace(&app, "stage"));
    assert_eq!(pane_rect(&app, workspace_pane(&app, "stage")), Some(stage_before));
}

#[test]
fn floating_or_hiding_a_dock_never_resizes_the_stage() {
    let (_mux, mut app, _events) = docked_app("docked-float", &["work", "stage"]);
    app.run_action(Action::DockWorkspaceBottom).unwrap();
    app.sync_layout((100, 31));
    let content = app.content_area;
    let docked_stage = pane_rect(&app, workspace_pane(&app, "stage")).unwrap();
    assert!(docked_stage.height < content.height, "a Docked band takes space");

    app.run_action(Action::ToggleDockFloating).unwrap();
    app.sync_layout((100, 31));
    let floating_stage = pane_rect(&app, workspace_pane(&app, "stage")).unwrap();
    assert_eq!(floating_stage.height, content.height, "a Floating band leaves the stage whole");
    let band = pane_rect(&app, workspace_pane(&app, "work")).expect("the band floats");
    assert_eq!(band.y + band.height, content.y + content.height);
    assert_eq!(app.docks.record.docks[0].mode, DockMode::Floating);

    // Hiding the focused dock hands focus to the stage, which keeps its size.
    app.run_action(Action::ToggleDockBottom).unwrap();
    app.sync_layout((100, 31));
    assert_eq!(app.tree.active_workspace, workspace_index(&app, "stage"));
    assert_eq!(pane_rect(&app, workspace_pane(&app, "work")), None);
    assert_eq!(pane_rect(&app, workspace_pane(&app, "stage")), Some(floating_stage));

    app.run_action(Action::ToggleDockBottom).unwrap();
    app.sync_layout((100, 31));
    assert!(pane_rect(&app, workspace_pane(&app, "work")).is_some());
    assert_eq!(pane_rect(&app, workspace_pane(&app, "stage")), Some(floating_stage));
}

#[test]
fn toggling_an_empty_edge_docks_a_new_workspace_there() {
    let (_mux, mut app, events) = docked_app("docked-toggle-new", &["work"]);
    let before = app.tree.workspaces().len();

    app.run_action(Action::ToggleDockRight).unwrap();
    settle_pending_mutations(&mut app, &events);
    app.sync_layout((100, 31));

    assert_eq!(app.tree.workspaces().len(), before + 1);
    let dock = app.docks.record.dock_at(DockEdge::Right).expect("the new workspace docks right");
    assert!(
        app.tree
            .workspaces()
            .iter()
            .any(|workspace| workspace.key == dock.workspace_key && workspace.name != "work")
    );
    let content = app.content_area;
    let (placement, _) = app.docks.placed.first().expect("the right dock is placed");
    assert_eq!(placement.rect.x + placement.rect.width, content.x + content.width);
}

#[test]
fn the_dock_record_survives_a_new_client() {
    let (mux, mut app, _events) = docked_app("docked-persist", &["work", "stage"]);
    let work_key = app.tree.workspaces()[workspace_index(&app, "work")].key.clone();
    app.run_action(Action::DockWorkspaceLeft).unwrap();
    app.run_action(Action::ToggleDockOrientation).unwrap();
    app.sync_layout((100, 31));

    let subject = format!("{PROJECTION_SUBJECT_PREFIX}client-docked-persist");
    let stored = mux
        .get_frontend_projection(PROJECTION_FRONTEND, PROJECTION_SCOPE, &subject)
        .unwrap()
        .expect("the record is in the client's frontend projection");
    assert_eq!(stored.projection["docks"][0]["edge"], "left");
    assert_eq!(stored.projection["docks"][0]["workspace_key"], work_key.as_str());
    assert_eq!(stored.projection["dock_orientation"], "row_major");

    // A restarted client with the same id reads the same frame.
    let mut restarted = test_app(Session::Local(mux));
    restarted.sidebar_visible = false;
    restarted.config.viewport.docked_workspaces = true;
    restarted.client_focus_id = Some("client-docked-persist".to_string());
    restarted.replace_tree(restarted.session.tree());
    restarted.tree.active_workspace = workspace_index(&restarted, "stage");
    restarted.sync_layout((100, 31));
    assert_eq!(restarted.docks.record.dock_at(DockEdge::Left).unwrap().workspace_key, work_key);
    let dock = pane_rect(&restarted, workspace_pane(&restarted, "work")).expect("restored dock");
    assert_eq!(dock.x, restarted.content_area.x);
}

#[test]
fn dock_actions_refuse_while_docked_workspaces_are_off() {
    let (_mux, mut app, _events) = docked_app("docked-off", &["work", "stage"]);
    app.config.viewport.docked_workspaces = false;

    app.run_action(Action::DockWorkspaceLeft).unwrap();
    app.sync_layout((100, 31));

    assert_eq!(
        app.status_message.as_deref(),
        Some(localization::catalog().menu.docked_workspaces_off)
    );
    assert!(app.docks.record.docks.is_empty());
    assert_eq!(pane_rect(&app, workspace_pane(&app, "stage")), None);
    assert_eq!(pane_rect(&app, workspace_pane(&app, "work")).map(|rect| rect.x), Some(0));
}

#[test]
fn left_and_bottom_docks_draw_their_panes_around_the_stage() {
    let (_mux, mut app, _events) = docked_app("docked-draw", &["work", "logs", "stage"]);
    app.run_action(Action::DockWorkspaceLeft).unwrap();
    app.select_workspace_for_client(Some(workspace_index(&app, "logs")), None);
    app.run_action(Action::DockWorkspaceBottom).unwrap();
    let mut terminal = Terminal::new(TestBackend::new(80, 24)).unwrap();
    app.draw_terminal(&mut terminal, RenderAction::Draw).unwrap();

    let glyphs = app.config.theme.border_style.glyphs();
    let buffer = terminal.backend().buffer().clone();
    for name in ["work", "logs", "stage"] {
        let rect = pane_rect(&app, workspace_pane(&app, name)).unwrap();
        let corner = buffer[(rect.x, rect.y + rect.height - 1)].symbol().to_string();
        assert_eq!(corner, glyphs.bottom_left, "{name} {rect:?}\n{}", buffer_text(&buffer));
    }
    let work = pane_rect(&app, workspace_pane(&app, "work")).unwrap();
    let logs = pane_rect(&app, workspace_pane(&app, "logs")).unwrap();
    let stage = pane_rect(&app, workspace_pane(&app, "stage")).unwrap();
    // Column major: the left dock owns the corner, the band spans the rest.
    assert_eq!(logs.x, work.x + work.width);
    assert_eq!(stage.x, logs.x);
    assert_eq!(stage.y + stage.height, logs.y);
    println!("{}", buffer_text(&buffer));
}
