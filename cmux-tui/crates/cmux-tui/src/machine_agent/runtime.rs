use std::collections::{HashMap, HashSet, VecDeque};
use std::io::{self, BufReader, Read, Write};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, SyncSender, TrySendError};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use cmux_tui_machine_agent_protocol as protocol;
use protocol::{
    AgentVersion, DataPayload, DrainComplete, Envelope, ErrorCode, GenerationReady,
    GenerationRejected, Heartbeat, Hello, Message, MigrationProof, OpaqueId, OpenStream,
    ReconnectGeneration, Registered, SessionName, StreamClosed, StreamData, StreamOpened,
    StreamRejected, StreamWindow,
};
use zeroize::Zeroize;

use super::identity::MachineIdentity;
use super::protocol_io::{self, FrameReadError};
use super::transport::{
    CloudConnector, ConnectionControl, DuplexConnection, LocalSessionConnector,
};

const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);
const MIN_HEARTBEAT: Duration = Duration::from_millis(protocol::MIN_HEARTBEAT_INTERVAL_MS);
const MAX_HEARTBEAT: Duration = Duration::from_millis(protocol::MAX_HEARTBEAT_INTERVAL_MS);
const EVENT_QUEUE_CAPACITY: usize = 128;
const RECONNECT_BASE: Duration = Duration::from_millis(250);
const RECONNECT_MAX: Duration = Duration::from_secs(30);

pub(super) trait StopSignal: Send + Sync {
    fn requested(&self) -> bool;
}

pub(super) trait WaitStrategy: Send + Sync {
    /// Returns false when shutdown interrupted the wait.
    fn wait(&self, duration: Duration, stop: &dyn StopSignal) -> bool;
    fn jitter(&self, upper_bound: Duration) -> Duration;
}

pub(super) trait Reporter: Send + Sync {
    fn pairing_code(&self, code: &str);
    fn registered(&self, session: &str);
    fn retrying(&self, delay: Duration);
    fn migration_failed(&self);
}

pub(super) struct SystemWait;

impl WaitStrategy for SystemWait {
    fn wait(&self, duration: Duration, stop: &dyn StopSignal) -> bool {
        let deadline = Instant::now() + duration;
        while !stop.requested() {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return true;
            }
            thread::sleep(remaining.min(Duration::from_millis(100)));
        }
        false
    }

    fn jitter(&self, upper_bound: Duration) -> Duration {
        if upper_bound.is_zero() {
            return Duration::ZERO;
        }
        let mut bytes = [0u8; 8];
        if getrandom::fill(&mut bytes).is_err() {
            return Duration::ZERO;
        }
        let upper_millis = upper_bound.as_millis().min(u128::from(u64::MAX)) as u64;
        Duration::from_millis(u64::from_le_bytes(bytes) % upper_millis.saturating_add(1))
    }
}

pub(super) struct MachineAgent {
    identity: MachineIdentity,
    session: SessionName,
    cloud: Arc<dyn CloudConnector>,
    local: Arc<dyn LocalSessionConnector>,
    reporter: Arc<dyn Reporter>,
    wait: Arc<dyn WaitStrategy>,
    stop: Arc<dyn StopSignal>,
    worker_sequence: AtomicU64,
}

impl MachineAgent {
    pub(super) fn new(
        identity: MachineIdentity,
        session: SessionName,
        cloud: Arc<dyn CloudConnector>,
        local: Arc<dyn LocalSessionConnector>,
        reporter: Arc<dyn Reporter>,
        wait: Arc<dyn WaitStrategy>,
        stop: Arc<dyn StopSignal>,
    ) -> Self {
        Self {
            identity,
            session,
            cloud,
            local,
            reporter,
            wait,
            stop,
            worker_sequence: AtomicU64::new(1),
        }
    }

    pub(super) fn run(&self) -> anyhow::Result<()> {
        self.local.verify_protocol()?;
        let (events_tx, events_rx) = mpsc::sync_channel(EVENT_QUEUE_CAPACITY);
        let recent_opens = Arc::new(Mutex::new(RecentOpenIds::default()));
        let mut recent_migrations = VecDeque::new();
        let mut workers = HashMap::<u64, WorkerHandle>::new();
        let mut latest_worker = None;
        let mut highest_generation = 0u64;
        let mut reconnect_attempt = 0u32;

        while !self.stop.requested() {
            if latest_worker.is_none() {
                match self.start_generation(
                    highest_generation,
                    None,
                    events_tx.clone(),
                    Arc::clone(&recent_opens),
                ) {
                    Ok(started) => {
                        highest_generation = highest_generation.max(started.generation);
                        latest_worker = Some(started.worker_id);
                        reconnect_attempt = 0;
                        self.report_registration(&started.registered);
                        workers.insert(started.worker_id, started.handle);
                    }
                    Err(_) => {
                        let delay = reconnect_delay(reconnect_attempt, self.wait.as_ref());
                        reconnect_attempt = reconnect_attempt.saturating_add(1);
                        self.reporter.retrying(delay);
                        if !self.wait.wait(delay, self.stop.as_ref()) {
                            break;
                        }
                        continue;
                    }
                }
            }

            match events_rx.recv_timeout(Duration::from_millis(100)) {
                Ok(CoordinatorEvent::MigrationRequested { worker_id, generation, request }) => {
                    let replayed = recent_migrations.iter().any(|seen: &SeenMigration| {
                        seen.generation == request.generation || seen.token == request.token
                    });
                    if generation >= request.generation
                        || request.generation <= highest_generation
                        || replayed
                    {
                        try_send_worker_command(
                            &workers,
                            worker_id,
                            WorkerCommand::ResumeMigration {
                                generation: request.generation,
                                code: error_code(if replayed { "replay" } else { "downgrade" }),
                            },
                        );
                        continue;
                    }
                    remember_migration(&mut recent_migrations, &request);
                    let proof = MigrationProof {
                        generation: request.generation,
                        token: request.token.clone(),
                    };
                    match self.start_generation(
                        highest_generation,
                        Some(proof),
                        events_tx.clone(),
                        Arc::clone(&recent_opens),
                    ) {
                        Ok(started) if started.generation == request.generation => {
                            if started.registered.pairing_code.is_some() {
                                started.handle.close();
                                try_send_worker_command(
                                    &workers,
                                    worker_id,
                                    WorkerCommand::ResumeMigration {
                                        generation: request.generation,
                                        code: error_code("invalid_migration"),
                                    },
                                );
                                self.reporter.migration_failed();
                                continue;
                            }
                            if !try_send_worker_command(
                                &workers,
                                worker_id,
                                WorkerCommand::CommitMigration { generation: started.generation },
                            ) {
                                started.handle.close();
                                self.reporter.migration_failed();
                                continue;
                            }
                            highest_generation = started.generation;
                            latest_worker = Some(started.worker_id);
                            workers.insert(started.worker_id, started.handle);
                        }
                        Ok(started) => {
                            started.handle.close();
                            try_send_worker_command(
                                &workers,
                                worker_id,
                                WorkerCommand::ResumeMigration {
                                    generation: request.generation,
                                    code: error_code("generation_mismatch"),
                                },
                            );
                            self.reporter.migration_failed();
                        }
                        Err(_) => {
                            try_send_worker_command(
                                &workers,
                                worker_id,
                                WorkerCommand::ResumeMigration {
                                    generation: request.generation,
                                    code: error_code("migration_failed"),
                                },
                            );
                            self.reporter.migration_failed();
                        }
                    }
                }
                Ok(CoordinatorEvent::Closed { worker_id }) => {
                    if let Some(worker) = workers.remove(&worker_id) {
                        worker.finish();
                    }
                    if latest_worker == Some(worker_id) {
                        latest_worker = None;
                    }
                }
                Err(RecvTimeoutError::Timeout) => {}
                Err(RecvTimeoutError::Disconnected) => break,
            }
        }

        for (_, worker) in workers {
            worker.close();
        }
        Ok(())
    }

    fn report_registration(&self, registered: &Registered) {
        if let Some(code) = &registered.pairing_code {
            self.reporter.pairing_code(code.expose());
        }
        self.reporter.registered(self.session.as_str());
    }

    fn start_generation(
        &self,
        minimum_generation: u64,
        migration: Option<MigrationProof>,
        coordinator: SyncSender<CoordinatorEvent>,
        recent_opens: Arc<Mutex<RecentOpenIds>>,
    ) -> anyhow::Result<StartedWorker> {
        let worker_id = self.worker_sequence.fetch_add(1, Ordering::Relaxed);
        if worker_id == u64::MAX {
            anyhow::bail!("machine-agent worker sequence is exhausted");
        }
        let connection = self.cloud.connect()?;
        let DuplexConnection { reader, mut writer, control } = connection;
        let connection_nonce = random_connection_nonce()?;
        let migration_generation = migration.as_ref().map(|proof| proof.generation);
        let hello = Envelope::new(Message::Hello(Hello {
            machine_id: self.identity.machine_id.clone(),
            secret: self.identity.secret.clone(),
            connection_nonce,
            session: self.session.clone(),
            agent_version: AgentVersion::new(env!("CARGO_PKG_VERSION"))?,
            minimum_generation,
            migration,
        }));
        protocol_io::write_frame(&mut writer, &hello)?;
        drop(hello);

        let mut reader = BufReader::new(reader);
        let deadline = ReadDeadline::start(Arc::clone(&control), HANDSHAKE_TIMEOUT)?;
        let registered = match protocol_io::read_frame(&mut reader) {
            Ok(Envelope { message: Message::Registered(registered), .. }) => registered,
            Ok(_) => {
                control.close();
                anyhow::bail!("machine-agent registration did not begin with registered")
            }
            Err(error) => {
                control.close();
                return Err(error.into());
            }
        };
        deadline.cancel();
        if registered.machine_id != self.identity.machine_id {
            control.close();
            anyhow::bail!("machine-agent registration changed the machine identity");
        }
        let heartbeat = Duration::from_millis(registered.heartbeat_interval_ms.get());
        if !(MIN_HEARTBEAT..=MAX_HEARTBEAT).contains(&heartbeat) {
            control.close();
            anyhow::bail!("machine-agent registration supplied an invalid heartbeat interval");
        }
        if registered.generation < minimum_generation
            || migration_generation.is_some_and(|expected| registered.generation != expected)
        {
            control.close();
            anyhow::bail!("machine-agent registration attempted a generation downgrade");
        }

        let generation = registered.generation;
        let (inputs_tx, inputs_rx) = mpsc::sync_channel(EVENT_QUEUE_CAPACITY);
        let commands = inputs_tx.clone();
        let worker_control = Arc::clone(&control);
        let local = Arc::clone(&self.local);
        let join = thread::Builder::new()
            .name(format!("machine-agent-generation-{generation}"))
            .spawn(move || {
                generation_worker(WorkerContext {
                    worker_id,
                    generation,
                    heartbeat,
                    writer,
                    reader,
                    control: worker_control,
                    local,
                    coordinator,
                    inputs_tx,
                    inputs_rx,
                    recent_opens,
                });
            })?;
        Ok(StartedWorker {
            worker_id,
            generation,
            registered,
            handle: WorkerHandle { commands, control, join: Some(join) },
        })
    }
}

struct StartedWorker {
    worker_id: u64,
    generation: u64,
    registered: Registered,
    handle: WorkerHandle,
}

struct WorkerHandle {
    commands: SyncSender<WorkerInput>,
    control: Arc<dyn ConnectionControl>,
    join: Option<JoinHandle<()>>,
}

impl WorkerHandle {
    fn close(mut self) {
        let _ = self.commands.try_send(WorkerInput::Command(WorkerCommand::Stop));
        self.control.close();
        if let Some(join) = self.join.take() {
            let _ = join.join();
        }
    }

    fn finish(mut self) {
        if let Some(join) = self.join.take() {
            let _ = join.join();
        }
    }
}

fn try_send_worker_command(
    workers: &HashMap<u64, WorkerHandle>,
    worker_id: u64,
    command: WorkerCommand,
) -> bool {
    let Some(worker) = workers.get(&worker_id) else { return false };
    match worker.commands.try_send(WorkerInput::Command(command)) {
        Ok(()) => true,
        Err(TrySendError::Full(_) | TrySendError::Disconnected(_)) => {
            worker.control.close();
            false
        }
    }
}

#[derive(Clone)]
struct SeenMigration {
    generation: u64,
    token: protocol::MigrationToken,
}

fn remember_migration(recent: &mut VecDeque<SeenMigration>, request: &ReconnectGeneration) {
    recent
        .push_back(SeenMigration { generation: request.generation, token: request.token.clone() });
    while recent.len() > protocol::MAX_RECENT_MIGRATIONS {
        recent.pop_front();
    }
}

fn reconnect_delay(attempt: u32, wait: &dyn WaitStrategy) -> Duration {
    let multiplier = 1u32.checked_shl(attempt.min(16)).unwrap_or(u32::MAX);
    let base = RECONNECT_BASE.saturating_mul(multiplier).min(RECONNECT_MAX);
    base.saturating_add(wait.jitter(base / 4)).min(RECONNECT_MAX)
}

fn random_connection_nonce() -> anyhow::Result<OpaqueId> {
    let mut bytes = [0u8; 16];
    if getrandom::fill(&mut bytes).is_err() {
        bytes.zeroize();
        anyhow::bail!("could not generate a machine-agent connection nonce");
    }
    let mut encoded = String::with_capacity(bytes.len() * 2 + "connection-".len());
    encoded.push_str("connection-");
    use std::fmt::Write as _;
    for byte in &bytes {
        write!(&mut encoded, "{byte:02x}").expect("writing to String cannot fail");
    }
    bytes.zeroize();
    OpaqueId::new(encoded).map_err(Into::into)
}

struct ReadDeadline {
    cancel: Option<SyncSender<()>>,
}

impl ReadDeadline {
    fn start(control: Arc<dyn ConnectionControl>, timeout: Duration) -> io::Result<Self> {
        let (cancel, receiver) = mpsc::sync_channel(1);
        thread::Builder::new().name("machine-agent-handshake-deadline".into()).spawn(
            move || {
                if receiver.recv_timeout(timeout).is_err() {
                    control.close();
                }
            },
        )?;
        Ok(Self { cancel: Some(cancel) })
    }

    fn cancel(mut self) {
        if let Some(cancel) = self.cancel.take() {
            let _ = cancel.send(());
        }
    }
}

impl Drop for ReadDeadline {
    fn drop(&mut self) {
        if let Some(cancel) = self.cancel.take() {
            let _ = cancel.send(());
        }
    }
}

enum CoordinatorEvent {
    MigrationRequested { worker_id: u64, generation: u64, request: ReconnectGeneration },
    Closed { worker_id: u64 },
}

enum WorkerCommand {
    CommitMigration { generation: u64 },
    ResumeMigration { generation: u64, code: ErrorCode },
    Stop,
}

enum WorkerInput {
    Cloud(Result<Envelope, FrameReadError>),
    LocalData { stream_id: u32, payload: DataPayload },
    LocalWake,
    Command(WorkerCommand),
}

struct WorkerContext {
    worker_id: u64,
    generation: u64,
    heartbeat: Duration,
    writer: Box<dyn Write + Send>,
    reader: BufReader<Box<dyn Read + Send>>,
    control: Arc<dyn ConnectionControl>,
    local: Arc<dyn LocalSessionConnector>,
    coordinator: SyncSender<CoordinatorEvent>,
    inputs_tx: SyncSender<WorkerInput>,
    inputs_rx: Receiver<WorkerInput>,
    recent_opens: Arc<Mutex<RecentOpenIds>>,
}

fn generation_worker(context: WorkerContext) {
    let WorkerContext {
        worker_id,
        generation,
        heartbeat,
        writer,
        mut reader,
        control,
        local,
        coordinator,
        inputs_tx,
        inputs_rx,
        recent_opens,
    } = context;
    let cloud_sender = inputs_tx.clone();
    let reader_control = Arc::clone(&control);
    let _ = thread::Builder::new().name(format!("machine-agent-cloud-reader-{generation}")).spawn(
        move || {
            loop {
                let frame = protocol_io::read_frame(&mut reader);
                let terminal = frame.is_err();
                if cloud_sender.send(WorkerInput::Cloud(frame)).is_err() || terminal {
                    break;
                }
            }
            reader_control.close();
        },
    );

    let mut state = GenerationState {
        generation,
        writer,
        control: Arc::clone(&control),
        local,
        inputs: inputs_tx,
        recent_opens,
        streams: HashMap::new(),
        migration_pending: false,
        draining: false,
        heartbeat,
        last_received: Instant::now(),
        last_ping: Instant::now(),
        next_ping_nonce: 1,
    };
    let _ = state.run(worker_id, &coordinator, inputs_rx);
    state.close_all();
    control.close();
    let _ = coordinator.send(CoordinatorEvent::Closed { worker_id });
}

struct GenerationState {
    generation: u64,
    writer: Box<dyn Write + Send>,
    control: Arc<dyn ConnectionControl>,
    local: Arc<dyn LocalSessionConnector>,
    inputs: SyncSender<WorkerInput>,
    recent_opens: Arc<Mutex<RecentOpenIds>>,
    streams: HashMap<u32, ActiveStream>,
    migration_pending: bool,
    draining: bool,
    heartbeat: Duration,
    last_received: Instant,
    last_ping: Instant,
    next_ping_nonce: u64,
}

impl GenerationState {
    fn run(
        &mut self,
        worker_id: u64,
        coordinator: &SyncSender<CoordinatorEvent>,
        receiver: Receiver<WorkerInput>,
    ) -> anyhow::Result<()> {
        loop {
            let timeout = self.heartbeat.min(Duration::from_millis(100));
            match receiver.recv_timeout(timeout) {
                Ok(WorkerInput::Cloud(frame)) => {
                    self.last_received = Instant::now();
                    self.handle_cloud(worker_id, coordinator, frame?)?;
                }
                Ok(WorkerInput::LocalData { stream_id, payload }) => {
                    if self.streams.contains_key(&stream_id) {
                        self.send(Message::Data(StreamData { stream_id, payload }))?;
                    }
                }
                Ok(WorkerInput::LocalWake) => {}
                Ok(WorkerInput::Command(command)) => {
                    if self.handle_command(command)? {
                        return Ok(());
                    }
                }
                Err(RecvTimeoutError::Timeout) => {}
                Err(RecvTimeoutError::Disconnected) => {
                    anyhow::bail!("machine-agent generation input queue disconnected")
                }
            }
            self.reap_local_streams()?;
            if self.draining && self.streams.is_empty() {
                self.send(Message::DrainComplete(DrainComplete { generation: self.generation }))?;
                return Ok(());
            }
            if self.last_received.elapsed() >= self.heartbeat.saturating_mul(3) {
                anyhow::bail!("machine-agent generation became idle");
            }
            if self.last_ping.elapsed() >= self.heartbeat {
                let nonce = self.next_ping_nonce;
                self.next_ping_nonce = self.next_ping_nonce.wrapping_add(1);
                self.send(Message::Ping(Heartbeat { nonce }))?;
                self.last_ping = Instant::now();
            }
        }
    }

    fn handle_cloud(
        &mut self,
        worker_id: u64,
        coordinator: &SyncSender<CoordinatorEvent>,
        frame: Envelope,
    ) -> anyhow::Result<()> {
        match frame.message {
            Message::ReconnectGeneration(request) => {
                if self.migration_pending || self.draining {
                    self.send(Message::GenerationRejected(GenerationRejected {
                        generation: request.generation,
                        code: error_code("busy"),
                    }))?;
                } else {
                    self.migration_pending = true;
                    coordinator
                        .send(CoordinatorEvent::MigrationRequested {
                            worker_id,
                            generation: self.generation,
                            request,
                        })
                        .map_err(|_| anyhow::anyhow!("machine-agent coordinator stopped"))?;
                }
            }
            Message::Open(open) => self.open_stream(open)?,
            Message::Data(data) => self.write_local(data)?,
            Message::Window(window) => self.add_window(window)?,
            Message::Close(closed) => self.close_stream(closed.stream_id, None)?,
            Message::Ping(heartbeat) => self.send(Message::Pong(heartbeat))?,
            Message::Pong(_) => {}
            Message::Hello(_)
            | Message::Registered(_)
            | Message::GenerationReady(_)
            | Message::GenerationRejected(_)
            | Message::DrainComplete(_)
            | Message::Opened(_)
            | Message::Reject(_) => {
                anyhow::bail!("cloud sent a machine-agent message in the wrong direction")
            }
        }
        Ok(())
    }

    fn handle_command(&mut self, command: WorkerCommand) -> anyhow::Result<bool> {
        match command {
            WorkerCommand::CommitMigration { generation } => {
                if !self.migration_pending || generation <= self.generation {
                    anyhow::bail!("invalid machine-agent migration commit");
                }
                self.send(Message::GenerationReady(GenerationReady {
                    from_generation: self.generation,
                    to_generation: generation,
                }))?;
                self.migration_pending = false;
                self.draining = true;
                Ok(false)
            }
            WorkerCommand::ResumeMigration { generation, code } => {
                self.send(Message::GenerationRejected(GenerationRejected { generation, code }))?;
                self.migration_pending = false;
                Ok(false)
            }
            WorkerCommand::Stop => Ok(true),
        }
    }

    fn open_stream(&mut self, open: OpenStream) -> anyhow::Result<()> {
        if self.migration_pending || self.draining {
            return self.reject(open.stream_id, "migrating");
        }
        if open.stream_id == 0
            || open.initial_window == 0
            || open.initial_window > protocol::MAX_STREAM_WINDOW_BYTES
        {
            return self.reject(open.stream_id, "invalid_open");
        }
        if self.streams.contains_key(&open.stream_id) {
            return self.reject(open.stream_id, "stream_replay");
        }
        if self.streams.len() >= protocol::MAX_ACTIVE_STREAMS {
            return self.reject(open.stream_id, "stream_limit");
        }
        let new_open = self
            .recent_opens
            .lock()
            .map_err(|_| anyhow::anyhow!("machine-agent replay cache is poisoned"))?
            .insert(open.open_id);
        if !new_open {
            return self.reject(open.stream_id, "replay");
        }
        let connection = match self.local.open() {
            Ok(connection) => connection,
            Err(_) => return self.reject(open.stream_id, "local_unavailable"),
        };
        let DuplexConnection { reader, writer, control } = connection;
        let flow = Arc::new(StreamFlow::new(open.initial_window));
        spawn_local_reader(
            open.stream_id,
            reader,
            Arc::clone(&flow),
            Arc::clone(&control),
            self.inputs.clone(),
        )?;
        self.streams.insert(
            open.stream_id,
            ActiveStream {
                writer,
                control,
                flow,
                receive_remaining: protocol::MAX_STREAM_WINDOW_BYTES,
            },
        );
        self.send(Message::Opened(StreamOpened {
            stream_id: open.stream_id,
            receive_window: protocol::MAX_STREAM_WINDOW_BYTES,
        }))
    }

    fn write_local(&mut self, data: StreamData) -> anyhow::Result<()> {
        let stream_id = data.stream_id;
        let mut payload = data.payload.into_bytes();
        let length = u32::try_from(payload.len()).expect("protocol payload length fits u32");
        if length == 0 {
            payload.zeroize();
            return self.close_stream(stream_id, Some("flow_control"));
        }
        let Some(stream) = self.streams.get_mut(&stream_id) else {
            payload.zeroize();
            return self.reject(stream_id, "unknown_stream");
        };
        if length > stream.receive_remaining {
            payload.zeroize();
            self.close_stream(stream_id, Some("flow_control"))?;
            return Ok(());
        }
        stream.receive_remaining -= length;
        if stream.writer.write_all(&payload).and_then(|()| stream.writer.flush()).is_err() {
            payload.zeroize();
            self.close_stream(stream_id, Some("local_write"))?;
            return Ok(());
        }
        payload.zeroize();
        stream.receive_remaining = stream.receive_remaining.saturating_add(length);
        self.send(Message::Window(StreamWindow { stream_id, bytes: length }))
    }

    fn add_window(&mut self, window: StreamWindow) -> anyhow::Result<()> {
        if window.bytes == 0 {
            return self.close_stream(window.stream_id, Some("flow_control"));
        }
        let Some(stream) = self.streams.get(&window.stream_id) else {
            return self.reject(window.stream_id, "unknown_stream");
        };
        if !stream.flow.add_credit(window.bytes) {
            return self.close_stream(window.stream_id, Some("flow_control"));
        }
        Ok(())
    }

    fn close_stream(&mut self, stream_id: u32, notify: Option<&str>) -> anyhow::Result<()> {
        if let Some(stream) = self.streams.remove(&stream_id) {
            stream.close();
        }
        if let Some(code) = notify {
            self.send(Message::Close(StreamClosed { stream_id, code: error_code(code) }))?;
        }
        Ok(())
    }

    fn reap_local_streams(&mut self) -> anyhow::Result<()> {
        let closed = self
            .streams
            .iter()
            .filter_map(|(stream_id, stream)| {
                stream.flow.reader_result().map(|code| (*stream_id, code))
            })
            .collect::<Vec<_>>();
        for (stream_id, code) in closed {
            self.close_stream(stream_id, Some(code))?;
        }
        Ok(())
    }

    fn reject(&mut self, stream_id: u32, code: &str) -> anyhow::Result<()> {
        self.send(Message::Reject(StreamRejected { stream_id, code: error_code(code) }))
    }

    fn send(&mut self, message: Message) -> anyhow::Result<()> {
        protocol_io::write_frame(&mut self.writer, &Envelope::new(message)).map_err(Into::into)
    }

    fn close_all(&mut self) {
        for (_, stream) in self.streams.drain() {
            stream.close();
        }
        self.control.close();
    }
}

struct ActiveStream {
    writer: Box<dyn Write + Send>,
    control: Arc<dyn ConnectionControl>,
    flow: Arc<StreamFlow>,
    receive_remaining: u32,
}

impl ActiveStream {
    fn close(self) {
        self.flow.close("closed");
        self.control.close();
    }
}

struct StreamFlow {
    state: Mutex<StreamFlowState>,
    available: Condvar,
}

struct StreamFlowState {
    credit: u32,
    closed: bool,
    reader_result: Option<&'static str>,
}

impl StreamFlow {
    fn new(credit: u32) -> Self {
        Self {
            state: Mutex::new(StreamFlowState { credit, closed: false, reader_result: None }),
            available: Condvar::new(),
        }
    }

    fn reserve(&self) -> Option<usize> {
        let mut state = self.state.lock().ok()?;
        while state.credit == 0 && !state.closed {
            state = self.available.wait(state).ok()?;
        }
        if state.closed {
            return None;
        }
        let reserved = state.credit.min(protocol::MAX_DATA_BYTES as u32);
        state.credit -= reserved;
        Some(reserved as usize)
    }

    fn return_credit(&self, bytes: u32) {
        if let Ok(mut state) = self.state.lock() {
            state.credit =
                state.credit.saturating_add(bytes).min(protocol::MAX_STREAM_WINDOW_BYTES);
            self.available.notify_all();
        }
    }

    fn add_credit(&self, bytes: u32) -> bool {
        let Ok(mut state) = self.state.lock() else { return false };
        let Some(total) = state.credit.checked_add(bytes) else { return false };
        if total > protocol::MAX_STREAM_WINDOW_BYTES || state.closed {
            return false;
        }
        state.credit = total;
        self.available.notify_all();
        true
    }

    fn mark_reader_done(&self, code: &'static str) {
        if let Ok(mut state) = self.state.lock() {
            state.closed = true;
            state.reader_result.get_or_insert(code);
            self.available.notify_all();
        }
    }

    fn close(&self, code: &'static str) {
        self.mark_reader_done(code);
    }

    fn reader_result(&self) -> Option<&'static str> {
        self.state.lock().ok()?.reader_result
    }
}

fn spawn_local_reader(
    stream_id: u32,
    mut reader: Box<dyn Read + Send>,
    flow: Arc<StreamFlow>,
    control: Arc<dyn ConnectionControl>,
    sender: SyncSender<WorkerInput>,
) -> io::Result<()> {
    thread::Builder::new().name(format!("machine-agent-local-{stream_id}")).spawn(move || {
        while let Some(reserved) = flow.reserve() {
            let mut payload = vec![0u8; reserved];
            match reader.read(&mut payload) {
                Ok(0) => {
                    payload.zeroize();
                    flow.return_credit(reserved as u32);
                    flow.mark_reader_done("eof");
                    let _ = sender.try_send(WorkerInput::LocalWake);
                    break;
                }
                Ok(read) => {
                    payload.truncate(read);
                    flow.return_credit((reserved - read) as u32);
                    let payload = DataPayload::new(payload).expect("bounded local read");
                    match sender.try_send(WorkerInput::LocalData { stream_id, payload }) {
                        Ok(()) => {}
                        Err(TrySendError::Full(_)) => {
                            flow.mark_reader_done("queue_overflow");
                            control.close();
                            break;
                        }
                        Err(TrySendError::Disconnected(_)) => break,
                    }
                }
                Err(_) => {
                    payload.zeroize();
                    flow.return_credit(reserved as u32);
                    flow.mark_reader_done("local_read");
                    let _ = sender.try_send(WorkerInput::LocalWake);
                    break;
                }
            }
        }
    })?;
    Ok(())
}

#[derive(Default)]
struct RecentOpenIds {
    order: VecDeque<OpaqueId>,
    values: HashSet<OpaqueId>,
}

impl RecentOpenIds {
    fn insert(&mut self, open_id: OpaqueId) -> bool {
        if self.values.contains(&open_id) {
            return false;
        }
        self.values.insert(open_id.clone());
        self.order.push_back(open_id);
        while self.order.len() > protocol::MAX_RECENT_OPEN_IDS {
            if let Some(expired) = self.order.pop_front() {
                self.values.remove(&expired);
            }
        }
        true
    }
}

fn error_code(value: &str) -> ErrorCode {
    ErrorCode::new(value).expect("static machine-agent error code is valid")
}

#[cfg(test)]
mod tests {
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
    }

    impl Reporter for TestReporter {
        fn pairing_code(&self, code: &str) {
            self.codes.lock().unwrap().push(code.to_string());
        }

        fn registered(&self, _: &str) {}

        fn retrying(&self, delay: Duration) {
            self.retries.lock().unwrap().push(delay);
        }

        fn migration_failed(&self) {
            self.migrations.fetch_add(1, Ordering::Relaxed);
        }
    }

    #[derive(Default)]
    struct RecordingControl(AtomicBool);

    impl ConnectionControl for RecordingControl {
        fn close(&self) {
            self.0.store(true, Ordering::Release);
        }
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
        oversized.writer.write_all(&vec![b'x'; protocol::MAX_FRAME_BYTES + 1]).unwrap();
        oversized.writer.write_all(b"\n").unwrap();

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
    fn migration_overlaps_generations_and_rejects_replay_or_downgrade() {
        let (cloud, mut servers) = QueueCloud::new();
        let mut old_server = WirePeer::new(servers.remove(0));
        let mut new_server = WirePeer::new(servers.remove(0));
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
}
