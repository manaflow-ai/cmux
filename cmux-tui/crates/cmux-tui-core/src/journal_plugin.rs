//! Supervision for userland journal plugins.
//!
//! The core owns only the lifecycle of a plugin process. Agent identity,
//! screen parsing, process discovery, and vendor rules stay outside this
//! module. A plugin communicates through the local resource socket and writes
//! normal journal events, so every frontend observes the same reducer state.

#[cfg(windows)]
use std::mem::size_of;
#[cfg(unix)]
use std::os::unix::process::CommandExt;
#[cfg(windows)]
use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

#[cfg(windows)]
use windows_sys::Win32::Foundation::{CloseHandle, HANDLE, INVALID_HANDLE_VALUE};
#[cfg(windows)]
use windows_sys::Win32::System::Diagnostics::ToolHelp::{
    CreateToolhelp32Snapshot, TH32CS_SNAPTHREAD, THREADENTRY32, Thread32First, Thread32Next,
};
#[cfg(windows)]
use windows_sys::Win32::System::JobObjects::{
    AssignProcessToJobObject, CreateJobObjectW, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JobObjectExtendedLimitInformation,
    SetInformationJobObject, TerminateJobObject,
};
#[cfg(windows)]
use windows_sys::Win32::System::Threading::{
    CREATE_SUSPENDED, OpenProcess, OpenThread, PROCESS_SET_QUOTA, PROCESS_TERMINATE, ResumeThread,
    THREAD_SUSPEND_RESUME,
};

const SUPERVISOR_WAIT: Duration = Duration::from_millis(500);
const MAX_RESTART_DELAY: Duration = Duration::from_secs(30);
const MAX_PLUGIN_COMMAND_ARGS: usize = 256;
const MAX_PLUGIN_COMMAND_ARG_BYTES: usize = 4096;
/// A child must stay healthy for this long before a later crash earns a fresh
/// backoff budget. Without a stability window, a crash loop can reset the
/// counter on every short-lived spawn and retry forever at one second.
const STABLE_RUNTIME: Duration = Duration::from_secs(30);

pub(crate) type JournalPluginExitHandler = Arc<dyn Fn(&str, u64) + Send + Sync + 'static>;

/// A plugin child plus the OS-owned boundary used to stop its descendants.
/// The supervisor must own the whole process tree: a plugin helper that keeps
/// running after the leader exits can otherwise continue to append events
/// after its generation has been fenced.
struct JournalPluginChild {
    child: Child,
    #[cfg(unix)]
    process_group_id: libc::pid_t,
    #[cfg(windows)]
    job: WindowsJournalPluginJob,
}

impl JournalPluginChild {
    fn try_wait(&mut self) -> std::io::Result<Option<ExitStatus>> {
        self.child.try_wait()
    }

    /// Terminate the owned process tree and reap the leader. The group/job
    /// operation runs before `wait`, so descendants are not left behind when
    /// the leader exits first.
    fn terminate(&mut self) {
        self.terminate_descendants();
        let _ = self.child.kill();
        let _ = self.child.wait();
    }

    fn terminate_descendants(&self) {
        #[cfg(unix)]
        {
            if self.process_group_id > 0 {
                // The child is placed in a fresh process group before exec.
                // A negative pid addresses that group, including helpers that
                // inherited it from the plugin.
                unsafe {
                    libc::kill(-self.process_group_id, libc::SIGKILL);
                }
            }
        }
        #[cfg(windows)]
        {
            self.job.terminate_descendants();
        }
    }
}

#[cfg(windows)]
struct WindowsJournalPluginJob {
    // Keep the kernel handle as an integer in the shared supervisor state.
    // `windows_sys::HANDLE` is a raw pointer and therefore is not `Send`,
    // even though Windows kernel handles are process-wide, thread-safe
    // values. Converting at the FFI boundary preserves the ownership model
    // without making an unsafe `Send` promise for the containing state.
    handle: usize,
}

#[cfg(windows)]
impl WindowsJournalPluginJob {
    fn raw_handle(&self) -> HANDLE {
        self.handle as HANDLE
    }

    fn assign(child: &Child) -> std::io::Result<Self> {
        let handle = unsafe { CreateJobObjectW(std::ptr::null(), std::ptr::null()) };
        if handle.is_null() {
            return Err(std::io::Error::last_os_error());
        }
        let job = Self { handle: handle as usize };
        let mut information = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
        information.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        let information_size = u32::try_from(size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>())
            .expect("Windows job information fits in u32");
        if unsafe {
            SetInformationJobObject(
                job.raw_handle(),
                JobObjectExtendedLimitInformation,
                std::ptr::from_ref(&information).cast(),
                information_size,
            )
        } == 0
        {
            return Err(std::io::Error::last_os_error());
        }

        let process = unsafe { OpenProcess(PROCESS_SET_QUOTA | PROCESS_TERMINATE, 0, child.id()) };
        if process.is_null() {
            return Err(std::io::Error::last_os_error());
        }
        let assigned = unsafe { AssignProcessToJobObject(job.raw_handle(), process) };
        let assign_error = (assigned == 0).then(std::io::Error::last_os_error);
        unsafe {
            CloseHandle(process);
        }
        if let Some(error) = assign_error {
            return Err(error);
        }
        Ok(job)
    }

    fn terminate_descendants(&self) {
        unsafe {
            TerminateJobObject(self.raw_handle(), 1);
        }
    }
}

#[cfg(windows)]
impl Drop for WindowsJournalPluginJob {
    fn drop(&mut self) {
        unsafe {
            CloseHandle(self.raw_handle());
        }
    }
}

#[cfg(windows)]
fn resume_suspended_journal_plugin(child: &Child) -> std::io::Result<()> {
    let snapshot = unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0) };
    if snapshot == INVALID_HANDLE_VALUE {
        return Err(std::io::Error::last_os_error());
    }
    let result = (|| {
        let mut entry = THREADENTRY32 {
            dwSize: u32::try_from(size_of::<THREADENTRY32>())
                .expect("Windows thread entry size fits in u32"),
            ..THREADENTRY32::default()
        };
        if unsafe { Thread32First(snapshot, &mut entry) } == 0 {
            return Err(std::io::Error::last_os_error());
        }
        loop {
            if entry.th32OwnerProcessID == child.id() {
                let thread = unsafe { OpenThread(THREAD_SUSPEND_RESUME, 0, entry.th32ThreadID) };
                if thread.is_null() {
                    return Err(std::io::Error::last_os_error());
                }
                let resumed = unsafe { ResumeThread(thread) };
                let error = (resumed == u32::MAX).then(std::io::Error::last_os_error);
                unsafe {
                    CloseHandle(thread);
                }
                return error.map_or(Ok(()), Err);
            }
            if unsafe { Thread32Next(snapshot, &mut entry) } == 0 {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::NotFound,
                    "suspended journal plugin has no thread to resume",
                ));
            }
        }
    })();
    unsafe {
        CloseHandle(snapshot);
    }
    result
}

/// A configured userland journal plugin.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct JournalPluginOptions {
    /// Stable plugin id. It is passed to the plugin and used for diagnostics.
    pub id: String,
    /// Executable plus arguments. The executable must be an absolute path
    /// after config resolution.
    pub command: Vec<String>,
    /// Optional working directory for the plugin process.
    pub cwd: Option<String>,
    /// Artifact revision. A changed revision restarts a running child even
    /// when its command and working directory stay the same.
    pub revision: Option<String>,
}

impl JournalPluginOptions {
    pub fn validate(&self) -> anyhow::Result<()> {
        anyhow::ensure!(!self.id.is_empty(), "journal plugin id must not be empty");
        anyhow::ensure!(self.id.len() <= 64, "journal plugin id is too long");
        anyhow::ensure!(
            self.id.as_bytes().first().is_some_and(|byte| byte.is_ascii_alphanumeric())
                && self.id.bytes().all(|byte| {
                    byte.is_ascii_lowercase()
                        || byte.is_ascii_digit()
                        || byte == b'_'
                        || byte == b'-'
                }),
            "journal plugin id must match [a-z0-9][a-z0-9_-]*"
        );
        anyhow::ensure!(
            self.id != crate::AGENT_HOOK_PRODUCER_ID,
            "journal plugin id is reserved for the built-in agent hook producer"
        );
        let Some(executable) = self.command.first() else {
            anyhow::bail!("journal plugin command must not be empty");
        };
        anyhow::ensure!(!executable.trim().is_empty(), "journal plugin command must not be empty");
        anyhow::ensure!(
            Path::new(executable).is_absolute(),
            "journal plugin command[0] must be an absolute executable path"
        );
        anyhow::ensure!(
            self.command.len() <= MAX_PLUGIN_COMMAND_ARGS,
            "journal plugin command must contain at most {MAX_PLUGIN_COMMAND_ARGS} arguments"
        );
        anyhow::ensure!(
            self.command.iter().all(|argument| {
                argument.len() <= MAX_PLUGIN_COMMAND_ARG_BYTES && !argument.contains('\0')
            }),
            "journal plugin command arguments must be at most {MAX_PLUGIN_COMMAND_ARG_BYTES} bytes and contain no NUL"
        );
        if let Some(cwd) = &self.cwd {
            anyhow::ensure!(
                !cwd.is_empty() && Path::new(cwd).is_absolute() && !cwd.contains('\0'),
                "journal plugin cwd must be an absolute path"
            );
        }
        if let Some(revision) = &self.revision {
            anyhow::ensure!(!revision.is_empty(), "journal plugin revision must not be empty");
            anyhow::ensure!(
                !revision.bytes().any(|byte| byte.is_ascii_control()),
                "journal plugin revision must not contain control characters"
            );
            anyhow::ensure!(revision.len() <= 128, "journal plugin revision is too long");
        }
        Ok(())
    }
}

#[derive(Default)]
struct SupervisorState {
    options: Option<JournalPluginOptions>,
    socket: Option<PathBuf>,
    session: Option<String>,
    child: Option<JournalPluginChild>,
    restart_at: Option<Instant>,
    failures: u32,
    child_started_at: Option<Instant>,
    started: bool,
    stopping: bool,
    generation: u64,
    child_generation: Option<u64>,
    exit_handler: Option<JournalPluginExitHandler>,
}

/// Owns one plugin process and restarts failed children until shutdown. The
/// runtime is deliberately small and has no knowledge of any agent vendor or
/// event schema.
pub struct JournalPluginRuntime {
    state: Arc<(Mutex<SupervisorState>, Condvar)>,
    thread: Mutex<Option<JoinHandle<()>>>,
}

impl Default for JournalPluginRuntime {
    fn default() -> Self {
        Self {
            state: Arc::new((Mutex::new(SupervisorState::default()), Condvar::new())),
            thread: Mutex::new(None),
        }
    }
}

impl JournalPluginRuntime {
    /// Replace the configured plugin. A running child is stopped before the
    /// new command is started, which prevents two plugins writing the same
    /// producer namespace during a config reload.
    pub fn configure(&self, options: Option<JournalPluginOptions>) {
        // An invalid replacement disables the old process. Keeping stale
        // configuration alive after a failed reload would report data that
        // the user just removed or rejected.
        let options = options.and_then(|options| {
            if let Err(error) = options.validate() {
                eprintln!("cmux-tui: disabling invalid journal plugin configuration: {error}");
                None
            } else {
                Some(options)
            }
        });
        let retired = {
            let (lock, changed) = &*self.state;
            let mut state = lock.lock().unwrap_or_else(|error| error.into_inner());
            if state.options == options {
                return;
            }
            let retired = state.child_generation.and_then(|generation| {
                state.options.as_ref().map(|options| (options.id.clone(), generation))
            });
            stop_child(&mut state);
            state.options = options;
            state.generation = next_generation(state.generation);
            state.child_generation = None;
            state.failures = 0;
            state.restart_at = None;
            changed.notify_all();
            (state.exit_handler.clone(), retired)
        };
        // A configuration replacement is also a producer retirement. Notify
        // outside the lock so the callback can append its cleanup event
        // without blocking the supervisor.
        if let (Some(handler), Some((plugin_id, generation))) = retired {
            handler(&plugin_id, generation);
        }
    }

    /// Install the callback used to turn an unexpected child exit into a
    /// generic journal lifecycle event. The callback runs without the
    /// supervisor mutex held.
    pub(crate) fn set_exit_handler(&self, handler: Option<JournalPluginExitHandler>) {
        let (lock, _) = &*self.state;
        lock.lock().unwrap_or_else(|error| error.into_inner()).exit_handler = handler;
    }

    /// Starts supervision after the local socket has been bound. This ordering
    /// gives the plugin an authoritative socket path and avoids a startup race.
    pub fn start(&self, socket: PathBuf, session: String) {
        let (lock, changed) = &*self.state;
        let mut state = lock.lock().unwrap_or_else(|error| error.into_inner());
        state.socket = Some(socket);
        state.session = Some(session);
        if !state.started {
            state.started = true;
            let shared = Arc::clone(&self.state);
            let handle = thread::Builder::new()
                .name("cmux-journal-plugin".into())
                .spawn(move || supervise(shared));
            match handle {
                Ok(handle) => *self.thread.lock().unwrap() = Some(handle),
                Err(error) => {
                    state.started = false;
                    eprintln!("cmux-tui: journal plugin supervisor did not start: {error}");
                }
            }
        }
        changed.notify_all();
    }

    /// Stops the child and joins the supervisor. Shutdown is terminal for this
    /// runtime; construct a new runtime to start supervision again. It is safe
    /// to call more than once, including from `Drop` after an earlier explicit
    /// shutdown.
    pub fn shutdown(&self) {
        let (lock, changed) = &*self.state;
        let retired = {
            let mut state = lock.lock().unwrap_or_else(|error| error.into_inner());
            state.stopping = true;
            let retired = state.child_generation.and_then(|generation| {
                state.options.as_ref().map(|options| (options.id.clone(), generation))
            });
            stop_child(&mut state);
            changed.notify_all();
            (state.exit_handler.clone(), retired)
        };
        // Treat an intentional daemon shutdown as a producer retirement too.
        // Otherwise a restored roster could retain rows from a child that was
        // stopped cleanly and never had a chance to emit session.ended.
        if let (Some(handler), Some((plugin_id, generation))) = retired {
            handler(&plugin_id, generation);
        }
        if let Some(handle) = self.thread.lock().unwrap().take()
            && handle.join().is_err()
        {
            eprintln!("cmux-tui: journal plugin supervisor panicked during shutdown");
        }
    }
}

impl Drop for JournalPluginRuntime {
    fn drop(&mut self) {
        self.shutdown();
    }
}

fn supervise(shared: Arc<(Mutex<SupervisorState>, Condvar)>) {
    loop {
        let (lock, changed) = &*shared;
        let mut state = lock.lock().unwrap_or_else(|error| error.into_inner());
        if state.stopping {
            stop_child(&mut state);
            return;
        }

        let child_status = state.child.as_mut().map(JournalPluginChild::try_wait);
        if let Some(child_status) = child_status {
            match child_status {
                Ok(Some(status)) => {
                    eprintln!("cmux-tui: journal plugin exited with {status}");
                    let (exited_generation, child_started_at) = mark_child_exit(&mut state, false);
                    note_child_failure(&mut state, Instant::now(), child_started_at);
                    let exit_handler = state.exit_handler.clone();
                    let plugin_id = state.options.as_ref().map(|options| options.id.clone());
                    drop(state);
                    if let (Some(handler), Some(plugin_id), Some(generation)) =
                        (exit_handler, plugin_id, exited_generation)
                    {
                        handler(&plugin_id, generation);
                    }
                    continue;
                }
                Ok(None) => {
                    let _ = changed.wait_timeout(state, SUPERVISOR_WAIT);
                    continue;
                }
                Err(error) => {
                    eprintln!("cmux-tui: cannot inspect journal plugin: {error}");
                    let (exited_generation, child_started_at) = mark_child_exit(&mut state, true);
                    note_child_failure(&mut state, Instant::now(), child_started_at);
                    let exit_handler = state.exit_handler.clone();
                    let plugin_id = state.options.as_ref().map(|options| options.id.clone());
                    drop(state);
                    if let (Some(handler), Some(plugin_id), Some(generation)) =
                        (exit_handler, plugin_id, exited_generation)
                    {
                        handler(&plugin_id, generation);
                    }
                    continue;
                }
            }
        }

        let Some(options) = state.options.clone() else {
            let _ = changed.wait_timeout(state, SUPERVISOR_WAIT);
            continue;
        };
        let Some(socket) = state.socket.clone() else {
            let _ = changed.wait_timeout(state, SUPERVISOR_WAIT);
            continue;
        };
        if state.restart_at.is_some_and(|at| at > Instant::now()) {
            let wait = state
                .restart_at
                .and_then(|at| at.checked_duration_since(Instant::now()))
                .unwrap_or(SUPERVISOR_WAIT)
                .min(SUPERVISOR_WAIT);
            let _ = changed.wait_timeout(state, wait);
            continue;
        }
        let session = state.session.clone().unwrap_or_else(|| "main".into());
        let generation = state.generation;
        match spawn_plugin(&options, &socket, &session, generation) {
            Ok(child) => {
                state.child = Some(child);
                state.child_generation = Some(generation);
                state.child_started_at = Some(Instant::now());
                state.restart_at = None;
            }
            Err(error) => {
                eprintln!("cmux-tui: journal plugin failed to start: {error}");
                note_child_failure(&mut state, Instant::now(), None);
            }
        }
    }
}

fn spawn_plugin(
    options: &JournalPluginOptions,
    socket: &PathBuf,
    session: &str,
    generation: u64,
) -> anyhow::Result<JournalPluginChild> {
    let mut command = Command::new(&options.command[0]);
    command
        .args(&options.command[1..])
        .env("CMUX_TUI_SOCKET", socket)
        .env("CMUX_MUX_SOCKET", socket)
        .env("CMUX_TUI_SESSION_ID", session)
        .env("CMUX_PLUGIN_ID", &options.id)
        .env("CMUX_PLUGIN_GENERATION", generation.to_string())
        .env("CMUX_PLUGIN_PROTOCOL_VERSION", "1")
        .env("CMUX_PLUGIN_KIND", "journal")
        .env("CMUX_JOURNAL_PLUGIN", "1")
        // Keep the preview name for plugins that shipped before the generic
        // contract was named. It carries no authority and is only a hint.
        .env("CMUX_AGENT_PLUGIN", "1")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::inherit());
    #[cfg(unix)]
    command.process_group(0);
    #[cfg(windows)]
    command.creation_flags(CREATE_SUSPENDED);
    if let Some(cwd) = &options.cwd {
        command.current_dir(cwd);
    }
    if let Some(revision) = &options.revision {
        command.env("CMUX_PLUGIN_REVISION", revision);
    }
    let child = command.spawn()?;
    #[cfg(unix)]
    {
        let process_group_id = libc::pid_t::try_from(child.id()).map_err(|_| {
            anyhow::anyhow!("journal plugin pid is outside the process-group range")
        })?;
        Ok(JournalPluginChild { process_group_id, child })
    }
    #[cfg(windows)]
    {
        let mut child = child;
        let job = match WindowsJournalPluginJob::assign(&child) {
            Ok(job) => job,
            Err(error) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(anyhow::anyhow!("isolate journal plugin process tree: {error}"));
            }
        };
        if let Err(error) = resume_suspended_journal_plugin(&child) {
            job.terminate_descendants();
            let _ = child.kill();
            let _ = child.wait();
            return Err(anyhow::anyhow!("resume isolated journal plugin: {error}"));
        }
        Ok(JournalPluginChild { child, job })
    }
    #[cfg(not(any(unix, windows)))]
    {
        Ok(JournalPluginChild { child })
    }
}

fn stop_child(state: &mut SupervisorState) {
    if let Some(mut child) = state.child.take() {
        child.terminate();
    }
    state.child_generation = None;
    state.child_started_at = None;
}

/// Retire the observed child and advance the restart fence. The old
/// generation is returned for the cleanup event; the new generation is used
/// only by the next child. The start time is returned separately so the
/// backoff policy can decide whether this was a stable or crash-loop exit.
fn mark_child_exit(
    state: &mut SupervisorState,
    terminate_child: bool,
) -> (Option<u64>, Option<Instant>) {
    if terminate_child {
        if let Some(mut child) = state.child.take() {
            child.terminate();
        }
    } else {
        if let Some(child) = state.child.take() {
            // `try_wait` already reaped the leader. The group/job can still
            // contain helpers, so close that ownership boundary before the
            // wrapper is dropped.
            child.terminate_descendants();
        }
    }
    let exited_generation = state.child_generation.take();
    let child_started_at = state.child_started_at.take();
    if exited_generation.is_some() {
        // A restarted child must receive a new fence even if the old process
        // did not emit a final event. Without this increment, late records
        // from the dead child can be accepted as current after the restart.
        state.generation = next_generation(state.generation);
    }
    (exited_generation, child_started_at)
}

/// Account for a failed launch or child exit. A child that lived through the
/// stability window resets the accumulated crash-loop budget; a short-lived
/// child advances it. Keeping this policy in the generic supervisor avoids
/// embedding agent-specific assumptions in the host.
fn note_child_failure(
    state: &mut SupervisorState,
    now: Instant,
    child_started_at: Option<Instant>,
) {
    if child_started_at.is_some_and(|started_at| now.duration_since(started_at) >= STABLE_RUNTIME) {
        state.failures = 0;
    }
    state.failures = state.failures.saturating_add(1);
    state.restart_at = Some(now + restart_delay(state.failures));
}

fn restart_delay(failures: u32) -> Duration {
    let shift = failures.saturating_sub(1).min(5);
    Duration::from_secs(1_u64 << shift).min(MAX_RESTART_DELAY)
}

fn next_generation(current: u64) -> u64 {
    current.wrapping_add(1).max(1)
}

/// Compatibility aliases for the initial agent-plugin preview. New hosts
/// should use the generic journal-plugin names so the core contract is not
/// tied to one projection or vendor.
pub type AgentPluginOptions = JournalPluginOptions;
pub type AgentPluginRuntime = JournalPluginRuntime;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn options_reject_empty_or_unsafe_commands() {
        let invalid = JournalPluginOptions {
            id: "valid_id".into(),
            command: vec![],
            cwd: None,
            revision: None,
        };
        assert!(invalid.validate().is_err());
        let too_many = JournalPluginOptions {
            id: "valid_id".into(),
            command: (0..=MAX_PLUGIN_COMMAND_ARGS)
                .map(|index| format!("/tmp/plugin-{index}"))
                .collect(),
            cwd: None,
            revision: None,
        };
        assert!(too_many.validate().is_err());
        let invalid_cwd = JournalPluginOptions {
            id: "valid_id".into(),
            command: vec!["/tmp/detector".into()],
            cwd: Some("/tmp/with\0nul".into()),
            revision: None,
        };
        assert!(invalid_cwd.validate().is_err());
        let reserved = JournalPluginOptions {
            id: crate::AGENT_HOOK_PRODUCER_ID.into(),
            command: vec!["/tmp/detector".into()],
            cwd: None,
            revision: None,
        };
        assert!(reserved.validate().is_err());
        let valid = JournalPluginOptions {
            id: "screen_detector".into(),
            command: vec!["/tmp/detector".into()],
            cwd: None,
            revision: Some("abc".into()),
        };
        assert!(valid.validate().is_ok());
    }

    #[test]
    fn restart_delay_is_bounded() {
        assert_eq!(restart_delay(1), Duration::from_secs(1));
        assert_eq!(restart_delay(6), Duration::from_secs(32).min(MAX_RESTART_DELAY));
    }

    #[test]
    fn unexpected_restart_advances_the_generation_fence() {
        assert_eq!(next_generation(0), 1);
        assert_eq!(next_generation(41), 42);
        assert_eq!(next_generation(u64::MAX), 1);

        let mut state = SupervisorState {
            generation: 1,
            child_generation: Some(1),
            ..SupervisorState::default()
        };
        assert_eq!(mark_child_exit(&mut state, false), (Some(1), None));
        assert_eq!(state.generation, 2);
        assert!(state.child_generation.is_none());
    }

    #[test]
    fn crash_backoff_accumulates_for_short_lived_children() {
        let started = Instant::now();
        let mut state = SupervisorState {
            failures: 2,
            child_started_at: Some(started),
            ..SupervisorState::default()
        };

        let child_started_at = state.child_started_at.take();
        note_child_failure(&mut state, started + Duration::from_secs(5), child_started_at);

        assert_eq!(state.failures, 3);
        assert_eq!(state.restart_at, Some(started + Duration::from_secs(9)));
    }

    #[test]
    fn stable_children_reset_the_crash_backoff_budget() {
        let started = Instant::now();
        let mut state = SupervisorState {
            failures: 5,
            child_started_at: Some(started),
            ..SupervisorState::default()
        };

        let child_started_at = state.child_started_at.take();
        note_child_failure(&mut state, started + STABLE_RUNTIME, child_started_at);

        assert_eq!(state.failures, 1);
        assert_eq!(state.restart_at, Some(started + STABLE_RUNTIME + Duration::from_secs(1)));
    }

    #[cfg(windows)]
    #[test]
    fn windows_runtime_can_cross_thread_boundaries() {
        fn assert_send_sync<T: Send + Sync>() {}

        assert_send_sync::<JournalPluginRuntime>();
    }
}
