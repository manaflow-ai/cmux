//! One app host process: started with fd 3 on its own thread (never under
//! the caller's lock), write [`ToHost`] lines, read [`FromHost`] lines on
//! that thread, which blocks on the socket, and report the exit once the
//! socket closes and the child is reaped.

use std::io::{BufRead, BufReader, Read, Write};
use std::os::fd::AsFd;
use std::os::unix::net::UnixStream;
use std::os::unix::process::ExitStatusExt;
use std::path::{Path, PathBuf};
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

/// Where first-party app server binaries ship: `CMUX_APP_SERVER_DIR`, else
/// the directory of the daemon executable (next to `cmux-app-host`).
pub fn resolve_server_dir() -> Option<PathBuf> {
    if let Some(dir) = std::env::var_os("CMUX_APP_SERVER_DIR").map(PathBuf::from) {
        return dir.is_dir().then_some(dir);
    }
    Some(std::env::current_exe().ok()?.parent()?.to_path_buf())
}

impl HostProcess {
    /// Starts the host with a clean environment and only fd 3 open beyond
    /// the null stdio, and returns at once: the process starts on the
    /// host's own thread. A process start is fork or spawn, exec and the
    /// dynamic loader, which a loaded machine stretches to seconds, and
    /// callers hold the supervisor lock; lines sent meanwhile wait in the
    /// socket. `on_message` runs on that thread for every line; `on_exit`
    /// runs once after the socket closed and the child was reaped, or with
    /// the error when the process did not start.
    pub fn spawn(
        binary: &Path,
        args: &[String],
        name: &str,
        on_message: impl Fn(FromHost) + Send + 'static,
        on_exit: impl FnOnce(std::io::Result<Exit>) + Send + 'static,
    ) -> std::io::Result<Self> {
        let (ours, theirs) = UnixStream::pair()?;
        let reader = ours.try_clone()?;
        let writer = ours.try_clone()?;
        let (queue, outgoing) = sync_channel(QUEUE);
        std::thread::Builder::new()
            .name(format!("cmux-app-host-w:{name}"))
            .spawn(move || write_loop(writer, outgoing))?;
        let (binary, args) = (binary.to_path_buf(), args.to_vec());
        #[cfg(test)]
        let name_for_pause = name.to_string();
        std::thread::Builder::new().name(format!("cmux-app-host:{name}")).spawn(move || {
            #[cfg(test)]
            test_seams::spawn_pause(&name_for_pause);
            let started = start_process(&binary, &args, &theirs);
            // The child holds its own copy now (or never will).
            drop(theirs);
            let mut child = match started {
                Ok(child) => child,
                Err(error) => {
                    let _ = reader.shutdown(std::net::Shutdown::Both);
                    on_exit(Err(error));
                    return;
                }
            };
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
            let _ = child.kill();
            let exit = match child.wait() {
                Ok(status) => Exit { code: status.code(), signal: status.signal() },
                Err(_) => Exit { code: None, signal: None },
            };
            on_exit(Ok(exit));
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

/// Starts `binary` with an empty environment, null stdio and `channel` on
/// fd 3, and no other descriptor of this process. Through `cmux_process`:
/// on macOS one `posix_spawn` with `POSIX_SPAWN_CLOEXEC_DEFAULT`, so no fork
/// of this large multithreaded process and no descriptor loop in a child (it
/// was up to 65,536 `fcntl` calls at the daemon's open-file limit); a
/// missing or unusable binary is its error.
fn start_process(
    binary: &Path,
    args: &[String],
    channel: &UnixStream,
) -> std::io::Result<cmux_process::Child> {
    let mut command = cmux_process::Command::new(binary);
    command
        .args(args)
        .env_clear()
        .stdin(cmux_process::Stdio::null())
        .stdout(cmux_process::Stdio::null())
        .stderr(cmux_process::Stdio::null())
        .inherit_fd(channel.as_fd(), 3)?;
    command.spawn()
}

/// A slow process start on demand: a loaded machine stretches fork, exec
/// and the dynamic loader to seconds, which a test cannot rely on.
#[cfg(test)]
pub(super) mod test_seams {
    use std::sync::{Mutex, PoisonError};
    use std::time::Duration;

    static PAUSES: Mutex<Vec<(String, Duration)>> = Mutex::new(Vec::new());

    /// The next start of a host named `name` takes `pause` longer.
    pub(in crate::apps) fn pause_next_spawn(name: &str, pause: Duration) {
        PAUSES.lock().unwrap_or_else(PoisonError::into_inner).push((name.into(), pause));
    }

    pub(super) fn spawn_pause(name: &str) {
        let pause = {
            let mut pauses = PAUSES.lock().unwrap_or_else(PoisonError::into_inner);
            let index = pauses.iter().position(|(n, _)| n == name);
            index.map(|i| pauses.remove(i).1)
        };
        if let Some(pause) = pause {
            std::thread::sleep(pause);
        }
    }
}

#[cfg(test)]
mod spawn_tests {
    use std::os::fd::AsRawFd;
    use std::sync::mpsc::channel;
    use std::time::Duration;

    use cmux_app_host::FromHost;

    use super::HostProcess;

    /// A host binary that cannot run is reported as an exit that never
    /// started. The descriptor step used to close `Command::spawn`'s
    /// exec-error pipe: the child aborted and the spawn looked successful.
    #[test]
    fn a_host_binary_that_cannot_run_is_a_spawn_error() {
        let missing = std::path::Path::new("/nonexistent/cmux-app-host");
        let (tx, rx) = channel();
        let started = HostProcess::spawn(
            missing,
            &[],
            "missing",
            |_| {},
            move |exit| {
                let _ = tx.send(exit);
            },
        );
        assert!(started.is_ok(), "the start happens on the host's thread");
        let exit = rx.recv_timeout(Duration::from_secs(30)).expect("an exit");
        let error = exit.expect_err("a missing binary does not start");
        assert_eq!(error.kind(), std::io::ErrorKind::NotFound, "{error}");
    }

    /// A host gets null stdio and its channel on fd 3, nothing else of the
    /// daemon: not a descriptor some library opened without close-on-exec.
    #[test]
    fn a_host_inherits_only_its_channel_and_null_stdio() {
        let file = std::fs::File::open("/dev/null").unwrap();
        // SAFETY: duplicating our own open descriptor; F_DUPFD leaves the copy inheritable.
        let leaked = unsafe { libc::fcntl(file.as_raw_fd(), libc::F_DUPFD, 200) };
        assert!(leaked >= 200, "an inheritable descriptor at 200 or above");
        let template =
            serde_json::to_string(&FromHost::Log { level: "info".into(), message: "FDS".into() })
                .unwrap()
                .replace('"', "\\\"");
        let line = template.replace("FDS", "$(ls /dev/fd | tr '\\n' ' ')");
        let script = format!("printf '%s\\n' \"{line}\" >&3; read -r _ <&3");
        let (tx, rx) = channel();
        let process = HostProcess::spawn(
            std::path::Path::new("/bin/sh"),
            &["-c".into(), script],
            "fds",
            move |message| {
                if let FromHost::Log { message, .. } = message {
                    let _ = tx.send(message);
                }
            },
            |_| {},
        )
        .unwrap();
        let listing = rx.recv_timeout(Duration::from_secs(30)).expect("the host's descriptors");
        process.kill();
        // SAFETY: closing the descriptor this test made.
        unsafe { libc::close(leaked) };
        let fds: Vec<i32> = listing.split_whitespace().filter_map(|f| f.parse().ok()).collect();
        for fd in [0, 1, 2, 3] {
            assert!(fds.contains(&fd), "fd {fd} is open in the host: {listing}");
        }
        // macOS: CLOEXEC_DEFAULT keeps even an inheritable descriptor out.
        // Linux runs std's spawn, where descriptors are close-on-exec from
        // birth (pipe2, SOCK_CLOEXEC, MSG_CMSG_CLOEXEC), as `cmux_process`
        // documents, so only one made inheritable on purpose would pass.
        #[cfg(target_vendor = "apple")]
        assert!(!fds.contains(&leaked), "fd {leaked} reached the host: {listing}");
    }
}
