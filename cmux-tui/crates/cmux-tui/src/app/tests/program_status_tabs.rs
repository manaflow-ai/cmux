//! cx-6so.36.7: a program's OSC 7501 status shows on its tab in the TUI.
//! A TUI attached to a daemon over its socket draws a working program's
//! progress after the tab title, then a `!` in the warning color once the
//! program waits on the user, without any action from the user.

use super::*;

/// The text of the first tab and the color of its last label cell.
fn first_tab(app: &mut App, terminal: &mut Terminal<TestBackend>) -> (String, Option<Color>) {
    terminal.draw(|frame| crate::ui::draw(app, frame)).unwrap();
    let Some(tab) = app.hits.iter().find_map(|(rect, hit)| {
        matches!(hit, crate::app::Hit::Tab { index: 0, .. }).then_some(*rect)
    }) else {
        return (String::new(), None);
    };
    let buffer = terminal.backend().buffer();
    let text: String =
        (tab.x..tab.x + tab.width).map(|x| buffer[(x, tab.y)].symbol().to_owned()).collect();
    let mark = (tab.x..tab.x + tab.width)
        .rev()
        .map(|x| &buffer[(x, tab.y)])
        .find(|cell| !cell.symbol().trim().is_empty());
    (text, mark.map(|cell| cell.fg))
}

/// Feeds the daemon's events to the app as its event loop would, until the
/// first tab reads `needle`.
fn wait_for_tab(
    app: &mut App,
    terminal: &mut Terminal<TestBackend>,
    mux_events: &cmux_tui_core::MuxEventReceiver,
    app_events: &Receiver<AppEvent>,
    needle: &str,
) -> (String, Option<Color>) {
    let deadline = Instant::now() + crate::test_wait::EVENT;
    loop {
        let tab = first_tab(app, terminal);
        if tab.0.contains(needle) {
            return tab;
        }
        assert!(Instant::now() < deadline, "the tab never showed {needle:?}; it reads {:?}", tab.0);
        while let Ok(event) = mux_events.try_recv() {
            app.handle(AppEvent::Mux(event)).unwrap();
        }
        while let Ok(event) = app_events.try_recv() {
            app.handle(event).unwrap();
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn a_remote_tab_shows_its_programs_progress_then_its_wait() {
    let mux = Mux::new(
        "program-status-tab-test",
        SurfaceOptions {
            // The test writes the program's reports; cat prints them back.
            command: Some(vec![
                "/bin/sh".to_string(),
                "-c".to_string(),
                "stty raw -echo; exec cat".to_string(),
            ]),
            cols: 40,
            rows: 8,
            ..Default::default()
        },
    );
    let surface = mux.new_workspace(Some("work".to_string()), Some((40, 8))).unwrap();
    let dir = PathBuf::from(format!(
        "/tmp/cmux-osc7501-tab-{}-{:?}",
        std::process::id(),
        std::thread::current().id()
    ));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("mux.sock");
    server::serve(mux.clone(), Some(socket.clone())).unwrap();
    let remote = RemoteSession::connect(&socket).unwrap();
    let mux_events = remote.subscribe();
    let session = Session::Remote(remote);
    let tree = session.refresh_tree().unwrap();
    let (mut app, app_events) = test_app_with_events(session);
    app.sidebar_visible = false;
    app.replace_tree(tree);
    app.sync_layout((40, 10));
    let mut terminal = Terminal::new(TestBackend::new(40, 10)).unwrap();

    surface.write_bytes(b"\x1b]7501;state=working:progress=40\x1b\\").unwrap();
    let (working, _) = wait_for_tab(&mut app, &mut terminal, &mux_events, &app_events, "40%");
    assert!(!working.contains('!'), "{working:?}");

    surface.write_bytes(b"\x1b]7501;state=blocked:kind=permission\x1b\\").unwrap();
    let (blocked, color) = wait_for_tab(&mut app, &mut terminal, &mux_events, &app_events, " ! ");
    assert!(!blocked.contains('%'), "a waiting program shows no progress it did not report");
    assert_eq!(color, Some(app.config.theme.notification_warning), "{blocked:?}");

    mux.close_surface(surface.id).unwrap();
    let _ = std::fs::remove_dir_all(dir);
}
