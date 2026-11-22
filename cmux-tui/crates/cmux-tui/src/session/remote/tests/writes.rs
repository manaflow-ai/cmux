//! Request cancellation, shutdown ordering, and the interactive write queue.

use super::*;

#[derive(Default)]
struct BlockingWriteState {
    blocked: bool,
    entered: bool,
    aborted: bool,
    fail_on_release: bool,
}

#[derive(Clone)]
struct BlockingWriteControl {
    state: Arc<(Mutex<BlockingWriteState>, Condvar)>,
}

impl BlockingWriteControl {
    fn wait_until_entered(&self) {
        let deadline = Instant::now() + Duration::from_secs(1);
        let (state, changed) = &*self.state;
        let mut state = state.lock().unwrap();
        while !state.entered {
            let remaining = deadline.saturating_duration_since(Instant::now());
            assert!(!remaining.is_zero(), "interactive writer never entered the test stream");
            let (next, timeout) = changed.wait_timeout(state, remaining).unwrap();
            state = next;
            assert!(!timeout.timed_out() || state.entered);
        }
    }

    fn release(&self) {
        let (state, changed) = &*self.state;
        let mut state = state.lock().unwrap();
        state.blocked = false;
        drop(state);
        changed.notify_all();
    }

    fn fail(&self) {
        let (state, changed) = &*self.state;
        let mut state = state.lock().unwrap();
        state.fail_on_release = true;
        state.blocked = false;
        drop(state);
        changed.notify_all();
    }
}

#[derive(Clone)]
struct BlockingWriteStream {
    control: BlockingWriteControl,
    output: Arc<Mutex<Vec<u8>>>,
}

impl BlockingWriteStream {
    fn new() -> (Self, BlockingWriteControl) {
        let control = BlockingWriteControl {
            state: Arc::new((
                Mutex::new(BlockingWriteState {
                    blocked: true,
                    entered: false,
                    aborted: false,
                    fail_on_release: false,
                }),
                Condvar::new(),
            )),
        };
        (Self { control: control.clone(), output: Arc::new(Mutex::new(Vec::new())) }, control)
    }
}

impl RemoteMessageWriter for BlockingWriteStream {
    fn send(&mut self, message: &str) -> io::Result<()> {
        let (state, changed) = &*self.control.state;
        let mut state = state.lock().unwrap();
        state.entered = true;
        changed.notify_all();
        while state.blocked {
            state = changed.wait(state).unwrap();
        }
        if state.aborted {
            return Err(io::Error::new(io::ErrorKind::Interrupted, "test writer aborted"));
        }
        if state.fail_on_release {
            return Err(io::Error::new(io::ErrorKind::BrokenPipe, "scripted write failure"));
        }
        drop(state);
        let mut output = self.output.lock().unwrap();
        output.extend_from_slice(message.as_bytes());
        output.push(b'\n');
        Ok(())
    }

    fn close(&mut self) -> io::Result<()> {
        self.control.release();
        Ok(())
    }
}

struct BlockingWriteAbort {
    control: BlockingWriteControl,
}

impl RemoteTransportAbort for BlockingWriteAbort {
    fn abort(&self) -> io::Result<()> {
        let (state, changed) = &*self.control.state;
        let mut state = state.lock().unwrap();
        state.aborted = true;
        state.blocked = false;
        drop(state);
        changed.notify_all();
        Ok(())
    }
}

fn blocking_test_session(writer: BlockingWriteStream) -> Arc<RemoteSession> {
    let abort = Arc::new(BlockingWriteAbort { control: writer.control.clone() });
    test_session_with_abort_and_context(Box::new(writer), abort, HashSet::new(), None)
}

#[cfg(unix)]
#[test]
fn malformed_json_cancels_a_pending_request_and_preserves_decode_reason() {
    let (client, server) = UnixStream::pair().unwrap();
    let (release_tx, release_rx) = channel();
    let peer = std::thread::spawn(move || {
        let mut peer = BufReader::new(server);
        for expected_command in ["identify", "set-client-info", "subscribe"] {
            let mut line = String::new();
            peer.read_line(&mut line).unwrap();
            let request: Value = serde_json::from_str(&line).unwrap();
            assert_eq!(request["cmd"], expected_command);
            let data = if expected_command == "identify" {
                json!({
                    "app": "cmux-tui",
                    "protocol": SUPPORTED_PROTOCOL_VERSION,
                    "capabilities": ["browser-pointer-frame-guard-v1"],
                })
            } else {
                Value::Null
            };
            writeln!(peer.get_mut(), "{}", json!({"id": request["id"], "ok": true, "data": data}))
                .unwrap();
        }

        let mut line = String::new();
        peer.read_line(&mut line).unwrap();
        let request: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(request["cmd"], "wait-for-malformed");
        peer.get_mut().write_all(b"not-json\n").unwrap();
        release_rx.recv().unwrap();
    });
    let session = RemoteSession::connect_stream(Box::new(client)).unwrap();
    let request_session = session.clone();
    let (done_tx, done_rx) = channel();
    let request = std::thread::spawn(move || {
        done_tx.send(request_session.request(json!({"cmd": "wait-for-malformed"}))).unwrap();
    });

    let result = match done_rx.recv_timeout(Duration::from_secs(2)) {
        Ok(result) => result,
        Err(error) => {
            session.begin_shutdown();
            request.join().unwrap();
            release_tx.send(()).unwrap();
            peer.join().unwrap();
            panic!("malformed JSON did not cancel the request promptly: {error}");
        }
    };
    request.join().unwrap();
    release_tx.send(()).unwrap();
    peer.join().unwrap();

    let error = result.unwrap_err();
    assert!(
        matches!(error.downcast_ref::<RemoteRequestError>(), Some(RemoteRequestError::Shutdown)),
        "expected shutdown after malformed JSON canceled the request, got {error:?}"
    );
    assert!(
        session
            .transport_disconnect_reason()
            .is_some_and(|reason| reason.starts_with("remote JSON decode failed:")),
        "malformed JSON decode reason was not preserved: {:?}",
        session.transport_disconnect_reason()
    );
    assert!(session.pending.lock().unwrap().is_empty());
}

#[cfg(unix)]
#[test]
fn shutdown_cancels_response_wait_before_ordered_release_write() {
    let (client, server) = UnixStream::pair().unwrap();
    let session = socket_test_session(client);
    let waiting_session = session.clone();
    let waiting = std::thread::spawn(move || {
        waiting_session.request(json!({"cmd": "mutation"})).unwrap_err()
    });

    let mut peer = BufReader::new(server);
    let mut first_line = String::new();
    peer.read_line(&mut first_line).unwrap();
    let first: Value = serde_json::from_str(&first_line).unwrap();
    assert_eq!(first["cmd"], "mutation");

    session.begin_shutdown();
    assert!(waiting.join().unwrap().to_string().contains("canceled for shutdown"));

    let release_error = session.send_bytes(7, b"release").unwrap_err();
    assert!(release_error.to_string().contains("canceled for shutdown"));
    let mut release_line = String::new();
    peer.read_line(&mut release_line).unwrap();
    let release: Value = serde_json::from_str(&release_line).unwrap();
    assert_eq!(release["cmd"], "send");
    assert_eq!(release["surface"], 7);
    assert_eq!(release["bytes"], "cmVsZWFzZQ==");
    assert!(release["id"].as_u64().unwrap() > first["id"].as_u64().unwrap());
}

#[test]
fn shutdown_send_waits_for_ordered_write_completion() {
    let (stream, control) = BlockingWriteStream::new();
    let output = stream.output.clone();
    let session = blocking_test_session(stream);
    session.begin_shutdown();
    let (wait_started_rx, resume_wait_tx) =
        session.interactive_writer.gate_next_wait_until_written();

    let (finished_tx, finished_rx) = channel();
    let release_session = session.clone();
    let release = std::thread::spawn(move || {
        finished_tx.send(release_session.send_bytes(7, b"release")).unwrap();
    });
    let sequence = wait_started_rx.recv_timeout(Duration::from_secs(2)).unwrap();
    control.wait_until_entered();
    assert!(
        matches!(finished_rx.try_recv(), Err(std::sync::mpsc::TryRecvError::Empty)),
        "shutdown send returned before its ordered write completed"
    );

    control.release();
    resume_wait_tx.send(()).unwrap();
    let error = finished_rx.recv_timeout(remote_write_timeout() * 2).unwrap().unwrap_err();
    assert!(
        matches!(error.downcast_ref::<RemoteRequestError>(), Some(RemoteRequestError::Shutdown)),
        "expected shutdown after the ordered write completed, got {error:?}"
    );
    release.join().unwrap();
    let writer_state = session.interactive_writer.shared.state.lock().unwrap();
    assert!(writer_state.last_written_sequence >= sequence);
    drop(writer_state);
    assert!(!output.lock().unwrap().is_empty());
}

#[test]
fn begin_shutdown_waits_for_previously_accepted_input() {
    let (stream, control) = BlockingWriteStream::new();
    let output = stream.output.clone();
    let session = blocking_test_session(stream);
    session.send_bytes(7, b"accepted").unwrap();
    control.wait_until_entered();

    let sequence = session.interactive_writer.last_enqueued_sequence().unwrap().unwrap();
    let (wait_started_rx, resume_wait_tx) =
        session.interactive_writer.gate_next_wait_until_written();

    let (finished_tx, finished_rx) = channel();
    let shutdown_session = session.clone();
    let shutdown = std::thread::spawn(move || {
        shutdown_session.begin_shutdown();
        finished_tx.send(()).unwrap();
    });
    assert_eq!(wait_started_rx.recv_timeout(Duration::from_secs(2)).unwrap(), sequence);
    assert!(
        matches!(finished_rx.try_recv(), Err(std::sync::mpsc::TryRecvError::Empty)),
        "shutdown returned before previously accepted input was written"
    );

    control.release();
    resume_wait_tx.send(()).unwrap();
    finished_rx.recv_timeout(remote_write_timeout() * 2).unwrap();
    shutdown.join().unwrap();
    let writer_state = session.interactive_writer.shared.state.lock().unwrap();
    assert!(writer_state.last_written_sequence >= sequence);
    drop(writer_state);
    assert!(!output.lock().unwrap().is_empty());
}

#[test]
fn write_timeout_aborts_the_blocked_writer_and_discards_queued_mutations() {
    let (stream, control) = BlockingWriteStream::new();
    let output = stream.output.clone();
    let session = blocking_test_session(stream);
    session.send_bytes(7, b"blocked").unwrap();
    control.wait_until_entered();
    session.send_bytes(7, b"queued").unwrap();
    let sequence = session.interactive_writer.last_enqueued_sequence().unwrap().unwrap();

    let started = Instant::now();
    let error = session.wait_for_ordered_write(sequence).unwrap_err();
    assert_eq!(error.kind(), io::ErrorKind::TimedOut);
    assert!(started.elapsed() < remote_write_timeout() * 5);
    let deadline = Instant::now() + remote_write_timeout();
    loop {
        let state = session.interactive_writer.shared.state.lock().unwrap();
        if state.writer_closed {
            assert!(state.writes.is_empty());
            assert_eq!(state.queued_bytes, 0);
            break;
        }
        drop(state);
        assert!(Instant::now() < deadline, "aborted writer did not exit");
        std::thread::yield_now();
    }
    assert!(control.state.0.lock().unwrap().aborted);
    assert!(output.lock().unwrap().is_empty());
    let error = session.send_bytes(7, b"late").unwrap_err();
    assert!(error.downcast_ref::<RemoteRequestError>().is_some_and(|error| {
        matches!(error, RemoteRequestError::Transport(io_error)
            if io_error.kind() == io::ErrorKind::TimedOut)
    }));
}

#[test]
fn dropping_a_session_aborts_a_blocked_writer() {
    let (stream, control) = BlockingWriteStream::new();
    let session = blocking_test_session(stream);
    session.send_bytes(7, b"blocked").unwrap();
    control.wait_until_entered();

    drop(session);

    let deadline = Instant::now() + remote_write_timeout();
    loop {
        let state = control.state.0.lock().unwrap();
        if state.aborted {
            break;
        }
        drop(state);
        assert!(Instant::now() < deadline, "dropped session did not abort writer");
        std::thread::yield_now();
    }
}

#[test]
fn closing_a_session_aborts_a_writer_that_cannot_drain() {
    let (stream, control) = BlockingWriteStream::new();
    let session = blocking_test_session(stream);
    session.send_bytes(7, b"blocked").unwrap();
    control.wait_until_entered();

    let started = Instant::now();
    session.disconnect_transport();

    assert!(started.elapsed() < remote_write_timeout() * 5);
    let state = control.state.0.lock().unwrap();
    assert!(state.aborted);
    drop(state);
    let state = session.interactive_writer.shared.state.lock().unwrap();
    assert!(state.writer_closed);
    assert!(matches!(
        state.failure,
        Some(ref failure) if failure.kind == io::ErrorKind::TimedOut
    ));
}

#[test]
fn send_failure_wakes_every_waiter_and_discards_the_queue() {
    let (stream, control) = BlockingWriteStream::new();
    let output = stream.output.clone();
    let session = blocking_test_session(stream);
    let first = session.interactive_writer.enqueue("first".into(), true).unwrap();
    control.wait_until_entered();
    let second = session.interactive_writer.enqueue("second".into(), true).unwrap();
    let (finished_tx, finished_rx) = channel();
    let mut waiters = Vec::new();
    for sequence in [first, second] {
        let session = session.clone();
        let finished_tx = finished_tx.clone();
        waiters.push(std::thread::spawn(move || {
            finished_tx
                .send(
                    session
                        .interactive_writer
                        .wait_until_written(sequence, remote_write_timeout() * 2),
                )
                .unwrap();
        }));
    }

    control.fail();
    for _ in 0..2 {
        let error = finished_rx
            .recv_timeout(remote_write_timeout() * 2)
            .expect("write failure did not wake a waiter")
            .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::BrokenPipe);
    }
    for waiter in waiters {
        waiter.join().unwrap();
    }
    let state = session.interactive_writer.shared.state.lock().unwrap();
    assert!(state.writes.is_empty());
    assert_eq!(state.queued_bytes, 0);
    assert!(state.writer_closed);
    drop(state);
    assert!(output.lock().unwrap().is_empty());
    assert_eq!(session.interactive_write_metrics().write_failures, 1);
}

#[cfg(unix)]
#[test]
fn keystroke_write_does_not_wait_for_command_response() {
    let (client, server) = UnixStream::pair().unwrap();
    let session = socket_test_session(client);
    let (finished_tx, finished_rx) = channel();
    let sender_session = session.clone();
    let sender = std::thread::spawn(move || {
        finished_tx.send(sender_session.send_bytes(9, b"x")).unwrap();
    });

    let mut peer = BufReader::new(server);
    let mut line = String::new();
    peer.read_line(&mut line).unwrap();
    let command: Value = serde_json::from_str(&line).unwrap();
    assert_eq!(command["cmd"], "send");
    assert_eq!(command["surface"], 9);
    assert_eq!(command["bytes"], "eA==");
    assert_eq!(command["no_reply"], true);
    assert!(finished_rx.recv_timeout(Duration::from_millis(100)).unwrap().is_ok());
    sender.join().unwrap();
    assert_eq!(Arc::strong_count(&session), 1);
}

#[cfg(unix)]
#[test]
fn accepted_interactive_writes_remain_fifo() {
    let (client, server) = UnixStream::pair().unwrap();
    let session = socket_test_session(client);
    session.send_bytes(7, b"release").unwrap();
    session.send_bytes(7, b"press").unwrap();

    let mut peer = BufReader::new(server);
    let mut first = String::new();
    let mut second = String::new();
    peer.read_line(&mut first).unwrap();
    peer.read_line(&mut second).unwrap();
    let first: Value = serde_json::from_str(&first).unwrap();
    let second: Value = serde_json::from_str(&second).unwrap();
    assert_eq!(first["bytes"], "cmVsZWFzZQ==");
    assert_eq!(second["bytes"], "cHJlc3M=");
    assert!(first["id"].as_u64().unwrap() < second["id"].as_u64().unwrap());
    session.begin_shutdown();
    let metrics = session.interactive_write_metrics();
    assert_eq!(metrics.samples, 2);
    assert_eq!(metrics.histogram.iter().map(|bucket| bucket.samples).sum::<u64>(), 2);
    assert!(metrics.p50.is_some());
    assert!(metrics.p95.is_some());
    assert!(metrics.p99.is_some());
}

#[test]
fn control_request_cannot_overtake_accepted_interactive_writes() {
    let (stream, control) = BlockingWriteStream::new();
    let output = stream.output.clone();
    let session = blocking_test_session(stream);
    session.send_bytes(7, b"first").unwrap();
    control.wait_until_entered();
    session.send_bytes(7, b"release").unwrap();

    let request_session = session.clone();
    let request = std::thread::spawn(move || {
        request_session.request(json!({"cmd": "mutation"})).unwrap_err()
    });
    let deadline = Instant::now() + Duration::from_secs(1);
    while session.interactive_writer.last_enqueued_sequence().unwrap() != Some(3) {
        assert!(Instant::now() < deadline, "control request was not queued");
        std::thread::yield_now();
    }

    control.release();
    session.begin_shutdown();
    assert!(request.join().unwrap().to_string().contains("canceled for shutdown"));
    let output = String::from_utf8(output.lock().unwrap().clone()).unwrap();
    let commands =
        output.lines().map(|line| serde_json::from_str::<Value>(line).unwrap()).collect::<Vec<_>>();
    assert_eq!(commands.len(), 3);
    assert_eq!(commands[0]["bytes"], "Zmlyc3Q=");
    assert_eq!(commands[1]["bytes"], "cmVsZWFzZQ==");
    assert_eq!(commands[2]["cmd"], "mutation");
}

#[test]
fn interactive_queue_saturation_fails_without_waiting_for_the_writer() {
    let (stream, control) = BlockingWriteStream::new();
    let session = blocking_test_session(stream);
    session.send_bytes(7, b"in-flight").unwrap();
    control.wait_until_entered();
    for _ in 0..INTERACTIVE_WRITE_QUEUE_CAPACITY {
        session.send_bytes(7, b"queued").unwrap();
    }

    let overflow_session = session.clone();
    let (finished_tx, finished_rx) = channel();
    let overflow = std::thread::spawn(move || {
        finished_tx.send(overflow_session.send_bytes(7, b"overflow")).unwrap();
    });
    let error = finished_rx
        .recv_timeout(Duration::from_millis(100))
        .expect("queue rejection waited for the blocked writer")
        .unwrap_err();
    assert!(error.downcast_ref::<RemoteRequestError>().is_some_and(|error| {
        matches!(error, RemoteRequestError::Transport(io_error)
            if io_error.kind() == io::ErrorKind::WouldBlock)
    }));
    let metrics = session.interactive_write_metrics();
    assert_eq!(metrics.backpressure_rejections, 1);
    control.release();
    overflow.join().unwrap();
}

#[test]
fn latency_histogram_reports_fixed_bucket_percentiles() {
    let metrics = InteractiveWriteMetrics::default();
    for latency in [
        Duration::from_micros(10),
        Duration::from_micros(80),
        Duration::from_micros(200),
        Duration::from_micros(900),
        Duration::from_millis(20),
    ] {
        metrics.record_latency(latency);
    }

    let snapshot = metrics.snapshot();
    assert_eq!(snapshot.samples, 5);
    assert_eq!(snapshot.write_failures, 0);
    assert_eq!(snapshot.backpressure_rejections, 0);
    assert_eq!(snapshot.p50, Some(Duration::from_micros(250)));
    assert_eq!(snapshot.p95, Some(Duration::from_millis(25)));
    assert_eq!(snapshot.p99, Some(Duration::from_millis(25)));
    assert_eq!(snapshot.histogram.iter().map(|bucket| bucket.samples).sum::<u64>(), 5);
}
