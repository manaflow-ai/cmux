//! Hosted terminal tests: receipted input pipelining, the hosted frame stager,
//! exited-host placeholders and final replays, and reconnect backoff.

use super::*;

fn append_disabled_kitty_replay_state(payload: &mut Vec<u8>) {
    for _ in 0..4 {
        payload.extend_from_slice(&0u64.to_le_bytes());
    }
    payload.extend_from_slice(&0u32.to_le_bytes());
    for _ in 0..4 {
        payload.extend_from_slice(
            &ghostty_vt::KittyImageIdCursors::DEFAULT_NEXT_IMAGE_ID.to_le_bytes(),
        );
    }
}

#[cfg(unix)]
#[test]
fn hosted_receipted_input_requests_pipeline_through_surface_reader() {
    let mux = Mux::new_for_test("hosted-input-ack-pipeline", SurfaceOptions::default());
    let workspace = mux.create_empty_workspace(None, None, None).unwrap();
    let (mut attachment, mut host) = crate::terminal_host_runtime::input_ack_surface_fixture();
    let terminal_id = attachment.record.terminal_id.clone();
    attachment.record.workspace_key = workspace.key.clone();
    mux.seed_launching_terminal_for_test(&terminal_id, &workspace.key).unwrap();

    let surface = Surface::spawn_hosted(
        1,
        SurfaceOptions::default(),
        Arc::downgrade(&mux),
        HostedSurfaceLaunch {
            attachment,
            kitty_reservation: None,
            terminate_on_error: false,
            defer_launch_activation: false,
            lifetime: PtyLifetime::SessionOwned,
            terminal_public_id: None,
            resource_identity: None,
        },
    )
    .unwrap();

    host.set_read_timeout(Some(Duration::from_secs(1))).unwrap();
    host.set_write_timeout(Some(Duration::from_secs(1))).unwrap();
    let read_input = |host: &mut std::os::unix::net::UnixStream| {
        let frame = crate::terminal_host_protocol::read_frame(
            host,
            crate::terminal_host_protocol::MAX_FRAME_PAYLOAD,
        )
        .expect("observe submitted input while the earlier ACK is withheld")
        .expect("hosted connection remains open while awaiting input ACKs");
        assert_eq!(frame.kind, MessageKind::Input);
        frame
    };

    std::thread::scope(|scope| {
        let first = scope.spawn(|| surface.write_bytes_confirmed(b"pipeline-a"));
        let first_request = read_input(&mut host);
        assert_eq!(first_request.payload, b"pipeline-a");
        assert_ne!(first_request.request_id, 0);

        let second = scope.spawn(|| surface.write_bytes_confirmed(b"pipeline-b"));
        let second_request = read_input(&mut host);
        assert_eq!(second_request.payload, b"pipeline-b");
        assert_ne!(second_request.request_id, 0);
        assert_ne!(first_request.request_id, second_request.request_id);

        let interactive = scope.spawn(|| surface.write_bytes(b"pipeline-interactive"));
        let interactive_request = read_input(&mut host);
        assert_eq!(interactive_request.payload, b"pipeline-interactive");
        assert_eq!(interactive_request.request_id, 0);
        interactive.join().unwrap().unwrap();
        assert!(!first.is_finished());
        assert!(!second.is_finished());

        let mut second_ack = Frame::new(MessageKind::InputAck, Vec::new());
        second_ack.request_id = second_request.request_id;
        crate::terminal_host_protocol::write_frame(&mut host, &second_ack).unwrap();
        second.join().unwrap().unwrap();
        assert!(!first.is_finished(), "B's ACK must leave A pending");

        let mut first_ack = Frame::new(MessageKind::InputAck, Vec::new());
        first_ack.request_id = first_request.request_id;
        crate::terminal_host_protocol::write_frame(&mut host, &first_ack).unwrap();
        first.join().unwrap().unwrap();
    });
}

#[cfg(unix)]
#[test]
fn hosted_stager_exposes_coupled_state_only_after_colors() {
    let mut stager = HostedFrameStager::new(40, false);
    let mut resize = Frame::new(MessageKind::Resized, {
        let mut payload = Vec::from([101, 0, 37, 0]);
        payload.extend_from_slice(&(b"authoritative replay".len() as u32).to_le_bytes());
        payload.extend_from_slice(b"authoritative replay");
        payload.extend_from_slice(&0u16.to_le_bytes());
        payload.extend_from_slice(&9u16.to_le_bytes());
        payload.extend_from_slice(&18u16.to_le_bytes());
        append_disabled_kitty_replay_state(&mut payload);
        payload
    });
    resize.flags = FLAG_COLORS_FOLLOW;
    resize.sequence = 41;

    // A delayed Colors frame cannot expose a resize attach callback or a
    // renderable transition with the old theme.
    assert!(stager.push(resize).unwrap().is_none());

    let colors = TerminalColorOverrides {
        foreground: Some(Rgb { r: 1, g: 2, b: 3 }),
        cursor_visual: Some((CursorShape::Bar, true)),
        ..Default::default()
    };
    let mut colors_frame = Frame::new(
        MessageKind::Colors,
        crate::terminal_host_runtime::encode_terminal_color_overrides(&colors),
    );
    colors_frame.sequence = 42;
    match stager.push(colors_frame).unwrap().unwrap() {
        HostedTransition::ResizedWithColors {
            cols,
            rows,
            cell_pixels,
            replay,
            kitty_image_aliases,
            colors: received,
            ..
        } => {
            assert_eq!((cols, rows), (101, 37));
            assert_eq!(cell_pixels, (9, 18));
            assert_eq!(replay, b"authoritative replay");
            assert!(kitty_image_aliases.is_empty());
            assert_eq!(received, colors);
        }
        other => panic!("unexpected staged transition: {other:?}"),
    }

    let mut output = Frame::new(MessageKind::Output, b"\x1b]10;red\x1b\\".to_vec());
    output.flags = FLAG_COLORS_FOLLOW;
    output.sequence = 43;
    assert!(stager.push(output).unwrap().is_none());
    let mut colors_frame = Frame::new(
        MessageKind::Colors,
        crate::terminal_host_runtime::encode_terminal_color_overrides(&colors),
    );
    colors_frame.sequence = 44;
    assert!(matches!(
        stager.push(colors_frame).unwrap(),
        Some(HostedTransition::OutputWithColors { .. })
    ));
}

#[cfg(unix)]
#[test]
fn hosted_stager_excludes_resize_framing_and_aliases_from_vt_replay() {
    let replay = b"\x1b[2Jhost replay";
    let mut payload = Vec::from([101, 0, 37, 0]);
    payload.extend_from_slice(&(replay.len() as u32).to_le_bytes());
    payload.extend_from_slice(replay);
    payload.extend_from_slice(&1u16.to_le_bytes());
    payload.extend_from_slice(&41u32.to_le_bytes());
    payload.extend_from_slice(&77u32.to_le_bytes());
    payload.extend_from_slice(&9u16.to_le_bytes());
    payload.extend_from_slice(&18u16.to_le_bytes());
    append_disabled_kitty_replay_state(&mut payload);

    let mut stager = HostedFrameStager::new(8, false);
    let mut resize = Frame::new(MessageKind::Resized, payload);
    resize.flags = FLAG_COLORS_FOLLOW;
    resize.sequence = 9;
    assert!(stager.push(resize).unwrap().is_none());

    let colors = TerminalColorOverrides {
        cursor_visual: Some((CursorShape::Block, true)),
        ..Default::default()
    };
    let mut colors = Frame::new(
        MessageKind::Colors,
        crate::terminal_host_runtime::encode_terminal_color_overrides(&colors),
    );
    colors.sequence = 10;
    match stager.push(colors).unwrap().unwrap() {
        HostedTransition::ResizedWithColors { replay: received, kitty_image_aliases, .. } => {
            assert_eq!(
                received, replay,
                "resize length and alias metadata leaked into VT replay bytes"
            );
            assert_eq!(
                kitty_image_aliases,
                vec![ghostty_vt::KittyImageAlias { image_id: 41, image_number: 77 }]
            );
        }
        other => panic!("unexpected staged transition: {other:?}"),
    }
}

#[cfg(unix)]
#[test]
fn hosted_stager_accepts_protocol_one_resize_without_alias_metadata() {
    let replay = b"legacy host replay";
    let mut payload = Vec::from([81, 0, 25, 0]);
    payload.extend_from_slice(&(replay.len() as u32).to_le_bytes());
    payload.extend_from_slice(replay);

    let mut stager = HostedFrameStager::new_for_version(0, 1, false);
    let mut resize = Frame::new(MessageKind::Resized, payload);
    resize.version = 1;
    resize.flags = FLAG_COLORS_FOLLOW;
    resize.sequence = 1;
    assert!(stager.push(resize).unwrap().is_none());

    let colors = TerminalColorOverrides {
        cursor_visual: Some((CursorShape::Block, true)),
        ..Default::default()
    };
    let mut colors = Frame::new(
        MessageKind::Colors,
        crate::terminal_host_runtime::encode_terminal_color_overrides(&colors),
    );
    colors.version = 1;
    colors.sequence = 2;
    match stager.push(colors).unwrap().unwrap() {
        HostedTransition::ResizedWithColors {
            cols,
            rows,
            replay: received,
            kitty_image_aliases,
            ..
        } => {
            assert_eq!((cols, rows), (81, 25));
            assert_eq!(received, replay);
            assert!(kitty_image_aliases.is_empty());
        }
        other => panic!("unexpected staged transition: {other:?}"),
    }
}

#[cfg(unix)]
#[test]
fn smart_hosted_stager_orders_raw_output_and_incremental_resize() {
    let mut stager = HostedFrameStager::new(7, true);
    let mut prefix = Frame::new(MessageKind::Output, vec![0xce]);
    prefix.sequence = 8;
    assert!(matches!(
        stager.push(prefix).unwrap(),
        Some(HostedTransition::Output(bytes)) if bytes == vec![0xce]
    ));

    let mut resized = Frame::new(MessageKind::Resized, vec![100, 0, 30, 0]);
    resized.sequence = 9;
    assert!(matches!(
        stager.push(resized).unwrap(),
        Some(HostedTransition::Resized { cols: 100, rows: 30, cell_pixels: None })
    ));

    let mut metrics = Frame::new(MessageKind::Resized, vec![100, 0, 30, 0, 9, 0, 18, 0]);
    metrics.sequence = 10;
    assert!(matches!(
        stager.push(metrics).unwrap(),
        Some(HostedTransition::Resized { cols: 100, rows: 30, cell_pixels: Some((9, 18)) })
    ));

    let mut suffix = Frame::new(MessageKind::Output, vec![0xbb]);
    suffix.sequence = 11;
    assert!(matches!(
        stager.push(suffix).unwrap(),
        Some(HostedTransition::Output(bytes)) if bytes == vec![0xbb]
    ));
}

#[cfg(unix)]
#[test]
fn hosted_stager_decodes_authoritative_exit_payload() {
    let exit = TerminalExit {
        outcome: crate::terminal_host_protocol::TerminalExitOutcome::Exit { code: 17 },
        exited_at_ms: 1_234_567,
    };
    let mut frame =
        Frame::new(MessageKind::Exit, crate::terminal_host_protocol::encode_terminal_exit(&exit));
    frame.sequence = 1;
    let mut stager = HostedFrameStager::new(0, false);
    match stager.push(frame).unwrap() {
        Some(HostedTransition::Exit(observed)) => assert_eq!(observed, exit),
        other => panic!("unexpected staged transition: {other:?}"),
    }

    let mut malformed = Frame::new(MessageKind::Exit, vec![1, 0, 2]);
    malformed.sequence = 1;
    assert!(HostedFrameStager::new(0, false).push(malformed).is_err());
}

#[cfg(unix)]
#[test]
fn hosted_stager_fails_closed_on_invalid_flags_and_pairing() {
    let mut stager = HostedFrameStager::new(0, false);
    let mut resized = Frame::new(MessageKind::Resized, vec![80, 0, 24, 0]);
    resized.sequence = 1;
    assert!(stager.push(resized).is_err(), "Resized must declare Colors follow");

    let mut stager = HostedFrameStager::new(0, false);
    let mut output = Frame::new(MessageKind::Output, vec![]);
    output.flags = FLAG_COLORS_FOLLOW | (1 << 7);
    output.sequence = 1;
    assert!(stager.push(output).is_err(), "unknown flags must fail closed");

    let mut stager = HostedFrameStager::new(0, false);
    let mut output = Frame::new(MessageKind::Output, vec![]);
    output.flags = FLAG_COLORS_FOLLOW;
    output.sequence = 1;
    assert!(stager.push(output).unwrap().is_none());
    let mut exit = Frame::new(MessageKind::Exit, vec![]);
    exit.sequence = 2;
    assert!(stager.push(exit).is_err(), "a coupled frame requires Colors exactly next");

    let mut stager = HostedFrameStager::new(0, false);
    let mut malformed = Frame::new(MessageKind::Resized, {
        let mut payload = vec![80, 0, 24, 0, 0, 0, 0, 0];
        payload.extend_from_slice(&1u16.to_le_bytes());
        payload.extend_from_slice(&41u32.to_le_bytes());
        payload
    });
    malformed.flags = FLAG_COLORS_FOLLOW;
    malformed.sequence = 1;
    assert!(stager.push(malformed).is_err(), "truncated aliases must fail closed");
}

#[cfg(unix)]
#[test]
fn exited_host_placeholder_preserves_identity_and_swallows_input() {
    let mux = Mux::new_for_test("exited-host-placeholder", SurfaceOptions::default());
    let identity = crate::terminal_host_runtime::TerminalHostIdentity {
        terminal_id: crate::terminal_host::TerminalId::random().unwrap().to_hex(),
        incarnation: crate::terminal_host::HostIncarnation::random().unwrap().to_hex(),
    };
    let surface = Surface::exited_terminal_placeholder(
        91,
        SurfaceOptions::default(),
        Arc::downgrade(&mux),
        identity.clone(),
    )
    .unwrap();

    assert_eq!(surface.terminal_host_identity(), Some(identity));
    assert_eq!(surface.terminal_host_connection_state(), Some(TerminalHostConnectionState::Exited));
    assert!(surface.is_dead());
    // Keep-on-exit terminals stay interactive surfaces after their child
    // dies, so input to the dead PTY is a harmless no-op, not an error.
    surface.write_bytes(b"must not reach a dead host").unwrap();
    surface.write_paste(b"must not reach a dead host").unwrap();
}

#[cfg(unix)]
fn exited_host_surface(name: &str, id: SurfaceId, mux: &Arc<Mux>) -> Arc<Surface> {
    let identity = crate::terminal_host_runtime::TerminalHostIdentity {
        terminal_id: crate::terminal_host::TerminalId::random().unwrap().to_hex(),
        incarnation: crate::terminal_host::HostIncarnation::random().unwrap().to_hex(),
    };
    Surface::exited_terminal_placeholder(
        id,
        SurfaceOptions { command: Some(vec![name.into()]), ..SurfaceOptions::default() },
        Arc::downgrade(mux),
        identity,
    )
    .unwrap()
}

#[cfg(unix)]
#[test]
fn exited_terminal_final_replay_serves_byte_attach() {
    const MARKER: &str = "exited-byte-final-replay";
    let mux = Mux::new_for_test("exited-host-byte-attach", SurfaceOptions::default());
    let surface = exited_host_surface("byte-attach", 92, &mux);
    surface.with_terminal(|term| term.vt_write(MARKER.as_bytes()));

    let attach = surface.attach_stream().expect("exited terminal must serve byte replay");
    let mut mirror = Terminal::new(attach.cols, attach.rows, 10_000, Callbacks::default()).unwrap();
    mirror.vt_write(&attach.replay);

    assert!(mirror.plain_text().unwrap().contains(MARKER));
    assert!(matches!(attach.stream.try_recv(), Err(TryRecvError::Disconnected)));
    assert!(surface.as_pty().unwrap().taps.lock().unwrap().is_empty());
}

#[cfg(unix)]
#[test]
fn exited_terminal_final_replay_serves_render_attach() {
    const MARKER: &str = "exited-render-final-frame";
    let mux = Mux::new_for_test("exited-host-render-attach", SurfaceOptions::default());
    let surface = exited_host_surface("render-attach", 93, &mux);
    surface.with_terminal(|term| term.vt_write(MARKER.as_bytes()));

    let first =
        surface.attach_render_stream().expect("exited terminal must serve final render frame");
    let rendered = first
        .initial
        .frame
        .styled_rows()
        .iter()
        .flat_map(|row| row.iter())
        .map(|cell| cell.text.as_str())
        .collect::<String>();

    assert!(rendered.contains(MARKER), "final render frame omitted {MARKER}: {rendered:?}");
    assert!(matches!(first.stream.try_recv(), Err(TryRecvError::Disconnected)));

    // Final snapshots are inert and must not consume the live attachment
    // budget even when their callers retain them.
    let mut attachments = vec![first];
    for _ in 1..crate::mux::RENDER_ATTACHMENT_LIMIT * 2 {
        let attach = surface
            .attach_render_stream()
            .expect("exited terminal final replay must not exhaust live render permits");
        assert!(matches!(attach.stream.try_recv(), Err(TryRecvError::Disconnected)));
        assert!(
            Arc::ptr_eq(&attachments[0].initial, &attach.initial),
            "exited render attaches must share one cached final snapshot"
        );
        attachments.push(attach);
    }
    assert!(surface.as_pty().unwrap().render.lock().unwrap().taps.is_empty());
}

#[cfg(unix)]
#[test]
fn exited_terminal_final_replay_does_not_reclassify_prior_host_loss() {
    let mux = Mux::new_for_test("already-dead-host-attach", SurfaceOptions::default());
    let surface =
        Surface::spawn_for_test(94, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
    let pty = surface.as_pty().unwrap();

    // A prior host-loss path may latch `dead` before hosted exit
    // finalization owns the terminal. It must not expose a replay that
    // was never finalized or close streams owned by that loss path.
    pty.dead.store(true, Ordering::Release);
    pty.host_connection_state.store(TerminalHostConnectionState::Failed as u8, Ordering::Release);
    assert_eq!(
        TerminalHostConnectionState::from_u8(pty.host_connection_state.load(Ordering::Acquire)),
        TerminalHostConnectionState::Failed
    );

    pty.finish_hosted_exit();

    assert_eq!(
        TerminalHostConnectionState::from_u8(pty.host_connection_state.load(Ordering::Acquire)),
        TerminalHostConnectionState::Failed
    );
    assert!(matches!(surface.attach_stream(), Err(ghostty_vt::Error::NoValue)));
    assert!(matches!(surface.attach_render_stream(), Err(ghostty_vt::Error::NoValue)));
}

#[cfg(unix)]
#[test]
fn exited_terminal_final_replay_closes_the_exit_attach_race() {
    for iteration in 0..64 {
        let mux = Mux::new_for_test(
            format!("hosted-exit-attach-race-{iteration}"),
            SurfaceOptions::default(),
        );
        let surface = Surface::spawn_for_test(
            iteration + 100,
            SurfaceOptions::default(),
            Arc::downgrade(&mux),
        )
        .unwrap();
        let start = Arc::new(std::sync::Barrier::new(2));

        std::thread::scope(|scope| {
            let exit_surface = surface.clone();
            let exit_start = start.clone();
            let exit = scope.spawn(move || {
                exit_start.wait();
                exit_surface.as_pty().unwrap().finish_hosted_exit();
            });

            start.wait();
            let during_exit = surface.attach_stream();
            exit.join().unwrap();

            during_exit.expect("attach racing hosted exit must serve live or final replay");
            surface.attach_stream().expect("attach after hosted exit must serve final replay");
        });
    }
}

#[test]
fn exited_terminal_final_replay_releases_rejected_render_permit() {
    let mux = Mux::new_for_test("dead-render-attach-permit", SurfaceOptions::default());
    let dead =
        Surface::spawn_for_test(200, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
    dead.as_pty().unwrap().dead.store(true, Ordering::Release);

    for _ in 0..crate::mux::RENDER_ATTACHMENT_LIMIT * 2 {
        assert!(matches!(dead.attach_render_stream(), Err(ghostty_vt::Error::NoValue)));
    }

    let live =
        Surface::spawn_for_test(201, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
    let mut attachments = Vec::new();
    for _ in 0..crate::mux::RENDER_ATTACHMENT_LIMIT {
        attachments.push(live.attach_render_stream().expect("rejected attach leaked a permit"));
    }
    assert!(matches!(live.attach_render_stream(), Err(ghostty_vt::Error::OutOfSpace)));
}

#[test]
fn terminal_reconnect_failure_state_never_decodes_as_connected() {
    assert_ne!(TerminalHostConnectionState::from_u8(3), TerminalHostConnectionState::Connected);
}

#[cfg(unix)]
#[test]
fn terminal_reconnect_backoff_advances_and_reaches_a_terminal_bound() {
    let mut backoff = TerminalHostReconnectBackoff::default();
    let delays = (0..TERMINAL_HOST_RECONNECT_MAX_FAILURES)
        .map(|_| backoff.next_delay().expect("retry within failure bound"))
        .collect::<Vec<_>>();

    assert_eq!(
        &delays[..7],
        &[
            Duration::from_millis(25),
            Duration::from_millis(50),
            Duration::from_millis(100),
            Duration::from_millis(200),
            Duration::from_millis(400),
            Duration::from_millis(800),
            Duration::from_secs(1),
        ]
    );
    assert!(delays[7..].iter().all(|delay| *delay == Duration::from_secs(1)));
    assert_eq!(backoff.next_delay(), None);
}

#[cfg(unix)]
#[test]
fn hosted_reconnect_backoff_releases_geometry_before_waiting() {
    let mux = Mux::new_for_test("reconnect-geometry-release", SurfaceOptions::default());
    let surface =
        Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
    let pty = surface.as_pty().unwrap();
    let (backoff_started_tx, backoff_started_rx) = std::sync::mpsc::channel();
    let (release_backoff_tx, release_backoff_rx) = std::sync::mpsc::channel();
    let release_backoff_rx = Arc::new(Mutex::new(release_backoff_rx));
    *pty.geometry_test_hook.lock().unwrap() = Some(Arc::new({
        move |step| {
            if step == PtyGeometryTestStep::ReconnectBackoffStarted {
                backoff_started_tx.send(()).unwrap();
                release_backoff_rx.lock().unwrap().recv().unwrap();
            }
        }
    }));

    let reconnect_surface = surface.clone();
    let reconnect = std::thread::spawn(move || {
        let pty = reconnect_surface.as_pty().unwrap();
        let geometry = pty.geometry.lock().unwrap();
        let mut retry = TerminalHostReconnectBackoff::default();
        wait_for_reconnect_after_geometry_failure(&mut retry, pty, geometry)
    });
    backoff_started_rx.recv().unwrap();

    let probing_surface = surface.clone();
    let (geometry_acquired_tx, geometry_acquired_rx) = std::sync::mpsc::channel();
    let geometry_probe = std::thread::spawn(move || {
        let size = probing_surface.test_cell_pixel_size();
        geometry_acquired_tx.send(size).unwrap();
    });
    let geometry_released_before_backoff =
        geometry_acquired_rx.recv_timeout(Duration::from_millis(100)).is_ok();

    release_backoff_tx.send(()).unwrap();
    assert!(reconnect.join().unwrap());
    geometry_probe.join().unwrap();
    assert!(
        geometry_released_before_backoff,
        "host reconnect backoff held the geometry transaction lock"
    );
}
