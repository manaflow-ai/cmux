//! Exact ownership helpers for Unix PTY sessions.
//!
//! `portable-pty` starts each terminal child as a session leader. Process
//! groups inside that session are transient job-control details, so shutdown
//! enumerates and signals every session member instead of guessing which
//! foreground or background groups still exist.

use std::collections::{HashMap, HashSet};
use std::io;
#[cfg(target_os = "macos")]
use std::mem::size_of;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::mpsc::{self, RecvTimeoutError};
use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::time::{Duration, Instant};

const SESSION_KILL_POLL: Duration = Duration::from_millis(5);
const PROCESS_SESSION_PREFLIGHT_TIMEOUT: Duration = Duration::from_secs(1);
const NATURAL_REAP_RETRY_INITIAL: Duration = Duration::from_millis(25);
const NATURAL_REAP_RETRY_MAX: Duration = Duration::from_secs(1);
const NATURAL_REAP_DEGRADED_RETRY: Duration = Duration::from_secs(30);
const NATURAL_REAP_BATCH_WINDOW: Duration = Duration::from_millis(5);
const NATURAL_REAP_CAPACITY: usize = 4_096;
#[cfg(not(test))]
const NATURAL_REAP_MAX_ATTEMPTS: usize = 8;
#[cfg(test)]
const NATURAL_REAP_MAX_ATTEMPTS: usize = 3;

#[cfg(test)]
static NATURAL_REAP_WORKERS: AtomicUsize = AtomicUsize::new(0);

static NATURAL_REAPER: OnceLock<Mutex<Option<NaturalReaper>>> = OnceLock::new();
static STABLE_PROCESS_SIGNALING: OnceLock<Result<(), StableProcessSignalingFailure>> =
    OnceLock::new();

struct StableProcessSignalingFailure {
    kind: io::ErrorKind,
    message: String,
}

impl StableProcessSignalingFailure {
    fn from_error(error: io::Error) -> Self {
        Self { kind: error.kind(), message: error.to_string() }
    }

    fn to_error(&self) -> io::Error {
        io::Error::new(self.kind, self.message.clone())
    }
}

#[cfg(test)]
thread_local! {
    static FORCE_PROCESS_SESSION_PREFLIGHT_FAILURE: std::cell::Cell<bool> =
        const { std::cell::Cell::new(false) };
}

#[cfg(test)]
pub(crate) fn dedicated_natural_reap_workers_for_test() -> usize {
    NATURAL_REAP_WORKERS.load(Ordering::Acquire)
}

#[cfg(test)]
pub(crate) fn set_process_session_preflight_failure_for_test(enabled: bool) {
    FORCE_PROCESS_SESSION_PREFLIGHT_FAILURE.set(enabled);
}

/// Synchronization shared by a WNOWAIT child observer and explicit PTY
/// shutdown. The session leader remains reserved until this state machine
/// confirms that cleanup completed and performs the sole final reap.
pub(crate) struct ReservedChildReap<'a> {
    pub(crate) signal_lock: &'a Mutex<()>,
    pub(crate) pty_drained: &'a AtomicBool,
    pub(crate) termination_started: &'a AtomicBool,
    pub(crate) cleanup_complete: &'a AtomicBool,
    pub(crate) child_reaped: &'a AtomicBool,
}

enum NaturalReaperCommand {
    Add(NaturalReapRequest),
    Wake,
}

struct NaturalReapRequest {
    session: libc::pid_t,
    cleanup_timeout: Duration,
    needs_cleanup: Box<dyn Fn() -> bool + Send>,
    prepare_cleanup: Box<dyn FnMut() -> bool + Send>,
    finish: Box<dyn FnMut(bool) -> bool + Send>,
    _lease: ReservedChildReaperLease,
    next_attempt: Instant,
    retry_delay: Duration,
    attempts: usize,
    degraded: bool,
}

struct NaturalReaper {
    sender: mpsc::Sender<NaturalReaperCommand>,
    active: Arc<AtomicUsize>,
    degraded: Arc<AtomicUsize>,
    wake_pending: Arc<AtomicBool>,
    _worker: std::thread::JoinHandle<()>,
}

pub(crate) struct ReservedChildReaperLease {
    sender: mpsc::Sender<NaturalReaperCommand>,
    active: Arc<AtomicUsize>,
    degraded: Arc<AtomicUsize>,
}

impl Drop for ReservedChildReaperLease {
    fn drop(&mut self) {
        self.active.fetch_sub(1, Ordering::AcqRel);
    }
}

impl NaturalReaper {
    fn start() -> io::Result<Self> {
        let (sender, receiver) = mpsc::channel();
        let active = Arc::new(AtomicUsize::new(0));
        let degraded = Arc::new(AtomicUsize::new(0));
        let wake_pending = Arc::new(AtomicBool::new(false));
        let worker_wake_pending = wake_pending.clone();
        let worker = std::thread::Builder::new().name("cmux-pty-session-reaper".into()).spawn(
            move || {
                #[cfg(test)]
                NATURAL_REAP_WORKERS.fetch_add(1, Ordering::AcqRel);
                run_natural_reaper(receiver, worker_wake_pending);
                #[cfg(test)]
                NATURAL_REAP_WORKERS.fetch_sub(1, Ordering::AcqRel);
            },
        )?;
        Ok(Self { sender, active, degraded, wake_pending, _worker: worker })
    }

    fn lease(&self) -> io::Result<ReservedChildReaperLease> {
        self.active
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |active| {
                (active < NATURAL_REAP_CAPACITY).then_some(active + 1)
            })
            .map_err(|_| {
                io::Error::new(io::ErrorKind::WouldBlock, "PTY session reaper capacity exhausted")
            })?;
        Ok(ReservedChildReaperLease {
            sender: self.sender.clone(),
            active: self.active.clone(),
            degraded: self.degraded.clone(),
        })
    }
}

pub(crate) fn reserve_child_reaper() -> io::Result<ReservedChildReaperLease> {
    let mut slot = NATURAL_REAPER.get_or_init(|| Mutex::new(None)).lock().unwrap();
    if slot.is_none() {
        *slot = Some(NaturalReaper::start()?);
    }
    slot.as_ref().expect("natural PTY reaper initialized").lease()
}

pub(crate) fn wake_child_reaper() {
    let Some(slot) = NATURAL_REAPER.get() else { return };
    let slot = slot.lock().unwrap();
    let Some(reaper) = slot.as_ref() else { return };
    if !reaper.wake_pending.swap(true, Ordering::AcqRel) {
        let _ = reaper.sender.send(NaturalReaperCommand::Wake);
    }
}

pub(crate) fn enqueue_reserved_session_leader(
    lease: ReservedChildReaperLease,
    session: libc::pid_t,
    cleanup_timeout: Duration,
    needs_cleanup: impl Fn() -> bool + Send + 'static,
    prepare_cleanup: impl FnMut() -> bool + Send + 'static,
    finish: impl FnMut(bool) -> bool + Send + 'static,
) {
    let sender = lease.sender.clone();
    sender
        .send(NaturalReaperCommand::Add(NaturalReapRequest {
            session,
            cleanup_timeout,
            needs_cleanup: Box::new(needs_cleanup),
            prepare_cleanup: Box::new(prepare_cleanup),
            finish: Box::new(finish),
            _lease: lease,
            next_attempt: Instant::now(),
            retry_delay: NATURAL_REAP_RETRY_INITIAL,
            attempts: 0,
            degraded: false,
        }))
        .expect("natural PTY reaper remains alive while its service is registered");
}

pub(crate) fn reserved_child_needs_cleanup(sync: ReservedChildReap<'_>) -> bool {
    let _signal = sync.signal_lock.lock().unwrap();
    !sync.cleanup_complete.load(Ordering::Acquire)
        && !sync.termination_started.load(Ordering::Acquire)
}

pub(crate) fn poll_reserved_session_leader(
    sync: ReservedChildReap<'_>,
    cleanup_succeeded: bool,
    reap: impl FnOnce(),
) -> bool {
    let _signal = sync.signal_lock.lock().unwrap();
    if !sync.cleanup_complete.load(Ordering::Acquire) {
        if sync.termination_started.load(Ordering::Acquire) || !cleanup_succeeded {
            return false;
        }
        sync.cleanup_complete.store(true, Ordering::Release);
    }
    if !sync.pty_drained.load(Ordering::Acquire) {
        return false;
    }
    reap();
    sync.child_reaped.store(true, Ordering::Release);
    true
}

fn run_natural_reaper(
    receiver: mpsc::Receiver<NaturalReaperCommand>,
    wake_pending: Arc<AtomicBool>,
) {
    let mut pending = Vec::<NaturalReapRequest>::new();
    loop {
        let received = if pending.is_empty() {
            receiver.recv().map_err(|_| RecvTimeoutError::Disconnected)
        } else {
            let now = Instant::now();
            let wait = pending
                .iter()
                .map(|request| request.next_attempt.saturating_duration_since(now))
                .min()
                .unwrap_or(NATURAL_REAP_RETRY_MAX);
            receiver.recv_timeout(wait)
        };
        match received {
            Ok(command) => {
                accept_natural_reaper_command(command, &mut pending, wake_pending.as_ref());
            }
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) if pending.is_empty() => return,
            Err(RecvTimeoutError::Disconnected) => {
                std::thread::sleep(NATURAL_REAP_RETRY_MAX);
            }
        }

        let batch_deadline = Instant::now() + NATURAL_REAP_BATCH_WINDOW;
        while let Some(remaining) = batch_deadline.checked_duration_since(Instant::now()) {
            match receiver.recv_timeout(remaining) {
                Ok(command) => {
                    accept_natural_reaper_command(command, &mut pending, wake_pending.as_ref());
                }
                Err(RecvTimeoutError::Timeout | RecvTimeoutError::Disconnected) => break,
            }
        }

        let now = Instant::now();
        let mut due = Vec::new();
        let mut index = 0;
        while index < pending.len() {
            if pending[index].next_attempt <= now {
                due.push(pending.swap_remove(index));
            } else {
                index += 1;
            }
        }
        if due.is_empty() {
            continue;
        }

        let needs_cleanup = due.iter().map(|request| (request.needs_cleanup)()).collect::<Vec<_>>();
        let prepared = due
            .iter_mut()
            .zip(&needs_cleanup)
            .map(|(request, needed)| !needed || (request.prepare_cleanup)())
            .collect::<Vec<_>>();
        let sessions = due
            .iter()
            .zip(needs_cleanup.iter().zip(&prepared))
            .filter_map(|(request, (needed, prepared))| {
                (*needed && *prepared).then_some(request.session)
            })
            .collect::<HashSet<_>>();
        let cleanup_timeout = due
            .iter()
            .zip(&needs_cleanup)
            .filter_map(|(request, needed)| needed.then_some(request.cleanup_timeout))
            .max()
            .unwrap_or_default();
        let cleanup_deadline = Instant::now() + cleanup_timeout;
        let cleaned = if sessions.is_empty() {
            HashSet::new()
        } else {
            SessionProcessSnapshot::capture(sessions.iter().copied(), cleanup_deadline)
                .map(|snapshot| {
                    kill_sessions_until_only_leaders_from_snapshot(
                        &snapshot,
                        &sessions,
                        cleanup_deadline,
                    )
                })
                .unwrap_or_default()
        };

        for ((mut request, needed), prepared) in due.into_iter().zip(needs_cleanup).zip(prepared) {
            let cleanup_succeeded = needed && prepared && cleaned.contains(&request.session);
            let done = (request.finish)(cleanup_succeeded);
            if done {
                if request.degraded {
                    request._lease.degraded.fetch_sub(1, Ordering::AcqRel);
                }
                continue;
            }
            if needed {
                request.attempts = request.attempts.saturating_add(1);
            }
            if request.attempts >= NATURAL_REAP_MAX_ATTEMPTS {
                if !request.degraded {
                    request.degraded = true;
                    request._lease.degraded.fetch_add(1, Ordering::AcqRel);
                }
                request.next_attempt = Instant::now() + NATURAL_REAP_DEGRADED_RETRY;
            } else {
                request.next_attempt = Instant::now() + request.retry_delay;
                request.retry_delay = (request.retry_delay * 2).min(NATURAL_REAP_RETRY_MAX);
            }
            pending.push(request);
        }
    }
}

fn kill_sessions_until_only_leaders_from_snapshot(
    snapshot: &SessionProcessSnapshot,
    sessions: &HashSet<libc::pid_t>,
    deadline: Instant,
) -> HashSet<libc::pid_t> {
    let mut states = HashMap::<libc::pid_t, (u64, Vec<libc::pid_t>)>::new();
    let mut failed = HashSet::new();
    for session in sessions {
        match snapshot.members(*session) {
            Ok((generation, members)) => {
                if signal_members(&members, *session, None).is_ok() {
                    states.insert(*session, (generation, members));
                } else {
                    failed.insert(*session);
                }
            }
            Err(_) => {
                failed.insert(*session);
            }
        }
    }

    let mut complete = HashSet::new();
    while complete.len() + failed.len() < sessions.len() && Instant::now() < deadline {
        let mut refresh = Vec::new();
        for (session, (_, members)) in &states {
            if complete.contains(session) || failed.contains(session) {
                continue;
            }
            let drained = members
                .iter()
                .copied()
                .filter(|pid| pid != session)
                .map(|pid| still_member(pid, *session))
                .collect::<io::Result<Vec<_>>>()
                .map(|members| members.into_iter().all(|alive| !alive));
            match drained {
                Ok(true) => refresh.push(*session),
                Ok(false) => {}
                Err(_) => {
                    failed.insert(*session);
                }
            }
        }

        if let Some(first) = refresh.first().copied() {
            let observed_generation = states[&first].0;
            if snapshot.refresh_members(first, observed_generation, deadline).is_err() {
                break;
            }
            for session in refresh {
                let Ok((generation, members)) = snapshot.members(session) else {
                    failed.insert(session);
                    continue;
                };
                if members.iter().all(|pid| *pid == session) {
                    complete.insert(session);
                    continue;
                }
                if signal_members(&members, session, None).is_err() {
                    failed.insert(session);
                    continue;
                }
                states.insert(session, (generation, members));
            }
        }

        if complete.len() + failed.len() < sessions.len() {
            std::thread::sleep(
                deadline.saturating_duration_since(Instant::now()).min(SESSION_KILL_POLL),
            );
        }
    }
    complete
}

fn accept_natural_reaper_command(
    command: NaturalReaperCommand,
    pending: &mut Vec<NaturalReapRequest>,
    wake_pending: &AtomicBool,
) {
    match command {
        NaturalReaperCommand::Add(request) => pending.push(request),
        NaturalReaperCommand::Wake => {
            wake_pending.store(false, Ordering::Release);
            let now = Instant::now();
            for request in pending {
                request.next_attempt = now;
            }
        }
    }
}

#[cfg(test)]
thread_local! {
    static PROCESS_TABLE_SCAN_COUNT: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
    static STABLE_PROCESS_PREFLIGHT_COUNT: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
    static RAW_PID_SIGNAL_COUNT: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
    static STABLE_PROCESS_SIGNAL_COUNT: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
}

#[cfg(test)]
pub(crate) fn reset_stable_process_preflight_count_for_test() {
    STABLE_PROCESS_PREFLIGHT_COUNT.set(0);
}

#[cfg(test)]
pub(crate) fn stable_process_preflight_count_for_test() -> usize {
    STABLE_PROCESS_PREFLIGHT_COUNT.get()
}

pub(crate) struct SessionProcessSnapshot {
    sessions: HashSet<libc::pid_t>,
    state: Mutex<SessionProcessSnapshotState>,
    refreshed: Condvar,
    #[cfg(test)]
    scan_count: AtomicUsize,
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
            scan_count: AtomicUsize::new(usize::from(has_sessions)),
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
    let Some(process) = stable_process_in_session(pid, session)? else {
        return Ok(());
    };
    let _ = process.signal(signal)?;
    Ok(())
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

fn stable_process_in_session(
    pid: libc::pid_t,
    session: libc::pid_t,
) -> io::Result<Option<StableProcessHandle>> {
    let Some(process) = StableProcessHandle::capture(pid)? else { return Ok(None) };
    // Bracket the PID-based session query with a stable process identity. If
    // the PID is recycled during getsid(2), the final identity check fails
    // closed and no signal is sent.
    let current_session = unsafe { libc::getsid(pid) };
    if current_session < 0 {
        let error = io::Error::last_os_error();
        return if error.raw_os_error() == Some(libc::ESRCH) { Ok(None) } else { Err(error) };
    }
    if current_session != session || !process.matches_current()? {
        return Ok(None);
    }
    Ok(Some(process))
}

#[cfg(target_os = "macos")]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
/// An OS-backed reference to one process instance that cannot retarget after PID reuse.
pub struct StableProcessHandle {
    pid: libc::pid_t,
    audit_token: MacAuditToken,
}

#[cfg(target_os = "macos")]
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct MacAuditToken {
    values: [u32; 8],
}

#[cfg(target_os = "macos")]
impl StableProcessHandle {
    /// Capture the process currently using `pid`, or return `None` if it is already gone.
    pub fn capture(pid: libc::pid_t) -> io::Result<Option<Self>> {
        const TASK_AUDIT_TOKEN: libc::task_flavor_t = 15;
        let mut task = 0;
        // SAFETY: mach_task_self returns the calling process's send right.
        #[allow(deprecated)]
        let current_task = unsafe { libc::mach_task_self() };
        // SAFETY: `task` points to writable storage for one task-name right.
        let name_result = unsafe { task_name_for_pid(current_task, pid, &mut task) };
        if name_result != libc::KERN_SUCCESS {
            return if process_is_gone(pid)? {
                Ok(None)
            } else {
                Err(io::Error::other(format!(
                    "cannot acquire stable process identity for PID {pid}: Mach error {name_result}"
                )))
            };
        }

        let mut audit_token = MacAuditToken { values: [0; 8] };
        let mut count = u32::try_from(size_of::<MacAuditToken>() / size_of::<libc::natural_t>())
            .expect("audit token count fits mach_msg_type_number_t");
        // SAFETY: the token buffer contains `count` natural_t values and the
        // returned task-name right remains owned until the call completes.
        let info_result = unsafe {
            libc::task_info(
                task,
                TASK_AUDIT_TOKEN,
                audit_token.values.as_mut_ptr().cast::<libc::integer_t>(),
                &mut count,
            )
        };
        // SAFETY: `task` is the send right returned by task_name_for_pid.
        let _ = unsafe { mach_port_deallocate(current_task, task) };
        if info_result != libc::KERN_SUCCESS {
            return if process_is_gone(pid)? {
                Ok(None)
            } else {
                Err(io::Error::other(format!(
                    "cannot read stable process identity for PID {pid}: Mach error {info_result}"
                )))
            };
        }
        let expected_pid = u32::try_from(pid)
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "invalid process id"))?;
        if count != 8 || audit_token.values[5] != expected_pid {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "stable process identity returned a mismatched PID",
            ));
        }
        Ok(Some(Self { pid, audit_token }))
    }

    /// Return whether this exact process instance is still alive.
    pub fn matches_current(&self) -> io::Result<bool> {
        Ok(Self::capture(self.pid)?.is_some_and(|current| current == *self))
    }

    /// Signal this exact process instance, returning false if it is already gone.
    pub fn signal(&self, signal: libc::c_int) -> io::Result<bool> {
        let mut token = self.audit_token;
        loop {
            // SAFETY: the audit token came from TASK_AUDIT_TOKEN for this
            // process instance; libproc validates its PID generation.
            let result = unsafe { proc_signal_with_audittoken(&mut token, signal) };
            if result == 0 {
                #[cfg(test)]
                STABLE_PROCESS_SIGNAL_COUNT.set(STABLE_PROCESS_SIGNAL_COUNT.get() + 1);
                return Ok(true);
            }
            if result == libc::ESRCH {
                #[cfg(test)]
                STABLE_PROCESS_SIGNAL_COUNT.set(STABLE_PROCESS_SIGNAL_COUNT.get() + 1);
                return Ok(false);
            }
            if result != libc::EINTR {
                return Err(io::Error::from_raw_os_error(result));
            }
        }
    }
}

#[cfg(target_os = "macos")]
fn process_is_gone(pid: libc::pid_t) -> io::Result<bool> {
    // SAFETY: signal zero performs a non-mutating liveness/permission probe.
    if unsafe { libc::kill(pid, 0) } == 0 {
        return Ok(false);
    }
    let error = io::Error::last_os_error();
    match error.raw_os_error() {
        Some(libc::ESRCH) => Ok(true),
        Some(libc::EPERM) => Ok(false),
        _ => Err(error),
    }
}

#[cfg(target_os = "macos")]
unsafe extern "C" {
    fn task_name_for_pid(
        target_task: libc::mach_port_t,
        pid: libc::pid_t,
        task: *mut libc::mach_port_t,
    ) -> libc::kern_return_t;
    fn mach_port_deallocate(
        task: libc::mach_port_t,
        name: libc::mach_port_t,
    ) -> libc::kern_return_t;
}

#[cfg(target_os = "macos")]
#[link(name = "proc")]
unsafe extern "C" {
    fn proc_signal_with_audittoken(token: *mut MacAuditToken, signal: libc::c_int) -> libc::c_int;
}

#[cfg(target_os = "linux")]
#[derive(Debug)]
/// An OS-backed reference to one process instance that cannot retarget after PID reuse.
pub struct StableProcessHandle {
    process_fd: std::os::fd::OwnedFd,
}

#[cfg(target_os = "linux")]
impl StableProcessHandle {
    /// Capture the process currently using `pid`, or return `None` if it is already gone.
    pub fn capture(pid: libc::pid_t) -> io::Result<Option<Self>> {
        use std::os::fd::FromRawFd;

        // SAFETY: pidfd_open receives a validated integer PID and zero flags.
        let descriptor = unsafe { libc::syscall(libc::SYS_pidfd_open, pid, 0) };
        if descriptor >= 0 {
            let descriptor = i32::try_from(descriptor)
                .map_err(|_| io::Error::other("pidfd descriptor is out of range"))?;
            // SAFETY: a successful pidfd_open returns one newly owned descriptor.
            return Ok(Some(Self {
                process_fd: unsafe { std::os::fd::OwnedFd::from_raw_fd(descriptor) },
            }));
        }
        let pidfd_error = io::Error::last_os_error();
        if pidfd_error.raw_os_error() == Some(libc::ESRCH) {
            return Ok(None);
        }

        // Linux 5.1 and 5.2 predate pidfd_open but pidfd_send_signal accepts
        // an open /proc/PID directory as the same exact process reference.
        match std::fs::File::open(format!("/proc/{pid}")) {
            Ok(process_directory) => Ok(Some(Self { process_fd: process_directory.into() })),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(io::Error::new(
                error.kind(),
                format!(
                    "cannot acquire stable process identity: pidfd_open failed ({pidfd_error}); \
                     /proc fallback failed ({error})"
                ),
            )),
        }
    }

    /// Return whether this exact process instance is still alive.
    pub fn matches_current(&self) -> io::Result<bool> {
        self.signal_result(0)
    }

    /// Signal this exact process instance, returning false if it is already gone.
    pub fn signal(&self, signal: libc::c_int) -> io::Result<bool> {
        let signaled = self.signal_result(signal)?;
        #[cfg(test)]
        STABLE_PROCESS_SIGNAL_COUNT.set(STABLE_PROCESS_SIGNAL_COUNT.get() + 1);
        Ok(signaled)
    }

    fn signal_result(&self, signal: libc::c_int) -> io::Result<bool> {
        use std::os::fd::AsRawFd;

        // SAFETY: the descriptor is a live pidfd, the siginfo pointer is
        // intentionally null, and flags must be zero.
        let result = unsafe {
            libc::syscall(
                libc::SYS_pidfd_send_signal,
                self.process_fd.as_raw_fd(),
                signal,
                std::ptr::null::<libc::siginfo_t>(),
                0,
            )
        };
        if result == 0 {
            return Ok(true);
        }
        let error = io::Error::last_os_error();
        if error.raw_os_error() == Some(libc::ESRCH) { Ok(false) } else { Err(error) }
    }
}

/// Verify that this runtime can enumerate PTY session members and signal exact
/// process instances before any PTY is spawned or shutdown topology mutates.
pub fn require_stable_process_signaling() -> io::Result<()> {
    require_stable_process_signaling_until(Instant::now() + PROCESS_SESSION_PREFLIGHT_TIMEOUT)
}

/// Cache the process-level capability once per server generation. Startup,
/// identity responses, and PTY creation share this result; shutdown still
/// performs a fresh bounded preflight immediately before mutating topology.
pub(crate) fn initialize_stable_process_signaling() {
    let _ = stable_process_signaling();
}

pub(crate) fn require_cached_stable_process_signaling() -> io::Result<()> {
    stable_process_signaling().as_ref().map_err(StableProcessSignalingFailure::to_error).copied()
}

fn stable_process_signaling() -> &'static Result<(), StableProcessSignalingFailure> {
    STABLE_PROCESS_SIGNALING.get_or_init(|| {
        require_stable_process_signaling().map_err(StableProcessSignalingFailure::from_error)
    })
}

pub(crate) fn require_stable_process_signaling_until(deadline: Instant) -> io::Result<()> {
    #[cfg(test)]
    STABLE_PROCESS_PREFLIGHT_COUNT.set(STABLE_PROCESS_PREFLIGHT_COUNT.get() + 1);
    #[cfg(test)]
    if FORCE_PROCESS_SESSION_PREFLIGHT_FAILURE.get() {
        return Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "forced process-session preflight failure",
        ));
    }
    let pid = libc::pid_t::try_from(std::process::id())
        .map_err(|_| io::Error::new(io::ErrorKind::Unsupported, "invalid process id"))?;
    let process = StableProcessHandle::capture(pid)?.ok_or_else(|| {
        io::Error::new(io::ErrorKind::Unsupported, "current process identity is unavailable")
    })?;
    match process.matches_current() {
        Ok(true) => {}
        Ok(false) => {
            return Err(io::Error::new(
                io::ErrorKind::Unsupported,
                "stable process signaling did not retain the current process",
            ));
        }
        Err(error) => {
            return Err(io::Error::new(
                io::ErrorKind::Unsupported,
                format!("stable process signaling is unavailable: {error}"),
            ));
        }
    }
    all_process_ids(Some(deadline)).map(|_| ()).map_err(|error| {
        io::Error::new(
            io::ErrorKind::Unsupported,
            format!("PTY session enumeration is unavailable: {error}"),
        )
    })
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
/// Placeholder on platforms without stable process signaling.
pub struct StableProcessHandle;

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
impl StableProcessHandle {
    /// Report that stable process handles are unsupported on this platform.
    pub fn capture(_pid: libc::pid_t) -> io::Result<Option<Self>> {
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "stable process signaling is unavailable on this platform",
        ))
    }

    /// Return false because no stable process handle is available.
    pub fn matches_current(&self) -> io::Result<bool> {
        Ok(false)
    }

    /// Report that stable process signaling is unsupported on this platform.
    pub fn signal(&self, _signal: libc::c_int) -> io::Result<bool> {
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "stable process signaling is unavailable on this platform",
        ))
    }
}

#[cfg(all(target_os = "macos", test))]
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

    #[cfg(any(target_os = "macos", target_os = "linux"))]
    #[test]
    fn natural_cleanup_does_not_wait_for_pty_drain() {
        let signal_lock = Mutex::new(());
        let pty_drained = AtomicBool::new(false);
        let termination_started = AtomicBool::new(false);
        let cleanup_complete = AtomicBool::new(false);
        let child_reaped = AtomicBool::new(false);
        let reap_called = AtomicBool::new(false);
        let sync = || ReservedChildReap {
            signal_lock: &signal_lock,
            pty_drained: &pty_drained,
            termination_started: &termination_started,
            cleanup_complete: &cleanup_complete,
            child_reaped: &child_reaped,
        };

        assert!(
            reserved_child_needs_cleanup(sync()),
            "a descendant holding the PTY open prevented its own cleanup"
        );
        assert!(
            !poll_reserved_session_leader(sync(), true, || {
                reap_called.store(true, Ordering::Release);
            }),
            "the session leader was reaped before the PTY reader drained"
        );
        assert!(
            cleanup_complete.load(Ordering::Acquire),
            "successful descendant cleanup was not recorded before PTY drain"
        );
        assert!(!child_reaped.load(Ordering::Acquire));
        assert!(!reap_called.load(Ordering::Acquire));

        pty_drained.store(true, Ordering::Release);
        assert!(poll_reserved_session_leader(sync(), false, || {
            reap_called.store(true, Ordering::Release);
        }));
        assert!(child_reaped.load(Ordering::Acquire));
        assert!(reap_called.load(Ordering::Acquire));
    }

    #[cfg(target_os = "linux")]
    fn enter_syscall_blocked_subprocess(
        child_env: &str,
        test_name: &str,
        syscalls: &[libc::c_long],
    ) -> bool {
        if std::env::var_os(child_env).is_none() {
            let status = Command::new(std::env::current_exe().unwrap())
                .args(["--exact", test_name])
                .env(child_env, "1")
                .status()
                .unwrap();
            assert!(status.success(), "pidfd compatibility subprocess failed: {status}");
            return false;
        }

        let mut filter = vec![libc::sock_filter {
            code: u16::try_from(libc::BPF_LD | libc::BPF_W | libc::BPF_ABS).unwrap(),
            jt: 0,
            jf: 0,
            k: 0,
        }];
        for syscall in syscalls {
            filter.extend([
                libc::sock_filter {
                    code: u16::try_from(libc::BPF_JMP | libc::BPF_JEQ | libc::BPF_K).unwrap(),
                    jt: 0,
                    jf: 1,
                    k: u32::try_from(*syscall).unwrap(),
                },
                libc::sock_filter {
                    code: u16::try_from(libc::BPF_RET | libc::BPF_K).unwrap(),
                    jt: 0,
                    jf: 0,
                    k: libc::SECCOMP_RET_ERRNO | u32::try_from(libc::ENOSYS).unwrap(),
                },
            ]);
        }
        filter.push(libc::sock_filter {
            code: u16::try_from(libc::BPF_RET | libc::BPF_K).unwrap(),
            jt: 0,
            jf: 0,
            k: libc::SECCOMP_RET_ALLOW,
        });
        let program = libc::sock_fprog {
            len: u16::try_from(filter.len()).unwrap(),
            filter: filter.as_mut_ptr(),
        };
        // SAFETY: this one-test subprocess opts into a filter whose backing
        // instructions remain live for the prctl call.
        assert_eq!(unsafe { libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) }, 0);
        // SAFETY: `program` describes the initialized filter above.
        let installed = unsafe {
            libc::prctl(
                libc::PR_SET_SECCOMP,
                libc::SECCOMP_MODE_FILTER,
                std::ptr::from_ref(&program),
            )
        };
        assert_eq!(
            installed,
            0,
            "could not install pidfd test filter: {}",
            io::Error::last_os_error()
        );
        true
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
        STABLE_PROCESS_SIGNAL_COUNT.set(0);

        signal_until(session, libc::SIGCONT, Instant::now() + Duration::from_secs(1)).unwrap();
        let raw_signals = RAW_PID_SIGNAL_COUNT.get();
        let stable_signals = STABLE_PROCESS_SIGNAL_COUNT.get();

        child.kill().unwrap();
        child.wait().unwrap();
        assert_eq!(
            raw_signals, 0,
            "session cleanup used a reusable PID instead of a stable process identity"
        );
        assert_eq!(stable_signals, 1, "session cleanup did not use the stable process handle");
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn pidfd_open_denial_uses_an_exact_proc_handle() {
        const CHILD_ENV: &str = "CMUX_TUI_TEST_BLOCK_PIDFD_OPEN";
        if !enter_syscall_blocked_subprocess(
            CHILD_ENV,
            "process_session::tests::pidfd_open_denial_uses_an_exact_proc_handle",
            &[libc::SYS_pidfd_open],
        ) {
            return;
        }

        let pid = libc::pid_t::try_from(std::process::id()).unwrap();
        let process = StableProcessHandle::capture(pid).unwrap().unwrap();
        assert!(process.matches_current().unwrap());
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn missing_exact_signal_support_fails_the_runtime_preflight() {
        const CHILD_ENV: &str = "CMUX_TUI_TEST_BLOCK_PIDFD_SIGNALING";
        if !enter_syscall_blocked_subprocess(
            CHILD_ENV,
            "process_session::tests::missing_exact_signal_support_fails_the_runtime_preflight",
            &[libc::SYS_pidfd_open, libc::SYS_pidfd_send_signal],
        ) {
            return;
        }

        let error = require_stable_process_signaling().unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::Unsupported);
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn missing_process_enumeration_fails_the_runtime_preflight() {
        const CHILD_ENV: &str = "CMUX_TUI_TEST_BLOCK_PROCESS_ENUMERATION";
        if !enter_syscall_blocked_subprocess(
            CHILD_ENV,
            "process_session::tests::missing_process_enumeration_fails_the_runtime_preflight",
            &[libc::SYS_getdents64],
        ) {
            return;
        }

        let error = require_stable_process_signaling().unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::Unsupported);
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
        let snapshot =
            Arc::new(SessionProcessSnapshot::capture(sessions.clone(), deadline).unwrap());
        let barrier = Arc::new(std::sync::Barrier::new(sessions.len()));

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

    #[cfg(any(target_os = "macos", target_os = "linux"))]
    #[test]
    fn natural_reap_batch_refreshes_all_sessions_with_one_scan() {
        let mut children = [spawn_session_child(), spawn_session_child()];
        let sessions = children
            .iter()
            .map(|child| libc::pid_t::try_from(child.id()).unwrap())
            .collect::<HashSet<_>>();
        let deadline = Instant::now() + Duration::from_secs(1);
        let snapshot = SessionProcessSnapshot::capture(sessions.iter().copied(), deadline).unwrap();

        let completed =
            kill_sessions_until_only_leaders_from_snapshot(&snapshot, &sessions, deadline);
        let scan_count = snapshot.scan_count();

        for child in &mut children {
            child.wait().unwrap();
        }
        assert_eq!(completed, sessions);
        assert_eq!(scan_count, 2, "one natural-reap batch did not share its reconciliation scan");
    }
}
