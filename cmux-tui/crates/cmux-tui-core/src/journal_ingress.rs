use std::collections::VecDeque;
use std::io;
use std::mem::size_of;
use std::sync::atomic::{AtomicBool, AtomicU8, Ordering};
use std::sync::mpsc::{Receiver, SyncSender, TryRecvError, TrySendError, sync_channel};
use std::sync::{Arc, Condvar, Mutex, Weak};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

use crate::resource::{
    ContentPublicId, FrontendProjectionPublicId, PanePublicId, ScreenPublicId, TabPublicId,
    TerminalPublicId, WorkspacePublicId,
};
use crate::workspace_registry::registry_connection::JournalWriterCommitScope;
use crate::{Mux, panic_free::RecoverPoison};

// Output coalescing only ever held terminal output, which shipped builds no
// longer journal (output_store.rs); the ingress tests still exercise it.
#[cfg(test)]
mod coalesce;
mod completion;
pub(crate) mod contention;
mod disk_full;
mod effect_intents;
mod terminal_offer;
pub(crate) use completion::JournalBatchReceipt;
use completion::{complete_batch_error, complete_batch_success};
pub(crate) use effect_intents::{EffectSend, PendingRegistryReceipt};
pub(crate) use terminal_offer::TerminalOffer;

const JOURNAL_TERMINAL_QUEUE_CAPACITY: usize = 1024;
const JOURNAL_DURABLE_QUEUE_CAPACITY: usize = 256;
const JOURNAL_TERMINAL_BATCH_CHUNKS: usize = 64;
const JOURNAL_DURABLE_BATCH_BYTES: usize = 8 * 1024 * 1024;
#[cfg(test)]
pub(crate) const TERMINAL_OUTPUT_INGRESS_BYTES: usize = 64 * 1024;
#[cfg(test)]
const TERMINAL_OUTPUT_BATCH_BYTES: usize = 256 * 1024;
const JOURNAL_TERMINAL_FAILURE_RETRY_ATTEMPTS: usize = 6;
/// A guest can be descheduled for several seconds while its state disk is
/// busy. Two seconds was short enough to turn a routine VM pause into a
/// permanent journal failure and, consequently, a capture gap on every
/// terminal. Keep the test timeout short so deadline tests stay fast; the
/// production default is deliberately long and can be tuned for a host.
#[cfg(test)]
const JOURNAL_DURABLE_WAIT: Duration = Duration::from_secs(2);
#[cfg(not(test))]
const JOURNAL_DURABLE_WAIT: Duration = Duration::from_secs(30);
#[cfg(not(test))]
const JOURNAL_DURABLE_WAIT_ENV: &str = "CMUX_TUI_JOURNAL_DURABLE_WAIT_MS";
#[cfg(not(test))]
const JOURNAL_DURABLE_WAIT_MIN: Duration = Duration::from_secs(5);
#[cfg(not(test))]
const JOURNAL_DURABLE_WAIT_MAX: Duration = crate::diagnostics::JOURNAL_APPEND_LONGEST_WAIT;
const JOURNAL_COMMIT_RESULT_WAIT: Duration = Duration::from_secs(1);
const JOURNAL_WRITER_SHUTDOWN_WAIT: Duration = Duration::from_secs(1);
const JOURNAL_SQLITE_RETRY_SLICE: Duration = Duration::from_millis(100);
const JOURNAL_RETRY_INITIAL_DELAY: Duration = Duration::from_millis(100);
const JOURNAL_RETRY_MAX_DELAY: Duration = Duration::from_secs(1);
const JOURNAL_NONRETRYABLE_RETRY_DELAY: Duration = Duration::from_millis(10);
const COMMIT_PENDING: u8 = 0;
const COMMIT_ADMITTED: u8 = 1;
const COMMIT_CANCELED: u8 = 2;

#[cfg(test)]
fn journal_durable_wait() -> Duration {
    JOURNAL_DURABLE_WAIT
}

#[cfg(not(test))]
fn journal_durable_wait() -> Duration {
    static WAIT: std::sync::OnceLock<Duration> = std::sync::OnceLock::new();
    *WAIT.get_or_init(|| {
        std::env::var(JOURNAL_DURABLE_WAIT_ENV)
            .ok()
            .and_then(|value| value.parse::<u64>().ok())
            .map(|milliseconds| {
                Duration::from_millis(milliseconds)
                    .clamp(JOURNAL_DURABLE_WAIT_MIN, JOURNAL_DURABLE_WAIT_MAX)
            })
            .unwrap_or(JOURNAL_DURABLE_WAIT)
    })
}

#[derive(Debug)]
pub(crate) struct JournalCommitIndeterminate {
    waited: Duration,
}

impl JournalCommitIndeterminate {
    pub(crate) const fn after(waited: Duration) -> Self {
        Self { waited }
    }
}

impl std::fmt::Display for JournalCommitIndeterminate {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            formatter,
            "session journal commit outcome is indeterminate after {} ms; the admitted commit may \
             still become durable",
            self.waited.as_millis()
        )
    }
}

impl std::error::Error for JournalCommitIndeterminate {}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FrontendFocusTarget {
    Pane,
    MachineRail,
    WorkspaceRail,
    TabsRail,
    ProjectionRail,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum FrontendJournalEvent {
    Focus {
        event_id: String,
        frontend_projection_id: FrontendProjectionPublicId,
        generation: String,
        target: FrontendFocusTarget,
        workspace_id: Option<WorkspacePublicId>,
        screen_id: Option<ScreenPublicId>,
        pane_id: Option<PanePublicId>,
        tab_id: Option<TabPublicId>,
        content_id: Option<ContentPublicId>,
    },
    Resize {
        event_id: String,
        frontend_projection_id: FrontendProjectionPublicId,
        generation: String,
        cols: u16,
        rows: u16,
        cell_width: u16,
        cell_height: u16,
    },
    Viewport {
        event_id: String,
        frontend_projection_id: FrontendProjectionPublicId,
        generation: String,
        screen_id: Option<ScreenPublicId>,
        offset: u64,
        target: u64,
        settled: bool,
    },
}

impl FrontendJournalEvent {
    pub(crate) fn generation(&self) -> &str {
        match self {
            Self::Focus { generation, .. }
            | Self::Resize { generation, .. }
            | Self::Viewport { generation, .. } => generation,
        }
    }

    pub(crate) fn event_id(&self) -> &str {
        match self {
            Self::Focus { event_id, .. }
            | Self::Resize { event_id, .. }
            | Self::Viewport { event_id, .. } => event_id,
        }
    }

    pub(crate) fn frontend_projection_id(&self) -> &FrontendProjectionPublicId {
        match self {
            Self::Focus { frontend_projection_id, .. }
            | Self::Resize { frontend_projection_id, .. }
            | Self::Viewport { frontend_projection_id, .. } => frontend_projection_id,
        }
    }
}

#[derive(Debug)]
pub(crate) enum JournalIngressEvent {
    /// Terminal-lane ordering fence. It appends no record, but its durable
    /// completion proves every earlier terminal output or resize committed
    /// before an exit transaction can remove that terminal's topology.
    TerminalBarrier,
    /// Test-only: shipped builds cannot construct terminal output for the
    /// journal (output_store.rs owns output). Kept for the ingress tests and
    /// for writer code that still reads older registries' records.
    #[cfg(test)]
    TerminalOutput {
        terminal_id: Arc<TerminalPublicId>,
        generation: Arc<str>,
        occurred_at_ms: u64,
        bytes: Vec<u8>,
    },
    TerminalResize {
        terminal_id: Arc<TerminalPublicId>,
        generation: Arc<str>,
        occurred_at_ms: u64,
        cols: u16,
        rows: u16,
        cell_width: u16,
        cell_height: u16,
    },
    /// A structural marker (no output): a terminal-host reconnect or respawn
    /// (surface/journal_reconnect.rs). Terminal lane, after the terminal's
    /// earlier resizes.
    TerminalOutputGap {
        terminal_id: Arc<TerminalPublicId>,
        generation: Arc<str>,
        occurred_at_ms: u64,
        reason: &'static str,
    },
    Frontend {
        principal_id: String,
        occurred_at_ms: u64,
        event: FrontendJournalEvent,
    },
    Producer {
        ingress: crate::JournalIngress,
        validated: crate::journal_kernel::ValidatedJournalIngress,
        origin: String,
        idempotency_key: String,
    },
    /// A registry commit (effect receipt, terminal record, workspace
    /// registry revision) applied in the batch under its own SAVEPOINT.
    Effect(Box<crate::workspace_registry::RegistryIntent>),
}

/// Which bounded ingress lane an event travels on. Terminal bytes and their
/// barriers never wait behind producers, and producers never wait behind a
/// large output burst.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum JournalLane {
    Terminal,
    Durable,
}

impl JournalIngressEvent {
    pub(crate) fn lane(&self) -> JournalLane {
        match self {
            Self::TerminalBarrier
            | Self::TerminalResize { .. }
            | Self::TerminalOutputGap { .. } => JournalLane::Terminal,
            #[cfg(test)]
            Self::TerminalOutput { .. } => JournalLane::Terminal,
            Self::Frontend { .. } | Self::Producer { .. } | Self::Effect(_) => JournalLane::Durable,
        }
    }

    fn estimated_bytes(&self) -> usize {
        match self {
            Self::TerminalBarrier => 0,
            #[cfg(test)]
            Self::TerminalOutput { bytes, .. } => bytes.len(),
            Self::TerminalResize { .. } => 64,
            Self::TerminalOutputGap { .. } => 128,
            Self::Effect(intent) => intent.estimated_bytes(),
            Self::Frontend { event, .. } => match event {
                FrontendJournalEvent::Focus { .. } => 512,
                FrontendJournalEvent::Resize { .. } => 256,
                FrontendJournalEvent::Viewport { .. } => 384,
            },
            Self::Producer { ingress, origin, idempotency_key, .. } => {
                let subjects = ingress.subjects.iter().fold(0_usize, |bytes, subject| {
                    bytes
                        .saturating_add(subject.kind.len())
                        .saturating_add(subject.id.len())
                        .saturating_add(2)
                });
                json_value_resident_bytes(&ingress.payload)
                    .saturating_add(subjects)
                    .saturating_add(ingress.producer_id.len())
                    .saturating_add(ingress.kind.len())
                    .saturating_add(ingress.causation_id.as_ref().map_or(0, String::len))
                    .saturating_add(ingress.correlation_id.as_ref().map_or(0, String::len))
                    .saturating_add(origin.len())
                    .saturating_add(idempotency_key.len())
                    .saturating_add(512)
            }
        }
    }

    #[cfg(test)]
    fn merge_output(&mut self, next: Self) -> Option<Self> {
        match self {
            Self::TerminalOutput { terminal_id, generation, bytes, .. } => match next {
                Self::TerminalOutput {
                    terminal_id: next_terminal,
                    generation: next_generation,
                    occurred_at_ms: _,
                    bytes: next_bytes,
                } if (Arc::ptr_eq(terminal_id, &next_terminal)
                    || terminal_id.as_ref() == next_terminal.as_ref())
                    && (Arc::ptr_eq(generation, &next_generation)
                        || generation.as_ref() == next_generation.as_ref())
                    && bytes.len().saturating_add(next_bytes.len())
                        <= TERMINAL_OUTPUT_BATCH_BYTES =>
                {
                    bytes.extend(next_bytes);
                    None
                }
                next => Some(next),
            },
            _ => Some(next),
        }
    }
}

fn json_value_resident_bytes(value: &serde_json::Value) -> usize {
    match value {
        serde_json::Value::Null => 0,
        serde_json::Value::Bool(_) => 1,
        serde_json::Value::Number(_) => size_of::<serde_json::Number>(),
        serde_json::Value::String(value) => value.len(),
        serde_json::Value::Array(values) => values.iter().fold(0_usize, |bytes, value| {
            bytes
                .saturating_add(size_of::<serde_json::Value>())
                .saturating_add(json_value_resident_bytes(value))
        }),
        serde_json::Value::Object(values) => values.iter().fold(0_usize, |bytes, (key, value)| {
            bytes
                .saturating_add(key.len())
                .saturating_add(size_of::<serde_json::Value>())
                .saturating_add(json_value_resident_bytes(value))
        }),
    }
}

#[derive(Debug)]
enum JournalIngressCompletion {
    Durable {
        sender: SyncSender<Result<(), String>>,
        deadline: Instant,
        commit_fence: Arc<AtomicU8>,
    },
    Producer {
        sender: SyncSender<Result<crate::JournalAppendCommit, String>>,
        deadline: Instant,
        commit_fence: Arc<AtomicU8>,
    },
    Effect {
        sender: SyncSender<Result<crate::workspace_registry::RegistryReceipt, String>>,
        deadline: Instant,
        commit_fence: Arc<AtomicU8>,
    },
}

impl JournalIngressCompletion {
    fn deadline(&self) -> Instant {
        match self {
            Self::Durable { deadline, .. }
            | Self::Producer { deadline, .. }
            | Self::Effect { deadline, .. } => *deadline,
        }
    }

    fn commit_fence(&self) -> &AtomicU8 {
        match self {
            Self::Durable { commit_fence, .. }
            | Self::Producer { commit_fence, .. }
            | Self::Effect { commit_fence, .. } => commit_fence,
        }
    }
}

pub(crate) struct QueuedJournalEvent {
    event: JournalIngressEvent,
    completion: Option<JournalIngressCompletion>,
}

impl QueuedJournalEvent {
    fn deadline(&self) -> Option<Instant> {
        self.completion.as_ref().map(JournalIngressCompletion::deadline)
    }

    #[cfg(test)]
    fn merge_output(&mut self, next: Self) -> Option<Self> {
        if self.completion.is_some() || next.completion.is_some() {
            return Some(next);
        }
        self.event.merge_output(next.event).map(|event| Self { event, completion: None })
    }
}

pub(crate) struct JournalIngressSender {
    terminal_sender: Option<SyncSender<QueuedJournalEvent>>,
    durable_sender: Option<SyncSender<QueuedJournalEvent>>,
    wake_sender: Option<SyncSender<()>>,
    state: Arc<JournalIngressState>,
    writer: Mutex<JournalWriterOwner>,
}

enum JournalWriterOwner {
    Vacant,
    Reserved,
    Running(JournalWriter),
    Joining(Arc<JournalWriterCompletion>),
    Closed,
}

#[derive(Default)]
struct JournalWriterCompletion {
    result: Mutex<Option<Result<(), String>>>,
    changed: Condvar,
}

impl JournalWriterCompletion {
    fn finish(&self, result: Result<(), String>) {
        *self.result.lock().recover_poison() = Some(result);
        self.changed.notify_all();
    }

    fn wait_until(&self, deadline: Instant) -> anyhow::Result<()> {
        let mut result = self.result.lock().recover_poison();
        while result.is_none() {
            let wait = deadline.saturating_duration_since(Instant::now());
            if wait.is_zero() {
                anyhow::bail!("session journal writer did not stop before the shutdown deadline");
            }
            let (next, timeout) = self.changed.wait_timeout(result, wait).recover_poison();
            result = next;
            if timeout.timed_out() && result.is_none() {
                anyhow::bail!("session journal writer did not stop before the shutdown deadline");
            }
        }
        let Some(result) = result.clone() else { anyhow::bail!("no journal writer result") };
        result.map_err(anyhow::Error::msg)
    }
}

struct JournalWriter {
    thread: std::thread::JoinHandle<()>,
    finished: Receiver<()>,
}

impl JournalWriter {
    fn spawn(name: &str, task: impl FnOnce() + Send + 'static) -> io::Result<Self> {
        let (finished_sender, finished) = sync_channel(1);
        let thread = std::thread::Builder::new().name(name.into()).spawn(move || {
            task();
            let _ = finished_sender.send(());
        })?;
        Ok(Self { thread, finished })
    }

    fn join_until(
        self,
        deadline: Instant,
        completion: Arc<JournalWriterCompletion>,
    ) -> anyhow::Result<()> {
        let Self { thread, finished } = self;
        if thread.thread().id() == std::thread::current().id() {
            let reaper_completion = completion.clone();
            let spawn = std::thread::Builder::new()
                .name("mux-session-journal-writer-reaper".into())
                .spawn(move || {
                    let result = thread.join().map_err(|_| {
                        eprintln!(
                            "cmux-tui: session journal writer panicked during self-join handoff"
                        );
                        "session journal writer panicked during self-join handoff".to_string()
                    });
                    reaper_completion.finish(result);
                });
            if let Err(error) = spawn {
                let error =
                    format!("hand off session journal writer self-join to reaper thread: {error}");
                completion.finish(Err(error.clone()));
                anyhow::bail!(error);
            }
            return Ok(());
        }
        let wait = deadline.saturating_duration_since(Instant::now());
        let result = match finished.recv_timeout(wait) {
            Ok(()) | Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => thread
                .join()
                .map_err(|_| "session journal writer panicked during shutdown".to_string()),
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => Err(format!(
                "session journal writer did not stop within {} ms; an admitted commit remains \
                 owned by the detached writer and its idempotency receipt will resolve recovery",
                wait.as_millis()
            )),
        };
        completion.finish(result.clone());
        result.map_err(anyhow::Error::msg)
    }
}

pub(crate) struct JournalIngressReceivers {
    terminal: Receiver<QueuedJournalEvent>,
    durable: Receiver<QueuedJournalEvent>,
    wake: Receiver<()>,
    state: Arc<JournalIngressState>,
}

#[cfg(test)]
pub(crate) enum JournalIngressTrySendError {
    Full { event: Box<JournalIngressEvent>, space_epoch: u64 },
    Failed { event: Box<JournalIngressEvent>, error: String },
}

#[derive(Default)]
struct JournalIngressState {
    stats: crate::diagnostics::JournalWriterStats,
    failure: Mutex<Option<String>>,
    enqueue_admission: Mutex<()>,
    closed: AtomicBool,
    commit_admission: Mutex<()>,
    queue_space_epoch: Mutex<u64>,
    queue_space_changed: Condvar,
    disk_full: disk_full::DiskFullState,
    /// Markers for records the full terminal lane refused (terminal_offer.rs).
    owed_terminal_gaps: Mutex<terminal_offer::OwedTerminalGaps>,
    #[cfg(test)]
    failure_notifier: Mutex<Option<SyncSender<String>>>,
    #[cfg(test)]
    nonretryable_failure_hook: Mutex<Option<(SyncSender<()>, Receiver<()>)>>,
    #[cfg(test)]
    enqueue_full_notifier: Mutex<Option<SyncSender<()>>>,
}

impl JournalIngressState {
    fn failure(&self) -> Option<String> {
        self.failure.lock().recover_poison().clone()
    }

    fn fail(&self, error: String) -> String {
        let mut stored_failure = self.failure.lock().recover_poison();
        let failure = stored_failure.get_or_insert(error).clone();
        drop(stored_failure);
        self.publish_queue_space();
        failure
    }

    fn admission_error(&self) -> Option<String> {
        self.failure().or_else(|| {
            self.closed
                .load(Ordering::Acquire)
                .then(|| "session journal admission is closed".to_string())
        })
    }

    fn close_admission(&self) {
        let _admission = self.enqueue_admission.lock().recover_poison();
        self.closed.store(true, Ordering::Release);
        self.publish_queue_space();
    }

    #[cfg(test)]
    fn notify_failure_for_test(&self, failure: &str) {
        if let Some(notifier) = self.failure_notifier.lock().recover_poison().take() {
            let _ = notifier.send(failure.to_string());
        }
    }

    #[cfg(test)]
    fn pause_nonretryable_failure_for_test(&self) -> bool {
        let hook = self.nonretryable_failure_hook.lock().recover_poison().take();
        let Some((entered, release)) = hook else { return false };
        entered.send(()).expect("nonretryable journal failure observer closed");
        release.recv().expect("nonretryable journal failure release closed");
        true
    }

    fn queue_space_epoch(&self) -> u64 {
        *self.queue_space_epoch.lock().recover_poison()
    }

    fn publish_queue_space(&self) {
        let mut epoch = self.queue_space_epoch.lock().recover_poison();
        *epoch = epoch.wrapping_add(1);
        self.queue_space_changed.notify_all();
    }

    fn wait_for_queue_space_until(&self, observed: u64, deadline: Instant) -> Result<(), String> {
        let mut epoch = self.queue_space_epoch.lock().recover_poison();
        while *epoch == observed {
            if let Some(error) = self.admission_error() {
                return Err(error);
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return Err(format!(
                    "timed out after {} ms waiting to queue a durable session journal event",
                    journal_durable_wait().as_millis()
                ));
            }
            let (next, result) =
                self.queue_space_changed.wait_timeout(epoch, remaining).recover_poison();
            epoch = next;
            if result.timed_out() && *epoch == observed {
                return Err(format!(
                    "timed out after {} ms waiting to queue a durable session journal event",
                    journal_durable_wait().as_millis()
                ));
            }
        }
        Ok(())
    }

    #[cfg(test)]
    fn wait_for_queue_space_change(&self, observed: u64) -> Result<(), String> {
        let mut epoch = self.queue_space_epoch.lock().recover_poison();
        while *epoch == observed {
            if let Some(error) = self.admission_error() {
                return Err(error);
            }
            epoch = self.queue_space_changed.wait(epoch).recover_poison();
        }
        Ok(())
    }

    #[cfg(test)]
    fn notify_enqueue_full_for_test(&self) {
        if let Some(notifier) = self.enqueue_full_notifier.lock().recover_poison().take() {
            let _ = notifier.send(());
        }
    }
}

impl JournalIngressSender {
    pub(crate) fn new(enabled: bool) -> (Self, Option<JournalIngressReceivers>) {
        let state = Arc::new(JournalIngressState::default());
        if !enabled {
            return (
                Self {
                    terminal_sender: None,
                    durable_sender: None,
                    wake_sender: None,
                    state,
                    writer: Mutex::new(JournalWriterOwner::Vacant),
                },
                None,
            );
        }
        let (terminal_sender, terminal) = sync_channel(JOURNAL_TERMINAL_QUEUE_CAPACITY);
        let (durable_sender, durable) = sync_channel(JOURNAL_DURABLE_QUEUE_CAPACITY);
        let (wake_sender, wake) = sync_channel(1);
        (
            Self {
                terminal_sender: Some(terminal_sender),
                durable_sender: Some(durable_sender),
                wake_sender: Some(wake_sender),
                state: state.clone(),
                writer: Mutex::new(JournalWriterOwner::Vacant),
            },
            Some(JournalIngressReceivers { terminal, durable, wake, state }),
        )
    }

    /// Test-only: waits for room in the terminal lane with no time limit.
    /// Shipped code offers its terminal-lane records (terminal_offer.rs): its
    /// callers hold terminal locks.
    #[cfg(test)]
    pub(crate) fn send(&self, event: JournalIngressEvent) {
        debug_assert!(event.lane() == JournalLane::Terminal);
        let Some(sender) = &self.terminal_sender else { return };
        match event {
            #[cfg(test)]
            JournalIngressEvent::TerminalOutput {
                terminal_id,
                generation,
                occurred_at_ms,
                bytes,
            } if bytes.len() > TERMINAL_OUTPUT_INGRESS_BYTES => {
                for bytes in bytes.chunks(TERMINAL_OUTPUT_INGRESS_BYTES) {
                    let event = JournalIngressEvent::TerminalOutput {
                        terminal_id: terminal_id.clone(),
                        generation: generation.clone(),
                        occurred_at_ms,
                        bytes: bytes.to_vec(),
                    };
                    if self.enqueue(sender, QueuedJournalEvent { event, completion: None }).is_err()
                    {
                        return;
                    }
                }
            }
            event => {
                let _ = self.enqueue(sender, QueuedJournalEvent { event, completion: None });
            }
        }
    }

    #[cfg(test)]
    pub(crate) fn try_send(
        &self,
        event: JournalIngressEvent,
    ) -> Result<(), JournalIngressTrySendError> {
        debug_assert!(event.lane() == JournalLane::Terminal);
        let Some(sender) = &self.terminal_sender else { return Ok(()) };
        let _admission = self.state.enqueue_admission.lock().recover_poison();
        if let Some(error) = self.state.admission_error() {
            return Err(JournalIngressTrySendError::Failed { event: Box::new(event), error });
        }
        let space_epoch = self.state.queue_space_epoch();
        self.state.stats.enqueued(JournalLane::Terminal);
        match sender.try_send(QueuedJournalEvent { event, completion: None }) {
            Ok(()) => {
                if let Some(wake) = &self.wake_sender {
                    match wake.try_send(()) {
                        Ok(()) | Err(TrySendError::Full(())) => {}
                        Err(TrySendError::Disconnected(())) => {}
                    }
                }
                Ok(())
            }
            Err(TrySendError::Full(queued)) => {
                self.state.stats.enqueue_failed(JournalLane::Terminal);
                Err(JournalIngressTrySendError::Full { event: Box::new(queued.event), space_epoch })
            }
            Err(TrySendError::Disconnected(queued)) => {
                self.state.stats.enqueue_failed(JournalLane::Terminal);
                Err(JournalIngressTrySendError::Failed {
                    event: Box::new(queued.event),
                    error: self.writer_error(),
                })
            }
        }
    }

    pub(crate) fn send_durable(&self, event: JournalIngressEvent) -> anyhow::Result<()> {
        self.send_durable_until(event, self.durable_deadline())
    }

    pub(crate) fn durable_deadline(&self) -> Instant {
        Instant::now() + journal_durable_wait()
    }

    pub(crate) fn send_durable_until(
        &self,
        event: JournalIngressEvent,
        deadline: Instant,
    ) -> anyhow::Result<()> {
        if let Some(error) = self.state.admission_error() {
            anyhow::bail!(error);
        }
        let sender = if event.lane() == JournalLane::Terminal {
            &self.terminal_sender
        } else {
            &self.durable_sender
        };
        let Some(sender) = sender else { return Ok(()) };
        let (completion, result) = sync_channel(1);
        let commit_fence = Arc::new(AtomicU8::new(COMMIT_PENDING));
        self.enqueue_until(
            sender,
            QueuedJournalEvent {
                event,
                completion: Some(JournalIngressCompletion::Durable {
                    sender: completion,
                    deadline,
                    commit_fence: commit_fence.clone(),
                }),
            },
            deadline,
        )
        .map_err(anyhow::Error::msg)?;
        let waited = Instant::now();
        let outcome = self.wait_for_commit_result(
            &result,
            deadline,
            &commit_fence,
            "waiting for session journal durability",
        );
        self.state.stats.receipt_waited(waited.elapsed());
        outcome
    }

    pub(crate) fn flush_terminal(&self) -> anyhow::Result<()> {
        self.send_durable(JournalIngressEvent::TerminalBarrier)
    }

    pub(crate) fn send_producer(
        &self,
        ingress: crate::JournalIngress,
        validated: crate::journal_kernel::ValidatedJournalIngress,
        origin: String,
        idempotency_key: String,
    ) -> anyhow::Result<crate::JournalAppendCommit> {
        if let Some(error) = self.state.admission_error() {
            anyhow::bail!(error);
        }
        let Some(sender) = &self.durable_sender else {
            anyhow::bail!("session journal writer is unavailable")
        };
        let (completion, result) = sync_channel(1);
        let deadline = Instant::now() + journal_durable_wait();
        let commit_fence = Arc::new(AtomicU8::new(COMMIT_PENDING));
        self.enqueue_until(
            sender,
            QueuedJournalEvent {
                event: JournalIngressEvent::Producer {
                    ingress,
                    validated,
                    origin,
                    idempotency_key,
                },
                completion: Some(JournalIngressCompletion::Producer {
                    sender: completion,
                    deadline,
                    commit_fence: commit_fence.clone(),
                }),
            },
            deadline,
        )
        .map_err(anyhow::Error::msg)?;
        let waited = Instant::now();
        let outcome = self.wait_for_commit_result(
            &result,
            deadline,
            &commit_fence,
            "waiting for a session journal producer receipt",
        );
        self.state.stats.receipt_waited(waited.elapsed());
        outcome
    }

    pub(crate) const fn enabled(&self) -> bool {
        self.terminal_sender.is_some()
    }

    pub(crate) fn is_current_writer_thread(&self) -> bool {
        self.writer.lock().is_ok_and(|owner| {
            matches!(
                &*owner,
                JournalWriterOwner::Running(writer)
                    if writer.thread.thread().id() == std::thread::current().id()
            )
        })
    }

    pub(crate) fn is_closed(&self) -> bool {
        self.state.closed.load(Ordering::Acquire)
    }

    pub(crate) fn close_and_join(&self) -> anyhow::Result<()> {
        self.close_and_join_until(Instant::now() + JOURNAL_WRITER_SHUTDOWN_WAIT)
    }

    fn close_and_join_until(&self, deadline: Instant) -> anyhow::Result<()> {
        self.state.close_admission();
        if let Some(wake) = &self.wake_sender {
            match wake.try_send(()) {
                Ok(()) | Err(TrySendError::Full(())) => {}
                Err(TrySendError::Disconnected(())) => {}
            }
        }
        enum CloseAction {
            Join(JournalWriter, Arc<JournalWriterCompletion>),
            Wait(Arc<JournalWriterCompletion>),
            Done,
        }
        let action = {
            let mut owner = self.writer.lock().recover_poison();
            match std::mem::replace(&mut *owner, JournalWriterOwner::Closed) {
                JournalWriterOwner::Running(writer) => {
                    let completion = Arc::new(JournalWriterCompletion::default());
                    *owner = JournalWriterOwner::Joining(completion.clone());
                    CloseAction::Join(writer, completion)
                }
                JournalWriterOwner::Joining(completion) => {
                    *owner = JournalWriterOwner::Joining(completion.clone());
                    CloseAction::Wait(completion)
                }
                JournalWriterOwner::Vacant | JournalWriterOwner::Closed => CloseAction::Done,
                JournalWriterOwner::Reserved => CloseAction::Done, // never escapes the lock
            }
        };
        match action {
            CloseAction::Join(writer, completion) => writer.join_until(deadline, completion),
            CloseAction::Wait(completion) => completion.wait_until(deadline),
            CloseAction::Done => Ok(()),
        }
    }

    pub(crate) fn spawn_writer(
        &self,
        name: &str,
        task: impl FnOnce() + Send + 'static,
    ) -> anyhow::Result<()> {
        let mut owner = self.writer.lock().recover_poison();
        anyhow::ensure!(
            matches!(*owner, JournalWriterOwner::Vacant),
            "session journal writer is already installed"
        );
        *owner = JournalWriterOwner::Reserved;
        match JournalWriter::spawn(name, task) {
            Ok(writer) => {
                *owner = JournalWriterOwner::Running(writer);
                Ok(())
            }
            Err(error) => {
                *owner = JournalWriterOwner::Vacant;
                Err(error.into())
            }
        }
    }

    #[cfg(test)]
    pub(crate) fn install_failure_notifier_for_test(&self, notifier: SyncSender<String>) {
        *self.state.failure_notifier.lock().recover_poison() = Some(notifier);
    }

    #[cfg(test)]
    pub(crate) fn install_nonretryable_failure_hook_for_test(
        &self,
        entered: SyncSender<()>,
        release: Receiver<()>,
    ) {
        *self.state.nonretryable_failure_hook.lock().recover_poison() = Some((entered, release));
    }

    #[cfg(test)]
    fn install_enqueue_full_notifier_for_test(&self, notifier: SyncSender<()>) {
        *self.state.enqueue_full_notifier.lock().recover_poison() = Some(notifier);
    }

    pub(crate) fn stats(&self) -> &crate::diagnostics::JournalWriterStats {
        &self.state.stats
    }

    #[cfg(test)]
    fn enqueue(
        &self,
        sender: &SyncSender<QueuedJournalEvent>,
        event: QueuedJournalEvent,
    ) -> Result<(), String> {
        let lane = event.event.lane();
        let mut pending = event;
        loop {
            let space_epoch = self.state.queue_space_epoch();
            let result = {
                let _admission = self.state.enqueue_admission.lock().recover_poison();
                if let Some(error) = self.state.admission_error() {
                    return Err(error);
                }
                // Count before the event is visible to the writer, which may
                // drain it before `try_send` returns.
                self.state.stats.enqueued(lane);
                sender.try_send(pending)
            };
            match result {
                Ok(()) => {
                    if let Some(wake) = &self.wake_sender {
                        match wake.try_send(()) {
                            Ok(()) | Err(TrySendError::Full(())) => {}
                            Err(TrySendError::Disconnected(())) => {}
                        }
                    }
                    return Ok(());
                }
                Err(TrySendError::Full(event)) => {
                    self.state.stats.enqueue_failed(lane);
                    if self.state.disk_full.is_full() {
                        return Err(self.state.disk_full.drop_event());
                    }
                    pending = event;
                }
                Err(TrySendError::Disconnected(_)) => {
                    self.state.stats.enqueue_failed(lane);
                    return Err(self.writer_error());
                }
            }
            #[cfg(test)]
            self.state.notify_enqueue_full_for_test();
            self.state.wait_for_queue_space_change(space_epoch)?;
        }
    }

    fn enqueue_until(
        &self,
        sender: &SyncSender<QueuedJournalEvent>,
        event: QueuedJournalEvent,
        deadline: Instant,
    ) -> Result<(), String> {
        self.enqueue_until_or_return(sender, event, deadline).map_err(|(error, _)| error)
    }

    /// [`Self::enqueue_until`] that hands the event back when it was not
    /// queued (deadline, admission closed, writer gone).
    fn enqueue_until_or_return(
        &self,
        sender: &SyncSender<QueuedJournalEvent>,
        event: QueuedJournalEvent,
        deadline: Instant,
    ) -> Result<(), (String, Box<QueuedJournalEvent>)> {
        let lane = event.event.lane();
        let mut pending = event;
        loop {
            if Instant::now() >= deadline {
                return Err((
                    format!(
                        "timed out after {} ms waiting to queue a durable session journal event",
                        journal_durable_wait().as_millis()
                    ),
                    Box::new(pending),
                ));
            }
            let space_epoch = self.state.queue_space_epoch();
            let result = {
                let _admission = self.state.enqueue_admission.lock().recover_poison();
                if Instant::now() >= deadline {
                    return Err((
                        format!(
                            "timed out after {} ms waiting to queue a durable session journal \
                             event",
                            journal_durable_wait().as_millis()
                        ),
                        Box::new(pending),
                    ));
                }
                if let Some(error) = self.state.admission_error() {
                    return Err((error, Box::new(pending)));
                }
                // A waiter is answered now, not at its deadline.
                if self.state.disk_full.is_full() {
                    self.state.disk_full.refused_waiter(&self.state);
                    return Err((disk_full::WAITER_ERROR.into(), Box::new(pending)));
                }
                // Count before the event is visible to the writer, which may
                // drain it before `try_send` returns.
                self.state.stats.enqueued(lane);
                sender.try_send(pending)
            };
            match result {
                Ok(()) => {
                    if let Some(wake) = &self.wake_sender {
                        match wake.try_send(()) {
                            Ok(()) | Err(TrySendError::Full(())) => {}
                            Err(TrySendError::Disconnected(())) => {}
                        }
                    }
                    return Ok(());
                }
                Err(TrySendError::Full(event)) => {
                    self.state.stats.enqueue_failed(lane);
                    pending = event;
                }
                Err(TrySendError::Disconnected(event)) => {
                    self.state.stats.enqueue_failed(lane);
                    return Err((self.writer_error(), Box::new(event)));
                }
            }
            if let Err(error) = self.state.wait_for_queue_space_until(space_epoch, deadline) {
                return Err((error, Box::new(pending)));
            }
        }
    }

    fn writer_error(&self) -> String {
        self.state.admission_error().unwrap_or_else(|| "session journal writer stopped".into())
    }

    fn wait_for_commit_result<T>(
        &self,
        result: &Receiver<Result<T, String>>,
        deadline: Instant,
        commit_fence: &AtomicU8,
        operation: &str,
    ) -> anyhow::Result<T> {
        let _slow_log = crate::diagnostics::request_log::registry_wait(deadline);
        match result.recv_timeout(deadline.saturating_duration_since(Instant::now())) {
            Ok(result) => result.map_err(anyhow::Error::msg),
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                Err(anyhow::Error::msg(self.writer_error()))
            }
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                let admission = self.state.commit_admission.lock().recover_poison();
                match commit_fence.load(Ordering::Acquire) {
                    COMMIT_PENDING => {
                        commit_fence.store(COMMIT_CANCELED, Ordering::Release);
                        Err(anyhow::anyhow!(
                            "timed out after {} ms {operation}",
                            journal_durable_wait().as_millis()
                        ))
                    }
                    COMMIT_ADMITTED => {
                        drop(admission);
                        match result.recv_timeout(JOURNAL_COMMIT_RESULT_WAIT) {
                            Ok(result) => result.map_err(anyhow::Error::msg),
                            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                                Err(anyhow::Error::msg(self.writer_error()))
                            }
                            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                                Err(anyhow::Error::new(JournalCommitIndeterminate::after(
                                    journal_durable_wait()
                                        .saturating_add(JOURNAL_COMMIT_RESULT_WAIT),
                                )))
                            }
                        }
                    }
                    COMMIT_CANCELED => Err(anyhow::anyhow!(
                        "timed out after {} ms {operation}",
                        journal_durable_wait().as_millis()
                    )),
                    state => Err(anyhow::anyhow!(
                        "session journal has an invalid commit admission state {state}"
                    )),
                }
            }
        }
    }
}

pub(crate) fn start(
    mux: &Arc<Mux>,
    receivers: Option<JournalIngressReceivers>,
) -> anyhow::Result<()> {
    let Some(receivers) = receivers else { return Ok(()) };
    let weak = Arc::downgrade(mux);
    mux.spawn_journal_writer("mux-session-journal-writer", move || run(weak, receivers))?;
    // Registry commits (effect receipts, terminal records, workspace
    // revisions) ride the writer batch from now on.
    mux.install_registry_intent_sink();
    Ok(())
}

fn run(mux: Weak<Mux>, receivers: JournalIngressReceivers) {
    let mut disk_full_retry = disk_full::DiskFullRetry::new();
    loop {
        let Some(batch) = receive_batch(&receivers) else { return };
        let mut pending = VecDeque::from([batch]);
        while let Some(mut batch) = pending.pop_front() {
            let mut delay = JOURNAL_RETRY_INITIAL_DELAY;
            let mut nonretryable_delay = JOURNAL_NONRETRYABLE_RETRY_DELAY;
            let mut reported_error = None;
            let mut uncompleted_nonretryable_failures = 0_usize;
            let mut retry_deadline = batch
                .iter()
                .filter_map(QueuedJournalEvent::deadline)
                .min()
                .unwrap_or_else(|| Instant::now() + journal_durable_wait());
            loop {
                let Some(mux) = mux.upgrade() else {
                    let error = "session journal stopped".to_string();
                    complete_batch_error(&batch, error.clone());
                    for pending_batch in pending {
                        complete_batch_error(&pending_batch, error.clone());
                    }
                    // The final Mux owner can disappear while this writer is
                    // in a retry wait. Drain both ingress lanes so receipts
                    // for events that never entered the active batch cannot
                    // remain unresolved forever.
                    let _admission = receivers.state.enqueue_admission.lock().recover_poison();
                    complete_queued_error(&receivers, &error);
                    return;
                };
                // The whole iteration runs as the journal writer: any registry
                // lock taken here is counted and asserted (a request thread
                // holds the registry while it waits for this batch). It ends
                // before `mux` drops: the last owner's drop may lock it.
                let writer = JournalWriterCommitScope::enter();
                if Instant::now() >= retry_deadline {
                    let detail = "the batch deadline expired before commit";
                    let (deadline, rest) = (&mut retry_deadline, &mut pending);
                    if !contention::expire(&receivers, &mut batch, rest, deadline, detail) {
                        return;
                    }
                    if batch.is_empty() {
                        break;
                    }
                }
                let events = batch.iter().map(|queued| &queued.event).collect::<Vec<_>>();
                let committed = mux.commit_session_journal_events(
                    &events,
                    retry_deadline,
                    JOURNAL_SQLITE_RETRY_SLICE,
                    || admit_batch_commit(&receivers.state, &batch, retry_deadline),
                );
                match committed {
                    Ok(commits) => {
                        let terminal_events =
                            events.iter().filter(|e| e.lane() == JournalLane::Terminal).count();
                        receivers
                            .state
                            .stats
                            .batch_committed(terminal_events, events.len() - terminal_events);
                        // Release the mux before the receipts: a request that
                        // drops the last other owner after its receipt must not
                        // leave the final drop (and its session lease) to this
                        // thread.
                        // A batch no request waits for (background events)
                        // asks for its own flush; a request's reply does.
                        if batch.iter().all(|queued| queued.completion.is_none()) {
                            mux.request_registry_flush();
                        }
                        drop((writer, mux));
                        disk_full_retry.recovered(&receivers.state);
                        complete_batch_success(&batch, commits);
                        break;
                    }
                    Err(error) => {
                        receivers.state.stats.commit_failed();
                        let summary = format!("{error:#}");
                        if reported_error.as_deref() != Some(summary.as_str()) {
                            eprintln!("cmux-tui: append session journal batch: {summary}");
                            reported_error = Some(summary.clone());
                        }
                        if disk_full::is_disk_full(&error) {
                            drop((writer, mux));
                            let (batch, rest) = (&mut batch, &mut pending);
                            if !disk_full_retry.wait(&receivers, batch, rest, &summary) {
                                return;
                            }
                            if batch.is_empty() {
                                break;
                            }
                            // Only events nobody waits on are kept: no deadline.
                            retry_deadline = Instant::now() + journal_durable_wait();
                            continue;
                        }
                        let transient = contention::is_transient(&error, retry_deadline);
                        if Instant::now() >= retry_deadline {
                            let detail = format!("journal commit: {summary}");
                            if !transient {
                                stop_writer_after_retry_deadline(
                                    &receivers, &batch, pending, &detail,
                                );
                                return;
                            }
                            let (deadline, rest) = (&mut retry_deadline, &mut pending);
                            let (batch, detail) = (&mut batch, detail.as_str());
                            if !contention::expire(&receivers, batch, rest, deadline, detail) {
                                return;
                            }
                            if batch.is_empty() {
                                break;
                            }
                        }
                        let remaining = retry_deadline.saturating_duration_since(Instant::now());
                        if transient {
                            drop(writer);
                            wait_for_journal_retry(mux, delay.min(remaining));
                            delay = next_journal_retry_delay(delay);
                            continue;
                        }
                        if batch.len() > 1 {
                            let later = batch.split_off(batch.len() / 2);
                            pending.push_front(later);
                            pending.push_front(batch);
                        } else if batch.first().is_some_and(|event| event.completion.is_none())
                            && uncompleted_nonretryable_failures
                                < JOURNAL_TERMINAL_FAILURE_RETRY_ATTEMPTS
                        {
                            uncompleted_nonretryable_failures += 1;
                            #[cfg(test)]
                            if receivers.state.pause_nonretryable_failure_for_test() {
                                continue;
                            }
                            drop(writer);
                            wait_for_journal_retry(mux, nonretryable_delay.min(remaining));
                            nonretryable_delay = next_nonretryable_retry_delay(nonretryable_delay);
                            continue;
                        } else if batch.first().is_some_and(|event| event.completion.is_none()) {
                            let _admit = receivers.state.enqueue_admission.lock().recover_poison();
                            let failure = receivers.state.fail(format!(
                                "session journal writer failed permanently: {summary}"
                            ));
                            // A terminal journal failure must not strand the
                            // live terminal hosts. Mark journaling failed,
                            // fail pending receipts, and keep the daemon
                            // available so callers can reconnect or export
                            // their session before the next restart.
                            #[cfg(test)]
                            receivers.state.notify_failure_for_test(&failure);
                            complete_batch_error(&batch, failure.clone());
                            for pending_batch in pending {
                                complete_batch_error(&pending_batch, failure.clone());
                            }
                            complete_queued_error(&receivers, &failure);
                            return;
                        } else {
                            drop((writer, mux));
                            complete_batch_error(&batch, summary);
                        }
                        break;
                    }
                }
            }
        }
    }
}

fn wait_for_journal_retry(mux: Arc<Mux>, timeout: Duration) {
    wait_for_journal_retry_after_release(mux, timeout, || {});
}

fn wait_for_journal_retry_after_release(
    mux: Arc<Mux>,
    timeout: Duration,
    after_release: impl FnOnce(),
) {
    // Do not retain the owning mux while sleeping. Shutdown and drop must be
    // able to release the writer even when SQLite stays locked.
    let journal = mux.shared_journal_handle();
    let epoch = journal.epoch();
    drop(mux);
    after_release();
    journal.wait(epoch, timeout);
}

fn next_journal_retry_delay(delay: Duration) -> Duration {
    delay.saturating_mul(2).min(JOURNAL_RETRY_MAX_DELAY)
}

fn next_nonretryable_retry_delay(delay: Duration) -> Duration {
    next_journal_retry_delay(delay)
}

fn admit_batch_commit(
    state: &JournalIngressState,
    batch: &[QueuedJournalEvent],
    deadline: Instant,
) -> anyhow::Result<()> {
    let _admission = state.commit_admission.lock().recover_poison();
    if Instant::now() >= deadline {
        return Err(contention::JournalContention::COMMIT_DEADLINE.into());
    }
    anyhow::ensure!(
        batch.iter().filter_map(|queued| queued.completion.as_ref()).all(|completion| {
            completion.commit_fence().load(Ordering::Acquire) != COMMIT_CANCELED
        }),
        "session journal commit was canceled before admission"
    );
    for completion in batch.iter().filter_map(|queued| queued.completion.as_ref()) {
        completion.commit_fence().store(COMMIT_ADMITTED, Ordering::Release);
    }
    Ok(())
}

fn stop_writer_after_retry_deadline(
    receivers: &JournalIngressReceivers,
    batch: &[QueuedJournalEvent],
    pending: VecDeque<Vec<QueuedJournalEvent>>,
    detail: &str,
) {
    let _admission = receivers.state.enqueue_admission.lock().recover_poison();
    receivers.state.stats.deadline_expired();
    let failure = receivers.state.fail(format!(
        "session journal writer timed out after {} ms: {detail}",
        journal_durable_wait().as_millis()
    ));
    // Journal persistence is a recoverability aid, not a reason to tear down
    // every live terminal host. The failed state rejects later journal writes
    // while the daemon remains available for the user to recover the session.
    #[cfg(test)]
    receivers.state.notify_failure_for_test(&failure);
    complete_batch_error(batch, failure.clone());
    for pending_batch in pending {
        complete_batch_error(&pending_batch, failure.clone());
    }
    complete_queued_error(receivers, &failure);
}

fn complete_queued_error(receivers: &JournalIngressReceivers, error: &str) {
    let mut terminal_drained = 0;
    while let Ok(queued) = receivers.terminal.try_recv() {
        terminal_drained += 1;
        complete_batch_error(std::slice::from_ref(&queued), error.to_string());
    }
    let mut durable_drained = 0;
    while let Ok(queued) = receivers.durable.try_recv() {
        durable_drained += 1;
        complete_batch_error(std::slice::from_ref(&queued), error.to_string());
    }
    receivers.state.stats.drained(JournalLane::Terminal, terminal_drained);
    receivers.state.stats.drained(JournalLane::Durable, durable_drained);
    if terminal_drained + durable_drained != 0 {
        receivers.state.publish_queue_space();
    }
}

fn receive_batch(receivers: &JournalIngressReceivers) -> Option<Vec<QueuedJournalEvent>> {
    loop {
        // Producers share one SQLite writer and therefore one commit order, but
        // terminal bytes and external producers have separate bounded lanes.
        // Cap each transaction at 4 MiB of unmerged terminal input so a large
        // output burst does not inflate durable producer receipt latency.
        // Share an fsync across small producer events, while bounding a single
        // transaction even when producers submit their maximum payloads.
        while receivers.wake.try_recv().is_ok() {}
        let mut batch =
            Vec::with_capacity(JOURNAL_TERMINAL_BATCH_CHUNKS + JOURNAL_DURABLE_QUEUE_CAPACITY);
        let terminal_drained =
            drain_lane(&receivers.terminal, &mut batch, JOURNAL_TERMINAL_BATCH_CHUNKS, usize::MAX);
        let mut durable = Vec::new();
        let durable_drained = drain_lane(
            &receivers.durable,
            &mut durable,
            JOURNAL_DURABLE_QUEUE_CAPACITY,
            JOURNAL_DURABLE_BATCH_BYTES,
        );
        receivers.state.stats.drained(JournalLane::Terminal, terminal_drained);
        receivers.state.stats.drained(JournalLane::Durable, durable_drained);
        if terminal_drained + durable_drained != 0 {
            receivers.state.publish_queue_space();
        }
        // Test builds: plain terminal output waits a bounded window for more
        // output (coalesce.rs). Shipped builds journal no output.
        #[cfg(test)]
        coalesce::hold_terminal_output(receivers, &mut batch, &mut durable, terminal_drained);
        batch.append(&mut durable);
        if !batch.is_empty() {
            return Some(batch);
        }
        if receivers.state.closed.load(Ordering::Acquire) {
            return None;
        }
        if receivers.wake.recv().is_err() {
            return None;
        }
    }
}

fn drain_lane(
    receiver: &Receiver<QueuedJournalEvent>,
    batch: &mut Vec<QueuedJournalEvent>,
    limit: usize,
    byte_limit: usize,
) -> usize {
    let mut drained = 0;
    let mut drained_bytes = 0_usize;
    while drained < limit && drained_bytes < byte_limit {
        let next = match receiver.try_recv() {
            Ok(event) => event,
            Err(TryRecvError::Empty | TryRecvError::Disconnected) => break,
        };
        drained += 1;
        drained_bytes = drained_bytes.saturating_add(next.event.estimated_bytes());
        #[cfg(test)]
        coalesce::push_coalesced(batch, next);
        #[cfg(not(test))]
        batch.push(next);
    }
    drained
}

#[cfg(test)]
#[path = "journal_ingress_tests.rs"]
mod tests;
