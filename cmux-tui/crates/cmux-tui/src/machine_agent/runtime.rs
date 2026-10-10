use std::collections::{HashMap, HashSet, VecDeque};
use std::io::{self, BufRead, BufReader, Read, Write};
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
const CLOUD_WRITE_TIMEOUT: Duration = Duration::from_secs(10);
const EVENT_QUEUE_CAPACITY: usize = 128;
const LOCAL_OPEN_CONCURRENCY: usize = 4;
const LOCAL_OPEN_QUEUE_CAPACITY: usize = 8;
const LOCAL_OPEN_TIMEOUT: Duration = Duration::from_secs(10);
const LOCAL_WRITE_QUEUE_CAPACITY: usize = 8;
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
    fn pairing_code(&self, code: &str) -> io::Result<()>;
    fn registered(&self, session: &str);
    fn retrying(&self, delay: Duration);
    fn migration_failed(&self);
    fn diagnostic(&self, diagnostic: MachineAgentDiagnostic);
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum GenerationFailureKind {
    Transport,
    InvalidFrame,
    Registration,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum MachineAgentDiagnostic {
    GenerationStart(GenerationFailureKind),
    MigrationReplacementStart(GenerationFailureKind),
    MigrationPairingCode,
    MigrationGenerationMismatch,
    MigrationCommitDelivery,
}

impl MachineAgentDiagnostic {
    pub(super) fn code(self) -> &'static str {
        match self {
            Self::GenerationStart(GenerationFailureKind::Transport) => "generation_start.transport",
            Self::GenerationStart(GenerationFailureKind::InvalidFrame) => {
                "generation_start.invalid_frame"
            }
            Self::GenerationStart(GenerationFailureKind::Registration) => {
                "generation_start.registration"
            }
            Self::MigrationReplacementStart(GenerationFailureKind::Transport) => {
                "migration_replacement.transport"
            }
            Self::MigrationReplacementStart(GenerationFailureKind::InvalidFrame) => {
                "migration_replacement.invalid_frame"
            }
            Self::MigrationReplacementStart(GenerationFailureKind::Registration) => {
                "migration_replacement.registration"
            }
            Self::MigrationPairingCode => "migration_replacement.pairing_code",
            Self::MigrationGenerationMismatch => "migration_replacement.generation_mismatch",
            Self::MigrationCommitDelivery => "migration_commit.delivery",
        }
    }
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
        let local_opens = spawn_local_connectors(Arc::clone(&self.local))?;
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
                    local_opens.clone(),
                    events_tx.clone(),
                    Arc::clone(&recent_opens),
                ) {
                    Ok(started) => {
                        if let Err(error) = self.report_registration(&started.registered) {
                            started.handle.close();
                            for (_, worker) in workers {
                                worker.close();
                            }
                            return Err(error.into());
                        }
                        highest_generation = highest_generation.max(started.generation);
                        latest_worker = Some(started.worker_id);
                        workers.insert(started.worker_id, started.handle);
                    }
                    Err(error) => {
                        let delay = reconnect_delay(reconnect_attempt, self.wait.as_ref());
                        reconnect_attempt = reconnect_attempt.saturating_add(1);
                        self.reporter.diagnostic(MachineAgentDiagnostic::GenerationStart(
                            generation_failure_kind(&error),
                        ));
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
                    if workers.keys().any(|existing| *existing != worker_id) {
                        try_send_worker_command(
                            &workers,
                            worker_id,
                            WorkerCommand::ResumeMigration {
                                generation: request.generation,
                                code: error_code("migration_in_progress"),
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
                        local_opens.clone(),
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
                                self.reporter
                                    .diagnostic(MachineAgentDiagnostic::MigrationPairingCode);
                                self.reporter.migration_failed();
                                continue;
                            }
                            let Some(replacement) = commit_migration_replacement(
                                &workers,
                                worker_id,
                                started.generation,
                                started.handle,
                                self.reporter.as_ref(),
                            ) else {
                                continue;
                            };
                            highest_generation = started.generation;
                            latest_worker = Some(started.worker_id);
                            workers.insert(started.worker_id, replacement);
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
                            self.reporter
                                .diagnostic(MachineAgentDiagnostic::MigrationGenerationMismatch);
                            self.reporter.migration_failed();
                        }
                        Err(error) => {
                            try_send_worker_command(
                                &workers,
                                worker_id,
                                WorkerCommand::ResumeMigration {
                                    generation: request.generation,
                                    code: error_code("migration_failed"),
                                },
                            );
                            self.reporter.diagnostic(
                                MachineAgentDiagnostic::MigrationReplacementStart(
                                    generation_failure_kind(&error),
                                ),
                            );
                            self.reporter.migration_failed();
                        }
                    }
                }
                Ok(CoordinatorEvent::Closed { worker_id, stable }) => {
                    if let Some(worker) = workers.remove(&worker_id) {
                        worker.finish();
                    }
                    if latest_worker == Some(worker_id) {
                        latest_worker = None;
                        if self.stop.requested() {
                            break;
                        }
                        if stable {
                            reconnect_attempt = 0;
                        }
                        let delay = reconnect_delay(reconnect_attempt, self.wait.as_ref());
                        reconnect_attempt = reconnect_attempt.saturating_add(1);
                        self.reporter.retrying(delay);
                        if !self.wait.wait(delay, self.stop.as_ref()) {
                            break;
                        }
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

    fn report_registration(&self, registered: &Registered) -> io::Result<()> {
        if let Some(code) = &registered.pairing_code {
            self.reporter.pairing_code(code.expose())?;
        }
        self.reporter.registered(self.session.as_str());
        Ok(())
    }

    fn start_generation(
        &self,
        minimum_generation: u64,
        migration: Option<MigrationProof>,
        local_opens: SyncSender<LocalOpenRequest>,
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
        if registered.generation < minimum_generation {
            control.close();
            anyhow::bail!("machine-agent registration attempted a generation downgrade");
        }

        let generation = registered.generation;
        let (inputs_tx, inputs_rx) = mpsc::sync_channel(EVENT_QUEUE_CAPACITY);
        let commands = inputs_tx.clone();
        let worker_control = Arc::clone(&control);
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
                    local_opens,
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

fn commit_migration_replacement(
    workers: &HashMap<u64, WorkerHandle>,
    worker_id: u64,
    generation: u64,
    replacement: WorkerHandle,
    reporter: &dyn Reporter,
) -> Option<WorkerHandle> {
    let (acknowledgment, result) = mpsc::sync_channel(1);
    if try_send_worker_command(
        workers,
        worker_id,
        WorkerCommand::CommitMigration { generation, acknowledgment },
    ) && matches!(result.recv_timeout(HANDSHAKE_TIMEOUT), Ok(true))
    {
        return Some(replacement);
    }
    if let Some(worker) = workers.get(&worker_id) {
        worker.control.close();
    }
    reporter.diagnostic(MachineAgentDiagnostic::MigrationCommitDelivery);
    reporter.migration_failed();
    replacement.close();
    None
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

fn generation_failure_kind(error: &anyhow::Error) -> GenerationFailureKind {
    for cause in error.chain() {
        if let Some(frame) = cause.downcast_ref::<FrameReadError>() {
            return match frame {
                FrameReadError::TooLarge | FrameReadError::Invalid(_) => {
                    GenerationFailureKind::InvalidFrame
                }
                FrameReadError::Io(_)
                | FrameReadError::Disconnected
                | FrameReadError::Truncated => GenerationFailureKind::Transport,
            };
        }
        if cause.downcast_ref::<io::Error>().is_some() {
            return GenerationFailureKind::Transport;
        }
    }
    GenerationFailureKind::Registration
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

enum WriteDeadlineCommand {
    Arm,
    Disarm,
}

struct WriteDeadline {
    commands: SyncSender<WriteDeadlineCommand>,
}

impl WriteDeadline {
    fn start(control: Arc<dyn ConnectionControl>, timeout: Duration) -> io::Result<Self> {
        let (commands, receiver) = mpsc::sync_channel(1);
        thread::Builder::new().name("mx-write-watch".into()).spawn(move || {
            while let Ok(WriteDeadlineCommand::Arm) = receiver.recv() {
                match receiver.recv_timeout(timeout) {
                    Ok(WriteDeadlineCommand::Disarm) => {}
                    Ok(WriteDeadlineCommand::Arm) | Err(RecvTimeoutError::Timeout) => {
                        control.close();
                        break;
                    }
                    Err(RecvTimeoutError::Disconnected) => break,
                }
            }
        })?;
        Ok(Self { commands })
    }

    fn write<W: Write>(&self, writer: &mut W, envelope: &Envelope) -> io::Result<()> {
        self.commands
            .send(WriteDeadlineCommand::Arm)
            .map_err(|_| io::Error::new(io::ErrorKind::BrokenPipe, "write watchdog stopped"))?;
        let result = protocol_io::write_frame(writer, envelope);
        let disarmed = self.commands.send(WriteDeadlineCommand::Disarm);
        match (result, disarmed) {
            (Err(error), _) => Err(error),
            (Ok(()), Ok(())) => Ok(()),
            (Ok(()), Err(_)) => {
                Err(io::Error::new(io::ErrorKind::TimedOut, "cloud write timed out"))
            }
        }
    }
}

enum CoordinatorEvent {
    MigrationRequested { worker_id: u64, generation: u64, request: ReconnectGeneration },
    Closed { worker_id: u64, stable: bool },
}

enum WorkerCommand {
    CommitMigration { generation: u64, acknowledgment: SyncSender<bool> },
    ResumeMigration { generation: u64, code: ErrorCode },
    Stop,
}

enum WorkerInput {
    Cloud(Result<Envelope, FrameReadError>),
    LocalOpenCompleted {
        stream_id: u32,
        instance_id: u64,
        connection: io::Result<DuplexConnection>,
    },
    LocalData {
        stream_id: u32,
        instance_id: u64,
        payload: DataPayload,
    },
    LocalWriteComplete {
        stream_id: u32,
        instance_id: u64,
        bytes: u32,
    },
    LocalWriteFailed {
        stream_id: u32,
        instance_id: u64,
    },
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
    local_opens: SyncSender<LocalOpenRequest>,
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
        reader,
        control,
        local_opens,
        coordinator,
        inputs_tx,
        inputs_rx,
        recent_opens,
    } = context;
    let cloud_sender = inputs_tx.clone();
    if spawn_cloud_reader_with(
        worker_id,
        generation,
        reader,
        Arc::clone(&control),
        cloud_sender,
        coordinator.clone(),
        |name, task| thread::Builder::new().name(name).spawn(task),
    )
    .is_err()
    {
        return;
    }
    let write_deadline = match WriteDeadline::start(Arc::clone(&control), CLOUD_WRITE_TIMEOUT) {
        Ok(write_deadline) => write_deadline,
        Err(_) => {
            control.close();
            let _ = coordinator.send(CoordinatorEvent::Closed { worker_id, stable: false });
            return;
        }
    };

    let mut state = GenerationState {
        generation,
        writer,
        write_deadline,
        control: Arc::clone(&control),
        local_opens,
        inputs: inputs_tx,
        recent_opens,
        pending_opens: HashMap::new(),
        streams: HashMap::new(),
        next_stream_instance_id: 1,
        migration_pending: false,
        draining: false,
        heartbeat,
        last_received: Instant::now(),
        last_ping: Instant::now(),
        next_ping_nonce: 1,
    };
    let stable_after = heartbeat.saturating_mul(3);
    let started_at = Instant::now();
    let _ = state.run(worker_id, &coordinator, inputs_rx);
    let stable = started_at.elapsed() >= stable_after;
    state.close_all();
    control.close();
    let _ = coordinator.send(CoordinatorEvent::Closed { worker_id, stable });
}

fn spawn_cloud_reader_with<R, S>(
    worker_id: u64,
    generation: u64,
    mut reader: R,
    control: Arc<dyn ConnectionControl>,
    sender: SyncSender<WorkerInput>,
    coordinator: SyncSender<CoordinatorEvent>,
    spawn: S,
) -> io::Result<JoinHandle<()>>
where
    R: BufRead + Send + 'static,
    S: FnOnce(String, Box<dyn FnOnce() + Send>) -> io::Result<JoinHandle<()>>,
{
    let reader_control = Arc::clone(&control);
    let task: Box<dyn FnOnce() + Send> = Box::new(move || {
        loop {
            let frame = protocol_io::read_frame(&mut reader);
            let terminal = frame.is_err();
            if sender.send(WorkerInput::Cloud(frame)).is_err() || terminal {
                break;
            }
        }
        reader_control.close();
    });
    match spawn(format!("machine-agent-cloud-reader-{generation}"), task) {
        Ok(handle) => Ok(handle),
        Err(error) => {
            control.close();
            let _ = coordinator.send(CoordinatorEvent::Closed { worker_id, stable: false });
            Err(error)
        }
    }
}

struct LocalOpenRequest {
    stream_id: u32,
    instance_id: u64,
    sender: SyncSender<WorkerInput>,
}

fn spawn_local_connectors(
    local: Arc<dyn LocalSessionConnector>,
) -> io::Result<SyncSender<LocalOpenRequest>> {
    let (requests, receiver) = mpsc::sync_channel::<LocalOpenRequest>(LOCAL_OPEN_QUEUE_CAPACITY);
    let receiver = Arc::new(Mutex::new(receiver));
    for index in 0..LOCAL_OPEN_CONCURRENCY {
        let local = Arc::clone(&local);
        let receiver = Arc::clone(&receiver);
        thread::Builder::new().name(format!("mx-local-open-{index}")).spawn(move || {
            loop {
                let request = receiver.lock().unwrap().recv();
                let Ok(request) = request else { break };
                let connection = local.open();
                if let Err(error) = request.sender.send(WorkerInput::LocalOpenCompleted {
                    stream_id: request.stream_id,
                    instance_id: request.instance_id,
                    connection,
                }) && let WorkerInput::LocalOpenCompleted { connection: Ok(connection), .. } =
                    error.0
                {
                    connection.control.close();
                }
            }
        })?;
    }
    Ok(requests)
}

struct GenerationState {
    generation: u64,
    writer: Box<dyn Write + Send>,
    write_deadline: WriteDeadline,
    control: Arc<dyn ConnectionControl>,
    local_opens: SyncSender<LocalOpenRequest>,
    inputs: SyncSender<WorkerInput>,
    recent_opens: Arc<Mutex<RecentOpenIds>>,
    pending_opens: HashMap<u32, PendingLocalOpen>,
    streams: HashMap<u32, ActiveStream>,
    next_stream_instance_id: u64,
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
                Ok(WorkerInput::LocalOpenCompleted { stream_id, instance_id, connection }) => {
                    self.handle_local_open_completed(stream_id, instance_id, connection)?;
                }
                Ok(WorkerInput::LocalData { stream_id, instance_id, payload }) => {
                    self.handle_local_data(stream_id, instance_id, payload)?;
                }
                Ok(WorkerInput::LocalWriteComplete { stream_id, instance_id, bytes }) => {
                    self.complete_local_write(stream_id, instance_id, bytes)?;
                }
                Ok(WorkerInput::LocalWriteFailed { stream_id, instance_id }) => {
                    self.fail_local_write(stream_id, instance_id)?;
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
            self.reap_pending_opens()?;
            self.reap_local_streams()?;
            if self.draining && self.pending_opens.is_empty() && self.streams.is_empty() {
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
            WorkerCommand::CommitMigration { generation, acknowledgment } => {
                if !self.migration_pending || generation <= self.generation {
                    let _ = acknowledgment.try_send(false);
                    anyhow::bail!("invalid machine-agent migration commit");
                }
                if let Err(error) = self.send(Message::GenerationReady(GenerationReady {
                    from_generation: self.generation,
                    to_generation: generation,
                })) {
                    let _ = acknowledgment.try_send(false);
                    return Err(error);
                }
                self.migration_pending = false;
                self.draining = true;
                self.reject_pending_opens("migrating")?;
                let _ = acknowledgment.try_send(true);
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
        if self.streams.contains_key(&open.stream_id)
            || self.pending_opens.contains_key(&open.stream_id)
        {
            return self.reject(open.stream_id, "stream_replay");
        }
        if self.streams.len() + self.pending_opens.len() >= protocol::MAX_ACTIVE_STREAMS {
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
        let instance_id = self.next_stream_instance_id;
        let Some(next_instance_id) = instance_id.checked_add(1) else {
            return self.reject(open.stream_id, "stream_limit");
        };
        self.next_stream_instance_id = next_instance_id;
        let request = LocalOpenRequest {
            stream_id: open.stream_id,
            instance_id,
            sender: self.inputs.clone(),
        };
        if self.local_opens.try_send(request).is_err() {
            return self.reject(open.stream_id, "local_unavailable");
        }
        self.pending_opens.insert(
            open.stream_id,
            PendingLocalOpen {
                instance_id,
                initial_window: open.initial_window,
                deadline: Instant::now() + LOCAL_OPEN_TIMEOUT,
            },
        );
        Ok(())
    }

    fn handle_local_open_completed(
        &mut self,
        stream_id: u32,
        instance_id: u64,
        connection: io::Result<DuplexConnection>,
    ) -> anyhow::Result<()> {
        let Some(pending) = self.pending_opens.remove(&stream_id) else {
            if let Ok(connection) = connection {
                connection.control.close();
            }
            return Ok(());
        };
        if pending.instance_id != instance_id {
            if let Ok(connection) = connection {
                connection.control.close();
            }
            self.pending_opens.insert(stream_id, pending);
            return Ok(());
        }
        let connection = match connection {
            Ok(connection) => connection,
            Err(_) => return self.reject(stream_id, "local_unavailable"),
        };
        let DuplexConnection { reader, writer, control } = connection;
        let flow = Arc::new(StreamFlow::new(pending.initial_window));
        let writes = match spawn_local_writer(
            stream_id,
            instance_id,
            writer,
            Arc::clone(&control),
            self.inputs.clone(),
        ) {
            Ok(writes) => writes,
            Err(_) => {
                control.close();
                return self.reject(stream_id, "local_unavailable");
            }
        };
        if spawn_local_reader(
            stream_id,
            instance_id,
            reader,
            Arc::clone(&flow),
            Arc::clone(&control),
            self.inputs.clone(),
        )
        .is_err()
        {
            drop(writes);
            control.close();
            return self.reject(stream_id, "local_unavailable");
        }
        self.streams.insert(
            stream_id,
            ActiveStream {
                instance_id,
                writes,
                control,
                flow,
                receive_remaining: protocol::MAX_STREAM_WINDOW_BYTES,
            },
        );
        self.send(Message::Opened(StreamOpened {
            stream_id,
            receive_window: protocol::MAX_STREAM_WINDOW_BYTES,
        }))
    }

    fn write_local(&mut self, data: StreamData) -> anyhow::Result<()> {
        let stream_id = data.stream_id;
        let length =
            u32::try_from(data.payload.as_bytes().len()).expect("protocol payload length fits u32");
        if length == 0 {
            return self.close_stream(stream_id, Some("flow_control"));
        }
        let Some(stream) = self.streams.get_mut(&stream_id) else {
            return self.reject(stream_id, "unknown_stream");
        };
        if length > stream.receive_remaining {
            self.close_stream(stream_id, Some("flow_control"))?;
            return Ok(());
        }
        stream.receive_remaining -= length;
        if stream.writes.try_send(data.payload).is_err() {
            self.close_stream(stream_id, Some("local_write"))?;
        }
        Ok(())
    }

    fn handle_local_data(
        &mut self,
        stream_id: u32,
        instance_id: u64,
        payload: DataPayload,
    ) -> anyhow::Result<()> {
        if self.streams.get(&stream_id).is_some_and(|stream| stream.instance_id == instance_id) {
            self.send(Message::Data(StreamData { stream_id, payload }))?;
        }
        Ok(())
    }

    fn complete_local_write(
        &mut self,
        stream_id: u32,
        instance_id: u64,
        bytes: u32,
    ) -> anyhow::Result<()> {
        let Some(stream) = self.streams.get_mut(&stream_id) else {
            return Ok(());
        };
        if stream.instance_id != instance_id {
            return Ok(());
        }
        let Some(receive_remaining) = stream.receive_remaining.checked_add(bytes) else {
            return self.close_stream(stream_id, Some("flow_control"));
        };
        if receive_remaining > protocol::MAX_STREAM_WINDOW_BYTES {
            return self.close_stream(stream_id, Some("flow_control"));
        }
        stream.receive_remaining = receive_remaining;
        self.send(Message::Window(StreamWindow { stream_id, bytes }))
    }

    fn fail_local_write(&mut self, stream_id: u32, instance_id: u64) -> anyhow::Result<()> {
        if self.streams.get(&stream_id).is_some_and(|stream| stream.instance_id == instance_id) {
            self.close_stream(stream_id, Some("local_write"))?;
        }
        Ok(())
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
        self.pending_opens.remove(&stream_id);
        if let Some(stream) = self.streams.remove(&stream_id) {
            stream.close();
        }
        if let Some(code) = notify {
            self.send(Message::Close(StreamClosed { stream_id, code: error_code(code) }))?;
        }
        Ok(())
    }

    fn reap_pending_opens(&mut self) -> anyhow::Result<()> {
        let expired = self
            .pending_opens
            .iter()
            .filter_map(|(stream_id, pending)| {
                (Instant::now() >= pending.deadline).then_some(*stream_id)
            })
            .collect::<Vec<_>>();
        for stream_id in expired {
            self.pending_opens.remove(&stream_id);
            self.reject(stream_id, "local_unavailable")?;
        }
        Ok(())
    }

    fn reject_pending_opens(&mut self, code: &str) -> anyhow::Result<()> {
        let stream_ids = self.pending_opens.keys().copied().collect::<Vec<_>>();
        self.pending_opens.clear();
        for stream_id in stream_ids {
            self.reject(stream_id, code)?;
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
        self.write_deadline.write(&mut self.writer, &Envelope::new(message)).map_err(Into::into)
    }

    fn close_all(&mut self) {
        self.pending_opens.clear();
        for (_, stream) in self.streams.drain() {
            stream.close();
        }
        self.control.close();
    }
}

struct PendingLocalOpen {
    instance_id: u64,
    initial_window: u32,
    deadline: Instant,
}

struct ActiveStream {
    instance_id: u64,
    writes: SyncSender<DataPayload>,
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
    instance_id: u64,
    mut reader: Box<dyn Read + Send>,
    flow: Arc<StreamFlow>,
    control: Arc<dyn ConnectionControl>,
    sender: SyncSender<WorkerInput>,
) -> io::Result<()> {
    thread::Builder::new().name(format!("machine-agent-local-reader-{stream_id}")).spawn(
        move || {
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
                        match sender.try_send(WorkerInput::LocalData {
                            stream_id,
                            instance_id,
                            payload,
                        }) {
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
        },
    )?;
    Ok(())
}

fn spawn_local_writer(
    stream_id: u32,
    instance_id: u64,
    mut writer: Box<dyn Write + Send>,
    control: Arc<dyn ConnectionControl>,
    sender: SyncSender<WorkerInput>,
) -> io::Result<SyncSender<DataPayload>> {
    let (writes, receiver) = mpsc::sync_channel::<DataPayload>(LOCAL_WRITE_QUEUE_CAPACITY);
    thread::Builder::new().name(format!("machine-agent-local-writer-{stream_id}")).spawn(
        move || {
            while let Ok(payload) = receiver.recv() {
                let mut bytes = payload.into_bytes();
                let length = u32::try_from(bytes.len()).expect("protocol payload length fits u32");
                let result = writer.write_all(&bytes).and_then(|()| writer.flush());
                bytes.zeroize();
                let event = if result.is_ok() {
                    WorkerInput::LocalWriteComplete { stream_id, instance_id, bytes: length }
                } else {
                    control.close();
                    WorkerInput::LocalWriteFailed { stream_id, instance_id }
                };
                if sender.send(event).is_err() || result.is_err() {
                    break;
                }
            }
        },
    )?;
    Ok(writes)
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
