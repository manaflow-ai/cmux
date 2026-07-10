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

use crate::session::SurfaceHandle;

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
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PtyInputEnqueueResult {
    Accepted,
    Oversized,
    Saturated,
}

pub struct PtyInputEvent {
    pub surface_id: SurfaceId,
    pub surface: SurfaceHandle,
    pub bytes: PtyInputBytes,
    pub kind: PtyInputKind,
}

#[derive(Default)]
struct QueueState {
    events: VecDeque<PtyInputEvent>,
    queued_bytes: usize,
    release_reservations: usize,
    in_flight: bool,
    closed: bool,
}

#[derive(Default)]
struct SharedQueue {
    state: Mutex<QueueState>,
    changed: Condvar,
}

pub struct PtyInputDispatcher {
    queue: Arc<SharedQueue>,
    worker: Option<JoinHandle<()>>,
}

impl PtyInputDispatcher {
    pub fn spawn() -> anyhow::Result<Self> {
        let queue = Arc::new(SharedQueue::default());
        let worker_queue = queue.clone();
        let worker = std::thread::Builder::new()
            .name("mux-pty-input".into())
            .spawn(move || worker(worker_queue))?;
        Ok(Self { queue, worker: Some(worker) })
    }

    pub fn enqueue(&self, event: PtyInputEvent) -> PtyInputEnqueueResult {
        let mut state = self.queue.state.lock().unwrap();
        if state.closed {
            return PtyInputEnqueueResult::Saturated;
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

    /// Wait until every input accepted before this call has completed.
    /// This is an ordering barrier for infrequent surface/session mutations.
    pub fn flush(&self, timeout: Duration) -> bool {
        let deadline = Instant::now() + timeout;
        let mut state = self.queue.state.lock().unwrap();
        while (!state.events.is_empty() || state.in_flight) && Instant::now() < deadline {
            let remaining = deadline.saturating_duration_since(Instant::now());
            let (next, _) = self.queue.changed.wait_timeout(state, remaining).unwrap();
            state = next;
        }
        state.events.is_empty() && !state.in_flight
    }

    /// Stop accepting work and discard queued bytes after an explicit input
    /// saturation disconnect. The in-flight request is allowed to return.
    pub fn abort(&self) {
        let mut state = self.queue.state.lock().unwrap();
        state.closed = true;
        state.events.clear();
        state.queued_bytes = 0;
        state.release_reservations = 0;
        self.queue.changed.notify_all();
    }

    /// Drain queued writes during detach/normal shutdown, bounded so a
    /// half-open remote session cannot hang terminal restoration forever.
    pub fn shutdown(&mut self, timeout: Duration) -> bool {
        let deadline = Instant::now() + timeout;
        let mut state = self.queue.state.lock().unwrap();
        while (!state.events.is_empty() || state.in_flight) && Instant::now() < deadline {
            let remaining = deadline.saturating_duration_since(Instant::now());
            let (next, _) = self.queue.changed.wait_timeout(state, remaining).unwrap();
            state = next;
        }
        let drained = state.events.is_empty() && !state.in_flight;
        state.closed = true;
        if !drained {
            state.events.clear();
            state.queued_bytes = 0;
            state.release_reservations = 0;
        }
        self.queue.changed.notify_all();
        drop(state);
        if drained && let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
        drained
    }
}

impl Drop for PtyInputDispatcher {
    fn drop(&mut self) {
        let mut state = self.queue.state.lock().unwrap();
        state.closed = true;
        state.events.clear();
        state.queued_bytes = 0;
        state.release_reservations = 0;
        self.queue.changed.notify_all();
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

    let merge_stream = event.kind != PtyInputKind::Motion
        && events.back().is_some_and(|previous| {
            previous.kind != PtyInputKind::Motion && previous.surface_id == event.surface_id
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

fn worker(queue: Arc<SharedQueue>) {
    loop {
        let event = {
            let mut state = queue.state.lock().unwrap();
            while state.events.is_empty() && !state.closed {
                state = queue.changed.wait(state).unwrap();
            }
            if state.events.is_empty() && state.closed {
                return;
            }
            state.in_flight = true;
            let event = state.events.pop_front().unwrap();
            state.queued_bytes = state.queued_bytes.saturating_sub(event.bytes.len());
            event
        };
        event.surface.write_bytes(&event.bytes);
        let mut state = queue.state.lock().unwrap();
        state.in_flight = false;
        queue.changed.notify_all();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn event(surface_id: SurfaceId, bytes: u8, kind: PtyInputKind) -> PtyInputEvent {
        PtyInputEvent {
            surface_id,
            surface: SurfaceHandle::RemoteBrowserUnsupported,
            bytes: SmallVec::from_slice(&[bytes]),
            kind,
        }
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
        let mut dispatcher = PtyInputDispatcher::spawn().unwrap();
        assert_eq!(
            dispatcher.enqueue(event(1, 1, PtyInputKind::Ordered)),
            PtyInputEnqueueResult::Accepted
        );
        assert!(dispatcher.shutdown(Duration::from_secs(1)));
    }

    #[test]
    fn shutdown_timeout_discards_pending_input() {
        let queue = Arc::new(SharedQueue::default());
        {
            let mut state = queue.state.lock().unwrap();
            state.events.push_back(event(1, 1, PtyInputKind::Press));
            state.events.push_back(event(1, 2, PtyInputKind::Release));
            state.queued_bytes = 2;
            state.release_reservations = 1;
            state.in_flight = true;
        }
        let mut dispatcher = PtyInputDispatcher { queue: queue.clone(), worker: None };

        assert!(!dispatcher.shutdown(Duration::ZERO));

        let state = queue.state.lock().unwrap();
        assert!(state.closed);
        assert!(state.events.is_empty());
        assert_eq!(state.queued_bytes, 0);
        assert_eq!(state.release_reservations, 0);
    }

    #[test]
    fn accepted_input_completes_before_following_mutation() {
        let queue = Arc::new(SharedQueue::default());
        queue.state.lock().unwrap().in_flight = true;
        let dispatcher = Arc::new(PtyInputDispatcher { queue: queue.clone(), worker: None });
        let mutated = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let (started_tx, started_rx) = std::sync::mpsc::channel();
        let (done_tx, done_rx) = std::sync::mpsc::channel();
        let flush_dispatcher = dispatcher;
        let mutation = mutated.clone();
        let flush_thread = std::thread::spawn(move || {
            started_tx.send(()).unwrap();
            let flushed = flush_dispatcher.flush(Duration::from_secs(1));
            if flushed {
                mutation.store(true, std::sync::atomic::Ordering::Release);
            }
            done_tx.send(flushed).unwrap();
        });

        started_rx.recv().unwrap();
        assert_eq!(done_rx.try_recv(), Err(std::sync::mpsc::TryRecvError::Empty));
        assert!(!mutated.load(std::sync::atomic::Ordering::Acquire));
        {
            let mut state = queue.state.lock().unwrap();
            state.in_flight = false;
            queue.changed.notify_all();
        }

        assert!(done_rx.recv_timeout(Duration::from_secs(1)).unwrap());
        assert!(mutated.load(std::sync::atomic::Ordering::Acquire));
        flush_thread.join().unwrap();
    }

    #[test]
    fn oversized_input_is_distinguished_from_queue_saturation() {
        let dispatcher = PtyInputDispatcher::spawn().unwrap();
        let mut oversized = event(1, 1, PtyInputKind::Ordered);
        oversized.bytes = vec![1; MAX_QUEUED_BYTES + 1].into();

        assert_eq!(dispatcher.enqueue(oversized), PtyInputEnqueueResult::Oversized);
    }
}
