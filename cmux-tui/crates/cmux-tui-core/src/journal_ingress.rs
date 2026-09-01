use std::collections::VecDeque;
use std::io;
use std::mem::size_of;
use std::sync::atomic::{AtomicBool, AtomicU8, Ordering};
use std::sync::mpsc::{Receiver, SyncSender, TryRecvError, TrySendError, sync_channel};
use std::sync::{Arc, Condvar, Mutex, Weak};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

use crate::Mux;
use crate::resource::{
    ContentPublicId, FrontendProjectionPublicId, PanePublicId, ScreenPublicId, TabPublicId,
    TerminalPublicId, WorkspacePublicId,
};

const JOURNAL_TERMINAL_QUEUE_CAPACITY: usize = 1024;
const JOURNAL_DURABLE_QUEUE_CAPACITY: usize = 256;
const JOURNAL_TERMINAL_BATCH_CHUNKS: usize = 64;
const JOURNAL_DURABLE_BATCH_BYTES: usize = 8 * 1024 * 1024;
pub(crate) const TERMINAL_OUTPUT_INGRESS_BYTES: usize = 64 * 1024;
const TERMINAL_OUTPUT_BATCH_BYTES: usize = 256 * 1024;
const JOURNAL_TERMINAL_FAILURE_RETRY_ATTEMPTS: usize = 6;
const JOURNAL_DURABLE_WAIT: Duration = Duration::from_secs(2);
const JOURNAL_COMMIT_RESULT_WAIT: Duration = Duration::from_secs(1);
const JOURNAL_WRITER_SHUTDOWN_WAIT: Duration = Duration::from_secs(1);
const JOURNAL_SQLITE_RETRY_SLICE: Duration = Duration::from_millis(100);
const COMMIT_PENDING: u8 = 0;
const COMMIT_ADMITTED: u8 = 1;
const COMMIT_CANCELED: u8 = 2;

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
    /// Durable evidence that the terminal host could not prove a complete
    /// source drain before daemon handoff. This record stays in the terminal
    /// lane after all bytes accepted by the old reader and before its barrier.
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
}

impl JournalIngressEvent {
    fn estimated_bytes(&self) -> usize {
        match self {
            Self::TerminalBarrier => 0,
            Self::TerminalOutput { bytes, .. } => bytes.len(),
            Self::TerminalResize { .. } => 64,
            Self::TerminalOutputGap { .. } => 128,
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
}

impl JournalIngressCompletion {
    fn deadline(&self) -> Instant {
        match self {
            Self::Durable { deadline, .. } | Self::Producer { deadline, .. } => *deadline,
        }
    }

    fn commit_fence(&self) -> &AtomicU8 {
        match self {
            Self::Durable { commit_fence, .. } | Self::Producer { commit_fence, .. } => {
                commit_fence
            }
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
        *self.result.lock().unwrap() = Some(result);
        self.changed.notify_all();
    }

    fn wait_until(&self, deadline: Instant) -> anyhow::Result<()> {
        let mut result = self.result.lock().unwrap();
        while result.is_none() {
            let wait = deadline.saturating_duration_since(Instant::now());
            if wait.is_zero() {
                anyhow::bail!("session journal writer did not stop before the shutdown deadline");
            }
            let (next, timeout) = self.changed.wait_timeout(result, wait).unwrap();
            result = next;
            if timeout.timed_out() && result.is_none() {
                anyhow::bail!("session journal writer did not stop before the shutdown deadline");
            }
        }
        result.clone().unwrap().map_err(anyhow::Error::msg)
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

pub(crate) enum JournalIngressTrySendError {
    Full { event: Box<JournalIngressEvent>, space_epoch: u64 },
    Failed { event: Box<JournalIngressEvent>, error: String },
}

#[derive(Default)]
struct JournalIngressState {
    failure: Mutex<Option<String>>,
    enqueue_admission: Mutex<()>,
    closed: AtomicBool,
    commit_admission: Mutex<()>,
    queue_space_epoch: Mutex<u64>,
    queue_space_changed: Condvar,
    #[cfg(test)]
    failure_notifier: Mutex<Option<SyncSender<String>>>,
    #[cfg(test)]
    nonretryable_failure_hook: Mutex<Option<(SyncSender<()>, Receiver<()>)>>,
    #[cfg(test)]
    enqueue_full_notifier: Mutex<Option<SyncSender<()>>>,
}

impl JournalIngressState {
    fn failure(&self) -> Option<String> {
        self.failure.lock().unwrap().clone()
    }

    fn fail(&self, error: String) -> String {
        let mut stored_failure = self.failure.lock().unwrap();
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
        let _admission = self.enqueue_admission.lock().unwrap();
        self.closed.store(true, Ordering::Release);
        self.publish_queue_space();
    }

    #[cfg(test)]
    fn notify_failure_for_test(&self, failure: &str) {
        if let Some(notifier) = self.failure_notifier.lock().unwrap().take() {
            let _ = notifier.send(failure.to_string());
        }
    }

    #[cfg(test)]
    fn pause_nonretryable_failure_for_test(&self) -> bool {
        let hook = self.nonretryable_failure_hook.lock().unwrap().take();
        let Some((entered, release)) = hook else { return false };
        entered.send(()).expect("nonretryable journal failure observer closed");
        release.recv().expect("nonretryable journal failure release closed");
        true
    }

    fn queue_space_epoch(&self) -> u64 {
        *self.queue_space_epoch.lock().unwrap()
    }

    fn publish_queue_space(&self) {
        let mut epoch = self.queue_space_epoch.lock().unwrap();
        *epoch = epoch.wrapping_add(1);
        self.queue_space_changed.notify_all();
    }

    fn wait_for_queue_space_until(&self, observed: u64, deadline: Instant) -> Result<(), String> {
        let mut epoch = self.queue_space_epoch.lock().unwrap();
        while *epoch == observed {
            if let Some(error) = self.admission_error() {
                return Err(error);
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return Err(format!(
                    "timed out after {} ms waiting to queue a durable session journal event",
                    JOURNAL_DURABLE_WAIT.as_millis()
                ));
            }
            let (next, result) = self.queue_space_changed.wait_timeout(epoch, remaining).unwrap();
            epoch = next;
            if result.timed_out() && *epoch == observed {
                return Err(format!(
                    "timed out after {} ms waiting to queue a durable session journal event",
                    JOURNAL_DURABLE_WAIT.as_millis()
                ));
            }
        }
        Ok(())
    }

    fn wait_for_queue_space(&self, observed: u64) -> Result<(), String> {
        self.wait_for_queue_space_until(observed, Instant::now() + JOURNAL_DURABLE_WAIT)
    }

    fn wait_for_queue_space_change(&self, observed: u64) -> Result<(), String> {
        let mut epoch = self.queue_space_epoch.lock().unwrap();
        while *epoch == observed {
            if let Some(error) = self.admission_error() {
                return Err(error);
            }
            epoch = self.queue_space_changed.wait(epoch).unwrap();
        }
        Ok(())
    }

    #[cfg(test)]
    fn notify_enqueue_full_for_test(&self) {
        if let Some(notifier) = self.enqueue_full_notifier.lock().unwrap().take() {
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

    pub(crate) fn send(&self, event: JournalIngressEvent) {
        debug_assert!(matches!(
            &event,
            JournalIngressEvent::TerminalOutput { .. } | JournalIngressEvent::TerminalResize { .. }
        ));
        let Some(sender) = &self.terminal_sender else { return };
        match event {
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

    pub(crate) fn try_send(
        &self,
        event: JournalIngressEvent,
    ) -> Result<(), JournalIngressTrySendError> {
        debug_assert!(matches!(
            &event,
            JournalIngressEvent::TerminalOutput { .. } | JournalIngressEvent::TerminalResize { .. }
        ));
        let Some(sender) = &self.terminal_sender else { return Ok(()) };
        let _admission = self.state.enqueue_admission.lock().unwrap();
        if let Some(error) = self.state.admission_error() {
            return Err(JournalIngressTrySendError::Failed { event: Box::new(event), error });
        }
        let space_epoch = self.state.queue_space_epoch();
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
                Err(JournalIngressTrySendError::Full { event: Box::new(queued.event), space_epoch })
            }
            Err(TrySendError::Disconnected(queued)) => Err(JournalIngressTrySendError::Failed {
                event: Box::new(queued.event),
                error: self.writer_error(),
            }),
        }
    }

    pub(crate) fn send_durable(&self, event: JournalIngressEvent) -> anyhow::Result<()> {
        if let Some(error) = self.state.admission_error() {
            anyhow::bail!(error);
        }
        let sender = if matches!(
            &event,
            JournalIngressEvent::TerminalBarrier | JournalIngressEvent::TerminalOutputGap { .. }
        ) {
            &self.terminal_sender
        } else {
            &self.durable_sender
        };
        let Some(sender) = sender else { return Ok(()) };
        let (completion, result) = sync_channel(1);
        let deadline = Instant::now() + JOURNAL_DURABLE_WAIT;
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
        self.wait_for_commit_result(
            result,
            deadline,
            &commit_fence,
            "waiting for session journal durability",
        )
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
        let deadline = Instant::now() + JOURNAL_DURABLE_WAIT;
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
        self.wait_for_commit_result(
            result,
            deadline,
            &commit_fence,
            "waiting for a session journal producer receipt",
        )
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
            let mut owner = self.writer.lock().unwrap();
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
                JournalWriterOwner::Reserved => {
                    unreachable!("journal writer reservation escaped its owner lock")
                }
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
        let mut owner = self.writer.lock().unwrap();
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
        *self.state.failure_notifier.lock().unwrap() = Some(notifier);
    }

    #[cfg(test)]
    pub(crate) fn install_nonretryable_failure_hook_for_test(
        &self,
        entered: SyncSender<()>,
        release: Receiver<()>,
    ) {
        *self.state.nonretryable_failure_hook.lock().unwrap() = Some((entered, release));
    }

    #[cfg(test)]
    fn install_enqueue_full_notifier_for_test(&self, notifier: SyncSender<()>) {
        *self.state.enqueue_full_notifier.lock().unwrap() = Some(notifier);
    }

    fn enqueue(
        &self,
        sender: &SyncSender<QueuedJournalEvent>,
        event: QueuedJournalEvent,
    ) -> Result<(), String> {
        let mut pending = event;
        loop {
            let space_epoch = self.state.queue_space_epoch();
            let result = {
                let _admission = self.state.enqueue_admission.lock().unwrap();
                if let Some(error) = self.state.admission_error() {
                    return Err(error);
                }
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
                Err(TrySendError::Full(event)) => pending = event,
                Err(TrySendError::Disconnected(_)) => return Err(self.writer_error()),
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
        let mut pending = event;
        loop {
            if Instant::now() >= deadline {
                return Err(format!(
                    "timed out after {} ms waiting to queue a durable session journal event",
                    JOURNAL_DURABLE_WAIT.as_millis()
                ));
            }
            let space_epoch = self.state.queue_space_epoch();
            let result = {
                let _admission = self.state.enqueue_admission.lock().unwrap();
                if Instant::now() >= deadline {
                    return Err(format!(
                        "timed out after {} ms waiting to queue a durable session journal event",
                        JOURNAL_DURABLE_WAIT.as_millis()
                    ));
                }
                if let Some(error) = self.state.admission_error() {
                    return Err(error);
                }
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
                Err(TrySendError::Full(event)) => pending = event,
                Err(TrySendError::Disconnected(_)) => return Err(self.writer_error()),
            }
            self.state.wait_for_queue_space_until(space_epoch, deadline)?;
        }
    }

    pub(crate) fn wait_for_queue_space(&self, observed: u64) -> Result<(), String> {
        self.state.wait_for_queue_space(observed)
    }

    fn writer_error(&self) -> String {
        self.state.admission_error().unwrap_or_else(|| "session journal writer stopped".into())
    }

    fn wait_for_commit_result<T>(
        &self,
        result: Receiver<Result<T, String>>,
        deadline: Instant,
        commit_fence: &AtomicU8,
        operation: &str,
    ) -> anyhow::Result<T> {
        match result.recv_timeout(deadline.saturating_duration_since(Instant::now())) {
            Ok(result) => result.map_err(anyhow::Error::msg),
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                Err(anyhow::Error::msg(self.writer_error()))
            }
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                let admission = self.state.commit_admission.lock().unwrap();
                match commit_fence.load(Ordering::Acquire) {
                    COMMIT_PENDING => {
                        commit_fence.store(COMMIT_CANCELED, Ordering::Release);
                        Err(anyhow::anyhow!(
                            "timed out after {} ms {operation}",
                            JOURNAL_DURABLE_WAIT.as_millis()
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
                                    JOURNAL_DURABLE_WAIT.saturating_add(JOURNAL_COMMIT_RESULT_WAIT),
                                )))
                            }
                        }
                    }
                    COMMIT_CANCELED => Err(anyhow::anyhow!(
                        "timed out after {} ms {operation}",
                        JOURNAL_DURABLE_WAIT.as_millis()
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
    mux.spawn_journal_writer("mux-session-journal-writer", move || run(weak, receivers))
}

fn run(mux: Weak<Mux>, receivers: JournalIngressReceivers) {
    loop {
        let Some(batch) = receive_batch(&receivers) else { return };
        let mut pending = VecDeque::from([batch]);
        while let Some(mut batch) = pending.pop_front() {
            let mut delay = Duration::from_millis(10);
            let mut reported_error = None;
            let mut uncompleted_nonretryable_failures = 0_usize;
            let retry_deadline = batch
                .iter()
                .filter_map(QueuedJournalEvent::deadline)
                .min()
                .unwrap_or_else(|| Instant::now() + JOURNAL_DURABLE_WAIT);
            loop {
                let Some(mux) = mux.upgrade() else {
                    let error = "session journal stopped".to_string();
                    complete_batch_error(&batch, error.clone());
                    for pending_batch in pending {
                        complete_batch_error(&pending_batch, error.clone());
                    }
                    return;
                };
                if Instant::now() >= retry_deadline {
                    stop_writer_after_retry_deadline(
                        &mux,
                        &receivers,
                        &batch,
                        pending,
                        "the batch deadline expired before commit",
                    );
                    return;
                }
                let events = batch.iter().map(|queued| &queued.event).collect::<Vec<_>>();
                match mux.commit_session_journal_events(
                    &events,
                    retry_deadline,
                    JOURNAL_SQLITE_RETRY_SLICE,
                    || admit_batch_commit(&receivers.state, &batch, retry_deadline),
                ) {
                    Ok(commits) => {
                        complete_batch_success(&batch, commits);
                        break;
                    }
                    Err(error) => {
                        let summary = format!("{error:#}");
                        if reported_error.as_deref() != Some(summary.as_str()) {
                            eprintln!("cmux-tui: append session journal batch: {summary}");
                            reported_error = Some(summary.clone());
                        }
                        let remaining = retry_deadline.saturating_duration_since(Instant::now());
                        if remaining.is_zero() {
                            stop_writer_after_retry_deadline(
                                &mux,
                                &receivers,
                                &batch,
                                pending,
                                &format!("journal commit: {summary}"),
                            );
                            return;
                        }
                        if retryable_sqlite_error(&error) {
                            let epoch = mux.journal_event_epoch();
                            mux.wait_for_journal_event(epoch, delay.min(remaining));
                            delay = (delay * 2).min(Duration::from_secs(1));
                            continue;
                        }
                        if batch.len() > 1 {
                            let later = batch.split_off(batch.len() / 2);
                            pending.push_front(later);
                            pending.push_front(batch);
                        } else if batch[0].completion.is_none()
                            && uncompleted_nonretryable_failures
                                < JOURNAL_TERMINAL_FAILURE_RETRY_ATTEMPTS
                        {
                            uncompleted_nonretryable_failures += 1;
                            #[cfg(test)]
                            if receivers.state.pause_nonretryable_failure_for_test() {
                                continue;
                            }
                            let epoch = mux.journal_event_epoch();
                            mux.wait_for_journal_event(epoch, delay);
                            delay = (delay * 2).min(Duration::from_secs(1));
                            continue;
                        } else if batch[0].completion.is_none() {
                            let failure = receivers.state.fail(format!(
                                "session journal writer failed permanently: {summary}"
                            ));
                            mux.request_daemon_shutdown();
                            #[cfg(test)]
                            receivers.state.notify_failure_for_test(&failure);
                            complete_batch_error(&batch, failure.clone());
                            for pending_batch in pending {
                                complete_batch_error(&pending_batch, failure.clone());
                            }
                            return;
                        } else {
                            complete_batch_error(&batch, summary);
                        }
                        break;
                    }
                }
            }
        }
    }
}

fn admit_batch_commit(
    state: &JournalIngressState,
    batch: &[QueuedJournalEvent],
    deadline: Instant,
) -> anyhow::Result<()> {
    let _admission = state.commit_admission.lock().unwrap();
    anyhow::ensure!(Instant::now() < deadline, "session journal commit deadline expired");
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
    mux: &Mux,
    receivers: &JournalIngressReceivers,
    batch: &[QueuedJournalEvent],
    pending: VecDeque<Vec<QueuedJournalEvent>>,
    detail: &str,
) {
    let failure = receivers.state.fail(format!(
        "session journal writer timed out after {} ms: {detail}",
        JOURNAL_DURABLE_WAIT.as_millis()
    ));
    mux.request_daemon_shutdown();
    #[cfg(test)]
    receivers.state.notify_failure_for_test(&failure);
    complete_batch_error(batch, failure.clone());
    for pending_batch in pending {
        complete_batch_error(&pending_batch, failure.clone());
    }
    complete_queued_error(receivers, &failure);
}

fn complete_queued_error(receivers: &JournalIngressReceivers, error: &str) {
    let mut drained = false;
    while let Ok(queued) = receivers.terminal.try_recv() {
        drained = true;
        complete_batch_error(std::slice::from_ref(&queued), error.to_string());
    }
    while let Ok(queued) = receivers.durable.try_recv() {
        drained = true;
        complete_batch_error(std::slice::from_ref(&queued), error.to_string());
    }
    if drained {
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
        let mut drained =
            drain_lane(&receivers.terminal, &mut batch, JOURNAL_TERMINAL_BATCH_CHUNKS, usize::MAX);
        drained |= drain_lane(
            &receivers.durable,
            &mut batch,
            JOURNAL_DURABLE_QUEUE_CAPACITY,
            JOURNAL_DURABLE_BATCH_BYTES,
        );
        if drained {
            receivers.state.publish_queue_space();
        }
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
) -> bool {
    let mut drained = 0;
    let mut drained_bytes = 0_usize;
    while drained < limit && drained_bytes < byte_limit {
        let next = match receiver.try_recv() {
            Ok(event) => event,
            Err(TryRecvError::Empty | TryRecvError::Disconnected) => break,
        };
        drained += 1;
        drained_bytes = drained_bytes.saturating_add(next.event.estimated_bytes());
        if let Some(last) = batch.last_mut() {
            if let Some(next) = last.merge_output(next) {
                batch.push(next);
            }
        } else {
            batch.push(next);
        }
    }
    drained != 0
}

fn retryable_sqlite_error(error: &anyhow::Error) -> bool {
    error.chain().any(|cause| {
        matches!(
            cause.downcast_ref::<rusqlite::Error>(),
            Some(rusqlite::Error::SqliteFailure(
                rusqlite::ffi::Error {
                    code: rusqlite::ErrorCode::DatabaseBusy | rusqlite::ErrorCode::DatabaseLocked,
                    ..
                },
                _
            ))
        )
    })
}

fn complete_batch_success(
    batch: &[QueuedJournalEvent],
    commits: Vec<Option<crate::JournalAppendCommit>>,
) {
    if commits.len() != batch.len() {
        complete_batch_error(batch, "session journal returned an incomplete batch".into());
        return;
    }
    for (queued, commit) in batch.iter().zip(commits) {
        match &queued.completion {
            Some(JournalIngressCompletion::Durable { sender, .. }) => {
                let _ = sender.send(Ok(()));
            }
            Some(JournalIngressCompletion::Producer { sender, .. }) => {
                let result = commit
                    .ok_or_else(|| "session journal omitted a producer append receipt".into());
                let _ = sender.send(result);
            }
            None => {}
        }
    }
}

fn complete_batch_error(batch: &[QueuedJournalEvent], error: String) {
    for queued in batch {
        match &queued.completion {
            Some(JournalIngressCompletion::Durable { sender, .. }) => {
                let _ = sender.send(Err(error.clone()));
            }
            Some(JournalIngressCompletion::Producer { sender, .. }) => {
                let _ = sender.send(Err(error.clone()));
            }
            None => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::resource::{
        FrontendProjectionPublicId, PanePublicId, ScreenPublicId, TabPublicId, WorkspacePublicId,
    };

    fn public_id<T>(
        prefix: &str,
        value: u128,
        parse: impl FnOnce(String) -> Result<T, crate::resource::ResourceError>,
    ) -> T {
        parse(format!("{prefix}_{value:032x}")).unwrap()
    }

    #[test]
    fn frontend_events_are_durable_idempotent_and_stably_scoped() {
        let root = std::env::temp_dir().join(format!(
            "cmux-frontend-journal-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        let mux = Mux::open_persistent("frontend-journal", crate::SurfaceOptions::default(), &root)
            .unwrap();
        let workspace_id = public_id("ws", 1, WorkspacePublicId::parse);
        let screen_id = public_id("screen", 2, ScreenPublicId::parse);
        let pane_id = public_id("pane", 3, PanePublicId::parse);
        let tab_id = public_id("tab", 4, TabPublicId::parse);
        let terminal_id = public_id("term", 5, TerminalPublicId::parse);
        let projection_id = public_id("projection", 6, FrontendProjectionPublicId::parse);
        let event = FrontendJournalEvent::Focus {
            event_id: "event_frontend_focus_test".into(),
            frontend_projection_id: projection_id.clone(),
            generation: "frontend_generation_1".into(),
            target: FrontendFocusTarget::Pane,
            workspace_id: Some(workspace_id.clone()),
            screen_id: Some(screen_id.clone()),
            pane_id: Some(pane_id.clone()),
            tab_id: Some(tab_id.clone()),
            content_id: Some(ContentPublicId::Terminal(terminal_id.clone())),
        };
        mux.journal_local_frontend_event(event.clone()).unwrap();
        mux.journal_local_frontend_event(event).unwrap();

        let records = mux.session_journal_after(0, 1024).unwrap().records;
        let records = records
            .iter()
            .filter(|record| record.kind == "frontend.focus.changed")
            .collect::<Vec<_>>();
        assert_eq!(records.len(), 1);
        let record = records[0];
        assert_eq!(record.sensitivity, crate::JournalSensitivity::Metadata);
        assert_eq!(record.replay, crate::JournalReplayPolicy::Advisory);
        assert_eq!(record.authority.as_ref().unwrap().role, "frontend.observer");
        for (kind, id) in [
            ("workspace", workspace_id.as_str()),
            ("screen", screen_id.as_str()),
            ("pane", pane_id.as_str()),
            ("tab", tab_id.as_str()),
            ("terminal", terminal_id.as_str()),
            ("frontend_projection", projection_id.as_str()),
        ] {
            assert!(record.subjects.iter().any(|subject| subject.kind == kind && subject.id == id));
        }
        drop(mux);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn frontend_event_id_reuse_with_different_content_is_rejected() {
        let root = std::env::temp_dir().join(format!(
            "cmux-frontend-journal-conflict-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        let mux = Mux::open_persistent(
            "frontend-journal-conflict",
            crate::SurfaceOptions::default(),
            &root,
        )
        .unwrap();
        let projection_id = public_id("projection", 7, FrontendProjectionPublicId::parse);
        let event = |cols| FrontendJournalEvent::Resize {
            event_id: "event_frontend_resize_conflict".into(),
            frontend_projection_id: projection_id.clone(),
            generation: "frontend_generation_1".into(),
            cols,
            rows: 24,
            cell_width: 8,
            cell_height: 16,
        };
        mux.journal_local_frontend_event(event(80)).unwrap();
        let error = mux.journal_local_frontend_event(event(81)).unwrap_err();
        assert!(error.to_string().contains("reused with different content"));
        drop(mux);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn frontend_event_retry_after_segment_sealing_is_idempotent() {
        let root = std::env::temp_dir().join(format!(
            "cmux-frontend-journal-sealed-retry-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        let mux = Mux::open_persistent(
            "frontend-journal-sealed-retry",
            crate::SurfaceOptions::default(),
            &root,
        )
        .unwrap();
        let projection_id = public_id("projection", 8, FrontendProjectionPublicId::parse);
        let event = FrontendJournalEvent::Resize {
            event_id: "event_frontend_resize_sealed_retry".into(),
            frontend_projection_id: projection_id,
            generation: "frontend_generation_1".into(),
            cols: 80,
            rows: 24,
            cell_width: 8,
            cell_height: 16,
        };
        mux.journal_local_frontend_event(event.clone()).unwrap();
        let checkpoint =
            mux.create_journal_checkpoint("client_test", "frontend_sealed_checkpoint").unwrap();
        mux.seal_journal_segments(
            checkpoint.checkpoint.source_sequence,
            "client_test",
            "frontend_sealed_segment",
        )
        .unwrap();

        mux.journal_local_frontend_event(event).unwrap();
        let records = mux.session_journal_after(0, 1024).unwrap().records;
        assert_eq!(
            records
                .iter()
                .filter(|record| record.event_id == "event_frontend_resize_sealed_retry")
                .count(),
            1
        );
        drop(mux);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn shutdown_waits_for_queued_terminal_journal_output() {
        let root = std::env::temp_dir().join(format!(
            "cmux-terminal-journal-shutdown-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        let mux = Mux::open_persistent(
            "terminal-journal-shutdown",
            crate::SurfaceOptions::default(),
            &root,
        )
        .unwrap();
        let database_path = std::fs::read_dir(&root)
            .unwrap()
            .filter_map(Result::ok)
            .map(|entry| entry.path().join("workspace-registry.sqlite3"))
            .find(|path| path.is_file())
            .expect("persistent journal database");
        let blocker = rusqlite::Connection::open(database_path).unwrap();
        blocker.execute_batch("BEGIN IMMEDIATE;").unwrap();
        let terminal_id = Arc::new(public_id("term", 12, TerminalPublicId::parse));
        mux.journal_terminal_output(
            terminal_id,
            Arc::from("shutdown-generation"),
            b"persist before shutdown returns".to_vec(),
        );

        let shutdown_mux = mux.clone();
        let (completed, completion) = sync_channel(1);
        let shutdown = std::thread::spawn(move || {
            shutdown_mux.shutdown();
            completed.send(()).unwrap();
        });
        assert!(
            completion.recv_timeout(Duration::from_millis(100)).is_err(),
            "shutdown returned before the queued journal write could commit"
        );
        blocker.execute_batch("ROLLBACK;").unwrap();
        completion.recv_timeout(Duration::from_secs(5)).unwrap();
        shutdown.join().unwrap();

        let records = mux.session_journal_after(0, 1024).unwrap().records;
        let output = records
            .iter()
            .find(|record| record.kind == "terminal.output")
            .expect("shutdown fenced queued terminal output");
        assert_eq!(
            output.terminal_output.as_deref(),
            Some(b"persist before shutdown returns".as_slice())
        );
        drop(blocker);
        drop(mux);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn shutdown_has_a_deadline_when_the_journal_stays_locked() {
        let root = std::env::temp_dir().join(format!(
            "cmux-terminal-journal-locked-shutdown-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        let mux = Mux::open_persistent(
            "terminal-journal-locked-shutdown",
            crate::SurfaceOptions::default(),
            &root,
        )
        .unwrap();
        let database_path = std::fs::read_dir(&root)
            .unwrap()
            .filter_map(Result::ok)
            .map(|entry| entry.path().join("workspace-registry.sqlite3"))
            .find(|path| path.is_file())
            .expect("persistent journal database");
        let blocker = rusqlite::Connection::open(database_path).unwrap();
        blocker.execute_batch("BEGIN IMMEDIATE;").unwrap();
        mux.journal_terminal_output(
            Arc::new(public_id("term", 15, TerminalPublicId::parse)),
            Arc::from("locked-shutdown-generation"),
            b"blocked until the shutdown deadline".to_vec(),
        );

        let started = Instant::now();
        mux.shutdown();

        assert!(
            started.elapsed() < JOURNAL_DURABLE_WAIT + Duration::from_secs(2),
            "a locked journal must not prevent shutdown forever"
        );
        assert!(
            mux.daemon_shutdown_requested(),
            "a journal lock beyond the fixed deadline must stop the daemon"
        );
        blocker.execute_batch("ROLLBACK;").unwrap();
        assert!(
            mux.flush_terminal_journal().unwrap_err().to_string().contains("timed out"),
            "later writes must observe the terminal journal failure"
        );
        drop(blocker);
        drop(mux);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn producer_receipt_and_sqlite_retries_share_one_deadline() {
        let root = std::env::temp_dir().join(format!(
            "cmux-journal-producer-locked-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        let mux = Mux::open_persistent(
            "journal-producer-locked",
            crate::SurfaceOptions::default(),
            &root,
        )
        .unwrap();
        let database_path = std::fs::read_dir(&root)
            .unwrap()
            .filter_map(Result::ok)
            .map(|entry| entry.path().join("workspace-registry.sqlite3"))
            .find(|path| path.is_file())
            .expect("persistent journal database");
        let blocker = rusqlite::Connection::open(database_path).unwrap();
        blocker.execute_batch("BEGIN IMMEDIATE;").unwrap();
        let ingress = crate::agent_hook_journal_ingress(
            "codex",
            "SubagentStop",
            None,
            serde_json::json!({
                "session_id":"locked-producer-root",
                "root_session_id":"locked-producer-root",
                "parent_session_id":"locked-producer-root",
                "child_agent_id":"locked-producer-child",
                "message":"must return at the fixed deadline",
            }),
        )
        .unwrap();
        let (failed, failed_receiver) = sync_channel(1);
        mux.install_journal_failure_notifier_for_test(failed);

        let started = Instant::now();
        let error = mux
            .append_journal_ingress(&ingress, "client_locked_producer", "locked_producer_1")
            .unwrap_err();

        assert!(error.to_string().contains("timed out"));
        assert!(
            started.elapsed() < JOURNAL_DURABLE_WAIT + Duration::from_secs(2),
            "a producer receipt must not wait without a limit"
        );
        failed_receiver.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(
            mux.daemon_shutdown_requested(),
            "a producer database lock beyond the deadline must stop the daemon"
        );
        blocker.execute_batch("ROLLBACK;").unwrap();
        drop(blocker);
        drop(mux);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn producer_deadline_includes_workspace_registry_mutex_admission() {
        let root = std::env::temp_dir().join(format!(
            "cmux-journal-producer-registry-lock-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        let mux = Mux::open_persistent(
            "journal-producer-registry-lock",
            crate::SurfaceOptions::default(),
            &root,
        )
        .unwrap();
        let locked_mux = mux.clone();
        let (entered, entered_receiver) = sync_channel(1);
        let (release, release_receiver) = sync_channel(1);
        let blocker = std::thread::spawn(move || {
            locked_mux.hold_workspace_registry_for_test(entered, release_receiver);
        });
        entered_receiver.recv().unwrap();
        let ingress = crate::agent_hook_journal_ingress(
            "codex",
            "SubagentStop",
            None,
            serde_json::json!({
                "session_id":"registry-lock-root",
                "root_session_id":"registry-lock-root",
                "parent_session_id":"registry-lock-root",
                "child_agent_id":"registry-lock-child",
                "message":"registry-mutex-deadline-marker",
            }),
        )
        .unwrap();
        let (failed, failed_receiver) = sync_channel(1);
        mux.install_journal_failure_notifier_for_test(failed);

        let started = Instant::now();
        let error = mux
            .append_journal_ingress(&ingress, "client_registry_lock", "registry_lock_deadline_1")
            .unwrap_err();

        assert!(error.to_string().contains("timed out"));
        assert!(
            started.elapsed() < JOURNAL_DURABLE_WAIT + Duration::from_secs(2),
            "registry mutex admission must not outlive the producer deadline"
        );
        failed_receiver.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(mux.daemon_shutdown_requested());
        release.send(()).unwrap();
        blocker.join().unwrap();
        let records = mux.session_journal_after(0, 1024).unwrap().records;
        assert!(
            records.iter().all(|record| {
                record.correlation_id.as_deref() != Some("registry_lock_deadline_1")
            }),
            "a producer event must not commit after its mutex admission deadline"
        );
        drop(mux);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn producer_deadline_prevents_a_late_transaction_commit() {
        let root = std::env::temp_dir().join(format!(
            "cmux-journal-producer-commit-deadline-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        let mux = Mux::open_persistent(
            "journal-producer-commit-deadline",
            crate::SurfaceOptions::default(),
            &root,
        )
        .unwrap();
        let (entered, entered_receiver) = sync_channel(1);
        let (release, release_receiver) = sync_channel(1);
        mux.install_journal_before_commit_for_test(entered, release_receiver);
        let (failed, failed_receiver) = sync_channel(1);
        mux.install_journal_failure_notifier_for_test(failed);
        let ingress = crate::agent_hook_journal_ingress(
            "codex",
            "SubagentStop",
            None,
            serde_json::json!({
                "session_id":"commit-deadline-root",
                "root_session_id":"commit-deadline-root",
                "parent_session_id":"commit-deadline-root",
                "child_agent_id":"commit-deadline-child",
                "message":"transaction-deadline-marker",
            }),
        )
        .unwrap();
        let producer_mux = mux.clone();
        let (result_sender, result_receiver) = sync_channel(1);
        let producer = std::thread::spawn(move || {
            result_sender
                .send(producer_mux.append_journal_ingress(
                    &ingress,
                    "client_commit_deadline",
                    "commit_deadline_1",
                ))
                .unwrap();
        });
        entered_receiver.recv_timeout(Duration::from_secs(1)).unwrap();

        let error = result_receiver
            .recv_timeout(JOURNAL_DURABLE_WAIT + Duration::from_secs(1))
            .expect("producer must return at its fixed deadline")
            .unwrap_err();
        assert!(error.to_string().contains("timed out"));
        release.send(()).unwrap();
        producer.join().unwrap();
        failed_receiver.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(mux.daemon_shutdown_requested());
        let records = mux.session_journal_after(0, 1024).unwrap().records;
        assert!(
            records
                .iter()
                .all(|record| { record.correlation_id.as_deref() != Some("commit_deadline_1") }),
            "a producer transaction must roll back after its deadline"
        );
        drop(mux);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn producer_waits_for_an_admitted_commit_past_its_deadline() {
        let root = std::env::temp_dir().join(format!(
            "cmux-journal-producer-admitted-commit-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        let mux = Mux::open_persistent(
            "journal-producer-admitted-commit",
            crate::SurfaceOptions::default(),
            &root,
        )
        .unwrap();
        let (entered, entered_receiver) = sync_channel(1);
        let (release, release_receiver) = sync_channel(1);
        mux.install_journal_after_commit_admission_for_test(entered, release_receiver);
        let ingress = crate::agent_hook_journal_ingress(
            "codex",
            "SubagentStop",
            None,
            serde_json::json!({
                "session_id":"admitted-commit-root",
                "root_session_id":"admitted-commit-root",
                "parent_session_id":"admitted-commit-root",
                "child_agent_id":"admitted-commit-child",
                "message":"admitted-commit-marker",
            }),
        )
        .unwrap();
        let producer_mux = mux.clone();
        let (result_sender, result_receiver) = sync_channel(1);
        let producer = std::thread::spawn(move || {
            result_sender
                .send(producer_mux.append_journal_ingress(
                    &ingress,
                    "client_admitted_commit",
                    "admitted_commit_1",
                ))
                .unwrap();
        });
        entered_receiver.recv_timeout(Duration::from_secs(1)).unwrap();

        assert!(
            result_receiver
                .recv_timeout(JOURNAL_DURABLE_WAIT + Duration::from_millis(100))
                .is_err(),
            "an admitted commit must not report a timeout while its result is unknown"
        );
        release.send(()).unwrap();
        result_receiver.recv_timeout(Duration::from_secs(1)).unwrap().unwrap();
        producer.join().unwrap();
        let records = mux.session_journal_after(0, 1024).unwrap().records;
        assert!(
            records
                .iter()
                .any(|record| { record.correlation_id.as_deref() == Some("admitted_commit_1") }),
            "the caller must observe success for the admitted durable commit"
        );
        drop(mux);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn producer_bounds_an_admitted_commit_with_an_indeterminate_result() {
        let root = std::env::temp_dir().join(format!(
            "cmux-journal-producer-indeterminate-commit-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        let mux = Mux::open_persistent(
            "journal-producer-indeterminate-commit",
            crate::SurfaceOptions::default(),
            &root,
        )
        .unwrap();
        let (entered, entered_receiver) = sync_channel(1);
        let (release, release_receiver) = sync_channel(1);
        mux.install_journal_after_commit_admission_for_test(entered, release_receiver);
        let ingress = crate::agent_hook_journal_ingress(
            "codex",
            "SubagentStop",
            None,
            serde_json::json!({
                "session_id":"indeterminate-commit-root",
                "root_session_id":"indeterminate-commit-root",
                "parent_session_id":"indeterminate-commit-root",
                "child_agent_id":"indeterminate-commit-child",
                "message":"indeterminate-commit-marker",
            }),
        )
        .unwrap();
        let producer_mux = mux.clone();
        let (result_sender, result_receiver) = sync_channel(1);
        let producer = std::thread::spawn(move || {
            result_sender
                .send(producer_mux.append_journal_ingress(
                    &ingress,
                    "client_indeterminate_commit",
                    "indeterminate_commit_1",
                ))
                .unwrap();
        });
        entered_receiver.recv_timeout(Duration::from_secs(1)).unwrap();

        let started = Instant::now();
        let error = result_receiver
            .recv_timeout(
                JOURNAL_DURABLE_WAIT
                    .saturating_add(JOURNAL_COMMIT_RESULT_WAIT)
                    .saturating_add(Duration::from_secs(1)),
            )
            .expect("an admitted commit must return an explicit bounded result")
            .unwrap_err();
        assert!(error.to_string().contains("outcome is indeterminate"));
        assert!(
            started.elapsed()
                < JOURNAL_DURABLE_WAIT
                    .saturating_add(JOURNAL_COMMIT_RESULT_WAIT)
                    .saturating_add(Duration::from_secs(1)),
            "an admitted commit result must remain bounded"
        );
        let durable_epoch = mux.journal_event_epoch();
        release.send(()).unwrap();
        producer.join().unwrap();
        assert_ne!(
            mux.wait_for_journal_event(durable_epoch, Duration::from_secs(1)),
            durable_epoch,
            "an indeterminate admitted commit did not publish its durable result"
        );
        let records = mux.session_journal_after(0, 1024).unwrap().records;
        assert!(
            records.iter().any(|record| {
                record.correlation_id.as_deref() == Some("indeterminate_commit_1")
            }),
            "an indeterminate result must not claim that the admitted commit failed"
        );
        drop(mux);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn shutdown_returns_when_an_admitted_commit_stays_blocked() {
        let root = std::env::temp_dir().join(format!(
            "cmux-journal-admitted-shutdown-deadline-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        let mux = Mux::open_persistent(
            "journal-admitted-shutdown-deadline",
            crate::SurfaceOptions::default(),
            &root,
        )
        .unwrap();
        let (entered, entered_receiver) = sync_channel(1);
        let (release, release_receiver) = sync_channel(1);
        mux.install_journal_after_commit_admission_for_test(entered, release_receiver);
        let ingress = crate::agent_hook_journal_ingress(
            "codex",
            "SubagentStop",
            None,
            serde_json::json!({
                "session_id":"admitted-shutdown-root",
                "root_session_id":"admitted-shutdown-root",
                "parent_session_id":"admitted-shutdown-root",
                "child_agent_id":"admitted-shutdown-child",
                "message":"admitted-shutdown-marker",
            }),
        )
        .unwrap();
        let producer_mux = mux.clone();
        let (producer_result, producer_result_receiver) = sync_channel(1);
        let producer = std::thread::spawn(move || {
            producer_result
                .send(producer_mux.append_journal_ingress(
                    &ingress,
                    "client_admitted_shutdown",
                    "admitted_shutdown_1",
                ))
                .unwrap();
        });
        entered_receiver.recv_timeout(Duration::from_secs(1)).unwrap();

        let shutdown_mux = mux.clone();
        let (shutdown_completed, shutdown_completion) = sync_channel(1);
        let shutdown = std::thread::spawn(move || {
            shutdown_mux.shutdown();
            shutdown_completed.send(()).unwrap();
        });
        let returned = shutdown_completion.recv_timeout(Duration::from_secs(5));

        release.send(()).unwrap();
        let result = producer_result_receiver.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(
            result.is_ok() || result.unwrap_err().to_string().contains("indeterminate"),
            "the admitted producer returned an invalid final result"
        );
        producer.join().unwrap();
        shutdown.join().unwrap();
        assert!(returned.is_ok(), "shutdown waited without a limit for an admitted commit");
        drop(mux);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn shutdown_joins_terminal_readers_before_the_final_journal_fence() {
        let root = std::env::temp_dir().join(format!(
            "cmux-terminal-reader-shutdown-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        let mux = Mux::open_persistent(
            "terminal-reader-shutdown",
            crate::SurfaceOptions::default(),
            &root,
        )
        .unwrap();
        let surface = crate::Surface::spawn_for_test(
            1,
            crate::SurfaceOptions::default(),
            Arc::downgrade(&mux),
        )
        .unwrap();
        let terminal_id = Arc::new(public_id("term", 13, TerminalPublicId::parse));
        let (release_reader, reader_release) = sync_channel(1);
        let reader_mux = mux.clone();
        let reader = std::thread::spawn(move || {
            reader_release.recv().unwrap();
            reader_mux.journal_terminal_output(
                terminal_id,
                Arc::from("delayed-reader-generation"),
                b"persist after reader shutdown starts".to_vec(),
            );
        });
        surface.install_terminal_reader_for_test(reader);
        mux.insert_surface_runtime_for_test(surface);

        let shutdown_mux = mux.clone();
        let (completed, completion) = sync_channel(1);
        let shutdown = std::thread::spawn(move || {
            shutdown_mux.shutdown();
            completed.send(()).unwrap();
        });
        assert!(
            completion.recv_timeout(Duration::from_millis(100)).is_err(),
            "shutdown returned before the terminal reader stopped"
        );
        release_reader.send(()).unwrap();
        completion.recv_timeout(Duration::from_secs(5)).unwrap();
        shutdown.join().unwrap();

        let records = mux.session_journal_after(0, 1024).unwrap().records;
        let output = records
            .iter()
            .find(|record| record.kind == "terminal.output")
            .expect("shutdown fenced delayed terminal reader output");
        assert_eq!(
            output.terminal_output.as_deref(),
            Some(b"persist after reader shutdown starts".as_slice())
        );
        drop(mux);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn reader_timeout_preserves_the_active_update_before_closing_capture() {
        let mux = Mux::new("active-terminal-journal-update", crate::SurfaceOptions::default());
        let surface = crate::Surface::spawn_for_test(
            1,
            crate::SurfaceOptions::default(),
            Arc::downgrade(&mux),
        )
        .unwrap();
        let reader_surface = surface.clone();
        let (active, active_receiver) = sync_channel(1);
        let (release, release_receiver) = sync_channel(1);
        let reader = std::thread::spawn(move || {
            let mut update = reader_surface
                .begin_terminal_journal_update_for_test()
                .expect("journal capture must be open");
            assert!(update.activate(), "active update reservation was revoked before mutation");
            active.send(()).unwrap();
            release_receiver.recv().unwrap();
            drop(update);
        });
        surface.install_terminal_reader_for_test(reader);
        active_receiver.recv_timeout(Duration::from_secs(1)).unwrap();

        let finishing_surface = surface.clone();
        let (finished, finished_receiver) = sync_channel(1);
        let finisher = std::thread::spawn(move || {
            let gap = finishing_surface
                .finish_terminal_reader(Instant::now() + Duration::from_millis(10));
            finished.send(gap).unwrap();
        });
        assert!(
            finished_receiver.recv_timeout(Duration::from_millis(100)).is_err(),
            "shutdown discarded an active terminal update at its reader deadline"
        );
        release.send(()).unwrap();
        assert!(
            finished_receiver.recv_timeout(Duration::from_secs(1)).unwrap().is_none(),
            "a completed active update must not create an output gap"
        );
        assert!(
            surface.begin_terminal_journal_update_for_test().is_none(),
            "a late terminal update started after the shutdown capture fence"
        );
        finisher.join().unwrap();
    }

    #[test]
    fn reader_timeout_revokes_a_pre_parse_reservation() {
        let mux = Mux::new("reserved-terminal-journal-update", crate::SurfaceOptions::default());
        let surface = crate::Surface::spawn_for_test(
            1,
            crate::SurfaceOptions::default(),
            Arc::downgrade(&mux),
        )
        .unwrap();
        let mut reservation =
            surface.begin_terminal_journal_update_for_test().expect("journal capture must be open");
        let finishing_surface = surface.clone();
        let (finished, finished_receiver) = sync_channel(1);
        let finisher = std::thread::spawn(move || {
            let _ = finishing_surface
                .finish_terminal_reader(Instant::now() + Duration::from_millis(10));
            finished.send(()).unwrap();
        });

        finished_receiver.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(
            !reservation.activate(),
            "a blocked read reservation became active after the shutdown fence"
        );
        drop(reservation);
        finisher.join().unwrap();
    }

    #[test]
    fn shutdown_uses_one_terminal_reader_deadline_for_all_surfaces() {
        let mux = Mux::new("shared-terminal-reader-deadline", crate::SurfaceOptions::default());
        let mut releases = Vec::new();
        for id in 1..=4 {
            let surface = crate::Surface::spawn_for_test(
                id,
                crate::SurfaceOptions::default(),
                Arc::downgrade(&mux),
            )
            .unwrap();
            let (release, release_receiver) = sync_channel(1);
            let reader = std::thread::spawn(move || release_receiver.recv().unwrap());
            surface.install_terminal_reader_for_test(reader);
            mux.insert_surface_runtime_for_test(surface);
            releases.push(release);
        }

        let started = Instant::now();
        mux.shutdown();

        assert!(
            started.elapsed() < Duration::from_secs(3),
            "terminal reader shutdown applied its deadline once per surface"
        );
        for release in releases {
            release.send(()).unwrap();
        }
    }

    #[cfg(unix)]
    #[test]
    fn shutdown_is_bounded_when_a_descendant_keeps_the_pty_open() {
        use std::os::unix::fs::OpenOptionsExt as _;

        let root = std::env::temp_dir().join(format!(
            "cmux-terminal-descendant-shutdown-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        let descendant_pid_path = root.join("descendant.pid");
        let release_gate_path = root.join("descendant.release");
        let release_ready_path = root.join("descendant.release-ready");
        let release_ready_signal_path = root.join("descendant.release-signal");
        let mux = Mux::open_persistent(
            "terminal-descendant-shutdown",
            crate::SurfaceOptions::default(),
            &root,
        )
        .unwrap();
        let release_gate_path_c = std::ffi::CString::new(std::os::unix::ffi::OsStrExt::as_bytes(
            release_gate_path.as_os_str(),
        ))
        .unwrap();
        assert_eq!(
            unsafe { libc::mkfifo(release_gate_path_c.as_ptr(), 0o600) },
            0,
            "failed to create descendant release gate: {}",
            io::Error::last_os_error()
        );
        let release_gate_reader = std::fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NONBLOCK)
            .open(&release_gate_path)
            .unwrap();
        let mut release_gate =
            std::fs::OpenOptions::new().write(true).open(&release_gate_path).unwrap();
        let release_ready_signal_path_c = std::ffi::CString::new(
            std::os::unix::ffi::OsStrExt::as_bytes(release_ready_signal_path.as_os_str()),
        )
        .unwrap();
        assert_eq!(
            unsafe { libc::mkfifo(release_ready_signal_path_c.as_ptr(), 0o600) },
            0,
            "failed to create descendant readiness signal: {}",
            io::Error::last_os_error()
        );
        let release_ready_signal_reader = std::fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NONBLOCK)
            .open(&release_ready_signal_path)
            .unwrap();
        let release_ready_signal_writer =
            std::fs::OpenOptions::new().write(true).open(&release_ready_signal_path).unwrap();
        let surface = crate::Surface::spawn(
            1,
            crate::SurfaceOptions {
                command: Some(vec![
                    "/bin/sh".into(),
                    "-c".into(),
                    "stty -echo; printf input-ready; read ready; /bin/sh -c 'exec 3<\"$1\" || exit 1; : > \"$2\" || exit 1; printf \"\\n\" > \"$3\" || exit 1; read release <&3' cmux-descendant \"$2\" \"$3\" \"$4\" & echo $! > \"$1\"; read ready_signal < \"$4\" || exit 1; printf detached-ready; exit 0".into(),
                    "cmux-shutdown-test".into(),
                    descendant_pid_path.to_string_lossy().into_owned(),
                    release_gate_path.to_string_lossy().into_owned(),
                    release_ready_path.to_string_lossy().into_owned(),
                    release_ready_signal_path.to_string_lossy().into_owned(),
                ]),
                ..crate::SurfaceOptions::default()
            },
            Arc::downgrade(&mux),
        )
        .unwrap();
        mux.insert_surface_runtime_for_test(surface.clone());

        let ready_deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let observed = surface.terminal_stream_revision().unwrap();
            if surface
                .with_terminal(|term| term.viewport_text().unwrap().contains("input-ready"))
                .unwrap()
            {
                break;
            }
            assert!(
                surface
                    .wait_for_terminal_stream_change(observed, Some(ready_deadline))
                    .unwrap()
                    .is_some(),
                "descendant fixture did not become ready"
            );
        }
        surface.write_bytes(b"ready\n").unwrap();
        loop {
            let observed = surface.terminal_stream_revision().unwrap();
            if surface
                .with_terminal(|term| term.viewport_text().unwrap().contains("detached-ready"))
                .unwrap()
            {
                break;
            }
            assert!(
                surface
                    .wait_for_terminal_stream_change(observed, Some(ready_deadline))
                    .unwrap()
                    .is_some(),
                "descendant fixture did not publish its pid"
            );
        }
        assert!(
            !std::fs::read_to_string(&descendant_pid_path).unwrap().trim().is_empty(),
            "descendant fixture did not publish its pid"
        );
        assert!(release_ready_path.exists(), "descendant did not open the release gate");

        let started = Instant::now();
        mux.shutdown();
        assert!(
            started.elapsed() < Duration::from_secs(3),
            "shutdown waited without a bound for a descendant-held PTY"
        );

        io::Write::write_all(&mut release_gate, b"release\n").unwrap();
        drop(release_gate);
        drop(release_gate_reader);
        drop(release_ready_signal_writer);
        drop(release_ready_signal_reader);
        assert!(
            surface.wait_for_terminal_reader_for_test(Instant::now() + Duration::from_secs(5)),
            "terminal reader did not finish after the descendant release"
        );
        assert!(surface.is_dead(), "terminal reader did not stop after descendant cleanup");
        drop(surface);
        drop(mux);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn terminal_output_survives_a_short_nonretryable_writer_failure() {
        let root = std::env::temp_dir().join(format!(
            "cmux-terminal-journal-writer-retry-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        let mux = Mux::open_persistent(
            "terminal-journal-writer-retry",
            crate::SurfaceOptions::default(),
            &root,
        )
        .unwrap();
        let database_path = std::fs::read_dir(&root)
            .unwrap()
            .filter_map(Result::ok)
            .map(|entry| entry.path().join("workspace-registry.sqlite3"))
            .find(|path| path.is_file())
            .expect("persistent journal database");
        let injector = rusqlite::Connection::open(database_path).unwrap();
        injector
            .execute_batch(
                "CREATE TRIGGER reject_test_terminal_output
                 BEFORE INSERT ON session_journal
                 WHEN NEW.kind = 'terminal.output'
                 BEGIN
                   SELECT RAISE(ABORT, 'injected terminal journal failure');
                 END;",
            )
            .unwrap();

        let (failure_observed, failure_observed_receiver) = sync_channel(1);
        let (retry, retry_receiver) = sync_channel(1);
        mux.install_journal_nonretryable_failure_hook_for_test(failure_observed, retry_receiver);
        let terminal_id = Arc::new(public_id("term", 11, TerminalPublicId::parse));
        mux.journal_terminal_output(
            terminal_id.clone(),
            Arc::from("writer-retry-generation"),
            b"must survive retry".to_vec(),
        );
        failure_observed_receiver.recv_timeout(Duration::from_secs(5)).unwrap();
        injector.execute_batch("DROP TRIGGER reject_test_terminal_output;").unwrap();
        retry.send(()).unwrap();
        mux.flush_terminal_journal().unwrap();

        let records = mux.session_journal_after(0, 1024).unwrap().records;
        let output = records
            .iter()
            .find(|record| record.kind == "terminal.output")
            .expect("terminal output retained across writer recovery");
        assert_eq!(output.terminal_output.as_deref(), Some(b"must survive retry".as_slice()));
        assert!(
            output.subjects.iter().any(|subject| {
                subject.kind == "terminal" && subject.id == terminal_id.as_str()
            })
        );

        drop(injector);
        drop(mux);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn permanent_terminal_writer_failure_releases_the_final_barrier() {
        let root = std::env::temp_dir().join(format!(
            "cmux-terminal-journal-writer-terminal-failure-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        let mux = Mux::open_persistent(
            "terminal-journal-writer-terminal-failure",
            crate::SurfaceOptions::default(),
            &root,
        )
        .unwrap();
        let database_path = std::fs::read_dir(&root)
            .unwrap()
            .filter_map(Result::ok)
            .map(|entry| entry.path().join("workspace-registry.sqlite3"))
            .find(|path| path.is_file())
            .expect("persistent journal database");
        let injector = rusqlite::Connection::open(database_path).unwrap();
        injector
            .execute_batch(
                "CREATE TRIGGER reject_permanent_test_terminal_output
                 BEFORE INSERT ON session_journal
                 WHEN NEW.kind = 'terminal.output'
                 BEGIN
                   SELECT RAISE(ABORT, 'injected permanent terminal journal failure');
                 END;",
            )
            .unwrap();
        mux.journal_terminal_output(
            Arc::new(public_id("term", 14, TerminalPublicId::parse)),
            Arc::from("permanent-writer-failure-generation"),
            b"cannot commit".to_vec(),
        );

        let started = Instant::now();
        let error = mux.flush_terminal_journal().unwrap_err();

        assert!(started.elapsed() < Duration::from_secs(3));
        assert!(error.to_string().contains("injected permanent terminal journal failure"));
        assert!(
            mux.daemon_shutdown_requested(),
            "a permanent output gap must stop the daemon instead of continuing silently"
        );
        assert!(
            mux.try_journal_terminal_output(
                Arc::new(public_id("term", 14, TerminalPublicId::parse)),
                Arc::from("permanent-writer-failure-generation"),
                42,
                b"must not be accepted".to_vec(),
            )
            .is_err(),
            "later output must observe the terminal writer failure"
        );
        assert!(
            mux.flush_terminal_journal().unwrap_err().to_string().contains("failed permanently"),
            "later barriers must observe the writer terminal state"
        );
        drop(injector);
        drop(mux);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn terminal_output_is_chunked_before_entering_the_bounded_queue() {
        let (sender, receivers) = JournalIngressSender::new(true);
        let receivers = receivers.unwrap();
        let terminal_id = Arc::new(public_id("term", 9, TerminalPublicId::parse));
        let bytes = (0..TERMINAL_OUTPUT_INGRESS_BYTES * 2 + 17)
            .map(|index| u8::try_from(index % 251).unwrap())
            .collect::<Vec<_>>();
        sender.send(JournalIngressEvent::TerminalOutput {
            terminal_id,
            generation: Arc::from("chunking-generation"),
            occurred_at_ms: 42,
            bytes: bytes.clone(),
        });

        let mut rebuilt = Vec::new();
        for expected_len in [TERMINAL_OUTPUT_INGRESS_BYTES, TERMINAL_OUTPUT_INGRESS_BYTES, 17] {
            let queued = receivers.terminal.recv().unwrap();
            let JournalIngressEvent::TerminalOutput { bytes, occurred_at_ms, .. } = queued.event
            else {
                panic!("expected terminal output")
            };
            assert_eq!(bytes.len(), expected_len);
            assert!(
                bytes.capacity() <= TERMINAL_OUTPUT_INGRESS_BYTES,
                "one small queued chunk retained the complete ingress allocation"
            );
            assert_eq!(occurred_at_ms, 42);
            rebuilt.extend_from_slice(&bytes);
        }
        assert_eq!(rebuilt, bytes);
        assert!(receivers.terminal.try_recv().is_err());
    }

    #[test]
    fn closed_ingress_rejects_late_terminal_and_durable_events() {
        let (sender, _receivers) = JournalIngressSender::new(true);
        sender.close_and_join().unwrap();
        let terminal_id = Arc::new(public_id("term", 15, TerminalPublicId::parse));

        assert!(matches!(
            sender.try_send(JournalIngressEvent::TerminalOutput {
                terminal_id,
                generation: Arc::from("closed-ingress-generation"),
                occurred_at_ms: 44,
                bytes: b"too late".to_vec(),
            }),
            Err(JournalIngressTrySendError::Failed { error, .. })
                if error.contains("admission is closed")
        ));
        assert!(
            sender
                .send_durable(JournalIngressEvent::TerminalBarrier)
                .unwrap_err()
                .to_string()
                .contains("admission is closed")
        );
    }

    #[test]
    fn shutdown_closes_admission_while_a_terminal_producer_waits_for_space() {
        let (sender, receivers) = JournalIngressSender::new(true);
        let receivers = receivers.unwrap();
        let sender = Arc::new(sender);
        let terminal_id = Arc::new(public_id("term", 16, TerminalPublicId::parse));
        for index in 0..JOURNAL_TERMINAL_QUEUE_CAPACITY {
            sender.send(JournalIngressEvent::TerminalResize {
                terminal_id: terminal_id.clone(),
                generation: Arc::from("blocked-admission-generation"),
                occurred_at_ms: u64::try_from(index).unwrap(),
                cols: 80,
                rows: 24,
                cell_width: 8,
                cell_height: 16,
            });
        }
        let (queue_full, queue_full_receiver) = sync_channel(1);
        sender.install_enqueue_full_notifier_for_test(queue_full);
        let blocked_sender = sender.clone();
        let blocked_terminal = terminal_id;
        let blocked = std::thread::spawn(move || {
            blocked_sender.send(JournalIngressEvent::TerminalResize {
                terminal_id: blocked_terminal,
                generation: Arc::from("blocked-admission-generation"),
                occurred_at_ms: u64::MAX,
                cols: 81,
                rows: 25,
                cell_width: 8,
                cell_height: 16,
            });
        });
        queue_full_receiver.recv_timeout(Duration::from_secs(1)).unwrap();

        let shutdown_sender = sender;
        let (shutdown_completion, shutdown_completed) = sync_channel(1);
        let shutdown = std::thread::spawn(move || {
            shutdown_completion
                .send(
                    shutdown_sender
                        .close_and_join_until(Instant::now() + Duration::from_millis(100)),
                )
                .unwrap();
        });
        let returned = shutdown_completed.recv_timeout(Duration::from_secs(1));
        assert!(
            returned.is_ok(),
            "shutdown waited on a terminal producer that held the admission lock"
        );
        returned.unwrap().unwrap();
        blocked.join().unwrap();
        shutdown.join().unwrap();

        let queued = (0..JOURNAL_TERMINAL_QUEUE_CAPACITY)
            .map(|_| receivers.terminal.recv().unwrap())
            .collect::<Vec<_>>();
        assert!(
            queued.iter().all(|queued| matches!(
                &queued.event,
                JournalIngressEvent::TerminalResize { occurred_at_ms, .. }
                    if *occurred_at_ms != u64::MAX
            )),
            "the event waiting outside the admission fence must not enter after close"
        );
        assert!(receivers.terminal.try_recv().is_err());
    }

    #[test]
    fn writer_shutdown_deadline_detaches_a_stalled_writer() {
        let (sender, _receivers) = JournalIngressSender::new(true);
        let (entered, entered_receiver) = sync_channel(1);
        let (release, release_receiver) = sync_channel(1);
        let (completed, completion_receiver) = sync_channel(1);
        let writer = JournalWriter::spawn("stalled-journal-writer-test", move || {
            entered.send(()).unwrap();
            release_receiver.recv().unwrap();
            completed.send(()).unwrap();
        })
        .unwrap();
        *sender.writer.lock().unwrap() = JournalWriterOwner::Running(writer);
        entered_receiver.recv_timeout(Duration::from_secs(1)).unwrap();

        let deadline = Instant::now() + Duration::from_millis(100);
        let started = Instant::now();
        let error = sender.close_and_join_until(deadline).unwrap_err();

        assert!(error.to_string().contains("did not stop within"));
        assert!(started.elapsed() < Duration::from_secs(1));
        release.send(()).unwrap();
        completion_receiver.recv_timeout(Duration::from_secs(1)).unwrap();
    }

    #[test]
    fn concurrent_writer_close_waits_for_the_shared_join_result() {
        let (sender, _receivers) = JournalIngressSender::new(true);
        let sender = Arc::new(sender);
        let (entered, entered_receiver) = sync_channel(1);
        let (release, release_receiver) = sync_channel(1);
        sender
            .spawn_writer("shared-journal-close-test", move || {
                entered.send(()).unwrap();
                release_receiver.recv().unwrap();
            })
            .unwrap();
        entered_receiver.recv_timeout(Duration::from_secs(1)).unwrap();

        let start = Arc::new(std::sync::Barrier::new(3));
        let (completed, completion_receiver) = sync_channel(2);
        let closers = (0..2)
            .map(|_| {
                let sender = sender.clone();
                let start = start.clone();
                let completed = completed.clone();
                std::thread::spawn(move || {
                    start.wait();
                    completed.send(sender.close_and_join()).unwrap();
                })
            })
            .collect::<Vec<_>>();
        start.wait();

        assert!(
            completion_receiver.recv_timeout(Duration::from_millis(100)).is_err(),
            "a concurrent closer returned before the journal writer stopped"
        );
        release.send(()).unwrap();
        for _ in 0..2 {
            completion_receiver.recv_timeout(Duration::from_secs(1)).unwrap().unwrap();
        }
        for closer in closers {
            closer.join().unwrap();
        }
    }

    #[test]
    fn duplicate_writer_is_rejected_before_its_thread_starts() {
        let (sender, _receivers) = JournalIngressSender::new(true);
        let (release, release_receiver) = sync_channel(1);
        sender
            .spawn_writer("owned-journal-writer-test", move || {
                release_receiver.recv().unwrap();
            })
            .unwrap();

        let duplicate_started = Arc::new(AtomicBool::new(false));
        let duplicate_observer = duplicate_started.clone();
        let error = sender
            .spawn_writer("duplicate-journal-writer-test", move || {
                duplicate_observer.store(true, Ordering::Release);
            })
            .unwrap_err();

        assert!(error.to_string().contains("already installed"));
        assert!(
            !duplicate_started.load(Ordering::Acquire),
            "a rejected writer must not start and detach"
        );
        release.send(()).unwrap();
        sender.close_and_join().unwrap();
    }

    #[test]
    fn mux_drop_joins_its_journal_writer() {
        let mux = Mux::new("journal-writer-drop-owner", crate::SurfaceOptions::default());
        let weak = Arc::downgrade(&mux);
        let writer_finished = Arc::new(AtomicBool::new(false));
        let writer_observer = writer_finished.clone();
        mux.spawn_journal_writer("mux-drop-journal-writer-test", move || {
            while weak.upgrade().is_some() {
                std::thread::yield_now();
            }
            writer_observer.store(true, Ordering::Release);
        })
        .unwrap();

        drop(mux);

        assert!(
            writer_finished.load(Ordering::Acquire),
            "Mux::drop returned before its journal writer stopped"
        );
    }

    #[test]
    fn writer_that_drops_the_last_mux_owner_hands_off_its_self_join() {
        let mux = Mux::new("journal-writer-self-drop", crate::SurfaceOptions::default());
        let writer_mux = mux.clone();
        let (release, release_receiver) = sync_channel(1);
        let (completed, completion_receiver) = sync_channel(1);
        mux.spawn_journal_writer("mux-self-drop-journal-writer-test", move || {
            release_receiver.recv().unwrap();
            drop(writer_mux);
            completed.send(()).unwrap();
        })
        .unwrap();

        drop(mux);
        release.send(()).unwrap();

        completion_receiver
            .recv_timeout(Duration::from_millis(500))
            .expect("journal writer waited for its own completion during Mux::drop");
    }

    #[test]
    fn saturated_durable_ingress_does_not_block_terminal_output() {
        let (sender, receivers) = JournalIngressSender::new(true);
        let receivers = receivers.unwrap();
        let durable = sender.durable_sender.as_ref().unwrap();
        for _ in 0..JOURNAL_DURABLE_QUEUE_CAPACITY {
            durable
                .try_send(QueuedJournalEvent {
                    event: JournalIngressEvent::TerminalBarrier,
                    completion: None,
                })
                .unwrap();
        }

        let terminal_id = Arc::new(public_id("term", 12, TerminalPublicId::parse));
        let enqueue = std::thread::spawn(move || {
            sender.send(JournalIngressEvent::TerminalOutput {
                terminal_id,
                generation: Arc::from("isolated-terminal-lane"),
                occurred_at_ms: 43,
                bytes: b"still-responsive".to_vec(),
            });
        });
        let queued = receivers
            .terminal
            .recv_timeout(Duration::from_millis(100))
            .expect("terminal output must use an ingress lane isolated from durable producers");
        assert!(matches!(queued.event, JournalIngressEvent::TerminalOutput { .. }));
        enqueue.join().unwrap();
    }

    #[test]
    fn durable_batches_are_bounded_by_resident_payload_bytes() {
        let (sender, receivers) = JournalIngressSender::new(true);
        let receivers = receivers.unwrap();
        let ingress = crate::JournalIngress {
            producer_id: "batch_probe".into(),
            manifest_version: 1,
            kind: "batch.probe".into(),
            schema_version: 1,
            occurred_at_ms: None,
            subjects: Vec::new(),
            sensitivity: None,
            payload: serde_json::json!({"blob":"x".repeat(1024 * 1024)}),
            causation_id: None,
            correlation_id: None,
        };
        let validated = crate::journal_kernel::ValidatedJournalIngress {
            class: crate::JournalClass::Observation,
            replay: crate::JournalReplayPolicy::Advisory,
            sensitivity: crate::JournalSensitivity::Metadata,
        };
        for index in 0..9 {
            sender
                .durable_sender
                .as_ref()
                .unwrap()
                .try_send(QueuedJournalEvent {
                    event: JournalIngressEvent::Producer {
                        ingress: ingress.clone(),
                        validated,
                        origin: "batch_probe".into(),
                        idempotency_key: format!("batch_probe_{index}"),
                    },
                    completion: None,
                })
                .unwrap();
        }

        let batch = receive_batch(&receivers).unwrap();
        assert_eq!(batch.len(), 8);
        assert_eq!(receivers.durable.try_iter().count(), 1);
    }

    #[test]
    fn durable_receipt_makes_exact_subject_index_immediately_readable() {
        let root = std::env::temp_dir().join(format!(
            "cmux-journal-subject-receipt-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        let mux = Mux::open_persistent(
            "journal-subject-receipt",
            crate::SurfaceOptions::default(),
            &root,
        )
        .unwrap();
        for index in 0..32 {
            let ingress = crate::agent_hook_journal_ingress(
                "codex",
                "SubagentStop",
                None,
                serde_json::json!({
                    "session_id":"receipt-root",
                    "root_session_id":"receipt-root",
                    "parent_session_id":"receipt-root",
                    "child_agent_id":format!("receipt-child-{index}"),
                    "message":format!("receipt-marker-{index}"),
                }),
            )
            .unwrap();
            let subject = ingress
                .subjects
                .iter()
                .find(|subject| subject.kind == "agent_tree")
                .cloned()
                .unwrap();
            let commit = mux
                .append_journal_ingress(
                    &ingress,
                    "client_subject_receipt",
                    &format!("subject_receipt_{index}"),
                )
                .unwrap();
            let reader = mux.session_journal_reader().unwrap().unwrap();
            let page =
                reader.after_subjects(commit.sequence.saturating_sub(1), 1, &[subject]).unwrap();
            assert_eq!(
                page.records.first().map(|record| record.sequence),
                Some(commit.sequence),
                "durable receipt {index} returned before its subject index was readable"
            );
        }
        drop(mux);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    #[ignore = "manual release-mode end-to-end journal ingress probe"]
    fn terminal_output_ingress_throughput_probe() {
        const CHUNKS: usize = 1_024;
        let root = std::env::temp_dir().join(format!(
            "cmux-journal-ingress-throughput-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        let mux = Mux::open_persistent(
            "journal-ingress-throughput",
            crate::SurfaceOptions::default(),
            &root,
        )
        .unwrap();
        let terminal_id = Arc::new(public_id("term", 10, TerminalPublicId::parse));
        let generation: Arc<str> = Arc::from("ingress-throughput-generation");
        let mut chunk = vec![b'x'; TERMINAL_OUTPUT_INGRESS_BYTES];
        chunk[TERMINAL_OUTPUT_INGRESS_BYTES - 17..].copy_from_slice(b"terminal-output\r\n");
        let started = Instant::now();
        for _ in 0..CHUNKS {
            mux.journal_terminal_output(terminal_id.clone(), generation.clone(), chunk.clone());
        }
        mux.flush_terminal_journal().unwrap();
        let elapsed = started.elapsed();
        let byte_count = CHUNKS * TERMINAL_OUTPUT_INGRESS_BYTES;
        let mebibytes_per_second = byte_count as f64 / (1024.0 * 1024.0) / elapsed.as_secs_f64();
        eprintln!(
            "terminal journal ingress: {} MiB in {elapsed:?}, {mebibytes_per_second:.1} MiB/s",
            byte_count / (1024 * 1024)
        );
        assert!(
            mebibytes_per_second >= 20.0,
            "terminal journal ingress regressed: {mebibytes_per_second:.1} MiB/s"
        );

        let mut sequence = 0;
        let mut stored_bytes = 0;
        loop {
            let page = mux.session_journal_after(sequence, 1_024).unwrap();
            for record in page.records {
                sequence = record.sequence;
                stored_bytes += record.terminal_output.as_ref().map_or(0, |bytes| bytes.len());
            }
            if sequence >= page.head_sequence {
                break;
            }
        }
        assert_eq!(stored_bytes, byte_count);
        drop(mux);
        std::fs::remove_dir_all(root).unwrap();
    }
}
