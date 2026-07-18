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
use std::mem::size_of;
use std::path::{Path, PathBuf};
use std::process::ExitStatus;
#[cfg(unix)]
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU8, AtomicUsize, Ordering};
use std::sync::mpsc::{RecvTimeoutError, SyncSender, TrySendError, sync_channel};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use crate::renderer_control::{
    MAXIMUM_RENDERER_CONTROL_FRAME_LENGTH, RendererBootstrap, RendererControlDirection,
    RendererControlEncoder, RendererControlEnvelope, RendererControlError,
    RendererControlIncrementalDecoder, RendererControlMessage, RendererControlSessionStateMachine,
    RendererControlWire, RendererNeedsFullScene, RendererPresentationReady,
    RendererPresentationRemoved, RendererSceneCapabilities, RendererWorkerReady,
};
use crate::{DaemonInstanceId, PresentationId, WorkspaceUuid};
use serde::Serialize;

const DEFAULT_HELPER_NAME: &str = "cmux-terminal-renderer";
const CONTROL_FD: i32 = 198;
const CHILD_POLL_INTERVAL: Duration = Duration::from_millis(100);
#[cfg(target_os = "macos")]
const REACTOR_REBUILD_RETRY: Duration = Duration::from_millis(250);
const WORKER_READY_TIMEOUT: Duration = Duration::from_secs(15);
const WORKER_WRITE_STALL_TIMEOUT: Duration = Duration::from_millis(250);
const WORKER_RETIREMENT_DEADLINE: Duration = Duration::from_millis(250);
const COORDINATOR_RETIREMENT_DEADLINE: Duration = Duration::from_millis(250);
const MAXIMUM_REAPER_QUEUE_LENGTH: usize = MAXIMUM_RENDERER_WORKERS + 1;
const PUBLICATION_PENDING: u8 = 0;
const PUBLICATION_CANCELED: u8 = 1;
const PUBLICATION_STARTED: u8 = 2;
const PUBLICATION_FINISHED: u8 = 3;
const MAXIMUM_COMMAND_QUEUE_LENGTH: usize = 1_024;
const MAXIMUM_COMMAND_QUEUE_BYTES: usize = 72 * 1_024 * 1_024;
const COMMAND_QUEUE_RECOVERY_RESERVE_BYTES: usize = 1_024;
const MAXIMUM_COMMAND_QUEUE_ALLOCATED_SLOTS: usize = MAXIMUM_COMMAND_QUEUE_LENGTH * 2;
const MAXIMUM_WORKER_OUTBOX_LENGTH: usize = 128;
const MAXIMUM_WORKER_OUTBOX_BYTES: usize = 72 * 1_024 * 1_024;
const MAXIMUM_WORKER_OUTBOX_ALLOCATED_SLOTS: usize = MAXIMUM_WORKER_OUTBOX_LENGTH * 2;
const MAXIMUM_WORKER_RECEIVE_BATCH_BYTES: usize = 1_024 * 1_024;
const MAXIMUM_WORKER_WRITE_BATCH_BYTES: usize = 1_024 * 1_024;
const MAXIMUM_WORKER_WRITE_SYSCALLS_PER_TURN: usize = 16;
const MAXIMUM_RENDERER_WORKERS: usize = 1_024;
const MAXIMUM_DESIRED_PRESENTATIONS: usize = 1_024;
const MAXIMUM_SUPERVISOR_QUEUED_MESSAGES: usize = 4_096;
const MAXIMUM_SUPERVISOR_QUEUED_BYTES: usize = 256 * 1_024 * 1_024;
const SUPERVISOR_RECOVERY_RESERVE_MESSAGES: usize = 1;
const SUPERVISOR_RECOVERY_RESERVE_BYTES: usize = 1_024;
const COORDINATOR_QUEUE_FIXED_STORAGE_BYTES: usize = size_of::<CoordinatorState>()
    + MAXIMUM_COMMAND_QUEUE_ALLOCATED_SLOTS * size_of::<AccountedCoordinatorCommand>();
const WORKER_OUTBOX_FIXED_STORAGE_BYTES: usize = size_of::<BoundedWorkerOutbox>()
    + MAXIMUM_WORKER_OUTBOX_ALLOCATED_SLOTS * size_of::<AccountedRendererMessage>();
const MAXIMUM_SUPERVISOR_FIXED_QUEUE_STORAGE_BYTES: usize = COORDINATOR_QUEUE_FIXED_STORAGE_BYTES
    + MAXIMUM_RENDERER_WORKERS * WORKER_OUTBOX_FIXED_STORAGE_BYTES
    // Encoding and final-byte session validation transiently hold both the
    // logical payload and its copied wire frame. The coordinator is the only
    // codec lane, so one global scratch allowance bounds that amplification.
    + MAXIMUM_RENDERER_CONTROL_FRAME_LENGTH;
const _: () = assert!(
    MAXIMUM_SUPERVISOR_FIXED_QUEUE_STORAGE_BYTES + SUPERVISOR_RECOVERY_RESERVE_BYTES
        < MAXIMUM_SUPERVISOR_QUEUED_BYTES
);
const _: () = assert!(
    COORDINATOR_QUEUE_FIXED_STORAGE_BYTES
        + COMMAND_QUEUE_RECOVERY_RESERVE_BYTES
        + MAXIMUM_RENDERER_CONTROL_FRAME_LENGTH
        <= MAXIMUM_COMMAND_QUEUE_BYTES
);
const _: () = assert!(
    WORKER_OUTBOX_FIXED_STORAGE_BYTES + MAXIMUM_RENDERER_CONTROL_FRAME_LENGTH
        <= MAXIMUM_WORKER_OUTBOX_BYTES
);

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

/// Public-kernel process lifetime token captured from PROC_PIDTBSDINFO.
/// PID plus this start timestamp identifies one process instance across PID
/// reuse without relying on a daemon-local generation alone.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize)]
pub struct RendererProcessInstanceToken {
    pub start_time_seconds: u64,
    pub start_time_microseconds: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct RendererWorkerStatus {
    pub workspace_uuid: WorkspaceUuid,
    pub renderer_epoch: u64,
    pub pid: Option<u32>,
    pub process_start_time_seconds: Option<u64>,
    pub process_start_time_microseconds: Option<u64>,
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
        process_instance_token: RendererProcessInstanceToken,
        effective_user_id: u32,
        scene_capabilities: RendererSceneCapabilities,
        /// The status snapshot produced by the coordinator at the same
        /// linearization point as this event. Consumers must not issue a
        /// synchronous status query from the event handler because handlers
        /// run on the coordinator thread.
        status: RendererWorkerStatus,
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
        process_instance_token: Option<RendererProcessInstanceToken>,
        /// The replacement/backoff status after the failed lifetime was
        /// retired, or `None` when the workspace no longer has demand.
        status: Option<RendererWorkerStatus>,
        /// True only after waitpid (or an equivalent kernel proof) confirms
        /// the exact worker lifetime can no longer publish.
        quiesced: bool,
        reason: String,
    },
    PresentationReady {
        workspace_uuid: WorkspaceUuid,
        renderer_epoch: u64,
        process_id: u32,
        process_instance_token: RendererProcessInstanceToken,
        /// Captured from the authenticated Ready handshake for this exact
        /// worker lifetime, so the consumer never has to re-query status.
        effective_user_id: u32,
        metrics: RendererPresentationReady,
    },
    PresentationRemoved {
        workspace_uuid: WorkspaceUuid,
        renderer_epoch: u64,
        process_id: u32,
        removal: RendererPresentationRemoved,
    },
}

type RendererSupervisorEventHandler = Arc<dyn Fn(RendererSupervisorEvent) + Send + Sync + 'static>;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RendererSupervisorError {
    Stopped,
    QueueFull,
    UnknownWorkspace(WorkspaceUuid),
    WorkerNotReady(WorkspaceUuid),
    PublicationUncertain { workspace_uuid: WorkspaceUuid, renderer_epoch: u64, diagnostic: String },
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
        let queue_budget = Arc::new(SupervisorQueueBudget::default());
        #[cfg(target_os = "macos")]
        let reactor = KqueueRendererEventReactor::new()?;
        #[cfg(target_os = "macos")]
        let shared =
            Arc::new(Shared::new_with_event_wake(queue_budget.clone(), Some(reactor.wake())));
        #[cfg(not(target_os = "macos"))]
        let shared = Arc::new(Shared::new(queue_budget.clone()));
        let coordinator_shared = shared.clone();
        let reaper_shared = shared.clone();
        let reaper_wake: RendererReaperWake = Arc::new(move || reaper_shared.notify_one());
        let mut core = SupervisorCore::new(
            spawner,
            clock,
            config.daemon_instance_id,
            config.initial_restart_delay,
            config.maximum_restart_delay,
            queue_budget,
            reaper_wake,
        )?;
        let coordinator = thread::Builder::new()
            .name("cmux-renderer-supervisor".to_owned())
            .spawn(move || {
                #[cfg(target_os = "macos")]
                coordinator_loop_event_driven(&coordinator_shared, &mut core, reactor);
                #[cfg(not(target_os = "macos"))]
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
        let state = self.shared.state.lock().unwrap();
        if state.stopping {
            return Err(RendererSupervisorError::Stopped);
        }
        let mut desired = self.shared.desired_presentations.lock().unwrap();
        if workspace_uuid.is_some()
            && !desired.values.contains_key(&presentation_id)
            && desired.values.len() >= MAXIMUM_DESIRED_PRESENTATIONS
        {
            return Err(RendererSupervisorError::QueueFull);
        }
        let changed = desired.set(presentation_id, workspace_uuid);
        if !changed {
            return Ok(());
        }
        drop(desired);
        drop(state);
        self.shared.notify_one();
        Ok(())
    }

    pub fn remove_presentation(
        &self,
        presentation_id: PresentationId,
    ) -> Result<(), RendererSupervisorError> {
        self.set_presentation_workspace(presentation_id, None)
    }

    /// Drop visibility for workspaces removed from canonical mux topology.
    pub fn retain_workspaces(
        &self,
        workspace_uuids: BTreeSet<WorkspaceUuid>,
    ) -> Result<(), RendererSupervisorError> {
        let state = self.shared.state.lock().unwrap();
        if state.stopping {
            return Err(RendererSupervisorError::Stopped);
        }
        let mut desired = self.shared.desired_presentations.lock().unwrap();
        let removed = desired
            .values
            .iter()
            .filter_map(|(presentation_id, workspace_uuid)| {
                (!workspace_uuids.contains(workspace_uuid)).then_some(*presentation_id)
            })
            .collect::<Vec<_>>();
        if removed.is_empty() {
            return Ok(());
        }
        for presentation_id in removed {
            let removed = desired.set(presentation_id, None);
            debug_assert!(removed);
        }
        drop(desired);
        drop(state);
        self.shared.notify_one();
        Ok(())
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
        message.encoded_frame_length()?;
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
        for message in &messages {
            message.encoded_frame_length()?;
        }
        self.enqueue(CoordinatorCommand::SendIfEpoch { workspace_uuid, renderer_epoch, messages })
    }

    /// Publish one atomic activation batch through the coordinator and wait
    /// until it has been written to the exact authenticated worker lifetime.
    /// Unlike `send_if_epoch`, this command is never silently discarded and
    /// never converted into overflow recovery. The returned snapshot is from
    /// the same coordinator turn as the write.
    pub fn publish_if_epoch(
        &self,
        workspace_uuid: WorkspaceUuid,
        renderer_epoch: u64,
        messages: Vec<RendererControlMessage>,
    ) -> Result<RendererWorkerStatus, RendererSupervisorError> {
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
        for message in &messages {
            message.encoded_frame_length()?;
        }
        let publication = Arc::new(RendererPublicationLinearization::default());
        let (reply, response) = sync_channel(1);
        self.enqueue(CoordinatorCommand::PublishIfEpoch {
            workspace_uuid,
            renderer_epoch,
            messages,
            publication: publication.clone(),
            reply,
        })?;
        match response.recv_timeout(Duration::from_secs(1)) {
            Ok(result) => result,
            Err(RecvTimeoutError::Timeout) if publication.cancel_if_pending() => {
                Err(RendererSupervisorError::Io(
                    "renderer activation publication timed out before it started".to_owned(),
                ))
            }
            // Once the coordinator wins the linearization CAS, a timeout
            // cannot be returned safely: bytes may already be visible to the
            // worker. Wait for the exact publication result instead.
            Err(RecvTimeoutError::Timeout) => {
                response.recv().unwrap_or(Err(RendererSupervisorError::Stopped))
            }
            Err(RecvTimeoutError::Disconnected) => Err(RendererSupervisorError::Stopped),
        }
    }

    /// Retire one exact worker lifetime and return true only after the child
    /// has been synchronously reaped. A stale epoch never retires a newer
    /// worker; it waits only for an already-owned reap of the requested epoch.
    pub fn retire_if_epoch(
        &self,
        workspace_uuid: WorkspaceUuid,
        renderer_epoch: u64,
    ) -> Result<bool, RendererSupervisorError> {
        let (reply, response) = sync_channel(1);
        self.enqueue(CoordinatorCommand::RetireIfEpoch { workspace_uuid, renderer_epoch, reply })?;
        match response.recv_timeout(Duration::from_secs(1)) {
            Ok(result) => result,
            Err(RecvTimeoutError::Timeout) => {
                Err(RendererSupervisorError::Io("renderer retirement proof timed out".to_owned()))
            }
            Err(RecvTimeoutError::Disconnected) => Err(RendererSupervisorError::Stopped),
        }
    }

    pub(crate) fn set_event_handler(&self, handler: RendererSupervisorEventHandler) {
        *self.shared.event_handler.lock().unwrap() = Some(handler);
    }

    /// Machine-readable lifecycle proof for the debug protocol.
    pub fn statuses(&self) -> Vec<RendererWorkerStatus> {
        let now = Instant::now();
        self.shared
            .statuses
            .lock()
            .unwrap()
            .values()
            .map(|published| published.current(now))
            .collect()
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
        state.enqueue(command)?;
        self.shared.notify_one();
        Ok(())
    }
}

impl Drop for RendererSupervisor {
    fn drop(&mut self) {
        {
            let mut state = self.shared.state.lock().unwrap();
            state.stopping = true;
            self.shared.notify_all();
        }
        if let Some(coordinator) = self.coordinator.take() {
            let _ = coordinator.join();
        }
    }
}

#[cfg(target_os = "macos")]
struct KqueueHandle(libc::c_int);

#[cfg(target_os = "macos")]
impl Drop for KqueueHandle {
    fn drop(&mut self) {
        unsafe {
            libc::close(self.0);
        }
    }
}

#[cfg(target_os = "macos")]
#[derive(Clone)]
struct KqueueCoordinatorWake {
    handle: Arc<KqueueHandle>,
}

#[cfg(target_os = "macos")]
impl KqueueCoordinatorWake {
    const IDENTIFIER: libc::uintptr_t = 1;

    fn trigger(&self) -> io::Result<()> {
        let change = libc::kevent {
            ident: Self::IDENTIFIER,
            filter: libc::EVFILT_USER,
            flags: 0,
            fflags: libc::NOTE_TRIGGER,
            data: 0,
            udata: std::ptr::null_mut(),
        };
        loop {
            if unsafe {
                libc::kevent(self.handle.0, &change, 1, std::ptr::null_mut(), 0, std::ptr::null())
            } >= 0
            {
                return Ok(());
            }
            let error = io::Error::last_os_error();
            if error.kind() != io::ErrorKind::Interrupted {
                return Err(error);
            }
        }
    }
}

/// One kernel wait set for command wakeups, control readability, and exact
/// child exit. Its maps change only when a worker lifetime starts or ends, so
/// an idle supervisor performs no work proportional to workspace count.
#[cfg(target_os = "macos")]
struct KqueueRendererEventReactor {
    handle: Arc<KqueueHandle>,
    next_token: usize,
    by_identity: BTreeMap<RendererWorkerIdentity, (usize, RendererProcessEventSource)>,
    by_token: BTreeMap<usize, RendererWorkerIdentity>,
}

#[cfg(target_os = "macos")]
impl KqueueRendererEventReactor {
    fn new() -> io::Result<Self> {
        let queue = unsafe { libc::kqueue() };
        if queue < 0 {
            return Err(io::Error::last_os_error());
        }
        let handle = Arc::new(KqueueHandle(queue));
        let user = libc::kevent {
            ident: KqueueCoordinatorWake::IDENTIFIER,
            filter: libc::EVFILT_USER,
            flags: libc::EV_ADD | libc::EV_CLEAR,
            fflags: 0,
            data: 0,
            udata: std::ptr::null_mut(),
        };
        if unsafe { libc::kevent(handle.0, &user, 1, std::ptr::null_mut(), 0, std::ptr::null()) }
            < 0
        {
            return Err(io::Error::last_os_error());
        }
        Ok(Self { handle, next_token: 2, by_identity: BTreeMap::new(), by_token: BTreeMap::new() })
    }

    fn wake(&self) -> KqueueCoordinatorWake {
        KqueueCoordinatorWake { handle: self.handle.clone() }
    }

    fn apply(&mut self, change: RendererProcessWatchChange) -> io::Result<()> {
        match change {
            RendererProcessWatchChange::Register { identity, source, write_enabled } => {
                self.register(identity, source, write_enabled)
            }
            RendererProcessWatchChange::SetWriteInterest { identity, source, enabled } => {
                self.set_write_interest(identity, source, enabled)
            }
            RendererProcessWatchChange::Unregister { identity, source } => {
                self.unregister(identity, source);
                Ok(())
            }
        }
    }

    fn register(
        &mut self,
        identity: RendererWorkerIdentity,
        source: RendererProcessEventSource,
        write_enabled: bool,
    ) -> io::Result<()> {
        if self.by_identity.contains_key(&identity) {
            return Ok(());
        }
        let token = self.next_token;
        self.next_token = self
            .next_token
            .checked_add(1)
            .ok_or_else(|| io::Error::other("renderer event token exhausted"))?;
        let user_data = token as *mut libc::c_void;
        let changes = [
            libc::kevent {
                ident: source.control_fd as libc::uintptr_t,
                filter: libc::EVFILT_READ,
                flags: libc::EV_ADD,
                fflags: 0,
                data: 0,
                udata: user_data,
            },
            libc::kevent {
                ident: source.control_fd as libc::uintptr_t,
                filter: libc::EVFILT_WRITE,
                flags: libc::EV_ADD
                    | if write_enabled { libc::EV_ENABLE } else { libc::EV_DISABLE },
                fflags: 0,
                data: 0,
                udata: user_data,
            },
            libc::kevent {
                ident: source.process_id as libc::uintptr_t,
                filter: libc::EVFILT_PROC,
                flags: libc::EV_ADD | libc::EV_ONESHOT,
                fflags: libc::NOTE_EXIT,
                data: 0,
                udata: user_data,
            },
        ];
        if unsafe {
            libc::kevent(
                self.handle.0,
                changes.as_ptr(),
                changes.len() as libc::c_int,
                std::ptr::null_mut(),
                0,
                std::ptr::null(),
            )
        } < 0
        {
            self.unregister(identity, source);
            return Err(io::Error::last_os_error());
        }
        match renderer_process_instance_token(source.process_id) {
            Ok(Some(current)) if current == source.process_instance_token => {}
            Ok(Some(_)) => {
                self.unregister(identity, source);
                return Err(io::Error::new(
                    io::ErrorKind::NotFound,
                    "renderer PID was reused before event registration",
                ));
            }
            Ok(None) => {
                self.unregister(identity, source);
                return Err(io::Error::new(
                    io::ErrorKind::Unsupported,
                    "renderer process-instance token is unavailable",
                ));
            }
            Err(error) => {
                self.unregister(identity, source);
                return Err(error);
            }
        }
        self.by_identity.insert(identity, (token, source));
        self.by_token.insert(token, identity);
        Ok(())
    }

    fn set_write_interest(
        &mut self,
        identity: RendererWorkerIdentity,
        source: RendererProcessEventSource,
        enabled: bool,
    ) -> io::Result<()> {
        let Some((token, registered_source)) = self.by_identity.get(&identity).copied() else {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                "renderer write watch identity is not registered",
            ));
        };
        if registered_source != source {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "renderer write watch source changed within one worker lifetime",
            ));
        }
        let change = libc::kevent {
            ident: source.control_fd as libc::uintptr_t,
            filter: libc::EVFILT_WRITE,
            flags: if enabled { libc::EV_ENABLE } else { libc::EV_DISABLE },
            fflags: 0,
            data: 0,
            udata: token as *mut libc::c_void,
        };
        if unsafe {
            libc::kevent(self.handle.0, &change, 1, std::ptr::null_mut(), 0, std::ptr::null())
        } < 0
        {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    }

    fn unregister(&mut self, identity: RendererWorkerIdentity, source: RendererProcessEventSource) {
        let token = self.by_identity.remove(&identity).map(|entry| entry.0);
        if let Some(token) = token {
            self.by_token.remove(&token);
        }
        let changes = [
            libc::kevent {
                ident: source.control_fd as libc::uintptr_t,
                filter: libc::EVFILT_READ,
                flags: libc::EV_DELETE,
                fflags: 0,
                data: 0,
                udata: std::ptr::null_mut(),
            },
            libc::kevent {
                ident: source.control_fd as libc::uintptr_t,
                filter: libc::EVFILT_WRITE,
                flags: libc::EV_DELETE,
                fflags: 0,
                data: 0,
                udata: std::ptr::null_mut(),
            },
            libc::kevent {
                ident: source.process_id as libc::uintptr_t,
                filter: libc::EVFILT_PROC,
                flags: libc::EV_DELETE,
                fflags: 0,
                data: 0,
                udata: std::ptr::null_mut(),
            },
        ];
        for change in changes {
            let _ = unsafe {
                libc::kevent(self.handle.0, &change, 1, std::ptr::null_mut(), 0, std::ptr::null())
            };
        }
    }

    fn wait(&self, timeout: Duration) -> io::Result<Vec<RendererWorkerIdentity>> {
        let timeout_value = libc::timespec {
            tv_sec: timeout.as_secs().try_into().unwrap_or(libc::time_t::MAX),
            tv_nsec: timeout.subsec_nanos().into(),
        };
        let timeout_pointer =
            if timeout == Duration::MAX { std::ptr::null() } else { &timeout_value };
        let mut events: [libc::kevent; 128] = unsafe { std::mem::zeroed() };
        let count = unsafe {
            libc::kevent(
                self.handle.0,
                std::ptr::null(),
                0,
                events.as_mut_ptr(),
                events.len() as libc::c_int,
                timeout_pointer,
            )
        };
        if count < 0 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::Interrupted {
                return Ok(Vec::new());
            }
            return Err(error);
        }
        let mut ready = BTreeSet::new();
        for event in &events[..count as usize] {
            if event.filter == libc::EVFILT_USER {
                continue;
            }
            if event.flags & libc::EV_ERROR != 0 && event.data != 0 {
                return Err(io::Error::from_raw_os_error(event.data as i32));
            }
            let token = event.udata as usize;
            if let Some(identity) = self.by_token.get(&token) {
                ready.insert(*identity);
            }
        }
        Ok(ready.into_iter().collect())
    }
}

struct Shared {
    state: Mutex<CoordinatorState>,
    desired_presentations: Mutex<DesiredPresentations>,
    statuses: Mutex<BTreeMap<WorkspaceUuid, PublishedRendererWorkerStatus>>,
    event_handler: Mutex<Option<RendererSupervisorEventHandler>>,
    changed: Condvar,
    #[cfg(target_os = "macos")]
    event_wake: Mutex<Option<KqueueCoordinatorWake>>,
}

#[derive(Clone)]
struct PublishedRendererWorkerStatus {
    status: RendererWorkerStatus,
    published_at: Instant,
}

impl PublishedRendererWorkerStatus {
    fn current(&self, now: Instant) -> RendererWorkerStatus {
        let mut status = self.status.clone();
        if let Some(retry_after_milliseconds) = status.retry_after_milliseconds {
            let elapsed = duration_milliseconds(now.saturating_duration_since(self.published_at));
            status.retry_after_milliseconds =
                Some(retry_after_milliseconds.saturating_sub(elapsed));
        }
        status
    }
}

impl Shared {
    fn new(queue_budget: Arc<SupervisorQueueBudget>) -> Self {
        #[cfg(target_os = "macos")]
        {
            Self::new_with_event_wake(queue_budget, None)
        }
        #[cfg(not(target_os = "macos"))]
        {
            Self::new_with_event_wake(queue_budget)
        }
    }

    fn new_with_event_wake(
        queue_budget: Arc<SupervisorQueueBudget>,
        #[cfg(target_os = "macos")] event_wake: Option<KqueueCoordinatorWake>,
    ) -> Self {
        Self {
            state: Mutex::new(CoordinatorState::new(queue_budget)),
            desired_presentations: Mutex::new(DesiredPresentations::default()),
            statuses: Mutex::new(BTreeMap::new()),
            event_handler: Mutex::new(None),
            changed: Condvar::new(),
            #[cfg(target_os = "macos")]
            event_wake: Mutex::new(event_wake),
        }
    }

    #[cfg(target_os = "macos")]
    fn replace_event_wake(&self, event_wake: Option<KqueueCoordinatorWake>) {
        *self.event_wake.lock().unwrap() = event_wake;
    }

    fn notify_one(&self) {
        self.changed.notify_one();
        #[cfg(target_os = "macos")]
        if let Some(wake) = self.event_wake.lock().unwrap().as_ref() {
            let _ = wake.trigger();
        }
    }

    fn notify_all(&self) {
        self.changed.notify_all();
        #[cfg(target_os = "macos")]
        if let Some(wake) = self.event_wake.lock().unwrap().as_ref() {
            let _ = wake.trigger();
        }
    }
}

#[derive(Default)]
struct DesiredPresentations {
    revision: u64,
    values: BTreeMap<PresentationId, WorkspaceUuid>,
    pending_changes: BTreeMap<PresentationId, CoalescedPresentationChange>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct CoalescedPresentationChange {
    before: Option<WorkspaceUuid>,
    after: Option<WorkspaceUuid>,
}

impl DesiredPresentations {
    fn set(
        &mut self,
        presentation_id: PresentationId,
        workspace_uuid: Option<WorkspaceUuid>,
    ) -> bool {
        let before = self.values.get(&presentation_id).copied();
        let changed = match workspace_uuid {
            Some(workspace_uuid) => {
                self.values.insert(presentation_id, workspace_uuid) != Some(workspace_uuid)
            }
            None => self.values.remove(&presentation_id).is_some(),
        };
        if changed {
            // This side lane is authoritative and coalescing. A presentation
            // that moves repeatedly before the coordinator wakes contributes
            // one keyed update instead of cloning the complete desired map.
            if let Some(pending) = self.pending_changes.get_mut(&presentation_id) {
                pending.after = workspace_uuid;
                if pending.after == pending.before {
                    self.pending_changes.remove(&presentation_id);
                }
            } else {
                self.pending_changes.insert(
                    presentation_id,
                    CoalescedPresentationChange { before, after: workspace_uuid },
                );
            }
            self.advance_revision();
        }
        changed
    }

    fn advance_revision(&mut self) {
        self.revision = self.revision.wrapping_add(1).max(1);
    }

    fn take_pending_changes(&mut self, reconciled_revision: &mut u64) -> Option<PendingChanges> {
        if self.revision == *reconciled_revision {
            return None;
        }
        *reconciled_revision = self.revision;
        Some(
            std::mem::take(&mut self.pending_changes)
                .into_iter()
                .map(|(presentation_id, change)| (presentation_id, change.after))
                .collect(),
        )
    }
}

type PendingChanges = BTreeMap<PresentationId, Option<WorkspaceUuid>>;

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
struct SupervisorQueueUsage {
    messages: usize,
    bytes: usize,
}

struct SupervisorQueueBudget {
    usage: Mutex<SupervisorQueueUsage>,
}

impl Default for SupervisorQueueBudget {
    fn default() -> Self {
        Self {
            usage: Mutex::new(SupervisorQueueUsage {
                messages: 0,
                bytes: MAXIMUM_SUPERVISOR_FIXED_QUEUE_STORAGE_BYTES,
            }),
        }
    }
}

impl SupervisorQueueBudget {
    fn try_reserve_normal(&self, messages: usize, bytes: usize) -> bool {
        self.try_reserve(
            messages,
            bytes,
            MAXIMUM_SUPERVISOR_QUEUED_MESSAGES.saturating_sub(SUPERVISOR_RECOVERY_RESERVE_MESSAGES),
            MAXIMUM_SUPERVISOR_QUEUED_BYTES.saturating_sub(SUPERVISOR_RECOVERY_RESERVE_BYTES),
        )
    }

    fn try_reserve_recovery(&self, messages: usize, bytes: usize) -> bool {
        self.try_reserve(
            messages,
            bytes,
            MAXIMUM_SUPERVISOR_QUEUED_MESSAGES,
            MAXIMUM_SUPERVISOR_QUEUED_BYTES,
        )
    }

    fn try_reserve(
        &self,
        messages: usize,
        bytes: usize,
        message_limit: usize,
        byte_limit: usize,
    ) -> bool {
        let mut usage = self.usage.lock().unwrap();
        if usage.messages.saturating_add(messages) > message_limit
            || usage.bytes.saturating_add(bytes) > byte_limit
        {
            return false;
        }
        usage.messages += messages;
        usage.bytes += bytes;
        true
    }

    fn release(&self, messages: usize, bytes: usize) {
        let mut usage = self.usage.lock().unwrap();
        usage.messages = usage
            .messages
            .checked_sub(messages)
            .expect("renderer queue message accounting underflow");
        usage.bytes =
            usage.bytes.checked_sub(bytes).expect("renderer queue byte accounting underflow");
        assert!(
            usage.bytes >= MAXIMUM_SUPERVISOR_FIXED_QUEUE_STORAGE_BYTES,
            "renderer queue fixed-storage reserve was released"
        );
    }

    #[cfg(test)]
    fn snapshot(&self) -> SupervisorQueueUsage {
        *self.usage.lock().unwrap()
    }
}

struct CoordinatorState {
    commands: VecDeque<AccountedCoordinatorCommand>,
    queue_budget: Arc<SupervisorQueueBudget>,
    retained_command_messages: usize,
    retained_command_dynamic_bytes: usize,
    stopping: bool,
}

struct AccountedCoordinatorCommand {
    command: CoordinatorCommand,
    retained_messages: usize,
    dynamic_bytes: usize,
}

#[derive(Default)]
struct RendererPublicationLinearization {
    state: AtomicU8,
}

impl RendererPublicationLinearization {
    fn begin(&self) -> bool {
        self.state
            .compare_exchange(
                PUBLICATION_PENDING,
                PUBLICATION_STARTED,
                Ordering::AcqRel,
                Ordering::Acquire,
            )
            .is_ok()
    }

    fn cancel_if_pending(&self) -> bool {
        self.state
            .compare_exchange(
                PUBLICATION_PENDING,
                PUBLICATION_CANCELED,
                Ordering::AcqRel,
                Ordering::Acquire,
            )
            .is_ok()
    }

    fn finish(&self) {
        let previous = self.state.swap(PUBLICATION_FINISHED, Ordering::AcqRel);
        debug_assert_eq!(previous, PUBLICATION_STARTED);
    }
}

enum CoordinatorCommand {
    #[cfg(test)]
    SetPresentation {
        presentation_id: PresentationId,
        workspace_uuid: Option<WorkspaceUuid>,
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
    PublishIfEpoch {
        workspace_uuid: WorkspaceUuid,
        renderer_epoch: u64,
        messages: Vec<RendererControlMessage>,
        publication: Arc<RendererPublicationLinearization>,
        reply: SyncSender<Result<RendererWorkerStatus, RendererSupervisorError>>,
    },
    RetireIfEpoch {
        workspace_uuid: WorkspaceUuid,
        renderer_epoch: u64,
        reply: SyncSender<Result<bool, RendererSupervisorError>>,
    },
    WorkspaceStatus {
        workspace_uuid: WorkspaceUuid,
        reply: SyncSender<Option<RendererWorkerStatus>>,
    },
    RecoverWorkspaceOverflow {
        workspace_uuid: WorkspaceUuid,
    },
}

impl CoordinatorState {
    fn new(queue_budget: Arc<SupervisorQueueBudget>) -> Self {
        let commands = VecDeque::with_capacity(MAXIMUM_COMMAND_QUEUE_LENGTH);
        assert!(
            commands.capacity() <= MAXIMUM_COMMAND_QUEUE_ALLOCATED_SLOTS,
            "coordinator queue allocation exceeded its fixed-storage reserve"
        );
        Self {
            commands,
            queue_budget,
            retained_command_messages: 0,
            retained_command_dynamic_bytes: 0,
            stopping: false,
        }
    }

    fn enqueue(&mut self, command: CoordinatorCommand) -> Result<(), RendererSupervisorError> {
        let retained_messages = command.retained_message_count();
        let dynamic_bytes = command.dynamic_retained_byte_count();
        let normal_count_limit = MAXIMUM_COMMAND_QUEUE_LENGTH.saturating_sub(1);
        let normal_byte_limit = MAXIMUM_COMMAND_QUEUE_BYTES
            .saturating_sub(COORDINATOR_QUEUE_FIXED_STORAGE_BYTES)
            .saturating_sub(COMMAND_QUEUE_RECOVERY_RESERVE_BYTES);
        if self.commands.len() < normal_count_limit
            && self.retained_command_dynamic_bytes.saturating_add(dynamic_bytes)
                <= normal_byte_limit
            && self.queue_budget.try_reserve_normal(retained_messages, dynamic_bytes)
        {
            self.push_accounted(command, retained_messages, dynamic_bytes);
            return Ok(());
        }

        let Some(workspace_uuid) = command.recoverable_workspace() else {
            return Err(RendererSupervisorError::QueueFull);
        };
        self.schedule_overflow_recovery(workspace_uuid)
    }

    fn schedule_overflow_recovery(
        &mut self,
        workspace_uuid: WorkspaceUuid,
    ) -> Result<(), RendererSupervisorError> {
        let mut removed_messages = 0_usize;
        let mut removed_dynamic_bytes = 0_usize;
        let mut retained_messages = 0_usize;
        let mut retained_dynamic_bytes = 0_usize;
        self.commands.retain(|queued| {
            let keep = queued.command.recoverable_workspace() != Some(workspace_uuid);
            if keep {
                retained_messages = retained_messages.saturating_add(queued.retained_messages);
                retained_dynamic_bytes =
                    retained_dynamic_bytes.saturating_add(queued.dynamic_bytes);
            } else {
                removed_messages = removed_messages.saturating_add(queued.retained_messages);
                removed_dynamic_bytes = removed_dynamic_bytes.saturating_add(queued.dynamic_bytes);
            }
            keep
        });
        self.queue_budget.release(removed_messages, removed_dynamic_bytes);
        self.retained_command_messages = retained_messages;
        self.retained_command_dynamic_bytes = retained_dynamic_bytes;

        if self.commands.iter().any(|queued| {
            matches!(
                queued.command,
                CoordinatorCommand::RecoverWorkspaceOverflow { workspace_uuid: queued_workspace }
                    if queued_workspace == workspace_uuid
            )
        }) {
            return Ok(());
        }

        let recovery = CoordinatorCommand::RecoverWorkspaceOverflow { workspace_uuid };
        let recovery_messages = recovery.retained_message_count();
        let recovery_dynamic_bytes = recovery.dynamic_retained_byte_count();
        if self.commands.len() >= MAXIMUM_COMMAND_QUEUE_LENGTH
            || COORDINATOR_QUEUE_FIXED_STORAGE_BYTES
                .saturating_add(self.retained_command_dynamic_bytes)
                .saturating_add(recovery_dynamic_bytes)
                > MAXIMUM_COMMAND_QUEUE_BYTES
            || !self.queue_budget.try_reserve_recovery(recovery_messages, recovery_dynamic_bytes)
        {
            return Err(RendererSupervisorError::QueueFull);
        }
        self.push_accounted(recovery, recovery_messages, recovery_dynamic_bytes);
        Ok(())
    }

    fn push_accounted(
        &mut self,
        command: CoordinatorCommand,
        retained_messages: usize,
        dynamic_bytes: usize,
    ) {
        self.retained_command_messages =
            self.retained_command_messages.saturating_add(retained_messages);
        self.retained_command_dynamic_bytes =
            self.retained_command_dynamic_bytes.saturating_add(dynamic_bytes);
        self.commands.push_back(AccountedCoordinatorCommand {
            command,
            retained_messages,
            dynamic_bytes,
        });
    }

    fn pop_front(&mut self) -> Option<CoordinatorCommand> {
        let queued = self.commands.pop_front()?;
        self.retained_command_messages =
            self.retained_command_messages.saturating_sub(queued.retained_messages);
        self.retained_command_dynamic_bytes =
            self.retained_command_dynamic_bytes.saturating_sub(queued.dynamic_bytes);
        self.queue_budget.release(queued.retained_messages, queued.dynamic_bytes);
        Some(queued.command)
    }

    #[cfg(test)]
    fn retained_byte_count(&self) -> usize {
        size_of::<Self>()
            .saturating_add(
                self.commands.capacity().saturating_mul(size_of::<AccountedCoordinatorCommand>()),
            )
            .saturating_add(self.retained_command_dynamic_bytes)
    }
}

impl Default for CoordinatorState {
    fn default() -> Self {
        Self::new(Arc::new(SupervisorQueueBudget::default()))
    }
}

impl Drop for CoordinatorState {
    fn drop(&mut self) {
        self.queue_budget
            .release(self.retained_command_messages, self.retained_command_dynamic_bytes);
    }
}

impl CoordinatorCommand {
    fn recoverable_workspace(&self) -> Option<WorkspaceUuid> {
        match self {
            Self::Send { workspace_uuid, .. } | Self::SendIfEpoch { workspace_uuid, .. } => {
                Some(*workspace_uuid)
            }
            #[cfg(test)]
            Self::SetPresentation { .. } => None,
            Self::PublishIfEpoch { .. }
            | Self::RetireIfEpoch { .. }
            | Self::WorkspaceStatus { .. }
            | Self::RecoverWorkspaceOverflow { .. } => None,
        }
    }

    fn retained_message_count(&self) -> usize {
        match self {
            Self::SendIfEpoch { messages, .. } | Self::PublishIfEpoch { messages, .. } => {
                messages.len()
            }
            #[cfg(test)]
            Self::SetPresentation { .. } => 1,
            Self::Send { .. }
            | Self::RetireIfEpoch { .. }
            | Self::WorkspaceStatus { .. }
            | Self::RecoverWorkspaceOverflow { .. } => 1,
        }
    }

    fn dynamic_retained_byte_count(&self) -> usize {
        match self {
            Self::Send { message, .. } => message.dynamic_retained_byte_count(),
            Self::SendIfEpoch { messages, .. } | Self::PublishIfEpoch { messages, .. } => messages
                .capacity()
                .saturating_mul(size_of::<RendererControlMessage>())
                .saturating_add(
                    messages
                        .iter()
                        .map(RendererControlMessage::dynamic_retained_byte_count)
                        .fold(0_usize, usize::saturating_add),
                ),
            #[cfg(test)]
            Self::SetPresentation { .. } => 0,
            Self::RetireIfEpoch { .. }
            | Self::WorkspaceStatus { .. }
            | Self::RecoverWorkspaceOverflow { .. } => 0,
        }
    }
}

fn coordinator_loop<S, C>(shared: &Shared, core: &mut SupervisorCore<S, C>)
where
    S: RendererSpawner,
    C: SupervisorClock,
{
    let mut desired_presentation_revision = 0;
    loop {
        let command = {
            let mut state = shared.state.lock().unwrap();
            if state.commands.is_empty() && !state.stopping {
                let timeout = core.next_wake_after().min(CHILD_POLL_INTERVAL);
                let (next, _) = shared.changed.wait_timeout(state, timeout).unwrap();
                state = next;
            }
            if state.stopping {
                core.shutdown();
                shared.statuses.lock().unwrap().clear();
                return;
            }
            state.pop_front()
        };

        if let Some(command) = command {
            process_coordinator_command(shared, core, &mut desired_presentation_revision, command);
        }
        reconcile_desired_presentations(shared, core, &mut desired_presentation_revision);
        core.tick();
        publish_core_updates(shared, core);
    }
}

#[cfg(target_os = "macos")]
fn coordinator_loop_event_driven<S, C>(
    shared: &Shared,
    core: &mut SupervisorCore<S, C>,
    reactor: KqueueRendererEventReactor,
) where
    S: RendererSpawner,
    C: SupervisorClock,
{
    let mut desired_presentation_revision = 0;
    let mut reactor = Some(reactor);
    let mut pending_ready = VecDeque::new();
    loop {
        let command = {
            let mut state = shared.state.lock().unwrap();
            if state.stopping {
                core.shutdown();
                shared.statuses.lock().unwrap().clear();
                return;
            }
            state.pop_front()
        };
        if let Some(command) = command {
            process_coordinator_command(shared, core, &mut desired_presentation_revision, command);
        }

        reconcile_desired_presentations(shared, core, &mut desired_presentation_revision);
        core.process_due_timers();
        if reactor.is_none() {
            match rebuild_renderer_event_reactor(core, KqueueRendererEventReactor::new) {
                Ok(rebuilt) => {
                    let wake = rebuilt.wake();
                    shared.replace_event_wake(Some(wake.clone()));
                    // Commands may have arrived while the old reactor was
                    // absent and therefore had no kernel wake target. A user
                    // event is level-preserved until the next kevent wait, so
                    // this closes the install-before-wait lost-wake window.
                    if let Err(error) = wake.trigger() {
                        eprintln!("failed to arm rebuilt renderer reactor: {error}");
                        shared.replace_event_wake(None);
                        continue;
                    }
                    reactor = Some(rebuilt);
                }
                Err(error) => {
                    eprintln!("cmux renderer event reactor remains unavailable: {error}");
                    publish_core_updates(shared, core);
                    wait_for_renderer_reactor_retry(shared, core.next_wake_after());
                    continue;
                }
            }
        }
        // Service at most one potentially 1 MiB worker receive batch per
        // coordinator turn. Commands, timers, and lifecycle publication get
        // a fairness point between every ready worker under a flood.
        if let Some(identity) = pending_ready.pop_front() {
            core.process_worker_event(identity);
            publish_core_updates(shared, core);
            continue;
        }
        let active_reactor = reactor.as_mut().unwrap();
        synchronize_renderer_event_reactor(core, active_reactor);
        publish_core_updates(shared, core);
        // One command per turn prevents a sustained producer from starving
        // writable workers and write-stall timers. A busy command lane must
        // still poll the kernel without sleeping: otherwise write readiness
        // is never harvested until the producer stops filling the queue.
        let commands_pending = !shared.state.lock().unwrap().commands.is_empty();
        let wait_timeout = if commands_pending { Duration::ZERO } else { core.next_wake_after() };
        let wait_result = active_reactor.wait(wait_timeout);
        match wait_result {
            Ok(ready) => {
                pending_ready.extend(ready);
            }
            Err(error) => {
                eprintln!("cmux renderer event reactor failed: {error}");
                shared.replace_event_wake(None);
                reactor = None;
            }
        }
    }
}

#[cfg(target_os = "macos")]
fn rebuild_renderer_event_reactor<S, C, F>(
    core: &mut SupervisorCore<S, C>,
    factory: F,
) -> io::Result<KqueueRendererEventReactor>
where
    S: RendererSpawner,
    C: SupervisorClock,
    F: FnOnce() -> io::Result<KqueueRendererEventReactor>,
{
    let reactor = factory()?;
    core.requeue_all_process_watches();
    Ok(reactor)
}

#[cfg(target_os = "macos")]
fn wait_for_renderer_reactor_retry(shared: &Shared, next_timer: Duration) {
    let timeout = next_timer.min(REACTOR_REBUILD_RETRY);
    let state = shared.state.lock().unwrap();
    if !state.stopping && state.commands.is_empty() {
        let _ = shared.changed.wait_timeout(state, timeout).unwrap();
    }
}

#[cfg(target_os = "macos")]
fn synchronize_renderer_event_reactor<S, C>(
    core: &mut SupervisorCore<S, C>,
    reactor: &mut KqueueRendererEventReactor,
) where
    S: RendererSpawner,
    C: SupervisorClock,
{
    loop {
        let changes = core.take_process_watch_changes();
        if changes.is_empty() {
            return;
        }
        let mut failures = Vec::new();
        for change in changes {
            let identity = match change {
                RendererProcessWatchChange::Register { identity, .. }
                | RendererProcessWatchChange::SetWriteInterest { identity, .. }
                | RendererProcessWatchChange::Unregister { identity, .. } => identity,
            };
            let is_required_watch =
                !matches!(change, RendererProcessWatchChange::Unregister { .. });
            if let Err(error) = reactor.apply(change)
                && is_required_watch
            {
                failures.push((
                    identity.workspace_uuid,
                    format!("failed to watch renderer worker events: {error}"),
                ));
            }
        }
        core.workers_failed(failures);
    }
}

fn process_coordinator_command<S, C>(
    shared: &Shared,
    core: &mut SupervisorCore<S, C>,
    desired_presentation_revision: &mut u64,
    command: CoordinatorCommand,
) where
    S: RendererSpawner,
    C: SupervisorClock,
{
    match command {
        #[cfg(test)]
        CoordinatorCommand::SetPresentation { presentation_id, workspace_uuid } => {
            core.set_presentation_workspace(presentation_id, workspace_uuid);
        }
        CoordinatorCommand::Send { workspace_uuid, message } => {
            if let Err(error) = core.send(workspace_uuid, message) {
                core.worker_failed(workspace_uuid, error.to_string());
            }
        }
        CoordinatorCommand::SendIfEpoch { workspace_uuid, renderer_epoch, messages } => {
            core.send_if_epoch(workspace_uuid, renderer_epoch, messages);
        }
        CoordinatorCommand::PublishIfEpoch {
            workspace_uuid,
            renderer_epoch,
            messages,
            publication,
            reply,
        } => {
            if !publication.begin() {
                let _ = reply.send(Err(RendererSupervisorError::Io(
                    "renderer activation publication was canceled".to_owned(),
                )));
                return;
            }
            core.publish_if_epoch(
                workspace_uuid,
                renderer_epoch,
                messages,
                RendererPublicationCompletion::new(
                    workspace_uuid,
                    renderer_epoch,
                    publication,
                    reply,
                ),
            );
        }
        CoordinatorCommand::RetireIfEpoch { workspace_uuid, renderer_epoch, reply } => {
            let _ = reply.send(core.retire_if_epoch(workspace_uuid, renderer_epoch));
        }
        CoordinatorCommand::WorkspaceStatus { workspace_uuid, reply } => {
            // Desired presentation changes use a coalescing side lane so
            // visibility teardown cannot be blocked by a saturated command
            // queue. Reconcile before answering this ordered status query.
            reconcile_desired_presentations(shared, core, desired_presentation_revision);
            let _ = reply.send(core.workspace_status(workspace_uuid));
        }
        CoordinatorCommand::RecoverWorkspaceOverflow { workspace_uuid } => {
            core.worker_failed(
                workspace_uuid,
                "renderer control queue overflow; forcing full scene recovery".to_owned(),
            );
        }
    }
}

fn publish_core_updates<S, C>(shared: &Shared, core: &mut SupervisorCore<S, C>)
where
    S: RendererSpawner,
    C: SupervisorClock,
{
    core.publish_reaper_completions();
    let status_changes = core.take_status_changes();
    if !status_changes.is_empty() {
        let mut statuses = shared.statuses.lock().unwrap();
        for (workspace_uuid, status) in status_changes {
            if let Some(status) = status {
                statuses.insert(
                    workspace_uuid,
                    PublishedRendererWorkerStatus { status, published_at: Instant::now() },
                );
            } else {
                statuses.remove(&workspace_uuid);
            }
        }
    }
    for event in core.take_events() {
        let handler = shared.event_handler.lock().unwrap().clone();
        if let Some(handler) = handler {
            handler(event);
        }
    }
}

fn reconcile_desired_presentations<S, C>(
    shared: &Shared,
    core: &mut SupervisorCore<S, C>,
    reconciled_revision: &mut u64,
) where
    S: RendererSpawner,
    C: SupervisorClock,
{
    let pending_changes = {
        let mut desired = shared.desired_presentations.lock().unwrap();
        desired.take_pending_changes(reconciled_revision)
    };
    if let Some(pending_changes) = pending_changes {
        core.apply_presentation_changes(pending_changes);
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

trait RendererProcess: Send + 'static {
    fn pid(&self) -> u32;
    fn process_instance_token(&self) -> Option<RendererProcessInstanceToken> {
        None
    }
    fn event_source(&self) -> Option<RendererProcessEventSource> {
        None
    }
    /// Attempt one nonblocking write. Partial progress is retained by the
    /// supervisor and resumed only after another fair coordinator turn.
    fn write_nonblocking(&mut self, bytes: &[u8]) -> io::Result<usize>;
    fn receive(&mut self, destination: &mut Vec<u8>) -> io::Result<ReceiveResult>;
    fn try_wait(&mut self) -> io::Result<Option<ExitStatus>>;
    /// Block until the exact child is reaped. Only the supervisor-owned
    /// reaper thread invokes this method.
    fn wait(&mut self) -> io::Result<ExitStatus>;
    /// Close the daemon endpoint before termination so no retired worker can
    /// retain a live control capability while the coordinator has forgotten
    /// its identity.
    fn close_control(&mut self);
    /// Request termination without waiting for process exit.
    fn terminate(&mut self) -> io::Result<()>;
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

struct AccountedRendererMessage {
    message: RendererControlMessage,
    reserved_bytes: usize,
    completion: Option<RendererPublicationCompletion>,
}

struct PendingRendererFrame {
    frame: Vec<u8>,
    offset: usize,
    reserved_bytes: usize,
    completion: Option<RendererPublicationCompletion>,
    bootstrap: bool,
}

struct RendererPublicationCompletion {
    workspace_uuid: WorkspaceUuid,
    renderer_epoch: u64,
    publication: Arc<RendererPublicationLinearization>,
    reply: Option<SyncSender<Result<RendererWorkerStatus, RendererSupervisorError>>>,
}

impl RendererPublicationCompletion {
    fn new(
        workspace_uuid: WorkspaceUuid,
        renderer_epoch: u64,
        publication: Arc<RendererPublicationLinearization>,
        reply: SyncSender<Result<RendererWorkerStatus, RendererSupervisorError>>,
    ) -> Self {
        Self { workspace_uuid, renderer_epoch, publication, reply: Some(reply) }
    }

    fn complete(mut self, result: Result<RendererWorkerStatus, RendererSupervisorError>) {
        self.finish(result);
    }

    fn fail_uncertain(mut self, diagnostic: &str) {
        self.finish(Err(RendererSupervisorError::PublicationUncertain {
            workspace_uuid: self.workspace_uuid,
            renderer_epoch: self.renderer_epoch,
            diagnostic: diagnostic.to_owned(),
        }));
    }

    fn finish(&mut self, result: Result<RendererWorkerStatus, RendererSupervisorError>) {
        let Some(reply) = self.reply.take() else { return };
        let _ = reply.send(result);
        self.publication.finish();
    }
}

impl Drop for RendererPublicationCompletion {
    fn drop(&mut self) {
        if self.reply.is_none() {
            return;
        }
        self.finish(Err(RendererSupervisorError::PublicationUncertain {
            workspace_uuid: self.workspace_uuid,
            renderer_epoch: self.renderer_epoch,
            diagnostic: "renderer worker stopped after publication began".to_owned(),
        }));
    }
}

struct BoundedWorkerOutbox {
    messages: VecDeque<AccountedRendererMessage>,
    pending_frame: Option<PendingRendererFrame>,
    retained_items: usize,
    retained_reserved_bytes: usize,
    queue_budget: Arc<SupervisorQueueBudget>,
}

impl BoundedWorkerOutbox {
    fn new(queue_budget: Arc<SupervisorQueueBudget>) -> Self {
        let messages = VecDeque::with_capacity(MAXIMUM_WORKER_OUTBOX_LENGTH);
        assert!(
            messages.capacity() <= MAXIMUM_WORKER_OUTBOX_ALLOCATED_SLOTS,
            "worker outbox allocation exceeded its fixed-storage reserve"
        );
        Self {
            messages,
            pending_frame: None,
            retained_items: 0,
            retained_reserved_bytes: 0,
            queue_budget,
        }
    }

    fn try_push(&mut self, message: RendererControlMessage) -> Result<(), RendererSupervisorError> {
        let reserved_bytes = renderer_message_reserved_bytes(&message)?;
        let reserved_byte_limit =
            MAXIMUM_WORKER_OUTBOX_BYTES.saturating_sub(WORKER_OUTBOX_FIXED_STORAGE_BYTES);
        if self.ordinary_item_count() >= MAXIMUM_WORKER_OUTBOX_LENGTH
            || self.retained_reserved_bytes.saturating_add(reserved_bytes) > reserved_byte_limit
            || !self.queue_budget.try_reserve_normal(1, reserved_bytes)
        {
            return Err(RendererSupervisorError::QueueFull);
        }
        self.retained_items += 1;
        self.retained_reserved_bytes += reserved_bytes;
        self.messages.push_back(AccountedRendererMessage {
            message,
            reserved_bytes,
            completion: None,
        });
        Ok(())
    }

    fn try_extend(
        &mut self,
        messages: Vec<RendererControlMessage>,
    ) -> Result<(), RendererSupervisorError> {
        let additional_count = messages.len();
        let mut additional_reserved_bytes = 0_usize;
        for message in &messages {
            additional_reserved_bytes =
                additional_reserved_bytes.saturating_add(renderer_message_reserved_bytes(message)?);
        }
        let reserved_byte_limit =
            MAXIMUM_WORKER_OUTBOX_BYTES.saturating_sub(WORKER_OUTBOX_FIXED_STORAGE_BYTES);
        if self.ordinary_item_count().saturating_add(additional_count)
            > MAXIMUM_WORKER_OUTBOX_LENGTH
            || self.retained_reserved_bytes.saturating_add(additional_reserved_bytes)
                > reserved_byte_limit
            || !self.queue_budget.try_reserve_normal(additional_count, additional_reserved_bytes)
        {
            return Err(RendererSupervisorError::QueueFull);
        }
        for message in messages {
            let reserved_bytes = renderer_message_reserved_bytes(&message)?;
            self.messages.push_back(AccountedRendererMessage {
                message,
                reserved_bytes,
                completion: None,
            });
        }
        self.retained_items += additional_count;
        self.retained_reserved_bytes += additional_reserved_bytes;
        Ok(())
    }

    fn attach_completion_to_back(&mut self, completion: RendererPublicationCompletion) {
        let queued = self.messages.back_mut().expect("publication batch cannot be empty");
        debug_assert!(queued.completion.is_none());
        queued.completion = Some(completion);
    }

    fn install_bootstrap(&mut self, frame: Vec<u8>) -> Result<(), RendererSupervisorError> {
        debug_assert!(self.pending_frame.is_none());
        let reserved_bytes = frame.capacity();
        let reserved_byte_limit =
            MAXIMUM_WORKER_OUTBOX_BYTES.saturating_sub(WORKER_OUTBOX_FIXED_STORAGE_BYTES);
        if self.retained_reserved_bytes.saturating_add(reserved_bytes) > reserved_byte_limit
            || !self.queue_budget.try_reserve_recovery(1, reserved_bytes)
        {
            return Err(RendererSupervisorError::QueueFull);
        }
        self.retained_items += 1;
        self.retained_reserved_bytes += reserved_bytes;
        self.pending_frame = Some(PendingRendererFrame {
            frame,
            offset: 0,
            reserved_bytes,
            completion: None,
            bootstrap: true,
        });
        Ok(())
    }

    fn prepare_next(
        &mut self,
        encoder: &mut RendererControlEncoder,
    ) -> Result<bool, RendererSupervisorError> {
        if self.pending_frame.is_some() {
            return Ok(true);
        }
        let Some(queued) = self.messages.pop_front() else { return Ok(false) };
        let AccountedRendererMessage { message, reserved_bytes, completion } = queued;
        let frame = match encoder.encode(message) {
            Ok(frame) => frame,
            Err(error) => {
                self.release_item(reserved_bytes);
                if let Some(completion) = completion {
                    completion.fail_uncertain(&error.to_string());
                }
                return Err(error.into());
            }
        };
        debug_assert!(frame.capacity() <= reserved_bytes);
        self.pending_frame = Some(PendingRendererFrame {
            frame,
            offset: 0,
            reserved_bytes,
            completion,
            bootstrap: false,
        });
        Ok(true)
    }

    fn complete_pending_frame(
        &mut self,
        session: &mut RendererControlSessionStateMachine,
    ) -> Result<Option<RendererPublicationCompletion>, RendererSupervisorError> {
        let mut pending = self.pending_frame.take().expect("pending renderer frame missing");
        debug_assert_eq!(pending.offset, pending.frame.len());
        let validation = RendererControlWire::decode(&pending.frame)
            .map_err(RendererSupervisorError::from)
            .and_then(|envelope| session.accept(&envelope).map_err(RendererSupervisorError::from));
        self.release_item(pending.reserved_bytes);
        if let Err(error) = validation {
            if let Some(completion) = pending.completion.take() {
                completion.fail_uncertain(&error.to_string());
            }
            return Err(error);
        }
        Ok(pending.completion)
    }

    fn discard_pending_frame(&mut self) {
        let Some(pending) = self.pending_frame.take() else { return };
        self.release_item(pending.reserved_bytes);
        drop(pending.completion);
    }

    fn fail_publications(&mut self, diagnostic: &str) {
        if let Some(completion) =
            self.pending_frame.as_mut().and_then(|pending| pending.completion.take())
        {
            completion.fail_uncertain(diagnostic);
        }
        for queued in &mut self.messages {
            if let Some(completion) = queued.completion.take() {
                completion.fail_uncertain(diagnostic);
            }
        }
    }

    fn release_item(&mut self, reserved_bytes: usize) {
        self.retained_items =
            self.retained_items.checked_sub(1).expect("renderer outbox item accounting underflow");
        self.retained_reserved_bytes = self
            .retained_reserved_bytes
            .checked_sub(reserved_bytes)
            .expect("renderer outbox byte accounting underflow");
        self.queue_budget.release(1, reserved_bytes);
    }

    fn ordinary_item_count(&self) -> usize {
        self.messages.len()
            + usize::from(self.pending_frame.as_ref().is_some_and(|frame| !frame.bootstrap))
    }

    fn has_writable_output(&self, state: RendererWorkerState) -> bool {
        self.pending_frame.is_some()
            || (state == RendererWorkerState::Ready && !self.messages.is_empty())
    }

    #[cfg(test)]
    fn len(&self) -> usize {
        self.ordinary_item_count()
    }

    #[cfg(test)]
    fn retained_byte_count(&self) -> usize {
        size_of::<Self>()
            .saturating_add(
                self.messages.capacity().saturating_mul(size_of::<AccountedRendererMessage>()),
            )
            .saturating_add(self.retained_reserved_bytes)
    }

    #[cfg(test)]
    fn retained_dynamic_byte_count(&self) -> usize {
        self.retained_reserved_bytes
    }

    #[cfg(test)]
    fn pop_front(&mut self) -> Option<RendererControlMessage> {
        let queued = self.messages.pop_front()?;
        self.release_item(queued.reserved_bytes);
        drop(queued.completion);
        Some(queued.message)
    }
}

fn renderer_message_reserved_bytes(
    message: &RendererControlMessage,
) -> Result<usize, RendererSupervisorError> {
    Ok(message.dynamic_retained_byte_count().max(message.encoded_frame_length()?))
}

struct WorkerWriteBatchOutcome {
    completions: Vec<RendererPublicationCompletion>,
    error: Option<RendererSupervisorError>,
    previous_write_interest: bool,
    write_interest: bool,
    previous_stall_deadline: Option<Duration>,
    stall_deadline: Option<Duration>,
}

fn flush_worker_write_batch<P: RendererProcess>(
    worker: &mut Worker<P>,
    now: Duration,
) -> WorkerWriteBatchOutcome {
    let previous_write_interest = worker.write_interest_enabled;
    let previous_stall_deadline = worker.write_stall_deadline;
    let mut completions = Vec::new();
    let mut error = None;
    let mut written_bytes = 0_usize;
    let mut write_calls = 0_usize;
    let mut made_progress = false;

    while written_bytes < MAXIMUM_WORKER_WRITE_BATCH_BYTES
        && write_calls < MAXIMUM_WORKER_WRITE_SYSCALLS_PER_TURN
    {
        if worker.outbox.pending_frame.is_none() {
            if worker.state != RendererWorkerState::Ready {
                break;
            }
            let prepared = match worker
                .outbox
                .prepare_next(worker.encoder.as_mut().expect("live renderer encoder missing"))
            {
                Ok(prepared) => prepared,
                Err(prepare_error) => {
                    error = Some(prepare_error);
                    break;
                }
            };
            if !prepared {
                break;
            }
        }

        let remaining_budget = MAXIMUM_WORKER_WRITE_BATCH_BYTES - written_bytes;
        let write_result = {
            let pending = worker.outbox.pending_frame.as_ref().unwrap();
            let remaining = &pending.frame[pending.offset..];
            let length = remaining.len().min(remaining_budget);
            worker
                .process
                .as_mut()
                .expect("live renderer process missing")
                .write_nonblocking(&remaining[..length])
        };
        write_calls += 1;
        let count = match write_result {
            Ok(0) => break,
            Ok(count) => count,
            Err(write_error) if write_error.kind() == io::ErrorKind::Interrupted => continue,
            Err(write_error) if write_error.kind() == io::ErrorKind::WouldBlock => break,
            Err(write_error) => {
                error = Some(write_error.into());
                break;
            }
        };
        let pending = worker.outbox.pending_frame.as_mut().unwrap();
        let remaining = pending.frame.len().saturating_sub(pending.offset);
        if count > remaining || count > remaining_budget {
            error = Some(RendererSupervisorError::Io(
                "renderer write reported impossible progress".to_owned(),
            ));
            break;
        }
        pending.offset += count;
        written_bytes += count;
        made_progress = true;
        if pending.offset == pending.frame.len() {
            match worker.outbox.complete_pending_frame(
                worker.session.as_mut().expect("live renderer session missing"),
            ) {
                Ok(Some(completion)) => completions.push(completion),
                Ok(None) => {}
                Err(session_error) => {
                    error = Some(session_error);
                    break;
                }
            }
        }
    }

    let write_interest = worker.outbox.has_writable_output(worker.state);
    worker.write_interest_enabled = write_interest;
    worker.write_stall_deadline = if write_interest {
        if made_progress || previous_stall_deadline.is_none() {
            Some(now.saturating_add(WORKER_WRITE_STALL_TIMEOUT))
        } else {
            previous_stall_deadline
        }
    } else {
        None
    };
    WorkerWriteBatchOutcome {
        completions,
        error,
        previous_write_interest,
        write_interest,
        previous_stall_deadline,
        stall_deadline: worker.write_stall_deadline,
    }
}

impl Default for BoundedWorkerOutbox {
    fn default() -> Self {
        Self::new(Arc::new(SupervisorQueueBudget::default()))
    }
}

impl Drop for BoundedWorkerOutbox {
    fn drop(&mut self) {
        self.queue_budget.release(self.retained_items, self.retained_reserved_bytes);
    }
}

struct Worker<P> {
    process: Option<P>,
    reaper_permit: Option<RendererReaperPermit>,
    epoch: u64,
    // Maintained by keyed presentation deltas. Statuses are published every
    // coordinator tick, so they never rescan presentations per worker.
    visible_presentation_count: usize,
    restart_count: u64,
    failure_streak: u32,
    state: RendererWorkerState,
    retry_at: Option<Duration>,
    ready_deadline: Option<Duration>,
    write_stall_deadline: Option<Duration>,
    write_interest_enabled: bool,
    last_error: Option<String>,
    encoder: Option<RendererControlEncoder>,
    decoder: Option<RendererControlIncrementalDecoder>,
    session: Option<RendererControlSessionStateMachine>,
    outbox: BoundedWorkerOutbox,
    effective_user_id: Option<u32>,
    scene_capabilities: Option<RendererSceneCapabilities>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
struct RendererWorkerIdentity {
    workspace_uuid: WorkspaceUuid,
    renderer_epoch: u64,
    process_id: Option<u32>,
    process_instance_token: Option<RendererProcessInstanceToken>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct RendererProcessEventSource {
    control_fd: i32,
    process_id: u32,
    process_instance_token: RendererProcessInstanceToken,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RendererProcessWatchChange {
    Register {
        identity: RendererWorkerIdentity,
        source: RendererProcessEventSource,
        write_enabled: bool,
    },
    SetWriteInterest {
        identity: RendererWorkerIdentity,
        source: RendererProcessEventSource,
        enabled: bool,
    },
    Unregister {
        identity: RendererWorkerIdentity,
        source: RendererProcessEventSource,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum RendererWorkerTimerKind {
    ReadyDeadline,
    WriteStall,
    Restart,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
struct RendererWorkerTimer {
    deadline: Duration,
    workspace_uuid: WorkspaceUuid,
    renderer_epoch: u64,
    kind: RendererWorkerTimerKind,
}

impl RendererWorkerIdentity {
    fn from_worker<P: RendererProcess>(workspace_uuid: WorkspaceUuid, worker: &Worker<P>) -> Self {
        Self {
            workspace_uuid,
            renderer_epoch: worker.epoch,
            process_id: worker.process.as_ref().map(RendererProcess::pid),
            process_instance_token: worker
                .process
                .as_ref()
                .and_then(RendererProcess::process_instance_token),
        }
    }
}

fn take_retired_renderer_process<P: RendererProcess>(
    workspace_uuid: WorkspaceUuid,
    worker: &mut Worker<P>,
) -> Option<RetiredRendererProcess<P>> {
    let identity = RendererWorkerIdentity::from_worker(workspace_uuid, worker);
    let process = worker.process.take()?;
    let permit =
        worker.reaper_permit.take().expect("live renderer process is missing its reaper permit");
    Some(RetiredRendererProcess { identity, process, _permit: permit })
}

struct RetiredRendererProcess<P> {
    identity: RendererWorkerIdentity,
    process: P,
    _permit: RendererReaperPermit,
}

#[derive(Debug, Default, PartialEq, Eq)]
struct RendererRetirementReport {
    unreaped: Vec<RendererWorkerIdentity>,
}

struct RendererReapRequest<P> {
    retired: RetiredRendererProcess<P>,
    completion: SyncSender<RendererWorkerIdentity>,
}

enum RendererReaperCommand<P> {
    Reap(RendererReapRequest<P>),
    Retry,
}

#[derive(Default)]
struct RendererReapLedger {
    identities: Mutex<BTreeSet<RendererWorkerIdentity>>,
    completed: Mutex<VecDeque<RendererWorkerIdentity>>,
    changed: Condvar,
}

impl RendererReapLedger {
    fn begin(&self, identities: impl IntoIterator<Item = RendererWorkerIdentity>) {
        self.identities.lock().unwrap().extend(identities);
    }

    fn complete(&self, identity: RendererWorkerIdentity) {
        if self.identities.lock().unwrap().remove(&identity) {
            self.completed.lock().unwrap().push_back(identity);
            self.changed.notify_all();
        }
    }

    fn acknowledge_completion(&self, identity: RendererWorkerIdentity) {
        self.completed.lock().unwrap().retain(|candidate| *candidate != identity);
    }

    fn take_completed(&self) -> Vec<RendererWorkerIdentity> {
        self.completed.lock().unwrap().drain(..).collect()
    }

    fn wait_until_epoch_quiesced(
        &self,
        workspace_uuid: WorkspaceUuid,
        renderer_epoch: u64,
        timeout: Duration,
    ) -> bool {
        let identities = self.identities.lock().unwrap();
        let (identities, _) = self
            .changed
            .wait_timeout_while(identities, timeout, |identities| {
                identities.iter().any(|identity| {
                    identity.workspace_uuid == workspace_uuid
                        && identity.renderer_epoch == renderer_epoch
                })
            })
            .unwrap();
        !identities.iter().any(|identity| {
            identity.workspace_uuid == workspace_uuid && identity.renderer_epoch == renderer_epoch
        })
    }
}

struct RendererReaperCapacity {
    available: AtomicUsize,
}

struct RendererReaperPermit {
    capacity: Arc<RendererReaperCapacity>,
}

type RendererReaperWake = Arc<dyn Fn() + Send + Sync + 'static>;

impl Drop for RendererReaperPermit {
    fn drop(&mut self) {
        let previous = self.capacity.available.fetch_add(1, Ordering::AcqRel);
        assert!(previous < MAXIMUM_RENDERER_WORKERS, "renderer reaper permit overflow");
    }
}

/// One bounded, supervisor-owned process reaper. Retirement closes every
/// control descriptor and signals every child before handing survivors to
/// this single blocking wait lane. Queue backpressure prevents an unlimited
/// population of forgotten process handles during a failure storm.
struct RendererProcessReaper<P: RendererProcess> {
    sender: Option<SyncSender<RendererReaperCommand<P>>>,
    thread: Option<JoinHandle<()>>,
    capacity: Arc<RendererReaperCapacity>,
    ledger: Arc<RendererReapLedger>,
    retry_queued: Arc<AtomicBool>,
}

impl<P: RendererProcess> RendererProcessReaper<P> {
    fn start(wake: RendererReaperWake) -> io::Result<Self> {
        let (sender, receiver) =
            sync_channel::<RendererReaperCommand<P>>(MAXIMUM_REAPER_QUEUE_LENGTH);
        let ledger = Arc::new(RendererReapLedger::default());
        let reaper_ledger = ledger.clone();
        let retry_queued = Arc::new(AtomicBool::new(false));
        let reaper_retry_queued = retry_queued.clone();
        let thread =
            thread::Builder::new().name("cmux-renderer-reaper".to_owned()).spawn(move || {
                let mut failed = Vec::new();
                while let Ok(command) = receiver.recv() {
                    match command {
                        RendererReaperCommand::Reap(request) => failed.push(request),
                        RendererReaperCommand::Retry => {
                            reaper_retry_queued.store(false, Ordering::Release);
                        }
                    }
                    let mut retry = Vec::new();
                    for mut request in failed.drain(..) {
                        match terminate_and_wait_renderer_process(&mut request.retired.process) {
                            Ok(()) => {
                                reaper_ledger.complete(request.retired.identity);
                                wake();
                                let _ = request.completion.send(request.retired.identity);
                            }
                            Err(error) => {
                                eprintln!(
                                    "failed to reap renderer worker {:?}; retaining ownership: {error}",
                                    request.retired.identity
                                );
                                retry.push(request);
                            }
                        }
                    }
                    failed = retry;
                }
                if !failed.is_empty() {
                    for request in &failed {
                        eprintln!(
                            "renderer reaper stopped while still owning unreaped worker {:?}",
                            request.retired.identity
                        );
                    }
                    // Preserve the child handles and their capacity permits
                    // until process exit. Dropping them here would falsely
                    // claim ownership ended without a successful wait.
                    std::mem::forget(failed);
                }
            })?;
        Ok(Self {
            sender: Some(sender),
            thread: Some(thread),
            capacity: Arc::new(RendererReaperCapacity {
                available: AtomicUsize::new(MAXIMUM_RENDERER_WORKERS),
            }),
            ledger,
            retry_queued,
        })
    }

    fn try_acquire(&self) -> Option<RendererReaperPermit> {
        let mut available = self.capacity.available.load(Ordering::Acquire);
        loop {
            if available == 0 {
                return None;
            }
            match self.capacity.available.compare_exchange_weak(
                available,
                available - 1,
                Ordering::AcqRel,
                Ordering::Acquire,
            ) {
                Ok(_) => {
                    return Some(RendererReaperPermit { capacity: self.capacity.clone() });
                }
                Err(current) => available = current,
            }
        }
    }

    /// Retire a batch with one deadline for the batch, never one timeout per
    /// PID. A single nonblocking probe handles children that already exited;
    /// all remaining waits are blocking waits on the owned reaper thread.
    fn retire(
        &self,
        mut retired: Vec<RetiredRendererProcess<P>>,
        deadline_after: Duration,
    ) -> RendererRetirementReport {
        if retired.is_empty() {
            return RendererRetirementReport::default();
        }

        for retired_process in &mut retired {
            retired_process.process.close_control();
        }
        for retired_process in &mut retired {
            if let Err(error) = retired_process.process.terminate() {
                eprintln!(
                    "failed to terminate renderer worker {:?}: {error}",
                    retired_process.identity
                );
            }
        }

        let mut survivors = Vec::with_capacity(retired.len());
        for mut retired_process in retired {
            match retired_process.process.try_wait() {
                Ok(Some(_)) => {}
                Ok(None) | Err(_) => survivors.push(retired_process),
            }
        }
        if survivors.is_empty() {
            return RendererRetirementReport::default();
        }

        let (completion, completed) = sync_channel(survivors.len());
        let mut outstanding = survivors.iter().map(|entry| entry.identity).collect::<BTreeSet<_>>();
        self.ledger.begin(outstanding.iter().copied());
        let sender = self.sender.as_ref().expect("renderer reaper sender missing");
        for retired_process in survivors {
            let request =
                RendererReapRequest { retired: retired_process, completion: completion.clone() };
            if let Err(error) = sender.try_send(RendererReaperCommand::Reap(request)) {
                let mut request = match error {
                    TrySendError::Full(RendererReaperCommand::Reap(request)) => {
                        debug_assert!(false, "renderer reaper permit invariant was violated");
                        request
                    }
                    TrySendError::Disconnected(RendererReaperCommand::Reap(request)) => request,
                    TrySendError::Full(RendererReaperCommand::Retry)
                    | TrySendError::Disconnected(RendererReaperCommand::Retry) => {
                        unreachable!("reap send returned a retry command")
                    }
                };
                if let Err(wait_error) =
                    terminate_and_wait_renderer_process(&mut request.retired.process)
                {
                    eprintln!(
                        "failed to synchronously reap renderer worker {:?}: {wait_error}",
                        request.retired.identity
                    );
                    // Preserve the child handle and permit. This path is only
                    // reachable after an invariant or thread failure.
                    std::mem::forget(request);
                    continue;
                }
                self.ledger.complete(request.retired.identity);
                self.ledger.acknowledge_completion(request.retired.identity);
                outstanding.remove(&request.retired.identity);
            }
        }
        drop(completion);

        let deadline = Instant::now().checked_add(deadline_after).unwrap_or_else(Instant::now);
        while !outstanding.is_empty() {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                break;
            }
            match completed.recv_timeout(remaining) {
                Ok(identity) => {
                    outstanding.remove(&identity);
                    self.ledger.acknowledge_completion(identity);
                }
                Err(RecvTimeoutError::Timeout | RecvTimeoutError::Disconnected) => break,
            }
        }
        RendererRetirementReport { unreaped: outstanding.into_iter().collect() }
    }

    fn wait_until_epoch_quiesced(
        &self,
        workspace_uuid: WorkspaceUuid,
        renderer_epoch: u64,
        timeout: Duration,
    ) -> bool {
        if !self.retry_queued.swap(true, Ordering::AcqRel) {
            let sent = self
                .sender
                .as_ref()
                .is_some_and(|sender| sender.try_send(RendererReaperCommand::Retry).is_ok());
            if !sent {
                self.retry_queued.store(false, Ordering::Release);
            }
        }
        self.ledger.wait_until_epoch_quiesced(workspace_uuid, renderer_epoch, timeout)
    }

    fn take_completed(&self) -> Vec<RendererWorkerIdentity> {
        self.ledger.take_completed()
    }
}

fn wait_for_renderer_process<P: RendererProcess>(process: &mut P) -> io::Result<()> {
    loop {
        match process.wait() {
            Ok(_) => return Ok(()),
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            #[cfg(unix)]
            Err(error) if error.raw_os_error() == Some(libc::ECHILD) => {
                // The kernel proves this PID is no longer a waitable child.
                return Ok(());
            }
            Err(error) => return Err(error),
        }
    }
}

fn terminate_and_wait_renderer_process<P: RendererProcess>(process: &mut P) -> io::Result<()> {
    // Retrying termination on the reaper lane ensures a transient pre-kill
    // status error cannot put a still-live child at the head of the blocking
    // wait queue. Persistent termination errors retain ownership and allow
    // later requests to proceed.
    process.terminate()?;
    wait_for_renderer_process(process)
}

impl<P: RendererProcess> Drop for RendererProcessReaper<P> {
    fn drop(&mut self) {
        self.sender.take();
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

#[cfg(test)]
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
struct ReconciliationOperationCounts {
    presentation_visits: usize,
    existing_worker_visits: usize,
    desired_workspace_visits: usize,
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
    presentation_counts: BTreeMap<WorkspaceUuid, usize>,
    workers: BTreeMap<WorkspaceUuid, Worker<S::Process>>,
    reaper: RendererProcessReaper<S::Process>,
    queue_budget: Arc<SupervisorQueueBudget>,
    next_epoch: Option<u64>,
    events: VecDeque<RendererSupervisorEvent>,
    timers: BTreeSet<RendererWorkerTimer>,
    process_watch_changes: VecDeque<RendererProcessWatchChange>,
    dirty_statuses: BTreeSet<WorkspaceUuid>,
    #[cfg(test)]
    last_reconciliation_operations: ReconciliationOperationCounts,
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
        queue_budget: Arc<SupervisorQueueBudget>,
        reaper_wake: RendererReaperWake,
    ) -> io::Result<Self> {
        Ok(Self {
            spawner,
            clock,
            daemon_instance_id,
            initial_restart_delay,
            maximum_restart_delay,
            presentations: BTreeMap::new(),
            presentation_counts: BTreeMap::new(),
            workers: BTreeMap::new(),
            reaper: RendererProcessReaper::start(reaper_wake)?,
            queue_budget,
            next_epoch: Some(1),
            events: VecDeque::new(),
            timers: BTreeSet::new(),
            process_watch_changes: VecDeque::new(),
            dirty_statuses: BTreeSet::new(),
            #[cfg(test)]
            last_reconciliation_operations: ReconciliationOperationCounts::default(),
        })
    }

    fn install_worker(&mut self, workspace_uuid: WorkspaceUuid, worker: Worker<S::Process>) {
        debug_assert!(!self.workers.contains_key(&workspace_uuid));
        if let Some(deadline) = worker.ready_deadline {
            self.timers.insert(RendererWorkerTimer {
                deadline,
                workspace_uuid,
                renderer_epoch: worker.epoch,
                kind: RendererWorkerTimerKind::ReadyDeadline,
            });
        }
        if let Some(deadline) = worker.retry_at {
            self.timers.insert(RendererWorkerTimer {
                deadline,
                workspace_uuid,
                renderer_epoch: worker.epoch,
                kind: RendererWorkerTimerKind::Restart,
            });
        }
        if let Some(deadline) = worker.write_stall_deadline {
            self.timers.insert(RendererWorkerTimer {
                deadline,
                workspace_uuid,
                renderer_epoch: worker.epoch,
                kind: RendererWorkerTimerKind::WriteStall,
            });
        }
        if let Some(process) = &worker.process
            && let Some(source) = process.event_source()
        {
            self.process_watch_changes.push_back(RendererProcessWatchChange::Register {
                identity: RendererWorkerIdentity::from_worker(workspace_uuid, &worker),
                source,
                write_enabled: worker.write_interest_enabled,
            });
        }
        self.workers.insert(workspace_uuid, worker);
        self.dirty_statuses.insert(workspace_uuid);
    }

    fn take_worker(&mut self, workspace_uuid: WorkspaceUuid) -> Option<Worker<S::Process>> {
        let worker = self.workers.remove(&workspace_uuid)?;
        if let Some(deadline) = worker.ready_deadline {
            self.timers.remove(&RendererWorkerTimer {
                deadline,
                workspace_uuid,
                renderer_epoch: worker.epoch,
                kind: RendererWorkerTimerKind::ReadyDeadline,
            });
        }
        if let Some(deadline) = worker.retry_at {
            self.timers.remove(&RendererWorkerTimer {
                deadline,
                workspace_uuid,
                renderer_epoch: worker.epoch,
                kind: RendererWorkerTimerKind::Restart,
            });
        }
        if let Some(deadline) = worker.write_stall_deadline {
            self.timers.remove(&RendererWorkerTimer {
                deadline,
                workspace_uuid,
                renderer_epoch: worker.epoch,
                kind: RendererWorkerTimerKind::WriteStall,
            });
        }
        if let Some(process) = &worker.process
            && let Some(source) = process.event_source()
        {
            self.process_watch_changes.push_back(RendererProcessWatchChange::Unregister {
                identity: RendererWorkerIdentity::from_worker(workspace_uuid, &worker),
                source,
            });
        }
        self.dirty_statuses.insert(workspace_uuid);
        Some(worker)
    }

    fn take_process_watch_changes(&mut self) -> Vec<RendererProcessWatchChange> {
        self.process_watch_changes.drain(..).collect()
    }

    #[cfg(target_os = "macos")]
    fn requeue_all_process_watches(&mut self) {
        self.process_watch_changes.clear();
        for (workspace_uuid, worker) in &self.workers {
            if let Some(process) = &worker.process
                && let Some(source) = process.event_source()
            {
                self.process_watch_changes.push_back(RendererProcessWatchChange::Register {
                    identity: RendererWorkerIdentity::from_worker(*workspace_uuid, worker),
                    source,
                    write_enabled: worker.write_interest_enabled,
                });
            }
        }
    }

    fn take_status_changes(&mut self) -> Vec<(WorkspaceUuid, Option<RendererWorkerStatus>)> {
        let now = self.clock.now();
        std::mem::take(&mut self.dirty_statuses)
            .into_iter()
            .map(|workspace_uuid| {
                let status = self
                    .workers
                    .get(&workspace_uuid)
                    .map(|worker| Self::worker_status_at(workspace_uuid, worker, now));
                (workspace_uuid, status)
            })
            .collect()
    }

    #[cfg(test)]
    fn set_presentation_workspace(
        &mut self,
        presentation_id: PresentationId,
        workspace_uuid: Option<WorkspaceUuid>,
    ) {
        self.apply_presentation_changes(BTreeMap::from([(presentation_id, workspace_uuid)]));
    }

    #[cfg(test)]
    fn remove_presentation(&mut self, presentation_id: PresentationId) {
        self.apply_presentation_changes(BTreeMap::from([(presentation_id, None)]));
    }

    #[cfg(test)]
    fn replace_presentations(&mut self, presentations: BTreeMap<PresentationId, WorkspaceUuid>) {
        let mut changes = self
            .presentations
            .keys()
            .filter(|presentation_id| !presentations.contains_key(presentation_id))
            .map(|presentation_id| (*presentation_id, None))
            .collect::<PendingChanges>();
        changes.extend(
            presentations
                .into_iter()
                .map(|(presentation_id, workspace_uuid)| (presentation_id, Some(workspace_uuid))),
        );
        self.apply_presentation_changes(changes);
    }

    #[cfg(test)]
    fn retain_workspaces(&mut self, workspace_uuids: &BTreeSet<WorkspaceUuid>) {
        let changes = self
            .presentations
            .iter()
            .filter_map(|(presentation_id, workspace_uuid)| {
                (!workspace_uuids.contains(workspace_uuid)).then_some((*presentation_id, None))
            })
            .collect();
        self.apply_presentation_changes(changes);
    }

    fn apply_presentation_changes(&mut self, changes: PendingChanges) {
        #[cfg(test)]
        let mut operations = ReconciliationOperationCounts::default();
        let mut touched_workspaces = BTreeSet::new();
        for (presentation_id, next_workspace) in changes {
            #[cfg(test)]
            {
                operations.presentation_visits += 1;
            }
            let previous_workspace = self.presentations.get(&presentation_id).copied();
            if previous_workspace == next_workspace {
                continue;
            }
            if let Some(previous_workspace) = previous_workspace {
                self.presentations.remove(&presentation_id);
                touched_workspaces.insert(previous_workspace);
                let count = self
                    .presentation_counts
                    .get_mut(&previous_workspace)
                    .expect("presentation count must exist for mapped presentation");
                *count = count.checked_sub(1).expect("presentation count cannot underflow");
                if *count == 0 {
                    self.presentation_counts.remove(&previous_workspace);
                }
            }
            if let Some(next_workspace) = next_workspace {
                self.presentations.insert(presentation_id, next_workspace);
                touched_workspaces.insert(next_workspace);
                *self.presentation_counts.entry(next_workspace).or_insert(0) += 1;
            }
        }

        let mut retired = Vec::new();
        let mut unavailable = Vec::new();
        // Free every dormant slot before admitting new desired workers. This
        // makes a move at the worker cap independent of UUID sort order.
        let dormant_workspaces = touched_workspaces
            .iter()
            .copied()
            .filter(|workspace| !self.presentation_counts.contains_key(workspace))
            .collect::<Vec<_>>();
        for workspace in dormant_workspaces {
            if let Some(mut worker) = self.take_worker(workspace) {
                worker.outbox.fail_publications("workspace visibility retired the renderer worker");
                #[cfg(test)]
                {
                    operations.existing_worker_visits += 1;
                }
                let identity = RendererWorkerIdentity::from_worker(workspace, &worker);
                if let Some(retired_process) = take_retired_renderer_process(workspace, &mut worker)
                {
                    retired.push(retired_process);
                }
                unavailable.push(identity);
            }
        }
        // Release permits for children that have already exited before
        // admitting replacements. Survivors keep their permits in the owned
        // reaper, so churn cannot exceed the live-plus-unreaped cap.
        let retirement = self.reaper.retire(retired, COORDINATOR_RETIREMENT_DEADLINE);
        let desired_touched_workspaces = touched_workspaces
            .into_iter()
            .filter(|workspace| self.presentation_counts.contains_key(workspace))
            .collect::<Vec<_>>();
        for workspace in desired_touched_workspaces {
            let visible_presentation_count = self.presentation_counts[&workspace];
            #[cfg(test)]
            {
                operations.desired_workspace_visits += 1;
            }
            if let Some(worker) = self.workers.get_mut(&workspace) {
                #[cfg(test)]
                {
                    operations.existing_worker_visits += 1;
                }
                worker.visible_presentation_count = visible_presentation_count;
                self.dirty_statuses.insert(workspace);
            } else if self.workers.len() < MAXIMUM_RENDERER_WORKERS {
                self.spawn_initial(workspace, visible_presentation_count);
            }
        }
        for identity in unavailable {
            let mut reason = "workspace is no longer visible".to_owned();
            if retirement.unreaped.contains(&identity) {
                reason.push_str("; renderer reap deferred after global retirement deadline");
            }
            self.events.push_back(RendererSupervisorEvent::WorkerUnavailable {
                workspace_uuid: identity.workspace_uuid,
                renderer_epoch: identity.renderer_epoch,
                process_id: identity.process_id,
                process_instance_token: identity.process_instance_token,
                status: None,
                quiesced: !retirement.unreaped.contains(&identity),
                reason,
            });
        }
        #[cfg(test)]
        {
            self.last_reconciliation_operations = operations;
        }
    }

    fn allocate_epoch(&mut self) -> Result<u64, RendererSupervisorError> {
        let epoch = self.next_epoch.ok_or(RendererSupervisorError::EpochExhausted)?;
        self.next_epoch = epoch.checked_add(1);
        Ok(epoch)
    }

    fn spawn_initial(&mut self, workspace_uuid: WorkspaceUuid, visible_presentation_count: usize) {
        match self.allocate_epoch() {
            Ok(epoch) => {
                let outbox = BoundedWorkerOutbox::new(self.queue_budget.clone());
                let mut worker = self.spawn_worker(workspace_uuid, epoch, 0, 0, outbox);
                worker.visible_presentation_count = visible_presentation_count;
                self.install_worker(workspace_uuid, worker);
            }
            Err(error) => {
                self.install_worker(
                    workspace_uuid,
                    Worker {
                        process: None,
                        reaper_permit: None,
                        epoch: u64::MAX,
                        visible_presentation_count,
                        restart_count: 0,
                        failure_streak: 1,
                        state: RendererWorkerState::Backoff,
                        retry_at: None,
                        ready_deadline: None,
                        write_stall_deadline: None,
                        write_interest_enabled: false,
                        last_error: Some(error.to_string()),
                        encoder: None,
                        decoder: None,
                        session: None,
                        outbox: BoundedWorkerOutbox::new(self.queue_budget.clone()),
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
        mut outbox: BoundedWorkerOutbox,
    ) -> Worker<S::Process> {
        let request = SpawnRequest {
            daemon_instance_id: self.daemon_instance_id,
            workspace_uuid,
            renderer_epoch: epoch,
        };
        let Some(reaper_permit) = self.reaper.try_acquire() else {
            return self.backoff_worker(
                workspace_uuid,
                epoch,
                restart_count.saturating_add(1),
                failure_streak.saturating_add(1),
                "renderer process capacity is held by unreaped workers".to_owned(),
                outbox,
            );
        };
        match self.spawner.spawn(&request) {
            Ok(process) => {
                let mut encoder =
                    RendererControlEncoder::new(RendererControlDirection::DaemonToWorker);
                let session = RendererControlSessionStateMachine::new();
                let bootstrap = RendererControlMessage::Bootstrap(RendererBootstrap {
                    daemon_instance_id: self.daemon_instance_id.as_uuid(),
                    workspace_id: workspace_uuid.as_uuid(),
                    renderer_epoch: epoch,
                });
                let bootstrap_result = encoder
                    .encode(bootstrap)
                    .map_err(RendererSupervisorError::from)
                    .and_then(|frame| {
                        outbox.install_bootstrap(frame)?;
                        Ok(())
                    });
                match bootstrap_result {
                    Ok(()) => {
                        let mut worker = Worker {
                            process: Some(process),
                            reaper_permit: Some(reaper_permit),
                            epoch,
                            visible_presentation_count: 0,
                            restart_count,
                            failure_streak,
                            state: RendererWorkerState::Starting,
                            retry_at: None,
                            ready_deadline: Some(
                                self.clock.now().saturating_add(WORKER_READY_TIMEOUT),
                            ),
                            write_stall_deadline: None,
                            write_interest_enabled: true,
                            last_error: None,
                            encoder: Some(encoder),
                            decoder: Some(RendererControlIncrementalDecoder::new(
                                RendererControlDirection::WorkerToDaemon,
                            )),
                            session: Some(session),
                            outbox,
                            effective_user_id: None,
                            scene_capabilities: None,
                        };
                        let outcome = flush_worker_write_batch(&mut worker, self.clock.now());
                        debug_assert!(outcome.completions.is_empty());
                        if let Some(error) = outcome.error {
                            let identity =
                                RendererWorkerIdentity::from_worker(workspace_uuid, &worker);
                            let process = worker.process.take().unwrap();
                            let permit = worker.reaper_permit.take().unwrap();
                            worker.outbox.discard_pending_frame();
                            let retained_outbox = std::mem::replace(
                                &mut worker.outbox,
                                BoundedWorkerOutbox::new(self.queue_budget.clone()),
                            );
                            drop(worker);
                            let retirement = self.reaper.retire(
                                vec![RetiredRendererProcess { identity, process, _permit: permit }],
                                COORDINATOR_RETIREMENT_DEADLINE,
                            );
                            let diagnostic = if retirement.unreaped.contains(&identity) {
                                format!(
                                    "{}; renderer reap deferred after global retirement deadline",
                                    error
                                )
                            } else {
                                error.to_string()
                            };
                            self.backoff_worker(
                                workspace_uuid,
                                epoch,
                                restart_count.saturating_add(1),
                                failure_streak.saturating_add(1),
                                diagnostic,
                                retained_outbox,
                            )
                        } else {
                            worker
                        }
                    }
                    Err(error) => {
                        let identity = RendererWorkerIdentity {
                            workspace_uuid,
                            renderer_epoch: epoch,
                            process_id: Some(process.pid()),
                            process_instance_token: process.process_instance_token(),
                        };
                        let retirement = self.reaper.retire(
                            vec![RetiredRendererProcess {
                                identity,
                                process,
                                _permit: reaper_permit,
                            }],
                            COORDINATOR_RETIREMENT_DEADLINE,
                        );
                        let diagnostic = if retirement.unreaped.contains(&identity) {
                            format!(
                                "{}; renderer reap deferred after global retirement deadline",
                                error
                            )
                        } else {
                            error.to_string()
                        };
                        self.backoff_worker(
                            workspace_uuid,
                            epoch,
                            restart_count.saturating_add(1),
                            failure_streak.saturating_add(1),
                            diagnostic,
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
        outbox: BoundedWorkerOutbox,
    ) -> Worker<S::Process> {
        let delay = restart_delay(
            workspace_uuid,
            failure_streak,
            self.initial_restart_delay,
            self.maximum_restart_delay,
        );
        Worker {
            process: None,
            reaper_permit: None,
            epoch,
            visible_presentation_count: 0,
            restart_count,
            failure_streak,
            state: RendererWorkerState::Backoff,
            retry_at: Some(self.clock.now().saturating_add(delay)),
            ready_deadline: None,
            write_stall_deadline: None,
            write_interest_enabled: false,
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
        {
            let worker = self
                .workers
                .get_mut(&workspace_uuid)
                .ok_or(RendererSupervisorError::UnknownWorkspace(workspace_uuid))?;
            worker.outbox.try_push(message)?;
        }
        self.flush_worker_writes(workspace_uuid)
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
            worker.outbox.try_extend(messages)?;
            Ok::<(), RendererSupervisorError>(())
        })();
        let result = result.and_then(|()| self.flush_worker_writes(workspace_uuid));
        if let Err(error) = result {
            self.worker_failed(workspace_uuid, error.to_string());
        }
    }

    fn publish_if_epoch(
        &mut self,
        workspace_uuid: WorkspaceUuid,
        renderer_epoch: u64,
        messages: Vec<RendererControlMessage>,
        completion: RendererPublicationCompletion,
    ) {
        let mut completion = Some(completion);
        let admission = (|| {
            let worker = self
                .workers
                .get_mut(&workspace_uuid)
                .ok_or(RendererSupervisorError::UnknownWorkspace(workspace_uuid))?;
            if worker.epoch != renderer_epoch || worker.state != RendererWorkerState::Ready {
                return Err(RendererSupervisorError::WorkerNotReady(workspace_uuid));
            }
            worker.outbox.try_extend(messages)?;
            worker
                .outbox
                .attach_completion_to_back(completion.take().expect("publication completion"));
            Ok::<(), RendererSupervisorError>(())
        })();
        if let Err(error) = admission {
            // Admission is all-or-nothing. No byte from this publication can
            // be visible when its completion remains local to this scope.
            completion.take().expect("rejected publication completion").complete(Err(error));
            return;
        }
        if let Err(error) = self.flush_worker_writes(workspace_uuid) {
            self.worker_failed(workspace_uuid, error.to_string());
        }
    }

    fn flush_worker_writes(
        &mut self,
        workspace_uuid: WorkspaceUuid,
    ) -> Result<(), RendererSupervisorError> {
        let now = self.clock.now();
        let (outcome, identity, source, status) = {
            let worker = self
                .workers
                .get_mut(&workspace_uuid)
                .ok_or(RendererSupervisorError::UnknownWorkspace(workspace_uuid))?;
            if worker.process.is_none() {
                return Ok(());
            }
            let identity = RendererWorkerIdentity::from_worker(workspace_uuid, worker);
            let source = worker.process.as_ref().and_then(RendererProcess::event_source);
            let outcome = flush_worker_write_batch(worker, now);
            let status = (!outcome.completions.is_empty())
                .then(|| Self::worker_status_at(workspace_uuid, worker, now));
            (outcome, identity, source, status)
        };

        for completion in outcome.completions {
            completion.complete(Ok(status.as_ref().unwrap().clone()));
        }
        let write_error = outcome.error;
        if outcome.previous_stall_deadline != outcome.stall_deadline {
            if let Some(deadline) = outcome.previous_stall_deadline {
                self.timers.remove(&RendererWorkerTimer {
                    deadline,
                    workspace_uuid,
                    renderer_epoch: identity.renderer_epoch,
                    kind: RendererWorkerTimerKind::WriteStall,
                });
            }
            if let Some(deadline) = outcome.stall_deadline {
                self.timers.insert(RendererWorkerTimer {
                    deadline,
                    workspace_uuid,
                    renderer_epoch: identity.renderer_epoch,
                    kind: RendererWorkerTimerKind::WriteStall,
                });
            }
        }
        if outcome.previous_write_interest != outcome.write_interest
            && let Some(source) = source
        {
            self.process_watch_changes.push_back(RendererProcessWatchChange::SetWriteInterest {
                identity,
                source,
                enabled: outcome.write_interest,
            });
        }
        match write_error {
            Some(error) => Err(error),
            None => Ok(()),
        }
    }

    fn retire_if_epoch(
        &mut self,
        workspace_uuid: WorkspaceUuid,
        renderer_epoch: u64,
    ) -> Result<bool, RendererSupervisorError> {
        let Some(current) = self.workers.get(&workspace_uuid) else {
            return Ok(self.reaper.wait_until_epoch_quiesced(
                workspace_uuid,
                renderer_epoch,
                WORKER_RETIREMENT_DEADLINE,
            ));
        };
        if current.epoch != renderer_epoch {
            return Ok(self.reaper.wait_until_epoch_quiesced(
                workspace_uuid,
                renderer_epoch,
                WORKER_RETIREMENT_DEADLINE,
            ));
        }
        if current.process.is_none() {
            return Ok(self.reaper.wait_until_epoch_quiesced(
                workspace_uuid,
                renderer_epoch,
                WORKER_RETIREMENT_DEADLINE,
            ));
        }

        let mut previous = self
            .take_worker(workspace_uuid)
            .ok_or(RendererSupervisorError::UnknownWorkspace(workspace_uuid))?;
        previous.outbox.fail_publications("renderer worker retired by exact lifetime fence");
        let identity = RendererWorkerIdentity::from_worker(workspace_uuid, &previous);
        let retired = take_retired_renderer_process(workspace_uuid, &mut previous)
            .into_iter()
            .collect::<Vec<_>>();
        let visible_presentation_count = previous.visible_presentation_count;
        if self.presentation_counts.contains_key(&workspace_uuid) {
            let outbox = BoundedWorkerOutbox::new(self.queue_budget.clone());
            let mut backoff = self.backoff_worker(
                workspace_uuid,
                renderer_epoch,
                previous.restart_count.saturating_add(1),
                previous.failure_streak.saturating_add(1),
                "renderer worker retired by exact lifetime fence".to_owned(),
                outbox,
            );
            backoff.visible_presentation_count = visible_presentation_count;
            self.install_worker(workspace_uuid, backoff);
        }
        let retirement = self.reaper.retire(retired, WORKER_RETIREMENT_DEADLINE);
        let quiesced = !retirement.unreaped.contains(&identity);
        self.events.push_back(RendererSupervisorEvent::WorkerUnavailable {
            workspace_uuid,
            renderer_epoch,
            process_id: identity.process_id,
            process_instance_token: identity.process_instance_token,
            status: self.workspace_status(workspace_uuid),
            quiesced,
            reason: "renderer worker retired by exact lifetime fence".to_owned(),
        });
        Ok(quiesced)
    }

    fn take_events(&mut self) -> Vec<RendererSupervisorEvent> {
        self.events.drain(..).collect()
    }

    fn publish_reaper_completions(&mut self) {
        for identity in self.reaper.take_completed() {
            self.events.push_back(RendererSupervisorEvent::WorkerUnavailable {
                workspace_uuid: identity.workspace_uuid,
                renderer_epoch: identity.renderer_epoch,
                process_id: identity.process_id,
                process_instance_token: identity.process_instance_token,
                status: self.workspace_status(identity.workspace_uuid),
                quiesced: true,
                reason: "deferred renderer reap completed".to_owned(),
            });
        }
    }

    fn tick(&mut self) {
        #[cfg(any(test, not(target_os = "macos")))]
        self.poll_all_workers();
        self.process_due_timers();
    }

    fn poll_all_workers(&mut self) {
        let workspaces = self.workers.keys().copied().collect::<Vec<_>>();
        let mut failures = Vec::new();
        for workspace_uuid in workspaces {
            if let Some(error) = self.service_worker(workspace_uuid) {
                failures.push((workspace_uuid, error));
            }
        }
        self.workers_failed(failures);
    }

    fn process_worker_event(&mut self, identity: RendererWorkerIdentity) {
        let is_current = self.workers.get(&identity.workspace_uuid).is_some_and(|worker| {
            worker.epoch == identity.renderer_epoch
                && worker.process.as_ref().map(RendererProcess::pid) == identity.process_id
                && worker.process.as_ref().and_then(RendererProcess::process_instance_token)
                    == identity.process_instance_token
        });
        if !is_current {
            return;
        }
        if let Some(error) = self.service_worker(identity.workspace_uuid) {
            self.worker_failed(identity.workspace_uuid, error);
        }
    }

    fn service_worker(&mut self, workspace_uuid: WorkspaceUuid) -> Option<String> {
        let (poll_error, write_serviced) = self.poll_worker(workspace_uuid);
        if let Some(error) = poll_error {
            return Some(error);
        }
        if write_serviced {
            return None;
        }
        self.flush_worker_writes(workspace_uuid).err().map(|error| error.to_string())
    }

    fn process_due_timers(&mut self) {
        let now = self.clock.now();
        let mut expired = Vec::new();
        let mut due_restarts = Vec::new();
        while let Some(timer) = self.timers.first().copied() {
            if timer.deadline > now {
                break;
            }
            self.timers.remove(&timer);
            let Some(worker) = self.workers.get(&timer.workspace_uuid) else {
                continue;
            };
            if worker.epoch != timer.renderer_epoch {
                continue;
            }
            match timer.kind {
                RendererWorkerTimerKind::ReadyDeadline
                    if worker.state == RendererWorkerState::Starting
                        && worker.ready_deadline == Some(timer.deadline) =>
                {
                    expired.push((
                        timer.workspace_uuid,
                        "renderer worker did not become ready before deadline".to_owned(),
                    ));
                }
                RendererWorkerTimerKind::Restart
                    if worker.state == RendererWorkerState::Backoff
                        && worker.retry_at == Some(timer.deadline) =>
                {
                    due_restarts.push(timer.workspace_uuid);
                }
                RendererWorkerTimerKind::WriteStall
                    if worker.write_stall_deadline == Some(timer.deadline)
                        && worker.outbox.has_writable_output(worker.state) =>
                {
                    expired.push((
                        timer.workspace_uuid,
                        "renderer worker write stalled under control-socket backpressure"
                            .to_owned(),
                    ));
                }
                _ => {}
            }
        }
        self.workers_failed(expired);
        for workspace_uuid in due_restarts {
            self.restart_worker(workspace_uuid);
        }
    }

    fn poll_worker(&mut self, workspace_uuid: WorkspaceUuid) -> (Option<String>, bool) {
        let mut received = Vec::new();
        let outcome = {
            let Some(worker) = self.workers.get_mut(&workspace_uuid) else {
                return (None, false);
            };
            let Some(process) = worker.process.as_mut() else {
                return (None, false);
            };
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
            return (Some(error), false);
        }
        if received.is_empty() {
            return (None, false);
        }
        let envelopes = {
            let worker = self.workers.get_mut(&workspace_uuid).unwrap();
            worker.decoder.as_mut().unwrap().feed(&received)
        };
        match envelopes {
            Ok(envelopes) => {
                let mut write_serviced = false;
                for envelope in envelopes {
                    let is_ready = matches!(&envelope.message, RendererControlMessage::Ready(_));
                    let (epoch, pid) = {
                        let worker = self.workers.get(&workspace_uuid).unwrap();
                        (worker.epoch, worker.process.as_ref().unwrap().pid())
                    };
                    if let Err(error) =
                        self.accept_worker_envelope(workspace_uuid, epoch, pid, envelope)
                    {
                        return (Some(error.to_string()), write_serviced || is_ready);
                    }
                    write_serviced |= is_ready;
                }
                (None, write_serviced)
            }
            Err(error) => (Some(error.to_string()), false),
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
        let process_instance_token =
            worker.process.as_ref().and_then(RendererProcess::process_instance_token).ok_or_else(
                || {
                    RendererSupervisorError::Io(
                        "renderer process-instance token is unavailable".to_owned(),
                    )
                },
            )?;
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
                if let Some(deadline) = worker.ready_deadline.take() {
                    self.timers.remove(&RendererWorkerTimer {
                        deadline,
                        workspace_uuid,
                        renderer_epoch,
                        kind: RendererWorkerTimerKind::ReadyDeadline,
                    });
                }
                worker.failure_streak = 0;
                worker.last_error = None;
                worker.effective_user_id = Some(ready.effective_user_id);
                worker.scene_capabilities = Some(ready.scene_capabilities);
                self.dirty_statuses.insert(workspace_uuid);
                self.flush_worker_writes(workspace_uuid)?;
                let status = self
                    .workspace_status(workspace_uuid)
                    .ok_or(RendererSupervisorError::UnknownWorkspace(workspace_uuid))?;
                self.events.push_back(RendererSupervisorEvent::WorkerReady {
                    workspace_uuid,
                    renderer_epoch,
                    process_id: pid,
                    process_instance_token,
                    effective_user_id: ready.effective_user_id,
                    scene_capabilities: ready.scene_capabilities,
                    status,
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
                let effective_user_id = worker.effective_user_id.ok_or_else(|| {
                    RendererSupervisorError::Io(
                        "renderer presentation became ready before its authenticated handshake"
                            .to_owned(),
                    )
                })?;
                self.events.push_back(RendererSupervisorEvent::PresentationReady {
                    workspace_uuid,
                    renderer_epoch,
                    process_id: pid,
                    process_instance_token,
                    effective_user_id,
                    metrics,
                });
            }
            RendererControlMessage::PresentationRemoved(removal) => {
                self.events.push_back(RendererSupervisorEvent::PresentationRemoved {
                    workspace_uuid,
                    renderer_epoch,
                    process_id: pid,
                    removal,
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
        self.workers_failed(vec![(workspace_uuid, error)]);
    }

    fn workers_failed(&mut self, failures: Vec<(WorkspaceUuid, String)>) {
        let mut retired = Vec::new();
        let mut unavailable = Vec::new();
        for (workspace_uuid, error) in failures {
            let Some(mut previous) = self.take_worker(workspace_uuid) else {
                continue;
            };
            previous.outbox.fail_publications(&error);
            let identity = RendererWorkerIdentity::from_worker(workspace_uuid, &previous);
            if let Some(retired_process) =
                take_retired_renderer_process(workspace_uuid, &mut previous)
            {
                retired.push(retired_process);
            }
            let outbox = BoundedWorkerOutbox::new(self.queue_budget.clone());
            let mut backoff = self.backoff_worker(
                workspace_uuid,
                previous.epoch,
                previous.restart_count.saturating_add(1),
                previous.failure_streak.saturating_add(1),
                error.clone(),
                outbox,
            );
            backoff.visible_presentation_count = previous.visible_presentation_count;
            self.install_worker(workspace_uuid, backoff);
            unavailable.push((identity, error));
        }
        let retirement = self.reaper.retire(retired, COORDINATOR_RETIREMENT_DEADLINE);
        for (identity, mut reason) in unavailable {
            if retirement.unreaped.contains(&identity) {
                reason.push_str("; renderer reap deferred after global retirement deadline");
            }
            self.events.push_back(RendererSupervisorEvent::WorkerUnavailable {
                workspace_uuid: identity.workspace_uuid,
                renderer_epoch: identity.renderer_epoch,
                process_id: identity.process_id,
                process_instance_token: identity.process_instance_token,
                status: self.workspace_status(identity.workspace_uuid),
                quiesced: !retirement.unreaped.contains(&identity),
                reason,
            });
        }
    }

    fn restart_worker(&mut self, workspace_uuid: WorkspaceUuid) {
        let Some(previous) = self.take_worker(workspace_uuid) else { return };
        let epoch = match self.allocate_epoch() {
            Ok(epoch) => epoch,
            Err(error) => {
                let outbox = BoundedWorkerOutbox::new(self.queue_budget.clone());
                let mut worker = self.backoff_worker(
                    workspace_uuid,
                    previous.epoch,
                    previous.restart_count,
                    previous.failure_streak,
                    error.to_string(),
                    outbox,
                );
                worker.visible_presentation_count = previous.visible_presentation_count;
                self.install_worker(workspace_uuid, worker);
                return;
            }
        };
        let outbox = BoundedWorkerOutbox::new(self.queue_budget.clone());
        let mut worker = self.spawn_worker(
            workspace_uuid,
            epoch,
            previous.restart_count,
            previous.failure_streak,
            outbox,
        );
        worker.visible_presentation_count = previous.visible_presentation_count;
        self.install_worker(workspace_uuid, worker);
    }

    fn next_wake_after(&self) -> Duration {
        let now = self.clock.now();
        self.timers.first().map(|timer| timer.deadline.saturating_sub(now)).unwrap_or(Duration::MAX)
    }

    fn statuses(&self) -> Vec<RendererWorkerStatus> {
        self.status_snapshot().0
    }

    fn workspace_status(&self, workspace_uuid: WorkspaceUuid) -> Option<RendererWorkerStatus> {
        let worker = self.workers.get(&workspace_uuid)?;
        Some(Self::worker_status_at(workspace_uuid, worker, self.clock.now()))
    }

    fn status_snapshot(&self) -> (Vec<RendererWorkerStatus>, usize) {
        let now = self.clock.now();
        let mut worker_visits = 0;
        let statuses = self
            .workers
            .iter()
            .map(|(workspace_uuid, worker)| {
                worker_visits += 1;
                Self::worker_status_at(*workspace_uuid, worker, now)
            })
            .collect();
        (statuses, worker_visits)
    }

    fn worker_status_at(
        workspace_uuid: WorkspaceUuid,
        worker: &Worker<S::Process>,
        now: Duration,
    ) -> RendererWorkerStatus {
        let process_instance_token =
            worker.process.as_ref().and_then(RendererProcess::process_instance_token);
        RendererWorkerStatus {
            workspace_uuid,
            renderer_epoch: worker.epoch,
            pid: worker.process.as_ref().map(RendererProcess::pid),
            process_start_time_seconds: process_instance_token
                .map(|token| token.start_time_seconds),
            process_start_time_microseconds: process_instance_token
                .map(|token| token.start_time_microseconds),
            restart_count: worker.restart_count,
            visible_presentation_count: worker.visible_presentation_count,
            state: worker.state,
            retry_after_milliseconds: worker
                .retry_at
                .map(|retry_at| duration_milliseconds(retry_at.saturating_sub(now))),
            last_error: worker.last_error.clone(),
            effective_user_id: worker.effective_user_id,
            scene_capabilities: worker.scene_capabilities.map(|value| value.bits()),
        }
    }

    fn shutdown(&mut self) {
        let mut workers = std::mem::take(&mut self.workers);
        for worker in workers.values_mut() {
            worker.outbox.fail_publications("renderer supervisor is shutting down");
        }
        self.presentations.clear();
        self.presentation_counts.clear();
        let retired = workers
            .into_iter()
            .filter_map(|(workspace_uuid, mut worker)| {
                take_retired_renderer_process(workspace_uuid, &mut worker)
            })
            .collect();
        let retirement = self.reaper.retire(retired, WORKER_RETIREMENT_DEADLINE);
        for identity in retirement.unreaped {
            eprintln!(
                "cmux renderer worker {} epoch {} pid {:?} exceeded the global reap deadline; background reaper owns it",
                identity.workspace_uuid, identity.renderer_epoch, identity.process_id
            );
        }
    }
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

#[cfg(target_os = "macos")]
fn renderer_process_instance_token(pid: u32) -> io::Result<Option<RendererProcessInstanceToken>> {
    let process_id = libc::pid_t::try_from(pid)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "renderer PID is out of range"))?;
    let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
    let expected_size = size_of::<libc::proc_bsdinfo>();
    let actual_size = unsafe {
        libc::proc_pidinfo(
            process_id,
            libc::PROC_PIDTBSDINFO,
            0,
            (&mut info as *mut libc::proc_bsdinfo).cast(),
            expected_size as libc::c_int,
        )
    };
    if actual_size != expected_size as libc::c_int || info.pbi_pid != pid {
        let error = io::Error::last_os_error();
        return Err(if actual_size <= 0 {
            error
        } else {
            io::Error::new(io::ErrorKind::InvalidData, "renderer process identity was truncated")
        });
    }
    Ok(Some(RendererProcessInstanceToken {
        start_time_seconds: info.pbi_start_tvsec,
        start_time_microseconds: info.pbi_start_tvusec,
    }))
}

#[cfg(all(unix, not(target_os = "macos")))]
fn renderer_process_instance_token(_pid: u32) -> io::Result<Option<RendererProcessInstanceToken>> {
    Ok(None)
}

#[cfg(unix)]
struct CommandRendererSpawner {
    executable: PathBuf,
}

#[cfg(unix)]
struct UnpublishedRendererChild {
    child: Option<Child>,
}

#[cfg(unix)]
impl UnpublishedRendererChild {
    fn new(child: Child) -> Self {
        Self { child: Some(child) }
    }

    fn child(&mut self) -> &mut Child {
        self.child.as_mut().unwrap()
    }

    fn publish(mut self) -> Child {
        self.child.take().unwrap()
    }
}

#[cfg(unix)]
impl Drop for UnpublishedRendererChild {
    fn drop(&mut self) {
        let Some(mut child) = self.child.take() else { return };
        kill_and_reap_renderer_child(&mut child, "unpublished renderer child");
    }
}

#[cfg(unix)]
fn kill_and_reap_renderer_child(child: &mut Child, owner: &str) {
    loop {
        match child.try_wait() {
            Ok(Some(_)) => return,
            Ok(None) => break,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) if error.raw_os_error() == Some(libc::ECHILD) => return,
            // A failed status probe is not evidence that the child exited. Keep
            // the fail-closed kill-and-wait path below.
            Err(_) => break,
        }
    }

    loop {
        match child.kill() {
            Ok(()) => break,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error)
                if matches!(error.raw_os_error(), Some(libc::ECHILD) | Some(libc::ESRCH)) =>
            {
                break;
            }
            Err(error) => {
                eprintln!("failed to kill {owner} {}: {error}", child.id());
                break;
            }
        }
    }

    loop {
        match child.wait() {
            Ok(_) => return,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) if error.raw_os_error() == Some(libc::ECHILD) => return,
            Err(error) => {
                eprintln!("failed to reap {owner} {}: {error}", child.id());
                return;
            }
        }
    }
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
        let mut unpublished = UnpublishedRendererChild::new(command.spawn()?);
        let process_instance_token = renderer_process_instance_token(unpublished.child().id())?;
        if let Some(status) = unpublished.child().try_wait()? {
            return Err(io::Error::other(format!(
                "renderer exited before process identity publication with {status}"
            )));
        }
        drop(worker_fd);
        let stream = std::os::unix::net::UnixStream::from(daemon_fd);
        #[cfg(target_vendor = "apple")]
        {
            let enabled: libc::c_int = 1;
            if unsafe {
                libc::setsockopt(
                    stream.as_raw_fd(),
                    libc::SOL_SOCKET,
                    libc::SO_NOSIGPIPE,
                    (&enabled as *const libc::c_int).cast(),
                    size_of::<libc::c_int>() as libc::socklen_t,
                )
            } < 0
            {
                return Err(io::Error::last_os_error());
            }
        }
        stream.set_nonblocking(true)?;
        Ok(CommandRendererProcess {
            child: unpublished.publish(),
            stream: Some(stream),
            process_instance_token,
        })
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
    stream: Option<std::os::unix::net::UnixStream>,
    process_instance_token: Option<RendererProcessInstanceToken>,
}

#[cfg(unix)]
impl RendererProcess for CommandRendererProcess {
    fn pid(&self) -> u32 {
        self.child.id()
    }

    fn process_instance_token(&self) -> Option<RendererProcessInstanceToken> {
        self.process_instance_token
    }

    fn event_source(&self) -> Option<RendererProcessEventSource> {
        use std::os::fd::AsRawFd;

        self.stream.as_ref().zip(self.process_instance_token).map(|(stream, token)| {
            RendererProcessEventSource {
                control_fd: stream.as_raw_fd(),
                process_id: self.child.id(),
                process_instance_token: token,
            }
        })
    }

    fn write_nonblocking(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.stream
            .as_mut()
            .ok_or_else(|| io::Error::new(io::ErrorKind::BrokenPipe, "renderer control closed"))?
            .write(bytes)
    }

    fn receive(&mut self, destination: &mut Vec<u8>) -> io::Result<ReceiveResult> {
        use std::os::fd::AsRawFd;

        let mut buffer = [0_u8; 64 * 1024];
        while destination.len() < MAXIMUM_WORKER_RECEIVE_BATCH_BYTES {
            let remaining = MAXIMUM_WORKER_RECEIVE_BATCH_BYTES - destination.len();
            let receive_length = remaining.min(buffer.len());
            let count = unsafe {
                libc::recv(
                    self.stream
                        .as_ref()
                        .ok_or_else(|| {
                            io::Error::new(io::ErrorKind::BrokenPipe, "renderer control closed")
                        })?
                        .as_raw_fd(),
                    buffer.as_mut_ptr().cast(),
                    receive_length,
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
        Ok(ReceiveResult::Open)
    }

    fn try_wait(&mut self) -> io::Result<Option<ExitStatus>> {
        self.child.try_wait()
    }

    fn wait(&mut self) -> io::Result<ExitStatus> {
        self.child.wait()
    }

    fn close_control(&mut self) {
        self.stream.take();
    }

    fn terminate(&mut self) -> io::Result<()> {
        loop {
            match self.child.try_wait() {
                Ok(Some(_)) => return Ok(()),
                Ok(None) => break,
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(error) if error.raw_os_error() == Some(libc::ECHILD) => return Ok(()),
                // A status-probe error is not evidence that the child exited.
                // Continue to the fail-closed SIGKILL path.
                Err(_) => break,
            }
        }
        self.child.kill()
    }
}

#[cfg(unix)]
impl Drop for CommandRendererProcess {
    fn drop(&mut self) {
        self.stream.take();
        kill_and_reap_renderer_child(&mut self.child, "renderer worker");
    }
}

#[cfg(not(unix))]
struct UnsupportedRendererProcess;

#[cfg(not(unix))]
impl RendererProcess for UnsupportedRendererProcess {
    fn pid(&self) -> u32 {
        0
    }
    fn write_nonblocking(&mut self, _bytes: &[u8]) -> io::Result<usize> {
        Err(io::Error::new(io::ErrorKind::Unsupported, "unsupported"))
    }
    fn receive(&mut self, _destination: &mut Vec<u8>) -> io::Result<ReceiveResult> {
        Err(io::Error::new(io::ErrorKind::Unsupported, "unsupported"))
    }
    fn try_wait(&mut self) -> io::Result<Option<ExitStatus>> {
        Err(io::Error::new(io::ErrorKind::Unsupported, "unsupported"))
    }
    fn wait(&mut self) -> io::Result<ExitStatus> {
        Err(io::Error::new(io::ErrorKind::Unsupported, "unsupported"))
    }
    fn close_control(&mut self) {}
    fn terminate(&mut self) -> io::Result<()> {
        Ok(())
    }
}

#[cfg(all(test, unix))]
mod tests {
    use std::collections::BTreeMap;
    use std::ffi::{OsStr, OsString};
    #[cfg(target_os = "macos")]
    use std::io::Read;
    #[cfg(target_os = "macos")]
    use std::os::fd::AsRawFd;
    use std::str::FromStr;
    use std::sync::{Arc, Mutex};

    use std::os::unix::process::ExitStatusExt;

    use crate::renderer_control::{
        RendererColorSpace, RendererFrameRelease, RendererNeedsFullSceneReason,
        RendererPixelFormat, RendererPresentationAttachment, RendererPresentationRemoval,
        RendererSceneCapabilities, RendererSemanticScene, RendererWorkerReady,
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

    #[test]
    fn published_backoff_status_adjusts_its_debug_countdown_at_read_time() {
        let published_at = Instant::now();
        let published = PublishedRendererWorkerStatus {
            status: RendererWorkerStatus {
                workspace_uuid: WorkspaceUuid::new(),
                renderer_epoch: 3,
                pid: None,
                process_start_time_seconds: None,
                process_start_time_microseconds: None,
                effective_user_id: None,
                scene_capabilities: None,
                restart_count: 2,
                visible_presentation_count: 1,
                state: RendererWorkerState::Backoff,
                retry_after_milliseconds: Some(100),
                last_error: Some("crashed".to_owned()),
            },
            published_at,
        };

        assert_eq!(
            published.current(published_at + Duration::from_millis(40)).retry_after_milliseconds,
            Some(60)
        );
        assert_eq!(
            published.current(published_at + Duration::from_millis(140)).retry_after_milliseconds,
            Some(0)
        );
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn kqueue_reactor_reports_only_registered_control_and_process_events() {
        let mut reactor = KqueueRendererEventReactor::new().unwrap();
        let (mut daemon, mut worker) = std::os::unix::net::UnixStream::pair().unwrap();
        let mut child = Command::new("/bin/sleep").arg("30").spawn().unwrap();
        let process_instance_token = renderer_process_instance_token(child.id()).unwrap().unwrap();
        let identity = RendererWorkerIdentity {
            workspace_uuid: WorkspaceUuid::new(),
            renderer_epoch: 7,
            process_id: Some(child.id()),
            process_instance_token: Some(process_instance_token),
        };
        let source = RendererProcessEventSource {
            control_fd: daemon.as_raw_fd(),
            process_id: child.id(),
            process_instance_token,
        };
        reactor
            .apply(RendererProcessWatchChange::Register { identity, source, write_enabled: false })
            .unwrap();

        worker.write_all(b"x").unwrap();
        let readable = reactor.wait(Duration::from_secs(1)).unwrap();
        let mut byte = [0_u8; 1];
        daemon.read_exact(&mut byte).unwrap();

        child.kill().unwrap();
        let exited = reactor.wait(Duration::from_secs(1)).unwrap();
        let _ = child.wait();
        reactor.apply(RendererProcessWatchChange::Unregister { identity, source }).unwrap();

        assert_eq!(readable, vec![identity]);
        assert_eq!(byte, [b'x']);
        assert_eq!(exited, vec![identity]);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn kqueue_write_interest_wakes_after_backpressure_clears_and_can_be_disabled() {
        let mut reactor = KqueueRendererEventReactor::new().unwrap();
        let (mut daemon, mut worker) = std::os::unix::net::UnixStream::pair().unwrap();
        daemon.set_nonblocking(true).unwrap();
        worker.set_nonblocking(true).unwrap();
        let mut child = Command::new("/bin/sleep").arg("30").spawn().unwrap();
        let process_instance_token = renderer_process_instance_token(child.id()).unwrap().unwrap();
        let identity = RendererWorkerIdentity {
            workspace_uuid: WorkspaceUuid::new(),
            renderer_epoch: 8,
            process_id: Some(child.id()),
            process_instance_token: Some(process_instance_token),
        };
        let source = RendererProcessEventSource {
            control_fd: daemon.as_raw_fd(),
            process_id: child.id(),
            process_instance_token,
        };
        reactor
            .apply(RendererProcessWatchChange::Register { identity, source, write_enabled: false })
            .unwrap();
        let bytes = [0xa5_u8; 64 * 1024];
        loop {
            match daemon.write(&bytes) {
                Ok(0) => panic!("socket made no progress before reporting backpressure"),
                Ok(_) => {}
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => break,
                Err(error) => panic!("failed to fill renderer socket: {error}"),
            }
        }
        reactor
            .apply(RendererProcessWatchChange::SetWriteInterest { identity, source, enabled: true })
            .unwrap();
        assert!(reactor.wait(Duration::from_millis(10)).unwrap().is_empty());

        let mut drained = [0_u8; 64 * 1024];
        assert!(worker.read(&mut drained).unwrap() > 0);
        assert_eq!(reactor.wait(Duration::from_secs(1)).unwrap(), vec![identity]);
        reactor
            .apply(RendererProcessWatchChange::SetWriteInterest {
                identity,
                source,
                enabled: false,
            })
            .unwrap();
        assert!(reactor.wait(Duration::from_millis(10)).unwrap().is_empty());

        child.kill().unwrap();
        let _ = child.wait();
        reactor.apply(RendererProcessWatchChange::Unregister { identity, source }).unwrap();
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn kqueue_zero_timeout_harvests_write_readiness_during_a_busy_command_turn() {
        let mut reactor = KqueueRendererEventReactor::new().unwrap();
        let (daemon, _worker) = std::os::unix::net::UnixStream::pair().unwrap();
        let mut child = Command::new("/bin/sleep").arg("30").spawn().unwrap();
        let process_instance_token = renderer_process_instance_token(child.id()).unwrap().unwrap();
        let identity = RendererWorkerIdentity {
            workspace_uuid: WorkspaceUuid::new(),
            renderer_epoch: 9,
            process_id: Some(child.id()),
            process_instance_token: Some(process_instance_token),
        };
        let source = RendererProcessEventSource {
            control_fd: daemon.as_raw_fd(),
            process_id: child.id(),
            process_instance_token,
        };
        reactor
            .apply(RendererProcessWatchChange::Register { identity, source, write_enabled: true })
            .unwrap();

        assert_eq!(reactor.wait(Duration::ZERO).unwrap(), vec![identity]);
        reactor
            .apply(RendererProcessWatchChange::SetWriteInterest {
                identity,
                source,
                enabled: false,
            })
            .unwrap();
        assert!(reactor.wait(Duration::ZERO).unwrap().is_empty());

        child.kill().unwrap();
        let _ = child.wait();
        reactor.apply(RendererProcessWatchChange::Unregister { identity, source }).unwrap();
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn rebuilt_kqueue_wakes_for_command_queued_before_wake_installation() {
        let reactor = KqueueRendererEventReactor::new().unwrap();
        let shared = Shared::new(Arc::new(SupervisorQueueBudget::default()));
        let presentation_id = PresentationId::new();
        let workspace_uuid = WorkspaceUuid::new();
        shared
            .state
            .lock()
            .unwrap()
            .enqueue(CoordinatorCommand::SetPresentation {
                presentation_id,
                workspace_uuid: Some(workspace_uuid),
            })
            .unwrap();

        let wake = reactor.wake();
        shared.replace_event_wake(Some(wake.clone()));
        let started = Instant::now();
        wake.trigger().unwrap();
        assert!(reactor.wait(Duration::from_secs(1)).unwrap().is_empty());
        assert!(started.elapsed() < Duration::from_millis(100));
        assert!(matches!(
            shared.state.lock().unwrap().pop_front(),
            Some(CoordinatorCommand::SetPresentation {
                presentation_id: queued_presentation,
                workspace_uuid: Some(queued_workspace),
            }) if queued_presentation == presentation_id && queued_workspace == workspace_uuid
        ));
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

    #[derive(Default)]
    struct FakeProcessRecord {
        crashed: bool,
        control_closed: bool,
        terminated: bool,
        reaped: bool,
        terminated_at: Option<Instant>,
        reap_delay: Duration,
        sent_messages: Vec<RendererControlMessage>,
        decoder: Option<RendererControlIncrementalDecoder>,
        receive_count: usize,
        try_wait_count: usize,
        wait_failures_remaining: usize,
        terminate_failures_remaining: usize,
        send_failure_after: Option<usize>,
        send_would_block: bool,
        maximum_write_size: Option<usize>,
    }

    #[derive(Default)]
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
            (record.terminated, record.reaped, record.sent_messages.len())
        }

        fn control_closed(&self, pid: u32) -> bool {
            self.0.lock().unwrap().processes[&pid].control_closed
        }

        fn set_reap_delay(&self, pid: u32, reap_delay: Duration) {
            self.0.lock().unwrap().processes.get_mut(&pid).unwrap().reap_delay = reap_delay;
        }

        fn set_wait_failures(&self, pid: u32, failures: usize) {
            self.0.lock().unwrap().processes.get_mut(&pid).unwrap().wait_failures_remaining =
                failures;
        }

        fn set_terminate_failures(&self, pid: u32, failures: usize) {
            self.0.lock().unwrap().processes.get_mut(&pid).unwrap().terminate_failures_remaining =
                failures;
        }

        fn set_send_failure_after(&self, pid: u32, successful_frames: usize) {
            self.0.lock().unwrap().processes.get_mut(&pid).unwrap().send_failure_after =
                Some(successful_frames);
        }

        fn set_send_would_block(&self, pid: u32, would_block: bool) {
            self.0.lock().unwrap().processes.get_mut(&pid).unwrap().send_would_block = would_block;
        }

        fn set_maximum_write_size(&self, pid: u32, maximum_write_size: Option<usize>) {
            self.0.lock().unwrap().processes.get_mut(&pid).unwrap().maximum_write_size =
                maximum_write_size;
        }

        fn all_reaped(&self) -> bool {
            self.0.lock().unwrap().processes.values().all(|record| record.reaped)
        }

        fn messages(&self, pid: u32) -> Vec<RendererControlMessage> {
            self.0.lock().unwrap().processes[&pid].sent_messages.clone()
        }

        fn poll_counts(&self, pid: u32) -> (usize, usize) {
            let state = self.0.lock().unwrap();
            let record = &state.processes[&pid];
            (record.try_wait_count, record.receive_count)
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

        fn process_instance_token(&self) -> Option<RendererProcessInstanceToken> {
            Some(RendererProcessInstanceToken {
                start_time_seconds: u64::from(self.pid),
                start_time_microseconds: u64::from(self.pid) ^ 0x5a5a,
            })
        }

        fn write_nonblocking(&mut self, bytes: &[u8]) -> io::Result<usize> {
            let mut state = self.state.lock().unwrap();
            let record = state.processes.get_mut(&self.pid).unwrap();
            if record.send_would_block {
                return Err(io::Error::new(
                    io::ErrorKind::WouldBlock,
                    "injected renderer backpressure",
                ));
            }
            let completed_frames = record.sent_messages.len();
            if record
                .send_failure_after
                .is_some_and(|successful_frames| completed_frames >= successful_frames)
            {
                return Err(io::Error::new(
                    io::ErrorKind::BrokenPipe,
                    "injected renderer send failure",
                ));
            }
            let count = record.maximum_write_size.unwrap_or(bytes.len()).min(bytes.len());
            let envelopes = record
                .decoder
                .get_or_insert_with(|| {
                    RendererControlIncrementalDecoder::new(RendererControlDirection::DaemonToWorker)
                })
                .feed(&bytes[..count])
                .map_err(io::Error::other)?;
            record.sent_messages.extend(envelopes.into_iter().map(|envelope| envelope.message));
            Ok(count)
        }

        fn receive(&mut self, _destination: &mut Vec<u8>) -> io::Result<ReceiveResult> {
            self.state.lock().unwrap().processes.get_mut(&self.pid).unwrap().receive_count += 1;
            Ok(ReceiveResult::Open)
        }

        fn try_wait(&mut self) -> io::Result<Option<ExitStatus>> {
            let mut state = self.state.lock().unwrap();
            let record = state.processes.get_mut(&self.pid).unwrap();
            record.try_wait_count += 1;
            if record.crashed {
                record.reaped = true;
                return Ok(Some(ExitStatus::from_raw(1 << 8)));
            }
            if record.terminated
                && record
                    .terminated_at
                    .is_some_and(|terminated_at| terminated_at.elapsed() >= record.reap_delay)
            {
                record.reaped = true;
                return Ok(Some(ExitStatus::from_raw(9)));
            }
            Ok(None)
        }

        fn wait(&mut self) -> io::Result<ExitStatus> {
            loop {
                let remaining = {
                    let mut state = self.state.lock().unwrap();
                    let record = state.processes.get_mut(&self.pid).unwrap();
                    if record.wait_failures_remaining > 0 {
                        record.wait_failures_remaining -= 1;
                        return Err(io::Error::other("injected renderer wait failure"));
                    }
                    if record.crashed {
                        record.reaped = true;
                        return Ok(ExitStatus::from_raw(1 << 8));
                    }
                    let Some(terminated_at) = record.terminated_at else {
                        return Err(io::Error::other("fake renderer was not terminated"));
                    };
                    let elapsed = terminated_at.elapsed();
                    if elapsed >= record.reap_delay {
                        record.reaped = true;
                        return Ok(ExitStatus::from_raw(9));
                    }
                    record.reap_delay.saturating_sub(elapsed)
                };
                thread::park_timeout(remaining);
            }
        }

        fn close_control(&mut self) {
            self.state.lock().unwrap().processes.get_mut(&self.pid).unwrap().control_closed = true;
        }

        fn terminate(&mut self) -> io::Result<()> {
            let mut state = self.state.lock().unwrap();
            let record = state.processes.get_mut(&self.pid).unwrap();
            assert!(
                record.control_closed,
                "renderer control capability must close before process termination"
            );
            if record.terminate_failures_remaining > 0 {
                record.terminate_failures_remaining -= 1;
                return Err(io::Error::other("injected renderer termination failure"));
            }
            record.terminated = true;
            record.terminated_at.get_or_insert_with(Instant::now);
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
        new_core_with_budget(spawner, clock, Arc::new(SupervisorQueueBudget::default()))
    }

    fn new_core_with_budget(
        spawner: FakeSpawner,
        clock: ManualClock,
        queue_budget: Arc<SupervisorQueueBudget>,
    ) -> SupervisorCore<FakeSpawner, ManualClock> {
        SupervisorCore::new(
            spawner,
            clock,
            daemon(),
            Duration::from_millis(100),
            Duration::from_secs(5),
            queue_budget,
            Arc::new(|| {}),
        )
        .unwrap()
    }

    fn publish_for_test(
        core: &mut SupervisorCore<FakeSpawner, ManualClock>,
        workspace_uuid: WorkspaceUuid,
        renderer_epoch: u64,
        messages: Vec<RendererControlMessage>,
    ) -> Result<RendererWorkerStatus, RendererSupervisorError> {
        begin_publication_for_test(core, workspace_uuid, renderer_epoch, messages).recv().unwrap()
    }

    fn begin_publication_for_test(
        core: &mut SupervisorCore<FakeSpawner, ManualClock>,
        workspace_uuid: WorkspaceUuid,
        renderer_epoch: u64,
        messages: Vec<RendererControlMessage>,
    ) -> std::sync::mpsc::Receiver<Result<RendererWorkerStatus, RendererSupervisorError>> {
        let publication = Arc::new(RendererPublicationLinearization::default());
        assert!(publication.begin());
        let (reply, response) = sync_channel(1);
        core.publish_if_epoch(
            workspace_uuid,
            renderer_epoch,
            messages,
            RendererPublicationCompletion::new(workspace_uuid, renderer_epoch, publication, reply),
        );
        response
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

    fn release(presentation_id: PresentationId, renderer_epoch: u64) -> RendererFrameRelease {
        RendererFrameRelease {
            daemon_instance_id: daemon().as_uuid(),
            renderer_epoch,
            terminal_id: terminal(),
            terminal_epoch: 9,
            terminal_sequence: 1,
            presentation_id: presentation_id.as_uuid(),
            presentation_generation: 1,
            frame_sequence: 1,
            surface_id: 1,
        }
    }

    #[test]
    fn coordinator_queue_caps_count_and_exact_retained_bytes_and_preserves_other_workspaces() {
        let workspace_a = workspace("20000000-0000-4000-8000-000000000030");
        let workspace_b = workspace("20000000-0000-4000-8000-000000000031");
        let presentation = presentation("30000000-0000-4000-8000-000000000030");
        let mut state = CoordinatorState::default();

        state
            .enqueue(CoordinatorCommand::Send {
                workspace_uuid: workspace_b,
                message: RendererControlMessage::FrameRelease(release(presentation, 1)),
            })
            .unwrap();
        for _ in 1..MAXIMUM_COMMAND_QUEUE_LENGTH - 1 {
            state
                .enqueue(CoordinatorCommand::Send {
                    workspace_uuid: workspace_a,
                    message: RendererControlMessage::FrameRelease(release(presentation, 1)),
                })
                .unwrap();
        }
        assert_eq!(state.commands.len(), MAXIMUM_COMMAND_QUEUE_LENGTH - 1);
        assert!(state.retained_byte_count() < MAXIMUM_COMMAND_QUEUE_BYTES);

        state
            .enqueue(CoordinatorCommand::Send {
                workspace_uuid: workspace_a,
                message: RendererControlMessage::FrameRelease(release(presentation, 1)),
            })
            .unwrap();

        assert!(state.commands.len() <= MAXIMUM_COMMAND_QUEUE_LENGTH);
        assert!(state.retained_byte_count() <= MAXIMUM_COMMAND_QUEUE_BYTES);
        assert_eq!(
            state.retained_command_dynamic_bytes,
            state.commands.iter().map(|queued| queued.dynamic_bytes).sum::<usize>()
        );
        assert!(state.commands.iter().any(|queued| matches!(
            queued.command,
            CoordinatorCommand::Send { workspace_uuid, .. } if workspace_uuid == workspace_b
        )));
        assert!(!state.commands.iter().any(|queued| matches!(
            queued.command,
            CoordinatorCommand::Send { workspace_uuid, .. } if workspace_uuid == workspace_a
        )));
        assert!(state.commands.iter().any(|queued| matches!(
            queued.command,
            CoordinatorCommand::RecoverWorkspaceOverflow { workspace_uuid }
                if workspace_uuid == workspace_a
        )));
    }

    #[test]
    fn oversized_retained_scene_schedules_recovery_without_encoding_amplification() {
        let workspace = workspace("20000000-0000-4000-8000-000000000032");
        let presentation = presentation("30000000-0000-4000-8000-000000000032");
        let mut bytes = Vec::with_capacity(MAXIMUM_COMMAND_QUEUE_BYTES);
        bytes.push(0xa5);
        let message = RendererControlMessage::SemanticScene(RendererSemanticScene {
            terminal_id: terminal(),
            terminal_epoch: 9,
            presentation_id: presentation.as_uuid(),
            presentation_generation: 1,
            canonical_sequence: 1,
            presentation_sequence: 1,
            bytes,
        });
        assert_eq!(message.encoded_frame_length().unwrap(), 113);
        assert!(message.retained_byte_count() >= MAXIMUM_COMMAND_QUEUE_BYTES);

        let mut state = CoordinatorState::default();
        state.enqueue(CoordinatorCommand::Send { workspace_uuid: workspace, message }).unwrap();

        assert_eq!(state.commands.len(), 1);
        assert!(matches!(
            state.commands.front().map(|queued| &queued.command),
            Some(CoordinatorCommand::RecoverWorkspaceOverflow { workspace_uuid })
                if *workspace_uuid == workspace
        ));
        assert_eq!(state.retained_command_dynamic_bytes, 0);
        assert!(state.retained_byte_count() <= COORDINATOR_QUEUE_FIXED_STORAGE_BYTES);
    }

    #[test]
    fn bounded_worker_outbox_rejects_count_and_bytes_atomically() {
        let presentation = presentation("30000000-0000-4000-8000-000000000033");
        let mut count_limited = BoundedWorkerOutbox::default();
        for _ in 0..MAXIMUM_WORKER_OUTBOX_LENGTH {
            count_limited
                .try_push(RendererControlMessage::FrameRelease(release(presentation, 1)))
                .unwrap();
        }
        let count_bytes = count_limited.retained_byte_count();
        assert_eq!(count_limited.len(), MAXIMUM_WORKER_OUTBOX_LENGTH);
        assert_eq!(
            count_limited
                .try_push(RendererControlMessage::FrameRelease(release(presentation, 1)))
                .unwrap_err(),
            RendererSupervisorError::QueueFull
        );
        assert_eq!(count_limited.len(), MAXIMUM_WORKER_OUTBOX_LENGTH);
        assert_eq!(count_limited.retained_byte_count(), count_bytes);

        let mut oversized_bytes = Vec::with_capacity(MAXIMUM_WORKER_OUTBOX_BYTES);
        oversized_bytes.push(0x5a);
        let oversized = RendererControlMessage::SemanticScene(RendererSemanticScene {
            terminal_id: terminal(),
            terminal_epoch: 9,
            presentation_id: presentation.as_uuid(),
            presentation_generation: 1,
            canonical_sequence: 1,
            presentation_sequence: 1,
            bytes: oversized_bytes,
        });
        let mut byte_limited = BoundedWorkerOutbox::default();
        assert_eq!(
            byte_limited.try_push(oversized).unwrap_err(),
            RendererSupervisorError::QueueFull
        );
        assert_eq!(byte_limited.len(), 0);
        assert_eq!(byte_limited.retained_dynamic_byte_count(), 0);
        assert!(byte_limited.retained_byte_count() <= WORKER_OUTBOX_FIXED_STORAGE_BYTES);
    }

    #[test]
    fn supervisor_aggregate_byte_budget_covers_every_worker_outbox() {
        let queue_budget = Arc::new(SupervisorQueueBudget::default());
        let baseline = queue_budget.snapshot();
        let presentation = presentation("30000000-0000-4000-8000-000000000036");
        let mut outboxes =
            (0..4).map(|_| BoundedWorkerOutbox::new(queue_budget.clone())).collect::<Vec<_>>();

        for (index, outbox) in outboxes.iter_mut().enumerate().take(2) {
            let mut bytes = Vec::with_capacity(MAXIMUM_SUPERVISOR_QUEUED_BYTES / 4);
            bytes.push(index as u8);
            outbox
                .try_push(RendererControlMessage::SemanticScene(RendererSemanticScene {
                    terminal_id: terminal(),
                    terminal_epoch: 9,
                    presentation_id: presentation.as_uuid(),
                    presentation_generation: 1,
                    canonical_sequence: index as u64 + 1,
                    presentation_sequence: index as u64 + 1,
                    bytes,
                }))
                .unwrap();
        }

        let before_rejection = queue_budget.snapshot();
        assert_eq!(before_rejection.messages, 2);
        assert_eq!(
            before_rejection.bytes,
            baseline.bytes
                + outboxes
                    .iter()
                    .map(BoundedWorkerOutbox::retained_dynamic_byte_count)
                    .sum::<usize>()
        );
        assert!(
            before_rejection.bytes
                <= MAXIMUM_SUPERVISOR_QUEUED_BYTES - SUPERVISOR_RECOVERY_RESERVE_BYTES
        );

        let mut bytes = Vec::with_capacity(MAXIMUM_SUPERVISOR_QUEUED_BYTES / 4);
        bytes.push(0xff);
        assert_eq!(
            outboxes[2]
                .try_push(RendererControlMessage::SemanticScene(RendererSemanticScene {
                    terminal_id: terminal(),
                    terminal_epoch: 9,
                    presentation_id: presentation.as_uuid(),
                    presentation_generation: 1,
                    canonical_sequence: 4,
                    presentation_sequence: 4,
                    bytes,
                }))
                .unwrap_err(),
            RendererSupervisorError::QueueFull
        );
        assert_eq!(queue_budget.snapshot(), before_rejection);
        assert_eq!(outboxes[2].len(), 0);

        drop(outboxes);
        assert_eq!(queue_budget.snapshot(), baseline);
    }

    #[test]
    fn fixed_queue_storage_and_worker_count_stay_bounded_through_churn() {
        let queue_budget = Arc::new(SupervisorQueueBudget::default());
        let baseline = queue_budget.snapshot();
        assert_eq!(baseline.messages, 0);
        assert_eq!(baseline.bytes, MAXIMUM_SUPERVISOR_FIXED_QUEUE_STORAGE_BYTES);
        assert!(baseline.bytes < MAXIMUM_SUPERVISOR_QUEUED_BYTES);
        let presentation = PresentationId::new();

        for _ in 0..256 {
            let mut outbox = BoundedWorkerOutbox::new(queue_budget.clone());
            let allocated_slots = outbox.messages.capacity();
            assert!(allocated_slots <= MAXIMUM_WORKER_OUTBOX_ALLOCATED_SLOTS);
            for _ in 0..MAXIMUM_WORKER_OUTBOX_LENGTH {
                outbox
                    .try_push(RendererControlMessage::FrameRelease(release(presentation, 1)))
                    .unwrap();
            }
            assert_eq!(queue_budget.snapshot().messages, MAXIMUM_WORKER_OUTBOX_LENGTH);
            assert!(queue_budget.snapshot().bytes > baseline.bytes);
            while outbox.pop_front().is_some() {}
            assert_eq!(outbox.messages.capacity(), allocated_slots);
            assert!(outbox.retained_byte_count() <= WORKER_OUTBOX_FIXED_STORAGE_BYTES);
            assert_eq!(queue_budget.snapshot(), baseline);
            drop(outbox);
            assert_eq!(queue_budget.snapshot(), baseline);
        }

        let mut coordinator = CoordinatorState::new(queue_budget.clone());
        for _ in 0..MAXIMUM_COMMAND_QUEUE_LENGTH - 1 {
            coordinator
                .enqueue(CoordinatorCommand::Send {
                    workspace_uuid: WorkspaceUuid::new(),
                    message: RendererControlMessage::FrameRelease(release(presentation, 1)),
                })
                .unwrap();
        }
        assert_eq!(queue_budget.snapshot().messages, MAXIMUM_COMMAND_QUEUE_LENGTH - 1);
        while coordinator.pop_front().is_some() {}
        assert!(coordinator.commands.capacity() <= MAXIMUM_COMMAND_QUEUE_ALLOCATED_SLOTS);
        assert!(coordinator.retained_byte_count() <= COORDINATOR_QUEUE_FIXED_STORAGE_BYTES);
        assert_eq!(queue_budget.snapshot(), baseline);

        let spawner = FakeSpawner::default();
        let mut core =
            new_core_with_budget(spawner.clone(), ManualClock::default(), queue_budget.clone());
        for _ in 0..MAXIMUM_RENDERER_WORKERS + 64 {
            core.set_presentation_workspace(PresentationId::new(), Some(WorkspaceUuid::new()));
        }
        assert_eq!(core.workers.len(), MAXIMUM_RENDERER_WORKERS);
        assert_eq!(spawner.spawn_count(), MAXIMUM_RENDERER_WORKERS);
        assert!(core.workers.values().all(|worker| {
            worker.outbox.messages.capacity() <= MAXIMUM_WORKER_OUTBOX_ALLOCATED_SLOTS
        }));
        assert_eq!(queue_budget.snapshot(), baseline);

        core.replace_presentations(BTreeMap::new());
        assert!(core.workers.is_empty());
        assert_eq!(queue_budget.snapshot(), baseline);
        core.set_presentation_workspace(PresentationId::new(), Some(WorkspaceUuid::new()));
        assert_eq!(core.workers.len(), 1);
        assert_eq!(spawner.spawn_count(), MAXIMUM_RENDERER_WORKERS + 1);

        drop(core);
        drop(coordinator);
        assert_eq!(queue_budget.snapshot(), baseline);
    }

    #[test]
    fn supervisor_aggregate_message_saturation_preserves_topology_and_recovers_one_workspace() {
        const SATURATED_WORKERS: usize = 24;

        let spawner = FakeSpawner::default();
        let clock = ManualClock::default();
        let queue_budget = Arc::new(SupervisorQueueBudget::default());
        let baseline = queue_budget.snapshot();
        let mut core = new_core_with_budget(spawner.clone(), clock.clone(), queue_budget.clone());
        let workspaces = (0..SATURATED_WORKERS).map(|_| WorkspaceUuid::new()).collect::<Vec<_>>();
        let presentations =
            (0..SATURATED_WORKERS).map(|_| PresentationId::new()).collect::<Vec<_>>();

        for (&workspace_uuid, &presentation_id) in workspaces.iter().zip(&presentations) {
            core.set_presentation_workspace(presentation_id, Some(workspace_uuid));
            for sequence in 1..=MAXIMUM_WORKER_OUTBOX_LENGTH as u64 {
                core.send(
                    workspace_uuid,
                    RendererControlMessage::SemanticScene(scene(
                        presentation_id,
                        1,
                        sequence,
                        sequence,
                        b"stalled-delta",
                    )),
                )
                .unwrap();
            }
        }
        assert_eq!(
            queue_budget.snapshot().messages,
            SATURATED_WORKERS * MAXIMUM_WORKER_OUTBOX_LENGTH
        );

        let continuity_workspace = WorkspaceUuid::new();
        let continuity_presentation = PresentationId::new();
        let target_workspace = workspaces[0];
        let target_presentation = presentations[0];
        let target_before = core.workers[&target_workspace].epoch;
        let target_old_pid = core.workers[&target_workspace].process.as_ref().unwrap().pid();
        let mut coordinator = CoordinatorState::new(queue_budget.clone());
        for _ in 0..MAXIMUM_COMMAND_QUEUE_LENGTH - 1 {
            coordinator
                .enqueue(CoordinatorCommand::SetPresentation {
                    presentation_id: continuity_presentation,
                    workspace_uuid: Some(continuity_workspace),
                })
                .unwrap();
        }
        assert_eq!(queue_budget.snapshot().messages, MAXIMUM_SUPERVISOR_QUEUED_MESSAGES - 1);

        coordinator
            .enqueue(CoordinatorCommand::Send {
                workspace_uuid: target_workspace,
                message: RendererControlMessage::SemanticScene(scene(
                    target_presentation,
                    1,
                    129,
                    129,
                    b"overflow",
                )),
            })
            .unwrap();
        let saturated = queue_budget.snapshot();
        assert_eq!(saturated.messages, MAXIMUM_SUPERVISOR_QUEUED_MESSAGES);
        assert!(saturated.bytes <= MAXIMUM_SUPERVISOR_QUEUED_BYTES);
        assert_eq!(coordinator.commands.len(), MAXIMUM_COMMAND_QUEUE_LENGTH);
        assert_eq!(
            coordinator
                .commands
                .iter()
                .filter(|queued| matches!(
                    queued.command,
                    CoordinatorCommand::SetPresentation { .. }
                ))
                .count(),
            MAXIMUM_COMMAND_QUEUE_LENGTH - 1
        );
        assert!(coordinator.commands.iter().any(|queued| matches!(
            queued.command,
            CoordinatorCommand::RecoverWorkspaceOverflow { workspace_uuid }
                if workspace_uuid == target_workspace
        )));

        while let Some(command) = coordinator.pop_front() {
            match command {
                CoordinatorCommand::SetPresentation { presentation_id, workspace_uuid } => {
                    core.set_presentation_workspace(presentation_id, workspace_uuid);
                }
                CoordinatorCommand::RecoverWorkspaceOverflow { workspace_uuid } => {
                    core.worker_failed(
                        workspace_uuid,
                        "aggregate renderer queue overflow; forcing full scene recovery".to_owned(),
                    );
                }
                _ => panic!("aggregate saturation test queued an unexpected command"),
            }
        }
        assert_eq!(core.presentations[&continuity_presentation], continuity_workspace);
        assert_eq!(spawner.spawn_count(), SATURATED_WORKERS + 1);
        assert_eq!(core.workers[&target_workspace].state, RendererWorkerState::Backoff);
        assert_eq!(core.workers[&target_workspace].outbox.len(), 0);
        assert_eq!(
            queue_budget.snapshot().messages,
            (SATURATED_WORKERS - 1) * MAXIMUM_WORKER_OUTBOX_LENGTH
        );

        let continuity = core
            .statuses()
            .into_iter()
            .find(|status| status.workspace_uuid == continuity_workspace)
            .unwrap();
        let continuity_pid = continuity.pid.unwrap();
        core.accept_worker_envelope(
            continuity_workspace,
            continuity.renderer_epoch,
            continuity_pid,
            ready_envelope(continuity_pid),
        )
        .unwrap();
        core.send_if_epoch(
            continuity_workspace,
            continuity.renderer_epoch,
            vec![
                RendererControlMessage::UpsertPresentation(attachment(continuity_presentation, 1)),
                RendererControlMessage::SemanticScene(scene(
                    continuity_presentation,
                    1,
                    1,
                    1,
                    b"continuity-full",
                )),
            ],
        );
        assert_eq!(spawner.messages(continuity_pid).len(), 3);

        clock.advance(Duration::from_millis(121));
        core.tick();
        let target_after = core
            .statuses()
            .into_iter()
            .find(|status| status.workspace_uuid == target_workspace)
            .unwrap();
        let target_new_pid = target_after.pid.unwrap();
        assert_ne!(target_after.renderer_epoch, target_before);
        assert_ne!(target_new_pid, target_old_pid);
        core.accept_worker_envelope(
            target_workspace,
            target_after.renderer_epoch,
            target_new_pid,
            ready_envelope(target_new_pid),
        )
        .unwrap();
        core.send_if_epoch(
            target_workspace,
            target_after.renderer_epoch,
            vec![
                RendererControlMessage::UpsertPresentation(attachment(target_presentation, 1)),
                RendererControlMessage::SemanticScene(scene(
                    target_presentation,
                    1,
                    129,
                    1,
                    b"fresh-full",
                )),
            ],
        );
        assert_eq!(spawner.messages(target_old_pid).len(), 1);
        let recovered = spawner.messages(target_new_pid);
        assert_eq!(recovered.len(), 3);
        assert!(matches!(
            &recovered[2],
            RendererControlMessage::SemanticScene(scene) if scene.bytes == b"fresh-full"
        ));
        assert_eq!(
            queue_budget.snapshot().messages,
            (SATURATED_WORKERS - 1) * MAXIMUM_WORKER_OUTBOX_LENGTH
        );

        drop(coordinator);
        drop(core);
        assert_eq!(queue_budget.snapshot(), baseline);
    }

    #[test]
    fn desired_presentation_removal_bypasses_a_saturated_command_queue() {
        let queue_budget = Arc::new(SupervisorQueueBudget::default());
        let shared = Arc::new(Shared::new(queue_budget));
        let supervisor = RendererSupervisor { shared: shared.clone(), coordinator: None };
        let presentation_id = PresentationId::new();
        supervisor.set_presentation_workspace(presentation_id, Some(WorkspaceUuid::new())).unwrap();

        let mut state = shared.state.lock().unwrap();
        for _ in 0..MAXIMUM_COMMAND_QUEUE_LENGTH - 1 {
            state
                .enqueue(CoordinatorCommand::SetPresentation {
                    presentation_id: PresentationId::new(),
                    workspace_uuid: Some(WorkspaceUuid::new()),
                })
                .unwrap();
        }
        assert_eq!(state.commands.len(), MAXIMUM_COMMAND_QUEUE_LENGTH - 1);
        drop(state);

        supervisor.remove_presentation(presentation_id).unwrap();
        assert!(
            !shared.desired_presentations.lock().unwrap().values.contains_key(&presentation_id)
        );
        assert_eq!(
            shared.state.lock().unwrap().commands.len(),
            MAXIMUM_COMMAND_QUEUE_LENGTH - 1,
            "desired-state removal must not consume the bounded message lane"
        );
    }

    #[test]
    fn status_query_reconciles_a_prior_side_lane_visibility_update() {
        let queue_budget = Arc::new(SupervisorQueueBudget::default());
        let shared = Arc::new(Shared::new(queue_budget.clone()));
        let workspace_uuid = WorkspaceUuid::new();
        let presentation_id = PresentationId::new();
        {
            let mut desired = shared.desired_presentations.lock().unwrap();
            assert!(desired.set(presentation_id, Some(workspace_uuid)));
        }
        let (reply, response) = sync_channel(1);
        shared
            .state
            .lock()
            .unwrap()
            .enqueue(CoordinatorCommand::WorkspaceStatus { workspace_uuid, reply })
            .unwrap();

        let coordinator_shared = shared.clone();
        let mut core =
            new_core_with_budget(FakeSpawner::default(), ManualClock::default(), queue_budget);
        let coordinator = thread::spawn(move || {
            coordinator_loop(&coordinator_shared, &mut core);
        });

        let status = response.recv_timeout(Duration::from_secs(1)).unwrap().unwrap();
        assert_eq!(status.workspace_uuid, workspace_uuid);
        assert_eq!(status.state, RendererWorkerState::Starting);

        {
            let mut state = shared.state.lock().unwrap();
            state.stopping = true;
        }
        shared.notify_all();
        coordinator.join().unwrap();
    }

    #[test]
    fn idempotent_desired_presentation_updates_do_not_schedule_full_reconciliation() {
        let shared = Arc::new(Shared::new(Arc::new(SupervisorQueueBudget::default())));
        let supervisor = RendererSupervisor { shared: shared.clone(), coordinator: None };
        let presentation_id = PresentationId::new();
        let workspace_uuid = WorkspaceUuid::new();

        supervisor.set_presentation_workspace(presentation_id, Some(workspace_uuid)).unwrap();
        assert_eq!(shared.desired_presentations.lock().unwrap().revision, 1);
        assert_eq!(shared.desired_presentations.lock().unwrap().pending_changes.len(), 1);

        supervisor.set_presentation_workspace(presentation_id, Some(workspace_uuid)).unwrap();
        supervisor.retain_workspaces(BTreeSet::from([workspace_uuid])).unwrap();
        supervisor.remove_presentation(PresentationId::new()).unwrap();

        assert_eq!(shared.desired_presentations.lock().unwrap().revision, 1);
        assert_eq!(shared.desired_presentations.lock().unwrap().pending_changes.len(), 1);
    }

    #[test]
    fn add_remove_churn_before_reconciliation_does_not_accumulate_tombstones() {
        let mut desired = DesiredPresentations::default();

        for _ in 0..10_000 {
            let presentation_id = PresentationId::new();
            assert!(desired.set(presentation_id, Some(WorkspaceUuid::new())));
            assert!(desired.set(presentation_id, None));
        }

        assert!(desired.values.is_empty());
        assert!(desired.pending_changes.is_empty());
        let mut revision = 0;
        assert!(desired.take_pending_changes(&mut revision).unwrap().is_empty());
    }

    #[test]
    fn starting_worker_saturation_restarts_only_that_workspace_and_drops_stale_scenes() {
        let spawner = FakeSpawner::default();
        let clock = ManualClock::default();
        let mut core = new_core(spawner.clone(), clock.clone());
        let workspace_a = workspace("20000000-0000-4000-8000-000000000034");
        let workspace_b = workspace("20000000-0000-4000-8000-000000000035");
        let presentation_a = presentation("30000000-0000-4000-8000-000000000034");
        let presentation_b = presentation("30000000-0000-4000-8000-000000000035");
        core.set_presentation_workspace(presentation_a, Some(workspace_a));
        core.set_presentation_workspace(presentation_b, Some(workspace_b));
        let status_a = core
            .statuses()
            .into_iter()
            .find(|status| status.workspace_uuid == workspace_a)
            .unwrap();
        let status_b = core
            .statuses()
            .into_iter()
            .find(|status| status.workspace_uuid == workspace_b)
            .unwrap();
        let old_pid_a = status_a.pid.unwrap();
        let pid_b = status_b.pid.unwrap();
        core.accept_worker_envelope(
            workspace_b,
            status_b.renderer_epoch,
            pid_b,
            ready_envelope(pid_b),
        )
        .unwrap();
        core.take_events();

        for sequence in 1..=MAXIMUM_WORKER_OUTBOX_LENGTH as u64 {
            core.send(
                workspace_a,
                RendererControlMessage::SemanticScene(scene(
                    presentation_a,
                    1,
                    sequence,
                    sequence,
                    b"stale",
                )),
            )
            .unwrap();
        }
        assert_eq!(core.workers[&workspace_a].outbox.len(), MAXIMUM_WORKER_OUTBOX_LENGTH);
        let overflow = core
            .send(
                workspace_a,
                RendererControlMessage::SemanticScene(scene(
                    presentation_a,
                    1,
                    129,
                    129,
                    b"overflow",
                )),
            )
            .unwrap_err();
        assert_eq!(overflow, RendererSupervisorError::QueueFull);
        core.worker_failed(workspace_a, overflow.to_string());

        assert_eq!(core.statuses().len(), 2);
        assert_eq!(core.workers[&workspace_a].state, RendererWorkerState::Backoff);
        assert_eq!(core.workers[&workspace_a].outbox.len(), 0);
        assert_eq!(core.workers[&workspace_b].state, RendererWorkerState::Ready);
        core.send_if_epoch(
            workspace_b,
            status_b.renderer_epoch,
            vec![
                RendererControlMessage::UpsertPresentation(attachment(presentation_b, 1)),
                RendererControlMessage::SemanticScene(scene(
                    presentation_b,
                    1,
                    1,
                    1,
                    b"workspace-b-full",
                )),
            ],
        );
        assert_eq!(spawner.messages(pid_b).len(), 3);

        clock.advance(Duration::from_millis(121));
        core.tick();
        let restarted = core
            .statuses()
            .into_iter()
            .find(|status| status.workspace_uuid == workspace_a)
            .unwrap();
        let new_pid_a = restarted.pid.unwrap();
        assert_ne!(new_pid_a, old_pid_a);
        assert_ne!(restarted.renderer_epoch, status_a.renderer_epoch);
        core.accept_worker_envelope(
            workspace_a,
            restarted.renderer_epoch,
            new_pid_a,
            ready_envelope(new_pid_a),
        )
        .unwrap();
        assert!(core.take_events().iter().any(|event| matches!(
            event,
            RendererSupervisorEvent::WorkerReady { workspace_uuid, renderer_epoch, .. }
                if *workspace_uuid == workspace_a
                    && *renderer_epoch == restarted.renderer_epoch
        )));
        core.send_if_epoch(
            workspace_a,
            restarted.renderer_epoch,
            vec![
                RendererControlMessage::UpsertPresentation(attachment(presentation_a, 1)),
                RendererControlMessage::SemanticScene(scene(
                    presentation_a,
                    1,
                    129,
                    1,
                    b"fresh-full",
                )),
            ],
        );

        assert_eq!(spawner.messages(old_pid_a).len(), 1);
        let recovered = spawner.messages(new_pid_a);
        assert_eq!(recovered.len(), 3);
        assert!(matches!(
            &recovered[2],
            RendererControlMessage::SemanticScene(scene) if scene.bytes == b"fresh-full"
        ));
        assert_eq!(spawner.record(old_pid_a), (true, true, 1));
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
        assert_eq!(spawner.record(pid), (true, true, 1));
        assert!(spawner.control_closed(pid));
    }

    #[test]
    fn one_thousand_dormant_canonical_workspaces_create_no_renderer_state() {
        const WORKSPACE_COUNT: usize = 1_000;

        let spawner = FakeSpawner::default();
        let queue_budget = Arc::new(SupervisorQueueBudget::default());
        let baseline = queue_budget.snapshot();
        let mut core =
            new_core_with_budget(spawner.clone(), ManualClock::default(), queue_budget.clone());
        let canonical_workspaces =
            (0..WORKSPACE_COUNT).map(|_| WorkspaceUuid::new()).collect::<BTreeSet<_>>();

        // Canonical existence is only a retention fence. Without a visible
        // presentation, no workspace enters the renderer's desired set.
        core.retain_workspaces(&canonical_workspaces);

        assert_eq!(canonical_workspaces.len(), WORKSPACE_COUNT);
        assert!(core.presentations.is_empty());
        assert!(core.workers.is_empty());
        assert_eq!(spawner.spawn_count(), 0);
        assert_eq!(core.last_reconciliation_operations, ReconciliationOperationCounts::default());
        let (statuses, worker_visits) = core.status_snapshot();
        assert!(statuses.is_empty());
        assert_eq!(worker_visits, 0);
        assert_eq!(queue_budget.snapshot(), baseline);
    }

    #[test]
    fn one_thousand_visible_workspaces_create_exactly_one_worker_each_in_linear_visits() {
        const WORKSPACE_COUNT: usize = 1_000;

        let spawner = FakeSpawner::default();
        let queue_budget = Arc::new(SupervisorQueueBudget::default());
        let baseline = queue_budget.snapshot();
        let mut core =
            new_core_with_budget(spawner.clone(), ManualClock::default(), queue_budget.clone());
        let desired = (0..WORKSPACE_COUNT)
            .map(|_| (PresentationId::new(), WorkspaceUuid::new()))
            .collect::<BTreeMap<_, _>>();
        let one_workspace = *desired.values().next().unwrap();

        core.replace_presentations(desired.clone());

        assert_eq!(core.workers.len(), WORKSPACE_COUNT);
        assert_eq!(spawner.spawn_count(), WORKSPACE_COUNT);
        assert_eq!(
            core.last_reconciliation_operations,
            ReconciliationOperationCounts {
                presentation_visits: WORKSPACE_COUNT,
                existing_worker_visits: 0,
                desired_workspace_visits: WORKSPACE_COUNT,
            }
        );
        let (statuses, worker_visits) = core.status_snapshot();
        assert_eq!(worker_visits, WORKSPACE_COUNT);
        assert_eq!(statuses.len(), WORKSPACE_COUNT);
        assert!(statuses.iter().all(|status| status.visible_presentation_count == 1));
        assert_eq!(
            core.workspace_status(one_workspace).unwrap().workspace_uuid,
            one_workspace,
            "a single-workspace query must use the keyed worker path"
        );
        assert!(core.workers.values().all(|worker| {
            worker.outbox.messages.capacity() <= MAXIMUM_WORKER_OUTBOX_ALLOCATED_SLOTS
        }));
        assert_eq!(queue_budget.snapshot(), baseline);

        // The compatibility full-snapshot helper validates each supplied key,
        // but unchanged keys touch no worker and spawn no duplicate process.
        core.replace_presentations(desired);
        assert_eq!(spawner.spawn_count(), WORKSPACE_COUNT);
        assert_eq!(
            core.last_reconciliation_operations,
            ReconciliationOperationCounts {
                presentation_visits: WORKSPACE_COUNT,
                existing_worker_visits: 0,
                desired_workspace_visits: 0,
            }
        );
        let (_, repeated_status_worker_visits) = core.status_snapshot();
        assert_eq!(repeated_status_worker_visits, WORKSPACE_COUNT);
    }

    #[test]
    fn one_worker_event_at_thousand_workspace_scale_polls_and_publishes_only_that_worker() {
        const WORKSPACE_COUNT: usize = 1_000;

        let spawner = FakeSpawner::default();
        let mut core = new_core(spawner.clone(), ManualClock::default());
        let desired = (0..WORKSPACE_COUNT)
            .map(|_| (PresentationId::new(), WorkspaceUuid::new()))
            .collect::<BTreeMap<_, _>>();
        core.replace_presentations(desired);
        assert_eq!(core.take_status_changes().len(), WORKSPACE_COUNT);

        let target_workspace = *core.workers.keys().next().unwrap();
        let target = core.workspace_status(target_workspace).unwrap();
        let target_pid = target.pid.unwrap();
        core.process_worker_event(RendererWorkerIdentity {
            workspace_uuid: target_workspace,
            renderer_epoch: target.renderer_epoch,
            process_id: Some(target_pid),
            process_instance_token: Some(RendererProcessInstanceToken {
                start_time_seconds: u64::from(target_pid),
                start_time_microseconds: u64::from(target_pid) ^ 0x5a5a,
            }),
        });

        assert_eq!(spawner.poll_counts(target_pid), (1, 1));
        for worker in core.workers.values().skip(1).take(32) {
            assert_eq!(spawner.poll_counts(worker.process.as_ref().unwrap().pid()), (0, 0));
        }
        assert!(core.take_status_changes().is_empty());

        core.accept_worker_envelope(
            target_workspace,
            target.renderer_epoch,
            target_pid,
            ready_envelope(target_pid),
        )
        .unwrap();
        let status_changes = core.take_status_changes();
        assert_eq!(status_changes.len(), 1);
        assert_eq!(status_changes[0].0, target_workspace);
        assert_eq!(status_changes[0].1.as_ref().unwrap().state, RendererWorkerState::Ready);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn permanent_reactor_rebuild_failure_never_falls_back_to_worker_polling() {
        const WORKSPACE_COUNT: usize = 1_000;

        let spawner = FakeSpawner::default();
        let mut core = new_core(spawner.clone(), ManualClock::default());
        core.replace_presentations(
            (0..WORKSPACE_COUNT).map(|_| (PresentationId::new(), WorkspaceUuid::new())).collect(),
        );
        let _ = core.take_process_watch_changes();
        let process_ids =
            core.statuses().into_iter().map(|status| status.pid.unwrap()).collect::<Vec<_>>();

        let result = rebuild_renderer_event_reactor(&mut core, || {
            Err(io::Error::other("injected permanent kqueue failure"))
        });

        assert!(result.is_err());
        assert!(core.take_process_watch_changes().is_empty());
        assert!(process_ids.into_iter().all(|pid| spawner.poll_counts(pid) == (0, 0)));
    }

    #[test]
    fn one_due_restart_timer_does_not_poll_or_restart_unrelated_workers() {
        let spawner = FakeSpawner::default();
        let clock = ManualClock::default();
        let mut core = new_core(spawner.clone(), clock.clone());
        let restarting_workspace = WorkspaceUuid::new();
        let unaffected_workspace = WorkspaceUuid::new();
        core.set_presentation_workspace(PresentationId::new(), Some(restarting_workspace));
        core.set_presentation_workspace(PresentationId::new(), Some(unaffected_workspace));
        let unaffected_before = core.workspace_status(unaffected_workspace).unwrap();
        let unaffected_pid = unaffected_before.pid.unwrap();

        core.worker_failed(restarting_workspace, "synthetic crash".to_owned());
        let retry_at = core.workers[&restarting_workspace].retry_at.unwrap();
        clock.advance(retry_at.saturating_sub(clock.now()));
        core.process_due_timers();

        assert_eq!(spawner.spawn_count(), 3);
        assert_eq!(core.workspace_status(unaffected_workspace).unwrap(), unaffected_before);
        assert_eq!(spawner.poll_counts(unaffected_pid), (0, 0));
        assert_eq!(
            core.workspace_status(restarting_workspace).unwrap().state,
            RendererWorkerState::Starting
        );
    }

    #[test]
    fn one_thousand_presentations_of_one_workspace_share_one_worker() {
        const PRESENTATION_COUNT: usize = 1_000;

        let spawner = FakeSpawner::default();
        let mut core = new_core(spawner.clone(), ManualClock::default());
        let workspace_uuid = WorkspaceUuid::new();
        let desired = (0..PRESENTATION_COUNT)
            .map(|_| (PresentationId::new(), workspace_uuid))
            .collect::<BTreeMap<_, _>>();

        core.replace_presentations(desired);

        assert_eq!(core.workers.len(), 1);
        assert_eq!(spawner.spawn_count(), 1);
        assert_eq!(
            core.last_reconciliation_operations,
            ReconciliationOperationCounts {
                presentation_visits: PRESENTATION_COUNT,
                existing_worker_visits: 0,
                desired_workspace_visits: 1,
            }
        );
        let (statuses, worker_visits) = core.status_snapshot();
        assert_eq!(worker_visits, 1);
        assert_eq!(statuses.len(), 1);
        assert_eq!(statuses[0].workspace_uuid, workspace_uuid);
        assert_eq!(statuses[0].visible_presentation_count, PRESENTATION_COUNT);
    }

    #[test]
    fn one_changed_presentation_at_thousand_workspace_scale_reconciles_only_touched_keys() {
        const WORKSPACE_COUNT: usize = 1_000;

        let spawner = FakeSpawner::default();
        let mut core = new_core(spawner.clone(), ManualClock::default());
        let mut desired = DesiredPresentations::default();
        let entries = (0..WORKSPACE_COUNT)
            .map(|_| (PresentationId::new(), WorkspaceUuid::new()))
            .collect::<Vec<_>>();
        for (presentation_id, workspace_uuid) in &entries {
            assert!(desired.set(*presentation_id, Some(*workspace_uuid)));
        }
        let mut revision = 0;
        core.apply_presentation_changes(desired.take_pending_changes(&mut revision).unwrap());
        assert_eq!(core.workers.len(), WORKSPACE_COUNT);

        let moved_presentation = entries[0].0;
        let previous_workspace = entries[0].1;
        let next_workspace = WorkspaceUuid::new();
        assert!(desired.set(moved_presentation, Some(next_workspace)));
        let pending = desired.take_pending_changes(&mut revision).unwrap();
        assert_eq!(pending.len(), 1, "the side lane must not clone all desired presentations");

        core.apply_presentation_changes(pending);

        assert_eq!(core.workers.len(), WORKSPACE_COUNT);
        assert!(!core.workers.contains_key(&previous_workspace));
        assert!(core.workers.contains_key(&next_workspace));
        assert_eq!(
            core.last_reconciliation_operations,
            ReconciliationOperationCounts {
                presentation_visits: 1,
                existing_worker_visits: 1,
                desired_workspace_visits: 1,
            }
        );
        assert_eq!(spawner.spawn_count(), WORKSPACE_COUNT + 1);
    }

    #[test]
    fn presentation_move_at_worker_cap_frees_old_slot_before_admitting_new_workspace() {
        let spawner = FakeSpawner::default();
        let mut core = new_core(spawner.clone(), ManualClock::default());
        let moved_presentation = PresentationId::new();
        let previous_workspace = workspace("f0000000-0000-4000-8000-000000000001");
        let next_workspace = workspace("10000000-0000-4000-8000-000000000001");
        core.set_presentation_workspace(moved_presentation, Some(previous_workspace));
        for _ in 1..MAXIMUM_RENDERER_WORKERS {
            core.set_presentation_workspace(PresentationId::new(), Some(WorkspaceUuid::new()));
        }
        assert_eq!(core.workers.len(), MAXIMUM_RENDERER_WORKERS);

        core.set_presentation_workspace(moved_presentation, Some(next_workspace));

        assert_eq!(core.workers.len(), MAXIMUM_RENDERER_WORKERS);
        assert!(!core.workers.contains_key(&previous_workspace));
        assert!(core.workers.contains_key(&next_workspace));
        assert_eq!(spawner.spawn_count(), MAXIMUM_RENDERER_WORKERS + 1);
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
    fn exact_epoch_retirement_returns_only_after_process_quiescence() {
        let spawner = FakeSpawner::default();
        let mut core = new_core(spawner.clone(), ManualClock::default());
        let workspace = WorkspaceUuid::new();
        core.set_presentation_workspace(PresentationId::new(), Some(workspace));
        let status = core.statuses()[0].clone();
        let pid = status.pid.unwrap();

        assert!(core.retire_if_epoch(workspace, status.renderer_epoch).unwrap());
        assert!(spawner.record(pid).0);
        assert!(spawner.record(pid).1);
        assert_eq!(core.workspace_status(workspace).unwrap().state, RendererWorkerState::Backoff);
        assert!(matches!(
            core.take_events().as_slice(),
            [RendererSupervisorEvent::WorkerUnavailable {
                renderer_epoch,
                quiesced: true,
                ..
            }] if *renderer_epoch == status.renderer_epoch
        ));
    }

    #[test]
    fn exact_epoch_retirement_retry_cannot_outpace_owned_reap() {
        let spawner = FakeSpawner::default();
        let mut core = new_core(spawner.clone(), ManualClock::default());
        let workspace = WorkspaceUuid::new();
        core.set_presentation_workspace(PresentationId::new(), Some(workspace));
        let status = core.statuses()[0].clone();
        spawner.set_reap_delay(status.pid.unwrap(), Duration::from_millis(600));

        assert!(!core.retire_if_epoch(workspace, status.renderer_epoch).unwrap());
        assert!(!core.retire_if_epoch(workspace, status.renderer_epoch).unwrap());
        assert!(core.reaper.wait_until_epoch_quiesced(
            workspace,
            status.renderer_epoch,
            Duration::from_secs(1),
        ));
        core.publish_reaper_completions();
        assert!(core.take_events().iter().any(|event| matches!(
            event,
            RendererSupervisorEvent::WorkerUnavailable {
                renderer_epoch,
                quiesced: true,
                ..
            } if *renderer_epoch == status.renderer_epoch
        )));
        assert!(core.retire_if_epoch(workspace, status.renderer_epoch).unwrap());
    }

    #[test]
    fn worker_that_never_becomes_ready_is_retired_and_restarted() {
        let spawner = FakeSpawner::default();
        let clock = ManualClock::default();
        let mut core = new_core(spawner.clone(), clock.clone());
        let workspace = workspace("20000000-0000-4000-8000-000000000004");
        core.set_presentation_workspace(
            presentation("30000000-0000-4000-8000-000000000004"),
            Some(workspace),
        );
        let first = core.statuses()[0].clone();
        let first_pid = first.pid.unwrap();

        clock.advance(WORKER_READY_TIMEOUT);
        core.tick();

        let backoff = core.statuses()[0].clone();
        assert_eq!(backoff.state, RendererWorkerState::Backoff);
        assert_eq!(backoff.pid, None);
        assert_eq!(backoff.restart_count, 1);
        assert!(backoff.last_error.as_deref().is_some_and(|error| error.contains("ready")));
        let (terminated, _, _) = spawner.record(first_pid);
        assert!(spawner.control_closed(first_pid));
        assert!(terminated);
        assert!(matches!(
            core.take_events().as_slice(),
            [RendererSupervisorEvent::WorkerUnavailable { reason, .. }]
                if reason.contains("ready")
        ));

        clock.advance(Duration::from_millis(121));
        core.tick();
        let restarted = core.statuses()[0].clone();
        assert_eq!(restarted.state, RendererWorkerState::Starting);
        assert_ne!(restarted.renderer_epoch, first.renderer_epoch);
        assert_ne!(restarted.pid, first.pid);
        assert_eq!(spawner.spawn_count(), 2);
    }

    #[test]
    fn ready_message_at_deadline_wins_before_timeout_reconciliation() {
        let spawner = FakeSpawner::default();
        let clock = ManualClock::default();
        let mut core = new_core(spawner, clock.clone());
        let workspace = workspace("20000000-0000-4000-8000-000000000005");
        core.set_presentation_workspace(
            presentation("30000000-0000-4000-8000-000000000005"),
            Some(workspace),
        );
        let starting = core.statuses()[0].clone();
        let pid = starting.pid.unwrap();

        clock.advance(WORKER_READY_TIMEOUT);
        core.accept_worker_envelope(workspace, starting.renderer_epoch, pid, ready_envelope(pid))
            .unwrap();
        core.tick();

        assert_eq!(core.statuses()[0].state, RendererWorkerState::Ready);
        assert!(matches!(
            core.take_events().as_slice(),
            [RendererSupervisorEvent::WorkerReady { process_id, .. }] if *process_id == pid
        ));
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
    fn canceled_exact_publication_has_no_worker_side_effect() {
        let spawner = FakeSpawner::default();
        let clock = ManualClock::default();
        let mut core = new_core(spawner.clone(), clock);
        let workspace = WorkspaceUuid::new();
        let presentation = PresentationId::new();
        core.set_presentation_workspace(presentation, Some(workspace));
        let status = core.statuses()[0].clone();
        let pid = status.pid.unwrap();
        core.accept_worker_envelope(workspace, status.renderer_epoch, pid, ready_envelope(pid))
            .unwrap();
        let before = spawner.messages(pid);
        let publication = Arc::new(RendererPublicationLinearization::default());
        assert!(publication.cancel_if_pending());
        assert!(!publication.begin());
        let (reply, response) = sync_channel(1);
        let shared = Shared::new(Arc::new(SupervisorQueueBudget::default()));
        let mut desired_revision = 0;
        process_coordinator_command(
            &shared,
            &mut core,
            &mut desired_revision,
            CoordinatorCommand::PublishIfEpoch {
                workspace_uuid: workspace,
                renderer_epoch: status.renderer_epoch,
                messages: vec![
                    RendererControlMessage::UpsertPresentation(attachment(presentation, 1)),
                    RendererControlMessage::SemanticScene(scene(
                        presentation,
                        1,
                        1,
                        1,
                        b"must-not-publish",
                    )),
                ],
                publication,
                reply,
            },
        );
        let error = response.recv().unwrap().unwrap_err();
        assert!(error.to_string().contains("canceled"));
        assert_eq!(spawner.messages(pid), before);
    }

    #[test]
    fn partial_exact_publication_is_reported_as_uncertain_and_retires_worker() {
        let spawner = FakeSpawner::default();
        let mut core = new_core(spawner.clone(), ManualClock::default());
        let workspace = WorkspaceUuid::new();
        let presentation = PresentationId::new();
        core.set_presentation_workspace(presentation, Some(workspace));
        let status = core.statuses()[0].clone();
        let pid = status.pid.unwrap();
        core.accept_worker_envelope(workspace, status.renderer_epoch, pid, ready_envelope(pid))
            .unwrap();
        // Bootstrap is frame one. Permit Upsert, then fail the full scene.
        spawner.set_send_failure_after(pid, 2);
        let error = publish_for_test(
            &mut core,
            workspace,
            status.renderer_epoch,
            vec![
                RendererControlMessage::UpsertPresentation(attachment(presentation, 1)),
                RendererControlMessage::SemanticScene(scene(
                    presentation,
                    1,
                    1,
                    1,
                    b"partial-publication",
                )),
            ],
        )
        .unwrap_err();
        assert!(matches!(
            error,
            RendererSupervisorError::PublicationUncertain {
                workspace_uuid,
                renderer_epoch,
                ..
            } if workspace_uuid == workspace && renderer_epoch == status.renderer_epoch
        ));
        let messages = spawner.messages(pid);
        assert!(matches!(messages[1], RendererControlMessage::UpsertPresentation(_)));
        assert_eq!(messages.len(), 2);
        assert!(spawner.record(pid).1, "uncertain publisher must be killed and reaped");
        assert_eq!(core.workspace_status(workspace).unwrap().state, RendererWorkerState::Backoff);
    }

    #[test]
    fn backpressured_worker_does_not_fail_or_block_another_workspace() {
        let spawner = FakeSpawner::default();
        let mut core = new_core(spawner.clone(), ManualClock::default());
        let workspace_a = WorkspaceUuid::new();
        let workspace_b = WorkspaceUuid::new();
        let presentation_a = PresentationId::new();
        let presentation_b = PresentationId::new();
        core.set_presentation_workspace(presentation_a, Some(workspace_a));
        core.set_presentation_workspace(presentation_b, Some(workspace_b));

        let status_a = core.workspace_status(workspace_a).unwrap();
        let status_b = core.workspace_status(workspace_b).unwrap();
        let pid_a = status_a.pid.unwrap();
        let pid_b = status_b.pid.unwrap();
        core.accept_worker_envelope(
            workspace_a,
            status_a.renderer_epoch,
            pid_a,
            ready_envelope(pid_a),
        )
        .unwrap();
        core.accept_worker_envelope(
            workspace_b,
            status_b.renderer_epoch,
            pid_b,
            ready_envelope(pid_b),
        )
        .unwrap();
        spawner.set_send_would_block(pid_a, true);

        core.send_if_epoch(
            workspace_a,
            status_a.renderer_epoch,
            vec![RendererControlMessage::UpsertPresentation(attachment(presentation_a, 1))],
        );
        core.send_if_epoch(
            workspace_b,
            status_b.renderer_epoch,
            vec![RendererControlMessage::UpsertPresentation(attachment(presentation_b, 1))],
        );

        assert_eq!(
            core.workspace_status(workspace_a).unwrap().state,
            RendererWorkerState::Ready,
            "socket backpressure is pending output, not a worker failure"
        );
        assert_eq!(spawner.messages(pid_b).len(), 2, "workspace B must publish immediately");
        assert!(matches!(
            &spawner.messages(pid_b)[1],
            RendererControlMessage::UpsertPresentation(value)
                if value.presentation_id == presentation_b.as_uuid()
        ));
    }

    #[test]
    fn exact_publication_on_writable_workspace_completes_while_peer_is_backpressured() {
        let spawner = FakeSpawner::default();
        let mut core = new_core(spawner.clone(), ManualClock::default());
        let workspace_a = WorkspaceUuid::new();
        let workspace_b = WorkspaceUuid::new();
        let presentation_a = PresentationId::new();
        let presentation_b = PresentationId::new();
        core.set_presentation_workspace(presentation_a, Some(workspace_a));
        core.set_presentation_workspace(presentation_b, Some(workspace_b));
        let status_a = core.workspace_status(workspace_a).unwrap();
        let status_b = core.workspace_status(workspace_b).unwrap();
        let pid_a = status_a.pid.unwrap();
        let pid_b = status_b.pid.unwrap();
        core.accept_worker_envelope(
            workspace_a,
            status_a.renderer_epoch,
            pid_a,
            ready_envelope(pid_a),
        )
        .unwrap();
        core.accept_worker_envelope(
            workspace_b,
            status_b.renderer_epoch,
            pid_b,
            ready_envelope(pid_b),
        )
        .unwrap();

        spawner.set_send_would_block(pid_a, true);
        let response_a = begin_publication_for_test(
            &mut core,
            workspace_a,
            status_a.renderer_epoch,
            vec![RendererControlMessage::UpsertPresentation(attachment(presentation_a, 1))],
        );
        assert!(matches!(response_a.try_recv(), Err(std::sync::mpsc::TryRecvError::Empty)));
        let pending_a = core.workers.get(&workspace_a).unwrap();
        assert_eq!(pending_a.outbox.len(), 1);
        assert!(pending_a.outbox.pending_frame.is_some());
        assert!(pending_a.write_interest_enabled);
        assert!(pending_a.write_stall_deadline.is_some());
        assert!(pending_a.outbox.retained_reserved_bytes <= MAXIMUM_WORKER_OUTBOX_BYTES);
        let aggregate = core.queue_budget.snapshot();
        assert!(aggregate.messages <= MAXIMUM_SUPERVISOR_QUEUED_MESSAGES);
        assert!(aggregate.bytes <= MAXIMUM_SUPERVISOR_QUEUED_BYTES);

        let published_b = publish_for_test(
            &mut core,
            workspace_b,
            status_b.renderer_epoch,
            vec![RendererControlMessage::UpsertPresentation(attachment(presentation_b, 1))],
        )
        .unwrap();
        assert_eq!(published_b.renderer_epoch, status_b.renderer_epoch);
        assert!(matches!(
            &spawner.messages(pid_b)[1],
            RendererControlMessage::UpsertPresentation(value)
                if value.presentation_id == presentation_b.as_uuid()
        ));
        assert!(matches!(response_a.try_recv(), Err(std::sync::mpsc::TryRecvError::Empty)));

        spawner.set_send_would_block(pid_a, false);
        core.process_worker_event(RendererWorkerIdentity {
            workspace_uuid: workspace_a,
            renderer_epoch: status_a.renderer_epoch,
            process_id: Some(pid_a),
            process_instance_token: Some(RendererProcessInstanceToken {
                start_time_seconds: u64::from(pid_a),
                start_time_microseconds: u64::from(pid_a) ^ 0x5a5a,
            }),
        });
        assert_eq!(response_a.recv().unwrap().unwrap().renderer_epoch, status_a.renderer_epoch);
        let drained_a = core.workers.get(&workspace_a).unwrap();
        assert_eq!(drained_a.outbox.len(), 0);
        assert!(!drained_a.write_interest_enabled);
        assert!(drained_a.write_stall_deadline.is_none());
    }

    #[test]
    fn partial_nonblocking_frame_retains_accounting_until_final_byte() {
        let spawner = FakeSpawner::default();
        let mut core = new_core(spawner.clone(), ManualClock::default());
        let workspace = WorkspaceUuid::new();
        let presentation = PresentationId::new();
        core.set_presentation_workspace(presentation, Some(workspace));
        let status = core.workspace_status(workspace).unwrap();
        let pid = status.pid.unwrap();
        core.accept_worker_envelope(workspace, status.renderer_epoch, pid, ready_envelope(pid))
            .unwrap();
        let baseline = core.queue_budget.snapshot();
        spawner.set_maximum_write_size(pid, Some(3));
        core.send_if_epoch(
            workspace,
            status.renderer_epoch,
            vec![RendererControlMessage::UpsertPresentation(attachment(presentation, 1))],
        );
        assert_eq!(spawner.messages(pid).len(), 1);
        assert_eq!(core.queue_budget.snapshot().messages, baseline.messages + 1);
        let identity = RendererWorkerIdentity {
            workspace_uuid: workspace,
            renderer_epoch: status.renderer_epoch,
            process_id: Some(pid),
            process_instance_token: Some(RendererProcessInstanceToken {
                start_time_seconds: u64::from(pid),
                start_time_microseconds: u64::from(pid) ^ 0x5a5a,
            }),
        };
        for _ in 0..64 {
            if spawner.messages(pid).len() == 2 {
                break;
            }
            core.process_worker_event(identity);
        }
        assert_eq!(spawner.messages(pid).len(), 2);
        assert_eq!(core.queue_budget.snapshot(), baseline);
        let worker = core.workers.get(&workspace).unwrap();
        assert!(worker.outbox.pending_frame.is_none());
        assert!(!worker.write_interest_enabled);
        assert!(worker.write_stall_deadline.is_none());
    }

    #[test]
    fn exact_publication_queue_rejection_is_definite_and_keeps_worker_ready() {
        let spawner = FakeSpawner::default();
        let mut core = new_core(spawner.clone(), ManualClock::default());
        let workspace = WorkspaceUuid::new();
        let presentation = PresentationId::new();
        core.set_presentation_workspace(presentation, Some(workspace));
        let status = core.workspace_status(workspace).unwrap();
        let pid = status.pid.unwrap();
        core.accept_worker_envelope(workspace, status.renderer_epoch, pid, ready_envelope(pid))
            .unwrap();
        spawner.set_send_would_block(pid, true);
        for generation in 1..=MAXIMUM_WORKER_OUTBOX_LENGTH as u64 {
            core.send(
                workspace,
                RendererControlMessage::UpsertPresentation(attachment(presentation, generation)),
            )
            .unwrap();
        }
        let rejected = begin_publication_for_test(
            &mut core,
            workspace,
            status.renderer_epoch,
            vec![RendererControlMessage::UpsertPresentation(attachment(PresentationId::new(), 1))],
        )
        .recv()
        .unwrap();
        assert_eq!(rejected.unwrap_err(), RendererSupervisorError::QueueFull);
        assert_eq!(core.workspace_status(workspace).unwrap().state, RendererWorkerState::Ready);
        assert_eq!(core.workers[&workspace].outbox.len(), MAXIMUM_WORKER_OUTBOX_LENGTH);
        assert!(!spawner.record(pid).0, "definite queue rejection must not kill the worker");
    }

    #[test]
    fn write_stall_fails_only_the_exact_backpressured_worker() {
        let spawner = FakeSpawner::default();
        let clock = ManualClock::default();
        let mut core = new_core(spawner.clone(), clock.clone());
        let workspace_a = WorkspaceUuid::new();
        let workspace_b = WorkspaceUuid::new();
        let presentation_a = PresentationId::new();
        let presentation_b = PresentationId::new();
        core.set_presentation_workspace(presentation_a, Some(workspace_a));
        core.set_presentation_workspace(presentation_b, Some(workspace_b));
        let status_a = core.workspace_status(workspace_a).unwrap();
        let status_b = core.workspace_status(workspace_b).unwrap();
        let pid_a = status_a.pid.unwrap();
        let pid_b = status_b.pid.unwrap();
        core.accept_worker_envelope(
            workspace_a,
            status_a.renderer_epoch,
            pid_a,
            ready_envelope(pid_a),
        )
        .unwrap();
        core.accept_worker_envelope(
            workspace_b,
            status_b.renderer_epoch,
            pid_b,
            ready_envelope(pid_b),
        )
        .unwrap();
        spawner.set_send_would_block(pid_a, true);
        let response = begin_publication_for_test(
            &mut core,
            workspace_a,
            status_a.renderer_epoch,
            vec![RendererControlMessage::UpsertPresentation(attachment(presentation_a, 1))],
        );
        clock.advance(WORKER_WRITE_STALL_TIMEOUT + Duration::from_millis(1));
        core.process_due_timers();
        assert!(matches!(
            response.recv().unwrap(),
            Err(RendererSupervisorError::PublicationUncertain {
                workspace_uuid,
                renderer_epoch,
                ..
            }) if workspace_uuid == workspace_a && renderer_epoch == status_a.renderer_epoch
        ));
        assert_eq!(core.workspace_status(workspace_a).unwrap().state, RendererWorkerState::Backoff);
        assert_eq!(core.workspace_status(workspace_b).unwrap().state, RendererWorkerState::Ready);
        assert_eq!(spawner.messages(pid_b).len(), 1);
    }

    #[test]
    fn authenticated_renderer_replies_and_disconnect_emit_exact_lifecycle_events() {
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
                process_instance_token: RendererProcessInstanceToken {
                    start_time_seconds: u64::from(pid),
                    start_time_microseconds: u64::from(pid) ^ 0x5a5a,
                },
                effective_user_id: unsafe { libc::geteuid() },
                metrics,
            }]
        );

        let removal = RendererPresentationRemoval {
            terminal_id: terminal(),
            terminal_epoch: 9,
            presentation_id: presentation.as_uuid(),
            presentation_generation: 1,
        };
        core.send_if_epoch(
            workspace,
            status.renderer_epoch,
            vec![RendererControlMessage::RemovePresentation(removal)],
        );
        let removed = RendererPresentationRemoved {
            terminal_id: terminal(),
            terminal_epoch: 9,
            presentation_id: presentation.as_uuid(),
            presentation_generation: 1,
        };
        let envelope = RendererControlEnvelope::new(
            RendererControlDirection::WorkerToDaemon,
            4,
            RendererControlMessage::PresentationRemoved(removed.clone()),
        )
        .unwrap();
        core.accept_worker_envelope(workspace, status.renderer_epoch, pid, envelope).unwrap();
        assert_eq!(
            core.take_events(),
            vec![RendererSupervisorEvent::PresentationRemoved {
                workspace_uuid: workspace,
                renderer_epoch: status.renderer_epoch,
                process_id: pid,
                removal: removed,
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
    fn many_worker_shutdown_closes_controls_and_reaps_under_one_global_deadline() {
        const WORKER_COUNT: usize = 96;

        let spawner = FakeSpawner::default();
        let mut core = new_core(spawner.clone(), ManualClock::default());
        for _ in 0..WORKER_COUNT {
            core.set_presentation_workspace(PresentationId::new(), Some(WorkspaceUuid::new()));
        }
        let pids =
            core.statuses().into_iter().map(|status| status.pid.unwrap()).collect::<Vec<_>>();
        for pid in &pids {
            spawner.set_reap_delay(*pid, Duration::from_millis(30));
        }

        let started = Instant::now();
        core.shutdown();
        let elapsed = started.elapsed();

        assert!(
            elapsed < Duration::from_millis(400),
            "96 workers must share one retirement deadline, elapsed {elapsed:?}"
        );
        assert!(core.statuses().is_empty());
        assert!(spawner.all_reaped());
        assert!(pids.into_iter().all(|pid| spawner.control_closed(pid)));
    }

    #[test]
    fn retirement_reports_unreaped_identity_without_waiting_past_batch_deadline() {
        let mut spawner = FakeSpawner::default();
        let workspace_uuid = WorkspaceUuid::new();
        let process = spawner
            .spawn(&SpawnRequest {
                daemon_instance_id: daemon(),
                workspace_uuid,
                renderer_epoch: 77,
            })
            .unwrap();
        let pid = process.pid();
        spawner.set_reap_delay(pid, Duration::from_millis(100));
        let identity = RendererWorkerIdentity {
            workspace_uuid,
            renderer_epoch: 77,
            process_id: Some(pid),
            process_instance_token: process.process_instance_token(),
        };
        let reaper = RendererProcessReaper::start(Arc::new(|| {})).unwrap();
        let permit = reaper.try_acquire().unwrap();

        let started = Instant::now();
        let report = reaper.retire(
            vec![RetiredRendererProcess { identity, process, _permit: permit }],
            Duration::from_millis(10),
        );

        assert!(started.elapsed() < Duration::from_millis(80));
        assert_eq!(report.unreaped, vec![identity]);
        assert!(spawner.control_closed(pid));
        assert!(spawner.record(pid).0, "termination must be requested before reporting");
        assert!(!spawner.record(pid).1, "the background reaper still owns this process");
    }

    #[test]
    fn reaper_retry_command_recovers_transient_wait_error_without_new_process() {
        let mut spawner = FakeSpawner::default();
        let reaper = RendererProcessReaper::start(Arc::new(|| {})).unwrap();
        let first_workspace = WorkspaceUuid::new();
        let first = spawner
            .spawn(&SpawnRequest {
                daemon_instance_id: daemon(),
                workspace_uuid: first_workspace,
                renderer_epoch: 1,
            })
            .unwrap();
        let first_pid = first.pid();
        spawner.set_reap_delay(first_pid, Duration::from_millis(20));
        spawner.set_wait_failures(first_pid, 1);
        let first_identity = RendererWorkerIdentity {
            workspace_uuid: first_workspace,
            renderer_epoch: 1,
            process_id: Some(first_pid),
            process_instance_token: first.process_instance_token(),
        };
        let first_report = reaper.retire(
            vec![RetiredRendererProcess {
                identity: first_identity,
                process: first,
                _permit: reaper.try_acquire().unwrap(),
            }],
            Duration::ZERO,
        );
        assert_eq!(first_report.unreaped, vec![first_identity]);
        assert!(!spawner.record(first_pid).1, "a wait error is not proof of reap");
        assert!(reaper.wait_until_epoch_quiesced(
            first_workspace,
            first_identity.renderer_epoch,
            Duration::from_secs(1),
        ));
        assert!(spawner.record(first_pid).1, "retained wait failure must be retried");
    }

    #[test]
    fn reaper_retries_termination_before_blocking_wait() {
        let mut spawner = FakeSpawner::default();
        let reaper = RendererProcessReaper::start(Arc::new(|| {})).unwrap();
        let workspace_uuid = WorkspaceUuid::new();
        let process = spawner
            .spawn(&SpawnRequest {
                daemon_instance_id: daemon(),
                workspace_uuid,
                renderer_epoch: 1,
            })
            .unwrap();
        let pid = process.pid();
        spawner.set_terminate_failures(pid, 1);
        let identity = RendererWorkerIdentity {
            workspace_uuid,
            renderer_epoch: 1,
            process_id: Some(pid),
            process_instance_token: process.process_instance_token(),
        };

        let report = reaper.retire(
            vec![RetiredRendererProcess {
                identity,
                process,
                _permit: reaper.try_acquire().unwrap(),
            }],
            Duration::from_secs(1),
        );
        assert!(report.unreaped.is_empty());
        assert!(spawner.record(pid).0, "SIGKILL-equivalent termination must be retried");
        assert!(spawner.record(pid).1);
    }

    #[test]
    fn reaper_permits_bound_live_and_unreaped_processes() {
        let reaper = RendererProcessReaper::<FakeProcess>::start(Arc::new(|| {})).unwrap();
        let mut permits = (0..MAXIMUM_RENDERER_WORKERS)
            .map(|_| reaper.try_acquire().unwrap())
            .collect::<Vec<_>>();
        assert!(reaper.try_acquire().is_none());
        permits.pop();
        assert!(reaper.try_acquire().is_some());
    }

    #[test]
    fn command_process_retirement_closes_control_fd_and_reaps_real_pid() {
        use std::io::Read;

        let child = Command::new("/bin/sleep")
            .arg("60")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let pid = child.id();
        let (stream, mut peer) = std::os::unix::net::UnixStream::pair().unwrap();
        peer.set_read_timeout(Some(Duration::from_secs(1))).unwrap();
        let identity = RendererWorkerIdentity {
            workspace_uuid: WorkspaceUuid::new(),
            renderer_epoch: 1,
            process_id: Some(pid),
            process_instance_token: None,
        };
        let process =
            CommandRendererProcess { child, stream: Some(stream), process_instance_token: None };
        let reaper = RendererProcessReaper::start(Arc::new(|| {})).unwrap();
        let permit = reaper.try_acquire().unwrap();

        let report = reaper.retire(
            vec![RetiredRendererProcess { identity, process, _permit: permit }],
            Duration::from_secs(1),
        );

        assert!(report.unreaped.is_empty());
        let mut byte = [0_u8; 1];
        assert_eq!(peer.read(&mut byte).unwrap(), 0, "daemon control endpoint must be closed");
        assert_eq!(unsafe { libc::kill(pid as i32, 0) }, -1);
        assert_eq!(io::Error::last_os_error().raw_os_error(), Some(libc::ESRCH));
    }

    #[test]
    fn command_process_drop_is_a_fail_closed_kill_and_reap_backstop() {
        let child = Command::new("/bin/sleep")
            .arg("60")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let pid = child.id();
        let (stream, _peer) = std::os::unix::net::UnixStream::pair().unwrap();
        drop(CommandRendererProcess { child, stream: Some(stream), process_instance_token: None });

        assert_eq!(unsafe { libc::kill(pid as i32, 0) }, -1);
        assert_eq!(io::Error::last_os_error().raw_os_error(), Some(libc::ESRCH));
    }

    #[test]
    fn unpublished_child_guard_kills_and_reaps_after_post_spawn_failure() {
        let child = Command::new("/bin/sleep").arg("60").spawn().unwrap();
        let pid = child.id();

        drop(UnpublishedRendererChild::new(child));

        assert_eq!(unsafe { libc::kill(pid as i32, 0) }, -1);
        assert_eq!(io::Error::last_os_error().raw_os_error(), Some(libc::ESRCH));
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
