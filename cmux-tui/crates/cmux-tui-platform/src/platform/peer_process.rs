//! The process at the other end of a local socket, as a request origin peer
//! key: `token:<pid>.<pid version>`. A pid alone can be reused by another
//! process, so it is never the key on its own.

#[cfg(unix)]
use std::os::fd::RawFd;

/// macOS: the peer's audit token (`LOCAL_PEERTOKEN`); its pid and pid
/// version are `val[5]` and `val[7]` (`audit_token_to_pid`,
/// `audit_token_to_pidversion`).
#[cfg(target_vendor = "apple")]
pub(crate) fn key(fd: RawFd) -> Option<String> {
    /// `SOL_LOCAL` and `LOCAL_PEERTOKEN` from `<sys/un.h>`.
    const SOL_LOCAL: libc::c_int = 0;
    const LOCAL_PEERTOKEN: libc::c_int = 0x006;
    let mut token = [0_u32; 8];
    let mut length = size_of_val(&token) as libc::socklen_t;
    // SAFETY: the out-buffer is valid for `length` bytes.
    let result = unsafe {
        libc::getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, token.as_mut_ptr().cast(), &raw mut length)
    };
    if result != 0 || length as usize != size_of_val(&token) {
        return None;
    }
    Some(format!("token:{}.{}", token[5], token[7]))
}

/// Linux: the peer's pid (`SO_PEERCRED`) and, as its version, the process
/// start time in clock ticks (`/proc/<pid>/stat` field 22), which differs
/// for a later process that reuses the pid.
#[cfg(any(target_os = "linux", target_os = "android"))]
pub(crate) fn key(fd: RawFd) -> Option<String> {
    use std::mem::{size_of, zeroed};

    // SAFETY: ucred is plain data and all-zero is a valid value.
    let mut credentials = unsafe { zeroed::<libc::ucred>() };
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
    if result != 0 || length as usize != size_of::<libc::ucred>() || credentials.pid <= 0 {
        return None;
    }
    let pid = credentials.pid;
    let start_time = start_time_of(pid)?;
    Some(format!("token:{pid}.{start_time}"))
}

/// Linux: the executable of the peer a key names (`/proc/<pid>/exe`), only
/// while its pid still has the key's start time, so a later process that
/// reused the pid never answers for the peer. One pid, read for one
/// connected socket's peer; nothing is enumerated. A process that exec'd
/// after it connected keeps its pid and start time, which PROTOCOL.md lists
/// as the residual risk.
#[cfg(any(target_os = "linux", target_os = "android"))]
pub(crate) fn executable(key: &str) -> Option<std::path::PathBuf> {
    let (pid, version) = key.strip_prefix("token:")?.split_once('.')?;
    let pid: libc::pid_t = pid.parse().ok().filter(|pid| *pid > 0)?;
    let version: u64 = version.parse().ok()?;
    let path = std::fs::read_link(format!("/proc/{pid}/exe")).ok()?;
    (start_time_of(pid)? == version).then_some(path)
}

/// The start time of `pid` in clock ticks, its version in a peer key.
#[cfg(any(target_os = "linux", target_os = "android"))]
fn start_time_of(pid: libc::pid_t) -> Option<u64> {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    linux_start_time(&stat)
}

/// Field 22 of `/proc/<pid>/stat`. The command name (field 2) may hold
/// spaces and parentheses, so fields are counted after its last `)`.
#[cfg(any(target_os = "linux", target_os = "android"))]
fn linux_start_time(stat: &str) -> Option<u64> {
    let (_, after_name) = stat.rsplit_once(')')?;
    after_name.split_whitespace().nth(19)?.parse().ok()
}

#[cfg(all(unix, not(any(target_vendor = "apple", target_os = "linux", target_os = "android"))))]
pub(crate) fn key(_fd: RawFd) -> Option<String> {
    None
}

#[cfg(all(test, any(target_os = "linux", target_os = "android")))]
mod tests {
    use std::os::fd::AsRawFd;
    use std::os::unix::net::UnixStream;

    #[test]
    fn executable_is_the_peers_while_its_key_is_current() {
        let (ours, _theirs) = UnixStream::pair().expect("socketpair");
        let key = super::key(ours.as_raw_fd()).expect("peer key");
        let own = std::fs::canonicalize(std::env::current_exe().expect("current exe"))
            .expect("canonical");
        let found = super::executable(&key).expect("peer executable");
        assert_eq!(std::fs::canonicalize(found).expect("canonical"), own);
    }

    #[test]
    fn executable_refuses_a_stale_or_malformed_key() {
        let (ours, _theirs) = UnixStream::pair().expect("socketpair");
        let key = super::key(ours.as_raw_fd()).expect("peer key");
        let (pid, version) =
            key.strip_prefix("token:").and_then(|rest| rest.split_once('.')).expect("key shape");
        let stale = format!("token:{pid}.{}", version.parse::<u64>().expect("version") + 1);
        assert_eq!(super::executable(&stale), None);
        for bad in
            ["", "token:", "pid:1.2", "token:x.1", "token:../self.1", "token:0.1", "token:-1.1"]
        {
            assert_eq!(super::executable(bad), None, "{bad}");
        }
    }
}
