//! Adoption, control acks, detach fences, metric commits, protocol fallback, snapshot boundaries and resize resyncs.

use super::*;
use crate::lock_rank::RankedMutex;

#[test]
fn termination_adoption_does_not_probe_legacy_protocols_for_receipt_hosts() {
    let (record_path, record, lease) = record_fixture("terminate-current-protocol");
    assert!(record.supports_terminate_ack);
    let endpoint = PathBuf::from(&record.endpoint);
    prepare_private_dir(endpoint.parent().unwrap()).unwrap();
    let _ = fs::remove_file(&endpoint);
    let listener = UnixListener::bind(&endpoint).unwrap();
    listener.set_nonblocking(true).unwrap();
    let server = thread::spawn(move || {
        let deadline = Instant::now() + Duration::from_millis(500);
        let mut hellos = Vec::new();
        while Instant::now() < deadline {
            match listener.accept() {
                Ok((mut stream, _)) => {
                    stream.set_nonblocking(false).unwrap();
                    stream.set_read_timeout(Some(Duration::from_millis(100))).unwrap();
                    if let Ok(Some(frame)) = read_frame(&mut stream, MAX_FRAME_PAYLOAD) {
                        hellos.push((frame.version, frame.flags));
                    }
                }
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    thread::sleep(Duration::from_millis(2));
                }
                Err(error) => panic!("accept termination probe: {error}"),
            }
        }
        hellos
    });

    assert!(
        connect_current_record_with_timeout(
            record.clone(),
            record_path.clone(),
            Duration::from_millis(30),
            OwnerIntent::OneShot,
        )
        .is_err()
    );
    let hellos = server.join().unwrap();
    assert_eq!(
        hellos,
        vec![(
            PROTOCOL_VERSION,
            FLAG_SMART_RENDERER | FLAG_VIEWER_SIZE_ACKS | FLAG_TERMINAL_METADATA
        )]
    );

    let _ = fs::remove_file(endpoint);
    drop(lease);
    assert!(remove_stale_terminal_host_record(&record_path, &record).unwrap());
    let _ = fs::remove_dir_all(record_path.parent().unwrap());
}

#[test]
fn timed_out_cell_pixel_ack_reconciles_when_the_response_arrives_late() {
    let (record_path, record, lease) = record_fixture("late-cell-pixel-ack");
    let (client, mut host) = UnixStream::pair().unwrap();
    let control_responses = Arc::new(ControlResponses::new());
    let (reconciled_tx, reconciled_rx) = std::sync::mpsc::channel();
    control_responses.set_deferred_cell_pixel_handler(Arc::new(
        move |request_id, expected, frame| {
            reconciled_tx.send((request_id, expected, frame)).unwrap();
        },
    ));
    let attachment = HostAttachment {
        record: record.clone(),
        record_path: record_path.clone(),
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
            command: vec!["/bin/cat".into()],
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
    let (release_ack_tx, release_ack_rx) = std::sync::mpsc::channel();
    let resolver = {
        let control_responses = control_responses.clone();
        thread::spawn(move || {
            let request = read_required_frame(&mut host, "cell pixel size request").unwrap();
            assert_eq!(request.kind, MessageKind::SetCellPixelSize);
            release_ack_rx.recv().unwrap();
            let mut ack = Frame::new(MessageKind::CellPixelSizeAck, request.payload.clone());
            ack.request_id = request.request_id;
            control_responses.resolve(&ack);
        })
    };

    let error = attachment
        .send_cell_pixel_size_until(9, 18, Instant::now() + Duration::from_millis(10))
        .unwrap_err();
    assert!(error.is::<DeferredCellPixelAck>());
    assert!(error.to_string().contains("late response will reconcile the mirror"), "{error:#}");
    release_ack_tx.send(()).unwrap();
    let (request_id, expected, resolution) =
        reconciled_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    assert_eq!(request_id, 2);
    assert_eq!(expected, (9, 18));
    let DeferredCellPixelResolution::Response(ack) = resolution else {
        panic!("late acknowledgement was reported as a disconnect");
    };
    assert_eq!(ack.payload, vec![9, 0, 18, 0]);
    assert_eq!(control_responses.latest_cell_pixel_ack(), 2);

    resolver.join().unwrap();
    drop(attachment);
    drop(lease);
    assert!(remove_stale_terminal_host_record(&record_path, &record).unwrap());
    let _ = fs::remove_dir_all(record_path.parent().unwrap());
}

#[test]
fn disconnect_settles_deferred_cell_pixel_waiters() {
    let control_responses = ControlResponses::new();
    let (sender, _receiver) = sync_channel(1);
    control_responses
        .waiters
        .lock()
        .unwrap()
        .insert(7, ControlResponseWaiter::Blocking { kind: MessageKind::CellPixelSizeAck, sender });
    assert!(control_responses.defer_cell_pixel(7, (9, 18)));
    let (settled_tx, settled_rx) = std::sync::mpsc::channel();
    control_responses.set_deferred_cell_pixel_handler(Arc::new(
        move |request_id, expected, _frame| {
            settled_tx.send((request_id, expected)).unwrap();
        },
    ));

    control_responses.fail_all();

    assert_eq!(settled_rx.recv_timeout(Duration::from_secs(1)).unwrap(), (7, (9, 18)));
}

#[test]
fn detach_fence_queues_prior_source_output_and_removes_the_client() {
    let host = test_host_shared();
    let (target_socket, _target_peer) = UnixStream::pair().unwrap();
    let (target_tx, target_rx) = mpsc_channel();
    let target = HostTap::new(target_tx, Arc::new(target_socket), usize::MAX);
    host.smart.taps.lock().unwrap().insert(7, target.clone());

    let before = host.smart.publish(Frame::new(MessageKind::Output, b"before".to_vec()));
    assert!(host.fence_client_detach(7, 42, &target));
    host.smart.publish(Frame::new(MessageKind::Output, b"after".to_vec()));

    let output = target_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    assert_eq!(output.kind, MessageKind::Output);
    assert_eq!(output.sequence, before);
    assert_eq!(output.payload, b"before");
    let receipt = target_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    assert_eq!(receipt.kind, MessageKind::DetachAck);
    assert_eq!(receipt.request_id, 42);
    assert!(target_rx.try_recv().is_err());
}

#[test]
fn detach_fence_reports_a_delayed_receipt_after_output_as_a_failure() {
    let (record_path, record, lease) = record_fixture("detach-delayed-ack");
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
        smart_renderer: true,
        reader: None,
        writer: Arc::new(RankedMutex::new(client)),
        control_responses: control_responses.clone(),
        next_request: AtomicU64::new(2),
        viewer_size: RankedMutex::new(None),
        launch_process: None,
        launch_activation_pending: false,
        pty_custody: None,
    };
    let (output_queued, output_seen) = sync_channel(1);
    let (release_ack, ack_release) = sync_channel(1);
    let responder = thread::spawn(move || {
        let request = read_frame(&mut host, MAX_FRAME_PAYLOAD).unwrap().unwrap();
        assert_eq!(request.kind, MessageKind::Detach);
        let mut output = Frame::new(MessageKind::Output, b"before-timeout".to_vec());
        output.sequence = 1;
        write_frame(&mut host, &output).unwrap();
        output_queued.send(()).unwrap();
        ack_release.recv().unwrap();
        let mut response = Frame::new(MessageKind::DetachAck, Vec::new());
        response.request_id = request.request_id;
        assert!(!control_responses.resolve(&response));
    });

    let deadline = Instant::now() + Duration::from_millis(100);
    let result = attachment.detach_for_daemon_shutdown_until(deadline);
    output_seen.recv_timeout(Duration::from_secs(1)).unwrap();
    assert!(result.unwrap_err().to_string().contains("timed out"));
    release_ack.send(()).unwrap();
    responder.join().unwrap();

    drop(attachment);
    drop(lease);
    let _ = fs::remove_dir_all(root);
}

#[test]
fn cell_pixel_commit_is_broadcast_to_live_renderer_taps_before_ack() {
    let host = test_host_shared();
    let (renderer_socket, _renderer_peer) = UnixStream::pair().unwrap();
    let (renderer_tx, renderer_rx) = mpsc_channel();
    host.taps
        .lock()
        .unwrap()
        .insert(1, HostTap::new(renderer_tx, Arc::new(renderer_socket), usize::MAX));
    let (target_socket, _target_peer) = UnixStream::pair().unwrap();
    let (target_tx, target_rx) = mpsc_channel();
    let target = HostTap::new(target_tx, Arc::new(target_socket), usize::MAX);
    host.smart.taps.lock().unwrap().insert(2, target.clone());

    assert!(host.set_cell_pixel_size(9, 18, 42, &target).unwrap());

    let resized = renderer_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    assert_eq!(resized.kind, MessageKind::Resized);
    assert_eq!(resized.flags, FLAG_COLORS_FOLLOW);
    assert_eq!(decode_host_resize_payload(&resized.payload).unwrap().cell_pixels, (9, 18));
    let colors = renderer_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    assert_eq!(colors.kind, MessageKind::Colors);
    assert!(colors.sequence > resized.sequence);

    let smart_resize = target_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    assert_eq!(smart_resize.kind, MessageKind::Resized);
    assert_eq!(smart_resize.payload, [80, 0, 24, 0, 9, 0, 18, 0]);
    assert_eq!(host.smart.applied_cursor.load(Ordering::Acquire), smart_resize.sequence);
    let ack = target_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    assert_eq!(ack.kind, MessageKind::CellPixelSizeAck);
    assert_eq!(ack.request_id, 42);
}

#[test]
fn kitty_limit_commit_replaces_live_mirrors_before_ack() {
    let host = test_host_shared();
    host.term
        .lock()
        .unwrap()
        .vt_write(b"\x1b_Ga=T,t=d,f=24,i=41,p=7,s=1,v=1,c=1,r=1,q=2;AAAA\x1b\\");
    let (target_socket, _target_peer) = UnixStream::pair().unwrap();
    let (target_tx, target_rx) = mpsc_channel();
    let target = HostTap::new(target_tx, Arc::new(target_socket), usize::MAX);
    host.taps.lock().unwrap().insert(1, target.clone());
    let (smart_socket, _smart_peer) = UnixStream::pair().unwrap();
    let (smart_tx, smart_rx) = mpsc_channel();
    host.smart
        .taps
        .lock()
        .unwrap()
        .insert(2, HostTap::new(smart_tx, Arc::new(smart_socket), usize::MAX));
    let limits = KittyGraphicsLimits::disabled();

    assert!(host.set_kitty_graphics_limits(limits, 43, &target).unwrap());

    let resized = target_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    assert_eq!(resized.kind, MessageKind::Resized);
    assert_eq!(resized.flags, FLAG_COLORS_FOLLOW);
    let decoded = decode_host_resize_payload(&resized.payload).unwrap();
    assert_eq!(decoded.kitty_state.limits, limits);
    let colors = target_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    assert_eq!(colors.kind, MessageKind::Colors);
    assert!(colors.sequence > resized.sequence);
    let ack = target_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    assert_eq!(ack.kind, MessageKind::KittyGraphicsLimitsAck);
    assert_eq!(ack.request_id, 43);
    let mut decoder = PayloadDecoder::new(&ack.payload);
    assert_eq!(decode_kitty_graphics_limits(&mut decoder).unwrap(), limits);
    decoder.finish().unwrap();

    let smart_resync = smart_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    assert_eq!(smart_resync.kind, MessageKind::ResyncRequired);
    assert_eq!(host.smart.applied_cursor.load(Ordering::Acquire), smart_resync.sequence);

    let mut mirror = Terminal::new(decoded.cols, decoded.rows, 0, Callbacks::default()).unwrap();
    mirror
        .apply_vt_replay(&ghostty_vt::VtReplay {
            bytes: decoded.replay,
            kitty_image_aliases: decoded.kitty_image_aliases,
            kitty_state: decoded.kitty_state,
            pending_sequence: Vec::new(),
        })
        .unwrap();
    assert!(mirror.kitty_graphics_snapshot().unwrap().images.is_empty());
    assert_eq!(mirror.kitty_graphics_limits().unwrap(), limits);
}

#[test]
fn adoption_quota_reconfiguration_finishes_before_snapshot_use() {
    let (record_path, record, lease) = record_fixture("adoption-kitty-quota");
    let root = record_path.parent().unwrap().to_path_buf();
    let (client, mut host) = UnixStream::pair().unwrap();
    let reader = client.try_clone().unwrap();
    let mut stale_state = test_kitty_state();
    stale_state.limits = KittyGraphicsLimits {
        image_bytes: 8_000,
        inflight_bytes: 8_000,
        images: 80,
        placements: 160,
    };
    let ceiling = KittyGraphicsLimits {
        image_bytes: 4_000,
        inflight_bytes: 4_000,
        images: 40,
        placements: 80,
    };
    let mut attachment = HostAttachment {
        record,
        record_path,
        snapshot: HostSnapshot {
            cols: 80,
            rows: 24,
            cell_pixels: DEFAULT_CELL_PIXELS,
            replay: Vec::new(),
            kitty_image_aliases: Vec::new(),
            kitty_state: stale_state,
            sequence_boundary: 0,
            colors: TerminalColorOverrides::default(),
            pid: None,
            command: Vec::new(),
            cwd: None,
            osc_progress: String::new(),
        },
        protocol_version: PROTOCOL_VERSION,
        smart_renderer: false,
        reader: Some(reader),
        writer: Arc::new(RankedMutex::new(client)),
        control_responses: Arc::new(ControlResponses::new()),
        next_request: AtomicU64::new(2),
        viewer_size: RankedMutex::new(None),
        launch_process: None,
        launch_activation_pending: false,
        pty_custody: None,
    };
    let responder = thread::spawn(move || {
        let request = read_frame(&mut host, MAX_FRAME_PAYLOAD).unwrap().unwrap();
        assert_eq!(request.kind, MessageKind::SetKittyGraphicsLimits);
        let mut decoder = PayloadDecoder::new(&request.payload);
        assert_eq!(decode_kitty_graphics_limits(&mut decoder).unwrap(), ceiling);
        decoder.finish().unwrap();

        let mut fresh_state = test_kitty_state();
        fresh_state.limits = ceiling;
        let mut resized = Frame::new(
            MessageKind::Resized,
            encode_resize(80, 24, &[], &[], DEFAULT_CELL_PIXELS, fresh_state).unwrap(),
        );
        resized.version = PROTOCOL_VERSION;
        resized.flags = FLAG_COLORS_FOLLOW;
        resized.sequence = 1;
        write_frame(&mut host, &resized).unwrap();
        let mut colors = Frame::new(
            MessageKind::Colors,
            encode_terminal_color_overrides(&TerminalColorOverrides {
                cursor_visual: Some((CursorShape::Block, false)),
                ..TerminalColorOverrides::default()
            }),
        );
        colors.version = PROTOCOL_VERSION;
        colors.sequence = 2;
        write_frame(&mut host, &colors).unwrap();

        let mut payload = Vec::new();
        encode_kitty_graphics_limits(&mut payload, ceiling).unwrap();
        let mut ack = Frame::new(MessageKind::KittyGraphicsLimitsAck, payload);
        ack.version = PROTOCOL_VERSION;
        ack.request_id = request.request_id;
        write_frame(&mut host, &ack).unwrap();
        assert!(read_frame(&mut host, MAX_FRAME_PAYLOAD).unwrap().is_none());
    });

    attachment.reconfigure_kitty_graphics_for_adoption(ceiling).unwrap();
    attachment.disconnect();
    responder.join().unwrap();

    drop(attachment);
    drop(lease);
    let _ = fs::remove_dir_all(root);
}

#[test]
fn upgraded_daemon_falls_back_to_a_live_protocol_one_host() {
    let (record_path, record, lease) = record_fixture("protocol-one-adoption");
    let endpoint = PathBuf::from(&record.endpoint);
    prepare_private_dir(endpoint.parent().unwrap()).unwrap();
    let _ = fs::remove_file(&endpoint);
    let listener = UnixListener::bind(&endpoint).unwrap();
    let terminal_id = TerminalId::from_bytes(decode_hex_array(&record.terminal_id).unwrap());
    let incarnation = HostIncarnation::from_bytes(decode_hex_array(&record.incarnation).unwrap());
    let expected_replay = b"protocol-one-live-state".to_vec();
    let host_replay = expected_replay.clone();
    let fake_host = thread::spawn(move || {
        let (mut smart, _) = listener.accept().unwrap();
        let smart_hello = read_required_frame(&mut smart, "smart owner hello").unwrap();
        assert_eq!(smart_hello.kind, MessageKind::ClientHello);
        assert_eq!(smart_hello.version, PROTOCOL_VERSION);
        assert_eq!(smart_hello.flags & FLAG_SMART_RENDERER, FLAG_SMART_RENDERER);
        drop(smart);

        for rejected_version in ((LEGACY_PROTOCOL_VERSION + 1)..=PROTOCOL_VERSION).rev() {
            let (mut rejected, _) = listener.accept().unwrap();
            let hello = read_required_frame(&mut rejected, "newer-version hello").unwrap();
            assert_eq!(hello.kind, MessageKind::ClientHello);
            assert_eq!(hello.version, rejected_version);
        }

        let (mut legacy, _) = listener.accept().unwrap();
        let legacy_hello = read_required_frame(&mut legacy, "legacy hello").unwrap();
        assert_eq!(legacy_hello.kind, MessageKind::ClientHello);
        assert_eq!(legacy_hello.version, LEGACY_PROTOCOL_VERSION);
        let decoded = ClientHello::decode(&legacy_hello.payload).unwrap();
        assert_eq!(
            (decoded.min_version, decoded.max_version),
            (LEGACY_PROTOCOL_VERSION, LEGACY_PROTOCOL_VERSION)
        );

        let response = HostHello {
            selected_version: LEGACY_PROTOCOL_VERSION,
            granted_rights: CapabilityRights::ADMIN,
            terminal_id,
            incarnation,
        };
        let mut hello = Frame::new(MessageKind::HostHello, response.encode());
        hello.version = LEGACY_PROTOCOL_VERSION;
        hello.request_id = legacy_hello.request_id;
        write_frame(&mut legacy, &hello).unwrap();

        let snapshot = HostSnapshot {
            cols: 80,
            rows: 24,
            cell_pixels: DEFAULT_CELL_PIXELS,
            replay: host_replay,
            kitty_image_aliases: Vec::new(),
            kitty_state: test_kitty_state(),
            sequence_boundary: 0,
            colors: TerminalColorOverrides::default(),
            pid: Some(42),
            command: vec!["/bin/cat".into()],
            cwd: Some("/tmp".into()),
            osc_progress: String::new(),
        };
        let mut payload = encode_snapshot(&snapshot).unwrap();
        payload.truncate(
            payload.len()
                - KITTY_IMAGE_ALIAS_COUNT_LEN
                - CELL_PIXEL_SIZE_ENCODED_LEN
                - KITTY_REPLAY_STATE_ENCODED_LEN,
        );
        let mut frame = Frame::new(MessageKind::Snapshot, payload);
        frame.version = LEGACY_PROTOCOL_VERSION;
        write_frame(&mut legacy, &frame).unwrap();

        let colors = TerminalColorOverrides {
            cursor_visual: Some((CursorShape::Block, true)),
            ..TerminalColorOverrides::default()
        };
        let mut frame = Frame::new(MessageKind::Colors, encode_terminal_color_overrides(&colors));
        frame.version = LEGACY_PROTOCOL_VERSION;
        write_frame(&mut legacy, &frame).unwrap();

        let release = read_required_frame(&mut legacy, "legacy viewer release").unwrap();
        assert_eq!(release.kind, MessageKind::ReleaseViewer);
        assert_eq!(release.version, LEGACY_PROTOCOL_VERSION);
    });

    let attachment = connect_record_with_timeout(
        record.clone(),
        record_path.clone(),
        Duration::from_secs(1),
        OwnerIntent::Surface,
    )
    .unwrap();
    assert_eq!(attachment.protocol_version(), LEGACY_PROTOCOL_VERSION);
    assert_eq!(attachment.snapshot.replay, expected_replay);
    assert!(attachment.snapshot.kitty_image_aliases.is_empty());
    assert!(!attachment.send_cell_pixel_size(9, 18).unwrap());
    drop(attachment);
    fake_host.join().unwrap();

    let _ = fs::remove_file(endpoint);
    drop(lease);
    assert!(remove_stale_terminal_host_record(&record_path, &record).unwrap());
    let _ = fs::remove_dir_all(record_path.parent().unwrap());
}

#[test]
fn smart_owner_negotiation_falls_back_to_a_live_legacy_host() {
    let (record_path, record, lease) = record_fixture("legacy-fallback");
    let mut record = record;
    // This fixture models a current-protocol host from before the
    // optional metadata extension. It must not receive the new tail.
    record.supports_terminal_metadata = false;
    let endpoint = PathBuf::from(&record.endpoint);
    prepare_private_dir(endpoint.parent().unwrap()).unwrap();
    let _ = fs::remove_file(&endpoint);
    let listener = UnixListener::bind(&endpoint).unwrap();
    listener.set_nonblocking(true).unwrap();
    let server_record = record.clone();
    let server = thread::spawn(move || -> anyhow::Result<bool> {
        let accept_before = |deadline: Instant| -> anyhow::Result<Option<UnixStream>> {
            loop {
                match listener.accept() {
                    Ok((stream, _)) => {
                        stream.set_nonblocking(false)?;
                        return Ok(Some(stream));
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        if Instant::now() >= deadline {
                            return Ok(None);
                        }
                        thread::sleep(Duration::from_millis(2));
                    }
                    Err(error) => return Err(error.into()),
                }
            }
        };

        let Some(mut smart) = accept_before(Instant::now() + Duration::from_secs(1))? else {
            return Ok(false);
        };
        smart.set_read_timeout(Some(Duration::from_secs(1)))?;
        let smart_hello = read_required_frame(&mut smart, "smart owner hello")?;
        if smart_hello.flags & FLAG_SMART_RENDERER == 0 {
            return Ok(false);
        }
        drop(smart);

        let Some(mut legacy) = accept_before(Instant::now() + Duration::from_secs(1))? else {
            return Ok(false);
        };
        legacy.set_read_timeout(Some(Duration::from_secs(1)))?;
        let hello_frame = read_required_frame(&mut legacy, "legacy owner hello")?;
        if hello_frame.flags != 0 || hello_frame.version != PROTOCOL_VERSION {
            return Ok(false);
        }
        let hello = ClientHello::decode(&hello_frame.payload)?;
        let incarnation =
            HostIncarnation::from_bytes(decode_hex_array(&server_record.incarnation)?);
        let response = HostHello {
            selected_version: PROTOCOL_VERSION,
            granted_rights: CapabilityRights::ADMIN,
            terminal_id: hello.terminal_id,
            incarnation,
        };
        let mut host_hello = Frame::new(MessageKind::HostHello, response.encode());
        host_hello.request_id = hello_frame.request_id;
        write_frame(&mut legacy, &host_hello)?;

        let snapshot = HostSnapshot {
            cols: 80,
            rows: 24,
            cell_pixels: DEFAULT_CELL_PIXELS,
            replay: b"legacy host survived".to_vec(),
            kitty_image_aliases: Vec::new(),
            kitty_state: test_kitty_state(),
            sequence_boundary: 0,
            colors: TerminalColorOverrides::default(),
            pid: None,
            command: vec!["/bin/sh".into()],
            cwd: None,
            osc_progress: String::new(),
        };
        let mut snapshot_frame = Frame::new(MessageKind::Snapshot, encode_snapshot(&snapshot)?);
        snapshot_frame.sequence = 17;
        write_frame(&mut legacy, &snapshot_frame)?;
        let colors_state = TerminalColorOverrides {
            cursor_visual: Some((CursorShape::Block, false)),
            ..Default::default()
        };
        let mut colors =
            Frame::new(MessageKind::Colors, encode_terminal_color_overrides(&colors_state));
        colors.sequence = snapshot_frame.sequence;
        write_frame(&mut legacy, &colors)?;

        let release = read_required_frame(&mut legacy, "legacy viewer release")?;
        Ok(release.kind == MessageKind::ReleaseViewer)
    });

    let result = connect_record_with_timeout(
        record.clone(),
        record_path.clone(),
        Duration::from_secs(1),
        OwnerIntent::Surface,
    );
    let saw_legacy = server.join().unwrap().unwrap();
    let attachment = result.expect("legacy fallback did not adopt the live shell");
    assert!(saw_legacy);
    assert!(!attachment.is_smart_renderer());
    assert!(!attachment.supports_journal_detach_fence());
    assert_eq!(attachment.snapshot.replay, b"legacy host survived");
    drop(attachment);

    let _ = fs::remove_file(endpoint);
    drop(lease);
    assert!(remove_stale_terminal_host_record(&record_path, &record).unwrap());
    let _ = fs::remove_dir_all(record_path.parent().unwrap());
}

#[test]
fn snapshot_boundary_waits_for_parser_progress_and_times_out() {
    let host = exited_host_fixture();
    let mut term = host.term.lock().unwrap();
    term.vt_write(b"\xce");
    assert!(!term.vt_stream_is_ground());

    let waiter_host = host.clone();
    let (result_sender, result_receiver) = std::sync::mpsc::channel();
    let waiter = thread::spawn(move || {
        let result = waiter_host
            .terminal_at_snapshot_boundary(Duration::from_secs(1))
            .and_then(|mut term| term.viewport_text().map_err(anyhow::Error::from));
        result_sender.send(result).unwrap();
    });

    let deadline = Instant::now() + Duration::from_secs(1);
    loop {
        match host.parser_progress.0.try_lock() {
            Err(TryLockError::WouldBlock) => break,
            Err(TryLockError::Poisoned(error)) => panic!("{error}"),
            Ok(guard) => drop(guard),
        }
        assert!(Instant::now() < deadline, "snapshot waiter never inspected the parser");
        thread::yield_now();
    }
    drop(term);

    loop {
        match host.parser_progress.0.try_lock() {
            Ok(guard) => {
                drop(guard);
                break;
            }
            Err(TryLockError::WouldBlock) => {}
            Err(TryLockError::Poisoned(error)) => panic!("{error}"),
        }
        assert!(Instant::now() < deadline, "snapshot waiter never entered its wait");
        thread::yield_now();
    }
    host.term.lock().unwrap().vt_write(b"\xbb");
    host.note_parser_progress();

    assert!(result_receiver.recv().unwrap().unwrap().contains('λ'));
    waiter.join().unwrap();

    let timed_out = exited_host_fixture();
    timed_out.term.lock().unwrap().vt_write(b"\x1b");
    let started = Instant::now();
    let error = match timed_out.terminal_at_snapshot_boundary(Duration::from_millis(20)) {
        Ok(_) => panic!("unterminated VT sequence was admitted for a snapshot"),
        Err(error) => error,
    };
    assert!(error.to_string().contains("safe snapshot boundary"));
    assert!(started.elapsed() < Duration::from_secs(1));
}

#[test]
fn snapshot_boundary_protects_legacy_and_smart_bootstraps() {
    for smart in [false, true] {
        let host = exited_host_fixture();
        host.term.lock().unwrap().vt_write(b"before \xce");
        let (server_stream, mut client_stream) = UnixStream::pair().unwrap();
        client_stream.set_read_timeout(Some(Duration::from_secs(1))).unwrap();
        let server_host = host.clone();
        let server = thread::spawn(move || {
            serve_client_with_snapshot_timeout(server_host, server_stream, Duration::from_secs(1))
        });

        write_frame(&mut client_stream, &snapshot_boundary_client_hello(&host, smart).unwrap())
            .unwrap();
        let hello = read_required_frame(&mut client_stream, "host hello").unwrap();
        assert_eq!(hello.kind, MessageKind::HostHello);
        assert_eq!(hello.flags & FLAG_SMART_RENDERER != 0, smart);

        host.term.lock().unwrap().vt_write(b"\xbb after");
        host.note_parser_progress();

        let snapshot = read_required_frame(&mut client_stream, "snapshot").unwrap();
        assert_eq!(snapshot.kind, MessageKind::Snapshot);
        let snapshot = decode_host_snapshot_payload(&snapshot.payload).unwrap();
        let colors = read_required_frame(&mut client_stream, "colors").unwrap();
        assert_eq!(colors.kind, MessageKind::Colors);
        if smart {
            assert_eq!(
                read_required_frame(&mut client_stream, "ready").unwrap().kind,
                MessageKind::Ready
            );
        }

        let mut mirror = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
        mirror.vt_write(&snapshot.replay);
        let text = mirror.viewport_text().unwrap();
        assert!(text.contains("before λ after"), "smart={smart} snapshot={text:?}");
        assert!(!text.contains('\u{fffd}'), "smart={smart} snapshot={text:?}");

        if smart {
            let cursor = host.smart.publish(Frame::new(MessageKind::Exit, Vec::new()));
            host.smart.mark_applied(cursor);
        } else {
            host.broadcast(MessageKind::Exit, Vec::new());
        }
        assert_eq!(
            read_required_frame(&mut client_stream, "exit").unwrap().kind,
            MessageKind::Exit
        );
        let _ = client_stream.shutdown(std::net::Shutdown::Both);
        server.join().unwrap().unwrap();
    }
}

#[test]
fn unterminated_snapshot_boundary_resyncs_legacy_and_smart_clients() {
    for smart in [false, true] {
        let host = exited_host_fixture();
        host.term.lock().unwrap().vt_write(b"\x1b]0;unterminated");
        let (server_stream, mut client_stream) = UnixStream::pair().unwrap();
        client_stream.set_read_timeout(Some(Duration::from_secs(1))).unwrap();
        let server_host = host.clone();
        let server = thread::spawn(move || {
            serve_client_with_snapshot_timeout(
                server_host,
                server_stream,
                Duration::from_millis(20),
            )
        });

        write_frame(&mut client_stream, &snapshot_boundary_client_hello(&host, smart).unwrap())
            .unwrap();
        assert_eq!(
            read_required_frame(&mut client_stream, "host hello").unwrap().kind,
            MessageKind::HostHello
        );
        let resync = read_required_frame(&mut client_stream, "resync").unwrap();
        assert_eq!(resync.kind, MessageKind::ResyncRequired);
        assert!(resync.payload.is_empty());
        assert!(server.join().unwrap().unwrap_err().to_string().contains("safe snapshot boundary"));
    }
}

#[test]
fn poisoned_snapshot_geometry_resyncs_and_fails_closed() {
    for poisoned in ["viewer_sizes", "size", "cell_pixels"] {
        let host = exited_host_fixture();
        let poison_host = host.clone();
        let poisoner = thread::spawn(move || match poisoned {
            "viewer_sizes" => {
                let _guard = poison_host.viewer_sizes.lock().unwrap();
                panic!("poison viewer sizes");
            }
            "size" => {
                let _guard = poison_host.size.lock().unwrap();
                panic!("poison size");
            }
            "cell_pixels" => {
                let _guard = poison_host.cell_pixels.lock().unwrap();
                panic!("poison cell pixels");
            }
            _ => unreachable!(),
        });
        assert!(poisoner.join().is_err());

        let (server_stream, mut client_stream) = UnixStream::pair().unwrap();
        client_stream.set_read_timeout(Some(Duration::from_secs(1))).unwrap();
        let server_host = host.clone();
        let server = thread::spawn(move || {
            serve_client_with_snapshot_timeout(
                server_host,
                server_stream,
                Duration::from_millis(20),
            )
        });

        write_frame(&mut client_stream, &snapshot_boundary_client_hello(&host, false).unwrap())
            .unwrap();
        assert_eq!(
            read_required_frame(&mut client_stream, "host hello").unwrap().kind,
            MessageKind::HostHello
        );
        assert_eq!(
            read_required_frame(&mut client_stream, "resync").unwrap().kind,
            MessageKind::ResyncRequired
        );
        let error = server.join().unwrap().unwrap_err();
        assert!(error.to_string().contains("poisoned"), "{poisoned} returned {error:#}");
    }
}

#[test]
fn legacy_resize_resyncs_instead_of_replaying_partial_utf8() {
    let host = exited_host_fixture();
    let (host_socket, _client_socket) = UnixStream::pair().unwrap();
    let (sender, receiver) = mpsc_channel();
    host.taps.lock().unwrap().insert(
        1,
        HostTap {
            sender,
            queued_bytes: Arc::new(AtomicUsize::new(0)),
            queued_output_bytes: Arc::new(AtomicUsize::new(0)),
            shutdown: Arc::new(host_socket),
            max_queued_bytes: usize::MAX,
        },
    );

    // A replay cannot serialize the decoder's pending 0xce byte. If
    // the later 0xbb is delivered after that replay, a fresh mirror
    // decodes it as U+FFFD instead of completing U+03BB.
    host.term.lock().unwrap().vt_write(b"before \xce");
    assert!(!host.term.lock().unwrap().vt_stream_is_ground());

    host.apply_parser_resize(100, 30, None, false, None, DEFAULT_CELL_PIXELS)
        .acknowledgement_queued
        .unwrap();

    let frame = receiver.recv_timeout(Duration::from_secs(1)).unwrap();
    assert_eq!(frame.kind, MessageKind::ResyncRequired);
    assert!(receiver.try_recv().is_err(), "unsafe resize emitted a replay or color pair");
}

#[test]
fn committed_resize_updates_cached_geometry_when_publication_fails() {
    let (host, parser_commands) = exited_host_fixture_with_parser();
    let parser_host = host.clone();
    let parser = thread::spawn(move || {
        let ParserCommand::Resize {
            cols,
            rows,
            cell_pixels,
            source_cursor,
            acknowledge_with_replay,
            targeted_ack,
            response,
        } = parser_commands.recv().unwrap()
        else {
            panic!("expected resize command");
        };
        let result = parser_host.apply_parser_resize(
            cols,
            rows,
            source_cursor,
            acknowledge_with_replay,
            targeted_ack,
            cell_pixels,
        );
        response.send(result).unwrap();
    });

    host.fail_next_resize_publication.store(true, Ordering::Release);
    let error = host.apply_viewer_minimum(Some((100, 30)), true, None).unwrap_err();
    assert!(error.to_string().contains("injected terminal resize publication failure"));
    assert_eq!(*host.size.lock().unwrap(), (100, 30));
    let term = host.term.lock().unwrap();
    assert_eq!((term.cols(), term.rows()), (100, 30));
    drop(term);
    assert!(host.apply_viewer_minimum(Some((100, 30)), false, None).unwrap());
    parser.join().unwrap();
}
