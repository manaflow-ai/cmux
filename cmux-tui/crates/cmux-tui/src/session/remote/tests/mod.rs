//! Tests for the remote session, split by topic. Shared writers and session
//! fixtures live here; each child module holds the tests for one topic.

#[cfg(unix)]
use std::io::{BufRead, Read, Write};
#[cfg(unix)]
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicBool, AtomicU64};
use std::sync::mpsc::{Receiver, Sender};
use std::sync::{Condvar, Mutex, Weak};

use ghostty_vt::{Callbacks, ColorSpec, KeyAction, Mods, RenderState, Terminal};
use serde_json::json;

use super::*;

mod attach;
mod bootstrap;
mod browser;
mod events;
mod geometry;
mod identity;
mod mirror;
mod overflow;
mod refresh;
mod requests;
mod resize;
mod subscriptions;
mod transport;
mod writes;

fn attached_surface(outcome: RemoteSurfaceAttach) -> Arc<RemoteSurface> {
    let RemoteSurfaceAttach::Attached(surface) = outcome else {
        panic!("surface attach did not produce a mirror");
    };
    surface
}

pub(super) struct CloseTrackingWriter {
    pub(super) closed: Arc<AtomicBool>,
}

impl RemoteMessageWriter for CloseTrackingWriter {
    fn send(&mut self, _message: &str) -> io::Result<()> {
        Ok(())
    }

    fn close(&mut self) -> io::Result<()> {
        self.closed.store(true, Ordering::Release);
        Ok(())
    }
}

struct UnexpectedWriteWriter;

impl RemoteMessageWriter for UnexpectedWriteWriter {
    fn send(&mut self, message: &str) -> io::Result<()> {
        panic!("unexpected remote write: {message}")
    }

    fn close(&mut self) -> io::Result<()> {
        Ok(())
    }
}

struct AcknowledgingWriter {
    session: Arc<Mutex<Option<Weak<RemoteSession>>>>,
    requests: Option<Sender<Value>>,
}

impl RemoteMessageWriter for AcknowledgingWriter {
    fn send(&mut self, message: &str) -> io::Result<()> {
        let request: Value = serde_json::from_str(message).map_err(io::Error::other)?;
        if let Some(requests) = self.requests.as_ref() {
            requests
                .send(request.clone())
                .map_err(|_| io::Error::new(io::ErrorKind::BrokenPipe, "request reader exited"))?;
        }
        let id = request
            .get("id")
            .and_then(Value::as_u64)
            .ok_or_else(|| io::Error::other("remote request omitted its id"))?;
        let session = self
            .session
            .lock()
            .unwrap()
            .as_ref()
            .and_then(Weak::upgrade)
            .ok_or_else(|| io::Error::other("test remote session was dropped"))?;
        let response = session
            .pending
            .lock()
            .unwrap()
            .remove(&id)
            .ok_or_else(|| io::Error::other("remote request was not pending"))?;
        response
            .response
            .send(json!({"id": id, "ok": true, "data": null}))
            .map_err(|_| io::Error::other("remote response receiver was dropped"))
    }

    fn close(&mut self) -> io::Result<()> {
        Ok(())
    }
}

struct RecordingAcknowledgingWriter {
    session: Arc<Mutex<Option<Weak<RemoteSession>>>>,
    requests: Arc<Mutex<Vec<Value>>>,
}

impl RemoteMessageWriter for RecordingAcknowledgingWriter {
    fn send(&mut self, message: &str) -> io::Result<()> {
        let request: Value = serde_json::from_str(message).map_err(io::Error::other)?;
        self.requests.lock().unwrap().push(request.clone());
        let id = request
            .get("id")
            .and_then(Value::as_u64)
            .ok_or_else(|| io::Error::other("remote request omitted its id"))?;
        let session = self
            .session
            .lock()
            .unwrap()
            .as_ref()
            .and_then(Weak::upgrade)
            .ok_or_else(|| io::Error::other("test remote session was dropped"))?;
        let response = session
            .pending
            .lock()
            .unwrap()
            .remove(&id)
            .ok_or_else(|| io::Error::other("remote request was not pending"))?;
        response
            .response
            .send(json!({"id": id, "ok": true, "data": null}))
            .map_err(|_| io::Error::other("remote response receiver was dropped"))
    }

    fn close(&mut self) -> io::Result<()> {
        Ok(())
    }
}

fn test_session_with_provider_context(
    writer: Box<dyn RemoteMessageWriter>,
    capabilities: HashSet<String>,
    provider_workspace_authority: Option<BearerToken>,
) -> Arc<RemoteSession> {
    test_session_with_abort_and_context(
        writer,
        Arc::new(NoopTransportAbort),
        capabilities,
        provider_workspace_authority,
    )
}

fn test_session_with_abort_and_context(
    writer: Box<dyn RemoteMessageWriter>,
    abort: Arc<dyn RemoteTransportAbort>,
    capabilities: HashSet<String>,
    provider_workspace_authority: Option<BearerToken>,
) -> Arc<RemoteSession> {
    Arc::new(RemoteSession {
        interactive_writer: InteractiveWriter::spawn(writer, abort).unwrap(),
        disconnect_state: disconnect::DisconnectCell::default(),
        pending: Mutex::new(PendingRemoteRequests::default()),
        next_id: AtomicU64::new(1),
        attach_progress: AtomicU64::new(0),
        shutdown: AtomicBool::new(false),
        surfaces: Mutex::new(HashMap::new()),
        exited_surfaces: Mutex::new(ExitedSurfaceState::default()),
        surface_leases: Mutex::new(HashMap::new()),
        retired_surfaces: Mutex::new(HashSet::new()),
        retire_surface_test_marker: Mutex::new(None),
        tree: Mutex::new(RemoteTreeCache::default()),
        browser_sources: Mutex::new(HashMap::new()),
        tree_refresh: Mutex::new(()),
        tree_stale: AtomicBool::new(true),
        subscription_started: AtomicBool::new(false),
        event_surface_filter: AtomicU64::new(0),
        subscription_recovery: Mutex::new(SubscriptionRecoveryState::default()),
        subscribers: MuxEventBroadcaster::default(),
        primed_subscription: Mutex::new(None),
        frame_dump_dir: None,
        frame_logs: Mutex::new(RemoteFrameLogs::default()),
        surface_overflow_recovery: Mutex::new(HashMap::new()),
        surface_overflow_reconnect_required: AtomicBool::new(false),
        cell_pixel_lifecycle: Mutex::new(()),
        cell_pixels: Mutex::new((8, 16)),
        capabilities: Mutex::new(capabilities),
        size_states: Mutex::new(HashMap::new()),
        provider_workspace_authority,
        provider_workspaces_guarded: AtomicBool::new(false),
    })
}

pub(super) fn test_session(writer: Box<dyn RemoteMessageWriter>) -> Arc<RemoteSession> {
    test_session_with_provider_context(writer, HashSet::new(), None)
}

fn test_remote_pty_surface(
    id: SurfaceId,
    cols: u16,
    rows: u16,
    cell_pixels: (u16, u16),
) -> Arc<RemoteSurface> {
    let mut term = Terminal::new(cols, rows, 100, Callbacks::default()).unwrap();
    term.resize(cols, rows, u32::from(cell_pixels.0), u32::from(cell_pixels.1)).unwrap();
    Arc::new(RemoteSurface {
        id,
        kind: SurfaceKind::Pty,
        term: Mutex::new(term),
        mouse_encoders: Mutex::new(MouseEncoders::new().unwrap()),
        cursor_provenance: Mutex::new(CursorStyleProvenance::default()),
        dirty: AtomicBool::new(false),
        geometry_lifecycle: Mutex::new(()),
        cell_pixels: Mutex::new(cell_pixels),
        geometry_test_hook: Mutex::new(None),
        content_generation: AtomicU64::new(1),
        reported_size: Mutex::new(None),
        browser: Mutex::new(RemoteBrowserState::default()),
    })
}

struct RejectingWriter {
    session: Arc<Mutex<Option<Weak<RemoteSession>>>>,
}

impl RemoteMessageWriter for RejectingWriter {
    fn send(&mut self, message: &str) -> io::Result<()> {
        let request: Value = serde_json::from_str(message).map_err(io::Error::other)?;
        let id = request
            .get("id")
            .and_then(Value::as_u64)
            .ok_or_else(|| io::Error::other("remote request omitted its id"))?;
        let session = self
            .session
            .lock()
            .unwrap()
            .as_ref()
            .and_then(Weak::upgrade)
            .ok_or_else(|| io::Error::other("test remote session was dropped"))?;
        let response = session
            .pending
            .lock()
            .unwrap()
            .remove(&id)
            .ok_or_else(|| io::Error::other("remote request was not pending"))?;
        response
            .response
            .send(json!({"id": id, "ok": false, "error": "injected rejection"}))
            .map_err(|_| io::Error::other("remote response receiver was dropped"))
    }

    fn close(&mut self) -> io::Result<()> {
        Ok(())
    }
}

pub(super) struct SilentWriter;

impl RemoteMessageWriter for SilentWriter {
    fn send(&mut self, _message: &str) -> io::Result<()> {
        Ok(())
    }

    fn close(&mut self) -> io::Result<()> {
        Ok(())
    }
}

#[cfg(unix)]
fn socket_test_session(stream: UnixStream) -> Arc<RemoteSession> {
    stream.set_write_timeout(Some(remote_write_timeout())).unwrap();
    test_session(Box::new(JsonLineWriter { inner: Box::new(stream) }))
}

fn test_remote_surface(id: SurfaceId) -> Arc<RemoteSurface> {
    Arc::new(RemoteSurface {
        id,
        kind: SurfaceKind::Pty,
        term: Mutex::new(Terminal::new(80, 24, 100, Callbacks::default()).unwrap()),
        mouse_encoders: Mutex::new(MouseEncoders::new().unwrap()),
        cursor_provenance: Mutex::new(CursorStyleProvenance::default()),
        dirty: AtomicBool::new(false),
        geometry_lifecycle: Mutex::new(()),
        cell_pixels: Mutex::new((8, 16)),
        geometry_test_hook: Mutex::new(None),
        content_generation: AtomicU64::new(1),
        reported_size: Mutex::new(None),
        browser: Mutex::new(RemoteBrowserState::default()),
    })
}
