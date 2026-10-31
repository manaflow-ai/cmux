//! Windows: a session daemon started on a fresh socket answers, and which
//! launches keep it answering after the launcher's Job Object closes.
//!
//! The Windows fork starts its daemon from `%LOCALAPPDATA%\cmux` with
//! `daemon start --session <name> --socket <path>` and then asks it for its
//! terminals (handoff cmux-tui-windows-daemon-start.md). A launcher often
//! runs inside a Job Object that kills its processes when it closes: an ssh
//! or IAP session (limit flags 0x2800 on win-2), an IDE or terminal. A
//! process killed with such a job leaves a 0-byte socket file and its
//! `.spawn-lock` behind (the lock file stays by design, see
//! `SocketStartLock`), and every later connect is refused (WSAECONNREFUSED,
//! 10061).
//!
//! - `daemon ensure` is the detached form: its owner leaves the caller's job
//!   (`CREATE_BREAKAWAY_FROM_JOB`), as the terminal host
//!   (`terminal_host_runtime/sys/windows/standby.rs`) and acpmux's daemon do.
//! - `daemon start` is the foreground owner on every platform: it lives in
//!   the job its launcher gives it, as on Unix it lives in its launcher's
//!   session. A launcher that must outlive its own job passes
//!   `CREATE_BREAKAWAY_FROM_JOB` itself (Chromium's
//!   `LaunchOptions::force_breakaway_from_job_` is a launcher option too) or
//!   runs `daemon ensure`.
//!
//! Each test uses a private data folder and state, so it never reaches a
//! person's real sessions.
#![cfg(windows)]

use std::os::windows::io::AsRawHandle;
use std::os::windows::process::CommandExt;
use std::path::PathBuf;
use std::process::{Child, Command, Output, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use windows_sys::Win32::Foundation::{CloseHandle, HANDLE, WAIT_OBJECT_0, WAIT_TIMEOUT};
use windows_sys::Win32::System::Threading::{
    OpenProcess, PROCESS_SYNCHRONIZE, PROCESS_TERMINATE, TerminateProcess, WaitForSingleObject,
};

const DETACHED_PROCESS: u32 = 0x0000_0008;
const CREATE_NEW_PROCESS_GROUP: u32 = 0x0000_0200;
const CREATE_SUSPENDED: u32 = 0x0000_0004;
const CREATE_BREAKAWAY_FROM_JOB: u32 = 0x0100_0000;
/// What the brief asks of a fresh daemon: an answer within 10 s.
const ANSWER_DEADLINE: Duration = Duration::from_secs(10);

fn test_timeout(timeout: Duration) -> Duration {
    let scale = std::env::var("CMUX_TEST_TIMEOUT_SCALE")
        .ok()
        .and_then(|value| value.parse::<u32>().ok())
        .unwrap_or(1)
        .clamp(1, 16);
    timeout.saturating_mul(scale)
}

fn bin() -> &'static str {
    env!("CARGO_BIN_EXE_cmux-tui")
}

/// A private data folder (the app's `%LOCALAPPDATA%\cmux`), with the session
/// socket, state and config in it. Dropping it stops the session's owner
/// (the exact pid this test learned) and removes the folder.
struct DataDir {
    dir: PathBuf,
    socket: PathBuf,
    session: String,
    owner_pid: Option<u32>,
}

impl DataDir {
    fn new(name: &str) -> Self {
        let stamp =
            SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() % 1_000_000_000;
        // Short: AF_UNIX paths are limited on Windows too.
        let dir = std::env::temp_dir().join(format!("cwds-{name}-{}-{stamp}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        Self {
            socket: dir.join("tui.sock"),
            session: format!("cwds-{name}-{stamp}"),
            dir,
            owner_pid: None,
        }
    }

    fn command(&self) -> Command {
        let mut command = Command::new(bin());
        command
            .current_dir(&self.dir)
            .env("CMUX_TUI_STATE_DIR", self.dir.join("state"))
            .env("CMUX_TUI_CONFIG", self.dir.join("config.json"));
        command
    }

    /// `terminal list --socket <path> --json`, once.
    fn terminal_list(&self) -> Output {
        self.command()
            .args(["terminal", "list", "--socket"])
            .arg(&self.socket)
            .arg("--json")
            .stdin(Stdio::null())
            .output()
            .unwrap()
    }

    /// Polls `terminal list` until it succeeds; panics with the last failure
    /// when `deadline` passes. Returns the parsed list.
    fn wait_for_terminal_list(&self, started: Instant, deadline: Duration) -> serde_json::Value {
        let deadline = started + test_timeout(deadline);
        loop {
            let output = self.terminal_list();
            if output.status.success() {
                return serde_json::from_slice(&output.stdout).unwrap_or_else(|error| {
                    panic!(
                        "terminal list printed no JSON ({error}): {}",
                        String::from_utf8_lossy(&output.stdout)
                    )
                });
            }
            assert!(
                Instant::now() < deadline,
                "the daemon on {} did not answer `terminal list` within {:?}: {:?}\nstdout: {}\nstderr: {}",
                self.socket.display(),
                deadline - started,
                output.status,
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr),
            );
            std::thread::sleep(Duration::from_millis(100));
        }
    }
}

impl Drop for DataDir {
    fn drop(&mut self) {
        let _ = self
            .command()
            .args(["server", "stop", "--json", "--session", &self.session, "--socket"])
            .arg(&self.socket)
            .stdin(Stdio::null())
            .output();
        if let Some(pid) = self.owner_pid {
            // Only the owner this test started, and only if `stop` left it.
            if let Some(process) = Process::open(pid)
                && !process.exits_within(Duration::from_secs(10))
            {
                process.terminate();
            }
        }
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

/// A process handle that can wait on and end one process.
struct Process(HANDLE);

impl Process {
    fn open(pid: u32) -> Option<Self> {
        // SAFETY: a plain Win32 call; the handle is owned by the value.
        let handle = unsafe { OpenProcess(PROCESS_SYNCHRONIZE | PROCESS_TERMINATE, 0, pid) };
        (!handle.is_null()).then_some(Self(handle))
    }

    /// Whether the process ends within `timeout`.
    fn exits_within(&self, timeout: Duration) -> bool {
        let millis = u32::try_from(timeout.as_millis()).unwrap_or(u32::MAX);
        // SAFETY: an open process handle with SYNCHRONIZE access.
        match unsafe { WaitForSingleObject(self.0, millis) } {
            WAIT_OBJECT_0 => true,
            WAIT_TIMEOUT => false,
            other => panic!("WaitForSingleObject: {other} {}", std::io::Error::last_os_error()),
        }
    }

    fn terminate(&self) {
        // SAFETY: an open process handle with PROCESS_TERMINATE access.
        unsafe { TerminateProcess(self.0, 1) };
    }
}

impl Drop for Process {
    fn drop(&mut self) {
        // SAFETY: the handle is owned and closed once.
        unsafe { CloseHandle(self.0) };
    }
}

/// A Job Object like the one an ssh session, a scheduled task or an IDE
/// runs its commands in: it kills every process in it when its last handle
/// closes (`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`) and lets a child leave it
/// (`JOB_OBJECT_LIMIT_BREAKAWAY_OK`).
struct KillOnCloseJob(HANDLE);

impl KillOnCloseJob {
    fn new() -> Self {
        use windows_sys::Win32::System::JobObjects::{
            CreateJobObjectW, JOB_OBJECT_LIMIT_BREAKAWAY_OK, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
            JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JobObjectExtendedLimitInformation,
            SetInformationJobObject,
        };
        // SAFETY: plain Win32 calls on a handle this function owns.
        unsafe {
            let job = CreateJobObjectW(std::ptr::null(), std::ptr::null());
            assert!(!job.is_null(), "CreateJobObjectW: {}", std::io::Error::last_os_error());
            let mut limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std::mem::zeroed();
            limits.BasicLimitInformation.LimitFlags =
                JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_BREAKAWAY_OK;
            let set = SetInformationJobObject(
                job,
                JobObjectExtendedLimitInformation,
                (&raw const limits).cast(),
                size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
            );
            assert_ne!(set, 0, "SetInformationJobObject: {}", std::io::Error::last_os_error());
            Self(job)
        }
    }

    /// Starts `command` suspended, puts it in the job, then resumes it, so
    /// every process it starts begins in the job too.
    fn spawn(&self, command: &mut Command) -> Child {
        use windows_sys::Win32::Foundation::INVALID_HANDLE_VALUE;
        use windows_sys::Win32::System::Diagnostics::ToolHelp::{
            CreateToolhelp32Snapshot, TH32CS_SNAPTHREAD, THREADENTRY32, Thread32First, Thread32Next,
        };
        use windows_sys::Win32::System::JobObjects::AssignProcessToJobObject;
        use windows_sys::Win32::System::Threading::{
            OpenThread, ResumeThread, THREAD_SUSPEND_RESUME,
        };
        let child = command.creation_flags(CREATE_SUSPENDED).spawn().unwrap();
        // SAFETY: plain Win32 calls; every handle opened here is closed here.
        unsafe {
            let assigned = AssignProcessToJobObject(self.0, child.as_raw_handle().cast());
            assert_ne!(
                assigned,
                0,
                "AssignProcessToJobObject: {}",
                std::io::Error::last_os_error()
            );
            let snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
            assert_ne!(snapshot, INVALID_HANDLE_VALUE, "CreateToolhelp32Snapshot");
            let mut entry: THREADENTRY32 = std::mem::zeroed();
            entry.dwSize = size_of::<THREADENTRY32>() as u32;
            let mut resumed = 0;
            let mut more = Thread32First(snapshot, &mut entry) != 0;
            while more {
                if entry.th32OwnerProcessID == child.id() {
                    let thread = OpenThread(THREAD_SUSPEND_RESUME, 0, entry.th32ThreadID);
                    assert!(!thread.is_null(), "OpenThread: {}", std::io::Error::last_os_error());
                    assert_ne!(ResumeThread(thread), u32::MAX, "ResumeThread");
                    CloseHandle(thread);
                    resumed += 1;
                }
                more = Thread32Next(snapshot, &mut entry) != 0;
            }
            CloseHandle(snapshot);
            assert!(resumed > 0, "no thread of the suspended process {} to resume", child.id());
        }
        child
    }
}

impl Drop for KillOnCloseJob {
    fn drop(&mut self) {
        // SAFETY: the handle is owned and closed once. Closing the last
        // handle ends every process still in the job.
        unsafe { CloseHandle(self.0) };
    }
}

/// The handoff's case: `daemon start` launched detached (no console, its own
/// process group, no stdio) from the data folder, on a socket no daemon ever
/// used, answers `terminal list` within 10 s with its (empty) terminal list.
#[test]
fn detached_daemon_start_on_a_fresh_socket_answers_terminal_list() {
    let mut data = DataDir::new("start");
    let started = Instant::now();
    let mut daemon = data
        .command()
        .args(["daemon", "start", "--session", &data.session, "--socket"])
        .arg(&data.socket)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .creation_flags(DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP)
        .spawn()
        .unwrap();
    data.owner_pid = Some(daemon.id());

    let list = data.wait_for_terminal_list(started, ANSWER_DEADLINE);
    assert_eq!(list, serde_json::json!([]), "a fresh session has no terminals");
    assert!(daemon.try_wait().unwrap().is_none(), "the daemon must keep running");
}

/// `daemon ensure` run from a launcher in a kill-on-close Job Object (an ssh
/// session, a scheduled task): once the launcher's job closes, the owner it
/// started still answers. Before the fix the owner stayed in the launcher's
/// job and was killed with it, leaving `tui.sock` and `tui.sock.spawn-lock`
/// with no listener.
#[test]
fn daemon_ensure_owner_outlives_the_launchers_kill_on_close_job() {
    let mut data = DataDir::new("ensure");
    let job = KillOnCloseJob::new();
    let mut ensure = data.command();
    ensure
        .args(["server", "ensure", "--json", "--session", &data.session, "--socket"])
        .arg(&data.socket)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let output = job.spawn(&mut ensure).wait_with_output().unwrap();
    assert!(
        output.status.success(),
        "server ensure failed: {:?}\nstdout: {}\nstderr: {}",
        output.status,
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr),
    );
    let ensured: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(ensured["status"], "started", "{ensured}");
    let pid = u32::try_from(ensured["pid"].as_u64().expect("owner pid")).unwrap();
    data.owner_pid = Some(pid);
    let owner = Process::open(pid).expect("the owner runs after ensure");

    // The launcher is gone; its job closes and kills what is still in it.
    drop(job);
    assert!(
        !owner.exits_within(Duration::from_secs(2)),
        "the owner (pid {pid}) died with its launcher's kill-on-close job; {} is left with no listener",
        data.socket.display(),
    );
    let list = data.wait_for_terminal_list(Instant::now(), ANSWER_DEADLINE);
    assert_eq!(list, serde_json::json!([]), "a fresh session has no terminals");
}

/// What `launcher_in_a_job` hands the helper below: the session, the socket,
/// the creation flags for `daemon start`, and the file to write its pid to.
const LAUNCH_SESSION_ENV: &str = "CWDS_LAUNCH_SESSION";
const LAUNCH_SOCKET_ENV: &str = "CWDS_LAUNCH_SOCKET";
const LAUNCH_FLAGS_ENV: &str = "CWDS_LAUNCH_FLAGS";
const LAUNCH_PID_FILE_ENV: &str = "CWDS_LAUNCH_PID_FILE";
const LAUNCHER_HELPER: &str = "launcher_helper_starts_daemon_start_and_exits";

/// Not a test of its own: the launcher process of
/// `daemon_start_outlives_its_launchers_job_only_when_launched_with_breakaway`.
/// That test runs this binary again with only this test selected, inside a
/// kill-on-close job, so this function is a launcher in a job (an app or a
/// script in an ssh session): it starts `daemon start` with the given
/// creation flags and exits. It does nothing without its environment.
#[test]
// skip-owner: PL-daemon; expiry: 2026-11-06; tracking: handoff/followups.md "skips audit 2026-10-30"
#[ignore = "launcher helper; run by daemon_start_outlives_its_launchers_job_only_when_launched_with_breakaway"]
fn launcher_helper_starts_daemon_start_and_exits() {
    let (Ok(session), Ok(socket), Ok(flags), Ok(pid_file)) = (
        std::env::var(LAUNCH_SESSION_ENV),
        std::env::var(LAUNCH_SOCKET_ENV),
        std::env::var(LAUNCH_FLAGS_ENV),
        std::env::var(LAUNCH_PID_FILE_ENV),
    ) else {
        return;
    };
    // The launcher exits and leaves the daemon running, as an app or script
    // that starts it does; the test that runs this helper stops the daemon.
    #[allow(
        clippy::zombie_processes,
        reason = "Windows has no zombies; the daemon must outlive this launcher"
    )]
    let daemon = Command::new(bin())
        .args(["daemon", "start", "--session", &session, "--socket", &socket])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .creation_flags(flags.parse().unwrap())
        .spawn()
        .unwrap();
    std::fs::write(pid_file, daemon.id().to_string()).unwrap();
}

/// Runs the launcher helper inside `job` with `flags` for `daemon start`;
/// returns the daemon's pid once the launcher has exited.
fn launch_daemon_start_from(job: &KillOnCloseJob, data: &DataDir, flags: u32) -> u32 {
    let pid_file = data.dir.join("daemon.pid");
    let mut launcher = Command::new(std::env::current_exe().unwrap());
    launcher
        .args(["--exact", LAUNCHER_HELPER, "--ignored", "--test-threads=1", "--quiet"])
        .current_dir(&data.dir)
        .env("CMUX_TUI_STATE_DIR", data.dir.join("state"))
        .env("CMUX_TUI_CONFIG", data.dir.join("config.json"))
        .env(LAUNCH_SESSION_ENV, &data.session)
        .env(LAUNCH_SOCKET_ENV, &data.socket)
        .env(LAUNCH_FLAGS_ENV, flags.to_string())
        .env(LAUNCH_PID_FILE_ENV, &pid_file)
        .stdin(Stdio::null());
    // Files, not pipes: the daemon may inherit the launcher's std handles,
    // and a pipe it holds would keep a read open until the daemon exits.
    let log = data.dir.join("launcher.log");
    let log_file = std::fs::File::create(&log).unwrap();
    launcher.stdout(log_file.try_clone().unwrap()).stderr(log_file);
    let status = job.spawn(&mut launcher).wait().unwrap();
    assert!(
        status.success(),
        "the launcher failed: {status:?}\n{}",
        std::fs::read_to_string(&log).unwrap_or_default(),
    );
    std::fs::read_to_string(&pid_file)
        .unwrap_or_else(|error| panic!("the launcher wrote no daemon pid ({error})"))
        .trim()
        .parse()
        .unwrap()
}

/// The contract for whoever runs `daemon start` (the Windows app's
/// `daemon_launch`, a script): the daemon lives in its launcher's job. A
/// launcher in a kill-on-close job (an ssh or IAP session) that starts it
/// with only `DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP` (what
/// `Start-Process` does) loses it when that job closes, which leaves the
/// 0-byte socket file and `.spawn-lock` of the handoff with nothing
/// listening; started with `CREATE_BREAKAWAY_FROM_JOB` as well, the daemon
/// outlives the job and still answers. The first daemon is the control: it
/// proves that this job does kill what stays in it.
#[test]
fn daemon_start_outlives_its_launchers_job_only_when_launched_with_breakaway() {
    let mut inside = DataDir::new("in-job");
    let mut away = DataDir::new("away");
    let job = KillOnCloseJob::new();
    let detached = DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP;
    let inside_pid = launch_daemon_start_from(&job, &inside, detached);
    inside.owner_pid = Some(inside_pid);
    let away_pid = launch_daemon_start_from(&job, &away, detached | CREATE_BREAKAWAY_FROM_JOB);
    away.owner_pid = Some(away_pid);
    let inside_process = Process::open(inside_pid).expect("the in-job daemon runs");
    let away_process = Process::open(away_pid).expect("the breakaway daemon runs");
    // Both answer while the launcher's job is open.
    for data in [&inside, &away] {
        let list = data.wait_for_terminal_list(Instant::now(), ANSWER_DEADLINE);
        assert_eq!(list, serde_json::json!([]), "a fresh session has no terminals");
    }

    drop(job);
    assert!(
        inside_process.exits_within(Duration::from_secs(5)),
        "control: the daemon (pid {inside_pid}) left in its launcher's kill-on-close job must end with it",
    );
    assert!(
        inside.socket.exists() && !inside.terminal_list().status.success(),
        "a daemon killed with its job leaves {} with no listener",
        inside.socket.display(),
    );
    assert!(
        !away_process.exits_within(Duration::from_secs(2)),
        "the daemon (pid {away_pid}) started with CREATE_BREAKAWAY_FROM_JOB died with its launcher's job",
    );
    let list = away.wait_for_terminal_list(Instant::now(), ANSWER_DEADLINE);
    assert_eq!(list, serde_json::json!([]), "a fresh session has no terminals");
}
