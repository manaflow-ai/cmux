//! One authenticated SSH connection per connect.
//!
//! A connect runs several `ssh` processes: the `remote-probe`, each install
//! step, and the carrier's `remote-link`. Without connection sharing, each one
//! authenticates on its own, so a password-only host asks for the password
//! once per process (https://github.com/manaflow-ai/cmux/issues/38157).
//!
//! [`SshConnectionShare`] opens one OpenSSH control master per target (the
//! only process that authenticates, and the only one that can prompt) and
//! sends every other run through it with `ControlMaster=no` and its private
//! `ControlPath`. The share records how long authentication took in an
//! [`SshAuthClock`], so startup deadlines can leave out the time a person
//! spends typing a password.
//!
//! cmux never reads, types or stores the password: `ssh` prompts on the
//! terminal itself.

use std::collections::HashMap;
use std::fmt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex as StdMutex};
use std::time::{Duration, Instant};

use cmux_process::{Child, Command, Stdio};
use tokio::io::{AsyncBufReadExt, AsyncReadExt};
use tokio::sync::Mutex;

use crate::ssh_args::{caller_manages_connection_sharing, private_master_ssh_arguments};

/// How long the master may take to connect and authenticate. A person types
/// the password in this window, so it is far longer than a command timeout;
/// Ctrl-C still ends it at once.
pub const SSH_MASTER_AUTH_TIMEOUT: Duration = Duration::from_secs(300);
/// Printed by the master's `LocalCommand`. OpenSSH runs `LocalCommand` after
/// authentication and after the control socket listens (ssh.c
/// `ssh_session2`), so the line is the signal that clients can attach.
const READY_TOKEN: &str = "cmux-ssh-master-ready";
const READY_OUTPUT_LIMIT: u64 = 64 * 1024;
/// `sun_path` is 104 bytes on macOS. OpenSSH binds `<ControlPath>.<16
/// random chars>` first and renames it, so the path needs 17 bytes of room.
const MAX_CONTROL_PATH_BYTES: usize = 104 - 1 - 17;
static NEXT_DIRECTORY_NONCE: AtomicU64 = AtomicU64::new(1);

/// The `ssh` invocation a master serves: runs share a master only when they
/// would reach the same host the same way.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct SshTarget {
    pub ssh_binary: String,
    pub destination: String,
    pub port: Option<u16>,
    pub extra_args: Vec<String>,
}

/// Why the shared connection could not be opened.
#[derive(Debug)]
pub enum SshConnectionError {
    /// `ssh` could not be started or its control directory made.
    Io(std::io::Error),
    /// `ssh` exited before it authenticated (wrong password, refused key,
    /// unreachable host). Its own message already went to the terminal.
    Exited { status: Option<i32> },
    /// No authenticated connection within [`SSH_MASTER_AUTH_TIMEOUT`].
    Timeout,
}

impl fmt::Display for SshConnectionError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(error) => write!(formatter, "could not start the SSH connection: {error}"),
            Self::Exited { status: Some(status) } => {
                write!(formatter, "SSH could not connect and authenticate (ssh exited {status})")
            }
            Self::Exited { status: None } => {
                formatter.write_str("SSH could not connect and authenticate (ssh was stopped)")
            }
            Self::Timeout => write!(
                formatter,
                "SSH did not connect and authenticate within {}s",
                SSH_MASTER_AUTH_TIMEOUT.as_secs()
            ),
        }
    }
}

impl std::error::Error for SshConnectionError {}

/// Time spent opening authenticated SSH connections, which startup
/// deadlines leave out. Shared across threads; reads never block on ssh.
#[derive(Debug, Default)]
pub struct SshAuthClock {
    state: StdMutex<HashMap<SshTarget, AuthClockState>>,
}

#[derive(Debug, Default)]
struct AuthClockState {
    active: usize,
    active_since: Option<Instant>,
    intervals: Vec<(Instant, Instant)>,
}

impl SshAuthClock {
    /// Authentication time up to `now`, including a run still in progress.
    pub fn excluded(&self, now: Instant) -> Duration {
        let state = self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let intervals = state.values().flat_map(|state| state.intervals_until(now)).collect();
        merged_interval_duration(intervals)
    }

    /// Authentication time for one SSH target, up to `now`.
    pub fn excluded_for(&self, target: &SshTarget, now: Instant) -> Duration {
        let state = self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        state.get(target).map_or(Duration::ZERO, |state| state.excluded(now))
    }

    /// Authentication time for a set of SSH targets, counting overlapping
    /// prompts once because a deadline advances in wall-clock time.
    pub fn excluded_for_targets(&self, targets: &[SshTarget], now: Instant) -> Duration {
        let state = self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let intervals = targets
            .iter()
            .filter_map(|target| state.get(target))
            .flat_map(|state| state.intervals_until(now))
            .collect();
        merged_interval_duration(intervals)
    }

    fn begin(self: &Arc<Self>, target: SshTarget) -> AuthClockGuard {
        let mut clocks = self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let state = clocks.entry(target.clone()).or_default();
        if state.active == 0 {
            state.active_since = Some(Instant::now());
        }
        state.active += 1;
        AuthClockGuard { clock: Arc::clone(self), target }
    }
}

impl AuthClockState {
    fn excluded(&self, now: Instant) -> Duration {
        merged_interval_duration(self.intervals_until(now))
    }

    fn intervals_until(&self, now: Instant) -> Vec<(Instant, Instant)> {
        let mut intervals = self.intervals.clone();
        if let Some(since) = self.active_since {
            intervals.push((since, now));
        }
        intervals
    }

    fn record(&mut self, start: Instant, end: Instant) {
        if let Some((_, previous_end)) = self.intervals.last_mut()
            && start <= *previous_end
        {
            *previous_end = (*previous_end).max(end);
        } else {
            self.intervals.push((start, end));
        }
    }
}

fn merged_interval_duration(mut intervals: Vec<(Instant, Instant)>) -> Duration {
    intervals.sort_unstable_by_key(|(start, _)| *start);
    let Some((mut current_start, mut current_end)) = intervals.pop() else {
        return Duration::ZERO;
    };
    let mut total = Duration::ZERO;
    for (start, end) in intervals.into_iter().rev() {
        if end >= current_start {
            current_start = current_start.min(start);
            current_end = current_end.max(end);
        } else {
            total = total.saturating_add(current_end.saturating_duration_since(current_start));
            current_start = start;
            current_end = end;
        }
    }
    total.saturating_add(current_end.saturating_duration_since(current_start))
}

struct AuthClockGuard {
    clock: Arc<SshAuthClock>,
    target: SshTarget,
}

impl Drop for AuthClockGuard {
    fn drop(&mut self) {
        let mut clocks = self.clock.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let Some(state) = clocks.get_mut(&self.target) else { return };
        state.active = state.active.saturating_sub(1);
        if state.active == 0
            && let Some(since) = state.active_since.take()
        {
            state.record(since, Instant::now());
        }
    }
}

/// Shares one authenticated connection per [`SshTarget`] among every `ssh`
/// run of one connect. Clones share the same masters; the last clone to drop
/// closes them. The default share is off: each run authenticates itself.
#[derive(Clone, Default)]
pub struct SshConnectionShare {
    inner: Option<Arc<ShareInner>>,
}

type SharedTarget = Arc<SharedTargetInner>;

struct SharedTargetInner {
    shared: Mutex<Option<Shared>>,
    reconnect_generation: AtomicU64,
}

struct ShareInner {
    masters: Mutex<HashMap<SshTarget, SharedTarget>>,
    clock: Arc<SshAuthClock>,
}

impl fmt::Debug for SshConnectionShare {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("SshConnectionShare")
            .field("enabled", &self.inner.is_some())
            .finish_non_exhaustive()
    }
}

impl SshConnectionShare {
    /// A share that opens control masters. OpenSSH control sockets are Unix
    /// sockets, so elsewhere this is the same as [`Self::disabled`].
    pub fn new() -> Self {
        if cfg!(unix) {
            Self {
                inner: Some(Arc::new(ShareInner {
                    masters: Mutex::new(HashMap::new()),
                    clock: Arc::new(SshAuthClock::default()),
                })),
            }
        } else {
            Self::disabled()
        }
    }

    pub fn disabled() -> Self {
        Self { inner: None }
    }

    /// The clock of authentication time, or `None` when sharing is off.
    pub fn auth_clock(&self) -> Option<Arc<SshAuthClock>> {
        self.inner.as_ref().map(|inner| Arc::clone(&inner.clock))
    }

    /// Retry unavailable control sockets on the next reconnect, while keeping
    /// live masters and coalescing concurrent runs for each target.
    pub async fn retry_unavailable(&self, targets: &[SshTarget]) {
        let Some(inner) = &self.inner else { return };
        let masters = inner.masters.lock().await;
        for target in targets {
            if let Some(entry) = masters.get(target) {
                entry.reconnect_generation.fetch_add(1, Ordering::AcqRel);
            }
        }
    }

    /// Options that send one `ssh` run for `target` through the shared
    /// connection, opening it first when none is alive. They go before the
    /// caller's own options so they win. Empty when sharing is off or the
    /// caller set up connection sharing itself (`-S`, `-M`, `ControlPath`,
    /// `ControlMaster`): that run then connects as before.
    pub async fn client_arguments(
        &self,
        target: &SshTarget,
    ) -> Result<Vec<String>, SshConnectionError> {
        let Some(inner) = &self.inner else { return Ok(Vec::new()) };
        if caller_manages_connection_sharing(&target.extra_args) {
            return Ok(Vec::new());
        }
        // Only runs for the same target wait for its authentication. Never
        // hold the map lock while a person is typing a password.
        let entry = {
            let mut masters = inner.masters.lock().await;
            Arc::clone(masters.entry(target.clone()).or_insert_with(|| {
                Arc::new(SharedTargetInner {
                    shared: Mutex::new(None),
                    reconnect_generation: AtomicU64::new(0),
                })
            }))
        };
        let mut shared = entry.shared.lock().await;
        let generation = entry.reconnect_generation.load(Ordering::Acquire);
        let live = match shared.as_mut() {
            Some(Shared::Master(master)) => master.is_alive().then(|| master.client_arguments()),
            Some(Shared::Unavailable(failed_generation)) if *failed_generation == generation => {
                return Ok(Vec::new());
            }
            _ => None,
        };
        if let Some(arguments) = live {
            return Ok(arguments);
        }
        *shared = None;
        let _clock = inner.clock.begin(target.clone());
        let opened = ControlMaster::open(target).await;
        let opened = match opened {
            Ok(opened) => opened,
            Err(error) => {
                drop(shared);
                remove_unused_entry(inner, target, &entry).await;
                return Err(error);
            }
        };
        match opened {
            Some(master) => {
                let arguments = master.client_arguments();
                *shared = Some(Shared::Master(Box::new(master)));
                Ok(arguments)
            }
            None => {
                // A reconnect may have started while authentication was in
                // flight. Cache the failure under the generation that is
                // current now, so that newer work does not immediately retry
                // the same unavailable socket because it observed an old
                // generation before opening the master.
                let generation = entry.reconnect_generation.load(Ordering::Acquire);
                *shared = Some(Shared::Unavailable(generation));
                Ok(Vec::new())
            }
        }
    }
}

async fn remove_unused_entry(inner: &ShareInner, target: &SshTarget, entry: &SharedTarget) {
    // The map owns one reference. If no waiter retained another reference after
    // its per-target lock was released, discard a failed entry so a later run
    // does not grow the map forever.
    // The map and this caller each retain one reference while this helper runs.
    if Arc::strong_count(entry) != 2 {
        return;
    }
    let mut masters = inner.masters.lock().await;
    if masters.get(target).is_some_and(|current| Arc::ptr_eq(current, entry))
        && Arc::strong_count(entry) == 2
    {
        masters.remove(target);
    }
}

/// What the share holds for one target.
enum Shared {
    Master(Box<ControlMaster>),
    /// ssh authenticated but could not listen on a control socket: runs
    /// connect on their own instead of opening (and prompting for) another
    /// master each time. A reconnect expires this negative cache entry.
    Unavailable(u64),
}

/// One `ssh -N` control master, owned by the share. Dropping it ends ssh,
/// which removes its socket.
struct ControlMaster {
    child: Child,
    socket: PathBuf,
    /// Held so the socket's private directory is removed with the master.
    _directory: PrivateDirectory,
}

impl ControlMaster {
    /// Starts the master and waits until it has authenticated and listens.
    /// `Ok(None)`: ssh authenticated but has no control socket (its listen
    /// failed); runs then connect on their own, as before.
    async fn open(target: &SshTarget) -> Result<Option<Self>, SshConnectionError> {
        let directory = PrivateDirectory::create().map_err(SshConnectionError::Io)?;
        let socket = directory.path().join("s");
        let mut command = Command::new(&target.ssh_binary);
        command
            .args(master_arguments(&socket))
            .args(private_master_ssh_arguments(
                target.port,
                &target.extra_args,
                &target.destination,
            ))
            // ssh prompts for a password on /dev/tty, never stdin.
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit());
        // Until ssh is ready, dropping this future (a timeout, a shutdown)
        // must end it: a leftover ssh would keep prompting on the terminal.
        let child = command.spawn().map_err(SshConnectionError::Io)?;
        live_masters::register(&child);
        let mut pending = PendingMaster(Some(child));
        let Some(child) = pending.0.as_mut() else {
            return Err(SshConnectionError::Exited { status: None });
        };
        let Some(stdout) = child.stdout.take() else {
            return Err(SshConnectionError::Io(std::io::Error::other(
                "ssh stdout pipe is unavailable",
            )));
        };
        let ready =
            match tokio::time::timeout(SSH_MASTER_AUTH_TIMEOUT, read_ready_line(stdout)).await {
                Err(_) => return Err(SshConnectionError::Timeout),
                Ok(Err(error)) => return Err(SshConnectionError::Io(error)),
                Ok(Ok(ready)) => ready,
            };
        if !ready || !matches!(child.try_wait(), Ok(None)) {
            // Without the ready line ssh closed stdout because it is exiting.
            // `cmux_process::Child` is the owner and reaps it on drop; stdout's EOF means
            // there is no useful async work left here, so do not block the runtime waiting
            // for a process that may be stuck in its own exit path.
            let status = child.try_wait().ok().flatten().and_then(|status| status.code());
            return Err(SshConnectionError::Exited { status });
        }
        // Disarm: from here the master's Drop owns ending ssh.
        let Some(child) = pending.0.take() else {
            return Err(SshConnectionError::Exited { status: None });
        };
        let master = Self { child, socket, _directory: directory };
        if !socket_exists(&master.socket) {
            return Ok(None);
        }
        Ok(Some(master))
    }

    fn is_alive(&mut self) -> bool {
        // A reaped master's pid could be reused: drop it from the exit hook's
        // list first. The caller drops a dead master right after this.
        if !matches!(self.child.try_wait(), Ok(None)) {
            live_masters::unregister(&self.child);
            return false;
        }
        socket_exists(&self.socket)
    }

    fn client_arguments(&self) -> Vec<String> {
        vec![
            "-o".into(),
            "ControlMaster=no".into(),
            "-o".into(),
            format!("ControlPath={}", control_path_value(&self.socket)),
        ]
    }
}

impl Drop for ControlMaster {
    fn drop(&mut self) {
        live_masters::unregister(&self.child);
        #[cfg(unix)]
        if let Ok(pid) = libc::pid_t::try_from(self.child.id())
            && matches!(self.child.try_wait(), Ok(None))
        {
            // SAFETY: `pid` is our own unreaped child, so it names that ssh.
            unsafe {
                libc::kill(pid, libc::SIGTERM);
            }
        }
        let _ = std::fs::remove_file(&self.socket);
    }
}

/// An ssh that is not yet a ready master. Dropping it kills and reaps ssh.
struct PendingMaster(Option<Child>);

impl Drop for PendingMaster {
    fn drop(&mut self) {
        if let Some(child) = self.0.as_mut() {
            live_masters::unregister(child);
            if matches!(child.try_wait(), Ok(None)) {
                let _ = child.kill();
            }
        }
    }
}

/// Masters this process started and has not reaped. A process exit that
/// skips destructors (`std::process::exit`, a return from `main` with the
/// runtime thread still running) ends them through an `atexit` hook, so the
/// authenticated connection does not linger after cmux.
mod live_masters {
    use std::sync::Mutex;
    #[cfg(unix)]
    use std::sync::Once;

    use cmux_process::Child;

    static PIDS: Mutex<Vec<i32>> = Mutex::new(Vec::new());
    #[cfg(unix)]
    static HOOK: Once = Once::new();

    pub(super) fn register(child: &Child) {
        let Ok(pid) = i32::try_from(child.id()) else { return };
        #[cfg(unix)]
        HOOK.call_once(|| {
            // SAFETY: registers a plain `extern "C"` function with no
            // captured state.
            unsafe {
                libc::atexit(end_all);
            }
        });
        PIDS.lock().unwrap_or_else(std::sync::PoisonError::into_inner).push(pid);
    }

    /// Called before the child is reaped or dropped, so a listed pid always
    /// names our own child (a zombie keeps its pid until it is reaped).
    pub(super) fn unregister(child: &Child) {
        let Ok(pid) = i32::try_from(child.id()) else { return };
        PIDS.lock().unwrap_or_else(std::sync::PoisonError::into_inner).retain(|live| *live != pid);
    }

    #[cfg(unix)]
    extern "C" fn end_all() {
        // try_lock: exit may run while another thread holds the lock.
        if let Ok(pids) = PIDS.try_lock() {
            for pid in pids.iter() {
                // SAFETY: every listed pid is an unreaped child of this process.
                unsafe {
                    libc::kill(*pid, libc::SIGTERM);
                }
            }
        }
    }
}

/// Reads ssh's stdout until the ready line (`true`) or EOF (`false`). It
/// does not wait for EOF after the line: OpenSSH before 7.7 keeps stdout
/// open after `LocalCommand`. Shell startup output before the line is
/// skipped, up to a bound.
async fn read_ready_line(stdout: std::process::ChildStdout) -> std::io::Result<bool> {
    let stdout = tokio::process::ChildStdout::from_std(stdout)?;
    let mut lines = tokio::io::BufReader::new(stdout.take(READY_OUTPUT_LIMIT)).lines();
    while let Some(line) = lines.next_line().await? {
        if line.trim() == READY_TOKEN {
            return Ok(true);
        }
    }
    Ok(false)
}

/// Options that make an `ssh -N` run this share's master: it authenticates,
/// listens on `socket`, prints the ready line and opens no session.
fn master_arguments(socket: &Path) -> Vec<String> {
    vec![
        "-N".into(),
        "-o".into(),
        "ControlMaster=yes".into(),
        "-o".into(),
        format!("ControlPath={}", control_path_value(socket)),
        "-o".into(),
        "ControlPersist=no".into(),
        // The master outlives single runs; without keepalives a connection
        // whose path died silently (sleep, a network change) would look
        // alive for the many minutes TCP takes to give up, and every link
        // and reconnect attempt through it would hang.
        "-o".into(),
        "ServerAliveInterval=15".into(),
        "-o".into(),
        "ServerAliveCountMax=3".into(),
        "-o".into(),
        "PermitLocalCommand=yes".into(),
        "-o".into(),
        format!("LocalCommand=echo {READY_TOKEN}"),
    ]
}

/// ssh expands `%` tokens in `ControlPath`.
fn control_path_value(socket: &Path) -> String {
    socket.to_string_lossy().replace('%', "%%")
}

fn socket_exists(path: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::FileTypeExt;
        std::fs::symlink_metadata(path).is_ok_and(|metadata| metadata.file_type().is_socket())
    }
    #[cfg(not(unix))]
    {
        path.exists()
    }
}

/// An owner-only directory for one control socket, removed on drop.
struct PrivateDirectory {
    path: PathBuf,
}

impl PrivateDirectory {
    fn create() -> std::io::Result<Self> {
        let mut last_error = None;
        for base in [std::env::temp_dir(), PathBuf::from("/tmp")] {
            // Unguessable, so another local user cannot take the name first
            // in a shared /tmp; mkdir fails rather than reuse an existing one.
            let mut random = [0_u8; 8];
            getrandom::fill(&mut random)
                .map_err(|error| std::io::Error::other(error.to_string()))?;
            let random: String = random.iter().map(|byte| format!("{byte:02x}")).collect();
            let name = format!(
                "cmux-ssh-{random}-{}",
                NEXT_DIRECTORY_NONCE.fetch_add(1, Ordering::Relaxed)
            );
            let path = base.join(name);
            // The socket is `<dir>/s`; ssh_config splits values on spaces.
            let fits = path.as_os_str().len() + 2 <= MAX_CONTROL_PATH_BYTES;
            // ssh_config splits values on spaces and quotes, and newer
            // OpenSSH expands `${VAR}` and unescapes `\\` in ControlPath.
            let unsafe_character =
                |c: char| c.is_whitespace() || matches!(c, '"' | '\'' | '\\' | '$');
            if !fits || path.to_string_lossy().chars().any(unsafe_character) {
                continue;
            }
            let mut builder = std::fs::DirBuilder::new();
            #[cfg(unix)]
            {
                use std::os::unix::fs::DirBuilderExt;
                builder.mode(0o700);
            }
            match builder.create(&path) {
                Ok(()) => return Ok(Self { path }),
                Err(error) => last_error = Some(error),
            }
        }
        Err(last_error.unwrap_or_else(|| {
            std::io::Error::other(
                "no temporary directory is short enough for an SSH control socket",
            )
        }))
    }

    fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for PrivateDirectory {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.path);
    }
}

#[cfg(all(test, unix))]
mod tests;
