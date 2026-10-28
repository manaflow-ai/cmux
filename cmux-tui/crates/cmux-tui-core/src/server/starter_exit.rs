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
//! The wait is an event (macOS: kqueue `EVFILT_PROC` `NOTE_EXIT`; Linux: a
//! pidfd), never a poll, on one thread that holds no reference to the mux.
//! It ends when the watched process exits, or with this process.

use super::*;

/// Starts the watcher. A `pid` that already exited stops the owner at once.
pub fn exit_with_process(mux: &Arc<Mux>, pid: u32) -> std::io::Result<()> {
    let watched = Arc::downgrade(mux);
    std::thread::Builder::new().name("owner-exit-with-pid".into()).spawn(move || {
        if let Err(error) = crate::state::status_owners::wait_for_process_exit(pid) {
            // A watch that cannot start leaves the owner as it would be
            // without the option; the caller already checked the pid.
            eprintln!("cmux-tui: cannot watch process {pid} for --exit-with-pid: {error}");
            return;
        }
        let Some(mux) = watched.upgrade() else { return };
        eprintln!("cmux-tui: process {pid} this owner was started for exited; stopping");
        stop_for_exited_starter(&mux);
    })?;
    Ok(())
}

/// Ends every terminal, then stops the owner as `shutdown-daemon
/// end_terminals` does. The owner stops even when a terminal could not be
/// ended: nothing is left to serve. False when another handoff already runs
/// (that one stops or keeps the owner).
pub(crate) fn stop_for_exited_starter(mux: &Arc<Mux>) -> bool {
    // Fence new clients while the terminals end. A client still connected is
    // not waited for: the process the owner serves is gone.
    if !mux.control_clients.begin_owner_shutdown(false) {
        return false;
    }
    if let Err(error) = mux.end_all_terminals() {
        eprintln!("cmux-tui: --exit-with-pid could not end every terminal: {error:#}");
    }
    let committed = mux
        .control_clients
        .commit_daemon_handoff_after_ack(orphan_shutdown::ORPHAN_SHUTDOWN_REQUESTER, || Ok(()))
        .is_ok();
    mux.request_daemon_shutdown();
    committed
}
