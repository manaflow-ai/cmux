//! `cmux-rd host --listen-systemd`: the production Cloud admission (Linux).
//!
//! systemd owns the listening socket (`cmux-agent-rd.socket`: `/run/cmux-rd/desktop.sock`,
//! root-only, 0600) and passes it as fd 3 (`LISTEN_FDS=1`, `LISTEN_PID` = this process).
//! The only process that may connect is the machine's root link receiver, after it verified
//! the owner's one-time link token for service `desktop`; the host checks each accepted
//! connection's `SO_PEERCRED` uid against `--peer-uid` and closes any other peer before it
//! reads a byte. There is no TCP or UDP listener in this mode.

use std::io;
use std::os::fd::{AsRawFd, FromRawFd, RawFd};
use std::os::unix::net::{UnixListener, UnixStream};

/// The first fd systemd passes (`SD_LISTEN_FDS_START`).
pub const LISTEN_FDS_START: RawFd = 3;

/// The listening fd that systemd passed, from the values of `LISTEN_PID` and `LISTEN_FDS`.
/// Exactly one fd, passed to this process; anything else is refused.
pub fn listen_fd_from_env(
    listen_pid: Option<&str>,
    listen_fds: Option<&str>,
    my_pid: u32,
) -> Result<RawFd, String> {
    let fds = listen_fds.ok_or(
        "--listen-systemd: LISTEN_FDS is not set; run the host from its systemd socket unit \
         (cmux-agent-rd.socket)",
    )?;
    let pid = listen_pid.ok_or("--listen-systemd: LISTEN_PID is not set")?;
    let pid: u32 = pid.parse().map_err(|_| format!("--listen-systemd: LISTEN_PID {pid:?} is not a pid"))?;
    if pid != my_pid {
        return Err(format!("--listen-systemd: LISTEN_PID {pid} is not this process ({my_pid})"));
    }
    match fds.parse::<u32>() {
        Ok(1) => Ok(LISTEN_FDS_START),
        _ => Err(format!("--listen-systemd: LISTEN_FDS={fds:?}; exactly one socket is required")),
    }
}

fn sockopt_int(fd: RawFd, name: libc::c_int) -> io::Result<libc::c_int> {
    let mut value: libc::c_int = 0;
    let mut len = std::mem::size_of::<libc::c_int>() as libc::socklen_t;
    // SAFETY: getsockopt with a valid out pointer and its length.
    let rc = unsafe {
        libc::getsockopt(fd, libc::SOL_SOCKET, name, (&mut value as *mut libc::c_int).cast(), &mut len)
    };
    if rc != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(value)
}

/// Takes the passed fd as a listener after checking it is a listening Unix stream socket,
/// marks it close-on-exec (the browser child must not inherit it) and clears the
/// `LISTEN_*` variables.
pub fn take_listener(fd: RawFd) -> Result<UnixListener, String> {
    let bad = |what: String| format!("--listen-systemd: fd {fd} {what}");
    if sockopt_int(fd, libc::SO_DOMAIN).map_err(|e| bad(format!("is not a socket: {e}")))? != libc::AF_UNIX {
        return Err(bad("is not a Unix socket (ListenStream= must be a path)".into()));
    }
    if sockopt_int(fd, libc::SO_TYPE).map_err(|e| bad(e.to_string()))? != libc::SOCK_STREAM {
        return Err(bad("is not a stream socket".into()));
    }
    if sockopt_int(fd, libc::SO_ACCEPTCONN).map_err(|e| bad(e.to_string()))? != 1 {
        return Err(bad("is not listening (Accept= must be no)".into()));
    }
    // SAFETY: fcntl on a valid fd.
    if unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) } != 0 {
        return Err(bad(format!("close-on-exec: {}", io::Error::last_os_error())));
    }
    for var in ["LISTEN_PID", "LISTEN_FDS", "LISTEN_FDNAMES"] {
        std::env::remove_var(var);
    }
    // SAFETY: systemd passed this fd to this process and nothing else owns it.
    Ok(unsafe { UnixListener::from_raw_fd(fd) })
}

/// The listener systemd passed to this process.
pub fn listener_from_env() -> Result<UnixListener, String> {
    let pid = std::env::var("LISTEN_PID").ok();
    let fds = std::env::var("LISTEN_FDS").ok();
    let fd = listen_fd_from_env(pid.as_deref(), fds.as_deref(), std::process::id())?;
    take_listener(fd)
}

/// The connecting process's uid (`SO_PEERCRED`).
pub fn peer_uid(stream: &UnixStream) -> io::Result<u32> {
    let mut cred = libc::ucred { pid: 0, uid: 0, gid: 0 };
    let mut len = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
    // SAFETY: getsockopt with a valid out pointer and its length.
    let rc = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            (&mut cred as *mut libc::ucred).cast(),
            &mut len,
        )
    };
    if rc != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(cred.uid)
}

/// Admits an accepted connection only when its peer uid is `expected`; any other peer (or
/// one whose credentials cannot be read) is shut down and dropped before a byte is read.
pub fn admit_peer(stream: UnixStream, expected: u32) -> Result<UnixStream, String> {
    match peer_uid(&stream) {
        Ok(uid) if uid == expected => Ok(stream),
        Ok(uid) => {
            let _ = stream.shutdown(std::net::Shutdown::Both);
            Err(format!("refused peer uid {uid}: only uid {expected} (the link receiver) may connect"))
        }
        Err(e) => {
            let _ = stream.shutdown(std::net::Shutdown::Both);
            Err(format!("refused peer: SO_PEERCRED failed: {e}"))
        }
    }
}

/// Waits up to `idle_ms` for a connection; `Ok(None)` when none came (the host then exits
/// and the socket unit starts it again on the next connection).
pub fn accept_within(listener: &UnixListener, idle_ms: u64) -> io::Result<Option<UnixStream>> {
    let deadline = std::time::Instant::now() + std::time::Duration::from_millis(idle_ms);
    loop {
        let left = deadline.saturating_duration_since(std::time::Instant::now());
        if left.is_zero() {
            return Ok(None);
        }
        crate::fdwait::wait_readable(&[listener.as_raw_fd()], Some(left.as_nanos() as u64))?;
        listener.set_nonblocking(true)?;
        let accepted = listener.accept();
        listener.set_nonblocking(false)?;
        match accepted {
            Ok((stream, _)) => {
                stream.set_nonblocking(false)?;
                return Ok(Some(stream));
            }
            Err(e) if matches!(e.kind(), io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted) => {}
            Err(e) => return Err(e),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};

    #[test]
    fn missing_listen_fds_refuses() {
        let err = listen_fd_from_env(None, None, 42).expect_err("refused");
        assert!(err.contains("LISTEN_FDS is not set"), "{err}");
        assert!(listen_fd_from_env(Some("42"), None, 42).is_err());
        assert!(listen_fd_from_env(None, Some("1"), 42).is_err());
    }

    #[test]
    fn listen_fds_for_another_process_or_count_refuses() {
        assert!(listen_fd_from_env(Some("41"), Some("1"), 42).expect_err("pid").contains("not this process"));
        assert!(listen_fd_from_env(Some("x"), Some("1"), 42).is_err());
        for n in ["0", "2", "", "one"] {
            assert!(listen_fd_from_env(Some("42"), Some(n), 42).is_err(), "{n}");
        }
        assert_eq!(listen_fd_from_env(Some("42"), Some("1"), 42), Ok(LISTEN_FDS_START));
    }

    #[test]
    fn a_passed_fd_that_is_not_a_listening_unix_socket_refuses() {
        let tcp = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
        assert!(take_listener(tcp.as_raw_fd()).expect_err("tcp").contains("not a Unix socket"));
        let (a, _b) = UnixStream::pair().expect("pair");
        assert!(take_listener(a.as_raw_fd()).expect_err("not listening").contains("not listening"));
        let file = std::fs::File::open("/dev/null").expect("open");
        assert!(take_listener(file.as_raw_fd()).expect_err("file").contains("not a socket"));
    }

    #[test]
    fn a_listening_unix_socket_is_taken() {
        let (dir, l) = listener();
        let fd = std::os::fd::IntoRawFd::into_raw_fd(l);
        let taken = take_listener(fd).expect("taken");
        let _client = UnixStream::connect(dir.path().join("desktop.sock")).expect("connect");
        assert!(accept_within(&taken, 2000).expect("accept").is_some());
        // SAFETY: fcntl on the fd we own.
        let flags = unsafe { libc::fcntl(taken.as_raw_fd(), libc::F_GETFD) };
        assert_ne!(flags & libc::FD_CLOEXEC, 0);
    }

    fn me() -> u32 {
        // SAFETY: getuid has no preconditions.
        unsafe { libc::getuid() }
    }

    fn listener() -> (tempdir::Dir, UnixListener) {
        let dir = tempdir::Dir::new();
        let l = UnixListener::bind(dir.path().join("desktop.sock")).expect("bind");
        (dir, l)
    }

    #[test]
    fn peer_uid_mismatch_closes_before_reading() {
        let (dir, l) = listener();
        let mut client = UnixStream::connect(dir.path().join("desktop.sock")).expect("connect");
        client.write_all(b"\x01\x05\x00\x00\x00hello").expect("write");
        let (server, _) = l.accept().expect("accept");
        let err = admit_peer(server, me().wrapping_add(1)).expect_err("mismatch");
        assert!(err.contains(&format!("refused peer uid {}", me())), "{err}");
        // Closed with nothing sent back.
        client.set_read_timeout(Some(std::time::Duration::from_secs(2))).expect("timeout");
        let mut buf = [0u8; 16];
        assert_eq!(client.read(&mut buf).unwrap_or(0), 0);
    }

    #[test]
    fn the_expected_peer_uid_is_admitted() {
        let (dir, l) = listener();
        let _client = UnixStream::connect(dir.path().join("desktop.sock")).expect("connect");
        let (server, _) = l.accept().expect("accept");
        assert_eq!(peer_uid(&server).expect("cred"), me());
        assert!(admit_peer(server, me()).is_ok());
    }

    #[test]
    fn accept_within_times_out_when_idle_and_returns_a_connection() {
        let (dir, l) = listener();
        let t = std::time::Instant::now();
        assert!(accept_within(&l, 150).expect("wait").is_none());
        assert!(t.elapsed() >= std::time::Duration::from_millis(150));
        let _client = UnixStream::connect(dir.path().join("desktop.sock")).expect("connect");
        assert!(accept_within(&l, 2000).expect("wait").is_some());
    }

    /// A private temporary directory removed on drop (no extra dependency).
    mod tempdir {
        pub struct Dir(std::path::PathBuf);
        impl Dir {
            pub fn new() -> Self {
                static N: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
                let n = N.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                let p = std::env::temp_dir().join(format!("cmux-rd-systemd-{}-{n}", std::process::id()));
                let _ = std::fs::remove_dir_all(&p);
                std::fs::create_dir(&p).expect("mkdir");
                Self(p)
            }
            pub fn path(&self) -> &std::path::Path {
                &self.0
            }
        }
        impl Drop for Dir {
            fn drop(&mut self) {
                let _ = std::fs::remove_dir_all(&self.0);
            }
        }
    }
}
