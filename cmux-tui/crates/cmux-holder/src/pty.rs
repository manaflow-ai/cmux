//! Open a PTY and start a child on it as its session leader.

use std::ffi::{CString, OsStr};
use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::PermissionsExt;

use crate::SpawnRequest;

/// A child running on a new PTY.
pub struct Spawned {
    pub master: OwnedFd,
    pub pid: libc::pid_t,
}

/// Open a PTY sized `cols` x `rows` and start `request.argv` on it with
/// exactly `request.env` and `request.cwd`, as the leader of a new session
/// whose controlling terminal is the PTY. A bare program name is looked up
/// in the request's `PATH`, as `Command::new` does on the local path. A
/// directory or program the child cannot enter or run fails the spawn (the
/// child reports its errno on a close-on-exec pipe) instead of starting a
/// shell elsewhere or exiting 127. The holder is single threaded, so `fork`
/// is safe here; the child only calls async-signal-safe functions before
/// `execve`.
pub fn spawn(request: &SpawnRequest) -> io::Result<Spawned> {
    let argv = c_strings(&request.argv)?;
    if argv.is_empty() {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "empty argv"));
    }
    let program = resolve_program(&request.argv[0], &request.env, &request.cwd)?;
    let env = c_strings(&request.env)?;
    let cwd = CString::new(request.cwd.clone())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "cwd has a NUL"))?;
    let mut argv_ptrs: Vec<*const libc::c_char> = argv.iter().map(|s| s.as_ptr()).collect();
    argv_ptrs.push(std::ptr::null());
    let mut env_ptrs: Vec<*const libc::c_char> = env.iter().map(|s| s.as_ptr()).collect();
    env_ptrs.push(std::ptr::null());

    let mut master: libc::c_int = -1;
    let mut slave: libc::c_int = -1;
    let mut size = libc::winsize {
        ws_row: request.rows,
        ws_col: request.cols,
        ws_xpixel: request.px_w,
        ws_ypixel: request.px_h,
    };
    // SAFETY: out-pointers to live locals; no name buffer, default termios.
    let opened = unsafe {
        libc::openpty(
            &mut master,
            &mut slave,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            &mut size,
        )
    };
    if opened != 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: openpty returned two fresh descriptors this function owns.
    let (master, slave) = unsafe { (OwnedFd::from_raw_fd(master), OwnedFd::from_raw_fd(slave)) };
    set_cloexec(master.as_raw_fd());
    set_cloexec(slave.as_raw_fd());
    let (error_read, error_write) = cloexec_pipe()?;

    // SAFETY: single-threaded process; the child path below calls only
    // async-signal-safe functions and ends in execve or _exit.
    let pid = unsafe { libc::fork() };
    if pid < 0 {
        return Err(io::Error::last_os_error());
    }
    if pid == 0 {
        // SAFETY: child side of fork, see above.
        unsafe {
            child(slave.as_raw_fd(), error_write.as_raw_fd(), &cwd, &program, &argv_ptrs, &env_ptrs)
        }
    }
    drop(slave);
    drop(error_write);
    if let Some((stage, errno)) = child_error(&error_read) {
        // The child reported and exits 127: reap it here, it never ran.
        let mut status = 0;
        // SAFETY: waits for the child this call forked.
        while unsafe { libc::waitpid(pid, &mut status, 0) } < 0
            && io::Error::last_os_error().kind() == io::ErrorKind::Interrupted
        {}
        let error = io::Error::from_raw_os_error(errno);
        let what = match stage {
            STAGE_CHDIR => format!("enter {}", String::from_utf8_lossy(&request.cwd)),
            STAGE_EXEC => format!("run {}", program.to_string_lossy()),
            _ => "start the terminal".to_string(),
        };
        return Err(io::Error::new(error.kind(), format!("{what}: {error}")));
    }
    // The master's open file description is shared with every dup the
    // daemon holds; the daemon's writer waits for room on its own
    // (holder_runtime::terminal), so non-blocking here is safe for it.
    set_nonblocking(master.as_raw_fd());
    Ok(Spawned { master, pid })
}

/// The child could not enter its directory.
const STAGE_CHDIR: u8 = b'C';
/// The child could not `execve` its program.
const STAGE_EXEC: u8 = b'E';

/// The child after `fork`: new session, the PTY as controlling terminal and
/// stdio, default signal dispositions, its directory, then `execve`. A
/// failure writes `stage u8, errno i32` to `error` and exits 127.
unsafe fn child(
    slave: libc::c_int,
    error: libc::c_int,
    cwd: &CString,
    program: &CString,
    argv: &[*const libc::c_char],
    env: &[*const libc::c_char],
) -> ! {
    // SAFETY: async-signal-safe calls on descriptors and pointers that stay
    // valid until execve.
    unsafe {
        libc::setsid();
        libc::ioctl(slave, libc::TIOCSCTTY as _, 0);
        libc::dup2(slave, 0);
        libc::dup2(slave, 1);
        libc::dup2(slave, 2);
        for signal in
            [libc::SIGHUP, libc::SIGINT, libc::SIGQUIT, libc::SIGTERM, libc::SIGPIPE, libc::SIGCHLD]
        {
            libc::signal(signal, libc::SIG_DFL);
        }
        let empty: libc::sigset_t = std::mem::zeroed();
        libc::sigprocmask(libc::SIG_SETMASK, &empty, std::ptr::null_mut());
        if libc::chdir(cwd.as_ptr()) != 0 {
            report_and_exit(error, STAGE_CHDIR)
        }
        libc::execve(program.as_ptr(), argv.as_ptr(), env.as_ptr());
        report_and_exit(error, STAGE_EXEC)
    }
}

/// Write `stage` and the current errno to the parent's error pipe, then
/// `_exit(127)`. Async-signal-safe.
unsafe fn report_and_exit(error: libc::c_int, stage: u8) -> ! {
    // SAFETY: errno read and one write of a stack buffer, then _exit.
    unsafe {
        let errno = io::Error::last_os_error().raw_os_error().unwrap_or(libc::EIO);
        let mut report = [stage, 0, 0, 0, 0];
        report[1..].copy_from_slice(&errno.to_ne_bytes());
        libc::write(error, report.as_ptr().cast(), report.len());
        libc::_exit(127)
    }
}

/// The child's `stage, errno` report, or `None` once its `execve` closed
/// the pipe's write end (the program runs).
fn child_error(read: &OwnedFd) -> Option<(u8, i32)> {
    let mut report = [0u8; 5];
    let mut got = 0;
    while got < report.len() {
        // SAFETY: reads into the unfilled tail of a live buffer.
        let n = unsafe {
            libc::read(read.as_raw_fd(), report[got..].as_mut_ptr().cast(), report.len() - got)
        };
        if n > 0 {
            got += n as usize;
        } else if n == 0 || io::Error::last_os_error().kind() != io::ErrorKind::Interrupted {
            break;
        }
    }
    (got == report.len())
        .then(|| (report[0], i32::from_ne_bytes([report[1], report[2], report[3], report[4]])))
}

/// A blocking pipe whose two ends close on exec.
fn cloexec_pipe() -> io::Result<(OwnedFd, OwnedFd)> {
    let mut fds = [0; 2];
    // SAFETY: pipe fills two descriptors.
    if unsafe { libc::pipe(fds.as_mut_ptr()) } != 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: pipe returned two fresh descriptors this function owns.
    let (read, write) = unsafe { (OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) };
    set_cloexec(read.as_raw_fd());
    set_cloexec(write.as_raw_fd());
    Ok((read, write))
}

/// The path `execve` runs for `program`: itself when it names a path (has a
/// `/`), else the first executable file of that name in the `PATH` of
/// `env` (`/usr/bin:/bin` without one). A relative `PATH` entry is taken
/// from `cwd`, where the child runs it.
fn resolve_program(program: &[u8], env: &[Vec<u8>], cwd: &[u8]) -> io::Result<CString> {
    let nul =
        |_: std::ffi::NulError| io::Error::new(io::ErrorKind::InvalidInput, "program has a NUL");
    if program.is_empty() {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "empty program name"));
    }
    if program.contains(&b'/') {
        return CString::new(program).map_err(nul);
    }
    let path = env
        .iter()
        .rev()
        .find_map(|entry| entry.strip_prefix(b"PATH="))
        .unwrap_or(&b"/usr/bin:/bin"[..]);
    for dir in path.split(|byte| *byte == b':') {
        let mut candidate = Vec::new();
        if !dir.starts_with(b"/") {
            candidate.extend_from_slice(cwd);
            candidate.push(b'/');
        }
        candidate.extend_from_slice(if dir.is_empty() { &b"."[..] } else { dir });
        candidate.push(b'/');
        candidate.extend_from_slice(program);
        if is_executable_file(&candidate) {
            return CString::new(candidate).map_err(nul);
        }
    }
    Err(io::Error::new(
        io::ErrorKind::NotFound,
        format!("{} is not in PATH", String::from_utf8_lossy(program)),
    ))
}

fn is_executable_file(path: &[u8]) -> bool {
    std::fs::metadata(OsStr::from_bytes(path))
        .is_ok_and(|meta| meta.is_file() && meta.permissions().mode() & 0o111 != 0)
}

fn c_strings(values: &[Vec<u8>]) -> io::Result<Vec<CString>> {
    values
        .iter()
        .map(|value| {
            CString::new(value.clone())
                .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "argument has a NUL"))
        })
        .collect()
}

/// Mark a descriptor close-on-exec.
pub fn set_cloexec(fd: libc::c_int) {
    // SAFETY: fcntl on a descriptor the caller owns.
    unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) };
}

/// Make a descriptor non-blocking.
pub fn set_nonblocking(fd: libc::c_int) {
    // SAFETY: fcntl on a descriptor the caller owns.
    unsafe {
        let flags = libc::fcntl(fd, libc::F_GETFL);
        libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK);
    }
}

/// Set a PTY's window size.
pub fn resize(master: libc::c_int, cols: u16, rows: u16, px_w: u16, px_h: u16) -> io::Result<()> {
    let size = libc::winsize { ws_row: rows, ws_col: cols, ws_xpixel: px_w, ws_ypixel: px_h };
    // SAFETY: TIOCSWINSZ reads one winsize from a live local.
    if unsafe { libc::ioctl(master, libc::TIOCSWINSZ as _, &size) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_bare_program_name_resolves_on_the_requests_path() {
        let env = vec![b"HOME=/".to_vec(), b"PATH=/nonexistent-cmux-dir:/bin:/usr/bin".to_vec()];
        let resolved = resolve_program(b"sh", &env, b"/").unwrap();
        assert!(resolved.to_bytes().ends_with(b"/sh"), "{resolved:?}");
        assert_eq!(resolve_program(b"/bin/sh", &[], b"/").unwrap().to_bytes(), b"/bin/sh");
        let missing = resolve_program(b"cmux-no-such-program", &env, b"/").unwrap_err();
        assert_eq!(missing.kind(), io::ErrorKind::NotFound);
    }
}
