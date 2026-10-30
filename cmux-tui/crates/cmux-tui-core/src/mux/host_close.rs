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

use crate::supervised::{self, Fatal, ShutdownBehavior};

#[cfg(any(unix, windows))]
use std::collections::VecDeque;
#[cfg(any(unix, windows))]
use std::path::PathBuf;

use super::*;
use crate::panic_free::RecoverPoison;

/// Upper bound on concurrent host-exit waiters. Every host already received
/// its termination request, so a waiter only observes an exit in progress.
#[cfg(any(unix, windows))]
const MAX_HOST_CLOSE_WORKERS: usize = 8;

#[cfg(any(unix, windows))]
struct PendingHostClose {
    runtime: Arc<Surface>,
    step: HostCloseStep,
    identity: Option<TerminalHostIdentity>,
    host_root: Option<PathBuf>,
    /// The mux, for a record cleanup retry when the host does not exit.
    owner: Weak<Mux>,
    /// Where the host's crash sidecar goes before its records are removed.
    panic_log: Option<crate::terminal_host_runtime::HostPanicLog>,
}

#[cfg(any(unix, windows))]
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
            let mut state = self.state.lock().recover_poison();
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
        if supervised::spawn_at(
            "terminal-host-close",
            cmux_threads::ThreadQos::Utility,
            Fatal,
            ShutdownBehavior::Continue,
            move || {
                closes.work();
            },
        )
        .is_err()
        {
            // Thread exhaustion must not strand a queued close: finish the
            // queue on this thread instead.
            self.work();
        }
    }

    #[cfg(any(unix, windows))]
    fn work(&self) {
        loop {
            let close = {
                let mut state = self.state.lock().recover_poison();
                match state.queue.pop_front() {
                    Some(close) => close,
                    None => {
                        state.workers -= 1;
                        return;
                    }
                }
            };
            let close = match close {
                PendingHostClose {
                    runtime,
                    step: HostCloseStep::Await(termination, deadline),
                    identity,
                    host_root,
                    owner,
                    panic_log,
                } => {
                    finish_host_close(
                        runtime,
                        termination,
                        deadline,
                        identity,
                        host_root,
                        owner,
                        panic_log,
                    );
                    None
                }
                close => signal_host_close(close),
            };
            let mut state = self.state.lock().recover_poison();
            // Waiters measure progress, so every step wakes them: a long
            // signal phase counts too, not only finished closes.
            state.steps = state.steps.wrapping_add(1);
            self.idle.notify_all();
            if let Some(close) = close {
                // Signaled: its wait goes behind the signals still queued.
                state.queue.push_back(close);
                continue;
            }
            state.pending -= 1;
        }
    }

    /// Wait until every queued host close finished, until no host was
    /// signaled and no close finished for `stall`, or until `ceiling`.
    /// Returns whether the queue drained. Each close is bounded by its own
    /// deadline, so a long queue that keeps progressing is waited for; a
    /// fixed deadline from the first enqueue made the hosts at the end of a
    /// large teardown miss it.
    pub(crate) fn wait_idle(&self, stall: Duration, ceiling: Instant) -> bool {
        let mut state = self.state.lock().recover_poison();
        let mut progress = (state.steps, Instant::now() + stall);
        while state.pending != 0 {
            if state.steps != progress.0 {
                progress = (state.steps, Instant::now() + stall);
            }
            let Some(remaining) = progress.1.min(ceiling).checked_duration_since(Instant::now())
            else {
                return false;
            };
            state = cmux_threads::checked::sync::wait_timeout(&self.idle, state, remaining)
                .recover_poison()
                .0;
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
fn signal_host_close(mut close: PendingHostClose) -> Option<PendingHostClose> {
    let termination = match close.runtime.begin_host_termination() {
        Ok(Some(termination)) => Some(termination),
        Ok(None) => {
            close.runtime.kill();
            if let (Some(identity), Some(root)) =
                (close.identity.as_ref(), close.host_root.as_ref())
            {
                terminate_discovered_terminal_host_in(
                    &close.owner,
                    root,
                    &identity.terminal_id,
                    Some(&identity.incarnation),
                    close.panic_log.as_ref(),
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

#[cfg(any(unix, windows))]
fn finish_host_close(
    runtime: Arc<Surface>,
    termination: Option<crate::surface::HostTermination>,
    deadline: Instant,
    identity: Option<TerminalHostIdentity>,
    host_root: Option<PathBuf>,
    owner: Weak<Mux>,
    panic_log: Option<crate::terminal_host_runtime::HostPanicLog>,
) {
    let acknowledged =
        match termination.map(|termination| runtime.wait_for_host_exit(termination, deadline)) {
            Some(Ok((path, exit))) => {
                acknowledge_exact_terminal_host_exit(&path, &exit, panic_log.as_ref())
            }
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
            &owner,
            &root,
            &identity.terminal_id,
            Some(&identity.incarnation),
            panic_log.as_ref(),
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
            let TerminalHostPaths { root: host_root, panic_log } = self.terminal_host_paths();
            self.terminal_host_closes.enqueue(PendingHostClose {
                runtime: runtime.clone(),
                step: HostCloseStep::Signal,
                identity,
                host_root,
                owner: self.work_owner(),
                panic_log,
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
            let TerminalHostPaths { root: host_root, panic_log } = self.terminal_host_paths();
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
                    owner: self.work_owner(),
                    panic_log: panic_log.clone(),
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
