//! Open a PTY and start a child on it as its session leader.

use std::ffi::CString;
use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};

use crate::SpawnRequest;

/// A child forked on a new PTY. Whether it entered its directory and runs
/// its program is not known yet: [`Self::start`] says, later.
pub struct Spawned {
    pub master: OwnedFd,
    pub pid: libc::pid_t,
    /// The child's start report ([`Start::poll`]).
    pub start: Start,
}

/// Open a PTY sized `cols` x `rows` and fork `request.argv` on it with
/// exactly `request.env` and `request.cwd`, as the leader of a new session
/// whose controlling terminal is the PTY. Returns as soon as the child is
/// forked: the holder's one loop serves every terminal, so it never waits
/// for the child and never touches a path the request names (a directory
/// or a `PATH` entry on a network mount that stopped answering would stop
/// every terminal's output). The child enters the directory and finds the
/// program itself: a bare name is tried in each entry of the request's
/// `PATH`, as `execvp` does, a relative entry relative to that directory. A
/// directory or program the child cannot enter or run fails the spawn
/// through [`Spawned::start`] (the child reports its errno on a
/// close-on-exec pipe and exits 127) instead of starting a shell elsewhere.
/// `open_file_limit` is the soft `RLIMIT_NOFILE` the child gets back (the
/// one cmux started with, before the daemon raised its own: programs that
/// use `select(2)` break above 1024). The holder is single threaded, so
/// `fork` is safe here; the child only calls async-signal-safe functions
/// before `execve`.
pub fn spawn(request: &SpawnRequest, open_file_limit: Option<u64>) -> io::Result<Spawned> {
    let argv = c_strings(&request.argv)?;
    let Some(program) = request.argv.first() else {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "empty argv"));
    };
    let programs = program_candidates(program, &request.env)?;
    let env = c_strings(&request.env)?;
    let cwd = CString::new(request.cwd.clone())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "cwd has a NUL"))?;
    let mut argv_ptrs: Vec<*const libc::c_char> = argv.iter().map(|s| s.as_ptr()).collect();
    argv_ptrs.push(std::ptr::null());
    let mut env_ptrs: Vec<*const libc::c_char> = env.iter().map(|s| s.as_ptr()).collect();
    env_ptrs.push(std::ptr::null());
    let program_ptrs: Vec<*const libc::c_char> = programs.iter().map(|s| s.as_ptr()).collect();

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
            // A raw pointer: macOS takes `*mut winsize`, Linux `*const`.
            &raw mut size,
        )
    };
    if opened != 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: openpty returned two fresh descriptors this function owns.
    let (master, slave) = unsafe { (OwnedFd::from_raw_fd(master), OwnedFd::from_raw_fd(slave)) };
    set_cloexec(master.as_raw_fd());
    set_cloexec(slave.as_raw_fd());
    let (report_read, report_write) = cloexec_pipe()?;

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
                (slave.as_raw_fd(), report_write.as_raw_fd()),
                open_file_limit,
                &cwd,
                &program_ptrs,
                (&argv_ptrs, &env_ptrs),
            )
        }
    }
    drop(slave);
    // The child's copy is now the only write end: its execve closes it.
    drop(report_write);
    set_nonblocking(report_read.as_raw_fd());
    // The master's open file description is shared with every dup the
    // daemon holds; the daemon's writer waits for room on its own
    // (holder_runtime::terminal), so non-blocking here is safe for it.
    set_nonblocking(master.as_raw_fd());
    let start = Start {
        pipe: report_read,
        report: [0; REPORT_BYTES],
        got: 0,
        cwd: request.cwd.clone(),
        program: program.clone(),
    };
    Ok(Spawned { master, pid, start })
}

/// The child could not enter its directory.
const STAGE_CHDIR: u8 = b'C';
/// The child could not `execve` its program.
const STAGE_EXEC: u8 = b'E';
/// A start report: `stage u8, errno i32`.
const REPORT_BYTES: usize = 5;

/// A child's start, as its close-on-exec report pipe tells it: end of file
/// once `execve` runs its program, a `stage, errno` report when it could
/// not enter its directory or find and run its program. The holder polls
/// [`Self::fd`] with every other descriptor and calls [`Self::poll`] when
/// it is readable.
pub struct Start {
    pipe: OwnedFd,
    report: [u8; REPORT_BYTES],
    got: usize,
    cwd: Vec<u8>,
    program: Vec<u8>,
}

impl Start {
    /// The report pipe's read end (non-blocking), to poll for `POLLIN`.
    pub fn fd(&self) -> RawFd {
        self.pipe.as_raw_fd()
    }

    /// Read what the pipe has, without blocking. `None` while the child is
    /// still starting; `Some(Ok(()))` once its program runs, or once it
    /// ended without a report (killed before `execve`: its exit status
    /// says how); `Some(Err(..))` with what it could not do, or when the
    /// pipe cannot be read (the caller then ends the child: whether it runs
    /// is not known).
    pub fn poll(&mut self) -> Option<io::Result<()>> {
        loop {
            // `got` stops at REPORT_BYTES (a full report returns below).
            let Some(room) = self.report.get_mut(self.got..) else {
                return Some(Err(self.failure()));
            };
            // SAFETY: reads into the unfilled tail of a live buffer.
            let n =
                unsafe { libc::read(self.pipe.as_raw_fd(), room.as_mut_ptr().cast(), room.len()) };
            if n > 0 {
                self.got += n as usize;
                if self.got == REPORT_BYTES {
                    return Some(Err(self.failure()));
                }
                continue;
            }
            if n == 0 {
                return Some(Ok(()));
            }
            let error = io::Error::last_os_error();
            match error.kind() {
                io::ErrorKind::Interrupted => {}
                io::ErrorKind::WouldBlock => return None,
                kind => {
                    let message = format!("read the start report: {error}");
                    return Some(Err(io::Error::new(kind, message)));
                }
            }
        }
    }

    fn failure(&self) -> io::Error {
        let [stage, errno @ ..] = self.report;
        let error = io::Error::from_raw_os_error(i32::from_ne_bytes(errno));
        let what = match stage {
            STAGE_CHDIR => format!("enter {}", String::from_utf8_lossy(&self.cwd)),
            STAGE_EXEC => format!("run {}", String::from_utf8_lossy(&self.program)),
            _ => "start the terminal".to_string(),
        };
        io::Error::new(error.kind(), format!("{what}: {error}"))
    }
}

/// The child after `fork`: new session, the PTY as controlling terminal and
/// stdio, default signal dispositions, the open-file limit cmux started
/// with, its directory, then `execve` of each of `programs` in turn (the
/// `PATH` search, [`program_candidates`]). Every other descriptor of the
/// holder is close-on-exec ([`mark_inherited_close_on_exec`] at startup,
/// and each one it opens later), so the program gets only its PTY. A
/// failure writes `stage u8, errno i32` to `report` and exits 127.
unsafe fn child(
    (slave, report): (libc::c_int, libc::c_int),
    open_file_limit: Option<u64>,
    cwd: &CString,
    programs: &[*const libc::c_char],
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
            report_and_exit(report, STAGE_CHDIR, errno())
        }
        // As execvp: a name that is not there (or not reachable) moves on
        // to the next entry; a program found but not executable is
        // remembered; any other failure ends the search.
        let mut failure = libc::ENOENT;
        let mut denied = false;
        for program in programs {
            libc::execve(*program, argv.as_ptr(), env.as_ptr());
            failure = errno();
            match failure {
                libc::EACCES => denied = true,
                libc::ENOENT | libc::ENOTDIR | libc::ELOOP | libc::ENAMETOOLONG => {}
                _ => report_and_exit(report, STAGE_EXEC, failure),
            }
        }
        report_and_exit(report, STAGE_EXEC, if denied { libc::EACCES } else { failure })
    }
}

/// The calling thread's errno. Async-signal-safe.
fn errno() -> i32 {
    io::Error::last_os_error().raw_os_error().unwrap_or(libc::EIO)
}

/// Write `stage` and `errno` to the parent's report pipe, then
/// `_exit(127)`. Async-signal-safe.
unsafe fn report_and_exit(report: libc::c_int, stage: u8, errno: i32) -> ! {
    let mut bytes = [stage, 0, 0, 0, 0];
    bytes[1..].copy_from_slice(&errno.to_ne_bytes());
    // SAFETY: one write of a stack buffer, then _exit.
    unsafe {
        libc::write(report, bytes.as_ptr().cast(), bytes.len());
        libc::_exit(127)
    }
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

/// The paths the child tries to `execve` for `program`, in order, without
/// touching the file system (the child finds out): `program` itself when it
/// names a path (has a `/`), else that name in each entry of the `PATH` of
/// `env` (`/usr/bin:/bin` without one), as `execvp` searches. An empty
/// entry is the directory itself (`.`); a relative entry is relative to the
/// child's directory, where it runs.
fn program_candidates(program: &[u8], env: &[Vec<u8>]) -> io::Result<Vec<CString>> {
    let nul =
        |_: std::ffi::NulError| io::Error::new(io::ErrorKind::InvalidInput, "program has a NUL");
    if program.is_empty() {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "empty program name"));
    }
    if program.contains(&b'/') {
        return Ok(vec![CString::new(program).map_err(nul)?]);
    }
    let path = env
        .iter()
        .rev()
        .find_map(|entry| entry.strip_prefix(b"PATH="))
        .unwrap_or(&b"/usr/bin:/bin"[..]);
    path.split(|byte| *byte == b':')
        .map(|dir| {
            let mut candidate = if dir.is_empty() { b".".to_vec() } else { dir.to_vec() };
            candidate.push(b'/');
            candidate.extend_from_slice(program);
            CString::new(candidate).map_err(nul)
        })
        .collect()
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

/// Send `signal` to the process groups of a terminal: its child's
/// (`leader`) and the PTY's foreground group. A login(1) start puts the
/// shell in a group of its own under login's; an interactive shell makes
/// that group the foreground one, and on SIGHUP it hangs up its own jobs.
/// The holder never scans the process table for more (pty-holder.md 4).
/// Never the holder's own group.
pub fn signal_terminal(leader: libc::pid_t, master: libc::c_int, signal: libc::c_int) {
    let mut groups = vec![leader];
    // SAFETY: tcgetpgrp on a master this holder keeps open.
    let foreground = unsafe { libc::tcgetpgrp(master) };
    if foreground > 0 {
        groups.push(foreground);
    }
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
    fn a_bare_program_name_is_tried_in_each_path_entry_and_a_path_as_it_is() {
        let env = vec![b"HOME=/".to_vec(), b"PATH=/nonexistent-cmux-dir::bin:/usr/bin".to_vec()];
        let tried = program_candidates(b"sh", &env).unwrap();
        let tried: Vec<&[u8]> = tried.iter().map(|path| path.to_bytes()).collect();
        assert_eq!(tried, [&b"/nonexistent-cmux-dir/sh"[..], b"./sh", b"bin/sh", b"/usr/bin/sh"]);
        let default = program_candidates(b"sh", &[]).unwrap();
        let default: Vec<&[u8]> = default.iter().map(|path| path.to_bytes()).collect();
        assert_eq!(default, [&b"/usr/bin/sh"[..], b"/bin/sh"]);
        let named = program_candidates(b"/bin/sh", &env).unwrap();
        assert_eq!(named.len(), 1);
        assert_eq!(named[0].to_bytes(), b"/bin/sh");
        assert!(program_candidates(b"", &env).is_err());
    }
}
