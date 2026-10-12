//! Smart-renderer streams, host taps, parser budget, viewer-size priority, exit publication and pwd frames.

use super::*;

#[test]
fn admin_owner_can_negotiate_the_smart_renderer_stream() {
    let host = exited_host_fixture();
    let (server_stream, mut client_stream) = UnixStream::pair().unwrap();
    client_stream.set_read_timeout(Some(Duration::from_secs(1))).unwrap();
    let server_host = host.clone();
    let server = thread::spawn(move || serve_client(server_host, server_stream));

    let mut hello = snapshot_boundary_client_hello(&host, false).unwrap();
    hello.flags = FLAG_SMART_RENDERER | FLAG_VIEWER_SIZE_ACKS;
    write_frame(&mut client_stream, &hello).unwrap();

    let host_hello = read_required_frame(&mut client_stream, "host hello").unwrap();
    assert_eq!(host_hello.kind, MessageKind::HostHello);
    assert_eq!(host_hello.flags & FLAG_SMART_RENDERER, FLAG_SMART_RENDERER);
    assert_eq!(
        read_required_frame(&mut client_stream, "snapshot").unwrap().kind,
        MessageKind::Snapshot
    );
    assert_eq!(
        read_required_frame(&mut client_stream, "colors").unwrap().kind,
        MessageKind::Colors
    );
    assert_eq!(read_required_frame(&mut client_stream, "ready").unwrap().kind, MessageKind::Ready);

    for (kind, payload) in [
        (MessageKind::Output, vec![0xce]),
        (MessageKind::Resized, vec![100, 0, 30, 0]),
        (MessageKind::Output, vec![0xbb]),
    ] {
        let cursor = host.smart.publish(Frame::new(kind, payload.clone()));
        host.smart.mark_applied(cursor);
        let received = read_required_frame(&mut client_stream, "smart transition").unwrap();
        assert_eq!((received.kind, received.payload), (kind, payload));
    }

    let cursor = host.smart.publish(Frame::new(MessageKind::Exit, Vec::new()));
    host.smart.mark_applied(cursor);
    assert_eq!(read_required_frame(&mut client_stream, "exit").unwrap().kind, MessageKind::Exit);
    let _ = client_stream.shutdown(std::net::Shutdown::Both);
    server.join().unwrap().unwrap();
}

#[test]
fn protocol_one_smart_renderer_handshake_is_rejected() {
    let host = exited_host_fixture();
    let (server_stream, mut client_stream) = UnixStream::pair().unwrap();
    client_stream.set_read_timeout(Some(Duration::from_secs(1))).unwrap();
    let server_host = host.clone();
    let server = thread::spawn(move || serve_client(server_host, server_stream));

    let hello = ClientHello {
        min_version: LEGACY_PROTOCOL_VERSION,
        max_version: LEGACY_PROTOCOL_VERSION,
        role: ClientRole::Admin,
        requested_rights: CapabilityRights::ADMIN,
        terminal_id: host.terminal_id,
        token: host.owner_token,
    };
    let mut hello = hello.into_frame(1);
    hello.version = LEGACY_PROTOCOL_VERSION;
    hello.flags = FLAG_SMART_RENDERER | FLAG_VIEWER_SIZE_ACKS;
    write_frame(&mut client_stream, &hello).unwrap();

    assert!(read_required_frame(&mut client_stream, "host hello").is_err());
    assert!(server.join().unwrap().is_err());
}

#[test]
fn changing_defaults_forces_smart_renderers_to_a_fresh_snapshot() {
    let (host, parser_receiver) = exited_host_fixture_with_parser();
    let (host_socket, _client_socket) = UnixStream::pair().unwrap();
    let (sender, receiver) = mpsc_channel();
    host.smart
        .subscribe(
            7,
            HostTap {
                sender,
                queued_bytes: Arc::new(AtomicUsize::new(0)),
                queued_output_bytes: Arc::new(AtomicUsize::new(0)),
                shutdown: Arc::new(host_socket),
                max_queued_bytes: usize::MAX,
            },
        )
        .unwrap();

    let defaults = DefaultColors { fg: Some(Rgb { r: 1, g: 2, b: 3 }), ..Default::default() };
    let update_host = host.clone();
    let update = thread::spawn(move || update_host.set_default_colors(defaults));

    let resync = receiver.recv_timeout(Duration::from_secs(1)).unwrap();
    assert_eq!(resync.kind, MessageKind::ResyncRequired);
    assert!(
        host.smart.applied_cursor.load(Ordering::Acquire) < resync.sequence,
        "the snapshot boundary must not advance before the parser applies defaults"
    );
    let command = parser_receiver.recv_timeout(Duration::from_secs(1)).unwrap();
    let ParserCommand::SetDefaults { colors, source_cursor, response } = command else {
        panic!("defaults update queued a different parser command");
    };
    assert_eq!(source_cursor, resync.sequence);
    host.apply_parser_defaults(*colors, source_cursor);
    response.send(()).unwrap();
    update.join().unwrap();

    assert_eq!(host.smart.applied_cursor.load(Ordering::Acquire), resync.sequence);
    assert_eq!(*host.default_colors.lock().unwrap(), defaults);
}

#[test]
fn repeating_defaults_does_not_resync_smart_renderers() {
    let host = exited_host_fixture();
    let (host_socket, _client_socket) = UnixStream::pair().unwrap();
    let (sender, receiver) = mpsc_channel();
    host.smart
        .subscribe(
            7,
            HostTap {
                sender,
                queued_bytes: Arc::new(AtomicUsize::new(0)),
                queued_output_bytes: Arc::new(AtomicUsize::new(0)),
                shutdown: Arc::new(host_socket),
                max_queued_bytes: usize::MAX,
            },
        )
        .unwrap();

    host.set_default_colors(DefaultColors::default());

    assert!(matches!(
        receiver.recv_timeout(Duration::from_millis(50)),
        Err(RecvTimeoutError::Timeout)
    ));
    assert_eq!(host.smart.applied_cursor.load(Ordering::Acquire), 0);
}

#[test]
fn host_tap_byte_overflow_closes_the_client_socket() {
    let (host_socket, mut client_socket) = UnixStream::pair().unwrap();
    client_socket.set_read_timeout(Some(Duration::from_secs(1))).unwrap();
    let (sender, _receiver) = mpsc_channel();
    let one_frame = crate::terminal_host_protocol::HEADER_LEN + 4;
    let tap = HostTap::new(sender, Arc::new(host_socket), one_frame);

    assert!(tap.try_send(Frame::new(MessageKind::Output, vec![1; 4])));
    assert!(!tap.try_send(Frame::new(MessageKind::Output, vec![2])));
    let mut byte = [0u8; 1];
    assert_eq!(client_socket.read(&mut byte).unwrap(), 0);
}

#[test]
fn host_tap_snapshot_headroom_does_not_expand_live_output_budget() {
    let (host_socket, mut client_socket) = UnixStream::pair().unwrap();
    client_socket.set_read_timeout(Some(Duration::from_secs(1))).unwrap();
    let (sender, _receiver) = mpsc_channel();
    let tap = HostTap::new(sender, Arc::new(host_socket), MAX_HOST_CLIENT_QUEUED_BYTES);
    let half_output_budget = 4 * 1024 * 1024;

    assert!(tap.try_send(Frame::new(MessageKind::Output, vec![1; half_output_budget],)));
    assert!(!tap.try_send(Frame::new(MessageKind::Output, vec![2; half_output_budget],)));
    let mut byte = [0u8; 1];
    assert_eq!(client_socket.read(&mut byte).unwrap(), 0);
}

#[test]
fn host_tap_disconnected_channel_closes_the_client_socket() {
    let (host_socket, mut client_socket) = UnixStream::pair().unwrap();
    client_socket.set_read_timeout(Some(Duration::from_secs(1))).unwrap();
    let (sender, receiver) = mpsc_channel();
    drop(receiver);
    let tap = HostTap::new(sender, Arc::new(host_socket), usize::MAX);

    assert!(!tap.try_send(Frame::new(MessageKind::Output, vec![1])));
    let mut byte = [0u8; 1];
    assert_eq!(client_socket.read(&mut byte).unwrap(), 0);
}

#[test]
fn smart_attach_replays_source_bytes_ahead_of_parser_boundary_exactly_once() {
    let state = SmartStreamState::new();
    let first = state.publish(Frame::new(MessageKind::Output, b"unparsed".to_vec()));
    assert_eq!(first, 1);
    assert_eq!(state.applied_cursor.load(Ordering::Acquire), 0);

    let (host_socket, _client_socket) = UnixStream::pair().unwrap();
    let (sender, receiver) = mpsc_channel();
    let tap = HostTap {
        sender,
        queued_bytes: Arc::new(AtomicUsize::new(0)),
        queued_output_bytes: Arc::new(AtomicUsize::new(0)),
        shutdown: Arc::new(host_socket),
        max_queued_bytes: usize::MAX,
    };
    let boundary = state.subscribe(7, tap).unwrap();
    assert_eq!(boundary, 0);
    let replayed = receiver.recv().unwrap();
    assert_eq!((replayed.sequence, replayed.payload), (1, b"unparsed".to_vec()));

    state.mark_applied(first);
    state.publish(Frame::new(MessageKind::Output, b"live".to_vec()));
    let live = receiver.recv().unwrap();
    assert_eq!((live.sequence, live.payload), (2, b"live".to_vec()));
    assert!(receiver.try_recv().is_err(), "attach duplicated a retained frame");
}

#[test]
fn smart_attach_cannot_miss_exit_between_dead_check_and_subscribe() {
    let host = exited_host_fixture();
    let exit_record_path = host.exit_record_path.clone();
    let exit_record_root = exit_record_path.parent().unwrap().to_path_buf();
    let exit_host = host.clone();
    let term = host.term.lock().unwrap();
    let smart_publication = host.smart.broadcast_lock.lock().unwrap();
    assert!(!host.dead.load(Ordering::Acquire));

    let (started_tx, started_rx) = std::sync::mpsc::channel();
    let exit = thread::spawn(move || {
        started_tx.send(()).unwrap();
        exit_host.persist_and_publish_exit_if_drained().unwrap();
    });
    started_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        match host.source_order_lock.try_lock() {
            Ok(source_order) => {
                drop(source_order);
                assert!(Instant::now() < deadline, "Exit did not reach publication");
                thread::yield_now();
            }
            Err(TryLockError::WouldBlock) => break,
            Err(TryLockError::Poisoned(error)) => panic!("{error}"),
        }
    }
    // Once Exit owns source ordering, the old implementation is
    // runnable and only a few uncontended operations from `dead =
    // true`. Give it a generous scheduling window so this regression
    // cannot pass merely because that thread was preempted after the
    // lock probe. The fixed implementation remains blocked on `term`.
    let transition_deadline = Instant::now() + Duration::from_secs(1);
    while !host.dead.load(Ordering::Acquire) && Instant::now() < transition_deadline {
        thread::sleep(Duration::from_millis(1));
    }
    assert!(
        !host.dead.load(Ordering::Acquire),
        "Exit bypassed the terminal snapshot lock after the attach dead check"
    );

    drop(smart_publication);
    let (host_socket, _client_socket) = UnixStream::pair().unwrap();
    let (sender, receiver) = mpsc_channel();
    let tap = HostTap {
        sender,
        queued_bytes: Arc::new(AtomicUsize::new(0)),
        queued_output_bytes: Arc::new(AtomicUsize::new(0)),
        shutdown: Arc::new(host_socket),
        max_queued_bytes: usize::MAX,
    };
    assert_eq!(host.smart.subscribe(7, tap).unwrap(), 0);
    drop(term);
    exit.join().unwrap();

    assert!(host.dead.load(Ordering::Acquire));
    assert_eq!(host.smart.applied_cursor.load(Ordering::Acquire), 1);
    let exit = receiver.recv().unwrap();
    assert_eq!((exit.kind, exit.sequence), (MessageKind::Exit, 1));
    assert!(receiver.try_recv().is_err(), "attach received Exit more than once");
    fs::remove_file(exit_record_path).unwrap();
    let _ = fs::remove_dir(exit_record_root);
}

#[test]
fn smart_attach_reports_retention_gap_instead_of_silent_corruption() {
    let state = SmartStreamState::new();
    for byte in 0..=MAX_SMART_RETAINED_FRAMES {
        state.publish(Frame::new(MessageKind::Output, vec![byte as u8]));
    }
    let (host_socket, _client_socket) = UnixStream::pair().unwrap();
    let (sender, _receiver) = mpsc_channel();
    let tap = HostTap {
        sender,
        queued_bytes: Arc::new(AtomicUsize::new(0)),
        queued_output_bytes: Arc::new(AtomicUsize::new(0)),
        shutdown: Arc::new(host_socket),
        max_queued_bytes: usize::MAX,
    };
    let gap = state.subscribe(9, tap).unwrap_err();
    assert_eq!(gap, SmartReplayGap::Retention { requested_after: 0, retained_after: 1 });
    assert!(state.is_empty(), "a gapped renderer must not join the live tap set");
}

#[test]
fn smart_attach_distinguishes_subscriber_queue_overflow() {
    let state = SmartStreamState::new();
    let cursor = state.publish(Frame::new(MessageKind::Output, vec![1]));
    state.mark_applied(0);
    let (host_socket, _client_socket) = UnixStream::pair().unwrap();
    let (sender, _receiver) = mpsc_channel();
    let tap = HostTap {
        sender,
        queued_bytes: Arc::new(AtomicUsize::new(0)),
        queued_output_bytes: Arc::new(AtomicUsize::new(0)),
        shutdown: Arc::new(host_socket),
        max_queued_bytes: 0,
    };

    let gap = state.subscribe(10, tap).unwrap_err();

    assert_eq!(cursor, 1);
    assert_eq!(gap, SmartReplayGap::SubscriberQueueOverflow { boundary: 0 });
    assert_eq!(gap.encode()[16], 1);
    assert!(state.is_empty(), "an overflowing renderer must not join the live tap set");
}

#[test]
fn smart_noisy_neighbor_is_evicted_without_stalling_other_renderers() {
    let state = SmartStreamState::new();
    let tap = |capacity| {
        let (host_socket, _client_socket) = UnixStream::pair().unwrap();
        let (sender, receiver) = mpsc_channel();
        (
            HostTap {
                sender,
                queued_bytes: Arc::new(AtomicUsize::new(0)),
                queued_output_bytes: Arc::new(AtomicUsize::new(0)),
                shutdown: Arc::new(host_socket),
                max_queued_bytes: capacity * (crate::terminal_host_protocol::HEADER_LEN + 1),
            },
            receiver,
        )
    };
    let (slow, _slow_receiver) = tap(1);
    let (fast, fast_receiver) = tap(4);
    state.subscribe(1, slow).unwrap();
    state.subscribe(2, fast).unwrap();

    state.publish(Frame::new(MessageKind::Output, vec![1]));
    state.publish(Frame::new(MessageKind::Output, vec![2]));

    assert_eq!(fast_receiver.recv().unwrap().payload, vec![1]);
    assert_eq!(fast_receiver.recv().unwrap().payload, vec![2]);
    assert_eq!(state.taps.lock().unwrap().len(), 1);
}

#[test]
fn smart_failed_transition_is_closed_by_applied_resync_boundary() {
    let state = SmartStreamState::new();
    let (host_socket, _client_socket) = UnixStream::pair().unwrap();
    let (sender, receiver) = mpsc_channel();
    let tap = HostTap {
        sender,
        queued_bytes: Arc::new(AtomicUsize::new(0)),
        queued_output_bytes: Arc::new(AtomicUsize::new(0)),
        shutdown: Arc::new(host_socket),
        max_queued_bytes: usize::MAX,
    };
    state.subscribe(1, tap).unwrap();

    let failed = state.publish(Frame::new(MessageKind::Resized, vec![80, 0, 24, 0]));
    state.close_failed_transition(Some(failed));

    assert_eq!(receiver.recv().unwrap().kind, MessageKind::Resized);
    let resync = receiver.recv().unwrap();
    assert_eq!(resync.kind, MessageKind::ResyncRequired);
    assert_eq!(resync.sequence, failed + 1);
    assert_eq!(state.applied_cursor.load(Ordering::Acquire), resync.sequence);
}

#[test]
fn parser_output_send_failure_closes_published_transition() {
    let state = SmartStreamState::new();
    let (host_socket, _client_socket) = UnixStream::pair().unwrap();
    let (tap_sender, tap_receiver) = mpsc_channel();
    state
        .subscribe(
            1,
            HostTap {
                sender: tap_sender,
                queued_bytes: Arc::new(AtomicUsize::new(0)),
                queued_output_bytes: Arc::new(AtomicUsize::new(0)),
                shutdown: Arc::new(host_socket),
                max_queued_bytes: usize::MAX,
            },
        )
        .unwrap();

    let failed = state.publish(Frame::new(MessageKind::Output, vec![1, 2, 3]));
    let budget = ParserBudget::new(3);
    budget.reserve(3);
    let (parser_sender, parser_receiver) = sync_channel(1);
    drop(parser_receiver);

    assert!(!enqueue_parser_output(&parser_sender, &budget, &state, vec![1, 2, 3], failed, 3,));

    assert_eq!(*budget.queued_bytes.lock().unwrap(), 0);
    assert_eq!(tap_receiver.recv().unwrap().kind, MessageKind::Output);
    let resync = tap_receiver.recv().unwrap();
    assert_eq!(resync.kind, MessageKind::ResyncRequired);
    assert_eq!(resync.sequence, failed + 1);
    assert_eq!(state.applied_cursor.load(Ordering::Acquire), resync.sequence);
}

#[test]
fn parser_budget_blocks_at_saturation_and_unblocks_after_release() {
    let budget = Arc::new(ParserBudget::new(4));
    budget.reserve(4);
    let (reserved, observed) = std::sync::mpsc::channel();
    let waiter = {
        let budget = budget.clone();
        thread::spawn(move || {
            budget.reserve(1);
            reserved.send(()).unwrap();
            budget.release(1);
        })
    };

    assert!(
        observed.recv_timeout(Duration::from_millis(30)).is_err(),
        "a saturated parser budget admitted another source chunk"
    );
    budget.release(4);
    observed.recv_timeout(Duration::from_secs(1)).unwrap();
    waiter.join().unwrap();
    assert_eq!(*budget.queued_bytes.lock().unwrap(), 0);
}

#[test]
fn viewer_resize_apply_order_cannot_invert_reduced_sizes() {
    let viewer_sizes = Arc::new(Mutex::new(ViewerSizes::default()));
    let applied = Arc::new(Mutex::new(Vec::new()));
    let (first_applying_tx, first_applying_rx) = std::sync::mpsc::channel();
    let (release_first_tx, release_first_rx) = std::sync::mpsc::channel();

    let first = {
        let viewer_sizes = viewer_sizes.clone();
        let applied = applied.clone();
        thread::spawn(move || {
            mutate_viewer_sizes(
                &viewer_sizes,
                |set| {
                    set.sizes.insert(1, (120, 40));
                },
                |desired| {
                    first_applying_tx.send(()).unwrap();
                    release_first_rx.recv().unwrap();
                    applied.lock().unwrap().push(desired.unwrap());
                    Ok(())
                },
            )
            .unwrap();
        })
    };
    first_applying_rx.recv().unwrap();

    let (second_attempting_tx, second_attempting_rx) = std::sync::mpsc::channel();
    let (second_mutating_tx, second_mutating_rx) = std::sync::mpsc::channel();
    let second = {
        let viewer_sizes = viewer_sizes.clone();
        let applied = applied.clone();
        thread::spawn(move || {
            second_attempting_tx.send(()).unwrap();
            mutate_viewer_sizes(
                &viewer_sizes,
                |set| {
                    second_mutating_tx.send(()).unwrap();
                    set.sizes.insert(2, (80, 24));
                },
                |desired| {
                    applied.lock().unwrap().push(desired.unwrap());
                    Ok(())
                },
            )
            .unwrap();
        })
    };
    second_attempting_rx.recv().unwrap();
    assert!(second_mutating_rx.try_recv().is_err());
    release_first_tx.send(()).unwrap();
    first.join().unwrap();
    second.join().unwrap();

    assert_eq!(*applied.lock().unwrap(), vec![(120, 40), (80, 24)]);
    assert_eq!(
        viewer_sizes
            .lock()
            .unwrap()
            .sizes
            .values()
            .copied()
            .reduce(|left, right| (left.0.min(right.0), left.1.min(right.1))),
        Some((80, 24))
    );
}

fn apply_viewer_mutation(
    viewers: &Mutex<ViewerSizes>,
    mutation: impl FnOnce(&mut ViewerSizes),
) -> Option<(u16, u16)> {
    let mut applied = None;
    mutate_viewer_sizes(viewers, mutation, |desired| {
        applied = desired;
        Ok(())
    })
    .unwrap();
    applied
}

#[test]
fn viewer_size_priority_absent_keeps_the_per_dimension_minimum() {
    let viewers = Mutex::new(ViewerSizes::default());
    let desired = apply_viewer_mutation(&viewers, |set| {
        set.sizes.insert(1, (80, 24));
        set.sizes.insert(2, (120, 20));
    });
    assert_eq!(desired, Some((80, 20)));
}

#[test]
fn viewer_size_priority_larger_preferred_viewer_wins_until_it_releases_or_leaves() {
    let viewers = Mutex::new(ViewerSizes::default());
    let desired = apply_viewer_mutation(&viewers, |set| {
        set.sizes.insert(1, (80, 24));
    });
    assert_eq!(desired, Some((80, 24)));

    let desired = apply_viewer_mutation(&viewers, |set| {
        set.sizes.insert(2, (120, 40));
        set.preferred.insert(2);
    });
    assert_eq!(desired, Some((120, 40)));

    // A smaller legacy report no longer reduces the grid.
    let desired = apply_viewer_mutation(&viewers, |set| {
        set.sizes.insert(1, (60, 20));
    });
    assert_eq!(desired, Some((120, 40)));

    let desired = apply_viewer_mutation(&viewers, |set| set.release(2));
    assert_eq!(desired, Some((60, 20)));

    // Priority belongs to the connection, so a later report regains it.
    let desired = apply_viewer_mutation(&viewers, |set| {
        set.sizes.insert(2, (100, 30));
    });
    assert_eq!(desired, Some((100, 30)));

    let desired = apply_viewer_mutation(&viewers, |set| set.remove_client(2));
    assert_eq!(desired, Some((60, 20)));
    let viewers = viewers.lock().unwrap();
    assert_eq!(viewers.sizes, HashMap::from([(1, (60, 20))]));
    assert!(viewers.preferred.is_empty());
}

#[test]
fn viewer_size_priority_reduces_only_among_preferred_viewers() {
    let viewers = Mutex::new(ViewerSizes::default());
    let desired = apply_viewer_mutation(&viewers, |set| {
        set.sizes.insert(1, (40, 10));
        set.sizes.insert(2, (120, 40));
        set.sizes.insert(3, (100, 50));
        set.preferred.extend([2, 3]);
    });
    assert_eq!(desired, Some((100, 40)));

    let desired = apply_viewer_mutation(&viewers, |set| set.remove_client(2));
    assert_eq!(desired, Some((100, 50)));

    let desired = apply_viewer_mutation(&viewers, |set| set.release(3));
    assert_eq!(desired, Some((40, 10)));

    let desired = apply_viewer_mutation(&viewers, |set| set.remove_client(1));
    assert_eq!(desired, None);
}

#[test]
fn viewer_size_priority_failed_apply_rolls_back_preferred_membership() {
    let viewers = Mutex::new(ViewerSizes::default());
    viewers.lock().unwrap().sizes.insert(1, (80, 24));
    let before = viewers.lock().unwrap().clone();
    let error = mutate_viewer_sizes(
        &viewers,
        |set| {
            set.sizes.insert(2, (120, 40));
            set.preferred.insert(2);
        },
        |desired| {
            assert_eq!(desired, Some((120, 40)));
            anyhow::bail!("injected PTY resize failure")
        },
    )
    .unwrap_err();
    assert!(error.to_string().contains("injected PTY"));
    assert_eq!(*viewers.lock().unwrap(), before);
}

#[test]
fn viewer_size_priority_is_negotiated_only_for_resizing_renderers() {
    let preferred = FLAG_VIEWER_SIZE_ACKS | FLAG_VIEWER_SIZE_PRIORITY;
    let legacy = FLAG_VIEWER_SIZE_ACKS;
    let ttl = Duration::from_secs(1);
    for (role, rights, flags, reserved, negotiated) in [
        (ClientRole::Renderer, CapabilityRights::RENDERER, preferred, true, true),
        (ClientRole::Renderer, CapabilityRights::RENDERER, legacy, true, false),
        (ClientRole::Renderer, CapabilityRights::READ, preferred, false, false),
        (ClientRole::Admin, CapabilityRights::ADMIN, preferred, false, false),
    ] {
        let host = exited_host_fixture();
        let token = if role == ClientRole::Admin {
            host.owner_token
        } else {
            host.capabilities.mint(host.terminal_id, rights, ttl).unwrap()
        };
        let mut hello = ClientHello {
            min_version: PROTOCOL_VERSION,
            max_version: PROTOCOL_VERSION,
            role,
            requested_rights: rights,
            terminal_id: host.terminal_id,
            token,
        }
        .into_frame(1);
        hello.flags = flags;
        let (server_stream, mut client_stream) = UnixStream::pair().unwrap();
        client_stream.set_read_timeout(Some(ttl)).unwrap();
        let server_host = host.clone();
        let server = thread::spawn(move || {
            serve_client_with_snapshot_timeout(server_host, server_stream, ttl)
        });

        write_frame(&mut client_stream, &hello).unwrap();
        let host_hello = read_required_frame(&mut client_stream, "host hello").unwrap();
        assert_eq!(host_hello.kind, MessageKind::HostHello);
        assert_eq!(
            host_hello.flags & FLAG_VIEWER_SIZE_PRIORITY != 0,
            negotiated,
            "{role:?} {rights:?} flags {flags:#x}"
        );
        let snapshot = read_required_frame(&mut client_stream, "snapshot").unwrap();
        assert_eq!(snapshot.kind, MessageKind::Snapshot);
        let colors = read_required_frame(&mut client_stream, "colors").unwrap();
        assert_eq!(colors.kind, MessageKind::Colors);
        {
            let viewers = host.viewer_sizes.lock().unwrap();
            assert_eq!(viewers.sizes.get(&1).copied(), reserved.then_some((80, 24)));
            assert_eq!(viewers.preferred.contains(&1), negotiated);
        }

        let _ = client_stream.shutdown(std::net::Shutdown::Both);
        server.join().unwrap().unwrap();
        assert_eq!(*host.viewer_sizes.lock().unwrap(), ViewerSizes::default());
    }
}

#[test]
fn exit_waits_for_final_pty_output_in_either_completion_order() {
    for child_first in [false, true] {
        let (host_socket, _client_socket) = UnixStream::pair().unwrap();
        let (sender, receiver) = mpsc_channel();
        let tap = HostTap::new(sender, Arc::new(host_socket), usize::MAX);
        let broadcast_lock = Mutex::new(());
        let sequence = AtomicU64::new(0);
        let taps = Mutex::new(HashMap::from([(1, tap)]));
        let exit = TerminalExit {
            outcome: crate::terminal_host_protocol::TerminalExitOutcome::Exit { code: 17 },
            exited_at_ms: 1234,
        };
        let child_exited = Mutex::new(None);
        let pty_drained = AtomicBool::new(false);
        let exit_published = AtomicBool::new(false);

        if child_first {
            *child_exited.lock().unwrap() = Some(exit.clone());
            assert!(
                persist_and_claim_host_exit_after_drain(
                    &child_exited,
                    &pty_drained,
                    &exit_published,
                    |_| Ok(()),
                )
                .unwrap()
                .is_none()
            );
        }

        publish_host_frames(
            &broadcast_lock,
            &sequence,
            &taps,
            [Frame::new(MessageKind::Output, b"final-output".to_vec())],
        );
        pty_drained.store(true, Ordering::Release);

        if !child_first {
            assert!(
                persist_and_claim_host_exit_after_drain(
                    &child_exited,
                    &pty_drained,
                    &exit_published,
                    |_| Ok(()),
                )
                .unwrap()
                .is_none()
            );
            *child_exited.lock().unwrap() = Some(exit.clone());
        }
        let claimed = persist_and_claim_host_exit_after_drain(
            &child_exited,
            &pty_drained,
            &exit_published,
            |_| Ok(()),
        )
        .unwrap()
        .expect("drained exited child claims one Exit");
        assert_eq!(claimed, exit);
        publish_host_frames(
            &broadcast_lock,
            &sequence,
            &taps,
            [Frame::new(MessageKind::Exit, encode_terminal_exit(&claimed))],
        );
        assert!(
            persist_and_claim_host_exit_after_drain(
                &child_exited,
                &pty_drained,
                &exit_published,
                |_| Ok(()),
            )
            .unwrap()
            .is_none()
        );

        let frames = receiver.try_iter().collect::<Vec<_>>();
        assert_eq!(frames.len(), 2);
        assert_eq!(frames[0].kind, MessageKind::Output);
        assert_eq!(frames[0].payload, b"final-output");
        assert_eq!(frames[0].sequence, 1);
        assert_eq!(frames[1].kind, MessageKind::Exit);
        assert_eq!(frames[1].sequence, 2);
        assert_eq!(decode_terminal_exit(&frames[1].payload).unwrap(), exit);
    }
}

#[test]
fn exit_persistence_failure_does_not_claim_or_publish_status() {
    let exit = TerminalExit {
        outcome: crate::terminal_host_protocol::TerminalExitOutcome::Signal {
            signal: libc::SIGTERM,
            core_dumped: false,
        },
        exited_at_ms: 4567,
    };
    let child_exited = Mutex::new(Some(exit.clone()));
    let pty_drained = AtomicBool::new(true);
    let exit_published = AtomicBool::new(false);
    let failed = persist_and_claim_host_exit_after_drain(
        &child_exited,
        &pty_drained,
        &exit_published,
        |_| anyhow::bail!("injected sidecar fsync failure"),
    );
    assert!(failed.is_err());
    assert!(!exit_published.load(Ordering::Acquire));

    let claimed = persist_and_claim_host_exit_after_drain(
        &child_exited,
        &pty_drained,
        &exit_published,
        |_| Ok(()),
    )
    .unwrap();
    assert_eq!(claimed, Some(exit));
    assert!(exit_published.load(Ordering::Acquire));
    assert!(
        persist_and_claim_host_exit_after_drain(
            &child_exited,
            &pty_drained,
            &exit_published,
            |_| panic!("already-published exit must not persist twice"),
        )
        .unwrap()
        .is_none()
    );
}

#[test]
fn private_socket_terminal_host_endpoint_dir_refuses_a_symlink() {
    let root = std::env::temp_dir().join(format!(
        "cmux-host-endpoint-dir-{}-{}",
        std::process::id(),
        RECORD_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)
    ));
    let target = root.join("target");
    fs::create_dir_all(&target).unwrap();
    fs::set_permissions(&target, fs::Permissions::from_mode(0o755)).unwrap();
    let alias = root.join("alias");
    std::os::unix::fs::symlink(&target, &alias).unwrap();

    let refused = prepare_endpoint_dir(&alias);
    let target_mode = fs::metadata(&target).unwrap().permissions().mode() & 0o777;
    let owned = root.join("owned");
    let created = prepare_endpoint_dir(&owned);
    let owned_mode = fs::metadata(&owned).map(|metadata| metadata.mode() & 0o777);
    let _ = fs::remove_dir_all(&root);

    assert!(refused.is_err(), "a symlinked endpoint directory must be refused");
    assert_eq!(target_mode, 0o755, "the symlink target must stay untouched");
    created.unwrap();
    assert_eq!(owned_mode.unwrap(), 0o700);
}

#[test]
fn exit_persistence_failure_writes_a_private_bounded_retry_diagnostic() {
    let directory = std::env::temp_dir().join(format!(
        "cmux-host-exit-diagnostic-{}-{}",
        std::process::id(),
        RECORD_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)
    ));
    prepare_private_dir(&directory).unwrap();
    let exit_path = directory.join("terminal.exit");
    write_exit_persistence_diagnostic(
        &exit_path,
        3,
        &anyhow::anyhow!("injected persistence failure"),
    )
    .unwrap();
    let diagnostic = exit_persistence_diagnostic_path(&exit_path);
    let message = fs::read_to_string(&diagnostic).unwrap();
    assert!(message.contains("attempt 3"), "{message}");
    assert!(message.contains("injected persistence failure"), "{message}");
    assert_eq!(fs::metadata(&diagnostic).unwrap().permissions().mode() & 0o777, 0o600);

    let mut delay = HOST_EXIT_PERSIST_RETRY_MIN;
    for _ in 0..16 {
        delay = next_exit_persistence_retry_delay(delay);
    }
    assert_eq!(delay, HOST_EXIT_PERSIST_RETRY_MAX);

    clear_exit_persistence_diagnostic(&exit_path);
    assert!(!diagnostic.exists());
    fs::remove_dir(directory).unwrap();
}

#[test]
fn persistent_exit_record_failure_does_not_block_host_progress() {
    let blocking_parent = std::env::temp_dir().join(format!(
        "cmux-host-exit-failure-{}-{}",
        std::process::id(),
        RECORD_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)
    ));
    fs::write(&blocking_parent, b"not a directory").unwrap();
    let host = exited_host_fixture_at(blocking_parent.clone());
    let weak = Arc::downgrade(&host);
    let (returned_tx, returned_rx) = std::sync::mpsc::channel();
    let publisher = thread::spawn({
        let host = host.clone();
        move || {
            host.publish_exit_if_drained();
            returned_tx.send(()).unwrap();
        }
    });

    returned_rx
        .recv_timeout(Duration::from_millis(250))
        .expect("exit persistence blocked the host snapshot path");
    publisher.join().unwrap();
    drop(host);
    let deadline = Instant::now() + Duration::from_secs(1);
    while weak.upgrade().is_some() && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(10));
    }
    assert!(weak.upgrade().is_none(), "exit publisher retained the dropped host");
    fs::remove_file(blocking_parent).unwrap();
}

#[test]
fn forced_drain_waits_for_late_bytes_then_exits_with_writer_still_open() {
    let (mut pty_reader, mut retained_writer) = UnixStream::pair().unwrap();
    let (mut drain_waiter, mut drain_waker) = UnixStream::pair().unwrap();
    let force_drain = Arc::new(AtomicBool::new(false));
    let worker_force = force_drain.clone();
    let (written_tx, written_rx) = std::sync::mpsc::channel();
    let (release_tx, release_rx) = std::sync::mpsc::channel();
    let worker = thread::spawn(move || {
        worker_force.store(true, Ordering::Release);
        drain_waker.write_all(&[1]).unwrap();
        // Keep the ordering deterministic without depending on the
        // worker being rescheduled inside the 100 ms drain window.
        // The bytes are still written strictly after forced drain is
        // requested and its waiter is woken.
        retained_writer.write_all(b"late").unwrap();
        written_tx.send(()).unwrap();
        // Deliberately retain the write side beyond the forced drain
        // bound. The helper must not confuse an open writer with more
        // bytes becoming readable forever.
        release_rx.recv().unwrap();
    });

    let mut forced_at = None;
    assert!(
        wait_for_pty_readable_or_forced_drain(
            pty_reader.as_raw_fd(),
            &mut drain_waiter,
            &force_drain,
            &mut forced_at,
        )
        .unwrap()
    );
    let mut late = [0u8; 4];
    pty_reader.read_exact(&mut late).unwrap();
    assert_eq!(&late, b"late");
    written_rx.recv().unwrap();
    assert!(
        !wait_for_pty_readable_or_forced_drain(
            pty_reader.as_raw_fd(),
            &mut drain_waiter,
            &force_drain,
            &mut forced_at,
        )
        .unwrap()
    );

    release_tx.send(()).unwrap();
    worker.join().unwrap();
}

#[test]
fn coupled_color_frames_stay_adjacent_under_concurrent_exit_and_resize() {
    let (host_socket, _client_socket) = UnixStream::pair().unwrap();
    let (sender, receiver) = mpsc_channel();
    let tap = HostTap::new(sender, Arc::new(host_socket), usize::MAX);
    let broadcast_lock = Mutex::new(());
    let sequence = AtomicU64::new(0);
    let taps = Mutex::new(HashMap::from([(1, tap)]));
    let barrier = Arc::new(std::sync::Barrier::new(4));

    thread::scope(|scope| {
        let spawn = |frames| {
            let barrier = barrier.clone();
            let broadcast_lock = &broadcast_lock;
            let sequence = &sequence;
            let taps = &taps;
            scope.spawn(move || {
                barrier.wait();
                publish_host_frames(broadcast_lock, sequence, taps, frames);
            });
        };
        let paired = |kind, payload| {
            let mut first = Frame::new(kind, Vec::new());
            first.flags = FLAG_COLORS_FOLLOW;
            vec![first, Frame::new(MessageKind::Colors, payload)]
        };
        spawn(paired(MessageKind::Output, vec![1]));
        spawn(paired(MessageKind::Resized, vec![2]));
        spawn(vec![Frame::new(MessageKind::Exit, vec![])]);
        barrier.wait();
    });

    let frames = receiver.try_iter().collect::<Vec<_>>();
    assert_eq!(frames.len(), 5);
    assert_eq!(frames.iter().map(|frame| frame.sequence).collect::<Vec<_>>(), vec![1, 2, 3, 4, 5]);
    let output = frames.iter().position(|frame| frame.kind == MessageKind::Output).unwrap();
    assert_eq!(frames[output].flags, FLAG_COLORS_FOLLOW);
    assert_eq!(frames[output + 1].kind, MessageKind::Colors);
    assert_eq!(frames[output + 1].flags, 0);
    assert_eq!(frames[output + 1].payload, vec![1]);
    let resized = frames.iter().position(|frame| frame.kind == MessageKind::Resized).unwrap();
    assert_eq!(frames[resized].flags, FLAG_COLORS_FOLLOW);
    assert_eq!(frames[resized + 1].kind, MessageKind::Colors);
    assert_eq!(frames[resized + 1].flags, 0);
    assert_eq!(frames[resized + 1].payload, vec![2]);
}

#[test]
fn pwd_none_to_none_emits_nothing() {
    let mut last_pwd = None;

    assert!(changed_pwd_frame(&mut last_pwd, None).is_none());
    assert_eq!(last_pwd, None);
}

#[test]
fn pwd_changes_emit_once_and_duplicates_are_suppressed() {
    let mut last_pwd = None;

    let first = changed_pwd_frame(&mut last_pwd, Some("/one".into())).unwrap();
    assert_eq!(first.kind, MessageKind::Pwd);
    assert_eq!(first.payload, b"/one");
    assert!(changed_pwd_frame(&mut last_pwd, Some("/one".into())).is_none());

    let changed = changed_pwd_frame(&mut last_pwd, Some("/two".into())).unwrap();
    assert_eq!(changed.kind, MessageKind::Pwd);
    assert_eq!(changed.payload, b"/two");
    assert_eq!(last_pwd.as_deref(), Some("/two"));
}

#[test]
fn pwd_clear_emits_one_empty_payload() {
    let mut last_pwd = Some("/before-clear".into());

    let clear = changed_pwd_frame(&mut last_pwd, None).unwrap();
    assert_eq!(clear.kind, MessageKind::Pwd);
    assert!(clear.payload.is_empty());
    assert_eq!(last_pwd, None);
    assert!(changed_pwd_frame(&mut last_pwd, None).is_none());
}

#[test]
fn late_snapshot_prefers_current_terminal_pwd_then_spawn_fallback() {
    let mut term = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
    let owner_token = CapabilityToken::from_bytes([7; crate::terminal_host::CAPABILITY_TOKEN_LEN]);
    let marker = format!(
        "{}{}:/spawn",
        crate::platform::SNAPSHOT_SPAWN_CWD_PREFIX,
        encode_hex(owner_token.as_bytes())
    );
    assert_eq!(
        snapshot_cwd(&term, Some("/spawn"), &owner_token, PROTOCOL_VERSION),
        Some(marker.clone())
    );

    term.vt_write(b"\x1b]7;file:///live\x1b\\");
    assert_eq!(
        snapshot_cwd(&term, Some("/spawn"), &owner_token, PROTOCOL_VERSION),
        Some(marker.clone())
    );

    term.vt_write(b"\x1b]7;\x1b\\");
    assert_eq!(snapshot_cwd(&term, Some("/spawn"), &owner_token, PROTOCOL_VERSION), Some(marker));
    assert_eq!(snapshot_cwd(&term, Some("file:///spawn"), &owner_token, PROTOCOL_VERSION), None);
}

#[test]
fn snapshot_cwd_uses_legacy_path_for_old_and_unknown_protocols() {
    let term = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
    let owner_token = CapabilityToken::from_bytes([7; crate::terminal_host::CAPABILITY_TOKEN_LEN]);
    for protocol_version in [LEGACY_PROTOCOL_VERSION, PROTOCOL_VERSION + 1] {
        let snapshot = snapshot_cwd(&term, Some("/spawn"), &owner_token, protocol_version);
        assert_eq!(snapshot, Some("/spawn".into()));
        assert_eq!(
            crate::platform::snapshot_cwd_to_local_path(snapshot.as_deref().unwrap(), None),
            Some(PathBuf::from("/spawn"))
        );
    }
}

#[test]
fn pwd_change_stays_contiguous_with_its_output_boundary() {
    let (host_socket, _client_socket) = UnixStream::pair().unwrap();
    let (sender, receiver) = mpsc_channel();
    let tap = HostTap::new(sender, Arc::new(host_socket), usize::MAX);
    let broadcast_lock = Mutex::new(());
    let sequence = AtomicU64::new(0);
    let taps = Mutex::new(HashMap::from([(1, tap)]));
    let barrier = Arc::new(std::sync::Barrier::new(3));
    let mut last_pwd = None;
    let output = output_transition_frames(
        b"prompt".to_vec(),
        Some(vec![7]),
        changed_pwd_frame(&mut last_pwd, Some("/work".into())),
    );

    thread::scope(|scope| {
        let spawn = |frames| {
            let barrier = barrier.clone();
            let broadcast_lock = &broadcast_lock;
            let sequence = &sequence;
            let taps = &taps;
            scope.spawn(move || {
                barrier.wait();
                publish_host_frames(broadcast_lock, sequence, taps, frames);
            });
        };
        spawn(output);
        spawn(vec![Frame::new(MessageKind::Exit, Vec::new())]);
        barrier.wait();
    });

    let frames = receiver.try_iter().collect::<Vec<_>>();
    assert_eq!(frames.len(), 4);
    assert_eq!(frames.iter().map(|frame| frame.sequence).collect::<Vec<_>>(), vec![1, 2, 3, 4]);
    let output = frames.iter().position(|frame| frame.kind == MessageKind::Output).unwrap();
    assert_eq!(frames[output].flags, FLAG_COLORS_FOLLOW);
    assert_eq!(frames[output + 1].kind, MessageKind::Colors);
    assert_eq!(frames[output + 1].payload, vec![7]);
    assert_eq!(frames[output + 2].kind, MessageKind::Pwd);
    assert_eq!(frames[output + 2].payload, b"/work");
    assert_eq!(frames[output + 1].sequence, frames[output].sequence + 1);
    assert_eq!(frames[output + 2].sequence, frames[output].sequence + 2);
}
