use std::collections::{BTreeMap, HashMap, VecDeque};
#[cfg(not(unix))]
use std::io::{Read, Write};
#[cfg(unix)]
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex as StdMutex};

#[cfg(not(unix))]
use cmux_pty::ChildKiller;
use cmux_pty::{Child, MasterPty, PtyCommand, PtySize};
use cmux_remote_protocol::{
    ByteString, OperationId, ProcessDescriptor, ProcessEnvironment, ProcessEvent, ProcessId,
    ProcessIo, ProcessIoKind, ProcessLifetime, ProcessOutputStream, ProcessOutputTruncationReason,
    ProcessReplayRange, ProcessSignal, ProcessState, ProcessTerminalColor, ProcessTerminalCursor,
    ProcessTerminalCursorStyle, ProcessTerminalRow, ProcessTerminalSize, ProcessTerminalSnapshot,
    ProcessTerminalStyledRun, ProcessTerminalUnderline, PtyEofPolicy, RpcError, RpcErrorDetails,
    RpcEvent, WorkspaceId, WorkspaceResponse,
};
use sha2::{Digest, Sha256};
#[cfg(unix)]
use tokio::io::unix::AsyncFd;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWriteExt};
use tokio::process::ChildStdin;
use tokio::sync::oneshot;
use tokio::sync::{Mutex, Notify, RwLock, Semaphore, broadcast, watch};
use tokio::task::JoinSet;

use super::ClientScope;
#[cfg(unix)]
use super::path::UnixWorkspaceDirectory;
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
const MAX_PROCESS_RESERVATIONS: usize = 256;
const MAX_COMPLETED_PROCESSES: usize = 64;
const MAX_REMEMBERED_WRITE_IDS: usize = 4_096;
const PROCESS_READ_CHUNK: usize = 64 * 1024;
const DEFAULT_PROCESS_OUTPUT_DRAIN_IDLE_TIMEOUT: std::time::Duration =
    std::time::Duration::from_secs(1);
const DEFAULT_PROCESS_OUTPUT_DRAIN_TOTAL_TIMEOUT: std::time::Duration =
    std::time::Duration::from_secs(2);
const MIN_PROCESS_OUTPUT_DRAIN_TIMEOUT_MS: u64 = 100;
const MAX_PROCESS_OUTPUT_DRAIN_TIMEOUT_MS: u64 = 60_000;
const MAX_PTY_DIMENSION: u16 = 4_096;
const MAX_PROCESS_ARGUMENTS: usize = 4_096;
const MAX_PROCESS_ENVIRONMENT: usize = 4_096;
const MAX_PROCESS_CONFIGURATION_BYTES: usize = 4 * 1024 * 1024;
const TERMINATION_GRACE: std::time::Duration = std::time::Duration::from_secs(2);
const CHILD_REAP_POLL_INTERVAL: std::time::Duration = std::time::Duration::from_millis(100);
const MAX_PROCESS_REPLAY_EVENTS: u32 = 1_024;
const MAX_PROCESS_TIMEOUT_MS: u64 = 7 * 24 * 60 * 60 * 1_000;
const MAX_OPERATION_ID_BYTES: usize = 256;
const MAX_PROCESS_CATALOG_ARGUMENTS: usize = 32;
const MAX_PROCESS_CATALOG_ARGUMENT_BYTES: usize = 512;
const MAX_PROCESS_CATALOG_ARGV_BYTES: usize = 4 * 1024;
const MAX_PROCESS_COMMAND_LABEL_BYTES: usize = 256;
const MAX_PROCESS_CATALOG_CWD_BYTES: usize = 4 * 1024;
const PROCESS_TERMINAL_SCROLLBACK_BYTES: usize = 2 * 1024 * 1024;
const MAX_PROCESS_TERMINAL_SNAPSHOT_CELLS: usize = 64 * 1024;
const MAX_PROCESS_TERMINAL_SNAPSHOT_BYTES: usize = 4 * 1024 * 1024;

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
                // Linux PTYs can keep reporting writable after a nonblocking
                // write returns EAGAIN. Yield so a full input queue cannot
                // monopolize a current-thread runtime and starve termination.
                Err(_) => tokio::task::yield_now().await,
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
    retained_bytes_limit: AtomicUsize,
}

#[derive(Default)]
struct EventHistory {
    events: VecDeque<RpcEvent>,
    retained_bytes: usize,
    exit: Option<ExitOutcome>,
    terminal: Option<ProcessTerminalModel>,
}

struct ProcessTerminalModel {
    terminal: ghostty_vt::Terminal,
    render: ghostty_vt::RenderState,
    through_sequence: u64,
}

impl ProcessEventLog {
    fn new(retained_bytes_limit: usize) -> Self {
        let (live, _) = broadcast::channel(PROCESS_BROADCAST_CAPACITY);
        Self {
            inner: Arc::new(ProcessEventLogInner {
                next_sequence: AtomicU64::new(1),
                history: StdMutex::new(EventHistory::default()),
                live,
                retained_bytes_limit: AtomicUsize::new(retained_bytes_limit),
            }),
        }
    }

    fn publish_output(&self, process: ProcessId, stderr: bool, bytes: &[u8]) {
        let data = ByteString::from_bytes(bytes);
        self.publish(|sequence, history| {
            if let Some(terminal) = history.terminal.as_mut() {
                terminal.terminal.vt_write(bytes);
                terminal.through_sequence = sequence;
            }
            let event = if stderr {
                ProcessEvent::Stderr { process, sequence, data }
            } else {
                ProcessEvent::Stdout { process, sequence, data }
            };
            RpcEvent { sequence, event }
        });
    }

    fn publish_exit(&self, process: ProcessId, outcome: ExitOutcome) {
        self.publish(|sequence, _| RpcEvent {
            sequence,
            event: ProcessEvent::Exit { process, code: outcome.code, signal: outcome.signal },
        });
    }

    fn publish_output_truncated(&self, process: ProcessId, reason: ProcessOutputTruncationReason) {
        self.publish(|sequence, _| RpcEvent {
            sequence,
            event: ProcessEvent::OutputTruncated { process, sequence, reason },
        });
    }

    fn set_retained_bytes_limit(&self, retained_bytes_limit: usize) {
        self.inner.retained_bytes_limit.store(retained_bytes_limit, Ordering::Release);
    }

    fn enable_terminal(&self, cols: u16, rows: u16) -> Result<(), RpcError> {
        let terminal = ghostty_vt::Terminal::new(
            cols,
            rows,
            PROCESS_TERMINAL_SCROLLBACK_BYTES,
            ghostty_vt::Callbacks::default(),
        )
        .map_err(terminal_model_error)?;
        let render = ghostty_vt::RenderState::new().map_err(terminal_model_error)?;
        let mut history =
            self.inner.history.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if history.terminal.is_some() {
            return Err(RpcError::new("internal", "process terminal model is already initialized"));
        }
        if !history.events.is_empty() {
            return Err(RpcError::new(
                "internal",
                "process terminal model must be initialized before output",
            ));
        }
        history.terminal = Some(ProcessTerminalModel { terminal, render, through_sequence: 0 });
        Ok(())
    }

    fn resize_terminal(
        &self,
        cols: u16,
        rows: u16,
        resize_pty: impl FnOnce() -> Result<(), RpcError>,
    ) -> Result<(), RpcError> {
        let mut history =
            self.inner.history.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let terminal = history
            .terminal
            .as_mut()
            .ok_or_else(|| RpcError::new("not-a-pty", "process does not own a PTY"))?;
        // The physical resize, VT model resize, output publication, and
        // snapshots all serialize on the event-history lock. Output caused by
        // SIGWINCH is therefore parsed at the new model size.
        resize_pty()?;
        terminal.terminal.resize(cols, rows, 0, 0).map_err(terminal_model_error)
    }

    fn snapshot_terminal(&self, process: ProcessId) -> Result<ProcessTerminalSnapshot, RpcError> {
        let snapshot = {
            let mut history =
                self.inner.history.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            let terminal = history
                .terminal
                .as_mut()
                .ok_or_else(|| RpcError::new("not-a-pty", "process does not own a PTY"))?;
            let cells = usize::from(terminal.terminal.cols())
                .saturating_mul(usize::from(terminal.terminal.rows()));
            if cells > MAX_PROCESS_TERMINAL_SNAPSHOT_CELLS {
                return Err(terminal_snapshot_too_large());
            }
            let ProcessTerminalModel { terminal, render, through_sequence } = terminal;
            render.update(terminal).map_err(terminal_model_error)?;
            let scrollback_rows = terminal.history_rows();
            let frame = render.build_frame().map_err(terminal_model_error)?;
            process_terminal_snapshot(process, &frame, scrollback_rows, *through_sequence)
        };
        let encoded_bytes = serde_json::to_vec(&snapshot)
            .map_err(|error| RpcError::new("terminal-snapshot-failed", error.to_string()))?
            .len();
        if encoded_bytes > MAX_PROCESS_TERMINAL_SNAPSHOT_BYTES {
            return Err(terminal_snapshot_too_large());
        }
        Ok(snapshot)
    }

    fn catalog_state(&self) -> (ProcessState, ProcessReplayRange, Option<ProcessTerminalSize>) {
        let history = self.inner.history.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let next_sequence = self.inner.next_sequence.load(Ordering::Acquire);
        let state = history.exit.map_or(ProcessState::Running, |outcome| ProcessState::Exited {
            code: outcome.code,
            signal: outcome.signal,
        });
        let range = replay_range(&history, next_sequence, history.exit.is_some());
        let pty_size = history.terminal.as_ref().map(|terminal| ProcessTerminalSize {
            cols: terminal.terminal.cols(),
            rows: terminal.terminal.rows(),
        });
        (state, range, pty_size)
    }

    fn publish(&self, make_event: impl FnOnce(u64, &mut EventHistory) -> RpcEvent) {
        let mut history =
            self.inner.history.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        // Sequence allocation, retention, and broadcast publication share one
        // critical section with PTY model updates. Subscribers and terminal
        // snapshots therefore observe exactly the same total output order.
        let sequence = self.inner.next_sequence.fetch_add(1, Ordering::Relaxed);
        let event = make_event(sequence, &mut history);
        let retained = event_size(&event);
        if let ProcessEvent::Exit { code, signal, .. } = &event.event {
            history.exit = Some(ExitOutcome { code: *code, signal: *signal });
        }
        history.retained_bytes = history.retained_bytes.saturating_add(retained);
        history.events.push_back(event.clone());
        let retained_bytes_limit = self.inner.retained_bytes_limit.load(Ordering::Acquire);
        while history.events.len() > PROCESS_EVENT_CAPACITY
            || history.retained_bytes > retained_bytes_limit
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
        let exited = exited || history.exit.is_some();
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
        let range = replay_range(&history, next_sequence, exited || history.exit.is_some());
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

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProcessSubscriptionError {
    Closed,
    ReplayGap { skipped: u64, requested_after: u64, range: ProcessReplayRange },
}

impl std::fmt::Display for ProcessSubscriptionError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Closed => write!(formatter, "process event stream closed"),
            Self::ReplayGap { requested_after, range, .. } => write!(
                formatter,
                "process replay after {requested_after} is outside retained range {:?}..={}",
                range.first_available, range.last_produced
            ),
        }
    }
}

impl std::error::Error for ProcessSubscriptionError {}

impl ProcessSubscription {
    pub async fn recv(&mut self) -> Result<RpcEvent, ProcessSubscriptionError> {
        loop {
            if let Some(event) = self.replay.pop_front() {
                self.last_delivered = event.sequence;
                self.terminal |= event.event.is_terminal();
                return Ok(event);
            }
            if self.terminal {
                return Err(ProcessSubscriptionError::Closed);
            }
            match self.live.recv().await {
                Ok(event) if event.sequence <= self.last_delivered => continue,
                Ok(event) => {
                    self.last_delivered = event.sequence;
                    self.terminal |= event.event.is_terminal();
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
                    let next_sequence = self.inner_next_sequence();
                    let range = replay_range(&history, next_sequence, history.exit.is_some());
                    let replay_gap = first
                        .map_or(self.last_delivered < range.last_produced, |first| {
                            self.last_delivered.saturating_add(1) < first
                        });
                    if replay_gap {
                        return Err(ProcessSubscriptionError::ReplayGap {
                            skipped,
                            requested_after: self.last_delivered,
                            range,
                        });
                    }
                    self.replay = history
                        .events
                        .iter()
                        .filter(|event| event.sequence > self.last_delivered)
                        .cloned()
                        .collect();
                }
                Err(broadcast::error::RecvError::Closed) => {
                    return Err(ProcessSubscriptionError::Closed);
                }
            }
        }
    }

    fn inner_next_sequence(&self) -> u64 {
        self.events.inner.next_sequence.load(Ordering::Acquire)
    }
}

type SharedMasterPty = Arc<StdMutex<Option<Box<dyn MasterPty + Send>>>>;

struct ProcessCatalogMetadata {
    command_label: String,
    display_argv: Vec<String>,
    display_argv_truncated: bool,
    cwd: String,
    io: ProcessIoKind,
}

struct ProcessTarget {
    serial: StdMutex<()>,
    closing: AtomicBool,
    exited: AtomicBool,
    notify: Notify,
}

impl ProcessTarget {
    fn new() -> Self {
        Self {
            serial: StdMutex::new(()),
            closing: AtomicBool::new(false),
            exited: AtomicBool::new(false),
            notify: Notify::new(),
        }
    }

    fn is_closing(&self) -> bool {
        self.closing.load(Ordering::Acquire)
    }

    fn begin_closing(&self) {
        self.closing.store(true, Ordering::Release);
        self.notify.notify_waiters();
    }

    fn is_exited(&self) -> bool {
        self.exited.load(Ordering::Acquire)
    }

    fn mark_exited(&self) {
        let _guard = self.serial.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        self.mark_exited_locked();
    }

    fn mark_exited_locked(&self) {
        self.exited.store(true, Ordering::Release);
        self.notify.notify_waiters();
    }

    #[cfg(unix)]
    fn signal_if_live<T>(&self, signal: impl FnOnce() -> T) -> Option<T> {
        let _guard = self.serial.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        (!self.is_exited()).then(signal)
    }

    #[cfg(unix)]
    fn try_reap<T>(
        &self,
        try_wait: impl FnOnce() -> std::io::Result<Option<T>>,
    ) -> std::io::Result<Option<T>> {
        let _guard = self.serial.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let status = try_wait()?;
        if status.is_some() {
            self.mark_exited_locked();
        }
        Ok(status)
    }
}

struct ProcessCompletion {
    finished: AtomicBool,
    notify: Notify,
}

impl ProcessCompletion {
    fn new() -> Self {
        Self { finished: AtomicBool::new(false), notify: Notify::new() }
    }

    fn is_finished(&self) -> bool {
        self.finished.load(Ordering::Acquire)
    }

    fn mark_finished(&self) {
        if !self.finished.swap(true, Ordering::AcqRel) {
            self.notify.notify_waiters();
        }
    }

    async fn wait(&self) {
        loop {
            let notified = self.notify.notified();
            tokio::pin!(notified);
            let _ = notified.as_mut().enable();
            if self.is_finished() {
                return;
            }
            notified.await;
        }
    }
}

struct ProcessRecord {
    id: ProcessId,
    owner: ClientScope,
    workspace: WorkspaceId,
    catalog: ProcessCatalogMetadata,
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
    target: Arc<ProcessTarget>,
    /// Signaled after bounded output drain, exit publication, and the catalog
    /// transition to completed state all finish.
    completion: Arc<ProcessCompletion>,
}

struct ProcessReservation {
    owner: ClientScope,
    events: ProcessEventLog,
}

#[derive(Default)]
struct ProcessStore {
    active: HashMap<ProcessId, Arc<ProcessRecord>>,
    completed: HashMap<ProcessId, Arc<ProcessRecord>>,
    completed_order: VecDeque<ProcessId>,
}

impl ProcessStore {
    fn get(&self, process: &ProcessId) -> Option<Arc<ProcessRecord>> {
        self.active.get(process).or_else(|| self.completed.get(process)).cloned()
    }

    fn contains_key(&self, process: &ProcessId) -> bool {
        self.active.contains_key(process) || self.completed.contains_key(process)
    }

    fn insert_active(&mut self, process: ProcessId, record: Arc<ProcessRecord>) {
        debug_assert!(!self.contains_key(&process));
        self.active.insert(process, record);
    }

    fn complete(&mut self, process: ProcessId) {
        let Some(record) = self.active.remove(&process) else { return };
        self.completed.insert(process, record);
        self.completed_order.push_back(process);
        while self.completed_order.len() > MAX_COMPLETED_PROCESSES {
            if let Some(evicted) = self.completed_order.pop_front() {
                self.completed.remove(&evicted);
            }
        }
    }

    fn reap_finished(&mut self) {
        let finished = self
            .active
            .iter()
            .filter_map(|(process, record)| record.completion.is_finished().then_some(*process))
            .collect::<Vec<_>>();
        for process in finished {
            self.complete(process);
        }
    }

    fn catalog_records(&self) -> Vec<Arc<ProcessRecord>> {
        let mut active = self.active.values().cloned().collect::<Vec<_>>();
        active.sort_by(|left, right| {
            left.workspace
                .0
                .cmp(&right.workspace.0)
                .then_with(|| left.catalog.command_label.cmp(&right.catalog.command_label))
                .then_with(|| left.id.to_string().cmp(&right.id.to_string()))
        });
        active.extend(
            self.completed_order
                .iter()
                .rev()
                .filter_map(|process| self.completed.get(process).cloned()),
        );
        debug_assert!(active.len() <= MAX_PROCESSES + MAX_COMPLETED_PROCESSES);
        active
    }
}

struct PendingProcessGuard {
    armed: bool,
    #[cfg(unix)]
    pid: Option<u32>,
    #[cfg(unix)]
    signal_process_group: bool,
    #[cfg(unix)]
    target: Option<Arc<ProcessTarget>>,
    #[cfg(not(unix))]
    killer: Option<Arc<StdMutex<Box<dyn ChildKiller + Send + Sync>>>>,
}

struct PendingPtyChild {
    child: Option<Box<dyn Child + Send + Sync>>,
    pid: Option<u32>,
}

impl PendingPtyChild {
    fn new(child: Box<dyn Child + Send + Sync>) -> Self {
        let pid = child.process_id();
        Self { child: Some(child), pid }
    }

    fn child_mut(&mut self) -> &mut (dyn Child + Send + Sync) {
        self.child.as_deref_mut().expect("pending PTY child was already handed off")
    }

    fn take(&mut self) -> Box<dyn Child + Send + Sync> {
        self.child.take().expect("pending PTY child was already handed off")
    }
}

impl Drop for PendingPtyChild {
    fn drop(&mut self) {
        let Some(mut child) = self.child.take() else { return };
        #[cfg(unix)]
        if let Some(pid) = self.pid.and_then(|pid| i32::try_from(pid).ok()) {
            if unsafe { libc::kill(-pid, libc::SIGKILL) } != 0 {
                let _ = child.kill();
            }
        } else {
            let _ = child.kill();
        }
        #[cfg(not(unix))]
        let _ = child.kill();
        let _ = child.wait();
    }
}

impl PendingProcessGuard {
    #[cfg(unix)]
    fn new(pid: Option<u32>, signal_process_group: bool) -> Self {
        Self { armed: true, pid, signal_process_group, target: None }
    }

    #[cfg(unix)]
    fn update_target(&mut self, pid: Option<u32>, target: Arc<ProcessTarget>) {
        self.pid = pid;
        self.target = Some(target);
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
        if let Some(pid) = self.pid.and_then(|pid| i32::try_from(pid).ok()) {
            let target = if self.signal_process_group { -pid } else { pid };
            if let Some(process_target) = &self.target {
                let _ =
                    process_target.signal_if_live(|| unsafe { libc::kill(target, libc::SIGKILL) });
            } else {
                let _ = unsafe { libc::kill(target, libc::SIGKILL) };
            }
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
            .field("command_label", &self.catalog.command_label)
            .field("lifetime", &self.lifetime)
            .field("pid", &self.pid)
            .field("finished", &self.completion.is_finished())
            .finish_non_exhaustive()
    }
}

impl ProcessRecord {
    fn descriptor(&self) -> ProcessDescriptor {
        let (state, replay, pty_size) = self.events.catalog_state();
        ProcessDescriptor {
            process: self.id,
            workspace: self.workspace.clone(),
            command_label: self.catalog.command_label.clone(),
            display_argv: self.catalog.display_argv.clone(),
            display_argv_truncated: self.catalog.display_argv_truncated,
            cwd: self.catalog.cwd.clone(),
            lifetime: self.lifetime,
            operation: self.operation.clone(),
            pid: self.pid,
            io: self.catalog.io,
            pty_size,
            state,
            replay,
        }
    }
}

pub(super) struct ProcessSpawnOptions {
    pub(super) requested_process: Option<ProcessId>,
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
    pub(super) output_drain_idle_timeout_ms: Option<u64>,
    pub(super) output_drain_total_timeout_ms: Option<u64>,
}

pub(crate) struct ProcessManager {
    spawn_serial: Mutex<()>,
    processes: Arc<RwLock<ProcessStore>>,
    reservations: Mutex<HashMap<ProcessId, ProcessReservation>>,
    pty_slots: Arc<Semaphore>,
}

impl Default for ProcessManager {
    fn default() -> Self {
        Self {
            spawn_serial: Mutex::new(()),
            processes: Arc::new(RwLock::new(ProcessStore::default())),
            reservations: Mutex::new(HashMap::new()),
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
            requested_process,
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
            output_drain_idle_timeout_ms,
            output_drain_total_timeout_ms,
        } = options;
        #[cfg(not(unix))]
        if matches!(&io, ProcessIo::Pty { .. }) {
            return Err(RpcError::new(
                "unsupported-process-io",
                "PTY processes are unavailable on this platform",
            ));
        }
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
        let (output_drain_idle_timeout, output_drain_total_timeout) =
            validate_output_drain_timeouts(
                output_drain_idle_timeout_ms,
                output_drain_total_timeout_ms,
            )?;
        let cwd = match cwd {
            Some(cwd) => root.resolve_existing(&cwd).await?,
            None => root.canonical_root().to_owned(),
        };
        #[cfg(unix)]
        let cwd_directory = {
            let unix_root = root.unix_root();
            let canonical = cwd.clone();
            tokio::task::spawn_blocking(move || {
                unix_root.pinned_directory_for_canonical_path(&canonical)
            })
            .await
            .map_err(|error| {
                RpcError::new("internal", format!("process cwd open task failed: {error}"))
            })??
        };
        #[cfg(not(unix))]
        {
            let metadata = tokio::fs::metadata(&cwd)
                .await
                .map_err(|error| RpcError::new("invalid-cwd", error.to_string()))?;
            if !metadata.is_dir() {
                return Err(RpcError::new("invalid-cwd", "process cwd is not a directory"));
            }
        }
        #[cfg(unix)]
        {
            let verifier = cwd_directory.try_clone()?;
            tokio::task::spawn_blocking(move || verifier.verify_identity("process cwd"))
                .await
                .map_err(|error| {
                RpcError::new("internal", format!("process cwd verification task failed: {error}"))
            })??;
        }
        let _spawn_guard = self.spawn_serial.lock().await;
        self.validate_requested_process_handle(requested_process, &owner).await?;
        self.reserve_capacity().await?;
        let retained_output_bytes = retained_output_bytes
            .map(|bytes| usize::try_from(bytes).unwrap_or(usize::MAX))
            .unwrap_or(PROCESS_EVENT_BYTES);
        if retained_output_bytes > PROCESS_EVENT_BYTES {
            return Err(RpcError::new(
                "resource-exhausted",
                format!("retained process output exceeds {PROCESS_EVENT_BYTES} bytes"),
            ));
        }
        let (id, events) =
            self.claim_process_handle(requested_process, &owner, retained_output_bytes).await?;
        let operation = match (lifetime, operation) {
            (ProcessLifetime::Operation, Some(operation)) => Some(operation),
            (ProcessLifetime::Operation, None) => {
                Some(OperationId(format!("process-{id}-{}", uuid::Uuid::new_v4())))
            }
            (_, Some(_)) => {
                return Err(RpcError::new(
                    "invalid-operation",
                    "operation id requires operation process lifetime",
                ));
            }
            (_, None) => None,
        };

        match io {
            ProcessIo::Pipes { stdin } => {
                self.spawn_pipes(
                    id,
                    events,
                    owner,
                    root.id.clone(),
                    argv,
                    cwd,
                    #[cfg(unix)]
                    cwd_directory,
                    env,
                    stdin,
                    lifetime,
                    operation,
                    timeout_ms,
                    output_drain_idle_timeout,
                    output_drain_total_timeout,
                    environment,
                )
                .await
            }
            ProcessIo::Pty { cols, rows, term, eof } => {
                self.spawn_pty(
                    id,
                    events,
                    owner,
                    root.id.clone(),
                    argv,
                    cwd,
                    #[cfg(unix)]
                    cwd_directory,
                    env,
                    cols,
                    rows,
                    term,
                    eof,
                    lifetime,
                    operation,
                    timeout_ms,
                    output_drain_idle_timeout,
                    output_drain_total_timeout,
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
        events: ProcessEventLog,
        owner: ClientScope,
        workspace: WorkspaceId,
        argv: Vec<String>,
        cwd: std::path::PathBuf,
        #[cfg(unix)] cwd_directory: UnixWorkspaceDirectory,
        env: BTreeMap<String, String>,
        writable_stdin: bool,
        lifetime: ProcessLifetime,
        operation: Option<OperationId>,
        timeout_ms: Option<u64>,
        output_drain_idle_timeout: std::time::Duration,
        output_drain_total_timeout: std::time::Duration,
        environment: ProcessEnvironment,
    ) -> Result<WorkspaceResponse, RpcError> {
        let catalog = process_catalog_metadata(&argv, &cwd, ProcessIoKind::Pipes);
        let mut command = tokio::process::Command::new(&argv[0]);
        if environment == ProcessEnvironment::Clean {
            command.env_clear();
        }
        command
            .args(&argv[1..])
            .envs(env)
            .stdin(if writable_stdin {
                std::process::Stdio::piped()
            } else {
                std::process::Stdio::null()
            })
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .kill_on_drop(true);
        #[cfg(not(unix))]
        command.current_dir(&cwd);
        #[cfg(unix)]
        {
            use std::os::unix::process::CommandExt as _;
            command.as_std_mut().process_group(0);
            let cwd = cwd_directory.try_clone_file()?;
            // SAFETY: `fchdir` is async-signal-safe, the descriptor remains
            // open through `spawn`, and the closure performs no allocation.
            unsafe {
                command.as_std_mut().pre_exec(move || {
                    if libc::fchdir(cwd.as_raw_fd()) == 0 {
                        Ok(())
                    } else {
                        Err(std::io::Error::last_os_error())
                    }
                });
            }
        }
        #[cfg(unix)]
        let mut child_events =
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::child())
                .map_err(|error| RpcError::new("process-spawn-failed", error.to_string()))?;
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
        let (exit_tx, exit_rx) = watch::channel(None);
        let response_operation = operation.clone();
        let record = Arc::new(ProcessRecord {
            id,
            owner,
            workspace,
            catalog,
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
            target: Arc::new(ProcessTarget::new()),
            completion: Arc::new(ProcessCompletion::new()),
        });
        #[cfg(unix)]
        pending.update_target(pid, record.target.clone());
        let (output_activity, output_activity_rx) = watch::channel(0_u64);
        let mut output_tasks = JoinSet::new();
        output_tasks.spawn(read_pipe(stdout, events.clone(), id, false, output_activity.clone()));
        output_tasks.spawn(read_pipe(stderr, events.clone(), id, true, output_activity.clone()));
        drop(output_activity);
        self.processes.write().await.insert_active(id, record.clone());
        let waiter_record = record.clone();
        let processes = self.processes.clone();
        tokio::spawn(async move {
            #[cfg(unix)]
            let status =
                wait_and_reap_pipe_child(&waiter_record.target, &mut child, &mut child_events)
                    .await;
            #[cfg(not(unix))]
            let status = child.wait().await;
            mark_target_exited(&waiter_record);
            for reason in drain_output_tasks(
                output_tasks,
                output_activity_rx,
                output_drain_idle_timeout,
                output_drain_total_timeout,
            )
            .await
            {
                events.publish_output_truncated(id, reason);
            }
            let outcome =
                status.map(exit_outcome).unwrap_or(ExitOutcome { code: None, signal: None });
            waiter_record.input.lock().await.writer = InputWriter::None;
            events.publish_exit(id, outcome);
            processes.write().await.complete(id);
            let _ = exit_tx.send(Some(outcome));
            waiter_record.completion.mark_finished();
        });
        schedule_process_timeout(record, timeout_ms);
        pending.disarm();
        Ok(WorkspaceResponse::ProcessStarted { process: id, pid, operation: response_operation })
    }

    #[allow(clippy::too_many_arguments)]
    async fn spawn_pty(
        &self,
        id: ProcessId,
        events: ProcessEventLog,
        owner: ClientScope,
        workspace: WorkspaceId,
        argv: Vec<String>,
        cwd: std::path::PathBuf,
        #[cfg(unix)] cwd_directory: UnixWorkspaceDirectory,
        env: BTreeMap<String, String>,
        cols: u16,
        rows: u16,
        term: String,
        eof: PtyEofPolicy,
        lifetime: ProcessLifetime,
        operation: Option<OperationId>,
        timeout_ms: Option<u64>,
        output_drain_idle_timeout: std::time::Duration,
        output_drain_total_timeout: std::time::Duration,
        environment: ProcessEnvironment,
    ) -> Result<WorkspaceResponse, RpcError> {
        #[cfg(not(unix))]
        let _ = (output_drain_idle_timeout, output_drain_total_timeout);
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
        events.enable_terminal(cols, rows)?;
        let catalog = process_catalog_metadata(&argv, &cwd, ProcessIoKind::Pty);
        let size = PtySize { rows, cols, pixel_width: 0, pixel_height: 0 };
        let pair = cmux_pty::open(size)
            .map_err(|error| RpcError::new("pty-open-failed", error.to_string()))?;
        let mut command = PtyCommand::new(&argv[0]);
        if environment == ProcessEnvironment::Clean {
            command.env_clear();
        }
        command.args(argv[1..].iter().cloned());
        #[cfg(not(unix))]
        command.cwd(&cwd);
        #[cfg(unix)]
        command.cwd_descriptor(cwd_directory.try_clone_file()?);
        // Remote workspace children get the same truecolor guarantee as local
        // surfaces (see Surface spawn in cmux-tui-core); explicit caller env
        // below can override it.
        command.env("COLORTERM", "truecolor");
        for (key, value) in env {
            command.env(key, value);
        }
        command.env("TERM", &term);
        #[cfg(unix)]
        let mut child_events =
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::child())
                .map_err(|error| RpcError::new("process-spawn-failed", error.to_string()))?;
        let cmux_pty::SpawnedPty { master, child } = pair
            .spawn(command)
            .map_err(|error| RpcError::new("process-spawn-failed", error.to_string()))?;
        let mut pending_child = PendingPtyChild::new(child);
        let pid = pending_child.pid;
        #[cfg(unix)]
        let mut pending = PendingProcessGuard::new(pid, true);
        #[cfg(not(unix))]
        let killer = Arc::new(StdMutex::new(pending_child.child_mut().clone_killer()));
        #[cfg(not(unix))]
        let mut pending = PendingProcessGuard::new(Some(killer.clone()));
        #[cfg(unix)]
        let pty_io = AsyncPty::from_master(master.as_ref())
            .map_err(|error| RpcError::new("pty-open-failed", error.to_string()))?;
        #[cfg(not(unix))]
        let mut reader = master
            .try_clone_reader()
            .map_err(|error| RpcError::new("pty-open-failed", error.to_string()))?;
        #[cfg(not(unix))]
        let writer = master
            .take_writer()
            .map_err(|error| RpcError::new("pty-open-failed", error.to_string()))?;
        #[cfg(unix)]
        let record_pid = pty_process_pid(pid, None);
        #[cfg(not(unix))]
        let record_pid = pid;
        #[cfg(unix)]
        let input_writer = InputWriter::Pty(pty_io.clone());
        #[cfg(not(unix))]
        let input_writer = InputWriter::Pty(writer);
        let master = Arc::new(StdMutex::new(Some(master)));
        let (exit_tx, exit_rx) = watch::channel(None);
        let response_operation = operation.clone();
        let record = Arc::new(ProcessRecord {
            id,
            owner,
            workspace,
            catalog,
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
            target: Arc::new(ProcessTarget::new()),
            completion: Arc::new(ProcessCompletion::new()),
        });
        #[cfg(unix)]
        pending.update_target(record_pid, record.target.clone());
        #[cfg(unix)]
        {
            let (output_activity, output_activity_rx) = watch::channel(0_u64);
            let mut output_tasks = JoinSet::new();
            output_tasks.spawn(read_pty(pty_io, events.clone(), id, output_activity.clone()));
            drop(output_activity);
            let (status_tx, status_rx) = oneshot::channel();
            let target = record.target.clone();
            tokio::spawn(async move {
                let _pty_slot = pty_slot;
                let outcome =
                    wait_and_reap_pty_child(&target, pending_child.child_mut(), &mut child_events)
                        .await;
                if outcome.is_ok() {
                    drop(pending_child.take());
                } else {
                    drop(pending_child);
                }
                // A reaped PID or process-group ID may be reused while
                // the async output-drain task is still finishing. Tell
                // the cancellation guard immediately so it never signals
                // an unrelated replacement process.
                target.mark_exited();
                let _ = status_tx.send(outcome);
            });
            self.processes.write().await.insert_active(id, record.clone());
            let waiter_record = record.clone();
            let processes = self.processes.clone();
            tokio::spawn(async move {
                let outcome = status_rx
                    .await
                    .ok()
                    .and_then(Result::ok)
                    .unwrap_or(ExitOutcome { code: None, signal: None });
                for reason in drain_output_tasks(
                    output_tasks,
                    output_activity_rx,
                    output_drain_idle_timeout,
                    output_drain_total_timeout,
                )
                .await
                {
                    events.publish_output_truncated(id, reason);
                }
                waiter_record.input.lock().await.writer = InputWriter::None;
                close_record_master(&waiter_record);
                events.publish_exit(id, outcome);
                processes.write().await.complete(id);
                let _ = exit_tx.send(Some(outcome));
                waiter_record.completion.mark_finished();
            });
        }
        #[cfg(not(unix))]
        {
            let reader_events = events.clone();
            let reader_thread = std::thread::Builder::new()
                .name(format!("cmux-remote-pty-{id}"))
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
            let (status_tx, status_rx) = oneshot::channel();
            let thread_record = record.clone();
            std::thread::Builder::new()
                .name(format!("cmux-remote-pty-wait-{id}"))
                .spawn(move || {
                    let _pty_slot = pty_slot;
                    let mut child = pending_child.take();
                    let status = child.wait();
                    thread_record.target.mark_exited();
                    let _ = reader_thread.join();
                    let outcome = status
                        .map(portable_pty_exit_outcome)
                        .unwrap_or(ExitOutcome { code: None, signal: None });
                    thread_record.input.blocking_lock().writer = InputWriter::None;
                    close_record_master(&thread_record);
                    events.publish_exit(id, outcome);
                    let _ = status_tx.send(outcome);
                })
                .map_err(|error| RpcError::new("pty-open-failed", error.to_string()))?;
            self.processes.write().await.insert_active(id, record.clone());
            let waiter_record = record.clone();
            let processes = self.processes.clone();
            tokio::spawn(async move {
                let outcome = status_rx.await.unwrap_or(ExitOutcome { code: None, signal: None });
                processes.write().await.complete(id);
                let _ = exit_tx.send(Some(outcome));
                waiter_record.completion.mark_finished();
            });
        }
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
                    _ = wait_for_process_input_close(&record) => {
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
                        _ = wait_for_process_input_close(&record) => {
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
                    _ = wait_for_process_input_close(&record) => {
                        return Err(RpcError::new(
                            "process-exited",
                            "process exited while PTY input was being written",
                        ));
                    }
                };
                input = record.input.lock().await;
                let (writer, result) = write;
                if !eof && !record.completion.is_finished() {
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
        record.events.resize_terminal(cols, rows, || {
            master
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .as_mut()
                .ok_or_else(|| RpcError::new("process-exited", "PTY master is closed"))?
                .resize(PtySize { rows, cols, pixel_width: 0, pixel_height: 0 })
                .map_err(|error| RpcError::new("pty-resize-failed", error.to_string()))
        })?;
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
        record.events.subscribe(after_sequence, record.completion.is_finished())
    }

    pub(crate) async fn subscribe_or_reserve(
        &self,
        owner: &ClientScope,
        process: ProcessId,
        after_sequence: u64,
        reserve: bool,
    ) -> Result<ProcessSubscription, RpcError> {
        if !reserve {
            return self.subscribe(process, after_sequence).await;
        }
        if process.is_nil() {
            return Err(RpcError::new("invalid-process-id", "process handle must not be nil"));
        }
        if after_sequence != 0 {
            return Err(RpcError::new(
                "invalid-replay-cursor",
                "a pre-spawn process stream must start after sequence zero",
            ));
        }

        let _spawn_guard = self.spawn_serial.lock().await;
        if self.processes.read().await.contains_key(&process) {
            return Err(RpcError::new(
                "duplicate-process-id",
                format!("process handle {process} already identifies a process"),
            ));
        }
        let mut reservations = self.reservations.lock().await;
        if reservations.contains_key(&process) {
            return Err(RpcError::new(
                "duplicate-process-id",
                format!("process handle {process} is already reserved"),
            ));
        }
        if reservations.len() >= MAX_PROCESS_RESERVATIONS {
            return Err(RpcError::new(
                "resource-exhausted",
                format!("pending process reservation limit of {MAX_PROCESS_RESERVATIONS} reached"),
            ));
        }
        let events = ProcessEventLog::new(PROCESS_EVENT_BYTES);
        let subscription = events.subscribe(after_sequence, false)?;
        reservations.insert(process, ProcessReservation { owner: owner.clone(), events });
        Ok(subscription)
    }

    pub(crate) async fn release_reservation(&self, owner: &ClientScope, process: ProcessId) {
        let _spawn_guard = self.spawn_serial.lock().await;
        let mut reservations = self.reservations.lock().await;
        if reservations.get(&process).is_some_and(|reservation| &reservation.owner == owner) {
            reservations.remove(&process);
        }
    }

    pub(crate) async fn read_events(
        &self,
        process: ProcessId,
        after_sequence: u64,
        limit: u32,
    ) -> Result<WorkspaceResponse, RpcError> {
        let record = self.get(process).await?;
        record.events.read(process, after_sequence, limit, record.completion.is_finished())
    }

    pub(crate) async fn list(&self) -> WorkspaceResponse {
        let records = {
            let mut processes = self.processes.write().await;
            processes.reap_finished();
            processes.catalog_records()
        };
        let processes = records.iter().map(|record| record.descriptor()).collect();
        WorkspaceResponse::Processes { processes }
    }

    pub(crate) async fn snapshot_terminal(
        &self,
        process: ProcessId,
    ) -> Result<WorkspaceResponse, RpcError> {
        let record = self.get(process).await?;
        let snapshot = record.events.snapshot_terminal(process)?;
        Ok(WorkspaceResponse::ProcessTerminalSnapshot { snapshot })
    }

    pub(crate) async fn finish_operation(&self, process: ProcessId) -> Result<(), RpcError> {
        let record = self.get(process).await?;
        if record.lifetime == ProcessLifetime::Operation && !record.completion.is_finished() {
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
            .active
            .values()
            .filter(|record| {
                record.lifetime == ProcessLifetime::Operation
                    && &record.owner == owner
                    && record.operation.as_ref() == Some(&operation)
                    && !record.completion.is_finished()
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
            .active
            .values()
            .filter(|record| {
                &record.workspace == workspace
                    && &record.owner == owner
                    && record.lifetime != ProcessLifetime::Detached
                    && !record.completion.is_finished()
            })
            .cloned()
            .collect::<Vec<_>>();
        for record in records {
            let _ = terminate_with_escalation(record);
        }
    }

    pub(crate) async fn close_client(&self, owner: &ClientScope) {
        self.reservations.lock().await.retain(|_, reservation| &reservation.owner != owner);
        let records = self
            .processes
            .read()
            .await
            .active
            .values()
            .filter(|record| {
                &record.owner == owner
                    && record.lifetime != ProcessLifetime::Detached
                    && !record.completion.is_finished()
            })
            .cloned()
            .collect::<Vec<_>>();
        for record in records {
            let _ = terminate_with_escalation(record);
        }
    }

    pub(crate) async fn shutdown(&self) {
        self.reservations.lock().await.clear();
        let records = self
            .processes
            .read()
            .await
            .active
            .values()
            .filter(|record| !record.completion.is_finished())
            .cloned()
            .collect::<Vec<_>>();
        for record in &records {
            let _ = signal_record(record, ProcessSignal::Terminate);
        }
        if wait_for_processes(&records, TERMINATION_GRACE).await {
            return;
        }
        for record in &records {
            if !record.completion.is_finished() {
                let _ = signal_record(record, ProcessSignal::Kill);
            }
        }
        let _ = wait_for_processes(&records, TERMINATION_GRACE).await;
    }

    async fn get(&self, process: ProcessId) -> Result<Arc<ProcessRecord>, RpcError> {
        self.processes
            .read()
            .await
            .get(&process)
            .ok_or_else(|| RpcError::new("unknown-process", format!("unknown process {process}")))
    }

    async fn claim_process_handle(
        &self,
        requested_process: Option<ProcessId>,
        owner: &ClientScope,
        retained_output_bytes: usize,
    ) -> Result<(ProcessId, ProcessEventLog), RpcError> {
        let processes = self.processes.read().await;
        let mut reservations = self.reservations.lock().await;
        let process = match requested_process {
            Some(process) if process.is_nil() => {
                return Err(RpcError::new(
                    "invalid-process-id",
                    "caller-supplied process handle must not be nil",
                ));
            }
            Some(process) => {
                if processes.contains_key(&process) {
                    return Err(RpcError::new(
                        "duplicate-process-id",
                        format!("process handle {process} is already in use"),
                    ));
                }
                process
            }
            None => loop {
                let candidate = ProcessId(uuid::Uuid::new_v4());
                if !processes.contains_key(&candidate) && !reservations.contains_key(&candidate) {
                    break candidate;
                }
            },
        };
        let events = match reservations.remove(&process) {
            Some(reservation) if &reservation.owner == owner => reservation.events,
            Some(reservation) => {
                reservations.insert(process, reservation);
                return Err(RpcError::new(
                    "duplicate-process-id",
                    format!("process handle {process} is reserved by another client"),
                ));
            }
            None => ProcessEventLog::new(retained_output_bytes),
        };
        events.set_retained_bytes_limit(retained_output_bytes);
        Ok((process, events))
    }

    async fn validate_requested_process_handle(
        &self,
        requested_process: Option<ProcessId>,
        owner: &ClientScope,
    ) -> Result<(), RpcError> {
        let Some(process) = requested_process else { return Ok(()) };
        if process.is_nil() {
            return Err(RpcError::new(
                "invalid-process-id",
                "caller-supplied process handle must not be nil",
            ));
        }
        if self.processes.read().await.contains_key(&process) {
            return Err(RpcError::new(
                "duplicate-process-id",
                format!("process handle {process} is already in use"),
            ));
        }
        if self
            .reservations
            .lock()
            .await
            .get(&process)
            .is_some_and(|reservation| &reservation.owner != owner)
        {
            return Err(RpcError::new(
                "duplicate-process-id",
                format!("process handle {process} is reserved by another client"),
            ));
        }
        Ok(())
    }

    async fn reserve_capacity(&self) -> Result<(), RpcError> {
        let mut processes = self.processes.write().await;
        processes.reap_finished();
        if processes.active.len() >= MAX_PROCESSES {
            return Err(RpcError::new(
                "resource-exhausted",
                format!("active process limit of {MAX_PROCESSES} reached"),
            ));
        }
        Ok(())
    }
}

async fn wait_for_processes(records: &[Arc<ProcessRecord>], timeout: std::time::Duration) -> bool {
    let completions = records.iter().map(|record| record.completion.clone()).collect::<Vec<_>>();
    wait_for_process_completions(&completions, timeout).await
}

async fn wait_for_process_completions(
    completions: &[Arc<ProcessCompletion>],
    timeout: std::time::Duration,
) -> bool {
    tokio::time::timeout(
        timeout,
        futures_util::future::join_all(completions.iter().map(|completion| completion.wait())),
    )
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
    record.target.mark_exited();
}

async fn wait_for_process_input_close(record: &ProcessRecord) {
    loop {
        let notified = record.target.notify.notified();
        if record.target.is_closing() || record.target.is_exited() {
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
    activity: watch::Sender<u64>,
) -> Result<(), ProcessOutputTruncationReason> {
    let stream = if stderr { ProcessOutputStream::Stderr } else { ProcessOutputStream::Stdout };
    let mut buffer = vec![0u8; PROCESS_READ_CHUNK];
    loop {
        match reader.read(&mut buffer).await {
            Ok(0) => return Ok(()),
            Ok(read) => {
                events.publish_output(process, stderr, &buffer[..read]);
                activity.send_modify(|generation| *generation = generation.wrapping_add(1));
            }
            Err(error) => {
                return Err(ProcessOutputTruncationReason::ReadError {
                    stream,
                    message: error.to_string(),
                });
            }
        }
    }
}

#[cfg(unix)]
async fn read_pty(
    pty: Arc<AsyncPty>,
    events: ProcessEventLog,
    process: ProcessId,
    activity: watch::Sender<u64>,
) -> Result<(), ProcessOutputTruncationReason> {
    let mut buffer = vec![0u8; PROCESS_READ_CHUNK];
    loop {
        match pty.read(&mut buffer).await {
            Ok(0) => return Ok(()),
            Ok(read) => {
                events.publish_output(process, false, &buffer[..read]);
                activity.send_modify(|generation| *generation = generation.wrapping_add(1));
            }
            Err(error) if error.raw_os_error() == Some(libc::EIO) => return Ok(()),
            Err(error) => {
                return Err(ProcessOutputTruncationReason::ReadError {
                    stream: ProcessOutputStream::Pty,
                    message: error.to_string(),
                });
            }
        }
    }
}

async fn drain_output_tasks(
    mut tasks: JoinSet<Result<(), ProcessOutputTruncationReason>>,
    mut activity: watch::Receiver<u64>,
    idle_timeout: std::time::Duration,
    total_timeout: std::time::Duration,
) -> Vec<ProcessOutputTruncationReason> {
    let mut reasons = Vec::new();
    let mut activity_open = true;
    let idle_deadline = tokio::time::sleep(idle_timeout);
    let total_deadline = tokio::time::sleep(total_timeout);
    tokio::pin!(idle_deadline);
    tokio::pin!(total_deadline);
    loop {
        if tasks.is_empty() {
            return reasons;
        }
        tokio::select! {
            biased;
            _ = &mut total_deadline => {
                reasons.push(ProcessOutputTruncationReason::DrainTotalTimeout {
                    total_timeout_ms: duration_millis(total_timeout),
                });
                tasks.abort_all();
                collect_output_task_failures(&mut tasks, &mut reasons).await;
                return reasons;
            }
            changed = activity.changed(), if activity_open => {
                match changed {
                    Ok(()) => idle_deadline
                        .as_mut()
                        .reset(tokio::time::Instant::now() + idle_timeout),
                    Err(_) => activity_open = false,
                }
            }
            joined = tasks.join_next() => {
                match joined {
                    Some(Ok(Ok(()))) => {}
                    Some(Ok(Err(reason))) => reasons.push(reason),
                    Some(Err(error)) => {
                        reasons.push(ProcessOutputTruncationReason::ReaderTaskFailed {
                            message: error.to_string(),
                        });
                    }
                    None => return reasons,
                }
            }
            _ = &mut idle_deadline => {
                reasons.push(ProcessOutputTruncationReason::DrainIdleTimeout {
                    idle_timeout_ms: duration_millis(idle_timeout),
                });
                tasks.abort_all();
                collect_output_task_failures(&mut tasks, &mut reasons).await;
                return reasons;
            }
        }
    }
}

async fn collect_output_task_failures(
    tasks: &mut JoinSet<Result<(), ProcessOutputTruncationReason>>,
    reasons: &mut Vec<ProcessOutputTruncationReason>,
) {
    while let Some(joined) = tasks.join_next().await {
        match joined {
            Ok(Ok(())) => {}
            Ok(Err(reason)) => reasons.push(reason),
            Err(error) if error.is_cancelled() => {}
            Err(error) => reasons.push(ProcessOutputTruncationReason::ReaderTaskFailed {
                message: error.to_string(),
            }),
        }
    }
}

fn process_catalog_metadata(
    argv: &[String],
    cwd: &std::path::Path,
    io: ProcessIoKind,
) -> ProcessCatalogMetadata {
    let command = std::path::Path::new(&argv[0])
        .file_name()
        .and_then(std::ffi::OsStr::to_str)
        .filter(|name| !name.is_empty())
        .unwrap_or(&argv[0]);
    let (command_label, _) = bounded_display_text(command, MAX_PROCESS_COMMAND_LABEL_BYTES);
    let (cwd, _) = bounded_display_text(&cwd.to_string_lossy(), MAX_PROCESS_CATALOG_CWD_BYTES);

    let mut display_argv = Vec::new();
    let mut display_argv_bytes = 0usize;
    let mut display_argv_truncated = argv.len() > MAX_PROCESS_CATALOG_ARGUMENTS;
    for argument in argv.iter().take(MAX_PROCESS_CATALOG_ARGUMENTS) {
        let remaining = MAX_PROCESS_CATALOG_ARGV_BYTES.saturating_sub(display_argv_bytes);
        if remaining == 0 {
            display_argv_truncated = true;
            break;
        }
        let limit = remaining.min(MAX_PROCESS_CATALOG_ARGUMENT_BYTES);
        let (argument, truncated) = bounded_display_text(argument, limit);
        display_argv_bytes = display_argv_bytes.saturating_add(argument.len());
        display_argv.push(argument);
        display_argv_truncated |= truncated;
    }
    display_argv_truncated |= display_argv.len() < argv.len();

    ProcessCatalogMetadata { command_label, display_argv, display_argv_truncated, cwd, io }
}

fn bounded_display_text(value: &str, max_bytes: usize) -> (String, bool) {
    let mut output = String::with_capacity(value.len().min(max_bytes));
    for character in value.chars() {
        let escaped = character.escape_debug().collect::<String>();
        if output.len().saturating_add(escaped.len()) > max_bytes {
            return (output, true);
        }
        output.push_str(&escaped);
    }
    (output, false)
}

fn process_terminal_snapshot(
    process: ProcessId,
    frame: &ghostty_vt::RenderFrame,
    scrollback_rows: u32,
    through_sequence: u64,
) -> ProcessTerminalSnapshot {
    let (cols, rows) = frame.size;
    let rows = (0..rows)
        .map(|row| ProcessTerminalRow {
            row,
            runs: frame
                .row_runs(row)
                .unwrap_or_default()
                .into_iter()
                .map(process_terminal_run)
                .collect(),
        })
        .collect();
    let (style, blink) = frame.cursor_visual;
    let (x, y, visible) =
        frame.cursor.map(|cursor| (cursor.x, cursor.y, true)).unwrap_or((0, 0, false));
    ProcessTerminalSnapshot {
        process,
        size: ProcessTerminalSize { cols, rows: frame.size.1 },
        rows,
        cursor: ProcessTerminalCursor {
            x,
            y,
            style: process_terminal_cursor_style(style),
            blink,
            visible,
            color: frame.cursor_color.map(process_terminal_color),
        },
        default_fg: process_terminal_color(frame.default_colors.1),
        default_bg: process_terminal_color(frame.default_colors.0),
        scrollback_rows,
        through_sequence,
    }
}

fn process_terminal_run(run: ghostty_vt::StyledRun) -> ProcessTerminalStyledRun {
    ProcessTerminalStyledRun {
        text: run.text,
        fg: run.fg.map(process_terminal_color),
        bg: run.bg.map(process_terminal_color),
        attrs: run.attrs,
        underline: run.underline.map(process_terminal_underline),
        width_hint: run.width_hint,
    }
}

fn process_terminal_color(color: ghostty_vt::Rgb) -> ProcessTerminalColor {
    ProcessTerminalColor { r: color.r, g: color.g, b: color.b }
}

fn process_terminal_cursor_style(style: ghostty_vt::CursorShape) -> ProcessTerminalCursorStyle {
    match style {
        ghostty_vt::CursorShape::Bar => ProcessTerminalCursorStyle::Bar,
        ghostty_vt::CursorShape::Underline => ProcessTerminalCursorStyle::Underline,
        ghostty_vt::CursorShape::Block | ghostty_vt::CursorShape::BlockHollow => {
            ProcessTerminalCursorStyle::Block
        }
    }
}

fn process_terminal_underline(underline: ghostty_vt::UnderlineStyle) -> ProcessTerminalUnderline {
    match underline {
        ghostty_vt::UnderlineStyle::Single => ProcessTerminalUnderline::Single,
        ghostty_vt::UnderlineStyle::Double => ProcessTerminalUnderline::Double,
        ghostty_vt::UnderlineStyle::Curly => ProcessTerminalUnderline::Curly,
        ghostty_vt::UnderlineStyle::Dotted => ProcessTerminalUnderline::Dotted,
        ghostty_vt::UnderlineStyle::Dashed => ProcessTerminalUnderline::Dashed,
    }
}

fn terminal_model_error(error: ghostty_vt::Error) -> RpcError {
    RpcError::new("terminal-model-failed", error.to_string())
}

fn terminal_snapshot_too_large() -> RpcError {
    RpcError::new(
        "terminal-snapshot-too-large",
        format!(
            "terminal snapshot exceeds {MAX_PROCESS_TERMINAL_SNAPSHOT_CELLS} cells or \
             {MAX_PROCESS_TERMINAL_SNAPSHOT_BYTES} encoded bytes"
        ),
    )
}

fn validate_output_drain_timeouts(
    idle_timeout_ms: Option<u64>,
    total_timeout_ms: Option<u64>,
) -> Result<(std::time::Duration, std::time::Duration), RpcError> {
    let idle_timeout = idle_timeout_ms
        .map(std::time::Duration::from_millis)
        .unwrap_or(DEFAULT_PROCESS_OUTPUT_DRAIN_IDLE_TIMEOUT);
    let total_timeout = total_timeout_ms
        .map(std::time::Duration::from_millis)
        .unwrap_or(DEFAULT_PROCESS_OUTPUT_DRAIN_TOTAL_TIMEOUT);
    let idle_timeout_ms = duration_millis(idle_timeout);
    let total_timeout_ms = duration_millis(total_timeout);
    if !(MIN_PROCESS_OUTPUT_DRAIN_TIMEOUT_MS..=MAX_PROCESS_OUTPUT_DRAIN_TIMEOUT_MS)
        .contains(&idle_timeout_ms)
        || !(MIN_PROCESS_OUTPUT_DRAIN_TIMEOUT_MS..=MAX_PROCESS_OUTPUT_DRAIN_TIMEOUT_MS)
            .contains(&total_timeout_ms)
        || idle_timeout > total_timeout
    {
        return Err(RpcError::new(
            "invalid-argument",
            format!(
                "output drain timeouts must be between {MIN_PROCESS_OUTPUT_DRAIN_TIMEOUT_MS} and \
                 {MAX_PROCESS_OUTPUT_DRAIN_TIMEOUT_MS} ms, with idle no greater than total"
            ),
        ));
    }
    Ok((idle_timeout, total_timeout))
}

fn duration_millis(duration: std::time::Duration) -> u64 {
    u64::try_from(duration.as_millis()).unwrap_or(u64::MAX)
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

#[cfg(unix)]
async fn wait_and_reap_pipe_child(
    target: &ProcessTarget,
    child: &mut tokio::process::Child,
    child_events: &mut tokio::signal::unix::Signal,
) -> std::io::Result<std::process::ExitStatus> {
    loop {
        match target.try_reap(|| child.try_wait()) {
            Ok(Some(status)) => return Ok(status),
            Ok(None) => {}
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error),
        }
        wait_for_child_exit_hint(child_events).await?;
    }
}

#[cfg(unix)]
async fn wait_and_reap_pty_child(
    target: &ProcessTarget,
    child: &mut dyn Child,
    child_events: &mut tokio::signal::unix::Signal,
) -> std::io::Result<ExitOutcome> {
    if let Some(native_child) = child.downcast_mut::<std::process::Child>() {
        loop {
            match target.try_reap(|| native_child.try_wait()) {
                Ok(Some(status)) => return Ok(exit_outcome(status)),
                Ok(None) => {}
                Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(error) => return Err(error),
            }
            wait_for_child_exit_hint(child_events).await?;
        }
    }
    loop {
        match target.try_reap(|| child.try_wait()) {
            Ok(Some(status)) => return Ok(portable_pty_exit_outcome(status)),
            Ok(None) => {}
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error),
        }
        wait_for_child_exit_hint(child_events).await?;
    }
}

#[cfg(unix)]
async fn wait_for_child_exit_hint(
    child_events: &mut tokio::signal::unix::Signal,
) -> std::io::Result<()> {
    match tokio::time::timeout(CHILD_REAP_POLL_INTERVAL, child_events.recv()).await {
        Ok(Some(())) | Err(_) => Ok(()),
        Ok(None) => Err(std::io::Error::other("SIGCHLD listener closed before the child exited")),
    }
}

#[cfg(unix)]
fn pty_process_pid(
    direct_child_pid: Option<u32>,
    _foreground_process_group: Option<u32>,
) -> Option<u32> {
    direct_child_pid
}

fn schedule_process_timeout(record: Arc<ProcessRecord>, timeout_ms: Option<u64>) {
    let Some(timeout_ms) = timeout_ms else { return };
    let mut exit = record.exit.clone();
    let record = Arc::downgrade(&record);
    tokio::spawn(async move {
        tokio::select! {
            _ = tokio::time::sleep(std::time::Duration::from_millis(timeout_ms)) => {
                if let Some(record) = record.upgrade()
                    && !record.completion.is_finished()
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
        if !record.completion.is_finished() {
            let _ = signal_record(&record, ProcessSignal::Kill);
        }
    });
    Ok(())
}

#[cfg(unix)]
fn signal_record(record: &ProcessRecord, signal: ProcessSignal) -> Result<(), RpcError> {
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
    let Some(result) = record.target.signal_if_live(|| {
        let signal_pid = if signal == ProcessSignal::Interrupt {
            record
                .master
                .as_ref()
                .and_then(|master| {
                    master
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner)
                        .as_ref()
                        .and_then(|master| master.process_group_leader())
                })
                .filter(|foreground| *foreground > 0)
                .unwrap_or(pid)
        } else {
            pid
        };
        let target = if record.signal_process_group { -signal_pid } else { signal_pid };
        unsafe { libc::kill(target, native) }
    }) else {
        return Ok(());
    };
    if result == 0 {
        if matches!(signal, ProcessSignal::Terminate | ProcessSignal::Kill) {
            record.target.begin_closing();
        }
        Ok(())
    } else {
        let error = std::io::Error::last_os_error();
        if error.raw_os_error() == Some(libc::ESRCH) && record.completion.is_finished() {
            Ok(())
        } else {
            Err(RpcError::new("process-signal-failed", error.to_string()))
        }
    }
}

#[cfg(not(unix))]
fn signal_record(record: &ProcessRecord, signal: ProcessSignal) -> Result<(), RpcError> {
    if record.target.is_exited() {
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
        .map_err(|error| RpcError::new("process-signal-failed", error.to_string()))?;
    record.target.begin_closing();
    Ok(())
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

fn portable_pty_exit_outcome(status: cmux_pty::ExitStatus) -> ExitOutcome {
    ExitOutcome { code: status.signal().is_none().then(|| status.exit_code() as i32), signal: None }
}

fn event_size(event: &RpcEvent) -> usize {
    match &event.event {
        ProcessEvent::Stdout { data, .. } | ProcessEvent::Stderr { data, .. } => {
            data.encoded().len()
        }
        ProcessEvent::OutputTruncated { .. }
        | ProcessEvent::ReplayGap { .. }
        | ProcessEvent::Exit { .. } => 0,
    }
}
