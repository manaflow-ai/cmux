//! `--exit-with-pid`: an owner started for one process ends with it.
//!
//! A session owner is detached on purpose (`setsid`, and the `server ensure`
//! that spawns it exits at once), so its parent is always launchd or init
//! and a parent-death signal cannot tell when the process it serves is gone.
//! A test harness that starts a throwaway owner names its own pid instead
//! (`server ensure --exit-with-pid <pid>`). When that process exits, by a
//! crash, a time limit or a cancelled CI job, the owner ends every terminal
//! as `server stop --end-terminals` does and stops; it never outlives the
//! harness by hours. The app's own owners never get the option: they outlive
//! the app by design.
//!
//! The process is named by its pid and kernel start time ([`Starter`]), so a
//! reused pid never stands in for it. The wait is an event (macOS: kqueue
//! `EVFILT_PROC` `NOTE_EXIT`; Linux: a pidfd), never a poll, on one thread
//! that holds no strong reference to the mux. It ends when the watched
//! process exits, or with this process.

use std::time::Duration;

use super::*;

/// How often a stop that found another handoff running (a client's
/// `shutdown-daemon`, a version handoff) tries again, until that handoff
/// stops the owner or is cancelled.
const HANDOFF_RETRY: Duration = Duration::from_millis(250);

/// The process an owner was started for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Starter {
    pub pid: u32,
    /// Kernel start time in milliseconds since the epoch. 0 only for an
    /// owner started by hand with a bare pid: then the pid alone names it.
    pub started_ms: u64,
}

impl Starter {
    /// The running process `pid` with its known start time; `None` when no
    /// process runs under it or its start time cannot be read (a process
    /// that exits while it is read), so `server ensure` never hands an owner
    /// an identity that any later process under the pid would match.
    pub fn current(pid: u32) -> Option<Self> {
        let started_ms =
            crate::process_identity::started_ms(pid).filter(|started| *started != 0)?;
        crate::state::status_owners::process_is_running(pid).then_some(Self { pid, started_ms })
    }

    /// Whether `pid` still names this process (not a later one that reused
    /// the pid).
    fn still_running(self) -> bool {
        crate::state::status_owners::process_is_running(self.pid)
            && same_process(self.started_ms, crate::process_identity::started_ms(self.pid))
    }
}

/// Whether a process now under the pid, started at `current` (`None` when
/// unreadable), is the one recorded as started at `recorded`. A known start
/// time matches only itself: an unreadable one never stands in for it.
pub(super) fn same_process(recorded: u64, current: Option<u64>) -> bool {
    recorded == 0 || current == Some(recorded)
}

/// Stops refused because another handoff ran (tests wait on it to prove the
/// watcher met the running handoff before it is cancelled).
#[cfg(test)]
pub(super) static REFUSED_STOPS: std::sync::atomic::AtomicUsize =
    std::sync::atomic::AtomicUsize::new(0);

/// Starts the watcher. A starter that already exited stops the owner at
/// once. Call it once the owner has started (its terminals restored and its
/// startup work begun), so the stop ends every terminal startup made.
pub fn exit_with_process(mux: &Arc<Mux>, starter: Starter) -> std::io::Result<()> {
    let watched = Arc::downgrade(mux);
    std::thread::Builder::new().name("owner-exit-with-pid".into()).spawn(move || {
        let pid = starter.pid;
        let waited =
            crate::state::status_owners::wait_for_process_exit_if(pid, || starter.still_running());
        if let Err(error) = waited {
            // A watch that cannot start leaves the owner as it would be
            // without the option.
            eprintln!("cmux-tui: cannot watch process {pid} for --exit-with-pid: {error}");
            return;
        }
        eprintln!("cmux-tui: process {pid} this owner was started for exited; stopping");
        loop {
            let Some(mux) = watched.upgrade() else { return };
            if mux.daemon_shutdown_requested() || stop_for_exited_starter(&mux) {
                return;
            }
            drop(mux);
            #[cfg(test)]
            REFUSED_STOPS.fetch_add(1, Ordering::SeqCst);
            std::thread::sleep(HANDOFF_RETRY);
        }
    })?;
    Ok(())
}

/// Releases the reservation unless the stop committed, also when ending
/// the terminals panics, so no stuck fence refuses every later client.
pub(super) struct StopFence<'a> {
    pub(super) mux: &'a Mux,
    pub(super) committed: bool,
}

impl Drop for StopFence<'_> {
    fn drop(&mut self) {
        if !self.committed {
            self.mux
                .control_clients
                .cancel_daemon_handoff(orphan_shutdown::ORPHAN_SHUTDOWN_REQUESTER);
        }
    }
}

/// Ends every terminal, then stops the owner as `shutdown-daemon
/// end_terminals` does. The owner stops even when a terminal could not be
/// ended: nothing is left to serve. False when another handoff runs (the
/// caller tries again) or the reservation changed before the commit.
pub(crate) fn stop_for_exited_starter(mux: &Arc<Mux>) -> bool {
    // Fence new clients while the terminals end. A client still connected is
    // not waited for: the process the owner serves is gone.
    if !mux.control_clients.begin_owner_shutdown(false) {
        return false;
    }
    let mut fence = StopFence { mux, committed: false };
    if let Err(error) = mux.end_all_terminals() {
        eprintln!("cmux-tui: --exit-with-pid could not end every terminal: {error:#}");
    }
    if mux
        .control_clients
        .commit_daemon_handoff_after_ack(orphan_shutdown::ORPHAN_SHUTDOWN_REQUESTER, || Ok(()))
        .is_err()
    {
        return false;
    }
    fence.committed = true;
    mux.request_daemon_shutdown();
    true
}
