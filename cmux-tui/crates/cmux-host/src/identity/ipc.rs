use std::fs;
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, RawFd};
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;
use std::time::{Duration, Instant};

use super::{HostIdentity, SOCKET};

const MAX_REPLY: usize = 2048;
const MAX_CLIENTS: usize = 8;
const TIMEOUT: Duration = Duration::from_secs(5);

/// No path or environment override: authority comes from the system host only.
pub fn query() -> io::Result<HostIdentity> {
    query_at(Path::new(SOCKET), 0)
}

fn query_at(path: &Path, expected_uid: u32) -> io::Result<HostIdentity> {
    let mut stream = connect(path)?;
    if peer_uid(&stream)? != expected_uid {
        return Err(io::Error::new(io::ErrorKind::PermissionDenied, "identity peer is not root"));
    }
    read_reply(&mut stream, TIMEOUT)
}

/// Nonblocking connect: a full listen backlog fails rather than hanging a turn.
fn connect(path: &Path) -> io::Result<UnixStream> {
    use std::os::unix::ffi::OsStrExt;
    let bytes = path.as_os_str().as_bytes();
    // SAFETY: zero is a valid initialized sockaddr_un; fields filled below.
    let mut addr: libc::sockaddr_un = unsafe { std::mem::zeroed() };
    if bytes.contains(&0) || bytes.len() >= addr.sun_path.len() {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "invalid identity socket path"));
    }
    addr.sun_family = libc::sa_family_t::try_from(libc::AF_UNIX)
        .map_err(|_| io::Error::other("invalid Unix socket family"))?;
    for (dst, src) in addr.sun_path.iter_mut().zip(bytes) {
        *dst = libc::c_char::from_ne_bytes([*src]);
    }
    // SAFETY: socket takes scalar arguments and returns an owned fd.
    let fd = unsafe {
        libc::socket(libc::AF_UNIX, libc::SOCK_STREAM | libc::SOCK_CLOEXEC | libc::SOCK_NONBLOCK, 0)
    };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: fd was created above and has exactly one owner.
    let stream = unsafe { UnixStream::from_raw_fd(fd) };
    let addr_len = libc::socklen_t::try_from(size_of_val(&addr))
        .map_err(|_| io::Error::other("invalid socket address size"))?;
    // SAFETY: addr is initialized and its complete size is passed.
    let rc = unsafe { libc::connect(fd, (&addr as *const libc::sockaddr_un).cast(), addr_len) };
    if rc != 0 {
        return Err(io::Error::last_os_error());
    }
    stream.set_nonblocking(false)?;
    Ok(stream)
}

fn peer_uid(stream: &UnixStream) -> io::Result<u32> {
    // SAFETY: zero initializes ucred; getsockopt writes within the supplied size.
    let mut cred: libc::ucred = unsafe { std::mem::zeroed() };
    let mut len = libc::socklen_t::try_from(size_of_val(&cred))
        .map_err(|_| io::Error::other("invalid peer credential size"))?;
    // SAFETY: valid fd and writable ucred/length pointers.
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
    if usize::try_from(len).ok() != Some(size_of_val(&cred)) {
        return Err(io::Error::other("invalid peer credentials"));
    }
    Ok(cred.uid)
}

fn read_reply(stream: &mut UnixStream, timeout: Duration) -> io::Result<HostIdentity> {
    let deadline = Instant::now()
        .checked_add(timeout)
        .ok_or_else(|| io::Error::other("invalid identity timeout"))?;
    let mut buf = Vec::new();
    loop {
        let left = deadline
            .checked_duration_since(Instant::now())
            .filter(|d| !d.is_zero())
            .ok_or_else(|| io::Error::new(io::ErrorKind::TimedOut, "identity query timed out"))?;
        stream.set_read_timeout(Some(left))?;
        let mut bytes = [0u8; 512];
        let n = stream.read(&mut bytes)?;
        if n == 0 {
            return Err(io::Error::other("identity unavailable"));
        }
        buf.extend(bytes.iter().take(n).copied());
        if buf.len() > MAX_REPLY {
            return Err(io::Error::other("identity reply too large"));
        }
        if buf.last() == Some(&b'\n') {
            return serde_json::from_slice(&buf)
                .map_err(|_| io::Error::other("identity unavailable"));
        }
    }
}

pub(crate) struct Listener {
    listener: UnixListener,
    pending: Vec<UnixStream>,
}

impl Listener {
    pub fn bind(path: &Path, gid: Option<u32>) -> io::Result<Self> {
        let parent =
            path.parent().ok_or_else(|| io::Error::other("no identity socket directory"))?;
        fs::create_dir_all(parent)?;
        let meta = fs::symlink_metadata(parent)?;
        // Never let a work-user directory nominate the identity service.
        // Test roots have the test process's uid; production caller is root.
        // SAFETY: geteuid has no preconditions.
        if !meta.is_dir() || meta.uid() != unsafe { libc::geteuid() } || meta.mode() & 0o022 != 0 {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "unsafe identity socket directory",
            ));
        }
        match fs::remove_file(path) {
            Ok(()) => {}
            Err(e) if e.kind() == io::ErrorKind::NotFound => {}
            Err(e) => return Err(e),
        }
        let listener = UnixListener::bind(path)?;
        if let Some(gid) = gid {
            std::os::unix::fs::chown(path, Some(0), Some(gid))?;
        }
        fs::set_permissions(path, fs::Permissions::from_mode(0o660))?;
        listener.set_nonblocking(true)?;
        Ok(Self { listener, pending: Vec::new() })
    }

    pub fn raw(&self) -> RawFd {
        self.listener.as_raw_fd()
    }

    pub fn has_pending(&self) -> bool {
        !self.pending.is_empty()
    }

    /// Accept BEFORE metadata observation: no client gets a prior observation.
    pub fn accept(&mut self) {
        for _ in 0..MAX_CLIENTS {
            let Ok((stream, _)) = self.listener.accept() else { break };
            if stream.set_nonblocking(true).is_ok() {
                self.pending.push(stream);
            }
        }
    }

    pub fn reply(&mut self, identity: Option<&HostIdentity>) {
        let text = identity
            .and_then(|id| serde_json::to_string(id).ok())
            .unwrap_or_else(|| "{\"error\":\"identity_unavailable\"}".to_owned());
        let text = format!("{text}\n");
        for mut stream in self.pending.drain(..) {
            // Nonblocking, bounded message; a slow reader gets EOF, never holds the host.
            let _ = stream.write_all(text.as_bytes());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identity_socket_round_trip_and_fail_closed_reply() {
        let dir = tempfile::tempdir().unwrap();
        fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o700)).unwrap();
        let socket = dir.path().join("identity.sock");
        let mut listener = Listener::bind(&socket, None).unwrap();
        let id = HostIdentity {
            machine: "m".into(),
            instance_id: "i".into(),
            guest_key: "sha256:abc".into(),
        };
        let mut client = connect(&socket).unwrap();
        // SAFETY: geteuid has no preconditions.
        assert_eq!(peer_uid(&client).unwrap(), unsafe { libc::geteuid() });
        listener.accept();
        listener.reply(Some(&id));
        assert_eq!(read_reply(&mut client, TIMEOUT).unwrap(), id);
        let mut client = connect(&socket).unwrap();
        listener.accept();
        listener.reply(None);
        assert!(read_reply(&mut client, TIMEOUT).is_err());
    }

    #[test]
    fn identity_socket_refuses_oversized_and_dripping_replies() {
        let (mut client, mut server) = UnixStream::pair().unwrap();
        server.write_all(&vec![b'x'; MAX_REPLY + 1]).unwrap();
        assert!(read_reply(&mut client, TIMEOUT).is_err());
        let (mut client, mut server) = UnixStream::pair().unwrap();
        let sender = std::thread::spawn(move || {
            for _ in 0..100 {
                if server.write_all(b"x").is_err() {
                    break;
                }
                std::thread::sleep(Duration::from_millis(20));
            }
        });
        let start = Instant::now();
        assert!(read_reply(&mut client, Duration::from_millis(80)).is_err());
        assert!(start.elapsed() < Duration::from_secs(1));
        drop(client);
        sender.join().unwrap();
    }

    #[test]
    fn identity_socket_rejects_an_untrusted_peer_before_reading() {
        let dir = tempfile::tempdir().unwrap();
        fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o700)).unwrap();
        let socket = dir.path().join("identity.sock");
        let _listener = Listener::bind(&socket, None).unwrap();
        // SAFETY: geteuid has no preconditions. Use a different required uid.
        let other_uid = unsafe { libc::geteuid() }.wrapping_add(1);
        assert_eq!(
            query_at(&socket, other_uid).unwrap_err().kind(),
            io::ErrorKind::PermissionDenied
        );
    }
}
