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

/// Sends `bytes` to the pane's program (`cat` on a raw tty, so they come back
/// as its output through the real PTY reader) and handles the App's events
/// until the terminal satisfies `until`.
fn program_prints(
    app: &mut App,
    events: &Receiver<AppEvent>,
    surface: &cmux_tui_core::Surface,
    bytes: &[u8],
    until: impl Fn(&mut ghostty_vt::Terminal) -> bool,
) {
    surface.write_bytes(bytes).unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while !surface.with_terminal(|terminal| until(terminal)).unwrap_or(false) {
        assert!(Instant::now() < deadline, "the program's output never arrived");
        if let Ok(event) = events.recv_timeout(Duration::from_millis(20)) {
            app.handle(event).unwrap();
        }
    }
    while let Ok(event) = events.recv_timeout(Duration::from_millis(50)) {
        app.handle(event).unwrap();
    }
}

fn shows(text: &'static str) -> impl Fn(&mut ghostty_vt::Terminal) -> bool {
    move |terminal| terminal.viewport_text().is_ok_and(|shown| shown.contains(text))
}

/// A click on a pane while its program holds a synchronized update is aimed
/// at the frame from before the update, and the terminal already holds
/// content the user has not seen. It fails closed, as any click on changed
/// content does (pty_mouse.rs `immediate_terminal_press_rejects_content_changed_before_surface_output`):
/// it never reaches the program mid-update, and it is not replayed against
/// the finished update, which the user never aimed at. The first click after
/// the update reaches the program.
#[test]
fn a_click_during_a_synchronized_update_never_meets_content_the_user_did_not_see() {
    let mux = Mux::new(
        "synchronized-output-click",
        SurfaceOptions {
            command: Some(vec![
                "/bin/sh".to_string(),
                "-c".to_string(),
                "stty raw -echo; printf ready; exec cat".to_string(),
            ]),
            ..Default::default()
        },
    );
    let surface = mux.new_workspace(Some("work".to_string()), Some((20, 8))).unwrap();
    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    app.replace_tree(app.session.tree());
    app.sidebar_visible = false;
    app.sync_layout((40, 12));
    let deadline = Instant::now() + Duration::from_secs(5);
    while !surface.with_terminal(shows("ready")).unwrap_or(false) {
        assert!(Instant::now() < deadline, "the program never started");
        if let Ok(event) = events.recv_timeout(Duration::from_millis(20)) {
            app.handle(event).unwrap();
        }
    }
    program_prints(&mut app, &events, &surface, b"\x1b[?1000h\x1b[?1006hBEFORE", shows("BEFORE"));
    let mut terminal = Terminal::new(TestBackend::new(40, 12)).unwrap();
    assert!(screen(&mut app, &mut terminal).contains("BEFORE"));
    let content = app.pane_areas[0].content;
    let press = MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Left),
        column: content.x + 4,
        row: content.y + 2,
        modifiers: KeyModifiers::NONE,
    };

    // The program starts an update; the pane repaints, still showing the
    // frame from before it.
    program_prints(&mut app, &events, &surface, b"\x1b[?2026h\x1b[2J\x1b[HHALF", shows("HALF"));
    let held = screen(&mut app, &mut terminal);
    assert!(held.contains("BEFORE") && !held.contains("HALF"), "the update must hold:\n{held}");

    app.encode_buf.clear();
    app.handle(AppEvent::Input(Event::Mouse(press))).unwrap();
    // The event loop replays waiting input every turn.
    app.replay_deferred_input().unwrap();
    // The click met the held pane: no draw ran since, so the hold stands
    // whatever the wall clock says (only a draw or the loop releases it).
    assert!(app.synchronized_output.deadline().is_some(), "the hold ended before the click");
    assert!(app.encode_buf.is_empty(), "the click reached the program mid-update");

    program_prints(&mut app, &events, &surface, b"DONE\x1b[?2026l", shows("HALFDONE"));
    assert!(screen(&mut app, &mut terminal).contains("HALFDONE"));
    app.replay_deferred_input().unwrap();
    assert!(
        app.encode_buf.is_empty(),
        "a click aimed at the frame before the update reached the finished update"
    );
    assert!(app.deferred_input.is_empty());

    app.handle(AppEvent::Input(Event::Mouse(press))).unwrap();
    assert!(
        app.encode_buf.starts_with(b"\x1b[<0;") && app.encode_buf.ends_with(b"M"),
        "a click after the update must reach the program: {:?}",
        String::from_utf8_lossy(&app.encode_buf)
    );
    mux.close_surface(surface.id).unwrap();
}
