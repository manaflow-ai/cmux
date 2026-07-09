//! Ordered, off-loop PTY input forwarding for remote sessions.
//!
//! Remote `write_bytes` waits for a control-socket response. All remote PTY
//! bytes use this single lane so mouse and keyboard input stay ordered without
//! blocking the UI. Motion is coalesced, and part of the bounded queue is
//! reserved for releases so stale motion can never strand a pressed button.

use std::collections::VecDeque;
use std::sync::{Arc, Condvar, Mutex};

use cmux_tui_core::SurfaceId;

use crate::session::SurfaceHandle;

const QUEUE_CAPACITY: usize = 512;
const RELEASE_RESERVE: usize = 16;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PtyInputKind {
    Ordered,
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
    closed: bool,
}

#[derive(Default)]
struct SharedQueue {
    state: Mutex<QueueState>,
    ready: Condvar,
}

pub struct PtyInputDispatcher {
    queue: Arc<SharedQueue>,
}

impl PtyInputDispatcher {
    pub fn spawn() -> anyhow::Result<Self> {
        let queue = Arc::new(SharedQueue::default());
        let worker_queue = queue.clone();
        std::thread::Builder::new()
            .name("mux-pty-input".into())
            .spawn(move || worker(worker_queue))?;
        Ok(Self { queue })
    }

    pub fn enqueue(&self, event: PtyInputEvent) -> bool {
        let mut state = self.queue.state.lock().unwrap();
        if state.closed || !enqueue_bounded(&mut state.events, event, QUEUE_CAPACITY) {
            return false;
        }
        self.queue.ready.notify_one();
        true
    }
}

impl Drop for PtyInputDispatcher {
    fn drop(&mut self) {
        let mut state = self.queue.state.lock().unwrap();
        state.closed = true;
        self.queue.ready.notify_one();
    }
}

fn enqueue_bounded(
    events: &mut VecDeque<PtyInputEvent>,
    event: PtyInputEvent,
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

    let reserve = RELEASE_RESERVE.min(capacity);
    let limit = if event.kind == PtyInputKind::Release {
        capacity
    } else {
        capacity.saturating_sub(reserve)
    };
    if events.len() >= limit {
        if let Some(index) = events.iter().position(|queued| queued.kind == PtyInputKind::Motion) {
            events.remove(index);
        } else {
            return false;
        }
    }
    events.push_back(event);
    true
}

fn worker(queue: Arc<SharedQueue>) {
    loop {
        let event = {
            let mut state = queue.state.lock().unwrap();
            while state.events.is_empty() && !state.closed {
                state = queue.ready.wait(state).unwrap();
            }
            if state.events.is_empty() && state.closed {
                return;
            }
            state.events.pop_front().unwrap()
        };
        event.surface.write_bytes(&event.bytes);
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
        assert!(enqueue_bounded(&mut events, event(1, 1, PtyInputKind::Motion), 32));
        assert!(enqueue_bounded(&mut events, event(1, 2, PtyInputKind::Motion), 32));
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].bytes, vec![2]);
    }

    #[test]
    fn ordered_events_and_other_surfaces_break_motion_coalescing() {
        let mut events = VecDeque::new();
        for item in [
            event(1, 1, PtyInputKind::Motion),
            event(1, 2, PtyInputKind::Ordered),
            event(1, 3, PtyInputKind::Motion),
            event(2, 4, PtyInputKind::Motion),
        ] {
            assert!(enqueue_bounded(&mut events, item, 32));
        }
        assert_eq!(events.iter().map(|event| event.bytes[0]).collect::<Vec<_>>(), vec![1, 2, 3, 4]);
    }

    #[test]
    fn release_uses_reserved_capacity_without_evicting_ordered_input() {
        let mut events = VecDeque::new();
        let ordered_limit = 20 - RELEASE_RESERVE;
        for byte in 0..ordered_limit as u8 {
            assert!(enqueue_bounded(&mut events, event(1, byte, PtyInputKind::Ordered), 20,));
        }
        assert!(!enqueue_bounded(&mut events, event(1, 99, PtyInputKind::Ordered), 20,));
        assert!(enqueue_bounded(&mut events, event(1, 100, PtyInputKind::Release), 20,));
        assert_eq!(events.front().unwrap().bytes, vec![0]);
        assert_eq!(events.back().unwrap().bytes, vec![100]);
    }
}
