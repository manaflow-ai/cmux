//! The sidebar rails draw only their visible rows: a frame's work (items walked, cloned, rows
//! built) is flat in the number of workspaces (cmux-view-rows frame_work). Each rail is drawn
//! at N = 100 and N = 10,000 into a TestBackend; the frame measured is the one after a warm-up
//! frame, with nothing changed between them (an idle redraw, a hover).
//!
//! To register a rail: count its row-building points under `#[cfg(test)]` with
//! `cmux_view_rows::frame_work::{walked, cloned, built}` (see draw_workspaces in ui/sidebar.rs),
//! then add a test here that calls
//! `contract(name, Expect::Flat | Expect::Grows(baseline), |n| { set up n; draw; measure(draw) })`.

use cmux_view_rows::frame_work::{Expect, FrameWork, contract, measure};

use super::*;

/// A tree of `n` workspaces, each one screen, pane and tab.
fn workspaces(n: usize) -> TreeView {
    let template = notify_tree(1, false).workspaces()[0].clone();
    let all = (0..n)
        .map(|i| {
            let mut ws = template.clone();
            let id = 1_000 + i as u64;
            ws.id = id;
            ws.key = format!("00000000-0000-4000-8000-{id:012}");
            ws.short_id = format!("{id:06}");
            ws.name = format!("work {i}");
            ws
        })
        .collect();
    TreeView::from_parts(all, 0, Some(1), 0)
}

/// The workspace rail at `n` workspaces: the work of the frame after the first.
fn workspace_rail_at(n: usize) -> FrameWork {
    let mux = Mux::new("frame-work-workspace-rail", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.tree = workspaces(n);
    // A rail 30 columns wide, as a person shows it (the test app starts with none).
    app.sidebar_visible = true;
    app.sidebar_width = 30;
    app.sidebar_view = SidebarView::Workspaces;
    let mut terminal = Terminal::new(TestBackend::new(140, 40)).unwrap();
    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
    let work = measure(|| {
        terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
    });
    assert!(work.built > 0, "the workspace rail drew no row: {work}");
    work
}

/// Baseline: the rail draws only the rows in view, but steps over every workspace to find them
/// (`viewport.body_y` per row) each frame.
#[test]
fn the_workspace_rail_is_a_known_whole_list_walk() {
    contract(
        "cmux-tui workspace rail",
        Expect::Grows("fix in lane visible-only-ios-rust-lists, then flip to Expect::Flat"),
        workspace_rail_at,
    )
    .unwrap();
}
