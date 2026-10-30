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

/// argv[1] of a terminal host process (cmux-host `TERMINAL_HOST_ARG`).
const TERMINAL_HOST_ARG: &str = "__terminal-host";

/// Whether the peer a key names runs inside a cmux terminal: the leader of
/// its session (the terminal's PTY child, which the host started with
/// setsid) is a child of a `cmux-tui __terminal-host`. Only this connected
/// socket's peer, its session leader and that leader's parent are read;
/// nothing is enumerated and no daemon lock is taken. A process that left
/// its terminal's session (setsid) answers false.
pub(crate) fn runs_in_terminal(key: &str) -> bool {
    let Some(pid) = key
        .strip_prefix("token:")
        .and_then(|rest| rest.split_once('.'))
        .and_then(|(pid, _)| pid.parse::<libc::pid_t>().ok())
        .filter(|pid| *pid > 0)
    else {
        return false;
    };
    // SAFETY: getsid only reads kernel process metadata for the positive pid.
    let Ok(leader) = u32::try_from(unsafe { libc::getsid(pid) }) else { return false };
    let Some(host) = super::codex_daemon::parent_process_id(leader).filter(|host| *host > 1)
    else {
        return false;
    };
    super::codex_daemon::process_arguments(host)
        .is_some_and(|argv| is_terminal_host(&argv))
}

fn is_terminal_host(argv: &[String]) -> bool {
    argv.get(1).is_some_and(|arg| arg == TERMINAL_HOST_ARG)
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

#[cfg(test)]
mod terminal_peer_tests {
    #[test]
    fn a_terminal_host_is_named_by_its_second_argument() {
        let argv = |args: &[&str]| args.iter().map(|arg| arg.to_string()).collect::<Vec<_>>();
        assert!(super::is_terminal_host(&argv(&["/x/cmux-tui", "__terminal-host", "--owner"])));
        assert!(!super::is_terminal_host(&argv(&["/x/cmux-tui", "--headless"])));
        assert!(!super::is_terminal_host(&argv(&["__terminal-host"])));
    }

    #[test]
    fn a_malformed_key_is_not_terminal_bound() {
        for bad in ["", "token:", "token:x.1", "token:0.1", "token:-1.1"] {
            assert!(!super::runs_in_terminal(bad), "{bad}");
        }
    }
}
