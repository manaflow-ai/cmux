use std::collections::VecDeque;
use std::sync::mpsc::{Receiver, SyncSender, TryRecvError, sync_channel};
use std::sync::{Arc, Weak};
use std::time::Duration;

use serde::{Deserialize, Serialize};

use crate::Mux;
use crate::resource::{
    ContentPublicId, PanePublicId, ScreenPublicId, TabPublicId, TerminalPublicId, WorkspacePublicId,
};

const JOURNAL_QUEUE_CAPACITY: usize = 1024;
const JOURNAL_DRAIN_LIMIT: usize = 1024;
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
        generation: String,
        cols: u16,
        rows: u16,
        cell_width: u16,
        cell_height: u16,
    },
    Viewport {
        event_id: String,
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
}

#[derive(Debug)]
pub(crate) enum JournalIngressEvent {
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
}

impl JournalIngressEvent {
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

pub(crate) struct QueuedJournalEvent {
    event: JournalIngressEvent,
    completion: Option<SyncSender<Result<(), String>>>,
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
    sender: Option<SyncSender<QueuedJournalEvent>>,
}

impl JournalIngressSender {
    pub(crate) fn new(enabled: bool) -> (Self, Option<Receiver<QueuedJournalEvent>>) {
        if !enabled {
            return (Self { sender: None }, None);
        }
        let (sender, receiver) = sync_channel(JOURNAL_QUEUE_CAPACITY);
        (Self { sender: Some(sender) }, Some(receiver))
    }

    pub(crate) fn send(&self, event: JournalIngressEvent) {
        let Some(sender) = &self.sender else { return };
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
                    if sender.send(QueuedJournalEvent { event, completion: None }).is_err() {
                        return;
                    }
                }
            }
            event => {
                let _ = sender.send(QueuedJournalEvent { event, completion: None });
            }
        }
    }

    pub(crate) fn send_durable(&self, event: JournalIngressEvent) -> anyhow::Result<()> {
        let Some(sender) = &self.sender else { return Ok(()) };
        let (completion, result) = sync_channel(1);
        sender
            .send(QueuedJournalEvent { event, completion: Some(completion) })
            .map_err(|_| anyhow::anyhow!("session journal writer stopped"))?;
        result
            .recv()
            .map_err(|_| anyhow::anyhow!("session journal writer stopped"))?
            .map_err(anyhow::Error::msg)
    }

    pub(crate) const fn enabled(&self) -> bool {
        self.sender.is_some()
    }
}

pub(crate) fn start(
    mux: &Arc<Mux>,
    receiver: Option<Receiver<QueuedJournalEvent>>,
) -> anyhow::Result<()> {
    let Some(receiver) = receiver else { return Ok(()) };
    let weak = Arc::downgrade(mux);
    std::thread::Builder::new()
        .name("mux-session-journal-writer".into())
        .spawn(move || run(weak, receiver))?;
    Ok(())
}

fn run(mux: Weak<Mux>, receiver: Receiver<QueuedJournalEvent>) {
    loop {
        let first = match receiver.recv() {
            Ok(event) => event,
            Err(_) => return,
        };
        let mut batch = Vec::with_capacity(JOURNAL_DRAIN_LIMIT.min(64));
        batch.push(first);
        while batch.len() < JOURNAL_DRAIN_LIMIT {
            let next = match receiver.try_recv() {
                Ok(event) => event,
                Err(TryRecvError::Empty | TryRecvError::Disconnected) => break,
            };
            let Some(last) = batch.last_mut() else { return };
            if let Some(next) = last.merge_output(next) {
                batch.push(next);
            }
        }
        let mut pending = VecDeque::from([batch]);
        while let Some(mut batch) = pending.pop_front() {
            let mut delay = Duration::from_millis(10);
            let mut reported_error = None;
            loop {
                let Some(mux) = mux.upgrade() else {
                    let result = Err("session journal stopped".into());
                    complete_batch(&batch, result.clone());
                    for pending_batch in pending {
                        complete_batch(&pending_batch, result.clone());
                    }
                    return;
                };
                let events = batch.iter().map(|queued| &queued.event).collect::<Vec<_>>();
                match mux.commit_session_journal_events(&events) {
                    Ok(()) => {
                        complete_batch(&batch, Ok(()));
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
                            complete_batch(&batch, Err(summary));
                        }
                        break;
                    }
                }
            }
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

fn complete_batch(batch: &[QueuedJournalEvent], result: Result<(), String>) {
    for queued in batch {
        if let Some(completion) = &queued.completion {
            let _ = completion.send(result.clone());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::resource::{PanePublicId, ScreenPublicId, TabPublicId, WorkspacePublicId};

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
        let event = FrontendJournalEvent::Focus {
            event_id: "event_frontend_focus_test".into(),
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
        let event = |cols| FrontendJournalEvent::Resize {
            event_id: "event_frontend_resize_conflict".into(),
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
        mux.journal_local_frontend_event(FrontendJournalEvent::Resize {
            event_id: "event_writer_retry_barrier".into(),
            generation: "writer-retry-frontend".into(),
            cols: 80,
            rows: 24,
            cell_width: 8,
            cell_height: 16,
        })
        .unwrap();

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
        let (sender, receiver) = JournalIngressSender::new(true);
        let receiver = receiver.unwrap();
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
            let queued = receiver.recv().unwrap();
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
        assert!(receiver.try_recv().is_err());
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
        mux.journal_local_frontend_event(FrontendJournalEvent::Resize {
            event_id: "event_ingress_throughput_barrier".into(),
            generation: "ingress-throughput-frontend".into(),
            cols: 80,
            rows: 24,
            cell_width: 8,
            cell_height: 16,
        })
        .unwrap();
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
