use std::collections::VecDeque;
use std::mem::size_of;
use std::sync::mpsc::{Receiver, SyncSender, TryRecvError, TrySendError, sync_channel};
use std::sync::{Arc, Weak};
use std::time::Duration;

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
const TERMINAL_OUTPUT_INGRESS_BYTES: usize = 64 * 1024;
const TERMINAL_OUTPUT_BATCH_BYTES: usize = 256 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FrontendFocusTarget {
    Pane,
    MachineRail,
    WorkspaceRail,
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
    Durable(SyncSender<Result<(), String>>),
    Producer(SyncSender<Result<crate::JournalAppendCommit, String>>),
}

pub(crate) struct QueuedJournalEvent {
    event: JournalIngressEvent,
    completion: Option<JournalIngressCompletion>,
}

impl QueuedJournalEvent {
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
}

pub(crate) struct JournalIngressReceivers {
    terminal: Receiver<QueuedJournalEvent>,
    durable: Receiver<QueuedJournalEvent>,
    wake: Receiver<()>,
}

impl JournalIngressSender {
    pub(crate) fn new(enabled: bool) -> (Self, Option<JournalIngressReceivers>) {
        if !enabled {
            return (Self { terminal_sender: None, durable_sender: None, wake_sender: None }, None);
        }
        let (terminal_sender, terminal) = sync_channel(JOURNAL_TERMINAL_QUEUE_CAPACITY);
        let (durable_sender, durable) = sync_channel(JOURNAL_DURABLE_QUEUE_CAPACITY);
        let (wake_sender, wake) = sync_channel(1);
        (
            Self {
                terminal_sender: Some(terminal_sender),
                durable_sender: Some(durable_sender),
                wake_sender: Some(wake_sender),
            },
            Some(JournalIngressReceivers { terminal, durable, wake }),
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

    pub(crate) fn send_durable(&self, event: JournalIngressEvent) -> anyhow::Result<()> {
        let sender = if matches!(&event, JournalIngressEvent::TerminalBarrier) {
            &self.terminal_sender
        } else {
            &self.durable_sender
        };
        let Some(sender) = sender else { return Ok(()) };
        let (completion, result) = sync_channel(1);
        self.enqueue(
            sender,
            QueuedJournalEvent {
                event,
                completion: Some(JournalIngressCompletion::Durable(completion)),
            },
        )
        .map_err(|_| anyhow::anyhow!("session journal writer stopped"))?;
        result
            .recv()
            .map_err(|_| anyhow::anyhow!("session journal writer stopped"))?
            .map_err(anyhow::Error::msg)
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
        let Some(sender) = &self.durable_sender else {
            anyhow::bail!("session journal writer is unavailable")
        };
        let (completion, result) = sync_channel(1);
        self.enqueue(
            sender,
            QueuedJournalEvent {
                event: JournalIngressEvent::Producer {
                    ingress,
                    validated,
                    origin,
                    idempotency_key,
                },
                completion: Some(JournalIngressCompletion::Producer(completion)),
            },
        )
        .map_err(|_| anyhow::anyhow!("session journal writer stopped"))?;
        result
            .recv()
            .map_err(|_| anyhow::anyhow!("session journal writer stopped"))?
            .map_err(anyhow::Error::msg)
    }

    pub(crate) const fn enabled(&self) -> bool {
        self.terminal_sender.is_some()
    }

    fn enqueue(
        &self,
        sender: &SyncSender<QueuedJournalEvent>,
        event: QueuedJournalEvent,
    ) -> Result<(), ()> {
        sender.send(event).map_err(|_| ())?;
        if let Some(wake) = &self.wake_sender {
            match wake.try_send(()) {
                Ok(()) | Err(TrySendError::Full(())) => {}
                Err(TrySendError::Disconnected(())) => {}
            }
        }
        Ok(())
    }
}

pub(crate) fn start(
    mux: &Arc<Mux>,
    receivers: Option<JournalIngressReceivers>,
) -> anyhow::Result<()> {
    let Some(receivers) = receivers else { return Ok(()) };
    let weak = Arc::downgrade(mux);
    std::thread::Builder::new()
        .name("mux-session-journal-writer".into())
        .spawn(move || run(weak, receivers))?;
    Ok(())
}

fn run(mux: Weak<Mux>, receivers: JournalIngressReceivers) {
    loop {
        let Some(batch) = receive_batch(&receivers) else { return };
        let mut pending = VecDeque::from([batch]);
        while let Some(mut batch) = pending.pop_front() {
            let mut delay = Duration::from_millis(10);
            let mut reported_error = None;
            loop {
                let Some(mux) = mux.upgrade() else {
                    let error = "session journal stopped".to_string();
                    complete_batch_error(&batch, error.clone());
                    for pending_batch in pending {
                        complete_batch_error(&pending_batch, error.clone());
                    }
                    return;
                };
                let events = batch.iter().map(|queued| &queued.event).collect::<Vec<_>>();
                match mux.commit_session_journal_events(&events) {
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
                        if retryable_sqlite_error(&error)
                            || (batch.len() == 1 && batch[0].completion.is_none())
                        {
                            let epoch = mux.journal_event_epoch();
                            mux.wait_for_journal_event(epoch, delay);
                            delay = (delay * 2).min(Duration::from_secs(1));
                            continue;
                        }
                        if batch.len() > 1 {
                            let later = batch.split_off(batch.len() / 2);
                            pending.push_front(later);
                            pending.push_front(batch);
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
        drain_lane(&receivers.terminal, &mut batch, JOURNAL_TERMINAL_BATCH_CHUNKS, usize::MAX);
        drain_lane(
            &receivers.durable,
            &mut batch,
            JOURNAL_DURABLE_QUEUE_CAPACITY,
            JOURNAL_DURABLE_BATCH_BYTES,
        );
        if !batch.is_empty() {
            return Some(batch);
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
) {
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
            Some(JournalIngressCompletion::Durable(completion)) => {
                let _ = completion.send(Ok(()));
            }
            Some(JournalIngressCompletion::Producer(completion)) => {
                let result = commit
                    .ok_or_else(|| "session journal omitted a producer append receipt".into());
                let _ = completion.send(result);
            }
            None => {}
        }
    }
}

fn complete_batch_error(batch: &[QueuedJournalEvent], error: String) {
    for queued in batch {
        match &queued.completion {
            Some(JournalIngressCompletion::Durable(completion)) => {
                let _ = completion.send(Err(error.clone()));
            }
            Some(JournalIngressCompletion::Producer(completion)) => {
                let _ = completion.send(Err(error.clone()));
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
    fn terminal_output_survives_a_nonretryable_writer_failure() {
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

        let terminal_id = Arc::new(public_id("term", 11, TerminalPublicId::parse));
        mux.journal_terminal_output(
            terminal_id.clone(),
            Arc::from("writer-retry-generation"),
            b"must survive retry".to_vec(),
        );
        std::thread::sleep(Duration::from_millis(500));
        injector.execute_batch("DROP TRIGGER reject_test_terminal_output;").unwrap();
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
        let started = std::time::Instant::now();
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
