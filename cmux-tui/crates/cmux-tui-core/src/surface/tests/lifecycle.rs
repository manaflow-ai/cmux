//! Surface lifecycle tests: reader and reaper shutdown, child startup guard,
//! terminal projections, and spawn deadlines.

use super::*;

#[test]
fn finish_terminal_reader_joins_owned_reaper_before_deadline() {
    let mux = Mux::new_for_test("reaper-join", SurfaceOptions::default());
    let surface = Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux))
        .expect("test PTY should spawn");
    let (started_tx, started_rx) = sync_channel(0);
    let reaper = std::thread::spawn(move || {
        started_tx.send(()).unwrap();
    });
    surface.install_terminal_reaper_for_test(reaper);
    started_rx.recv().unwrap();

    let pty = surface.as_pty().unwrap();
    surface.finish_terminal_reader(Instant::now() + Duration::from_secs(1));

    assert!(
        pty.reaper_thread.lock().unwrap().is_none(),
        "terminal teardown must consume the child-reaper join handle"
    );
}

#[test]
fn finish_terminal_reader_retains_reaper_after_deadline() {
    let mux = Mux::new_for_test("reaper-timeout", SurfaceOptions::default());
    let surface = Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux))
        .expect("test PTY should spawn");
    let (started_tx, started_rx) = sync_channel(0);
    let (release_tx, release_rx) = sync_channel(0);
    let reaper = std::thread::spawn(move || {
        started_tx.send(()).unwrap();
        release_rx.recv().unwrap();
    });
    surface.install_terminal_reaper_for_test(reaper);
    started_rx.recv().unwrap();

    let pty = surface.as_pty().unwrap();
    surface.finish_terminal_reader(Instant::now());
    assert!(
        pty.reaper_thread.lock().unwrap().is_some(),
        "a live child-reaper handle must remain owned after timeout"
    );

    release_tx.send(()).unwrap();
    assert!(pty.reaper_completion.wait_until(Instant::now() + Duration::from_secs(1)));
    surface.finish_terminal_reader(Instant::now() + Duration::from_secs(1));
    assert!(pty.reaper_thread.lock().unwrap().is_none());
}

#[test]
fn finish_terminal_reader_does_not_self_join_reaper() {
    let mux = Mux::new_for_test("reaper-self-join", SurfaceOptions::default());
    let surface = Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux))
        .expect("test PTY should spawn");
    let (started_tx, started_rx) = sync_channel(0);
    let (proceed_tx, proceed_rx) = sync_channel(0);
    let completion = surface.install_terminal_reaper_that_finishes_for_test(started_tx, proceed_rx);
    started_rx.recv().unwrap();
    proceed_tx.send(()).unwrap();

    assert!(completion.wait_until(Instant::now() + Duration::from_secs(1)));
    let pty = surface.as_pty().unwrap();
    surface.finish_terminal_reader(Instant::now() + Duration::from_secs(1));
    assert!(pty.reaper_thread.lock().unwrap().is_none());
}

#[cfg(unix)]
#[test]
fn local_surface_reaper_timeout_retains_production_handle() {
    let mux = Mux::new_for_test("production-reaper-timeout", SurfaceOptions::default());
    let surface = Surface::spawn(
        2,
        SurfaceOptions {
            command: Some(vec!["/bin/sh".into(), "-c".into(), "read _".into()]),
            ..SurfaceOptions::default()
        },
        Arc::downgrade(&mux),
    )
    .expect("local PTY should spawn");
    let pty = surface.as_pty().expect("spawned surface should be a PTY");

    surface.finish_terminal_reader(Instant::now());
    assert!(
        pty.reaper_thread.lock().unwrap().is_some(),
        "a live production child-reaper handle must remain owned after timeout"
    );

    surface.kill();
    assert!(
        pty.reaper_completion.wait_until(Instant::now() + Duration::from_secs(1)),
        "killing the local PTY must release the production reaper"
    );
    surface.finish_terminal_reader(Instant::now() + Duration::from_secs(1));
    assert!(pty.reaper_thread.lock().unwrap().is_none());
}

#[test]
fn pty_child_startup_guard_kills_and_waits_on_drop() {
    let state = Arc::new(StartupChildState::default());
    {
        let _guard = PtyChildStartupGuard::new(Box::new(StartupChild { state: state.clone() }));
    }

    assert_eq!(state.kill_count.load(Ordering::Relaxed), 1);
    assert_eq!(state.wait_count.load(Ordering::Relaxed), 1);
}

#[test]
fn agent_browser_provider_uses_a_terminal_local_daemon_session() {
    let mut options = SurfaceOptions {
        extra_env: vec![
            ("CMUX_TUI_AGENT_BROWSER_PROVIDER".into(), "1".into()),
            ("AGENT_BROWSER_SESSION".into(), "unsafe-shared-session".into()),
        ],
        ..SurfaceOptions::default()
    };
    configure_agent_browser_session(&mut options, "term_0123456789abcdef");
    assert_eq!(
        options
            .extra_env
            .iter()
            .find(|(key, _)| key == "AGENT_BROWSER_SESSION")
            .map(|(_, value)| value.as_str()),
        Some("cmux-term_0123456789abcdef")
    );
}

#[test]
fn terminal_projection_has_distinct_view_identity_and_shared_runtime() {
    let mux = Mux::new_for_test("terminal-projection", SurfaceOptions::default());
    let source =
        Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
    let source_identity = source.resource_identity().unwrap().clone();
    let projection = source
        .project_terminal(
            2,
            TabResourceIdentity::new(
                crate::resource::TabPublicId::random().unwrap(),
                source_identity.content_id,
            ),
        )
        .unwrap();

    assert_eq!(source.id, 1);
    assert_eq!(projection.id, 2);
    assert!(source.shares_terminal_runtime(&projection));
    let foreign_identity = TabResourceIdentity::new(
        crate::resource::TabPublicId::random().unwrap(),
        ContentPublicId::Terminal(TerminalPublicId::random().unwrap()),
    );
    assert!(source.project_terminal(3, foreign_identity).is_err());

    source.set_name(Some("source".into()));
    projection.set_name(Some("projection".into()));
    assert_eq!(source.name().as_deref(), Some("source"));
    assert_eq!(projection.name().as_deref(), Some("projection"));

    projection.resize(91, 37).unwrap();
    assert_eq!(source.size(), (91, 37));
    source.with_terminal(|terminal| terminal.vt_write(b"shared-output"));
    let projected_text =
        projection.with_terminal(|terminal| terminal.viewport_text().unwrap()).unwrap();
    assert!(projected_text.contains("shared-output"));

    source.with_terminal(|terminal| {
        for line in 0..48 {
            terminal.vt_write(format!("\r\nline-{line:02}").as_bytes());
        }
    });
    let bottom = projection.view_scrollbar().unwrap();
    assert!(!bottom.scrolled_back());
    source.view_scroll_delta(-5).unwrap();
    let source_scrollbar = source.view_scrollbar().unwrap();
    let projection_scrollbar = projection.view_scrollbar().unwrap();
    assert!(source_scrollbar.scrolled_back());
    assert_eq!(projection_scrollbar, bottom);
    let compatibility_scrollbar =
        source.with_terminal(|terminal| terminal.scrollbar().unwrap()).unwrap();
    assert_eq!(compatibility_scrollbar, bottom);

    let mut source_render = RenderState::new().unwrap();
    let mut projection_render = RenderState::new().unwrap();
    let source_frame = source.render_view_frame(&mut source_render).unwrap();
    let projection_frame = projection.render_view_frame(&mut projection_render).unwrap();
    assert_ne!(source_frame.frame.runs(), projection_frame.frame.runs());
    assert_eq!(projection.view_scrollbar().unwrap(), bottom);
    let compatibility_after_render =
        source.with_terminal(|terminal| terminal.scrollbar().unwrap()).unwrap();
    assert_eq!(compatibility_after_render, bottom);

    let writer = CapturingWriter::default();
    replace_local_writer(&source, Box::new(writer.clone()));
    source.write_bytes(b"first").unwrap();
    projection.write_bytes(b"second").unwrap();
    assert_eq!(&*writer.0.lock().unwrap(), b"firstsecond");
}

#[test]
fn surface_enum_keeps_terminal_state_out_of_line() {
    // Test-only geometry and PTY hooks add fields that release builds omit.
    const MAX_TEST_SURFACE_BYTES: usize = 800;
    assert!(
        size_of::<Surface>() <= MAX_TEST_SURFACE_BYTES,
        "Surface grew to {} bytes (PTY {}, browser {}); keep large runtime state out of line",
        size_of::<Surface>(),
        size_of::<PtySurface>(),
        size_of::<BrowserSurface>()
    );
}

#[cfg(target_os = "macos")]
#[test]
fn macos_surface_spawn_returns_within_deadline() {
    let (result_tx, result_rx) = sync_channel(1);
    std::thread::spawn(move || {
        let mux = Mux::new_for_test("macos-pty-deadline", SurfaceOptions::default());
        let options = SurfaceOptions {
            command: Some(vec!["/bin/sh".into(), "-c".into(), "exit 0".into()]),
            ..SurfaceOptions::default()
        };
        let result = Surface::spawn(9_001, options, Arc::downgrade(&mux))
            .map(drop)
            .map_err(|error| error.to_string());
        let _ = result_tx.send(result);
    });

    result_rx
        .recv_timeout(Duration::from_secs(5))
        .expect("macOS surface PTY spawn blocked past its five-second deadline")
        .expect("macOS surface PTY spawn failed");
}
