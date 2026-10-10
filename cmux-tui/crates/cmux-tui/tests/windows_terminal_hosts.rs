//! Windows per-terminal hosts (bead cx-ko2e, plans/cmux-next/windows-terminal-hosts.md):
//! a terminal survives a daemon restart, as on Unix
//! (terminal_host_recovery.rs `fenced_daemon_shutdown_acks_then_preserves_and_re_adopts_terminal_host`).
//! The daemon's Job Object decides what ends a host that could not break
//! away: a kill-on-close job ends the terminal when it closes (and every tree
//! says so), a plain one does not.
#![cfg(windows)]

use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_tui_core::platform::transport;

fn test_timeout(timeout: Duration) -> Duration {
    let scale = std::env::var("CMUX_TEST_TIMEOUT_SCALE")
        .ok()
        .and_then(|value| value.parse::<u32>().ok())
        .unwrap_or(1)
        .clamp(1, 16);
    timeout.saturating_mul(scale)
}

/// A headless daemon on a private socket and state folder. Dropping it ends
/// its terminals and the daemon (exact child only).
struct Daemon {
    child: Option<Child>,
    socket: PathBuf,
    state: PathBuf,
    dir: PathBuf,
    /// A Job Object without `JOB_OBJECT_LIMIT_BREAKAWAY_OK` that the daemon
    /// (and every daemon `start` starts again) runs in.
    job: Option<NoBreakawayJob>,
}

impl Daemon {
    fn new(name: &str) -> Self {
        Self::with_job(name, None)
    }

    /// A daemon started in a job that forbids breakaway, as under a parent
    /// that keeps its children in a job (some CI runners, IDE terminals).
    /// `kill_on_close`: the job ends its processes when its last handle
    /// closes.
    fn new_in_job_without_breakaway(name: &str, kill_on_close: bool) -> Self {
        Self::with_job(name, Some(NoBreakawayJob::new(kill_on_close)))
    }

    fn with_job(name: &str, job: Option<NoBreakawayJob>) -> Self {
        let stamp =
            SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() % 1_000_000_000;
        // Short: AF_UNIX paths are limited on Windows too.
        let dir = std::env::temp_dir().join(format!("cwth-{name}-{}-{stamp}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let mut daemon =
            Self { child: None, socket: dir.join("mux.sock"), state: dir.join("state"), dir, job };
        daemon.start();
        daemon
    }

    fn start(&mut self) {
        let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
        command
            .args(["--headless", "--socket"])
            .arg(&self.socket)
            .arg("--state")
            .arg(&self.state)
            .env("CMUX_TUI_CONFIG", self.dir.join("config.json"))
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        let child = match &self.job {
            None => command.spawn().unwrap(),
            Some(job) => {
                // Suspended until it is in the job, so every process it
                // starts is in the job too.
                use std::os::windows::process::CommandExt;
                let child = command.creation_flags(CREATE_SUSPENDED).spawn().unwrap();
                job.assign_and_resume(&child);
                child
            }
        };
        self.child = Some(child);
        let deadline = Instant::now() + test_timeout(Duration::from_secs(20));
        while transport::connect(&self.socket).is_err() {
            assert!(Instant::now() < deadline, "daemon did not create {}", self.socket.display());
            std::thread::sleep(Duration::from_millis(25));
        }
    }

    /// The fenced shutdown that keeps terminal hosts (`server stop`).
    fn stop_keeping_terminals(&mut self) {
        let identify = request(&self.socket, serde_json::json!({"id": 1, "cmd": "identify"}));
        let accepted = request(
            &self.socket,
            serde_json::json!({
                "id": 2,
                "cmd": "shutdown-daemon",
                "pid": identify["pid"],
                "generation": identify["generation"],
            }),
        );
        assert_eq!(accepted["accepted"], true, "{accepted}");
        let mut child = self.child.take().unwrap();
        let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
        while child.try_wait().unwrap().is_none() {
            assert!(Instant::now() < deadline, "daemon did not exit after a fenced shutdown");
            std::thread::sleep(Duration::from_millis(10));
        }
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        if self.child.is_some() {
            if let Ok(identify) = std::panic::catch_unwind(|| {
                request(&self.socket, serde_json::json!({"cmd": "identify"}))
            }) {
                let _ = request_response(
                    &self.socket,
                    serde_json::json!({
                        "cmd": "shutdown-daemon",
                        "pid": identify["pid"],
                        "generation": identify["generation"],
                        "end_terminals": true,
                    }),
                );
            }
            if let Some(mut child) = self.child.take() {
                let deadline = Instant::now() + Duration::from_secs(15);
                while child.try_wait().ok().flatten().is_none() && Instant::now() < deadline {
                    std::thread::sleep(Duration::from_millis(50));
                }
                let _ = child.kill();
                let _ = child.wait();
            }
        }
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

const CREATE_SUSPENDED: u32 = 0x0000_0004;

/// An unnamed Job Object without `JOB_OBJECT_LIMIT_BREAKAWAY_OK`: a process
/// in it cannot start a child with `CREATE_BREAKAWAY_FROM_JOB`
/// (`ERROR_ACCESS_DENIED`). With `kill_on_close` it has
/// `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`: dropping it (the last handle) ends
/// every process in it.
struct NoBreakawayJob(windows_sys::Win32::Foundation::HANDLE);

impl NoBreakawayJob {
    fn new(kill_on_close: bool) -> Self {
        use windows_sys::Win32::System::JobObjects::{
            CreateJobObjectW, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
            JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JobObjectExtendedLimitInformation,
            SetInformationJobObject,
        };
        // SAFETY: plain Win32 calls on a handle this function owns.
        unsafe {
            let job = CreateJobObjectW(std::ptr::null(), std::ptr::null());
            assert!(!job.is_null(), "CreateJobObjectW: {}", std::io::Error::last_os_error());
            if !kill_on_close {
                return Self(job);
            }
            let mut limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std::mem::zeroed();
            limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
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

    /// Put a suspended `child` in the job, then resume its threads.
    fn assign_and_resume(&self, child: &Child) {
        use std::os::windows::io::AsRawHandle;
        use windows_sys::Win32::Foundation::{CloseHandle, INVALID_HANDLE_VALUE};
        use windows_sys::Win32::System::Diagnostics::ToolHelp::{
            CreateToolhelp32Snapshot, TH32CS_SNAPTHREAD, THREADENTRY32, Thread32First, Thread32Next,
        };
        use windows_sys::Win32::System::JobObjects::AssignProcessToJobObject;
        use windows_sys::Win32::System::Threading::{
            OpenThread, ResumeThread, THREAD_SUSPEND_RESUME,
        };
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
            assert!(resumed > 0, "no thread of the suspended daemon {} to resume", child.id());
        }
    }
}

impl Drop for NoBreakawayJob {
    fn drop(&mut self) {
        // SAFETY: the handle is owned and closed once.
        unsafe { windows_sys::Win32::Foundation::CloseHandle(self.0) };
    }
}

fn request_response(path: &Path, value: serde_json::Value) -> serde_json::Value {
    let stream = transport::connect(path).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    writeln!(writer, "{value}").unwrap();
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    serde_json::from_str(&line).unwrap()
}

fn request(path: &Path, value: serde_json::Value) -> serde_json::Value {
    let response = request_response(path, value);
    assert_eq!(response["ok"], true, "request failed: {response}");
    response["data"].clone()
}

/// The pid of the program a terminal runs (`process-info`).
fn shell_pid(path: &Path, surface: u64) -> u32 {
    let info = request(path, serde_json::json!({"cmd": "process-info", "surface": surface}));
    info["pid"].as_u64().and_then(|pid| u32::try_from(pid).ok()).unwrap_or_else(|| {
        panic!("no pid for surface {surface}: {info}");
    })
}

/// Whether process `pid` ends within `timeout`. A pid that cannot be opened
/// has ended.
fn process_ends_within(pid: u32, timeout: Duration) -> bool {
    use windows_sys::Win32::Foundation::{CloseHandle, WAIT_OBJECT_0};
    use windows_sys::Win32::System::Threading::{
        OpenProcess, PROCESS_SYNCHRONIZE, WaitForSingleObject,
    };
    // SAFETY: plain Win32 calls; the handle opened here is closed here.
    unsafe {
        let process = OpenProcess(PROCESS_SYNCHRONIZE, 0, pid);
        if process.is_null() {
            return true;
        }
        let ended = WaitForSingleObject(process, timeout.as_millis() as u32) == WAIT_OBJECT_0;
        CloseHandle(process);
        ended
    }
}

fn wait_for_screen(path: &Path, surface: u64, marker: &str) -> String {
    let deadline = Instant::now() + test_timeout(Duration::from_secs(15));
    let mut last = String::new();
    while Instant::now() < deadline {
        last = request(path, serde_json::json!({"cmd": "read-screen", "surface": surface}))["text"]
            .as_str()
            .unwrap_or_default()
            .to_string();
        if last.contains(marker) {
            return last;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    last
}

#[test]
fn a_terminal_survives_a_fenced_daemon_restart_on_windows() {
    let mut daemon = Daemon::new("restart");
    let marker = format!("before-restart-{}", std::process::id());
    // cmd.exe echoes its input and keeps running.
    let created = request(
        &daemon.socket,
        serde_json::json!({
            "id": 1,
            "cmd": "run",
            "argv": ["cmd.exe", "/q", "/k"],
            "new_workspace": true,
            "name": "restart-survivor",
        }),
    );
    let surface = created["surface"].as_u64().unwrap();
    let terminal_id = created["terminal_id"].as_str().unwrap().to_string();
    let incarnation = created["terminal_incarnation"].as_str().unwrap().to_string();
    request(
        &daemon.socket,
        serde_json::json!({"id": 2, "cmd": "send", "surface": surface, "text": format!("echo {marker}\r")}),
    );
    assert!(wait_for_screen(&daemon.socket, surface, &marker).contains(&marker));

    daemon.stop_keeping_terminals();
    daemon.start();

    let deadline = Instant::now() + test_timeout(Duration::from_secs(20));
    let adopted = loop {
        let resolved = request_response(
            &daemon.socket,
            serde_json::json!({"id": 3, "cmd": "resolve-terminal", "terminal_id": terminal_id}),
        );
        let data = &resolved["data"];
        if resolved["ok"] == true
            && data["lifecycle"] == "running"
            && data["terminal_incarnation"].as_str() == Some(incarnation.as_str())
            && let Some(surface) = data["surface"].as_u64()
        {
            break surface;
        }
        assert!(
            Instant::now() < deadline,
            "the restarted daemon did not adopt terminal {terminal_id} (incarnation {incarnation}): {resolved}"
        );
        std::thread::sleep(Duration::from_millis(100));
    };
    assert!(
        wait_for_screen(&daemon.socket, adopted, &marker).contains(&marker),
        "the screen from before the restart is gone"
    );

    let after = format!("after-restart-{}", std::process::id());
    request(
        &daemon.socket,
        serde_json::json!({"id": 4, "cmd": "send", "surface": adopted, "text": format!("echo {after}\r")}),
    );
    assert!(
        wait_for_screen(&daemon.socket, adopted, &after).contains(&after),
        "input after the restart did not reach the same shell"
    );
}

fn tab_of(path: &Path, surface: u64) -> serde_json::Value {
    let tree = request(path, serde_json::json!({"cmd": "list-workspaces"}));
    tree["workspaces"]
        .as_array()
        .into_iter()
        .flatten()
        .flat_map(|workspace| workspace["screens"].as_array().into_iter().flatten())
        .flat_map(|screen| screen["panes"].as_array().into_iter().flatten())
        .flat_map(|pane| pane["tabs"].as_array().into_iter().flatten())
        .find(|tab| tab["surface"] == surface)
        .cloned()
        .unwrap_or_else(|| panic!("no tab for surface {surface}: {tree}"))
}

/// A daemon in a kill-on-close job that forbids breakaway starts the
/// terminal's host inside that job (coordinator decision 2026-10-09). The
/// terminal runs, every tree says it ends when the job closes
/// (`terminal_host_fallback: "breakaway_denied"`), and closing the job ends
/// its shell.
#[test]
fn a_terminal_in_a_kill_on_close_job_without_breakaway_says_so() {
    let mut daemon = Daemon::new_in_job_without_breakaway("nobreak", true);
    let marker = format!("in-job-{}", std::process::id());
    let created = request(
        &daemon.socket,
        serde_json::json!({
            "id": 1,
            "cmd": "run",
            "argv": ["cmd.exe", "/q", "/k"],
            "new_workspace": true,
            "name": "no-breakaway",
        }),
    );
    let surface = created["surface"].as_u64().unwrap();
    request(
        &daemon.socket,
        serde_json::json!({"id": 2, "cmd": "send", "surface": surface, "text": format!("echo {marker}\r")}),
    );
    assert!(
        wait_for_screen(&daemon.socket, surface, &marker).contains(&marker),
        "the terminal in the daemon's job does not run"
    );
    let tab = tab_of(&daemon.socket, surface);
    assert_eq!(tab["terminal_state"], "running", "{tab}");
    assert_eq!(tab["terminal_host_fallback"], "breakaway_denied", "{tab}");

    let shell = shell_pid(&daemon.socket, surface);
    drop(daemon.job.take());
    assert!(
        process_ends_within(shell, test_timeout(Duration::from_secs(10))),
        "the shell {shell} outlived its kill-on-close job"
    );
}

/// A daemon in a job that forbids breakaway but does not kill on close: the
/// host runs inside that job, no tree shows a notice, the terminal survives
/// a fenced daemon restart, and its shell survives the job closing.
#[test]
fn a_terminal_in_a_plain_job_without_breakaway_survives_restart_and_job_close() {
    let mut daemon = Daemon::new_in_job_without_breakaway("plainjob", false);
    let marker = format!("plain-job-{}", std::process::id());
    let created = request(
        &daemon.socket,
        serde_json::json!({
            "id": 1,
            "cmd": "run",
            "argv": ["cmd.exe", "/q", "/k"],
            "new_workspace": true,
            "name": "plain-job",
        }),
    );
    let surface = created["surface"].as_u64().unwrap();
    let terminal_id = created["terminal_id"].as_str().unwrap().to_string();
    let tab = tab_of(&daemon.socket, surface);
    assert!(tab["terminal_host_fallback"].is_null(), "{tab}");
    let shell = shell_pid(&daemon.socket, surface);

    daemon.stop_keeping_terminals();
    daemon.start();
    let deadline = Instant::now() + test_timeout(Duration::from_secs(20));
    let adopted = loop {
        let resolved = request_response(
            &daemon.socket,
            serde_json::json!({"id": 2, "cmd": "resolve-terminal", "terminal_id": terminal_id}),
        );
        if resolved["ok"] == true
            && resolved["data"]["lifecycle"] == "running"
            && let Some(surface) = resolved["data"]["surface"].as_u64()
        {
            break surface;
        }
        assert!(Instant::now() < deadline, "terminal {terminal_id} was not adopted: {resolved}");
        std::thread::sleep(Duration::from_millis(100));
    };

    drop(daemon.job.take());
    assert!(
        !process_ends_within(shell, Duration::from_secs(2)),
        "the shell {shell} ended with a job that does not kill on close"
    );
    request(
        &daemon.socket,
        serde_json::json!({"id": 3, "cmd": "send", "surface": adopted, "text": format!("echo {marker}\r")}),
    );
    assert!(
        wait_for_screen(&daemon.socket, adopted, &marker).contains(&marker),
        "the terminal stopped answering after its job closed"
    );
}

/// A terminal with its own host reports no fallback.
#[test]
fn a_hosted_terminal_reports_no_fallback() {
    let daemon = Daemon::new("hosted");
    let created = request(
        &daemon.socket,
        serde_json::json!({"id": 1, "cmd": "run", "argv": ["cmd.exe", "/q", "/k"], "new_workspace": true}),
    );
    let surface = created["surface"].as_u64().unwrap();
    let tab = tab_of(&daemon.socket, surface);
    assert!(tab["terminal_host_fallback"].is_null(), "{tab}");
}
