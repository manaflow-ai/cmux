//! Receipted input, termination receipts, discovery and exit records, liveness leases, handshake bounds.

use super::*;
use crate::lock_rank::RankedMutex;

#[test]
fn receipted_input_never_reaches_a_legacy_host_without_ack_support() {
    let (record_path, mut record, lease) = record_fixture("input-ack-legacy");
    let root = record_path.parent().unwrap().to_path_buf();
    record.supports_input_ack = false;
    let (client, mut host) = UnixStream::pair().unwrap();
    host.set_read_timeout(Some(Duration::from_millis(20))).unwrap();
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
        control_responses: Arc::new(ControlResponses::new()),
        next_request: AtomicU64::new(2),
        viewer_size: RankedMutex::new(None),
        launch_process: None,
        launch_activation_pending: false,
        pty_custody: None,
    };

    let error = match attachment.begin_input_confirmed(b"must-not-send") {
        Ok(_) => panic!("legacy host accepted a receipted input request"),
        Err(ConfirmedInputFailure::Known(error)) => error,
        Err(ConfirmedInputFailure::Indeterminate(error)) => {
            panic!("legacy-host rejection became indeterminate: {error}")
        }
    };
    assert_eq!(error.kind(), std::io::ErrorKind::Unsupported);
    let mut byte = [0u8; 1];
    let read_error = host.read(&mut byte).unwrap_err();
    assert!(matches!(
        read_error.kind(),
        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
    ));

    drop(attachment);
    drop(lease);
    let _ = fs::remove_dir_all(root);
}

#[test]
fn receipted_input_rejects_lower_negotiated_protocols_before_sending() {
    for version in 1..4 {
        let (mut attachment, mut host) = input_ack_surface_fixture();
        attachment.protocol_version = version;
        host.set_nonblocking(true).unwrap();
        let result = attachment.begin_input_confirmed(b"must-not-send");
        let Err(ConfirmedInputFailure::Known(error)) = result else {
            panic!("protocol {version} must reject confirmed input before delivery");
        };
        assert_eq!(error.kind(), std::io::ErrorKind::Unsupported);
        assert_eq!(attachment.control_responses.pending_input_acks_for_test(), (0, 0));
        let mut byte = [0];
        assert_eq!(host.read(&mut byte).unwrap_err().kind(), std::io::ErrorKind::WouldBlock);
    }
}

#[test]
fn host_command_path_rejects_receipted_input_on_older_protocols() {
    assert!(!input_request_is_supported(PROTOCOL_VERSION - 1, 1));
    assert!(input_request_is_supported(PROTOCOL_VERSION - 1, 0));
    assert!(input_request_is_supported(PROTOCOL_VERSION, 1));
}

#[test]
fn receipted_input_distinguishes_oversize_from_full_window() {
    let (attachment, mut host) = input_ack_surface_fixture();
    host.set_nonblocking(true).unwrap();
    let oversized = vec![0; MAX_PENDING_INPUT_ACK_BYTES + 1];
    let Err(ConfirmedInputFailure::Known(error)) = attachment.begin_input_confirmed(&oversized)
    else {
        panic!("oversized input must fail before delivery");
    };
    assert_eq!(error.kind(), std::io::ErrorKind::InvalidInput);
    assert_eq!(attachment.control_responses.pending_input_acks_for_test(), (0, 0));
    assert!(attachment.control_responses.try_reserve_input_ack(MAX_PENDING_INPUT_ACK_BYTES));
    let result = attachment.begin_input_confirmed(b"x");
    attachment.control_responses.release_input_ack(MAX_PENDING_INPUT_ACK_BYTES);
    let Err(ConfirmedInputFailure::Known(error)) = result else {
        panic!("full receipt window must reject admission");
    };
    assert_eq!(error.kind(), std::io::ErrorKind::WouldBlock);
    assert_eq!(attachment.control_responses.pending_input_acks_for_test(), (0, 0));
    let mut byte = [0];
    assert_eq!(host.read(&mut byte).unwrap_err().kind(), std::io::ErrorKind::WouldBlock);
}

#[test]
fn receipted_input_timeout_can_abort_while_writer_mutex_is_held() {
    let (attachment, mut host) = input_ack_surface_fixture();
    host.set_read_timeout(Some(Duration::from_millis(250))).unwrap();
    let receipt = attachment.begin_input_confirmed(b"timeout").unwrap();
    let request = read_frame(&mut host, MAX_FRAME_PAYLOAD).unwrap().unwrap();
    assert_eq!(request.kind, MessageKind::Input);
    assert_ne!(request.request_id, 0);

    let writer_guard = attachment.writer.lock().unwrap();
    let (result_tx, result_rx) = sync_channel(1);
    let waiter = thread::spawn(move || {
        result_tx.send(receipt.wait_for(Duration::from_millis(20))).unwrap();
    });
    let error = result_rx
        .recv_timeout(Duration::from_millis(250))
        .expect("input ACK timeout blocked behind the socket writer mutex")
        .unwrap_err();
    assert_eq!(error.kind(), std::io::ErrorKind::TimedOut);
    assert!(
        read_frame(&mut host, MAX_FRAME_PAYLOAD).unwrap().is_none(),
        "timeout shutdown did not reach the peer while the socket writer mutex was held"
    );
    drop(writer_guard);
    waiter.join().unwrap();
}

#[test]
fn receipted_input_window_is_bounded() {
    let responses = ControlResponses::new();
    for _ in 0..MAX_PENDING_INPUT_ACKS {
        assert!(responses.try_reserve_input_ack(1));
    }
    assert!(!responses.try_reserve_input_ack(1));
    assert_eq!(
        responses.pending_input_acks_for_test(),
        (MAX_PENDING_INPUT_ACKS, MAX_PENDING_INPUT_ACKS)
    );
    responses.release_input_ack(1);
    assert!(responses.try_reserve_input_ack(1));
    for _ in 0..MAX_PENDING_INPUT_ACKS {
        responses.release_input_ack(1);
    }
    assert_eq!(responses.pending_input_acks_for_test(), (0, 0));

    assert!(responses.try_reserve_input_ack(MAX_PENDING_INPUT_ACK_BYTES));
    assert!(!responses.try_reserve_input_ack(1));
    responses.release_input_ack(MAX_PENDING_INPUT_ACK_BYTES);
    assert_eq!(responses.pending_input_acks_for_test(), (0, 0));
    assert!(!responses.try_reserve_input_ack(MAX_PENDING_INPUT_ACK_BYTES + 1));
}

#[test]
fn interactive_input_keeps_fire_and_forget_semantics() {
    let host = test_host_shared();
    let (pty_writer, mut pty_reader) = UnixStream::pair().unwrap();
    *host.writer.lock().unwrap() = Box::new(pty_writer);
    let (target_socket, _target_peer) = UnixStream::pair().unwrap();
    let (target_tx, target_rx) = mpsc_channel();
    let target = HostTap::new(target_tx, Arc::new(target_socket), usize::MAX);

    assert!(host.write_input(b"x", 0, &target));
    let mut byte = [0u8; 1];
    pty_reader.read_exact(&mut byte).unwrap();
    assert_eq!(&byte, b"x");
    assert!(target_rx.recv_timeout(Duration::from_millis(20)).is_err());
}

struct GatedInputWriter {
    write_started: SyncSender<()>,
    write_release: Receiver<()>,
    flush_started: SyncSender<()>,
    flush_release: Receiver<()>,
    fail_flush: bool,
}

impl Write for GatedInputWriter {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        self.write_started.send(()).unwrap();
        self.write_release.recv().unwrap();
        Ok(bytes.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        self.flush_started.send(()).unwrap();
        self.flush_release.recv().unwrap();
        if self.fail_flush {
            return Err(std::io::Error::new(
                std::io::ErrorKind::BrokenPipe,
                "synthetic flush failure",
            ));
        }
        Ok(())
    }
}

#[test]
fn host_input_receipt_follows_pty_write_and_flush() {
    let host = test_host_shared();
    let (write_started_tx, write_started_rx) = sync_channel(0);
    let (write_release_tx, write_release_rx) = sync_channel(0);
    let (flush_started_tx, flush_started_rx) = sync_channel(0);
    let (flush_release_tx, flush_release_rx) = sync_channel(0);
    *host.writer.lock().unwrap() = Box::new(GatedInputWriter {
        write_started: write_started_tx,
        write_release: write_release_rx,
        flush_started: flush_started_tx,
        flush_release: flush_release_rx,
        fail_flush: false,
    });
    let (target_socket, _target_peer) = UnixStream::pair().unwrap();
    let (target_tx, target_rx) = mpsc_channel();
    let target = HostTap::new(target_tx, Arc::new(target_socket), usize::MAX);
    let worker = thread::spawn(move || {
        assert!(host.write_input(b"x", 42, &target));
    });

    write_started_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    assert!(target_rx.recv_timeout(Duration::from_millis(20)).is_err());
    write_release_tx.send(()).unwrap();
    flush_started_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    assert!(target_rx.recv_timeout(Duration::from_millis(20)).is_err());
    flush_release_tx.send(()).unwrap();

    let ack = target_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    assert_eq!(ack.kind, MessageKind::InputAck);
    assert_eq!(ack.request_id, 42);
    assert!(ack.payload.is_empty());
    worker.join().unwrap();
}

#[test]
fn host_input_receipt_requires_successful_flush() {
    let host = test_host_shared();
    let (write_started_tx, write_started_rx) = sync_channel(0);
    let (write_release_tx, write_release_rx) = sync_channel(0);
    let (flush_started_tx, flush_started_rx) = sync_channel(0);
    let (flush_release_tx, flush_release_rx) = sync_channel(0);
    *host.writer.lock().unwrap() = Box::new(GatedInputWriter {
        write_started: write_started_tx,
        write_release: write_release_rx,
        flush_started: flush_started_tx,
        flush_release: flush_release_rx,
        fail_flush: true,
    });
    let (target_socket, _target_peer) = UnixStream::pair().unwrap();
    let (target_tx, target_rx) = mpsc_channel();
    let target = HostTap::new(target_tx, Arc::new(target_socket), usize::MAX);
    let worker = thread::spawn(move || host.write_input(b"x", 42, &target));

    write_started_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    assert!(target_rx.recv_timeout(Duration::from_millis(20)).is_err());
    write_release_tx.send(()).unwrap();
    flush_started_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    assert!(target_rx.recv_timeout(Duration::from_millis(20)).is_err());
    flush_release_tx.send(()).unwrap();

    assert!(!worker.join().unwrap());
    assert!(target_rx.recv_timeout(Duration::from_millis(20)).is_err());
}

#[test]
fn terminate_waits_for_the_authoritative_host_receipt() {
    let (record_path, record, lease) = record_fixture("terminate-ack");
    let root = record_path.parent().unwrap().to_path_buf();
    let (client, mut host) = UnixStream::pair().unwrap();
    let control_responses = Arc::new(ControlResponses::new());
    let mut attachment = HostAttachment {
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
    let responder = thread::spawn(move || {
        let request = read_frame(&mut host, MAX_FRAME_PAYLOAD).unwrap().unwrap();
        assert_eq!(request.kind, MessageKind::Terminate);
        assert_ne!(request.request_id, 0);
        let mut response = Frame::new(MessageKind::TerminateAck, Vec::new());
        response.request_id = request.request_id;
        assert!(control_responses.resolve(&response));
    });

    attachment.terminate().unwrap();
    responder.join().unwrap();

    drop(attachment);
    drop(lease);
    let _ = fs::remove_dir_all(root);
}

#[test]
fn clear_history_control_write_failure_after_header_is_ambiguous() {
    let (record_path, record, lease) = record_fixture("clear-history-partial-control-write");
    let root = record_path.parent().unwrap().to_path_buf();
    let (client, mut host) = UnixStream::pair().unwrap();
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
        control_responses: Arc::new(ControlResponses::new()),
        next_request: AtomicU64::new(2),
        viewer_size: RankedMutex::new(None),
        launch_process: None,
        launch_activation_pending: false,
        pty_custody: None,
    };
    let peer = thread::spawn(move || {
        let mut header = [0; crate::terminal_host_protocol::HEADER_LEN];
        Read::read_exact(&mut host, &mut header).unwrap();
        host.shutdown(std::net::Shutdown::Both).unwrap();
    });

    let failure = attachment
        .send_control_request(
            MessageKind::ClearHistory,
            MessageKind::ClearHistoryAck,
            vec![b'x'; MAX_FRAME_PAYLOAD],
        )
        .unwrap_err();
    peer.join().unwrap();

    assert_eq!(
        failure.delivery(),
        ClearHistoryDelivery::Ambiguous,
        "a delivered frame header means the host may have received the complete request"
    );
    drop(attachment);
    drop(lease);
    let _ = fs::remove_dir_all(root);
}

#[test]
fn clear_history_ack_status_preserves_reason_and_delivery() {
    for (message, expected) in [
        (CLEAR_HISTORY_PRESERVATION_ERROR, CLEAR_HISTORY_ACK_PRESERVATION_FAILED),
        (CLEAR_HISTORY_STREAM_TIMEOUT_ERROR, CLEAR_HISTORY_ACK_STREAM_TIMEOUT),
        (CLEAR_HISTORY_FALLBACK_UNREPRESENTABLE_ERROR, CLEAR_HISTORY_ACK_FALLBACK_UNREPRESENTABLE),
        (CLEAR_HISTORY_FALLBACK_WRITE_TIMEOUT_ERROR, CLEAR_HISTORY_ACK_FALLBACK_WRITE_TIMEOUT),
        ("other pre-execution failure", CLEAR_HISTORY_ACK_KNOWN_NOT_DELIVERED),
    ] {
        assert_eq!(
            clear_history_ack_status(Err(ClearHistoryFailure::known_not_delivered(
                anyhow::anyhow!(message)
            ))),
            expected
        );
    }
    assert_eq!(
        clear_history_ack_status(Err(ClearHistoryFailure::ambiguous(anyhow::anyhow!(
            "partial PTY write"
        )))),
        CLEAR_HISTORY_ACK_AMBIGUOUS
    );
}

#[test]
fn process_nonce_proves_stale_record_even_if_pid_is_live_and_reused() {
    let (record_path, record, lease) = record_fixture("liveness");
    assert_eq!(
        terminal_host_record_liveness(&record_path, &record).unwrap(),
        TerminalHostLiveness::Live
    );

    // The recorded PID is this still-running test process. Releasing
    // the process-start nonce nevertheless proves that the exact
    // recorded host lifetime ended; PID existence cannot mask it.
    drop(lease);
    assert!(!process_definitely_absent(record.host_pid));
    assert_eq!(
        terminal_host_record_liveness(&record_path, &record).unwrap(),
        TerminalHostLiveness::Dead
    );
    assert!(remove_stale_terminal_host_record(&record_path, &record).unwrap());
    assert!(!record_path.exists());
    let _ = fs::remove_dir_all(record_path.parent().unwrap());
}

#[test]
fn launch_publication_reservation_blocks_reset_lock_until_released() {
    let root = std::env::temp_dir().join(format!(
        "cmux-host-publication-reservation-{}-{}",
        std::process::id(),
        RECORD_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)
    ));
    let reservation = reserve_terminal_host_publication(&root).unwrap();

    let error = match acquire_terminal_host_reset_lock(&root) {
        Ok(_) => panic!("reset lock was not blocked by publication reservation"),
        Err(error) => error,
    };
    assert!(error.to_string().contains("live or unverified hosts"), "{error:#}");

    drop(reservation);
    let reset_lock = acquire_terminal_host_reset_lock(&root).unwrap();
    assert!(reset_lock.is_some());
    drop(reset_lock);
    let _ = fs::remove_dir_all(root);
}

#[test]
fn reset_lock_prepares_missing_publication_lock() {
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::OpenOptionsExt;

    let root = std::env::temp_dir().join(format!(
        "cmux-host-reset-prepares-publication-lock-{}-{}",
        std::process::id(),
        RECORD_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)
    ));
    prepare_private_dir(&root).unwrap();
    assert!(!terminal_host_publication_lock_path(&root).exists());

    let reset_lock = acquire_terminal_host_reset_lock(&root).unwrap();

    assert!(reset_lock.is_some());
    let publication_lock = OpenOptions::new()
        .read(true)
        .write(true)
        .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
        .open(terminal_host_publication_lock_path(&root))
        .unwrap();
    // SAFETY: flock only observes the advisory lock on this valid test descriptor.
    assert_ne!(
        unsafe { libc::flock(publication_lock.as_raw_fd(), libc::LOCK_SH | libc::LOCK_NB) },
        0,
        "publication reservation should be blocked while reset holds the lock"
    );
    drop(reset_lock);
    // SAFETY: flock only observes the advisory lock on this valid test descriptor.
    assert_eq!(
        unsafe { libc::flock(publication_lock.as_raw_fd(), libc::LOCK_SH | libc::LOCK_NB) },
        0
    );
    // SAFETY: flock only changes the advisory lock on this valid test descriptor.
    let _ = unsafe { libc::flock(publication_lock.as_raw_fd(), libc::LOCK_UN) };
    drop(publication_lock);
    let _ = fs::remove_dir_all(root);
}

#[test]
fn dropping_liveness_lease_releases_inherited_descriptor_lock() {
    let (record_path, record, lease) = record_fixture("inherited-liveness-fd");
    let inherited = lease.file.try_clone().unwrap();

    drop(lease);
    assert_eq!(
        terminal_host_record_liveness(&record_path, &record).unwrap(),
        TerminalHostLiveness::Dead,
        "the lease owner must explicitly unlock before an inherited descriptor closes"
    );

    drop(inherited);
    assert!(remove_stale_terminal_host_record(&record_path, &record).unwrap());
    let _ = fs::remove_dir_all(record_path.parent().unwrap());
}

#[test]
fn record_loader_rejects_noncanonical_filenames_and_identity_spellings() {
    let (record_path, record, lease) = record_fixture("canonical");
    let root = record_path.parent().unwrap();
    fs::write(root.join("duplicate.json"), serde_json::to_vec(&record).unwrap()).unwrap();
    let mut uppercase = record.clone();
    uppercase.host_start_nonce.make_ascii_uppercase();
    fs::write(
        root.join(format!("{}.json", TerminalId::random().unwrap().to_hex())),
        serde_json::to_vec(&uppercase).unwrap(),
    )
    .unwrap();

    let loaded = load_terminal_host_records(root).unwrap();
    assert_eq!(loaded, vec![(record_path.clone(), record.clone())]);
    drop(lease);
    assert!(remove_stale_terminal_host_record(&record_path, &record).unwrap());
    let _ = fs::remove_dir_all(root);
}

#[test]
fn exit_sidecar_round_trips_and_requires_exact_acknowledgement() {
    let (record_path, record, lease) = record_fixture("exit-sidecar");
    let root = record_path.parent().unwrap();
    let exit_record = TerminalHostExitRecord::new(
        &TerminalHostIdentity {
            terminal_id: record.terminal_id.clone(),
            incarnation: record.incarnation.clone(),
        },
        TerminalExit {
            outcome: crate::terminal_host_protocol::TerminalExitOutcome::Exit { code: 17 },
            exited_at_ms: 1_234_567,
        },
    );
    let exit_path = record_path.with_extension("exit");
    write_exit_record(&exit_path, &exit_record).unwrap();
    assert_eq!(
        load_terminal_host_exit_records(root).unwrap(),
        vec![(exit_path.clone(), exit_record.clone())]
    );
    assert_eq!(
        terminal_host_exit_record(&record_path).unwrap(),
        Some((exit_path.clone(), exit_record.clone()))
    );

    let mut mismatch = exit_record.clone();
    mismatch.exit.exited_at_ms += 1;
    assert!(!acknowledge_terminal_host_exit_record(&exit_path, &mismatch).unwrap());
    assert!(exit_path.exists(), "mismatched ack must retain restart evidence");
    assert!(acknowledge_terminal_host_exit_record(&exit_path, &exit_record).unwrap());
    assert!(!exit_path.exists());
    assert!(
        !acknowledge_terminal_host_exit_record(&exit_path, &exit_record).unwrap(),
        "repeated exact ack is an idempotent no-op"
    );

    drop(lease);
    assert!(remove_stale_terminal_host_record(&record_path, &record).unwrap());
    let _ = fs::remove_dir_all(root);
}

#[test]
fn exit_sidecar_publication_never_clobbers_a_concurrent_outcome() {
    let (record_path, record, lease) = record_fixture("exit-sidecar-race");
    let root = record_path.parent().unwrap().to_path_buf();
    let exit_path = record_path.with_extension("exit");
    let identity = TerminalHostIdentity {
        terminal_id: record.terminal_id.clone(),
        incarnation: record.incarnation.clone(),
    };
    let first = TerminalHostExitRecord::new(
        &identity,
        TerminalExit {
            outcome: crate::terminal_host_protocol::TerminalExitOutcome::Exit { code: 17 },
            exited_at_ms: 1_234_567,
        },
    );
    let second = TerminalHostExitRecord::new(
        &identity,
        TerminalExit {
            outcome: crate::terminal_host_protocol::TerminalExitOutcome::Signal {
                signal: libc::SIGTERM,
                core_dumped: false,
            },
            exited_at_ms: 1_234_568,
        },
    );
    let barrier = Arc::new(std::sync::Barrier::new(3));
    let publishers = [first.clone(), second.clone()]
        .into_iter()
        .map(|candidate| {
            let barrier = barrier.clone();
            let exit_path = exit_path.clone();
            thread::spawn(move || {
                barrier.wait();
                write_exit_record(&exit_path, &candidate)
            })
        })
        .collect::<Vec<_>>();
    barrier.wait();
    let results =
        publishers.into_iter().map(|publisher| publisher.join().unwrap()).collect::<Vec<_>>();
    assert_eq!(results.iter().filter(|result| result.is_ok()).count(), 1);
    let stored: TerminalHostExitRecord =
        serde_json::from_slice(&fs::read(&exit_path).unwrap()).unwrap();
    assert!(stored == first || stored == second);
    validate_terminal_host_exit_record(&exit_path, &stored).unwrap();

    let mut unknown_field = serde_json::to_value(&stored).unwrap();
    unknown_field["unexpected"] = serde_json::json!(true);
    assert!(
        serde_json::from_value::<TerminalHostExitRecord>(unknown_field).is_err(),
        "exit sidecars must reject fields outside the versioned schema"
    );

    assert!(acknowledge_terminal_host_exit_record(&exit_path, &stored).unwrap());
    drop(lease);
    assert!(remove_stale_terminal_host_record(&record_path, &record).unwrap());
    let _ = fs::remove_dir_all(root);
}

#[test]
fn input_ack_capability_requires_version_4_record() {
    let (record_path, record, lease) = record_fixture("input-ack-version");
    validate_terminal_host_record(&record_path, &record).unwrap();
    for version in [2, 3] {
        let mut legacy = record.clone();
        legacy.record_version = version;
        legacy.supports_terminate_ack = version >= 3;
        legacy.supports_input_ack = false;
        legacy.supports_terminal_metadata = false;
        legacy.supports_viewer_size_priority = false;
        validate_terminal_host_record(&record_path, &legacy).unwrap();
        legacy.supports_input_ack = true;
        assert!(
            validate_terminal_host_record(&record_path, &legacy).is_err(),
            "version {version} must reject input acknowledgements"
        );
    }
    drop(lease);
    assert!(remove_stale_terminal_host_record(&record_path, &record).unwrap());
    fs::remove_dir_all(record_path.parent().unwrap()).unwrap();
}

#[test]
fn legacy_record_is_adoptable_shape_but_never_unsafely_reaped() {
    let (v2_path, v2, lease) = record_fixture("legacy");
    let root = v2_path.parent().unwrap();
    let terminal_id = TerminalId::random().unwrap().to_hex();
    let mut legacy = v2.clone();
    legacy.record_version = 1;
    legacy.terminal_id = terminal_id.clone();
    legacy.endpoint =
        format!("/tmp/cmux-th-{}/{terminal_id}.sock", fs::metadata(root).unwrap().uid());
    legacy.host_pid = 0;
    legacy.host_start_nonce.clear();
    legacy.supports_set_defaults = false;
    legacy.supports_clear_history = false;
    legacy.supports_terminate_ack = false;
    legacy.supports_input_ack = false;
    legacy.supports_terminal_metadata = false;
    legacy.supports_viewer_size_priority = false;
    let legacy_path = legacy.record_path(root);
    write_record(&legacy_path, &legacy).unwrap();

    validate_terminal_host_record(&legacy_path, &legacy).unwrap();
    assert_eq!(
        terminal_host_record_liveness(&legacy_path, &legacy).unwrap(),
        TerminalHostLiveness::Indeterminate
    );
    assert!(
        load_terminal_host_records(root)
            .unwrap()
            .iter()
            .any(|(_, record)| record.terminal_id == terminal_id)
    );
    assert!(!remove_stale_terminal_host_record(&legacy_path, &legacy).unwrap());

    let mut invalid = legacy.clone();
    invalid.supports_input_ack = true;
    assert!(validate_terminal_host_record(&legacy_path, &invalid).is_err());

    fs::remove_file(&legacy_path).unwrap();
    drop(lease);
    assert!(remove_stale_terminal_host_record(&v2_path, &v2).unwrap());
    let _ = fs::remove_dir_all(root);
}

#[test]
fn geometry_is_bounded_and_failed_apply_rolls_back_viewer_set() {
    assert_eq!(normalize_terminal_geometry(0, 0).unwrap(), (1, 1));
    assert_eq!(normalize_terminal_geometry(u16::MAX, 1).unwrap(), (10_000, 1));
    assert!(normalize_terminal_geometry(10_000, 10_000).is_err());

    let viewers = Mutex::new(ViewerSizes::default());
    viewers.lock().unwrap().sizes.insert(1, (80, 24));
    let error = mutate_viewer_sizes(
        &viewers,
        |set| {
            set.sizes.insert(2, (70, 20));
        },
        |_| anyhow::bail!("injected PTY resize failure"),
    )
    .unwrap_err();
    assert!(error.to_string().contains("injected PTY"));
    assert_eq!(viewers.lock().unwrap().sizes, HashMap::from([(1, (80, 24))]));
    assert!(viewers.lock().unwrap().preferred.is_empty());
}

#[test]
fn stalled_host_handshake_is_time_bounded() {
    let (record_path, record, lease) = record_fixture("handshake-timeout");
    let endpoint = PathBuf::from(&record.endpoint);
    prepare_private_dir(endpoint.parent().unwrap()).unwrap();
    let _ = fs::remove_file(&endpoint);
    let listener = UnixListener::bind(&endpoint).unwrap();
    let connect_record = record.clone();
    let connect_record_path = record_path.clone();
    let (result_sender, result_receiver) = std::sync::mpsc::channel();
    let connector = thread::spawn(move || {
        result_sender
            .send(
                connect_record_with_timeout(
                    connect_record,
                    connect_record_path,
                    Duration::from_millis(30),
                    OwnerIntent::Surface,
                )
                .is_err(),
            )
            .unwrap();
    });

    let (_stalled_stream, _) = listener.accept().unwrap();
    assert!(result_receiver.recv_timeout(Duration::from_secs(1)).unwrap());
    connector.join().unwrap();
    let _ = fs::remove_file(endpoint);
    drop(lease);
    assert!(remove_stale_terminal_host_record(&record_path, &record).unwrap());
    let _ = fs::remove_dir_all(record_path.parent().unwrap());
}
