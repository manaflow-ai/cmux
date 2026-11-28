//! The core half of the DEV owner orphan exit (the policy and its watcher
//! live in the cmux-tui crate, `headless/dev_orphan_exit.rs`).
//!
//! The registry tells one observer each time a client connects or leaves, so
//! the watcher can time how long the owner has had no client at all.
//! [`stop_orphaned_owner`] then stops the OWNER only, the way `server stop`
//! without `end_terminals` does: no terminal ends and no terminal host is
//! signalled. The hosts keep running for the next owner of the session to
//! adopt. It acts only while no client is connected, fenced so that no
//! client can join while it decides.

use super::*;

/// The registry's handoff reservation holder for an orphan exit. Client ids
/// start at 1, so no connection can own or release it.
const ORPHAN_SHUTDOWN_REQUESTER: u64 = 0;

impl ClientRegistry {
    /// Installs the callback for client arrivals and departures. It runs
    /// with no registry lock held.
    pub(crate) fn set_client_presence_observer(&self, observer: impl Fn() + Send + Sync + 'static) {
        *self.client_presence_observer.lock().unwrap_or_else(std::sync::PoisonError::into_inner) =
            Some(Box::new(observer));
    }

    pub(crate) fn notify_client_presence(&self) {
        if let Some(observer) = self
            .client_presence_observer
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_ref()
        {
            observer();
        }
    }

    /// Connected clients, of any role.
    pub(crate) fn client_count(&self) -> usize {
        self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner).clients.len()
    }

    /// Reserves the daemon handoff for an orphan exit, atomically with the
    /// check that no client is connected. While it is held, a new
    /// connection is closed at registration. False when a client is
    /// connected or another handoff runs.
    fn begin_orphan_shutdown(&self) -> bool {
        let mut state = self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if state.daemon_handoff.is_some() || !state.clients.is_empty() {
            return false;
        }
        state.daemon_handoff = Some(DaemonHandoffReservation::Pending(ORPHAN_SHUTDOWN_REQUESTER));
        true
    }
}

impl Mux {
    /// Number of connected clients, of any role.
    pub fn client_count(&self) -> usize {
        self.control_clients.client_count()
    }

    /// Calls `observer` (with no registry lock held) each time a client
    /// connects or leaves.
    pub fn set_client_presence_observer(&self, observer: impl Fn() + Send + Sync + 'static) {
        self.control_clients.set_client_presence_observer(observer);
    }

    /// Live hosted terminals (launching, adopting or running).
    pub fn live_terminal_count(&self) -> anyhow::Result<usize> {
        Ok(self
            .terminal_registry_snapshot()?
            .terminals
            .iter()
            .filter(|terminal| {
                use crate::workspace_registry::TerminalLifecycle as Lifecycle;
                matches!(
                    terminal.lifecycle,
                    Lifecycle::Launching | Lifecycle::Adopting | Lifecycle::Running
                )
            })
            .count())
    }
}

/// Releases the orphan reservation unless the exit committed, also when the
/// policy check panics, so a stuck fence can never refuse every later
/// client.
struct OrphanFence<'a> {
    clients: &'a ClientRegistry,
    committed: bool,
}

impl Drop for OrphanFence<'_> {
    fn drop(&mut self) {
        if !self.committed {
            self.clients.cancel_daemon_handoff(ORPHAN_SHUTDOWN_REQUESTER);
        }
    }
}

/// Stops an orphaned owner: the owner loop is asked to leave as on a plain
/// `server stop`; every terminal and its host keep running. `still_orphaned`
/// runs under the fence (no client can connect meanwhile) and repeats the
/// caller's policy check, so a terminal or client that appeared since the
/// caller looked keeps the owner. `false` changes nothing: a client is
/// connected, another handoff runs, or the check no longer holds.
pub fn stop_orphaned_owner(mux: &Arc<Mux>, still_orphaned: impl FnOnce() -> bool) -> bool {
    if !mux.control_clients.begin_orphan_shutdown() {
        return false;
    }
    let mut fence = OrphanFence { clients: &mux.control_clients, committed: false };
    if !still_orphaned() {
        return false;
    }
    if mux
        .control_clients
        .commit_daemon_handoff_after_ack(ORPHAN_SHUTDOWN_REQUESTER, || Ok(()))
        .is_err()
    {
        return false;
    }
    fence.committed = true;
    mux.request_daemon_shutdown();
    true
}
