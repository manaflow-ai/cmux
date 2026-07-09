//! Off-loop PTY mouse forwarding for remote sessions.
//!
//! A remote `write_bytes` call waits for a control-socket response. Mouse
//! motion must not perform that round trip on the UI thread, so remote events
//! use this bounded worker. Consecutive motions on one surface are coalesced;
//! button and wheel events retain their order.

use std::sync::mpsc::{Receiver, SyncSender, sync_channel};

use cmux_tui_core::SurfaceId;

use crate::session::SurfaceHandle;

const QUEUE_CAPACITY: usize = 512;

pub struct PtyMouseInputEvent {
    pub surface_id: SurfaceId,
    pub surface: SurfaceHandle,
    pub bytes: Vec<u8>,
    pub motion: bool,
}

pub struct PtyMouseInputDispatcher {
    tx: SyncSender<PtyMouseInputEvent>,
}

impl PtyMouseInputDispatcher {
    pub fn spawn() -> anyhow::Result<Self> {
        let (tx, rx) = sync_channel(QUEUE_CAPACITY);
        std::thread::Builder::new().name("mux-pty-mouse-input".into()).spawn(move || worker(rx))?;
        Ok(Self { tx })
    }

    /// Queue an event without blocking the UI. A wedged remote endpoint may
    /// fill the bounded queue, in which case new input is dropped.
    pub fn enqueue(&self, event: PtyMouseInputEvent) {
        let _ = self.tx.try_send(event);
    }
}

fn worker(rx: Receiver<PtyMouseInputEvent>) {
    while let Ok(event) = rx.recv() {
        let mut batch = vec![event];
        while let Ok(next) = rx.try_recv() {
            batch.push(next);
        }
        for event in coalesce_motion(batch) {
            event.surface.write_bytes(&event.bytes);
        }
    }
}

fn coalesce_motion(batch: Vec<PtyMouseInputEvent>) -> Vec<PtyMouseInputEvent> {
    let mut coalesced: Vec<PtyMouseInputEvent> = Vec::with_capacity(batch.len());
    for event in batch {
        if event.motion
            && coalesced
                .last()
                .is_some_and(|previous| previous.motion && previous.surface_id == event.surface_id)
        {
            *coalesced.last_mut().unwrap() = event;
        } else {
            coalesced.push(event);
        }
    }
    coalesced
}

#[cfg(test)]
mod tests {
    use super::*;

    fn event(surface_id: SurfaceId, bytes: u8, motion: bool) -> PtyMouseInputEvent {
        PtyMouseInputEvent {
            surface_id,
            surface: SurfaceHandle::RemoteBrowserUnsupported,
            bytes: vec![bytes],
            motion,
        }
    }

    #[test]
    fn consecutive_motion_on_one_surface_keeps_latest() {
        let events = coalesce_motion(vec![event(1, 1, true), event(1, 2, true)]);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].bytes, vec![2]);
    }

    #[test]
    fn ordered_events_and_other_surfaces_break_motion_coalescing() {
        let events = coalesce_motion(vec![
            event(1, 1, true),
            event(1, 2, false),
            event(1, 3, true),
            event(2, 4, true),
        ]);
        assert_eq!(events.iter().map(|event| event.bytes[0]).collect::<Vec<_>>(), vec![1, 2, 3, 4]);
    }
}
