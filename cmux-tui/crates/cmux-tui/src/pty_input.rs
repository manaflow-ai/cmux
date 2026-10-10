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
    error.downcast_ref::<KnownNotDeliveredOperationError>().map_or(error, |marked| &marked.error)
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
        event.surface.write_bytes(&event.bytes)
    };
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
    // A retire_surface during the failure report above saw this operation in
    // flight and marked its lane. Once nothing on the lane is in flight, no
    // late quarantine can come, so the mark goes too.
    if let Some(lane) = ordering_lane
        && state.in_flight.is_none_or(|input| input.lane != Some(lane))
        && !state.in_flight_surface_operations.contains_key(&lane)
    {
        state.retired_in_flight_lanes.remove(&lane);
    }
    queue.changed.notify_all();
    drop(state);
    // Completion is a barrier: publish only after timeout pruning,
    // in-flight ownership, and failure delivery have all settled.
    if let Some(after_operation) = after_operation {
        after_operation();
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
