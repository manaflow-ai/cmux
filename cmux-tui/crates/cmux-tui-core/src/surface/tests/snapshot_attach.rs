//! Snapshot viewer queue, request gate and position tests.

use super::*;
use crate::stream_interrupt::StreamInterrupt;

fn next_event(receiver: &AttachFrameReceiver) -> ViewerEvent {
    let interrupt = StreamInterrupt::new();
    receiver
        .recv_viewer_event(&interrupt, Some(Instant::now() + Duration::from_secs(5)))
        .expect("viewer event")
}

fn is_snapshot(event: &ViewerEvent) -> bool {
    matches!(event, ViewerEvent::Snapshot)
}

#[test]
fn snapshot_viewer_starts_with_a_snapshot_then_live_bytes() {
    let lifecycle = AttachLifecycle::default();
    let (tap, receiver) = AttachTap::snapshot_pair(lifecycle, 16, 1024);
    assert!(is_snapshot(&next_event(&receiver)));
    receiver.finish_snapshot_locked();
    assert!(tap.try_send(AttachFrame::Output(b"abc".to_vec())));
    match next_event(&receiver) {
        ViewerEvent::Frame(AttachFrame::Output(bytes)) => {
            assert_eq!(bytes, b"abc");
        }
        other => panic!("expected output, got {other:?}"),
    }
}

#[test]
fn snapshot_viewer_overflow_resyncs_instead_of_disconnecting() {
    let lifecycle = AttachLifecycle::default();
    let (tap, receiver) = AttachTap::snapshot_pair(lifecycle.clone(), 16, 4096);
    receiver.finish_snapshot_locked();
    // A slow viewer: nothing drains. Offer far more than the cap.
    for _ in 0..1000 {
        assert!(tap.try_send(AttachFrame::Output(vec![b'x'; 1000])));
        assert!(receiver.backlog_bytes() <= 4096);
    }
    assert!(!lifecycle.is_canceled());
    assert!(!lifecycle.overflowed());
    assert_eq!(receiver.resyncs(), 1);
    // Behind: the next event is a snapshot, and no stale byte follows it.
    assert!(is_snapshot(&next_event(&receiver)));
    receiver.finish_snapshot_locked();
    assert!(matches!(receiver.try_recv(), Err(TryRecvError::Empty)));
}

#[test]
fn legacy_viewer_overflow_still_disconnects() {
    let lifecycle = AttachLifecycle::default();
    let (tap, _receiver) = AttachTap::pair(lifecycle.clone(), 16, 4096);
    let mut accepted = true;
    for _ in 0..100 {
        accepted &= tap.try_send(AttachFrame::Output(vec![b'x'; 1000]));
    }
    assert!(!accepted);
    assert!(lifecycle.overflowed());
}

#[test]
fn grid_change_reaches_a_snapshot_viewer_as_a_snapshot() {
    let lifecycle = AttachLifecycle::default();
    let (tap, receiver) = AttachTap::snapshot_pair(lifecycle, 16, 1 << 20);
    receiver.finish_snapshot_locked();
    assert!(tap.try_send(AttachFrame::Output(b"before".to_vec())));
    assert!(tap.try_send(AttachFrame::Resized {
        cols: 10,
        rows: 5,
        replay: Arc::from(&b"replay"[..]),
        kitty_image_aliases: Vec::new(),
        kitty_state: KittyReplayState::default(),
        pending_sequence: Arc::from([]),
    }));
    assert!(tap.try_send(AttachFrame::Output(b"after".to_vec())));
    assert!(is_snapshot(&next_event(&receiver)));
}

#[test]
fn stream_position_counts_output_and_grid_generations() {
    let position = SnapshotStreamPosition::default();
    position.add_output(5);
    position.observe_frame(&AttachFrame::OutputWithColors {
        output: vec![0; 7],
        colors: Box::default(),
    });
    position.observe_frame(&AttachFrame::ColorsChanged(Arc::new(TerminalColors::default())));
    assert_eq!(position.load(), (0, 12));
    position.observe_frame(&AttachFrame::Resized {
        cols: 1,
        rows: 1,
        replay: Arc::from([]),
        kitty_image_aliases: Vec::new(),
        kitty_state: KittyReplayState::default(),
        pending_sequence: Arc::from([]),
    });
    assert_eq!(position.load(), (1, 12));
}

#[test]
fn duplicate_snapshot_requests_collapse_into_one_snapshot() {
    let lifecycle = AttachLifecycle::default();
    let (tap, receiver) = AttachTap::snapshot_pair(lifecycle, 16, 1 << 20);
    let gate = SnapshotRequestGate::new(receiver.snapshot_request_handle());
    let start = Instant::now();
    // The attach snapshot is pending: a request now collapses into it.
    assert_eq!(gate.request(start), SnapshotAdmission::Collapsed);
    receiver.finish_snapshot_locked();
    gate.sent(start);
    let later = start + SNAPSHOT_REQUEST_MIN_INTERVAL;
    assert_eq!(gate.request(later), SnapshotAdmission::Accepted);
    // Same or another request id while that snapshot is in flight: collapsed.
    assert_eq!(gate.request(later), SnapshotAdmission::Collapsed);
    assert_eq!(gate.request(later + Duration::from_millis(1)), SnapshotAdmission::Collapsed);
    assert!(tap.try_send(AttachFrame::Output(b"x".to_vec())));
    assert!(is_snapshot(&next_event(&receiver)));
    receiver.finish_snapshot_locked();
    gate.sent(later);
    // Exactly one snapshot answered all three requests.
    assert!(matches!(receiver.try_recv(), Err(TryRecvError::Empty)));
}

#[test]
fn snapshot_requests_are_throttled_per_viewer() {
    let lifecycle = AttachLifecycle::default();
    let (_tap, receiver) = AttachTap::snapshot_pair(lifecycle, 16, 1 << 20);
    let gate = SnapshotRequestGate::new(receiver.snapshot_request_handle());
    let start = Instant::now();
    receiver.finish_snapshot_locked();
    gate.sent(start);
    assert_eq!(
        gate.request(start + Duration::from_millis(200)),
        SnapshotAdmission::Throttled { retry_after_ms: 300 }
    );
    assert_eq!(gate.request(start + SNAPSHOT_REQUEST_MIN_INTERVAL), SnapshotAdmission::Accepted);
}

#[test]
fn snapshot_request_after_the_viewer_left_is_not_attached() {
    let lifecycle = AttachLifecycle::default();
    let (tap, receiver) = AttachTap::snapshot_pair(lifecycle, 16, 1 << 20);
    let gate = SnapshotRequestGate::new(receiver.snapshot_request_handle());
    receiver.finish_snapshot_locked();
    gate.sent(Instant::now() - SNAPSHOT_REQUEST_MIN_INTERVAL);
    drop(receiver);
    drop(tap);
    assert_eq!(gate.request(Instant::now()), SnapshotAdmission::NotAttached);
}

/// Deterministic flood stream shaped like `schemas/terminal-corpus/generate.py
/// --flood-out`: colored numbered lines of 10..=150 filler bytes.
fn flood_chunk(line: &mut u64, rng: &mut u64, target: usize) -> Vec<u8> {
    let mut out = Vec::with_capacity(target + 256);
    while out.len() < target {
        *rng = rng.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        let filler = 10 + ((*rng >> 33) % 141) as usize;
        out.extend_from_slice(format!("\x1b[3{}m{:09} ", *line % 8, *line).as_bytes());
        out.extend(std::iter::repeat_n(b'x', filler));
        out.extend_from_slice(b"\x1b[0m\r\n");
        *line += 1;
    }
    out
}

/// A slow viewer (it never drains, no credit) under a flood: host memory for
/// the viewer stays within the backlog cap, the viewer is resynced by a
/// snapshot instead of disconnected, and the snapshot it receives equals the
/// host terminal's. Size:
/// `CMUX_TERMINAL_FLOOD_BYTES` (default 100 MB, the plan's run), or the bytes
/// of `CMUX_TERMINAL_FLOOD_FILE` (generate.py --flood-out). The timing line is
/// also appended to `$GITHUB_STEP_SUMMARY` when CI sets it.
#[test]
fn flood_with_a_slow_snapshot_viewer_stays_bounded_and_resyncs() {
    let mux = Mux::new_for_test("snapshot-flood", SurfaceOptions::default());
    let surface =
        Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
    let pty = surface.as_pty().unwrap();
    let cap = DEFAULT_VIEWER_BACKLOG_BYTES;
    let stream = surface.attach_snapshot_stream(AttachLifecycle::default(), cap, false).unwrap();
    let first = surface.take_viewer_snapshot(&stream.receiver).unwrap();
    stream.requests.sent(Instant::now());

    let file =
        std::env::var_os("CMUX_TERMINAL_FLOOD_FILE").map(|path| std::fs::read(path).unwrap());
    let total: usize = match &file {
        Some(bytes) => bytes.len(),
        None => std::env::var("CMUX_TERMINAL_FLOOD_BYTES")
            .ok()
            .and_then(|value| value.parse().ok())
            .unwrap_or(100 * 1024 * 1024),
    };
    let (mut line, mut rng, mut fed, mut max_backlog) = (0u64, 42u64, 0usize, 0usize);
    let started = Instant::now();
    while fed < total {
        let chunk = match &file {
            Some(bytes) => bytes[fed..(fed + 65_536).min(bytes.len())].to_vec(),
            None => flood_chunk(&mut line, &mut rng, 65_536.min(total - fed)),
        };
        fed += chunk.len();
        // The reader's path: parse and broadcast under the terminal lock.
        let mut term = pty.term.lock().unwrap();
        let normalized = term.vt_write_with_normalized(&chunk).into_owned();
        pty.broadcast_attach_output(&normalized);
        drop(term);
        max_backlog = max_backlog.max(stream.receiver.backlog_bytes());
        assert!(stream.receiver.backlog_bytes() <= cap, "backlog above the cap after {fed} B");
    }
    let parse_elapsed = started.elapsed();
    assert!(!stream.lifecycle.is_canceled() && !stream.lifecycle.overflowed());
    assert!(stream.receiver.resyncs() >= 1);

    // The viewer drains: its next event is a snapshot, not the backlog.
    assert!(is_snapshot(&next_event(&stream.receiver)));
    let resync_started = Instant::now();
    let last = surface.take_viewer_snapshot(&stream.receiver).unwrap();
    let resync_elapsed = resync_started.elapsed();
    assert!(last.offset >= first.offset + fed as u64, "offset counts every published byte");
    let host = surface.encode_terminal_snapshot(SnapshotPhase::Ready).unwrap();
    // The shell may print between the two encodes; compare when quiet.
    if surface.snapshot_stream_position() == Some((last.generation, last.offset)) {
        assert_eq!(last.data, host, "the viewer's snapshot equals the host terminal's");
    }
    let report = format!(
        "flood: {fed} B in {parse_elapsed:?} ({:.1} MB/s), max viewer backlog {max_backlog} B \
         (cap {cap}), resyncs {}, resync snapshot {} B in {resync_elapsed:?}",
        fed as f64 / parse_elapsed.as_secs_f64() / 1e6,
        stream.receiver.resyncs(),
        last.data.len()
    );
    // Direct stderr writes bypass libtest capture, so CI logs keep the timing.
    let _ = std::io::stderr().write_all(format!("{report}\n").as_bytes());
    if let Some(summary) = std::env::var_os("GITHUB_STEP_SUMMARY") {
        use std::io::Write as _;
        let mut file = std::fs::OpenOptions::new().append(true).open(summary).unwrap();
        writeln!(file, "- {report}").unwrap();
    }
    drop(stream);
    surface.kill();
}

#[test]
fn a_deferred_snapshot_does_not_keep_requests_collapsed() {
    let lifecycle = AttachLifecycle::default();
    let (tap, receiver) = AttachTap::snapshot_pair(lifecycle, 16, 1 << 20);
    let gate = SnapshotRequestGate::new(receiver.snapshot_request_handle());
    let start = Instant::now();
    // The first snapshot could not be encoded: deferred, not pending.
    receiver.defer_snapshot();
    gate.sent(start);
    let later = start + SNAPSHOT_REQUEST_MIN_INTERVAL;
    assert_eq!(gate.request(later), SnapshotAdmission::Accepted);
    assert!(is_snapshot(&next_event(&receiver)));
    // Deferred again; the next output asks for the snapshot by itself.
    receiver.defer_snapshot();
    gate.sent(later);
    assert!(tap.try_send(AttachFrame::Output(b"more".to_vec())));
    assert!(is_snapshot(&next_event(&receiver)));
    receiver.finish_snapshot_locked();
    assert!(tap.try_send(AttachFrame::Output(b"live".to_vec())));
    assert!(matches!(next_event(&receiver), ViewerEvent::Frame(AttachFrame::Output(_))));
}

#[test]
fn snapshot_encode_waits_for_an_oversized_escape_sequence_to_finish() {
    let mux = Mux::new_for_test("snapshot-deferred", SurfaceOptions::default());
    let surface =
        Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
    let pty = surface.as_pty().unwrap();
    let stream = surface.attach_snapshot_stream(AttachLifecycle::default(), 1 << 20, false).unwrap();
    // An OSC longer than the 1 MiB snapshot continuation budget.
    {
        let mut term = pty.term.lock().unwrap();
        let mut osc = b"\x1b]2;".to_vec();
        osc.extend(std::iter::repeat_n(b'x', 2 << 20));
        let normalized = term.vt_write_with_normalized(&osc).into_owned();
        pty.broadcast_attach_output(&normalized);
    }
    assert!(is_snapshot(&next_event(&stream.receiver)));
    assert!(surface.take_viewer_snapshot(&stream.receiver).is_err());
    stream.receiver.defer_snapshot();
    // The sequence ends; the next output brings the snapshot back.
    {
        let mut term = pty.term.lock().unwrap();
        let normalized = term.vt_write_with_normalized(b"\x07done").into_owned();
        pty.broadcast_attach_output(&normalized);
    }
    assert!(is_snapshot(&next_event(&stream.receiver)));
    assert!(surface.take_viewer_snapshot(&stream.receiver).is_ok());
    drop(stream);
    surface.kill();
}

#[test]
fn only_a_grid_change_resyncs_a_snapshot_viewer() {
    let mux = Mux::new_for_test("snapshot-grid-only", SurfaceOptions::default());
    let surface =
        Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
    let stream = surface.attach_snapshot_stream(AttachLifecycle::default(), 1 << 20, false).unwrap();
    surface.take_viewer_snapshot(&stream.receiver).unwrap();
    let (generation, _) = surface.snapshot_stream_position().unwrap();
    let (width, height) = surface.cell_pixel_size();
    surface.set_cell_pixel_size(width + 1, height + 1).unwrap();
    assert_eq!(stream.receiver.resyncs(), 0, "a pixel-only change reflows nothing");
    assert_eq!(surface.snapshot_stream_position().unwrap().0, generation);
    surface.resize(40, 10).unwrap();
    assert_eq!(stream.receiver.resyncs(), 1);
    assert!(surface.snapshot_stream_position().unwrap().0 > generation);
    drop(stream);
    surface.kill();
}

/// Cost of the viewer snapshot under the terminal lock with scrollback
/// (`terminal-snapshot-history-v1` encodes COMPLETE). Run on a Testbox:
/// `cargo test -p cmux-tui-core --release --lib snapshot_history_encode_cost -- --ignored --nocapture`.
#[test]
#[ignore = "measurement"]
fn snapshot_history_encode_cost() {
    for lines in [10_000usize, 100_000] {
        let mut term =
            Terminal::new(80, 24, DEFAULT_SCROLLBACK_LIMIT_BYTES, Callbacks::default()).unwrap();
        for line in 0..lines {
            term.vt_write(
                format!(
                    "\x1b[32m{line:06}\x1b[0m compiling crate-{} v0.{}.{} (/home/dev/src/project/crates/c{}) in {}ms\r\n",
                    line % 977,
                    line % 13,
                    line % 101,
                    line % 31,
                    line % 4099
                )
                .as_bytes(),
            );
        }
        let runs = 5;
        let mut ready_time = Duration::ZERO;
        let mut complete_time = Duration::ZERO;
        let (mut ready_len, mut complete_len) = (0, 0);
        for _ in 0..runs {
            let started = Instant::now();
            ready_len = term.encode_snapshot(SnapshotPhase::Ready).unwrap().len();
            ready_time += started.elapsed();
            let started = Instant::now();
            let complete = term.encode_snapshot(SnapshotPhase::Complete).unwrap();
            complete_time += started.elapsed();
            complete_len = complete.len();
            assert_eq!(ghostty_vt::snapshot_ready_len(&complete), Some(ready_len));
        }
        println!(
            "snapshot-history-cost lines={lines} history_rows={} ready_bytes={ready_len} \
             history_bytes={} complete_bytes={complete_len} ready_ms={:.3} complete_ms={:.3}",
            term.history_rows(),
            complete_len - ready_len,
            ready_time.as_secs_f64() * 1000.0 / runs as f64,
            complete_time.as_secs_f64() * 1000.0 / runs as f64,
        );
    }
}

/// Grid changes before the worker takes its snapshot collapse into one
/// pending snapshot (the queue keeps a flag, not one event per change).
#[test]
fn a_burst_of_grid_changes_queues_one_snapshot() {
    let lifecycle = AttachLifecycle::default();
    let (tap, receiver) = AttachTap::snapshot_pair(lifecycle, 64, 1 << 20);
    receiver.finish_snapshot_locked();
    for cols in 0..10u16 {
        assert!(tap.try_send(AttachFrame::Resized {
            cols: 60 + cols,
            rows: 20,
            replay: Arc::from(&b"replay"[..]),
            kitty_image_aliases: Vec::new(),
            kitty_state: KittyReplayState::default(),
            pending_sequence: Arc::from([]),
        }));
    }
    assert_eq!(receiver.resyncs(), 1, "ten grid changes ask for one snapshot");
    assert!(is_snapshot(&next_event(&receiver)));
    receiver.finish_snapshot_locked();
    let interrupt = StreamInterrupt::new();
    assert!(
        receiver.recv_viewer_event(&interrupt, Some(Instant::now())).is_err(),
        "nothing else is queued after the one snapshot"
    );
}

// ---- terminal-snapshot-local-history-v1 -------------------------------

fn local_ready(generation: u64, offset: u64, cols: u16) -> Arc<LocalReadySnapshot> {
    Arc::new(LocalReadySnapshot {
        frame: TerminalSnapshotFrame {
            generation,
            offset,
            version: 1,
            cols,
            rows: 20,
            data: vec![0; 64],
            history: Vec::new(),
            colors: TerminalColors::default(),
            marker_epoch: 0,
            active_top_marker: 0,
        },
        history_rows: 7,
        history_digest: vec![0xab; 32],
    })
}

fn resized(cols: u16) -> AttachFrame {
    AttachFrame::Resized {
        cols,
        rows: 20,
        replay: Arc::from(&b"replay"[..]),
        kitty_image_aliases: Vec::new(),
        kitty_state: KittyReplayState::default(),
        pending_sequence: Arc::from([]),
    }
}

fn local_viewer(backlog: usize) -> (AttachTap, AttachFrameReceiver) {
    let (tap, receiver) = AttachTap::snapshot_pair(AttachLifecycle::default(), 64, backlog);
    receiver.set_local_history(true);
    (tap, receiver)
}

fn expect_output(event: ViewerEvent, expected: &[u8]) {
    match event {
        ViewerEvent::Frame(AttachFrame::Output(bytes)) => assert_eq!(bytes, expected),
        other => panic!("expected output {expected:?}, got {other:?}"),
    }
}

fn expect_local(event: ViewerEvent) -> Arc<LocalReadySnapshot> {
    match event {
        ViewerEvent::LocalReady(ready) => ready,
        other => panic!("expected a local READY, got {other:?}"),
    }
}

/// A caught-up local-history viewer keeps every frame before the resize,
/// then the local READY, then the frames after it.
#[test]
fn a_resize_queues_a_local_ready_after_the_pending_frames() {
    let (tap, receiver) = local_viewer(1 << 20);
    receiver.finish_snapshot_locked();
    assert!(tap.wants_local_ready());
    assert!(tap.try_send(AttachFrame::Output(b"before".to_vec())));
    let ready = local_ready(1, 6, 60);
    tap.resync_snapshot_at_cut(Some(&ready));
    assert!(tap.try_send(AttachFrame::Output(b"after".to_vec())));
    expect_output(next_event(&receiver), b"before");
    assert!(Arc::ptr_eq(&expect_local(next_event(&receiver)), &ready));
    expect_output(next_event(&receiver), b"after");
    assert_eq!(receiver.resyncs(), 0);
}

/// With replay viewers attached the resize carries a replay frame; a
/// local-history viewer still gets the local READY in order, not a resync.
#[test]
fn a_resize_frame_reaches_a_local_history_viewer_as_its_local_ready() {
    let (tap, receiver) = local_viewer(1 << 20);
    receiver.finish_snapshot_locked();
    assert!(tap.try_send(AttachFrame::Output(b"before".to_vec())));
    let ready = local_ready(1, 6, 60);
    assert!(tap.try_send_resize(resized(60), Some(&ready)));
    expect_output(next_event(&receiver), b"before");
    assert!(Arc::ptr_eq(&expect_local(next_event(&receiver)), &ready));
    assert_eq!(receiver.resyncs(), 0);
}

/// A burst of resizes queues one local READY per resize, in order.
#[test]
fn a_burst_of_resizes_queues_one_local_ready_each() {
    let (tap, receiver) = local_viewer(1 << 20);
    receiver.finish_snapshot_locked();
    let readies: Vec<_> = (0..10u16).map(|step| local_ready(1 + u64::from(step), 0, 60 + step)).collect();
    for ready in &readies {
        tap.resync_snapshot_at_cut(Some(ready));
    }
    for ready in &readies {
        assert!(Arc::ptr_eq(&expect_local(next_event(&receiver)), ready));
    }
    let interrupt = StreamInterrupt::new();
    assert!(receiver.recv_viewer_event(&interrupt, Some(Instant::now())).is_err());
}

/// A viewer that is behind (a snapshot pending or deferred) keeps the
/// READY with history at a later cut.
#[test]
fn a_behind_local_history_viewer_resyncs_by_snapshot() {
    let ready = local_ready(1, 0, 60);
    // The attach snapshot is still pending.
    let (tap, receiver) = local_viewer(1 << 20);
    assert!(!tap.wants_local_ready());
    tap.resync_snapshot_at_cut(Some(&ready));
    assert!(is_snapshot(&next_event(&receiver)));
    receiver.finish_snapshot_locked();
    assert!(matches!(receiver.try_recv(), Err(TryRecvError::Empty)));
    // A deferred snapshot.
    let (tap, receiver) = local_viewer(1 << 20);
    receiver.defer_snapshot();
    assert!(!tap.wants_local_ready());
    assert!(tap.try_send_resize(resized(60), Some(&ready)));
    assert!(is_snapshot(&next_event(&receiver)));
}

/// A local READY over the viewer's backlog cap is an overflow: the viewer
/// resyncs by snapshot instead.
#[test]
fn a_local_ready_over_the_backlog_cap_resyncs() {
    let (tap, receiver) = local_viewer(1024);
    receiver.finish_snapshot_locked();
    let mut big = local_ready(1, 0, 60);
    Arc::get_mut(&mut big).unwrap().frame.data = vec![0; 4096];
    tap.resync_snapshot_at_cut(Some(&big));
    assert_eq!(receiver.resyncs(), 1);
    assert!(is_snapshot(&next_event(&receiver)));
}

/// A viewer that did not opt in resyncs exactly as before.
#[test]
fn a_viewer_without_local_history_ignores_local_readies() {
    let (tap, receiver) = AttachTap::snapshot_pair(AttachLifecycle::default(), 64, 1 << 20);
    receiver.finish_snapshot_locked();
    assert!(!tap.wants_local_ready());
    let ready = local_ready(1, 0, 60);
    assert!(tap.try_send(AttachFrame::Output(b"dropped".to_vec())));
    assert!(tap.try_send_resize(resized(60), Some(&ready)));
    assert_eq!(receiver.resyncs(), 1);
    assert!(is_snapshot(&next_event(&receiver)));
}
