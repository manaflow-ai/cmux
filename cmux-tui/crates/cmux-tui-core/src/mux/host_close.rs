//! Asynchronous terminal-host shutdown after a committed close.
//!
//! A terminal close commits its tombstone and removes every view first, so
//! the tree and the reply reflect the close at once. Ending the host process
//! can take up to [`TERMINAL_HOST_CLOSE_WAIT`]: the close path hands the host
//! to a small worker pool, which sends the termination request, awaits the
//! host's receipt, and then awaits the durable exit receipt. The requesting
//! connection never waits for the host: its termination receipt arrives
//! through the surface's reader thread, behind the terminal's queued output,
//! so a busy stream can hold it for the whole control timeout. Many closes
//! therefore end their hosts in parallel instead of one after another on the
//! requesting connection.

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
    step: HostCloseStep,
    identity: Option<TerminalHostIdentity>,
    host_root: Option<PathBuf>,
}

#[cfg(unix)]
enum HostCloseStep {
    /// Not yet asked to exit. A worker signals it and queues the wait
    /// behind the other signals, so a batch close signals every host first.
    Signal,
    /// Asked to exit. `None` when the host could not be signaled through its
    /// connection; the worker then falls back to the host record. The
    /// deadline starts when the host is signaled, not when the close was
    /// queued: a teardown that queues a thousand closes must not spend the
    /// later hosts' exit time waiting in the queue.
    Await(Option<crate::surface::HostTermination>, Instant),
}

#[derive(Default)]
#[cfg_attr(not(unix), allow(dead_code))]
struct HostCloseState {
    #[cfg(unix)]
    queue: VecDeque<PendingHostClose>,
    workers: usize,
    /// Closes queued or in progress.
    pending: usize,
    /// Closes finished since start; a waiter measures progress with it.
    finished: u64,
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
            let close = match close.step {
                HostCloseStep::Signal => signal_host_close(close),
                HostCloseStep::Await(..) => {
                    finish_host_close(close);
                    None
                }
            };
            let mut state = self.state.lock().unwrap();
            if let Some(close) = close {
                // Signaled: its wait goes behind the signals still queued.
                state.queue.push_back(close);
                continue;
            }
            state.pending -= 1;
            state.finished = state.finished.wrapping_add(1);
            // Waiters measure progress, so every finished close wakes them.
            self.idle.notify_all();
        }
    }

    /// Wait until every queued host close finished, or until no close
    /// finished for `stall`. Returns whether the queue drained. Each close
    /// is bounded by its own deadline, so a long queue that keeps finishing
    /// closes is waited for; a fixed deadline from the first enqueue made
    /// the hosts at the end of a large teardown miss it.
    pub(crate) fn wait_idle(&self, stall: Duration) -> bool {
        let mut state = self.state.lock().unwrap();
        let mut progress = (state.finished, Instant::now() + stall);
        while state.pending != 0 {
            if state.finished != progress.0 {
                progress = (state.finished, Instant::now() + stall);
            }
            let Some(remaining) = progress.1.checked_duration_since(Instant::now()) else {
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

/// Ask one queued host to exit. Returns the close to await, or `None` when a
/// local runtime was killed inline.
#[cfg(unix)]
fn signal_host_close(mut close: PendingHostClose) -> Option<PendingHostClose> {
    let termination = match close.runtime.begin_host_termination() {
        Ok(Some(termination)) => Some(termination),
        Ok(None) => {
            close.runtime.kill();
            if let (Some(identity), Some(root)) =
                (close.identity.as_ref(), close.host_root.as_ref())
            {
                terminate_discovered_terminal_host_in(
                    root,
                    &identity.terminal_id,
                    Some(&identity.incarnation),
                );
            }
            return None;
        }
        Err(error) => {
            if let Some(identity) = close.identity.as_ref() {
                eprintln!(
                    "cmux-tui: terminal {} close could not signal its host: {error:#}",
                    identity.terminal_id
                );
            }
            None
        }
    };
    close.step = HostCloseStep::Await(termination, Instant::now() + TERMINAL_HOST_CLOSE_WAIT);
    Some(close)
}

#[cfg(unix)]
fn finish_host_close(close: PendingHostClose) {
    let PendingHostClose { runtime, step, identity, host_root } = close;
    let HostCloseStep::Await(termination, deadline) = step else {
        unreachable!("only a signaled host close is awaited");
    };
    let acknowledged =
        match termination.map(|termination| runtime.wait_for_host_exit(termination, deadline)) {
            Some(Ok((path, exit))) => acknowledge_exact_terminal_host_exit(&path, &exit),
            Some(Err(error)) => {
                if let Some(identity) = identity.as_ref() {
                    eprintln!(
                        "cmux-tui: terminal {} close could not await host exit: {error:#}",
                        identity.terminal_id
                    );
                }
                false
            }
            None => false,
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
    /// End one closed terminal's runtime. A hosted runtime is signaled and
    /// awaited on the host-close pool, so the close reply never waits for
    /// the host's termination receipt; a local runtime is killed inline.
    pub(super) fn terminate_terminal_runtime(&self, runtime: &Arc<Surface>) {
        let identity = self.resource_terminal_host_identity(runtime);
        if let Some(identity) = identity.as_ref() {
            self.terminal_respawns.forget_argv(&identity.terminal_id);
        }
        #[cfg(unix)]
        {
            if !runtime.has_host_termination() {
                // A local runtime: kill it inline, and end any host record
                // left for the same terminal.
                runtime.kill();
                if let Some(identity) = identity {
                    self.terminate_discovered_terminal_host(
                        &identity.terminal_id,
                        Some(&identity.incarnation),
                    );
                }
                return;
            }
            let host_root = self.surface_options.lock().unwrap().terminal_host_root.clone();
            self.terminal_host_closes.enqueue(PendingHostClose {
                runtime: runtime.clone(),
                step: HostCloseStep::Signal,
                identity,
                host_root,
            });
        }
        #[cfg(not(unix))]
        {
            let _ = identity;
            runtime.kill();
        }
    }

    /// End several closed terminals' runtimes without delaying the caller:
    /// the host-close pool asks every host to exit, then awaits each exit.
    /// A batch close's reply does not wait for a hundred hosts to be
    /// signaled one after another.
    pub(super) fn terminate_terminal_runtimes_deferred(&self, runtimes: Vec<Arc<Surface>>) {
        #[cfg(unix)]
        {
            let host_root = self.surface_options.lock().unwrap().terminal_host_root.clone();
            for runtime in runtimes {
                let identity = self.resource_terminal_host_identity(&runtime);
                if let Some(identity) = identity.as_ref() {
                    self.terminal_respawns.forget_argv(&identity.terminal_id);
                }
                self.terminal_host_closes.enqueue(PendingHostClose {
                    runtime,
                    step: HostCloseStep::Signal,
                    identity,
                    host_root: host_root.clone(),
                });
            }
        }
        #[cfg(not(unix))]
        for runtime in runtimes {
            runtime.kill();
        }
    }

    /// Wait until every closed terminal's host has exited or been handed to
    /// record cleanup, or until no host close finished for `stall`. Returns
    /// whether all finished.
    pub fn wait_for_terminal_host_closes(&self, stall: Duration) -> bool {
        self.terminal_host_closes.wait_idle(stall)
    }
}
