//! Off-loop PTY mouse forwarding for remote sessions.
//!
//! A remote `write_bytes` call waits for a control-socket response. Mouse
//! motion must not perform that round trip on the UI thread, so remote events
//! use this bounded worker. Consecutive motions on one surface are coalesced.
//! When the queue is full, ordered events displace stale motion and releases
//! are prioritized so an inner TUI is not left with a stuck button.

use std::collections::VecDeque;
use std::sync::{Arc, Condvar, Mutex};

use cmux_tui_core::SurfaceId;

use crate::session::SurfaceHandle;

const QUEUE_CAPACITY: usize = 512;

pub struct PtyMouseInputEvent {
    pub surface_id: SurfaceId,
    pub surface: SurfaceHandle,
    pub bytes: Vec<u8>,
    pub motion: bool,
    pub release: bool,
}

#[derive(Default)]
struct QueueState {
    events: VecDeque<PtyMouseInputEvent>,
    closed: bool,
}

#[derive(Default)]
struct SharedQueue {
    state: Mutex<QueueState>,
    ready: Condvar,
}

pub struct PtyMouseInputDispatcher {
    queue: Arc<SharedQueue>,
}

impl PtyMouseInputDispatcher {
    pub fn spawn() -> anyhow::Result<Self> {
        let queue = Arc::new(SharedQueue::default());
        let worker_queue = queue.clone();
        std::thread::Builder::new()
            .name("mux-pty-mouse-input".into())
            .spawn(move || worker(worker_queue))?;
        Ok(Self { queue })
    }

    pub fn enqueue(&self, event: PtyMouseInputEvent) {
        let mut state = self.queue.state.lock().unwrap();
        if state.closed || !enqueue_bounded(&mut state.events, event, QUEUE_CAPACITY) {
            return;
        }
        self.queue.ready.notify_one();
    }
}

impl Drop for PtyMouseInputDispatcher {
    fn drop(&mut self) {
        let mut state = self.queue.state.lock().unwrap();
        state.closed = true;
        self.queue.ready.notify_one();
    }
}

fn enqueue_bounded(
    events: &mut VecDeque<PtyMouseInputEvent>,
    event: PtyMouseInputEvent,
    capacity: usize,
) -> bool {
    if event.motion
        && events
            .back()
            .is_some_and(|previous| previous.motion && previous.surface_id == event.surface_id)
    {
        *events.back_mut().unwrap() = event;
        return true;
    }

    if events.len() >= capacity {
        if let Some(index) = events.iter().position(|queued| queued.motion) {
            events.remove(index);
        } else if event.release {
            // A release is the recovery edge for the inner application's
            // pressed state, so keep the newest one under extreme saturation.
            events.pop_front();
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

    fn event(surface_id: SurfaceId, bytes: u8, motion: bool, release: bool) -> PtyMouseInputEvent {
        PtyMouseInputEvent {
            surface_id,
            surface: SurfaceHandle::RemoteBrowserUnsupported,
            bytes: vec![bytes],
            motion,
            release,
        }
    }

    #[test]
    fn consecutive_motion_on_one_surface_keeps_latest() {
        let mut events = VecDeque::new();
        assert!(enqueue_bounded(&mut events, event(1, 1, true, false), 4));
        assert!(enqueue_bounded(&mut events, event(1, 2, true, false), 4));
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].bytes, vec![2]);
    }

    #[test]
    fn ordered_events_and_other_surfaces_break_motion_coalescing() {
        let mut events = VecDeque::new();
        for item in [
            event(1, 1, true, false),
            event(1, 2, false, false),
            event(1, 3, true, false),
            event(2, 4, true, false),
        ] {
            assert!(enqueue_bounded(&mut events, item, 8));
        }
        assert_eq!(events.iter().map(|event| event.bytes[0]).collect::<Vec<_>>(), vec![1, 2, 3, 4]);
    }

    #[test]
    fn release_displaces_motion_when_queue_is_full() {
        let mut events = VecDeque::from([
            event(1, 1, false, false),
            event(1, 2, true, false),
            event(1, 3, false, false),
        ]);
        assert!(enqueue_bounded(&mut events, event(1, 4, false, true), 3));
        assert_eq!(events.iter().map(|event| event.bytes[0]).collect::<Vec<_>>(), vec![1, 3, 4]);
    }
}
