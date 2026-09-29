//! Asynchronous terminal-host shutdown after a committed close.
//!
//! A terminal close commits its tombstone and removes every view first, so
//! the tree and the reply reflect the close at once. Ending the host process
//! can take up to [`TERMINAL_HOST_CLOSE_WAIT`]: the close path sends the host
//! its termination request immediately and hands the wait for the durable
//! exit receipt to a small worker pool. Many closes therefore end their hosts
//! in parallel instead of one after another on the requesting connection.

#[cfg(unix)]
use std::collections::VecDeque;
#[cfg(unix)]
use std::path::PathBuf;

use super::*;

/// Upper bound on concurrent host-exit waiters. Every host already received
/// its termination request, so a waiter only observes an exit in progress.
#[cfg(unix)]
const MAX_HOST_CLOSE_WORKERS: usize = 8;

#[cfg(unix)]
struct PendingHostClose {
    runtime: Arc<Surface>,
    termination: crate::surface::HostTermination,
    identity: Option<TerminalHostIdentity>,
    host_root: Option<PathBuf>,
    deadline: Instant,
}

#[derive(Default)]
#[cfg_attr(not(unix), allow(dead_code))]
struct HostCloseState {
    #[cfg(unix)]
    queue: VecDeque<PendingHostClose>,
    workers: usize,
    /// Closes queued or in progress.
    pending: usize,
}

/// Shared queue of hosts that were asked to exit.
#[derive(Default)]
pub(crate) struct TerminalHostCloses {
    state: Mutex<HostCloseState>,
    idle: Condvar,
}

impl TerminalHostCloses {
    #[cfg(unix)]
    fn enqueue(self: &Arc<Self>, close: PendingHostClose) {
        let spawn = {
            let mut state = self.state.lock().unwrap();
            state.queue.push_back(close);
            state.pending += 1;
            if state.workers < MAX_HOST_CLOSE_WORKERS {
                state.workers += 1;
                true
            } else {
                false
            }
        };
        if !spawn {
            return;
        }
        let closes = self.clone();
        if std::thread::Builder::new()
            .name("terminal-host-close".into())
            .spawn(move || closes.work())
            .is_err()
        {
            // Thread exhaustion must not strand a queued close: finish the
            // queue on this thread instead.
            self.work();
        }
    }

    #[cfg(unix)]
    fn work(&self) {
        loop {
            let close = {
                let mut state = self.state.lock().unwrap();
                match state.queue.pop_front() {
                    Some(close) => close,
                    None => {
                        state.workers -= 1;
                        return;
                    }
                }
            };
            finish_host_close(close);
            let mut state = self.state.lock().unwrap();
            state.pending -= 1;
            if state.pending == 0 {
                self.idle.notify_all();
            }
        }
    }

    /// Wait until every queued host close finished or `deadline` passed.
    /// Returns whether the queue drained.
    pub(crate) fn wait_idle(&self, deadline: Instant) -> bool {
        let mut state = self.state.lock().unwrap();
        while state.pending != 0 {
            let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
                return false;
            };
            state = self.idle.wait_timeout(state, remaining).unwrap().0;
        }
        true
    }

    #[cfg(test)]
    pub(crate) fn pending(&self) -> usize {
        self.state.lock().unwrap().pending
    }
}

#[cfg(unix)]
fn finish_host_close(close: PendingHostClose) {
    let PendingHostClose { runtime, termination, identity, host_root, deadline } = close;
    let acknowledged = match runtime.wait_for_host_exit(termination, deadline) {
        Ok((path, exit)) => acknowledge_exact_terminal_host_exit(&path, &exit),
        Err(error) => {
            if let Some(identity) = identity.as_ref() {
                eprintln!(
                    "cmux-tui: terminal {} close could not await host exit: {error:#}",
                    identity.terminal_id
                );
            }
            false
        }
    };
    runtime.kill();
    if !acknowledged && let (Some(identity), Some(root)) = (identity, host_root) {
        terminate_discovered_terminal_host_in(
            &root,
            &identity.terminal_id,
            Some(&identity.incarnation),
        );
    }
}

impl Mux {
    /// End one closed terminal's runtime. A hosted runtime is asked to exit
    /// now and awaited on the host-close pool; a local runtime is killed
    /// inline.
    pub(super) fn terminate_terminal_runtime(&self, runtime: &Arc<Surface>) {
        let identity = self.resource_terminal_host_identity(runtime);
        #[cfg(unix)]
        {
            let termination = match runtime.begin_host_termination() {
                Ok(Some(termination)) => termination,
                outcome => {
                    // A local runtime, or a host that could not be signaled:
                    // kill inline and fall back to the host record.
                    if let (Err(error), Some(identity)) = (&outcome, identity.as_ref()) {
                        eprintln!(
                            "cmux-tui: terminal {} close could not signal its host: {error:#}",
                            identity.terminal_id
                        );
                    }
                    runtime.kill();
                    if let Some(identity) = identity {
                        self.terminate_discovered_terminal_host(
                            &identity.terminal_id,
                            Some(&identity.incarnation),
                        );
                    }
                    return;
                }
            };
            let host_root = self.surface_options.lock().unwrap().terminal_host_root.clone();
            self.terminal_host_closes.enqueue(PendingHostClose {
                runtime: runtime.clone(),
                termination,
                identity,
                host_root,
                deadline: Instant::now() + TERMINAL_HOST_CLOSE_WAIT,
            });
        }
        #[cfg(not(unix))]
        {
            let _ = identity;
            runtime.kill();
        }
    }

    /// Wait until every closed terminal's host has exited or been handed to
    /// record cleanup, or `deadline` passed. Returns whether all finished.
    pub fn wait_for_terminal_host_closes(&self, deadline: Instant) -> bool {
        self.terminal_host_closes.wait_idle(deadline)
    }
}
