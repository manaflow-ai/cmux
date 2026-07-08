//! Off-loop browser command forwarding.
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
//! Results are intentionally discarded: browser commands report their
//! user-visible errors through the surface's own status (`BrowserStatus`)
//! and status events.

use std::sync::mpsc::{sync_channel, Receiver, Sender, SyncSender};

use mux_core::{MuxEvent, SurfaceId};

use crate::app::AppEvent;
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
    Navigate(String),
    Back,
    Forward,
    Reload,
    Activate,
}

impl BrowserInputKind {
    /// Mouse moves carry only a position; when several are queued for
    /// the same surface, only the newest matters.
    fn is_mouse_move(&self) -> bool {
        matches!(self, BrowserInputKind::Mouse { event_type: "mouseMoved", .. })
    }

    /// Discrete control actions the user explicitly invoked. Unlike disposable
    /// pointer/key input, a control command that fails to reach the browser
    /// must surface backpressure instead of vanishing.
    fn is_control(&self) -> bool {
        matches!(
            self,
            BrowserInputKind::Navigate(_)
                | BrowserInputKind::Back
                | BrowserInputKind::Forward
                | BrowserInputKind::Reload
                | BrowserInputKind::Activate
        )
    }
}

pub struct BrowserInputDispatcher {
    tx: SyncSender<BrowserInputEvent>,
}

impl BrowserInputDispatcher {
    /// `feedback` is the app event channel. A discrete control command that
    /// fails inside the worker (per-surface queue full, surface closed, or a
    /// remote request error) reports back through it as a status event so the
    /// user sees the command did not take effect; disposable input errors stay
    /// discarded.
    pub fn spawn(feedback: Sender<AppEvent>) -> anyhow::Result<Self> {
        let (tx, rx) = sync_channel(QUEUE_CAPACITY);
        std::thread::Builder::new()
            .name("mux-browser-input".into())
            .spawn(move || worker(rx, feedback))?;
        Ok(BrowserInputDispatcher { tx })
    }

    /// Queue an event; never blocks. Returns `false` when the queue is
    /// full (the worker is wedged inside a blocking browser call) and the
    /// event was dropped. Disposable input (mouse/key) may ignore the
    /// result, but discrete control commands (navigate/back/forward/
    /// reload/activate) must surface backpressure to the user instead of
    /// dropping silently: a reload the user asked for that never runs and
    /// gives no feedback is a bug, unlike a coalesced mouse move.
    #[must_use = "control commands must surface backpressure instead of dropping silently"]
    pub fn enqueue(&self, event: BrowserInputEvent) -> bool {
        self.tx.try_send(event).is_ok()
    }
}

#[cfg(test)]
impl BrowserInputDispatcher {
    /// Build a dispatcher whose worker never runs, so the caller can hold
    /// the receiver and saturate the queue deterministically.
    fn without_worker() -> (Self, Receiver<BrowserInputEvent>) {
        let (tx, rx) = sync_channel(QUEUE_CAPACITY);
        (BrowserInputDispatcher { tx }, rx)
    }
}

fn worker(rx: Receiver<BrowserInputEvent>, feedback: Sender<AppEvent>) {
    while let Ok(event) = rx.recv() {
        // Drain whatever queued behind the first event so mouse moves
        // can be coalesced across the batch.
        let mut batch = vec![event];
        while let Ok(next) = rx.try_recv() {
            batch.push(next);
        }
        coalesce_mouse_moves(&mut batch);
        for event in batch {
            dispatch(&event, &feedback);
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

fn dispatch(event: &BrowserInputEvent, feedback: &Sender<AppEvent>) {
    let surface = &event.surface;
    let result = match &event.kind {
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
        BrowserInputKind::Navigate(url) => surface.browser_navigate(url),
        BrowserInputKind::Back => surface.browser_back(),
        BrowserInputKind::Forward => surface.browser_forward(),
        BrowserInputKind::Reload => surface.browser_reload(),
        BrowserInputKind::Activate => surface.browser_activate(),
    };
    // Disposable input errors are discarded by design (a wedged browser
    // surfaces itself via BrowserStatus). A discrete control command the user
    // invoked must not fail silently here: the outer queue already accepted it,
    // so this inner failure (per-surface queue full, surface closed, remote
    // request error) is the only place left to report it. Surface it as a
    // status event, matching the outer-queue backpressure path.
    if event.kind.is_control() {
        if let Err(err) = result {
            let _ = feedback
                .send(AppEvent::Mux(MuxEvent::Status(format!("browser command failed: {err}"))));
        }
    }
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

    fn reload_event(surface: SurfaceId) -> BrowserInputEvent {
        BrowserInputEvent {
            surface_id: surface,
            surface: SurfaceHandle::RemoteBrowserUnsupported,
            kind: BrowserInputKind::Reload,
        }
    }

    // Regression: a full dispatcher queue (worker wedged inside a blocking
    // browser call) must report the drop so control commands can surface
    // backpressure to the user, instead of the old `let _ = try_send` that
    // swallowed the failure and made a dropped reload/navigate look accepted.
    #[test]
    fn full_queue_reports_drop_instead_of_swallowing_it() {
        let (dispatcher, _rx) = BrowserInputDispatcher::without_worker();
        for _ in 0..QUEUE_CAPACITY {
            assert!(dispatcher.enqueue(reload_event(1)), "queue should accept until full");
        }
        assert!(
            !dispatcher.enqueue(reload_event(1)),
            "a full queue must report the drop, not swallow it as accepted"
        );
    }

    // Regression: a discrete control command that fails inside the worker
    // (here: RemoteBrowserUnsupported bails) must report a status event so the
    // user learns it did not take effect, instead of the old `let _ = ...` that
    // swallowed the inner result even after the outer queue accepted it.
    // Disposable input must not report.
    #[test]
    fn failed_control_command_reports_status_but_input_does_not() {
        use std::sync::mpsc::channel;
        let (tx, rx) = channel::<AppEvent>();

        dispatch(&reload_event(1), &tx);
        match rx.try_recv() {
            Ok(AppEvent::Mux(MuxEvent::Status(msg))) => {
                assert!(msg.contains("browser command failed"), "unexpected message: {msg}");
            }
            Ok(_) => panic!("control failure emitted a non-status event"),
            Err(_) => panic!("a failed control command must emit a status event"),
        }

        // Disposable input never reports, so the worker stays quiet for it.
        dispatch(&move_event(1, 1.0), &tx);
        assert!(rx.try_recv().is_err(), "disposable input must not emit status feedback");
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
