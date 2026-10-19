//! A shared host's per-terminal runtime on its event loop
//! (`shared_exec.rs`): the parser, the PTY reader, the child watch and the
//! exit publisher that a one-terminal host runs on four threads
//! (`shared/host_start.rs`).
//!
//! - Parser: a serial job that each queued command wakes
//!   (`ParserSender::set_wake`); it applies the commands in queue order with
//!   the same [`HostParser`] the parser thread uses. A panic ends the
//!   terminal as on the parser thread, never the process.
//! - PTY reader: from the launch owner's ready (the launch barrier), a
//!   serial job that each master readiness, drain wake or forced-drain
//!   deadline runs; it reads and publishes exactly as the reader thread
//!   does (`publish_pty_bytes`), with the same forced-drain window
//!   (`poll_pty`), and queues `Drain` at the end. It may block where the
//!   thread blocked (the parser budget and queue apply backpressure).
//! - Child: an exit watch (EVFILT_PROC, pidfd) that runs `watch_child`, the
//!   reader thread's body, once the child has ended; it is never reaped
//!   before that body decides.
//! - Exit publisher: a serial job that each publication request wakes.

use std::io::Read;
use std::os::fd::{AsRawFd, RawFd};
use std::os::unix::net::UnixStream;
use std::sync::mpsc::{Receiver, TryRecvError};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Instant;

use super::super::shared::host_parser::{self, HostParser};
use super::super::shared::host_shared::HostShared;
use super::super::shared::host_start::{end_pty_stream, publish_pty_bytes, watch_child};
use super::super::shared::host_state::ParserCommand;
use super::super::sys::{PtyPoll, poll_pty};
use super::HostChild;
use super::shared_exec::{Executor, SerialJob};

pub(crate) struct Parts {
    pub(crate) parser: HostParser,
    pub(crate) parser_commands: Receiver<ParserCommand>,
    pub(crate) exit_requests: Receiver<()>,
    pub(crate) pty_reader: Box<dyn Read + Send>,
    pub(crate) pty_poll_fd: RawFd,
    pub(crate) pty_drain_waiter: UnixStream,
    pub(crate) child: HostChild,
}

use super::super::shared::host_crash::attribute;

pub(crate) fn start(executor: &'static Executor, host: &Arc<HostShared>, parts: Parts) {
    let Parts {
        parser,
        parser_commands,
        exit_requests,
        pty_reader,
        pty_poll_fd,
        pty_drain_waiter,
        child,
    } = parts;
    start_exit_publisher(executor, host, exit_requests);
    start_parser(executor, host, parser, parser_commands);
    let reader_host = host.clone();
    host.when_launch_owner_stream_ready(Box::new(move || {
        start_pty_reader(executor, reader_host, pty_reader, pty_poll_fd, pty_drain_waiter);
    }));
    watch_child_exit(executor, host, child);
}

fn start_exit_publisher(
    executor: &'static Executor,
    host: &Arc<HostShared>,
    requests: Receiver<()>,
) {
    let weak = Arc::downgrade(host);
    let job = SerialJob::new();
    let wake = job.clone();
    let _ = host.exit_publish_wake.set(Box::new(move || wake.wake(executor)));
    job.install(
        executor,
        attribute(move || {
            loop {
                match requests.try_recv() {
                    Ok(()) => {
                        if !HostShared::publish_exit_with_retries(&weak, &requests) {
                            return false;
                        }
                    }
                    Err(TryRecvError::Empty) => return true,
                    Err(TryRecvError::Disconnected) => return false,
                }
            }
        }),
    );
}

fn start_parser(
    executor: &'static Executor,
    host: &Arc<HostShared>,
    parser: HostParser,
    commands: Receiver<ParserCommand>,
) {
    let job = SerialJob::new();
    let wake = job.clone();
    host.parser_commands.set_wake(Box::new(move || wake.wake(executor)));
    let failed_host = Arc::downgrade(host);
    let mut parser = Some(parser);
    job.install(
        executor,
        attribute(move || {
            loop {
                let command = match commands.try_recv() {
                    Ok(command) => command,
                    Err(TryRecvError::Empty) => return true,
                    Err(TryRecvError::Disconnected) => return false,
                };
                let Some(running) = parser.as_mut() else { return false };
                let applied = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    running.apply(command)
                }));
                match applied {
                    Ok(true) => {}
                    Ok(false) => {
                        // Drained: the parser is done for good.
                        parser = None;
                        return false;
                    }
                    Err(_) => {
                        parser = None;
                        // As on the parser thread: end the terminal and
                        // publish its exit; the host process keeps running.
                        if let Some(host) = failed_host.upgrade() {
                            executor.submit(move || host_parser::after_parser_panic(&host));
                        }
                        return false;
                    }
                }
            }
        }),
    );
}

struct PtyReader {
    host: Arc<HostShared>,
    reader: Box<dyn Read + Send>,
    fd: RawFd,
    waiter: UnixStream,
    forced_at: Option<Instant>,
    waiter_closed: bool,
    buffer: Box<[u8]>,
    pty_token: Option<u64>,
    waiter_token: Option<u64>,
    timer: Option<Instant>,
}

fn start_pty_reader(
    executor: &'static Executor,
    host: Arc<HostShared>,
    reader: Box<dyn Read + Send>,
    fd: RawFd,
    waiter: UnixStream,
) {
    let mut state = Some(PtyReader {
        host,
        reader,
        fd,
        waiter,
        forced_at: None,
        waiter_closed: false,
        buffer: vec![0u8; 64 * 1024].into_boxed_slice(),
        pty_token: None,
        waiter_token: None,
        timer: None,
    });
    let job = SerialJob::new();
    let wake = job.clone();
    job.install(
        executor,
        attribute(move || {
            let Some(reader) = state.as_mut() else { return false };
            if reader.pump(executor, &wake) {
                return true;
            }
            reader.forget(executor);
            end_pty_stream(&reader.host);
            state = None;
            false
        }),
    );
}

impl PtyReader {
    /// Read until the master has nothing more; true while the stream goes
    /// on (the next readiness is armed).
    fn pump(&mut self, executor: &'static Executor, job: &Arc<SerialJob>) -> bool {
        loop {
            let polled = poll_pty(
                self.fd,
                &mut self.waiter,
                &self.host.force_pty_drain,
                &mut self.forced_at,
                &mut self.waiter_closed,
                false,
            );
            match polled {
                Ok(PtyPoll::Readable) => match self.reader.read(&mut self.buffer) {
                    Ok(0) => return false,
                    Ok(count) => {
                        if !publish_pty_bytes(&self.host, &self.buffer[..count]) {
                            return false;
                        }
                    }
                    Err(error)
                        if matches!(
                            error.kind(),
                            std::io::ErrorKind::Interrupted | std::io::ErrorKind::WouldBlock
                        ) => {}
                    Err(_) => return false,
                },
                Ok(PtyPoll::Pending(remaining)) => {
                    self.arm(executor, job, remaining.map(|remaining| Instant::now() + remaining));
                    return true;
                }
                Ok(PtyPoll::Ended) | Err(_) => return false,
            }
        }
    }

    fn arm(
        &mut self,
        executor: &'static Executor,
        job: &Arc<SerialJob>,
        deadline: Option<Instant>,
    ) {
        let rearm = |fd: RawFd, old: Option<u64>| {
            if let Some(old) = old {
                executor.forget_handler(old);
            }
            let wake = job.clone();
            executor.on_readable(fd, move || wake.wake(executor)).ok()
        };
        self.pty_token = rearm(self.fd, self.pty_token);
        if self.waiter_closed {
            if let Some(old) = self.waiter_token.take() {
                executor.forget(self.waiter.as_raw_fd(), old);
            }
        } else {
            self.waiter_token = rearm(self.waiter.as_raw_fd(), self.waiter_token);
        }
        if let Some(deadline) = deadline
            && self.timer.is_none_or(|armed| armed <= Instant::now() || armed > deadline)
        {
            self.timer = Some(deadline);
            let wake = job.clone();
            executor.at(deadline, move || wake.wake(executor));
        }
    }

    fn forget(&mut self, executor: &'static Executor) {
        if let Some(token) = self.pty_token.take() {
            executor.forget(self.fd, token);
        }
        if let Some(token) = self.waiter_token.take() {
            executor.forget(self.waiter.as_raw_fd(), token);
        }
    }
}

fn watch_child_exit(executor: &'static Executor, host: &Arc<HostShared>, child: HostChild) {
    let pid = child.process_id().and_then(|pid| libc::pid_t::try_from(pid).ok());
    // Taken once: by the exit event, or at once when the child already
    // ended (a zombie may raise no exit event).
    let child = Arc::new(Mutex::new(Some(child)));
    let run = {
        let host = host.clone();
        attribute(move || {
            let taken = child.lock().unwrap_or_else(PoisonError::into_inner).take();
            if let Some(child) = taken {
                watch_child(&host, child);
            }
        })
    };
    let run = Arc::new(Mutex::new(run));
    let fire = { move || (run.lock().unwrap_or_else(PoisonError::into_inner))() };
    let watched = pid.is_some_and(|pid| executor.on_exit(pid, fire.clone()).is_ok());
    if !watched || pid.is_some_and(child_ended) {
        // Not watchable (the body waits itself), or ended already.
        executor.submit(fire);
    }
}

/// The child ended (still unreaped).
fn child_ended(pid: libc::pid_t) -> bool {
    let mut status = std::mem::MaybeUninit::<libc::siginfo_t>::zeroed();
    // SAFETY: status is writable siginfo storage; WNOWAIT leaves the child
    // waitable for its watcher.
    let result = unsafe {
        libc::waitid(
            libc::P_PID,
            pid as libc::id_t,
            status.as_mut_ptr(),
            libc::WEXITED | libc::WNOHANG | libc::WNOWAIT,
        )
    };
    // SAFETY: waitid zeroed or filled it; si_pid is 0 while running.
    result == 0 && unsafe { status.assume_init().si_pid() } != 0
}
