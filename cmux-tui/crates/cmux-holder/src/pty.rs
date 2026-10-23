//! Open a PTY and start a child on it as its session leader.

use std::ffi::CString;
use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};

use crate::SpawnRequest;

/// A child running on a new PTY.
pub struct Spawned {
    pub master: OwnedFd,
    pub pid: libc::pid_t,
}

/// Open a PTY sized `cols` x `rows` and start `request.argv` on it with
/// exactly `request.env` and `request.cwd`, as the leader of a new session
/// whose controlling terminal is the PTY. The holder is single threaded, so
/// `fork` is safe here; the child only calls async-signal-safe functions
/// before `execve`.
pub fn spawn(request: &SpawnRequest) -> io::Result<Spawned> {
    let argv = c_strings(&request.argv)?;
    if argv.is_empty() {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "empty argv"));
    }
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

    // SAFETY: single-threaded process; the child path below calls only
    // async-signal-safe functions and ends in execve or _exit.
    let pid = unsafe { libc::fork() };
    if pid < 0 {
        return Err(io::Error::last_os_error());
    }
    if pid == 0 {
        // SAFETY: child side of fork, see above.
        unsafe { child(slave.as_raw_fd(), &cwd, &argv_ptrs, &env_ptrs) }
    }
    drop(slave);
    set_nonblocking(master.as_raw_fd());
    Ok(Spawned { master, pid })
}

/// The child after `fork`: new session, the PTY as controlling terminal and
/// stdio, default signal dispositions, then `execve`.
unsafe fn child(
    slave: libc::c_int,
    cwd: &CString,
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
        libc::chdir(cwd.as_ptr());
        libc::execve(argv[0], argv.as_ptr(), env.as_ptr());
        libc::_exit(127)
    }
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
