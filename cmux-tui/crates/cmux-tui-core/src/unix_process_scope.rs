//! Bounded Unix process cleanup for short-lived child commands.
//!
//! Linux installs an inherited seccomp fence that prevents a hook from leaving
//! its assigned process group. macOS executes hooks in a kernel sandbox that
//! prevents descendant creation. Two command-local identities provide a
//! defense-in-depth ownership path: an environment marker survives
//! `closefrom(2)`, and an inherited file marker survives environment
//! replacement. One process-wide tracker scans all active scopes together at
//! a fixed maximum rate, follows known parent-child lineage, and records exact
//! process identities before cleanup. Each scan has process and descriptor
//! work limits. Cleanup always requests one tracker-owned final complete pass;
//! an expired command deadline returns to the caller while the tracker keeps
//! the inactive scope and advances through bounded scan chunks.

use std::collections::{HashMap, HashSet};
use std::ffi::OsStr;
use std::fs::OpenOptions;
use std::io;
#[cfg(target_os = "macos")]
use std::mem::size_of;
#[cfg(target_os = "linux")]
use std::os::fd::FromRawFd;
use std::os::fd::{AsRawFd, OwnedFd};
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::process::CommandExt;
use std::process::Command;
use std::sync::{Arc, Condvar, Mutex, OnceLock, mpsc};
use std::thread::JoinHandle;
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
    #[cfg(test)]
    track_before_finalization: bool,
    #[cfg(test)]
    final_scan_gate: Option<FinalScanTestGate>,
}

#[cfg(test)]
#[derive(Clone)]
struct FinalScanTestGate {
    reached: mpsc::SyncSender<()>,
    resume: Arc<Mutex<mpsc::Receiver<()>>>,
    used: Arc<std::sync::atomic::AtomicBool>,
}

#[cfg(test)]
impl FinalScanTestGate {
    fn pause_once(&self) {
        if self.used.swap(true, std::sync::atomic::Ordering::AcqRel) {
            return;
        }
        let _ = self.reached.send(());
        let _ = self.resume.lock().unwrap().recv();
    }
}

#[derive(Clone, Copy, Default)]
struct ProcessScanCursor {
    after_pid: u32,
    file_descriptors: Option<(u32, libc::c_int)>,
}

#[derive(Default)]
struct FinalScanProgress {
    cursor: ProcessScanCursor,
    snapshots: HashMap<ProcessIdentity, ProcessSnapshot>,
    matches: HashSet<(usize, ProcessIdentity)>,
}

#[derive(Default)]
struct ProcessScanResult {
    snapshots: Vec<ProcessSnapshot>,
    matches: HashSet<(usize, ProcessIdentity)>,
    next: Option<ProcessScanCursor>,
}

#[derive(Default)]
struct ProcessScopeTrackerState {
    next_registration: u64,
    revision: u64,
    scopes: HashMap<u64, ScopeRegistration>,
    finalizing: HashMap<u64, FinalScanProgress>,
    finalizing_turn: u64,
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
    tracker: Option<ScopeTracker>,
    terminated: bool,
    #[cfg(test)]
    track_before_finalization: bool,
    #[cfg(test)]
    final_scan_gate: Option<FinalScanTestGate>,
    #[cfg(all(test, target_os = "linux"))]
    kernel_group_fence: bool,
}

/// A signal from the kernel that an owned child is waitable. The observer
/// uses `waitid(WNOWAIT)`, so checking for exit does not release the child's
/// PID or process group before its process scope is terminated.
pub struct UnixChildExitSignal {
    result: mpsc::Receiver<io::Result<()>>,
    observer: Option<JoinHandle<()>>,
}

impl UnixChildExitSignal {
    /// Start one blocking kernel wait for an owned child without reaping it.
    pub fn observe(pid: u32) -> io::Result<Self> {
        let pid = libc::pid_t::try_from(pid).map_err(|_| {
            io::Error::new(io::ErrorKind::InvalidInput, "child pid is out of range")
        })?;
        let (sender, result) = mpsc::sync_channel(1);
        let observer =
            std::thread::Builder::new().name("cmux-child-exit".into()).spawn(move || {
                let _ = sender.send(wait_for_child_exit_without_reaping(pid));
            })?;
        Ok(Self { result, observer: Some(observer) })
    }

    /// Return true when the child is waitable without releasing its PID.
    pub fn try_waitable(&self) -> io::Result<bool> {
        match self.result.try_recv() {
            Ok(result) => result.map(|()| true),
            Err(mpsc::TryRecvError::Empty) => Ok(false),
            Err(mpsc::TryRecvError::Disconnected) => {
                Err(io::Error::other("child exit observer stopped without a result"))
            }
        }
    }

    /// Wait through an absolute deadline for the child to become waitable.
    pub fn wait_until(&self, deadline: Instant) -> io::Result<bool> {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Ok(false);
        }
        match self.result.recv_timeout(remaining) {
            Ok(result) => result.map(|()| true),
            Err(mpsc::RecvTimeoutError::Timeout) => Ok(false),
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                Err(io::Error::other("child exit observer stopped without a result"))
            }
        }
    }

    /// Join the observer after the child is waitable or has been killed.
    pub fn finish(mut self) {
        if let Some(observer) = self.observer.take() {
            let _ = observer.join();
        }
    }
}

fn wait_for_child_exit_without_reaping(pid: libc::pid_t) -> io::Result<()> {
    loop {
        let mut status = std::mem::MaybeUninit::<libc::siginfo_t>::zeroed();
        // SAFETY: status points to writable siginfo storage. WNOWAIT observes
        // this owned child becoming waitable without releasing its PID/PGID.
        let result = unsafe {
            libc::waitid(
                libc::P_PID,
                pid as libc::id_t,
                status.as_mut_ptr(),
                libc::WEXITED | libc::WNOWAIT,
            )
        };
        if result == 0 {
            return Ok(());
        }
        let error = io::Error::last_os_error();
        if error.kind() != io::ErrorKind::Interrupted {
            return Err(error);
        }
    }
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
            tracker: None,
            terminated: false,
            #[cfg(test)]
            track_before_finalization: true,
            #[cfg(test)]
            final_scan_gate: None,
            #[cfg(all(test, target_os = "linux"))]
            kernel_group_fence: true,
        })
    }

    /// Build a command whose controlled launcher stops before it executes the
    /// requested program. `bind` registers the stopped root and then releases
    /// it, so user code cannot detach before scope ownership exists.
    pub fn suspended_command(program: impl AsRef<OsStr>) -> Command {
        let program = program.as_ref();
        #[cfg(target_os = "macos")]
        let command = {
            let mut command = Command::new("/usr/bin/sandbox-exec");
            command
                .args([
                    "-p",
                    "(version 1) (allow default) (deny process-fork)",
                    "/bin/sh",
                    "-c",
                    "kill -STOP $$; exec \"$@\"",
                    "cmux-process-scope",
                ])
                .arg(program);
            command
        };
        #[cfg(not(target_os = "macos"))]
        let command = {
            let mut command = Command::new("/bin/sh");
            command.args(["-c", "kill -STOP $$; exec \"$@\"", "cmux-process-scope"]).arg(program);
            command
        };
        command
    }

    /// Select this command as the only child that receives the scope
    /// identities. The file was opened with `O_CLOEXEC`, so unrelated
    /// concurrent spawns cannot inherit it.
    pub fn configure(&self, command: &mut Command) {
        command.env(PROCESS_SCOPE_ENV, &self.marker);
        let marker_fd = self._marker_fd.as_raw_fd();
        #[cfg(all(test, target_os = "linux"))]
        let kernel_group_fence = self.kernel_group_fence;
        #[cfg(all(not(test), target_os = "linux"))]
        let kernel_group_fence = true;
        // SAFETY: the closure calls only async-signal-safe syscalls between
        // fork and exec and does not allocate.
        unsafe {
            command.pre_exec(move || {
                if libc::setpgid(0, 0) != 0 {
                    return Err(io::Error::last_os_error());
                }
                let flags = libc::fcntl(marker_fd, libc::F_GETFD);
                if flags < 0 || libc::fcntl(marker_fd, libc::F_SETFD, flags & !libc::FD_CLOEXEC) < 0
                {
                    return Err(io::Error::last_os_error());
                }
                #[cfg(target_os = "linux")]
                if kernel_group_fence {
                    install_linux_process_group_fence()?;
                }
                Ok(())
            });
        }
    }

    /// Record the exact root identity and start holder discovery while the
    /// command still owns its execution budget.
    pub fn bind(&mut self, root: u32) -> io::Result<()> {
        wait_for_suspended_child(root)?;
        self.root = Some(process_identity(root).ok_or_else(|| {
            io::Error::new(io::ErrorKind::NotFound, "process scope root is unavailable")
        })?);
        #[cfg(target_os = "linux")]
        {
            self.root_pidfd = Some(pidfd_open(root)?);
        }
        self.start_tracker()?;
        self.resume_root()
    }

    /// Kill the original group and every recorded descendant within the
    /// default cleanup interval.
    pub fn terminate(&mut self) {
        self.terminate_until(Instant::now() + CLEANUP_DEADLINE);
    }

    /// Kill the original group and every recorded descendant. The shared
    /// tracker owns a final complete pass even when the caller's deadline has
    /// expired; the caller waits only inside its remaining budget.
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
            #[cfg(test)]
            track_before_finalization: self.track_before_finalization,
            #[cfg(test)]
            final_scan_gate: self.final_scan_gate.clone(),
        })?;
        self.tracker = Some(ScopeTracker { registration, registry });
        Ok(())
    }

    #[cfg(all(test, target_os = "linux"))]
    pub(crate) fn final_scan_gate_for_test(
        &mut self,
    ) -> (mpsc::Receiver<()>, mpsc::SyncSender<()>) {
        let (reached, reached_receiver) = mpsc::sync_channel(1);
        let (resume, resume_receiver) = mpsc::sync_channel(1);
        self.track_before_finalization = false;
        self.kernel_group_fence = false;
        self.final_scan_gate = Some(FinalScanTestGate {
            reached,
            resume: Arc::new(Mutex::new(resume_receiver)),
            used: Arc::new(std::sync::atomic::AtomicBool::new(false)),
        });
        (reached_receiver, resume)
    }

    fn resume_root(&self) -> io::Result<()> {
        let root = self.root.ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidInput, "process scope is unbound")
        })?;
        if process_identity(root.pid) != Some(root) {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                "stopped process scope root is unavailable",
            ));
        }
        let pid = libc::pid_t::try_from(root.pid).map_err(|_| {
            io::Error::new(io::ErrorKind::InvalidInput, "process scope root is out of range")
        })?;
        if unsafe { libc::kill(pid, libc::SIGCONT) } != 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(())
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
        // group. A waitable root can reject SIGSTOP, but its unreaped PID still
        // reserves the numeric PGID through this operation.
        if pidfd_send_signal(pidfd, libc::SIGSTOP).is_err()
            && process_identity(root.pid) != Some(root)
        {
            return;
        }
        if let Ok(group) = libc::pid_t::try_from(root.pid) {
            unsafe {
                libc::kill(-group, libc::SIGKILL);
            }
        }
        let _ = pidfd_send_signal(pidfd, libc::SIGKILL);
    }

    #[cfg(target_os = "macos")]
    fn terminate_root_group(&self) {
        let Some(root) = self.root else { return };
        // A live root is stopped through its audit token before the numeric
        // process-group operation. A waitable root cannot accept SIGSTOP, but
        // the caller keeps it unreaped until this scope operation completes,
        // so its PID/PGID is still reserved while the group is signaled.
        if !signal_process_with(root, libc::SIGSTOP) && process_identity(root.pid) != Some(root) {
            return;
        }
        if let Ok(group) = libc::pid_t::try_from(root.pid) {
            unsafe {
                libc::kill(-group, libc::SIGKILL);
            }
        }
        let _ = signal_process_with(root, libc::SIGKILL);
    }

    #[cfg(all(unix, not(any(target_os = "linux", target_os = "macos"))))]
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

fn wait_for_suspended_child(pid: u32) -> io::Result<()> {
    let pid = libc::pid_t::try_from(pid)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "child pid is out of range"))?;
    loop {
        let mut status = 0;
        let waited = unsafe { libc::waitpid(pid, &mut status, libc::WUNTRACED) };
        if waited == pid {
            if libc::WIFSTOPPED(status) && libc::WSTOPSIG(status) == libc::SIGSTOP {
                return Ok(());
            }
            return Err(io::Error::other(
                "process scope launcher exited before its ownership fence",
            ));
        }
        if waited < 0 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(error);
        }
    }
}

#[cfg(target_os = "linux")]
const fn linux_bpf_statement(code: u32, value: u32) -> libc::sock_filter {
    libc::sock_filter { code: code as u16, jt: 0, jf: 0, k: value }
}

#[cfg(target_os = "linux")]
const fn linux_bpf_jump(code: u32, value: u32, equal: u8, not_equal: u8) -> libc::sock_filter {
    libc::sock_filter { code: code as u16, jt: equal, jf: not_equal, k: value }
}

/// Install a kernel-enforced process-group fence before the controlled shell
/// runs. The filter is inherited across fork and exec and cannot be removed
/// after `PR_SET_NO_NEW_PRIVS`. It leaves ordinary child creation available,
/// but rejects the two syscalls that can move a hook or descendant out of the
/// process group owned by this scope.
#[cfg(target_os = "linux")]
fn install_linux_process_group_fence() -> io::Result<()> {
    const SECCOMP_DATA_NR_OFFSET: u32 = 0;
    const SECCOMP_DATA_ARCH_OFFSET: u32 = 4;
    const X32_SYSCALL_BIT: u32 = 0x4000_0000;
    #[cfg(target_arch = "x86_64")]
    const AUDIT_ARCH: u32 = 0xc000_003e;
    #[cfg(target_arch = "aarch64")]
    const AUDIT_ARCH: u32 = 0xc000_00b7;
    #[cfg(not(any(target_arch = "x86_64", target_arch = "aarch64")))]
    compile_error!("cmux-tui process scopes require a Linux seccomp audit architecture");

    let denied = libc::SECCOMP_RET_ERRNO | u32::try_from(libc::EPERM).unwrap_or(1);
    let mut filter = [
        linux_bpf_statement(libc::BPF_LD | libc::BPF_W | libc::BPF_ABS, SECCOMP_DATA_ARCH_OFFSET),
        linux_bpf_jump(libc::BPF_JMP | libc::BPF_JEQ | libc::BPF_K, AUDIT_ARCH, 1, 0),
        linux_bpf_statement(libc::BPF_RET | libc::BPF_K, libc::SECCOMP_RET_KILL_PROCESS),
        linux_bpf_statement(libc::BPF_LD | libc::BPF_W | libc::BPF_ABS, SECCOMP_DATA_NR_OFFSET),
        linux_bpf_statement(libc::BPF_ALU | libc::BPF_AND | libc::BPF_K, !X32_SYSCALL_BIT),
        linux_bpf_jump(
            libc::BPF_JMP | libc::BPF_JEQ | libc::BPF_K,
            u32::try_from(libc::SYS_setsid).unwrap_or(u32::MAX),
            0,
            1,
        ),
        linux_bpf_statement(libc::BPF_RET | libc::BPF_K, denied),
        linux_bpf_jump(
            libc::BPF_JMP | libc::BPF_JEQ | libc::BPF_K,
            u32::try_from(libc::SYS_setpgid).unwrap_or(u32::MAX),
            0,
            1,
        ),
        linux_bpf_statement(libc::BPF_RET | libc::BPF_K, denied),
        linux_bpf_statement(libc::BPF_RET | libc::BPF_K, libc::SECCOMP_RET_ALLOW),
    ];
    let program = libc::sock_fprog {
        len: u16::try_from(filter.len()).unwrap_or(u16::MAX),
        filter: filter.as_mut_ptr(),
    };
    if unsafe { libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) } != 0 {
        return Err(io::Error::last_os_error());
    }
    if unsafe {
        libc::prctl(libc::PR_SET_SECCOMP, libc::SECCOMP_MODE_FILTER, std::ptr::from_ref(&program))
    } != 0
    {
        return Err(io::Error::last_os_error());
    }
    Ok(())
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

    /// Ask the shared tracker to own one final complete scan while this scope
    /// is still registered. The caller waits only inside its cleanup budget.
    /// If that budget expires, the tracker retains the inactive registration,
    /// kills late matches, and removes it after the scan completes.
    fn finalize(&self, registration: u64, deadline: Instant) {
        let mut state = self.state.lock().unwrap();
        if !state.scopes.contains_key(&registration) {
            return;
        }
        state.finalizing.entry(registration).or_default();
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
            let (revision, registrations, final_scan) = {
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
                let finalizing = state
                    .finalizing
                    .keys()
                    .copied()
                    .filter(|registration| *registration > state.finalizing_turn)
                    .min()
                    .or_else(|| state.finalizing.keys().copied().min());
                let final_scan = finalizing.and_then(|registration| {
                    state.finalizing_turn = registration;
                    let scope = state.scopes.get(&registration)?.clone();
                    let cursor = state.finalizing.get(&registration)?.cursor;
                    Some((registration, cursor, scope))
                });
                let registrations = match &final_scan {
                    Some((registration, _, scope)) => vec![(*registration, scope.clone())],
                    None => state
                        .scopes
                        .iter()
                        .filter(|(_, scope)| scope_tracks_before_finalization(scope))
                        .map(|(registration, scope)| (*registration, scope.clone()))
                        .collect::<Vec<_>>(),
                };
                (state.revision, registrations, final_scan.map(|(id, cursor, _)| (id, cursor)))
            };
            let scopes = registrations.iter().map(|(_, scope)| scope.clone()).collect::<Vec<_>>();
            let scan = scan_registered_processes(
                &scopes,
                final_scan.map_or_else(ProcessScanCursor::default, |(_, cursor)| cursor),
            );
            last_scan = Instant::now();

            if let Some((registration, _)) = final_scan {
                let mut completed = None;
                {
                    let mut state = self.state.lock().unwrap();
                    let scan_complete = scan.next.is_none();
                    if let Some(progress) = state.finalizing.get_mut(&registration) {
                        progress.snapshots.extend(
                            scan.snapshots.iter().map(|snapshot| (snapshot.identity, *snapshot)),
                        );
                        progress.matches.extend(scan.matches.iter().copied());
                        if let Some(next) = scan.next {
                            progress.cursor = next;
                        }
                    }
                    if scan_complete && let Some(progress) = state.finalizing.get_mut(&registration)
                    {
                        let progress = std::mem::take(progress);
                        completed = state
                            .scopes
                            .get(&registration)
                            .cloned()
                            .map(|scope| (scope, progress.snapshots, progress.matches));
                    }
                }
                #[cfg(test)]
                if let Some((scope, _, _)) = completed.as_ref()
                    && let Some(gate) = scope.final_scan_gate.as_ref()
                {
                    gate.pause_once();
                }
                for (scope, identity) in scan.matches {
                    record_tracked_process(&scopes[scope], identity);
                }
                if let Some((scope, snapshots, mut matches)) = completed {
                    let snapshots = snapshots.into_values().collect::<Vec<_>>();
                    include_lineage_matches(std::slice::from_ref(&scope), &snapshots, &mut matches);
                    matches.retain(|(_, identity)| {
                        *identity != scope.root && identity.pid != std::process::id()
                    });
                    let found_owned_process = !matches.is_empty();
                    for (_, identity) in matches {
                        record_tracked_process(&scope, identity);
                    }
                    let mut state = self.state.lock().unwrap();
                    if found_owned_process && state.scopes.contains_key(&registration) {
                        state.revision = state.revision.wrapping_add(1);
                        self.changed.notify_one();
                    } else if state.scopes.remove(&registration).is_some() {
                        state.finalizing.remove(&registration);
                        state.revision = state.revision.wrapping_add(1);
                        self.changed.notify_all();
                    }
                }
            } else {
                for (scope, identity) in scan.matches {
                    record_tracked_process(&scopes[scope], identity);
                }
            }
            let state = self.state.lock().unwrap();
            let _ = self
                .changed
                .wait_timeout_while(state, TRACK_INTERVAL, |state| state.revision == revision)
                .unwrap();
        }
    }
}

fn scope_tracks_before_finalization(_scope: &ScopeRegistration) -> bool {
    #[cfg(test)]
    {
        _scope.track_before_finalization
    }
    #[cfg(not(test))]
    {
        true
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
    tracked.identities.insert(identity);
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

#[cfg(target_os = "macos")]
fn signal_process(identity: ProcessIdentity) {
    let _ = signal_process_with(identity, libc::SIGKILL);
}

#[cfg(target_os = "macos")]
fn signal_process_with(identity: ProcessIdentity, signal: libc::c_int) -> bool {
    let mut token = MacAuditToken { val: [u32::MAX; 8] };
    token.val[5] = identity.pid;
    token.val[7] = identity.started as u32;
    // SAFETY: proc_signal_with_audittoken validates the PID and PID version
    // together in the kernel. It either signals this exact process instance
    // or returns ESRCH after PID reuse.
    unsafe { proc_signal_with_audittoken(&mut token, signal) == 0 }
}

#[cfg(all(unix, not(any(target_os = "linux", target_os = "macos"))))]
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
fn scan_registered_processes(
    scopes: &[ScopeRegistration],
    cursor: ProcessScanCursor,
) -> ProcessScanResult {
    use std::os::unix::fs::MetadataExt as _;

    let mut result = ProcessScanResult::default();
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
    let Ok(processes) = std::fs::read_dir("/proc") else {
        result.next = Some(cursor);
        return result;
    };
    let mut pids = processes
        .flatten()
        .filter_map(|process| {
            process.file_name().to_str().and_then(|value| value.parse::<u32>().ok())
        })
        .collect::<Vec<_>>();
    pids.sort_unstable();
    let mut remaining_file_descriptors = MAX_SCAN_FILE_DESCRIPTORS;
    let mut last_completed_pid = cursor.after_pid;
    let resumed_pid = cursor.file_descriptors.map(|(pid, _)| pid);
    for (inspected_processes, pid) in pids
        .into_iter()
        .filter(|pid| *pid > cursor.after_pid || resumed_pid == Some(*pid))
        .enumerate()
    {
        if inspected_processes >= MAX_SCAN_PROCESSES {
            result.next =
                Some(ProcessScanCursor { after_pid: last_completed_pid, file_descriptors: None });
            include_lineage_matches(scopes, &result.snapshots, &mut result.matches);
            return result;
        }
        let process = std::path::PathBuf::from(format!("/proc/{pid}"));
        let Some(snapshot) = std::fs::read_to_string(process.join("stat"))
            .ok()
            .and_then(|stat| linux_process_snapshot_from_stat(pid, &stat))
        else {
            last_completed_pid = pid;
            continue;
        };
        result.snapshots.push(snapshot);
        if snapshot.identity.started < earliest_start {
            last_completed_pid = pid;
            continue;
        }
        if let Ok(environment) = std::fs::read(process.join("environ")) {
            for entry in environment.split(|byte| *byte == 0) {
                for (scope, expected) in expected.iter().enumerate() {
                    if entry == expected {
                        result.matches.insert((scope, snapshot.identity));
                    }
                }
            }
        }
        if let Ok(fds) = std::fs::read_dir(process.join("fd")) {
            let after_fd = cursor
                .file_descriptors
                .filter(|(resume_pid, _)| *resume_pid == pid)
                .map_or(-1, |(_, fd)| fd);
            let mut fds = fds
                .flatten()
                .filter_map(|fd| {
                    let number = fd
                        .file_name()
                        .to_str()
                        .and_then(|value| value.parse::<libc::c_int>().ok())?;
                    Some((number, fd.path()))
                })
                .filter(|(fd, _)| *fd > after_fd)
                .collect::<Vec<_>>();
            fds.sort_unstable_by_key(|(fd, _)| *fd);
            let mut last_fd = after_fd;
            for (fd, path) in fds {
                if remaining_file_descriptors == 0 {
                    result.next = Some(ProcessScanCursor {
                        after_pid: last_completed_pid,
                        file_descriptors: Some((pid, last_fd)),
                    });
                    include_lineage_matches(scopes, &result.snapshots, &mut result.matches);
                    return result;
                }
                remaining_file_descriptors -= 1;
                last_fd = fd;
                let Some(marker) = std::fs::metadata(path)
                    .ok()
                    .map(|metadata| FileMarker { device: metadata.dev(), inode: metadata.ino() })
                else {
                    continue;
                };
                if let Some(scope_indexes) = file_markers.get(&marker) {
                    for scope in scope_indexes {
                        result.matches.insert((*scope, snapshot.identity));
                    }
                }
            }
        }
        last_completed_pid = pid;
    }
    include_lineage_matches(scopes, &result.snapshots, &mut result.matches);
    result
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
fn scan_registered_processes(
    scopes: &[ScopeRegistration],
    cursor: ProcessScanCursor,
) -> ProcessScanResult {
    let mut result = ProcessScanResult::default();
    const PROC_ALL_PIDS: u32 = 1;
    let bytes = unsafe { libc::proc_listpids(PROC_ALL_PIDS, 0, std::ptr::null_mut(), 0) };
    let Ok(bytes) = usize::try_from(bytes) else {
        result.next = Some(cursor);
        return result;
    };
    let mut pids = vec![0 as libc::pid_t; bytes / size_of::<libc::pid_t>() + 32];
    let Ok(capacity) = libc::c_int::try_from(pids.len() * size_of::<libc::pid_t>()) else {
        result.next = Some(cursor);
        return result;
    };
    let written =
        unsafe { libc::proc_listpids(PROC_ALL_PIDS, 0, pids.as_mut_ptr().cast(), capacity) };
    let Ok(written) = usize::try_from(written) else {
        result.next = Some(cursor);
        return result;
    };
    let Some(mut arguments) = mac_process_argument_buffer() else {
        result.next = Some(cursor);
        return result;
    };
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
    let mut pids = pids
        .into_iter()
        .take(written / size_of::<libc::pid_t>())
        .filter_map(|pid| u32::try_from(pid).ok())
        .filter(|pid| *pid != 0)
        .collect::<Vec<_>>();
    pids.sort_unstable();
    pids.dedup();
    let mut remaining_file_descriptors = MAX_SCAN_FILE_DESCRIPTORS;
    let mut last_completed_pid = cursor.after_pid;
    let resumed_pid = cursor.file_descriptors.map(|(pid, _)| pid);
    for (inspected_processes, pid) in pids
        .into_iter()
        .filter(|pid| *pid > cursor.after_pid || resumed_pid == Some(*pid))
        .enumerate()
    {
        if inspected_processes >= MAX_SCAN_PROCESSES {
            result.next =
                Some(ProcessScanCursor { after_pid: last_completed_pid, file_descriptors: None });
            include_lineage_matches(scopes, &result.snapshots, &mut result.matches);
            return result;
        }
        let Some(snapshot) = mac_process_snapshot(pid) else {
            last_completed_pid = pid;
            continue;
        };
        result.snapshots.push(snapshot);
        if snapshot.identity.started < earliest_start {
            last_completed_pid = pid;
            continue;
        }
        if let Some(process_arguments) = mac_process_arguments(pid, &mut arguments) {
            for (scope, expected) in expected.iter().enumerate() {
                if mac_environment_contains(process_arguments, expected) {
                    result.matches.insert((scope, snapshot.identity));
                }
            }
        }
        let after_fd = cursor
            .file_descriptors
            .filter(|(resume_pid, _)| *resume_pid == pid)
            .map_or(-1, |(_, fd)| fd);
        let file_scan = mac_process_file_markers(pid, after_fd, &mut remaining_file_descriptors);
        for marker in file_scan.markers {
            if let Some(scope_indexes) = file_markers.get(&marker) {
                for scope in scope_indexes {
                    result.matches.insert((*scope, snapshot.identity));
                }
            }
        }
        if let Some(last_fd) = file_scan.next_fd {
            result.next = Some(ProcessScanCursor {
                after_pid: last_completed_pid,
                file_descriptors: Some((pid, last_fd)),
            });
            include_lineage_matches(scopes, &result.snapshots, &mut result.matches);
            return result;
        }
        last_completed_pid = pid;
    }
    include_lineage_matches(scopes, &result.snapshots, &mut result.matches);
    result
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
#[derive(Clone, Copy)]
#[repr(C)]
struct MacProcessUniqueInfo {
    _uuid: [u8; 16],
    _unique_id: u64,
    _parent_unique_id: u64,
    id_version: i32,
    _original_parent_id_version: i32,
    _reserved2: u64,
    _reserved3: u64,
}

#[cfg(target_os = "macos")]
#[repr(C)]
struct MacBsdInfoWithUniqueId {
    bsd: libc::proc_bsdinfo,
    unique: MacProcessUniqueInfo,
}

#[cfg(target_os = "macos")]
#[repr(C)]
struct MacAuditToken {
    val: [u32; 8],
}

#[cfg(target_os = "macos")]
unsafe extern "C" {
    fn proc_signal_with_audittoken(token: *mut MacAuditToken, signal: libc::c_int) -> libc::c_int;
}

#[cfg(target_os = "macos")]
#[repr(C)]
struct VnodeFdInfo {
    _file: ProcFileInfo,
    vnode: libc::vnode_info,
}

#[cfg(target_os = "macos")]
struct MacFileMarkerScan {
    markers: Vec<FileMarker>,
    next_fd: Option<libc::c_int>,
}

#[cfg(target_os = "macos")]
fn mac_process_file_markers(
    pid: u32,
    after_fd: libc::c_int,
    remaining: &mut usize,
) -> MacFileMarkerScan {
    const PROC_PIDFDVNODEINFO: libc::c_int = 1;
    let empty = || MacFileMarkerScan { markers: Vec::new(), next_fd: None };
    let Ok(pid_int) = libc::c_int::try_from(pid) else { return empty() };
    let bytes =
        unsafe { libc::proc_pidinfo(pid_int, libc::PROC_PIDLISTFDS, 0, std::ptr::null_mut(), 0) };
    let Ok(bytes) = usize::try_from(bytes) else { return empty() };
    let mut fds =
        Vec::<libc::proc_fdinfo>::with_capacity(bytes / size_of::<libc::proc_fdinfo>() + 8);
    let Ok(capacity) = libc::c_int::try_from(fds.capacity() * size_of::<libc::proc_fdinfo>())
    else {
        return empty();
    };
    let written = unsafe {
        libc::proc_pidinfo(pid_int, libc::PROC_PIDLISTFDS, 0, fds.as_mut_ptr().cast(), capacity)
    };
    let Ok(written) = usize::try_from(written) else { return empty() };
    let count = written / size_of::<libc::proc_fdinfo>();
    // SAFETY: proc_pidinfo initialized `count` entries within the allocation.
    unsafe {
        fds.set_len(count.min(fds.capacity()));
    }
    fds.sort_unstable_by_key(|fd| fd.proc_fd);
    let mut markers = Vec::new();
    let mut last_fd = after_fd;
    for fd in fds.into_iter().filter(|fd| fd.proc_fd > after_fd) {
        if *remaining == 0 {
            return MacFileMarkerScan { markers, next_fd: Some(last_fd) };
        }
        *remaining -= 1;
        last_fd = fd.proc_fd;
        let marker = (|| {
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
        })();
        if let Some(marker) = marker {
            markers.push(marker);
        }
    }
    MacFileMarkerScan { markers, next_fd: None }
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
fn mac_process_arguments(pid: u32, buffer: &mut [u8]) -> Option<&[u8]> {
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
    const PROC_PIDT_BSDINFOWITHUNIQID: libc::c_int = 18;
    let pid_int = libc::c_int::try_from(pid).ok()?;
    let mut info = std::mem::MaybeUninit::<MacBsdInfoWithUniqueId>::zeroed();
    let size = libc::c_int::try_from(size_of::<MacBsdInfoWithUniqueId>()).ok()?;
    let written = unsafe {
        libc::proc_pidinfo(pid_int, PROC_PIDT_BSDINFOWITHUNIQID, 0, info.as_mut_ptr().cast(), size)
    };
    if written != size {
        return None;
    }
    // SAFETY: proc_pidinfo initialized the full structure.
    let info = unsafe { info.assume_init() };
    // Keep chronological start time in the high bits for scan filtering and
    // the kernel PID version in the low bits for race-free signal delivery.
    let started = (u128::from(info.bsd.pbi_start_tvsec) << 64)
        | (u128::from(info.bsd.pbi_start_tvusec) << 32)
        | u128::from(info.unique.id_version as u32);
    Some(ProcessSnapshot { identity: ProcessIdentity { pid, started }, parent: info.bsd.pbi_ppid })
}

#[cfg(all(unix, not(any(target_os = "linux", target_os = "macos"))))]
fn scan_registered_processes(
    _scopes: &[ScopeRegistration],
    _cursor: ProcessScanCursor,
) -> ProcessScanResult {
    ProcessScanResult::default()
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
        let stat = "12 (name with ) marker) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 4242";
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

    #[cfg(target_os = "macos")]
    #[test]
    fn mac_process_scope_launcher_stops_before_the_requested_program() {
        let command = UnixProcessScope::suspended_command("/usr/bin/false");
        let arguments = command
            .get_args()
            .map(|argument| argument.to_string_lossy().into_owned())
            .collect::<Vec<_>>();
        assert_eq!(
            arguments,
            [
                "-p",
                "(version 1) (allow default) (deny process-fork)",
                "/bin/sh",
                "-c",
                "kill -STOP $$; exec \"$@\"",
                "cmux-process-scope",
                "/usr/bin/false",
            ]
        );
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn mac_process_scope_runs_the_requested_program() {
        let mut scope = UnixProcessScope::prepare().unwrap();
        let mut command = UnixProcessScope::suspended_command("/usr/bin/false");
        command
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null());
        scope.configure(&mut command);
        let mut child = command.spawn().unwrap();
        scope.bind(child.id()).unwrap();
        let status = child.wait().unwrap();
        assert!(!status.success(), "the macOS process scope did not run the requested program");
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn mac_process_scope_denies_descendant_creation() {
        let mut scope = UnixProcessScope::prepare().unwrap();
        let helper = std::env::current_exe().unwrap();
        let mut command = UnixProcessScope::suspended_command(helper.as_os_str());
        command
            .args([
                "--exact",
                "unix_process_scope::tests::mac_process_scope_descendant_probe",
                "--ignored",
            ])
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null());
        scope.configure(&mut command);
        let mut child = command.spawn().unwrap();
        scope.bind(child.id()).unwrap();
        let status = child.wait().unwrap();
        assert!(status.success(), "the macOS process sandbox allowed a hook descendant");
    }

    #[cfg(target_os = "macos")]
    #[test]
    #[ignore = "run only as the child of mac_process_scope_denies_descendant_creation"]
    fn mac_process_scope_descendant_probe() {
        // SAFETY: the child exits immediately without touching shared Rust state.
        let descendant = unsafe { libc::fork() };
        if descendant == 0 {
            // SAFETY: _exit terminates the fork child without running Rust destructors.
            unsafe { libc::_exit(0) };
        }
        if descendant > 0 {
            let mut status = 0;
            // SAFETY: descendant is the child PID returned by fork.
            unsafe { libc::waitpid(descendant, &mut status, 0) };
            panic!("the macOS process sandbox allowed a descendant");
        }
    }
}
