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
    assert!(listen_fd_from_env(Some("41"), Some("1"), 42)
        .expect_err("pid")
        .contains("not this process"));
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
    // Closed: end of file, or a reset because the host never read what was sent. A read
    // timeout (the connection still open) fails.
    match client.read(&mut buf) {
        Ok(n) => assert_eq!(n, 0, "nothing is sent back"),
        Err(e) => {
            assert_eq!(e.kind(), std::io::ErrorKind::ConnectionReset, "closed, not timed out: {e}")
        }
    }
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
            let p =
                std::env::temp_dir().join(format!("cmux-rd-systemd-{}-{n}", std::process::id()));
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
