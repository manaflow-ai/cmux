//! Resize replay and kitty image alias state.

use super::*;

#[test]
fn two_views_of_one_terminal_keep_independent_scroll_offsets() {
    let mut server = Terminal::new(12, 4, 100, Callbacks::default()).unwrap();
    for index in 0..20 {
        server.vt_write(format!("shared-{index:02}\r\n").as_bytes());
    }
    let replay = server.vt_replay_bytes().unwrap();
    let first = test_remote_pty_surface(1, 12, 4, (8, 16));
    let second = test_remote_pty_surface(2, 12, 4, (8, 16));
    first.apply_stream_resize(12, 4, Some(&replay), &[]).unwrap();
    second.apply_stream_resize(12, 4, Some(&replay), &[]).unwrap();

    first.term.lock().unwrap().scroll_delta(-5);
    let first_scrollbar = first.term.lock().unwrap().scrollbar().unwrap();
    let second_scrollbar = second.term.lock().unwrap().scrollbar().unwrap();
    assert!(first_scrollbar.scrolled_back());
    assert!(!second_scrollbar.scrolled_back());
    assert_ne!(first_scrollbar.offset, second_scrollbar.offset);
    assert_eq!(
        first.term.lock().unwrap().selection_text_absolute((0, 0), (8, 0)).unwrap(),
        second.term.lock().unwrap().selection_text_absolute((0, 0), (8, 0)).unwrap()
    );
}

#[test]
fn failed_resize_alias_restore_keeps_the_previous_mirror() {
    let surface = test_remote_pty_surface(7, 12, 4, (8, 16));
    surface.term.lock().unwrap().vt_write(b"previous");
    let previous = surface.term.lock().unwrap().plain_text().unwrap();
    let mut authoritative = Terminal::new(8, 4, 100, Callbacks::default()).unwrap();
    authoritative.vt_write(b"replacement");
    let replay = authoritative.vt_replay().unwrap();

    surface
        .apply_stream_resize_with_colors(
            8,
            4,
            Some(&replay.bytes),
            &[ghostty_vt::KittyImageAlias { image_id: 999, image_number: 77 }],
            Some(replay.kitty_state),
            None,
            &replay.pending_sequence,
        )
        .unwrap_err();

    let mut mirror = surface.term.lock().unwrap();
    assert_eq!(mirror.cols(), 12);
    assert_eq!(mirror.plain_text().unwrap(), previous);
}

#[test]
fn malformed_resize_alias_sidecar_keeps_the_previous_mirror() {
    let session = test_session(Box::new(SilentWriter));
    let surface = test_remote_pty_surface(7, 12, 4, (8, 16));
    surface.term.lock().unwrap().vt_write(b"previous");
    let previous = surface.term.lock().unwrap().plain_text().unwrap();
    session.surfaces.lock().unwrap().insert(7, surface.clone());
    let mut authoritative = Terminal::new(8, 4, 100, Callbacks::default()).unwrap();
    authoritative.vt_write(b"replacement");
    let replay = authoritative.vt_replay_bytes().unwrap();

    session.handle_line(json!({
        "event": "resized",
        "surface": 7,
        "cols": 8,
        "rows": 4,
        "replay": base64::engine::general_purpose::STANDARD.encode(replay),
        "kitty_image_aliases": [{"image_id": 7}],
    }));

    let mut mirror = surface.term.lock().unwrap();
    assert_eq!(mirror.cols(), 12);
    assert_eq!(mirror.plain_text().unwrap(), previous);
}

#[test]
fn remote_kitty_alias_sidecar_rejects_more_than_the_terminal_host_limit() {
    let aliases = (1..=cmux_tui_core::terminal_host_protocol::MAX_KITTY_IMAGE_ALIASES + 1)
        .map(|image_id| json!({"image_id": image_id, "image_number": image_id}))
        .collect::<Vec<_>>();
    let value = json!({"kitty_image_aliases": aliases});

    assert!(parse_kitty_image_aliases(&value).is_err());
}

#[test]
fn remote_kitty_alias_sidecar_rejects_zero_values() {
    for alias in
        [json!({"image_id": 0, "image_number": 1}), json!({"image_id": 1, "image_number": 0})]
    {
        let value = json!({"kitty_image_aliases": [alias]});
        assert!(parse_kitty_image_aliases(&value).is_err());
    }
}

#[test]
fn remote_kitty_alias_sidecar_rejects_duplicate_image_ids() {
    let value = json!({
        "kitty_image_aliases": [
            {"image_id": 7, "image_number": 41},
            {"image_id": 7, "image_number": 42},
        ],
    });

    assert!(parse_kitty_image_aliases(&value).is_err());
}

#[test]
fn remote_kitty_replay_state_is_bounded_and_strict() {
    let limits = KittyGraphicsLimits::default();
    let valid = json!({
        "kitty_graphics_state": {
            "image_bytes": limits.image_bytes,
            "inflight_bytes": limits.inflight_bytes,
            "images": limits.images,
            "placements": limits.placements,
            "replay_cursor_offset": 9,
            "primary_replay_next_image_id": 41,
            "primary_next_image_id": 42,
            "alternate_replay_next_image_id": 43,
            "alternate_next_image_id": 44,
        }
    });
    assert_eq!(
        parse_kitty_replay_state(&valid).unwrap(),
        KittyReplayState {
            limits,
            replay_cursor_offset: 9,
            replay_next_image_ids: KittyImageIdCursors { primary: 41, alternate: 43 },
            next_image_ids: KittyImageIdCursors { primary: 42, alternate: 44 },
        }
    );
    assert_eq!(parse_kitty_replay_state(&json!({})).unwrap(), KittyReplayState::disabled());

    let mut oversized = valid.clone();
    oversized["kitty_graphics_state"]["image_bytes"] = json!(u64::MAX);
    assert!(parse_kitty_replay_state(&oversized).is_err());
    let mut zero_cursor = valid.clone();
    zero_cursor["kitty_graphics_state"]["alternate_next_image_id"] = json!(0);
    assert!(parse_kitty_replay_state(&zero_cursor).is_err());
    let mut extra = valid;
    extra["kitty_graphics_state"]["future"] = json!(1);
    assert!(parse_kitty_replay_state(&extra).is_err());
}

#[test]
fn resized_event_preserves_the_automatic_kitty_image_id_cursor() {
    let session = test_session(Box::new(SilentWriter));
    let surface = test_remote_pty_surface(7, 12, 4, (8, 16));
    session.surfaces.lock().unwrap().insert(7, surface.clone());
    let mut authoritative = Terminal::new(12, 4, 100, Callbacks::default()).unwrap();
    authoritative.vt_write(b"\x1b_Ga=t,t=d,f=24,I=1,s=1,v=1,q=2;/wAA\x1b\\");
    let first_id = authoritative.kitty_graphics_snapshot().unwrap().images[0].id;
    authoritative.vt_write(format!("\x1b_Ga=d,d=I,i={first_id},q=2;\x1b\\").as_bytes());
    let replay = authoritative.vt_replay().unwrap();
    let state = replay.kitty_state;

    session.handle_line(json!({
        "event": "resized",
        "surface": 7,
        "cols": 12,
        "rows": 4,
        "replay": base64::engine::general_purpose::STANDARD.encode(&replay.bytes),
        "kitty_image_aliases": [],
        "kitty_graphics_state": {
            "image_bytes": state.limits.image_bytes,
            "inflight_bytes": state.limits.inflight_bytes,
            "images": state.limits.images,
            "placements": state.limits.placements,
            "replay_cursor_offset": state.replay_cursor_offset,
            "primary_replay_next_image_id": state.replay_next_image_ids.primary,
            "primary_next_image_id": state.next_image_ids.primary,
            "alternate_replay_next_image_id": state.replay_next_image_ids.alternate,
            "alternate_next_image_id": state.next_image_ids.alternate,
        },
    }));

    let next = b"\x1b_Ga=t,t=d,f=24,I=2,s=1,v=1,q=2;AP8A\x1b\\";
    authoritative.vt_write(next);
    surface.term.lock().unwrap().vt_write(next);
    assert_eq!(
        surface.term.lock().unwrap().kitty_graphics_snapshot().unwrap().images[0].id,
        authoritative.kitty_graphics_snapshot().unwrap().images[0].id
    );
}

#[cfg(unix)]
#[test]
fn resized_event_decodes_protocol_replay_field() {
    let (client, _server) = UnixStream::pair().unwrap();
    let session = socket_test_session(client);
    let surface = Arc::new(RemoteSurface {
        id: 7,
        kind: SurfaceKind::Pty,
        term: Mutex::new(Terminal::new(12, 4, 100, Callbacks::default()).unwrap()),
        mouse_encoders: Mutex::new(MouseEncoders::new().unwrap()),
        cursor_provenance: Mutex::new(CursorStyleProvenance::default()),
        dirty: AtomicBool::new(false),
        geometry_lifecycle: Mutex::new(()),
        cell_pixels: Mutex::new((8, 16)),
        geometry_test_hook: Mutex::new(None),
        content_generation: AtomicU64::new(1),
        reported_size: Mutex::new(None),
        browser: Mutex::new(RemoteBrowserState::default()),
    });
    session.surfaces.lock().unwrap().insert(7, surface.clone());

    let mut authoritative = Terminal::new(12, 4, 100, Callbacks::default()).unwrap();
    for index in 0..8 {
        authoritative.vt_write(format!("authoritative-{index}\r\n").as_bytes());
    }
    authoritative.resize(8, 4, 8, 16).unwrap();
    let expected = authoritative.plain_text().unwrap();
    let replay = authoritative.vt_replay_bytes().unwrap();
    session.handle_line(json!({
        "event": "resized",
        "surface": 7,
        "cols": 8,
        "rows": 4,
        "replay": base64::engine::general_purpose::STANDARD.encode(replay),
    }));

    assert_eq!(surface.term.lock().unwrap().plain_text().unwrap(), expected);
}

#[cfg(unix)]
#[test]
fn real_server_attach_and_resize_preserve_kitty_number_aliases() {
    let mux = cmux_tui_core::Mux::new(
        format!("remote-kitty-aliases-{}", std::process::id()),
        cmux_tui_core::SurfaceOptions {
            command: Some(vec!["/bin/cat".to_string()]),
            ..Default::default()
        },
    );
    let authoritative = mux.new_workspace_as(&cmux_tui_core::Actor::local_user(), None, Some((20, 4))).unwrap();
    authoritative
        .try_with_terminal(|terminal| {
            terminal.vt_write(b"\x1b_Ga=t,t=d,f=24,I=77,s=1,v=1,q=2;/wAA\x1b\\");
        })
        .unwrap();
    let image_id = authoritative
        .try_with_terminal(|terminal| terminal.kitty_graphics_snapshot().unwrap().images[0].id)
        .unwrap();

    let socket = cmux_tui_core::server::serve(mux.clone(), None).unwrap();
    let remote = RemoteSession::connect(&socket).unwrap();
    let mirror = attached_surface(
        remote
            .try_ensure_surface_with_kind(authoritative.id, SurfaceKind::Pty, Some((20, 4)))
            .unwrap(),
    );

    let wait_for = |mut predicate: Box<dyn FnMut() -> bool>| {
        let deadline = Instant::now() + Duration::from_secs(5);
        while !predicate() {
            assert!(Instant::now() < deadline, "remote mirror did not converge");
            std::thread::sleep(Duration::from_millis(10));
        }
    };
    wait_for(Box::new({
        let mirror = mirror.clone();
        move || {
            mirror
                .term
                .lock()
                .unwrap()
                .kitty_graphics_snapshot()
                .unwrap()
                .image(image_id)
                .is_some_and(|image| image.number == 77)
        }
    }));

    mux.resize_surface(authoritative.id, 21, 4).unwrap();
    wait_for(Box::new({
        let mirror = mirror.clone();
        move || {
            let terminal = mirror.term.lock().unwrap();
            terminal.cols() == 21
                && terminal
                    .kitty_graphics_snapshot()
                    .unwrap()
                    .image(image_id)
                    .is_some_and(|image| image.number == 77)
        }
    }));

    authoritative.write_bytes(b"\x1b_Ga=p,I=77,p=12,c=1,r=1,q=2;\x1b\\\n").unwrap();
    wait_for(Box::new({
        move || {
            mirror
                .term
                .lock()
                .unwrap()
                .kitty_graphics_snapshot()
                .unwrap()
                .placements
                .iter()
                .any(|placement| placement.image_id == image_id && placement.placement_id == 12)
        }
    }));

    remote.begin_shutdown();
    let _ = mux.close_surface_as(&cmux_tui_core::Actor::local_user(), authoritative.id);
    cmux_tui_core::server::cleanup(&socket);
}

#[cfg(unix)]
#[test]
fn surface_resized_event_is_forwarded_without_changing_reported_size() {
    let (client, _server) = UnixStream::pair().unwrap();
    let session = socket_test_session(client);
    let events = session.subscribe();
    let surface = Arc::new(RemoteSurface {
        id: 7,
        kind: SurfaceKind::Browser,
        term: Mutex::new(Terminal::new(12, 4, 100, Callbacks::default()).unwrap()),
        mouse_encoders: Mutex::new(MouseEncoders::new().unwrap()),
        cursor_provenance: Mutex::new(CursorStyleProvenance::default()),
        dirty: AtomicBool::new(false),
        geometry_lifecycle: Mutex::new(()),
        cell_pixels: Mutex::new((8, 16)),
        geometry_test_hook: Mutex::new(None),
        content_generation: AtomicU64::new(1),
        reported_size: Mutex::new(Some((12, 4))),
        browser: Mutex::new(RemoteBrowserState::default()),
    });
    session.surfaces.lock().unwrap().insert(7, surface.clone());

    session.handle_line(json!({
        "event": "surface-resized",
        "surface": 7,
        "cols": 90,
        "rows": 31,
    }));

    assert_eq!(surface.reported_size(), Some((12, 4)));
    assert!(events.try_iter().any(|event| matches!(
        event,
        MuxEvent::SurfaceResized { surface: 7, cols: 90, rows: 31, .. }
    )));
}

#[cfg(unix)]
#[test]
fn surface_resize_failure_releases_remote_browser_report() {
    let (client, _server) = UnixStream::pair().unwrap();
    let session = socket_test_session(client);
    let events = session.subscribe();
    let surface = Arc::new(RemoteSurface {
        id: 7,
        kind: SurfaceKind::Browser,
        term: Mutex::new(Terminal::new(12, 4, 100, Callbacks::default()).unwrap()),
        mouse_encoders: Mutex::new(MouseEncoders::new().unwrap()),
        cursor_provenance: Mutex::new(CursorStyleProvenance::default()),
        dirty: AtomicBool::new(false),
        geometry_lifecycle: Mutex::new(()),
        cell_pixels: Mutex::new((8, 16)),
        geometry_test_hook: Mutex::new(None),
        content_generation: AtomicU64::new(1),
        reported_size: Mutex::new(Some((90, 31))),
        browser: Mutex::new(RemoteBrowserState::default()),
    });
    session.surfaces.lock().unwrap().insert(7, surface.clone());

    session.handle_line(json!({
        "event": "surface-resize-failed",
        "surface": 7,
        "cols": 90,
        "rows": 31,
        "error": "device metrics rejected",
        "retry_after_ms": 250,
    }));

    assert_eq!(surface.reported_size(), None);
    assert!(events.try_iter().any(|event| matches!(
        event,
        MuxEvent::SurfaceResizeFailed {
            surface: 7,
            cols: 90,
            rows: 31,
            retry_after_ms: Some(250),
            ..
        }
    )));
}
