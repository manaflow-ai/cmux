//! Render tap, render attachment, resize replay and PTY geometry tests.

use super::*;

#[test]
fn producer_without_render_taps_skips_frame_but_emits_output() {
    let mux = Mux::new_for_test("producer-skip", SurfaceOptions::default());
    let events = mux.subscribe();
    let surface =
        Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
    let pty = surface.as_pty().unwrap();

    let term = pty.term.lock().unwrap();
    assert!(!pty.build_producer_frame(term, 2).unwrap());

    let render = pty.render.lock().unwrap();
    assert_eq!(render.built_generation, 0);
    assert!(render.latest.is_none());
    drop(render);
    assert!(pty.dirty.load(Ordering::Acquire));
    assert!(matches!(events.try_recv(), Ok(MuxEvent::SurfaceOutput(1))));
}

#[test]
fn stalled_render_tap_retains_only_latest_frame_and_scroll_state_in_order() {
    let mux = Mux::new_for_test("render-tap-latest", SurfaceOptions::default());
    let surface =
        Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
    let pty = surface.as_pty().unwrap();
    let attach = surface.attach_render_stream().unwrap();
    let mut generation = pty.render.lock().unwrap().built_generation;

    let mut expected_dirty_rows = std::collections::BTreeSet::new();
    {
        let mut term = pty.term.lock().unwrap();
        term.vt_write(b"\x1b[1;1Ha");
        generation += 1;
        pty.build_frame_locked(&mut term, generation, false).unwrap();
        expected_dirty_rows.extend(
            pty.render.lock().unwrap().latest.as_ref().unwrap().frame.dirty_rows.iter().copied(),
        );
        broadcast_render_scroll_locked(pty, (4, false));
        term.vt_write(b"\x1b[2;1Hb");
        generation += 1;
        pty.build_frame_locked(&mut term, generation, false).unwrap();
        expected_dirty_rows.extend(
            pty.render.lock().unwrap().latest.as_ref().unwrap().frame.dirty_rows.iter().copied(),
        );
        broadcast_render_scroll_locked(pty, (9, true));
        term.vt_write(b"\x1b[3;1Hc");
        generation += 1;
        pty.build_frame_locked(&mut term, generation, false).unwrap();
        expected_dirty_rows.extend(
            pty.render.lock().unwrap().latest.as_ref().unwrap().frame.dirty_rows.iter().copied(),
        );
    }

    let mut pending = Vec::new();
    while let Ok(frame) = attach.stream.try_recv() {
        pending.push(frame);
    }
    assert_eq!(
        pending.len(),
        2,
        "a stalled render consumer retained more than one frame plus final scroll state"
    );
    assert!(matches!(pending[0], RenderAttachFrame::ScrollChanged { offset: 9, at_bottom: true }));
    let RenderAttachFrame::Frame(frame) = &pending[1] else {
        panic!("final render frame must follow the final preceding scroll state");
    };
    let latest = pty.render.lock().unwrap().latest.clone().unwrap();
    assert_eq!(frame.frame.seq, latest.frame.seq);
    assert_eq!(
        frame.frame.dirty_rows.iter().copied().collect::<std::collections::BTreeSet<_>>(),
        expected_dirty_rows,
        "coalescing the newest snapshot must preserve every undrained dirty row"
    );
    for row in &expected_dirty_rows {
        assert_eq!(frame.frame.styled_row(*row), latest.frame.styled_row(*row));
    }

    let latest_uncoalesced = {
        let mut term = pty.term.lock().unwrap();
        term.vt_write(b"d");
        generation += 1;
        pty.build_frame_locked(&mut term, generation, false).unwrap();
        let latest = pty.render.lock().unwrap().latest.clone().unwrap();
        broadcast_render_scroll_locked(pty, (11, false));
        latest
    };
    let first = attach.stream.try_recv().unwrap();
    let second = attach.stream.try_recv().unwrap();
    let RenderAttachFrame::Frame(frame) = first else {
        panic!("frame must precede the later scroll state");
    };
    assert!(
        Arc::ptr_eq(&frame, &latest_uncoalesced),
        "a tap that keeps up must reuse the shared immutable frame"
    );
    assert!(matches!(second, RenderAttachFrame::ScrollChanged { offset: 11, at_bottom: false }));
    assert!(matches!(attach.stream.try_recv(), Err(TryRecvError::Empty)));
}

#[test]
fn render_attachments_are_bounded_across_a_mux() {
    const EXPECTED_MAX_ATTACHMENTS: usize = 64;

    let mux = Mux::new_for_test("render-tap-cap", SurfaceOptions::default());
    let surface =
        Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
    let mut attachments = Vec::with_capacity(EXPECTED_MAX_ATTACHMENTS);
    for _ in 0..EXPECTED_MAX_ATTACHMENTS {
        attachments.push(surface.attach_render_stream().unwrap());
    }

    assert!(matches!(surface.attach_render_stream(), Err(ghostty_vt::Error::OutOfSpace)));
    attachments.pop();
    assert!(surface.attach_render_stream().is_ok());
}

#[test]
fn dropped_idle_render_attachments_remove_their_taps_immediately() {
    let mux = Mux::new_for_test("render-tap-drop", SurfaceOptions::default());
    let surface =
        Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
    let pty = surface.as_pty().unwrap();

    for _ in 0..128 {
        let attachment = surface.attach_render_stream().unwrap();
        assert_eq!(pty.render.lock().unwrap().taps.len(), 1);
        drop(attachment);
        assert!(
            pty.render.lock().unwrap().taps.is_empty(),
            "an idle closed attachment remained registered until later output"
        );
    }
}

#[test]
fn changed_kitty_limits_resynchronize_live_byte_attachments() {
    let mux = Mux::new_for_test("kitty-limit-resync", SurfaceOptions::default());
    let surface =
        Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
    let attach = surface.attach_stream().unwrap();
    surface
        .with_terminal(|terminal| {
            terminal.vt_write(b"\x1b_Ga=T,t=d,f=24,i=41,p=7,s=1,v=1,c=1,r=1,q=2;AAAA\x1b\\");
        })
        .unwrap();

    surface.set_kitty_graphics_limits(0, 0, 0, 0).unwrap();

    assert!(
        matches!(
            attach.stream.recv_timeout(Duration::from_secs(1)),
            Ok(AttachFrame::Resized { .. } | AttachFrame::ResizedWithColors { .. })
        ),
        "a byte-stream mirror was left on the pre-eviction Kitty scene"
    );
}

#[test]
fn geometry_updates_skip_vt_replay_without_byte_attach_subscribers() {
    let mux = Mux::new_for_test("resize-without-byte-attach", SurfaceOptions::default());
    let surface =
        Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
    let pty = surface.as_pty().unwrap();
    let render = surface.attach_render_stream().unwrap();

    surface.resize(100, 30).unwrap();
    surface.set_cell_pixel_size(9, 18).unwrap();

    assert_eq!(
        pty.vt_replay_builds.load(Ordering::Acquire),
        0,
        "render-only geometry updates must not construct byte-attach replay"
    );
    assert!(matches!(render.stream.try_recv(), Ok(RenderAttachFrame::Frame(_))));

    let byte_attach = surface.attach_stream().unwrap();
    pty.vt_replay_builds.store(0, Ordering::Release);
    surface.resize(101, 31).unwrap();
    assert_eq!(pty.vt_replay_builds.load(Ordering::Acquire), 1);

    drop(byte_attach);
    pty.vt_replay_builds.store(0, Ordering::Release);
    surface.resize(102, 31).unwrap();
    assert_eq!(
        pty.vt_replay_builds.load(Ordering::Acquire),
        0,
        "dropping the final byte attach must suppress the next resize replay"
    );
}

#[test]
fn resize_replay_preserves_a_valid_large_inflight_kitty_upload() {
    const OLD_VT_REPLAY_MAX_BYTES: usize = 8 * 1024 * 1024;
    const IMAGE_WIDTH: usize = 2_048;
    const IMAGE_HEIGHT: usize = 1_024;
    const IMAGE_ID: u32 = 196;

    let pixels = vec![0xff; IMAGE_WIDTH * IMAGE_HEIGHT * 3];
    let payload = base64::engine::general_purpose::STANDARD.encode(&pixels);
    let final_payload = payload.split_at(payload.len() - 4);
    let first_chunk = format!(
        "\x1b_Ga=t,t=d,f=24,i={IMAGE_ID},s={IMAGE_WIDTH},v={IMAGE_HEIGHT},m=1,q=2;{}\x1b\\",
        final_payload.0
    )
    .into_bytes();
    let final_chunk = format!("\x1b_Gm=0,q=2;{}\x1b\\", final_payload.1).into_bytes();
    assert!(
        first_chunk.len() > OLD_VT_REPLAY_MAX_BYTES,
        "fixture must exceed the old {OLD_VT_REPLAY_MAX_BYTES}-byte resize replay budget"
    );
    assert!(first_chunk.len() <= ghostty_vt::KITTY_INFLIGHT_REPLAY_MAX_BYTES);

    let mux = Mux::new_for_test("large-inflight-resize", SurfaceOptions::default());
    let surface =
        Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
    let attach = surface.attach_stream().unwrap();
    let pty = surface.as_pty().unwrap();
    {
        let mut terminal = pty.term.lock().unwrap();
        terminal.vt_write(&first_chunk);
        assert!(terminal.kitty_graphics_snapshot().unwrap().image(IMAGE_ID).is_none());
    }

    surface.resize(81, 24).unwrap();
    let (cols, rows, replay, kitty_image_aliases) =
        match attach.stream.recv_timeout(Duration::from_secs(2)).unwrap() {
            AttachFrame::Resized { cols, rows, replay, kitty_image_aliases, .. }
            | AttachFrame::ResizedWithColors { cols, rows, replay, kitty_image_aliases, .. } => {
                (cols, rows, replay, kitty_image_aliases)
            }
            _ => panic!("resize must publish replacement terminal state"),
        };
    assert!(
        replay.len() >= first_chunk.len(),
        "{}-byte resize replay omitted the {}-byte in-flight prefix",
        replay.len(),
        first_chunk.len()
    );

    let mut mirror = Terminal::new(cols, rows, 10_000, Callbacks::default()).unwrap();
    mirror.resize(cols, rows, 8, 16).unwrap();
    mirror.vt_write(&replay);
    mirror.restore_kitty_image_aliases(&kitty_image_aliases).unwrap();
    mirror.vt_write(&final_chunk);

    assert_eq!(
        mirror
            .kitty_graphics_snapshot()
            .unwrap()
            .image(IMAGE_ID)
            .expect("resize replay must let a fresh terminal accept the final upload chunk")
            .data
            .len(),
        pixels.len()
    );
}

#[test]
fn resize_replay_budget_covers_inflight_state_and_transport_limits() {
    assert_eq!(ghostty_vt::KITTY_INFLIGHT_REPLAY_MAX_BYTES, 13_595_480);
    assert_eq!(VT_REPLAY_TEXT_HEADROOM_BYTES, 2_097_152);
    assert_eq!(VT_REPLAY_MAX_BYTES, 15_692_632);
    assert_eq!(ATTACH_STREAM_MAX_BYTES - VT_REPLAY_MAX_BYTES, 1_084_584);
    assert_eq!(VT_REPLAY_MAX_BYTES.div_ceil(3) * 4, 20_923_512);
    const {
        assert!(
            VT_REPLAY_MAX_BYTES + VT_REPLAY_FRAME_METADATA_HEADROOM_BYTES
                <= ATTACH_STREAM_MAX_BYTES
        );
    }
    assert!(VT_REPLAY_MAX_BYTES.div_ceil(3) * 4 < VT_REPLAY_ENCODED_TRANSPORT_MAX_BYTES);
}

#[test]
fn resize_replay_failure_preflights_without_mutating_terminal_or_pty_geometry() {
    let mux = Mux::new_for_test("failed-resize-replay", SurfaceOptions::default());
    let surface =
        Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
    let attach = surface.attach_stream().unwrap();
    let pty = surface.as_pty().unwrap();
    let history = (0..40).map(|line| format!("history-{line:02}\r\n")).collect::<String>();
    let mut oversized = b"\x1b_Ga=t,t=d,f=24,i=197,s=1,v=1,m=1,q=2;".to_vec();
    oversized.resize(ghostty_vt::KITTY_INFLIGHT_REPLAY_MAX_BYTES + 1, b'A');
    oversized.extend_from_slice(b"\x1b\\");
    let (text_before, scrollbar_before) = {
        let mut terminal = pty.term.lock().unwrap();
        terminal.vt_write(history.as_bytes());
        terminal.vt_write(&oversized);
        assert_eq!(
            terminal.vt_replay_bounded(VT_REPLAY_MAX_BYTES),
            Err(ghostty_vt::Error::OutOfSpace)
        );
        (terminal.plain_text().unwrap(), terminal.scrollbar())
    };

    let error = surface.resize(100, 30).unwrap_err();

    assert!(error.to_string().contains("geometry unchanged"), "{error:#}");
    assert_eq!(surface.size(), (80, 24));
    {
        let mut terminal = pty.term.lock().unwrap();
        assert_eq!((terminal.cols(), terminal.rows()), (80, 24));
        assert_eq!(terminal.plain_text().unwrap(), text_before);
        assert_eq!(terminal.scrollbar(), scrollbar_before);
    }
    let master = surface.test_master_size();
    assert_eq!(
        (master.cols, master.rows, master.pixel_width, master.pixel_height),
        (80, 24, 640, 384)
    );
    assert!(matches!(attach.stream.try_recv(), Err(TryRecvError::Empty)));
}

#[test]
fn concurrent_pty_resize_and_cell_pixel_update_publish_one_geometry_transaction_at_a_time() {
    let mux = Mux::new_for_test("pty-geometry-transaction", SurfaceOptions::default());
    let surface =
        Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
    let pty = surface.as_pty().unwrap();
    let (resize_entered_tx, resize_entered_rx) = std::sync::mpsc::channel();
    let (release_resize_tx, release_resize_rx) = std::sync::mpsc::channel();
    let (cell_started_tx, cell_started_rx) = std::sync::mpsc::channel();
    let release_resize_rx = Arc::new(Mutex::new(release_resize_rx));
    *pty.geometry_test_hook.lock().unwrap() = Some(Arc::new({
        move |step| match step {
            PtyGeometryTestStep::ResizeCommitBoundary => {
                resize_entered_tx.send(()).unwrap();
                release_resize_rx.lock().unwrap().recv().unwrap();
            }
            PtyGeometryTestStep::CellPixelStarted => {
                cell_started_tx.send(()).unwrap();
            }
            _ => {}
        }
    }));

    let resizing_surface = surface.clone();
    let resizing = std::thread::spawn(move || resizing_surface.resize(100, 30));
    resize_entered_rx.recv().unwrap();

    let updating_surface = surface.clone();
    let (cell_done_tx, cell_done_rx) = std::sync::mpsc::channel();
    let updating = std::thread::spawn(move || {
        let result = updating_surface.set_cell_pixel_size(9, 18);
        cell_done_tx.send(result).unwrap();
    });
    cell_started_rx.recv().unwrap();
    let cell_completed_while_resize_was_uncommitted =
        cell_done_rx.recv_timeout(Duration::from_millis(100)).is_ok();

    release_resize_tx.send(()).unwrap();
    resizing.join().unwrap().unwrap();
    updating.join().unwrap();

    assert!(
        !cell_completed_while_resize_was_uncommitted,
        "cell pixels published while the resize transaction was paused before its backend commit"
    );
    assert_eq!(surface.size(), (100, 30));
    let master = surface.test_master_size();
    assert_eq!(
        (master.cols, master.rows, master.pixel_width, master.pixel_height),
        (100, 30, 900, 540)
    );
}

#[test]
fn failed_pty_master_resize_commits_nothing_and_the_same_request_retries() {
    let mux = Mux::new_for_test("pty-resize-failure", SurfaceOptions::default());
    let surface =
        Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
    surface.fail_next_test_master_resize();

    let failed = surface.resize(100, 30);

    assert!(failed.is_err(), "PTY master resize failure must reach the caller");
    assert_eq!(surface.size(), (80, 24));
    {
        let term = surface.as_pty().unwrap().term.lock().unwrap();
        assert_eq!((term.cols(), term.rows()), (80, 24));
    }
    let master = surface.test_master_size();
    assert_eq!(
        (master.cols, master.rows, master.pixel_width, master.pixel_height),
        (80, 24, 640, 384)
    );

    assert!(surface.resize(100, 30).unwrap());
    assert_eq!(surface.size(), (100, 30));
    let master = surface.test_master_size();
    assert_eq!(
        (master.cols, master.rows, master.pixel_width, master.pixel_height),
        (100, 30, 800, 480)
    );
}

#[test]
fn pty_eof_publishes_final_render_frame_before_surface_removal() {
    const FINAL_MARKER: &str = "CMUX_FINAL_RENDER_MARKER";

    let mux = Mux::new("pty-final-render", SurfaceOptions::default());
    let placement = mux
        .run_command_surface(
            vec!["/bin/sh".into(), "-c".into(), format!("IFS= read -r _; printf '{FINAL_MARKER}'")],
            None,
            true,
            None,
            None,
            Some((80, 24)),
        )
        .unwrap();
    let surface = mux.surface(placement.surface).unwrap();
    let attach = surface.attach_render_stream().unwrap();
    let events = mux.subscribe();

    let (entered_tx, entered_rx) = sync_channel(1);
    let (release_tx, release_rx) = sync_channel(1);
    let release_rx = Mutex::new(release_rx);
    {
        let pty = surface.as_pty().unwrap();
        *pty.frame_producer_before_upgrade.lock().unwrap() = Some(Arc::new(move || {
            let _ = entered_tx.try_send(());
            let _ = release_rx.lock().unwrap().recv_timeout(Duration::from_secs(5));
        }));
    }

    surface.write_bytes(b"go\n").unwrap();
    drop(surface);
    entered_rx
        .recv_timeout(Duration::from_secs(2))
        .expect("frame producer did not receive the final output request");

    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        match events.recv_timeout(remaining) {
            Ok(MuxEvent::SurfaceExited(id)) if id == placement.surface => break,
            Ok(_) => {}
            Err(error) => panic!("surface did not exit before frame worker release: {error}"),
        }
    }
    release_tx.send(()).unwrap();

    let frame = attach
        .stream
        .recv_timeout(Duration::from_secs(2))
        .expect("final render frame was dropped with the surface");
    let RenderAttachFrame::Frame(frame) = frame else {
        panic!("expected final render frame");
    };
    let rendered = frame
        .frame
        .styled_rows()
        .iter()
        .flat_map(|row| row.iter())
        .map(|cell| cell.text.as_str())
        .collect::<String>();
    assert!(
        rendered.contains(FINAL_MARKER),
        "final render frame did not contain producer receipt: {rendered:?}"
    );
    mux.shutdown();
}

#[test]
fn pty_pixel_overflow_rejects_creation_and_geometry_updates_without_mutation() {
    let mux = Mux::new_for_test("pty-pixel-overflow", SurfaceOptions::default());
    let oversized = SurfaceOptions { cols: 10_000, ..SurfaceOptions::default() };
    let creation_error = Surface::spawn_for_test(1, oversized, Arc::downgrade(&mux)).unwrap_err();
    assert!(creation_error.to_string().contains("PTY pixel width exceeds 65535"));

    let surface =
        Surface::spawn_for_test(2, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
    let resize_error = surface.resize(10_000, 24).unwrap_err();
    assert!(resize_error.to_string().contains("PTY pixel width exceeds 65535"));
    let cell_error = surface.set_cell_pixel_size(1_000, 16).unwrap_err();
    assert!(cell_error.to_string().contains("PTY pixel width exceeds 65535"));

    assert_eq!(surface.size(), (80, 24));
    assert_eq!(surface.test_cell_pixel_size(), (8, 16));
    {
        let terminal = surface.as_pty().unwrap().term.lock().unwrap();
        assert_eq!((terminal.cols(), terminal.rows()), (80, 24));
    }
    let master = surface.test_master_size();
    assert_eq!(
        (master.cols, master.rows, master.pixel_width, master.pixel_height),
        (80, 24, 640, 384)
    );
}
