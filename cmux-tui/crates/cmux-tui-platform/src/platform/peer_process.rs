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
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    let start_time = linux_start_time(&stat)?;
    Some(format!("token:{pid}.{start_time}"))
}

/// Field 22 of `/proc/<pid>/stat`. The command name (field 2) may hold
/// spaces and parentheses, so fields are counted after its last `)`.
#[cfg(any(target_os = "linux", target_os = "android", test))]
fn linux_start_time(stat: &str) -> Option<u64> {
    let (_, after_name) = stat.rsplit_once(')')?;
    after_name.split_whitespace().nth(19)?.parse().ok()
}

#[cfg(all(unix, not(any(target_vendor = "apple", target_os = "linux", target_os = "android"))))]
pub(crate) fn key(_fd: RawFd) -> Option<String> {
    None
}

#[cfg(test)]
mod tests {
    use super::linux_start_time;

    #[test]
    fn start_time_is_field_22_even_with_parentheses_in_the_name() {
        let stat =
            "4242 (a (b) c) S 1 4242 4242 0 -1 4194560 100 0 0 0 1 2 0 0 20 0 1 0 987654 1 2";
        assert_eq!(linux_start_time(stat), Some(987654));
        assert_eq!(linux_start_time("garbage"), None);
    }
}
