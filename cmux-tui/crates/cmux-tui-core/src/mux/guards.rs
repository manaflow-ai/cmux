//! Small Mux state holders: pending terminal host binding and release guards, the pending workspace surface guard, the resource wait wake signal, config reload state, and the client focus record.

use super::*;

#[cfg(any(unix, windows))]
pub(crate) struct PendingTerminalHostBinding {
    pub(super) mux: Weak<Mux>,
    pub(super) surface_id: SurfaceId,
    pub(super) identity: TerminalHostIdentity,
}

#[cfg(any(unix, windows))]
impl Drop for PendingTerminalHostBinding {
    fn drop(&mut self) {
        let Some(mux) = self.mux.upgrade() else { return };
        let mut pending = mux.pending_terminal_hosts.lock().unwrap();
        if pending.get(&self.surface_id) == Some(&self.identity) {
            pending.remove(&self.surface_id);
        }
    }
}

#[cfg(any(unix, windows))]
pub(super) struct PendingTerminalHostRelease(pub(super) Arc<Surface>);

#[cfg(any(unix, windows))]
impl Drop for PendingTerminalHostRelease {
    fn drop(&mut self) {
        self.0.release_pending_terminal_host_binding();
    }
}

pub(super) struct PendingWorkspaceSurface<'a> {
    pub(super) pending: &'a Mutex<HashMap<SurfaceId, WorkspaceId>>,
    pub(super) surface: SurfaceId,
}

impl Drop for PendingWorkspaceSurface<'_> {
    fn drop(&mut self) {
        self.pending.lock().unwrap().remove(&self.surface);
    }
}

/// One-shot wakeup shared by a terminal-exit subscription and any
/// connection-owned cancellation sources. The durable terminal registry
/// remains authoritative; this only decides when a waiter should query it.
pub(crate) struct ResourceWaitWake {
    pub(super) notified: Mutex<bool>,
    pub(super) changed: Condvar,
}

impl Default for ResourceWaitWake {
    fn default() -> Self {
        Self { notified: Mutex::new(false), changed: Condvar::new() }
    }
}

impl ResourceWaitWake {
    pub(crate) fn notify(&self) {
        let mut notified = self.notified.lock().unwrap();
        *notified = true;
        self.changed.notify_all();
    }

    /// Returns true for an explicit wake and false when the deadline expires.
    pub(crate) fn wait_until(&self, deadline: Option<Instant>) -> bool {
        let mut notified = self.notified.lock().unwrap();
        while !*notified {
            match deadline {
                Some(deadline) => {
                    let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
                        return false;
                    };
                    let (next, timeout) = self.changed.wait_timeout(notified, remaining).unwrap();
                    notified = next;
                    if timeout.timed_out() && !*notified {
                        return false;
                    }
                }
                None => notified = self.changed.wait(notified).unwrap(),
            }
        }
        true
    }
}

/// The multiplexer. Shared by frontends and the control socket server.
#[derive(Default)]
pub(super) struct ConfigReloadState {
    pub(super) requested: u64,
    pub(super) applied: u64,
}

/// One client's most recently reported focus (client-focus-v1).
#[derive(Clone)]
pub(super) struct ClientFocusRecord {
    pub(super) client_id: String,
    pub(super) pane: PaneId,
    pub(super) tab: Option<usize>,
}

/// Bounded size of the per-client focus memory.
pub(super) const CLIENT_FOCUS_MEMORY_LIMIT: usize = 64;
