//! Mux ingress: forwarding mux events into the app channel, starting the
//! ordered session, and the coalescing mux title and PTY failure ingress.

use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use cmux_tui_core::{MuxEvent, SurfaceId};
use crossbeam_channel::Sender as SyncSender;

use crate::app::PTY_FAILURE_CAPACITY;
use crate::app::events::{AppEvent, EventCancellation, SessionEventSender, SessionEventWorker};
use crate::app::ordered_session::OrderedSession;
use crate::pty_input::{PtyInputKind, PtyInputSender, PtyOperationFailure};
use crate::session::Session;

#[derive(Default)]
pub(super) struct MuxTitleIngress {
    pub(super) state: Mutex<MuxTitleIngressState>,
}

pub(super) fn forward_mux_events(
    event_source: Session,
    mut session_events: cmux_tui_core::MuxEventReceiver,
    stop_receiver: Arc<Mutex<Option<cmux_tui_core::MuxEventReceiver>>>,
    destination_mutation_committed: Arc<AtomicU64>,
    mux_recovery_generation: Arc<AtomicU64>,
    tx: SessionEventSender,
    mux_titles: Arc<MuxTitleIngress>,
) {
    let mut next_recovery_generation = 0_u64;
    while !tx.cancellation.stop.load(Ordering::Acquire) {
        let needs_recovery = match session_events.recv() {
            Ok(event) => {
                if matches!(forward_mux_event(event, &tx, &mux_titles), ForwardMuxOutcome::Stop) {
                    return;
                }
                false
            }
            Err(_) => {
                if session_events.overflowed() {
                    true
                } else {
                    return;
                }
            }
        };
        // The mailbox may close immediately after yielding its final accepted
        // event. Recover only after that event is forwarded.
        if !needs_recovery && !session_events.overflowed() {
            continue;
        }
        next_recovery_generation = next_recovery_generation.wrapping_add(1).max(1);
        let recovery_generation = next_recovery_generation;
        mux_recovery_generation.store(recovery_generation, Ordering::Release);
        // Subscribe before draining the closed mailbox so new events are
        // retained while every event accepted before overflow is delivered.
        let next_session_events = event_source.events();
        {
            let mut stop = stop_receiver.lock().unwrap();
            if tx.cancellation.stop.load(Ordering::Acquire) {
                next_session_events.close();
                return;
            }
            *stop = Some(next_session_events.clone());
        }
        let overflowed_events = std::mem::replace(&mut session_events, next_session_events);
        for event in overflowed_events.try_iter() {
            if tx.cancellation.stop.load(Ordering::Acquire) {
                return;
            }
            if matches!(forward_mux_event(event, &tx, &mux_titles), ForwardMuxOutcome::Stop) {
                return;
            }
        }
        if tx
            .send(AppEvent::Mux(MuxEvent::Status(
                "mux event backlog overflowed; transient events beyond the hard limit were rejected"
                    .to_string(),
            )))
            .is_err()
        {
            return;
        }
        let destination_generation = destination_mutation_committed.load(Ordering::Acquire);
        let title_snapshot_epoch = mux_titles.current_epoch();
        let recovered = event_source.refresh_tree().map_err(|error| error.to_string());
        let recovery_succeeded = recovered.is_ok();
        if recovered.is_ok() {
            mux_titles.reconcile_authoritative(title_snapshot_epoch);
        }
        if tx
            .send(AppEvent::MuxSubscriptionRecovered {
                recovery_generation,
                destination_generation,
                result: recovered,
            })
            .is_err()
        {
            return;
        }
        if !recovery_succeeded {
            if mux_titles.rearm_wake() && tx.send(AppEvent::MuxTitlesReady).is_err() {
                return;
            }
            continue;
        }
        for event in session_events.try_iter() {
            if tx.cancellation.stop.load(Ordering::Acquire) {
                return;
            }
            if matches!(forward_mux_event(event, &tx, &mux_titles), ForwardMuxOutcome::Stop) {
                return;
            }
        }
        if session_events.overflowed() {
            continue;
        }
        // A prior title wake may precede the authoritative snapshot. Queue a
        // post-snapshot wake so retained title changes cannot be overwritten.
        if tx.send(AppEvent::MuxTitlesReady).is_err()
            || tx.send(AppEvent::MuxRecoveryComplete { recovery_generation }).is_err()
        {
            return;
        }
    }
}

pub(super) enum ForwardMuxOutcome {
    Continue,
    Stop,
}

pub(super) fn forward_mux_event(
    event: MuxEvent,
    tx: &SessionEventSender,
    mux_titles: &MuxTitleIngress,
) -> ForwardMuxOutcome {
    if !tx.accepts_mux_event(&event) {
        return ForwardMuxOutcome::Continue;
    }
    if let MuxEvent::TitleChanged { surface, title } = &event {
        if !mux_titles.push(*surface, title.clone()) {
            return ForwardMuxOutcome::Continue;
        }
        return match tx.send(AppEvent::MuxTitlesReady) {
            Ok(()) => ForwardMuxOutcome::Continue,
            Err(_) => ForwardMuxOutcome::Stop,
        };
    }
    if let MuxEvent::SurfaceExited(surface) = &event {
        mux_titles.remove(*surface);
    }
    let terminal = matches!(event, MuxEvent::Empty);
    match tx.send(AppEvent::Mux(event)) {
        Ok(()) if terminal => ForwardMuxOutcome::Stop,
        Ok(()) => ForwardMuxOutcome::Continue,
        Err(_) => ForwardMuxOutcome::Stop,
    }
}

pub(super) fn start_ordered_session(
    inner: Session,
    operations: PtyInputSender,
    app_events: SyncSender<AppEvent>,
    generation: u64,
    surface_filter: Option<SurfaceId>,
) -> anyhow::Result<(OrderedSession, SessionEventWorker, Arc<MuxTitleIngress>, Arc<AtomicU64>)> {
    start_ordered_session_inner(inner, operations, app_events, generation, surface_filter, false)
}

pub(super) fn prepare_ordered_session(
    inner: Session,
    operations: PtyInputSender,
    app_events: SyncSender<AppEvent>,
    generation: u64,
    surface_filter: Option<SurfaceId>,
) -> anyhow::Result<(OrderedSession, SessionEventWorker, Arc<MuxTitleIngress>, Arc<AtomicU64>)> {
    start_ordered_session_inner(inner, operations, app_events, generation, surface_filter, true)
}

pub(super) fn start_ordered_session_inner(
    inner: Session,
    operations: PtyInputSender,
    app_events: SyncSender<AppEvent>,
    generation: u64,
    surface_filter: Option<SurfaceId>,
    paused: bool,
) -> anyhow::Result<(OrderedSession, SessionEventWorker, Arc<MuxTitleIngress>, Arc<AtomicU64>)> {
    let cancellation = EventCancellation::new();
    let start = Arc::new(AtomicBool::new(!paused));
    let events =
        SessionEventSender::scoped(app_events, generation, surface_filter, cancellation.clone());
    let layout_resize_owner = inner.allocate_layout_resize_owner();
    let operations = operations.for_session_generation(generation);
    let session = OrderedSession::new_with_event_sender(
        inner,
        operations,
        events.clone(),
        layout_resize_owner,
    );
    let mux_titles = Arc::new(MuxTitleIngress::default());
    let mux_recovery_generation = Arc::new(AtomicU64::new(0));
    let event_source = session.inner.clone();
    let session_events = event_source.events();
    let stop = Arc::new(Mutex::new(Some(session_events.clone())));
    let destination_mutation_committed = session.destination_mutation_committed.clone();
    let mux_recovery_sequence = mux_recovery_generation.clone();
    let worker_events = events;
    let worker_titles = mux_titles.clone();
    let worker_start = start.clone();
    let worker_stop = stop.clone();
    let mux =
        std::thread::Builder::new().name(format!("mux-events-{generation}")).spawn(move || {
            while !worker_start.load(Ordering::Acquire)
                && !worker_events.cancellation.stop.load(Ordering::Acquire)
            {
                std::thread::park_timeout(Duration::from_millis(1));
            }
            if worker_events.cancellation.stop.load(Ordering::Acquire) {
                return;
            }
            forward_mux_events(
                event_source,
                session_events,
                worker_stop,
                destination_mutation_committed,
                mux_recovery_sequence,
                worker_events,
                worker_titles,
            );
        })?;
    Ok((
        session,
        SessionEventWorker { cancellation, start, stop, mux: Some(mux) },
        mux_titles,
        mux_recovery_generation,
    ))
}

#[derive(Default)]
pub(super) struct MuxTitleIngressState {
    pub(super) wake_queued: bool,
    pub(super) epoch: u64,
    titles: HashMap<SurfaceId, RetainedMuxTitle>,
    dirty: HashSet<SurfaceId>,
}

pub(super) struct RetainedMuxTitle {
    pub(super) title: Arc<str>,
    pub(super) epoch: u64,
}

impl MuxTitleIngress {
    /// Returns true when the app channel needs one wake event.
    pub(super) fn push(&self, surface: SurfaceId, title: impl Into<Arc<str>>) -> bool {
        let mut state = self.state.lock().unwrap();
        state.epoch = state.epoch.saturating_add(1);
        let epoch = state.epoch;
        state.titles.insert(surface, RetainedMuxTitle { title: title.into(), epoch });
        state.dirty.insert(surface);
        if state.wake_queued {
            false
        } else {
            state.wake_queued = true;
            true
        }
    }

    pub(super) fn remove(&self, surface: SurfaceId) {
        let mut state = self.state.lock().unwrap();
        state.titles.remove(&surface);
        state.dirty.remove(&surface);
    }

    pub(super) fn take_dirty(&self) -> HashMap<SurfaceId, Arc<str>> {
        let mut state = self.state.lock().unwrap();
        state.wake_queued = false;
        let dirty = std::mem::take(&mut state.dirty);
        dirty
            .into_iter()
            .filter_map(|surface| {
                state.titles.get(&surface).map(|retained| (surface, retained.title.clone()))
            })
            .collect()
    }

    pub(super) fn snapshot(&self) -> HashMap<SurfaceId, Arc<str>> {
        let state = self.state.lock().unwrap();
        state.titles.iter().map(|(surface, retained)| (*surface, retained.title.clone())).collect()
    }

    pub(super) fn current_epoch(&self) -> u64 {
        self.state.lock().unwrap().epoch
    }

    pub(super) fn rearm_wake(&self) -> bool {
        let mut state = self.state.lock().unwrap();
        state.wake_queued = false;
        if state.dirty.is_empty() {
            false
        } else {
            state.wake_queued = true;
            true
        }
    }

    pub(super) fn reconcile_authoritative(&self, through_epoch: u64) {
        let mut state = self.state.lock().unwrap();
        state.titles.retain(|_, retained| retained.epoch > through_epoch);
        let retained_surfaces = state.titles.keys().copied().collect::<HashSet<_>>();
        state.dirty.retain(|surface| retained_surfaces.contains(surface));
    }
}

#[derive(Default)]
pub(super) struct PtyFailureIngress {
    pub(super) state: Mutex<PtyFailureIngressState>,
}

#[derive(Default)]
pub(super) struct PtyFailureIngressState {
    pub(super) wake_queued: bool,
    pub(super) failures: VecDeque<PtyOperationFailure>,
}

impl PtyFailureIngress {
    /// Returns true when the app channel needs one wake event.
    pub(super) fn push(&self, failure: PtyOperationFailure) -> bool {
        let mut state = self.state.lock().unwrap();
        if failure.kind == Some(PtyInputKind::Motion)
            && let Some(existing) = state.failures.iter_mut().find(|existing| {
                existing.kind == Some(PtyInputKind::Motion)
                    && existing.session_generation == failure.session_generation
                    && existing.surface_id == failure.surface_id
            })
        {
            *existing = failure;
        } else {
            if state.failures.len() >= PTY_FAILURE_CAPACITY {
                if let Some(index) = state
                    .failures
                    .iter()
                    .position(|existing| existing.kind == Some(PtyInputKind::Motion))
                {
                    state.failures.remove(index);
                } else {
                    state.failures.pop_front();
                }
            }
            state.failures.push_back(failure);
        }
        if state.wake_queued {
            false
        } else {
            state.wake_queued = true;
            true
        }
    }

    pub(super) fn take(&self) -> VecDeque<PtyOperationFailure> {
        let mut state = self.state.lock().unwrap();
        state.wake_queued = false;
        std::mem::take(&mut state.failures)
    }
}
