use std::collections::{BTreeMap, HashMap, VecDeque};
#[cfg(not(unix))]
use std::io::{Read, Write};
#[cfg(unix)]
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex as StdMutex};

use cmux_remote_protocol::{
    ByteString, OperationId, ProcessEnvironment, ProcessEvent, ProcessId, ProcessIo,
    ProcessLifetime, ProcessReplayRange, ProcessSignal, PtyEofPolicy, RpcError, RpcErrorDetails,
    RpcEvent, WorkspaceId, WorkspaceResponse,
};
#[cfg(not(unix))]
use portable_pty::ChildKiller;
use portable_pty::{CommandBuilder, MasterPty, PtySize, native_pty_system};
use sha2::{Digest, Sha256};
#[cfg(unix)]
use tokio::io::unix::AsyncFd;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWriteExt};
use tokio::process::ChildStdin;
#[cfg(unix)]
use tokio::sync::oneshot;
use tokio::sync::{Mutex, Notify, RwLock, Semaphore, broadcast, watch};

use super::ClientScope;
use super::path::WorkspaceRoot;

const MAX_PROCESSES: usize = 64;
const MAX_PTY_PROCESSES: usize = 16;
// Keep one interactive RPC below one carrier frame after JSON/base64 framing.
// Large stdin producers chunk with increasing write IDs, which also gives the
// interactive scheduler a fairness point between writes.
const MAX_PROCESS_WRITE_BYTES: usize = 32 * 1024;
const PROCESS_EVENT_CAPACITY: usize = 512;
const PROCESS_EVENT_BYTES: usize = 4 * 1024 * 1024;
const PROCESS_BROADCAST_CAPACITY: usize = 64;
const MAX_REMEMBERED_WRITE_IDS: usize = 4_096;
const PROCESS_READ_CHUNK: usize = 64 * 1024;
const PROCESS_OUTPUT_DRAIN_TIMEOUT: std::time::Duration = std::time::Duration::from_millis(250);
const MAX_PTY_DIMENSION: u16 = 4_096;
const MAX_PROCESS_ARGUMENTS: usize = 4_096;
const MAX_PROCESS_ENVIRONMENT: usize = 4_096;
const MAX_PROCESS_CONFIGURATION_BYTES: usize = 4 * 1024 * 1024;
const TERMINATION_GRACE: std::time::Duration = std::time::Duration::from_secs(2);
const MAX_PROCESS_REPLAY_EVENTS: u32 = 1_024;
const MAX_PROCESS_TIMEOUT_MS: u64 = 7 * 24 * 60 * 60 * 1_000;
const MAX_OPERATION_ID_BYTES: usize = 256;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct ExitOutcome {
    code: Option<i32>,
    signal: Option<i32>,
}

enum InputWriter {
    None,
    Pipe(ChildStdin),
    #[cfg(unix)]
    Pty(Arc<AsyncPty>),
    #[cfg(not(unix))]
    Pty(Box<dyn Write + Send>),
}

#[cfg(unix)]
struct AsyncPty {
    fd: AsyncFd<OwnedFd>,
}

#[cfg(unix)]
impl AsyncPty {
    fn from_master(master: &dyn MasterPty) -> std::io::Result<Arc<Self>> {
        let raw = master
            .as_raw_fd()
            .ok_or_else(|| std::io::Error::other("PTY master has no file descriptor"))?;
        let duplicated = unsafe { libc::fcntl(raw, libc::F_DUPFD_CLOEXEC, 0) };
        if duplicated < 0 {
            return Err(std::io::Error::last_os_error());
        }
        let flags = unsafe { libc::fcntl(duplicated, libc::F_GETFL) };
        if flags < 0
            || unsafe { libc::fcntl(duplicated, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0
        {
            let error = std::io::Error::last_os_error();
            let _ = unsafe { libc::close(duplicated) };
            return Err(error);
        }
        let fd = unsafe { OwnedFd::from_raw_fd(duplicated) };
        Ok(Arc::new(Self { fd: AsyncFd::new(fd)? }))
    }

    async fn read(&self, buffer: &mut [u8]) -> std::io::Result<usize> {
        loop {
            let mut ready = self.fd.readable().await?;
            match ready.try_io(|fd| {
                let read = unsafe {
                    libc::read(fd.get_ref().as_raw_fd(), buffer.as_mut_ptr().cast(), buffer.len())
                };
                if read < 0 { Err(std::io::Error::last_os_error()) } else { Ok(read as usize) }
            }) {
                Ok(Err(error)) if error.kind() == std::io::ErrorKind::Interrupted => continue,
                Ok(result) => return result,
                Err(_) => continue,
            }
        }
    }

    async fn write_all(&self, bytes: &[u8]) -> std::io::Result<()> {
        let mut offset = 0;
        while offset < bytes.len() {
            let mut ready = self.fd.writable().await?;
            match ready.try_io(|fd| {
                let written = unsafe {
                    libc::write(
                        fd.get_ref().as_raw_fd(),
                        bytes[offset..].as_ptr().cast(),
                        bytes.len() - offset,
                    )
                };
                if written < 0 {
                    Err(std::io::Error::last_os_error())
                } else {
                    Ok(written as usize)
                }
            }) {
                Ok(Ok(0)) => return Err(std::io::Error::from(std::io::ErrorKind::WriteZero)),
                Ok(Ok(written)) => offset += written,
                Ok(Err(error)) if error.kind() == std::io::ErrorKind::Interrupted => continue,
                Ok(Err(error)) => return Err(error),
                Err(_) => continue,
            }
        }
        Ok(())
    }
}

struct InputState {
    writer: InputWriter,
    writes: HashMap<u64, WriteRecord>,
    accepted_order: VecDeque<u64>,
    highest_write_id: Option<u64>,
}

#[derive(Clone, Copy, PartialEq, Eq)]
struct WriteFingerprint {
    digest: [u8; 32],
    eof: bool,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum WriteOutcome {
    Uncertain,
    Accepted,
}

#[derive(Clone, Copy)]
struct WriteRecord {
    fingerprint: WriteFingerprint,
    outcome: WriteOutcome,
}

enum WriteStart {
    New,
    AlreadyAccepted,
}

impl InputState {
    fn new(writer: InputWriter) -> Self {
        Self {
            writer,
            writes: HashMap::new(),
            accepted_order: VecDeque::new(),
            highest_write_id: None,
        }
    }

    fn begin_write(
        &mut self,
        write_id: u64,
        fingerprint: WriteFingerprint,
    ) -> Result<WriteStart, RpcError> {
        if let Some(previous) = self.writes.get(&write_id) {
            if previous.fingerprint != fingerprint {
                return Err(RpcError::new(
                    "write-id-conflict",
                    format!("write id {write_id} was reused with different data or EOF state"),
                ));
            }
            return match previous.outcome {
                WriteOutcome::Accepted => Ok(WriteStart::AlreadyAccepted),
                WriteOutcome::Uncertain => Err(RpcError::new(
                    "write-outcome-unknown",
                    format!("write id {write_id} may have been partially applied"),
                )),
            };
        }

        if self.highest_write_id.is_some_and(|highest| write_id <= highest) {
            return Err(RpcError::new(
                "stale-write-id",
                format!("write id {write_id} is older than the retained idempotency window"),
            ));
        }
        self.highest_write_id = Some(write_id);
        self.writes.insert(write_id, WriteRecord { fingerprint, outcome: WriteOutcome::Uncertain });
        self.accepted_order.push_back(write_id);
        while self.accepted_order.len() > MAX_REMEMBERED_WRITE_IDS {
            if let Some(evicted) = self.accepted_order.pop_front() {
                self.writes.remove(&evicted);
            }
        }
        Ok(WriteStart::New)
    }

    fn accept_write(&mut self, write_id: u64) {
        if let Some(record) = self.writes.get_mut(&write_id) {
            record.outcome = WriteOutcome::Accepted;
        }
    }
}

#[derive(Clone)]
struct ProcessEventLog {
    inner: Arc<ProcessEventLogInner>,
}

struct ProcessEventLogInner {
    next_sequence: AtomicU64,
    history: StdMutex<EventHistory>,
    live: broadcast::Sender<RpcEvent>,
    retained_bytes_limit: usize,
}

#[derive(Default)]
struct EventHistory {
    events: VecDeque<RpcEvent>,
    retained_bytes: usize,
    exited: bool,
}

impl ProcessEventLog {
    fn new(retained_bytes_limit: usize) -> Self {
        let (live, _) = broadcast::channel(PROCESS_BROADCAST_CAPACITY);
        Self {
            inner: Arc::new(ProcessEventLogInner {
                next_sequence: AtomicU64::new(1),
                history: StdMutex::new(EventHistory::default()),
                live,
                retained_bytes_limit,
            }),
        }
    }

    fn publish_output(&self, process: ProcessId, stderr: bool, bytes: &[u8]) {
        let data = ByteString::from_bytes(bytes);
        self.publish(|sequence| {
            let event = if stderr {
                ProcessEvent::Stderr { process, sequence, data }
            } else {
                ProcessEvent::Stdout { process, sequence, data }
            };
            RpcEvent { sequence, event }
        });
    }

    fn publish_exit(&self, process: ProcessId, outcome: ExitOutcome) {
        self.publish(|sequence| RpcEvent {
            sequence,
            event: ProcessEvent::Exit { process, code: outcome.code, signal: outcome.signal },
        });
    }

    fn publish(&self, make_event: impl FnOnce(u64) -> RpcEvent) {
        let mut history =
            self.inner.history.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        // Sequence allocation, retention, and broadcast publication share one
        // critical section. Subscribers therefore observe exactly the same
        // total order in replay history and on the live channel.
        let sequence = self.inner.next_sequence.fetch_add(1, Ordering::Relaxed);
        let event = make_event(sequence);
        let retained = event_size(&event);
        history.exited |= matches!(event.event, ProcessEvent::Exit { .. });
        history.retained_bytes = history.retained_bytes.saturating_add(retained);
        history.events.push_back(event.clone());
        while history.events.len() > PROCESS_EVENT_CAPACITY
            || history.retained_bytes > self.inner.retained_bytes_limit
        {
            let Some(evicted) = history.events.pop_front() else { break };
            history.retained_bytes = history.retained_bytes.saturating_sub(event_size(&evicted));
        }
        let _ = self.inner.live.send(event);
    }

    fn subscribe(
        &self,
        after_sequence: u64,
        exited: bool,
    ) -> Result<ProcessSubscription, RpcError> {
        let history = self.inner.history.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let next_sequence = self.inner.next_sequence.load(Ordering::Acquire);
        if after_sequence >= next_sequence {
            return Err(RpcError::new(
                "invalid-replay-cursor",
                format!("process has not produced sequence {after_sequence}"),
            ));
        }
        let exited = exited || history.exited;
        let range = replay_range(&history, next_sequence, exited);
        let replay_gap =
            range.first_available.map_or(after_sequence < range.last_produced, |first| {
                after_sequence.saturating_add(1) < first
            });
        if replay_gap {
            return Err(RpcError::new(
                "replay-unavailable",
                format!(
                    "requested process replay is outside retained range {:?}..={}",
                    range.first_available, range.last_produced
                ),
            )
            .with_details(RpcErrorDetails::ProcessReplayGap {
                requested_after: after_sequence,
                range,
            }));
        }
        let replay = history
            .events
            .iter()
            .filter(|event| event.sequence > after_sequence)
            .cloned()
            .collect();
        let live = self.inner.live.subscribe();
        Ok(ProcessSubscription {
            replay,
            live,
            events: self.clone(),
            last_delivered: after_sequence,
            terminal: exited,
        })
    }

    fn read(
        &self,
        process: ProcessId,
        after_sequence: u64,
        limit: u32,
        exited: bool,
    ) -> Result<WorkspaceResponse, RpcError> {
        if limit == 0 || limit > MAX_PROCESS_REPLAY_EVENTS {
            return Err(RpcError::new(
                "invalid-argument",
                format!("process replay limit must be between 1 and {MAX_PROCESS_REPLAY_EVENTS}"),
            ));
        }
        let history = self.inner.history.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let next_sequence = self.inner.next_sequence.load(Ordering::Acquire);
        let range = replay_range(&history, next_sequence, exited || history.exited);
        let replay_gap =
            range.first_available.map_or(after_sequence < range.last_produced, |first| {
                after_sequence.saturating_add(1) < first
            });
        if replay_gap {
            return Ok(WorkspaceResponse::ProcessReplayGap {
                process,
                requested_after: after_sequence,
                range,
            });
        }
        if after_sequence >= next_sequence {
            return Err(RpcError::new(
                "invalid-replay-cursor",
                format!("process has not produced sequence {after_sequence}"),
            ));
        }
        let limit = usize::try_from(limit).unwrap_or(usize::MAX);
        let mut events = history
            .events
            .iter()
            .filter(|event| event.sequence > after_sequence)
            .take(limit.saturating_add(1))
            .cloned()
            .collect::<Vec<_>>();
        let has_more = events.len() > limit;
        events.truncate(limit);
        let next_cursor =
            has_more.then(|| events.last().map_or(after_sequence, |event| event.sequence));
        Ok(WorkspaceResponse::ProcessEvents { process, range, events, next_cursor })
    }
}

fn replay_range(history: &EventHistory, next_sequence: u64, exited: bool) -> ProcessReplayRange {
    ProcessReplayRange {
        first_available: history.events.front().map(|event| event.sequence),
        last_produced: next_sequence.saturating_sub(1),
        exited,
    }
}

pub struct ProcessSubscription {
    replay: VecDeque<RpcEvent>,
    live: broadcast::Receiver<RpcEvent>,
    events: ProcessEventLog,
    last_delivered: u64,
    terminal: bool,
}

impl ProcessSubscription {
    pub async fn recv(&mut self) -> Result<RpcEvent, broadcast::error::RecvError> {
        loop {
            if let Some(event) = self.replay.pop_front() {
                self.last_delivered = event.sequence;
                self.terminal |= matches!(event.event, ProcessEvent::Exit { .. });
                return Ok(event);
            }
            if self.terminal {
                return Err(broadcast::error::RecvError::Closed);
            }
            match self.live.recv().await {
                Ok(event) if event.sequence <= self.last_delivered => continue,
                Ok(event) => {
                    self.last_delivered = event.sequence;
                    self.terminal |= matches!(event.event, ProcessEvent::Exit { .. });
                    return Ok(event);
                }
                Err(broadcast::error::RecvError::Lagged(skipped)) => {
                    let history = self
                        .events
                        .inner
                        .history
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner);
                    let first = history.events.front().map(|event| event.sequence);
                    if first.is_some_and(|first| self.last_delivered.saturating_add(1) < first) {
                        return Err(broadcast::error::RecvError::Lagged(skipped));
                    }
                    self.replay = history
                        .events
                        .iter()
                        .filter(|event| event.sequence > self.last_delivered)
                        .cloned()
                        .collect();
                }
                Err(error) => return Err(error),
            }
        }
    }
}

type SharedMasterPty = Arc<StdMutex<Option<Box<dyn MasterPty + Send>>>>;

struct ProcessRecord {
    id: ProcessId,
    owner: ClientScope,
    workspace: WorkspaceId,
    lifetime: ProcessLifetime,
    operation: Option<OperationId>,
    pid: Option<u32>,
    signal_process_group: bool,
    write_serial: Mutex<()>,
    input: Mutex<InputState>,
    master: Option<SharedMasterPty>,
    pty_eof: Option<PtyEofPolicy>,
    #[cfg(not(unix))]
    killer: Option<Arc<StdMutex<Box<dyn ChildKiller + Send + Sync>>>>,
    events: ProcessEventLog,
    exit: watch::Receiver<Option<ExitOutcome>>,
    /// Set immediately after the direct child is reaped. PID and process-group
    /// IDs may be reused after this point, even while output is still draining.
    target_exited: Arc<AtomicBool>,
    target_exit_notify: Arc<Notify>,
    /// Set after bounded output drain and exit-event publication complete.
    finished: Arc<AtomicBool>,
}

struct PendingProcessGuard {
    armed: bool,
    #[cfg(unix)]
    pid: Option<u32>,
    #[cfg(unix)]
    signal_process_group: bool,
    #[cfg(unix)]
    target_exited: Option<Arc<AtomicBool>>,
    #[cfg(not(unix))]
    killer: Option<Arc<StdMutex<Box<dyn ChildKiller + Send + Sync>>>>,
}

impl PendingProcessGuard {
    #[cfg(unix)]
    fn new(pid: Option<u32>, signal_process_group: bool) -> Self {
        Self { armed: true, pid, signal_process_group, target_exited: None }
    }

    #[cfg(unix)]
    fn update_target(&mut self, pid: Option<u32>, target_exited: Arc<AtomicBool>) {
        self.pid = pid;
        self.target_exited = Some(target_exited);
    }

    #[cfg(not(unix))]
    fn new(killer: Option<Arc<StdMutex<Box<dyn ChildKiller + Send + Sync>>>>) -> Self {
        Self { armed: true, killer }
    }

    fn disarm(&mut self) {
        self.armed = false;
    }
}

impl Drop for PendingProcessGuard {
    fn drop(&mut self) {
        if !self.armed {
            return;
        }
        #[cfg(unix)]
        if self.target_exited.as_ref().is_some_and(|exited| exited.load(Ordering::Acquire)) {
            return;
        }
        #[cfg(unix)]
        if let Some(pid) = self.pid.and_then(|pid| i32::try_from(pid).ok()) {
            let target = if self.signal_process_group { -pid } else { pid };
            let _ = unsafe { libc::kill(target, libc::SIGKILL) };
        }
        #[cfg(not(unix))]
        if let Some(killer) = &self.killer {
            let _ = killer.lock().unwrap_or_else(std::sync::PoisonError::into_inner).kill();
        }
    }
}

impl std::fmt::Debug for ProcessRecord {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("ProcessRecord")
            .field("id", &self.id)
            .field("workspace", &self.workspace)
            .field("lifetime", &self.lifetime)
            .field("pid", &self.pid)
            .field("finished", &self.finished.load(Ordering::Acquire))
            .finish_non_exhaustive()
    }
}

pub(super) struct ProcessSpawnOptions {
    pub(super) owner: ClientScope,
    pub(super) argv: Vec<String>,
    pub(super) cwd: Option<String>,
    pub(super) env: BTreeMap<String, String>,
    pub(super) io: ProcessIo,
    pub(super) lifetime: ProcessLifetime,
    pub(super) operation: Option<OperationId>,
    pub(super) timeout_ms: Option<u64>,
    pub(super) retained_output_bytes: Option<u32>,
    pub(super) environment: ProcessEnvironment,
}

pub(crate) struct ProcessManager {
    next_id: AtomicU64,
    spawn_serial: Mutex<()>,
    processes: RwLock<HashMap<ProcessId, Arc<ProcessRecord>>>,
    pty_slots: Arc<Semaphore>,
}

impl Default for ProcessManager {
    fn default() -> Self {
        Self {
            next_id: AtomicU64::new(1),
            spawn_serial: Mutex::new(()),
            processes: RwLock::new(HashMap::new()),
            pty_slots: Arc::new(Semaphore::new(MAX_PTY_PROCESSES)),
        }
    }
}

impl ProcessManager {
    pub(crate) async fn spawn(
        &self,
        root: Arc<WorkspaceRoot>,
        options: ProcessSpawnOptions,
    ) -> Result<WorkspaceResponse, RpcError> {
        let ProcessSpawnOptions {
            owner,
            argv,
            cwd,
            env,
            io,
            lifetime,
            operation,
            timeout_ms,
            retained_output_bytes,
            environment,
        } = options;
        if argv.is_empty() || argv[0].is_empty() {
            return Err(RpcError::new("invalid-argument", "process argv cannot be empty"));
        }
        if argv.iter().any(|argument| argument.contains('\0')) {
            return Err(RpcError::new(
                "invalid-argument",
                "process arguments cannot contain NUL bytes",
            ));
        }
        if argv.len() > MAX_PROCESS_ARGUMENTS || env.len() > MAX_PROCESS_ENVIRONMENT {
            return Err(RpcError::new(
                "resource-exhausted",
                format!(
                    "process accepts at most {MAX_PROCESS_ARGUMENTS} arguments and {MAX_PROCESS_ENVIRONMENT} environment entries"
                ),
            ));
        }
        let configuration_bytes = argv
            .iter()
            .chain(env.iter().flat_map(|(key, value)| [key, value]))
            .fold(0usize, |total, value| total.saturating_add(value.len()));
        if configuration_bytes > MAX_PROCESS_CONFIGURATION_BYTES {
            return Err(RpcError::new(
                "resource-exhausted",
                format!("process configuration exceeds {MAX_PROCESS_CONFIGURATION_BYTES} bytes"),
            ));
        }
        validate_environment(&env)?;
        if operation.as_ref().is_some_and(|operation| {
            operation.0.is_empty() || operation.0.len() > MAX_OPERATION_ID_BYTES
        }) {
            return Err(RpcError::new(
                "invalid-operation",
                format!("operation ID must contain between 1 and {MAX_OPERATION_ID_BYTES} bytes"),
            ));
        }
        if timeout_ms.is_some_and(|timeout| timeout == 0 || timeout > MAX_PROCESS_TIMEOUT_MS) {
            return Err(RpcError::new(
                "invalid-argument",
                format!("process timeout must be between 1 and {MAX_PROCESS_TIMEOUT_MS} ms"),
            ));
        }
        let cwd = match cwd {
            Some(cwd) => root.resolve_existing(&cwd).await?,
            None => root.canonical_root().to_owned(),
        };
        let metadata = tokio::fs::metadata(&cwd)
            .await
            .map_err(|error| RpcError::new("invalid-cwd", error.to_string()))?;
        if !metadata.is_dir() {
            return Err(RpcError::new("invalid-cwd", "process cwd is not a directory"));
        }
        let _spawn_guard = self.spawn_serial.lock().await;
        self.reserve_capacity().await?;
        let id = ProcessId(self.next_id.fetch_add(1, Ordering::Relaxed));
        let operation = match (lifetime, operation) {
            (ProcessLifetime::Operation, Some(operation)) => Some(operation),
            (ProcessLifetime::Operation, None) => {
                Some(OperationId(format!("process-{}-{}", id.0, uuid::Uuid::new_v4())))
            }
            (_, Some(_)) => {
                return Err(RpcError::new(
                    "invalid-operation",
                    "operation id requires operation process lifetime",
                ));
            }
            (_, None) => None,
        };
        let retained_output_bytes = retained_output_bytes
            .map(|bytes| usize::try_from(bytes).unwrap_or(usize::MAX))
            .unwrap_or(PROCESS_EVENT_BYTES);
        if retained_output_bytes > PROCESS_EVENT_BYTES {
            return Err(RpcError::new(
                "resource-exhausted",
                format!("retained process output exceeds {PROCESS_EVENT_BYTES} bytes"),
            ));
        }

        match io {
            ProcessIo::Pipes { stdin } => {
                self.spawn_pipes(
                    id,
                    owner,
                    root.id.clone(),
                    argv,
                    cwd,
                    env,
                    stdin,
                    lifetime,
                    operation,
                    timeout_ms,
                    retained_output_bytes,
                    environment,
                )
                .await
            }
            ProcessIo::Pty { cols, rows, term, eof } => {
                self.spawn_pty(
                    id,
                    owner,
                    root.id.clone(),
                    argv,
                    cwd,
                    env,
                    cols,
                    rows,
                    term,
                    eof,
                    lifetime,
                    operation,
                    timeout_ms,
                    retained_output_bytes,
                    environment,
                )
                .await
            }
        }
    }

    #[allow(clippy::too_many_arguments)]
    async fn spawn_pipes(
        &self,
        id: ProcessId,
        owner: ClientScope,
        workspace: WorkspaceId,
        argv: Vec<String>,
        cwd: std::path::PathBuf,
        env: BTreeMap<String, String>,
        writable_stdin: bool,
        lifetime: ProcessLifetime,
        operation: Option<OperationId>,
        timeout_ms: Option<u64>,
        retained_output_bytes: usize,
        environment: ProcessEnvironment,
    ) -> Result<WorkspaceResponse, RpcError> {
        let mut command = tokio::process::Command::new(&argv[0]);
        if environment == ProcessEnvironment::Clean {
            command.env_clear();
        }
        command
            .args(&argv[1..])
            .current_dir(cwd)
            .envs(env)
            .stdin(if writable_stdin {
                std::process::Stdio::piped()
            } else {
                std::process::Stdio::null()
            })
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .kill_on_drop(true);
        #[cfg(unix)]
        {
            use std::os::unix::process::CommandExt as _;
            command.as_std_mut().process_group(0);
        }
        let mut child = command
            .spawn()
            .map_err(|error| RpcError::new("process-spawn-failed", error.to_string()))?;
        let pid = child.id();
        #[cfg(unix)]
        let mut pending = PendingProcessGuard::new(pid, true);
        #[cfg(not(unix))]
        let mut pending = PendingProcessGuard::new(None);
        let stdin = if writable_stdin {
            InputWriter::Pipe(
                child
                    .stdin
                    .take()
                    .ok_or_else(|| RpcError::new("internal", "process stdin was not piped"))?,
            )
        } else {
            InputWriter::None
        };
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| RpcError::new("internal", "process stdout was not piped"))?;
        let stderr = child
            .stderr
            .take()
            .ok_or_else(|| RpcError::new("internal", "process stderr was not piped"))?;
        let events = ProcessEventLog::new(retained_output_bytes);
        let (exit_tx, exit_rx) = watch::channel(None);
        let response_operation = operation.clone();
        let record = Arc::new(ProcessRecord {
            id,
            owner,
            workspace,
            lifetime,
            operation,
            pid,
            signal_process_group: cfg!(unix),
            write_serial: Mutex::new(()),
            input: Mutex::new(InputState::new(stdin)),
            master: None,
            pty_eof: None,
            #[cfg(not(unix))]
            killer: None,
            events: events.clone(),
            exit: exit_rx,
            target_exited: Arc::new(AtomicBool::new(false)),
            target_exit_notify: Arc::new(Notify::new()),
            finished: Arc::new(AtomicBool::new(false)),
        });
        #[cfg(unix)]
        pending.update_target(pid, record.target_exited.clone());
        let stdout_task = tokio::spawn(read_pipe(stdout, events.clone(), id, false));
        let stderr_task = tokio::spawn(read_pipe(stderr, events.clone(), id, true));
        self.processes.write().await.insert(id, record.clone());
        let waiter_record = record.clone();
        tokio::spawn(async move {
            let status = child.wait().await;
            mark_target_exited(&waiter_record);
            let mut stdout_task = stdout_task;
            let mut stderr_task = stderr_task;
            if tokio::time::timeout(PROCESS_OUTPUT_DRAIN_TIMEOUT, async {
                let _ = (&mut stdout_task).await;
                let _ = (&mut stderr_task).await;
            })
            .await
            .is_err()
            {
                stdout_task.abort();
                stderr_task.abort();
                let _ = stdout_task.await;
                let _ = stderr_task.await;
            }
            let outcome =
                status.map(exit_outcome).unwrap_or(ExitOutcome { code: None, signal: None });
            waiter_record.input.lock().await.writer = InputWriter::None;
            events.publish_exit(id, outcome);
            let _ = exit_tx.send(Some(outcome));
            waiter_record.finished.store(true, Ordering::Release);
        });
        schedule_process_timeout(record, timeout_ms);
        pending.disarm();
        Ok(WorkspaceResponse::ProcessStarted { process: id, pid, operation: response_operation })
    }

    #[allow(clippy::too_many_arguments)]
    async fn spawn_pty(
        &self,
        id: ProcessId,
        owner: ClientScope,
        workspace: WorkspaceId,
        argv: Vec<String>,
        cwd: std::path::PathBuf,
        env: BTreeMap<String, String>,
        cols: u16,
        rows: u16,
        term: String,
        eof: PtyEofPolicy,
        lifetime: ProcessLifetime,
        operation: Option<OperationId>,
        timeout_ms: Option<u64>,
        retained_output_bytes: usize,
        environment: ProcessEnvironment,
    ) -> Result<WorkspaceResponse, RpcError> {
        validate_pty_size(cols, rows)?;
        let pty_slot = self.pty_slots.clone().try_acquire_owned().map_err(|_| {
            RpcError::new(
                "resource-exhausted",
                format!("active PTY process limit of {MAX_PTY_PROCESSES} reached"),
            )
        })?;
        if term.is_empty() || term.len() > 256 || term.contains('\0') {
            return Err(RpcError::new("invalid-argument", "PTY TERM is invalid"));
        }
        let pair = native_pty_system()
            .openpty(PtySize { rows, cols, pixel_width: 0, pixel_height: 0 })
            .map_err(|error| RpcError::new("pty-open-failed", error.to_string()))?;
        let mut command = CommandBuilder::new(&argv[0]);
        if environment == ProcessEnvironment::Clean {
            command.env_clear();
        }
        command.args(&argv[1..]);
        command.cwd(&cwd);
        for (key, value) in env {
            command.env(key, value);
        }
        command.env("TERM", &term);
        let mut child = pair
            .slave
            .spawn_command(command)
            .map_err(|error| RpcError::new("process-spawn-failed", error.to_string()))?;
        let pid = child.process_id();
        #[cfg(unix)]
        let mut pending = PendingProcessGuard::new(pid, true);
        drop(pair.slave);
        #[cfg(not(unix))]
        let killer = Arc::new(StdMutex::new(child.clone_killer()));
        #[cfg(not(unix))]
        let mut pending = PendingProcessGuard::new(Some(killer.clone()));
        #[cfg(unix)]
        let pty_io = AsyncPty::from_master(pair.master.as_ref())
            .map_err(|error| RpcError::new("pty-open-failed", error.to_string()))?;
        #[cfg(not(unix))]
        let mut reader = pair
            .master
            .try_clone_reader()
            .map_err(|error| RpcError::new("pty-open-failed", error.to_string()))?;
        #[cfg(not(unix))]
        let writer = pair
            .master
            .take_writer()
            .map_err(|error| RpcError::new("pty-open-failed", error.to_string()))?;
        #[cfg(unix)]
        let process_group_pid =
            pair.master.process_group_leader().and_then(|pid| u32::try_from(pid).ok());
        #[cfg(not(unix))]
        let process_group_pid = pid;
        let record_pid = process_group_pid.or(pid);
        #[cfg(unix)]
        let input_writer = InputWriter::Pty(pty_io.clone());
        #[cfg(not(unix))]
        let input_writer = InputWriter::Pty(writer);
        let master = Arc::new(StdMutex::new(Some(pair.master)));
        let events = ProcessEventLog::new(retained_output_bytes);
        let (exit_tx, exit_rx) = watch::channel(None);
        let response_operation = operation.clone();
        let record = Arc::new(ProcessRecord {
            id,
            owner,
            workspace,
            lifetime,
            operation,
            pid: record_pid,
            signal_process_group: cfg!(unix),
            write_serial: Mutex::new(()),
            input: Mutex::new(InputState::new(input_writer)),
            master: Some(master),
            pty_eof: Some(eof),
            #[cfg(not(unix))]
            killer: Some(killer),
            events: events.clone(),
            exit: exit_rx,
            target_exited: Arc::new(AtomicBool::new(false)),
            target_exit_notify: Arc::new(Notify::new()),
            finished: Arc::new(AtomicBool::new(false)),
        });
        #[cfg(unix)]
        pending.update_target(record_pid, record.target_exited.clone());
        #[cfg(unix)]
        {
            let reader_task = tokio::spawn(read_pty(pty_io, events.clone(), id));
            let (status_tx, status_rx) = oneshot::channel();
            let target_exited = record.target_exited.clone();
            let target_exit_notify = record.target_exit_notify.clone();
            std::thread::Builder::new()
                .name(format!("cmux-remote-pty-wait-{}", id.0))
                .spawn(move || {
                    let _pty_slot = pty_slot;
                    let status = child.wait();
                    // A reaped PID or process-group ID may be reused while
                    // the async output-drain task is still finishing. Tell
                    // the cancellation guard immediately so it never signals
                    // an unrelated replacement process.
                    target_exited.store(true, Ordering::Release);
                    target_exit_notify.notify_waiters();
                    let _ = status_tx.send(status);
                })
                .map_err(|error| RpcError::new("pty-open-failed", error.to_string()))?;
            let waiter_record = record.clone();
            tokio::spawn(async move {
                let status = status_rx.await.ok().and_then(Result::ok);
                let mut reader_task = reader_task;
                if tokio::time::timeout(PROCESS_OUTPUT_DRAIN_TIMEOUT, &mut reader_task)
                    .await
                    .is_err()
                {
                    reader_task.abort();
                    let _ = reader_task.await;
                }
                let outcome = status
                    .map(|status| ExitOutcome {
                        code: status.signal().is_none().then(|| status.exit_code() as i32),
                        signal: None,
                    })
                    .unwrap_or(ExitOutcome { code: None, signal: None });
                waiter_record.input.lock().await.writer = InputWriter::None;
                close_record_master(&waiter_record);
                events.publish_exit(id, outcome);
                let _ = exit_tx.send(Some(outcome));
                waiter_record.finished.store(true, Ordering::Release);
            });
        }
        #[cfg(not(unix))]
        {
            let reader_events = events.clone();
            let reader_thread = std::thread::Builder::new()
                .name(format!("cmux-remote-pty-{}", id.0))
                .spawn(move || {
                    let mut buffer = vec![0u8; PROCESS_READ_CHUNK];
                    loop {
                        match reader.read(&mut buffer) {
                            Ok(0) | Err(_) => break,
                            Ok(read) => reader_events.publish_output(id, false, &buffer[..read]),
                        }
                    }
                })
                .map_err(|error| RpcError::new("pty-open-failed", error.to_string()))?;
            let waiter_record = record.clone();
            std::thread::Builder::new()
                .name(format!("cmux-remote-pty-wait-{}", id.0))
                .spawn(move || {
                    let _pty_slot = pty_slot;
                    let status = child.wait();
                    waiter_record.target_exited.store(true, Ordering::Release);
                    waiter_record.target_exit_notify.notify_waiters();
                    let _ = reader_thread.join();
                    let outcome = status
                        .map(|status| ExitOutcome {
                            code: status.signal().is_none().then(|| status.exit_code() as i32),
                            signal: None,
                        })
                        .unwrap_or(ExitOutcome { code: None, signal: None });
                    waiter_record.input.blocking_lock().writer = InputWriter::None;
                    close_record_master(&waiter_record);
                    events.publish_exit(id, outcome);
                    let _ = exit_tx.send(Some(outcome));
                    waiter_record.finished.store(true, Ordering::Release);
                })
                .map_err(|error| RpcError::new("pty-open-failed", error.to_string()))?;
        }
        self.processes.write().await.insert(id, record.clone());
        schedule_process_timeout(record, timeout_ms);
        pending.disarm();
        Ok(WorkspaceResponse::ProcessStarted { process: id, pid, operation: response_operation })
    }

    pub(crate) async fn write(
        &self,
        process: ProcessId,
        write_id: u64,
        data: &ByteString,
        eof: bool,
    ) -> Result<WorkspaceResponse, RpcError> {
        let bytes = data.decode().map_err(|error| {
            RpcError::new("invalid-data", format!("invalid process bytes: {error}"))
        })?;
        if bytes.len() > MAX_PROCESS_WRITE_BYTES {
            return Err(RpcError::new(
                "resource-exhausted",
                format!("process write exceeds {MAX_PROCESS_WRITE_BYTES} bytes"),
            ));
        }
        let record = self.get(process).await?;
        let _write_guard = record.write_serial.lock().await;
        let fingerprint = write_fingerprint(&bytes, eof);
        let mut input = record.input.lock().await;
        let pty_eof = matches!(input.writer, InputWriter::Pty(_))
            .then_some(record.pty_eof.unwrap_or(PtyEofPolicy::Reject));
        if eof && pty_eof == Some(PtyEofPolicy::Reject) && !input.writes.contains_key(&write_id) {
            return Err(RpcError::new(
                "pty-eof-unsupported",
                "PTY EOF policy rejects EOF; send terminal input or a signal explicitly",
            ));
        }
        if !input.writes.contains_key(&write_id)
            && matches!(input.writer, InputWriter::None)
            && !bytes.is_empty()
        {
            return Err(RpcError::new("stdin-closed", "process stdin is closed"));
        }
        if matches!(input.begin_write(write_id, fingerprint)?, WriteStart::AlreadyAccepted) {
            return Ok(WorkspaceResponse::ProcessWriteAccepted { process, write_id });
        }
        let mut pty_writer = None;
        match &mut input.writer {
            InputWriter::None => {}
            InputWriter::Pipe(writer) => {
                let write = async {
                    writer.write_all(&bytes).await?;
                    writer.flush().await
                };
                tokio::pin!(write);
                tokio::select! {
                    result = &mut write => {
                        result.map_err(|error| {
                            RpcError::new("process-write-failed", error.to_string())
                        })?;
                    }
                    _ = wait_for_target_exit(&record) => {
                        return Err(RpcError::new(
                            "process-exited",
                            "process exited while stdin was being written",
                        ));
                    }
                }
            }
            #[cfg(unix)]
            InputWriter::Pty(writer) => {
                // Keep the durable writer in the process record while this
                // request awaits readiness. If the owning client disappears,
                // canceling the request must not make a detached PTY
                // permanently unwritable for a later attachment.
                pty_writer = Some(writer.clone());
            }
            #[cfg(not(unix))]
            InputWriter::Pty(_) => {
                pty_writer = match std::mem::replace(&mut input.writer, InputWriter::None) {
                    InputWriter::Pty(writer) => Some(writer),
                    _ => unreachable!("matched PTY writer before replacing it"),
                };
            }
        }
        if let Some(writer) = pty_writer {
            drop(input);
            let send_control_d = eof && pty_eof == Some(PtyEofPolicy::ControlD);
            #[cfg(unix)]
            {
                {
                    let write = async {
                        writer.write_all(&bytes).await?;
                        if send_control_d {
                            writer.write_all(&[4]).await?;
                        }
                        Ok::<_, std::io::Error>(())
                    };
                    tokio::pin!(write);
                    tokio::select! {
                        result = &mut write => result.map_err(|error| {
                            RpcError::new("process-write-failed", error.to_string())
                        })?,
                        _ = wait_for_target_exit(&record) => {
                            return Err(RpcError::new(
                                "process-exited",
                                "process exited while PTY input was being written",
                            ));
                        }
                    }
                }
                input = record.input.lock().await;
            }
            #[cfg(not(unix))]
            {
                let mut writer = writer;
                let mut write = tokio::task::spawn_blocking(move || {
                    let result = writer.write_all(&bytes).and_then(|()| {
                        if send_control_d {
                            writer.write_all(&[4])?;
                        }
                        writer.flush()
                    });
                    (writer, result)
                });
                let write = tokio::select! {
                    result = &mut write => result.map_err(|error| {
                        RpcError::new(
                            "process-write-failed",
                            format!("PTY write task failed: {error}"),
                        )
                    })?,
                    _ = wait_for_target_exit(&record) => {
                        return Err(RpcError::new(
                            "process-exited",
                            "process exited while PTY input was being written",
                        ));
                    }
                };
                input = record.input.lock().await;
                let (writer, result) = write;
                if !eof && !record.finished.load(Ordering::Acquire) {
                    input.writer = InputWriter::Pty(writer);
                }
                result.map_err(|error| RpcError::new("process-write-failed", error.to_string()))?;
            }
        }
        if eof {
            input.writer = InputWriter::None;
        }
        if eof && pty_eof == Some(PtyEofPolicy::Hangup) {
            drop(input);
            signal_record(&record, ProcessSignal::Hangup)?;
            input = record.input.lock().await;
        }
        input.accept_write(write_id);
        Ok(WorkspaceResponse::ProcessWriteAccepted { process, write_id })
    }

    pub(crate) async fn resize(
        &self,
        process: ProcessId,
        cols: u16,
        rows: u16,
    ) -> Result<WorkspaceResponse, RpcError> {
        validate_pty_size(cols, rows)?;
        let record = self.get(process).await?;
        let master = record
            .master
            .as_ref()
            .ok_or_else(|| RpcError::new("not-a-pty", "process does not own a PTY"))?;
        master
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_mut()
            .ok_or_else(|| RpcError::new("process-exited", "PTY master is closed"))?
            .resize(PtySize { rows, cols, pixel_width: 0, pixel_height: 0 })
            .map_err(|error| RpcError::new("pty-resize-failed", error.to_string()))?;
        Ok(WorkspaceResponse::ProcessResized { process, cols, rows })
    }

    pub(crate) async fn signal(
        &self,
        process: ProcessId,
        signal: ProcessSignal,
    ) -> Result<WorkspaceResponse, RpcError> {
        let record = self.get(process).await?;
        signal_record(&record, signal)?;
        Ok(WorkspaceResponse::ProcessSignaled { process, signal })
    }

    pub(crate) async fn wait(&self, process: ProcessId) -> Result<WorkspaceResponse, RpcError> {
        let record = self.get(process).await?;
        let mut exit = record.exit.clone();
        loop {
            if let Some(outcome) = *exit.borrow() {
                return Ok(WorkspaceResponse::ProcessExit {
                    process,
                    code: outcome.code,
                    signal: outcome.signal,
                });
            }
            exit.changed()
                .await
                .map_err(|_| RpcError::new("process-lost", "process exit state closed"))?;
        }
    }

    pub async fn subscribe(
        &self,
        process: ProcessId,
        after_sequence: u64,
    ) -> Result<ProcessSubscription, RpcError> {
        let record = self.get(process).await?;
        record.events.subscribe(after_sequence, record.finished.load(Ordering::Acquire))
    }

    pub(crate) async fn read_events(
        &self,
        process: ProcessId,
        after_sequence: u64,
        limit: u32,
    ) -> Result<WorkspaceResponse, RpcError> {
        let record = self.get(process).await?;
        record.events.read(process, after_sequence, limit, record.finished.load(Ordering::Acquire))
    }

    pub(crate) async fn finish_operation(&self, process: ProcessId) -> Result<(), RpcError> {
        let record = self.get(process).await?;
        if record.lifetime == ProcessLifetime::Operation && !record.finished.load(Ordering::Acquire)
        {
            terminate_with_escalation(record)?;
        }
        Ok(())
    }

    pub(crate) async fn finish_operation_id(
        &self,
        owner: &ClientScope,
        operation: OperationId,
    ) -> Result<WorkspaceResponse, RpcError> {
        let records = self
            .processes
            .read()
            .await
            .values()
            .filter(|record| {
                record.lifetime == ProcessLifetime::Operation
                    && &record.owner == owner
                    && record.operation.as_ref() == Some(&operation)
                    && !record.finished.load(Ordering::Acquire)
            })
            .cloned()
            .collect::<Vec<_>>();
        let mut signaled = 0u32;
        for record in records {
            terminate_with_escalation(record)?;
            signaled = signaled.saturating_add(1);
        }
        Ok(WorkspaceResponse::OperationFinished { operation, processes_signaled: signaled })
    }

    pub(crate) async fn close_workspace(&self, owner: &ClientScope, workspace: &WorkspaceId) {
        let records = self
            .processes
            .read()
            .await
            .values()
            .filter(|record| {
                &record.workspace == workspace
                    && &record.owner == owner
                    && record.lifetime != ProcessLifetime::Detached
                    && !record.finished.load(Ordering::Acquire)
            })
            .cloned()
            .collect::<Vec<_>>();
        for record in records {
            let _ = terminate_with_escalation(record);
        }
    }

    pub(crate) async fn close_client(&self, owner: &ClientScope) {
        let records = self
            .processes
            .read()
            .await
            .values()
            .filter(|record| {
                &record.owner == owner
                    && record.lifetime != ProcessLifetime::Detached
                    && !record.finished.load(Ordering::Acquire)
            })
            .cloned()
            .collect::<Vec<_>>();
        for record in records {
            let _ = terminate_with_escalation(record);
        }
    }

    pub(crate) async fn shutdown(&self) {
        let records = self
            .processes
            .read()
            .await
            .values()
            .filter(|record| !record.finished.load(Ordering::Acquire))
            .cloned()
            .collect::<Vec<_>>();
        for record in &records {
            let _ = signal_record(record, ProcessSignal::Terminate);
        }
        if wait_for_processes(&records, TERMINATION_GRACE).await {
            return;
        }
        for record in &records {
            if !record.finished.load(Ordering::Acquire) {
                let _ = signal_record(record, ProcessSignal::Kill);
            }
        }
        let _ = wait_for_processes(&records, TERMINATION_GRACE).await;
    }

    async fn get(&self, process: ProcessId) -> Result<Arc<ProcessRecord>, RpcError> {
        self.processes.read().await.get(&process).cloned().ok_or_else(|| {
            RpcError::new("unknown-process", format!("unknown process {}", process.0))
        })
    }

    async fn reserve_capacity(&self) -> Result<(), RpcError> {
        let mut processes = self.processes.write().await;
        if processes.len() >= MAX_PROCESSES {
            processes.retain(|_, process| !process.finished.load(Ordering::Acquire));
        }
        if processes.len() >= MAX_PROCESSES {
            return Err(RpcError::new(
                "resource-exhausted",
                format!("active process limit of {MAX_PROCESSES} reached"),
            ));
        }
        Ok(())
    }
}

async fn wait_for_processes(records: &[Arc<ProcessRecord>], timeout: std::time::Duration) -> bool {
    tokio::time::timeout(timeout, async {
        while records.iter().any(|record| !record.finished.load(Ordering::Acquire)) {
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
    })
    .await
    .is_ok()
}

async fn wait_for_process_exit(exit: &mut watch::Receiver<Option<ExitOutcome>>) {
    while exit.borrow().is_none() {
        if exit.changed().await.is_err() {
            break;
        }
    }
}

fn mark_target_exited(record: &ProcessRecord) {
    record.target_exited.store(true, Ordering::Release);
    record.target_exit_notify.notify_waiters();
}

async fn wait_for_target_exit(record: &ProcessRecord) {
    loop {
        let notified = record.target_exit_notify.notified();
        if record.target_exited.load(Ordering::Acquire) {
            return;
        }
        notified.await;
    }
}

fn close_record_master(record: &ProcessRecord) {
    if let Some(master) = &record.master {
        master.lock().unwrap_or_else(std::sync::PoisonError::into_inner).take();
    }
}

async fn read_pipe(
    mut reader: impl AsyncRead + Unpin,
    events: ProcessEventLog,
    process: ProcessId,
    stderr: bool,
) {
    let mut buffer = vec![0u8; PROCESS_READ_CHUNK];
    loop {
        match reader.read(&mut buffer).await {
            Ok(0) | Err(_) => break,
            Ok(read) => events.publish_output(process, stderr, &buffer[..read]),
        }
    }
}

#[cfg(unix)]
async fn read_pty(pty: Arc<AsyncPty>, events: ProcessEventLog, process: ProcessId) {
    let mut buffer = vec![0u8; PROCESS_READ_CHUNK];
    loop {
        match pty.read(&mut buffer).await {
            Ok(0) | Err(_) => break,
            Ok(read) => events.publish_output(process, false, &buffer[..read]),
        }
    }
}

fn validate_environment(environment: &BTreeMap<String, String>) -> Result<(), RpcError> {
    for (key, value) in environment {
        if key.is_empty() || key.contains('=') || key.contains('\0') || value.contains('\0') {
            return Err(RpcError::new("invalid-environment", "process environment is invalid"));
        }
    }
    Ok(())
}

fn write_fingerprint(bytes: &[u8], eof: bool) -> WriteFingerprint {
    let mut digest = Sha256::new();
    digest.update(bytes);
    digest.update([u8::from(eof)]);
    WriteFingerprint { digest: digest.finalize().into(), eof }
}

fn validate_pty_size(cols: u16, rows: u16) -> Result<(), RpcError> {
    if cols == 0 || rows == 0 || cols > MAX_PTY_DIMENSION || rows > MAX_PTY_DIMENSION {
        return Err(RpcError::new(
            "invalid-pty-size",
            format!("PTY size must be between 1 and {MAX_PTY_DIMENSION}"),
        ));
    }
    Ok(())
}

fn schedule_process_timeout(record: Arc<ProcessRecord>, timeout_ms: Option<u64>) {
    let Some(timeout_ms) = timeout_ms else { return };
    let mut exit = record.exit.clone();
    let record = Arc::downgrade(&record);
    tokio::spawn(async move {
        tokio::select! {
            _ = tokio::time::sleep(std::time::Duration::from_millis(timeout_ms)) => {
                if let Some(record) = record.upgrade()
                    && !record.finished.load(Ordering::Acquire)
                {
                    let _ = terminate_with_escalation(record);
                }
            }
            _ = wait_for_process_exit(&mut exit) => {}
        }
    });
}

fn terminate_with_escalation(record: Arc<ProcessRecord>) -> Result<(), RpcError> {
    signal_record(&record, ProcessSignal::Terminate)?;
    tokio::spawn(async move {
        tokio::time::sleep(TERMINATION_GRACE).await;
        if !record.finished.load(Ordering::Acquire) {
            let _ = signal_record(&record, ProcessSignal::Kill);
        }
    });
    Ok(())
}

#[cfg(unix)]
fn signal_record(record: &ProcessRecord, signal: ProcessSignal) -> Result<(), RpcError> {
    if record.target_exited.load(Ordering::Acquire) {
        return Ok(());
    }
    let pid = record
        .pid
        .and_then(|pid| i32::try_from(pid).ok())
        .ok_or_else(|| RpcError::new("process-signal-failed", "process has no usable pid"))?;
    let native = match signal {
        ProcessSignal::Interrupt => libc::SIGINT,
        ProcessSignal::Terminate => libc::SIGTERM,
        ProcessSignal::Kill => libc::SIGKILL,
        ProcessSignal::Hangup => libc::SIGHUP,
    };
    let target = if record.signal_process_group { -pid } else { pid };
    let result = unsafe { libc::kill(target, native) };
    if result == 0 {
        Ok(())
    } else {
        let error = std::io::Error::last_os_error();
        if error.raw_os_error() == Some(libc::ESRCH) && record.finished.load(Ordering::Acquire) {
            Ok(())
        } else {
            Err(RpcError::new("process-signal-failed", error.to_string()))
        }
    }
}

#[cfg(not(unix))]
fn signal_record(record: &ProcessRecord, signal: ProcessSignal) -> Result<(), RpcError> {
    if record.target_exited.load(Ordering::Acquire) {
        return Ok(());
    }
    if !matches!(signal, ProcessSignal::Terminate | ProcessSignal::Kill) {
        return Err(RpcError::new("unsupported-signal", "signal is unavailable on this platform"));
    }
    let killer = record
        .killer
        .as_ref()
        .ok_or_else(|| RpcError::new("unsupported-signal", "process has no portable killer"))?;
    killer
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .kill()
        .map_err(|error| RpcError::new("process-signal-failed", error.to_string()))
}

#[cfg(unix)]
fn exit_outcome(status: std::process::ExitStatus) -> ExitOutcome {
    use std::os::unix::process::ExitStatusExt as _;
    ExitOutcome { code: status.code(), signal: status.signal() }
}

#[cfg(not(unix))]
fn exit_outcome(status: std::process::ExitStatus) -> ExitOutcome {
    ExitOutcome { code: status.code(), signal: None }
}

fn event_size(event: &RpcEvent) -> usize {
    match &event.event {
        ProcessEvent::Stdout { data, .. } | ProcessEvent::Stderr { data, .. } => {
            data.encoded().len()
        }
        ProcessEvent::Exit { .. } => 0,
    }
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use tempfile::tempdir;

    use super::*;

    async fn root() -> (tempfile::TempDir, Arc<WorkspaceRoot>) {
        let directory = tempdir().unwrap();
        let root =
            WorkspaceRoot::open(WorkspaceId("process".into()), directory.path().to_str().unwrap())
                .await
                .unwrap();
        (directory, root)
    }

    fn spawn_options(
        argv: Vec<String>,
        io: ProcessIo,
        lifetime: ProcessLifetime,
    ) -> ProcessSpawnOptions {
        ProcessSpawnOptions {
            owner: ClientScope::local(),
            argv,
            cwd: None,
            env: BTreeMap::new(),
            io,
            lifetime,
            operation: None,
            timeout_ms: None,
            retained_output_bytes: None,
            environment: ProcessEnvironment::Inherit,
        }
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn pipe_process_separates_output_replays_and_reports_exit() {
        let (_directory, root) = root().await;
        let manager = ProcessManager::default();
        let response = manager
            .spawn(
                root,
                spawn_options(
                    vec![
                        "/bin/sh".into(),
                        "-c".into(),
                        "printf out; printf err >&2; exit 7".into(),
                    ],
                    ProcessIo::Pipes { stdin: false },
                    ProcessLifetime::Workspace,
                ),
            )
            .await
            .unwrap();
        let WorkspaceResponse::ProcessStarted { process, .. } = response else { panic!() };
        let exit = manager.wait(process).await.unwrap();
        assert_eq!(exit, WorkspaceResponse::ProcessExit { process, code: Some(7), signal: None });

        let mut events = manager.subscribe(process, 0).await.unwrap();
        let mut saw_stdout = false;
        let mut saw_stderr = false;
        loop {
            match events.recv().await.unwrap().event {
                ProcessEvent::Stdout { .. } => saw_stdout = true,
                ProcessEvent::Stderr { .. } => saw_stderr = true,
                ProcessEvent::Exit { .. } => break,
            }
        }
        assert!(saw_stdout);
        assert!(saw_stderr);
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn duplicate_write_id_is_applied_once() {
        let (_directory, root) = root().await;
        let manager = ProcessManager::default();
        let response = manager
            .spawn(
                root,
                spawn_options(
                    vec!["/bin/cat".into()],
                    ProcessIo::Pipes { stdin: true },
                    ProcessLifetime::Workspace,
                ),
            )
            .await
            .unwrap();
        let WorkspaceResponse::ProcessStarted { process, .. } = response else { panic!() };
        let data = ByteString::from_bytes(b"once");
        manager.write(process, 9, &data, false).await.unwrap();
        manager.write(process, 9, &data, false).await.unwrap();
        let conflict = manager
            .write(process, 9, &ByteString::from_bytes(b"different"), false)
            .await
            .unwrap_err();
        assert_eq!(conflict.code, "write-id-conflict");
        manager.write(process, 10, &ByteString::from_bytes(b""), true).await.unwrap();
        manager.wait(process).await.unwrap();

        let mut events = manager.subscribe(process, 0).await.unwrap();
        let mut stdout = Vec::new();
        loop {
            let event = events.recv().await.unwrap();
            match event.event {
                ProcessEvent::Stdout { data, .. } => stdout.extend(data.decode().unwrap()),
                ProcessEvent::Exit { .. } => break,
                ProcessEvent::Stderr { .. } => {}
            }
        }
        assert_eq!(stdout, b"once");
    }

    #[test]
    fn replay_rejects_a_cursor_the_process_has_not_produced() {
        let log = ProcessEventLog::new(PROCESS_EVENT_BYTES);
        let error = log.subscribe(1, false).err().expect("future cursor must be rejected");
        assert_eq!(error.code, "invalid-replay-cursor");
        assert!(log.subscribe(0, false).is_ok());
    }

    #[tokio::test]
    async fn finished_subscription_at_exit_cursor_closes() {
        let log = ProcessEventLog::new(PROCESS_EVENT_BYTES);
        log.publish_exit(ProcessId(7), ExitOutcome { code: Some(0), signal: None });

        // The caller's finished flag can lag exit publication briefly. The
        // event log records terminal state atomically with the Exit event.
        let mut subscription = log.subscribe(1, false).unwrap();
        assert_eq!(subscription.recv().await, Err(broadcast::error::RecvError::Closed));
    }

    #[tokio::test]
    async fn live_subscription_closes_after_delivering_exit() {
        let log = ProcessEventLog::new(PROCESS_EVENT_BYTES);
        let mut subscription = log.subscribe(0, false).unwrap();
        log.publish_exit(ProcessId(7), ExitOutcome { code: Some(0), signal: None });

        assert!(matches!(subscription.recv().await.unwrap().event, ProcessEvent::Exit { .. }));
        assert_eq!(subscription.recv().await, Err(broadcast::error::RecvError::Closed));
    }

    #[test]
    fn concurrent_publishers_retain_sequence_order() {
        let log = ProcessEventLog::new(PROCESS_EVENT_BYTES);
        let publishers = (0..4)
            .map(|_| {
                let log = log.clone();
                std::thread::spawn(move || {
                    for _ in 0..64 {
                        log.publish_output(ProcessId(7), false, b"x");
                    }
                })
            })
            .collect::<Vec<_>>();
        for publisher in publishers {
            publisher.join().unwrap();
        }

        let history = log.inner.history.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        assert_eq!(
            history.events.iter().map(|event| event.sequence).collect::<Vec<_>>(),
            (1..=256).collect::<Vec<_>>()
        );
    }

    #[tokio::test]
    async fn live_subscription_recovers_broadcast_lag_from_retained_history() {
        let log = ProcessEventLog::new(PROCESS_EVENT_BYTES);
        let mut subscription = log.subscribe(0, false).unwrap();
        for index in 0..(PROCESS_BROADCAST_CAPACITY + 40) {
            log.publish_output(ProcessId(7), false, format!("event-{index}").as_bytes());
        }

        for expected in 1..=(PROCESS_BROADCAST_CAPACITY + 40) as u64 {
            let event = subscription.recv().await.unwrap();
            assert_eq!(event.sequence, expected);
        }
    }

    #[test]
    fn typed_replay_pages_and_reports_retention_gaps() {
        let process = ProcessId(7);
        let log = ProcessEventLog::new(PROCESS_EVENT_BYTES);
        log.publish_output(process, false, b"one");
        log.publish_output(process, false, b"two");
        log.publish_output(process, false, b"three");

        let first = log.read(process, 0, 2, false).unwrap();
        let WorkspaceResponse::ProcessEvents { events, next_cursor, range, .. } = first else {
            panic!()
        };
        assert_eq!(events.iter().map(|event| event.sequence).collect::<Vec<_>>(), [1, 2]);
        assert_eq!(next_cursor, Some(2));
        assert_eq!(range.first_available, Some(1));

        let second = log.read(process, 2, 2, false).unwrap();
        let WorkspaceResponse::ProcessEvents { events, next_cursor, .. } = second else { panic!() };
        assert_eq!(events.iter().map(|event| event.sequence).collect::<Vec<_>>(), [3]);
        assert_eq!(next_cursor, None);

        let evicting = ProcessEventLog::new(4);
        evicting.publish_output(process, false, b"a");
        evicting.publish_output(process, false, b"b");
        let gap = evicting.read(process, 0, 1, false).unwrap();
        assert!(matches!(
            gap,
            WorkspaceResponse::ProcessReplayGap {
                requested_after: 0,
                range: ProcessReplayRange { first_available: Some(2), .. },
                ..
            }
        ));
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn operation_finish_terminates_all_owned_processes() {
        let (_directory, root) = root().await;
        let manager = ProcessManager::default();
        let operation = OperationId("test-operation".into());
        let mut options = spawn_options(
            vec!["/bin/sleep".into(), "30".into()],
            ProcessIo::Pipes { stdin: false },
            ProcessLifetime::Operation,
        );
        options.operation = Some(operation.clone());
        let response = manager.spawn(root.clone(), options).await.unwrap();
        let WorkspaceResponse::ProcessStarted { process, operation: response_operation, .. } =
            response
        else {
            panic!()
        };
        assert_eq!(response_operation, Some(operation.clone()));
        let other_owner =
            ClientScope::new("other-device", cmux_remote_protocol::SessionId([9; 16]));
        let mut other_options = spawn_options(
            vec!["/bin/sleep".into(), "30".into()],
            ProcessIo::Pipes { stdin: false },
            ProcessLifetime::Operation,
        );
        other_options.owner = other_owner;
        other_options.operation = Some(operation.clone());
        let WorkspaceResponse::ProcessStarted { process: other_process, .. } =
            manager.spawn(root, other_options).await.unwrap()
        else {
            panic!()
        };
        assert_eq!(
            manager.finish_operation_id(&ClientScope::local(), operation.clone()).await.unwrap(),
            WorkspaceResponse::OperationFinished { operation, processes_signaled: 1 }
        );
        tokio::time::timeout(std::time::Duration::from_secs(2), manager.wait(process))
            .await
            .expect("operation process should terminate")
            .unwrap();
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(50), manager.wait(other_process))
                .await
                .is_err(),
            "finishing one client operation terminated another client's process"
        );
        manager.signal(other_process, ProcessSignal::Kill).await.unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn process_timeout_terminates_command() {
        let (_directory, root) = root().await;
        let manager = ProcessManager::default();
        let mut options = spawn_options(
            vec!["/bin/sleep".into(), "30".into()],
            ProcessIo::Pipes { stdin: false },
            ProcessLifetime::Workspace,
        );
        options.timeout_ms = Some(20);
        let response = manager.spawn(root, options).await.unwrap();
        let WorkspaceResponse::ProcessStarted { process, .. } = response else { panic!() };
        tokio::time::timeout(std::time::Duration::from_secs(2), manager.wait(process))
            .await
            .expect("timed process should terminate")
            .unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn daemon_shutdown_terminates_detached_pipe_and_pty_processes() {
        let (_directory, root) = root().await;
        let manager = ProcessManager::default();
        let pipe = manager
            .spawn(
                root.clone(),
                spawn_options(
                    vec!["/bin/sleep".into(), "30".into()],
                    ProcessIo::Pipes { stdin: false },
                    ProcessLifetime::Detached,
                ),
            )
            .await
            .unwrap();
        let WorkspaceResponse::ProcessStarted { process: pipe, .. } = pipe else { panic!() };
        let pty = manager
            .spawn(
                root,
                spawn_options(
                    vec!["/bin/sh".into(), "-c".into(), "sleep 30".into()],
                    ProcessIo::Pty {
                        cols: 80,
                        rows: 24,
                        term: "xterm-256color".into(),
                        eof: PtyEofPolicy::Reject,
                    },
                    ProcessLifetime::Detached,
                ),
            )
            .await
            .unwrap();
        let WorkspaceResponse::ProcessStarted { process: pty, .. } = pty else { panic!() };

        tokio::time::timeout(std::time::Duration::from_secs(5), manager.shutdown())
            .await
            .expect("daemon shutdown should not hang");
        manager.wait(pipe).await.unwrap();
        manager.wait(pty).await.unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn canceled_pipe_spawn_kills_the_unpublished_process() {
        let (directory, root) = root().await;
        let manager = Arc::new(ProcessManager::default());
        let pid_file = directory.path().join("pending-pipe.pid");
        let mut env = BTreeMap::new();
        env.insert("PIDFILE".into(), pid_file.to_string_lossy().into_owned());
        let processes = manager.processes.write().await;
        let spawn_manager = manager.clone();
        let workspace = root.id.clone();
        let cwd = root.canonical_root().to_owned();
        let spawn = tokio::spawn(async move {
            spawn_manager
                .spawn_pipes(
                    ProcessId(9_001),
                    ClientScope::local(),
                    workspace,
                    vec![
                        "/bin/sh".into(),
                        "-c".into(),
                        "printf '%s' \"$$\" > \"$PIDFILE\"; exec sleep 30".into(),
                    ],
                    cwd,
                    env,
                    false,
                    ProcessLifetime::Workspace,
                    None,
                    None,
                    PROCESS_EVENT_BYTES,
                    ProcessEnvironment::Inherit,
                )
                .await
        });
        let pid = wait_for_test_pid(&pid_file).await;
        assert!(!spawn.is_finished(), "spawn unexpectedly published while its map was locked");

        spawn.abort();
        let _ = spawn.await;
        drop(processes);
        wait_for_test_process_exit(pid).await;
        assert!(manager.processes.read().await.is_empty());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn canceled_pty_spawn_kills_the_unpublished_process() {
        let (directory, root) = root().await;
        let manager = Arc::new(ProcessManager::default());
        let pid_file = directory.path().join("pending-pty.pid");
        let mut env = BTreeMap::new();
        env.insert("PIDFILE".into(), pid_file.to_string_lossy().into_owned());
        let processes = manager.processes.write().await;
        let spawn_manager = manager.clone();
        let workspace = root.id.clone();
        let cwd = root.canonical_root().to_owned();
        let spawn = tokio::spawn(async move {
            spawn_manager
                .spawn_pty(
                    ProcessId(9_002),
                    ClientScope::local(),
                    workspace,
                    vec![
                        "/bin/sh".into(),
                        "-c".into(),
                        "printf '%s' \"$$\" > \"$PIDFILE\"; exec sleep 30".into(),
                    ],
                    cwd,
                    env,
                    80,
                    24,
                    "xterm-256color".into(),
                    PtyEofPolicy::Reject,
                    ProcessLifetime::Workspace,
                    None,
                    None,
                    PROCESS_EVENT_BYTES,
                    ProcessEnvironment::Inherit,
                )
                .await
        });
        let pid = wait_for_test_pid(&pid_file).await;
        assert!(!spawn.is_finished(), "spawn unexpectedly published while its map was locked");

        spawn.abort();
        let _ = spawn.await;
        drop(processes);
        wait_for_test_process_exit(pid).await;
        assert!(manager.processes.read().await.is_empty());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn client_cleanup_unblocks_a_full_process_stdin_pipe() {
        let (_directory, root) = root().await;
        let manager = Arc::new(ProcessManager::default());
        let response = manager
            .spawn(
                root,
                spawn_options(
                    vec!["/bin/sleep".into(), "30".into()],
                    ProcessIo::Pipes { stdin: true },
                    ProcessLifetime::Workspace,
                ),
            )
            .await
            .unwrap();
        let WorkspaceResponse::ProcessStarted { process, .. } = response else { panic!() };
        let writer_manager = manager.clone();
        let writer = tokio::spawn(async move {
            let bytes = ByteString::from_bytes(&vec![b'x'; MAX_PROCESS_WRITE_BYTES]);
            for write_id in 1..=64 {
                writer_manager.write(process, write_id, &bytes, false).await?;
            }
            Ok::<(), RpcError>(())
        });
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        assert!(!writer.is_finished(), "stdin never filled during the regression test");

        manager.close_client(&ClientScope::local()).await;
        let outcome = tokio::time::timeout(std::time::Duration::from_secs(5), writer)
            .await
            .expect("client cleanup should unblock stdin")
            .unwrap();
        if let Err(error) = outcome {
            assert!(matches!(error.code.as_str(), "process-exited" | "process-write-failed"));
        }
        manager.wait(process).await.unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn client_cleanup_unblocks_a_full_pty_input_queue() {
        let (_directory, root) = root().await;
        let manager = Arc::new(ProcessManager::default());
        let response = manager
            .spawn(
                root,
                spawn_options(
                    vec!["/bin/sh".into(), "-c".into(), "stty raw -echo; exec sleep 30".into()],
                    ProcessIo::Pty {
                        cols: 80,
                        rows: 24,
                        term: "xterm-256color".into(),
                        eof: PtyEofPolicy::Reject,
                    },
                    ProcessLifetime::Workspace,
                ),
            )
            .await
            .unwrap();
        let WorkspaceResponse::ProcessStarted { process, .. } = response else { panic!() };
        let writer_manager = manager.clone();
        let writer = tokio::spawn(async move {
            let bytes = ByteString::from_bytes(&vec![b'x'; MAX_PROCESS_WRITE_BYTES]);
            for write_id in 1..=64 {
                writer_manager.write(process, write_id, &bytes, false).await?;
            }
            Ok::<(), RpcError>(())
        });
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        assert!(!writer.is_finished(), "PTY input queue never filled during the regression test");

        manager.close_client(&ClientScope::local()).await;
        let outcome = tokio::time::timeout(std::time::Duration::from_secs(5), writer)
            .await
            .expect("client cleanup should unblock PTY input")
            .unwrap();
        if let Err(error) = outcome {
            assert!(matches!(error.code.as_str(), "process-exited" | "process-write-failed"));
        }
        manager.wait(process).await.unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn canceled_detached_pty_write_preserves_input_for_reattachment() {
        let (directory, root) = root().await;
        let manager = Arc::new(ProcessManager::default());
        let go = directory.path().join("start-reading");
        let ready = directory.path().join("reader-ready");
        let mut options = spawn_options(
            vec![
                "/bin/sh".into(),
                "-c".into(),
                "stty raw -echo; while [ ! -e \"$GO\" ]; do sleep 0.01; done; printf ready > \"$READY\"; exec cat >/dev/null".into(),
            ],
            ProcessIo::Pty {
                cols: 80,
                rows: 24,
                term: "xterm-256color".into(),
                eof: PtyEofPolicy::Reject,
            },
            ProcessLifetime::Detached,
        );
        options.env.insert("GO".into(), go.to_string_lossy().into_owned());
        options.env.insert("READY".into(), ready.to_string_lossy().into_owned());
        let response = manager.spawn(root, options).await.unwrap();
        let WorkspaceResponse::ProcessStarted { process, .. } = response else { panic!() };
        let writer_manager = manager.clone();
        let writer = tokio::spawn(async move {
            let bytes = ByteString::from_bytes(&vec![b'x'; MAX_PROCESS_WRITE_BYTES]);
            for write_id in 1..=64 {
                writer_manager.write(process, write_id, &bytes, false).await?;
            }
            Ok::<(), RpcError>(())
        });
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        assert!(!writer.is_finished(), "PTY input queue never filled during the regression test");

        writer.abort();
        let _ = writer.await;
        manager.close_client(&ClientScope::local()).await;
        tokio::fs::write(&go, b"go").await.unwrap();
        wait_for_test_file(&ready).await;
        tokio::time::timeout(
            std::time::Duration::from_secs(2),
            manager.write(process, 10_000, &ByteString::from_bytes(b"after"), false),
        )
        .await
        .expect("reattached writer should not block")
        .expect("detached PTY should remain writable after request cancellation");
        manager.signal(process, ProcessSignal::Kill).await.unwrap();
        manager.wait(process).await.unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn explicit_pty_accepts_input_and_resize() {
        let (_directory, root) = root().await;
        let manager = ProcessManager::default();
        let response = manager
            .spawn(
                root,
                spawn_options(
                    vec!["/bin/sh".into()],
                    ProcessIo::Pty {
                        cols: 80,
                        rows: 24,
                        term: "xterm-256color".into(),
                        eof: PtyEofPolicy::Reject,
                    },
                    ProcessLifetime::Workspace,
                ),
            )
            .await
            .unwrap();
        let WorkspaceResponse::ProcessStarted { process, .. } = response else { panic!() };
        assert_eq!(
            manager.resize(process, 100, 40).await.unwrap(),
            WorkspaceResponse::ProcessResized { process, cols: 100, rows: 40 }
        );
        let eof = manager.write(process, 1, &ByteString::from_bytes(b""), true).await.unwrap_err();
        assert_eq!(eof.code, "pty-eof-unsupported");
        manager
            .write(process, 1, &ByteString::from_bytes(b"stty size; exit\n"), false)
            .await
            .unwrap();
        manager.wait(process).await.unwrap();
        let mut events = manager.subscribe(process, 0).await.unwrap();
        let mut output = Vec::new();
        loop {
            let event = events.recv().await.unwrap();
            match event.event {
                ProcessEvent::Stdout { data, .. } => output.extend(data.decode().unwrap()),
                ProcessEvent::Exit { .. } => break,
                ProcessEvent::Stderr { .. } => {}
            }
        }
        assert!(String::from_utf8_lossy(&output).contains("40 100"));
        let record = manager.get(process).await.unwrap();
        assert!(
            record
                .master
                .as_ref()
                .unwrap()
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .is_none(),
            "completed PTY retained its master file descriptor"
        );
        assert_eq!(manager.resize(process, 80, 24).await.unwrap_err().code, "process-exited");
    }

    #[cfg(unix)]
    async fn wait_for_test_pid(path: &std::path::Path) -> u32 {
        tokio::time::timeout(std::time::Duration::from_secs(5), async {
            loop {
                if let Ok(contents) = tokio::fs::read_to_string(path).await
                    && let Ok(pid) = contents.parse()
                {
                    break pid;
                }
                tokio::time::sleep(std::time::Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("spawned process should publish its pid")
    }

    #[cfg(unix)]
    async fn wait_for_test_file(path: &std::path::Path) {
        tokio::time::timeout(std::time::Duration::from_secs(5), async {
            while !path.exists() {
                tokio::time::sleep(std::time::Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("spawned process should publish its readiness file");
    }

    #[cfg(unix)]
    async fn wait_for_test_process_exit(pid: u32) {
        let pid = i32::try_from(pid).unwrap();
        tokio::time::timeout(std::time::Duration::from_secs(5), async {
            loop {
                let alive = unsafe { libc::kill(pid, 0) } == 0;
                if !alive && std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH) {
                    break;
                }
                tokio::time::sleep(std::time::Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("canceled spawn should kill and reap its child");
    }
}
