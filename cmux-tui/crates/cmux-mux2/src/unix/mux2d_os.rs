//! Descriptors, PTY spawning and the listening socket.

use super::*;

pub(super) fn cvt(r: libc::c_int) -> io::Result<libc::c_int> {
    if r < 0 { Err(io::Error::last_os_error()) } else { Ok(r) }
}

pub(super) fn set_nonblock_cloexec(fd: RawFd) -> io::Result<()> {
    // SAFETY: fcntl on a descriptor this process owns.
    unsafe {
        let fl = cvt(libc::fcntl(fd, libc::F_GETFL))?;
        cvt(libc::fcntl(fd, libc::F_SETFL, fl | libc::O_NONBLOCK))?;
        cvt(libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC))?;
    }
    Ok(())
}

/// Writes all of `data` to a socket, waiting for room. Only used right
/// before exec, when nothing else needs the loop.
pub(super) fn write_all_blocking(fd: RawFd, mut data: &[u8], deadline: std::time::Instant) {
    while !data.is_empty() && std::time::Instant::now() < deadline {
        // SAFETY: data is a valid slice.
        let n = unsafe { libc::write(fd, data.as_ptr().cast(), data.len()) };
        if n > 0 {
            data = &data[n as usize..];
        } else if n < 0 && io::Error::last_os_error().kind() == io::ErrorKind::WouldBlock {
            let mut pfd = libc::pollfd { fd, events: libc::POLLOUT, revents: 0 };
            // SAFETY: one valid pollfd.
            unsafe { libc::poll(&mut pfd, 1, 100) };
        } else {
            return;
        }
    }
}

pub(super) fn set_winsize(fd: RawFd, cols: u16, rows: u16) {
    let ws = libc::winsize { ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0 };
    // SAFETY: TIOCSWINSZ with a valid winsize.
    unsafe { libc::ioctl(fd, libc::TIOCSWINSZ, &ws) };
}

// From <spawn.h> (macOS 10.15+, glibc 2.26+); not bound by the pinned libc.
#[cfg(target_os = "macos")]
const POSIX_SPAWN_SETSID: libc::c_short = 0x0400;
#[cfg(target_os = "linux")]
const POSIX_SPAWN_SETSID: libc::c_short = 0x80;
/// macOS starts the child with only the descriptors file actions name. Linux
/// has no such flag; every descriptor the server opens is close-on-exec.
#[cfg(target_os = "macos")]
const SPAWN_CLOEXEC_DEFAULT: libc::c_short = libc::POSIX_SPAWN_CLOEXEC_DEFAULT as libc::c_short;
#[cfg(target_os = "linux")]
const SPAWN_CLOEXEC_DEFAULT: libc::c_short = 0;
unsafe extern "C" {
    fn posix_spawn_file_actions_addchdir_np(
        actions: *mut libc::posix_spawn_file_actions_t,
        path: *const libc::c_char,
    ) -> libc::c_int;
}

/// Opens a PTY and starts `argv` on it as a session leader with the PTY as
/// its controlling terminal.
///
/// posix_spawn, not fork: its cost does not grow with the server's memory.
/// POSIX_SPAWN_SETSID makes the child a session leader, and on macOS a
/// session leader without a controlling terminal acquires the tty it opens
/// first, so opening the slave by path as fd 0 sets the controlling terminal
/// (checked by `mux2-ctty-probe`: tty, foreground process group and job
/// control all hold). The child starts with default signal dispositions, an
/// empty signal mask, and only fds 0-2 (POSIX_SPAWN_CLOEXEC_DEFAULT).
pub(super) fn spawn_pty(
    argv: &[CString],
    cwd: Option<&std::ffi::CStr>,
    cols: u16,
    rows: u16,
) -> io::Result<(RawFd, libc::pid_t)> {
    // SAFETY: standard PTY allocation on a fresh master descriptor.
    let master = cvt(unsafe { libc::posix_openpt(libc::O_RDWR | libc::O_NOCTTY) })?;
    let close_master = |e: io::Error| {
        // SAFETY: closing the master we own.
        unsafe { libc::close(master) };
        e
    };
    let mut name = [0 as libc::c_char; 128];
    // SAFETY: grantpt/unlockpt on our master; the slave name fills at most
    // 128 bytes (TIOCPTYGNAME on macOS, ptsname_r on Linux).
    unsafe {
        cvt(libc::grantpt(master)).map_err(close_master)?;
        cvt(libc::unlockpt(master)).map_err(close_master)?;
        #[cfg(target_os = "macos")]
        cvt(libc::ioctl(master, libc::TIOCPTYGNAME as _, name.as_mut_ptr()))
            .map_err(close_master)?;
        #[cfg(target_os = "linux")]
        {
            let rc = libc::ptsname_r(master, name.as_mut_ptr(), name.len());
            if rc != 0 {
                return Err(close_master(io::Error::from_raw_os_error(rc)));
            }
        }
    }
    set_nonblock_cloexec(master).map_err(close_master)?;
    set_winsize(master, cols, rows);
    let mut ptrs: Vec<*mut libc::c_char> = argv.iter().map(|a| a.as_ptr().cast_mut()).collect();
    ptrs.push(std::ptr::null_mut());
    let mut pid: libc::pid_t = 0;
    // SAFETY: attribute and file-action objects are initialized before use
    // and destroyed after; every pointer passed outlives the call.
    let rc = unsafe {
        // A pointer on macOS, a struct on Linux: zeroed is a valid start
        // for both before the init calls.
        let mut attr: libc::posix_spawnattr_t = std::mem::zeroed();
        let mut fa: libc::posix_spawn_file_actions_t = std::mem::zeroed();
        let mut rc = libc::posix_spawnattr_init(&mut attr);
        if rc != 0 {
            return Err(close_master(io::Error::from_raw_os_error(rc)));
        }
        rc = libc::posix_spawn_file_actions_init(&mut fa);
        if rc != 0 {
            libc::posix_spawnattr_destroy(&mut attr);
            return Err(close_master(io::Error::from_raw_os_error(rc)));
        }
        let mut all: libc::sigset_t = std::mem::zeroed();
        libc::sigfillset(&mut all);
        let mut none: libc::sigset_t = std::mem::zeroed();
        libc::sigemptyset(&mut none);
        let flags = POSIX_SPAWN_SETSID
            | libc::POSIX_SPAWN_SETSIGDEF as libc::c_short
            | libc::POSIX_SPAWN_SETSIGMASK as libc::c_short
            | SPAWN_CLOEXEC_DEFAULT;
        // The first failing setup call wins; nothing spawns half-configured.
        for step in [
            libc::posix_spawnattr_setsigdefault(&mut attr, &all),
            libc::posix_spawnattr_setsigmask(&mut attr, &none),
            libc::posix_spawnattr_setflags(&mut attr, flags),
            libc::posix_spawn_file_actions_addopen(&mut fa, 0, name.as_ptr(), libc::O_RDWR, 0),
            libc::posix_spawn_file_actions_adddup2(&mut fa, 0, 1),
            libc::posix_spawn_file_actions_adddup2(&mut fa, 0, 2),
            cwd.map_or(0, |dir| posix_spawn_file_actions_addchdir_np(&mut fa, dir.as_ptr())),
        ] {
            if rc == 0 {
                rc = step;
            }
        }
        if rc == 0 {
            rc = libc::posix_spawnp(&mut pid, ptrs[0], &fa, &attr, ptrs.as_ptr(), environ_ptr());
        }
        libc::posix_spawn_file_actions_destroy(&mut fa);
        libc::posix_spawnattr_destroy(&mut attr);
        rc
    };
    if rc != 0 {
        return Err(close_master(io::Error::from_raw_os_error(rc)));
    }
    Ok((master, pid))
}

/// The current environment, for posix_spawn.
#[cfg(target_os = "macos")]
pub(super) fn environ_ptr() -> *const *mut libc::c_char {
    unsafe extern "C" {
        fn _NSGetEnviron() -> *mut *const *mut libc::c_char;
    }
    // SAFETY: _NSGetEnviron returns the process environment pointer.
    unsafe { *_NSGetEnviron() }
}

/// The current environment, for posix_spawn.
#[cfg(target_os = "linux")]
pub(super) fn environ_ptr() -> *const *mut libc::c_char {
    unsafe extern "C" {
        static environ: *const *mut libc::c_char;
    }
    // SAFETY: reading the libc environment pointer; the server only changes
    // the environment before it starts threads.
    unsafe { environ }
}

/// Device and inode of the socket file, to tell our socket from a newer
/// server's at the same path.
pub(super) type SocketId = (u64, u64);

pub(super) fn socket_id(path: &std::path::Path) -> Option<SocketId> {
    use std::os::unix::fs::MetadataExt;
    std::fs::symlink_metadata(path).ok().map(|m| (m.dev(), m.ino()))
}

/// Runs `f` holding an exclusive flock on `<socket>.lock`. Start-up and
/// removal of the socket happen under it, so two servers started at once
/// never both unlink and bind the path (the loser's terminals would be
/// unreachable). The lock is released when the descriptor closes.
fn with_socket_lock<T>(path: &std::path::Path, f: impl FnOnce() -> T) -> io::Result<T> {
    let mut lock = path.as_os_str().to_owned();
    lock.push(".lock");
    let lock = std::fs::OpenOptions::new().read(true).write(true).create(true).open(lock)?;
    use std::os::fd::AsRawFd;
    // SAFETY: flock on a descriptor we own; blocks only while another
    // server is between its liveness check and listen(), or removing.
    loop {
        if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX) } == 0 {
            break;
        }
        let e = io::Error::last_os_error();
        if e.kind() != io::ErrorKind::Interrupted {
            return Err(e);
        }
    }
    Ok(f())
}

/// Listens on `path`. Returns `None` when a live server already accepts
/// connections there: the caller exits and its client connects to that one.
pub(super) fn listen_socket(path: &std::path::Path) -> io::Result<Option<RawFd>> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
        let cdir = CString::new(dir.as_os_str().as_bytes()).map_err(io::Error::other)?;
        // SAFETY: chmod on a directory we own.
        unsafe { libc::chmod(cdir.as_ptr(), 0o700) };
    }
    with_socket_lock(path, || {
        if std::os::unix::net::UnixStream::connect(path).is_ok() {
            return Ok(None);
        }
        let _ = std::fs::remove_file(path);
        bind_listen(path).map(Some)
    })?
}

/// Removes the socket at exit, unless a newer server owns the path now.
pub(super) fn remove_socket_if_ours(path: &std::path::Path, ours: Option<SocketId>) {
    let _ = with_socket_lock(path, || {
        if ours.is_some() && socket_id(path) == ours {
            let _ = std::fs::remove_file(path);
        }
    });
}

fn bind_listen(path: &std::path::Path) -> io::Result<RawFd> {
    // SAFETY: plain socket/bind/listen with a correctly built sockaddr_un.
    unsafe {
        let fd = cvt(libc::socket(libc::AF_UNIX, libc::SOCK_STREAM, 0))?;
        let fail = |e: io::Error| {
            libc::close(fd);
            e
        };
        let mut addr: libc::sockaddr_un = std::mem::zeroed();
        addr.sun_family = libc::AF_UNIX as _;
        let bytes = path.as_os_str().as_bytes();
        if bytes.len() >= addr.sun_path.len() {
            return Err(fail(io::Error::new(io::ErrorKind::InvalidInput, "socket path too long")));
        }
        for (dst, src) in addr.sun_path.iter_mut().zip(bytes) {
            *dst = *src as libc::c_char;
        }
        cvt(libc::bind(fd, (&raw const addr).cast(), size_of::<libc::sockaddr_un>() as u32))
            .map_err(fail)?;
        cvt(libc::listen(fd, 1024)).map_err(fail)?;
        set_nonblock_cloexec(fd).map_err(fail)?;
        Ok(fd)
    }
}

pub(super) fn raise_nofile() {
    // SAFETY: get/setrlimit with a valid struct.
    unsafe {
        let mut lim: libc::rlimit = std::mem::zeroed();
        if libc::getrlimit(libc::RLIMIT_NOFILE, &mut lim) == 0 {
            #[cfg(target_os = "linux")]
            let max: libc::c_int = 0; // the hard limit is the bound
            #[cfg(target_os = "macos")]
            let mut max: libc::c_int = 0;
            #[cfg(target_os = "macos")]
            {
                let mut len = size_of::<libc::c_int>();
                let name = c"kern.maxfilesperproc";
                libc::sysctlbyname(
                    name.as_ptr(),
                    (&raw mut max).cast(),
                    &mut len,
                    std::ptr::null_mut(),
                    0,
                );
            }
            let want = if max > 0 { (max as libc::rlim_t).min(lim.rlim_max) } else { lim.rlim_max };
            lim.rlim_cur = want;
            libc::setrlimit(libc::RLIMIT_NOFILE, &lim);
        }
    }
}

/// The command for a terminal started without one: `login -fp USER`, as
/// Terminal.app and Rex do. login(1) records the session (utmpx), runs the
/// account's shell from the user database as a login shell, and `-p` keeps
/// the server's environment. Falls back to `$SHELL -l` when login is missing
/// or the account has no name.
pub(super) fn default_login_argv() -> Result<Vec<CString>, std::ffi::NulError> {
    const LOGIN: &str = "/usr/bin/login";
    // SAFETY: getpwuid returns a pointer into static storage or null; the
    // name is copied before any other passwd call.
    let user = unsafe {
        let pw = libc::getpwuid(libc::getuid());
        if pw.is_null() || (*pw).pw_name.is_null() {
            None
        } else {
            Some(std::ffi::CStr::from_ptr((*pw).pw_name).to_owned())
        }
    };
    // Linux login(1) is not setuid: -f works only for root there.
    // SAFETY: geteuid has no preconditions.
    let can_login = cfg!(target_os = "macos") || unsafe { libc::geteuid() } == 0;
    if let Some(user) = user.filter(|_| can_login && std::path::Path::new(LOGIN).exists()) {
        return Ok(vec![CString::new(LOGIN)?, CString::new("-fp")?, user]);
    }
    let shell = std::env::var_os("SHELL").unwrap_or_else(|| "/bin/zsh".into());
    Ok(vec![CString::new(shell.as_bytes())?, CString::new("-l")?])
}
