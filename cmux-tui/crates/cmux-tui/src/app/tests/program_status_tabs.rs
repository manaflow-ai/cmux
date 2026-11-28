//! cx-6so.36.7: a program's OSC 7501 status shows on its tab in the TUI.
//! A TUI attached to a daemon over its socket draws a working program's
//! progress after the tab title, then a `!` once the program waits on the
//! user, and no mark once it clears its status, without any action from the
//! user.

use super::*;

/// The text of the first tab, rendered as the event loop renders `action`.
fn first_tab(app: &mut App, terminal: &mut Terminal<TestBackend>, action: RenderAction) -> String {
    app.draw_terminal(terminal, action).unwrap();
    let Some(tab) = app.hits.iter().find_map(|(rect, hit)| {
        matches!(hit, crate::app::Hit::Tab { index: 0, .. }).then_some(*rect)
    }) else {
        return String::new();
    };
    let buffer = terminal.backend().buffer();
    (tab.x..tab.x + tab.width).map(|x| buffer[(x, tab.y)].symbol().to_owned()).collect()
}

/// Feeds the daemon's events to the app as its event loop would, until the
/// first tab reads as `wanted` describes.
fn wait_for_tab(
    app: &mut App,
    terminal: &mut Terminal<TestBackend>,
    mux_events: &cmux_tui_core::MuxEventReceiver,
    app_events: &Receiver<AppEvent>,
    wanted: &str,
    shown: impl Fn(&str) -> bool,
) -> String {
    let deadline = Instant::now() + crate::test_wait::EVENT;
    let mut action = RenderAction::Draw;
    loop {
        let tab = first_tab(app, terminal, action);
        if shown(&tab) {
            return tab;
        }
        assert!(Instant::now() < deadline, "the tab never showed {wanted}; it reads {tab:?}");
        // Like the event loop: the frame redraws the layout only when an
        // event asked for it.
        action = RenderAction::Paint;
        let events = std::iter::from_fn(|| mux_events.try_recv().ok().map(AppEvent::Mux))
            .chain(std::iter::from_fn(|| app_events.try_recv().ok()))
            .collect::<Vec<_>>();
        for event in events {
            if app.handle(event).unwrap() == RenderAction::Draw {
                action = RenderAction::Draw;
            }
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn a_remote_tab_shows_its_programs_progress_then_its_wait() {
    let mux = Mux::new(
        "program-status-tab-test",
        SurfaceOptions {
            // The program reports progress, waits on the user once the test
            // presses Enter, and clears its status after the next one.
            command: Some(vec![
                "/bin/sh".to_string(),
                "-c".to_string(),
                concat!(
                    "printf '\\033]7501;state=working:progress=40\\033\\\\'; read _; ",
                    "printf '\\033]7501;state=blocked:kind=permission\\033\\\\'; read _; ",
                    "printf '\\033]7501;state=clear\\033\\\\'; sleep 600",
                )
                .to_string(),
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

    let working = wait_for_tab(&mut app, &mut terminal, &mux_events, &app_events, "40%", |tab| {
        tab.contains("40%")
    });
    assert!(!working.contains('!'), "{working:?}");

    surface.write_bytes(b"\r").unwrap();
    let blocked = wait_for_tab(&mut app, &mut terminal, &mux_events, &app_events, "!", |tab| {
        tab.contains(" ! ")
    });
    assert!(!blocked.contains('%'), "a waiting program shows no progress it did not report");

    // The daemon sends each shown status once, so a missed one would stay.
    surface.write_bytes(b"\r").unwrap();
    let cleared =
        wait_for_tab(&mut app, &mut terminal, &mux_events, &app_events, "no mark", |tab| {
            !tab.is_empty() && !tab.contains('!')
        });
    assert!(!cleared.contains('%'), "{cleared:?}");

    mux.close_surface(surface.id).unwrap();
    let _ = std::fs::remove_dir_all(dir);
}
