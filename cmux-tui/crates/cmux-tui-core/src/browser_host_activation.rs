//! Socket activation of the daemon's browser host: the daemon binds the
//! host's agent and provider sockets once and keeps them, passes them to every
//! host it starts, and while no host runs one thread blocks in poll(2) on the
//! agent socket and a cancel pipe. The first agent connect wakes it and starts
//! a host, which accepts the waiting connection. The daemon's end (the
//! supervisor's drop) writes the cancel pipe, and the thread ends.

use std::fs::File;
use std::os::fd::{AsRawFd, OwnedFd, RawFd};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;
use std::sync::{Arc, Mutex, Weak};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use super::{Inner, PROVIDER_SOCKET_FILE, State, lock};

#[derive(Default)]
pub(super) struct Activation {
    sockets: Mutex<Option<Sockets>>,
    thread: Mutex<Option<JoinHandle<()>>>,
}

struct Sockets {
    agent: UnixListener,
    provider: UnixListener,
    /// The hosts' lock files (`<socket>.lock`), held by the daemon.
    _locks: [File; 2],
    /// The socket files, removed at the daemon's end.
    paths: [std::path::PathBuf; 2],
    cancel_read: OwnedFd,
    cancel_write: OwnedFd,
}

impl Activation {
    /// Binds `socket` and the provider socket beside it (0600, in a 0700
    /// directory), and the cancel pipe.
    pub(super) fn bind(&self, socket: &Path) -> Result<(), String> {
        use std::os::unix::fs::PermissionsExt;
        let dir = socket.parent().ok_or("the browser host socket has no directory")?;
        std::fs::create_dir_all(dir)
            .and_then(|()| std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700)))
            .map_err(|error| format!("cannot prepare {}: {error}", dir.display()))?;
        let provider_path = socket.with_file_name(PROVIDER_SOCKET_FILE);
        let (agent, agent_lock) = bind_one(socket)?;
        let (provider, provider_lock) = bind_one(&provider_path)?;
        let (cancel_read, cancel_write) =
            std::io::pipe().map_err(|error| format!("cannot open the cancel pipe: {error}"))?;
        *lock(&self.sockets) = Some(Sockets {
            agent,
            provider,
            _locks: [agent_lock, provider_lock],
            paths: [socket.to_path_buf(), provider_path],
            cancel_read: cancel_read.into(),
            cancel_write: cancel_write.into(),
        });
        Ok(())
    }

    pub(super) fn is_bound(&self) -> bool {
        lock(&self.sockets).is_some()
    }

    /// The listening sockets for a host (agent, provider).
    pub(super) fn raw_fds(&self) -> Option<(RawFd, RawFd)> {
        lock(&self.sockets).as_ref().map(|s| (s.agent.as_raw_fd(), s.provider.as_raw_fd()))
    }

    /// Ends the activation thread (the daemon's end) and waits for it,
    /// unless this runs on that thread.
    pub(super) fn shutdown(&self) {
        if let Some(sockets) = lock(&self.sockets).as_ref() {
            // SAFETY: one byte from a valid buffer to the pipe we own.
            let _ =
                unsafe { libc::write(sockets.cancel_write.as_raw_fd(), [1u8].as_ptr().cast(), 1) };
        }
        let handle = lock(&self.thread).take();
        if let Some(handle) = handle
            && handle.thread().id() != std::thread::current().id()
        {
            let _ = handle.join();
        }
        // No connect reaches a socket of a daemon that ended, even one whose
        // listening fd another process inherited between fork and exec.
        if let Some(sockets) = lock(&self.sockets).as_ref() {
            for path in &sockets.paths {
                let _ = std::fs::remove_file(path);
            }
        }
    }
}

/// Binds one socket the way the host does (`server::bind` in
/// cmux-browser-host): an exclusive lock file, refused while another host
/// answers, a stale socket file replaced, mode 0600.
fn bind_one(path: &Path) -> Result<(UnixListener, File), String> {
    use std::os::unix::fs::PermissionsExt;
    let lock_file = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(path.with_extension("lock"))
        .map_err(|error| format!("cannot open the lock of {}: {error}", path.display()))?;
    // SAFETY: flock(2) on a file we own.
    if unsafe { libc::flock(lock_file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        return Err(format!("a browser host already owns {}", path.display()));
    }
    if UnixStream::connect(path).is_ok() {
        return Err(format!("a browser host already listens on {}", path.display()));
    }
    let _ = std::fs::remove_file(path);
    let listener = UnixListener::bind(path)
        .map_err(|error| format!("cannot bind {}: {error}", path.display()))?;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))
        .map_err(|error| format!("cannot protect {}: {error}", path.display()))?;
    Ok((listener, lock_file))
}

/// Starts the activation thread unless it already waits.
pub(super) fn arm(inner: &Arc<Inner>) {
    let fds = lock(&inner.activation.sockets)
        .as_ref()
        .map(|s| (s.agent.as_raw_fd(), s.cancel_read.as_raw_fd()));
    let Some((agent, cancel)) = fds else { return };
    let mut thread = lock(&inner.activation.thread);
    if thread.as_ref().is_some_and(|handle| !handle.is_finished()) {
        return;
    }
    let weak = Arc::downgrade(inner);
    match std::thread::Builder::new()
        .name("browser-host-activate".into())
        .spawn(move || run(&weak, agent, cancel))
    {
        Ok(handle) => *thread = Some(handle),
        Err(error) => eprintln!("cmux-tui: cannot start browser host activation: {error}"),
    }
}

#[derive(PartialEq)]
enum Wake {
    Agent,
    Cancel,
    Timeout,
}

/// The activation thread. The fds stay valid while it runs: the supervisor's
/// drop cancels and joins it before the sockets close.
fn run(weak: &Weak<Inner>, agent: RawFd, cancel: RawFd) {
    loop {
        if wait(Some(agent), cancel, None) == Wake::Cancel {
            return;
        }
        let Some(inner) = weak.upgrade() else { return };
        if matches!(*lock(&inner.state), State::Running(_)) {
            // A host serves the socket; the next idle stop arms this again.
            return;
        }
        // After a crash the Backoff restart owns the next start.
        let hold =
            lock(&inner.restart_due).and_then(|due| due.checked_duration_since(Instant::now()));
        let delay = match hold {
            Some(hold) => hold,
            None => match Inner::credentials(&inner) {
                Ok(_) => return,
                Err(error) => {
                    eprintln!("cmux-tui: browser host start on connect failed: {error}");
                    let mut backoff = lock(&inner.backoff);
                    let backoff = backoff.get_or_insert_with(|| {
                        crate::backoff::Backoff::new(
                            Duration::from_millis(200),
                            Duration::from_secs(30),
                        )
                    });
                    let delay = backoff.next_delay();
                    *lock(&inner.restart_due) = Some(Instant::now() + delay);
                    delay
                }
            },
        };
        drop(inner);
        // The waiting connection stays queued; a cancellable delay, not a poll loop.
        if wait(None, cancel, Some(delay)) == Wake::Cancel {
            return;
        }
    }
}

/// Blocks until `agent` is readable (a connect), `cancel` is readable, or
/// `timeout` passes.
fn wait(agent: Option<RawFd>, cancel: RawFd, timeout: Option<Duration>) -> Wake {
    let mut fds = vec![libc::pollfd { fd: cancel, events: libc::POLLIN, revents: 0 }];
    if let Some(agent) = agent {
        fds.push(libc::pollfd { fd: agent, events: libc::POLLIN, revents: 0 });
    }
    let timeout_ms = timeout.map_or(-1, |t| t.as_millis().clamp(1, i32::MAX as u128) as i32);
    loop {
        // SAFETY: `fds` is a valid array of pollfd for its length.
        let ready = unsafe { libc::poll(fds.as_mut_ptr(), fds.len() as libc::nfds_t, timeout_ms) };
        if ready < 0 {
            if std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            // A broken poll cannot wait; stop rather than spin.
            return Wake::Cancel;
        }
        if ready == 0 {
            return Wake::Timeout;
        }
        if fds[0].revents != 0 {
            return Wake::Cancel;
        }
        return Wake::Agent;
    }
}
