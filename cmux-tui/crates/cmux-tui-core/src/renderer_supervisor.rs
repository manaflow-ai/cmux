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
use std::sync::mpsc::{RecvTimeoutError, SyncSender, sync_channel};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use crate::renderer_control::{
    MAXIMUM_RENDERER_CONTROL_FRAME_LENGTH, RendererBootstrap, RendererControlDirection,
    RendererControlEncoder, RendererControlEnvelope, RendererControlError,
    RendererControlIncrementalDecoder, RendererControlMessage, RendererControlSessionStateMachine,
    RendererControlWire, RendererNeedsFullScene, RendererPresentationReady,
    RendererSceneCapabilities, RendererWorkerReady,
};
use crate::{DaemonInstanceId, PresentationId, WorkspaceUuid};
use serde::Serialize;

const DEFAULT_HELPER_NAME: &str = "cmux-terminal-renderer";
const CONTROL_FD: i32 = 198;
const CHILD_POLL_INTERVAL: Duration = Duration::from_millis(100);
const WORKER_RETIREMENT_DEADLINE: Duration = Duration::from_millis(250);
const COORDINATOR_RETIREMENT_DEADLINE: Duration = Duration::ZERO;
const WORKER_REAP_POLL_INTERVAL: Duration = Duration::from_millis(2);
const BACKGROUND_REAP_POLL_INTERVAL: Duration = Duration::from_millis(25);
const MAXIMUM_COMMAND_QUEUE_LENGTH: usize = 1_024;
const MAXIMUM_COMMAND_QUEUE_BYTES: usize = 72 * 1_024 * 1_024;
const COMMAND_QUEUE_RECOVERY_RESERVE_BYTES: usize = 1_024;
const MAXIMUM_COMMAND_QUEUE_ALLOCATED_SLOTS: usize = MAXIMUM_COMMAND_QUEUE_LENGTH * 2;
const MAXIMUM_WORKER_OUTBOX_LENGTH: usize = 128;
const MAXIMUM_WORKER_OUTBOX_BYTES: usize = 72 * 1_024 * 1_024;
const MAXIMUM_WORKER_OUTBOX_ALLOCATED_SLOTS: usize = MAXIMUM_WORKER_OUTBOX_LENGTH * 2;
const MAXIMUM_WORKER_RECEIVE_BATCH_BYTES: usize = 1_024 * 1_024;
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
    + MAXIMUM_RENDERER_WORKERS * WORKER_OUTBOX_FIXED_STORAGE_BYTES;
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
        let queue_budget = Arc::new(SupervisorQueueBudget::default());
        let shared = Arc::new(Shared::new(queue_budget.clone()));
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
                    queue_budget,
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
        self.shared.changed.notify_one();
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
        self.shared.changed.notify_one();
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
        state.enqueue(command)?;
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

struct Shared {
    state: Mutex<CoordinatorState>,
    desired_presentations: Mutex<DesiredPresentations>,
    statuses: Mutex<Vec<RendererWorkerStatus>>,
    event_handler: Mutex<Option<RendererSupervisorEventHandler>>,
    changed: Condvar,
}

impl Shared {
    fn new(queue_budget: Arc<SupervisorQueueBudget>) -> Self {
        Self {
            state: Mutex::new(CoordinatorState::new(queue_budget)),
            desired_presentations: Mutex::new(DesiredPresentations::default()),
            statuses: Mutex::new(Vec::new()),
            event_handler: Mutex::new(None),
            changed: Condvar::new(),
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
            Self::WorkspaceStatus { .. } | Self::RecoverWorkspaceOverflow { .. } => None,
        }
    }

    fn retained_message_count(&self) -> usize {
        match self {
            Self::SendIfEpoch { messages, .. } => messages.len(),
            #[cfg(test)]
            Self::SetPresentation { .. } => 1,
            Self::Send { .. }
            | Self::WorkspaceStatus { .. }
            | Self::RecoverWorkspaceOverflow { .. } => 1,
        }
    }

    fn dynamic_retained_byte_count(&self) -> usize {
        match self {
            Self::Send { message, .. } => message.dynamic_retained_byte_count(),
            Self::SendIfEpoch { messages, .. } => messages
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
            Self::WorkspaceStatus { .. } | Self::RecoverWorkspaceOverflow { .. } => 0,
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
                *shared.statuses.lock().unwrap() = Vec::new();
                return;
            }
            state.pop_front()
        };

        if let Some(command) = command {
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
                CoordinatorCommand::WorkspaceStatus { workspace_uuid, reply } => {
                    // Desired presentation changes use a coalescing side lane
                    // so visibility teardown cannot be blocked by a saturated
                    // command queue. Reconcile that lane before answering the
                    // ordered status query, otherwise the first attach can see
                    // `None` even though its visibility update completed first.
                    reconcile_desired_presentations(
                        shared,
                        core,
                        &mut desired_presentation_revision,
                    );
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
        reconcile_desired_presentations(shared, core, &mut desired_presentation_revision);
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
    fn send(&mut self, bytes: &[u8]) -> io::Result<()>;
    fn receive(&mut self, destination: &mut Vec<u8>) -> io::Result<ReceiveResult>;
    fn try_wait(&mut self) -> io::Result<Option<ExitStatus>>;
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
    dynamic_bytes: usize,
}

struct BoundedWorkerOutbox {
    messages: VecDeque<AccountedRendererMessage>,
    retained_dynamic_bytes: usize,
    queue_budget: Arc<SupervisorQueueBudget>,
}

impl BoundedWorkerOutbox {
    fn new(queue_budget: Arc<SupervisorQueueBudget>) -> Self {
        let messages = VecDeque::with_capacity(MAXIMUM_WORKER_OUTBOX_LENGTH);
        assert!(
            messages.capacity() <= MAXIMUM_WORKER_OUTBOX_ALLOCATED_SLOTS,
            "worker outbox allocation exceeded its fixed-storage reserve"
        );
        Self { messages, retained_dynamic_bytes: 0, queue_budget }
    }

    fn try_push(&mut self, message: RendererControlMessage) -> Result<(), RendererSupervisorError> {
        message.encoded_frame_length()?;
        let dynamic_bytes = message.dynamic_retained_byte_count();
        let dynamic_byte_limit =
            MAXIMUM_WORKER_OUTBOX_BYTES.saturating_sub(WORKER_OUTBOX_FIXED_STORAGE_BYTES);
        if self.messages.len() >= MAXIMUM_WORKER_OUTBOX_LENGTH
            || self.retained_dynamic_bytes.saturating_add(dynamic_bytes) > dynamic_byte_limit
            || !self.queue_budget.try_reserve_normal(1, dynamic_bytes)
        {
            return Err(RendererSupervisorError::QueueFull);
        }
        self.retained_dynamic_bytes = self.retained_dynamic_bytes.saturating_add(dynamic_bytes);
        self.messages.push_back(AccountedRendererMessage { message, dynamic_bytes });
        Ok(())
    }

    fn try_extend(
        &mut self,
        messages: Vec<RendererControlMessage>,
    ) -> Result<(), RendererSupervisorError> {
        let additional_count = messages.len();
        let mut additional_dynamic_bytes = 0_usize;
        for message in &messages {
            message.encoded_frame_length()?;
            additional_dynamic_bytes =
                additional_dynamic_bytes.saturating_add(message.dynamic_retained_byte_count());
        }
        let dynamic_byte_limit =
            MAXIMUM_WORKER_OUTBOX_BYTES.saturating_sub(WORKER_OUTBOX_FIXED_STORAGE_BYTES);
        if self.messages.len().saturating_add(additional_count) > MAXIMUM_WORKER_OUTBOX_LENGTH
            || self.retained_dynamic_bytes.saturating_add(additional_dynamic_bytes)
                > dynamic_byte_limit
            || !self.queue_budget.try_reserve_normal(additional_count, additional_dynamic_bytes)
        {
            return Err(RendererSupervisorError::QueueFull);
        }
        for message in messages {
            let dynamic_bytes = message.dynamic_retained_byte_count();
            self.messages.push_back(AccountedRendererMessage { message, dynamic_bytes });
        }
        self.retained_dynamic_bytes =
            self.retained_dynamic_bytes.saturating_add(additional_dynamic_bytes);
        Ok(())
    }

    fn pop_front(&mut self) -> Option<RendererControlMessage> {
        let queued = self.messages.pop_front()?;
        self.retained_dynamic_bytes =
            self.retained_dynamic_bytes.saturating_sub(queued.dynamic_bytes);
        self.queue_budget.release(1, queued.dynamic_bytes);
        Some(queued.message)
    }

    #[cfg(test)]
    fn len(&self) -> usize {
        self.messages.len()
    }

    #[cfg(test)]
    fn retained_byte_count(&self) -> usize {
        size_of::<Self>()
            .saturating_add(
                self.messages.capacity().saturating_mul(size_of::<AccountedRendererMessage>()),
            )
            .saturating_add(self.retained_dynamic_bytes)
    }

    #[cfg(test)]
    fn retained_dynamic_byte_count(&self) -> usize {
        self.retained_dynamic_bytes
    }
}

impl Default for BoundedWorkerOutbox {
    fn default() -> Self {
        Self::new(Arc::new(SupervisorQueueBudget::default()))
    }
}

impl Drop for BoundedWorkerOutbox {
    fn drop(&mut self) {
        self.queue_budget.release(self.messages.len(), self.retained_dynamic_bytes);
    }
}

struct Worker<P> {
    process: Option<P>,
    epoch: u64,
    // Maintained by keyed presentation deltas. Statuses are published every
    // coordinator tick, so they never rescan presentations per worker.
    visible_presentation_count: usize,
    restart_count: u64,
    failure_streak: u32,
    state: RendererWorkerState,
    retry_at: Option<Duration>,
    last_error: Option<String>,
    encoder: Option<RendererControlEncoder>,
    decoder: Option<RendererControlIncrementalDecoder>,
    session: Option<RendererControlSessionStateMachine>,
    outbox: BoundedWorkerOutbox,
    effective_user_id: Option<u32>,
    scene_capabilities: Option<RendererSceneCapabilities>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct RendererWorkerIdentity {
    workspace_uuid: WorkspaceUuid,
    renderer_epoch: u64,
    process_id: Option<u32>,
}

impl RendererWorkerIdentity {
    fn from_worker<P: RendererProcess>(workspace_uuid: WorkspaceUuid, worker: &Worker<P>) -> Self {
        Self {
            workspace_uuid,
            renderer_epoch: worker.epoch,
            process_id: worker.process.as_ref().map(RendererProcess::pid),
        }
    }
}

struct RetiredRendererProcess<P> {
    identity: RendererWorkerIdentity,
    process: P,
}

#[derive(Debug, Default, PartialEq, Eq)]
struct RendererRetirementReport {
    unreaped: Vec<RendererWorkerIdentity>,
}

/// Retire a batch with one deadline for the batch, never one timeout per PID.
/// All control descriptors close first, then all termination requests are
/// issued, then nonblocking wait probes reap the children collectively. Any
/// survivor moves to an isolated background reaper so the coordinator owns no
/// forgotten child and cannot block past `deadline_after`.
fn retire_renderer_processes<P: RendererProcess>(
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

    let deadline = Instant::now().checked_add(deadline_after).unwrap_or_else(Instant::now);
    reap_ready_processes(&mut retired);
    while !retired.is_empty() {
        let now = Instant::now();
        if now >= deadline {
            break;
        }
        thread::sleep(WORKER_REAP_POLL_INTERVAL.min(deadline.saturating_duration_since(now)));
        reap_ready_processes(&mut retired);
    }

    let unreaped = retired.iter().map(|entry| entry.identity).collect::<Vec<_>>();
    if !retired.is_empty() {
        let unreaped_for_diagnostic = unreaped.clone();
        if let Err(error) = thread::Builder::new()
            .name("cmux-renderer-reaper".to_owned())
            .spawn(move || background_reap_renderer_processes(retired))
        {
            eprintln!(
                "failed to start renderer background reaper for {:?}: {error}",
                unreaped_for_diagnostic
            );
        }
    }
    RendererRetirementReport { unreaped }
}

fn reap_ready_processes<P: RendererProcess>(retired: &mut Vec<RetiredRendererProcess<P>>) {
    let mut index = 0;
    while index < retired.len() {
        match retired[index].process.try_wait() {
            Ok(Some(_)) => {
                retired.swap_remove(index);
            }
            Ok(None) => index += 1,
            Err(error) => {
                eprintln!(
                    "failed to poll retired renderer worker {:?}: {error}",
                    retired[index].identity
                );
                index += 1;
            }
        }
    }
}

fn background_reap_renderer_processes<P: RendererProcess>(
    mut retired: Vec<RetiredRendererProcess<P>>,
) {
    while !retired.is_empty() {
        reap_ready_processes(&mut retired);
        if !retired.is_empty() {
            thread::sleep(BACKGROUND_REAP_POLL_INTERVAL);
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
    queue_budget: Arc<SupervisorQueueBudget>,
    next_epoch: Option<u64>,
    events: VecDeque<RendererSupervisorEvent>,
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
    ) -> Self {
        Self {
            spawner,
            clock,
            daemon_instance_id,
            initial_restart_delay,
            maximum_restart_delay,
            presentations: BTreeMap::new(),
            presentation_counts: BTreeMap::new(),
            workers: BTreeMap::new(),
            queue_budget,
            next_epoch: Some(1),
            events: VecDeque::new(),
            #[cfg(test)]
            last_reconciliation_operations: ReconciliationOperationCounts::default(),
        }
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
        for workspace in touched_workspaces
            .iter()
            .copied()
            .filter(|workspace| !self.presentation_counts.contains_key(workspace))
        {
            if let Some(mut worker) = self.workers.remove(&workspace) {
                #[cfg(test)]
                {
                    operations.existing_worker_visits += 1;
                }
                let identity = RendererWorkerIdentity::from_worker(workspace, &worker);
                if let Some(process) = worker.process.take() {
                    retired.push(RetiredRendererProcess { identity, process });
                }
                unavailable.push(identity);
            }
        }
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
            } else if self.workers.len() < MAXIMUM_RENDERER_WORKERS {
                self.spawn_initial(workspace, visible_presentation_count);
            }
        }
        // Every retired identity is absent from `workers` before the first
        // control descriptor is closed or process is signalled.
        let retirement = retire_renderer_processes(retired, COORDINATOR_RETIREMENT_DEADLINE);
        for identity in unavailable {
            let mut reason = "workspace is no longer visible".to_owned();
            if retirement.unreaped.contains(&identity) {
                reason.push_str("; renderer reap deferred after global retirement deadline");
            }
            self.events.push_back(RendererSupervisorEvent::WorkerUnavailable {
                workspace_uuid: identity.workspace_uuid,
                renderer_epoch: identity.renderer_epoch,
                process_id: identity.process_id,
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
                self.workers.insert(workspace_uuid, worker);
            }
            Err(error) => {
                self.workers.insert(
                    workspace_uuid,
                    Worker {
                        process: None,
                        epoch: u64::MAX,
                        visible_presentation_count,
                        restart_count: 0,
                        failure_streak: 1,
                        state: RendererWorkerState::Backoff,
                        retry_at: None,
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
        outbox: BoundedWorkerOutbox,
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
                        visible_presentation_count: 0,
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
                        let identity = RendererWorkerIdentity {
                            workspace_uuid,
                            renderer_epoch: epoch,
                            process_id: Some(process.pid()),
                        };
                        let retirement = retire_renderer_processes(
                            vec![RetiredRendererProcess { identity, process }],
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
            epoch,
            visible_presentation_count: 0,
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
        worker.outbox.try_push(message)?;
        if worker.state == RendererWorkerState::Ready {
            flush_worker_outbox(worker)?;
        }
        Ok(())
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
            flush_worker_outbox(worker)?;
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
        let mut failures = Vec::new();
        for workspace_uuid in workspaces {
            if let Some(error) = self.poll_worker(workspace_uuid) {
                failures.push((workspace_uuid, error));
            }
        }
        self.workers_failed(failures);
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

    fn poll_worker(&mut self, workspace_uuid: WorkspaceUuid) -> Option<String> {
        let mut received = Vec::new();
        let outcome = {
            let worker = self.workers.get_mut(&workspace_uuid)?;
            let process = worker.process.as_mut()?;
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
            return Some(error);
        }
        if received.is_empty() {
            return None;
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
                        return Some(error.to_string());
                    }
                }
                None
            }
            Err(error) => Some(error.to_string()),
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
                flush_worker_outbox(worker)?;
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
        self.workers_failed(vec![(workspace_uuid, error)]);
    }

    fn workers_failed(&mut self, failures: Vec<(WorkspaceUuid, String)>) {
        let mut retired = Vec::new();
        let mut unavailable = Vec::new();
        for (workspace_uuid, error) in failures {
            let Some(mut previous) = self.workers.remove(&workspace_uuid) else {
                continue;
            };
            let identity = RendererWorkerIdentity::from_worker(workspace_uuid, &previous);
            if let Some(process) = previous.process.take() {
                retired.push(RetiredRendererProcess { identity, process });
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
            self.workers.insert(workspace_uuid, backoff);
            unavailable.push((identity, error));
        }
        let retirement = retire_renderer_processes(retired, COORDINATOR_RETIREMENT_DEADLINE);
        for (identity, mut reason) in unavailable {
            if retirement.unreaped.contains(&identity) {
                reason.push_str("; renderer reap deferred after global retirement deadline");
            }
            self.events.push_back(RendererSupervisorEvent::WorkerUnavailable {
                workspace_uuid: identity.workspace_uuid,
                renderer_epoch: identity.renderer_epoch,
                process_id: identity.process_id,
                reason,
            });
        }
    }

    fn restart_worker(&mut self, workspace_uuid: WorkspaceUuid) {
        let Some(previous) = self.workers.remove(&workspace_uuid) else { return };
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
                self.workers.insert(workspace_uuid, worker);
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
        RendererWorkerStatus {
            workspace_uuid,
            renderer_epoch: worker.epoch,
            pid: worker.process.as_ref().map(RendererProcess::pid),
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
        let workers = std::mem::take(&mut self.workers);
        self.presentations.clear();
        self.presentation_counts.clear();
        let retired = workers
            .into_iter()
            .filter_map(|(workspace_uuid, mut worker)| {
                let identity = RendererWorkerIdentity::from_worker(workspace_uuid, &worker);
                worker.process.take().map(|process| RetiredRendererProcess { identity, process })
            })
            .collect();
        let retirement = retire_renderer_processes(retired, WORKER_RETIREMENT_DEADLINE);
        for identity in retirement.unreaped {
            eprintln!(
                "cmux renderer worker {} epoch {} pid {:?} exceeded the global reap deadline; background reaper owns it",
                identity.workspace_uuid, identity.renderer_epoch, identity.process_id
            );
        }
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

fn flush_worker_outbox<P: RendererProcess>(
    worker: &mut Worker<P>,
) -> Result<(), RendererSupervisorError> {
    while let Some(message) = worker.outbox.pop_front() {
        send_control_message(worker, message)?;
    }
    Ok(())
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
        Ok(CommandRendererProcess { child, stream: Some(stream) })
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
}

#[cfg(unix)]
impl RendererProcess for CommandRendererProcess {
    fn pid(&self) -> u32 {
        self.child.id()
    }

    fn send(&mut self, bytes: &[u8]) -> io::Result<()> {
        self.stream
            .as_mut()
            .ok_or_else(|| io::Error::new(io::ErrorKind::BrokenPipe, "renderer control closed"))?
            .write_all(bytes)
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

    fn close_control(&mut self) {
        self.stream.take();
    }

    fn terminate(&mut self) -> io::Result<()> {
        if self.child.try_wait()?.is_none() {
            self.child.kill()?;
        }
        Ok(())
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
    fn close_control(&mut self) {}
    fn terminate(&mut self) -> io::Result<()> {
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
        control_closed: bool,
        terminated: bool,
        reaped: bool,
        terminated_at: Option<Instant>,
        reap_delay: Duration,
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

        fn control_closed(&self, pid: u32) -> bool {
            self.0.lock().unwrap().processes[&pid].control_closed
        }

        fn set_reap_delay(&self, pid: u32, reap_delay: Duration) {
            self.0.lock().unwrap().processes.get_mut(&pid).unwrap().reap_delay = reap_delay;
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
            record.terminated = true;
            record.terminated_at = Some(Instant::now());
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

        for (index, outbox) in outboxes.iter_mut().enumerate().take(3) {
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
        assert_eq!(before_rejection.messages, 3);
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
            outboxes[3]
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
        assert_eq!(outboxes[3].len(), 0);

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
            assert_eq!(queue_budget.snapshot().bytes, baseline.bytes);
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
        shared.changed.notify_all();
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
        let identity =
            RendererWorkerIdentity { workspace_uuid, renderer_epoch: 77, process_id: Some(pid) };

        let started = Instant::now();
        let report = retire_renderer_processes(
            vec![RetiredRendererProcess { identity, process }],
            Duration::from_millis(10),
        );

        assert!(started.elapsed() < Duration::from_millis(80));
        assert_eq!(report.unreaped, vec![identity]);
        assert!(spawner.control_closed(pid));
        assert!(spawner.record(pid).0, "termination must be requested before reporting");
        assert!(!spawner.record(pid).1, "the background reaper still owns this process");
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
        };
        let process = CommandRendererProcess { child, stream: Some(stream) };

        let report = retire_renderer_processes(
            vec![RetiredRendererProcess { identity, process }],
            Duration::from_secs(1),
        );

        assert!(report.unreaped.is_empty());
        let mut byte = [0_u8; 1];
        assert_eq!(peer.read(&mut byte).unwrap(), 0, "daemon control endpoint must be closed");
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
