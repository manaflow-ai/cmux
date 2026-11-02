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

#[cfg(unix)]
mod supervised;
#[cfg(unix)]
pub use supervised::SupervisedChild;

#[cfg(target_os = "linux")]
mod root;
#[cfg(target_os = "linux")]
pub use root::RootOwnedDaemon;

/// Authenticate the root endpoint of a private inherited bootstrap channel.
/// This separate entry point never changes ordinary same-user admission.
/// It proves parenthood, not enrollment or permission to serve. Do not use
/// it to authorize a caller on a public socket or a caller-selected path.
#[cfg(target_os = "linux")]
pub fn verify_inherited_root_parent(fd: std::os::fd::RawFd) -> Result<(), CallerRefused> {
    root::verify_parent(fd)
}

use std::fmt;
use std::io;

/// Protect a private bootstrap recipient from same-user process inspection and
/// core dumps. Call only after authenticating its startup authority, before
/// advertising support or accepting private material. Ordinary caller admission
/// is unchanged. Failure must leave the private receiving role unavailable.
#[cfg(target_os = "linux")]
pub fn protect_private_process() -> io::Result<()> {
    // SAFETY: integer-only prctl changes only this process's dumpability.
    if unsafe { libc::prctl(libc::PR_SET_DUMPABLE, 0, 0, 0, 0) } != 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: integer-only prctl reads this process's current dumpability.
    let state = unsafe { libc::prctl(libc::PR_GET_DUMPABLE, 0, 0, 0, 0) };
    match state {
        0 => Ok(()),
        -1 => Err(io::Error::last_os_error()),
        _ => Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "link.private_process.inspection_not_blocked",
        )),
    }
}

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

/// Check the kernel uid and pid of an inherited stream's parent endpoint.
/// This proves parenthood, not code identity. Use it only with a private
/// inherited channel; it does not authorize a peer on a public socket.
#[cfg(unix)]
pub fn verify_inherited_parent(fd: std::os::fd::RawFd) -> Result<(), CallerRefused> {
    let uid = peer_uid(fd).map_err(CallerRefused::Io)?;
    // SAFETY: geteuid/getppid have no preconditions.
    let own = unsafe { libc::geteuid() };
    let parent = unsafe { libc::getppid() } as u32;
    if uid != own {
        return Err(CallerRefused::OtherUser { uid });
    }
    if peer_pid(fd).map_err(CallerRefused::Io)? != Some(parent) {
        return Err(CallerRefused::Io(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "inherited peer is not the parent process",
        )));
    }
    Ok(())
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
pub(crate) fn peer_uid(fd: std::os::fd::RawFd) -> io::Result<u32> {
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
pub(crate) fn peer_uid(fd: std::os::fd::RawFd) -> io::Result<u32> {
    let mut uid: libc::uid_t = 0;
    let mut gid: libc::gid_t = 0;
    // SAFETY: both out-pointers are valid for writes of one id each.
    if unsafe { libc::getpeereid(fd, &raw mut uid, &raw mut gid) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(uid)
}

/// The pid of the process that serves the other end of a connected Unix
/// socket (for a client stream: the process that called `listen`), or
/// `None` on a system with no peer-pid API (the BSDs other than macOS).
#[cfg(any(target_os = "linux", target_os = "android"))]
pub fn peer_pid(fd: std::os::fd::RawFd) -> io::Result<Option<u32>> {
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
    Ok(u32::try_from(credentials.pid).ok())
}

/// See the Linux [`peer_pid`]: macOS answers through `LOCAL_PEERPID`.
#[cfg(target_vendor = "apple")]
pub fn peer_pid(fd: std::os::fd::RawFd) -> io::Result<Option<u32>> {
    let mut pid: libc::pid_t = 0;
    let mut length = size_of::<libc::pid_t>() as libc::socklen_t;
    // SAFETY: both out-pointers are valid for writes of the lengths passed.
    let result = unsafe {
        libc::getsockopt(
            fd,
            libc::SOL_LOCAL,
            libc::LOCAL_PEERPID,
            (&raw mut pid).cast(),
            &raw mut length,
        )
    };
    if result != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(u32::try_from(pid).ok())
}

/// See the Linux [`peer_pid`]: no peer-pid API here, so callers check the
/// uid only.
#[cfg(all(unix, not(any(target_os = "linux", target_os = "android", target_vendor = "apple"))))]
pub fn peer_pid(_fd: std::os::fd::RawFd) -> io::Result<Option<u32>> {
    Ok(None)
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
