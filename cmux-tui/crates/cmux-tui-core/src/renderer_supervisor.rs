//! Daemon-owned lifecycle for per-workspace terminal renderer workers.
//!
//! A worker exists only while at least one presentation exposes its workspace.
//! The daemon passes a private, close-on-exec Unix socket carrying the binary
//! [`crate::renderer_control`] protocol. PTY descriptors and PTY bytes never
//! cross this boundary.

use std::collections::{BTreeMap, BTreeSet, VecDeque};
#[cfg(unix)]
use std::ffi::OsString;
use std::fmt;
use std::io;
#[cfg(unix)]
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::ExitStatus;
#[cfg(unix)]
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{RecvTimeoutError, SyncSender, sync_channel};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use crate::renderer_control::{
    RendererBootstrap, RendererControlDirection, RendererControlEncoder, RendererControlEnvelope,
    RendererControlError, RendererControlIncrementalDecoder, RendererControlMessage,
    RendererControlSessionStateMachine, RendererControlWire, RendererNeedsFullScene,
    RendererPresentationReady, RendererSceneCapabilities, RendererWorkerReady,
};
use crate::{DaemonInstanceId, PresentationId, WorkspaceUuid};
use serde::Serialize;

const DEFAULT_HELPER_NAME: &str = "cmux-terminal-renderer";
const CONTROL_FD: i32 = 198;
const CHILD_POLL_INTERVAL: Duration = Duration::from_millis(100);
const MAXIMUM_COMMAND_QUEUE_LENGTH: usize = 8_192;

/// Renderer workers receive resolved terminal configuration over their private
/// control channel. They only need process-local paths and locale state from
/// the daemon environment, never credentials or daemon/frontend capabilities.
#[cfg(unix)]
const RENDERER_ENVIRONMENT_ALLOWLIST: &[&str] =
    &["HOME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "GHOSTTY_RESOURCES_DIR"];

#[cfg(unix)]
fn renderer_child_environment(
    environment: impl IntoIterator<Item = (OsString, OsString)>,
) -> BTreeMap<OsString, OsString> {
    environment
        .into_iter()
        .filter(|(name, value)| {
            !value.is_empty()
                && RENDERER_ENVIRONMENT_ALLOWLIST.iter().any(|allowed| name == allowed)
        })
        .collect()
}

/// Resolve the worker beside the running cmux-tui binary in Resources/bin.
/// An override is intentionally available for isolated tests and development.
pub fn resolve_renderer_executable(
    current_executable: &Path,
    explicit_override: Option<&Path>,
) -> io::Result<PathBuf> {
    if let Some(path) = explicit_override {
        if path.as_os_str().is_empty() {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "empty renderer path"));
        }
        return Ok(path.to_path_buf());
    }
    let directory = current_executable.parent().ok_or_else(|| {
        io::Error::new(io::ErrorKind::InvalidInput, "cmux-tui executable has no parent directory")
    })?;
    Ok(directory.join(DEFAULT_HELPER_NAME))
}

#[derive(Debug, Clone)]
pub struct RendererSupervisorConfig {
    pub executable: PathBuf,
    pub daemon_instance_id: DaemonInstanceId,
    pub initial_restart_delay: Duration,
    pub maximum_restart_delay: Duration,
}

impl RendererSupervisorConfig {
    pub fn bundled(daemon_instance_id: DaemonInstanceId) -> io::Result<Self> {
        let current = std::env::current_exe()?;
        Ok(Self {
            executable: resolve_renderer_executable(&current, None)?,
            daemon_instance_id,
            initial_restart_delay: Duration::from_millis(100),
            maximum_restart_delay: Duration::from_secs(10),
        })
    }

    fn validate(&self) -> io::Result<()> {
        if self.executable.as_os_str().is_empty() {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "empty renderer path"));
        }
        if self.initial_restart_delay.is_zero()
            || self.maximum_restart_delay < self.initial_restart_delay
        {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "invalid restart bounds"));
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum RendererWorkerState {
    Starting,
    Ready,
    Backoff,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct RendererWorkerStatus {
    pub workspace_uuid: WorkspaceUuid,
    pub renderer_epoch: u64,
    pub pid: Option<u32>,
    pub effective_user_id: Option<u32>,
    pub scene_capabilities: Option<u64>,
    pub restart_count: u64,
    pub visible_presentation_count: usize,
    pub state: RendererWorkerState,
    pub retry_after_milliseconds: Option<u64>,
    pub last_error: Option<String>,
}

/// Authenticated worker lifecycle messages delivered after the binary
/// control-session state machine accepts their workspace, epoch, process, and
/// presentation fences.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RendererSupervisorEvent {
    WorkerReady {
        workspace_uuid: WorkspaceUuid,
        renderer_epoch: u64,
        process_id: u32,
        effective_user_id: u32,
        scene_capabilities: RendererSceneCapabilities,
    },
    NeedsFullScene {
        workspace_uuid: WorkspaceUuid,
        renderer_epoch: u64,
        request: RendererNeedsFullScene,
    },
    WorkerUnavailable {
        workspace_uuid: WorkspaceUuid,
        renderer_epoch: u64,
        process_id: Option<u32>,
        reason: String,
    },
    PresentationReady {
        workspace_uuid: WorkspaceUuid,
        renderer_epoch: u64,
        process_id: u32,
        metrics: RendererPresentationReady,
    },
}

type RendererSupervisorEventHandler = Arc<dyn Fn(RendererSupervisorEvent) + Send + Sync + 'static>;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RendererSupervisorError {
    Stopped,
    QueueFull,
    UnknownWorkspace(WorkspaceUuid),
    WorkerNotReady(WorkspaceUuid),
    StaleWorkerReply { workspace_uuid: WorkspaceUuid, renderer_epoch: u64, pid: u32 },
    ProcessIdentityMismatch { expected: u32, actual: u32 },
    EffectiveUserIdentityMismatch { expected: u32, actual: u32 },
    EpochExhausted,
    Protocol(RendererControlError),
    Io(String),
}

impl fmt::Display for RendererSupervisorError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "renderer supervisor error: {self:?}")
    }
}

impl std::error::Error for RendererSupervisorError {}

impl From<RendererControlError> for RendererSupervisorError {
    fn from(value: RendererControlError) -> Self {
        Self::Protocol(value)
    }
}

impl From<io::Error> for RendererSupervisorError {
    fn from(value: io::Error) -> Self {
        Self::Io(value.to_string())
    }
}

/// The production handle. Its coordinator thread and child processes are
/// owned by cmuxd and are synchronously terminated and reaped on drop.
pub struct RendererSupervisor {
    shared: Arc<Shared>,
    coordinator: Option<JoinHandle<()>>,
}

impl RendererSupervisor {
    pub fn start(config: RendererSupervisorConfig) -> io::Result<Self> {
        config.validate()?;
        let clock = SystemSupervisorClock::new();
        let spawner = CommandRendererSpawner::new(config.executable.clone());
        let shared = Arc::new(Shared::default());
        let coordinator_shared = shared.clone();
        let coordinator = thread::Builder::new()
            .name("cmux-renderer-supervisor".to_owned())
            .spawn(move || {
                let mut core = SupervisorCore::new(
                    spawner,
                    clock,
                    config.daemon_instance_id,
                    config.initial_restart_delay,
                    config.maximum_restart_delay,
                );
                coordinator_loop(&coordinator_shared, &mut core);
            })?;
        Ok(Self { shared, coordinator: Some(coordinator) })
    }

    /// Declare which workspace a live presentation currently displays.
    /// Passing `None` makes the presentation non-visible without destroying it.
    pub fn set_presentation_workspace(
        &self,
        presentation_id: PresentationId,
        workspace_uuid: Option<WorkspaceUuid>,
    ) -> Result<(), RendererSupervisorError> {
        self.enqueue(CoordinatorCommand::SetPresentation { presentation_id, workspace_uuid })
    }

    pub fn remove_presentation(
        &self,
        presentation_id: PresentationId,
    ) -> Result<(), RendererSupervisorError> {
        self.enqueue(CoordinatorCommand::RemovePresentation { presentation_id })
    }

    /// Drop visibility for workspaces removed from canonical mux topology.
    pub fn retain_workspaces(
        &self,
        workspace_uuids: BTreeSet<WorkspaceUuid>,
    ) -> Result<(), RendererSupervisorError> {
        self.enqueue(CoordinatorCommand::RetainWorkspaces { workspace_uuids })
    }

    /// Queue one daemon-to-worker control message. Messages accepted before
    /// Ready are retained in-order and flushed after the handshake.
    pub fn send(
        &self,
        workspace_uuid: WorkspaceUuid,
        message: RendererControlMessage,
    ) -> Result<(), RendererSupervisorError> {
        if message.direction() != RendererControlDirection::DaemonToWorker
            || matches!(message, RendererControlMessage::Bootstrap(_))
        {
            return Err(RendererSupervisorError::Protocol(
                RendererControlError::UnexpectedDirection,
            ));
        }
        self.enqueue(CoordinatorCommand::Send { workspace_uuid, message })
    }

    /// Queue a message only for the exact live worker lifetime. If that
    /// worker is no longer ready when the coordinator observes the command,
    /// it is discarded. The next authenticated `WorkerReady` event causes
    /// the daemon owner to replay current desired state instead.
    pub fn send_if_epoch(
        &self,
        workspace_uuid: WorkspaceUuid,
        renderer_epoch: u64,
        messages: Vec<RendererControlMessage>,
    ) -> Result<(), RendererSupervisorError> {
        if messages.is_empty()
            || messages.iter().any(|message| {
                message.direction() != RendererControlDirection::DaemonToWorker
                    || matches!(message, RendererControlMessage::Bootstrap(_))
            })
        {
            return Err(RendererSupervisorError::Protocol(
                RendererControlError::UnexpectedDirection,
            ));
        }
        self.enqueue(CoordinatorCommand::SendIfEpoch { workspace_uuid, renderer_epoch, messages })
    }

    pub(crate) fn set_event_handler(&self, handler: RendererSupervisorEventHandler) {
        *self.shared.event_handler.lock().unwrap() = Some(handler);
    }

    /// Machine-readable lifecycle proof for the debug protocol.
    pub fn statuses(&self) -> Vec<RendererWorkerStatus> {
        self.shared.statuses.lock().unwrap().clone()
    }

    /// Observe one worker after all previously enqueued lifecycle commands.
    /// This is used by the local frontend attach handshake to obtain the
    /// renderer epoch that fences its frame endpoint.
    pub fn workspace_status(
        &self,
        workspace_uuid: WorkspaceUuid,
    ) -> Result<Option<RendererWorkerStatus>, RendererSupervisorError> {
        let (reply, response) = sync_channel(1);
        self.enqueue(CoordinatorCommand::WorkspaceStatus { workspace_uuid, reply })?;
        match response.recv_timeout(Duration::from_secs(1)) {
            Ok(status) => Ok(status),
            Err(RecvTimeoutError::Timeout) => {
                Err(RendererSupervisorError::Io("renderer status request timed out".to_owned()))
            }
            Err(RecvTimeoutError::Disconnected) => Err(RendererSupervisorError::Stopped),
        }
    }

    fn enqueue(&self, command: CoordinatorCommand) -> Result<(), RendererSupervisorError> {
        let mut state = self.shared.state.lock().unwrap();
        if state.stopping {
            return Err(RendererSupervisorError::Stopped);
        }
        if state.commands.len() >= MAXIMUM_COMMAND_QUEUE_LENGTH {
            return Err(RendererSupervisorError::QueueFull);
        }
        state.commands.push_back(command);
        self.shared.changed.notify_one();
        Ok(())
    }
}

impl Drop for RendererSupervisor {
    fn drop(&mut self) {
        {
            let mut state = self.shared.state.lock().unwrap();
            state.stopping = true;
            self.shared.changed.notify_all();
        }
        if let Some(coordinator) = self.coordinator.take() {
            let _ = coordinator.join();
        }
    }
}

#[derive(Default)]
struct Shared {
    state: Mutex<CoordinatorState>,
    statuses: Mutex<Vec<RendererWorkerStatus>>,
    event_handler: Mutex<Option<RendererSupervisorEventHandler>>,
    changed: Condvar,
}

#[derive(Default)]
struct CoordinatorState {
    commands: VecDeque<CoordinatorCommand>,
    stopping: bool,
}

enum CoordinatorCommand {
    SetPresentation {
        presentation_id: PresentationId,
        workspace_uuid: Option<WorkspaceUuid>,
    },
    RemovePresentation {
        presentation_id: PresentationId,
    },
    RetainWorkspaces {
        workspace_uuids: BTreeSet<WorkspaceUuid>,
    },
    Send {
        workspace_uuid: WorkspaceUuid,
        message: RendererControlMessage,
    },
    SendIfEpoch {
        workspace_uuid: WorkspaceUuid,
        renderer_epoch: u64,
        messages: Vec<RendererControlMessage>,
    },
    WorkspaceStatus {
        workspace_uuid: WorkspaceUuid,
        reply: SyncSender<Option<RendererWorkerStatus>>,
    },
}

fn coordinator_loop<S, C>(shared: &Shared, core: &mut SupervisorCore<S, C>)
where
    S: RendererSpawner,
    C: SupervisorClock,
{
    loop {
        let commands = {
            let mut state = shared.state.lock().unwrap();
            if state.commands.is_empty() && !state.stopping {
                let timeout = core.next_wake_after().min(CHILD_POLL_INTERVAL);
                let (next, _) = shared.changed.wait_timeout(state, timeout).unwrap();
                state = next;
            }
            if state.stopping {
                core.shutdown();
                *shared.statuses.lock().unwrap() = Vec::new();
                return;
            }
            state.commands.drain(..).collect::<Vec<_>>()
        };

        for command in commands {
            match command {
                CoordinatorCommand::SetPresentation { presentation_id, workspace_uuid } => {
                    core.set_presentation_workspace(presentation_id, workspace_uuid);
                }
                CoordinatorCommand::RemovePresentation { presentation_id } => {
                    core.remove_presentation(presentation_id);
                }
                CoordinatorCommand::RetainWorkspaces { workspace_uuids } => {
                    core.retain_workspaces(&workspace_uuids);
                }
                CoordinatorCommand::Send { workspace_uuid, message } => {
                    if let Err(error) = core.send(workspace_uuid, message) {
                        core.worker_failed(workspace_uuid, error.to_string());
                    }
                }
                CoordinatorCommand::SendIfEpoch { workspace_uuid, renderer_epoch, messages } => {
                    core.send_if_epoch(workspace_uuid, renderer_epoch, messages);
                }
                CoordinatorCommand::WorkspaceStatus { workspace_uuid, reply } => {
                    let status = core
                        .statuses()
                        .into_iter()
                        .find(|status| status.workspace_uuid == workspace_uuid);
                    let _ = reply.send(status);
                }
            }
        }
        core.tick();
        *shared.statuses.lock().unwrap() = core.statuses();
        for event in core.take_events() {
            let handler = shared.event_handler.lock().unwrap().clone();
            if let Some(handler) = handler {
                handler(event);
            }
        }
    }
}

trait SupervisorClock: Clone + Send + 'static {
    fn now(&self) -> Duration;
}

#[derive(Clone)]
struct SystemSupervisorClock {
    origin: Instant,
}

impl SystemSupervisorClock {
    fn new() -> Self {
        Self { origin: Instant::now() }
    }
}

impl SupervisorClock for SystemSupervisorClock {
    fn now(&self) -> Duration {
        self.origin.elapsed()
    }
}

struct SpawnRequest {
    daemon_instance_id: DaemonInstanceId,
    workspace_uuid: WorkspaceUuid,
    renderer_epoch: u64,
}

trait RendererProcess: Send {
    fn pid(&self) -> u32;
    fn send(&mut self, bytes: &[u8]) -> io::Result<()>;
    fn receive(&mut self, destination: &mut Vec<u8>) -> io::Result<ReceiveResult>;
    fn try_wait(&mut self) -> io::Result<Option<ExitStatus>>;
    fn terminate_and_wait(&mut self) -> io::Result<()>;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ReceiveResult {
    Open,
    EndOfFile,
}

trait RendererSpawner: Send + 'static {
    type Process: RendererProcess;
    fn spawn(&mut self, request: &SpawnRequest) -> io::Result<Self::Process>;
}

struct Worker<P> {
    process: Option<P>,
    epoch: u64,
    restart_count: u64,
    failure_streak: u32,
    state: RendererWorkerState,
    retry_at: Option<Duration>,
    last_error: Option<String>,
    encoder: Option<RendererControlEncoder>,
    decoder: Option<RendererControlIncrementalDecoder>,
    session: Option<RendererControlSessionStateMachine>,
    outbox: VecDeque<RendererControlMessage>,
    effective_user_id: Option<u32>,
    scene_capabilities: Option<RendererSceneCapabilities>,
}

struct SupervisorCore<S, C>
where
    S: RendererSpawner,
    C: SupervisorClock,
{
    spawner: S,
    clock: C,
    daemon_instance_id: DaemonInstanceId,
    initial_restart_delay: Duration,
    maximum_restart_delay: Duration,
    presentations: BTreeMap<PresentationId, WorkspaceUuid>,
    workers: BTreeMap<WorkspaceUuid, Worker<S::Process>>,
    next_epoch: Option<u64>,
    events: VecDeque<RendererSupervisorEvent>,
}

impl<S, C> SupervisorCore<S, C>
where
    S: RendererSpawner,
    C: SupervisorClock,
{
    fn new(
        spawner: S,
        clock: C,
        daemon_instance_id: DaemonInstanceId,
        initial_restart_delay: Duration,
        maximum_restart_delay: Duration,
    ) -> Self {
        Self {
            spawner,
            clock,
            daemon_instance_id,
            initial_restart_delay,
            maximum_restart_delay,
            presentations: BTreeMap::new(),
            workers: BTreeMap::new(),
            next_epoch: Some(1),
            events: VecDeque::new(),
        }
    }

    fn set_presentation_workspace(
        &mut self,
        presentation_id: PresentationId,
        workspace_uuid: Option<WorkspaceUuid>,
    ) {
        match workspace_uuid {
            Some(workspace_uuid) => {
                self.presentations.insert(presentation_id, workspace_uuid);
            }
            None => {
                self.presentations.remove(&presentation_id);
            }
        }
        self.reconcile();
    }

    fn remove_presentation(&mut self, presentation_id: PresentationId) {
        self.presentations.remove(&presentation_id);
        self.reconcile();
    }

    fn retain_workspaces(&mut self, workspace_uuids: &BTreeSet<WorkspaceUuid>) {
        self.presentations.retain(|_, workspace_uuid| workspace_uuids.contains(workspace_uuid));
        self.reconcile();
    }

    fn visible_workspaces(&self) -> BTreeSet<WorkspaceUuid> {
        self.presentations.values().copied().collect()
    }

    fn reconcile(&mut self) {
        let desired = self.visible_workspaces();
        let dormant = self
            .workers
            .keys()
            .filter(|workspace| !desired.contains(workspace))
            .copied()
            .collect::<Vec<_>>();
        for workspace in dormant {
            if let Some(mut worker) = self.workers.remove(&workspace) {
                self.events.push_back(RendererSupervisorEvent::WorkerUnavailable {
                    workspace_uuid: workspace,
                    renderer_epoch: worker.epoch,
                    process_id: worker.process.as_ref().map(RendererProcess::pid),
                    reason: "workspace is no longer visible".to_owned(),
                });
                stop_worker(&mut worker);
            }
        }
        for workspace in desired {
            if !self.workers.contains_key(&workspace) {
                self.spawn_initial(workspace);
            }
        }
    }

    fn allocate_epoch(&mut self) -> Result<u64, RendererSupervisorError> {
        let epoch = self.next_epoch.ok_or(RendererSupervisorError::EpochExhausted)?;
        self.next_epoch = epoch.checked_add(1);
        Ok(epoch)
    }

    fn spawn_initial(&mut self, workspace_uuid: WorkspaceUuid) {
        match self.allocate_epoch() {
            Ok(epoch) => {
                let worker = self.spawn_worker(workspace_uuid, epoch, 0, 0, VecDeque::new());
                self.workers.insert(workspace_uuid, worker);
            }
            Err(error) => {
                self.workers.insert(
                    workspace_uuid,
                    Worker {
                        process: None,
                        epoch: u64::MAX,
                        restart_count: 0,
                        failure_streak: 1,
                        state: RendererWorkerState::Backoff,
                        retry_at: None,
                        last_error: Some(error.to_string()),
                        encoder: None,
                        decoder: None,
                        session: None,
                        outbox: VecDeque::new(),
                        effective_user_id: None,
                        scene_capabilities: None,
                    },
                );
            }
        }
    }

    fn spawn_worker(
        &mut self,
        workspace_uuid: WorkspaceUuid,
        epoch: u64,
        restart_count: u64,
        failure_streak: u32,
        outbox: VecDeque<RendererControlMessage>,
    ) -> Worker<S::Process> {
        let request = SpawnRequest {
            daemon_instance_id: self.daemon_instance_id,
            workspace_uuid,
            renderer_epoch: epoch,
        };
        match self.spawner.spawn(&request) {
            Ok(mut process) => {
                let mut encoder =
                    RendererControlEncoder::new(RendererControlDirection::DaemonToWorker);
                let mut session = RendererControlSessionStateMachine::new();
                let bootstrap = RendererControlMessage::Bootstrap(RendererBootstrap {
                    daemon_instance_id: self.daemon_instance_id.as_uuid(),
                    workspace_id: workspace_uuid.as_uuid(),
                    renderer_epoch: epoch,
                });
                let bootstrap_result = encoder
                    .encode(bootstrap)
                    .map_err(RendererSupervisorError::from)
                    .and_then(|frame| {
                        let envelope = RendererControlWire::decode(&frame)?;
                        session.accept(&envelope)?;
                        process.send(&frame)?;
                        Ok(())
                    });
                match bootstrap_result {
                    Ok(()) => Worker {
                        process: Some(process),
                        epoch,
                        restart_count,
                        failure_streak,
                        state: RendererWorkerState::Starting,
                        retry_at: None,
                        last_error: None,
                        encoder: Some(encoder),
                        decoder: Some(RendererControlIncrementalDecoder::new(
                            RendererControlDirection::WorkerToDaemon,
                        )),
                        session: Some(session),
                        outbox,
                        effective_user_id: None,
                        scene_capabilities: None,
                    },
                    Err(error) => {
                        let _ = process.terminate_and_wait();
                        self.backoff_worker(
                            workspace_uuid,
                            epoch,
                            restart_count.saturating_add(1),
                            failure_streak.saturating_add(1),
                            error.to_string(),
                            outbox,
                        )
                    }
                }
            }
            Err(error) => self.backoff_worker(
                workspace_uuid,
                epoch,
                restart_count.saturating_add(1),
                failure_streak.saturating_add(1),
                error.to_string(),
                outbox,
            ),
        }
    }

    fn backoff_worker(
        &self,
        workspace_uuid: WorkspaceUuid,
        epoch: u64,
        restart_count: u64,
        failure_streak: u32,
        error: String,
        outbox: VecDeque<RendererControlMessage>,
    ) -> Worker<S::Process> {
        let delay = restart_delay(
            workspace_uuid,
            failure_streak,
            self.initial_restart_delay,
            self.maximum_restart_delay,
        );
        Worker {
            process: None,
            epoch,
            restart_count,
            failure_streak,
            state: RendererWorkerState::Backoff,
            retry_at: Some(self.clock.now().saturating_add(delay)),
            last_error: Some(error),
            encoder: None,
            decoder: None,
            session: None,
            outbox,
            effective_user_id: None,
            scene_capabilities: None,
        }
    }

    fn send(
        &mut self,
        workspace_uuid: WorkspaceUuid,
        message: RendererControlMessage,
    ) -> Result<(), RendererSupervisorError> {
        let worker = self
            .workers
            .get_mut(&workspace_uuid)
            .ok_or(RendererSupervisorError::UnknownWorkspace(workspace_uuid))?;
        if worker.state != RendererWorkerState::Ready {
            worker.outbox.push_back(message);
            return Ok(());
        }
        send_control_message(worker, message)
    }

    fn send_if_epoch(
        &mut self,
        workspace_uuid: WorkspaceUuid,
        renderer_epoch: u64,
        messages: Vec<RendererControlMessage>,
    ) {
        let result = (|| {
            let worker = self
                .workers
                .get_mut(&workspace_uuid)
                .ok_or(RendererSupervisorError::UnknownWorkspace(workspace_uuid))?;
            if worker.epoch != renderer_epoch || worker.state != RendererWorkerState::Ready {
                return Ok(());
            }
            for message in messages {
                send_control_message(worker, message)?;
            }
            Ok::<(), RendererSupervisorError>(())
        })();
        if let Err(error) = result {
            self.worker_failed(workspace_uuid, error.to_string());
        }
    }

    fn take_events(&mut self) -> Vec<RendererSupervisorEvent> {
        self.events.drain(..).collect()
    }

    fn tick(&mut self) {
        let workspaces = self.workers.keys().copied().collect::<Vec<_>>();
        for workspace_uuid in workspaces {
            self.poll_worker(workspace_uuid);
        }
        let now = self.clock.now();
        let due = self
            .workers
            .iter()
            .filter_map(|(workspace, worker)| {
                (worker.state == RendererWorkerState::Backoff
                    && worker.retry_at.is_some_and(|retry_at| retry_at <= now))
                .then_some(*workspace)
            })
            .collect::<Vec<_>>();
        for workspace_uuid in due {
            self.restart_worker(workspace_uuid);
        }
    }

    fn poll_worker(&mut self, workspace_uuid: WorkspaceUuid) {
        let mut received = Vec::new();
        let outcome = {
            let Some(worker) = self.workers.get_mut(&workspace_uuid) else { return };
            let Some(process) = worker.process.as_mut() else { return };
            match process.try_wait() {
                Ok(Some(status)) => Err(format!("worker exited with {status}")),
                Err(error) => Err(format!("failed to poll worker: {error}")),
                Ok(None) => match process.receive(&mut received) {
                    Ok(ReceiveResult::Open) => Ok(()),
                    Ok(ReceiveResult::EndOfFile) => Err("worker control socket closed".to_owned()),
                    Err(error) => Err(format!("failed to read worker control socket: {error}")),
                },
            }
        };
        if let Err(error) = outcome {
            self.worker_failed(workspace_uuid, error);
            return;
        }
        if received.is_empty() {
            return;
        }
        let envelopes = {
            let worker = self.workers.get_mut(&workspace_uuid).unwrap();
            worker.decoder.as_mut().unwrap().feed(&received)
        };
        match envelopes {
            Ok(envelopes) => {
                for envelope in envelopes {
                    let (epoch, pid) = {
                        let worker = self.workers.get(&workspace_uuid).unwrap();
                        (worker.epoch, worker.process.as_ref().unwrap().pid())
                    };
                    if let Err(error) =
                        self.accept_worker_envelope(workspace_uuid, epoch, pid, envelope)
                    {
                        self.worker_failed(workspace_uuid, error.to_string());
                        break;
                    }
                }
            }
            Err(error) => self.worker_failed(workspace_uuid, error.to_string()),
        }
    }

    fn accept_worker_envelope(
        &mut self,
        workspace_uuid: WorkspaceUuid,
        renderer_epoch: u64,
        pid: u32,
        envelope: RendererControlEnvelope,
    ) -> Result<(), RendererSupervisorError> {
        let worker = self
            .workers
            .get_mut(&workspace_uuid)
            .ok_or(RendererSupervisorError::UnknownWorkspace(workspace_uuid))?;
        let current_pid = worker.process.as_ref().map(RendererProcess::pid);
        if worker.epoch != renderer_epoch || current_pid != Some(pid) {
            return Err(RendererSupervisorError::StaleWorkerReply {
                workspace_uuid,
                renderer_epoch,
                pid,
            });
        }
        if let RendererControlMessage::Ready(RendererWorkerReady {
            process_id,
            effective_user_id,
            ..
        }) = &envelope.message
        {
            if *process_id != pid {
                return Err(RendererSupervisorError::ProcessIdentityMismatch {
                    expected: pid,
                    actual: *process_id,
                });
            }
            #[cfg(unix)]
            {
                let expected = unsafe { libc::geteuid() };
                if *effective_user_id != expected {
                    return Err(RendererSupervisorError::EffectiveUserIdentityMismatch {
                        expected,
                        actual: *effective_user_id,
                    });
                }
            }
        }
        worker.session.as_mut().unwrap().accept(&envelope)?;
        match envelope.message {
            RendererControlMessage::Ready(ready) => {
                worker.state = RendererWorkerState::Ready;
                worker.failure_streak = 0;
                worker.last_error = None;
                worker.effective_user_id = Some(ready.effective_user_id);
                worker.scene_capabilities = Some(ready.scene_capabilities);
                while let Some(message) = worker.outbox.pop_front() {
                    send_control_message(worker, message)?;
                }
                self.events.push_back(RendererSupervisorEvent::WorkerReady {
                    workspace_uuid,
                    renderer_epoch,
                    process_id: pid,
                    effective_user_id: ready.effective_user_id,
                    scene_capabilities: ready.scene_capabilities,
                });
            }
            RendererControlMessage::NeedsFullScene(request) => {
                self.events.push_back(RendererSupervisorEvent::NeedsFullScene {
                    workspace_uuid,
                    renderer_epoch,
                    request,
                });
            }
            RendererControlMessage::PresentationReady(metrics) => {
                self.events.push_back(RendererSupervisorEvent::PresentationReady {
                    workspace_uuid,
                    renderer_epoch,
                    process_id: pid,
                    metrics,
                });
            }
            RendererControlMessage::Fatal(fatal) => {
                return Err(RendererSupervisorError::Io(format!(
                    "worker fatal {:?}: {}",
                    fatal.code, fatal.diagnostic
                )));
            }
            _ => {}
        }
        Ok(())
    }

    fn worker_failed(&mut self, workspace_uuid: WorkspaceUuid, error: String) {
        let Some(mut previous) = self.workers.remove(&workspace_uuid) else { return };
        self.events.push_back(RendererSupervisorEvent::WorkerUnavailable {
            workspace_uuid,
            renderer_epoch: previous.epoch,
            process_id: previous.process.as_ref().map(RendererProcess::pid),
            reason: error.clone(),
        });
        if let Some(process) = previous.process.as_mut() {
            let _ = process.terminate_and_wait();
        }
        previous.process = None;
        let backoff = self.backoff_worker(
            workspace_uuid,
            previous.epoch,
            previous.restart_count.saturating_add(1),
            previous.failure_streak.saturating_add(1),
            error,
            previous.outbox,
        );
        self.workers.insert(workspace_uuid, backoff);
    }

    fn restart_worker(&mut self, workspace_uuid: WorkspaceUuid) {
        let Some(previous) = self.workers.remove(&workspace_uuid) else { return };
        let epoch = match self.allocate_epoch() {
            Ok(epoch) => epoch,
            Err(error) => {
                self.workers.insert(
                    workspace_uuid,
                    self.backoff_worker(
                        workspace_uuid,
                        previous.epoch,
                        previous.restart_count,
                        previous.failure_streak,
                        error.to_string(),
                        previous.outbox,
                    ),
                );
                return;
            }
        };
        let worker = self.spawn_worker(
            workspace_uuid,
            epoch,
            previous.restart_count,
            previous.failure_streak,
            previous.outbox,
        );
        self.workers.insert(workspace_uuid, worker);
    }

    fn next_wake_after(&self) -> Duration {
        let now = self.clock.now();
        self.workers
            .values()
            .filter_map(|worker| worker.retry_at)
            .map(|retry_at| retry_at.saturating_sub(now))
            .min()
            .unwrap_or(CHILD_POLL_INTERVAL)
    }

    fn statuses(&self) -> Vec<RendererWorkerStatus> {
        let now = self.clock.now();
        self.workers
            .iter()
            .map(|(workspace_uuid, worker)| RendererWorkerStatus {
                workspace_uuid: *workspace_uuid,
                renderer_epoch: worker.epoch,
                pid: worker.process.as_ref().map(RendererProcess::pid),
                restart_count: worker.restart_count,
                visible_presentation_count: self
                    .presentations
                    .values()
                    .filter(|workspace| *workspace == workspace_uuid)
                    .count(),
                state: worker.state,
                retry_after_milliseconds: worker
                    .retry_at
                    .map(|retry_at| duration_milliseconds(retry_at.saturating_sub(now))),
                last_error: worker.last_error.clone(),
                effective_user_id: worker.effective_user_id,
                scene_capabilities: worker.scene_capabilities.map(|value| value.bits()),
            })
            .collect()
    }

    fn shutdown(&mut self) {
        for worker in self.workers.values_mut() {
            stop_worker(worker);
        }
        self.workers.clear();
        self.presentations.clear();
    }
}

fn send_control_message<P: RendererProcess>(
    worker: &mut Worker<P>,
    message: RendererControlMessage,
) -> Result<(), RendererSupervisorError> {
    let frame = worker.encoder.as_mut().unwrap().encode(message)?;
    let envelope = RendererControlWire::decode(&frame)?;
    worker.session.as_mut().unwrap().accept(&envelope)?;
    worker.process.as_mut().unwrap().send(&frame)?;
    Ok(())
}

fn stop_worker<P: RendererProcess>(worker: &mut Worker<P>) {
    if worker.process.is_some() && worker.encoder.is_some() && worker.session.is_some() {
        let _ = send_control_message(worker, RendererControlMessage::Shutdown);
    }
    if let Some(process) = worker.process.as_mut() {
        let _ = process.terminate_and_wait();
    }
    worker.process = None;
}

fn restart_delay(
    workspace_uuid: WorkspaceUuid,
    failure_streak: u32,
    initial: Duration,
    maximum: Duration,
) -> Duration {
    let exponent = failure_streak.saturating_sub(1).min(31);
    let multiplier = 1_u32.checked_shl(exponent).unwrap_or(u32::MAX);
    let base = initial.saturating_mul(multiplier).min(maximum);
    let mut hash = 0xcbf2_9ce4_8422_2325_u64;
    for byte in workspace_uuid.as_uuid().as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    hash ^= u64::from(failure_streak);
    let basis_points = 8_000_u128 + u128::from(hash % 4_001);
    let nanos = base.as_nanos().saturating_mul(basis_points) / 10_000;
    Duration::from_nanos(u64::try_from(nanos).unwrap_or(u64::MAX)).min(maximum)
}

fn duration_milliseconds(duration: Duration) -> u64 {
    u64::try_from(duration.as_millis()).unwrap_or(u64::MAX)
}

#[cfg(unix)]
struct CommandRendererSpawner {
    executable: PathBuf,
}

#[cfg(unix)]
impl CommandRendererSpawner {
    fn new(executable: PathBuf) -> Self {
        Self { executable }
    }
}

#[cfg(unix)]
impl RendererSpawner for CommandRendererSpawner {
    type Process = CommandRendererProcess;

    fn spawn(&mut self, request: &SpawnRequest) -> io::Result<Self::Process> {
        use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
        use std::os::unix::process::CommandExt;

        let mut descriptors = [-1_i32; 2];
        // Darwin has no socketpair SOCK_CLOEXEC flag. Mark both endpoints
        // immediately, before constructing or spawning the child command.
        let result = unsafe {
            libc::socketpair(libc::AF_UNIX, libc::SOCK_STREAM, 0, descriptors.as_mut_ptr())
        };
        if result != 0 {
            return Err(io::Error::last_os_error());
        }
        let daemon_fd = unsafe { OwnedFd::from_raw_fd(descriptors[0]) };
        let worker_fd = unsafe { OwnedFd::from_raw_fd(descriptors[1]) };
        for descriptor in [&daemon_fd, &worker_fd] {
            if unsafe { libc::fcntl(descriptor.as_raw_fd(), libc::F_SETFD, libc::FD_CLOEXEC) } < 0 {
                return Err(io::Error::last_os_error());
            }
        }
        let daemon_raw = daemon_fd.as_raw_fd();
        let worker_raw = worker_fd.as_raw_fd();

        let mut command = Command::new(&self.executable);
        command.env_clear();
        command.envs(renderer_child_environment(std::env::vars_os()));
        command
            .arg("--workspace")
            .arg(request.workspace_uuid.to_string())
            .arg("--renderer-epoch")
            .arg(request.renderer_epoch.to_string())
            .env("CMUX_RENDERER_CONTROL_FD", CONTROL_FD.to_string())
            .env("CMUX_DAEMON_INSTANCE_ID", request.daemon_instance_id.to_string())
            .stdin(Stdio::null());
        unsafe {
            command.pre_exec(move || {
                if libc::dup2(worker_raw, CONTROL_FD) < 0 {
                    return Err(io::Error::last_os_error());
                }
                if libc::fcntl(CONTROL_FD, libc::F_SETFD, 0) < 0 {
                    return Err(io::Error::last_os_error());
                }
                if worker_raw != CONTROL_FD {
                    libc::close(worker_raw);
                }
                libc::close(daemon_raw);
                Ok(())
            });
        }
        let child = command.spawn()?;
        drop(worker_fd);
        let stream = std::os::unix::net::UnixStream::from(daemon_fd);
        stream.set_write_timeout(Some(Duration::from_millis(250)))?;
        Ok(CommandRendererProcess { child, stream })
    }
}

#[cfg(not(unix))]
struct CommandRendererSpawner {
    executable: PathBuf,
}

#[cfg(not(unix))]
impl CommandRendererSpawner {
    fn new(executable: PathBuf) -> Self {
        Self { executable }
    }
}

#[cfg(not(unix))]
impl RendererSpawner for CommandRendererSpawner {
    type Process = UnsupportedRendererProcess;

    fn spawn(&mut self, _request: &SpawnRequest) -> io::Result<Self::Process> {
        let _ = &self.executable;
        Err(io::Error::new(io::ErrorKind::Unsupported, "renderer workers require Unix sockets"))
    }
}

#[cfg(unix)]
struct CommandRendererProcess {
    child: Child,
    stream: std::os::unix::net::UnixStream,
}

#[cfg(unix)]
impl RendererProcess for CommandRendererProcess {
    fn pid(&self) -> u32 {
        self.child.id()
    }

    fn send(&mut self, bytes: &[u8]) -> io::Result<()> {
        self.stream.write_all(bytes)
    }

    fn receive(&mut self, destination: &mut Vec<u8>) -> io::Result<ReceiveResult> {
        use std::os::fd::AsRawFd;

        let mut buffer = [0_u8; 64 * 1024];
        loop {
            let count = unsafe {
                libc::recv(
                    self.stream.as_raw_fd(),
                    buffer.as_mut_ptr().cast(),
                    buffer.len(),
                    libc::MSG_DONTWAIT,
                )
            };
            if count == 0 {
                return Ok(ReceiveResult::EndOfFile);
            }
            if count > 0 {
                destination.extend_from_slice(&buffer[..count as usize]);
                continue;
            }
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::WouldBlock {
                return Ok(ReceiveResult::Open);
            }
            return Err(error);
        }
    }

    fn try_wait(&mut self) -> io::Result<Option<ExitStatus>> {
        self.child.try_wait()
    }

    fn terminate_and_wait(&mut self) -> io::Result<()> {
        if self.child.try_wait()?.is_none() {
            self.child.kill()?;
        }
        self.child.wait().map(|_| ())
    }
}

#[cfg(not(unix))]
struct UnsupportedRendererProcess;

#[cfg(not(unix))]
impl RendererProcess for UnsupportedRendererProcess {
    fn pid(&self) -> u32 {
        0
    }
    fn send(&mut self, _bytes: &[u8]) -> io::Result<()> {
        Err(io::Error::new(io::ErrorKind::Unsupported, "unsupported"))
    }
    fn receive(&mut self, _destination: &mut Vec<u8>) -> io::Result<ReceiveResult> {
        Err(io::Error::new(io::ErrorKind::Unsupported, "unsupported"))
    }
    fn try_wait(&mut self) -> io::Result<Option<ExitStatus>> {
        Err(io::Error::new(io::ErrorKind::Unsupported, "unsupported"))
    }
    fn terminate_and_wait(&mut self) -> io::Result<()> {
        Ok(())
    }
}

#[cfg(all(test, unix))]
mod tests {
    use std::collections::BTreeMap;
    use std::ffi::{OsStr, OsString};
    use std::str::FromStr;
    use std::sync::{Arc, Mutex};

    use std::os::unix::process::ExitStatusExt;

    use crate::renderer_control::{
        RendererColorSpace, RendererNeedsFullSceneReason, RendererPixelFormat,
        RendererPresentationAttachment, RendererPresentationRemoval, RendererSceneCapabilities,
        RendererSemanticScene, RendererWorkerReady,
    };

    use super::*;

    #[test]
    fn renderer_child_environment_cannot_inherit_authentication_secrets() {
        let environment = [
            ("HOME", "/Users/example"),
            ("TMPDIR", "/private/tmp/example"),
            ("LANG", "en_US.UTF-8"),
            ("LC_CTYPE", "UTF-8"),
            ("GHOSTTY_RESOURCES_DIR", "/Applications/cmux.app/Contents/Resources/ghostty"),
            ("OPENAI_API_KEY", "openai-secret"),
            ("ANTHROPIC_API_KEY", "anthropic-secret"),
            ("AWS_SECRET_ACCESS_KEY", "aws-secret"),
            ("GITHUB_TOKEN", "github-secret"),
            ("CMUX_SOCKET_PASSWORD", "cmux-secret"),
            ("CMUX_TUI_SOCKET", "/tmp/daemon-capability.sock"),
            ("PATH", "/secret/toolchain"),
            ("LC_ALL", ""),
        ]
        .into_iter()
        .map(|(name, value)| (OsString::from(name), OsString::from(value)));

        let child = renderer_child_environment(environment);

        assert_eq!(child.get(OsStr::new("HOME")), Some(&OsString::from("/Users/example")));
        assert_eq!(child.get(OsStr::new("LANG")), Some(&OsString::from("en_US.UTF-8")));
        assert_eq!(
            child.get(OsStr::new("GHOSTTY_RESOURCES_DIR")),
            Some(&OsString::from("/Applications/cmux.app/Contents/Resources/ghostty"))
        );
        assert!(!child.contains_key(OsStr::new("OPENAI_API_KEY")));
        assert!(!child.contains_key(OsStr::new("ANTHROPIC_API_KEY")));
        assert!(!child.contains_key(OsStr::new("AWS_SECRET_ACCESS_KEY")));
        assert!(!child.contains_key(OsStr::new("GITHUB_TOKEN")));
        assert!(!child.contains_key(OsStr::new("CMUX_SOCKET_PASSWORD")));
        assert!(!child.contains_key(OsStr::new("CMUX_TUI_SOCKET")));
        assert!(!child.contains_key(OsStr::new("PATH")));
        assert!(!child.contains_key(OsStr::new("LC_ALL")));
    }

    #[derive(Clone, Default)]
    struct ManualClock(Arc<Mutex<Duration>>);

    impl ManualClock {
        fn advance(&self, duration: Duration) {
            let mut now = self.0.lock().unwrap();
            *now = now.saturating_add(duration);
        }
    }

    impl SupervisorClock for ManualClock {
        fn now(&self) -> Duration {
            *self.0.lock().unwrap()
        }
    }

    #[derive(Debug, Default)]
    struct FakeProcessRecord {
        crashed: bool,
        terminated: bool,
        reaped: bool,
        sent_frames: Vec<Vec<u8>>,
    }

    #[derive(Debug, Default)]
    struct FakeSpawnerState {
        next_pid: u32,
        spawn_count: usize,
        processes: BTreeMap<u32, FakeProcessRecord>,
    }

    #[derive(Clone, Default)]
    struct FakeSpawner(Arc<Mutex<FakeSpawnerState>>);

    impl FakeSpawner {
        fn spawn_count(&self) -> usize {
            self.0.lock().unwrap().spawn_count
        }

        fn crash(&self, pid: u32) {
            self.0.lock().unwrap().processes.get_mut(&pid).unwrap().crashed = true;
        }

        fn record(&self, pid: u32) -> (bool, bool, usize) {
            let state = self.0.lock().unwrap();
            let record = state.processes.get(&pid).unwrap();
            (record.terminated, record.reaped, record.sent_frames.len())
        }

        fn all_reaped(&self) -> bool {
            self.0.lock().unwrap().processes.values().all(|record| record.reaped)
        }

        fn messages(&self, pid: u32) -> Vec<RendererControlMessage> {
            self.0.lock().unwrap().processes[&pid]
                .sent_frames
                .iter()
                .map(|frame| RendererControlWire::decode(frame).unwrap().message)
                .collect()
        }
    }

    struct FakeProcess {
        pid: u32,
        state: Arc<Mutex<FakeSpawnerState>>,
    }

    impl RendererProcess for FakeProcess {
        fn pid(&self) -> u32 {
            self.pid
        }

        fn send(&mut self, bytes: &[u8]) -> io::Result<()> {
            self.state
                .lock()
                .unwrap()
                .processes
                .get_mut(&self.pid)
                .unwrap()
                .sent_frames
                .push(bytes.to_vec());
            Ok(())
        }

        fn receive(&mut self, _destination: &mut Vec<u8>) -> io::Result<ReceiveResult> {
            Ok(ReceiveResult::Open)
        }

        fn try_wait(&mut self) -> io::Result<Option<ExitStatus>> {
            let mut state = self.state.lock().unwrap();
            let record = state.processes.get_mut(&self.pid).unwrap();
            if record.crashed {
                record.reaped = true;
                return Ok(Some(ExitStatus::from_raw(1 << 8)));
            }
            Ok(None)
        }

        fn terminate_and_wait(&mut self) -> io::Result<()> {
            let mut state = self.state.lock().unwrap();
            let record = state.processes.get_mut(&self.pid).unwrap();
            record.terminated = true;
            record.reaped = true;
            Ok(())
        }
    }

    impl RendererSpawner for FakeSpawner {
        type Process = FakeProcess;

        fn spawn(&mut self, _request: &SpawnRequest) -> io::Result<Self::Process> {
            let mut state = self.0.lock().unwrap();
            state.next_pid = state.next_pid.max(4_000).saturating_add(1);
            let pid = state.next_pid;
            state.spawn_count += 1;
            state.processes.insert(pid, FakeProcessRecord::default());
            Ok(FakeProcess { pid, state: self.0.clone() })
        }
    }

    fn workspace(value: &str) -> WorkspaceUuid {
        WorkspaceUuid::from_str(value).unwrap()
    }

    fn presentation(value: &str) -> PresentationId {
        PresentationId::from_str(value).unwrap()
    }

    fn daemon() -> DaemonInstanceId {
        DaemonInstanceId::from_str("10000000-0000-4000-8000-000000000001").unwrap()
    }

    fn new_core(
        spawner: FakeSpawner,
        clock: ManualClock,
    ) -> SupervisorCore<FakeSpawner, ManualClock> {
        SupervisorCore::new(
            spawner,
            clock,
            daemon(),
            Duration::from_millis(100),
            Duration::from_secs(5),
        )
    }

    fn ready_envelope(pid: u32) -> RendererControlEnvelope {
        RendererControlEnvelope::new(
            RendererControlDirection::WorkerToDaemon,
            1,
            RendererControlMessage::Ready(RendererWorkerReady {
                process_id: pid,
                effective_user_id: unsafe { libc::geteuid() },
                scene_capabilities: RendererSceneCapabilities::FULL_SCENE,
            }),
        )
        .unwrap()
    }

    fn terminal() -> uuid::Uuid {
        uuid::Uuid::parse_str("40000000-0000-4000-8000-000000000001").unwrap()
    }

    fn attachment(
        presentation_id: PresentationId,
        generation: u64,
    ) -> RendererPresentationAttachment {
        RendererPresentationAttachment {
            terminal_id: terminal(),
            terminal_epoch: 9,
            presentation_id: presentation_id.as_uuid(),
            presentation_generation: generation,
            width: 1_280,
            height: 800,
            backing_scale_factor: 2.0,
            pixel_format: RendererPixelFormat::Bgra8Unorm,
            color_space: RendererColorSpace::DisplayP3,
            frame_endpoint_service: "dev.cmux.test.renderer".to_owned(),
            frame_endpoint_capability: vec![0x5a; 32],
            resolved_config_revision: 1,
            resolved_config: vec![1, 2, 3],
        }
    }

    fn scene(
        presentation_id: PresentationId,
        generation: u64,
        canonical_sequence: u64,
        presentation_sequence: u64,
        bytes: &[u8],
    ) -> RendererSemanticScene {
        RendererSemanticScene {
            terminal_id: terminal(),
            terminal_epoch: 9,
            presentation_id: presentation_id.as_uuid(),
            presentation_generation: generation,
            canonical_sequence,
            presentation_sequence,
            bytes: bytes.to_vec(),
        }
    }

    #[test]
    fn one_worker_follows_workspace_visibility_without_duplicates() {
        let spawner = FakeSpawner::default();
        let mut core = new_core(spawner.clone(), ManualClock::default());
        let workspace = workspace("20000000-0000-4000-8000-000000000001");
        let first = presentation("30000000-0000-4000-8000-000000000001");
        let second = presentation("30000000-0000-4000-8000-000000000002");

        core.set_presentation_workspace(first, Some(workspace));
        let first_status = core.statuses().pop().unwrap();
        let pid = first_status.pid.unwrap();
        assert_eq!(spawner.spawn_count(), 1);
        assert_eq!(first_status.visible_presentation_count, 1);

        core.set_presentation_workspace(second, Some(workspace));
        assert_eq!(spawner.spawn_count(), 1);
        assert_eq!(core.statuses()[0].visible_presentation_count, 2);

        core.remove_presentation(first);
        assert_eq!(core.statuses()[0].pid, Some(pid));
        core.remove_presentation(second);
        assert!(core.statuses().is_empty());
        assert_eq!(spawner.record(pid), (true, true, 2));
    }

    #[test]
    fn crash_restarts_after_bounded_clock_driven_backoff() {
        let spawner = FakeSpawner::default();
        let clock = ManualClock::default();
        let mut core = new_core(spawner.clone(), clock.clone());
        let workspace = workspace("20000000-0000-4000-8000-000000000002");
        core.set_presentation_workspace(
            presentation("30000000-0000-4000-8000-000000000003"),
            Some(workspace),
        );
        let first = core.statuses()[0].clone();
        spawner.crash(first.pid.unwrap());
        core.tick();

        let backoff = core.statuses()[0].clone();
        assert_eq!(backoff.state, RendererWorkerState::Backoff);
        assert_eq!(backoff.pid, None);
        assert_eq!(backoff.restart_count, 1);
        assert!(backoff.retry_after_milliseconds.is_some_and(|delay| delay <= 120));
        assert_eq!(spawner.spawn_count(), 1);

        clock.advance(Duration::from_millis(121));
        core.tick();
        let restarted = core.statuses()[0].clone();
        assert_eq!(restarted.state, RendererWorkerState::Starting);
        assert_ne!(restarted.renderer_epoch, first.renderer_epoch);
        assert_ne!(restarted.pid, first.pid);
        assert_eq!(spawner.spawn_count(), 2);
    }

    #[test]
    fn scene_lifecycle_sends_full_delta_remove_and_rehydrates_only_the_new_epoch() {
        let spawner = FakeSpawner::default();
        let clock = ManualClock::default();
        let mut core = new_core(spawner.clone(), clock.clone());
        let workspace = workspace("20000000-0000-4000-8000-000000000020");
        let presentation = presentation("30000000-0000-4000-8000-000000000020");
        core.set_presentation_workspace(presentation, Some(workspace));
        let first = core.statuses()[0].clone();
        let first_pid = first.pid.unwrap();
        core.accept_worker_envelope(
            workspace,
            first.renderer_epoch,
            first_pid,
            ready_envelope(first_pid),
        )
        .unwrap();
        assert!(matches!(
            core.take_events().as_slice(),
            [RendererSupervisorEvent::WorkerReady { renderer_epoch, .. }]
                if *renderer_epoch == first.renderer_epoch
        ));

        core.send_if_epoch(
            workspace,
            first.renderer_epoch,
            vec![
                RendererControlMessage::UpsertPresentation(attachment(presentation, 1)),
                RendererControlMessage::SemanticScene(scene(presentation, 1, 1, 1, b"full")),
            ],
        );
        core.send_if_epoch(
            workspace,
            first.renderer_epoch,
            vec![RendererControlMessage::SemanticScene(scene(presentation, 1, 2, 2, b"delta"))],
        );
        core.send_if_epoch(
            workspace,
            first.renderer_epoch,
            vec![RendererControlMessage::RemovePresentation(RendererPresentationRemoval {
                terminal_id: terminal(),
                terminal_epoch: 9,
                presentation_id: presentation.as_uuid(),
                presentation_generation: 1,
            })],
        );
        let first_messages = spawner.messages(first_pid);
        assert!(matches!(first_messages[0], RendererControlMessage::Bootstrap(_)));
        assert!(matches!(first_messages[1], RendererControlMessage::UpsertPresentation(_)));
        assert!(matches!(
            &first_messages[2],
            RendererControlMessage::SemanticScene(value) if value.bytes == b"full"
        ));
        assert!(matches!(
            &first_messages[3],
            RendererControlMessage::SemanticScene(value) if value.bytes == b"delta"
        ));
        assert!(matches!(first_messages[4], RendererControlMessage::RemovePresentation(_)));

        spawner.crash(first_pid);
        core.tick();
        assert!(matches!(
            core.take_events().as_slice(),
            [RendererSupervisorEvent::WorkerUnavailable { renderer_epoch, .. }]
                if *renderer_epoch == first.renderer_epoch
        ));
        clock.advance(Duration::from_millis(121));
        core.tick();
        let second = core.statuses()[0].clone();
        let second_pid = second.pid.unwrap();
        core.accept_worker_envelope(
            workspace,
            second.renderer_epoch,
            second_pid,
            ready_envelope(second_pid),
        )
        .unwrap();
        core.take_events();
        core.send_if_epoch(
            workspace,
            first.renderer_epoch,
            vec![RendererControlMessage::UpsertPresentation(attachment(presentation, 1))],
        );
        core.send_if_epoch(
            workspace,
            second.renderer_epoch,
            vec![
                RendererControlMessage::UpsertPresentation(attachment(presentation, 1)),
                RendererControlMessage::SemanticScene(scene(presentation, 1, 2, 2, b"rehydrate")),
            ],
        );
        let second_messages = spawner.messages(second_pid);
        assert_eq!(second_messages.len(), 3);
        assert!(matches!(second_messages[0], RendererControlMessage::Bootstrap(_)));
        assert!(matches!(second_messages[1], RendererControlMessage::UpsertPresentation(_)));
        assert!(matches!(
            &second_messages[2],
            RendererControlMessage::SemanticScene(value) if value.bytes == b"rehydrate"
        ));
    }

    #[test]
    fn authenticated_needs_full_and_disconnect_emit_exact_lifecycle_events() {
        let spawner = FakeSpawner::default();
        let mut core = new_core(spawner.clone(), ManualClock::default());
        let workspace = workspace("20000000-0000-4000-8000-000000000021");
        let presentation = presentation("30000000-0000-4000-8000-000000000021");
        core.set_presentation_workspace(presentation, Some(workspace));
        let status = core.statuses()[0].clone();
        let pid = status.pid.unwrap();
        core.accept_worker_envelope(workspace, status.renderer_epoch, pid, ready_envelope(pid))
            .unwrap();
        core.take_events();
        core.send_if_epoch(
            workspace,
            status.renderer_epoch,
            vec![
                RendererControlMessage::UpsertPresentation(attachment(presentation, 1)),
                RendererControlMessage::SemanticScene(scene(presentation, 1, 7, 3, b"full")),
            ],
        );
        let request = RendererNeedsFullScene {
            terminal_id: terminal(),
            terminal_epoch: 9,
            presentation_id: presentation.as_uuid(),
            presentation_generation: 1,
            last_canonical_sequence: 7,
            last_presentation_sequence: 3,
            reason: RendererNeedsFullSceneReason::SequenceGap,
        };
        let envelope = RendererControlEnvelope::new(
            RendererControlDirection::WorkerToDaemon,
            2,
            RendererControlMessage::NeedsFullScene(request.clone()),
        )
        .unwrap();
        core.accept_worker_envelope(workspace, status.renderer_epoch, pid, envelope).unwrap();
        assert_eq!(
            core.take_events(),
            vec![RendererSupervisorEvent::NeedsFullScene {
                workspace_uuid: workspace,
                renderer_epoch: status.renderer_epoch,
                request,
            }]
        );

        let metrics = RendererPresentationReady {
            terminal_id: terminal(),
            terminal_epoch: 9,
            presentation_id: presentation.as_uuid(),
            presentation_generation: 1,
            canonical_sequence: 7,
            presentation_sequence: 3,
            columns: 120,
            rows: 40,
            cell_width: 18,
            cell_height: 36,
            padding_top: 8,
            padding_right: 10,
            padding_bottom: 12,
            padding_left: 14,
        };
        let envelope = RendererControlEnvelope::new(
            RendererControlDirection::WorkerToDaemon,
            3,
            RendererControlMessage::PresentationReady(metrics.clone()),
        )
        .unwrap();
        core.accept_worker_envelope(workspace, status.renderer_epoch, pid, envelope).unwrap();
        assert_eq!(
            core.take_events(),
            vec![RendererSupervisorEvent::PresentationReady {
                workspace_uuid: workspace,
                renderer_epoch: status.renderer_epoch,
                process_id: pid,
                metrics,
            }]
        );

        core.remove_presentation(presentation);
        assert!(core.statuses().is_empty());
        assert!(spawner.record(pid).0);
        assert!(spawner.record(pid).1);
        assert!(matches!(
            core.take_events().as_slice(),
            [RendererSupervisorEvent::WorkerUnavailable { renderer_epoch, process_id, .. }]
                if *renderer_epoch == status.renderer_epoch && *process_id == Some(pid)
        ));
    }

    #[test]
    fn stale_epoch_and_process_replies_are_rejected() {
        let spawner = FakeSpawner::default();
        let clock = ManualClock::default();
        let mut core = new_core(spawner.clone(), clock.clone());
        let workspace = workspace("20000000-0000-4000-8000-000000000003");
        core.set_presentation_workspace(
            presentation("30000000-0000-4000-8000-000000000004"),
            Some(workspace),
        );
        let old = core.statuses()[0].clone();
        spawner.crash(old.pid.unwrap());
        core.tick();
        clock.advance(Duration::from_millis(121));
        core.tick();
        let current = core.statuses()[0].clone();

        let error = core
            .accept_worker_envelope(
                workspace,
                old.renderer_epoch,
                old.pid.unwrap(),
                ready_envelope(old.pid.unwrap()),
            )
            .unwrap_err();
        assert!(matches!(error, RendererSupervisorError::StaleWorkerReply { .. }));

        let wrong_user = RendererControlEnvelope::new(
            RendererControlDirection::WorkerToDaemon,
            1,
            RendererControlMessage::Ready(RendererWorkerReady {
                process_id: current.pid.unwrap(),
                effective_user_id: unsafe { libc::geteuid() }.wrapping_add(1),
                scene_capabilities: RendererSceneCapabilities::FULL_SCENE,
            }),
        )
        .unwrap();
        let error = core
            .accept_worker_envelope(
                workspace,
                current.renderer_epoch,
                current.pid.unwrap(),
                wrong_user,
            )
            .unwrap_err();
        assert!(matches!(error, RendererSupervisorError::EffectiveUserIdentityMismatch { .. }));

        core.accept_worker_envelope(
            workspace,
            current.renderer_epoch,
            current.pid.unwrap(),
            ready_envelope(current.pid.unwrap()),
        )
        .unwrap();
        assert_eq!(core.statuses()[0].state, RendererWorkerState::Ready);
    }

    #[test]
    fn shutdown_terminates_and_reaps_every_child() {
        let spawner = FakeSpawner::default();
        let mut core = new_core(spawner.clone(), ManualClock::default());
        core.set_presentation_workspace(
            presentation("30000000-0000-4000-8000-000000000005"),
            Some(workspace("20000000-0000-4000-8000-000000000004")),
        );
        core.set_presentation_workspace(
            presentation("30000000-0000-4000-8000-000000000006"),
            Some(workspace("20000000-0000-4000-8000-000000000005")),
        );
        assert_eq!(spawner.spawn_count(), 2);
        core.shutdown();
        assert!(core.statuses().is_empty());
        assert!(spawner.all_reaped());
    }

    #[test]
    fn canonical_workspace_deletion_stops_a_stale_presentations_worker() {
        let spawner = FakeSpawner::default();
        let mut core = new_core(spawner.clone(), ManualClock::default());
        let retained = workspace("20000000-0000-4000-8000-000000000006");
        let deleted = workspace("20000000-0000-4000-8000-000000000007");
        core.set_presentation_workspace(
            presentation("30000000-0000-4000-8000-000000000007"),
            Some(retained),
        );
        core.set_presentation_workspace(
            presentation("30000000-0000-4000-8000-000000000008"),
            Some(deleted),
        );
        let deleted_pid = core
            .statuses()
            .into_iter()
            .find(|status| status.workspace_uuid == deleted)
            .unwrap()
            .pid
            .unwrap();

        core.retain_workspaces(&BTreeSet::from([retained]));

        assert_eq!(core.statuses().len(), 1);
        assert_eq!(core.statuses()[0].workspace_uuid, retained);
        assert!(spawner.record(deleted_pid).0);
        assert!(spawner.record(deleted_pid).1);
    }

    #[test]
    fn helper_path_defaults_to_the_bundled_bin_directory() {
        let executable = Path::new("/Applications/cmux.app/Contents/Resources/bin/cmux-tui");
        assert_eq!(
            resolve_renderer_executable(executable, None).unwrap(),
            Path::new("/Applications/cmux.app/Contents/Resources/bin/cmux-terminal-renderer")
        );
        assert_eq!(
            resolve_renderer_executable(executable, Some(Path::new("/tmp/fake-renderer"))).unwrap(),
            Path::new("/tmp/fake-renderer")
        );
    }
}
