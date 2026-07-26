//! Exact ownership helpers for Unix PTY sessions.
//!
//! `portable-pty` starts each terminal child as a session leader. Process
//! groups inside that session are transient job-control details, so shutdown
//! enumerates and signals every session member instead of guessing which
//! foreground or background groups still exist.

use std::io;
use std::time::{Duration, Instant};

const SESSION_KILL_POLL: Duration = Duration::from_millis(5);

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
    loop {
        let session_members = members(session)?;
        for pid in &session_members {
            signal_if_still_member(*pid, session, libc::SIGKILL)?;
        }
        // Once WNOWAIT has observed the leader's exit, no process can fork a
        // new member between this complete session scan and success.
        if leader_exited() && session_members.iter().all(|pid| *pid == leader) {
            return Ok(true);
        }
        if Instant::now() >= deadline {
            return Ok(false);
        }
        std::thread::sleep(
            deadline.saturating_duration_since(Instant::now()).min(SESSION_KILL_POLL),
        );
    }
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
    // SAFETY: getsid only queries process metadata.
    let current_session = unsafe { libc::getsid(pid) };
    if current_session < 0 {
        let error = io::Error::last_os_error();
        return if error.raw_os_error() == Some(libc::ESRCH) { Ok(()) } else { Err(error) };
    }
    if current_session != session {
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

fn members(session: libc::pid_t) -> io::Result<Vec<libc::pid_t>> {
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

#[cfg(target_os = "macos")]
fn all_process_ids() -> io::Result<Vec<libc::pid_t>> {
    use std::ffi::c_void;
    use std::mem::size_of;

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
