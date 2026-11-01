//! Asynchronous terminal-host shutdown after a committed close.
//!
//! A terminal close commits its tombstone and removes every view first, so
//! the tree and the reply reflect the close at once. Ending the host process
//! can take up to [`TERMINAL_HOST_CLOSE_WAIT`]: the close path hands the host
//! to a small signaling pool. Each signal's exit wait runs independently, so
//! a slow close-reply stream cannot occupy every signaling worker while later
//! terminals wait in the queue. The requesting connection never waits for the
//! host: its termination receipt arrives through the surface's reader thread,
//! behind the terminal's queued output, so a busy stream can hold it for the
//! whole control timeout.

#[cfg(any(unix, windows))]
use std::collections::VecDeque;
#[cfg(any(unix, windows))]
use std::path::PathBuf;

use super::*;

/// Upper bound on concurrent host-exit signalers. Exit waits run in their own
/// short-lived threads and never consume these workers.
#[cfg(any(unix, windows))]
const MAX_HOST_CLOSE_WORKERS: usize = 8;

#[cfg(any(unix, windows))]
struct PendingHostClose {
    runtime: Arc<Surface>,
    identity: Option<TerminalHostIdentity>,
    host_root: Option<PathBuf>,
    termination: Option<(crate::surface::HostTermination, Instant)>,
}

#[derive(Default)]
#[cfg_attr(not(any(unix, windows)), allow(dead_code))]
struct HostCloseState {
    #[cfg(any(unix, windows))]
    queue: VecDeque<PendingHostClose>,
    workers: usize,
    /// Closes queued or in progress.
    pending: usize,
    /// Steps (signals and finished closes) since start; a waiter measures
    /// progress with it.
    steps: u64,
}

/// Shared queue of hosts that were asked to exit.
#[derive(Default)]
pub(crate) struct TerminalHostCloses {
    state: Mutex<HostCloseState>,
    idle: Condvar,
}

impl TerminalHostCloses {
    #[cfg(any(unix, windows))]
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
            self.clone().work();
        }
    }

    #[cfg(any(unix, windows))]
    fn work(self: Arc<Self>) {
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
            let close = signal_host_close(close);
            let mut state = self.state.lock().unwrap();
            state.steps = state.steps.wrapping_add(1);
            self.idle.notify_all();
            if let Some(close) = close {
                // Never let an exit wait occupy a signaling worker. Close
                // requests can arrive slowly (for example while each reply
                // commits state), so keeping the wait in this pool starves
                // later signals and makes hosts trail the last reply.
                let closes = self.clone();
                if std::thread::Builder::new()
                    .name("terminal-host-close-wait".into())
                    .spawn(move || {
                        finish_host_close(close);
                        closes.complete();
                    })
                    .is_err()
                {
                    // Thread exhaustion must not strand a close. Finish it
                    // inline as the enqueue path did before the pool existed.
                    finish_host_close(close);
                    state.pending -= 1;
                    self.idle.notify_all();
                }
                continue;
            }
            state.pending -= 1;
            self.idle.notify_all();
        }
    }

    fn complete(&self) {
        let mut state = self.state.lock().unwrap();
        state.steps = state.steps.wrapping_add(1);
        state.pending -= 1;
        self.idle.notify_all();
    }

    /// Wait until every queued host close finished, until no host was
    /// signaled and no close finished for `stall`, or until `ceiling`.
    /// Returns whether the queue drained. Each close is bounded by its own
    /// deadline, so a long queue that keeps progressing is waited for; a
    /// fixed deadline from the first enqueue made the hosts at the end of a
    /// large teardown miss it.
    pub(crate) fn wait_idle(&self, stall: Duration, ceiling: Instant) -> bool {
        let mut state = self.state.lock().unwrap();
        let mut progress = (state.steps, Instant::now() + stall);
        while state.pending != 0 {
            if state.steps != progress.0 {
                progress = (state.steps, Instant::now() + stall);
            }
            let Some(remaining) = progress.1.min(ceiling).checked_duration_since(Instant::now())
            else {
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
#[cfg(any(unix, windows))]
fn signal_host_close(close: PendingHostClose) -> Option<PendingHostClose> {
    let PendingHostClose { runtime, identity, host_root, .. } = close;
    let termination = match runtime.begin_host_termination() {
        Ok(Some(termination)) => Some(termination),
        Ok(None) => {
            runtime.kill();
            if let (Some(identity), Some(root)) = (identity.as_ref(), host_root.as_ref()) {
                terminate_discovered_terminal_host_in(
                    root,
                    &identity.terminal_id,
                    Some(&identity.incarnation),
                );
            }
            return None;
        }
        Err(error) => {
            if let Some(identity) = identity.as_ref() {
                eprintln!(
                    "cmux-tui: terminal {} close could not signal its host: {error:#}",
                    identity.terminal_id
                );
            }
            None
        }
    };
    Some(PendingHostClose {
        runtime,
        identity,
        host_root,
        termination: termination
            .map(|termination| (termination, Instant::now() + TERMINAL_HOST_CLOSE_WAIT)),
    })
}

#[cfg(any(unix, windows))]
fn finish_host_close(close: PendingHostClose) {
    let PendingHostClose { runtime, termination, identity, host_root } = close;
    let Some((termination, deadline)) = termination else { return };
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
    /// End one closed terminal's runtime. A hosted runtime is signaled and
    /// awaited on the host-close pool, so the close reply never waits for
    /// the host's termination receipt; a local runtime is killed inline.
    pub(super) fn terminate_terminal_runtime(&self, runtime: &Arc<Surface>) {
        let identity = self.resource_terminal_host_identity(runtime);
        if let Some(identity) = identity.as_ref() {
            self.terminal_respawns.forget_argv(&identity.terminal_id);
        }
        #[cfg(any(unix, windows))]
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
                identity,
                host_root,
                termination: None,
            });
        }
        #[cfg(not(any(unix, windows)))]
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
        #[cfg(any(unix, windows))]
        {
            let host_root = self.surface_options.lock().unwrap().terminal_host_root.clone();
            for runtime in runtimes {
                let identity = self.resource_terminal_host_identity(&runtime);
                if let Some(identity) = identity.as_ref() {
                    self.terminal_respawns.forget_argv(&identity.terminal_id);
                }
                self.terminal_host_closes.enqueue(PendingHostClose {
                    runtime,
                    identity,
                    host_root: host_root.clone(),
                    termination: None,
                });
            }
        }
        #[cfg(not(any(unix, windows)))]
        for runtime in runtimes {
            runtime.kill();
        }
    }

    /// Wait until every closed terminal's host has exited or been handed to
    /// record cleanup, until the close pool made no progress for `stall`, or
    /// until `ceiling`. Returns whether all finished.
    pub fn wait_for_terminal_host_closes(&self, stall: Duration, ceiling: Instant) -> bool {
        self.terminal_host_closes.wait_idle(stall, ceiling)
    }
}
