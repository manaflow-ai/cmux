use super::*;
use crate::ui::graphics::{
    GraphicData, GraphicFormat, GraphicImage, GraphicImageKey, GraphicPlacementKey,
    clear_image_transmission_observer, observe_image_transmissions,
};
use cmux_tui_core::Rect;
use ghostty_vt::{Callbacks, Terminal};
use std::sync::atomic::{AtomicBool, Ordering};

struct BlockingOutput {
    entered: SyncSender<()>,
    release: Receiver<()>,
    restored: Arc<AtomicBool>,
    writes_after_restore: Arc<Mutex<Vec<bool>>>,
}

impl Write for BlockingOutput {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        let _ = self.entered.try_send(());
        self.release.recv().unwrap();
        self.writes_after_restore.lock().unwrap().push(self.restored.load(Ordering::Acquire));
        Ok(buf.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

struct ObservedOutput {
    bytes: Arc<Mutex<Vec<u8>>>,
    flushed: SyncSender<()>,
}

impl Write for ObservedOutput {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.bytes.lock().unwrap().extend_from_slice(buf);
        Ok(buf.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        let _ = self.flushed.try_send(());
        Ok(())
    }
}

struct SupersedingOutput {
    bytes: Arc<Mutex<Vec<u8>>>,
    entered: Option<SyncSender<()>>,
    release: Option<Receiver<()>>,
    flushed: SyncSender<()>,
}

impl GraphicsOutput for SupersedingOutput {
    fn write_segment(
        &mut self,
        bytes: &[u8],
        _permit: &WritePermit<'_>,
        emitted: &mut usize,
    ) -> io::Result<bool> {
        *emitted = 0;
        self.bytes.lock().unwrap().extend_from_slice(bytes);
        *emitted = bytes.len();
        let _ = self.flushed.try_send(());
        if let Some(entered) = self.entered.take() {
            entered.send(()).unwrap();
            self.release.take().unwrap().recv().unwrap();
        }
        Ok(true)
    }

    fn write_recovery(&mut self, bytes: &[u8]) -> io::Result<()> {
        self.bytes.lock().unwrap().extend_from_slice(bytes);
        let _ = self.flushed.try_send(());
        Ok(())
    }
}

struct PrefixInterruptOutput {
    bytes: Vec<u8>,
}

impl GraphicsOutput for PrefixInterruptOutput {
    fn write_segment(
        &mut self,
        bytes: &[u8],
        _permit: &WritePermit<'_>,
        emitted: &mut usize,
    ) -> io::Result<bool> {
        let end = bytes
            .windows(2)
            .position(|window| window == b"\x1b\\")
            .map(|at| at + 2)
            .expect("graphics segment must contain a complete APC");
        self.bytes.extend_from_slice(&bytes[..end]);
        *emitted = end;
        Ok(false)
    }

    fn write_recovery(&mut self, bytes: &[u8]) -> io::Result<()> {
        self.bytes.extend_from_slice(bytes);
        Ok(())
    }
}

struct RecoveringPartialOutput {
    bytes: Vec<u8>,
    recovery_attempts: usize,
}

impl GraphicsOutput for RecoveringPartialOutput {
    fn write_segment(
        &mut self,
        bytes: &[u8],
        _permit: &WritePermit<'_>,
        emitted: &mut usize,
    ) -> io::Result<bool> {
        let partial = bytes.len().min(8);
        self.bytes.extend_from_slice(&bytes[..partial]);
        *emitted = partial;
        Err(io::Error::new(io::ErrorKind::TimedOut, "terminal stayed blocked after a partial APC"))
    }

    fn write_recovery(&mut self, bytes: &[u8]) -> io::Result<()> {
        self.recovery_attempts += 1;
        self.bytes.extend_from_slice(bytes);
        Ok(())
    }
}

struct PermanentRecoveryFailureOutput {
    attempted: SyncSender<()>,
}

impl GraphicsOutput for PermanentRecoveryFailureOutput {
    fn write_segment(
        &mut self,
        bytes: &[u8],
        _permit: &WritePermit<'_>,
        emitted: &mut usize,
    ) -> io::Result<bool> {
        *emitted = bytes.len().min(8);
        Err(io::Error::new(io::ErrorKind::TimedOut, "terminal stayed blocked after a partial APC"))
    }

    fn write_recovery(&mut self, _bytes: &[u8]) -> io::Result<()> {
        let _ = self.attempted.try_send(());
        Err(io::Error::new(io::ErrorKind::BrokenPipe, "terminal output is gone"))
    }
}

fn rgba_placement(image_id: u32, generation: u64, x: u16, rgba: [u8; 4]) -> GraphicPlacement {
    rgba_placement_in_namespace(91, image_id, generation, x, rgba)
}

fn rgba_placement_in_namespace(
    namespace: u64,
    image_id: u32,
    generation: u64,
    x: u16,
    rgba: [u8; 4],
) -> GraphicPlacement {
    let image_key = GraphicImageKey { namespace, surface: 7, image_id };
    GraphicPlacement {
        key: GraphicPlacementKey { image: image_key, placement_id: 1, ordinal: 0 },
        image: Arc::new(GraphicImage {
            key: image_key,
            generation,
            width: 1,
            height: 1,
            format: GraphicFormat::Rgba,
            data: GraphicData::Bytes(Arc::from(rgba)),
        }),
        rect: Rect { x, y: 0, width: 1, height: 1 },
        pointer_frame_seq: None,
        columns: Some(1),
        rows: Some(1),
        source: None,
        x_offset: 0,
        y_offset: 0,
        z: 0,
    }
}

fn wait_for_output(
    flushed: &Receiver<()>,
    bytes: &Arc<Mutex<Vec<u8>>>,
    predicate: impl Fn(&[u8]) -> bool,
) {
    loop {
        flushed.recv_timeout(Duration::from_secs(2)).expect("graphics writer flush");
        if predicate(&bytes.lock().unwrap()) {
            return;
        }
    }
}

fn key(ch: char, modifiers: KeyModifiers) -> Event {
    Event::Key(KeyEvent::new(KeyCode::Char(ch), modifiers))
}

#[test]
fn large_batches_split_only_between_complete_kitty_commands() {
    let command = |payload: u8| {
        let mut command = b"\x1b_Gq=2,m=1;".to_vec();
        command.extend(std::iter::repeat_n(payload, 4_096));
        command.extend_from_slice(b"\x1b\\");
        command
    };
    let commands = (0..40).map(command).collect::<Vec<_>>();
    let batch = commands.concat();

    let mut offset = 0;
    let mut segments = Vec::new();
    while offset < batch.len() {
        let end = next_graphics_write_end(&batch, offset).expect("complete Kitty segment");
        let segment = &batch[offset..end];
        assert!(segment.ends_with(b"\x1b\\"));
        assert!(
            segment.len() <= MAX_LOCKED_GRAPHICS_WRITE_BYTES,
            "bounded command grouping held stdout for {} bytes",
            segment.len()
        );
        segments.extend_from_slice(segment);
        offset = end;
    }
    assert_eq!(segments, batch);
    assert!(next_graphics_write_end(b"\x1b_Gunterminated", 0).is_none());
}

#[cfg(unix)]
#[test]
fn shutdown_cancels_a_writer_blocked_by_terminal_backpressure() {
    let mut raw_fds = [-1; 2];
    assert_eq!(unsafe { libc::pipe(raw_fds.as_mut_ptr()) }, 0);
    let read_fd = unsafe { OwnedFd::from_raw_fd(raw_fds[0]) };
    let write_fd = unsafe { OwnedFd::from_raw_fd(raw_fds[1]) };
    let flags = unsafe { libc::fcntl(write_fd.as_raw_fd(), libc::F_GETFL) };
    assert!(flags >= 0);
    assert_eq!(
        unsafe { libc::fcntl(write_fd.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK) },
        0
    );
    let fill = [0_u8; 4_096];
    loop {
        let written =
            unsafe { libc::write(write_fd.as_raw_fd(), fill.as_ptr().cast(), fill.len()) };
        if written >= 0 {
            continue;
        }
        assert_eq!(io::Error::last_os_error().raw_os_error(), Some(libc::EAGAIN));
        break;
    }

    let mut writer = GraphicsWriter::spawn_with_test_graphics_output(
        Arc::new(StdoutLock::new(())),
        InterruptibleStdout { fd: write_fd },
    )
    .unwrap();
    let (attempt_tx, attempt_rx) = sync_channel(1);
    writer.control.observe_write_attempts(attempt_tx);
    writer.submit_test(vec![GraphicPlacement::browser(
        0,
        1,
        Rect { x: 0, y: 0, width: 10, height: 5 },
        1,
        10,
        5,
        "AAAA".to_string(),
    )]);
    attempt_rx.recv_timeout(Duration::from_secs(1)).unwrap();

    let started = Instant::now();
    writer.shutdown(Duration::ZERO);
    assert!(
        started.elapsed() < Duration::from_secs(1),
        "cancelable stdout did not stop within its bounded poll interval"
    );
    drop(read_fd);
}

#[cfg(not(unix))]
#[test]
fn production_graphics_writer_is_disabled_without_interruptible_output() {
    let (processing_fence, _processing_fence_notifier) = graphics_fence_channel();
    let result = GraphicsWriter::spawn(Arc::new(StdoutLock::new(())), processing_fence, || {});
    let Err(error) = result else {
        panic!("non-Unix graphics output must be disabled");
    };
    assert_eq!(error.kind(), io::ErrorKind::Unsupported);
}

#[cfg(unix)]
#[test]
fn segment_backpressure_has_a_total_deadline_without_external_supersession() {
    let mut raw_fds = [-1; 2];
    assert_eq!(unsafe { libc::pipe(raw_fds.as_mut_ptr()) }, 0);
    let _read_fd = unsafe { OwnedFd::from_raw_fd(raw_fds[0]) };
    let write_fd = unsafe { OwnedFd::from_raw_fd(raw_fds[1]) };
    let flags = unsafe { libc::fcntl(write_fd.as_raw_fd(), libc::F_GETFL) };
    assert!(flags >= 0);
    assert_eq!(
        unsafe { libc::fcntl(write_fd.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK) },
        0
    );
    let fill = [0_u8; MAX_LOCKED_GRAPHICS_WRITE_BYTES];
    let mut fill_len = fill.len();
    loop {
        let written = unsafe { libc::write(write_fd.as_raw_fd(), fill.as_ptr().cast(), fill_len) };
        if written > 0 {
            continue;
        }
        assert_ne!(written, 0, "pipe accepted a zero-length fill write");
        assert_eq!(io::Error::last_os_error().raw_os_error(), Some(libc::EAGAIN));
        if fill_len == 1 {
            break;
        }
        fill_len = (fill_len / 2).max(1);
    }

    let control = Arc::new(WriterControl::default());
    let slot = Arc::new(Mutex::new(PendingGraphics { revision: 1, ..PendingGraphics::default() }));
    let (attempt_tx, attempt_rx) = sync_channel(1);
    control.observe_write_attempts(attempt_tx);
    let (done_tx, done_rx) = sync_channel(1);
    let worker_control = control.clone();
    let mut segment = b"\x1b_Gq=2;".to_vec();
    segment.resize(MAX_LOCKED_GRAPHICS_WRITE_BYTES - 2, b'A');
    segment.extend_from_slice(b"\x1b\\");
    let worker = std::thread::spawn(move || {
        let mut output = InterruptibleStdout { fd: write_fd };
        let mut emitted = 0;
        let result = output.write_segment(
            &segment,
            &WritePermit { slot: &slot, control: &worker_control, revision: 1 },
            &mut emitted,
        );
        let _ = done_tx.send(result);
    });

    attempt_rx
        .recv_timeout(Duration::from_secs(1))
        .expect("writer never reached terminal backpressure");
    let result = match done_rx.recv_timeout(Duration::from_secs(1)) {
        Ok(result) => result,
        Err(_) => {
            control.cancelled.store(true, Ordering::Release);
            worker.join().unwrap();
            panic!("graphics segment ignored its total output deadline");
        }
    };
    assert_eq!(result.unwrap_err().kind(), io::ErrorKind::TimedOut);
    worker.join().unwrap();
}

#[cfg(unix)]
#[test]
fn cancellation_terminates_a_partially_written_apc_before_returning() {
    let mut raw_fds = [-1; 2];
    assert_eq!(unsafe { libc::pipe(raw_fds.as_mut_ptr()) }, 0);
    let read_fd = unsafe { OwnedFd::from_raw_fd(raw_fds[0]) };
    let write_fd = unsafe { OwnedFd::from_raw_fd(raw_fds[1]) };
    let flags = unsafe { libc::fcntl(write_fd.as_raw_fd(), libc::F_GETFL) };
    assert!(flags >= 0);
    assert_eq!(
        unsafe { libc::fcntl(write_fd.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK) },
        0
    );

    let mut command = b"\x1b_Gq=2;".to_vec();
    command.resize(256 * 1024, b'A');
    command.extend_from_slice(b"\x1b\\");
    let control = Arc::new(WriterControl::default());
    let slot = Arc::new(Mutex::new(PendingGraphics { revision: 1, ..PendingGraphics::default() }));
    let worker_control = control.clone();
    let worker_slot = slot;
    let worker = std::thread::spawn(move || {
        let mut output = InterruptibleStdout { fd: write_fd };
        let mut emitted = 0;
        output.write_segment(
            &command,
            &WritePermit { slot: &worker_slot, control: &worker_control, revision: 1 },
            &mut emitted,
        )
    });

    let deadline = Instant::now() + Duration::from_secs(1);
    loop {
        let mut available: libc::c_int = 0;
        assert_eq!(unsafe { libc::ioctl(read_fd.as_raw_fd(), libc::FIONREAD, &mut available) }, 0);
        if available > 0 {
            break;
        }
        assert!(Instant::now() < deadline, "writer never emitted its APC prefix");
        std::thread::yield_now();
    }
    control.cancelled.store(true, Ordering::Release);

    let mut emitted = Vec::new();
    let mut buffer = [0_u8; 8 * 1024];
    while !emitted.contains(&CONTROL_STRING_CANCEL) {
        let count =
            unsafe { libc::read(read_fd.as_raw_fd(), buffer.as_mut_ptr().cast(), buffer.len()) };
        assert!(count > 0, "pipe closed before the APC cancellation byte");
        emitted.extend_from_slice(&buffer[..count as usize]);
    }
    assert!(!worker.join().unwrap().unwrap());
    assert!(emitted.starts_with(b"\x1b_Gq=2;"));
    assert!(
        emitted.iter().position(|byte| *byte == CONTROL_STRING_CANCEL).unwrap() < 256 * 1024,
        "writer completed the large payload instead of canceling its partial APC"
    );
}

#[cfg(unix)]
#[test]
fn partial_apc_abort_is_bounded_when_output_never_becomes_writable() {
    let mut raw_fds = [-1; 2];
    assert_eq!(unsafe { libc::pipe(raw_fds.as_mut_ptr()) }, 0);
    let read_fd = unsafe { OwnedFd::from_raw_fd(raw_fds[0]) };
    let write_fd = unsafe { OwnedFd::from_raw_fd(raw_fds[1]) };
    let flags = unsafe { libc::fcntl(write_fd.as_raw_fd(), libc::F_GETFL) };
    assert!(flags >= 0);
    assert_eq!(
        unsafe { libc::fcntl(write_fd.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK) },
        0
    );

    let fill = [0_u8; 4_096];
    loop {
        let written =
            unsafe { libc::write(write_fd.as_raw_fd(), fill.as_ptr().cast(), fill.len()) };
        if written >= 0 {
            continue;
        }
        assert_eq!(io::Error::last_os_error().raw_os_error(), Some(libc::EAGAIN));
        break;
    }
    let mut full_bytes: libc::c_int = 0;
    assert_eq!(unsafe { libc::ioctl(read_fd.as_raw_fd(), libc::FIONREAD, &mut full_bytes) }, 0);
    let mut drained = [0_u8; 4_096];
    let drain_bytes = usize::try_from(full_bytes).unwrap().min(drained.len());
    assert_eq!(
        unsafe { libc::read(read_fd.as_raw_fd(), drained.as_mut_ptr().cast(), drain_bytes) },
        drain_bytes as isize
    );

    let mut command = b"\x1b_Gq=2;".to_vec();
    command.resize(256 * 1024, b'A');
    command.extend_from_slice(b"\x1b\\");
    let control = Arc::new(WriterControl::default());
    let slot = Arc::new(Mutex::new(PendingGraphics { revision: 1, ..PendingGraphics::default() }));
    let (blocked_tx, blocked_rx) = sync_channel(1);
    control.observe_write_attempts(blocked_tx);
    let worker_control = control.clone();
    let worker_slot = slot;
    let worker = std::thread::spawn(move || {
        let mut output = InterruptibleStdout { fd: write_fd };
        let mut emitted = 0;
        output.write_segment(
            &command,
            &WritePermit { slot: &worker_slot, control: &worker_control, revision: 1 },
            &mut emitted,
        )
    });

    blocked_rx
        .recv_timeout(Duration::from_secs(1))
        .expect("writer never reached terminal backpressure");
    let started = Instant::now();
    control.cancelled.store(true, Ordering::Release);
    let error = worker.join().unwrap().unwrap_err();

    assert_eq!(error.kind(), io::ErrorKind::TimedOut);
    assert!(
        started.elapsed() < Duration::from_secs(1),
        "partial APC cancellation remained blocked after its deadline"
    );
}

#[cfg(unix)]
fn stopped_pty_output_with_sentinel(sentinel: &[u8]) -> (OwnedFd, InterruptibleStdout) {
    let mut master = -1;
    let mut slave = -1;
    assert_eq!(
        unsafe {
            libc::openpty(
                &mut master,
                &mut slave,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            )
        },
        0
    );
    let master = unsafe { OwnedFd::from_raw_fd(master) };
    let slave = unsafe { OwnedFd::from_raw_fd(slave) };
    // Linux can reject even the first nonblocking write after TCOOFF. Queue
    // unrelated output before suspending the PTY, then fill the stopped queue.
    assert_eq!(
        unsafe { libc::write(slave.as_raw_fd(), sentinel.as_ptr().cast(), sentinel.len()) },
        sentinel.len() as isize
    );
    assert_eq!(unsafe { libc::tcflow(slave.as_raw_fd(), libc::TCOOFF) }, 0);
    let flags = unsafe { libc::fcntl(slave.as_raw_fd(), libc::F_GETFL) };
    assert!(flags >= 0);
    assert_eq!(
        unsafe { libc::fcntl(slave.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK) },
        0
    );
    let fill = [b'x'; 4_096];
    loop {
        let written = unsafe { libc::write(slave.as_raw_fd(), fill.as_ptr().cast(), fill.len()) };
        if written >= 0 {
            continue;
        }
        assert_eq!(io::Error::last_os_error().raw_os_error(), Some(libc::EAGAIN));
        break;
    }
    (master, InterruptibleStdout { fd: slave })
}

#[cfg(unix)]
fn resume_pty_and_read_prefix(master: &OwnedFd, output: &InterruptibleStdout) -> Vec<u8> {
    assert_eq!(unsafe { libc::tcflow(output.fd.as_raw_fd(), libc::TCOON) }, 0);
    let mut bytes = vec![0_u8; 8 * 1024];
    let count = unsafe { libc::read(master.as_raw_fd(), bytes.as_mut_ptr().cast(), bytes.len()) };
    assert!(count > 0, "resumed pseudo-terminal produced no queued output");
    bytes.truncate(count as usize);
    bytes
}

#[cfg(unix)]
#[test]
fn partial_apc_timeout_does_not_flush_unrelated_terminal_output() {
    let sentinel = b"ratatui-frame-before-graphics";
    let (master, mut output) = stopped_pty_output_with_sentinel(sentinel);

    let result = output.abort_partial_control_string();
    let queued = resume_pty_and_read_prefix(&master, &output);

    assert_eq!(result.unwrap_err().kind(), io::ErrorKind::TimedOut);
    assert!(
        queued.windows(sentinel.len()).any(|window| window == sentinel),
        "graphics cancellation discarded output queued by another terminal writer"
    );
}

#[cfg(unix)]
#[test]
fn recovery_timeout_does_not_flush_unrelated_terminal_output() {
    let sentinel = b"ratatui-frame-before-recovery";
    let (master, mut output) = stopped_pty_output_with_sentinel(sentinel);

    let result = output.write_recovery(DELETE_ALL_GRAPHICS);
    let queued = resume_pty_and_read_prefix(&master, &output);

    assert_eq!(result.unwrap_err().kind(), io::ErrorKind::TimedOut);
    assert!(
        queued.windows(sentinel.len()).any(|window| window == sentinel),
        "graphics recovery discarded output queued by another terminal writer"
    );
}

#[test]
fn kitty_graphics_response_completes_matching_processing_fence() {
    let (waiter, notifier) = graphics_fence_channel();
    let mut filter = GraphicsResponseFilter::new(notifier);
    let id = processing_fence_id(11);
    waiter.prepare(id);
    let response = format!("Gi={id};OK");
    let wire_events = std::iter::once(key('_', KeyModifiers::ALT))
        .chain(response.chars().map(|ch| {
            key(ch, if ch.is_uppercase() { KeyModifiers::SHIFT } else { KeyModifiers::NONE })
        }))
        .chain(std::iter::once(key('\\', KeyModifiers::ALT)));

    assert!(wire_events.flat_map(|event| filter.filter(event)).next().is_none());
    waiter.wait_for(id).unwrap();
}

#[test]
fn non_graphics_apc_input_is_replayed_losslessly() {
    let (_waiter, notifier) = graphics_fence_channel();
    let mut filter = GraphicsResponseFilter::new(notifier);
    let events = vec![
        key('_', KeyModifiers::ALT),
        key('x', KeyModifiers::NONE),
        key('\\', KeyModifiers::ALT),
    ];

    let replayed =
        events.clone().into_iter().flat_map(|event| filter.filter(event)).collect::<Vec<_>>();

    assert_eq!(replayed, events);
}

#[test]
fn processing_completion_waits_for_host_fence_after_stdout_flush() {
    let lock = Arc::new(StdoutLock::new(()));
    let held = lock.lock();
    let (processed_tx, processed_rx) = std::sync::mpsc::channel();
    let (fence_entered_tx, fence_entered_rx) = std::sync::mpsc::channel();
    let (fence_release_tx, fence_release_rx) = std::sync::mpsc::channel();
    let mut writer = GraphicsWriter::spawn_with_output_and_fence(
        lock.clone(),
        Vec::new(),
        move || {
            fence_entered_tx.send(()).unwrap();
            fence_release_rx.recv().unwrap();
            Ok(())
        },
        move || {
            processed_tx.send(()).unwrap();
        },
    )
    .unwrap();
    let mut placement = GraphicPlacement::browser(
        1,
        11,
        Rect { x: 1, y: 2, width: 3, height: 4 },
        13,
        3,
        4,
        "AAAA".to_string(),
    );
    placement.pointer_frame_seq = Some(8);

    assert!(writer.submit(7, 1, vec![placement]));
    assert!(
        processed_rx.recv_timeout(Duration::from_millis(50)).is_err(),
        "submission must not complete while output is blocked"
    );

    drop(held);
    fence_entered_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    assert!(
        lock.try_lock().is_some(),
        "waiting for a graphics response must not monopolize terminal output"
    );
    assert_eq!(
        writer.take_completion(),
        None,
        "stdout flush alone must not complete the ordered submission"
    );
    assert!(
        processed_rx.recv_timeout(Duration::from_millis(50)).is_err(),
        "the app must wait until the host acknowledges command processing"
    );

    fence_release_tx.send(()).unwrap();
    processed_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    assert_eq!(
        writer.take_completion(),
        Some(GraphicsCompletion::Processed(GraphicsProcessing {
            id: 7,
            session_generation: 1,
            graphics: vec![ProcessedGraphic {
                surface: 11,
                rect: Rect { x: 1, y: 2, width: 3, height: 4 },
                seq: 13,
                pointer_frame_seq: Some(8),
            }],
        }))
    );
    writer.shutdown(Duration::from_secs(1));
}

#[test]
fn snapshot_slot_is_latest_wins_and_shutdown_is_clean() {
    let (tx, rx) = sync_channel(1);
    let slot = Arc::new(Mutex::new(PendingGraphics::default()));
    submit_snapshot(
        &slot,
        &tx,
        GraphicsSubmission {
            id: 1,
            session_generation: 1,
            scene: vec![Arc::from(vec![GraphicPlacement::browser(
                0,
                1,
                Rect { x: 0, y: 0, width: 10, height: 5 },
                1,
                10,
                5,
                "AAAA".to_string(),
            )])],
        },
    );
    submit_snapshot(
        &slot,
        &tx,
        GraphicsSubmission {
            id: 2,
            session_generation: 1,
            scene: vec![Arc::from(vec![GraphicPlacement::browser(
                0,
                1,
                Rect { x: 1, y: 1, width: 11, height: 6 },
                2,
                11,
                6,
                "BBBB".to_string(),
            )])],
        },
    );

    let latest = take_pending_update(&slot, 0)
        .and_then(|update| update.submission)
        .map(|submission| submission.scene)
        .expect("latest snapshot");
    assert_eq!(latest.len(), 1);
    assert_eq!(latest[0][0].image.generation, 2);
    assert_eq!(latest[0][0].rect.x, 1);
    rx.recv_timeout(Duration::from_secs(1)).unwrap();
    assert!(rx.try_recv().is_err());

    let lock = Arc::new(StdoutLock::new(()));
    let mut writer = GraphicsWriter::spawn_with_output(lock, io::sink()).unwrap();
    writer.shutdown(Duration::from_secs(1));
    assert!(writer.handle.as_ref().is_none_or(|handle| handle.is_finished()));
}

#[test]
fn host_scene_invalidation_survives_latest_wins_coalescing() {
    let (tx, rx) = sync_channel(1);
    let slot = Arc::new(Mutex::new(PendingGraphics::default()));
    let writer = GraphicsWriter {
        slot: slot.clone(),
        completion: Arc::new(Mutex::new(None)),
        notify: Some(tx),
        control: Arc::new(WriterControl::default()),
        handle: None,
    };

    writer.invalidate_host_scene();
    writer.submit_test(vec![GraphicPlacement::browser(
        0,
        1,
        Rect { x: 0, y: 0, width: 10, height: 5 },
        1,
        10,
        5,
        "AAAA".to_string(),
    )]);
    writer.submit_test(vec![GraphicPlacement::browser(
        0,
        1,
        Rect { x: 1, y: 1, width: 11, height: 6 },
        2,
        11,
        6,
        "BBBB".to_string(),
    )]);

    let update = take_pending_update(&slot, 0).expect("pending scene update");
    assert_ne!(update.host_scene_epoch, 0);
    let latest = update.submission.expect("latest submission").scene;
    assert_eq!(latest.len(), 1);
    assert_eq!(latest[0][0].image.generation, 2);
    assert_eq!(latest[0][0].rect.x, 1);
    rx.recv_timeout(Duration::from_secs(1)).unwrap();
    assert!(rx.try_recv().is_err());
}

#[test]
fn host_scene_invalidation_discards_a_pre_clear_write_waiting_on_stdout() {
    let stdout_lock = Arc::new(StdoutLock::new(()));
    let bytes = Arc::new(Mutex::new(Vec::new()));
    let (flushed_tx, flushed_rx) = sync_channel(8);
    let output = ObservedOutput { bytes: bytes.clone(), flushed: flushed_tx };
    let (ready_tx, ready_rx) = sync_channel(1);
    let mut writer = GraphicsWriter::spawn_with_output_and_fence(
        stdout_lock.clone(),
        output,
        || Ok(()),
        move || {
            let _ = ready_tx.try_send(());
        },
    )
    .unwrap();
    let first = rgba_placement(41, 1, 0, [255, 0, 0, 255]);
    let second = rgba_placement(42, 1, 1, [0, 255, 0, 255]);

    writer.submit_test(vec![first.clone(), second]);
    wait_for_output(&flushed_rx, &bytes, |bytes| {
        String::from_utf8_lossy(bytes).matches("a=p").count() == 2
    });
    ready_rx
        .recv_timeout(Duration::from_secs(2))
        .expect("initial graphics batch must finish before blocking stdout");
    bytes.lock().unwrap().clear();

    let draw_guard = stdout_lock.lock();
    let (attempt_tx, attempt_rx) = sync_channel(1);
    writer.control.observe_write_attempts(attempt_tx);
    let changed_second = rgba_placement(42, 2, 1, [0, 0, 255, 255]);
    writer.submit_test(vec![first, changed_second.clone()]);
    attempt_rx
        .recv_timeout(Duration::from_secs(2))
        .expect("pre-clear graphics batch must be waiting on stdout");

    writer.invalidate_host_scene();
    writer.submit_test(vec![changed_second]);
    drop(draw_guard);

    wait_for_output(&flushed_rx, &bytes, |bytes| {
        String::from_utf8_lossy(bytes).matches("a=p").count() == 1
    });
    let raced_output = bytes.lock().unwrap().clone();
    let mut host = Terminal::new(8, 4, 0, Callbacks::default()).unwrap();
    host.resize(8, 4, 1, 1).unwrap();
    host.vt_write(&raced_output);
    let snapshot = host.kitty_graphics_snapshot().unwrap();
    assert_eq!(
        snapshot.images.len(),
        1,
        "stale pre-clear transmission left a duplicate host image: {snapshot:?}"
    );
    assert_eq!(
        snapshot.placements.len(),
        1,
        "stale pre-clear placement survived host-scene invalidation: {snapshot:?}"
    );

    writer.shutdown(Duration::from_secs(1));
}

#[test]
fn newer_snapshot_supersedes_an_inflight_scene_and_resets_the_host() {
    let bytes = Arc::new(Mutex::new(Vec::new()));
    let (entered_tx, entered_rx) = sync_channel(1);
    let (release_tx, release_rx) = sync_channel(1);
    let (flushed_tx, flushed_rx) = sync_channel(8);
    let output = SupersedingOutput {
        bytes: bytes.clone(),
        entered: Some(entered_tx),
        release: Some(release_rx),
        flushed: flushed_tx,
    };
    let mut writer =
        GraphicsWriter::spawn_with_test_graphics_output(Arc::new(StdoutLock::new(())), output)
            .unwrap();
    let old = rgba_placement(41, 1, 0, [255, 0, 0, 255]);
    let latest = rgba_placement(41, 2, 0, [0, 0, 255, 255]);

    writer.submit_test(vec![old]);
    entered_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    writer.submit_test(vec![latest]);
    release_tx.send(()).unwrap();

    wait_for_output(&flushed_rx, &bytes, |bytes| {
        bytes.windows(DELETE_ALL_GRAPHICS.len()).any(|window| window == DELETE_ALL_GRAPHICS)
            && String::from_utf8_lossy(bytes).contains("AAD//w==")
    });

    let emitted = bytes.lock().unwrap().clone();
    let mut host = Terminal::new(8, 4, 0, Callbacks::default()).unwrap();
    host.resize(8, 4, 1, 1).unwrap();
    host.vt_write(&emitted);
    let snapshot = host.kitty_graphics_snapshot().unwrap();
    assert_eq!(snapshot.images.len(), 1);
    assert_eq!(snapshot.images[0].data.as_ref(), &[0, 0, 255, 255]);
    assert_eq!(snapshot.placements.len(), 1);
    writer.shutdown(Duration::from_secs(1));
}

#[test]
fn superseded_scene_does_not_encode_images_beyond_the_active_batch() {
    let namespace = u64::MAX - 17;
    let (observed_tx, observed_rx) = std::sync::mpsc::channel();
    observe_image_transmissions(observed_tx);
    let bytes = Arc::new(Mutex::new(Vec::new()));
    let (entered_tx, entered_rx) = sync_channel(1);
    let (release_tx, release_rx) = sync_channel(1);
    let (flushed_tx, _flushed_rx) = sync_channel(8);
    let output = SupersedingOutput {
        bytes,
        entered: Some(entered_tx),
        release: Some(release_rx),
        flushed: flushed_tx,
    };
    let mut writer =
        GraphicsWriter::spawn_with_test_graphics_output(Arc::new(StdoutLock::new(())), output)
            .unwrap();
    let old = (0..3)
        .map(|index| {
            rgba_placement_in_namespace(
                namespace,
                41 + index,
                1,
                u16::try_from(index).unwrap(),
                [u8::try_from(index).unwrap(), 0, 0, 255],
            )
        })
        .collect();

    writer.submit_test(old);
    entered_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    let encoded_before_supersession =
        observed_rx.try_iter().filter(|key| key.namespace == namespace).count();
    writer.submit_test(Vec::new());
    release_tx.send(()).unwrap();
    writer.shutdown(Duration::from_secs(1));
    clear_image_transmission_observer();

    assert_eq!(
        encoded_before_supersession, 1,
        "the writer encoded later images before checking for a newer scene"
    );
}

#[test]
fn superseding_a_multipart_upload_does_not_poison_the_next_image() {
    let bytes = Arc::new(Mutex::new(Vec::new()));
    let (entered_tx, entered_rx) = sync_channel(1);
    let (release_tx, release_rx) = sync_channel(1);
    let (flushed_tx, flushed_rx) = sync_channel(8);
    let output = SupersedingOutput {
        bytes: bytes.clone(),
        entered: Some(entered_tx),
        release: Some(release_rx),
        flushed: flushed_tx,
    };
    let mut writer =
        GraphicsWriter::spawn_with_test_graphics_output(Arc::new(StdoutLock::new(())), output)
            .unwrap();
    let old = GraphicPlacement::browser(
        0,
        7,
        Rect { x: 0, y: 0, width: 1, height: 1 },
        1,
        1,
        1,
        "A".repeat(MAX_LOCKED_GRAPHICS_WRITE_BYTES * 2),
    );
    let latest = rgba_placement(41, 1, 0, [0, 0, 255, 255]);

    writer.submit_test(vec![old]);
    entered_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    writer.submit_test(vec![latest]);
    release_tx.send(()).unwrap();

    wait_for_output(&flushed_rx, &bytes, |bytes| {
        bytes.windows(DELETE_ALL_GRAPHICS.len()).any(|window| window == DELETE_ALL_GRAPHICS)
            && String::from_utf8_lossy(bytes).contains("AAD//w==")
    });
    let emitted = bytes.lock().unwrap().clone();
    let mut host = Terminal::new(8, 4, 0, Callbacks::default()).unwrap();
    host.resize(8, 4, 1, 1).unwrap();
    host.vt_write(&emitted);
    let snapshot = host.kitty_graphics_snapshot().unwrap();
    assert_eq!(snapshot.images.len(), 1, "{snapshot:?}");
    assert_eq!(snapshot.images[0].data.as_ref(), &[0, 0, 255, 255]);
    assert_eq!(snapshot.placements.len(), 1);
    writer.shutdown(Duration::from_secs(1));
}

#[test]
fn cancellation_terminates_a_completed_multipart_chunk() {
    let bytes = Arc::new(Mutex::new(Vec::new()));
    let (entered_tx, entered_rx) = sync_channel(1);
    let (release_tx, release_rx) = sync_channel(1);
    let (flushed_tx, _flushed_rx) = sync_channel(8);
    let output = SupersedingOutput {
        bytes: bytes.clone(),
        entered: Some(entered_tx),
        release: Some(release_rx),
        flushed: flushed_tx,
    };
    let mut writer =
        GraphicsWriter::spawn_with_test_graphics_output(Arc::new(StdoutLock::new(())), output)
            .unwrap();
    let shutdown = writer.shutdown_control();
    writer.submit_test(vec![GraphicPlacement::browser(
        0,
        7,
        Rect { x: 0, y: 0, width: 1, height: 1 },
        1,
        1,
        1,
        "A".repeat(MAX_LOCKED_GRAPHICS_WRITE_BYTES * 2),
    )]);
    entered_rx.recv_timeout(Duration::from_secs(1)).unwrap();

    let cleanup = std::thread::spawn(move || writer.shutdown(Duration::ZERO));
    shutdown.wait_until_cancelled();
    release_tx.send(()).unwrap();
    cleanup.join().unwrap();

    let mut host = Terminal::new(8, 4, 0, Callbacks::default()).unwrap();
    host.resize(8, 4, 1, 1).unwrap();
    host.vt_write(&bytes.lock().unwrap());
    let mut next = GraphicsState::default();
    let latest = rgba_placement(41, 1, 0, [0, 0, 255, 255]);
    for batch in next.frame_batches(&[latest]) {
        host.vt_write(&batch);
    }
    let snapshot = host.kitty_graphics_snapshot().unwrap();
    assert_eq!(snapshot.images.len(), 1, "{snapshot:?}");
    assert_eq!(snapshot.images[0].data.as_ref(), &[0, 0, 255, 255]);
    assert_eq!(snapshot.placements.len(), 1);
}

#[test]
fn partial_segment_progress_recovers_completed_multipart_chunks() {
    let old = GraphicPlacement::browser(
        0,
        7,
        Rect { x: 0, y: 0, width: 1, height: 1 },
        1,
        1,
        1,
        "A".repeat(4_096 * 2),
    );
    let mut graphics = GraphicsState::default();
    let batch = graphics.frame_batches(&[old]).remove(0);
    let slot = Arc::new(Mutex::new(PendingGraphics { revision: 1, ..PendingGraphics::default() }));
    let control = WriterControl::default();
    let stdout_lock = Arc::new(StdoutLock::new(()));
    let mut output = PrefixInterruptOutput { bytes: Vec::new() };

    assert_eq!(
        write_batch(&mut output, &stdout_lock, &slot, &control, 1, &batch),
        BatchWriteOutcome::Stopped
    );

    let mut host = Terminal::new(8, 4, 0, Callbacks::default()).unwrap();
    host.resize(8, 4, 1, 1).unwrap();
    host.vt_write(&output.bytes);
    let mut next = GraphicsState::default();
    for batch in next.frame_batches(&[rgba_placement(41, 1, 0, [0, 0, 255, 255])]) {
        host.vt_write(&batch);
    }
    let snapshot = host.kitty_graphics_snapshot().unwrap();
    assert_eq!(snapshot.images.len(), 1, "{snapshot:?}");
    assert_eq!(snapshot.images[0].data.as_ref(), &[0, 0, 255, 255]);
    assert_eq!(snapshot.placements.len(), 1);
}

#[test]
fn failed_partial_apc_recovery_precedes_later_terminal_output() {
    let slot = Arc::new(Mutex::new(PendingGraphics { revision: 1, ..PendingGraphics::default() }));
    let control = WriterControl::default();
    let stdout_lock = Arc::new(StdoutLock::new(()));
    let mut output = RecoveringPartialOutput { bytes: Vec::new(), recovery_attempts: 0 };
    let command = b"\x1b_Gq=2;payload\x1b\\";

    assert_eq!(
        write_batch(&mut output, &stdout_lock, &slot, &control, 1, command),
        BatchWriteOutcome::Stopped
    );
    assert_writer_failed(&control, false);
    output.bytes.extend_from_slice(b"visible-after-recovery");

    let mut host = Terminal::new(80, 4, 0, Callbacks::default()).unwrap();
    host.resize(80, 4, 1, 1).unwrap();
    host.vt_write(&output.bytes);
    assert!(
        host.viewport_text().unwrap().contains("visible-after-recovery"),
        "normal terminal output was consumed by an unterminated Kitty APC"
    );
    assert_eq!(output.recovery_attempts, 1);
}

#[test]
fn permanent_parser_recovery_failure_returns_without_retrying_forever() {
    let slot = Arc::new(Mutex::new(PendingGraphics { revision: 1, ..PendingGraphics::default() }));
    let control = Arc::new(WriterControl::default());
    let stdout_lock = Arc::new(StdoutLock::new(()));
    let (attempted_tx, attempted_rx) = sync_channel(1);
    let (done_tx, done_rx) = sync_channel(1);
    let worker_control = control.clone();
    let worker = std::thread::spawn(move || {
        let mut output = PermanentRecoveryFailureOutput { attempted: attempted_tx };
        let outcome = write_batch(
            &mut output,
            &stdout_lock,
            &slot,
            &worker_control,
            1,
            b"\x1b_Gq=2;payload\x1b\\",
        );
        let _ = done_tx.send(outcome);
    });

    attempted_rx
        .recv_timeout(Duration::from_secs(1))
        .expect("writer never attempted parser recovery");
    let outcome = match done_rx.recv_timeout(Duration::from_millis(250)) {
        Ok(outcome) => outcome,
        Err(_) => {
            control.cancelled.store(true, Ordering::Release);
            worker.join().unwrap();
            panic!("permanent parser recovery failure retried forever");
        }
    };
    assert_eq!(outcome, BatchWriteOutcome::Stopped);
    assert_writer_failed(&control, true);
    worker.join().unwrap();
}

#[test]
fn shutdown_quiesces_a_blocked_writer_before_terminal_restore() {
    let (entered_tx, entered_rx) = sync_channel(1);
    let (release_tx, release_rx) = sync_channel(1);
    let restored = Arc::new(AtomicBool::new(false));
    let writes_after_restore = Arc::new(Mutex::new(Vec::new()));
    let output = BlockingOutput {
        entered: entered_tx,
        release: release_rx,
        restored: restored.clone(),
        writes_after_restore: writes_after_restore.clone(),
    };
    let mut writer =
        GraphicsWriter::spawn_with_output(Arc::new(StdoutLock::new(())), output).unwrap();
    let shutdown = writer.shutdown_control();
    writer.submit_test(vec![GraphicPlacement::browser(
        0,
        1,
        Rect { x: 0, y: 0, width: 10, height: 5 },
        1,
        10,
        5,
        "AAAA".to_string(),
    )]);
    entered_rx.recv().unwrap();

    let (shutdown_done_tx, shutdown_done_rx) = sync_channel(1);
    let restored_for_shutdown = restored.clone();
    std::thread::spawn(move || {
        writer.shutdown(Duration::ZERO);
        restored_for_shutdown.store(true, Ordering::Release);
        shutdown_done_tx.send(()).unwrap();
    });

    shutdown.wait_until_cancelled();
    release_tx.send(()).unwrap();
    shutdown_done_rx.recv().unwrap();

    assert!(restored.load(Ordering::Acquire));
    assert!(
        writes_after_restore.lock().unwrap().iter().all(|after_restore| !after_restore),
        "graphics bytes were written after terminal restoration"
    );
}

#[test]
fn panic_shutdown_control_quiesces_before_terminal_restore() {
    let (entered_tx, entered_rx) = sync_channel(1);
    let (release_tx, release_rx) = sync_channel(1);
    let restored = Arc::new(AtomicBool::new(false));
    let writes_after_restore = Arc::new(Mutex::new(Vec::new()));
    let output = BlockingOutput {
        entered: entered_tx,
        release: release_rx,
        restored: restored.clone(),
        writes_after_restore: writes_after_restore.clone(),
    };
    let writer = GraphicsWriter::spawn_with_output(Arc::new(StdoutLock::new(())), output).unwrap();
    let shutdown = writer.shutdown_control();
    writer.submit_test(vec![GraphicPlacement::browser(
        0,
        1,
        Rect { x: 0, y: 0, width: 10, height: 5 },
        1,
        10,
        5,
        "AAAA".to_string(),
    )]);
    entered_rx.recv().unwrap();

    let (panic_hook_done_tx, panic_hook_done_rx) = sync_channel(1);
    let panic_shutdown = shutdown.clone();
    let restored_for_hook = restored.clone();
    std::thread::spawn(move || {
        panic_shutdown.cancel_and_wait();
        restored_for_hook.store(true, Ordering::Release);
        panic_hook_done_tx.send(()).unwrap();
    });

    shutdown.wait_until_cancelled();
    release_tx.send(()).unwrap();
    panic_hook_done_rx.recv().unwrap();

    assert!(restored.load(Ordering::Acquire));
    assert!(
        writes_after_restore.lock().unwrap().iter().all(|after_restore| !after_restore),
        "panic restoration raced a graphics write"
    );
}

#[test]
fn panic_hook_cancellation_does_not_join_writer_waiting_on_owned_stdout() {
    const CHILD_ENV: &str = "CMUX_TEST_PANIC_GRAPHICS_OWNER";
    if std::env::var_os(CHILD_ENV).is_some() {
        let stdout_lock = Arc::new(StdoutLock::new(()));
        let writer = GraphicsWriter::spawn_with_output(stdout_lock.clone(), io::sink())
            .expect("spawn graphics writer");
        let shutdown = writer.shutdown_control();
        let (attempt_tx, attempt_rx) = sync_channel(1);
        writer.control.observe_write_attempts(attempt_tx);
        let guard = stdout_lock.lock();
        writer.submit_test(vec![GraphicPlacement::browser(
            0,
            1,
            Rect { x: 0, y: 0, width: 10, height: 5 },
            1,
            10,
            5,
            "AAAA".to_string(),
        )]);
        attempt_rx
            .recv_timeout(Duration::from_secs(1))
            .expect("graphics writer never waited on the owned stdout lock");

        shutdown.cancel_for_panic_hook();
        drop(guard);
        return;
    }

    let current_exe = std::env::current_exe().expect("resolve current test executable");
    let mut child = std::process::Command::new(current_exe)
        .arg("panic_hook_cancellation_does_not_join_writer_waiting_on_owned_stdout")
        .arg("--nocapture")
        .env(CHILD_ENV, "1")
        .spawn()
        .expect("spawn isolated panic-hook regression");
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        if let Some(status) = child.try_wait().expect("poll panic-hook regression") {
            assert!(status.success(), "isolated panic-hook regression failed: {status}");
            break;
        }
        if Instant::now() >= deadline {
            child.kill().expect("kill deadlocked panic-hook regression");
            let _ = child.wait();
            panic!("panic hook joined a graphics writer waiting on its stdout lock");
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}
