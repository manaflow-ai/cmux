//! Frontend journal delivery: the coalescing queue of pending frontend journal
//! events and the worker thread that writes them to the session.

use std::sync::{Arc, Condvar, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use cmux_tui_core::FrontendJournalEvent;

use crate::session::Session;

pub(super) struct PendingFrontendJournalEvent {
    pub(super) sequence: u64,
    retry_at: Instant,
    pub(super) session: Session,
    pub(super) event: Box<FrontendJournalEvent>,
}

#[repr(usize)]
#[derive(Clone, Copy)]
pub(super) enum FrontendJournalSlot {
    Focus = 0,
    Resize = 1,
    Viewport = 2,
}

impl FrontendJournalSlot {
    const COUNT: usize = 3;

    fn for_event(event: &FrontendJournalEvent) -> Self {
        match event {
            FrontendJournalEvent::Focus { .. } => Self::Focus,
            FrontendJournalEvent::Resize { .. } => Self::Resize,
            FrontendJournalEvent::Viewport { .. } => Self::Viewport,
        }
    }

    pub(super) const fn index(self) -> usize {
        self as usize
    }
}

impl PendingFrontendJournalEvent {
    fn slot(&self) -> FrontendJournalSlot {
        FrontendJournalSlot::for_event(self.event.as_ref())
    }
}

#[derive(Default)]
pub(super) struct FrontendJournalQueueState {
    pub(super) pending: [Option<PendingFrontendJournalEvent>; FrontendJournalSlot::COUNT],
    pub(super) next_sequence: u64,
    stopping: bool,
}

#[derive(Default)]
pub(super) struct FrontendJournalQueue {
    pub(super) state: Mutex<FrontendJournalQueueState>,
    pub(super) changed: Condvar,
}

impl FrontendJournalQueue {
    pub(super) fn push(&self, session: Session, event: FrontendJournalEvent) {
        let slot = FrontendJournalSlot::for_event(&event).index();
        let mut state = self.state.lock().unwrap();
        if state.stopping {
            return;
        }
        state.next_sequence = state.next_sequence.wrapping_add(1).max(1);
        let sequence = state.next_sequence;
        state.pending[slot] = Some(PendingFrontendJournalEvent {
            sequence,
            retry_at: Instant::now(),
            session,
            event: Box::new(event),
        });
        drop(state);
        self.changed.notify_one();
    }

    pub(super) fn take(&self) -> Option<PendingFrontendJournalEvent> {
        let mut state = self.state.lock().unwrap();
        loop {
            if state.stopping {
                return None;
            }
            let now = Instant::now();
            if let Some(slot) = state
                .pending
                .iter()
                .enumerate()
                .filter_map(|(slot, pending)| {
                    pending
                        .as_ref()
                        .filter(|pending| pending.retry_at <= now)
                        .map(|pending| (slot, pending.sequence))
                })
                .min_by_key(|(_, sequence)| *sequence)
                .map(|(slot, _)| slot)
            {
                return state.pending[slot].take();
            }
            if let Some(retry_at) =
                state.pending.iter().flatten().map(|pending| pending.retry_at).min()
            {
                let wait = retry_at.saturating_duration_since(now);
                (state, _) = self.changed.wait_timeout(state, wait).unwrap();
            } else {
                state = self.changed.wait(state).unwrap();
            }
        }
    }

    pub(super) fn retry(&self, mut pending: PendingFrontendJournalEvent) {
        let slot = pending.slot();
        let mut state = self.state.lock().unwrap();
        if state.stopping || state.pending[slot.index()].is_some() {
            return;
        }
        pending.retry_at = Instant::now() + Duration::from_millis(100);
        state.pending[slot.index()] = Some(pending);
        drop(state);
        self.changed.notify_one();
    }

    pub(super) fn stop(&self) {
        self.state.lock().unwrap().stopping = true;
        self.changed.notify_one();
    }

    #[cfg(test)]
    pub(super) fn pending_count(&self) -> usize {
        self.state.lock().unwrap().pending.iter().flatten().count()
    }
}

pub(super) struct FrontendJournalWorker {
    pub(super) queue: Option<Arc<FrontendJournalQueue>>,
    pub(super) worker: Option<JoinHandle<()>>,
}

impl FrontendJournalWorker {
    pub(super) fn spawn() -> anyhow::Result<Self> {
        let queue = Arc::new(FrontendJournalQueue::default());
        let worker_queue = queue.clone();
        let worker = std::thread::Builder::new()
            .name("frontend-session-journal".into())
            .spawn(move || run_frontend_journal_worker(&worker_queue))?;
        Ok(Self { queue: Some(queue), worker: Some(worker) })
    }

    #[cfg(test)]
    pub(super) const fn disabled() -> Self {
        Self { queue: None, worker: None }
    }

    pub(super) fn send(&self, session: Session, event: FrontendJournalEvent) {
        if let Some(queue) = &self.queue {
            queue.push(session, event);
        }
    }

    pub(super) fn stop_and_join(&mut self) {
        if let Some(queue) = self.queue.take() {
            queue.stop();
        }
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

impl Drop for FrontendJournalWorker {
    fn drop(&mut self) {
        self.stop_and_join();
    }
}

pub(super) fn run_frontend_journal_worker(queue: &FrontendJournalQueue) {
    while let Some(pending) = queue.take() {
        if pending.session.journal_frontend_event(pending.event.as_ref().clone()).is_err() {
            queue.retry(pending);
        }
    }
}
