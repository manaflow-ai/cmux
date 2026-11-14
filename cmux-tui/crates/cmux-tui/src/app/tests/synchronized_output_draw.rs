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

/// A program whose synchronized update ran out its hold (drawn live, as a
/// stuck program is) may end that update and start the next one between two
/// draws. The new update holds again: the pane never draws its first half.
#[test]
fn an_update_started_after_an_expired_hold_is_held_again() {
    let (mux, surface) = test_mux("synchronized-output-expired", None);
    surface.with_terminal(|terminal| terminal.vt_write(b"BEFORE"));
    let mut app = test_app(Session::Local(mux.clone()));
    app.sidebar_visible = false;
    app.replace_tree(app.session.tree());
    app.sync_layout((40, 12));
    let mut terminal = Terminal::new(TestBackend::new(40, 12)).unwrap();
    assert!(screen(&mut app, &mut terminal).contains("BEFORE"));

    surface.with_terminal(|terminal| terminal.vt_write(b"\x1b[?2026h\x1b[2J\x1b[HSTUCK"));
    assert!(!screen(&mut app, &mut terminal).contains("STUCK"), "the update must hold");
    // The hold runs out, as the event loop's timeout ends it.
    let deadline = app.synchronized_output.deadline().expect("a held update");
    assert!(app.synchronized_output.release_expired(deadline));
    assert!(screen(&mut app, &mut terminal).contains("STUCK"), "a stuck update is drawn live");

    // Between two draws the program ends that update and draws half of the
    // next one.
    surface.with_terminal(|terminal| {
        terminal.vt_write(b"\x1b[?2026l\x1b[?2026h\x1b[2J\x1b[HPART");
    });
    let held = screen(&mut app, &mut terminal);
    assert!(
        held.contains("STUCK") && !held.contains("PART"),
        "the pane drew a half-finished update that started after an expired hold:\n{held}"
    );

    surface.with_terminal(|terminal| terminal.vt_write(b"REST\x1b[?2026l"));
    let whole = screen(&mut app, &mut terminal);
    assert!(whole.contains("PARTREST"), "the finished update must show at once:\n{whole}");
    mux.close_surface(surface.id).unwrap();
}

/// A click on a pane while its program holds a synchronized update waits for
/// the update, then reaches the program, as a click waiting on any repaint
/// does; it is never dropped.
#[test]
fn a_click_during_a_synchronized_update_reaches_the_program_after_it() {
    let (mux, surface) = test_mux("synchronized-output-click", None);
    surface.with_terminal(|terminal| terminal.vt_write(b"\x1b[?1000h\x1b[?1006hBEFORE"));
    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    app.replace_tree(app.session.tree());
    app.sidebar_visible = false;
    app.sync_layout((40, 12));
    while app.session.has_pending_mutations() {
        app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
    }
    let mut terminal = Terminal::new(TestBackend::new(40, 12)).unwrap();
    assert!(screen(&mut app, &mut terminal).contains("BEFORE"));
    let content = app.pane_areas[0].content;

    // The program starts an update; its output reaches the App and the pane
    // repaints, still showing the frame before the update.
    surface.with_terminal(|terminal| terminal.vt_write(b"\x1b[?2026h\x1b[2J\x1b[HHALF"));
    let repaint = app.handle(AppEvent::Mux(MuxEvent::SurfaceOutput(surface.id))).unwrap();
    app.render_action(&mut terminal, repaint).unwrap();
    assert!(buffer_text(terminal.backend().buffer()).contains("BEFORE"));

    app.encode_buf.clear();
    app.handle(AppEvent::Input(Event::Mouse(MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Left),
        column: content.x + 4,
        row: content.y + 2,
        modifiers: KeyModifiers::NONE,
    })))
    .unwrap();
    // The event loop replays waiting input every turn.
    app.replay_deferred_input().unwrap();
    assert!(app.encode_buf.is_empty(), "the click reached the program mid-update");

    surface.with_terminal(|terminal| terminal.vt_write(b"DONE\x1b[?2026l"));
    let repaint = app.handle(AppEvent::Mux(MuxEvent::SurfaceOutput(surface.id))).unwrap();
    app.render_action(&mut terminal, repaint).unwrap();
    assert!(buffer_text(terminal.backend().buffer()).contains("HALFDONE"));
    app.replay_deferred_input().unwrap();
    assert_eq!(
        app.encode_buf, b"\x1b[<0;5;3M",
        "a click made during a synchronized update was dropped"
    );
    mux.close_surface(surface.id).unwrap();
}
