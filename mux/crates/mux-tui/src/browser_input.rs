//! Off-loop browser input forwarding.
//!
//! Forwarding input to a browser surface ultimately performs blocking
//! I/O: a CDP request/response on the shared WebSocket for local
//! surfaces (30s timeout, plus up to the reader's poll window to take
//! the socket lock), or a JSON request over the control socket (10s
//! timeout) for remote ones. A wedged Chrome or half-open session must
//! never freeze the TUI event loop just because the mouse moved, so
//! input events are handed to a dedicated worker thread through a
//! bounded queue:
//!
//! - Consecutive mouse moves on the same surface are coalesced (latest
//!   wins) before dispatch, so a stalled endpoint never builds a replay
//!   backlog of stale hover/drag positions.
//! - When the queue is full (the worker is stuck inside a blocking
//!   call), events are dropped instead of blocking the UI. Dropped
//!   input against a wedged browser was going nowhere anyway.
//!
//! Results are intentionally discarded: browser input has no caller
//! that can act on a per-event error, and the surface's own status
//! (`BrowserStatus`) is what the UI reports.

use std::sync::mpsc::{Receiver, SyncSender, sync_channel};

use mux_core::SurfaceId;

use crate::session::SurfaceHandle;

/// Bounded queue depth. Input events are tiny; this is sized so bursts
/// (drag + key repeat) never drop while a healthy worker drains, but a
/// blocked worker caps queued work at a few hundred events.
const QUEUE_CAPACITY: usize = 512;

pub struct BrowserInputEvent {
    pub surface_id: SurfaceId,
    pub surface: SurfaceHandle,
    pub kind: BrowserInputKind,
}

pub enum BrowserInputKind {
    Mouse {
        event_type: &'static str,
        x: f64,
        y: f64,
        button: Option<&'static str>,
        click_count: Option<u32>,
    },
    Wheel {
        x: f64,
        y: f64,
        delta_y: f64,
    },
    Key {
        event_type: &'static str,
        key: &'static str,
        code: &'static str,
        windows_virtual_key_code: u32,
        modifiers: u32,
        text: Option<&'static str>,
    },
    InsertText(String),
}

impl BrowserInputKind {
    /// Mouse moves carry only a position; when several are queued for
    /// the same surface, only the newest matters.
    fn is_mouse_move(&self) -> bool {
        matches!(self, BrowserInputKind::Mouse { event_type: "mouseMoved", .. })
    }
}

pub struct BrowserInputDispatcher {
    tx: SyncSender<BrowserInputEvent>,
}

impl BrowserInputDispatcher {
    pub fn spawn() -> anyhow::Result<Self> {
        let (tx, rx) = sync_channel(QUEUE_CAPACITY);
        std::thread::Builder::new().name("mux-browser-input".into()).spawn(move || worker(rx))?;
        Ok(BrowserInputDispatcher { tx })
    }

    /// Queue an event; never blocks. A full queue (worker wedged inside
    /// a blocking browser call) drops the event.
    pub fn enqueue(&self, event: BrowserInputEvent) {
        let _ = self.tx.try_send(event);
    }
}

fn worker(rx: Receiver<BrowserInputEvent>) {
    while let Ok(event) = rx.recv() {
        // Drain whatever queued behind the first event so mouse moves
        // can be coalesced across the batch.
        let mut batch = vec![event];
        while let Ok(next) = rx.try_recv() {
            batch.push(next);
        }
        coalesce_mouse_moves(&mut batch);
        for event in batch {
            dispatch(&event);
        }
    }
}

/// Drop a mouse move when the next event is also a mouse move on the
/// same surface: only the final position of a consecutive run is
/// forwarded. Clicks, keys, and wheel events keep their order.
fn coalesce_mouse_moves(batch: &mut Vec<BrowserInputEvent>) {
    let mut index = 0;
    while index + 1 < batch.len() {
        let drop_current = batch[index].kind.is_mouse_move()
            && batch[index + 1].kind.is_mouse_move()
            && batch[index].surface_id == batch[index + 1].surface_id;
        if drop_current {
            batch.remove(index);
        } else {
            index += 1;
        }
    }
}

fn dispatch(event: &BrowserInputEvent) {
    let surface = &event.surface;
    let _ = match &event.kind {
        BrowserInputKind::Mouse { event_type, x, y, button, click_count } => {
            surface.browser_mouse_event(event_type, *x, *y, *button, *click_count)
        }
        BrowserInputKind::Wheel { x, y, delta_y } => surface.browser_wheel(*x, *y, *delta_y),
        BrowserInputKind::Key {
            event_type,
            key,
            code,
            windows_virtual_key_code,
            modifiers,
            text,
        } => surface.browser_key_event(
            event_type,
            key,
            code,
            *windows_virtual_key_code,
            *modifiers,
            *text,
        ),
        BrowserInputKind::InsertText(text) => surface.browser_insert_text(text),
    };
}

#[cfg(test)]
mod tests {
    use super::*;

    fn move_event(surface: SurfaceId, x: f64) -> BrowserInputEvent {
        BrowserInputEvent {
            surface_id: surface,
            surface: SurfaceHandle::RemoteBrowserUnsupported,
            kind: BrowserInputKind::Mouse {
                event_type: "mouseMoved",
                x,
                y: 0.0,
                button: Some("none"),
                click_count: None,
            },
        }
    }

    fn click_event(surface: SurfaceId) -> BrowserInputEvent {
        BrowserInputEvent {
            surface_id: surface,
            surface: SurfaceHandle::RemoteBrowserUnsupported,
            kind: BrowserInputKind::Mouse {
                event_type: "mousePressed",
                x: 0.0,
                y: 0.0,
                button: Some("left"),
                click_count: Some(1),
            },
        }
    }

    fn positions(batch: &[BrowserInputEvent]) -> Vec<(&'static str, SurfaceId)> {
        batch
            .iter()
            .map(|event| match event.kind {
                BrowserInputKind::Mouse { event_type, .. } => (event_type, event.surface_id),
                _ => ("other", event.surface_id),
            })
            .collect()
    }

    #[test]
    fn consecutive_moves_on_same_surface_keep_latest_only() {
        let mut batch = vec![move_event(1, 1.0), move_event(1, 2.0), move_event(1, 3.0)];
        coalesce_mouse_moves(&mut batch);
        assert_eq!(batch.len(), 1);
        match batch[0].kind {
            BrowserInputKind::Mouse { x, .. } => assert_eq!(x, 3.0),
            _ => panic!("expected mouse event"),
        }
    }

    #[test]
    fn clicks_break_coalescing_and_keep_order() {
        let mut batch = vec![move_event(1, 1.0), click_event(1), move_event(1, 2.0)];
        coalesce_mouse_moves(&mut batch);
        assert_eq!(
            positions(&batch),
            vec![("mouseMoved", 1), ("mousePressed", 1), ("mouseMoved", 1)]
        );
    }

    #[test]
    fn moves_on_different_surfaces_are_kept() {
        let mut batch = vec![move_event(1, 1.0), move_event(2, 1.0)];
        coalesce_mouse_moves(&mut batch);
        assert_eq!(batch.len(), 2);
    }
}
