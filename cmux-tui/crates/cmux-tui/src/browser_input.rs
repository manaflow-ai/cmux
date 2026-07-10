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
//!   call), pointer and key events are dropped instead of blocking the
//!   UI. The latest rejected resize per surface is retained so geometry
//!   catches up after already-queued input drains.
//!
//! Results are intentionally discarded: browser input has no caller
//! that can act on a per-event error, and the surface's own status
//! (`BrowserStatus`) is what the UI reports.

use std::collections::HashMap;
use std::sync::mpsc::{Receiver, SyncSender, TrySendError, sync_channel};
use std::sync::{Arc, Mutex};

use cmux_tui_core::SurfaceId;

use crate::session::SurfaceHandle;

/// Bounded queue depth. Input events are tiny; this is sized so bursts
/// (drag + key repeat) never drop while a healthy worker drains, but a
/// blocked worker caps queued work at a few hundred events.
const QUEUE_CAPACITY: usize = 512;

#[derive(Clone)]
pub struct BrowserInputEvent {
    pub surface_id: SurfaceId,
    pub surface: SurfaceHandle,
    pub kind: BrowserInputKind,
}

#[derive(Clone)]
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
    Resize {
        cols: u16,
        rows: u16,
        reassert: bool,
    },
}

impl BrowserInputKind {
    /// Mouse moves carry only a position; when several are queued for
    /// the same surface, only the newest matters.
    fn is_mouse_move(&self) -> bool {
        matches!(self, BrowserInputKind::Mouse { event_type: "mouseMoved", .. })
    }

    fn is_resize(&self) -> bool {
        matches!(self, BrowserInputKind::Resize { .. })
    }
}

pub struct BrowserInputDispatcher {
    tx: SyncSender<BrowserInputEvent>,
    latest_resizes: Arc<Mutex<HashMap<SurfaceId, BrowserInputEvent>>>,
}

impl BrowserInputDispatcher {
    pub fn spawn() -> anyhow::Result<Self> {
        let (tx, rx) = sync_channel(QUEUE_CAPACITY);
        let latest_resizes = Arc::new(Mutex::new(HashMap::new()));
        let worker_resizes = latest_resizes.clone();
        std::thread::Builder::new()
            .name("mux-browser-input".into())
            .spawn(move || worker(rx, worker_resizes))?;
        Ok(BrowserInputDispatcher { tx, latest_resizes })
    }

    /// Queue an event without blocking. A full queue retains the latest
    /// resize per surface and drops other input.
    pub fn enqueue(&self, event: BrowserInputEvent) {
        if let Err(TrySendError::Full(event)) = self.tx.try_send(event)
            && event.kind.is_resize()
        {
            self.latest_resizes.lock().unwrap().insert(event.surface_id, event);
        }
    }
}

fn worker(
    rx: Receiver<BrowserInputEvent>,
    latest_resizes: Arc<Mutex<HashMap<SurfaceId, BrowserInputEvent>>>,
) {
    while let Ok(event) = rx.recv() {
        // Drain whatever queued behind the first event so mouse moves
        // can be coalesced across the batch.
        let mut batch = vec![event];
        while let Ok(next) = rx.try_recv() {
            batch.push(next);
        }
        let latest = std::mem::take(&mut *latest_resizes.lock().unwrap());
        merge_latest_resizes(&mut batch, latest);
        coalesce_browser_events(&mut batch);
        for event in batch {
            dispatch(&event);
        }
    }
}

fn merge_latest_resizes(
    batch: &mut Vec<BrowserInputEvent>,
    latest: HashMap<SurfaceId, BrowserInputEvent>,
) {
    // These resizes were rejected only after every event already in
    // `batch`, so append them at that ordering point. The subsequent
    // coalescing pass may merge them with a trailing resize run, but
    // must not move them ahead of intervening browser input.
    batch.extend(latest.into_values());
}

/// Drop a mouse move when the next event is also a mouse move on the
/// same surface: only the final position of a consecutive run is
/// forwarded. Clicks, keys, and wheel events keep their order.
fn coalesce_browser_events(batch: &mut Vec<BrowserInputEvent>) {
    let mut index = 0;
    while index + 1 < batch.len() {
        let same_coalescing_kind = (batch[index].kind.is_mouse_move()
            && batch[index + 1].kind.is_mouse_move())
            || (batch[index].kind.is_resize() && batch[index + 1].kind.is_resize());
        let drop_current =
            same_coalescing_kind && batch[index].surface_id == batch[index + 1].surface_id;
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
        BrowserInputKind::Resize { cols, rows, reassert } => {
            if *reassert {
                surface.reassert_size(*cols, *rows)
            } else {
                surface.resize(*cols, *rows)
            }
        }
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

    fn resize_event(surface: SurfaceId, cols: u16) -> BrowserInputEvent {
        BrowserInputEvent {
            surface_id: surface,
            surface: SurfaceHandle::RemoteBrowserUnsupported,
            kind: BrowserInputKind::Resize { cols, rows: 24, reassert: false },
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
        coalesce_browser_events(&mut batch);
        assert_eq!(batch.len(), 1);
        match batch[0].kind {
            BrowserInputKind::Mouse { x, .. } => assert_eq!(x, 3.0),
            _ => panic!("expected mouse event"),
        }
    }

    #[test]
    fn clicks_break_coalescing_and_keep_order() {
        let mut batch = vec![move_event(1, 1.0), click_event(1), move_event(1, 2.0)];
        coalesce_browser_events(&mut batch);
        assert_eq!(
            positions(&batch),
            vec![("mouseMoved", 1), ("mousePressed", 1), ("mouseMoved", 1)]
        );
    }

    #[test]
    fn moves_on_different_surfaces_are_kept() {
        let mut batch = vec![move_event(1, 1.0), move_event(2, 1.0)];
        coalesce_browser_events(&mut batch);
        assert_eq!(batch.len(), 2);
    }

    #[test]
    fn consecutive_resizes_keep_latest_without_crossing_clicks() {
        let mut batch = vec![resize_event(1, 80), resize_event(1, 100), click_event(1)];
        coalesce_browser_events(&mut batch);
        assert_eq!(batch.len(), 2);
        match batch[0].kind {
            BrowserInputKind::Resize { cols, .. } => assert_eq!(cols, 100),
            _ => panic!("expected resize event"),
        }
        assert!(matches!(batch[1].kind, BrowserInputKind::Mouse { .. }));
    }

    #[test]
    fn resize_coalescing_stops_at_non_resize_input() {
        let mut batch = vec![resize_event(1, 80), click_event(1), resize_event(1, 100)];

        coalesce_browser_events(&mut batch);

        assert_eq!(batch.len(), 3);
        assert!(matches!(batch[0].kind, BrowserInputKind::Resize { cols: 80, .. }));
        assert!(matches!(batch[1].kind, BrowserInputKind::Mouse { .. }));
        assert!(matches!(batch[2].kind, BrowserInputKind::Resize { cols: 100, .. }));
    }

    #[test]
    fn only_full_resizes_are_saved_for_fallback_delivery() {
        let (tx, rx) = sync_channel(1);
        let latest_resizes = Arc::new(Mutex::new(HashMap::new()));
        let dispatcher = BrowserInputDispatcher { tx, latest_resizes: latest_resizes.clone() };

        dispatcher.enqueue(click_event(1));
        dispatcher.enqueue(resize_event(1, 132));
        assert!(matches!(rx.recv().unwrap().kind, BrowserInputKind::Mouse { .. }));
        assert!(matches!(
            latest_resizes.lock().unwrap().get(&1).map(|event| &event.kind),
            Some(BrowserInputKind::Resize { cols: 132, .. })
        ));

        latest_resizes.lock().unwrap().clear();
        dispatcher.enqueue(resize_event(2, 144));
        assert!(latest_resizes.lock().unwrap().is_empty());
        assert!(matches!(rx.recv().unwrap().kind, BrowserInputKind::Resize { cols: 144, .. }));

        drop(rx);
        dispatcher.enqueue(resize_event(3, 156));
        assert!(latest_resizes.lock().unwrap().is_empty());
    }

    #[test]
    fn dropped_resize_slot_delivers_latest_geometry_after_queued_input() {
        let mut batch = vec![click_event(1)];
        let latest = HashMap::from([(1, resize_event(1, 132))]);

        merge_latest_resizes(&mut batch, latest);

        assert_eq!(batch.len(), 2);
        assert!(matches!(batch[0].kind, BrowserInputKind::Mouse { .. }));
        assert!(matches!(batch[1].kind, BrowserInputKind::Resize { cols: 132, .. }));
    }
}
