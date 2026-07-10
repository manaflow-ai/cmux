//! Ordered, off-loop PTY input forwarding.
//!
//! All PTY bytes use one lane so local writer locks and remote control-socket
//! responses cannot block the UI. Consecutive byte-stream writes are batched,
//! motion is coalesced, and every accepted mouse press reserves its release
//! capacity.

use std::collections::VecDeque;
use std::sync::{Arc, Condvar, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use cmux_tui_core::SurfaceId;
use smallvec::SmallVec;

use crate::session::{SurfaceHandle, is_remote_transport_failure};

const QUEUE_CAPACITY: usize = 512;
const MAX_QUEUED_BYTES: usize = 4 * 1024 * 1024;
const RESERVED_RELEASE_BYTES: usize = 64;

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

pub struct PtyInputEvent {
    pub surface_id: SurfaceId,
    pub surface: SurfaceHandle,
    pub bytes: PtyInputBytes,
    pub kind: PtyInputKind,
    mutation: Option<Box<dyn FnOnce() -> anyhow::Result<()> + Send>>,
    label: &'static str,
    coalesce_key: Option<(&'static str, u64)>,
    remote: bool,
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
            label: "PTY input",
            coalesce_key: None,
            remote,
        }
    }

    fn mutation(
        label: &'static str,
        coalesce_key: Option<(&'static str, u64)>,
        remote: bool,
        operation: impl FnOnce() -> anyhow::Result<()> + Send + 'static,
    ) -> Self {
        Self {
            surface_id: 0,
            surface: SurfaceHandle::RemoteBrowserUnsupported,
            bytes: PtyInputBytes::new(),
            kind: PtyInputKind::Mutation,
            mutation: Some(Box::new(operation)),
            label,
            coalesce_key,
            remote,
        }
    }
}

#[derive(Debug, Clone)]
pub struct PtyOperationFailure {
    pub surface_id: Option<SurfaceId>,
    pub kind: Option<PtyInputKind>,
    pub label: &'static str,
    pub error: String,
    pub lane_failed: bool,
}

#[derive(Default)]
struct QueueState {
    events: VecDeque<PtyInputEvent>,
    queued_bytes: usize,
    release_reservations: usize,
    in_flight: Option<InFlightInput>,
    closed: bool,
    remote_failed: bool,
    shutdown_release_drain: bool,
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

    pub fn enqueue(&self, event: PtyInputEvent) -> PtyInputEnqueueResult {
        self.sender.enqueue(event)
    }

    pub fn sender(&self) -> PtyInputSender {
        self.sender.clone()
    }

    pub fn cancel_release_reservation(&self) {
        self.sender.cancel_release_reservation();
    }

    /// Drain queued writes during detach/normal shutdown, bounded so a
    /// half-open remote session cannot hang terminal restoration forever.
    pub fn shutdown(&mut self, timeout: Duration) -> bool {
        let deadline = Instant::now() + timeout;
        let mut state = self.sender.queue.state.lock().unwrap();
        while (!state.events.is_empty() || state.in_flight.is_some()) && Instant::now() < deadline {
            let remaining = deadline.saturating_duration_since(Instant::now());
            let (next, _) = self.sender.queue.changed.wait_timeout(state, remaining).unwrap();
            state = next;
        }
        let drained = state.events.is_empty() && state.in_flight.is_none();
        state.closed = true;
        if !drained {
            let release = state
                .in_flight
                .filter(|input| input.kind == PtyInputKind::Press)
                .and_then(|input| {
                    state.events.iter().position(|event| {
                        event.kind == PtyInputKind::Release && event.surface_id == input.surface_id
                    })
                })
                .and_then(|index| state.events.remove(index));
            state.events.clear();
            state.queued_bytes = release.as_ref().map_or(0, |event| event.bytes.len());
            state.release_reservations = 0;
            if let Some(release) = release {
                state.events.push_back(release);
                state.shutdown_release_drain = true;
            }
        }
        self.sender.queue.changed.notify_all();
        drop(state);
        if drained && let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
        drained
    }
}

impl PtyInputSender {
    pub fn enqueue(&self, event: PtyInputEvent) -> PtyInputEnqueueResult {
        let mut state = self.queue.state.lock().unwrap();
        if state.closed {
            return PtyInputEnqueueResult::Saturated;
        }
        if state.remote_failed && event.remote {
            return PtyInputEnqueueResult::Failed;
        }
        if event.bytes.len() > MAX_QUEUED_BYTES {
            return PtyInputEnqueueResult::Oversized;
        }
        let QueueState { events, queued_bytes, release_reservations, .. } = &mut *state;
        let accepted = enqueue_bounded(
            events,
            queued_bytes,
            release_reservations,
            event,
            QUEUE_CAPACITY,
            MAX_QUEUED_BYTES,
        );
        if accepted {
            self.queue.changed.notify_one();
            PtyInputEnqueueResult::Accepted
        } else {
            PtyInputEnqueueResult::Saturated
        }
    }

    pub fn cancel_release_reservation(&self) {
        let mut state = self.queue.state.lock().unwrap();
        state.release_reservations = state.release_reservations.saturating_sub(1);
        self.queue.changed.notify_all();
    }

    pub fn enqueue_session_mutation(
        &self,
        label: &'static str,
        remote: bool,
        operation: impl FnOnce() -> anyhow::Result<()> + Send + 'static,
    ) {
        self.enqueue_mutation_with_key(label, None, remote, operation);
    }

    pub fn enqueue_coalescing_mutation(
        &self,
        label: &'static str,
        key: (&'static str, u64),
        remote: bool,
        operation: impl FnOnce() -> anyhow::Result<()> + Send + 'static,
    ) {
        self.enqueue_mutation_with_key(label, Some(key), remote, operation);
    }

    fn enqueue_mutation_with_key(
        &self,
        label: &'static str,
        key: Option<(&'static str, u64)>,
        remote: bool,
        operation: impl FnOnce() -> anyhow::Result<()> + Send + 'static,
    ) {
        let result = self.enqueue(PtyInputEvent::mutation(label, key, remote, operation));
        if result != PtyInputEnqueueResult::Accepted {
            (self.on_failure)(PtyOperationFailure {
                surface_id: None,
                kind: None,
                label,
                error: match result {
                    PtyInputEnqueueResult::Failed => {
                        "remote operation lane is unavailable after a transport failure"
                    }
                    _ => "operation queue is full; the session was left unchanged",
                }
                .into(),
                lane_failed: result == PtyInputEnqueueResult::Failed,
            });
        }
    }
}

impl Drop for PtyInputDispatcher {
    fn drop(&mut self) {
        let mut state = self.sender.queue.state.lock().unwrap();
        state.closed = true;
        if !state.shutdown_release_drain {
            state.events.clear();
            state.queued_bytes = 0;
            state.release_reservations = 0;
        }
        self.sender.queue.changed.notify_all();
    }
}

fn enqueue_bounded(
    events: &mut VecDeque<PtyInputEvent>,
    queued_bytes: &mut usize,
    release_reservations: &mut usize,
    event: PtyInputEvent,
    capacity: usize,
    max_bytes: usize,
) -> bool {
    if event.coalesce_key.is_some()
        && events.back().is_some_and(|previous| previous.coalesce_key == event.coalesce_key)
    {
        *events.back_mut().unwrap() = event;
        return true;
    }
    if event.kind == PtyInputKind::Motion
        && events.back().is_some_and(|previous| {
            previous.kind == PtyInputKind::Motion && previous.surface_id == event.surface_id
        })
    {
        let previous_len = events.back().unwrap().bytes.len();
        let projected_bytes = queued_bytes.saturating_sub(previous_len)
            + event.bytes.len()
            + *release_reservations * RESERVED_RELEASE_BYTES;
        if projected_bytes > max_bytes {
            return false;
        }
        *queued_bytes = queued_bytes.saturating_sub(previous_len) + event.bytes.len();
        *events.back_mut().unwrap() = event;
        return true;
    }

    let merge_stream = event.kind == PtyInputKind::Ordered
        && events.back().is_some_and(|previous| {
            previous.kind == PtyInputKind::Ordered && previous.surface_id == event.surface_id
        });
    let consumes_reservation = event.kind == PtyInputKind::Release && *release_reservations > 0;
    let mut projected = events.len()
        + *release_reservations
        + usize::from(!merge_stream)
        + usize::from(event.kind == PtyInputKind::Press);
    if consumes_reservation {
        projected -= 1;
    }
    let mut projected_bytes = *queued_bytes
        + event.bytes.len()
        + (*release_reservations + usize::from(event.kind == PtyInputKind::Press))
            * RESERVED_RELEASE_BYTES;
    if consumes_reservation {
        projected_bytes = projected_bytes.saturating_sub(RESERVED_RELEASE_BYTES);
    }
    while projected > capacity || projected_bytes > max_bytes {
        let Some(index) = events.iter().position(|queued| queued.kind == PtyInputKind::Motion)
        else {
            return false;
        };
        let removed = events.remove(index).unwrap();
        *queued_bytes = queued_bytes.saturating_sub(removed.bytes.len());
        projected -= 1;
        projected_bytes = projected_bytes.saturating_sub(removed.bytes.len());
    }

    if event.kind == PtyInputKind::Press {
        *release_reservations += 1;
    } else if consumes_reservation {
        *release_reservations -= 1;
    }

    if merge_stream {
        *queued_bytes += event.bytes.len();
        events.back_mut().unwrap().bytes.extend_from_slice(&event.bytes);
    } else {
        *queued_bytes += event.bytes.len();
        events.push_back(event);
    }
    true
}

fn worker(queue: Arc<SharedQueue>, on_failure: Arc<dyn Fn(PtyOperationFailure) + Send + Sync>) {
    loop {
        let event = {
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
        let result = if let Some(operation) = event.mutation {
            operation()
        } else {
            event.surface.write_bytes(&event.bytes)
        };
        let remote_transport_failed =
            remote && result.as_ref().err().is_some_and(is_remote_transport_failure);
        let failure = result.err().map(|error| PtyOperationFailure {
            surface_id,
            kind,
            label: event.label,
            error: error.to_string(),
            lane_failed: remote_transport_failed,
        });
        let mut state = queue.state.lock().unwrap();
        let mut canceled = Vec::new();
        if failure.is_some() && kind == Some(PtyInputKind::Press) {
            state.release_reservations = state.release_reservations.saturating_sub(1);
        }
        if remote_transport_failed {
            // One dispatcher belongs to one local or remote App session. A
            // remote timeout means every queued remote request shares the
            // same failed transport, so cancel the backlog instead of paying
            // the request timeout once per event.
            state.remote_failed = true;
            canceled.extend(state.events.drain(..).map(|event| PtyOperationFailure {
                surface_id: (event.kind != PtyInputKind::Mutation).then_some(event.surface_id),
                kind: (event.kind != PtyInputKind::Mutation).then_some(event.kind),
                label: event.label,
                error: "canceled after the remote transport failed".into(),
                lane_failed: true,
            }));
            state.queued_bytes = 0;
            state.release_reservations = 0;
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
    }
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
        let mut releases = 0;
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
    fn ordered_bytes_batch_without_crossing_motion_or_surfaces() {
        let mut events = VecDeque::new();
        let mut queued_bytes = 0;
        let mut releases = 0;
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
        let mut releases = 0;
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
    fn accepted_press_guarantees_its_release_slot() {
        let mut events = VecDeque::new();
        let mut queued_bytes = 0;
        let mut releases = 0;
        assert!(enqueue_bounded(
            &mut events,
            &mut queued_bytes,
            &mut releases,
            event(1, 1, PtyInputKind::Press),
            3,
            1024,
        ));
        assert_eq!(releases, 1);
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
        assert_eq!(releases, 0);
        assert_eq!(events.len(), 3);
        assert_eq!(events.back().unwrap().bytes.as_slice(), &[4]);
    }

    #[test]
    fn ordered_batch_respects_byte_budget() {
        let mut events = VecDeque::new();
        let mut queued_bytes = 0;
        let mut releases = 0;
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
    fn shutdown_timeout_preserves_release_behind_in_flight_press() {
        let queue = Arc::new(SharedQueue::default());
        {
            let mut state = queue.state.lock().unwrap();
            state.events.push_back(event(1, 1, PtyInputKind::Motion));
            state.events.push_back(event(1, 2, PtyInputKind::Release));
            state.queued_bytes = 2;
            state.in_flight = Some(InFlightInput { surface_id: 1, kind: PtyInputKind::Press });
        }
        let mut dispatcher = PtyInputDispatcher {
            sender: PtyInputSender { queue: queue.clone(), on_failure: Arc::new(|_| {}) },
            worker: None,
        };

        assert!(!dispatcher.shutdown(Duration::ZERO));

        let state = queue.state.lock().unwrap();
        assert!(state.closed);
        assert_eq!(state.events.len(), 1);
        assert_eq!(state.events[0].kind, PtyInputKind::Release);
        assert_eq!(state.queued_bytes, 1);
        assert_eq!(state.release_reservations, 0);
        assert!(state.shutdown_release_drain);
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
        assert!(!state.shutdown_release_drain);
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
        failure_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert_eq!(dispatcher.sender.queue.state.lock().unwrap().release_reservations, 0);
    }

    #[test]
    fn remote_failure_cancels_backlog_and_rejects_later_operations() {
        let (failure_tx, failure_rx) = std::sync::mpsc::channel();
        let dispatcher = PtyInputDispatcher::spawn(move |failure| {
            failure_tx.send(failure).unwrap();
        })
        .unwrap();
        let sender = dispatcher.sender();
        let ran = Arc::new(std::sync::atomic::AtomicBool::new(false));

        sender.enqueue_session_mutation("remote input", true, || {
            Err(crate::session::test_remote_timeout_error())
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
        assert!(!ran.load(std::sync::atomic::Ordering::Acquire));

        sender.enqueue_session_mutation("later resize", true, || Ok(()));
        let later = failure_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert_eq!(later.label, "later resize");
        assert!(later.error.contains("unavailable"));
        assert!(later.lane_failed);
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
