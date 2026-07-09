//! Ordered, off-loop PTY input forwarding for remote sessions.
//!
//! Remote `write_bytes` waits for a control-socket response. All remote PTY
//! bytes use one lane so mouse and keyboard input stay ordered without
//! blocking the UI. Consecutive byte-stream writes are batched, motion is
//! coalesced, and every accepted mouse press reserves its release capacity.

use std::collections::VecDeque;
use std::sync::{Arc, Condvar, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use cmux_tui_core::SurfaceId;

use crate::session::SurfaceHandle;

const QUEUE_CAPACITY: usize = 512;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PtyInputKind {
    Ordered,
    Press,
    Motion,
    Release,
}

pub struct PtyInputEvent {
    pub surface_id: SurfaceId,
    pub surface: SurfaceHandle,
    pub bytes: Vec<u8>,
    pub kind: PtyInputKind,
}

#[derive(Default)]
struct QueueState {
    events: VecDeque<PtyInputEvent>,
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

    pub fn enqueue(&self, event: PtyInputEvent) -> bool {
        let mut state = self.queue.state.lock().unwrap();
        if state.closed {
            return false;
        }
        let QueueState { events, release_reservations, .. } = &mut *state;
        let accepted = enqueue_bounded(events, release_reservations, event, QUEUE_CAPACITY);
        if accepted {
            self.queue.changed.notify_one();
        }
        accepted
    }

    /// Stop accepting work and discard queued bytes after an explicit input
    /// saturation disconnect. The in-flight request is allowed to return.
    pub fn abort(&self) {
        let mut state = self.queue.state.lock().unwrap();
        state.closed = true;
        state.events.clear();
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
        self.queue.changed.notify_all();
    }
}

fn enqueue_bounded(
    events: &mut VecDeque<PtyInputEvent>,
    release_reservations: &mut usize,
    mut event: PtyInputEvent,
    capacity: usize,
) -> bool {
    if event.kind == PtyInputKind::Motion
        && events.back().is_some_and(|previous| {
            previous.kind == PtyInputKind::Motion && previous.surface_id == event.surface_id
        })
    {
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
    while projected > capacity {
        let Some(index) = events.iter().position(|queued| queued.kind == PtyInputKind::Motion)
        else {
            return false;
        };
        events.remove(index);
        projected -= 1;
    }

    if event.kind == PtyInputKind::Press {
        *release_reservations += 1;
    } else if consumes_reservation {
        *release_reservations -= 1;
    }

    if merge_stream {
        events.back_mut().unwrap().bytes.append(&mut event.bytes);
    } else {
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
            state.events.pop_front().unwrap()
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
            bytes: vec![bytes],
            kind,
        }
    }

    #[test]
    fn consecutive_motion_on_one_surface_keeps_latest() {
        let mut events = VecDeque::new();
        let mut releases = 0;
        assert!(enqueue_bounded(&mut events, &mut releases, event(1, 1, PtyInputKind::Motion), 8,));
        assert!(enqueue_bounded(&mut events, &mut releases, event(1, 2, PtyInputKind::Motion), 8,));
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].bytes, vec![2]);
    }

    #[test]
    fn ordered_bytes_batch_without_crossing_motion_or_surfaces() {
        let mut events = VecDeque::new();
        let mut releases = 0;
        for item in [
            event(1, 1, PtyInputKind::Ordered),
            event(1, 2, PtyInputKind::Ordered),
            event(1, 3, PtyInputKind::Motion),
            event(2, 4, PtyInputKind::Ordered),
        ] {
            assert!(enqueue_bounded(&mut events, &mut releases, item, 8));
        }
        assert_eq!(events.len(), 3);
        assert_eq!(events[0].bytes, vec![1, 2]);
        assert_eq!(events[1].bytes, vec![3]);
        assert_eq!(events[2].bytes, vec![4]);
    }

    #[test]
    fn accepted_press_guarantees_its_release_slot() {
        let mut events = VecDeque::new();
        let mut releases = 0;
        assert!(enqueue_bounded(&mut events, &mut releases, event(1, 1, PtyInputKind::Press), 3,));
        assert_eq!(releases, 1);
        assert!(
            enqueue_bounded(&mut events, &mut releases, event(2, 2, PtyInputKind::Ordered), 3,)
        );
        assert!(!enqueue_bounded(
            &mut events,
            &mut releases,
            event(3, 3, PtyInputKind::Ordered),
            3,
        ));
        assert!(
            enqueue_bounded(&mut events, &mut releases, event(1, 4, PtyInputKind::Release), 3,)
        );
        assert_eq!(releases, 0);
        assert_eq!(events.len(), 3);
        assert_eq!(events.back().unwrap().bytes, vec![4]);
    }

    #[test]
    fn shutdown_drains_and_joins_the_worker() {
        let mut dispatcher = PtyInputDispatcher::spawn().unwrap();
        assert!(dispatcher.enqueue(event(1, 1, PtyInputKind::Ordered)));
        assert!(dispatcher.shutdown(Duration::from_secs(1)));
    }
}
