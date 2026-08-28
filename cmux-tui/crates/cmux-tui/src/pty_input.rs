//! Ordered, off-loop PTY input forwarding.
//!
//! PTY bytes and session mutations enter one bounded scheduler so local writer
//! locks and remote control-socket responses cannot block the UI. Acknowledged
//! surface operations run concurrently behind per-surface barriers, allowing
//! unrelated panes to keep accepting input while preserving each surface's
//! order. Consecutive byte-stream writes are batched, motion is coalesced, and
//! every accepted mouse press reserves its release capacity.

use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use cmux_tui_core::{SurfaceId, SurfaceKind};
use smallvec::SmallVec;

use crate::session::{SurfaceHandle, is_remote_timeout, is_remote_transport_failure};

pub(crate) const PTY_OPERATION_QUEUE_CAPACITY: usize = 512;
pub(crate) const TERMINAL_EXITED_LABEL: &str = "terminal exited";
const MAX_QUEUED_BYTES: usize = 4 * 1024 * 1024;
const MAX_CONCURRENT_SURFACE_OPERATIONS: usize = 32;
const RESERVED_RELEASE_BYTES: usize = 64;
const REMOTE_RELEASE_MAX_ATTEMPTS: u8 = 3;

pub type PtyInputBytes = SmallVec<[u8; 64]>;
type MutationCoalesceKey = (&'static str, u64, u64);
#[cfg(test)]
type DeliveredWriteObserver = Arc<dyn Fn(SurfaceId, &[u8]) + Send + Sync>;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PtyInputKind {
    Ordered,
    Press,
    Motion,
    Release,
    Mutation,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PtyInputEnqueueResult {
    Accepted,
    Oversized,
    Saturated,
    Failed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PtyOperationDelivery {
    KnownNotDelivered,
    Ambiguous,
}

#[derive(Debug)]
struct KnownNotDeliveredOperationError {
    error: anyhow::Error,
}

impl std::fmt::Display for KnownNotDeliveredOperationError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        self.error.fmt(formatter)
    }
}

impl std::error::Error for KnownNotDeliveredOperationError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        Some(self.error.as_ref())
    }
}

pub(crate) fn mark_operation_known_not_delivered(error: anyhow::Error) -> anyhow::Error {
    anyhow::Error::new(KnownNotDeliveredOperationError { error })
}

fn underlying_operation_error(error: &anyhow::Error) -> &anyhow::Error {
    error
        .downcast_ref::<KnownNotDeliveredOperationError>()
        .map(|marked| &marked.error)
        .unwrap_or(error)
}

pub struct PtyInputEvent {
    session_generation: u64,
    pub surface_id: SurfaceId,
    pub surface: SurfaceHandle,
    pub bytes: PtyInputBytes,
    retained_bytes: usize,
    pub kind: PtyInputKind,
    mutation: Option<Box<dyn FnOnce() -> anyhow::Result<()> + Send>>,
    after_operation: Option<Box<dyn FnOnce() + Send>>,
    on_superseded: Option<Box<dyn FnOnce() + Send>>,
    label: &'static str,
    coalesce_key: Option<MutationCoalesceKey>,
    failure_surface_id: Option<SurfaceId>,
    concurrent_surface_operation: bool,
    remote: bool,
    reservation_id: Option<u64>,
    remote_release_attempts: u8,
}

impl PtyInputEvent {
    pub fn input(
        surface_id: SurfaceId,
        surface: SurfaceHandle,
        bytes: PtyInputBytes,
        kind: PtyInputKind,
    ) -> Self {
        let remote = surface.is_remote();
        Self {
            session_generation: 1,
            surface_id,
            surface,
            bytes,
            retained_bytes: 0,
            kind,
            mutation: None,
            after_operation: None,
            on_superseded: None,
            label: "PTY input",
            coalesce_key: None,
            failure_surface_id: None,
            concurrent_surface_operation: false,
            remote,
            reservation_id: None,
            remote_release_attempts: 0,
        }
    }

    pub fn release(
        surface_id: SurfaceId,
        surface: SurfaceHandle,
        bytes: PtyInputBytes,
        reservation_id: u64,
    ) -> Self {
        let mut event = Self::input(surface_id, surface, bytes, PtyInputKind::Release);
        event.reservation_id = Some(reservation_id);
        event
    }

    #[cfg(test)]
    pub(crate) fn test_remote_timeout_input(
        surface_id: SurfaceId,
        surface: SurfaceHandle,
        bytes: PtyInputBytes,
        kind: PtyInputKind,
    ) -> Self {
        let mut event = Self::input(surface_id, surface, bytes, kind);
        event.remote = true;
        event.mutation = Some(Box::new(|| Err(crate::session::test_remote_timeout_error())));
        event
    }

    #[cfg(test)]
    fn mutation(
        label: &'static str,
        coalesce_key: Option<MutationCoalesceKey>,
        remote: bool,
        operation: impl FnOnce() -> anyhow::Result<()> + Send + 'static,
    ) -> Self {
        Self::mutation_with_superseded(label, coalesce_key, remote, None, None, operation)
    }

    #[cfg(test)]
    fn mutation_with_superseded(
        label: &'static str,
        coalesce_key: Option<MutationCoalesceKey>,
        remote: bool,
        on_superseded: Option<Box<dyn FnOnce() + Send>>,
        after_operation: Option<Box<dyn FnOnce() + Send>>,
        operation: impl FnOnce() -> anyhow::Result<()> + Send + 'static,
    ) -> Self {
        Self::mutation_for_surface(
            label,
            PtyMutationIdentity { coalesce_key, ..Default::default() },
            remote,
            on_superseded,
            after_operation,
            operation,
        )
    }

    fn mutation_for_surface(
        label: &'static str,
        identity: PtyMutationIdentity,
        remote: bool,
        on_superseded: Option<Box<dyn FnOnce() + Send>>,
        after_operation: Option<Box<dyn FnOnce() + Send>>,
        operation: impl FnOnce() -> anyhow::Result<()> + Send + 'static,
    ) -> Self {
        Self {
            session_generation: 1,
            surface_id: 0,
            surface: SurfaceHandle::RemoteBrowserUnsupported,
            bytes: PtyInputBytes::new(),
            retained_bytes: identity.retained_bytes,
            kind: PtyInputKind::Mutation,
            mutation: Some(Box::new(operation)),
            after_operation,
            on_superseded,
            label,
            coalesce_key: identity.coalesce_key,
            failure_surface_id: identity.failure_surface_id,
            concurrent_surface_operation: identity.concurrent_surface_operation,
            remote,
            reservation_id: None,
            remote_release_attempts: 0,
        }
    }

    fn queued_byte_len(&self) -> usize {
        self.bytes.len().saturating_add(self.retained_bytes)
    }

    fn ordering_surface_id(&self) -> Option<SurfaceId> {
        if self.kind == PtyInputKind::Mutation {
            self.concurrent_surface_operation.then_some(self.failure_surface_id).flatten()
        } else {
            Some(self.surface_id)
        }
    }

    fn ordering_lane(&self) -> Option<PtyInputLane> {
        self.ordering_surface_id().map(|surface_id| PtyInputLane {
            session_generation: self.session_generation,
            surface_id,
        })
    }
}

#[derive(Debug, Clone)]
pub struct PtyOperationFailure {
    pub session_generation: u64,
    pub surface_id: Option<SurfaceId>,
    pub kind: Option<PtyInputKind>,
    pub reservation_id: Option<u64>,
    pub label: &'static str,
    pub error: String,
    pub lane_failed: bool,
    pub delivery: PtyOperationDelivery,
}

struct QueueState {
    events: VecDeque<PtyInputEvent>,
    queued_bytes: usize,
    release_reservations: ReleaseReservations,
    in_flight: Option<InFlightInput>,
    in_flight_surface_operations: HashMap<PtyInputLane, usize>,
    failed_lanes: HashSet<PtyInputLane>,
    retired_in_flight_lanes: HashSet<PtyInputLane>,
    failed_remote_generations: HashSet<u64>,
    active_session_generation: u64,
    closed: bool,
    shutdown_release_drain: bool,
}

impl Default for QueueState {
    fn default() -> Self {
        Self {
            events: VecDeque::new(),
            queued_bytes: 0,
            release_reservations: ReleaseReservations::default(),
            in_flight: None,
            in_flight_surface_operations: HashMap::new(),
            failed_lanes: HashSet::new(),
            retired_in_flight_lanes: HashSet::new(),
            failed_remote_generations: HashSet::new(),
            active_session_generation: 1,
            closed: false,
            shutdown_release_drain: false,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
struct PtyInputLane {
    session_generation: u64,
    surface_id: SurfaceId,
}

#[derive(Default)]
struct ReleaseReservations {
    next_id: u64,
    outstanding: HashMap<u64, PtyInputLane>,
}

impl ReleaseReservations {
    fn len(&self) -> usize {
        self.outstanding.len()
    }

    fn reserve(&mut self, lane: PtyInputLane) -> u64 {
        self.next_id = self.next_id.wrapping_add(1);
        let id = self.next_id;
        self.outstanding.insert(id, lane);
        id
    }

    fn consume(&mut self, lane: PtyInputLane) -> bool {
        let id = self
            .outstanding
            .iter()
            .filter_map(|(id, reserved_lane)| (*reserved_lane == lane).then_some(*id))
            .min();
        id.is_some_and(|id| self.outstanding.remove(&id).is_some())
    }

    fn consume_id(&mut self, reservation_id: u64, lane: PtyInputLane) -> bool {
        if self.outstanding.get(&reservation_id) != Some(&lane) {
            return false;
        }
        self.outstanding.remove(&reservation_id).is_some()
    }

    fn cancel(&mut self, reservation_id: u64) {
        self.outstanding.remove(&reservation_id);
    }

    fn clear(&mut self) {
        self.outstanding.clear();
    }

    fn retain_generation(&mut self, session_generation: u64) {
        self.outstanding.retain(|_, lane| lane.session_generation == session_generation);
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct InFlightInput {
    lane: Option<PtyInputLane>,
    kind: PtyInputKind,
}

#[derive(Default)]
struct SharedQueue {
    state: Mutex<QueueState>,
    changed: Condvar,
    #[cfg(test)]
    after_operation_before_cleanup: Mutex<Option<Arc<dyn Fn() + Send + Sync>>>,
    #[cfg(test)]
    delivered_write_observer: Mutex<Option<DeliveredWriteObserver>>,
}

pub struct PtyInputDispatcher {
    sender: PtyInputSender,
    worker: Option<JoinHandle<()>>,
}

#[derive(Clone)]
pub struct PtyInputSender {
    queue: Arc<SharedQueue>,
    on_failure: Arc<dyn Fn(PtyOperationFailure) + Send + Sync>,
    session_generation: u64,
}

#[derive(Clone, Copy, Default)]
struct PtyMutationIdentity {
    coalesce_key: Option<MutationCoalesceKey>,
    failure_surface_id: Option<SurfaceId>,
    retained_bytes: usize,
    concurrent_surface_operation: bool,
}

impl PtyInputDispatcher {
    pub fn spawn(
        on_failure: impl Fn(PtyOperationFailure) + Send + Sync + 'static,
    ) -> anyhow::Result<Self> {
        let queue = Arc::new(SharedQueue::default());
        let worker_queue = queue.clone();
        let on_failure = Arc::new(on_failure);
        let worker_failure = on_failure.clone();
        let worker = std::thread::Builder::new()
            .name("mux-pty-input".into())
            .spawn(move || worker(worker_queue, worker_failure))?;
        Ok(Self {
            sender: PtyInputSender { queue, on_failure, session_generation: 1 },
            worker: Some(worker),
        })
    }

    #[cfg(test)]
    pub fn enqueue(&self, event: PtyInputEvent) -> PtyInputEnqueueResult {
        self.sender.enqueue(event)
    }

    #[cfg(test)]
    pub fn set_delivered_write_observer(&self, observer: Option<DeliveredWriteObserver>) {
        *self.sender.queue.delivered_write_observer.lock().unwrap() = observer;
    }

    pub fn enqueue_with_reservation(
        &self,
        event: PtyInputEvent,
    ) -> (PtyInputEnqueueResult, Option<u64>) {
        self.sender.enqueue_with_reservation(event)
    }

    pub fn sender(&self) -> PtyInputSender {
        self.sender.clone()
    }

    pub fn activate_session_generation(&mut self, session_generation: u64) {
        self.sender.session_generation = session_generation;
        let mut state = self.sender.queue.state.lock().unwrap();
        state.active_session_generation = session_generation;
        state.failed_lanes.retain(|lane| lane.session_generation == session_generation);
        state.retired_in_flight_lanes.retain(|lane| lane.session_generation == session_generation);
        state.failed_remote_generations.retain(|generation| *generation == session_generation);
        state.release_reservations.retain_generation(session_generation);
        self.sender.queue.changed.notify_all();
    }

    pub fn cancel_release_reservation(&self, reservation_id: u64) {
        self.sender.cancel_release_reservation(reservation_id);
    }

    /// Drain queued writes during detach/normal shutdown, bounded so a
    /// half-open remote session cannot hang terminal restoration forever.
    pub fn shutdown(&mut self, timeout: Duration) -> bool {
        let deadline = Instant::now() + timeout;
        let mut state = self.sender.queue.state.lock().unwrap();
        state.closed = true;
        self.sender.queue.changed.notify_all();
        while (!state.events.is_empty()
            || state.in_flight.is_some()
            || !state.in_flight_surface_operations.is_empty())
            && Instant::now() < deadline
        {
            let remaining = deadline.saturating_duration_since(Instant::now());
            let (next, _) = self.sender.queue.changed.wait_timeout(state, remaining).unwrap();
            state = next;
        }
        let drained = state.events.is_empty()
            && state.in_flight.is_none()
            && state.in_flight_surface_operations.is_empty();
        let canceled = if drained {
            Vec::new()
        } else {
            state.shutdown_release_drain = true;
            let generations =
                state.events.iter().map(|event| event.session_generation).collect::<HashSet<_>>();
            let mut canceled = Vec::new();
            for generation in generations {
                canceled.extend(prune_to_recovery_releases(
                    &mut state,
                    generation,
                    "canceled after the shutdown drain timed out",
                ));
            }
            self.sender.queue.changed.notify_all();
            canceled
        };
        drop(state);
        for failure in canceled {
            (self.sender.on_failure)(failure);
        }
        if drained && let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
        drained
    }
}

impl PtyInputSender {
    pub(crate) fn for_session_generation(&self, session_generation: u64) -> Self {
        Self { queue: self.queue.clone(), on_failure: self.on_failure.clone(), session_generation }
    }

    pub(crate) fn session_generation(&self) -> u64 {
        self.session_generation
    }

    #[cfg(test)]
    pub fn set_after_operation_before_cleanup(&self, hook: Option<Arc<dyn Fn() + Send + Sync>>) {
        *self.queue.after_operation_before_cleanup.lock().unwrap() = hook;
    }

    #[cfg(test)]
    pub fn queued_bytes_for_test(&self) -> usize {
        self.queue.state.lock().unwrap().queued_bytes
    }

    pub fn enqueue(&self, event: PtyInputEvent) -> PtyInputEnqueueResult {
        self.enqueue_with_reservation(event).0
    }

    fn enqueue_with_reservation(
        &self,
        mut event: PtyInputEvent,
    ) -> (PtyInputEnqueueResult, Option<u64>) {
        event.session_generation = self.session_generation;
        let mut state = self.queue.state.lock().unwrap();
        if state.closed {
            return (PtyInputEnqueueResult::Saturated, None);
        }
        if state.active_session_generation != self.session_generation {
            return (PtyInputEnqueueResult::Failed, None);
        }
        if state.failed_remote_generations.contains(&self.session_generation) && event.remote {
            return (PtyInputEnqueueResult::Failed, None);
        }
        let ordering_lane = event.ordering_lane();
        let reserved_recovery_release = event.kind == PtyInputKind::Release
            && ordering_lane.is_some_and(|lane| match event.reservation_id {
                Some(reservation_id) => {
                    state.release_reservations.outstanding.get(&reservation_id) == Some(&lane)
                }
                None => state
                    .release_reservations
                    .outstanding
                    .values()
                    .any(|reserved| *reserved == lane),
            });
        if ordering_lane.is_some_and(|lane| state.failed_lanes.contains(&lane))
            && !reserved_recovery_release
        {
            return (PtyInputEnqueueResult::Failed, None);
        }
        if event.queued_byte_len() > MAX_QUEUED_BYTES {
            return (PtyInputEnqueueResult::Oversized, None);
        }
        let reserves_release = event.kind == PtyInputKind::Press;
        let active_operations = state.in_flight_surface_operations.len();
        let active_bytes = state.in_flight_surface_operations.values().copied().sum::<usize>();
        let available_capacity = PTY_OPERATION_QUEUE_CAPACITY.saturating_sub(active_operations);
        let available_bytes = MAX_QUEUED_BYTES.saturating_sub(active_bytes);
        let QueueState { events, queued_bytes, release_reservations, .. } = &mut *state;
        let outcome = enqueue_bounded_with_evictions(
            events,
            queued_bytes,
            release_reservations,
            event,
            available_capacity,
            available_bytes,
        );
        let result = if outcome.accepted {
            let reservation_id = reserves_release.then_some(release_reservations.next_id);
            self.queue.changed.notify_one();
            (PtyInputEnqueueResult::Accepted, reservation_id)
        } else {
            (PtyInputEnqueueResult::Saturated, None)
        };
        drop(state);
        if let Some(on_superseded) = outcome.superseded {
            on_superseded();
        }
        for failure in outcome.evicted {
            (self.on_failure)(failure);
        }
        result
    }

    pub fn cancel_release_reservation(&self, reservation_id: u64) {
        let mut state = self.queue.state.lock().unwrap();
        state.release_reservations.cancel(reservation_id);
        self.queue.changed.notify_all();
    }

    pub fn retire_surface(&self, surface_id: SurfaceId) {
        let lane = PtyInputLane { session_generation: self.session_generation, surface_id };
        let mut state = self.queue.state.lock().unwrap();
        state.failed_lanes.remove(&lane);
        let is_in_flight = state.in_flight.is_some_and(|input| input.lane == Some(lane))
            || state.in_flight_surface_operations.contains_key(&lane);
        if is_in_flight {
            state.retired_in_flight_lanes.insert(lane);
        } else {
            state.retired_in_flight_lanes.remove(&lane);
        }
        state.events.retain(|event| event.ordering_lane() != Some(lane));
        state.release_reservations.outstanding.retain(|_, reserved_lane| *reserved_lane != lane);
        state.queued_bytes = state.events.iter().map(PtyInputEvent::queued_byte_len).sum();
        self.queue.changed.notify_all();
    }

    #[cfg(test)]
    pub fn enqueue_session_mutation(
        &self,
        label: &'static str,
        remote: bool,
        operation: impl FnOnce() -> anyhow::Result<()> + Send + 'static,
    ) {
        let _ = self.enqueue_mutation(
            label,
            PtyMutationIdentity::default(),
            remote,
            None,
            None,
            operation,
        );
    }

    pub fn enqueue_session_mutation_with_settlement(
        &self,
        label: &'static str,
        remote: bool,
        after_operation: impl FnOnce() + Send + 'static,
        operation: impl FnOnce() -> anyhow::Result<()> + Send + 'static,
    ) {
        let _ = self.enqueue_mutation(
            label,
            PtyMutationIdentity::default(),
            remote,
            None,
            Some(Box::new(after_operation)),
            operation,
        );
    }

    pub fn enqueue_coalescing_mutation_with_settlement(
        &self,
        label: &'static str,
        key: MutationCoalesceKey,
        remote: bool,
        on_superseded: impl FnOnce() + Send + 'static,
        after_operation: impl FnOnce() + Send + 'static,
        operation: impl FnOnce() -> anyhow::Result<()> + Send + 'static,
    ) -> PtyInputEnqueueResult {
        self.enqueue_mutation(
            label,
            PtyMutationIdentity { coalesce_key: Some(key), ..Default::default() },
            remote,
            Some(Box::new(on_superseded)),
            Some(Box::new(after_operation)),
            operation,
        )
    }

    pub fn enqueue_coalescing_surface_operation(
        &self,
        label: &'static str,
        surface_id: SurfaceId,
        remote: bool,
        operation: impl FnOnce() -> anyhow::Result<()> + Send + 'static,
    ) -> PtyInputEnqueueResult {
        self.enqueue_mutation(
            label,
            PtyMutationIdentity {
                coalesce_key: Some((label, surface_id, 0)),
                failure_surface_id: Some(surface_id),
                concurrent_surface_operation: true,
                ..Default::default()
            },
            remote,
            None,
            None,
            operation,
        )
    }

    pub fn enqueue_surface_operation_with_retained_bytes(
        &self,
        label: &'static str,
        surface_id: SurfaceId,
        remote: bool,
        retained_bytes: usize,
        operation: impl FnOnce() -> anyhow::Result<()> + Send + 'static,
    ) -> PtyInputEnqueueResult {
        self.enqueue_mutation(
            label,
            PtyMutationIdentity {
                failure_surface_id: Some(surface_id),
                retained_bytes,
                concurrent_surface_operation: true,
                ..Default::default()
            },
            remote,
            None,
            None,
            operation,
        )
    }

    fn enqueue_mutation(
        &self,
        label: &'static str,
        identity: PtyMutationIdentity,
        remote: bool,
        on_superseded: Option<Box<dyn FnOnce() + Send>>,
        after_operation: Option<Box<dyn FnOnce() + Send>>,
        operation: impl FnOnce() -> anyhow::Result<()> + Send + 'static,
    ) -> PtyInputEnqueueResult {
        let result = self.enqueue(PtyInputEvent::mutation_for_surface(
            label,
            identity,
            remote,
            on_superseded,
            after_operation,
            operation,
        ));
        if result != PtyInputEnqueueResult::Accepted {
            (self.on_failure)(PtyOperationFailure {
                session_generation: self.session_generation,
                surface_id: identity.failure_surface_id,
                kind: None,
                reservation_id: None,
                label,
                error: match result {
                    PtyInputEnqueueResult::Failed => {
                        "remote operation lane is unavailable after a transport failure"
                    }
                    _ => "operation queue is full; the session was left unchanged",
                }
                .into(),
                lane_failed: result == PtyInputEnqueueResult::Failed,
                delivery: PtyOperationDelivery::KnownNotDelivered,
            });
        }
        result
    }
}

impl Drop for PtyInputDispatcher {
    fn drop(&mut self) {
        let mut state = self.sender.queue.state.lock().unwrap();
        state.closed = true;
        if !state.shutdown_release_drain {
            state.events.clear();
            state.queued_bytes = 0;
            state.release_reservations.clear();
        }
        self.sender.queue.changed.notify_all();
    }
}

#[cfg(test)]
fn enqueue_bounded(
    events: &mut VecDeque<PtyInputEvent>,
    queued_bytes: &mut usize,
    release_reservations: &mut ReleaseReservations,
    event: PtyInputEvent,
    capacity: usize,
    max_bytes: usize,
) -> bool {
    let outcome = enqueue_bounded_with_evictions(
        events,
        queued_bytes,
        release_reservations,
        event,
        capacity,
        max_bytes,
    );
    if let Some(on_superseded) = outcome.superseded {
        on_superseded();
    }
    outcome.accepted
}

struct BoundedEnqueueOutcome {
    accepted: bool,
    evicted: Vec<PtyOperationFailure>,
    superseded: Option<Box<dyn FnOnce() + Send>>,
}

fn enqueue_bounded_with_evictions(
    events: &mut VecDeque<PtyInputEvent>,
    queued_bytes: &mut usize,
    release_reservations: &mut ReleaseReservations,
    mut event: PtyInputEvent,
    capacity: usize,
    max_bytes: usize,
) -> BoundedEnqueueOutcome {
    let mut evicted = Vec::new();
    let mut replaced = None;
    if let Some(key) = event.coalesce_key {
        for index in (0..events.len()).rev() {
            if events[index].session_generation == event.session_generation
                && events[index].coalesce_key == Some(key)
            {
                let previous = events.remove(index).unwrap();
                *queued_bytes = queued_bytes.saturating_sub(previous.queued_byte_len());
                replaced = Some((index, previous));
                break;
            }
            if events[index].coalesce_key.is_none() {
                break;
            }
        }
    }
    if event.kind == PtyInputKind::Motion
        && events.back().is_some_and(|previous| {
            previous.session_generation == event.session_generation
                && previous.kind == PtyInputKind::Motion
                && previous.surface_id == event.surface_id
        })
    {
        let previous_len = events.back().unwrap().queued_byte_len();
        let projected_bytes = queued_bytes.saturating_sub(previous_len)
            + event.queued_byte_len()
            + release_reservations.len() * RESERVED_RELEASE_BYTES;
        if projected_bytes > max_bytes {
            if let Some((index, previous)) = replaced.take() {
                *queued_bytes += previous.queued_byte_len();
                events.insert(index, previous);
            }
            return BoundedEnqueueOutcome { accepted: false, evicted, superseded: None };
        }
        *queued_bytes = queued_bytes.saturating_sub(previous_len) + event.queued_byte_len();
        *events.back_mut().unwrap() = event;
        let superseded = replaced.as_mut().and_then(|(_, previous)| previous.on_superseded.take());
        return BoundedEnqueueOutcome { accepted: true, evicted, superseded };
    }

    let merge_stream = event.kind == PtyInputKind::Ordered
        && events.back().is_some_and(|previous| {
            previous.session_generation == event.session_generation
                && previous.kind == PtyInputKind::Ordered
                && previous.surface_id == event.surface_id
        });
    let lane = event.ordering_lane();
    let consumes_reservation = event.kind == PtyInputKind::Release
        && match event.reservation_id {
            Some(reservation_id) => {
                release_reservations.outstanding.get(&reservation_id) == lane.as_ref()
            }
            None => {
                release_reservations.outstanding.values().any(|reserved| Some(*reserved) == lane)
            }
        };
    let mut projected = events.len()
        + release_reservations.len()
        + usize::from(!merge_stream)
        + usize::from(event.kind == PtyInputKind::Press);
    if consumes_reservation {
        projected -= 1;
    }
    let mut projected_bytes = *queued_bytes
        + event.queued_byte_len()
        + (release_reservations.len() + usize::from(event.kind == PtyInputKind::Press))
            * RESERVED_RELEASE_BYTES;
    if consumes_reservation {
        projected_bytes = projected_bytes.saturating_sub(RESERVED_RELEASE_BYTES);
    }
    while projected > capacity || projected_bytes > max_bytes {
        let Some(index) = events.iter().position(|queued| queued.kind == PtyInputKind::Motion)
        else {
            if let Some((index, previous)) = replaced.take() {
                *queued_bytes += previous.queued_byte_len();
                events.insert(index, previous);
            }
            return BoundedEnqueueOutcome { accepted: false, evicted, superseded: None };
        };
        let removed = events.remove(index).unwrap();
        *queued_bytes = queued_bytes.saturating_sub(removed.queued_byte_len());
        projected -= 1;
        projected_bytes = projected_bytes.saturating_sub(removed.queued_byte_len());
        evicted.push(PtyOperationFailure {
            session_generation: removed.session_generation,
            surface_id: Some(removed.surface_id),
            kind: Some(PtyInputKind::Motion),
            reservation_id: removed.reservation_id,
            label: removed.label,
            error: "evicted from the bounded PTY queue before delivery".to_string(),
            lane_failed: false,
            delivery: PtyOperationDelivery::KnownNotDelivered,
        });
    }

    if event.kind == PtyInputKind::Press {
        event.reservation_id = Some(
            release_reservations
                .reserve(lane.expect("terminal press has a generation-scoped surface lane")),
        );
    } else if consumes_reservation {
        let lane = lane.expect("terminal release has a generation-scoped surface lane");
        if let Some(reservation_id) = event.reservation_id {
            release_reservations.consume_id(reservation_id, lane);
        } else {
            release_reservations.consume(lane);
        }
    }

    if merge_stream {
        *queued_bytes += event.queued_byte_len();
        events.back_mut().unwrap().bytes.extend_from_slice(&event.bytes);
    } else {
        *queued_bytes += event.queued_byte_len();
        events.push_back(event);
    }
    let superseded = replaced.as_mut().and_then(|(_, previous)| previous.on_superseded.take());
    BoundedEnqueueOutcome { accepted: true, evicted, superseded }
}

fn worker(queue: Arc<SharedQueue>, on_failure: Arc<dyn Fn(PtyOperationFailure) + Send + Sync>) {
    loop {
        let event = {
            let mut state = queue.state.lock().unwrap();
            loop {
                if let Some(event) = dequeue_ready_event(&mut state) {
                    break event;
                }
                if state.events.is_empty()
                    && state.in_flight_surface_operations.is_empty()
                    && state.closed
                {
                    return;
                }
                state = queue.changed.wait(state).unwrap();
            }
        };

        if event.concurrent_surface_operation {
            spawn_surface_operation(queue.clone(), on_failure.clone(), event);
        } else {
            process_event(queue.clone(), on_failure.clone(), event);
        }
    }
}

fn dequeue_ready_event(state: &mut QueueState) -> Option<PtyInputEvent> {
    let mut ready_index = None;
    let mut blocked_queued_lanes = HashSet::new();
    for (index, event) in state.events.iter().enumerate() {
        if event.kind == PtyInputKind::Mutation && !event.concurrent_surface_operation {
            if index == 0 && state.in_flight_surface_operations.is_empty() {
                ready_index = Some(index);
            }
            // A session mutation is a global ordering barrier. If earlier
            // surface work keeps it from running, later input must wait too.
            break;
        }
        let lane = event
            .ordering_lane()
            .expect("surface input and concurrent operations have an ordering lane");
        if blocked_queued_lanes.contains(&lane) {
            continue;
        }
        if state.in_flight_surface_operations.contains_key(&lane) {
            blocked_queued_lanes.insert(lane);
            continue;
        }
        if event.concurrent_surface_operation
            && state.in_flight_surface_operations.len() >= MAX_CONCURRENT_SURFACE_OPERATIONS
        {
            // Worker saturation delays this operation, but it remains the
            // ordering barrier for later work in the same surface lane.
            blocked_queued_lanes.insert(lane);
            continue;
        }
        ready_index = Some(index);
        break;
    }
    let index = ready_index?;
    let event = state.events.remove(index).unwrap();
    state.queued_bytes = state.queued_bytes.saturating_sub(event.queued_byte_len());
    if event.concurrent_surface_operation {
        let lane =
            event.ordering_lane().expect("concurrent surface operation has an ordering lane");
        assert!(state.in_flight_surface_operations.insert(lane, event.queued_byte_len()).is_none());
    } else {
        state.in_flight = Some(InFlightInput { lane: event.ordering_lane(), kind: event.kind });
    }
    Some(event)
}

fn spawn_surface_operation(
    queue: Arc<SharedQueue>,
    on_failure: Arc<dyn Fn(PtyOperationFailure) + Send + Sync>,
    event: PtyInputEvent,
) {
    let pending = Arc::new(Mutex::new(Some(event)));
    let worker_pending = pending.clone();
    let worker_queue = queue.clone();
    let worker_failure = on_failure.clone();
    let spawn = std::thread::Builder::new().name("mux-surface-operation".into()).spawn(move || {
        let event = worker_pending.lock().unwrap().take().unwrap();
        process_event(worker_queue, worker_failure, event);
    });
    if let Err(error) = spawn {
        let event = pending.lock().unwrap().take().unwrap();
        fail_surface_operation_spawn(queue, on_failure, event, error);
    }
}

fn fail_surface_operation_spawn(
    queue: Arc<SharedQueue>,
    on_failure: Arc<dyn Fn(PtyOperationFailure) + Send + Sync>,
    mut event: PtyInputEvent,
    error: std::io::Error,
) {
    let lane = event.ordering_lane().expect("concurrent surface operation has an ordering lane");
    let after_operation = event.after_operation.take();
    on_failure(PtyOperationFailure {
        session_generation: event.session_generation,
        surface_id: Some(lane.surface_id),
        kind: None,
        reservation_id: None,
        label: event.label,
        error: format!("could not start surface operation worker: {error}"),
        lane_failed: false,
        delivery: PtyOperationDelivery::KnownNotDelivered,
    });
    let mut state = queue.state.lock().unwrap();
    state.in_flight_surface_operations.remove(&lane);
    state.retired_in_flight_lanes.remove(&lane);
    queue.changed.notify_all();
    drop(state);
    if let Some(after_operation) = after_operation {
        after_operation();
    }
}

fn known_exited_input(kind: PtyInputKind, surface_dead: bool) -> bool {
    kind != PtyInputKind::Mutation && surface_dead
}

fn process_event(
    queue: Arc<SharedQueue>,
    on_failure: Arc<dyn Fn(PtyOperationFailure) + Send + Sync>,
    mut event: PtyInputEvent,
) {
    let concurrent_surface = event.concurrent_surface_operation;
    let ordering_lane = event.ordering_lane();
    let kind = (event.kind != PtyInputKind::Mutation).then_some(event.kind);
    let surface_id = kind.map(|_| event.surface_id).or(event.failure_surface_id);
    let session_generation = event.session_generation;
    let remote = event.remote;
    let reservation_id = event.reservation_id;
    if remote && event.kind == PtyInputKind::Release {
        event.remote_release_attempts = event.remote_release_attempts.saturating_add(1);
    }
    let after_operation = event.after_operation.take();
    let reject_known_exit = known_exited_input(event.kind, event.surface.is_dead());
    #[cfg(test)]
    let is_write = event.mutation.is_none();
    let result = if reject_known_exit {
        Err(mark_operation_known_not_delivered(anyhow::anyhow!(
            "terminal exited before input delivery"
        )))
    } else if let Some(operation) = event.mutation.take() {
        operation()
    } else {
        let write_result = event.surface.write_bytes(&event.bytes);
        if crate::input_audit::enabled() {
            crate::input_audit::record(
                "t3-write",
                &format!(
                    "surface={} kind={:?} result={}",
                    event.surface_id,
                    event.kind,
                    match &write_result {
                        Ok(()) => "ok".to_string(),
                        Err(error) => format!("err:{error}"),
                    }
                ),
                &event.bytes,
            );
        }
        write_result
    };
    if reject_known_exit && crate::input_audit::enabled() {
        crate::input_audit::record(
            "t3-rejected-exited",
            &format!("surface={} kind={:?}", event.surface_id, event.kind),
            &event.bytes,
        );
    }
    #[cfg(test)]
    if is_write && result.is_ok() {
        let observer = queue.delivered_write_observer.lock().unwrap().clone();
        if let Some(observer) = observer {
            observer(event.surface_id, &event.bytes);
        }
    }
    #[cfg(test)]
    let before_cleanup = queue.after_operation_before_cleanup.lock().unwrap().clone();
    #[cfg(test)]
    if let Some(before_cleanup) = before_cleanup {
        before_cleanup();
    }
    let marked_known_not_delivered = result
        .as_ref()
        .err()
        .is_some_and(|error| error.downcast_ref::<KnownNotDeliveredOperationError>().is_some());
    let operation_error = result.as_ref().err().map(underlying_operation_error);
    let remote_transport_failed =
        remote && operation_error.is_some_and(is_remote_transport_failure);
    let remote_timed_out = remote && operation_error.is_some_and(is_remote_timeout);
    // Any remote transport error can follow a complete request write, and
    // response timeout or rejection can likewise follow an operation that
    // already executed. Local PTY errors can occur while flushing after
    // bytes were written.
    let known_not_delivered = marked_known_not_delivered
        || (event.kind != PtyInputKind::Mutation
            && !remote
            && event.surface.kind() == SurfaceKind::Browser);
    let suppress_mutation_timeout = remote_timed_out
        && event.kind == PtyInputKind::Mutation
        && event.failure_surface_id.is_none();
    let ambiguous_release = remote_timed_out && event.kind == PtyInputKind::Release;
    let retry_ambiguous_release =
        ambiguous_release && event.remote_release_attempts < REMOTE_RELEASE_MAX_ATTEMPTS;
    let exhausted_ambiguous_release = ambiguous_release && !retry_ambiguous_release;
    let ambiguous_surface_failure = result.is_err()
        && ordering_lane.is_some()
        && !known_not_delivered
        && !remote_transport_failed
        && !remote_timed_out;
    let timed_out_surface_lane =
        remote_timed_out && ordering_lane.is_some() && !retry_ambiguous_release;
    let failure = result.err().and_then(|error| {
        (!suppress_mutation_timeout && !retry_ambiguous_release).then(|| PtyOperationFailure {
            session_generation,
            surface_id,
            kind,
            reservation_id,
            label: if reject_known_exit { TERMINAL_EXITED_LABEL } else { event.label },
            error: if exhausted_ambiguous_release {
                format!(
                    "mouse release timed out after {REMOTE_RELEASE_MAX_ATTEMPTS} attempts; detach and reconnect before sending more input"
                )
            } else {
                error.to_string()
            },
            lane_failed: remote_transport_failed
                || exhausted_ambiguous_release
                || ambiguous_surface_failure
                || timed_out_surface_lane,
            delivery: if known_not_delivered {
                PtyOperationDelivery::KnownNotDelivered
            } else {
                PtyOperationDelivery::Ambiguous
            },
        })
    });
    let mut state = queue.state.lock().unwrap();
    let retired_lane =
        ordering_lane.is_some_and(|lane| state.retired_in_flight_lanes.remove(&lane));
    let mut canceled = Vec::new();
    if failure
        .as_ref()
        .is_some_and(|failure| failure.delivery == PtyOperationDelivery::KnownNotDelivered)
        && kind == Some(PtyInputKind::Press)
        && let Some(reservation_id) = reservation_id
    {
        state.release_reservations.outstanding.remove(&reservation_id);
    }
    if remote_transport_failed || (exhausted_ambiguous_release && !retired_lane) {
        // A failed socket write poisons only the remote session generation
        // that owns it. A replacement session may reuse every surface id.
        if state.active_session_generation == session_generation {
            state.failed_remote_generations.insert(session_generation);
        }
        canceled.extend(prune_failed_generation(
            &mut state,
            session_generation,
            if exhausted_ambiguous_release {
                "canceled after mouse release recovery timed out; detach and reconnect"
            } else {
                "canceled after the remote transport failed"
            },
        ));
    } else if remote_timed_out {
        // A timeout does not prove the socket is dead. Acknowledged surface
        // operations cancel only their own followers; unrelated surfaces can
        // continue using the live transport.
        if !retired_lane
            && retry_ambiguous_release
            && (!state.closed || state.shutdown_release_drain)
        {
            requeue_ambiguous_release(&mut state, event);
        }
        if let Some(lane) = ordering_lane {
            if !retired_lane {
                if !retry_ambiguous_release && state.active_session_generation == session_generation
                {
                    state.failed_lanes.insert(lane);
                }
                canceled.extend(prune_lane_to_recovery_releases(
                    &mut state,
                    lane,
                    "canceled after a remote surface request timed out",
                ));
            }
        } else {
            canceled.extend(prune_to_recovery_releases(
                &mut state,
                session_generation,
                "canceled after a remote request timed out",
            ));
        }
    } else if ambiguous_surface_failure {
        let lane = ordering_lane.expect("ambiguous surface failure has an ordering lane");
        if !retired_lane {
            if state.active_session_generation == session_generation {
                state.failed_lanes.insert(lane);
            }
            canceled.extend(prune_failed_lane(
                &mut state,
                lane,
                reservation_id.filter(|_| kind == Some(PtyInputKind::Press)),
                "canceled after ambiguous surface delivery; detach and reconnect",
            ));
        }
    }
    drop(state);
    if let Some(failure) = failure {
        on_failure(failure);
    }
    for failure in canceled {
        on_failure(failure);
    }
    let mut state = queue.state.lock().unwrap();
    if let Some(lane) = concurrent_surface.then_some(ordering_lane).flatten() {
        state.in_flight_surface_operations.remove(&lane);
    } else {
        state.in_flight = None;
    }
    queue.changed.notify_all();
    drop(state);
    // Completion is a barrier: publish only after timeout pruning,
    // in-flight ownership, and failure delivery have all settled.
    if let Some(after_operation) = after_operation {
        after_operation();
    }
}

/// Byte-accounting tap (issue 10431): queued bytes canceled before delivery.
fn audit_canceled_event(event: &PtyInputEvent, reason: &str) {
    if !event.bytes.is_empty() {
        crate::input_audit::record(
            "t3-canceled",
            &format!("surface={} kind={:?} reason={reason}", event.surface_id, event.kind),
            &event.bytes,
        );
    }
}

fn requeue_ambiguous_release(state: &mut QueueState, event: PtyInputEvent) {
    debug_assert_eq!(event.kind, PtyInputKind::Release);
    state.queued_bytes += event.queued_byte_len();
    state.events.push_front(event);
}

fn prune_failed_generation(
    state: &mut QueueState,
    session_generation: u64,
    error: &'static str,
) -> Vec<PtyOperationFailure> {
    let mut retained = VecDeque::new();
    let mut canceled = Vec::new();
    for event in state.events.drain(..) {
        if event.session_generation != session_generation {
            retained.push_back(event);
            continue;
        }
        audit_canceled_event(&event, error);
        canceled.push(PtyOperationFailure {
            session_generation: event.session_generation,
            surface_id: (event.kind != PtyInputKind::Mutation)
                .then_some(event.surface_id)
                .or(event.failure_surface_id),
            kind: (event.kind != PtyInputKind::Mutation).then_some(event.kind),
            reservation_id: event.reservation_id,
            label: event.label,
            error: error.into(),
            lane_failed: true,
            delivery: PtyOperationDelivery::KnownNotDelivered,
        });
    }
    state
        .release_reservations
        .outstanding
        .retain(|_, lane| lane.session_generation != session_generation);
    state.queued_bytes = retained.iter().map(PtyInputEvent::queued_byte_len).sum();
    state.events = retained;
    canceled
}

fn prune_to_recovery_releases(
    state: &mut QueueState,
    session_generation: u64,
    error: &'static str,
) -> Vec<PtyOperationFailure> {
    let canceled_press_reservations = state
        .events
        .iter()
        .filter(|event| {
            event.session_generation == session_generation && event.kind == PtyInputKind::Press
        })
        .filter_map(|event| event.reservation_id)
        .collect::<HashSet<_>>();
    let mut retained = VecDeque::new();
    let mut canceled = Vec::new();
    for event in state.events.drain(..) {
        if event.session_generation != session_generation {
            retained.push_back(event);
            continue;
        }
        let retain_release = event.kind == PtyInputKind::Release
            && event.reservation_id.is_some_and(|id| !canceled_press_reservations.contains(&id));
        if retain_release {
            retained.push_back(event);
            continue;
        }
        if event.kind == PtyInputKind::Press
            && let Some(reservation_id) = event.reservation_id
        {
            state.release_reservations.outstanding.remove(&reservation_id);
        }
        audit_canceled_event(&event, error);
        canceled.push(PtyOperationFailure {
            session_generation: event.session_generation,
            surface_id: (event.kind != PtyInputKind::Mutation)
                .then_some(event.surface_id)
                .or(event.failure_surface_id),
            kind: (event.kind != PtyInputKind::Mutation).then_some(event.kind),
            reservation_id: event.reservation_id,
            label: event.label,
            error: error.into(),
            lane_failed: false,
            delivery: PtyOperationDelivery::KnownNotDelivered,
        });
    }
    state.queued_bytes = retained.iter().map(PtyInputEvent::queued_byte_len).sum();
    state.events = retained;
    canceled
}

fn prune_failed_lane(
    state: &mut QueueState,
    lane: PtyInputLane,
    recovery_reservation_id: Option<u64>,
    error: &'static str,
) -> Vec<PtyOperationFailure> {
    let mut retained = VecDeque::new();
    let mut canceled = Vec::new();
    for event in state.events.drain(..) {
        if event.ordering_lane() != Some(lane) {
            retained.push_back(event);
            continue;
        }
        let retain_recovery_release = event.kind == PtyInputKind::Release
            && event.reservation_id == recovery_reservation_id
            && recovery_reservation_id.is_some();
        if retain_recovery_release {
            retained.push_back(event);
            continue;
        }
        audit_canceled_event(&event, error);
        canceled.push(PtyOperationFailure {
            session_generation: event.session_generation,
            surface_id: Some(lane.surface_id),
            kind: (event.kind != PtyInputKind::Mutation).then_some(event.kind),
            reservation_id: event.reservation_id,
            label: event.label,
            error: error.into(),
            lane_failed: true,
            delivery: PtyOperationDelivery::KnownNotDelivered,
        });
    }
    state.release_reservations.outstanding.retain(|reservation_id, reserved_lane| {
        *reserved_lane != lane || Some(*reservation_id) == recovery_reservation_id
    });
    state.queued_bytes = retained.iter().map(PtyInputEvent::queued_byte_len).sum();
    state.events = retained;
    canceled
}

fn prune_lane_to_recovery_releases(
    state: &mut QueueState,
    lane: PtyInputLane,
    error: &'static str,
) -> Vec<PtyOperationFailure> {
    let canceled_press_reservations = state
        .events
        .iter()
        .filter(|event| event.ordering_lane() == Some(lane) && event.kind == PtyInputKind::Press)
        .filter_map(|event| event.reservation_id)
        .collect::<HashSet<_>>();
    let mut retained = VecDeque::new();
    let mut canceled = Vec::new();
    for event in state.events.drain(..) {
        if event.ordering_lane() != Some(lane) {
            retained.push_back(event);
            continue;
        }
        let retain_release = event.kind == PtyInputKind::Release
            && event.reservation_id.is_some_and(|id| !canceled_press_reservations.contains(&id));
        if retain_release {
            retained.push_back(event);
            continue;
        }
        if event.kind == PtyInputKind::Press
            && let Some(reservation_id) = event.reservation_id
        {
            state.release_reservations.outstanding.remove(&reservation_id);
        }
        audit_canceled_event(&event, error);
        canceled.push(PtyOperationFailure {
            session_generation: event.session_generation,
            surface_id: Some(lane.surface_id),
            kind: (event.kind != PtyInputKind::Mutation).then_some(event.kind),
            reservation_id: event.reservation_id,
            label: event.label,
            error: error.into(),
            lane_failed: false,
            delivery: PtyOperationDelivery::KnownNotDelivered,
        });
    }
    state.queued_bytes = retained.iter().map(PtyInputEvent::queued_byte_len).sum();
    state.events = retained;
    canceled
}

#[cfg(test)]
mod tests {
    use super::*;
    use cmux_tui_core::{Mux as TestMux, SurfaceOptions as TestSurfaceOptions};

    fn lane(surface_id: SurfaceId) -> PtyInputLane {
        PtyInputLane { session_generation: 1, surface_id }
    }

    fn event(surface_id: SurfaceId, bytes: u8, kind: PtyInputKind) -> PtyInputEvent {
        PtyInputEvent::input(
            surface_id,
            SurfaceHandle::RemoteBrowserUnsupported,
            SmallVec::from_slice(&[bytes]),
            kind,
        )
    }

    #[test]
    fn exited_input_is_rejected_before_transport_but_mutations_are_not() {
        assert!(known_exited_input(PtyInputKind::Ordered, true));
        assert!(!known_exited_input(PtyInputKind::Mutation, true));
        assert!(!known_exited_input(PtyInputKind::Ordered, false));
    }

    #[test]
    fn clean_terminal_exit_is_known_not_delivered_and_does_not_fail_its_lane() {
        let mux = TestMux::new(
            "clean-terminal-exit-lane-test",
            TestSurfaceOptions {
                command: Some(vec!["/bin/sh".to_string(), "-c".to_string(), "exit 0".to_string()]),
                ..Default::default()
            },
        );
        let surface = mux.new_workspace(Some("work".to_string()), Some((20, 8))).unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        while !surface.is_dead() {
            assert!(Instant::now() < deadline, "terminal host did not exit");
            std::thread::yield_now();
        }

        let (failure_tx, failure_rx) = std::sync::mpsc::channel();
        let mut dispatcher = PtyInputDispatcher::spawn(move |failure| {
            failure_tx.send(failure).unwrap();
        })
        .unwrap();
        let input = || {
            PtyInputEvent::input(
                surface.id,
                SurfaceHandle::Local(surface.clone(), mux.clone()),
                PtyInputBytes::from_slice(b"x"),
                PtyInputKind::Ordered,
            )
        };

        assert_eq!(dispatcher.enqueue(input()), PtyInputEnqueueResult::Accepted);
        let failure = failure_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert_eq!(failure.label, "terminal exited");
        assert_eq!(failure.delivery, PtyOperationDelivery::KnownNotDelivered);
        assert!(!failure.lane_failed, "a clean process exit must not poison the input lane");
        assert_eq!(dispatcher.enqueue(input()), PtyInputEnqueueResult::Accepted);

        assert!(dispatcher.shutdown(Duration::from_secs(1)));
        mux.shutdown();
    }

    #[test]
    fn exit_observed_after_a_failed_write_keeps_delivery_ambiguous() {
        let mux = TestMux::new("post-write-exit-delivery-test", TestSurfaceOptions::default());
        let surface = mux.new_workspace(None, Some((20, 8))).unwrap();
        let handle = SurfaceHandle::Local(surface.clone(), mux.clone());
        let (failure_tx, failure_rx) = std::sync::mpsc::channel();
        let dispatcher = PtyInputDispatcher::spawn(move |failure| {
            failure_tx.send(failure).unwrap();
        })
        .unwrap();
        dispatcher.sender().set_after_operation_before_cleanup(Some(Arc::new({
            let surface = surface.clone();
            move || surface.kill()
        })));
        let mut input = PtyInputEvent::input(
            surface.id,
            handle,
            PtyInputBytes::from_slice(b"x"),
            PtyInputKind::Ordered,
        );
        input.mutation = Some(Box::new(|| Err(anyhow::anyhow!("flush failed after acceptance"))));

        assert_eq!(dispatcher.enqueue(input), PtyInputEnqueueResult::Accepted);
        let failure = failure_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert_eq!(failure.delivery, PtyOperationDelivery::Ambiguous);
        assert!(failure.lane_failed);
        assert_eq!(failure.label, "PTY input");

        mux.shutdown();
    }

    fn mutation_with_retained_bytes(retained_bytes: usize) -> PtyInputEvent {
        PtyInputEvent::mutation_for_surface(
            "retained payload",
            PtyMutationIdentity { retained_bytes, ..Default::default() },
            false,
            None,
            None,
            || Ok(()),
        )
    }

    #[test]
    fn consecutive_motion_on_one_surface_keeps_latest() {
        let mut events = VecDeque::new();
        let mut queued_bytes = 0;
        let mut releases = ReleaseReservations::default();
        assert!(enqueue_bounded(
            &mut events,
            &mut queued_bytes,
            &mut releases,
            event(1, 1, PtyInputKind::Motion),
            8,
            1024,
        ));
        assert!(enqueue_bounded(
            &mut events,
            &mut queued_bytes,
            &mut releases,
            event(1, 2, PtyInputKind::Motion),
            8,
            1024,
        ));
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].bytes.as_slice(), &[2]);
    }

    #[test]
    fn bounded_queue_reports_evicted_motion_as_known_not_delivered() {
        let mut events = VecDeque::new();
        let mut queued_bytes = 0;
        let mut releases = ReleaseReservations::default();
        assert!(enqueue_bounded(
            &mut events,
            &mut queued_bytes,
            &mut releases,
            event(7, 1, PtyInputKind::Motion),
            1,
            1024,
        ));

        let outcome = enqueue_bounded_with_evictions(
            &mut events,
            &mut queued_bytes,
            &mut releases,
            event(8, 2, PtyInputKind::Ordered),
            1,
            1024,
        );

        assert!(outcome.accepted);
        assert_eq!(outcome.evicted.len(), 1);
        assert_eq!(outcome.evicted[0].surface_id, Some(7));
        assert_eq!(outcome.evicted[0].kind, Some(PtyInputKind::Motion));
        assert_eq!(outcome.evicted[0].delivery, PtyOperationDelivery::KnownNotDelivered);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].surface_id, 8);
    }

    #[test]
    fn sender_emits_failure_when_bounded_queue_evicts_motion() {
        let (failure_tx, failure_rx) = std::sync::mpsc::channel();
        let (started_tx, started_rx) = std::sync::mpsc::channel();
        let (unblock_tx, unblock_rx) = std::sync::mpsc::channel();
        let dispatcher = PtyInputDispatcher::spawn(move |failure| {
            failure_tx.send(failure).unwrap();
        })
        .unwrap();
        let sender = dispatcher.sender();
        sender.enqueue_session_mutation("blocker", false, move || {
            started_tx.send(()).unwrap();
            unblock_rx.recv().unwrap();
            Ok(())
        });
        started_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert_eq!(
            sender.enqueue(event(7, 1, PtyInputKind::Motion)),
            PtyInputEnqueueResult::Accepted
        );
        for _ in 0..PTY_OPERATION_QUEUE_CAPACITY - 1 {
            assert_eq!(
                sender.enqueue(PtyInputEvent::mutation("fill", None, false, || Ok(()))),
                PtyInputEnqueueResult::Accepted
            );
        }

        assert_eq!(
            sender.enqueue(PtyInputEvent::mutation("overflow", None, false, || Ok(()))),
            PtyInputEnqueueResult::Accepted
        );
        let failure = failure_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert_eq!(failure.surface_id, Some(7));
        assert_eq!(failure.kind, Some(PtyInputKind::Motion));
        assert_eq!(failure.delivery, PtyOperationDelivery::KnownNotDelivered);

        unblock_tx.send(()).unwrap();
    }

    #[test]
    fn ordered_bytes_batch_without_crossing_motion_or_surfaces() {
        let mut events = VecDeque::new();
        let mut queued_bytes = 0;
        let mut releases = ReleaseReservations::default();
        for item in [
            event(1, 1, PtyInputKind::Ordered),
            event(1, 2, PtyInputKind::Ordered),
            event(1, 3, PtyInputKind::Motion),
            event(2, 4, PtyInputKind::Ordered),
        ] {
            assert!(enqueue_bounded(&mut events, &mut queued_bytes, &mut releases, item, 8, 1024,));
        }
        assert_eq!(events.len(), 3);
        assert_eq!(events[0].bytes.as_slice(), &[1, 2]);
        assert!(!events[0].bytes.spilled());
        assert_eq!(events[1].bytes.as_slice(), &[3]);
        assert_eq!(events[2].bytes.as_slice(), &[4]);
    }

    #[test]
    fn ordered_input_does_not_cross_a_session_mutation() {
        let mut events = VecDeque::new();
        let mut queued_bytes = 0;
        let mut releases = ReleaseReservations::default();
        assert!(enqueue_bounded(
            &mut events,
            &mut queued_bytes,
            &mut releases,
            event(1, 1, PtyInputKind::Ordered),
            8,
            1024,
        ));
        assert!(enqueue_bounded(
            &mut events,
            &mut queued_bytes,
            &mut releases,
            PtyInputEvent::mutation("close tab", None, false, || Ok(())),
            8,
            1024,
        ));
        assert!(enqueue_bounded(
            &mut events,
            &mut queued_bytes,
            &mut releases,
            event(1, 2, PtyInputKind::Ordered),
            8,
            1024,
        ));

        assert_eq!(events.len(), 3);
        assert_eq!(events[0].bytes.as_slice(), &[1]);
        assert_eq!(events[1].kind, PtyInputKind::Mutation);
        assert_eq!(events[2].bytes.as_slice(), &[2]);
    }

    #[test]
    fn surface_operation_failure_keeps_its_surface_identity() {
        let (failure_tx, failure_rx) = std::sync::mpsc::channel();
        let dispatcher = PtyInputDispatcher::spawn(move |failure| {
            failure_tx.send(failure).unwrap();
        })
        .unwrap();

        assert_eq!(
            dispatcher.sender().enqueue_coalescing_surface_operation(
                "clear terminal history",
                42,
                false,
                || Err(anyhow::anyhow!("clear failed")),
            ),
            PtyInputEnqueueResult::Accepted
        );

        let failure = failure_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert_eq!(failure.surface_id, Some(42));
        assert_eq!(failure.kind, None);
        assert_eq!(failure.label, "clear terminal history");
        assert_eq!(failure.delivery, PtyOperationDelivery::Ambiguous);
    }

    #[test]
    fn ambiguous_surface_operation_quarantines_only_its_surface() {
        let queue = Arc::new(SharedQueue::default());
        {
            let mut state = queue.state.lock().unwrap();
            state.events.push_back(event(41, 1, PtyInputKind::Ordered));
            state.events.push_back(event(42, 2, PtyInputKind::Ordered));
            state.queued_bytes = 2;
            state.in_flight_surface_operations.insert(lane(41), 0);
        }
        let failures = Arc::new(Mutex::new(Vec::new()));
        let captured_failures = failures.clone();
        let on_failure: Arc<dyn Fn(PtyOperationFailure) + Send + Sync> =
            Arc::new(move |failure| captured_failures.lock().unwrap().push(failure));
        let operation = PtyInputEvent::mutation_for_surface(
            "clear terminal history",
            PtyMutationIdentity {
                failure_surface_id: Some(41),
                concurrent_surface_operation: true,
                ..Default::default()
            },
            false,
            None,
            None,
            || Err(anyhow::anyhow!("partial fallback write")),
        );

        process_event(queue.clone(), on_failure.clone(), operation);

        {
            let state = queue.state.lock().unwrap();
            assert_eq!(
                state.events.iter().map(PtyInputEvent::ordering_surface_id).collect::<Vec<_>>(),
                vec![Some(42)],
                "same-surface input survived an ambiguous surface operation"
            );
            assert!(!state.in_flight_surface_operations.contains_key(&lane(41)));
        }
        let sender = PtyInputSender { queue, on_failure, session_generation: 1 };
        assert_eq!(
            sender.enqueue(event(41, 3, PtyInputKind::Ordered)),
            PtyInputEnqueueResult::Failed,
            "new same-surface input entered an ambiguous lane"
        );
        assert_eq!(
            sender.enqueue(event(42, 4, PtyInputKind::Ordered)),
            PtyInputEnqueueResult::Accepted,
            "an unrelated surface was quarantined"
        );

        let failures = failures.lock().unwrap();
        assert!(failures.iter().any(|failure| {
            failure.surface_id == Some(41)
                && failure.label == "clear terminal history"
                && failure.delivery == PtyOperationDelivery::Ambiguous
                && failure.lane_failed
        }));
        assert!(failures.iter().any(|failure| {
            failure.surface_id == Some(41)
                && failure.delivery == PtyOperationDelivery::KnownNotDelivered
                && failure.lane_failed
        }));
    }

    #[test]
    fn retiring_a_failed_surface_removes_its_lane_quarantine() {
        let (failure_tx, failure_rx) = std::sync::mpsc::channel();
        let dispatcher = PtyInputDispatcher::spawn(move |failure| {
            failure_tx.send(failure).unwrap();
        })
        .unwrap();
        let sender = dispatcher.sender();

        assert_eq!(
            sender.enqueue_coalescing_surface_operation(
                "clear terminal history",
                41,
                false,
                || Err(anyhow::anyhow!("partial fallback write")),
            ),
            PtyInputEnqueueResult::Accepted
        );
        let failure = failure_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(failure.lane_failed);
        assert_eq!(
            sender.enqueue(event(41, 1, PtyInputKind::Ordered)),
            PtyInputEnqueueResult::Failed
        );

        sender.retire_surface(41);

        let state = sender.queue.state.lock().unwrap();
        assert!(!state.failed_lanes.contains(&lane(41)));
        assert!(!state.retired_in_flight_lanes.contains(&lane(41)));
        drop(state);
        assert_eq!(
            sender.enqueue(event(41, 2, PtyInputKind::Ordered)),
            PtyInputEnqueueResult::Accepted
        );
    }

    #[test]
    fn retiring_an_in_flight_surface_prevents_late_lane_quarantine() {
        let (failure_tx, failure_rx) = std::sync::mpsc::channel();
        let dispatcher = PtyInputDispatcher::spawn(move |failure| {
            failure_tx.send(failure).unwrap();
        })
        .unwrap();
        let sender = dispatcher.sender();
        let (finished_tx, finished_rx) = std::sync::mpsc::channel();
        let (resume_tx, resume_rx) = std::sync::mpsc::channel();
        let resume_rx = Arc::new(Mutex::new(resume_rx));
        sender.set_after_operation_before_cleanup(Some(Arc::new(move || {
            finished_tx.send(()).unwrap();
            resume_rx.lock().unwrap().recv().unwrap();
        })));

        assert_eq!(
            sender.enqueue_coalescing_surface_operation(
                "clear terminal history",
                41,
                false,
                || Err(anyhow::anyhow!("partial fallback write")),
            ),
            PtyInputEnqueueResult::Accepted
        );
        finished_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        sender.retire_surface(41);
        resume_tx.send(()).unwrap();
        let failure = failure_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(failure.lane_failed);
        sender.set_after_operation_before_cleanup(None);

        let state = sender.queue.state.lock().unwrap();
        assert!(!state.failed_lanes.contains(&lane(41)));
        assert!(!state.retired_in_flight_lanes.contains(&lane(41)));
        drop(state);
        assert_eq!(
            sender.enqueue(event(41, 2, PtyInputKind::Ordered)),
            PtyInputEnqueueResult::Accepted
        );
    }

    #[test]
    fn blocking_surface_operation_is_a_per_surface_barrier() {
        let dispatcher = PtyInputDispatcher::spawn(|_| {}).unwrap();
        let sender = dispatcher.sender();
        let (started_tx, started_rx) = std::sync::mpsc::channel();
        let (unblock_tx, unblock_rx) = std::sync::mpsc::channel();
        let (same_surface_tx, same_surface_rx) = std::sync::mpsc::channel();
        let (other_surface_tx, other_surface_rx) = std::sync::mpsc::channel();

        assert_eq!(
            sender.enqueue_surface_operation_with_retained_bytes(
                "blocking surface operation",
                41,
                false,
                0,
                move || {
                    started_tx.send(()).unwrap();
                    let _ = unblock_rx.recv();
                    Ok(())
                },
            ),
            PtyInputEnqueueResult::Accepted
        );
        started_rx.recv_timeout(Duration::from_secs(1)).unwrap();

        let mut same_surface = event(41, 1, PtyInputKind::Ordered);
        same_surface.after_operation = Some(Box::new(move || same_surface_tx.send(()).unwrap()));
        assert_eq!(sender.enqueue(same_surface), PtyInputEnqueueResult::Accepted);

        let mut other_surface = event(42, 2, PtyInputKind::Ordered);
        other_surface.after_operation = Some(Box::new(move || other_surface_tx.send(()).unwrap()));
        assert_eq!(sender.enqueue(other_surface), PtyInputEnqueueResult::Accepted);

        other_surface_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(same_surface_rx.recv_timeout(Duration::from_millis(50)).is_err());

        unblock_tx.send(()).unwrap();
        same_surface_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    }

    #[test]
    fn replacement_generation_isolates_a_reused_surface_lane() {
        let (failure_tx, failure_rx) = std::sync::mpsc::channel();
        let mut dispatcher = PtyInputDispatcher::spawn(move |failure| {
            failure_tx.send(failure).unwrap();
        })
        .unwrap();
        let old_sender = dispatcher.sender();
        let (old_started_tx, old_started_rx) = std::sync::mpsc::channel();
        let (old_release_tx, old_release_rx) = std::sync::mpsc::channel();

        assert_eq!(
            old_sender.enqueue_surface_operation_with_retained_bytes(
                "old session operation",
                41,
                false,
                0,
                move || {
                    old_started_tx.send(()).unwrap();
                    old_release_rx.recv().unwrap();
                    Err(anyhow::anyhow!("ambiguous old session completion"))
                },
            ),
            PtyInputEnqueueResult::Accepted
        );
        old_started_rx.recv_timeout(Duration::from_secs(1)).unwrap();

        dispatcher.activate_session_generation(2);
        let new_sender = dispatcher.sender();
        assert_eq!(
            old_sender.enqueue(event(41, 1, PtyInputKind::Ordered)),
            PtyInputEnqueueResult::Failed,
            "a retired session sender remained active"
        );

        let (new_started_tx, new_started_rx) = std::sync::mpsc::channel();
        let (new_release_tx, new_release_rx) = std::sync::mpsc::channel();
        assert_eq!(
            new_sender.enqueue_surface_operation_with_retained_bytes(
                "new session operation",
                41,
                false,
                0,
                move || {
                    new_started_tx.send(()).unwrap();
                    new_release_rx.recv().unwrap();
                    Ok(())
                },
            ),
            PtyInputEnqueueResult::Accepted
        );
        new_started_rx.recv_timeout(Duration::from_secs(1)).unwrap();

        let (follower_tx, follower_rx) = std::sync::mpsc::channel();
        let mut follower = event(41, 2, PtyInputKind::Ordered);
        follower.after_operation = Some(Box::new(move || follower_tx.send(()).unwrap()));
        assert_eq!(new_sender.enqueue(follower), PtyInputEnqueueResult::Accepted);

        old_release_tx.send(()).unwrap();
        let old_failure = failure_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert_eq!(old_failure.session_generation, 1);
        assert!(old_failure.lane_failed);
        assert!(
            follower_rx.recv_timeout(Duration::from_millis(50)).is_err(),
            "new-session input crossed its own surface barrier"
        );

        new_release_tx.send(()).unwrap();
        follower_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(dispatcher.shutdown(Duration::from_secs(1)));
    }

    #[test]
    fn concurrent_surface_operations_respect_worker_cap() {
        const EXPECTED_MAX_CONCURRENT_SURFACE_OPERATIONS: usize = 32;
        let mut state = QueueState::default();
        for surface in 1..=(EXPECTED_MAX_CONCURRENT_SURFACE_OPERATIONS as u64 + 1) {
            state.events.push_back(PtyInputEvent::mutation_for_surface(
                "blocking surface operation",
                PtyMutationIdentity {
                    failure_surface_id: Some(surface),
                    concurrent_surface_operation: true,
                    ..Default::default()
                },
                false,
                None,
                None,
                || Ok(()),
            ));
        }

        for _ in 0..EXPECTED_MAX_CONCURRENT_SURFACE_OPERATIONS {
            assert!(dequeue_ready_event(&mut state).is_some());
        }
        assert!(
            dequeue_ready_event(&mut state).is_none(),
            "surface operation scheduler exceeded its worker cap"
        );
    }

    #[test]
    fn saturated_worker_cap_preserves_the_queued_surface_barrier() {
        let mut state = QueueState::default();
        for surface in 1..=MAX_CONCURRENT_SURFACE_OPERATIONS as u64 {
            state.in_flight_surface_operations.insert(lane(surface), 0);
        }
        state.events.push_back(PtyInputEvent::mutation_for_surface(
            "queued clear history",
            PtyMutationIdentity {
                failure_surface_id: Some(100),
                concurrent_surface_operation: true,
                ..Default::default()
            },
            false,
            None,
            None,
            || Ok(()),
        ));
        state.events.push_back(event(100, 1, PtyInputKind::Ordered));
        state.events.push_back(event(101, 2, PtyInputKind::Ordered));
        state.queued_bytes = state.events.iter().map(PtyInputEvent::queued_byte_len).sum();

        let ready = dequeue_ready_event(&mut state).unwrap();

        assert_eq!(
            ready.ordering_lane(),
            Some(lane(101)),
            "same-surface input overtook the clear blocked on worker capacity"
        );
        assert_eq!(
            state.events.iter().map(PtyInputEvent::ordering_lane).collect::<Vec<_>>(),
            vec![Some(lane(100)), Some(lane(100))]
        );
    }

    #[test]
    fn in_flight_surface_operation_counts_against_byte_budget() {
        let dispatcher = PtyInputDispatcher::spawn(|_| {}).unwrap();
        let sender = dispatcher.sender();
        let (started_tx, started_rx) = std::sync::mpsc::channel();
        let (unblock_tx, unblock_rx) = std::sync::mpsc::channel();

        assert_eq!(
            sender.enqueue_surface_operation_with_retained_bytes(
                "retained surface operation",
                41,
                false,
                MAX_QUEUED_BYTES,
                move || {
                    started_tx.send(()).unwrap();
                    let _ = unblock_rx.recv();
                    Ok(())
                },
            ),
            PtyInputEnqueueResult::Accepted
        );
        started_rx.recv_timeout(Duration::from_secs(1)).unwrap();

        assert_eq!(
            sender.enqueue(event(42, 1, PtyInputKind::Ordered)),
            PtyInputEnqueueResult::Saturated
        );
        unblock_tx.send(()).unwrap();
    }

    #[test]
    fn session_mutation_blocks_later_input_behind_surface_operation() {
        let dispatcher = PtyInputDispatcher::spawn(|_| {}).unwrap();
        let sender = dispatcher.sender();
        let (started_tx, started_rx) = std::sync::mpsc::channel();
        let (unblock_tx, unblock_rx) = std::sync::mpsc::channel();
        let (order_tx, order_rx) = std::sync::mpsc::channel();

        assert_eq!(
            sender.enqueue_surface_operation_with_retained_bytes(
                "blocking surface operation",
                41,
                false,
                0,
                move || {
                    started_tx.send(()).unwrap();
                    let _ = unblock_rx.recv();
                    Ok(())
                },
            ),
            PtyInputEnqueueResult::Accepted
        );
        started_rx.recv_timeout(Duration::from_secs(1)).unwrap();

        let mutation_tx = order_tx.clone();
        sender.enqueue_session_mutation("close pane", false, move || {
            mutation_tx.send("mutation").unwrap();
            Ok(())
        });
        let mut input = event(42, 1, PtyInputKind::Ordered);
        input.after_operation = Some(Box::new(move || order_tx.send("input").unwrap()));
        assert_eq!(sender.enqueue(input), PtyInputEnqueueResult::Accepted);

        assert!(
            order_rx.recv_timeout(Duration::from_millis(50)).is_err(),
            "input overtook the earlier session mutation"
        );
        unblock_tx.send(()).unwrap();
        assert_eq!(order_rx.recv_timeout(Duration::from_secs(1)).unwrap(), "mutation");
        assert_eq!(order_rx.recv_timeout(Duration::from_secs(1)).unwrap(), "input");
    }

    #[test]
    fn timed_out_surface_operation_prunes_only_its_surface() {
        let (failure_tx, failure_rx) = std::sync::mpsc::channel();
        let mut dispatcher = PtyInputDispatcher::spawn(move |failure| {
            let _ = failure_tx.send(failure);
        })
        .unwrap();
        let sender = dispatcher.sender();
        let (started_tx, started_rx) = std::sync::mpsc::channel();
        let (unblock_tx, unblock_rx) = std::sync::mpsc::channel();
        let (same_surface_tx, same_surface_rx) = std::sync::mpsc::channel();
        let (other_surface_tx, other_surface_rx) = std::sync::mpsc::channel();

        assert_eq!(
            sender.enqueue_surface_operation_with_retained_bytes(
                "timed out surface operation",
                41,
                true,
                0,
                move || {
                    started_tx.send(()).unwrap();
                    let _ = unblock_rx.recv();
                    Err(crate::session::test_remote_timeout_error())
                },
            ),
            PtyInputEnqueueResult::Accepted
        );
        started_rx.recv_timeout(Duration::from_secs(1)).unwrap();

        let mut same_surface = event(41, 1, PtyInputKind::Ordered);
        same_surface.remote = true;
        same_surface.after_operation = Some(Box::new(move || same_surface_tx.send(()).unwrap()));
        assert_eq!(sender.enqueue(same_surface), PtyInputEnqueueResult::Accepted);

        let mut other_surface = event(42, 2, PtyInputKind::Ordered);
        other_surface.remote = true;
        other_surface.after_operation = Some(Box::new(move || other_surface_tx.send(()).unwrap()));
        assert_eq!(sender.enqueue(other_surface), PtyInputEnqueueResult::Accepted);

        other_surface_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        unblock_tx.send(()).unwrap();
        assert!(dispatcher.shutdown(Duration::from_secs(1)));
        assert!(same_surface_rx.recv_timeout(Duration::from_millis(50)).is_err());

        let failures = failure_rx.try_iter().collect::<Vec<_>>();
        assert!(failures.iter().any(|failure| {
            failure.surface_id == Some(41)
                && failure.label == "timed out surface operation"
                && failure.delivery == PtyOperationDelivery::Ambiguous
        }));
        assert!(failures.iter().any(|failure| {
            failure.surface_id == Some(41)
                && failure.label == "PTY input"
                && failure.delivery == PtyOperationDelivery::KnownNotDelivered
        }));
        assert!(!failures.iter().any(|failure| {
            failure.surface_id == Some(42)
                && failure.error.contains("canceled after a remote surface request timed out")
        }));
    }

    #[test]
    fn coalescing_mutations_replace_by_key_across_adjacent_resize_work() {
        let mut events = VecDeque::new();
        let mut queued_bytes = 0;
        let mut releases = ReleaseReservations::default();
        for item in [
            PtyInputEvent::mutation("resize one", Some(("resize", 1, 0)), false, || Ok(())),
            PtyInputEvent::mutation("resize two", Some(("resize", 2, 0)), false, || Ok(())),
            PtyInputEvent::mutation("resize one latest", Some(("resize", 1, 0)), false, || Ok(())),
        ] {
            assert!(enqueue_bounded(&mut events, &mut queued_bytes, &mut releases, item, 8, 1024));
        }

        assert_eq!(events.len(), 2);
        assert_eq!(events[0].label, "resize two");
        assert_eq!(events[1].label, "resize one latest");

        assert!(enqueue_bounded(
            &mut events,
            &mut queued_bytes,
            &mut releases,
            event(1, 1, PtyInputKind::Ordered),
            8,
            1024,
        ));
        assert!(enqueue_bounded(
            &mut events,
            &mut queued_bytes,
            &mut releases,
            PtyInputEvent::mutation("resize after input", Some(("resize", 1, 0)), false, || Ok(()),),
            8,
            1024,
        ));
        assert_eq!(events.len(), 4);
    }

    #[test]
    fn retained_mutation_payload_counts_toward_the_byte_limit() {
        let mut events = VecDeque::new();
        let mut queued_bytes = 0;
        let mut releases = ReleaseReservations::default();

        assert!(enqueue_bounded(
            &mut events,
            &mut queued_bytes,
            &mut releases,
            mutation_with_retained_bytes(6),
            8,
            10,
        ));
        assert!(!enqueue_bounded(
            &mut events,
            &mut queued_bytes,
            &mut releases,
            mutation_with_retained_bytes(5),
            8,
            10,
        ));

        assert_eq!(queued_bytes, 6);
        assert_eq!(events.len(), 1);
    }

    #[test]
    fn coalescing_mutations_distinguish_both_subject_ids() {
        let mut events = VecDeque::new();
        let mut queued_bytes = 0;
        let mut releases = ReleaseReservations::default();
        for item in [
            PtyInputEvent::mutation("surface 7 client 1", Some(("sizing", 7, 1)), false, || Ok(())),
            PtyInputEvent::mutation("surface 7 client 2", Some(("sizing", 7, 2)), false, || Ok(())),
            PtyInputEvent::mutation("surface 8 client 1", Some(("sizing", 8, 1)), false, || Ok(())),
            PtyInputEvent::mutation(
                "surface 7 client 1 latest",
                Some(("sizing", 7, 1)),
                false,
                || Ok(()),
            ),
        ] {
            assert!(enqueue_bounded(&mut events, &mut queued_bytes, &mut releases, item, 8, 1024));
        }

        assert_eq!(events.len(), 3);
        assert_eq!(events[0].label, "surface 7 client 2");
        assert_eq!(events[1].label, "surface 8 client 1");
        assert_eq!(events[2].label, "surface 7 client 1 latest");
    }

    #[test]
    fn coalescing_mutation_reports_the_replaced_sample_as_superseded() {
        let mut events = VecDeque::new();
        let mut queued_bytes = 0;
        let mut releases = ReleaseReservations::default();
        let superseded = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let replaced = superseded.clone();
        assert!(enqueue_bounded(
            &mut events,
            &mut queued_bytes,
            &mut releases,
            PtyInputEvent::mutation_with_superseded(
                "resize old",
                Some(("resize", 1, 0)),
                false,
                Some(Box::new(move || {
                    replaced.store(true, std::sync::atomic::Ordering::Release);
                })),
                None,
                || Ok(()),
            ),
            8,
            1024,
        ));
        assert!(enqueue_bounded(
            &mut events,
            &mut queued_bytes,
            &mut releases,
            PtyInputEvent::mutation("resize latest", Some(("resize", 1, 0)), false, || Ok(())),
            8,
            1024,
        ));

        assert!(superseded.load(std::sync::atomic::Ordering::Acquire));
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].label, "resize latest");
    }

    #[test]
    fn rejected_coalescing_replacement_restores_the_previous_sample() {
        let mut events = VecDeque::new();
        let mut queued_bytes = 0;
        let mut releases = ReleaseReservations::default();
        let superseded = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let replaced = superseded.clone();
        let mut previous = PtyInputEvent::mutation_with_superseded(
            "resize old",
            Some(("resize", 1, 0)),
            false,
            Some(Box::new(move || {
                replaced.store(true, std::sync::atomic::Ordering::Release);
            })),
            None,
            || Ok(()),
        );
        previous.bytes = PtyInputBytes::from_slice(&[1]);
        assert!(enqueue_bounded(&mut events, &mut queued_bytes, &mut releases, previous, 8, 1,));

        let mut too_large =
            PtyInputEvent::mutation("resize latest", Some(("resize", 1, 0)), false, || Ok(()));
        too_large.bytes = PtyInputBytes::from_slice(&[2, 3]);
        assert!(!enqueue_bounded(&mut events, &mut queued_bytes, &mut releases, too_large, 8, 1,));

        assert!(!superseded.load(std::sync::atomic::Ordering::Acquire));
        assert_eq!(queued_bytes, 1);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].label, "resize old");
        assert_eq!(events[0].bytes.as_slice(), &[1]);
    }

    #[test]
    fn accepted_press_guarantees_its_release_slot() {
        let mut events = VecDeque::new();
        let mut queued_bytes = 0;
        let mut releases = ReleaseReservations::default();
        assert!(enqueue_bounded(
            &mut events,
            &mut queued_bytes,
            &mut releases,
            event(1, 1, PtyInputKind::Press),
            3,
            1024,
        ));
        assert_eq!(releases.len(), 1);
        assert!(enqueue_bounded(
            &mut events,
            &mut queued_bytes,
            &mut releases,
            event(2, 2, PtyInputKind::Ordered),
            3,
            1024,
        ));
        assert!(!enqueue_bounded(
            &mut events,
            &mut queued_bytes,
            &mut releases,
            event(3, 3, PtyInputKind::Ordered),
            3,
            1024,
        ));
        assert!(enqueue_bounded(
            &mut events,
            &mut queued_bytes,
            &mut releases,
            event(1, 4, PtyInputKind::Release),
            3,
            1024,
        ));
        assert_eq!(releases.len(), 0);
        assert_eq!(events.len(), 3);
        assert_eq!(events.back().unwrap().bytes.as_slice(), &[4]);
    }

    #[test]
    fn failed_consumed_press_does_not_cancel_a_newer_reservation() {
        let mut reservations = ReleaseReservations::default();
        let first = reservations.reserve(lane(7));
        assert!(reservations.consume(lane(7)));
        let second = reservations.reserve(lane(7));

        reservations.outstanding.remove(&first);

        assert_eq!(reservations.len(), 1);
        assert!(reservations.outstanding.contains_key(&second));
    }

    #[test]
    fn release_consumes_only_its_exact_reservation() {
        let mut events = VecDeque::new();
        let mut queued_bytes = 0;
        let mut releases = ReleaseReservations::default();
        assert!(enqueue_bounded(
            &mut events,
            &mut queued_bytes,
            &mut releases,
            event(7, 1, PtyInputKind::Press),
            8,
            1024,
        ));
        let first = releases.next_id;
        assert!(enqueue_bounded(
            &mut events,
            &mut queued_bytes,
            &mut releases,
            event(7, 2, PtyInputKind::Press),
            8,
            1024,
        ));
        let second = releases.next_id;

        let mut release = event(7, 3, PtyInputKind::Release);
        release.reservation_id = Some(first);
        assert!(enqueue_bounded(&mut events, &mut queued_bytes, &mut releases, release, 8, 1024,));

        assert!(!releases.outstanding.contains_key(&first));
        assert_eq!(releases.outstanding.get(&second), Some(&lane(7)));
    }

    #[test]
    fn ordered_batch_respects_byte_budget() {
        let mut events = VecDeque::new();
        let mut queued_bytes = 0;
        let mut releases = ReleaseReservations::default();
        let mut first = event(1, 1, PtyInputKind::Ordered);
        first.bytes = vec![1; 8].into();
        assert!(enqueue_bounded(&mut events, &mut queued_bytes, &mut releases, first, 8, 10,));
        let mut overflow = event(1, 2, PtyInputKind::Ordered);
        overflow.bytes = vec![2; 3].into();
        assert!(!enqueue_bounded(&mut events, &mut queued_bytes, &mut releases, overflow, 8, 10,));
        assert_eq!(queued_bytes, 8);
    }

    #[test]
    fn shutdown_drains_and_joins_the_worker() {
        let mut dispatcher = PtyInputDispatcher::spawn(|_| {}).unwrap();
        assert_eq!(
            dispatcher.enqueue(event(1, 1, PtyInputKind::Ordered)),
            PtyInputEnqueueResult::Accepted
        );
        assert!(dispatcher.shutdown(Duration::from_secs(1)));
    }

    #[test]
    fn shutdown_retains_release_for_worker_behind_in_flight_operation() {
        let queue = Arc::new(SharedQueue::default());
        let released = Arc::new(std::sync::atomic::AtomicBool::new(false));
        {
            let mut state = queue.state.lock().unwrap();
            state.events.push_back(event(1, 1, PtyInputKind::Motion));
            let released_flag = released.clone();
            let mut release = event(1, 2, PtyInputKind::Release);
            release.reservation_id = Some(7);
            release.mutation = Some(Box::new(move || {
                released_flag.store(true, std::sync::atomic::Ordering::Release);
                Ok(())
            }));
            state.events.push_back(release);
            state.queued_bytes = 2;
            state.in_flight =
                Some(InFlightInput { lane: Some(lane(2)), kind: PtyInputKind::Ordered });
        }
        let mut dispatcher = PtyInputDispatcher {
            sender: PtyInputSender {
                queue: queue.clone(),
                on_failure: Arc::new(|_| {}),
                session_generation: 1,
            },
            worker: None,
        };

        assert!(!dispatcher.shutdown(Duration::ZERO));

        let state = queue.state.lock().unwrap();
        assert!(state.closed);
        assert_eq!(state.events.len(), 1);
        assert_eq!(state.queued_bytes, 1);
        assert_eq!(state.release_reservations.len(), 0);
        assert!(!released.load(std::sync::atomic::Ordering::Acquire));
    }

    #[test]
    fn shutdown_waits_for_worker_ordered_release_after_response_wait_is_canceled() {
        let (line_tx, line_rx) = std::sync::mpsc::channel();
        let (cancel_tx, cancel_rx) = std::sync::mpsc::channel();
        let mut dispatcher = PtyInputDispatcher::spawn(|_| {}).unwrap();
        dispatcher.sender().enqueue_session_mutation("in flight", true, move || {
            line_tx.send("request").unwrap();
            cancel_rx.recv().unwrap();
            Ok(())
        });
        assert_eq!(line_rx.recv_timeout(Duration::from_secs(1)).unwrap(), "request");

        let released = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let released_flag = released.clone();
        let mut release = event(1, 2, PtyInputKind::Release);
        release.mutation = Some(Box::new(move || {
            released_flag.store(true, std::sync::atomic::Ordering::Release);
            Ok(())
        }));
        assert_eq!(dispatcher.enqueue(release), PtyInputEnqueueResult::Accepted);

        let shutdown = std::thread::spawn(move || dispatcher.shutdown(Duration::from_secs(1)));
        cancel_tx.send(()).unwrap();
        assert!(shutdown.join().unwrap());
        assert!(released.load(std::sync::atomic::Ordering::Acquire));
    }

    #[test]
    fn shutdown_closes_enqueue_then_drains_accepted_fifo_work() {
        let (started_tx, started_rx) = std::sync::mpsc::channel();
        let (unblock_tx, unblock_rx) = std::sync::mpsc::channel();
        let order = Arc::new(Mutex::new(Vec::new()));
        let mut dispatcher = PtyInputDispatcher::spawn(|_| {}).unwrap();
        let sender = dispatcher.sender();
        let first_order = order.clone();
        sender.enqueue_session_mutation("first", false, move || {
            started_tx.send(()).unwrap();
            unblock_rx.recv().unwrap();
            first_order.lock().unwrap().push(1);
            Ok(())
        });
        started_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        let second_order = order.clone();
        sender.enqueue_session_mutation("second", false, move || {
            second_order.lock().unwrap().push(2);
            Ok(())
        });

        let queue = dispatcher.sender.queue.clone();
        let shutdown = std::thread::spawn(move || dispatcher.shutdown(Duration::from_secs(1)));
        while !queue.state.lock().unwrap().closed {
            std::thread::yield_now();
        }
        assert_eq!(
            sender.enqueue(event(1, 3, PtyInputKind::Ordered)),
            PtyInputEnqueueResult::Saturated
        );
        unblock_tx.send(()).unwrap();

        assert!(shutdown.join().unwrap());
        assert_eq!(*order.lock().unwrap(), vec![1, 2]);
    }

    #[test]
    fn recovery_prune_drops_release_paired_with_a_canceled_queued_press() {
        let mut state = QueueState::default();
        let mut press = event(7, 1, PtyInputKind::Press);
        press.reservation_id = Some(11);
        let mut paired_release = event(7, 2, PtyInputKind::Release);
        paired_release.reservation_id = Some(11);
        let mut ambiguous_release = event(7, 3, PtyInputKind::Release);
        ambiguous_release.reservation_id = Some(12);
        state.events = VecDeque::from([press, paired_release, ambiguous_release]);
        state.queued_bytes = 3;
        state.release_reservations.outstanding.insert(11, lane(7));

        let canceled = prune_to_recovery_releases(&mut state, 1, "timed out");

        assert_eq!(canceled.len(), 2);
        assert_eq!(state.events.len(), 1);
        assert_eq!(state.events[0].reservation_id, Some(12));
        assert_eq!(state.queued_bytes, 1);
        assert!(!state.release_reservations.outstanding.contains_key(&11));
    }

    #[test]
    fn shutdown_timeout_discards_backlog_without_an_in_flight_press() {
        let queue = Arc::new(SharedQueue::default());
        {
            let mut state = queue.state.lock().unwrap();
            state.events.push_back(event(1, 1, PtyInputKind::Ordered));
            state.queued_bytes = 1;
            state.in_flight =
                Some(InFlightInput { lane: Some(lane(1)), kind: PtyInputKind::Ordered });
        }
        let mut dispatcher = PtyInputDispatcher {
            sender: PtyInputSender {
                queue: queue.clone(),
                on_failure: Arc::new(|_| {}),
                session_generation: 1,
            },
            worker: None,
        };

        assert!(!dispatcher.shutdown(Duration::ZERO));

        let state = queue.state.lock().unwrap();
        assert!(state.events.is_empty());
        assert!(state.shutdown_release_drain);
    }

    #[test]
    fn accepted_operation_completes_before_following_mutation_without_blocking_enqueue() {
        let dispatcher = PtyInputDispatcher::spawn(|_| {}).unwrap();
        let sender = dispatcher.sender();
        let mutated = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let (started_tx, started_rx) = std::sync::mpsc::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel();
        sender.enqueue_session_mutation("blocking operation", false, move || {
            started_tx.send(()).unwrap();
            release_rx.recv().unwrap();
            Ok(())
        });
        let mutation = mutated.clone();
        sender.enqueue_session_mutation("following mutation", false, move || {
            mutation.store(true, std::sync::atomic::Ordering::Release);
            Ok(())
        });

        started_rx.recv().unwrap();
        assert!(!mutated.load(std::sync::atomic::Ordering::Acquire));
        release_tx.send(()).unwrap();
        let deadline = Instant::now() + Duration::from_secs(1);
        while !mutated.load(std::sync::atomic::Ordering::Acquire) && Instant::now() < deadline {
            std::thread::yield_now();
        }
        assert!(mutated.load(std::sync::atomic::Ordering::Acquire));
    }

    #[test]
    fn operation_failure_is_reported() {
        let (failure_tx, failure_rx) = std::sync::mpsc::channel();
        let dispatcher = PtyInputDispatcher::spawn(move |failure| {
            failure_tx.send(failure).unwrap();
        })
        .unwrap();

        dispatcher
            .sender()
            .enqueue_session_mutation("close pane", false, || anyhow::bail!("write failed"));

        let failure = failure_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert_eq!(failure.label, "close pane");
        assert_eq!(failure.error, "write failed");
    }

    #[test]
    fn remote_mutation_timeout_is_reported_only_by_its_session_outcome() {
        let (failure_tx, failure_rx) = std::sync::mpsc::channel();
        let dispatcher = PtyInputDispatcher::spawn(move |failure| {
            failure_tx.send(failure).unwrap();
        })
        .unwrap();

        dispatcher.sender().enqueue_session_mutation("timed out mutation", true, || {
            Err(crate::session::test_remote_timeout_error())
        });

        assert!(failure_rx.recv_timeout(Duration::from_millis(100)).is_err());
    }

    #[test]
    fn pty_write_failure_is_reported_with_its_surface() {
        let (failure_tx, failure_rx) = std::sync::mpsc::channel();
        let dispatcher = PtyInputDispatcher::spawn(move |failure| {
            failure_tx.send(failure).unwrap();
        })
        .unwrap();

        assert_eq!(
            dispatcher.enqueue(event(42, 1, PtyInputKind::Ordered)),
            PtyInputEnqueueResult::Accepted
        );

        let failure = failure_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert_eq!(failure.surface_id, Some(42));
        assert_eq!(failure.kind, Some(PtyInputKind::Ordered));
        assert_eq!(failure.label, "PTY input");
        assert!(failure.error.contains("browser surface"));
    }

    #[test]
    fn failed_press_releases_its_reserved_queue_slot() {
        let (failure_tx, failure_rx) = std::sync::mpsc::channel();
        let dispatcher = PtyInputDispatcher::spawn(move |failure| {
            failure_tx.send(failure).unwrap();
        })
        .unwrap();

        assert_eq!(
            dispatcher.enqueue(event(7, 1, PtyInputKind::Press)),
            PtyInputEnqueueResult::Accepted
        );
        let failure = failure_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert_eq!(failure.delivery, PtyOperationDelivery::KnownNotDelivered);
        assert_eq!(dispatcher.sender.queue.state.lock().unwrap().release_reservations.len(), 0);
    }

    #[test]
    fn timed_out_remote_press_keeps_its_release_reservation() {
        let (failure_tx, failure_rx) = std::sync::mpsc::channel();
        let dispatcher = PtyInputDispatcher::spawn(move |failure| {
            failure_tx.send(failure).unwrap();
        })
        .unwrap();
        let mut press = event(7, 1, PtyInputKind::Press);
        press.remote = true;
        press.mutation = Some(Box::new(|| Err(crate::session::test_remote_timeout_error())));

        let (result, reservation_id) = dispatcher.enqueue_with_reservation(press);
        assert_eq!(result, PtyInputEnqueueResult::Accepted);
        assert!(reservation_id.is_some());
        let failure = failure_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert_eq!(failure.delivery, PtyOperationDelivery::Ambiguous);
        assert_eq!(failure.reservation_id, reservation_id);
        assert_eq!(dispatcher.sender.queue.state.lock().unwrap().release_reservations.len(), 1);

        assert_eq!(
            dispatcher.enqueue(event(7, 2, PtyInputKind::Release)),
            PtyInputEnqueueResult::Accepted
        );
        assert_eq!(dispatcher.sender.queue.state.lock().unwrap().release_reservations.len(), 0);
    }

    #[test]
    fn ambiguous_local_press_keeps_its_recovery_release_reservation() {
        let (failure_tx, failure_rx) = std::sync::mpsc::channel();
        let mut dispatcher = PtyInputDispatcher::spawn(move |failure| {
            failure_tx.send(failure).unwrap();
        })
        .unwrap();
        let mux = cmux_tui_core::Mux::new(
            "ambiguous-local-press-recovery-test",
            cmux_tui_core::SurfaceOptions::default(),
        );
        let surface = mux.new_workspace(None, Some((20, 8))).unwrap();
        let handle = SurfaceHandle::Local(surface.clone(), mux.clone());
        let mut press = PtyInputEvent::input(
            surface.id,
            handle.clone(),
            PtyInputBytes::from_slice(b"press"),
            PtyInputKind::Press,
        );
        press.mutation = Some(Box::new(|| Err(anyhow::anyhow!("flush failed"))));

        let (result, reservation_id) = dispatcher.enqueue_with_reservation(press);
        assert_eq!(result, PtyInputEnqueueResult::Accepted);
        let reservation_id = reservation_id.unwrap();
        let failure = failure_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert_eq!(failure.delivery, PtyOperationDelivery::Ambiguous);
        assert!(failure.lane_failed);
        assert_eq!(failure.reservation_id, Some(reservation_id));

        assert_eq!(
            dispatcher.enqueue(PtyInputEvent::release(
                surface.id,
                handle,
                PtyInputBytes::from_slice(b"release"),
                reservation_id,
            )),
            PtyInputEnqueueResult::Accepted,
            "lane quarantine rejected the matching recovery release"
        );
        assert!(dispatcher.shutdown(Duration::from_secs(1)));
        mux.close_surface(surface.id).unwrap();
    }

    #[test]
    fn ambiguous_release_is_retained_for_retry() {
        let mut state = QueueState::default();
        let mut release = event(7, 3, PtyInputKind::Release);
        release.reservation_id = Some(11);

        requeue_ambiguous_release(&mut state, release);

        assert_eq!(state.queued_bytes, 1);
        assert_eq!(state.events.len(), 1);
        assert_eq!(state.events[0].kind, PtyInputKind::Release);
        assert_eq!(state.events[0].reservation_id, Some(11));
    }

    #[test]
    fn remote_transport_failure_cancels_backlog_and_rejects_later_operations() {
        let (failure_tx, failure_rx) = std::sync::mpsc::channel();
        let dispatcher = PtyInputDispatcher::spawn(move |failure| {
            failure_tx.send(failure).unwrap();
        })
        .unwrap();
        let sender = dispatcher.sender();
        let ran = Arc::new(std::sync::atomic::AtomicBool::new(false));

        sender.enqueue_session_mutation("remote input", true, || {
            Err(crate::session::test_remote_transport_error())
        });
        let follower_ran = ran.clone();
        sender.enqueue_session_mutation("queued close", true, move || {
            follower_ran.store(true, std::sync::atomic::Ordering::Release);
            Ok(())
        });

        let first = failure_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        let second = failure_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!([first.label, second.label].contains(&"remote input"));
        assert!([first.label, second.label].contains(&"queued close"));
        assert!(first.lane_failed);
        assert!(second.lane_failed);
        let remote_failure =
            [&first, &second].into_iter().find(|failure| failure.label == "remote input").unwrap();
        let canceled_failure =
            [&first, &second].into_iter().find(|failure| failure.label == "queued close").unwrap();
        assert_eq!(remote_failure.delivery, PtyOperationDelivery::Ambiguous);
        assert_eq!(canceled_failure.delivery, PtyOperationDelivery::KnownNotDelivered);
        assert!(!ran.load(std::sync::atomic::Ordering::Acquire));

        sender.enqueue_session_mutation("later resize", true, || Ok(()));
        let later = failure_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert_eq!(later.label, "later resize");
        assert!(later.error.contains("unavailable"));
        assert!(later.lane_failed);
    }

    #[test]
    fn remote_timeout_cancels_stale_backlog_but_allows_recovery() {
        let (failure_tx, failure_rx) = std::sync::mpsc::channel();
        let dispatcher = PtyInputDispatcher::spawn(move |failure| {
            failure_tx.send(failure).unwrap();
        })
        .unwrap();
        let sender = dispatcher.sender();
        let stale_ran = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let recovered = Arc::new(std::sync::atomic::AtomicBool::new(false));

        sender.enqueue_session_mutation("timed out request", true, || {
            Err(crate::session::test_remote_timeout_error())
        });
        let stale = stale_ran.clone();
        sender.enqueue_session_mutation("stale queued request", true, move || {
            stale.store(true, std::sync::atomic::Ordering::Release);
            Ok(())
        });

        let canceled = failure_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert_eq!(canceled.label, "stale queued request");
        assert!(!canceled.lane_failed);
        assert!(failure_rx.try_recv().is_err());
        assert!(!stale_ran.load(std::sync::atomic::Ordering::Acquire));

        let recovery = recovered.clone();
        sender.enqueue_session_mutation("recovery request", true, move || {
            recovery.store(true, std::sync::atomic::Ordering::Release);
            Ok(())
        });
        let deadline = Instant::now() + Duration::from_secs(1);
        while !recovered.load(std::sync::atomic::Ordering::Acquire) && Instant::now() < deadline {
            std::thread::yield_now();
        }
        assert!(recovered.load(std::sync::atomic::Ordering::Acquire));
    }

    #[test]
    fn remote_surface_timeout_quarantines_only_its_lane() {
        let (failure_tx, failure_rx) = std::sync::mpsc::channel();
        let dispatcher = PtyInputDispatcher::spawn(move |failure| {
            failure_tx.send(failure).unwrap();
        })
        .unwrap();
        let sender = dispatcher.sender();

        assert_eq!(
            sender.enqueue_surface_operation_with_retained_bytes(
                "timed out clear",
                41,
                true,
                0,
                || Err(crate::session::test_remote_timeout_error()),
            ),
            PtyInputEnqueueResult::Accepted
        );
        let failure = failure_rx.recv_timeout(Duration::from_secs(1)).unwrap();

        assert_eq!(failure.surface_id, Some(41));
        assert_eq!(failure.delivery, PtyOperationDelivery::Ambiguous);
        assert!(failure.lane_failed);
        assert_eq!(
            sender.enqueue(event(41, 1, PtyInputKind::Ordered)),
            PtyInputEnqueueResult::Failed,
            "same-surface input entered a lane with an ambiguous timeout"
        );
        assert_eq!(
            sender.enqueue(event(42, 2, PtyInputKind::Ordered)),
            PtyInputEnqueueResult::Accepted,
            "an unrelated surface was quarantined"
        );
    }

    #[test]
    fn remote_command_rejection_keeps_the_operation_lane_available() {
        let (failure_tx, failure_rx) = std::sync::mpsc::channel();
        let dispatcher = PtyInputDispatcher::spawn(move |failure| {
            failure_tx.send(failure).unwrap();
        })
        .unwrap();
        let sender = dispatcher.sender();
        let ran = Arc::new(std::sync::atomic::AtomicBool::new(false));

        sender.enqueue_session_mutation("invalid remote command", true, || {
            Err(crate::session::test_remote_rejected_error())
        });
        let follower_ran = ran.clone();
        sender.enqueue_session_mutation("following operation", true, move || {
            follower_ran.store(true, std::sync::atomic::Ordering::Release);
            Ok(())
        });

        let failure = failure_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert_eq!(failure.label, "invalid remote command");
        assert!(!failure.lane_failed);
        assert_eq!(failure.delivery, PtyOperationDelivery::Ambiguous);
        let deadline = Instant::now() + Duration::from_secs(1);
        while !ran.load(std::sync::atomic::Ordering::Acquire) && Instant::now() < deadline {
            std::thread::yield_now();
        }
        assert!(ran.load(std::sync::atomic::Ordering::Acquire));
    }

    #[test]
    fn oversized_input_is_distinguished_from_queue_saturation() {
        let dispatcher = PtyInputDispatcher::spawn(|_| {}).unwrap();
        let mut oversized = event(1, 1, PtyInputKind::Ordered);
        oversized.bytes = vec![1; MAX_QUEUED_BYTES + 1].into();

        assert_eq!(dispatcher.enqueue(oversized), PtyInputEnqueueResult::Oversized);
    }
}
