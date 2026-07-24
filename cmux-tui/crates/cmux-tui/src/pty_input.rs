//! Ordered, off-loop PTY input forwarding.
//!
//! All PTY bytes use one lane so local writer locks and remote control-socket
//! responses cannot block the UI. Consecutive byte-stream writes are batched,
//! motion is coalesced, and every accepted mouse press reserves its release
//! capacity.

use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use cmux_tui_core::{SurfaceId, SurfaceKind};
use smallvec::SmallVec;

use crate::session::{SurfaceHandle, is_remote_timeout, is_remote_transport_failure};

const QUEUE_CAPACITY: usize = 512;
const MAX_QUEUED_BYTES: usize = 4 * 1024 * 1024;
const RESERVED_RELEASE_BYTES: usize = 64;
const REMOTE_RELEASE_MAX_ATTEMPTS: u8 = 3;

pub type PtyInputBytes = SmallVec<[u8; 64]>;

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

pub struct PtyInputEvent {
    pub surface_id: SurfaceId,
    pub surface: SurfaceHandle,
    pub bytes: PtyInputBytes,
    pub kind: PtyInputKind,
    mutation: Option<Box<dyn FnOnce() -> anyhow::Result<()> + Send>>,
    after_operation: Option<Box<dyn FnOnce() + Send>>,
    on_superseded: Option<Box<dyn FnOnce() + Send>>,
    label: &'static str,
    coalesce_key: Option<(&'static str, u64)>,
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
            surface_id,
            surface,
            bytes,
            kind,
            mutation: None,
            after_operation: None,
            on_superseded: None,
            label: "PTY input",
            coalesce_key: None,
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
    fn mutation(
        label: &'static str,
        coalesce_key: Option<(&'static str, u64)>,
        remote: bool,
        operation: impl FnOnce() -> anyhow::Result<()> + Send + 'static,
    ) -> Self {
        Self::mutation_with_superseded(label, coalesce_key, remote, None, None, operation)
    }

    fn mutation_with_superseded(
        label: &'static str,
        coalesce_key: Option<(&'static str, u64)>,
        remote: bool,
        on_superseded: Option<Box<dyn FnOnce() + Send>>,
        after_operation: Option<Box<dyn FnOnce() + Send>>,
        operation: impl FnOnce() -> anyhow::Result<()> + Send + 'static,
    ) -> Self {
        Self {
            surface_id: 0,
            surface: SurfaceHandle::RemoteBrowserUnsupported,
            bytes: PtyInputBytes::new(),
            kind: PtyInputKind::Mutation,
            mutation: Some(Box::new(operation)),
            after_operation,
            on_superseded,
            label,
            coalesce_key,
            remote,
            reservation_id: None,
            remote_release_attempts: 0,
        }
    }
}

#[derive(Debug, Clone)]
pub struct PtyOperationFailure {
    pub surface_id: Option<SurfaceId>,
    pub kind: Option<PtyInputKind>,
    pub reservation_id: Option<u64>,
    pub label: &'static str,
    pub error: String,
    pub lane_failed: bool,
    pub delivery: PtyOperationDelivery,
}

#[derive(Default)]
struct QueueState {
    events: VecDeque<PtyInputEvent>,
    queued_bytes: usize,
    release_reservations: ReleaseReservations,
    in_flight: Option<InFlightInput>,
    closed: bool,
    remote_failed: bool,
    shutdown_release_drain: bool,
}

#[derive(Default)]
struct ReleaseReservations {
    next_id: u64,
    outstanding: HashMap<u64, SurfaceId>,
}

impl ReleaseReservations {
    fn len(&self) -> usize {
        self.outstanding.len()
    }

    fn reserve(&mut self, surface_id: SurfaceId) -> u64 {
        self.next_id = self.next_id.wrapping_add(1);
        let id = self.next_id;
        self.outstanding.insert(id, surface_id);
        id
    }

    fn consume(&mut self, surface_id: SurfaceId) -> bool {
        let id = self
            .outstanding
            .iter()
            .filter_map(|(id, surface)| (*surface == surface_id).then_some(*id))
            .min();
        id.is_some_and(|id| self.outstanding.remove(&id).is_some())
    }

    fn consume_id(&mut self, reservation_id: u64, surface_id: SurfaceId) -> bool {
        if self.outstanding.get(&reservation_id) != Some(&surface_id) {
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
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct InFlightInput {
    surface_id: SurfaceId,
    kind: PtyInputKind,
}

#[derive(Default)]
struct SharedQueue {
    state: Mutex<QueueState>,
    changed: Condvar,
    #[cfg(test)]
    after_operation_before_cleanup: Mutex<Option<Arc<dyn Fn() + Send + Sync>>>,
}

pub struct PtyInputDispatcher {
    sender: PtyInputSender,
    worker: Option<JoinHandle<()>>,
}

#[derive(Clone)]
pub struct PtyInputSender {
    queue: Arc<SharedQueue>,
    on_failure: Arc<dyn Fn(PtyOperationFailure) + Send + Sync>,
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
        Ok(Self { sender: PtyInputSender { queue, on_failure }, worker: Some(worker) })
    }

    #[cfg(test)]
    pub fn enqueue(&self, event: PtyInputEvent) -> PtyInputEnqueueResult {
        self.sender.enqueue(event)
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
        while (!state.events.is_empty() || state.in_flight.is_some()) && Instant::now() < deadline {
            let remaining = deadline.saturating_duration_since(Instant::now());
            let (next, _) = self.sender.queue.changed.wait_timeout(state, remaining).unwrap();
            state = next;
        }
        let drained = state.events.is_empty() && state.in_flight.is_none();
        let canceled = if drained {
            Vec::new()
        } else {
            state.shutdown_release_drain = true;
            let canceled = prune_to_recovery_releases(
                &mut state,
                "canceled after the shutdown drain timed out",
            );
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
    #[cfg(test)]
    pub fn set_after_operation_before_cleanup(&self, hook: Option<Arc<dyn Fn() + Send + Sync>>) {
        *self.queue.after_operation_before_cleanup.lock().unwrap() = hook;
    }

    pub fn enqueue(&self, event: PtyInputEvent) -> PtyInputEnqueueResult {
        self.enqueue_with_reservation(event).0
    }

    fn enqueue_with_reservation(
        &self,
        event: PtyInputEvent,
    ) -> (PtyInputEnqueueResult, Option<u64>) {
        let mut state = self.queue.state.lock().unwrap();
        if state.closed {
            return (PtyInputEnqueueResult::Saturated, None);
        }
        if state.remote_failed && event.remote {
            return (PtyInputEnqueueResult::Failed, None);
        }
        if event.bytes.len() > MAX_QUEUED_BYTES {
            return (PtyInputEnqueueResult::Oversized, None);
        }
        let reserves_release = event.kind == PtyInputKind::Press;
        let QueueState { events, queued_bytes, release_reservations, .. } = &mut *state;
        let outcome = enqueue_bounded_with_evictions(
            events,
            queued_bytes,
            release_reservations,
            event,
            QUEUE_CAPACITY,
            MAX_QUEUED_BYTES,
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

    #[cfg(test)]
    pub fn enqueue_session_mutation(
        &self,
        label: &'static str,
        remote: bool,
        operation: impl FnOnce() -> anyhow::Result<()> + Send + 'static,
    ) {
        let _ = self.enqueue_mutation_with_key(label, None, remote, None, None, operation);
    }

    pub fn enqueue_session_mutation_with_settlement(
        &self,
        label: &'static str,
        remote: bool,
        after_operation: impl FnOnce() + Send + 'static,
        operation: impl FnOnce() -> anyhow::Result<()> + Send + 'static,
    ) {
        let _ = self.enqueue_mutation_with_key(
            label,
            None,
            remote,
            None,
            Some(Box::new(after_operation)),
            operation,
        );
    }

    pub fn enqueue_coalescing_mutation_with_settlement(
        &self,
        label: &'static str,
        key: (&'static str, u64),
        remote: bool,
        on_superseded: impl FnOnce() + Send + 'static,
        after_operation: impl FnOnce() + Send + 'static,
        operation: impl FnOnce() -> anyhow::Result<()> + Send + 'static,
    ) -> PtyInputEnqueueResult {
        self.enqueue_mutation_with_key(
            label,
            Some(key),
            remote,
            Some(Box::new(on_superseded)),
            Some(Box::new(after_operation)),
            operation,
        )
    }

    fn enqueue_mutation_with_key(
        &self,
        label: &'static str,
        key: Option<(&'static str, u64)>,
        remote: bool,
        on_superseded: Option<Box<dyn FnOnce() + Send>>,
        after_operation: Option<Box<dyn FnOnce() + Send>>,
        operation: impl FnOnce() -> anyhow::Result<()> + Send + 'static,
    ) -> PtyInputEnqueueResult {
        let result = self.enqueue(PtyInputEvent::mutation_with_superseded(
            label,
            key,
            remote,
            on_superseded,
            after_operation,
            operation,
        ));
        if result != PtyInputEnqueueResult::Accepted {
            (self.on_failure)(PtyOperationFailure {
                surface_id: None,
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
            if events[index].coalesce_key == Some(key) {
                let previous = events.remove(index).unwrap();
                *queued_bytes = queued_bytes.saturating_sub(previous.bytes.len());
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
            previous.kind == PtyInputKind::Motion && previous.surface_id == event.surface_id
        })
    {
        let previous_len = events.back().unwrap().bytes.len();
        let projected_bytes = queued_bytes.saturating_sub(previous_len)
            + event.bytes.len()
            + release_reservations.len() * RESERVED_RELEASE_BYTES;
        if projected_bytes > max_bytes {
            if let Some((index, previous)) = replaced.take() {
                *queued_bytes += previous.bytes.len();
                events.insert(index, previous);
            }
            return BoundedEnqueueOutcome { accepted: false, evicted, superseded: None };
        }
        *queued_bytes = queued_bytes.saturating_sub(previous_len) + event.bytes.len();
        *events.back_mut().unwrap() = event;
        let superseded = replaced.as_mut().and_then(|(_, previous)| previous.on_superseded.take());
        return BoundedEnqueueOutcome { accepted: true, evicted, superseded };
    }

    let merge_stream = event.kind == PtyInputKind::Ordered
        && events.back().is_some_and(|previous| {
            previous.kind == PtyInputKind::Ordered && previous.surface_id == event.surface_id
        });
    let consumes_reservation = event.kind == PtyInputKind::Release
        && match event.reservation_id {
            Some(reservation_id) => {
                release_reservations.outstanding.get(&reservation_id) == Some(&event.surface_id)
            }
            None => release_reservations
                .outstanding
                .values()
                .any(|surface| *surface == event.surface_id),
        };
    let mut projected = events.len()
        + release_reservations.len()
        + usize::from(!merge_stream)
        + usize::from(event.kind == PtyInputKind::Press);
    if consumes_reservation {
        projected -= 1;
    }
    let mut projected_bytes = *queued_bytes
        + event.bytes.len()
        + (release_reservations.len() + usize::from(event.kind == PtyInputKind::Press))
            * RESERVED_RELEASE_BYTES;
    if consumes_reservation {
        projected_bytes = projected_bytes.saturating_sub(RESERVED_RELEASE_BYTES);
    }
    while projected > capacity || projected_bytes > max_bytes {
        let Some(index) = events.iter().position(|queued| queued.kind == PtyInputKind::Motion)
        else {
            if let Some((index, previous)) = replaced.take() {
                *queued_bytes += previous.bytes.len();
                events.insert(index, previous);
            }
            return BoundedEnqueueOutcome { accepted: false, evicted, superseded: None };
        };
        let removed = events.remove(index).unwrap();
        *queued_bytes = queued_bytes.saturating_sub(removed.bytes.len());
        projected -= 1;
        projected_bytes = projected_bytes.saturating_sub(removed.bytes.len());
        evicted.push(PtyOperationFailure {
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
        event.reservation_id = Some(release_reservations.reserve(event.surface_id));
    } else if consumes_reservation {
        if let Some(reservation_id) = event.reservation_id {
            release_reservations.consume_id(reservation_id, event.surface_id);
        } else {
            release_reservations.consume(event.surface_id);
        }
    }

    if merge_stream {
        *queued_bytes += event.bytes.len();
        events.back_mut().unwrap().bytes.extend_from_slice(&event.bytes);
    } else {
        *queued_bytes += event.bytes.len();
        events.push_back(event);
    }
    let superseded = replaced.as_mut().and_then(|(_, previous)| previous.on_superseded.take());
    BoundedEnqueueOutcome { accepted: true, evicted, superseded }
}

fn worker(queue: Arc<SharedQueue>, on_failure: Arc<dyn Fn(PtyOperationFailure) + Send + Sync>) {
    loop {
        let mut event = {
            let mut state = queue.state.lock().unwrap();
            while state.events.is_empty() && !state.closed {
                state = queue.changed.wait(state).unwrap();
            }
            if state.events.is_empty() && state.closed {
                return;
            }
            let event = state.events.pop_front().unwrap();
            state.in_flight =
                Some(InFlightInput { surface_id: event.surface_id, kind: event.kind });
            state.queued_bytes = state.queued_bytes.saturating_sub(event.bytes.len());
            event
        };
        let kind = (event.kind != PtyInputKind::Mutation).then_some(event.kind);
        let surface_id = kind.map(|_| event.surface_id);
        let remote = event.remote;
        let reservation_id = event.reservation_id;
        if remote && event.kind == PtyInputKind::Release {
            event.remote_release_attempts = event.remote_release_attempts.saturating_add(1);
        }
        let after_operation = event.after_operation.take();
        let result = if let Some(operation) = event.mutation.take() {
            operation()
        } else {
            event.surface.write_bytes(&event.bytes)
        };
        #[cfg(test)]
        let before_cleanup = queue.after_operation_before_cleanup.lock().unwrap().clone();
        #[cfg(test)]
        if let Some(before_cleanup) = before_cleanup {
            before_cleanup();
        }
        let remote_transport_failed =
            remote && result.as_ref().err().is_some_and(is_remote_transport_failure);
        let remote_timed_out = remote && result.as_ref().err().is_some_and(is_remote_timeout);
        // Remote writes are newline framed, so a transport write error cannot
        // have delivered a complete command. A response timeout or rejection
        // can follow a PTY write that already executed. Local PTY errors can
        // likewise occur while flushing after bytes were written.
        let known_not_delivered =
            remote_transport_failed || (!remote && event.surface.kind() == SurfaceKind::Browser);
        let suppress_mutation_timeout = remote_timed_out && event.kind == PtyInputKind::Mutation;
        let ambiguous_release = remote_timed_out && event.kind == PtyInputKind::Release;
        let retry_ambiguous_release =
            ambiguous_release && event.remote_release_attempts < REMOTE_RELEASE_MAX_ATTEMPTS;
        let exhausted_ambiguous_release = ambiguous_release && !retry_ambiguous_release;
        let failure = result.err().and_then(|error| {
            (!suppress_mutation_timeout && !retry_ambiguous_release).then(|| PtyOperationFailure {
                surface_id,
                kind,
                reservation_id,
                label: event.label,
                error: if exhausted_ambiguous_release {
                    format!(
                        "mouse release timed out after {REMOTE_RELEASE_MAX_ATTEMPTS} attempts; detach and reconnect before sending more input"
                    )
                } else {
                    error.to_string()
                },
                lane_failed: remote_transport_failed || exhausted_ambiguous_release,
                delivery: if known_not_delivered {
                    PtyOperationDelivery::KnownNotDelivered
                } else {
                    PtyOperationDelivery::Ambiguous
                },
            })
        });
        let mut state = queue.state.lock().unwrap();
        let mut canceled = Vec::new();
        if failure
            .as_ref()
            .is_some_and(|failure| failure.delivery == PtyOperationDelivery::KnownNotDelivered)
            && kind == Some(PtyInputKind::Press)
            && let Some(reservation_id) = reservation_id
        {
            state.release_reservations.outstanding.remove(&reservation_id);
        }
        if remote_transport_failed || exhausted_ambiguous_release {
            // One dispatcher belongs to one local or remote App session. A
            // A failed socket write means every queued remote request shares
            // the same dead transport, so cancel the backlog immediately.
            state.remote_failed = true;
            canceled.extend(state.events.drain(..).map(|event| PtyOperationFailure {
                surface_id: (event.kind != PtyInputKind::Mutation).then_some(event.surface_id),
                kind: (event.kind != PtyInputKind::Mutation).then_some(event.kind),
                reservation_id: event.reservation_id,
                label: event.label,
                error: if exhausted_ambiguous_release {
                    "canceled after mouse release recovery timed out; detach and reconnect".into()
                } else {
                    "canceled after the remote transport failed".into()
                },
                lane_failed: true,
                delivery: PtyOperationDelivery::KnownNotDelivered,
            }));
            state.queued_bytes = 0;
            state.release_reservations.clear();
        } else if remote_timed_out {
            // A timeout does not prove the socket is dead. Drop stale queued
            // work so one stalled request cannot multiply into minutes of
            // latency, but retain releases that may balance a press already
            // executed by the remote server.
            if retry_ambiguous_release && (!state.closed || state.shutdown_release_drain) {
                requeue_ambiguous_release(&mut state, event);
            }
            canceled.extend(prune_to_recovery_releases(
                &mut state,
                "canceled after a remote request timed out",
            ));
        }
        state.in_flight = None;
        queue.changed.notify_all();
        drop(state);
        if let Some(failure) = failure {
            on_failure(failure);
        }
        for failure in canceled {
            on_failure(failure);
        }
        // Completion is a barrier: publish only after timeout pruning,
        // in-flight ownership, and failure delivery have all settled.
        if let Some(after_operation) = after_operation {
            after_operation();
        }
    }
}

fn requeue_ambiguous_release(state: &mut QueueState, event: PtyInputEvent) {
    debug_assert_eq!(event.kind, PtyInputKind::Release);
    state.queued_bytes += event.bytes.len();
    state.events.push_front(event);
}

fn prune_to_recovery_releases(
    state: &mut QueueState,
    error: &'static str,
) -> Vec<PtyOperationFailure> {
    let canceled_press_reservations = state
        .events
        .iter()
        .filter(|event| event.kind == PtyInputKind::Press)
        .filter_map(|event| event.reservation_id)
        .collect::<HashSet<_>>();
    let mut releases = VecDeque::new();
    let mut canceled = Vec::new();
    for event in state.events.drain(..) {
        let retain_release = event.kind == PtyInputKind::Release
            && event.reservation_id.is_some_and(|id| !canceled_press_reservations.contains(&id));
        if retain_release {
            releases.push_back(event);
            continue;
        }
        if event.kind == PtyInputKind::Press
            && let Some(reservation_id) = event.reservation_id
        {
            state.release_reservations.outstanding.remove(&reservation_id);
        }
        canceled.push(PtyOperationFailure {
            surface_id: (event.kind != PtyInputKind::Mutation).then_some(event.surface_id),
            kind: (event.kind != PtyInputKind::Mutation).then_some(event.kind),
            reservation_id: event.reservation_id,
            label: event.label,
            error: error.into(),
            lane_failed: false,
            delivery: PtyOperationDelivery::KnownNotDelivered,
        });
    }
    state.queued_bytes = releases.iter().map(|event| event.bytes.len()).sum();
    state.events = releases;
    canceled
}

#[cfg(test)]
mod tests {
    use super::*;

    fn event(surface_id: SurfaceId, bytes: u8, kind: PtyInputKind) -> PtyInputEvent {
        PtyInputEvent::input(
            surface_id,
            SurfaceHandle::RemoteBrowserUnsupported,
            SmallVec::from_slice(&[bytes]),
            kind,
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
        for _ in 0..QUEUE_CAPACITY - 1 {
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
    fn coalescing_mutations_replace_by_key_across_adjacent_resize_work() {
        let mut events = VecDeque::new();
        let mut queued_bytes = 0;
        let mut releases = ReleaseReservations::default();
        for item in [
            PtyInputEvent::mutation("resize one", Some(("resize", 1)), false, || Ok(())),
            PtyInputEvent::mutation("resize two", Some(("resize", 2)), false, || Ok(())),
            PtyInputEvent::mutation("resize one latest", Some(("resize", 1)), false, || Ok(())),
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
            PtyInputEvent::mutation("resize after input", Some(("resize", 1)), false, || Ok(())),
            8,
            1024,
        ));
        assert_eq!(events.len(), 4);
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
                Some(("resize", 1)),
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
            PtyInputEvent::mutation("resize latest", Some(("resize", 1)), false, || Ok(())),
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
            Some(("resize", 1)),
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
            PtyInputEvent::mutation("resize latest", Some(("resize", 1)), false, || Ok(()));
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
        let first = reservations.reserve(7);
        assert!(reservations.consume(7));
        let second = reservations.reserve(7);

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
        assert_eq!(releases.outstanding.get(&second), Some(&7));
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
            state.in_flight = Some(InFlightInput { surface_id: 2, kind: PtyInputKind::Ordered });
        }
        let mut dispatcher = PtyInputDispatcher {
            sender: PtyInputSender { queue: queue.clone(), on_failure: Arc::new(|_| {}) },
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
        state.release_reservations.outstanding.insert(11, 7);

        let canceled = prune_to_recovery_releases(&mut state, "timed out");

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
            state.in_flight = Some(InFlightInput { surface_id: 1, kind: PtyInputKind::Ordered });
        }
        let mut dispatcher = PtyInputDispatcher {
            sender: PtyInputSender { queue: queue.clone(), on_failure: Arc::new(|_| {}) },
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
        assert_eq!(first.delivery, PtyOperationDelivery::KnownNotDelivered);
        assert_eq!(second.delivery, PtyOperationDelivery::KnownNotDelivered);
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
