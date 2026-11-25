use std::io::Cursor;
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicBool, AtomicUsize};

use protocol::{MachineSecret, MigrationToken, PairingCode};

use super::super::transport::duplex_from_unix_stream;
use super::*;

struct AtomicStop(AtomicBool);

impl AtomicStop {
    fn new() -> Arc<Self> {
        Arc::new(Self(AtomicBool::new(false)))
    }

    fn stop(&self) {
        self.0.store(true, Ordering::Release);
    }
}

impl StopSignal for AtomicStop {
    fn requested(&self) -> bool {
        self.0.load(Ordering::Acquire)
    }
}

#[derive(Default)]
struct TestReporter {
    codes: Mutex<Vec<String>>,
    retries: Mutex<Vec<Duration>>,
    migrations: AtomicUsize,
    diagnostics: Mutex<Vec<MachineAgentDiagnostic>>,
    /// Signals that the old generation's peer received its
    /// `GenerationRejected`. When set, each diagnostic first waits up to
    /// `REJECTION_ORDER_WINDOW` for that signal, so a runtime that tells
    /// the peer before it reports is caught in every run.
    peer_rejected: Mutex<Option<Receiver<()>>>,
    /// A diagnostic was reported after the peer already had the rejection.
    reported_after_rejection: AtomicBool,
}

/// How long a diagnostic waits to see whether the peer already has the
/// rejection. The correct order sends the rejection only after the
/// report, so this wait always runs out there.
const REJECTION_ORDER_WINDOW: Duration = Duration::from_millis(200);

impl Reporter for TestReporter {
    fn pairing_code(&self, code: &str) -> io::Result<()> {
        self.codes.lock().unwrap().push(code.to_string());
        Ok(())
    }

    fn registered(&self, _: &str) {}

    fn retrying(&self, delay: Duration) {
        self.retries.lock().unwrap().push(delay);
    }

    fn migration_failed(&self) {
        self.migrations.fetch_add(1, Ordering::Relaxed);
    }

    fn diagnostic(&self, diagnostic: MachineAgentDiagnostic) {
        if let Some(peer_rejected) = self.peer_rejected.lock().unwrap().as_ref()
            && peer_rejected.recv_timeout(REJECTION_ORDER_WINDOW).is_ok()
        {
            self.reported_after_rejection.store(true, Ordering::Release);
        }
        self.diagnostics.lock().unwrap().push(diagnostic);
    }
}

#[derive(Default)]
struct FailingPairingReporter {
    registered: AtomicBool,
}

impl Reporter for FailingPairingReporter {
    fn pairing_code(&self, _: &str) -> io::Result<()> {
        Err(io::Error::new(io::ErrorKind::BrokenPipe, "test terminal closed"))
    }

    fn registered(&self, _: &str) {
        self.registered.store(true, Ordering::Release);
    }

    fn retrying(&self, _: Duration) {}

    fn migration_failed(&self) {}

    fn diagnostic(&self, _: MachineAgentDiagnostic) {}
}

#[derive(Default)]
struct RecordingControl(AtomicBool);

impl ConnectionControl for RecordingControl {
    fn close(&self) {
        self.0.store(true, Ordering::Release);
    }
}

#[derive(Clone, Default)]
struct RecordingWriter(Arc<Mutex<Vec<u8>>>);

impl Write for RecordingWriter {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.0.lock().unwrap().extend_from_slice(bytes);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

impl RecordingWriter {
    fn read_frame(&self) -> Envelope {
        let bytes = self.0.lock().unwrap().clone();
        protocol_io::read_frame(&mut BufReader::new(Cursor::new(bytes))).unwrap()
    }

    fn is_empty(&self) -> bool {
        self.0.lock().unwrap().is_empty()
    }
}

struct DeadlineBlockingWriter(Arc<RecordingControl>);

impl Write for DeadlineBlockingWriter {
    fn write(&mut self, _: &[u8]) -> io::Result<usize> {
        while !self.0.0.load(Ordering::Acquire) {
            thread::sleep(Duration::from_millis(1));
        }
        Err(io::Error::new(io::ErrorKind::BrokenPipe, "test connection closed"))
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

fn state_with_active_stream(
    instance_id: u64,
) -> (GenerationState, RecordingWriter, Receiver<DataPayload>) {
    let writer = RecordingWriter::default();
    let (inputs, _inputs_rx) = mpsc::sync_channel(EVENT_QUEUE_CAPACITY);
    let (local_opens, _local_opens_rx) = mpsc::sync_channel(LOCAL_OPEN_QUEUE_CAPACITY);
    let (writes, write_rx) = mpsc::sync_channel(LOCAL_WRITE_QUEUE_CAPACITY);
    let control = Arc::new(RecordingControl::default());
    let erased_control: Arc<dyn ConnectionControl> = control;
    let write_deadline =
        WriteDeadline::start(Arc::clone(&erased_control), Duration::from_secs(1)).unwrap();
    let stream_control = Arc::new(RecordingControl::default());
    let erased_stream_control: Arc<dyn ConnectionControl> = stream_control;
    let state = GenerationState {
        generation: 1,
        writer: Box::new(writer.clone()),
        write_deadline,
        control: erased_control,
        local_opens,
        inputs,
        recent_opens: Arc::new(Mutex::new(RecentOpenIds::default())),
        pending_opens: HashMap::new(),
        streams: HashMap::from([(
            7,
            ActiveStream {
                instance_id,
                writes,
                control: erased_stream_control,
                flow: Arc::new(StreamFlow::new(protocol::MAX_STREAM_WINDOW_BYTES)),
                receive_remaining: protocol::MAX_STREAM_WINDOW_BYTES,
            },
        )]),
        next_stream_instance_id: instance_id + 1,
        migration_pending: false,
        draining: false,
        heartbeat: Duration::from_secs(1),
        last_received: Instant::now(),
        last_ping: Instant::now(),
        next_ping_nonce: 1,
    };
    (state, writer, write_rx)
}

#[test]
fn cloud_write_deadline_closes_an_unresponsive_connection() {
    let control = Arc::new(RecordingControl::default());
    let erased_control: Arc<dyn ConnectionControl> = control.clone();
    let deadline = WriteDeadline::start(erased_control, Duration::from_millis(20)).unwrap();
    let mut writer = DeadlineBlockingWriter(control.clone());

    let error = deadline
        .write(&mut writer, &Envelope::new(Message::Ping(Heartbeat { nonce: 1 })))
        .unwrap_err();

    assert_eq!(error.kind(), io::ErrorKind::BrokenPipe);
    assert!(control.0.load(Ordering::Acquire));
}

#[test]
fn cloud_reader_spawn_failure_closes_connection_and_notifies_coordinator() {
    let (inputs_tx, _inputs_rx) = mpsc::sync_channel(EVENT_QUEUE_CAPACITY);
    let (coordinator_tx, coordinator_rx) = mpsc::sync_channel(EVENT_QUEUE_CAPACITY);
    let control = Arc::new(RecordingControl::default());
    let erased_control: Arc<dyn ConnectionControl> = control.clone();

    let error = spawn_cloud_reader_with(
        7,
        3,
        BufReader::new(Box::new(io::empty())),
        erased_control,
        inputs_tx,
        coordinator_tx,
        |_, _| Err(io::Error::other("thread quota exhausted")),
    )
    .unwrap_err();

    assert_eq!(error.kind(), io::ErrorKind::Other);
    assert!(control.0.load(Ordering::Acquire));
    assert!(matches!(
        coordinator_rx.recv_timeout(Duration::from_millis(100)),
        Ok(CoordinatorEvent::Closed { worker_id: 7, stable: false })
    ));
}

#[test]
fn saturated_worker_command_queue_closes_connection_without_blocking() {
    let (commands, _inputs) = mpsc::sync_channel(1);
    commands.send(WorkerInput::Command(WorkerCommand::Stop)).unwrap();
    let control = Arc::new(RecordingControl::default());
    let erased_control: Arc<dyn ConnectionControl> = control.clone();
    let workers =
        HashMap::from([(7, WorkerHandle { commands, control: erased_control, join: None })]);

    assert!(!try_send_worker_command(
        &workers,
        7,
        WorkerCommand::ResumeMigration { generation: 2, code: error_code("migration_failed") },
    ));
    assert!(control.0.load(Ordering::Acquire));
}

#[test]
fn failed_migration_commit_closes_both_generations_and_reports_diagnostic() {
    let (old_commands, _old_inputs) = mpsc::sync_channel(1);
    old_commands.send(WorkerInput::Command(WorkerCommand::Stop)).unwrap();
    let old_control = Arc::new(RecordingControl::default());
    let erased_old_control: Arc<dyn ConnectionControl> = old_control.clone();
    let workers = HashMap::from([(
        7,
        WorkerHandle { commands: old_commands, control: erased_old_control, join: None },
    )]);

    let (replacement_commands, _replacement_inputs) = mpsc::sync_channel(1);
    let replacement_control = Arc::new(RecordingControl::default());
    let erased_replacement_control: Arc<dyn ConnectionControl> = replacement_control.clone();
    let replacement = WorkerHandle {
        commands: replacement_commands,
        control: erased_replacement_control,
        join: None,
    };
    let reporter = TestReporter::default();

    assert!(commit_migration_replacement(&workers, 7, 2, replacement, &reporter).is_none());
    assert!(old_control.0.load(Ordering::Acquire));
    assert!(replacement_control.0.load(Ordering::Acquire));
    assert_eq!(reporter.migrations.load(Ordering::Relaxed), 1);
    assert_eq!(
        *reporter.diagnostics.lock().unwrap(),
        vec![MachineAgentDiagnostic::MigrationCommitDelivery]
    );
}

#[test]
fn migration_commit_requires_generation_ready_acknowledgment() {
    let (old_commands, old_inputs) = mpsc::sync_channel(1);
    let old_control = Arc::new(RecordingControl::default());
    let erased_old_control: Arc<dyn ConnectionControl> = old_control.clone();
    let old_thread = thread::spawn(move || {
        let WorkerInput::Command(WorkerCommand::CommitMigration { generation: 2, acknowledgment }) =
            old_inputs.recv().unwrap()
        else {
            panic!("expected migration commit");
        };
        acknowledgment.send(false).unwrap();
    });
    let workers = HashMap::from([(
        7,
        WorkerHandle {
            commands: old_commands,
            control: erased_old_control,
            join: Some(old_thread),
        },
    )]);

    let (replacement_commands, _replacement_inputs) = mpsc::sync_channel(1);
    let replacement_control = Arc::new(RecordingControl::default());
    let erased_replacement_control: Arc<dyn ConnectionControl> = replacement_control.clone();
    let replacement = WorkerHandle {
        commands: replacement_commands,
        control: erased_replacement_control,
        join: None,
    };
    let reporter = TestReporter::default();

    assert!(commit_migration_replacement(&workers, 7, 2, replacement, &reporter).is_none());
    assert!(old_control.0.load(Ordering::Acquire));
    assert!(replacement_control.0.load(Ordering::Acquire));
    assert_eq!(
        *reporter.diagnostics.lock().unwrap(),
        vec![MachineAgentDiagnostic::MigrationCommitDelivery]
    );
    for (_, worker) in workers {
        worker.finish();
    }
}

#[test]
fn generation_failures_map_to_fixed_sanitized_diagnostic_categories() {
    let transport = anyhow::Error::new(io::Error::other("private upstream detail"));
    let invalid_frame = anyhow::Error::new(FrameReadError::TooLarge);
    let registration = anyhow::anyhow!("private registration detail");

    assert_eq!(generation_failure_kind(&transport), GenerationFailureKind::Transport);
    assert_eq!(generation_failure_kind(&invalid_frame), GenerationFailureKind::InvalidFrame);
    assert_eq!(generation_failure_kind(&registration), GenerationFailureKind::Registration);
    assert_eq!(
        MachineAgentDiagnostic::GenerationStart(generation_failure_kind(&transport)).code(),
        "generation_start.transport"
    );
}

#[test]
fn stale_local_reader_data_cannot_cross_a_reused_stream_id() {
    let (mut state, writer, _write_rx) = state_with_active_stream(2);
    state.handle_local_data(7, 1, DataPayload::new(b"stale".to_vec()).unwrap()).unwrap();
    assert!(writer.is_empty());

    state.handle_local_data(7, 2, DataPayload::new(b"current".to_vec()).unwrap()).unwrap();
    assert!(matches!(
        writer.read_frame().message,
        Message::Data(StreamData { stream_id: 7, ref payload })
            if payload.as_bytes() == b"current"
    ));
}

#[test]
fn cloud_data_waits_for_async_local_write_before_reopening_window() {
    let (mut state, writer, write_rx) = state_with_active_stream(2);
    state
        .write_local(StreamData {
            stream_id: 7,
            payload: DataPayload::new(b"cloud".to_vec()).unwrap(),
        })
        .unwrap();
    assert_eq!(
        state.streams.get(&7).unwrap().receive_remaining,
        protocol::MAX_STREAM_WINDOW_BYTES - 5
    );
    assert!(writer.is_empty());
    assert_eq!(write_rx.recv().unwrap().as_bytes(), b"cloud");

    state.complete_local_write(7, 2, 5).unwrap();
    assert!(matches!(
        writer.read_frame().message,
        Message::Window(StreamWindow { stream_id: 7, bytes: 5 })
    ));
}

struct TestWait;

impl WaitStrategy for TestWait {
    fn wait(&self, _: Duration, stop: &dyn StopSignal) -> bool {
        !stop.requested()
    }

    fn jitter(&self, _: Duration) -> Duration {
        Duration::ZERO
    }
}

struct QueueCloud {
    connections: Mutex<VecDeque<DuplexConnection>>,
    attempts: AtomicUsize,
}

impl QueueCloud {
    fn new() -> (Arc<Self>, Vec<UnixStream>) {
        let mut clients = VecDeque::new();
        let mut servers = Vec::new();
        for _ in 0..3 {
            let (client, server) = UnixStream::pair().unwrap();
            clients.push_back(duplex_from_unix_stream(client).unwrap());
            servers.push(server);
        }
        (
            Arc::new(Self { connections: Mutex::new(clients), attempts: AtomicUsize::new(0) }),
            servers,
        )
    }
}

impl CloudConnector for QueueCloud {
    fn connect(&self) -> io::Result<DuplexConnection> {
        self.attempts.fetch_add(1, Ordering::Relaxed);
        self.connections
            .lock()
            .unwrap()
            .pop_front()
            .ok_or_else(|| io::Error::new(io::ErrorKind::ConnectionRefused, "no fake cloud"))
    }
}

struct QueueLocal {
    streams: Mutex<VecDeque<DuplexConnection>>,
}

impl LocalSessionConnector for QueueLocal {
    fn verify_protocol(&self) -> anyhow::Result<()> {
        Ok(())
    }

    fn open(&self) -> io::Result<DuplexConnection> {
        self.streams
            .lock()
            .unwrap()
            .pop_front()
            .ok_or_else(|| io::Error::new(io::ErrorKind::ConnectionRefused, "no fake session"))
    }
}

struct BlockingLocal {
    streams: Mutex<VecDeque<DuplexConnection>>,
    opens: AtomicUsize,
    started: (Mutex<bool>, Condvar),
    released: (Mutex<bool>, Condvar),
}

impl BlockingLocal {
    fn new(streams: Vec<DuplexConnection>) -> Arc<Self> {
        Arc::new(Self {
            streams: Mutex::new(streams.into()),
            opens: AtomicUsize::new(0),
            started: (Mutex::new(false), Condvar::new()),
            released: (Mutex::new(false), Condvar::new()),
        })
    }

    fn wait_until_started(&self) {
        let (started, available) = &self.started;
        let mut started = started.lock().unwrap();
        while !*started {
            started = available.wait(started).unwrap();
        }
    }

    fn release(&self) {
        let (released, available) = &self.released;
        *released.lock().unwrap() = true;
        available.notify_all();
    }
}

impl LocalSessionConnector for BlockingLocal {
    fn verify_protocol(&self) -> anyhow::Result<()> {
        Ok(())
    }

    fn open(&self) -> io::Result<DuplexConnection> {
        if self.opens.fetch_add(1, Ordering::SeqCst) == 0 {
            let (started, available) = &self.started;
            *started.lock().unwrap() = true;
            available.notify_all();

            let (released, available) = &self.released;
            let mut released = released.lock().unwrap();
            while !*released {
                released = available.wait(released).unwrap();
            }
        }
        self.streams
            .lock()
            .unwrap()
            .pop_front()
            .ok_or_else(|| io::Error::new(io::ErrorKind::ConnectionRefused, "no fake session"))
    }
}

struct SaturatingLocal {
    streams: Mutex<VecDeque<DuplexConnection>>,
    opens: AtomicUsize,
    started: (Mutex<()>, Condvar),
    released: (Mutex<bool>, Condvar),
}

impl SaturatingLocal {
    fn new(streams: Vec<DuplexConnection>) -> Arc<Self> {
        Arc::new(Self {
            streams: Mutex::new(streams.into()),
            opens: AtomicUsize::new(0),
            started: (Mutex::new(()), Condvar::new()),
            released: (Mutex::new(false), Condvar::new()),
        })
    }

    fn wait_until_started(&self, expected: usize) {
        let (started, available) = &self.started;
        let mut started = started.lock().unwrap();
        while self.opens.load(Ordering::Acquire) < expected {
            started = available.wait(started).unwrap();
        }
    }

    fn release(&self) {
        let (released, available) = &self.released;
        *released.lock().unwrap() = true;
        available.notify_all();
    }
}

impl LocalSessionConnector for SaturatingLocal {
    fn verify_protocol(&self) -> anyhow::Result<()> {
        Ok(())
    }

    fn open(&self) -> io::Result<DuplexConnection> {
        let started = self.started.0.lock().unwrap();
        self.opens.fetch_add(1, Ordering::Release);
        self.started.1.notify_all();
        drop(started);

        let (released, available) = &self.released;
        let mut released = released.lock().unwrap();
        while !*released {
            released = available.wait(released).unwrap();
        }
        self.streams
            .lock()
            .unwrap()
            .pop_front()
            .ok_or_else(|| io::Error::new(io::ErrorKind::ConnectionRefused, "no fake session"))
    }
}

fn identity() -> MachineIdentity {
    MachineIdentity {
        machine_id: OpaqueId::new("machine-test").unwrap(),
        secret: MachineSecret::new("0123456789abcdef0123456789abcdef").unwrap(),
    }
}

struct WirePeer {
    reader: BufReader<UnixStream>,
    writer: UnixStream,
}

impl WirePeer {
    fn new(writer: UnixStream) -> Self {
        let reader = BufReader::new(writer.try_clone().unwrap());
        Self { reader, writer }
    }

    fn read(&mut self) -> Envelope {
        protocol_io::read_frame(&mut self.reader).unwrap()
    }

    fn write(&mut self, message: Message) {
        protocol_io::write_frame(&mut self.writer, &Envelope::new(message)).unwrap();
    }

    fn shutdown(&self) {
        let _ = self.writer.shutdown(std::net::Shutdown::Both);
    }
}

fn registered(generation: u64, code: Option<&str>) -> Message {
    Message::Registered(Registered {
        machine_id: OpaqueId::new("machine-test").unwrap(),
        generation,
        pairing_code: code.map(|code| PairingCode::new(code).unwrap()),
        heartbeat_interval_ms: protocol::HeartbeatIntervalMs::new(1_000).unwrap(),
    })
}

#[test]
fn reconnect_backoff_is_exponential_and_bounded() {
    assert_eq!(reconnect_delay(0, &TestWait), Duration::from_millis(250));
    assert_eq!(reconnect_delay(1, &TestWait), Duration::from_millis(500));
    assert_eq!(reconnect_delay(20, &TestWait), Duration::from_secs(30));
}

#[test]
fn disconnected_generation_reconnects_with_stable_identity_and_generation_floor() {
    let (cloud, mut servers) = QueueCloud::new();
    let attempts = cloud.clone();
    let mut first = WirePeer::new(servers.remove(0));
    let mut second = WirePeer::new(servers.remove(0));
    let local = Arc::new(QueueLocal { streams: Mutex::new(VecDeque::new()) });
    let reporter = Arc::new(TestReporter::default());
    let stop = AtomicStop::new();
    let agent = MachineAgent::new(
        identity(),
        SessionName::new("agents").unwrap(),
        cloud,
        local,
        reporter.clone(),
        Arc::new(TestWait),
        stop.clone(),
    );
    let agent_thread = thread::spawn(move || agent.run().unwrap());

    let Message::Hello(first_hello) = first.read().message else {
        panic!("expected initial hello");
    };
    first.write(registered(2, Some("ABCD-EFGH")));
    first.shutdown();

    let Message::Hello(second_hello) = second.read().message else {
        panic!("expected reconnect hello");
    };
    assert_eq!(second_hello.machine_id, first_hello.machine_id);
    assert_eq!(second_hello.secret, first_hello.secret);
    assert_ne!(second_hello.connection_nonce, first_hello.connection_nonce);
    assert_eq!(second_hello.minimum_generation, 2);
    second.write(registered(2, None));

    stop.stop();
    second.shutdown();
    agent_thread.join().unwrap();
    assert!(attempts.attempts.load(Ordering::Relaxed) >= 2);
    assert_eq!(reporter.codes.lock().unwrap().as_slice(), ["ABCD-EFGH"]);
}

#[test]
fn pairing_code_write_failure_closes_generation_and_aborts_registration() {
    let (cloud, mut servers) = QueueCloud::new();
    let mut server = WirePeer::new(servers.remove(0));
    let reporter = Arc::new(FailingPairingReporter::default());
    let agent = MachineAgent::new(
        identity(),
        SessionName::new("agents").unwrap(),
        cloud,
        Arc::new(QueueLocal { streams: Mutex::new(VecDeque::new()) }),
        reporter.clone(),
        Arc::new(TestWait),
        AtomicStop::new(),
    );
    let agent_thread = thread::spawn(move || agent.run());

    assert!(matches!(server.read().message, Message::Hello(_)));
    server.write(registered(1, Some("ABCD-EFGH")));

    let error = agent_thread.join().unwrap().unwrap_err();
    assert_eq!(error.downcast_ref::<io::Error>().unwrap().kind(), io::ErrorKind::BrokenPipe);
    assert!(!reporter.registered.load(Ordering::Acquire));
}

#[test]
fn repeated_established_disconnects_apply_exponential_backoff() {
    let (cloud, mut servers) = QueueCloud::new();
    let mut first = WirePeer::new(servers.remove(0));
    let mut second = WirePeer::new(servers.remove(0));
    let mut third = WirePeer::new(servers.remove(0));
    let reporter = Arc::new(TestReporter::default());
    let stop = AtomicStop::new();
    let agent = MachineAgent::new(
        identity(),
        SessionName::new("agents").unwrap(),
        cloud,
        Arc::new(QueueLocal { streams: Mutex::new(VecDeque::new()) }),
        reporter.clone(),
        Arc::new(TestWait),
        stop.clone(),
    );
    let agent_thread = thread::spawn(move || agent.run().unwrap());

    let _ = first.read();
    first.write(registered(1, None));
    first.shutdown();
    let _ = second.read();
    second.write(registered(1, None));
    second.shutdown();
    let _ = third.read();
    third.write(registered(1, None));

    stop.stop();
    third.shutdown();
    agent_thread.join().unwrap();
    assert_eq!(
        *reporter.retries.lock().unwrap(),
        vec![Duration::from_millis(250), Duration::from_millis(500)]
    );
}

#[test]
fn malformed_and_oversized_cloud_frames_force_clean_reconnects() {
    let (cloud, mut servers) = QueueCloud::new();
    let mut oversized = WirePeer::new(servers.remove(0));
    let mut malformed = WirePeer::new(servers.remove(0));
    let mut healthy = WirePeer::new(servers.remove(0));
    let local = Arc::new(QueueLocal { streams: Mutex::new(VecDeque::new()) });
    let stop = AtomicStop::new();
    let agent = MachineAgent::new(
        identity(),
        SessionName::new("agents").unwrap(),
        cloud,
        local,
        Arc::new(TestReporter::default()),
        Arc::new(TestWait),
        stop.clone(),
    );
    let agent_thread = thread::spawn(move || agent.run().unwrap());

    let _ = oversized.read();
    oversized.write(registered(1, None));
    let oversized_write = oversized
        .writer
        .write_all(&vec![b'x'; protocol::MAX_FRAME_BYTES + 1])
        .and_then(|()| oversized.writer.write_all(b"\n"));
    if let Err(error) = oversized_write {
        assert!(matches!(error.kind(), io::ErrorKind::BrokenPipe | io::ErrorKind::ConnectionReset));
    }

    let Message::Hello(reconnected) = malformed.read().message else {
        panic!("oversized input did not reconnect");
    };
    assert_eq!(reconnected.minimum_generation, 1);
    malformed.write(registered(1, None));
    malformed.writer.write_all(b"{\"type\":broken}\n").unwrap();

    let Message::Hello(reconnected) = healthy.read().message else {
        panic!("malformed input did not reconnect");
    };
    assert_eq!(reconnected.minimum_generation, 1);
    healthy.write(registered(1, None));
    stop.stop();
    healthy.shutdown();
    agent_thread.join().unwrap();
}

#[test]
fn idle_generation_is_replaced_and_shutdown_interrupts_the_replacement() {
    let (cloud, mut servers) = QueueCloud::new();
    let mut idle = WirePeer::new(servers.remove(0));
    let mut replacement = WirePeer::new(servers.remove(0));
    replacement.reader.get_ref().set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    let local = Arc::new(QueueLocal { streams: Mutex::new(VecDeque::new()) });
    let stop = AtomicStop::new();
    let agent = MachineAgent::new(
        identity(),
        SessionName::new("agents").unwrap(),
        cloud,
        local,
        Arc::new(TestReporter::default()),
        Arc::new(TestWait),
        stop.clone(),
    );
    let agent_thread = thread::spawn(move || agent.run().unwrap());

    let _ = idle.read();
    idle.write(Message::Registered(Registered {
        machine_id: OpaqueId::new("machine-test").unwrap(),
        generation: 1,
        pairing_code: None,
        heartbeat_interval_ms: protocol::HeartbeatIntervalMs::new(1_000).unwrap(),
    }));
    assert!(matches!(idle.read().message, Message::Ping(_)));
    let Message::Hello(reconnected) = replacement.read().message else {
        panic!("idle generation was not replaced");
    };
    assert_eq!(reconnected.minimum_generation, 1);
    replacement.write(registered(1, None));
    stop.stop();
    replacement.shutdown();
    agent_thread.join().unwrap();
}

#[test]
fn streams_obey_windows_and_reject_replay_or_zero_length_flow_frames() {
    let (cloud, mut cloud_servers) = QueueCloud::new();
    let cloud_server = cloud_servers.remove(0);
    let (local_client, mut local_server) = UnixStream::pair().unwrap();
    let (zero_window_client, _zero_window_server) = UnixStream::pair().unwrap();
    let local = Arc::new(QueueLocal {
        streams: Mutex::new(VecDeque::from([
            duplex_from_unix_stream(local_client).unwrap(),
            duplex_from_unix_stream(zero_window_client).unwrap(),
        ])),
    });
    let reporter = Arc::new(TestReporter::default());
    let stop = AtomicStop::new();
    let agent = MachineAgent::new(
        identity(),
        SessionName::new("agents").unwrap(),
        cloud,
        local,
        reporter,
        Arc::new(TestWait),
        stop.clone(),
    );
    let agent_thread = thread::spawn(move || agent.run().unwrap());
    let mut cloud_server = WirePeer::new(cloud_server);
    let hello = cloud_server.read();
    assert!(matches!(hello.message, Message::Hello(_)));
    cloud_server.write(registered(1, Some("ABCD-EFGH")));
    cloud_server.write(Message::Open(OpenStream {
        stream_id: 7,
        open_id: OpaqueId::new("open-7").unwrap(),
        initial_window: 4,
    }));
    let opened = cloud_server.read();
    assert!(matches!(opened.message, Message::Opened(StreamOpened { stream_id: 7, .. })));

    local_server.write_all(b"abcdefgh").unwrap();
    let first = cloud_server.read();
    let Message::Data(first) = first.message else { panic!("expected local data") };
    assert_eq!(first.payload.as_bytes(), b"abcd");
    cloud_server.reader.get_ref().set_read_timeout(Some(Duration::from_millis(150))).unwrap();
    assert!(
        matches!(
            protocol_io::read_frame(&mut cloud_server.reader),
            Err(FrameReadError::Io(ref error))
                if matches!(
                    error.kind(),
                    io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
                )
        ),
        "flow control did not stop local reads"
    );
    cloud_server.reader.get_ref().set_read_timeout(None).unwrap();
    cloud_server.write(Message::Window(StreamWindow { stream_id: 7, bytes: 4 }));
    let second = cloud_server.read();
    let Message::Data(second) = second.message else { panic!("expected resumed local data") };
    assert_eq!(second.payload.as_bytes(), b"efgh");

    cloud_server.write(Message::Data(StreamData {
        stream_id: 7,
        payload: DataPayload::new(b"cloud".to_vec()).unwrap(),
    }));
    let window = cloud_server.read();
    assert!(matches!(window.message, Message::Window(StreamWindow { stream_id: 7, bytes: 5 })));
    let mut received = [0u8; 5];
    local_server.read_exact(&mut received).unwrap();
    assert_eq!(&received, b"cloud");

    cloud_server.write(Message::Data(StreamData {
        stream_id: 7,
        payload: DataPayload::new(Vec::new()).unwrap(),
    }));
    assert!(matches!(
        cloud_server.read().message,
        Message::Close(StreamClosed { stream_id: 7, ref code })
            if code.as_str() == "flow_control"
    ));
    cloud_server.write(Message::Open(OpenStream {
        stream_id: 9,
        open_id: OpaqueId::new("open-9").unwrap(),
        initial_window: 4,
    }));
    assert!(matches!(
        cloud_server.read().message,
        Message::Opened(StreamOpened { stream_id: 9, .. })
    ));
    cloud_server.write(Message::Window(StreamWindow { stream_id: 9, bytes: 0 }));
    assert!(matches!(
        cloud_server.read().message,
        Message::Close(StreamClosed { stream_id: 9, ref code })
            if code.as_str() == "flow_control"
    ));

    cloud_server.write(Message::Open(OpenStream {
        stream_id: 8,
        open_id: OpaqueId::new("open-7").unwrap(),
        initial_window: 4,
    }));
    let replay = cloud_server.read();
    assert!(matches!(
        replay.message,
        Message::Reject(StreamRejected { stream_id: 8, ref code })
            if code.as_str() == "replay"
    ));
    stop.stop();
    cloud_server.shutdown();
    agent_thread.join().unwrap();
}

#[test]
fn blocked_local_open_does_not_block_cloud_control_frames() {
    let (cloud, mut cloud_servers) = QueueCloud::new();
    let mut cloud_server = WirePeer::new(cloud_servers.remove(0));
    let (blocked_local_client, _blocked_local_server) = UnixStream::pair().unwrap();
    let (ready_local_client, _ready_local_server) = UnixStream::pair().unwrap();
    let local = BlockingLocal::new(vec![
        duplex_from_unix_stream(blocked_local_client).unwrap(),
        duplex_from_unix_stream(ready_local_client).unwrap(),
    ]);
    let stop = AtomicStop::new();
    let agent = MachineAgent::new(
        identity(),
        SessionName::new("agents").unwrap(),
        cloud,
        local.clone(),
        Arc::new(TestReporter::default()),
        Arc::new(TestWait),
        stop.clone(),
    );
    let agent_thread = thread::spawn(move || agent.run().unwrap());

    assert!(matches!(cloud_server.read().message, Message::Hello(_)));
    cloud_server.write(registered(1, None));
    cloud_server.write(Message::Open(OpenStream {
        stream_id: 7,
        open_id: OpaqueId::new("blocked-open").unwrap(),
        initial_window: 4,
    }));
    local.wait_until_started();

    cloud_server.reader.get_ref().set_read_timeout(Some(Duration::from_millis(500))).unwrap();
    cloud_server.write(Message::Ping(Heartbeat { nonce: 42 }));
    assert!(matches!(cloud_server.read().message, Message::Pong(Heartbeat { nonce: 42 })));
    cloud_server.write(Message::Open(OpenStream {
        stream_id: 8,
        open_id: OpaqueId::new("ready-open").unwrap(),
        initial_window: 4,
    }));
    assert!(matches!(
        cloud_server.read().message,
        Message::Opened(StreamOpened { stream_id: 8, .. })
    ));

    local.release();
    assert!(matches!(
        cloud_server.read().message,
        Message::Opened(StreamOpened { stream_id: 7, .. })
    ));
    cloud_server.reader.get_ref().set_read_timeout(None).unwrap();
    stop.stop();
    cloud_server.shutdown();
    agent_thread.join().unwrap();
}

#[test]
fn blocked_local_open_workers_remain_bounded_across_reconnects() {
    let (cloud, mut cloud_servers) = QueueCloud::new();
    let mut first = WirePeer::new(cloud_servers.remove(0));
    let mut second = WirePeer::new(cloud_servers.remove(0));
    let mut local_clients = Vec::new();
    let mut _local_servers = Vec::new();
    for _ in 0..=LOCAL_OPEN_CONCURRENCY {
        let (client, server) = UnixStream::pair().unwrap();
        local_clients.push(duplex_from_unix_stream(client).unwrap());
        _local_servers.push(server);
    }
    let local = SaturatingLocal::new(local_clients);
    let stop = AtomicStop::new();
    let agent = MachineAgent::new(
        identity(),
        SessionName::new("agents").unwrap(),
        cloud,
        local.clone(),
        Arc::new(TestReporter::default()),
        Arc::new(TestWait),
        stop.clone(),
    );
    let agent_thread = thread::spawn(move || agent.run().unwrap());

    assert!(matches!(first.read().message, Message::Hello(_)));
    first.write(registered(1, None));
    for stream_id in 1..=LOCAL_OPEN_CONCURRENCY as u32 {
        first.write(Message::Open(OpenStream {
            stream_id,
            open_id: OpaqueId::new(format!("blocked-{stream_id}")).unwrap(),
            initial_window: 4,
        }));
    }
    local.wait_until_started(LOCAL_OPEN_CONCURRENCY);
    first.shutdown();

    assert!(matches!(second.read().message, Message::Hello(_)));
    second.write(registered(2, None));
    second.write(Message::Open(OpenStream {
        stream_id: 9,
        open_id: OpaqueId::new("next-generation-open").unwrap(),
        initial_window: 4,
    }));
    thread::sleep(Duration::from_millis(50));
    assert_eq!(local.opens.load(Ordering::Acquire), LOCAL_OPEN_CONCURRENCY);

    local.release();
    second.reader.get_ref().set_read_timeout(Some(Duration::from_secs(1))).unwrap();
    assert!(matches!(second.read().message, Message::Opened(StreamOpened { stream_id: 9, .. })));
    second.reader.get_ref().set_read_timeout(None).unwrap();
    stop.stop();
    second.shutdown();
    agent_thread.join().unwrap();
}

#[test]
fn migration_overlaps_generations_and_rejects_replay_or_downgrade() {
    let (cloud, mut servers) = QueueCloud::new();
    let mut old_server = WirePeer::new(servers.remove(0));
    let mut new_server = WirePeer::new(servers.remove(0));
    let mut third_server = WirePeer::new(servers.remove(0));
    let (old_local_client, mut old_local_server) = UnixStream::pair().unwrap();
    let (new_local_client, mut new_local_server) = UnixStream::pair().unwrap();
    let local = Arc::new(QueueLocal {
        streams: Mutex::new(VecDeque::from([
            duplex_from_unix_stream(old_local_client).unwrap(),
            duplex_from_unix_stream(new_local_client).unwrap(),
        ])),
    });
    let reporter = Arc::new(TestReporter::default());
    let stop = AtomicStop::new();
    let agent = MachineAgent::new(
        identity(),
        SessionName::new("agents").unwrap(),
        cloud,
        local,
        reporter,
        Arc::new(TestWait),
        stop.clone(),
    );
    let thread = thread::spawn(move || agent.run().unwrap());
    let _ = old_server.read();
    old_server.write(registered(4, None));
    old_server.write(Message::Open(OpenStream {
        stream_id: 40,
        open_id: OpaqueId::new("old-open").unwrap(),
        initial_window: 16,
    }));
    assert!(matches!(
        old_server.read().message,
        Message::Opened(StreamOpened { stream_id: 40, .. })
    ));
    old_server.write(Message::ReconnectGeneration(ReconnectGeneration {
        generation: 5,
        token: MigrationToken::new("migration-token-1234").unwrap(),
    }));
    let hello = new_server.read();
    let Message::Hello(hello) = hello.message else { panic!("expected replacement hello") };
    assert_eq!(hello.minimum_generation, 4);
    assert_eq!(hello.migration.unwrap().generation, 5);
    old_local_server.write_all(b"pending").unwrap();
    let Message::Data(pending_data) = old_server.read().message else {
        panic!("old stream stopped before replacement acknowledgement");
    };
    assert_eq!(pending_data.payload.as_bytes(), b"pending");
    new_server.write(registered(5, None));
    let ready = old_server.read();
    assert!(matches!(
        ready.message,
        Message::GenerationReady(GenerationReady { from_generation: 4, to_generation: 5 })
    ));
    old_server.write(Message::Open(OpenStream {
        stream_id: 41,
        open_id: OpaqueId::new("stale-open").unwrap(),
        initial_window: 16,
    }));
    assert!(matches!(
        old_server.read().message,
        Message::Reject(StreamRejected { stream_id: 41, ref code })
            if code.as_str() == "migrating"
    ));
    new_server.write(Message::Open(OpenStream {
        stream_id: 50,
        open_id: OpaqueId::new("new-open").unwrap(),
        initial_window: 16,
    }));
    assert!(matches!(
        new_server.read().message,
        Message::Opened(StreamOpened { stream_id: 50, .. })
    ));

    old_local_server.write_all(b"old").unwrap();
    new_local_server.write_all(b"new").unwrap();
    let Message::Data(old_data) = old_server.read().message else {
        panic!("old generation stopped carrying its existing stream");
    };
    let Message::Data(new_data) = new_server.read().message else {
        panic!("replacement generation did not carry new streams");
    };
    assert_eq!(old_data.payload.as_bytes(), b"old");
    assert_eq!(new_data.payload.as_bytes(), b"new");

    new_server.write(Message::ReconnectGeneration(ReconnectGeneration {
        generation: 6,
        token: MigrationToken::new("overlapping-migration-1234").unwrap(),
    }));
    third_server.reader.get_ref().set_read_timeout(Some(Duration::from_millis(250))).unwrap();
    assert!(
        matches!(
            protocol_io::read_frame(&mut third_server.reader),
            Err(FrameReadError::Io(ref error))
                if matches!(
                    error.kind(),
                    io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
                )
        ),
        "a third generation started while the oldest generation was still draining"
    );
    assert!(matches!(
        new_server.read().message,
        Message::GenerationRejected(GenerationRejected { generation: 6, ref code })
            if code.as_str() == "migration_in_progress"
    ));

    old_local_server.shutdown(std::net::Shutdown::Write).unwrap();
    assert!(matches!(
        old_server.read().message,
        Message::Close(StreamClosed { stream_id: 40, ref code }) if code.as_str() == "eof"
    ));
    assert!(matches!(
        old_server.read().message,
        Message::DrainComplete(DrainComplete { generation: 4 })
    ));

    new_server.write(Message::ReconnectGeneration(ReconnectGeneration {
        generation: 4,
        token: MigrationToken::new("another-token-1234").unwrap(),
    }));
    let downgrade = new_server.read();
    assert!(matches!(
        downgrade.message,
        Message::GenerationRejected(GenerationRejected { generation: 4, ref code })
            if code.as_str() == "downgrade"
    ));
    new_server.write(Message::ReconnectGeneration(ReconnectGeneration {
        generation: 6,
        token: MigrationToken::new("migration-token-1234").unwrap(),
    }));
    let replay = new_server.read();
    assert!(matches!(
        replay.message,
        Message::GenerationRejected(GenerationRejected { generation: 6, ref code })
            if code.as_str() == "replay"
    ));
    stop.stop();
    new_server.shutdown();
    thread.join().unwrap();
}

fn assert_invalid_migration_registration(
    registered_generation: u64,
    pairing_code: Option<&str>,
    expected_code: &str,
    expected_diagnostic: MachineAgentDiagnostic,
) {
    let (cloud, mut servers) = QueueCloud::new();
    let mut old_server = WirePeer::new(servers.remove(0));
    let mut replacement_server = WirePeer::new(servers.remove(0));
    let local = Arc::new(QueueLocal { streams: Mutex::new(VecDeque::new()) });
    let (peer_rejected, rejection_seen) = mpsc::channel();
    let reporter = Arc::new(TestReporter {
        peer_rejected: Mutex::new(Some(rejection_seen)),
        ..TestReporter::default()
    });
    let stop = AtomicStop::new();
    let agent = MachineAgent::new(
        identity(),
        SessionName::new("agents").unwrap(),
        cloud,
        local,
        reporter.clone(),
        Arc::new(TestWait),
        stop.clone(),
    );
    let thread = thread::spawn(move || agent.run().unwrap());

    let _ = old_server.read();
    old_server.write(registered(4, None));
    old_server.write(Message::ReconnectGeneration(ReconnectGeneration {
        generation: 5,
        token: MigrationToken::new("invalid-migration-1234").unwrap(),
    }));
    let Message::Hello(hello) = replacement_server.read().message else {
        panic!("expected replacement hello");
    };
    assert_eq!(hello.migration.unwrap().generation, 5);
    // The old peer reads on its own thread, so a rejection that the
    // runtime sends before it reports reaches the reporter while it waits.
    // The old generation keeps its heartbeat while the migration runs.
    let old_peer = thread::spawn(move || {
        let message = loop {
            match old_server.read().message {
                Message::Ping(_) => {}
                message => break message,
            }
        };
        let _ = peer_rejected.send(());
        (old_server, message)
    });
    replacement_server.write(registered(registered_generation, pairing_code));

    let (old_server, rejection) = old_peer.join().unwrap();
    assert!(matches!(
        rejection,
        Message::GenerationRejected(GenerationRejected { generation: 5, ref code })
            if code.as_str() == expected_code
    ));
    // Whoever sees the rejection can rely on the failure being reported.
    assert_eq!(*reporter.diagnostics.lock().unwrap(), vec![expected_diagnostic]);
    assert_eq!(reporter.migrations.load(Ordering::Acquire), 1);
    assert!(
        !reporter.reported_after_rejection.load(Ordering::Acquire),
        "the old generation's peer got its rejection before the failure was reported"
    );

    stop.stop();
    old_server.shutdown();
    replacement_server.shutdown();
    thread.join().unwrap();
}

#[test]
fn migration_pairing_code_resumes_old_generation_and_reports_diagnostic() {
    assert_invalid_migration_registration(
        5,
        Some("ABCD-EFGH"),
        "invalid_migration",
        MachineAgentDiagnostic::MigrationPairingCode,
    );
}

#[test]
fn migration_generation_mismatch_resumes_old_generation_and_reports_diagnostic() {
    assert_invalid_migration_registration(
        6,
        None,
        "generation_mismatch",
        MachineAgentDiagnostic::MigrationGenerationMismatch,
    );
}
