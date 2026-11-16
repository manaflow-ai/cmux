//! One app host process: started with fd 3 on its own thread (never under
//! the caller's lock), write [`ToHost`] lines, read [`FromHost`] lines on
//! that thread, which blocks on the socket, and report the exit once the
//! socket closes and the child is reaped.

use std::io::{BufRead, BufReader, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
#[cfg(not(target_os = "macos"))]
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
#[cfg(not(target_os = "macos"))]
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
            let pid = match started {
                Ok(pid) => pid,
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
            // SAFETY: signalling our own child by pid; it is not reaped yet, so the pid is still ours.
            unsafe { libc::kill(pid, libc::SIGKILL) };
            on_exit(Ok(reap(pid)));
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

/// Waits for `pid` (our child) and reads how it ended.
fn reap(pid: libc::pid_t) -> Exit {
    let mut status: libc::c_int = 0;
    loop {
        // SAFETY: waiting on our own child; `status` is a valid out pointer.
        let rc = unsafe { libc::waitpid(pid, &mut status, 0) };
        if rc == pid {
            break;
        }
        if rc == -1 && std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted {
            continue;
        }
        return Exit { code: None, signal: None };
    }
    if libc::WIFEXITED(status) {
        Exit { code: Some(libc::WEXITSTATUS(status)), signal: None }
    } else if libc::WIFSIGNALED(status) {
        Exit { code: None, signal: Some(libc::WTERMSIG(status)) }
    } else {
        Exit { code: None, signal: None }
    }
}

/// Starts `binary` with an empty environment, null stdio and `channel` on
/// fd 3, and no other descriptor of this process. macOS: one
/// `posix_spawn` with `POSIX_SPAWN_CLOEXEC_DEFAULT` (no fork of this large
/// multithreaded process, no descriptor loop), and a missing or unusable
/// binary is its error.
#[cfg(target_os = "macos")]
fn start_process(
    binary: &Path,
    args: &[String],
    channel: &UnixStream,
) -> std::io::Result<libc::pid_t> {
    use std::ffi::CString;
    use std::os::unix::ffi::OsStrExt;

    unsafe extern "C" {
        fn posix_spawn_file_actions_addinherit_np(
            actions: *mut libc::posix_spawn_file_actions_t,
            fd: libc::c_int,
        ) -> libc::c_int;
    }
    /// `POSIX_SPAWN_CLOEXEC_DEFAULT` in <spawn.h>.
    const CLOEXEC_DEFAULT: libc::c_short = 0x4000;

    let path = CString::new(binary.as_os_str().as_bytes())?;
    let mut owned = vec![path.clone()];
    for arg in args {
        owned.push(CString::new(arg.as_bytes())?);
    }
    let mut argv: Vec<*mut libc::c_char> =
        owned.iter().map(|arg| arg.as_ptr().cast_mut()).collect();
    argv.push(std::ptr::null_mut());
    let envp: [*mut libc::c_char; 1] = [std::ptr::null_mut()];
    let null = c"/dev/null";
    let fd = channel.as_raw_fd();
    let check = |rc: libc::c_int| {
        if rc == 0 { Ok(()) } else { Err(std::io::Error::from_raw_os_error(rc)) }
    };
    // SAFETY: the actions and attributes are initialized before use and
    // destroyed once on every path; every pointer passed outlives the call.
    unsafe {
        let mut actions: libc::posix_spawn_file_actions_t = std::ptr::null_mut();
        check(libc::posix_spawn_file_actions_init(&mut actions))?;
        let mut attr: libc::posix_spawnattr_t = std::ptr::null_mut();
        if let Err(error) = check(libc::posix_spawnattr_init(&mut attr)) {
            libc::posix_spawn_file_actions_destroy(&mut actions);
            return Err(error);
        }
        let result = (|| {
            for (stdio, mode) in [(0, libc::O_RDONLY), (1, libc::O_WRONLY), (2, libc::O_WRONLY)] {
                let null = null.as_ptr();
                check(libc::posix_spawn_file_actions_addopen(&mut actions, stdio, null, mode, 0))?;
            }
            if fd == 3 {
                check(posix_spawn_file_actions_addinherit_np(&mut actions, 3))?;
            } else {
                check(libc::posix_spawn_file_actions_adddup2(&mut actions, fd, 3))?;
            }
            // The daemon ignores SIGPIPE; the host starts with it at its
            // default and no signal blocked, as `Command` would.
            let mut empty: libc::sigset_t = std::mem::zeroed();
            libc::sigemptyset(&mut empty);
            check(libc::posix_spawnattr_setsigmask(&mut attr, &empty))?;
            let mut pipe: libc::sigset_t = std::mem::zeroed();
            libc::sigemptyset(&mut pipe);
            libc::sigaddset(&mut pipe, libc::SIGPIPE);
            check(libc::posix_spawnattr_setsigdefault(&mut attr, &pipe))?;
            let flags = CLOEXEC_DEFAULT
                | libc::POSIX_SPAWN_SETSIGMASK as libc::c_short
                | libc::POSIX_SPAWN_SETSIGDEF as libc::c_short;
            check(libc::posix_spawnattr_setflags(&mut attr, flags))?;
            let mut pid: libc::pid_t = 0;
            check(libc::posix_spawn(
                &mut pid,
                path.as_ptr(),
                &actions,
                &attr,
                argv.as_ptr(),
                envp.as_ptr(),
            ))?;
            Ok(pid)
        })();
        libc::posix_spawnattr_destroy(&mut attr);
        libc::posix_spawn_file_actions_destroy(&mut actions);
        result
    }
}

/// Elsewhere (Linux): fork and exec through `Command`, with the channel on
/// fd 3 and every other descriptor close-on-exec in one `close_range` call.
#[cfg(not(target_os = "macos"))]
fn start_process(
    binary: &Path,
    args: &[String],
    channel: &UnixStream,
) -> std::io::Result<libc::pid_t> {
    let fd = channel.as_raw_fd();
    let mut command = Command::new(binary);
    command.args(args).env_clear().stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    // SAFETY: sysconf before the fork; only async-signal-safe calls in pre_exec.
    let max_fd = match unsafe { libc::sysconf(libc::_SC_OPEN_MAX) } {
        n if n > 0 => n.min(65_536) as libc::c_int,
        _ => 4096,
    };
    // SAFETY: only async-signal-safe calls between fork and exec.
    unsafe { command.pre_exec(move || child_fds(fd, max_fd)) };
    // The child is reaped by pid (`reap`); `Child` does not wait on drop.
    let child = command.spawn()?;
    Ok(child.id() as libc::pid_t)
}

/// In the child before exec: the channel on fd 3 without close-on-exec, and
/// every other inherited descriptor above 3 close-on-exec.
#[cfg(not(target_os = "macos"))]
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
        // Close-on-exec, not closed: `Command::spawn` reports a failed exec
        // over a private pipe, and closing it aborts the child instead.
        // One call where the kernel has it (Linux 5.11).
        #[cfg(target_os = "linux")]
        {
            const CLOSE_RANGE_CLOEXEC: libc::c_uint = 1 << 2;
            if libc::syscall(libc::SYS_close_range, 4_u32, u32::MAX, CLOSE_RANGE_CLOEXEC) == 0 {
                return Ok(());
            }
        }
        for other in 4..max_fd {
            libc::fcntl(other, libc::F_SETFD, libc::FD_CLOEXEC);
        }
    }
    Ok(())
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
        let error = exit.err().expect("a missing binary does not start");
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
        assert!(!fds.contains(&leaked), "fd {leaked} reached the host: {listing}");
    }
}
