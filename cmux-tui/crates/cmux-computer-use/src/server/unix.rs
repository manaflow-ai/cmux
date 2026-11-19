//! The agent socket on macOS and Linux: a Unix socket, mode 0600, in a
//! directory of this user's, mode 0700. A peer must be this user (its uid
//! from the kernel, never from what it says).

use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use super::Stream;

pub(super) struct Listener {
    listener: UnixListener,
    path: PathBuf,
    /// The socket file's inode, so stop removes only our own file.
    ino: u64,
    /// The one uid admitted (this process's; tests set another to see a refusal).
    pub(super) uid: u32,
}

impl Listener {
    pub(super) fn bind(endpoint: &str) -> io::Result<Self> {
        let path = PathBuf::from(endpoint);
        let dir = path.parent().filter(|d| !d.as_os_str().is_empty()).ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidInput, "the socket path has no directory")
        })?;
        private_dir(dir)?;
        match std::fs::symlink_metadata(&path) {
            Ok(meta) => {
                use std::os::unix::fs::FileTypeExt;
                if !meta.file_type().is_socket() {
                    return Err(io::Error::new(
                        io::ErrorKind::AlreadyExists,
                        format!("{} exists and is not a socket", path.display()),
                    ));
                }
                std::fs::remove_file(&path)?;
            }
            Err(e) if e.kind() == io::ErrorKind::NotFound => {}
            Err(e) => return Err(e),
        }
        let listener = UnixListener::bind(&path)?;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
        let ino = std::fs::symlink_metadata(&path)?.ino();
        Ok(Self { listener, path, ino, uid: current_uid() })
    }

    pub(super) fn accept(&self) -> io::Result<(Arc<dyn Stream>, Result<(), String>)> {
        let (stream, _) = self.listener.accept()?;
        let admitted = match peer_uid(&stream) {
            Some(uid) if uid == self.uid => Ok(()),
            Some(_) => Err("another user".to_string()),
            None => Err("unknown peer".to_string()),
        };
        Ok((Arc::new(Conn(stream)), admitted))
    }

    /// Unblocks a pending accept (the accept loop then sees the stop flag).
    pub(super) fn wake(&self) {
        let _ = UnixStream::connect(&self.path);
    }

    pub(super) fn remove(&self) {
        // Only our own socket: a newer worker may already serve the path.
        if std::fs::symlink_metadata(&self.path).is_ok_and(|now| now.ino() == self.ino) {
            let _ = std::fs::remove_file(&self.path);
        }
    }
}

/// Creates `dir` (0700) or checks an existing one is this user's and not a symlink.
pub fn private_dir(dir: &Path) -> io::Result<()> {
    std::fs::create_dir_all(dir)?;
    let meta = std::fs::symlink_metadata(dir)?;
    if !meta.is_dir() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("{} is not a directory", dir.display()),
        ));
    }
    if meta.uid() != current_uid() {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!("{} belongs to another user", dir.display()),
        ));
    }
    if meta.mode() & 0o777 != 0o700 {
        std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}

fn current_uid() -> u32 {
    // SAFETY: no arguments, cannot fail.
    unsafe { libc::geteuid() }
}

#[cfg(any(target_os = "linux", target_os = "android"))]
fn peer_uid(stream: &UnixStream) -> Option<u32> {
    let mut cred = libc::ucred { pid: 0, uid: 0, gid: 0 };
    let mut len = size_of::<libc::ucred>() as libc::socklen_t;
    // SAFETY: getsockopt into a correctly sized ucred.
    let ok = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            (&raw mut cred).cast(),
            &mut len,
        )
    } == 0;
    ok.then_some(cred.uid)
}

#[cfg(not(any(target_os = "linux", target_os = "android")))]
fn peer_uid(stream: &UnixStream) -> Option<u32> {
    let mut uid: libc::uid_t = 0;
    let mut gid: libc::gid_t = 0;
    // SAFETY: getpeereid into two out values.
    let ok = unsafe { libc::getpeereid(stream.as_raw_fd(), &mut uid, &mut gid) } == 0;
    ok.then_some(uid)
}

struct Conn(UnixStream);

impl Stream for Conn {
    fn read(&self, buf: &mut [u8]) -> io::Result<usize> {
        (&self.0).read(buf)
    }
    fn write_all(&self, buf: &[u8]) -> io::Result<()> {
        (&self.0).write_all(buf)
    }
    fn set_read_timeout(&self, limit: Option<Duration>) {
        let _ = self.0.set_read_timeout(limit);
    }
    fn shutdown(&self) {
        let _ = self.0.shutdown(std::net::Shutdown::Both);
    }
}
