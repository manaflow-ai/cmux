//! A stdio server ends with the process that started it (ask-25170f5ee5).
//!
//! An agent's MCP servers (`cmux mcp serve`, `acpmux subsession-mcp`,
//! `forum-mcp`, `acpmux-mcp`, ...) end when stdin closes. That is not enough:
//! when a harness dies while another process still holds the write end of
//! the server's stdin (a sibling spawned while the pipe was open, which
//! macOS cannot rule out, `cmux-process`), the server waits forever. On a
//! busy Mac that left a dozen of each running for sessions long gone.
//!
//! [`exit_with_parent`] records the parent at startup and exits this
//! process once it is gone. It waits on a kernel event, not a timer: a
//! Linux pidfd, kqueue `EVFILT_PROC`/`NOTE_EXIT` on macOS. Only where the
//! kernel has neither (Linux before 5.3) does it re-check `getppid` every
//! [`FALLBACK_CHECK`]. A parent counts as gone once `getppid` no longer
//! names it (the server was reparented to init or a subreaper), so a pid
//! reused after the parent exited is never waited on.

use std::io;
use std::time::Duration;

/// How often the fallback re-checks the parent, on a kernel with no
/// process-exit event.
pub const FALLBACK_CHECK: Duration = Duration::from_secs(5);

/// This process's parent now.
#[cfg(unix)]
pub fn parent_pid() -> u32 {
    // SAFETY: getppid has no preconditions and cannot fail.
    u32::try_from(unsafe { libc::getppid() }).unwrap_or_default()
}

#[cfg(not(unix))]
pub fn parent_pid() -> u32 {
    0
}

/// Starts a thread that exits this process (status 0) once its parent at
/// the time of this call exits. On Windows it does nothing: there the
/// server ends at stdin EOF only.
///
/// The exit skips destructors. A server that holds children ends them
/// anyway: their stdin is a pipe only this process writes, so they read
/// EOF once it is gone (and acpmux's own servers watch their parent too).
pub fn exit_with_parent() {
    #[cfg(unix)]
    {
        let parent = parent_pid();
        let watcher = std::thread::Builder::new().name("parent-watch".into()).spawn(move || {
            wait_for_parent_or_poll(parent);
            std::process::exit(0);
        });
        if let Err(error) = watcher {
            tracing::warn!("parent watch: no thread, the server ends at stdin EOF only: {error}");
        }
    }
}

/// Blocks until `parent` is no longer this process's parent: on the kernel
/// event, or by [`FALLBACK_CHECK`] where there is none.
#[cfg(unix)]
fn wait_for_parent_or_poll(parent: u32) {
    if wait_for_parent(parent).is_ok() {
        return;
    }
    while parent_pid() == parent {
        std::thread::sleep(FALLBACK_CHECK);
    }
}

/// Blocks until process `parent`, this process's parent when the caller
/// read it, exits (at once when it no longer is the parent). An error means
/// the kernel has no process-exit event here; the caller falls back to
/// checking [`parent_pid`].
#[cfg(target_os = "linux")]
pub fn wait_for_parent(parent: u32) -> io::Result<()> {
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    let pid = libc::pid_t::try_from(parent).map_err(|_| io::ErrorKind::InvalidInput)?;
    // SAFETY: pidfd_open takes a pid and flags and returns a descriptor.
    let fd = unsafe { libc::syscall(libc::SYS_pidfd_open, pid, 0 as libc::c_uint) };
    if fd < 0 {
        let error = io::Error::last_os_error();
        return if error.raw_os_error() == Some(libc::ESRCH) { Ok(()) } else { Err(error) };
    }
    // SAFETY: a successful pidfd_open returns a new descriptor owned here.
    let fd = unsafe { OwnedFd::from_raw_fd(fd as libc::c_int) };
    // The parent may have exited before the open and its pid gone to another
    // process: while `parent` is still our parent, the pidfd is its own.
    if parent_pid() != parent {
        return Ok(());
    }
    let mut pollfd = libc::pollfd { fd: fd.as_raw_fd(), events: libc::POLLIN, revents: 0 };
    loop {
        // SAFETY: `pollfd` names the pidfd owned here.
        if unsafe { libc::poll(&mut pollfd, 1, -1) } > 0 {
            return Ok(());
        }
        let error = io::Error::last_os_error();
        if error.kind() != io::ErrorKind::Interrupted {
            return Err(error);
        }
    }
}

#[cfg(target_os = "macos")]
pub fn wait_for_parent(parent: u32) -> io::Result<()> {
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    let pid = libc::pid_t::try_from(parent).map_err(|_| io::ErrorKind::InvalidInput)?;
    // SAFETY: kqueue has no preconditions.
    let queue = unsafe { libc::kqueue() };
    if queue < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: a successful kqueue returns a new descriptor owned here.
    let queue = unsafe { OwnedFd::from_raw_fd(queue) };
    // SAFETY: an all-zero kevent is a valid value; the fields are set below.
    let mut change: libc::kevent = unsafe { std::mem::zeroed() };
    change.ident = pid as libc::uintptr_t;
    change.filter = libc::EVFILT_PROC;
    change.flags = libc::EV_ADD | libc::EV_ONESHOT;
    change.fflags = libc::NOTE_EXIT;
    // SAFETY: `change` is initialized and outlives the call; no event is read.
    let added = unsafe {
        libc::kevent(queue.as_raw_fd(), &change, 1, std::ptr::null_mut(), 0, std::ptr::null())
    };
    if added < 0 {
        let error = io::Error::last_os_error();
        return if error.raw_os_error() == Some(libc::ESRCH) { Ok(()) } else { Err(error) };
    }
    // As on Linux: registered while `parent` is still our parent, the event
    // is its own.
    if parent_pid() != parent {
        return Ok(());
    }
    // SAFETY: as above.
    let mut event: libc::kevent = unsafe { std::mem::zeroed() };
    loop {
        // SAFETY: `event` outlives the call; no change is applied.
        let count = unsafe {
            libc::kevent(queue.as_raw_fd(), std::ptr::null(), 0, &mut event, 1, std::ptr::null())
        };
        if count > 0 {
            return Ok(());
        }
        let error = io::Error::last_os_error();
        if error.kind() != io::ErrorKind::Interrupted {
            return Err(error);
        }
    }
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
pub fn wait_for_parent(_parent: u32) -> io::Result<()> {
    Err(io::ErrorKind::Unsupported.into())
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::io::{BufRead, BufReader, Read};
    use std::process::{Command, Stdio};
    use std::sync::mpsc;

    const CHILD_ENV: &str = "ACPMUX_PARENT_WATCH_TEST_CHILD";
    const CHILD_TEST: &str = "parent_watch::tests::a_server_whose_parent_died_exits";

    /// The orphaned server: the test binary again, under a shell that the
    /// test kills while the test still holds the server's stdin open.
    #[test]
    fn a_server_whose_parent_died_exits() {
        if std::env::var_os(CHILD_ENV).is_some() {
            exit_with_parent();
            eprintln!("ready {}", std::process::id());
            // Blocks: stdin stays open, so only the parent watch ends this.
            let _ = io::stdin().read_to_end(&mut Vec::new());
            return;
        }
        let mut shell = Command::new("/bin/sh")
            .arg("-c")
            // A background job's stdin would be /dev/null; fd 3 keeps the pipe.
            .arg(r#"exec 3<&0; "$0" --exact "$1" --nocapture <&3 3<&- & wait"#)
            .arg(std::env::current_exe().unwrap())
            .arg(CHILD_TEST)
            .env(CHILD_ENV, "1")
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let _stdin = shell.stdin.take().unwrap();
        let (tx, lines) = mpsc::channel();
        let stderr = BufReader::new(shell.stderr.take().unwrap());
        // Only the shell and the server hold the stderr pipe: its EOF is
        // both gone.
        std::thread::spawn(move || {
            for line in stderr.lines() {
                let _ = tx.send(line.ok());
            }
            let _ = tx.send(None);
        });
        let server = loop {
            let line = lines.recv_timeout(Duration::from_secs(30)).unwrap().unwrap();
            if let Some(pid) = line.strip_prefix("ready ") {
                break pid.parse::<libc::pid_t>().unwrap();
            }
        };
        shell.kill().unwrap();
        shell.wait().unwrap();
        let exited = loop {
            match lines.recv_timeout(Duration::from_secs(20)) {
                Ok(Some(_)) => continue,
                Ok(None) => break true,
                Err(_) => break false,
            }
        };
        if !exited {
            // SAFETY: the server this test started still runs as `server`.
            unsafe { libc::kill(server, libc::SIGKILL) };
        }
        assert!(exited, "the server outlived its parent with stdin still open");
    }

    #[test]
    fn a_parent_that_is_not_ours_counts_as_gone() {
        // Not our parent: the wait returns at once instead of blocking.
        wait_for_parent(std::process::id()).unwrap();
    }
}
