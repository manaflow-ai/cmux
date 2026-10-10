//! Launch, snapshot/resize payload codecs and the clear-history ack; spawned PTY child guards.

use super::*;
use crate::lock_rank::RankedMutex;

#[test]
fn spawned_pty_child_disarm_prevents_late_kill() {
    let kills = Arc::new(AtomicUsize::new(0));
    let child = GuardTestChild { kills: Arc::clone(&kills) };
    let mut guard = SpawnedPtyChild::new(Box::new(child), Some(123));
    let _ = guard.wait_and_disarm();
    assert_eq!(guard.process_groups, [None, None]);
    drop(guard);
    assert_eq!(kills.load(Ordering::Relaxed), 0);
}

#[test]
fn startup_child_cleanup_excludes_host_process_group() {
    let host_group = unsafe { libc::getpgrp() };
    let mut signaled = Vec::new();
    signal_validated_process_groups(
        [Some(host_group), Some(host_group + 1), Some(0), Some(-1)],
        host_group,
        libc::SIGKILL,
        |group, signal| {
            signaled.push((group, signal));
            true
        },
    );
    assert_eq!(signaled, vec![(host_group + 1, libc::SIGKILL)]);
}

#[test]
fn startup_child_cleanup_reports_group_signal_failure() {
    let host_group = unsafe { libc::getpgrp() };
    let all_succeeded = signal_validated_process_groups(
        [Some(host_group + 1)],
        host_group,
        libc::SIGKILL,
        |_group, _signal| false,
    );
    assert!(!all_succeeded);
}

#[test]
fn default_host_cell_metrics_initialize_both_terminal_backends() {
    let size = pty_size(80, 24, DEFAULT_CELL_PIXELS).unwrap();
    assert_eq!((size.cols, size.rows, size.pixel_width, size.pixel_height), (80, 24, 640, 384));

    let mut terminal = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
    terminal
        .resize(80, 24, u32::from(DEFAULT_CELL_PIXELS.0), u32::from(DEFAULT_CELL_PIXELS.1))
        .unwrap();
    terminal.vt_write(b"\x1b_Ga=T,t=d,f=24,i=1,p=1,s=1,v=1,c=1,r=1,q=2;/wAA\x1b\\");
    let graphics = terminal.kitty_graphics_snapshot().unwrap();
    assert_eq!((graphics.placements[0].pixel_width, graphics.placements[0].pixel_height), (8, 16));
}

#[test]
fn pty_size_rejects_pixel_dimension_overflow() {
    let maximum_cols = u16::MAX / DEFAULT_CELL_PIXELS.0;
    let boundary = pty_size(maximum_cols, 24, DEFAULT_CELL_PIXELS).unwrap();
    assert_eq!(boundary.pixel_width, maximum_cols * DEFAULT_CELL_PIXELS.0);

    let width_error = pty_size(maximum_cols + 1, 24, DEFAULT_CELL_PIXELS).unwrap_err();
    assert!(width_error.to_string().contains("pixel width"));

    let maximum_rows = u16::MAX / DEFAULT_CELL_PIXELS.1;
    let height_error = pty_size(80, maximum_rows + 1, DEFAULT_CELL_PIXELS).unwrap_err();
    assert!(height_error.to_string().contains("pixel height"));
}

#[test]
fn launch_round_trip_preserves_ghostty_defaults() {
    let mut default_colors = DefaultColors {
        fg: Some(Rgb { r: 1, g: 2, b: 3 }),
        bg: Some(Rgb { r: 4, g: 5, b: 6 }),
        cursor: Some(Rgb { r: 7, g: 8, b: 9 }),
        selection_bg: Some(Rgb { r: 16, g: 17, b: 18 }),
        selection_fg: Some(Rgb { r: 19, g: 20, b: 21 }),
        cursor_style: Some(CursorShape::Bar),
        cursor_blink: Some(false),
        ..Default::default()
    };
    default_colors.palette[0] = Some(Rgb { r: 10, g: 11, b: 12 });
    default_colors.palette[255] = Some(Rgb { r: 13, g: 14, b: 15 });
    let launch = HostLaunch {
        endpoint: "/tmp/terminal.sock".into(),
        record_path: "/tmp/terminal.json".into(),
        term: "xterm-256color".into(),
        cols: 80,
        rows: 24,
        cell_pixels: (9, 18),
        scrollback: 10_000,
        cwd: Some("/tmp".into()),
        command: vec!["/bin/cat".into()],
        extra_env: vec![("KEY".into(), "value".into())],
        default_colors,
        kitty_graphics_limits: KittyGraphicsLimits {
            image_bytes: 1_000,
            inflight_bytes: 500,
            images: 10,
            placements: 20,
        },
        seed: b"seeded".to_vec(),
    };

    let decoded = HostLaunch::decode(&launch.encode().unwrap()).unwrap();
    assert_eq!(decoded.default_colors, default_colors);
    assert_eq!(decoded.cell_pixels, (9, 18));
    assert_eq!(decoded.kitty_graphics_limits, launch.kitty_graphics_limits);
    assert_eq!(decoded.command, launch.command);
    assert_eq!((decoded.extra_env, decoded.seed), (launch.extra_env, launch.seed));
    assert_eq!(
        decode_default_colors_payload(&encode_default_colors_payload(default_colors)).unwrap(),
        default_colors,
        "live SetDefaults must preserve the complete frontend defaults"
    );

    default_colors.cursor_blink = None;
    assert_eq!(
        decode_default_colors_payload(&encode_default_colors_payload(default_colors))
            .unwrap()
            .cursor_blink,
        None,
        "an absent Ghostty blink setting must survive the host boundary"
    );
}

#[test]
fn launch_failure_is_reported_before_bootstrap_pipe_closes() {
    let sequence = RECORD_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed);
    let terminal_id = TerminalId::random().unwrap();
    let bootstrap = HostBootstrap {
        min_version: PROTOCOL_VERSION,
        max_version: PROTOCOL_VERSION,
        terminal_id,
        owner_token: CapabilityToken::random().unwrap(),
    };
    let launch = HostLaunch {
        endpoint: format!("/tmp/cmux-host-launch-failure-{}-{sequence}.sock", std::process::id()),
        record_path: format!(
            "/tmp/cmux-host-launch-failure-{}-{sequence}.json",
            std::process::id()
        ),
        term: "xterm-256color".into(),
        cols: 80,
        rows: 24,
        cell_pixels: DEFAULT_CELL_PIXELS,
        scrollback: 1_000,
        cwd: Some("/tmp".into()),
        command: vec!["/definitely/missing/cmux-terminal-host-child".into()],
        extra_env: Vec::new(),
        default_colors: DefaultColors::default(),
        kitty_graphics_limits: KittyGraphicsLimits::default(),
        seed: Vec::new(),
    };
    let mut input = Vec::new();
    write_frame(&mut input, &bootstrap.into_frame(1)).unwrap();
    let mut launch_frame = Frame::new(MessageKind::Launch, launch.encode().unwrap());
    launch_frame.request_id = 2;
    write_frame(&mut input, &launch_frame).unwrap();

    let mut output = Vec::new();
    let result = serve_terminal_host_stdio(
        &["--bootstrap-stdio".to_string()],
        &mut std::io::Cursor::new(input),
        &mut output,
    );
    assert!(result.is_ok(), "host closed without reporting launch failure: {result:?}");

    let mut output = std::io::Cursor::new(output);
    let ready = read_frame(&mut output, MAX_FRAME_PAYLOAD).unwrap().unwrap();
    assert_eq!(ready.kind, MessageKind::Ready);
    let failure_frame = read_frame(&mut output, MAX_FRAME_PAYLOAD).unwrap().unwrap();
    assert_eq!(failure_frame.kind, MessageKind::LaunchFailed);
    assert_eq!(failure_frame.request_id, 2);
    let failure = decode_host_launch_failure(&failure_frame.payload).unwrap();
    assert!(
        failure
            .message
            .as_bytes()
            .windows("terminal launch failed".len())
            .any(|window| window == b"terminal launch failed"),
        "launch failure payload omitted the child error: {failure:?}",
    );
}

#[test]
fn pty_capacity_survives_context_as_a_typed_launch_failure() {
    let error =
        anyhow::Error::new(PtyOpenError::from_io(std_io::Error::from_raw_os_error(libc::ENXIO)))
            .context("allocate terminal host");
    let failure = host_launch_failure(&error);

    assert_eq!(failure.kind, HostLaunchFailureKind::PtyCapacityExhausted);
    assert!(failure.message.contains("terminal launch failed"));
    assert!(failure.message.contains("PTY capacity exhausted"));
}

#[test]
fn resized_payload_is_length_prefixed_for_cross_language_clients() {
    assert_eq!(
        encode_resize(0x0123, 0x0456, &[0xaa, 0xbb, 0xcc], &[], (9, 18), test_kitty_state(),)
            .unwrap(),
        vec![
            0x23, 0x01, 0x56, 0x04, 3, 0, 0, 0, 0xaa, 0xbb, 0xcc, 0, 0, 9, 0, 18, 0, 1, 0, 0, 0, 0,
            0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 5, 0, 0, 0, 6, 0, 0, 0, 7, 0, 0, 0, 8, 0, 0, 0,
        ]
    );
}

#[test]
fn snapshot_payload_round_trip_preserves_kitty_image_alias_section() {
    let snapshot = HostSnapshot {
        cols: 80,
        rows: 24,
        cell_pixels: (9, 18),
        replay: b"theme-portable replay".to_vec(),
        kitty_image_aliases: vec![
            KittyImageAlias { image_id: 41, image_number: 77 },
            KittyImageAlias { image_id: 42, image_number: 77 },
        ],
        kitty_state: test_kitty_state(),
        sequence_boundary: 0,
        colors: TerminalColorOverrides::default(),
        pid: Some(42),
        command: vec!["/bin/cat".into()],
        cwd: Some("/tmp".into()),
        osc_progress: String::new(),
    };
    let payload = encode_snapshot(&snapshot).unwrap();

    let decoded = decode_snapshot(&payload).expect("snapshot decoder must retain Kitty aliases");
    assert_eq!(decoded.kitty_image_aliases, snapshot.kitty_image_aliases);
    assert_eq!(decoded.kitty_state, snapshot.kitty_state);
    assert_eq!(decoded.cell_pixels, snapshot.cell_pixels);
    assert_eq!(
        encode_snapshot(&decoded).unwrap(),
        payload,
        "snapshot encode/decode dropped Kitty image-number aliases"
    );
}

#[test]
fn snapshot_payload_round_trip_preserves_negotiated_terminal_metadata() {
    let snapshot = HostSnapshot {
        cols: 80,
        rows: 24,
        cell_pixels: (9, 18),
        replay: b"replay".to_vec(),
        kitty_image_aliases: Vec::new(),
        kitty_state: KittyReplayState::disabled(),
        sequence_boundary: 0,
        colors: TerminalColorOverrides::default(),
        pid: None,
        command: Vec::new(),
        cwd: None,
        osc_progress: "4;1;50".into(),
    };
    let payload = encode_snapshot_for_version(&snapshot, PROTOCOL_VERSION, true).unwrap();
    let decoded = decode_snapshot_for_version(&payload, PROTOCOL_VERSION, true).unwrap();
    assert_eq!(decoded.osc_progress, snapshot.osc_progress);
    assert!(
        decode_snapshot(&payload).is_err(),
        "a metadata tail must not be accepted without negotiation"
    );
}

#[test]
fn host_snapshot_negotiates_terminal_metadata_at_the_stream_boundary() {
    let host = exited_host_fixture();
    assert!(host.terminal_metadata.lock().unwrap().set_osc_progress("4;1;50"));
    let (server_stream, mut client_stream) = UnixStream::pair().unwrap();
    client_stream.set_read_timeout(Some(Duration::from_secs(1))).unwrap();
    let server = thread::spawn({
        let host = host.clone();
        move || serve_client(host, server_stream)
    });

    let mut hello = snapshot_boundary_client_hello(&host, false).unwrap();
    hello.flags |= FLAG_TERMINAL_METADATA;
    write_frame(&mut client_stream, &hello).unwrap();
    let host_hello = read_required_frame(&mut client_stream, "host hello").unwrap();
    assert_eq!(host_hello.flags & FLAG_TERMINAL_METADATA, FLAG_TERMINAL_METADATA);
    let snapshot_frame = read_required_frame(&mut client_stream, "snapshot").unwrap();
    let snapshot =
        decode_snapshot_for_version(&snapshot_frame.payload, PROTOCOL_VERSION, true).unwrap();
    assert_eq!(snapshot.osc_progress, "4;1;50");
    assert_eq!(
        read_required_frame(&mut client_stream, "colors").unwrap().kind,
        MessageKind::Colors
    );
    drop(client_stream);
    assert!(server.join().unwrap().is_ok());
}

#[test]
fn snapshot_payload_matches_the_cross_language_current_golden_bytes() {
    let snapshot = HostSnapshot {
        cols: 1,
        rows: 2,
        cell_pixels: (9, 18),
        replay: Vec::new(),
        kitty_image_aliases: Vec::new(),
        kitty_state: test_kitty_state(),
        sequence_boundary: 0,
        colors: TerminalColorOverrides::default(),
        pid: None,
        command: Vec::new(),
        cwd: None,
        osc_progress: String::new(),
    };

    assert_eq!(
        encode_snapshot(&snapshot).unwrap(),
        vec![
            1, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 9, 0, 18, 0, 1, 0, 0, 0, 0, 0, 0, 0,
            2, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5,
            0, 0, 0, 6, 0, 0, 0, 7, 0, 0, 0, 8, 0, 0, 0,
        ]
    );
}

#[test]
fn legacy_snapshots_and_resizes_decode_without_newer_tails() {
    let snapshot = HostSnapshot {
        cols: 80,
        rows: 24,
        cell_pixels: (9, 18),
        replay: b"legacy replay".to_vec(),
        kitty_image_aliases: vec![KittyImageAlias { image_id: 41, image_number: 77 }],
        kitty_state: test_kitty_state(),
        sequence_boundary: 0,
        colors: TerminalColorOverrides::default(),
        pid: Some(42),
        command: vec!["/bin/cat".into()],
        cwd: Some("/tmp".into()),
        osc_progress: String::new(),
    };
    let snapshot_payload = encode_snapshot(&snapshot).unwrap();
    let v2_snapshot_len = snapshot_payload.len() - KITTY_REPLAY_STATE_ENCODED_LEN;
    let decoded = decode_snapshot_for_version(&snapshot_payload[..v2_snapshot_len], 2, false)
        .expect("protocol-v2 snapshots end after cell metrics");
    assert_eq!(decoded.replay, snapshot.replay);
    assert_eq!(decoded.kitty_image_aliases, snapshot.kitty_image_aliases);
    assert_eq!(decoded.cell_pixels, snapshot.cell_pixels);
    assert_eq!(decoded.kitty_state, KittyReplayState::disabled());

    let v1_snapshot_len = snapshot_payload.len()
        - KITTY_IMAGE_ALIAS_COUNT_LEN
        - snapshot.kitty_image_aliases.len() * KITTY_IMAGE_ALIAS_ENCODED_LEN
        - CELL_PIXEL_SIZE_ENCODED_LEN
        - KITTY_REPLAY_STATE_ENCODED_LEN;
    let decoded = decode_snapshot_for_version(
        &snapshot_payload[..v1_snapshot_len],
        LEGACY_PROTOCOL_VERSION,
        false,
    )
    .expect("protocol-v1 snapshots end before Kitty aliases");
    assert_eq!(decoded.replay, snapshot.replay);
    assert!(decoded.kitty_image_aliases.is_empty());
    assert_eq!(decoded.cell_pixels, DEFAULT_CELL_PIXELS);
    assert_eq!(decoded.kitty_state, KittyReplayState::disabled());

    let resize_payload = encode_resize(
        81,
        25,
        b"legacy resize",
        &snapshot.kitty_image_aliases,
        snapshot.cell_pixels,
        test_kitty_state(),
    )
    .unwrap();
    let v2_resize_len = resize_payload.len() - KITTY_REPLAY_STATE_ENCODED_LEN;
    assert_eq!(
        decode_host_resize_payload_for_version(&resize_payload[..v2_resize_len], 2).unwrap(),
        DecodedHostResize {
            cols: 81,
            rows: 25,
            cell_pixels: snapshot.cell_pixels,
            replay: b"legacy resize".to_vec(),
            kitty_image_aliases: snapshot.kitty_image_aliases.clone(),
            kitty_state: KittyReplayState::disabled(),
        }
    );

    let v1_resize_len = resize_payload.len()
        - KITTY_IMAGE_ALIAS_COUNT_LEN
        - snapshot.kitty_image_aliases.len() * KITTY_IMAGE_ALIAS_ENCODED_LEN
        - CELL_PIXEL_SIZE_ENCODED_LEN
        - KITTY_REPLAY_STATE_ENCODED_LEN;
    assert_eq!(
        decode_host_resize_payload_for_version(
            &resize_payload[..v1_resize_len],
            LEGACY_PROTOCOL_VERSION,
        )
        .unwrap(),
        DecodedHostResize {
            cols: 81,
            rows: 25,
            cell_pixels: DEFAULT_CELL_PIXELS,
            replay: b"legacy resize".to_vec(),
            kitty_image_aliases: Vec::new(),
            kitty_state: KittyReplayState::disabled(),
        }
    );
}

#[test]
fn resize_alias_section_preserves_number_history_and_rejects_malformed_data() {
    let alias = KittyImageAlias { image_id: 41, image_number: 77 };
    let valid = encode_resize(80, 24, b"replay", &[alias], (9, 18), test_kitty_state()).unwrap();
    assert_eq!(
        decode_host_resize_payload(&valid).unwrap(),
        DecodedHostResize {
            cols: 80,
            rows: 24,
            cell_pixels: (9, 18),
            replay: b"replay".to_vec(),
            kitty_image_aliases: vec![alias],
            kitty_state: test_kitty_state(),
        }
    );

    let alias_offset = 8 + b"replay".len();
    let mut zero_id = valid.clone();
    zero_id[alias_offset + 2..alias_offset + 6].fill(0);
    assert!(decode_host_resize_payload(&zero_id).is_err());

    let duplicate_aliases = [
        KittyImageAlias { image_id: 41, image_number: 77 },
        KittyImageAlias { image_id: 42, image_number: 77 },
    ];
    let duplicate_numbers =
        encode_resize(80, 24, b"replay", &duplicate_aliases, (9, 18), test_kitty_state()).unwrap();
    assert_eq!(
        decode_host_resize_payload(&duplicate_numbers).unwrap(),
        DecodedHostResize {
            cols: 80,
            rows: 24,
            cell_pixels: (9, 18),
            replay: b"replay".to_vec(),
            kitty_image_aliases: duplicate_aliases.to_vec(),
            kitty_state: test_kitty_state(),
        }
    );

    let mut truncated = valid.clone();
    truncated.pop();
    assert!(decode_host_resize_payload(&truncated).is_err());

    let mut invalid_offset = valid.clone();
    let state_offset = alias_offset
        + KITTY_IMAGE_ALIAS_COUNT_LEN
        + KITTY_IMAGE_ALIAS_ENCODED_LEN
        + CELL_PIXEL_SIZE_ENCODED_LEN;
    invalid_offset[state_offset + KITTY_GRAPHICS_LIMITS_ENCODED_LEN
        ..state_offset + KITTY_GRAPHICS_LIMITS_ENCODED_LEN + size_of::<u32>()]
        .copy_from_slice(&7u32.to_le_bytes());
    assert!(decode_host_resize_payload(&invalid_offset).is_err());

    let mut invalid_state = test_kitty_state();
    invalid_state.replay_cursor_offset = 7;
    assert!(encode_resize(80, 24, b"replay", &[alias], (9, 18), invalid_state).is_err());

    let mut trailing = valid;
    trailing.push(0);
    assert!(decode_host_resize_payload(&trailing).is_err());

    let mut excessive = vec![80, 0, 24, 0, 0, 0, 0, 0];
    excessive.extend_from_slice(&((MAX_KITTY_IMAGE_ALIASES + 1) as u16).to_le_bytes());
    assert!(decode_host_resize_payload(&excessive).is_err());
}

#[test]
fn clear_history_ack_preserves_known_not_delivered_failure() {
    let (record_path, record, lease) = record_fixture("clear-history-ack");
    let root = record_path.parent().unwrap().to_path_buf();
    let (client, mut host) = UnixStream::pair().unwrap();
    let control_responses = Arc::new(ControlResponses::new());
    let attachment = HostAttachment {
        record,
        record_path,
        snapshot: HostSnapshot {
            cols: 80,
            rows: 24,
            cell_pixels: DEFAULT_CELL_PIXELS,
            replay: Vec::new(),
            kitty_image_aliases: Vec::new(),
            kitty_state: test_kitty_state(),
            sequence_boundary: 0,
            colors: TerminalColorOverrides::default(),
            pid: None,
            command: Vec::new(),
            cwd: None,
            osc_progress: String::new(),
        },
        protocol_version: PROTOCOL_VERSION,
        smart_renderer: false,
        reader: None,
        writer: Arc::new(RankedMutex::new(client)),
        control_responses: control_responses.clone(),
        next_request: AtomicU64::new(2),
        viewer_size: RankedMutex::new(None),
        launch_process: None,
        launch_activation_pending: false,
        pty_custody: None,
    };
    let responder = thread::spawn(move || {
        let request = read_frame(&mut host, MAX_FRAME_PAYLOAD).unwrap().unwrap();
        assert_eq!(request.kind, MessageKind::ClearHistory);
        let mut response = Frame::new(
            MessageKind::ClearHistoryAck,
            vec![crate::terminal_host_protocol::CLEAR_HISTORY_ACK_FAILED],
        );
        response.request_id = request.request_id;
        assert!(control_responses.resolve(&response));
    });

    let failure = attachment.send_clear_history(None).unwrap_err();
    responder.join().unwrap();

    assert_eq!(failure.delivery(), ClearHistoryDelivery::KnownNotDelivered);
    assert_eq!(failure.into_error().to_string(), CLEAR_HISTORY_PRESERVATION_ERROR);
    drop(attachment);
    drop(lease);
    let _ = fs::remove_dir_all(root);
}
