//! The core half of the DEV owner orphan exit (the policy and its watcher
//! live in the cmux-tui crate, `headless/dev_orphan_exit.rs`).
//!
//! The registry tells its observers each time a client connects or leaves,
//! so the watcher can time how long the owner has had no client at all (the
//! lost-paths exit, cmux-tui `headless/lost_paths.rs`, listens too). The
//! owner's own journal plugin (the bundled screen detector, which connects
//! back at start and stays) is not such a client: a connection from that
//! plugin's process group is classified before it registers and is not
//! counted (cmux issue 23086: every DEV owner and Chief owner kept itself
//! alive through it).
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
    /// Adds a callback for client arrivals and departures. Each runs with
    /// no registry lock held; none may add another (the list's lock is held
    /// while they run).
    pub(crate) fn add_client_presence_observer(&self, observer: impl Fn() + Send + Sync + 'static) {
        self.client_presence_observers
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .push(Box::new(observer));
    }

    pub(crate) fn notify_client_presence(&self) {
        for observer in self
            .client_presence_observers
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .iter()
        {
            observer();
        }
    }

    /// Connected clients, of any role.
    pub(crate) fn client_count(&self) -> usize {
        self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner).clients.len()
    }

    /// Connected clients other than the owner's own journal plugin.
    pub(crate) fn user_client_count(&self) -> usize {
        let state = self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        state.clients.values().filter(|record| !record.owner_plugin).count()
    }

    /// Reserves the daemon handoff for an orphan exit, atomically with the
    /// check that no client is connected. While it is held, a new
    /// connection is closed at registration. False when a client other
    /// than the owner's own plugin is connected or another handoff runs.
    fn begin_orphan_shutdown(&self) -> bool {
        self.begin_owner_shutdown(true)
    }

    /// Reserves the daemon handoff for an exit the owner starts itself (an
    /// orphan exit, or the exit of the process it was started for,
    /// `starter_exit`). With `require_no_clients`, only while no client other
    /// than the owner's own plugin is connected. False when another handoff
    /// runs (or such a client is connected and `require_no_clients`).
    pub(super) fn begin_owner_shutdown(&self, require_no_clients: bool) -> bool {
        let mut state = self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if state.daemon_handoff.is_some()
            || (require_no_clients && state.clients.values().any(|record| !record.owner_plugin))
        {
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

    /// Number of connected clients other than the owner's own journal
    /// plugin: the clients the orphan exit waits on.
    pub fn user_client_count(&self) -> usize {
        self.control_clients.user_client_count()
    }

    /// Calls `observer` (with no registry lock held) each time a client
    /// connects or leaves, along with every observer added before it.
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

/// Whether a new local connection's peer is in the owner's journal plugin
/// process group (its `register_classified` flag). The supervisor records
/// its child under the same lock it spawns under, so the plugin's own
/// connection always finds its group here.
#[cfg(unix)]
pub(super) fn is_owner_plugin_peer(mux: &Mux, peer_key: Option<&str>) -> bool {
    let Some(pid) = peer_key.and_then(origin_gate::peer_pid) else { return false };
    let Some(group) = mux.journal_plugin_process_group() else { return false };
    let Ok(pid) = libc::pid_t::try_from(pid) else { return false };
    // SAFETY: getpgid only reads kernel metadata for a positive pid. A pid
    // reused since the connect can match only when its new process is a
    // live member of the plugin's own group.
    unsafe { libc::getpgid(pid) == group }
}

/// No process-group check off Unix, so a plugin connection counts as a
/// client there. The orphan watcher runs only for macOS DEV bundles.
#[cfg(not(unix))]
pub(super) fn is_owner_plugin_peer(_mux: &Mux, _peer_key: Option<&str>) -> bool {
    false
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
/// `server stop`; every terminal and its host keep running. Only the owner's
/// own journal plugin may still be connected. `still_orphaned`
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
