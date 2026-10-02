//! One app host process: spawn with fd 3, write [`ToHost`] lines, read
//! [`FromHost`] lines on a reader thread that blocks on the socket, and
//! report the exit once the socket closes and the child is reaped.

use std::io::{BufRead, BufReader, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc::{Receiver, SyncSender, TrySendError, sync_channel};

use cmux_app_host::protocol::MAX_LINE_BYTES;
use cmux_app_host::{FromHost, ToHost};

/// How a host process ended.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Exit {
    pub code: Option<i32>,
    pub signal: Option<i32>,
}

impl Exit {
    pub fn describe(&self) -> String {
        match (self.code, self.signal) {
            (Some(0), _) => "exited".into(),
            (Some(65), _) => "protocol error".into(),
            (Some(70), _) => "app limit or engine failure".into(),
            (Some(77), _) => "sandbox could not be applied".into(),
            (Some(code), _) => format!("exit {code}"),
            (None, Some(signal)) => format!("signal {signal}"),
            (None, None) => "unknown exit".into(),
        }
    }
}

/// Messages queued for one host before it counts as stuck and is killed.
const QUEUE: usize = 4096;

enum Outgoing {
    Line(Vec<u8>),
    Shutdown,
}

/// One host process. Sending never blocks: lines go through a bounded queue
/// to a writer thread, so the reader thread (and the supervisor lock) never
/// waits on a host that is itself waiting to write to us, and messages queued
/// under the supervisor lock reach the host in that order.
pub struct HostProcess {
    queue: SyncSender<Outgoing>,
    socket: UnixStream,
}

/// The host binary: `CMUX_APP_HOST_BIN`, else `cmux-app-host` next to the
/// daemon executable. `None` when neither exists (the capability is then not
/// advertised).
pub fn resolve_binary() -> Option<PathBuf> {
    if let Some(path) = std::env::var_os("CMUX_APP_HOST_BIN").map(PathBuf::from) {
        return path.is_file().then_some(path);
    }
    let path = std::env::current_exe().ok()?.parent()?.join("cmux-app-host");
    path.is_file().then_some(path)
}

impl HostProcess {
    /// Spawns the host with a clean environment and only fd 3 open beyond
    /// the null stdio. `on_message` runs on the reader thread for every line;
    /// `on_exit` runs once after the socket closed and the child was reaped.
    pub fn spawn(
        binary: &Path,
        args: &[String],
        name: &str,
        on_message: impl Fn(FromHost) + Send + 'static,
        on_exit: impl FnOnce(Exit) + Send + 'static,
    ) -> std::io::Result<Self> {
        let (ours, theirs) = UnixStream::pair()?;
        let fd = theirs.as_raw_fd();
        let mut command = Command::new(binary);
        command
            .args(args)
            .env_clear()
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        // SAFETY: sysconf before the fork; only async-signal-safe calls in pre_exec.
        let max_fd = match unsafe { libc::sysconf(libc::_SC_OPEN_MAX) } {
            n if n > 0 => n.min(65_536) as libc::c_int,
            _ => 4096,
        };
        // SAFETY: only async-signal-safe calls between fork and exec.
        unsafe { command.pre_exec(move || child_fds(fd, max_fd)) };
        let mut child = command.spawn()?;
        drop(theirs);
        let pid = child.id();
        let reader = ours.try_clone()?;
        let writer = ours.try_clone()?;
        let (queue, outgoing) = sync_channel(QUEUE);
        std::thread::Builder::new()
            .name(format!("cmux-app-host-w:{name}"))
            .spawn(move || write_loop(writer, outgoing))?;
        std::thread::Builder::new().name(format!("cmux-app-host:{name}")).spawn(move || {
            let mut lines = BufReader::new(reader);
            let mut line = Vec::new();
            loop {
                line.clear();
                match lines.by_ref().take(MAX_LINE_BYTES as u64 + 1).read_until(b'\n', &mut line) {
                    Ok(0) | Err(_) => break,
                    Ok(_) if line.last() != Some(&b'\n') => break,
                    Ok(_) => match serde_json::from_slice::<FromHost>(&line) {
                        Ok(message) => on_message(message),
                        Err(_) => break,
                    },
                }
            }
            // A malformed or oversized line, or the socket closed: end the process.
            // SAFETY: signalling our own child by pid; it is not reaped yet, so the pid is still ours.
            unsafe { libc::kill(pid as libc::pid_t, libc::SIGKILL) };
            let status = child.wait();
            let exit = match status {
                Ok(status) => Exit { code: status.code(), signal: status.signal() },
                Err(_) => Exit { code: None, signal: None },
            };
            on_exit(exit);
        })?;
        Ok(Self { queue, socket: ours })
    }

    /// Queues one message. A host whose queue is full is stuck and is killed.
    pub fn send(&self, message: &ToHost) {
        let Ok(mut line) = serde_json::to_vec(message) else { return };
        line.push(b'\n');
        self.enqueue(Outgoing::Line(line));
    }

    /// Asks the host to exit after the queued messages; the reader thread
    /// reports the exit.
    pub fn shutdown(&self) {
        self.enqueue(Outgoing::Shutdown);
    }

    /// Closes the channel both ways: the host reads end of input and exits,
    /// the reader thread sees the close and reaps it.
    pub fn kill(&self) {
        let _ = self.socket.shutdown(std::net::Shutdown::Both);
    }

    fn enqueue(&self, item: Outgoing) {
        match self.queue.try_send(item) {
            Ok(()) => {}
            Err(TrySendError::Full(_) | TrySendError::Disconnected(_)) => self.kill(),
        }
    }
}

fn write_loop(mut socket: UnixStream, outgoing: Receiver<Outgoing>) {
    while let Ok(item) = outgoing.recv() {
        match item {
            Outgoing::Line(line) => {
                if socket.write_all(&line).is_err() {
                    let _ = socket.shutdown(std::net::Shutdown::Both);
                    return;
                }
            }
            Outgoing::Shutdown => {
                let mut line = serde_json::to_vec(&ToHost::Shutdown).unwrap_or_default();
                line.push(b'\n');
                let _ = socket.write_all(&line);
                let _ = socket.shutdown(std::net::Shutdown::Write);
                return;
            }
        }
    }
}

/// In the child before exec: the channel on fd 3 without close-on-exec, and
/// every other inherited descriptor above 2 closed.
fn child_fds(fd: libc::c_int, max_fd: libc::c_int) -> std::io::Result<()> {
    // SAFETY: plain descriptor syscalls on this (forked, single-threaded) process.
    unsafe {
        if fd == 3 {
            if libc::fcntl(3, libc::F_SETFD, 0) != 0 {
                return Err(std::io::Error::last_os_error());
            }
        } else if libc::dup2(fd, 3) != 3 {
            return Err(std::io::Error::last_os_error());
        }
        for other in 4..max_fd {
            libc::close(other);
        }
    }
    Ok(())
}
