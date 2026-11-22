//! Who may connect to the link's local socket and to the daemon's remote
//! entry: a process of the same user and, on macOS, code signed as cmux.
//!
//! On macOS "signed as cmux" means: when this process has a Team ID, the
//! caller satisfies `anchor apple generic and certificate leaf[subject.OU] =
//! "<that Team ID>"`; when this process has no Team ID (a development build,
//! ad-hoc signed by the linker), the caller must be the same code (equal
//! cdhash). The caller is named by its audit token, never by pid, so a reused
//! pid cannot pass. Linux and other Unix systems have no code signature: the
//! same-user check is the whole boundary there.

#[cfg(target_os = "macos")]
#[path = "caller_macos.rs"]
pub(crate) mod macos;

use std::fmt;
use std::io;

/// Why a caller was refused.
#[derive(Debug)]
pub enum CallerRefused {
    /// The caller runs as another user.
    OtherUser { uid: u32 },
    /// The caller is not signed as cmux (macOS).
    Signature(String),
    /// The peer credentials could not be read.
    Io(io::Error),
}

impl fmt::Display for CallerRefused {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::OtherUser { uid } => write!(formatter, "caller runs as another user (uid {uid})"),
            Self::Signature(detail) => write!(formatter, "caller is not signed as cmux: {detail}"),
            Self::Io(error) => write!(formatter, "cannot read caller credentials: {error}"),
        }
    }
}

impl std::error::Error for CallerRefused {}

impl From<CallerRefused> for io::Error {
    fn from(refused: CallerRefused) -> Self {
        io::Error::new(io::ErrorKind::PermissionDenied, refused.to_string())
    }
}

/// Accept the peer of `stream` only when it is this user and, on macOS,
/// signed as cmux.
#[cfg(unix)]
pub fn verify(stream: &std::os::unix::net::UnixStream) -> Result<(), CallerRefused> {
    use std::os::fd::AsRawFd;
    verify_fd(stream.as_raw_fd())
}

/// [`verify`] for a raw connected Unix socket descriptor (tokio streams).
#[cfg(unix)]
pub fn verify_fd(fd: std::os::fd::RawFd) -> Result<(), CallerRefused> {
    let uid = peer_uid(fd).map_err(CallerRefused::Io)?;
    // SAFETY: geteuid has no preconditions.
    let own = unsafe { libc::geteuid() };
    if uid != own {
        return Err(CallerRefused::OtherUser { uid });
    }
    #[cfg(target_os = "macos")]
    macos::verify_signature(fd).map_err(CallerRefused::Signature)?;
    Ok(())
}

#[cfg(any(target_os = "linux", target_os = "android"))]
fn peer_uid(fd: std::os::fd::RawFd) -> io::Result<u32> {
    // SAFETY: ucred is plain data and all-zero is a valid value.
    let mut credentials = unsafe { std::mem::zeroed::<libc::ucred>() };
    let mut length = size_of::<libc::ucred>() as libc::socklen_t;
    // SAFETY: both out-pointers are valid for writes of the lengths passed.
    let result = unsafe {
        libc::getsockopt(
            fd,
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            (&raw mut credentials).cast(),
            &raw mut length,
        )
    };
    if result != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(credentials.uid)
}

#[cfg(all(unix, not(any(target_os = "linux", target_os = "android"))))]
fn peer_uid(fd: std::os::fd::RawFd) -> io::Result<u32> {
    let mut uid: libc::uid_t = 0;
    let mut gid: libc::gid_t = 0;
    // SAFETY: both out-pointers are valid for writes of one id each.
    if unsafe { libc::getpeereid(fd, &raw mut uid, &raw mut gid) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(uid)
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::os::unix::net::UnixStream;

    /// This test process is the same user and the same code as itself, so
    /// it passes its own check (on macOS through the signature path too).
    #[test]
    fn a_process_of_the_same_user_and_code_is_accepted() {
        let (left, right) = UnixStream::pair().unwrap();
        verify(&left).unwrap();
        verify(&right).unwrap();
    }

    /// A different binary of the same user is refused: `/usr/bin/nc` is
    /// Apple's code, so it has neither this build's Team ID nor this test
    /// binary's cdhash. The uid check alone would accept it.
    #[cfg(target_os = "macos")]
    #[test]
    fn a_different_binary_of_the_same_user_is_refused() {
        use std::process::{Command, Stdio};
        let directory = cmux_unix_socket::short_test_dir("caller");
        let path = directory.path().join("c.sock");
        let listener = std::os::unix::net::UnixListener::bind(&path).unwrap();
        let mut child = Command::new("/usr/bin/nc")
            .arg("-U")
            .arg(&path)
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let (stream, _) = listener.accept().unwrap();
        let refused = verify(&stream);
        let _ = child.kill();
        let _ = child.wait();
        assert!(matches!(refused, Err(CallerRefused::Signature(_))), "{refused:?}");
    }
}
