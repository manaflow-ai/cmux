//! Exact ownership helpers for Unix PTY sessions.
//!
//! `portable-pty` starts each terminal child as a session leader. Process
//! groups inside that session are transient job-control details, so shutdown
//! enumerates and signals every session member instead of guessing which
//! foreground or background groups still exist.

use std::io;
use std::time::{Duration, Instant};

const SESSION_KILL_POLL: Duration = Duration::from_millis(5);

#[cfg(test)]
thread_local! {
    static PROCESS_TABLE_SCAN_COUNT: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
}

pub(crate) fn signal(session: libc::pid_t, signal: libc::c_int) -> io::Result<()> {
    validate_session_target(session)?;
    for pid in members(session)? {
        signal_if_still_member(pid, session, signal)?;
    }
    Ok(())
}

/// Repeatedly SIGKILL every member until the session contains only its
/// reserved leader (or is empty). Callers must keep the leader unreaped for
/// this entire operation, which prevents the session id from being reused.
pub(crate) fn kill_until_only_leader(
    session: libc::pid_t,
    leader: libc::pid_t,
    deadline: Instant,
    leader_exited: impl Fn() -> bool,
) -> io::Result<bool> {
    validate_session_target(session)?;
    let mut known_members = members(session)?;
    signal_members(&known_members, session, None)?;
    loop {
        let known_drained = known_members
            .iter()
            .copied()
            .filter(|pid| *pid != leader)
            .map(|pid| still_member(pid, session))
            .collect::<io::Result<Vec<_>>>()?
            .into_iter()
            .all(|alive| !alive);
        if leader_exited() && known_drained {
            let current = members(session)?;
            if current.iter().all(|pid| *pid == leader) {
                return Ok(true);
            }
            signal_members(&current, session, None)?;
            known_members = current;
        }
        if Instant::now() >= deadline {
            return Ok(false);
        }
        std::thread::sleep(
            deadline.saturating_duration_since(Instant::now()).min(SESSION_KILL_POLL),
        );
    }
}

/// Drain a captured session while the caller keeps one exact member stopped.
/// The reserved process prevents session-id reuse and cannot fork, so global
/// membership is reconciled only after each known generation has exited.
pub fn kill_until_only_reserved(
    session: libc::pid_t,
    reserved: libc::pid_t,
    deadline: Instant,
) -> io::Result<bool> {
    validate_session_target(session)?;
    if !still_member(reserved, session)? {
        return Err(io::Error::new(io::ErrorKind::NotFound, "reserved PTY session process exited"));
    }
    let mut known_members = members(session)?;
    signal_members(&known_members, session, Some(reserved))?;
    loop {
        let known_drained = known_members
            .iter()
            .copied()
            .filter(|pid| *pid != reserved)
            .map(|pid| still_member(pid, session))
            .collect::<io::Result<Vec<_>>>()?
            .into_iter()
            .all(|alive| !alive);
        if known_drained {
            let current = members(session)?;
            if current.iter().all(|pid| *pid == reserved) {
                return Ok(true);
            }
            signal_members(&current, session, Some(reserved))?;
            known_members = current;
        }
        if Instant::now() >= deadline {
            return Ok(false);
        }
        std::thread::sleep(
            deadline.saturating_duration_since(Instant::now()).min(SESSION_KILL_POLL),
        );
    }
}

/// Read-only proof used after every pre-close process identity in a captured
/// legacy PTY session has already disappeared.
pub fn session_is_empty(session: libc::pid_t) -> io::Result<bool> {
    validate_session_target(session)?;
    members(session).map(|members| members.is_empty())
}

/// Snapshot process IDs in a non-caller session. Callers must capture exact
/// process birth identities before using the result for later signaling.
pub fn session_member_pids(session: libc::pid_t) -> io::Result<Vec<libc::pid_t>> {
    validate_session_target(session)?;
    members(session)
}

fn signal_members(
    members: &[libc::pid_t],
    session: libc::pid_t,
    reserved: Option<libc::pid_t>,
) -> io::Result<()> {
    for pid in members.iter().copied().filter(|pid| Some(*pid) != reserved) {
        signal_if_still_member(pid, session, libc::SIGKILL)?;
    }
    Ok(())
}

fn validate_session_target(session: libc::pid_t) -> io::Result<()> {
    if session <= 1 {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "invalid PTY session id"));
    }
    // SAFETY: getsid(0) only queries the calling process.
    if unsafe { libc::getsid(0) } == session {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "refusing to signal the mux process session",
        ));
    }
    Ok(())
}

fn signal_if_still_member(
    pid: libc::pid_t,
    session: libc::pid_t,
    signal: libc::c_int,
) -> io::Result<()> {
    // Revalidate membership immediately before signaling. The reserved
    // session leader prevents the session id itself from being recycled.
    if !still_member(pid, session)? {
        return Ok(());
    }
    // SAFETY: membership was revalidated above and `signal` is a platform
    // signal constant supplied by this module's callers.
    if unsafe { libc::kill(pid, signal) } == 0 {
        return Ok(());
    }
    let error = io::Error::last_os_error();
    if error.raw_os_error() == Some(libc::ESRCH) { Ok(()) } else { Err(error) }
}

fn still_member(pid: libc::pid_t, session: libc::pid_t) -> io::Result<bool> {
    // SAFETY: getsid only queries process metadata.
    let current_session = unsafe { libc::getsid(pid) };
    if current_session >= 0 {
        return Ok(current_session == session);
    }
    let error = io::Error::last_os_error();
    if error.raw_os_error() == Some(libc::ESRCH) { Ok(false) } else { Err(error) }
}

fn members(session: libc::pid_t) -> io::Result<Vec<libc::pid_t>> {
    #[cfg(test)]
    PROCESS_TABLE_SCAN_COUNT.set(PROCESS_TABLE_SCAN_COUNT.get() + 1);
    let mut members = Vec::new();
    for pid in all_process_ids()? {
        if pid <= 1 {
            continue;
        }
        // SAFETY: getsid only queries process metadata.
        let current_session = unsafe { libc::getsid(pid) };
        if current_session == session {
            members.push(pid);
            continue;
        }
        if current_session < 0 {
            let error = io::Error::last_os_error();
            if error.raw_os_error() != Some(libc::ESRCH) {
                return Err(error);
            }
        }
    }
    members.sort_unstable();
    members.dedup();
    Ok(members)
}

#[cfg(test)]
fn shutdown_batch_members_for_test(
    sessions: &[libc::pid_t],
    deadline: Instant,
) -> io::Result<Vec<Vec<libc::pid_t>>> {
    sessions
        .iter()
        .map(|session| {
            if Instant::now() >= deadline {
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "process-session snapshot deadline expired",
                ));
            }
            members(*session)
        })
        .collect()
}

#[cfg(all(target_os = "macos", test))]
fn macos_session_process_ids(session: libc::pid_t) -> io::Result<Vec<libc::pid_t>> {
    members(session)
}

#[cfg(target_os = "macos")]
fn all_process_ids() -> io::Result<Vec<libc::pid_t>> {
    use std::ffi::c_void;
    use std::mem::size_of;

    // Callers retain this snapshot and poll its members directly. A new full
    // process-table scan happens only after that generation has drained.
    // SAFETY: a null buffer asks libproc for the current process count.
    let count = unsafe { libc::proc_listallpids(std::ptr::null_mut(), 0) };
    if count < 0 {
        return Err(io::Error::last_os_error());
    }
    let mut capacity =
        usize::try_from(count).map_err(|_| io::Error::other("invalid process count"))? + 32;
    for _ in 0..4 {
        let mut pids = vec![0; capacity];
        let bytes = capacity
            .checked_mul(size_of::<libc::pid_t>())
            .and_then(|bytes| i32::try_from(bytes).ok())
            .ok_or_else(|| io::Error::other("process list buffer overflow"))?;
        // SAFETY: `pids` owns a writable buffer of `bytes` bytes.
        let listed = unsafe { libc::proc_listallpids(pids.as_mut_ptr().cast::<c_void>(), bytes) };
        if listed < 0 {
            return Err(io::Error::last_os_error());
        }
        let listed =
            usize::try_from(listed).map_err(|_| io::Error::other("invalid process count"))?;
        if listed < capacity {
            pids.truncate(listed);
            return Ok(pids);
        }
        capacity = capacity
            .checked_mul(2)
            .ok_or_else(|| io::Error::other("process list buffer overflow"))?;
    }
    Err(io::Error::other("process list did not stabilize"))
}

#[cfg(target_os = "linux")]
fn all_process_ids() -> io::Result<Vec<libc::pid_t>> {
    let mut pids = Vec::new();
    for entry in std::fs::read_dir("/proc")? {
        let entry = match entry {
            Ok(entry) => entry,
            Err(error) if error.kind() == io::ErrorKind::NotFound => continue,
            Err(error) => return Err(error),
        };
        if let Some(pid) =
            entry.file_name().to_str().and_then(|name| name.parse::<libc::pid_t>().ok())
        {
            pids.push(pid);
        }
    }
    Ok(pids)
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn all_process_ids() -> io::Result<Vec<libc::pid_t>> {
    Err(io::Error::new(
        io::ErrorKind::Unsupported,
        "PTY session enumeration is unavailable on this platform",
    ))
}

#[cfg(test)]
mod tests {
    #[cfg(any(target_os = "macos", target_os = "linux"))]
    use std::os::unix::process::CommandExt;
    #[cfg(any(target_os = "macos", target_os = "linux"))]
    use std::process::{Command, Stdio};

    #[cfg(any(target_os = "macos", target_os = "linux"))]
    use super::*;

    #[cfg(any(target_os = "macos", target_os = "linux"))]
    fn spawn_session_child() -> std::process::Child {
        let mut command = Command::new("sleep");
        command.arg("60").stdout(Stdio::null()).stderr(Stdio::null());
        unsafe {
            command.pre_exec(|| {
                if libc::setsid() < 0 {
                    return Err(io::Error::last_os_error());
                }
                Ok(())
            });
        }
        command.spawn().unwrap()
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn macos_session_query_is_scoped_to_the_owned_session() {
        let mut child = spawn_session_child();
        let session = libc::pid_t::try_from(child.id()).unwrap();

        let members = macos_session_process_ids(session).unwrap();

        let current = libc::pid_t::try_from(std::process::id()).unwrap();
        assert!(members.contains(&session));
        assert!(!members.contains(&current));
        child.kill().unwrap();
        child.wait().unwrap();
    }

    #[cfg(any(target_os = "macos", target_os = "linux"))]
    #[test]
    fn shutdown_batch_reuses_one_process_table_snapshot() {
        let mut children = [spawn_session_child(), spawn_session_child()];
        let sessions = children
            .iter()
            .map(|child| libc::pid_t::try_from(child.id()).unwrap())
            .collect::<Vec<_>>();
        PROCESS_TABLE_SCAN_COUNT.set(0);

        let snapshots =
            shutdown_batch_members_for_test(&sessions, Instant::now() + Duration::from_secs(1));
        let scan_count = PROCESS_TABLE_SCAN_COUNT.get();

        for child in &mut children {
            child.kill().unwrap();
            child.wait().unwrap();
        }
        let snapshots = snapshots.unwrap();
        assert!(
            snapshots.iter().zip(&sessions).all(|(members, session)| members.contains(session))
        );
        assert_eq!(
            scan_count, 1,
            "one shutdown batch scanned the global process table more than once"
        );
    }
}
