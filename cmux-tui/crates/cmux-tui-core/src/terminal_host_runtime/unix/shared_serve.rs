//! A shared host's accept loop for one terminal, on its event loop
//! (`shared_exec.rs`) instead of a thread of its own.
//!
//! It is the loop of `serve_terminal_host_stdio` after `Ready`, step by
//! step: each listener readiness, accept-waker wake or deadline runs one
//! [`SharedServing::step`] (a serial job), which accepts every waiting
//! client, applies the launch-owner deadline and the orphan grace exactly as
//! the loop does, and arms the next wait. When the terminal is dead and no
//! client stream is left it ends the terminal the same way: the exit test
//! gate, 20 ms, then the service guard (record and lease), and the rest.

use std::os::fd::RawFd;
use std::sync::Arc;
use std::time::{Duration, Instant};

use super::super::shared::host_accept;
use super::super::shared::host_shared::HostShared;
use super::super::shared::host_state::*;
use super::super::shared::records::HostServiceGuard;
use super::super::sys::HostListener;
use super::host_signals::Registration;
use super::shared_exec::{Executor, SerialJob};
use super::*;

/// The first wait after a failed accept; it doubles up to `MAX_BACKOFF`
/// (host_accept.rs keeps the same bounds for a one-terminal host).
const FIRST_BACKOFF: Duration = Duration::from_millis(20);
const MAX_BACKOFF: Duration = Duration::from_secs(1);

/// What keeps one served terminal alive, in drop order.
pub(crate) struct ServingParts {
    pub(crate) shared: Arc<HostShared>,
    pub(crate) listener: HostListener,
    pub(crate) guard: HostServiceGuard,
    pub(crate) publication_lock: Box<dyn Send>,
    pub(crate) signals: Registration,
    pub(crate) pty_lock: Box<dyn Send>,
    /// The slot's guard and bootstrap socket (shared_host.rs).
    pub(crate) keepalive: Box<dyn Send>,
}

struct SharedServing {
    parts: Option<ServingParts>,
    launch_owner_deadline: Instant,
    orphan_grace: Option<Duration>,
    orphan_since: Option<Instant>,
    orphan_ended: bool,
    backoff: Duration,
    failures: u64,
    listener_token: Option<u64>,
    waker_token: Option<u64>,
    timer: Option<Instant>,
}

enum Next {
    /// Wait for a client, a wake, or the deadline.
    Wait(Option<Instant>),
    /// An accept failed: wait for a wake or the backoff only.
    Backoff(Instant),
    Done,
}

/// Serve `parts` from `executor` until the terminal ends.
pub(crate) fn serve(executor: &'static Executor, parts: ServingParts) {
    let mut serving = SharedServing {
        parts: Some(parts),
        launch_owner_deadline: Instant::now() + HOST_LAUNCH_OWNER_TIMEOUT,
        orphan_grace: host_orphan_grace(),
        orphan_since: None,
        orphan_ended: false,
        backoff: FIRST_BACKOFF,
        failures: 0,
        listener_token: None,
        waker_token: None,
        timer: None,
    };
    let job = SerialJob::new();
    let wake = job.clone();
    job.install(executor, move || serving.run(executor, &wake));
}

impl SharedServing {
    fn shared(&self) -> &Arc<HostShared> {
        &self.parts.as_ref().expect("serving parts").shared
    }

    fn run(&mut self, executor: &'static Executor, job: &Arc<SerialJob>) -> bool {
        self.shared().accept_waker.drain();
        match self.step() {
            Next::Done => {
                self.finish(executor);
                false
            }
            Next::Wait(deadline) => {
                self.arm(executor, job, true, deadline);
                true
            }
            Next::Backoff(deadline) => {
                self.arm(executor, job, false, Some(deadline));
                true
            }
        }
    }

    fn arm(
        &mut self,
        executor: &'static Executor,
        job: &Arc<SerialJob>,
        listen: bool,
        deadline: Option<Instant>,
    ) {
        let parts = self.parts.as_ref().expect("serving parts");
        let listener_fd = parts.listener.fd();
        let waker_fd = parts.shared.accept_waker.fd();
        let rearm = |fd: RawFd, old: Option<u64>| {
            if let Some(old) = old {
                executor.forget_handler(old);
            }
            let wake = job.clone();
            executor.on_readable(fd, move || wake.wake(executor)).ok()
        };
        self.listener_token = if listen {
            rearm(listener_fd, self.listener_token)
        } else {
            if let Some(old) = self.listener_token.take() {
                executor.forget(listener_fd, old);
            }
            None
        };
        self.waker_token = rearm(waker_fd, self.waker_token);
        if let Some(deadline) = deadline
            && self.timer.is_none_or(|armed| armed <= Instant::now() || armed > deadline)
        {
            self.timer = Some(deadline);
            let wake = job.clone();
            executor.at(deadline, move || wake.wake(executor));
        }
    }

    /// One pass of the accept loop of `serve_terminal_host_stdio`.
    fn step(&mut self) -> Next {
        let shared = self.shared().clone();
        loop {
            let now = Instant::now();
            if !shared.launch_owner_claimed.load(Ordering::Acquire)
                && now >= self.launch_owner_deadline
                && shared
                    .launch_owner_claimed
                    .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
                    .is_ok()
            {
                // A launcher that vanished before authenticating must not
                // retain an already-exited host forever.
                shared.mark_launch_owner_stream_ready();
            }
            if shared.dead.load(Ordering::Acquire)
                && shared.active_client_streams.load(Ordering::Acquire) == 0
            {
                return Next::Done;
            }
            if shared.active_client_streams.load(Ordering::Acquire) == 0 {
                if self.orphan_since.is_none() {
                    self.orphan_since = Some(now);
                    shared.lifetime.set_orphan_since(self.orphan_since);
                }
            } else if self.orphan_since.take().is_some() {
                shared.lifetime.set_orphan_since(None);
            }
            let accepted = self.parts.as_ref().expect("serving parts").listener.accept();
            match accepted {
                Ok(stream) => {
                    if self.orphan_since.take().is_some() {
                        shared.lifetime.set_orphan_since(None);
                    }
                    match host_accept::serve_accepted(&shared, stream) {
                        Ok(()) => self.reset_backoff(),
                        Err(error) => return self.after_error(&error),
                    }
                }
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    if let (Some(since), Some(orphan_grace)) =
                        (self.orphan_since, self.orphan_grace)
                        && !self.orphan_ended
                        && now.saturating_duration_since(since) >= orphan_grace
                    {
                        self.orphan_ended = true;
                        eprintln!(
                            "terminal-host: no client for {} s (owner daemon gone); ending the \
                             terminal",
                            orphan_grace.as_secs()
                        );
                        shared.lifetime.mark_owner_gone();
                        shared.request_termination();
                        continue;
                    }
                    // The listener drained: a later error starts a new streak.
                    self.reset_backoff();
                    let launch = (!shared.launch_owner_claimed.load(Ordering::Acquire))
                        .then_some(self.launch_owner_deadline);
                    let orphan = self
                        .orphan_since
                        .filter(|_| !self.orphan_ended)
                        .zip(self.orphan_grace)
                        .map(|(since, grace)| since + grace);
                    let deadline = match (launch, orphan) {
                        (Some(a), Some(b)) => Some(a.min(b)),
                        (a, b) => a.or(b),
                    };
                    return Next::Wait(deadline);
                }
                Err(error)
                    if matches!(
                        error.kind(),
                        std::io::ErrorKind::Interrupted | std::io::ErrorKind::ConnectionAborted
                    ) => {}
                // EMFILE, ENFILE, ENOBUFS, ENOMEM: never end the shell.
                Err(error) => return self.after_error(&error),
            }
        }
    }

    fn reset_backoff(&mut self) {
        self.backoff = FIRST_BACKOFF;
        self.failures = 0;
    }

    fn after_error(&mut self, error: &std::io::Error) -> Next {
        self.failures += 1;
        if self.failures == 1 {
            eprintln!("terminal-host: accepting a client failed; retrying: {error}");
        }
        let deadline = Instant::now() + self.backoff;
        self.backoff = (self.backoff * 2).min(MAX_BACKOFF);
        Next::Backoff(deadline)
    }

    fn finish(&mut self, executor: &'static Executor) {
        let Some(parts) = self.parts.take() else { return };
        if let Some(token) = self.listener_token.take() {
            executor.forget(parts.listener.fd(), token);
        }
        if let Some(token) = self.waker_token.take() {
            executor.forget(parts.shared.accept_waker.fd(), token);
        }
        // Debug builds only (cx-6xk9): a test holds an ended host alive.
        #[cfg(debug_assertions)]
        shared::host_serve::wait_at_test_gate("CMUX_TUI_TEST_HOST_EXIT_GATE");
        thread::sleep(Duration::from_millis(20));
        let ServingParts {
            shared,
            listener,
            guard,
            publication_lock,
            signals,
            pty_lock,
            keepalive,
        } = parts;
        drop(guard);
        drop(publication_lock);
        drop(listener);
        drop(signals);
        drop(pty_lock);
        drop(shared);
        drop(keepalive);
    }
}
