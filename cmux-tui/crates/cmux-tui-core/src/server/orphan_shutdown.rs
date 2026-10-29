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
pub(super) const ORPHAN_SHUTDOWN_REQUESTER: u64 = 0;

impl ClientRegistry {
    /// Adds a callback for client arrivals and departures. It runs with no
    /// registry lock held.
    pub(crate) fn add_client_presence_observer(&self, observer: impl Fn() + Send + Sync + 'static) {
        self.client_presence_observers
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .push(Box::new(observer));
    }

    pub(crate) fn notify_client_presence(&self) {
        let observers = self
            .client_presence_observers
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        for observer in observers.iter() {
            observer();
        }
    }

    /// Connected clients, of any role, except the connections of `own_plugin`
    /// (the daemon's own journal plugin, a reader of this daemon that needs it
    /// only while something else does; cp/quit-chief-idle).
    pub(crate) fn client_count(&self, own_plugin: Option<u32>) -> usize {
        let state = self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        state.clients.values().filter(|record| !is_own_plugin(record, own_plugin)).count()
    }

    /// Reserves the daemon handoff for an orphan exit, atomically with the
    /// check that no client but the daemon's own plugin is connected. While
    /// it is held, a new connection is closed at registration. False when a
    /// client is connected or another handoff runs.
    fn begin_orphan_shutdown(&self, own_plugin: Option<u32>) -> bool {
        self.begin_owner_shutdown(true, own_plugin)
    }

    /// Reserves the daemon handoff for an exit the owner starts itself (an
    /// orphan exit, or the exit of the process it was started for,
    /// `starter_exit`). With `require_no_clients`, only while no client but
    /// `own_plugin` (the daemon's own plugin) is connected. False when another
    /// handoff runs (or such a client is connected and `require_no_clients`).
    pub(super) fn begin_owner_shutdown(&self, require_no_clients: bool, own_plugin: Option<u32>) -> bool {
        let mut state = self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if state.daemon_handoff.is_some()
            || (require_no_clients
                && state.clients.values().any(|record| !is_own_plugin(record, own_plugin)))
        {
            return false;
        }
        state.daemon_handoff = Some(DaemonHandoffReservation::Pending(ORPHAN_SHUTDOWN_REQUESTER));
        true
    }
}

/// Whether `record`'s socket peer is `own_plugin`, by the kernel's peer pid
/// at accept (`origin.peer_key`); a connection with no known peer counts.
fn is_own_plugin(record: &ClientRecord, own_plugin: Option<u32>) -> bool {
    own_plugin.is_some()
        && record.origin.peer_key.as_deref().and_then(origin_gate::peer_pid) == own_plugin
}

impl Mux {
    /// Number of connected clients, of any role, except the daemon's own
    /// journal plugin (`cmux-agent-screen-detection`): it connects to this
    /// daemon for the daemon's whole life, so with it counted no exit that
    /// waits for "no client" could ever fire.
    pub fn client_count(&self) -> usize {
        self.control_clients.client_count(self.journal_plugin_pid())
    }

    /// Adds `observer`, called (with no registry lock held) each time a
    /// client connects or leaves; the DEV orphan exit and the idle exit both watch.
    pub fn add_client_presence_observer(&self, observer: impl Fn() + Send + Sync + 'static) {
        self.control_clients.add_client_presence_observer(observer);
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
    if !mux.control_clients.begin_orphan_shutdown(mux.journal_plugin_pid()) {
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
