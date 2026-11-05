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
            adopted: false,
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

/// A hosted surface on a fake host connection (the host end is the second value).
#[cfg(unix)]
pub(super) fn hosted_typing_surface(
    name: &str,
) -> (Arc<Mux>, Arc<Surface>, std::os::unix::net::UnixStream) {
    hosted_surface_with(name, |_| {})
}

/// [`hosted_typing_surface`] with the fake host's attachment changed by `configure` before the surface takes it.
#[cfg(unix)]
fn hosted_surface_with(
    name: &str,
    configure: impl FnOnce(&mut crate::terminal_host_runtime::HostAttachment),
) -> (Arc<Mux>, Arc<Surface>, std::os::unix::net::UnixStream) {
    let mux = Mux::new_for_test(name, SurfaceOptions::default());
    let workspace = mux.create_empty_workspace(None, None, None).unwrap();
    let (mut attachment, host) = crate::terminal_host_runtime::input_ack_surface_fixture();
    configure(&mut attachment);
    let terminal_id = attachment.record.terminal_id.clone();
    attachment.record.workspace_key = workspace.key.clone();
    mux.seed_launching_terminal_for_test(&terminal_id, &workspace.key).unwrap();
    let surface = Surface::spawn_hosted(
        1,
        SurfaceOptions::default(),
        Arc::downgrade(&mux),
        HostedSurfaceLaunch {
            adopted: false,
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
    host.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    (mux, surface, host)
}

/// How long the fake host reads nothing before it drains its socket.
#[cfg(unix)]
const HOST_STALL: Duration = Duration::from_millis(600);

/// A key while another client's large paste to the same hosted terminal is in its socket write and the host reads
/// nothing for [`HOST_STALL`]: how long the key took to return, and the frame kinds the host then read, in order.
/// The host drains on its own thread after the stall, so a key that waits for the paste cannot hang the test.
#[cfg(unix)]
fn key_behind_a_blocked_paste() -> (Duration, Vec<MessageKind>) {
    let (_mux, surface, mut host) = hosted_typing_surface("hosted-input-port");
    // Far larger than the socket buffer: its write blocks while the host reads nothing.
    let paste = vec![b'p'; 8 * 1024 * 1024];
    std::thread::scope(|scope| {
        let reader = scope.spawn(move || {
            std::thread::sleep(HOST_STALL);
            let mut kinds = Vec::new();
            while kinds.last() != Some(&MessageKind::Input) {
                let frame = crate::terminal_host_protocol::read_frame(
                    &mut host,
                    crate::terminal_host_protocol::MAX_FRAME_PAYLOAD,
                )
                .expect("the host reads the queued frames")
                .expect("the host connection stays open");
                kinds.push(frame.kind);
            }
            kinds
        });
        let pasting = scope.spawn(|| surface.write_paste(&paste));
        // Long enough for the paste's writer to be inside its blocked socket write, well inside the stall.
        std::thread::sleep(Duration::from_millis(150));
        let started = Instant::now();
        // The person's key: it answers when the port took it.
        surface.write_bytes_replying(b"k", InputReply::Accepted).expect("the key was accepted");
        let took = started.elapsed();
        pasting.join().unwrap().expect("the paste was written");
        (took, reader.join().unwrap())
    })
}

/// R-DAEMON-STATE stage S1 step 6 (DESIGN.md section 2.6.1): a key to a hosted terminal never waits for another
/// writer's blocked write to the same terminal's host socket. A paste's write once held the terminal's runtime lock
/// and the host writer for the whole write (bounded only by the socket's send timeout), and the key waited behind it.
/// The key is handed to the terminal's own input port and returns at once; the port writes in order, the paste first,
/// once the host reads.
#[cfg(unix)]
#[test]
fn a_key_does_not_wait_for_another_writers_blocked_host_socket() {
    let (took, kinds) = key_behind_a_blocked_paste();
    assert!(
        took < Duration::from_millis(100),
        "the key waited {took:?} for another writer's blocked host socket"
    );
    // The host stops reading at the first key frame, so this proves the key arrived (after the paste, below), not
    // that it arrived only once: `keys_on_the_input_port_reach_the_host_once_each_in_order` checks that.
    assert_eq!(
        kinds.iter().filter(|kind| **kind == MessageKind::Input).count(),
        1,
        "the key reached the host: {kinds:?}"
    );
    // Both must be there: the host stops reading at the first key, so a key that passed the paste leaves no paste.
    let paste_at = kinds.iter().position(|kind| *kind == MessageKind::Paste);
    let key_at = kinds.iter().position(|kind| *kind == MessageKind::Input);
    assert!(
        matches!((paste_at, key_at), (Some(paste), Some(key)) if paste < key),
        "the paste, written first, reached the host before the key: {kinds:?}"
    );
}

/// A key to a terminal whose host connection the reader shut down (`Failed`, still retrying) is refused at once
/// (`cmux send` exits non-zero); once a replacement's route is published, keys go through again (#34544 review 3).
#[cfg(unix)]
#[test]
fn a_key_to_a_failed_link_is_refused_until_a_live_route_is_published() {
    let (_mux, surface, mut host) = hosted_typing_surface("hosted-input-port-failed");
    let pty = surface.as_pty().expect("a terminal");
    pty.input_route.store(Some(Arc::new(input_port::InputRoute::Failed)));
    let refused = surface.write_bytes(b"x").expect_err("a key to a failed link was accepted");
    assert_eq!(refused.kind(), std::io::ErrorKind::NotConnected, "{refused}");

    let live = PtyTerminalRuntime::input_route_of(&pty.runtime.lock().unwrap());
    pty.input_route.store(live);
    surface.write_bytes(b"y").expect("the key after the replacement was refused");
    let frame = loop {
        let frame = crate::terminal_host_protocol::read_frame(
            &mut host,
            crate::terminal_host_protocol::MAX_FRAME_PAYLOAD,
        )
        .expect("the host reads the key")
        .expect("the host connection stays open");
        if frame.kind == MessageKind::Input {
            break frame;
        }
    };
    assert_eq!(frame.payload, b"y", "the refused key must not reach the host");
}

/// A hosted terminal publishes its input route when its runtime is made and at every runtime swap
/// (`PtyTerminalRuntime::replace_runtime`), so its keys and pastes go through its input port. A hosted terminal
/// with no route breaks that rule: its input must fail with a typed error (`cmux send` exits non-zero, the
/// creating-input flush gives the bytes back), never go to the host connection around the port (with no reconnect
/// wait and out of order with the port's frames), and never panic (plans/cmux-next/rust-panic-free.md rule 1).
#[cfg(unix)]
#[test]
fn input_to_a_hosted_terminal_with_no_input_route_fails_and_does_not_panic() {
    let (mux, surface, mut host) = hosted_typing_surface("hosted-input-no-route");
    let pty = surface.as_pty().expect("a terminal");
    pty.input_route.store(None);
    let key = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| surface.write_bytes(b"k")));
    let paste =
        std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| surface.write_paste(b"p")));
    let written: Vec<MessageKind> = frames_until_quiet(&mut host, Duration::from_millis(300))
        .into_iter()
        .map(|frame| frame.kind)
        .filter(|kind| matches!(kind, MessageKind::Input | MessageKind::Paste))
        .collect();
    let outcome = |what: &str, result: std::thread::Result<std::io::Result<()>>| match result {
        Ok(Err(error)) if error.kind() == std::io::ErrorKind::NotConnected => None,
        Ok(Err(error)) => {
            Some(format!("the {what} failed with another error: {error} ({:?})", error.kind()))
        }
        Ok(Ok(())) => Some(format!("the {what} was answered ok")),
        Err(_) => Some(format!("the {what} panicked")),
    };
    let paste_panicked = paste.is_err();
    let mut wrong: Vec<String> =
        [outcome("key", key), outcome("paste", paste)].into_iter().flatten().collect();
    if !written.is_empty() {
        wrong.push(format!("input reached the host around the input port: {written:?}"));
    }
    if paste_panicked {
        // The panic poisoned the terminal's runtime lock, so the surface's teardown would panic a second time.
        std::mem::forget(surface);
        std::mem::forget(mux);
    }
    assert!(
        wrong.is_empty(),
        "input to a hosted terminal with no input route: {}",
        wrong.join("; ")
    );
}

/// R-DAEMON-STATE S1.6b: a frame another writer sends to a hosted terminal's host connection (a viewer size, cell
/// pixels, receipted input, a clear history, Kitty limits, a clipboard reply, a terminate) after a key the input port
/// took reaches the host after that key, though the port has not written it yet.
#[cfg(unix)]
#[test]
fn a_frame_sent_after_a_key_the_port_holds_reaches_the_host_after_it() {
    let (_mux, surface, mut host) = hosted_typing_surface("hosted-input-port-order-barrier");
    let pty = surface.as_pty().expect("a terminal");
    // The key must be a frame the port's writer holds: no inline write.
    pty.input_port.queue_every_write_for_test();
    let resume = pty.input_port.pause_writes_for_test();
    surface.write_bytes_replying(b"k", InputReply::Accepted).expect("the port took the key");
    std::thread::scope(|scope| {
        let direct = scope.spawn(|| {
            let runtime = pty.runtime.lock().unwrap();
            let PtyRuntime::Hosted(attachment) = &*runtime else {
                panic!("the fixture's terminal is hosted");
            };
            attachment.send(MessageKind::Activate, &[]).expect("the direct frame was written");
        });
        // The direct sender is now inside its send, while the port holds the key.
        std::thread::sleep(Duration::from_millis(200));
        resume.send(()).expect("the port's writer waits");
        direct.join().unwrap();
    });
    drop(resume);
    let mut kinds = Vec::new();
    while !(kinds.contains(&MessageKind::Input) && kinds.contains(&MessageKind::Activate)) {
        let frame = crate::terminal_host_protocol::read_frame(
            &mut host,
            crate::terminal_host_protocol::MAX_FRAME_PAYLOAD,
        )
        .expect("the host reads both frames")
        .expect("the host connection stays open");
        kinds.push(frame.kind);
    }
    let key_at = kinds.iter().position(|kind| *kind == MessageKind::Input);
    let frame_at = kinds.iter().position(|kind| *kind == MessageKind::Activate);
    assert!(
        matches!((key_at, frame_at), (Some(key), Some(frame)) if key < frame),
        "a frame sent after a key the port held passed it: {kinds:?}"
    );
}

/// R-DAEMON-STATE S1.6b: a write that is not the person's key (a script's `cmux send`, a resource input effect, the
/// creating-input flush) answers when the input port wrote it, so it never answers ok for bytes the port has not
/// written.
#[cfg(unix)]
#[test]
fn an_automation_write_answers_after_the_port_wrote_it() {
    let (_mux, surface, mut host) = hosted_typing_surface("hosted-input-port-automation-reply");
    let pty = surface.as_pty().expect("a terminal");
    let resume = pty.input_port.pause_writes_for_test();
    std::thread::scope(|scope| {
        let writing = scope.spawn(|| surface.write_bytes(b"a"));
        std::thread::sleep(Duration::from_millis(200));
        let answered_early = writing.is_finished();
        resume.send(()).expect("the port's writer waits");
        writing.join().unwrap().expect("the write");
        assert!(!answered_early, "an automation write answered before the port wrote it");
    });
    let frame = crate::terminal_host_protocol::read_frame(
        &mut host,
        crate::terminal_host_protocol::MAX_FRAME_PAYLOAD,
    )
    .expect("the host reads the write")
    .expect("the host connection stays open");
    assert_eq!((frame.kind, frame.payload.as_slice()), (MessageKind::Input, &b"a"[..]));
}

/// R-DAEMON-STATE S1.6b: a write that is not the person's key gets the error of its own frame (here the reader
/// shut the connection down after the port took the bytes), so `cmux send` exits non-zero and a resource input effect
/// is marked failed.
#[cfg(unix)]
#[test]
fn an_automation_write_gets_the_error_of_its_frame() {
    let (_mux, surface, _host) = hosted_typing_surface("hosted-input-port-automation-error");
    let pty = surface.as_pty().expect("a terminal");
    let resume = pty.input_port.pause_writes_for_test();
    std::thread::scope(|scope| {
        let writing = scope.spawn(|| surface.write_bytes(b"b"));
        // The route fails after the port took the frame (else the write is refused at enqueue, with the same error).
        wait_until("the port took the write", || pty.input_port.accepted_for_test() == 1);
        pty.input_route.store(Some(Arc::new(input_port::InputRoute::Failed)));
        resume.send(()).expect("the port's writer waits");
        let error = writing
            .join()
            .unwrap()
            .expect_err("an automation write the port could not write answered ok");
        assert_eq!(error.kind(), std::io::ErrorKind::NotConnected, "{error}");
    });
}

/// Keys to a hosted terminal on the input port reach the host once each, in the order they were typed, and a key the
/// port took returns before the host read anything (#34544 review). An idle port writes each key on its own turn
/// (`input_port_inline.rs`); the order holds the same way when the port's writer writes them.
#[cfg(unix)]
#[test]
fn keys_on_the_input_port_reach_the_host_once_each_in_order() {
    let (_mux, surface, mut host) = hosted_typing_surface("hosted-input-port-order");
    let keys: Vec<u8> = (b'a'..=b'z').collect();
    for key in &keys {
        surface.write_bytes_replying(&[*key], InputReply::Accepted).expect("the port took the key");
    }
    let mut written = Vec::new();
    while written.len() < keys.len() {
        let frame = crate::terminal_host_protocol::read_frame(
            &mut host,
            crate::terminal_host_protocol::MAX_FRAME_PAYLOAD,
        )
        .expect("the host reads the keys")
        .expect("the host connection stays open");
        if frame.kind == MessageKind::Input {
            written.extend_from_slice(&frame.payload);
        }
    }
    assert_eq!(written, keys, "the keys reached the host in another order or more than once");
    // Nothing more: no key is written twice.
    host.set_read_timeout(Some(Duration::from_millis(150))).unwrap();
    // Ends at the read timeout (nothing more) or at end of stream.
    while let Ok(Some(frame)) = crate::terminal_host_protocol::read_frame(
        &mut host,
        crate::terminal_host_protocol::MAX_FRAME_PAYLOAD,
    ) {
        assert_ne!(
            frame.kind,
            MessageKind::Input,
            "a key reached the host twice: {:?}",
            frame.payload
        );
    }
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

/// `render-state` carries no position. A render attach to an exited terminal
/// whose viewport is scrolled back must still learn the position: the stream
/// gives `scroll-changed` and then ends.
#[cfg(unix)]
#[test]
fn exited_terminal_render_attach_learns_a_scrolled_back_viewport() {
    let mux = Mux::new_for_test("exited-host-render-scroll", SurfaceOptions::default());
    let surface = exited_host_surface("render-scroll", 95, &mux);
    let output: String = (1..=500).map(|line| format!("{line}\r\n")).collect();
    surface.with_terminal(|term| term.vt_write(output.as_bytes()));
    surface.scroll_delta(-3).unwrap();
    let scrolled = surface.with_terminal(|term| term.scrollbar()).flatten().unwrap();
    assert!(scrolled.scrolled_back(), "fixture scrolls the exited terminal back");

    let attach = surface.attach_render_stream().expect("exited terminal serves a final frame");
    let first = attach.stream.try_recv();
    assert!(
        matches!(first, Ok(RenderAttachFrame::ScrollChanged { offset, at_bottom: false })
            if offset == scrolled.offset),
        "an exited render attach must get scroll-changed {{offset:{}, at_bottom:false}} \
         after render-state; got {first:?}",
        scrolled.offset
    );
    assert!(matches!(attach.stream.try_recv(), Err(TryRecvError::Disconnected)));
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

/// A host connection whose host end is closed: a send on its route fails as a lost host's send does (EPIPE).
#[cfg(unix)]
fn dead_host_route() -> input_port::InputRoute {
    let (attachment, host) = crate::terminal_host_runtime::input_ack_surface_fixture();
    drop(host);
    input_port::InputRoute::Hosted(attachment.input_route())
}

/// Waits (at most 5 s) until `ready` holds, or fails the test with `what`.
#[cfg(unix)]
pub(super) fn wait_until(what: &str, ready: impl Fn() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while !ready() {
        assert!(Instant::now() < deadline, "timed out waiting until {what}");
        std::thread::sleep(Duration::from_millis(2));
    }
}

/// The frames `host` reads until it reads nothing for `quiet` or its connection ends.
#[cfg(unix)]
fn frames_until_quiet(host: &mut std::os::unix::net::UnixStream, quiet: Duration) -> Vec<Frame> {
    host.set_read_timeout(Some(quiet)).unwrap();
    let mut frames = Vec::new();
    while let Ok(Some(frame)) = crate::terminal_host_protocol::read_frame(
        host,
        crate::terminal_host_protocol::MAX_FRAME_PAYLOAD,
    ) {
        frames.push(frame);
    }
    frames
}

/// The payloads of the `Input` frames in `frames`, in order.
#[cfg(unix)]
fn input_payloads(frames: &[Frame]) -> Vec<Vec<u8>> {
    frames
        .iter()
        .filter(|frame| frame.kind == MessageKind::Input)
        .map(|f| f.payload.clone())
        .collect()
}

/// Starts the port's writer on a key `k` and lets it write it, then holds it paused on its next frame: the next
/// frame is taken at once by a running writer (no thread start), so a test of a frame "taken, not yet written"
/// does not depend on how fast a new thread starts (#35082 review 2, should-do 4). Returns the pause's sender.
#[cfg(unix)]
fn running_paused_writer(surface: &Surface, pty: &PtySurface) -> std::sync::mpsc::Sender<()> {
    // The key must be a frame the port's writer holds: no inline write.
    pty.input_port.queue_every_write_for_test();
    let resume = pty.input_port.pause_writes_for_test();
    surface.write_bytes_replying(b"k", InputReply::Accepted).expect("the port took the key");
    wait_until("the writer took the key", || pty.input_port.queued_frames_for_test() == 0);
    resume.send(()).expect("the port's writer waits");
    resume
}

/// Installs a live replacement connection as the reader does (`PtyTerminalRuntime::replace_runtime` under the
/// runtime lock, which it then releases); returns the replacement's host end.
#[cfg(unix)]
fn install_replacement(pty: &PtySurface) -> std::os::unix::net::UnixStream {
    let (replacement, host) = crate::terminal_host_runtime::input_ack_surface_fixture();
    let mut runtime = pty.runtime.lock().unwrap();
    pty.replace_runtime(&mut runtime, PtyRuntime::Hosted(Box::new(replacement)));
    host
}

/// R-DAEMON-STATE S1.6b review 1 (must-fix 1): after the reader installs a live replacement connection
/// (`replace_runtime`) and before its stream notify (the VT replay comes between), another writer's frame on the new
/// connection must not pass the keys the input port took while the connection was lost. The port's reconnect wait
/// ended only at the stream notify, and the barrier skipped while the port waited, so the frame went first.
#[cfg(unix)]
#[test]
fn a_frame_sent_after_a_replacement_install_waits_for_the_keys_the_port_held() {
    let (_mux, surface, _host) = hosted_typing_surface("hosted-input-port-install-order");
    let pty = surface.as_pty().expect("a terminal");
    pty.input_route.store(Some(Arc::new(dead_host_route())));
    surface.write_bytes_replying(b"k", InputReply::Accepted).expect("the port took the key");
    wait_until("the port's writer waits for a reconnect", || {
        pty.input_port.reconnecting_for_test()
    });
    let mut replacement_host = install_replacement(pty);
    {
        let runtime = pty.runtime.lock().unwrap();
        let PtyRuntime::Hosted(attachment) = &*runtime else {
            panic!("the replacement is hosted");
        };
        attachment.send(MessageKind::Activate, &[]).expect("the direct frame was written");
    }
    let kinds: Vec<_> = frames_until_quiet(&mut replacement_host, Duration::from_millis(1500))
        .into_iter()
        .map(|frame| frame.kind)
        .collect();
    let key_at = kinds.iter().position(|kind| *kind == MessageKind::Input);
    let frame_at = kinds.iter().position(|kind| *kind == MessageKind::Activate);
    assert!(
        matches!((key_at, frame_at), (Some(key), Some(frame)) if key < frame),
        "a frame sent after the replacement install passed the key the port held: {kinds:?}"
    );
}

/// R-DAEMON-STATE S1.6b review 1 (must-fix 2): a host connection lost again later (here after a replacement that got
/// no write) gives its writes their own reconnect wait. The port kept the first loss's deadline until a write
/// succeeded, so the later write failed at once.
#[cfg(unix)]
#[test]
fn a_later_host_loss_waits_for_its_own_reconnect() {
    let (_mux, surface, _host) = hosted_typing_surface("hosted-input-port-second-loss");
    let pty = surface.as_pty().expect("a terminal");
    pty.input_port.set_reconnect_wait_for_test(Duration::from_millis(300));
    pty.input_route.store(Some(Arc::new(dead_host_route())));
    surface.write_bytes(b"1").expect_err("a write to a lost host that never came back answered ok");
    let replacement_host = install_replacement(pty);
    // The first loss's wait is long over when the replacement's host is lost too.
    std::thread::sleep(Duration::from_millis(400));
    drop(replacement_host);
    std::thread::scope(|scope| {
        let writing = scope.spawn(|| surface.write_bytes(b"2"));
        wait_until("the write waits for a reconnect or has answered", || {
            writing.is_finished() || pty.input_port.reconnecting_for_test()
        });
        if writing.is_finished() {
            let answered = writing.join().unwrap();
            panic!("the later loss's write did not wait for its reconnect: {answered:?}");
        }
        let mut next_host = install_replacement(pty);
        writing.join().unwrap().expect("the write after the second reconnect");
        let written =
            input_payloads(&frames_until_quiet(&mut next_host, Duration::from_millis(300)));
        assert_eq!(written, vec![b"2".to_vec()], "the write reached the next replacement once");
    });
}

/// While the port's writer waits for a reconnect, a frame another writer sends under the runtime lock does not wait
/// for it: the connection that frame goes to is gone, and the replacement the port waits for is installed under the
/// lock that writer holds (S1.6b; a regression stalls every such frame for the order wait during a reconnect).
#[cfg(unix)]
#[test]
fn a_frame_sent_while_the_port_waits_for_a_reconnect_does_not_wait_for_it() {
    let (_mux, surface, _host) = hosted_typing_surface("hosted-input-port-reconnect-skip");
    let pty = surface.as_pty().expect("a terminal");
    pty.input_route.store(Some(Arc::new(dead_host_route())));
    surface.write_bytes_replying(b"k", InputReply::Accepted).expect("the port took the key");
    wait_until("the port's writer waits for a reconnect", || {
        pty.input_port.reconnecting_for_test()
    });
    let runtime = pty.runtime.lock().unwrap();
    let PtyRuntime::Hosted(attachment) = &*runtime else {
        panic!("the fixture's terminal is hosted");
    };
    let started = Instant::now();
    let _ = attachment.send(MessageKind::Activate, &[]);
    let took = started.elapsed();
    assert!(
        took < Duration::from_millis(500),
        "a frame under the runtime lock waited {took:?} for a port that waits for a reconnect"
    );
}

/// Writes queued behind a lost host that does not come back fail together, one reconnect wait after they were sent,
/// not one wait after another.
#[cfg(unix)]
#[test]
fn writes_queued_behind_a_lost_host_fail_together() {
    let (_mux, surface, _host) = hosted_typing_surface("hosted-input-port-fail-together");
    let pty = surface.as_pty().expect("a terminal");
    let wait = Duration::from_millis(300);
    pty.input_port.set_reconnect_wait_for_test(wait);
    pty.input_route.store(Some(Arc::new(dead_host_route())));
    let target: &Surface = &surface;
    let started = Instant::now();
    std::thread::scope(|scope| {
        let writes: Vec<_> = (0..5u8)
            .map(|index| scope.spawn(move || target.write_bytes(&[b'0' + index])))
            .collect();
        for write in writes {
            write
                .join()
                .unwrap()
                .expect_err("a write to a lost host that never came back answered ok");
        }
    });
    let took = started.elapsed();
    assert!(
        took < wait * 3,
        "5 writes behind a lost host took {took:?} with a reconnect wait of {wait:?}"
    );
}

/// Receipted input (the `terminal.input.*` operations' path) sent after a key the input port holds reaches the host
/// after that key (S1.6b: every direct writer of the connection, not only `HostAttachment::send`).
#[cfg(unix)]
#[test]
fn receipted_input_sent_after_a_key_the_port_holds_reaches_the_host_after_it() {
    let (_mux, surface, mut host) = hosted_typing_surface("hosted-input-port-receipted-order");
    let pty = surface.as_pty().expect("a terminal");
    // The key must be a frame the port's writer holds: no inline write.
    pty.input_port.queue_every_write_for_test();
    let resume = pty.input_port.pause_writes_for_test();
    surface.write_bytes_replying(b"k", InputReply::Accepted).expect("the port took the key");
    std::thread::scope(|scope| {
        let receipted = scope.spawn(|| {
            let runtime = pty.runtime.lock().unwrap();
            let PtyRuntime::Hosted(attachment) = &*runtime else {
                panic!("the fixture's terminal is hosted");
            };
            attachment.begin_input_confirmed(b"r").map(|_| ()).map_err(|_| "not written")
        });
        std::thread::sleep(Duration::from_millis(200));
        resume.send(()).expect("the port's writer waits");
        receipted.join().unwrap().expect("the receipted input was written");
    });
    drop(resume);
    let written = input_payloads(&frames_until_quiet(&mut host, Duration::from_millis(300)));
    assert_eq!(
        written,
        vec![b"k".to_vec(), b"r".to_vec()],
        "receipted input passed the key the port held"
    );
}

/// R-DAEMON-STATE S1.6b review 1 (item 6): a write whose wait for the port ends before the port's writer took its
/// frame is never written: its error says so, and nothing reaches the host later (the creating-input flush gives
/// such bytes back, so writing them too would type them twice).
#[cfg(unix)]
#[test]
fn a_write_whose_wait_ends_before_the_port_takes_it_is_never_written() {
    let (_mux, surface, mut host) = hosted_typing_surface("hosted-input-port-reply-timeout");
    let pty = surface.as_pty().expect("a terminal");
    // The key must be a frame the port's writer holds: no inline write.
    pty.input_port.queue_every_write_for_test();
    pty.input_port.set_reply_wait_for_test(Duration::from_millis(300));
    let resume = pty.input_port.pause_writes_for_test();
    // The writer holds a key at its pause; the write queues behind it.
    surface.write_bytes_replying(b"k", InputReply::Accepted).expect("the port took the key");
    wait_until("the writer took the key", || pty.input_port.queued_frames_for_test() == 0);
    let error =
        surface.write_bytes(b"x").expect_err("a write the port did not reach in time answered ok");
    assert_eq!(error.kind(), std::io::ErrorKind::TimedOut, "{error}");
    assert!(!input_may_be_written(&error), "a frame the port never took may be written: {error}");
    drop(resume);
    let written = input_payloads(&frames_until_quiet(&mut host, Duration::from_millis(500)));
    assert_eq!(
        written,
        vec![b"k".to_vec()],
        "a write that answered 'not written' reached the host"
    );
}

/// R-DAEMON-STATE S1.6b review 1 (item 6): a write whose wait ends while the port's writer is writing its frame says
/// that the bytes may still be written, so a caller that gives input back keeps these.
#[cfg(unix)]
#[test]
fn a_write_whose_wait_ends_during_its_write_may_be_written() {
    let (_mux, surface, mut host) = hosted_typing_surface("hosted-input-port-reply-in-flight");
    let pty = surface.as_pty().expect("a terminal");
    let resume = running_paused_writer(&surface, pty);
    // The running writer takes "y" at once and holds it at its pause; the wait ends long after that.
    pty.input_port.set_reply_wait_for_test(Duration::from_secs(2));
    let error = surface.write_bytes(b"y").expect_err("a write still being written answered ok");
    assert!(
        input_may_be_written(&error),
        "a frame the port was writing was 'not written': {error}"
    );
    drop(resume);
    let written = input_payloads(&frames_until_quiet(&mut host, Duration::from_millis(500)));
    assert_eq!(
        written,
        vec![b"k".to_vec(), b"y".to_vec()],
        "the frame the port was writing reached the host"
    );
}

/// R-DAEMON-STATE S1.6b review 1 (item 6): the creating-input flush gives back the bytes it could not write, but not
/// bytes whose write may still reach the program; giving those back too types them twice.
#[cfg(unix)]
#[test]
fn the_creating_input_flush_keeps_input_that_may_have_been_written() {
    let (mux, surface, mut host) = hosted_typing_surface("hosted-input-port-creating-flush");
    let pty = surface.as_pty().expect("a terminal");
    let terminal_id = surface.terminal_host_identity().expect("a hosted terminal").terminal_id;
    let generation =
        mux.begin_creating_input(&terminal_id).expect("no live terminal has the id yet");
    let given_back = Arc::new(Mutex::new(Vec::new()));
    for bytes in [&b"a"[..], &b"b"[..]] {
        let given_back = given_back.clone();
        let notice: crate::mux::creating_input::UnclaimedNotice =
            Arc::new(move |_terminal: &str, bytes: &[u8], _reason: &str| {
                given_back.lock().unwrap().extend_from_slice(bytes);
            });
        mux.write_terminal_input(&terminal_id, 7, bytes, false, notice)
            .expect("queued while creating");
    }
    mux.insert_surface_runtime_for_test(surface.clone());
    let resume = running_paused_writer(&surface, pty);
    pty.input_port.set_reply_wait_for_test(Duration::from_secs(2));
    // The flush writes "a"; the running writer takes it at once and holds it at its pause until the flush's wait
    // ends.
    mux.finish_creating_input(&terminal_id, generation, None);
    assert_eq!(
        given_back.lock().unwrap().as_slice(),
        b"b",
        "the flush gave back input whose write may still reach the program"
    );
    drop(resume);
    let written = input_payloads(&frames_until_quiet(&mut host, Duration::from_millis(500)));
    assert_eq!(
        written,
        vec![b"k".to_vec(), b"a".to_vec()],
        "the input the flush kept reached the host once"
    );
}

/// R-DAEMON-STATE S1.6c (#35082 review 2, should-do 1): a write that waits out a lost host connection fails as soon
/// as the reader gives that host up (the link is `Failed` and nothing will install a replacement), not at its own
/// reconnect deadline. The reader's wake reached only `stream_progress`, which the
/// port's writer no longer waits on.
#[cfg(unix)]
#[test]
fn a_write_waiting_for_a_reconnect_fails_when_the_reader_gives_up() {
    let (_mux, surface, _host) = hosted_typing_surface("hosted-input-port-give-up");
    let pty = surface.as_pty().expect("a terminal");
    pty.input_port.set_reconnect_wait_for_test(Duration::from_secs(5));
    pty.input_route.store(Some(Arc::new(dead_host_route())));
    std::thread::scope(|scope| {
        let writing = scope.spawn(|| {
            let started = Instant::now();
            (surface.write_bytes(b"g"), started.elapsed())
        });
        wait_until("the write waits for a reconnect", || pty.input_port.reconnecting_for_test());
        // The reader gives the host up, as `wait_or_fail` does at the end of its budget.
        pty.host_connection_state
            .store(TerminalHostConnectionState::Failed as u8, Ordering::Release);
        pty.reader_gave_up();
        let (written, took) = writing.join().unwrap();
        written.expect_err("a write to a host the reader gave up on answered ok");
        assert!(
            took < Duration::from_secs(2),
            "a write to a host the reader gave up on waited {took:?}, its reconnect deadline, not the give-up"
        );
    });
}

/// R-DAEMON-STATE S1.6c (#35082 review 1, item 4): a viewer size sent while the input port holds the person's key
/// (a key that moved the grid sends it under the sizing lock, on the key's own turn) does not wait for the port: it
/// goes on the port behind the key. Before, it waited in the order barrier for up to 2 s, then went first.
#[cfg(unix)]
#[test]
fn a_viewer_size_behind_a_key_the_port_holds_goes_after_it_without_waiting() {
    let (_mux, surface, mut host) = hosted_typing_surface("hosted-input-port-viewer-size");
    let pty = surface.as_pty().expect("a terminal");
    // The key must be a frame the port's writer holds: no inline write.
    pty.input_port.queue_every_write_for_test();
    let resume = pty.input_port.pause_writes_for_test();
    surface.write_bytes_replying(b"k", InputReply::Accepted).expect("the port took the key");
    wait_until("the writer took the key", || pty.input_port.queued_frames_for_test() == 0);
    let started = Instant::now();
    surface.resize(97, 31).expect("the viewer size was sent");
    let took = started.elapsed();
    drop(resume);
    let kinds: Vec<_> = frames_until_quiet(&mut host, Duration::from_millis(500))
        .into_iter()
        .map(|frame| frame.kind)
        .collect();
    assert!(
        took < Duration::from_millis(500),
        "a viewer size waited {took:?} for the key the port held (it runs under the sizing lock on a key's turn)"
    );
    let key_at = kinds.iter().position(|kind| *kind == MessageKind::Input);
    let size_at = kinds.iter().position(|kind| *kind == MessageKind::ViewerSize);
    assert!(
        matches!((key_at, size_at), (Some(key), Some(size)) if key < size),
        "the viewer size did not reach the host after the key the port held: {kinds:?}"
    );
}

/// R-DAEMON-STATE S1.6c (#35082 review 2, should-do 2): an attach that settles the host's viewer size gives up at its
/// own deadline, not the order barrier's 2 s, when the input port holds a frame.
#[cfg(unix)]
#[test]
fn a_viewer_size_settle_ends_by_its_own_deadline_behind_a_held_frame() {
    let (_mux, surface, _host) =
        hosted_surface_with("hosted-input-port-settle-deadline", |attachment| {
            attachment.viewer_size_acks = true;
        });
    let pty = surface.as_pty().expect("a terminal");
    // The key must be a frame the port's writer holds: no inline write.
    pty.input_port.queue_every_write_for_test();
    surface.resize(97, 31).expect("the first viewer size was sent");
    let resume = pty.input_port.pause_writes_for_test();
    surface.write_bytes_replying(b"k", InputReply::Accepted).expect("the port took the key");
    wait_until("the writer took the key", || pty.input_port.queued_frames_for_test() == 0);
    let started = Instant::now();
    let settled = surface.settle_hosted_viewer_size(Instant::now() + Duration::from_millis(200));
    let took = started.elapsed();
    drop(resume);
    assert!(!settled, "the fake host acknowledges nothing, so the size cannot settle");
    assert!(
        took < Duration::from_millis(900),
        "an attach with a 200 ms deadline waited {took:?} for the input port's held frame"
    );
}

/// R-DAEMON-STATE S1.6d (#35413 review; DESIGN 2.6.1): the input port's writer carries the person's keys from the
/// daemon to the host, so once it takes one it runs at user-interactive QoS, as the connection threads that carried
/// the key do (server/input_qos.rs, TYPING FIX 2 F7). Under full CPU a default-QoS thread waits for a CPU. A port
/// that only automation writes to (a `Written` write: a script's `cmux send`) keeps the default QoS.
#[cfg(target_os = "macos")]
#[test]
fn the_input_ports_writer_runs_at_user_interactive_qos_once_it_carries_a_persons_key() {
    let (_mux, surface, _host) = hosted_typing_surface("hosted-input-port-writer-qos");
    let pty = surface.as_pty().expect("a terminal");
    // The key must be a frame the port's writer holds: no inline write.
    pty.input_port.queue_every_write_for_test();
    let interactive = libc::qos_class_t::QOS_CLASS_USER_INTERACTIVE as u32;
    surface.write_bytes(b"a").expect("automation's write was written");
    let automation = pty.input_port.writer_qos_for_test();
    assert!(automation.is_some(), "the writer recorded no QoS for automation's write");
    assert_ne!(
        automation,
        Some(interactive),
        "automation's write ran the writer at user-interactive QoS"
    );
    surface.write_bytes_replying(b"k", InputReply::Accepted).expect("the port took the key");
    wait_until("the writer took the key", || pty.input_port.queued_frames_for_test() == 0);
    surface.write_bytes(b"b").expect("the next write was written");
    assert_eq!(
        pty.input_port.writer_qos_for_test(),
        Some(interactive),
        "the writer that carried the person's key does not run at user-interactive QoS"
    );
}

/// A viewer size of 97x31 queued on the input port behind a key its writer took, and then that writer waiting for a
/// reconnect (the route it writes on is dead).
#[cfg(unix)]
fn a_size_queued_then_a_reconnect_wait(surface: &Surface, pty: &PtySurface) {
    // The key must be a frame the port's writer holds: no inline write.
    pty.input_port.queue_every_write_for_test();
    let resume = pty.input_port.pause_writes_for_test();
    surface.write_bytes_replying(b"k", InputReply::Accepted).expect("the port took the key");
    wait_until("the writer took the key", || pty.input_port.queued_frames_for_test() == 0);
    surface.resize(97, 31).expect("the first viewer size was sent");
    assert_eq!(
        pty.input_port.queued_frames_for_test(),
        1,
        "the first viewer size waits on the port behind the key"
    );
    pty.input_route.store(Some(Arc::new(dead_host_route())));
    drop(resume);
    wait_until("the port's writer waits for a reconnect", || {
        pty.input_port.reconnecting_for_test()
    });
}

/// The size frames `host` reads until it reads nothing for 500 ms: a `ViewerSize` as its columns and rows, a
/// `ReleaseViewer` as `None`.
#[cfg(unix)]
fn size_frames_until_quiet(host: &mut std::os::unix::net::UnixStream) -> Vec<Option<(u16, u16)>> {
    frames_until_quiet(host, Duration::from_millis(500))
        .into_iter()
        .filter_map(|frame| match frame.kind {
            MessageKind::ViewerSize => {
                let [cols_low, cols_high, rows_low, rows_high]: [u8; 4] =
                    frame.payload.as_slice().try_into().expect("a viewer size is 4 bytes");
                Some(Some((
                    u16::from_le_bytes([cols_low, cols_high]),
                    u16::from_le_bytes([rows_low, rows_high]),
                )))
            }
            MessageKind::ReleaseViewer => Some(None),
            _ => None,
        })
        .collect()
}

/// R-DAEMON-STATE S1.6c (#35375 review): a viewer size sent while the input port waits for a reconnect goes on the
/// port too, in place of the size it queued before the loss, so the new connection's last size is the newest. Written
/// directly, it went to the lost connection, and the stale queued size reached the new host after the install: the
/// host kept 97x31 while the daemon's lease said 100x30, and a later send of 100x30 wrote nothing.
#[cfg(unix)]
#[test]
fn a_viewer_size_sent_during_a_reconnect_wait_is_the_new_hosts_last_size() {
    let (_mux, surface, _host) = hosted_typing_surface("hosted-input-port-size-reconnect");
    let pty = surface.as_pty().expect("a terminal");
    a_size_queued_then_a_reconnect_wait(&surface, pty);
    surface.resize(100, 30).expect("the newer viewer size was sent");
    let mut replacement_host = install_replacement(pty);
    let sizes = size_frames_until_quiet(&mut replacement_host);
    assert_eq!(
        sizes.last(),
        Some(&Some((100, 30))),
        "the new host's last viewer size is not the newest lease: {sizes:?}"
    );
}

/// The release form of the case above: a release during the reconnect wait must be the new host's last size frame,
/// or the host keeps a lease the daemon released (and a later release writes nothing).
#[cfg(unix)]
#[test]
fn a_viewer_size_release_during_a_reconnect_wait_is_the_new_hosts_last_size_frame() {
    let (_mux, surface, _host) = hosted_typing_surface("hosted-input-port-release-reconnect");
    let pty = surface.as_pty().expect("a terminal");
    a_size_queued_then_a_reconnect_wait(&surface, pty);
    surface.release_viewer_size().expect("the release was sent");
    let mut replacement_host = install_replacement(pty);
    let sizes = size_frames_until_quiet(&mut replacement_host);
    assert_eq!(
        sizes.last(),
        Some(&None),
        "the new host's last size frame is not the release: {sizes:?}"
    );
}

/// R-DAEMON-STATE S1.6c (#35082 review 2, should-do 3): a write whose frame the port's writer took and then lost (the
/// writer panicked during its write) may have reached the host, so its error says so, as a timeout during the write
/// does; the creating-input flush must not give those bytes back.
#[cfg(unix)]
#[test]
fn a_write_the_writer_lost_after_taking_it_may_be_written() {
    let (_mux, surface, _host) = hosted_typing_surface("hosted-input-port-writer-lost");
    let pty = surface.as_pty().expect("a terminal");
    pty.input_port.panic_after_take_for_test();
    let error = surface.write_bytes(b"w").expect_err("a write its writer lost answered ok");
    assert!(
        input_may_be_written(&error),
        "a frame the writer took and lost was reported as not written: {error}"
    );
}

/// A write waiting for a reconnect on the input port, from a thread; the test thread then ends the reconnect with
/// `end` and gets the write's result and how long it took.
#[cfg(unix)]
fn write_waiting_for_a_reconnect_then(
    name: &str,
    end: impl FnOnce(&Surface, &PtySurface),
) -> (std::io::Result<()>, Duration) {
    let (_mux, surface, _host) = hosted_typing_surface(name);
    let pty = surface.as_pty().expect("a terminal");
    pty.input_port.set_reconnect_wait_for_test(Duration::from_secs(5));
    pty.input_route.store(Some(Arc::new(dead_host_route())));
    std::thread::scope(|scope| {
        let writing = scope.spawn(|| {
            let started = Instant::now();
            (surface.write_bytes(b"g"), started.elapsed())
        });
        wait_until("the write waits for a reconnect", || pty.input_port.reconnecting_for_test());
        end(&surface, pty);
        writing.join().unwrap()
    })
}

/// #35280 review (should-do 1): the reader's real give-up (its backoff past the budget, `wait_or_fail`) ends the
/// port's reconnect wait, not only a hand call of `reader_gave_up`.
#[cfg(unix)]
#[test]
fn a_write_waiting_for_a_reconnect_fails_when_the_readers_backoff_gives_up() {
    let (written, took) =
        write_waiting_for_a_reconnect_then("hosted-input-port-backoff-gives-up", |_, pty| {
            let mut backoff = TerminalHostReconnectBackoff::default();
            while backoff.next_delay().is_some() {}
            assert!(!backoff.wait_or_fail(pty), "the exhausted backoff did not give the host up");
        });
    written.expect_err("a write to a host the reader gave up on answered ok");
    assert!(took < Duration::from_secs(2), "the write waited {took:?} after the reader gave up");
}

/// #35280 review (should-do 1): a daemon shutdown's detach (`disconnect_for_daemon_shutdown`) ends the port's
/// reconnect wait: the write fails now, not at its own deadline.
#[cfg(unix)]
#[test]
fn a_write_waiting_for_a_reconnect_fails_when_the_daemon_shuts_down() {
    let (written, took) =
        write_waiting_for_a_reconnect_then("hosted-input-port-shutdown-detach", |surface, _| {
            surface.disconnect_for_daemon_shutdown();
        });
    written.expect_err("a write to a terminal the daemon detached answered ok");
    assert!(took < Duration::from_secs(2), "the write waited {took:?} after the daemon's detach");
}
