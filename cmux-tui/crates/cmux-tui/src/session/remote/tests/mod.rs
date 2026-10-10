//! Tests for the remote session, split by topic. Shared writers and session
//! fixtures live here; each child module holds the tests for one topic.

#[cfg(unix)]
use std::io::{BufRead, Write};
#[cfg(unix)]
use std::os::unix::net::UnixStream;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, AtomicU64};

use serde_json::json;

use super::*;

mod attach;
mod resize;
mod transport;

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
