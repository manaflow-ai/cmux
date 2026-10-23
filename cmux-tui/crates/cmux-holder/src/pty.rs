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
    /// The PTY's device number ([`tty_device`]).
    pub tty: Option<u64>,
}

/// Open a PTY sized `cols` x `rows` and start `request.argv` on it with
/// exactly `request.env` and `request.cwd`, as the leader of a new session
/// whose controlling terminal is the PTY. A bare program name is looked up
/// in the request's `PATH`, as `Command::new` does on the local path. A
/// directory or program the child cannot enter or run fails the spawn (the
/// child reports its errno on a close-on-exec pipe) instead of starting a
/// shell elsewhere or exiting 127. `open_file_limit` is the soft
/// `RLIMIT_NOFILE` the child gets back (the one cmux started with, before
/// the daemon raised its own: programs that use `select(2)` break above
/// 1024). The holder is single threaded, so `fork` is safe here; the child
/// only calls async-signal-safe functions before `execve`.
pub fn spawn(request: &SpawnRequest, open_file_limit: Option<u64>) -> io::Result<Spawned> {
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
    let tty = tty_device(master.as_raw_fd());
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
            child(
                (slave.as_raw_fd(), error_write.as_raw_fd()),
                open_file_limit,
                &cwd,
                &program,
                (&argv_ptrs, &env_ptrs),
            )
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
    Ok(Spawned { master, pid, tty })
}

/// The child could not enter its directory.
const STAGE_CHDIR: u8 = b'C';
/// The child could not `execve` its program.
const STAGE_EXEC: u8 = b'E';

/// The child after `fork`: new session, the PTY as controlling terminal and
/// stdio, default signal dispositions, the open-file limit cmux started
/// with, its directory, then `execve`. Every other descriptor of the holder
/// is close-on-exec ([`mark_inherited_close_on_exec`] at startup, and each
/// one it opens later), so the program gets only its PTY. A failure writes
/// `stage u8, errno i32` to `error` and exits 127.
unsafe fn child(
    (slave, error): (libc::c_int, libc::c_int),
    open_file_limit: Option<u64>,
    cwd: &CString,
    program: &CString,
    (argv, env): (&[*const libc::c_char], &[*const libc::c_char]),
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
        if let Some(soft) = open_file_limit {
            let mut limit: libc::rlimit = std::mem::zeroed();
            if libc::getrlimit(libc::RLIMIT_NOFILE, &mut limit) == 0 {
                limit.rlim_cur = (soft as libc::rlim_t).min(limit.rlim_max);
                libc::setrlimit(libc::RLIMIT_NOFILE, &limit);
            }
        }
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

/// The device number of the PTY whose master is `master` (its slave's
/// `st_rdev`), which names the terminal's processes in the process table.
pub fn tty_device(master: libc::c_int) -> Option<u64> {
    use std::os::unix::fs::MetadataExt;
    // SAFETY: ptsname returns a pointer to a static buffer (the holder is
    // single threaded) or null.
    let name = unsafe { libc::ptsname(master) };
    if name.is_null() {
        return None;
    }
    // SAFETY: a non-null ptsname result is a NUL-terminated string.
    let name = unsafe { std::ffi::CStr::from_ptr(name) };
    std::fs::metadata(OsStr::from_bytes(name.to_bytes())).ok().map(|meta| meta.rdev())
}

/// Send `signal` to every process group of a terminal: its child's
/// (`leader`), the PTY's foreground group, and on macOS the group of each
/// process whose controlling terminal is the PTY (`tty`). A login(1) start
/// puts the shell and its jobs in groups of their own under login's, so
/// signalling the child's group alone would leave them running. Never the
/// holder's own group.
pub fn signal_terminal(
    leader: libc::pid_t,
    master: libc::c_int,
    tty: Option<u64>,
    signal: libc::c_int,
) {
    let mut groups = vec![leader];
    // SAFETY: tcgetpgrp on a master this holder keeps open.
    let foreground = unsafe { libc::tcgetpgrp(master) };
    if foreground > 0 {
        groups.push(foreground);
    }
    #[cfg(target_vendor = "apple")]
    if let Some(tty) = tty {
        for pid in tty_processes(tty) {
            // SAFETY: getpgid reads the group of a pid; a gone pid fails.
            let group = unsafe { libc::getpgid(pid) };
            if group > 0 {
                groups.push(group);
            }
        }
    }
    #[cfg(not(target_vendor = "apple"))]
    let _ = tty;
    // SAFETY: getpgrp cannot fail.
    let own = unsafe { libc::getpgrp() };
    groups.sort_unstable();
    groups.dedup();
    for group in groups {
        if group > 1 && group != own {
            // SAFETY: signals one process group of this terminal.
            unsafe { libc::killpg(group, signal) };
        }
    }
}

/// The pids whose controlling terminal is device `tty`.
#[cfg(target_vendor = "apple")]
fn tty_processes(tty: u64) -> Vec<libc::pid_t> {
    /// `PROC_TTY_ONLY` of `<sys/proc_info.h>`; libc does not export it.
    const PROC_TTY_ONLY: u32 = 3;
    // dev_t is 32 bits on macOS; a sign-extended one keeps its low half.
    let tty = tty as u32;
    // SAFETY: a null buffer asks only for the size the list needs.
    let bytes = unsafe { libc::proc_listpids(PROC_TTY_ONLY, tty, std::ptr::null_mut(), 0) };
    let Ok(bytes) = usize::try_from(bytes) else { return Vec::new() };
    let mut pids: Vec<libc::pid_t> = vec![0; bytes / size_of::<libc::pid_t>() + 16];
    let room = (pids.len() * size_of::<libc::pid_t>()) as libc::c_int;
    // SAFETY: fills at most `room` bytes of a live buffer of that size.
    let filled = unsafe { libc::proc_listpids(PROC_TTY_ONLY, tty, pids.as_mut_ptr().cast(), room) };
    let Ok(filled) = usize::try_from(filled) else { return Vec::new() };
    pids.truncate(filled / size_of::<libc::pid_t>());
    pids.retain(|pid| *pid > 0);
    pids
}

/// Mark every descriptor above stderr close-on-exec: the holder starts
/// with whatever its daemon inherited without close-on-exec (from the app,
/// a launcher or a test), and `fork` + `execve` would pass each one to
/// every shell for its whole life. Call once at startup; every descriptor
/// the holder opens afterwards is close-on-exec already.
pub fn mark_inherited_close_on_exec() {
    let listed: Option<Vec<libc::c_int>> = std::fs::read_dir("/dev/fd").ok().map(|entries| {
        entries
            .flatten()
            .filter_map(|entry| entry.file_name().to_str()?.parse::<libc::c_int>().ok())
            .collect()
    });
    let descriptors = listed.unwrap_or_else(|| {
        // SAFETY: sysconf takes no pointers.
        let limit = unsafe { libc::sysconf(libc::_SC_OPEN_MAX) };
        (3..libc::c_int::try_from(limit.clamp(3, 65_536)).unwrap_or(3)).collect()
    });
    for fd in descriptors {
        if fd > 2 {
            set_cloexec(fd);
        }
    }
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
