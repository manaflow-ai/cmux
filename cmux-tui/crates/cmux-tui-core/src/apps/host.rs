//! One app host process: spawn with fd 3, write [`ToHost`] lines, read
//! [`FromHost`] lines on a reader thread that blocks on the socket, and
//! report the exit once the socket closes and the child is reaped.

use crate::supervised::{self, Fatal, ShutdownBehavior};
use cmux_threads::checked::sync as waits;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::fd::AsFd;
use std::os::unix::net::UnixStream;
use std::os::unix::process::ExitStatusExt;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{Receiver, SyncSender, TrySendError, sync_channel};

use cmux_app_host::protocol::MAX_LINE_BYTES;
use cmux_app_host::{FromHost, ToHost};
use cmux_process::{Command, Stdio};

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

/// `--panic-log <path>`: the host's panic log (`HelperPanicLog::AppHost`),
/// which it opens before its sandbox holds. Empty with no state directory.
pub fn panic_log_args() -> Vec<String> {
    crate::diagnostics::HelperPanicLog::AppHost
        .path()
        .and_then(|path| path.into_os_string().into_string().ok())
        .map(|path| vec![cmux_app_host::protocol::PANIC_LOG_FLAG.to_string(), path])
        .unwrap_or_default()
}

/// Where first-party app server binaries ship: `CMUX_APP_SERVER_DIR`, else
/// the directory of the daemon executable (next to `cmux-app-host`).
pub fn resolve_server_dir() -> Option<PathBuf> {
    if let Some(dir) = std::env::var_os("CMUX_APP_SERVER_DIR").map(PathBuf::from) {
        return dir.is_dir().then_some(dir);
    }
    Some(std::env::current_exe().ok()?.parent()?.to_path_buf())
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
        let mut command = Command::new(binary);
        command
            .args(args)
            .env_clear()
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            // Only fd 3 beyond the null stdio, on Linux too.
            .isolate()
            .inherit_fd(theirs.as_fd(), 3)?;
        crate::request_path::note(crate::request_path::BlockingKind::ProcessSpawn);
        let mut child = command.spawn()?;
        drop(theirs);
        let pid = child.id();
        let reader = ours.try_clone()?;
        let writer = ours.try_clone()?;
        let (queue, outgoing) = sync_channel(QUEUE);
        supervised::spawn_at(
            format!("cmux-app-host-w:{name}"),
            cmux_threads::ThreadQos::Utility,
            Fatal,
            ShutdownBehavior::Continue,
            move || write_loop(writer, outgoing),
        )?;
        supervised::spawn_at(
            format!("cmux-app-host:{name}"),
            cmux_threads::ThreadQos::Utility,
            Fatal,
            ShutdownBehavior::Continue,
            move || {
                let mut lines = BufReader::new(reader);
                let mut line = Vec::new();
                loop {
                    line.clear();
                    match lines
                        .by_ref()
                        .take(MAX_LINE_BYTES as u64 + 1)
                        .read_until(b'\n', &mut line)
                    {
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
            },
        )?;
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
    while let Ok(item) = waits::recv(&outgoing) {
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

#[cfg(test)]
mod spawn_tests {
    use super::HostProcess;

    /// A host binary that cannot run is a spawn error. The descriptor step
    /// used to close `Command::spawn`'s exec-error pipe: the child aborted
    /// and the spawn looked successful.
    #[test]
    fn a_host_binary_that_cannot_run_is_a_spawn_error() {
        let missing = std::path::Path::new("/nonexistent/cmux-app-host");
        let result = HostProcess::spawn(missing, &[], "missing", |_| {}, |_| {});
        let error = result.err().expect("a missing binary does not start");
        assert_eq!(error.kind(), std::io::ErrorKind::NotFound, "{error}");
    }
}
