//! `notifications/tools/list_changed` for the app's action tools. A thread
//! reads the app's `events.stream` (blocking, no polling) and tells the
//! client to list the tools again when the app publishes
//! `action.catalog.changed` or comes back after it quit or restarted. While
//! the app is unreachable the thread waits with a doubling delay (a backoff
//! after a failure, never a fixed poll).

use std::io::{self, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{Value, json};

use super::super::GlobalArgs;

/// The app's event for a changed action registry
/// (`ControlRouter.actionCatalogChangedEvent`).
pub(super) const CATALOG_CHANGED: &str = "action.catalog.changed";
const FIRST_RETRY: Duration = Duration::from_millis(500);
const MAX_RETRY: Duration = Duration::from_secs(30);

/// The server's stdout, shared by the request loop and the watcher, and
/// whether the client finished initialization (no notification before it).
#[derive(Clone)]
pub(in crate::cli) struct Output {
    writer: Arc<Mutex<Box<dyn Write + Send>>>,
    ready: Arc<AtomicBool>,
}

impl Output {
    pub(super) fn new(writer: impl Write + Send + 'static) -> Self {
        Self { writer: Arc::new(Mutex::new(Box::new(writer))), ready: Arc::default() }
    }

    /// Writes one JSON-RPC message as one line.
    pub(super) fn send(&self, message: &Value) -> io::Result<()> {
        let mut bytes = serde_json::to_vec(message).map_err(io::Error::other)?;
        bytes.push(b'\n');
        let mut writer = self.writer.lock().map_err(|_| io::Error::other("stdout lock"))?;
        writer.write_all(&bytes)?;
        writer.flush()
    }

    pub(super) fn set_ready(&self) {
        self.ready.store(true, Ordering::Release);
    }

    /// `notifications/tools/list_changed`, once the client is initialized.
    pub(super) fn tools_changed(&self) -> io::Result<()> {
        if !self.ready.load(Ordering::Acquire) {
            return Ok(());
        }
        self.send(&json!({"jsonrpc": "2.0", "method": "notifications/tools/list_changed"}))
    }
}

/// Decides when the client must list the tools again.
#[derive(Debug, Default)]
pub(super) struct ActionWatch {
    /// The stream is open (its acknowledgement arrived).
    open: bool,
    /// The app was unreachable or the stream ended since the last open.
    gap: bool,
}

impl ActionWatch {
    /// One frame from the stream; `true` when the tools may have changed:
    /// the first frame after a gap (the app came back, maybe a new build) or
    /// an `action.catalog.changed` event.
    pub(super) fn frame(&mut self, frame: &Value) -> bool {
        if !self.open {
            self.open = true;
            return std::mem::take(&mut self.gap);
        }
        frame["type"] == "event" && frame["name"] == CATALOG_CHANGED
    }

    /// The stream ended or did not open. Returns whether it had opened.
    pub(super) fn lost(&mut self) -> bool {
        self.gap = true;
        std::mem::take(&mut self.open)
    }
}

/// Starts the watcher thread for the life of the process.
pub(super) fn spawn(global: GlobalArgs, output: Output) {
    let started = std::thread::Builder::new().name("cmux-mcp-actions".into()).spawn(move || {
        let params = json!({"names": [CATALOG_CHANGED], "include_heartbeats": false});
        let mut watch = ActionWatch::default();
        let mut delay = FIRST_RETRY;
        loop {
            let _ = super::transport::watch_app_events(&global, params.clone(), |frame| {
                if watch.frame(frame) {
                    let _ = output.tools_changed();
                }
            });
            if watch.lost() {
                delay = FIRST_RETRY;
            }
            // Backoff after a failure or a closed stream.
            std::thread::sleep(delay);
            delay = (delay * 2).min(MAX_RETRY);
        }
    });
    if let Err(error) = started {
        eprintln!("cmux mcp: cannot watch the app's actions: {error}");
    }
}
