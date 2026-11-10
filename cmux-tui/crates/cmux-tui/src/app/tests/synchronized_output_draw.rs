//! Tests: a pane draws a synchronized update (DEC mode 2026) as one frame,
//! through the App's real draw path.

use super::*;

fn screen(app: &mut App, terminal: &mut Terminal<TestBackend>) -> String {
    app.render_action(terminal, RenderAction::Draw).unwrap();
    buffer_text(terminal.backend().buffer())
}

#[test]
fn a_pane_never_draws_a_half_finished_synchronized_update() {
    let (mux, surface) = test_mux("synchronized-output-draw", None);
    surface.with_terminal(|terminal| terminal.vt_write(b"BEFORE"));
    let mut app = test_app(Session::Local(mux.clone()));
    app.sidebar_visible = false;
    app.replace_tree(app.session.tree());
    app.sync_layout((40, 12));
    let mut terminal = Terminal::new(TestBackend::new(40, 12)).unwrap();
    assert!(screen(&mut app, &mut terminal).contains("BEFORE"));

    // The program starts an update and has cleared the screen and drawn half.
    surface.with_terminal(|terminal| terminal.vt_write(b"\x1b[?2026h\x1b[2J\x1b[HHALF"));
    let held = screen(&mut app, &mut terminal);
    assert!(
        held.contains("BEFORE") && !held.contains("HALF"),
        "the pane drew a half-finished synchronized update:\n{held}"
    );

    surface.with_terminal(|terminal| terminal.vt_write(b"DONE\x1b[?2026l"));
    let whole = screen(&mut app, &mut terminal);
    assert!(
        whole.contains("HALFDONE") && !whole.contains("BEFORE"),
        "the finished update must show at once:\n{whole}"
    );
    mux.close_surface(surface.id).unwrap();
}
