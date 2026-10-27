//! An idle acpmux daemon must not wake up (plans/cmux-next/idle-wakeups.md,
//! resource-efficiency-DESIGN.md): no agent, no request, no chat written, so
//! no periodic tick, poll or timed re-check. Every cmux app keeps one daemon
//! (and each tagged dev build its own) for hours, so a 1 Hz wake costs every
//! Mac all day. The daemon serves a chat root of real size (2000 chats) and
//! keeps the app's watch stream open, as the app does.
//!
//! The same holds with a chat that watches a transcript nobody writes to
//! (`hub/watch.rs`) and with an `_acpmux/wait` (`server/wait.rs`) pending on an
//! idle chat: both wake on a change or a deadline, never on a timer.
//!
//! The periodic upkeep (catalog refresh, harness health, upload sweep) runs on
//! one maintenance clock with a 5-minute wall grid (`src/maintenance.rs`), so
//! a daemon with all three registered does not wake inside the window either.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process starts no agent.
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::fs;
use std::io::{BufRead, BufReader, ErrorKind, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};
use std::time::Duration;

/// Quiet window over which wakeups are counted.
const WINDOW: Duration = Duration::from_secs(10);
/// Windows measured; a process is judged by its median window.
const WINDOWS: u32 = 3;
/// Time after startup for one-shot work (the first chat scan, the cache save).
const SETTLE: Duration = Duration::from_secs(5);
/// Context switches allowed per process in its median window: a 1 Hz wake gives 10.
const MAX_SWITCHES_PER_WINDOW: u64 = 5;
/// CPU allowed per process in its median window: 0.5% of one core.
const MAX_CPU_PER_WINDOW: Duration = Duration::from_millis(50);
const CHATS: usize = 2000;
/// The Claude Code conversation the watched chat follows; not one of the `CHATS`.
const WATCHED: &str = "11111111-1111-4111-8111-111111111111";

/// What a process used in one window.
#[derive(Clone, Copy, Debug)]
struct Usage {
    cpu: Duration,
    switches: u64,
    /// macOS package idle plus interrupt wakeups; 0 elsewhere. Read only
    /// through `Debug`, in a failure message.
    #[allow(dead_code)]
    wakeups: u64,
}

/// A process's counters at one instant. Context switches are per thread id
/// on Linux, where a thread's count leaves the process total when the thread
/// exits (tokio's idle blocking threads exit 10 s after their last task); on
/// macOS the task total keeps dead threads' counts, under the one key 0.
struct Mark {
    cpu: Duration,
    switches: BTreeMap<u64, u64>,
    wakeups: u64,
}

#[cfg(target_os = "macos")]
fn usage(pid: u32) -> Mark {
    use std::os::raw::{c_int, c_void};

    #[repr(C)]
    #[derive(Default)]
    struct TaskInfo {
        virtual_size: u64,
        resident_size: u64,
        total_user: u64,
        total_system: u64,
        threads_user: u64,
        threads_system: u64,
        policy: i32,
        faults: i32,
        pageins: i32,
        cow_faults: i32,
        messages_sent: i32,
        messages_received: i32,
        syscalls_mach: i32,
        syscalls_unix: i32,
        csw: i32,
        threadnum: i32,
        numrunning: i32,
        priority: i32,
    }

    #[repr(C)]
    #[derive(Default)]
    struct RusageV2 {
        uuid: [u8; 16],
        user_time: u64,
        system_time: u64,
        pkg_idle_wkups: u64,
        interrupt_wkups: u64,
        rest: [u64; 15],
    }

    #[repr(C)]
    #[derive(Default)]
    struct Timebase {
        numer: u32,
        denom: u32,
    }

    unsafe extern "C" {
        fn proc_pidinfo(
            pid: c_int,
            flavor: c_int,
            arg: u64,
            buffer: *mut c_void,
            size: c_int,
        ) -> c_int;
        fn proc_pid_rusage(pid: c_int, flavor: c_int, buffer: *mut c_void) -> c_int;
        fn mach_timebase_info(info: *mut Timebase) -> c_int;
    }
    const PROC_PIDTASKINFO: c_int = 4;
    const RUSAGE_INFO_V2: c_int = 2;

    let mut task = TaskInfo::default();
    let mut rusage = RusageV2::default();
    let mut timebase = Timebase::default();
    // SAFETY: each buffer matches the flavor's C layout and size.
    unsafe {
        let size = size_of::<TaskInfo>() as c_int;
        assert_eq!(
            proc_pidinfo(pid as c_int, PROC_PIDTASKINFO, 0, (&raw mut task).cast(), size),
            size,
            "proc_pidinfo({pid})"
        );
        assert_eq!(proc_pid_rusage(pid as c_int, RUSAGE_INFO_V2, (&raw mut rusage).cast()), 0);
        mach_timebase_info(&raw mut timebase);
    }
    // Task times are Mach absolute ticks on Apple silicon.
    let ticks = task.total_user + task.total_system;
    let nanos = ticks as u128 * timebase.numer as u128 / timebase.denom.max(1) as u128;
    Mark {
        cpu: Duration::from_nanos(nanos as u64),
        switches: BTreeMap::from([(0, task.csw.max(0) as u64)]),
        wakeups: rusage.pkg_idle_wkups + rusage.interrupt_wkups,
    }
}

#[cfg(target_os = "linux")]
fn usage(pid: u32) -> Mark {
    let stat = fs::read_to_string(format!("/proc/{pid}/stat")).unwrap();
    // Fields after the parenthesized command name; utime and stime are 14 and 15.
    let fields: Vec<&str> = stat[stat.rfind(')').unwrap() + 2..].split(' ').collect();
    let ticks: u64 = fields[11].parse::<u64>().unwrap() + fields[12].parse::<u64>().unwrap();
    // SAFETY: sysconf has no preconditions.
    let hz = unsafe { libc::sysconf(libc::_SC_CLK_TCK) }.max(1) as u64;
    // Per-thread counters: /proc/<pid>/status only covers the main thread.
    let switches = fs::read_dir(format!("/proc/{pid}/task"))
        .unwrap()
        .filter_map(Result::ok)
        .filter_map(|task| {
            let tid = task.file_name().to_str()?.parse::<u64>().ok()?;
            let status = fs::read_to_string(task.path().join("status")).ok()?;
            let switches = status
                .lines()
                .filter(|line| line.contains("ctxt_switches:"))
                .filter_map(|line| line.split_whitespace().nth(1)?.parse::<u64>().ok())
                .sum();
            Some((tid, switches))
        })
        .collect();
    Mark { cpu: Duration::from_millis(ticks * 1000 / hz), switches, wakeups: 0 }
}

/// Use between two marks. Switches count per thread alive at `after`: one
/// that started after `before` counts from 0, one that exited is left out.
fn delta(before: &Mark, after: &Mark) -> Usage {
    let switches = after
        .switches
        .iter()
        .map(|(tid, now)| now.saturating_sub(before.switches.get(tid).copied().unwrap_or(0)))
        .sum();
    Usage {
        cpu: after.cpu.saturating_sub(before.cpu),
        switches,
        wakeups: after.wakeups.saturating_sub(before.wakeups),
    }
}

fn woke(windows: &[Usage]) -> bool {
    let mut switches: Vec<u64> = windows.iter().map(|used| used.switches).collect();
    let mut cpu: Vec<Duration> = windows.iter().map(|used| used.cpu).collect();
    switches.sort_unstable();
    cpu.sort_unstable();
    switches[switches.len() / 2] > MAX_SWITCHES_PER_WINDOW
        || cpu[cpu.len() / 2] > MAX_CPU_PER_WINDOW
}

fn scratch(name: &str) -> PathBuf {
    // Short: the socket path must stay under the macOS limit.
    let dir = std::env::temp_dir().join(format!("amx-idle-{name}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

/// `CHATS` Claude Code transcripts under the daemon's home.
fn write_chats(home: &Path) {
    for i in 0..CHATS {
        let id = format!("00000000-0000-4000-8000-{i:012}");
        let folder = home.join(".claude/projects").join(format!("-work-p{}", i % 50));
        fs::create_dir_all(&folder).unwrap();
        let line = json!({"type":"user","isSidechain":false,"cwd":format!("/work/p{}", i % 50),
            "sessionId":id,"timestamp":"2026-10-01T01:00:00.000Z",
            "message":{"role":"user","content":format!("chat {i}")}});
        fs::write(folder.join(format!("{id}.jsonl")), format!("{line}\n")).unwrap();
    }
}

/// The daemon's direct children (the router), by `ps`.
fn children(pid: u32) -> Vec<u32> {
    let out = std::process::Command::new("ps").args(["-A", "-o", "pid=,ppid="]).output().unwrap();
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter_map(|line| {
            let mut fields = line.split_whitespace();
            let child: u32 = fields.next()?.parse().ok()?;
            let parent: u32 = fields.next()?.parse().ok()?;
            (parent == pid).then_some(child)
        })
        .collect()
}

/// The watched conversation: one finished turn under the daemon's home, run
/// in `cwd` (a chat opens only in a folder that exists).
fn write_watched(home: &Path, cwd: &Path) {
    fs::create_dir_all(cwd).unwrap();
    let folder = home.join(".claude/projects/-work-watched");
    fs::create_dir_all(&folder).unwrap();
    let user = json!({"type":"user","isSidechain":false,"cwd":cwd,
        "sessionId":WATCHED,"timestamp":"2026-10-01T01:00:00.000Z",
        "message":{"role":"user","content":"a watched prompt"}});
    let answer = json!({"type":"assistant","isSidechain":false,"cwd":cwd,
        "sessionId":WATCHED,"timestamp":"2026-10-01T01:00:01.000Z",
        "message":{"role":"assistant","content":[{"type":"text","text":"a watched answer"}],
            "stop_reason":"end_turn"}});
    fs::write(folder.join(format!("{WATCHED}.jsonl")), format!("{user}\n{answer}\n")).unwrap();
}

/// A daemon on its own scratch folder, killed and cleaned up on drop.
struct Daemon {
    child: Child,
    dir: PathBuf,
    socket: PathBuf,
}

impl Daemon {
    /// Starts the daemon on `dir` (`CHATS` chats plus the watched
    /// conversation) and waits for its readiness line. Its one harness,
    /// `fakeclaude`, is of the Claude family and never starts: launches are
    /// denied, and a watch starts none.
    fn start(dir: PathBuf) -> Self {
        Self::start_with(dir, &[])
    }

    /// [`Daemon::start`] with `env` set over the test's defaults.
    fn start_with(dir: PathBuf, env: &[(&str, &str)]) -> Self {
        let home = daemon_env::home(&dir);
        write_chats(&home);
        write_watched(&home, &dir.join("watched"));
        let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
        let config = json!({
            "harnesses": {"fakeclaude": {"argv": ["python3", fake], "family": "claude"}},
            "defaultHarness": "fakeclaude",
        });
        fs::write(dir.join("config.json"), config.to_string()).unwrap();
        let socket = dir.join("s.sock");
        let mut child = daemon_env::acpmux(&dir)
            .args(["daemon", "run", "--memory", "--ready-fd", "1", "--log", "warn"])
            .env("ACPMUX_HOME", &dir)
            .env("ACPMUX_SOCKET", &socket)
            .env("ACPMUX_LOGIN_ENV", "0")
            // No catalog fetch: the test never reaches the network.
            .env("ACPMUX_CATALOG_FETCH", "0")
            // The kernel memory pressure source runs too (`src/memory.rs`):
            // it waits on the kernel's event, never on a timer.
            .env("CMUX_ENABLE_FEATURES", "memoryAcpmuxPressure")
            .envs(env.iter().copied())
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .unwrap();
        let stdout = child.stdout.take().unwrap();
        let ready = BufReader::new(stdout).lines().map_while(Result::ok).find_map(|line| {
            serde_json::from_str::<Value>(&line).ok().filter(|v| v["ready"] == true)
        });
        if ready.is_none() {
            let _ = child.kill();
            panic!("the daemon exited without a readiness line: {:?}", child.wait());
        }
        Self { child, dir, socket }
    }

    fn pid(&self) -> u32 {
        self.child.id()
    }

    fn connect(&self) -> Rpc {
        Rpc::new(UnixStream::connect(&self.socket).unwrap())
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = fs::remove_dir_all(&self.dir);
    }
}

/// How long a test waits for any one answer.
const ANSWER_TIMEOUT: Duration = Duration::from_secs(30);

/// One JSON-RPC connection: a line per message.
struct Rpc {
    stream: UnixStream,
    reader: BufReader<UnixStream>,
    next: u64,
}

impl Rpc {
    fn new(stream: UnixStream) -> Self {
        stream.set_read_timeout(Some(ANSWER_TIMEOUT)).unwrap();
        let reader = BufReader::new(stream.try_clone().unwrap());
        Self { stream, reader, next: 1 }
    }

    /// Sends a request and returns its id, without reading the answer.
    fn send(&mut self, method: &str, params: Value) -> u64 {
        let id = self.next;
        self.next += 1;
        let call = json!({"jsonrpc":"2.0","id":id,"method":method,"params":params});
        self.stream.write_all(format!("{call}\n").as_bytes()).unwrap();
        id
    }

    /// The result of `method`; an error answer fails the test. Notifications
    /// before the answer are skipped.
    fn call(&mut self, method: &str, params: Value) -> Value {
        let id = self.send(method, params);
        loop {
            let mut line = String::new();
            assert!(self.reader.read_line(&mut line).unwrap() > 0, "the daemon closed the stream");
            if let Ok(answer) = serde_json::from_str::<Value>(&line)
                && answer["id"] == id
            {
                assert!(answer.get("error").is_none(), "{method}: {answer}");
                return answer["result"].clone();
            }
        }
    }

    /// Whether the answer to request `id` arrives within `within`.
    fn answered_within(&mut self, id: u64, within: Duration) -> bool {
        self.stream.set_read_timeout(Some(within)).unwrap();
        let answered = loop {
            let mut line = String::new();
            match self.reader.read_line(&mut line) {
                Ok(0) => panic!("the daemon closed the stream"),
                Ok(_) if serde_json::from_str::<Value>(&line).is_ok_and(|m| m["id"] == id) => {
                    break true;
                }
                Ok(_) => {}
                Err(e) if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) => {
                    break false;
                }
                Err(e) => panic!("read the wait's connection: {e}"),
            }
        };
        self.stream.set_read_timeout(Some(ANSWER_TIMEOUT)).unwrap();
        answered
    }
}

/// The app's connection: a watch stream it keeps open for its whole life.
fn watch_stream(daemon: &Daemon) -> Rpc {
    let mut rpc = daemon.connect();
    rpc.call("_acpmux/watch", json!({"enabled": true}));
    rpc
}

fn session_summary(rpc: &mut Rpc, id: &str) -> Value {
    let sessions = rpc.call("_acpmux/sessions", json!({}));
    sessions["sessions"]
        .as_array()
        .and_then(|rows| rows.iter().find(|s| s["sessionId"] == id))
        .cloned()
        .unwrap_or_else(|| panic!("no session {id} in {sessions}"))
}

/// A chat that watches the `WATCHED` conversation, once it shows the
/// conversation's turn; its session id.
fn watched_chat(rpc: &mut Rpc) -> String {
    let adopt = json!({"agentSessionId": WATCHED, "watch": true});
    let created = rpc.call(
        "session/new",
        json!({"mcpServers": [], "_meta": {"acpmux": {"harness": "fakeclaude", "adopt": adopt}}}),
    );
    let id = created["sessionId"].as_str().unwrap_or_else(|| panic!("{created}")).to_owned();
    // Test polling: the chat reads the transcript on its own task.
    for _ in 0..100 {
        let summary = session_summary(rpc, &id);
        if summary["watching"] == "claude" && summary["turnCount"] == 1 {
            return id;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    panic!("the chat never showed the watched turn: {}", session_summary(rpc, &id));
}

/// Measures the daemon and its children over `WINDOWS` quiet windows after
/// `SETTLE`, and fails with every process whose median window woke up.
fn assert_idle(daemon: &Daemon, what: &str) {
    std::thread::sleep(SETTLE);
    let pid = daemon.pid();
    let processes: Vec<(String, u32)> = std::iter::once(("daemon".to_string(), pid))
        .chain(children(pid).into_iter().map(|child| (format!("child {child}"), child)))
        .collect();
    let mut marks = vec![processes.iter().map(|(_, pid)| usage(*pid)).collect::<Vec<Mark>>()];
    for _ in 0..WINDOWS {
        std::thread::sleep(WINDOW);
        marks.push(processes.iter().map(|(_, pid)| usage(*pid)).collect());
    }
    let mut failures = Vec::new();
    for (at, (name, _)) in processes.iter().enumerate() {
        let windows: Vec<Usage> =
            marks.windows(2).map(|pair| delta(&pair[0][at], &pair[1][at])).collect();
        if woke(&windows) {
            failures.push(format!("{name}: {windows:?}"));
        }
    }
    assert!(failures.is_empty(), "{what} woke up (per {WINDOW:?} window): {failures:#?}");
}

#[test]
fn acpmux_daemon_idle_has_no_periodic_wakeups() {
    let daemon = Daemon::start(scratch("daemon"));
    let mut app = watch_stream(&daemon);
    // `daemon status` names each memory consumer with its bytes (`src/daemon_status.rs`).
    let status = app.call("_acpmux/status", json!({}));
    let consumers = status["memory"]["consumers"].as_array().cloned().unwrap_or_default();
    assert!(consumers.iter().any(|c| c["name"] == "pool.auth_cache"), "{}", status["memory"]);
    assert!(consumers.iter().all(|c| c.get("bytes").is_some()), "{}", status["memory"]);
    eprintln!("memory pressure source running: {}", status["memory"]["pressure_source"]);
    assert_idle(&daemon, "an idle acpmux daemon");
}

/// A watched transcript nobody writes to costs nothing: the watch hears of a
/// change to the file, it does not read the file again on a timer.
#[test]
fn acpmux_daemon_idle_with_a_watched_transcript() {
    let daemon = Daemon::start(scratch("watched"));
    let mut app = watch_stream(&daemon);
    watched_chat(&mut app);
    assert_idle(&daemon, "an acpmux daemon with an unchanged watched transcript");
}

/// An `_acpmux/wait` pending on an idle chat wakes on hub events and its
/// deadline only, never to evaluate again on a timer.
#[test]
fn acpmux_daemon_idle_with_a_pending_wait() {
    let daemon = Daemon::start(scratch("wait"));
    let mut app = watch_stream(&daemon);
    let id = watched_chat(&mut app);
    // Taken over, the chat no longer reads the transcript: an idle chat with
    // no agent, so only the wait is measured. `open` skips the holder check
    // (no Claude Code registered this conversation here).
    app.call("_acpmux/watch_take_over", json!({"sessionId": id, "ifLive": "open"}));
    assert!(session_summary(&mut app, &id)["watching"].is_null());
    let mut waiter = daemon.connect();
    let wait = waiter.send("_acpmux/wait", json!({"sessions": [id], "until": ["closed"]}));
    assert!(!waiter.answered_within(wait, Duration::from_secs(1)), "the wait resolved at once");
    assert_idle(&daemon, "an acpmux daemon with a pending wait");
    assert!(!waiter.answered_within(wait, Duration::from_millis(10)), "the wait resolved");
}

/// The catalog refresh, the harness health check and the upload sweep are
/// registered on the maintenance clock, and none of them wakes the daemon
/// inside the measured windows (30 s).
#[test]
fn acpmux_daemon_idle_with_its_maintenance_jobs_registered() {
    // The upload age cap stays on (default 30 days), so the sweep is a real job.
    let daemon = Daemon::start_with(scratch("upkeep"), &[("ACPMUX_HEALTH_FETCH", "0")]);
    let mut app = watch_stream(&daemon);
    let energy = app.call("_acpmux/energy", json!({}));
    assert_eq!(
        energy["jobs"],
        json!(["catalog.refresh", "harness_health.check", "file_uploads.sweep"]),
        "{energy}"
    );
    // An Energy Saver edge wakes the clock once to re-grid, then nothing.
    assert_eq!(app.call("_acpmux/energy", json!({"saver": true}))["changed"], json!(true));
    assert_idle(&daemon, "an acpmux daemon with its maintenance jobs registered");
}
