//! Bounded Unix process cleanup for short-lived child commands.
//!
//! A process group covers normal descendants. Two command-local identities
//! cover daemon detach behavior: an environment marker survives
//! `closefrom(2)`, and an inherited file marker survives environment
//! replacement. One process-wide tracker scans all active scopes together at
//! a fixed maximum rate, follows known parent-child lineage, and records exact
//! process identities before cleanup. Each scan has process and descriptor
//! work limits. Cleanup requests one tracker-owned final scan when its budget
//! permits; an expired command deadline never starts a process-table scan.

use std::collections::{HashMap, HashSet};
use std::fs::OpenOptions;
use std::io;
use std::mem::size_of;
#[cfg(target_os = "linux")]
use std::os::fd::FromRawFd;
use std::os::fd::{AsRawFd, OwnedFd};
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::process::CommandExt;
use std::process::Command;
use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::time::{Duration, Instant};

const CLEANUP_DEADLINE: Duration = Duration::from_millis(250);
const TRACK_INTERVAL: Duration = Duration::from_millis(100);
const MAX_TRACKED_PROCESSES: usize = 256;
const MAX_SCAN_PROCESSES: usize = 16_384;
const MAX_SCAN_FILE_DESCRIPTORS: usize = 65_536;
const PROCESS_SCOPE_ENV: &str = "CMUX_TUI_PROCESS_SCOPE";

#[derive(Clone, Copy, Debug, Hash, PartialEq, Eq)]
struct ProcessIdentity {
    pid: u32,
    started: u128,
}

#[derive(Clone, Copy, Debug, Hash, PartialEq, Eq)]
struct FileMarker {
    device: u64,
    inode: u64,
}

struct ScopeTracker {
    registration: u64,
    registry: Arc<ProcessScopeTracker>,
}

struct TrackedProcesses {
    active: bool,
    #[cfg(target_os = "linux")]
    identities: HashMap<ProcessIdentity, OwnedFd>,
    #[cfg(not(target_os = "linux"))]
    identities: HashSet<ProcessIdentity>,
}

impl Default for TrackedProcesses {
    fn default() -> Self {
        Self {
            active: true,
            #[cfg(target_os = "linux")]
            identities: HashMap::new(),
            #[cfg(not(target_os = "linux"))]
            identities: HashSet::new(),
        }
    }
}

#[derive(Clone)]
struct ScopeRegistration {
    marker: String,
    file_marker: FileMarker,
    root: ProcessIdentity,
    tracked: Arc<Mutex<TrackedProcesses>>,
    tracked_changed: Arc<Condvar>,
}

#[derive(Default)]
struct ProcessScopeTrackerState {
    next_registration: u64,
    revision: u64,
    scopes: HashMap<u64, ScopeRegistration>,
    finalizing: HashSet<u64>,
}

#[derive(Default)]
struct ProcessScopeTracker {
    state: Mutex<ProcessScopeTrackerState>,
    changed: Condvar,
    started: Mutex<bool>,
}

/// Owns one process group and the private identities used to find descendants
/// that leave that group.
pub struct UnixProcessScope {
    marker: String,
    _marker_fd: OwnedFd,
    file_marker: FileMarker,
    root: Option<ProcessIdentity>,
    #[cfg(target_os = "linux")]
    root_pidfd: Option<OwnedFd>,
    tracked: Arc<Mutex<TrackedProcesses>>,
    tracked_changed: Arc<Condvar>,
    tracker: Option<ScopeTracker>,
    terminated: bool,
}

impl UnixProcessScope {
    /// Allocate command-local identities before the command is spawned.
    pub fn prepare() -> io::Result<Self> {
        let mut random = [0_u8; 16];
        getrandom::fill(&mut random)
            .map_err(|error| io::Error::other(format!("allocate process scope: {error}")))?;
        let marker = random.iter().map(|byte| format!("{byte:02x}")).collect::<String>();
        let (marker_fd, file_marker) = create_file_marker(&marker)?;
        Ok(Self {
            marker,
            _marker_fd: marker_fd,
            file_marker,
            root: None,
            #[cfg(target_os = "linux")]
            root_pidfd: None,
            tracked: Arc::new(Mutex::new(TrackedProcesses::default())),
            tracked_changed: Arc::new(Condvar::new()),
            tracker: None,
            terminated: false,
        })
    }

    /// Select this command as the only child that receives the scope
    /// identities. The file was opened with `O_CLOEXEC`, so unrelated
    /// concurrent spawns cannot inherit it.
    pub fn configure(&self, command: &mut Command) {
        command.env(PROCESS_SCOPE_ENV, &self.marker);
        let marker_fd = self._marker_fd.as_raw_fd();
        // SAFETY: the closure calls only async-signal-safe fcntl(2) operations
        // between fork and exec and does not allocate.
        unsafe {
            command.pre_exec(move || {
                let flags = libc::fcntl(marker_fd, libc::F_GETFD);
                if flags < 0 || libc::fcntl(marker_fd, libc::F_SETFD, flags & !libc::FD_CLOEXEC) < 0
                {
                    return Err(io::Error::last_os_error());
                }
                Ok(())
            });
        }
    }

    /// Record the exact root identity and start holder discovery while the
    /// command still owns its execution budget.
    pub fn bind(&mut self, root: u32) -> io::Result<()> {
        self.root = Some(process_identity(root).ok_or_else(|| {
            io::Error::new(io::ErrorKind::NotFound, "process scope root is unavailable")
        })?);
        #[cfg(target_os = "linux")]
        {
            self.root_pidfd = Some(pidfd_open(root)?);
        }
        self.start_tracker()
    }

    /// Kill the original group and every recorded descendant within the
    /// default cleanup interval.
    pub fn terminate(&mut self) {
        self.terminate_until(Instant::now() + CLEANUP_DEADLINE);
    }

    /// Kill the original group and every recorded descendant without starting
    /// process discovery after the caller's absolute deadline.
    pub fn terminate_until(&mut self, deadline: Instant) {
        if self.terminated {
            return;
        }
        self.terminated = true;
        self.terminate_root_group();
        self.signal_tracked();
        if let Some(tracker) = self.tracker.take() {
            self.deactivate_and_signal_tracked();
            tracker.registry.finalize(tracker.registration, deadline);
        } else {
            self.deactivate_and_signal_tracked();
        }
    }

    fn start_tracker(&mut self) -> io::Result<()> {
        let root = self.root.ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidInput, "process scope is unbound")
        })?;
        let registry = process_scope_tracker();
        let registration = registry.register(ScopeRegistration {
            marker: self.marker.clone(),
            file_marker: self.file_marker,
            root,
            tracked: self.tracked.clone(),
            tracked_changed: self.tracked_changed.clone(),
        })?;
        self.tracker = Some(ScopeTracker { registration, registry });
        Ok(())
    }

    #[cfg(all(test, target_os = "linux"))]
    pub(crate) fn wait_until_tracked_for_test(&self, pid: u32, deadline: Instant) -> bool {
        let mut tracked = self.tracked.lock().unwrap();
        loop {
            if tracked.identities.keys().any(|identity| identity.pid == pid) {
                return true;
            }
            let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
                return false;
            };
            let (next, timeout) = self.tracked_changed.wait_timeout(tracked, remaining).unwrap();
            tracked = next;
            if timeout.timed_out() && !tracked.identities.keys().any(|identity| identity.pid == pid)
            {
                return false;
            }
        }
    }

    #[cfg(all(test, not(target_os = "linux")))]
    pub(crate) fn wait_until_tracked_for_test(&self, pid: u32, deadline: Instant) -> bool {
        let mut tracked = self.tracked.lock().unwrap();
        loop {
            if tracked.identities.iter().any(|identity| identity.pid == pid) {
                return true;
            }
            let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
                return false;
            };
            let (next, timeout) = self.tracked_changed.wait_timeout(tracked, remaining).unwrap();
            tracked = next;
            if timeout.timed_out() && !tracked.identities.iter().any(|identity| identity.pid == pid)
            {
                return false;
            }
        }
    }

    #[cfg(target_os = "linux")]
    fn signal_tracked(&self) {
        let Ok(tracked) = self.tracked.try_lock() else { return };
        for (identity, pidfd) in tracked.identities.iter() {
            if identity.pid != std::process::id() && Some(*identity) != self.root {
                let _ = pidfd_send_signal(pidfd, libc::SIGKILL);
            }
        }
    }

    #[cfg(not(target_os = "linux"))]
    fn signal_tracked(&self) {
        let Ok(tracked) = self.tracked.try_lock() else { return };
        for identity in tracked.identities.iter().copied() {
            if identity.pid != std::process::id() && Some(identity) != self.root {
                signal_process(identity);
            }
        }
    }

    /// Close tracker admission and signal the complete handed-off set while
    /// holding the same mutex used by insertion. An in-flight shared scan
    /// signals a late match directly instead of inserting it after this pass.
    #[cfg(target_os = "linux")]
    fn deactivate_and_signal_tracked(&self) {
        let mut tracked = self.tracked.lock().unwrap();
        tracked.active = false;
        for (identity, pidfd) in tracked.identities.iter() {
            if identity.pid != std::process::id() && Some(*identity) != self.root {
                let _ = pidfd_send_signal(pidfd, libc::SIGKILL);
            }
        }
    }

    #[cfg(not(target_os = "linux"))]
    fn deactivate_and_signal_tracked(&self) {
        let mut tracked = self.tracked.lock().unwrap();
        tracked.active = false;
        for identity in tracked.identities.iter().copied() {
            if identity.pid != std::process::id() && Some(identity) != self.root {
                signal_process(identity);
            }
        }
    }

    #[cfg(target_os = "linux")]
    fn terminate_root_group(&self) {
        let (Some(root), Some(pidfd)) = (self.root, self.root_pidfd.as_ref()) else { return };
        if process_identity(root.pid) != Some(root) {
            return;
        }
        // Stop the exact pidfd-owned root before addressing its numeric process
        // group. While that root is stopped and alive, its PID/PGID cannot be
        // reused by an unrelated process between verification and killpg(2).
        if pidfd_send_signal(pidfd, libc::SIGSTOP).is_err() {
            return;
        }
        if let Ok(group) = libc::pid_t::try_from(root.pid) {
            unsafe {
                libc::kill(-group, libc::SIGKILL);
            }
        }
        let _ = pidfd_send_signal(pidfd, libc::SIGKILL);
    }

    #[cfg(not(target_os = "linux"))]
    fn terminate_root_group(&self) {
        let Some(root) = self.root else { return };
        if process_identity(root.pid) != Some(root) {
            return;
        }
        if let Ok(group) = libc::pid_t::try_from(root.pid) {
            unsafe {
                libc::kill(-group, libc::SIGKILL);
            }
        }
    }
}

impl Drop for UnixProcessScope {
    fn drop(&mut self) {
        self.terminate();
    }
}

fn process_scope_tracker() -> Arc<ProcessScopeTracker> {
    static TRACKER: OnceLock<Arc<ProcessScopeTracker>> = OnceLock::new();
    TRACKER.get_or_init(|| Arc::new(ProcessScopeTracker::default())).clone()
}

impl ProcessScopeTracker {
    fn register(self: &Arc<Self>, scope: ScopeRegistration) -> io::Result<u64> {
        self.ensure_started()?;
        let mut state = self.state.lock().unwrap();
        state.next_registration = state.next_registration.wrapping_add(1).max(1);
        let registration = state.next_registration;
        state.scopes.insert(registration, scope);
        state.revision = state.revision.wrapping_add(1);
        self.changed.notify_one();
        Ok(registration)
    }

    fn unregister(&self, registration: u64) {
        let mut state = self.state.lock().unwrap();
        if state.scopes.remove(&registration).is_some() {
            state.finalizing.remove(&registration);
            state.revision = state.revision.wrapping_add(1);
            self.changed.notify_all();
        }
    }

    /// Ask the shared tracker to own one final complete scan while this scope
    /// is still registered. The caller waits only inside its cleanup budget.
    /// If that budget expires, the tracker retains the inactive registration,
    /// kills late matches, and removes it after the scan completes.
    fn finalize(&self, registration: u64, deadline: Instant) {
        if Instant::now() >= deadline {
            self.unregister(registration);
            return;
        }
        let mut state = self.state.lock().unwrap();
        if !state.scopes.contains_key(&registration) {
            return;
        }
        state.finalizing.insert(registration);
        state.revision = state.revision.wrapping_add(1);
        self.changed.notify_one();
        while state.scopes.contains_key(&registration) {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return;
            }
            let (next, timeout) = self.changed.wait_timeout(state, remaining).unwrap();
            state = next;
            if timeout.timed_out() && state.scopes.contains_key(&registration) {
                return;
            }
        }
    }

    fn ensure_started(self: &Arc<Self>) -> io::Result<()> {
        let mut started = self.started.lock().unwrap();
        if *started {
            return Ok(());
        }
        let tracker = self.clone();
        std::thread::Builder::new()
            .name("cmux-process-scopes".into())
            .spawn(move || tracker.run())?;
        *started = true;
        Ok(())
    }

    fn run(&self) {
        let mut last_scan = Instant::now().checked_sub(TRACK_INTERVAL).unwrap_or_else(Instant::now);
        loop {
            let (revision, registrations, finalizing) = {
                let mut state = self.state.lock().unwrap();
                while state.scopes.is_empty() {
                    state = self.changed.wait(state).unwrap();
                }
                let remaining = TRACK_INTERVAL.saturating_sub(last_scan.elapsed());
                if !remaining.is_zero() {
                    let (next, _) = self.changed.wait_timeout(state, remaining).unwrap();
                    state = next;
                    if state.scopes.is_empty() {
                        continue;
                    }
                }
                (
                    state.revision,
                    state
                        .scopes
                        .iter()
                        .map(|(registration, scope)| (*registration, scope.clone()))
                        .collect::<Vec<_>>(),
                    state.finalizing.clone(),
                )
            };
            let scopes = registrations.iter().map(|(_, scope)| scope.clone()).collect::<Vec<_>>();

            for (scope, identity) in scan_registered_processes(&scopes) {
                record_tracked_process(&scopes[scope], identity);
            }
            last_scan = Instant::now();

            let mut state = self.state.lock().unwrap();
            let mut finalized = false;
            for (registration, _) in &registrations {
                if finalizing.contains(registration) {
                    state.scopes.remove(registration);
                    state.finalizing.remove(registration);
                    finalized = true;
                }
            }
            if finalized {
                state.revision = state.revision.wrapping_add(1);
                self.changed.notify_all();
            }
            let _ = self
                .changed
                .wait_timeout_while(state, TRACK_INTERVAL, |state| state.revision == revision)
                .unwrap();
        }
    }
}

#[cfg(target_os = "linux")]
fn record_tracked_process(scope: &ScopeRegistration, identity: ProcessIdentity) {
    if identity == scope.root || identity.pid == std::process::id() {
        return;
    }
    let Ok(pidfd) = pidfd_open(identity.pid) else { return };
    if process_identity(identity.pid) != Some(identity) {
        return;
    }
    let mut tracked = scope.tracked.lock().unwrap();
    if !tracked.active {
        let _ = pidfd_send_signal(&pidfd, libc::SIGKILL);
        return;
    }
    if tracked.identities.len() >= MAX_TRACKED_PROCESSES
        || tracked.identities.contains_key(&identity)
    {
        return;
    }
    tracked.identities.insert(identity, pidfd);
    scope.tracked_changed.notify_all();
}

#[cfg(not(target_os = "linux"))]
fn record_tracked_process(scope: &ScopeRegistration, identity: ProcessIdentity) {
    if identity == scope.root || identity.pid == std::process::id() {
        return;
    }
    let mut tracked = scope.tracked.lock().unwrap();
    if !tracked.active {
        signal_process(identity);
        return;
    }
    if tracked.identities.len() >= MAX_TRACKED_PROCESSES {
        return;
    }
    if tracked.identities.insert(identity) {
        scope.tracked_changed.notify_all();
    }
}

fn create_file_marker(marker: &str) -> io::Result<(OwnedFd, FileMarker)> {
    let path = std::env::temp_dir().join(format!("cmux-tui-process-scope-{marker}"));
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
        .open(&path)?;
    let identity = file_marker_for_fd(file.as_raw_fd());
    let unlink = std::fs::remove_file(&path);
    let identity = identity?;
    unlink?;
    Ok((file.into(), identity))
}

fn file_marker_for_fd(fd: libc::c_int) -> io::Result<FileMarker> {
    let mut stat = std::mem::MaybeUninit::<libc::stat>::zeroed();
    if unsafe { libc::fstat(fd, stat.as_mut_ptr()) } != 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: fstat(2) initialized the structure after returning success.
    let stat = unsafe { stat.assume_init() };
    #[cfg(target_os = "macos")]
    let device = u64::try_from(stat.st_dev)
        .map_err(|_| io::Error::other("file marker device is out of range"))?;
    #[cfg(not(target_os = "macos"))]
    let device = stat.st_dev;
    let inode = stat.st_ino;
    Ok(FileMarker { device, inode })
}

#[cfg(target_os = "linux")]
fn pidfd_open(pid: u32) -> io::Result<OwnedFd> {
    let pid = libc::pid_t::try_from(pid)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "process id is out of range"))?;
    let fd = unsafe { libc::syscall(libc::SYS_pidfd_open, pid, 0_u32) };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    let fd = i32::try_from(fd).map_err(|_| io::Error::other("pidfd is out of range"))?;
    // SAFETY: pidfd_open returned a new descriptor owned by this scope.
    Ok(unsafe { OwnedFd::from_raw_fd(fd) })
}

#[cfg(target_os = "linux")]
fn pidfd_send_signal(pidfd: &OwnedFd, signal: libc::c_int) -> io::Result<()> {
    let result = unsafe {
        libc::syscall(
            libc::SYS_pidfd_send_signal,
            pidfd.as_raw_fd(),
            signal,
            std::ptr::null::<libc::siginfo_t>(),
            0_u32,
        )
    };
    if result < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

#[cfg(not(target_os = "linux"))]
fn signal_process(identity: ProcessIdentity) {
    if process_identity(identity.pid) != Some(identity) {
        return;
    }
    if let Ok(pid) = libc::pid_t::try_from(identity.pid) {
        unsafe {
            libc::kill(pid, libc::SIGKILL);
        }
    }
}

fn marker_environment_entry(marker: &str) -> Vec<u8> {
    format!("{PROCESS_SCOPE_ENV}={marker}").into_bytes()
}

#[derive(Clone, Copy)]
struct ProcessSnapshot {
    identity: ProcessIdentity,
    parent: u32,
}

fn scope_known_identities(scope: &ScopeRegistration) -> Vec<ProcessIdentity> {
    let tracked = scope.tracked.lock().unwrap();
    #[cfg(target_os = "linux")]
    {
        tracked.identities.keys().copied().collect()
    }
    #[cfg(not(target_os = "linux"))]
    {
        tracked.identities.iter().copied().collect()
    }
}

fn include_lineage_matches(
    scopes: &[ScopeRegistration],
    processes: &[ProcessSnapshot],
    matches: &mut HashSet<(usize, ProcessIdentity)>,
) {
    let present = processes
        .iter()
        .map(|process| (process.identity.pid, process.identity))
        .collect::<HashMap<_, _>>();
    for (scope_index, scope) in scopes.iter().enumerate() {
        let mut owned = matches
            .iter()
            .filter_map(|(index, identity)| (*index == scope_index).then_some(*identity))
            .collect::<HashSet<_>>();
        if present.get(&scope.root.pid) == Some(&scope.root) {
            owned.insert(scope.root);
        }
        for identity in scope_known_identities(scope) {
            if present.get(&identity.pid) == Some(&identity) {
                owned.insert(identity);
            }
        }
        loop {
            let mut changed = false;
            for process in processes {
                if owned.contains(&process.identity) {
                    continue;
                }
                if present.get(&process.parent).is_some_and(|parent| owned.contains(parent)) {
                    owned.insert(process.identity);
                    matches.insert((scope_index, process.identity));
                    changed = true;
                }
            }
            if !changed {
                break;
            }
        }
    }
}

#[cfg(target_os = "linux")]
fn scan_registered_processes(scopes: &[ScopeRegistration]) -> HashSet<(usize, ProcessIdentity)> {
    use std::os::unix::fs::MetadataExt as _;

    let earliest_start = scopes.iter().map(|scope| scope.root.started).min().unwrap_or(0);
    let expected =
        scopes.iter().map(|scope| marker_environment_entry(&scope.marker)).collect::<Vec<_>>();
    let file_markers = scopes.iter().enumerate().fold(
        HashMap::<FileMarker, Vec<usize>>::new(),
        |mut markers, (index, scope)| {
            markers.entry(scope.file_marker).or_default().push(index);
            markers
        },
    );
    let Ok(processes) = std::fs::read_dir("/proc") else { return HashSet::new() };
    let mut snapshots = Vec::new();
    let mut matches = HashSet::new();
    let mut remaining_file_descriptors = MAX_SCAN_FILE_DESCRIPTORS;
    for process in processes.flatten().take(MAX_SCAN_PROCESSES) {
        let Some(pid) = process.file_name().to_str().and_then(|value| value.parse::<u32>().ok())
        else {
            continue;
        };
        let Some(snapshot) = std::fs::read_to_string(process.path().join("stat"))
            .ok()
            .and_then(|stat| linux_process_snapshot_from_stat(pid, &stat))
        else {
            continue;
        };
        snapshots.push(snapshot);
        if snapshot.identity.started < earliest_start {
            continue;
        }
        if let Ok(environment) = std::fs::read(process.path().join("environ")) {
            for entry in environment.split(|byte| *byte == 0) {
                for (scope, expected) in expected.iter().enumerate() {
                    if entry == expected {
                        matches.insert((scope, snapshot.identity));
                    }
                }
            }
        }
        if remaining_file_descriptors != 0
            && let Ok(fds) = std::fs::read_dir(process.path().join("fd"))
        {
            for fd in fds.flatten().take(remaining_file_descriptors) {
                remaining_file_descriptors -= 1;
                let Some(marker) = std::fs::metadata(fd.path())
                    .ok()
                    .map(|metadata| FileMarker { device: metadata.dev(), inode: metadata.ino() })
                else {
                    continue;
                };
                if let Some(scope_indexes) = file_markers.get(&marker) {
                    for scope in scope_indexes {
                        matches.insert((*scope, snapshot.identity));
                    }
                }
            }
        }
    }
    include_lineage_matches(scopes, &snapshots, &mut matches);
    matches
}

#[cfg(target_os = "linux")]
fn process_identity(pid: u32) -> Option<ProcessIdentity> {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    linux_process_identity_from_stat(pid, &stat)
}

#[cfg(target_os = "linux")]
fn linux_process_identity_from_stat(pid: u32, stat: &str) -> Option<ProcessIdentity> {
    Some(linux_process_snapshot_from_stat(pid, stat)?.identity)
}

#[cfg(target_os = "linux")]
fn linux_process_snapshot_from_stat(pid: u32, stat: &str) -> Option<ProcessSnapshot> {
    let fields = stat.get(stat.rfind(')')? + 1..)?.split_whitespace().collect::<Vec<_>>();
    // `fields[0]` is field 3 (`state`); process start time is field 22.
    let parent = fields.get(1)?.parse::<u32>().ok()?;
    let started = fields.get(19)?.parse::<u128>().ok()?;
    Some(ProcessSnapshot { identity: ProcessIdentity { pid, started }, parent })
}

#[cfg(target_os = "macos")]
fn scan_registered_processes(scopes: &[ScopeRegistration]) -> HashSet<(usize, ProcessIdentity)> {
    const PROC_ALL_PIDS: u32 = 1;
    let bytes = unsafe { libc::proc_listpids(PROC_ALL_PIDS, 0, std::ptr::null_mut(), 0) };
    let Ok(bytes) = usize::try_from(bytes) else { return HashSet::new() };
    let mut pids = vec![0 as libc::pid_t; bytes / size_of::<libc::pid_t>() + 32];
    let Ok(capacity) = libc::c_int::try_from(pids.len() * size_of::<libc::pid_t>()) else {
        return HashSet::new();
    };
    let written =
        unsafe { libc::proc_listpids(PROC_ALL_PIDS, 0, pids.as_mut_ptr().cast(), capacity) };
    let Ok(written) = usize::try_from(written) else { return HashSet::new() };
    let Some(mut arguments) = mac_process_argument_buffer() else { return HashSet::new() };
    let expected =
        scopes.iter().map(|scope| marker_environment_entry(&scope.marker)).collect::<Vec<_>>();
    let file_markers = scopes.iter().enumerate().fold(
        HashMap::<FileMarker, Vec<usize>>::new(),
        |mut markers, (index, scope)| {
            markers.entry(scope.file_marker).or_default().push(index);
            markers
        },
    );
    let earliest_start = scopes.iter().map(|scope| scope.root.started).min().unwrap_or(0);
    let mut snapshots = Vec::new();
    let mut matches = HashSet::new();
    let mut remaining_file_descriptors = MAX_SCAN_FILE_DESCRIPTORS;
    for pid in pids.into_iter().take(written / size_of::<libc::pid_t>()).take(MAX_SCAN_PROCESSES) {
        let Ok(pid) = u32::try_from(pid) else { continue };
        let Some(snapshot) = mac_process_snapshot(pid) else { continue };
        snapshots.push(snapshot);
        if snapshot.identity.started < earliest_start {
            continue;
        }
        if let Some(process_arguments) = mac_process_arguments(pid, &mut arguments) {
            for (scope, expected) in expected.iter().enumerate() {
                if mac_environment_contains(process_arguments, expected) {
                    matches.insert((scope, snapshot.identity));
                }
            }
        }
        for marker in mac_process_file_markers(pid, &mut remaining_file_descriptors) {
            if let Some(scope_indexes) = file_markers.get(&marker) {
                for scope in scope_indexes {
                    matches.insert((*scope, snapshot.identity));
                }
            }
        }
    }
    include_lineage_matches(scopes, &snapshots, &mut matches);
    matches
}

#[cfg(target_os = "macos")]
#[repr(C)]
struct ProcFileInfo {
    _open_flags: u32,
    _status: u32,
    _offset: libc::off_t,
    _file_type: i32,
    _guard_flags: u32,
}

#[cfg(target_os = "macos")]
#[repr(C)]
struct VnodeFdInfo {
    _file: ProcFileInfo,
    vnode: libc::vnode_info,
}

#[cfg(target_os = "macos")]
fn mac_process_file_markers(pid: u32, remaining: &mut usize) -> Vec<FileMarker> {
    if *remaining == 0 {
        return Vec::new();
    }
    const PROC_PIDFDVNODEINFO: libc::c_int = 1;
    let Ok(pid_int) = libc::c_int::try_from(pid) else { return Vec::new() };
    let bytes =
        unsafe { libc::proc_pidinfo(pid_int, libc::PROC_PIDLISTFDS, 0, std::ptr::null_mut(), 0) };
    let Ok(bytes) = usize::try_from(bytes) else { return Vec::new() };
    let mut fds =
        Vec::<libc::proc_fdinfo>::with_capacity(bytes / size_of::<libc::proc_fdinfo>() + 8);
    let Ok(capacity) = libc::c_int::try_from(fds.capacity() * size_of::<libc::proc_fdinfo>())
    else {
        return Vec::new();
    };
    let written = unsafe {
        libc::proc_pidinfo(pid_int, libc::PROC_PIDLISTFDS, 0, fds.as_mut_ptr().cast(), capacity)
    };
    let Ok(written) = usize::try_from(written) else { return Vec::new() };
    let count = (written / size_of::<libc::proc_fdinfo>()).min(*remaining);
    *remaining -= count;
    // SAFETY: proc_pidinfo initialized `count` entries within the allocation.
    unsafe {
        fds.set_len(count.min(fds.capacity()));
    }
    fds.into_iter()
        .filter_map(|fd| {
            if fd.proc_fdtype != libc::PROX_FDTYPE_VNODE as u32 {
                return None;
            }
            let mut info = std::mem::MaybeUninit::<VnodeFdInfo>::zeroed();
            let Ok(size) = libc::c_int::try_from(size_of::<VnodeFdInfo>()) else {
                return None;
            };
            let written = unsafe {
                libc::proc_pidfdinfo(
                    pid_int,
                    fd.proc_fd,
                    PROC_PIDFDVNODEINFO,
                    info.as_mut_ptr().cast(),
                    size,
                )
            };
            if written != size {
                return None;
            }
            // SAFETY: proc_pidfdinfo initialized the full structure.
            let info = unsafe { info.assume_init() };
            Some(FileMarker {
                device: u64::from(info.vnode.vi_stat.vst_dev),
                inode: info.vnode.vi_stat.vst_ino,
            })
        })
        .collect()
}

#[cfg(target_os = "macos")]
fn mac_process_argument_buffer() -> Option<Vec<u8>> {
    let mut mib = [libc::CTL_KERN, libc::KERN_ARGMAX];
    let mut argmax = 0 as libc::c_int;
    let mut size = size_of::<libc::c_int>();
    let result = unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            mib.len() as libc::c_uint,
            (&mut argmax as *mut libc::c_int).cast(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    if result != 0 || argmax <= 0 {
        return None;
    }
    let argmax = usize::try_from(argmax).ok()?;
    (argmax <= 16 * 1024 * 1024).then(|| vec![0; argmax])
}

#[cfg(target_os = "macos")]
fn mac_process_arguments<'a>(pid: u32, buffer: &'a mut [u8]) -> Option<&'a [u8]> {
    let pid = libc::c_int::try_from(pid).ok()?;
    let mut mib = [libc::CTL_KERN, libc::KERN_PROCARGS2, pid];
    let mut size = buffer.len();
    let result = unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            mib.len() as libc::c_uint,
            buffer.as_mut_ptr().cast(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    if result == 0 { Some(&buffer[..size.min(buffer.len())]) } else { None }
}

#[cfg(target_os = "macos")]
fn mac_environment_contains(arguments: &[u8], expected: &[u8]) -> bool {
    let Some(argc) = arguments.get(..4) else { return false };
    let argc = i32::from_ne_bytes(argc.try_into().expect("four-byte argc"));
    let Ok(argc) = usize::try_from(argc) else { return false };
    let mut cursor = 4;
    let Some(path_end) = arguments[cursor..].iter().position(|byte| *byte == 0) else {
        return false;
    };
    cursor += path_end + 1;
    while arguments.get(cursor) == Some(&0) {
        cursor += 1;
    }
    for _ in 0..argc {
        let Some(end) = arguments[cursor..].iter().position(|byte| *byte == 0) else {
            return false;
        };
        cursor += end + 1;
    }
    while arguments.get(cursor) == Some(&0) {
        cursor += 1;
    }
    arguments[cursor..].split(|byte| *byte == 0).any(|entry| entry == expected)
}

#[cfg(target_os = "macos")]
fn process_identity(pid: u32) -> Option<ProcessIdentity> {
    Some(mac_process_snapshot(pid)?.identity)
}

#[cfg(target_os = "macos")]
fn mac_process_snapshot(pid: u32) -> Option<ProcessSnapshot> {
    let pid_int = libc::c_int::try_from(pid).ok()?;
    let mut info = std::mem::MaybeUninit::<libc::proc_bsdinfo>::zeroed();
    let size = libc::c_int::try_from(size_of::<libc::proc_bsdinfo>()).ok()?;
    let written = unsafe {
        libc::proc_pidinfo(pid_int, libc::PROC_PIDTBSDINFO, 0, info.as_mut_ptr().cast(), size)
    };
    if written != size {
        return None;
    }
    // SAFETY: proc_pidinfo initialized the full structure.
    let info = unsafe { info.assume_init() };
    let started = (u128::from(info.pbi_start_tvsec) << 64) | u128::from(info.pbi_start_tvusec);
    Some(ProcessSnapshot { identity: ProcessIdentity { pid, started }, parent: info.pbi_ppid })
}

#[cfg(all(unix, not(any(target_os = "linux", target_os = "macos"))))]
fn scan_registered_processes(_scopes: &[ScopeRegistration]) -> HashSet<(usize, ProcessIdentity)> {
    HashSet::new()
}

#[cfg(all(unix, not(any(target_os = "linux", target_os = "macos"))))]
fn process_identity(pid: u32) -> Option<ProcessIdentity> {
    Some(ProcessIdentity { pid, started: 0 })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(target_os = "linux")]
    #[test]
    fn linux_process_identity_uses_start_time_after_a_parenthesized_name() {
        let stat = "12 (name with ) marker) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 4242";
        assert_eq!(
            linux_process_identity_from_stat(12, stat),
            Some(ProcessIdentity { pid: 12, started: 4242 })
        );
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn mac_argument_parser_finds_only_environment_entries() {
        let expected = b"CMUX_TUI_PROCESS_SCOPE=abc";
        let mut arguments = 2_i32.to_ne_bytes().to_vec();
        arguments.extend_from_slice(b"/bin/tool\0\0tool\0--flag\0A=1\0");
        arguments.extend_from_slice(expected);
        arguments.push(0);
        assert!(mac_environment_contains(&arguments, expected));

        let mut argv_only = 1_i32.to_ne_bytes().to_vec();
        argv_only.extend_from_slice(b"/bin/tool\0\0CMUX_TUI_PROCESS_SCOPE=abc\0A=1\0");
        assert!(!mac_environment_contains(&argv_only, expected));
    }
}
