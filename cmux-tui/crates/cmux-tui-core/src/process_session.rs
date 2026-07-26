//! Exact ownership helpers for Unix PTY sessions.
//!
//! `portable-pty` starts each terminal child as a session leader. Process
//! groups inside that session are transient job-control details, so shutdown
//! enumerates and signals every session member instead of guessing which
//! foreground or background groups still exist.

use std::collections::{HashMap, HashSet};
use std::io;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Condvar, Mutex};
use std::time::{Duration, Instant};

const SESSION_KILL_POLL: Duration = Duration::from_millis(5);
const NATURAL_REAP_RETRY_INITIAL: Duration = Duration::from_millis(25);
const NATURAL_REAP_RETRY_MAX: Duration = Duration::from_secs(1);

/// Synchronization shared by a WNOWAIT child observer and explicit PTY
/// shutdown. The session leader remains reserved until this state machine
/// confirms that cleanup completed and performs the sole final reap.
pub(crate) struct ReservedChildReap<'a> {
    pub(crate) changed: &'a (Mutex<bool>, Condvar),
    pub(crate) signal_lock: &'a Mutex<()>,
    pub(crate) pty_drained: &'a AtomicBool,
    pub(crate) termination_started: &'a AtomicBool,
    pub(crate) cleanup_complete: &'a AtomicBool,
    pub(crate) child_reaped: &'a AtomicBool,
}

/// Reap a waitable PTY session leader without holding its signal lock during
/// process-table scans. A transient natural-cleanup failure is retried even
/// when no other lifecycle event arrives.
pub(crate) fn reap_reserved_session_leader(
    sync: ReservedChildReap<'_>,
    cleanup_timeout: Duration,
    mut cleanup: impl FnMut(Instant) -> bool,
    reap: impl FnOnce(),
) {
    let mut reap = Some(reap);
    let mut retry_delay = NATURAL_REAP_RETRY_INITIAL;
    loop {
        let should_attempt_cleanup = {
            let _signal = sync.signal_lock.lock().unwrap();
            if sync.cleanup_complete.load(Ordering::Acquire) {
                reap.take().expect("reserved child is reaped once")();
                sync.child_reaped.store(true, Ordering::Release);
                return;
            }
            !sync.termination_started.load(Ordering::Acquire)
                && sync.pty_drained.load(Ordering::Acquire)
        };

        let cleanup_succeeded = should_attempt_cleanup && cleanup(Instant::now() + cleanup_timeout);
        if should_attempt_cleanup {
            let _signal = sync.signal_lock.lock().unwrap();
            let cleanup_claimed = sync.cleanup_complete.load(Ordering::Acquire);
            let termination_started = sync.termination_started.load(Ordering::Acquire);
            if cleanup_claimed || (cleanup_succeeded && !termination_started) {
                sync.cleanup_complete.store(true, Ordering::Release);
                reap.take().expect("reserved child is reaped once")();
                sync.child_reaped.store(true, Ordering::Release);
                return;
            }
        }

        let state = sync.changed.0.lock().unwrap();
        let retry_natural_cleanup = should_attempt_cleanup
            && !cleanup_succeeded
            && !sync.termination_started.load(Ordering::Acquire)
            && !sync.cleanup_complete.load(Ordering::Acquire);
        if retry_natural_cleanup {
            let (_state, _) = sync
                .changed
                .1
                .wait_timeout_while(state, retry_delay, |_| {
                    !sync.termination_started.load(Ordering::Acquire)
                        && !sync.cleanup_complete.load(Ordering::Acquire)
                        && sync.pty_drained.load(Ordering::Acquire)
                })
                .unwrap();
            retry_delay = (retry_delay * 2).min(NATURAL_REAP_RETRY_MAX);
        } else {
            let _state = sync
                .changed
                .1
                .wait_while(state, |_| {
                    !sync.cleanup_complete.load(Ordering::Acquire)
                        && (sync.termination_started.load(Ordering::Acquire)
                            || !sync.pty_drained.load(Ordering::Acquire))
                })
                .unwrap();
            retry_delay = NATURAL_REAP_RETRY_INITIAL;
        }
    }
}

#[cfg(test)]
thread_local! {
    static PROCESS_TABLE_SCAN_COUNT: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
    static RAW_PID_SIGNAL_COUNT: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
}

pub(crate) struct SessionProcessSnapshot {
    sessions: HashSet<libc::pid_t>,
    state: Mutex<SessionProcessSnapshotState>,
    refreshed: Condvar,
    #[cfg(test)]
    scan_count: std::sync::atomic::AtomicUsize,
}

struct SessionProcessSnapshotState {
    generation: u64,
    members: HashMap<libc::pid_t, Vec<libc::pid_t>>,
    refreshing: bool,
    failure: Option<SessionScanFailure>,
}

#[derive(Clone)]
struct SessionScanFailure {
    kind: io::ErrorKind,
    message: String,
}

impl SessionScanFailure {
    fn from_error(error: &io::Error) -> Self {
        Self { kind: error.kind(), message: error.to_string() }
    }

    fn to_error(&self) -> io::Error {
        io::Error::new(self.kind, self.message.clone())
    }
}

impl SessionProcessSnapshot {
    pub(crate) fn capture(
        sessions: impl IntoIterator<Item = libc::pid_t>,
        deadline: Instant,
    ) -> io::Result<Self> {
        let sessions = sessions.into_iter().collect::<HashSet<_>>();
        for session in &sessions {
            validate_session_target(*session)?;
        }
        let members = scan_sessions(&sessions, Some(deadline))?;
        #[cfg(test)]
        let has_sessions = !sessions.is_empty();
        Ok(Self {
            sessions,
            state: Mutex::new(SessionProcessSnapshotState {
                generation: 0,
                members,
                refreshing: false,
                failure: None,
            }),
            refreshed: Condvar::new(),
            #[cfg(test)]
            scan_count: std::sync::atomic::AtomicUsize::new(usize::from(has_sessions)),
        })
    }

    fn members(&self, session: libc::pid_t) -> io::Result<(u64, Vec<libc::pid_t>)> {
        if !self.sessions.contains(&session) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "PTY session is outside the shutdown snapshot",
            ));
        }
        let state = self.state.lock().unwrap();
        if let Some(failure) = &state.failure {
            return Err(failure.to_error());
        }
        Ok((state.generation, state.members.get(&session).cloned().unwrap_or_default()))
    }

    fn refresh_members(
        &self,
        session: libc::pid_t,
        observed_generation: u64,
        deadline: Instant,
    ) -> io::Result<(u64, Vec<libc::pid_t>)> {
        if !self.sessions.contains(&session) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "PTY session is outside the shutdown snapshot",
            ));
        }
        let mut state = self.state.lock().unwrap();
        loop {
            if let Some(failure) = &state.failure {
                return Err(failure.to_error());
            }
            if state.generation != observed_generation {
                return Ok((
                    state.generation,
                    state.members.get(&session).cloned().unwrap_or_default(),
                ));
            }
            let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
                return Err(snapshot_deadline_error());
            };
            if !state.refreshing {
                state.refreshing = true;
                break;
            }
            let (next, timeout) = self.refreshed.wait_timeout(state, remaining).unwrap();
            state = next;
            if timeout.timed_out() && state.generation == observed_generation {
                return Err(snapshot_deadline_error());
            }
        }
        drop(state);

        #[cfg(test)]
        self.scan_count.fetch_add(1, Ordering::Relaxed);
        let scanned = scan_sessions(&self.sessions, Some(deadline));
        let mut state = self.state.lock().unwrap();
        state.refreshing = false;
        match scanned {
            Ok(members) => {
                state.generation = state.generation.saturating_add(1);
                state.members = members;
            }
            Err(error) => {
                state.failure = Some(SessionScanFailure::from_error(&error));
            }
        }
        self.refreshed.notify_all();
        if let Some(failure) = &state.failure {
            return Err(failure.to_error());
        }
        Ok((state.generation, state.members.get(&session).cloned().unwrap_or_default()))
    }

    #[cfg(test)]
    fn scan_count(&self) -> usize {
        self.scan_count.load(Ordering::Relaxed)
    }
}

pub(crate) fn signal_until(
    session: libc::pid_t,
    signal: libc::c_int,
    deadline: Instant,
) -> io::Result<()> {
    let snapshot = SessionProcessSnapshot::capture([session], deadline)?;
    signal_from_snapshot(&snapshot, session, signal)
}

pub(crate) fn signal_from_snapshot(
    snapshot: &SessionProcessSnapshot,
    session: libc::pid_t,
    signal: libc::c_int,
) -> io::Result<()> {
    validate_session_target(session)?;
    let (_, members) = snapshot.members(session)?;
    signal_members_with(&members, session, None, signal)
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
    let snapshot = SessionProcessSnapshot::capture([session], deadline)?;
    kill_until_only_leader_from_snapshot(&snapshot, session, leader, deadline, leader_exited)
}

pub(crate) fn kill_until_only_leader_from_snapshot(
    snapshot: &SessionProcessSnapshot,
    session: libc::pid_t,
    leader: libc::pid_t,
    deadline: Instant,
    leader_exited: impl Fn() -> bool,
) -> io::Result<bool> {
    kill_until_only_reserved_from_snapshot(snapshot, session, leader, deadline, leader_exited, None)
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
    let snapshot = SessionProcessSnapshot::capture([session], deadline)?;
    kill_until_only_reserved_from_snapshot(
        &snapshot,
        session,
        reserved,
        deadline,
        || true,
        Some(reserved),
    )
}

fn kill_until_only_reserved_from_snapshot(
    snapshot: &SessionProcessSnapshot,
    session: libc::pid_t,
    reserved: libc::pid_t,
    deadline: Instant,
    can_reconcile: impl Fn() -> bool,
    signal_exclusion: Option<libc::pid_t>,
) -> io::Result<bool> {
    validate_session_target(session)?;
    let (mut generation, mut known_members) = snapshot.members(session)?;
    signal_members(&known_members, session, signal_exclusion)?;
    loop {
        let known_drained = known_members
            .iter()
            .copied()
            .filter(|pid| *pid != reserved)
            .map(|pid| still_member(pid, session))
            .collect::<io::Result<Vec<_>>>()?
            .into_iter()
            .all(|alive| !alive);
        if can_reconcile() && known_drained {
            let (current_generation, current) =
                snapshot.refresh_members(session, generation, deadline)?;
            if current.iter().all(|pid| *pid == reserved) {
                return Ok(true);
            }
            signal_members(&current, session, signal_exclusion)?;
            generation = current_generation;
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
pub fn session_is_empty_until(session: libc::pid_t, deadline: Instant) -> io::Result<bool> {
    validate_session_target(session)?;
    members_until(session, deadline).map(|members| members.is_empty())
}

/// Snapshot process IDs in a non-caller session. Callers must capture exact
/// process birth identities before using the result for later signaling.
pub fn session_member_pids_until(
    session: libc::pid_t,
    deadline: Instant,
) -> io::Result<Vec<libc::pid_t>> {
    validate_session_target(session)?;
    members_until(session, deadline)
}

fn signal_members(
    members: &[libc::pid_t],
    session: libc::pid_t,
    reserved: Option<libc::pid_t>,
) -> io::Result<()> {
    signal_members_with(members, session, reserved, libc::SIGKILL)
}

fn signal_members_with(
    members: &[libc::pid_t],
    session: libc::pid_t,
    reserved: Option<libc::pid_t>,
    signal: libc::c_int,
) -> io::Result<()> {
    for pid in members.iter().copied().filter(|pid| Some(*pid) != reserved) {
        signal_if_still_member(pid, session, signal)?;
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
    #[cfg(test)]
    RAW_PID_SIGNAL_COUNT.set(RAW_PID_SIGNAL_COUNT.get() + 1);
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

#[cfg(test)]
fn members(session: libc::pid_t) -> io::Result<Vec<libc::pid_t>> {
    let sessions = HashSet::from([session]);
    Ok(scan_sessions(&sessions, None)?.remove(&session).unwrap_or_default())
}

fn members_until(session: libc::pid_t, deadline: Instant) -> io::Result<Vec<libc::pid_t>> {
    let sessions = HashSet::from([session]);
    Ok(scan_sessions(&sessions, Some(deadline))?.remove(&session).unwrap_or_default())
}

fn scan_sessions(
    sessions: &HashSet<libc::pid_t>,
    deadline: Option<Instant>,
) -> io::Result<HashMap<libc::pid_t, Vec<libc::pid_t>>> {
    let mut members =
        sessions.iter().copied().map(|session| (session, Vec::new())).collect::<HashMap<_, _>>();
    if sessions.is_empty() {
        return Ok(members);
    }
    #[cfg(test)]
    PROCESS_TABLE_SCAN_COUNT.set(PROCESS_TABLE_SCAN_COUNT.get() + 1);
    for pid in all_process_ids(deadline)? {
        ensure_before_deadline(deadline)?;
        if pid <= 1 {
            continue;
        }
        // SAFETY: getsid only queries process metadata.
        let current_session = unsafe { libc::getsid(pid) };
        if let Some(session_members) = members.get_mut(&current_session) {
            session_members.push(pid);
            continue;
        }
        if current_session < 0 {
            let error = io::Error::last_os_error();
            if error.raw_os_error() != Some(libc::ESRCH) {
                return Err(error);
            }
        }
    }
    for session_members in members.values_mut() {
        session_members.sort_unstable();
        session_members.dedup();
    }
    Ok(members)
}

fn ensure_before_deadline(deadline: Option<Instant>) -> io::Result<()> {
    if deadline.is_some_and(|deadline| Instant::now() >= deadline) {
        return Err(snapshot_deadline_error());
    }
    Ok(())
}

fn snapshot_deadline_error() -> io::Error {
    io::Error::new(io::ErrorKind::TimedOut, "process-session snapshot deadline expired")
}

#[cfg(test)]
fn shutdown_batch_members_for_test(
    sessions: &[libc::pid_t],
    deadline: Instant,
) -> io::Result<Vec<Vec<libc::pid_t>>> {
    let snapshot = SessionProcessSnapshot::capture(sessions.iter().copied(), deadline)?;
    sessions.iter().map(|session| snapshot.members(*session).map(|(_, members)| members)).collect()
}

#[cfg(all(target_os = "macos", test))]
fn macos_session_process_ids(session: libc::pid_t) -> io::Result<Vec<libc::pid_t>> {
    members(session)
}

#[cfg(target_os = "macos")]
fn all_process_ids(deadline: Option<Instant>) -> io::Result<Vec<libc::pid_t>> {
    use std::ffi::c_void;
    use std::mem::size_of;

    // Callers retain this snapshot and poll its members directly. A new full
    // process-table scan happens only after that generation has drained.
    ensure_before_deadline(deadline)?;
    // SAFETY: a null buffer asks libproc for the current process count.
    let count = unsafe { libc::proc_listallpids(std::ptr::null_mut(), 0) };
    if count < 0 {
        return Err(io::Error::last_os_error());
    }
    let mut capacity =
        usize::try_from(count).map_err(|_| io::Error::other("invalid process count"))? + 32;
    for _ in 0..4 {
        ensure_before_deadline(deadline)?;
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
fn all_process_ids(deadline: Option<Instant>) -> io::Result<Vec<libc::pid_t>> {
    let mut pids = Vec::new();
    for entry in std::fs::read_dir("/proc")? {
        ensure_before_deadline(deadline)?;
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
fn all_process_ids(_deadline: Option<Instant>) -> io::Result<Vec<libc::pid_t>> {
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
    fn session_members_are_never_signaled_through_a_reusable_pid() {
        let mut child = spawn_session_child();
        let session = libc::pid_t::try_from(child.id()).unwrap();
        RAW_PID_SIGNAL_COUNT.set(0);

        signal_until(session, libc::SIGCONT, Instant::now() + Duration::from_secs(1)).unwrap();
        let raw_signals = RAW_PID_SIGNAL_COUNT.get();

        child.kill().unwrap();
        child.wait().unwrap();
        assert_eq!(
            raw_signals, 0,
            "session cleanup used a reusable PID instead of a stable process identity"
        );
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

    #[cfg(any(target_os = "macos", target_os = "linux"))]
    #[test]
    fn concurrent_shutdown_refreshes_share_one_new_snapshot_generation() {
        let mut children = [spawn_session_child(), spawn_session_child()];
        let sessions = children
            .iter()
            .map(|child| libc::pid_t::try_from(child.id()).unwrap())
            .collect::<Vec<_>>();
        let deadline = Instant::now() + Duration::from_secs(1);
        let snapshot = std::sync::Arc::new(
            SessionProcessSnapshot::capture(sessions.clone(), deadline).unwrap(),
        );
        let barrier = std::sync::Arc::new(std::sync::Barrier::new(sessions.len()));

        std::thread::scope(|scope| {
            for session in &sessions {
                let snapshot = snapshot.clone();
                let barrier = barrier.clone();
                scope.spawn(move || {
                    let generation = snapshot.members(*session).unwrap().0;
                    barrier.wait();
                    snapshot.refresh_members(*session, generation, deadline).unwrap();
                });
            }
        });
        let scan_count = snapshot.scan_count();

        for child in &mut children {
            child.kill().unwrap();
            child.wait().unwrap();
        }
        assert_eq!(
            scan_count, 2,
            "concurrent refreshes did not coalesce onto one new process-table snapshot"
        );
    }
}
