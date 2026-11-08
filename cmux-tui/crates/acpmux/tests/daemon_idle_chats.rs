//! An idle acpmux daemon WITH CHATS must not wake up (cmux-ad m9, 2026-11-04): on
//! Lawrence's Mac, with no user action, every cmux build's acpmux daemon used 18-52 %
//! CPU, and every one of them had chats whose turns had ended. `daemon_idle.rs`
//! covers a daemon with no agent and no session; this one has what a person's daemon
//! has: its own store on disk (not `--memory`), a fake agent harness, CHATS chats each
//! answered once, each attached by a client the way the app keeps an open chat, the
//! app's watch streams, and a short idle-child time so the harnesses hibernate as they
//! do after 2 minutes. It then counts CPU time and context switches of the daemon and
//! of every process it started (the router, agent hosts, harnesses) over quiet
//! windows. A process that runs in every window wakes on a loop. On macOS a failure
//! names the loop: `sample` of the busiest process, the top of its call graph.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// The daemon this test starts runs tests/fake_agent.py only.
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use serde_json::{Value, json};
use std::collections::BTreeSet;
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};
use std::time::Duration;

/// Chats made, each answered once.
const CHATS: usize = 3;
/// How long an unused harness lives here (the daemon's default is 120 s).
const IDLE_CHILD_SECS: &str = "3";
/// After the last turn: the harnesses hibernate, one-shot work (saves, the chat scan) ends.
const SETTLE: Duration = Duration::from_secs(15);
/// Quiet window over which wakeups are counted, and how many (the median is judged).
const WINDOW: Duration = Duration::from_secs(10);
const WINDOWS: u32 = 3;
/// Context switches allowed per process in its median window: a 1 Hz wake gives 10.
const MAX_SWITCHES_PER_WINDOW: u64 = 5;
/// CPU allowed per process in its median window: 0.5 % of one core.
const MAX_CPU_PER_WINDOW: Duration = Duration::from_millis(50);

const ATTACH_KINDS: &[&str] = &[
    "transcript",
    "available_commands_update",
    "usage_update",
    "config_option_update",
    "bookmarks",
    "queue_order",
    "queue_updated",
    "prompt_refused",
];

struct Rpc {
    reader: BufReader<UnixStream>,
    writer: UnixStream,
    next: u64,
}

impl Rpc {
    fn connect(path: &Path) -> Self {
        let s = UnixStream::connect(path).expect("connect to the daemon socket");
        s.set_read_timeout(Some(Duration::from_secs(60))).unwrap();
        Self { reader: BufReader::new(s.try_clone().unwrap()), writer: s, next: 0 }
    }

    fn call(&mut self, method: &str, params: Value) -> Value {
        self.next += 1;
        let line = json!({"jsonrpc": "2.0", "id": self.next, "method": method, "params": params});
        self.writer.write_all(format!("{line}\n").as_bytes()).unwrap();
        loop {
            let mut text = String::new();
            assert!(self.reader.read_line(&mut text).unwrap() > 0, "the daemon closed the socket");
            let Ok(v) = serde_json::from_str::<Value>(&text) else { continue };
            if v.get("id") == Some(&json!(self.next)) {
                assert!(v.get("error").is_none(), "{method} failed: {v}");
                return v["result"].clone();
            }
        }
    }

    /// Keeps the connection open and reads (and drops) what the daemon pushes, as the app does.
    fn drain(self) -> std::thread::JoinHandle<()> {
        let mut reader = self.reader;
        let writer = self.writer;
        std::thread::spawn(move || {
            let _keep = writer;
            let _ = reader.get_ref().set_read_timeout(None);
            let mut line = String::new();
            while reader.read_line(&mut line).map(|n| n > 0).unwrap_or(false) {
                line.clear();
            }
        })
    }
}

#[derive(Clone, Copy, Debug, Default)]
struct Usage {
    cpu: Duration,
    switches: u64,
}

#[cfg(target_os = "macos")]
fn usage(pid: u32) -> Option<Usage> {
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
        fn mach_timebase_info(info: *mut Timebase) -> c_int;
    }
    const PROC_PIDTASKINFO: c_int = 4;
    let mut task = TaskInfo::default();
    let mut timebase = Timebase::default();
    // SAFETY: the buffer matches the flavor's C layout and size.
    let got = unsafe {
        let size = size_of::<TaskInfo>() as c_int;
        mach_timebase_info(&raw mut timebase);
        proc_pidinfo(pid as c_int, PROC_PIDTASKINFO, 0, (&raw mut task).cast(), size) == size
    };
    if !got {
        return None;
    }
    let ticks = task.total_user + task.total_system;
    let nanos = ticks as u128 * timebase.numer as u128 / timebase.denom.max(1) as u128;
    Some(Usage { cpu: Duration::from_nanos(nanos as u64), switches: task.csw.max(0) as u64 })
}

#[cfg(target_os = "linux")]
fn usage(pid: u32) -> Option<Usage> {
    let stat = fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    let fields: Vec<&str> = stat[stat.rfind(')')? + 2..].split(' ').collect();
    let ticks: u64 = fields[11].parse::<u64>().ok()? + fields[12].parse::<u64>().ok()?;
    // SAFETY: sysconf has no preconditions.
    let hz = unsafe { libc::sysconf(libc::_SC_CLK_TCK) }.max(1) as u64;
    let switches = fs::read_dir(format!("/proc/{pid}/task"))
        .ok()?
        .filter_map(Result::ok)
        .filter_map(|task| fs::read_to_string(task.path().join("status")).ok())
        .flat_map(|status| {
            status
                .lines()
                .filter(|line| line.contains("ctxt_switches:"))
                .filter_map(|line| line.split_whitespace().nth(1)?.parse::<u64>().ok())
                .collect::<Vec<_>>()
        })
        .sum();
    Some(Usage { cpu: Duration::from_millis(ticks * 1000 / hz), switches })
}

/// Each thread of `pid` as (thread handle, name, CPU time): macOS `PROC_PIDLISTTHREADS` and
/// `PROC_PIDTHREADINFO`. A thread whose time grew in a window ran in it; a handle that is new in
/// every window is a thread made and ended per wake (a blocking pool thread past its keep-alive).
#[cfg(target_os = "macos")]
fn threads(pid: u32) -> Vec<(u64, String, Duration)> {
    use std::os::raw::{c_int, c_void};
    #[repr(C)]
    struct ThreadInfo {
        user_time: u64,
        system_time: u64,
        cpu_usage: i32,
        policy: i32,
        run_state: i32,
        flags: i32,
        sleep_time: i32,
        curpri: i32,
        priority: i32,
        maxpriority: i32,
        name: [u8; 64],
    }
    unsafe extern "C" {
        fn proc_pidinfo(
            pid: c_int,
            flavor: c_int,
            arg: u64,
            buffer: *mut c_void,
            size: c_int,
        ) -> c_int;
    }
    const PROC_PIDTHREADINFO: c_int = 5;
    const PROC_PIDLISTTHREADS: c_int = 6;
    let mut handles = vec![0u64; 512];
    // SAFETY: the buffer holds `handles.len()` u64 handles, as the flavor writes.
    let got = unsafe {
        proc_pidinfo(
            pid as c_int,
            PROC_PIDLISTTHREADS,
            0,
            handles.as_mut_ptr().cast(),
            (handles.len() * 8) as c_int,
        )
    };
    handles.truncate(usize::try_from(got.max(0)).unwrap_or(0) / 8);
    handles
        .into_iter()
        .filter_map(|handle| {
            let mut info: ThreadInfo = unsafe { std::mem::zeroed() };
            let size = size_of::<ThreadInfo>() as c_int;
            // SAFETY: `info` matches struct proc_threadinfo and its size.
            let read = unsafe {
                proc_pidinfo(pid as c_int, PROC_PIDTHREADINFO, handle, (&raw mut info).cast(), size)
            };
            (read == size).then(|| {
                let end = info.name.iter().position(|b| *b == 0).unwrap_or(info.name.len());
                let name = String::from_utf8_lossy(&info.name[..end]).into_owned();
                (handle, name, Duration::from_nanos(info.user_time + info.system_time))
            })
        })
        .collect()
}

#[cfg(not(target_os = "macos"))]
fn threads(_pid: u32) -> Vec<(u64, String, Duration)> {
    Vec::new()
}

/// The daemon threads that ran in EVERY window, and whether a new thread was made in every window:
/// either is a periodic wake, however cheap each wake is (a 10 s timer passes a 5-switch budget).
fn every_window(marks: &[Vec<(u64, String, Duration)>]) -> Vec<String> {
    let windows: Vec<(Vec<u64>, bool)> = marks
        .windows(2)
        .map(|pair| {
            let before: std::collections::HashMap<u64, Duration> =
                pair[0].iter().map(|(h, _, t)| (*h, *t)).collect();
            let ran = pair[1]
                .iter()
                .filter(|(h, _, t)| before.get(h).is_some_and(|was| t > was))
                .map(|(h, _, _)| *h)
                .collect();
            let made = pair[1].iter().any(|(h, _, _)| !before.contains_key(h));
            (ran, made)
        })
        .collect();
    if windows.is_empty() {
        return Vec::new();
    }
    let mut found: Vec<String> = marks[marks.len() - 1]
        .iter()
        .filter(|(h, _, _)| windows.iter().all(|(ran, _)| ran.contains(h)))
        .map(|(h, name, _)| format!("thread {name}#{h:x} ran in every window"))
        .collect();
    if windows.iter().all(|(_, made)| *made) {
        found.push("a new thread was made in every window".to_owned());
    }
    found
}

/// The threads of `pid` that ran in each window: name, handle, CPU, and whether the thread was
/// new in that window.
fn thread_report(marks: &[Vec<(u64, String, Duration)>]) -> String {
    let mut lines = Vec::new();
    for (n, pair) in marks.windows(2).enumerate() {
        let before: std::collections::HashMap<u64, Duration> =
            pair[0].iter().map(|(h, _, t)| (*h, *t)).collect();
        let mut ran = Vec::new();
        for (handle, name, time) in &pair[1] {
            match before.get(handle) {
                Some(was) if time > was => {
                    ran.push(format!("{name}#{handle:x} +{:?}", *time - *was))
                }
                Some(_) => {}
                None => ran.push(format!("NEW {name}#{handle:x} {time:?}")),
            }
        }
        let gone =
            pair[0].iter().filter(|(h, _, _)| !pair[1].iter().any(|(k, _, _)| k == h)).count();
        lines.push(format!("  window {}: ran [{}], ended threads {gone}", n + 1, ran.join(", ")));
    }
    lines.join("\n")
}

/// (pid, ppid, command) of every process.
fn table() -> Vec<(u32, u32, String)> {
    let out = std::process::Command::new("ps")
        .args(["-A", "-ww", "-o", "pid=,ppid=,command="])
        .output()
        .unwrap();
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter_map(|line| {
            let mut fields = line.split_whitespace();
            let pid = fields.next()?.parse().ok()?;
            let ppid = fields.next()?.parse().ok()?;
            Some((pid, ppid, fields.collect::<Vec<_>>().join(" ")))
        })
        .collect()
}

/// Whether `pid`'s environment names `needle` (this user's processes only).
fn environment_has(pid: u32, needle: &str) -> bool {
    #[cfg(target_os = "linux")]
    {
        fs::read(format!("/proc/{pid}/environ"))
            .is_ok_and(|env| String::from_utf8_lossy(&env).contains(needle))
    }
    #[cfg(target_os = "macos")]
    {
        std::process::Command::new("ps")
            .args(["-E", "-ww", "-o", "command=", "-p", &pid.to_string()])
            .output()
            .is_ok_and(|out| String::from_utf8_lossy(&out.stdout).contains(needle))
    }
}

/// The daemon and every process it started, also those that left its tree (agent hosts
/// outlive their daemon): their environment names this test's home.
fn processes(daemon: u32, home: &Path) -> Vec<(u32, String)> {
    let rows = table();
    let mut ours: BTreeSet<u32> = BTreeSet::from([daemon]);
    loop {
        let before = ours.len();
        for (pid, ppid, _) in &rows {
            if ours.contains(ppid) {
                ours.insert(*pid);
            }
        }
        if ours.len() == before {
            break;
        }
    }
    let needle = home.to_string_lossy().into_owned();
    for (pid, _, command) in &rows {
        if !ours.contains(pid)
            && (command.contains("acpmux") || command.contains("fake_agent"))
            && environment_has(*pid, &needle)
        {
            ours.insert(*pid);
        }
    }
    rows.into_iter()
        .filter(|(pid, _, _)| ours.contains(pid))
        .map(|(pid, _, command)| {
            let name = if pid == daemon {
                "daemon".to_owned()
            } else {
                command.chars().take(120).collect()
            };
            (pid, name)
        })
        .collect()
}

/// The top of `sample`'s call graph for `pid` (macOS), else nothing.
fn sample_of(pid: u32, scratch: &Path) -> String {
    #[cfg(target_os = "macos")]
    {
        let file = scratch.join(format!("sample-{pid}.txt"));
        let _ = std::process::Command::new("/usr/bin/sample")
            .args([&pid.to_string(), "3", "-mayDie", "-file"])
            .arg(&file)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
        let text = fs::read_to_string(&file).unwrap_or_default();
        let graph = text.split("Call graph:").nth(1).unwrap_or("");
        let tops = text.split("Sort by top of stack").nth(1).unwrap_or("");
        let graph: Vec<&str> = graph.lines().take(70).collect();
        let tops: Vec<&str> = tops.lines().take(16).collect();
        format!(
            "sample {pid} (call graph):\n{}\ntop of stack:\n{}",
            graph.join("\n"),
            tops.join("\n")
        )
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (pid, scratch);
        String::new()
    }
}

fn private_dir(path: &Path) {
    use std::os::unix::fs::PermissionsExt;
    fs::create_dir_all(path).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o700)).unwrap();
}

struct Daemon(Child);

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn start(scratch: &Path, home: &Path) -> (Daemon, PathBuf) {
    let socket = scratch.join("s.sock");
    let mut child = daemon_env::command(scratch, daemon_env::Agents::StandIn, &[])
        .args(["daemon", "run", "--ready-fd", "1", "--log", "warn"])
        .env("ACPMUX_HOME", home)
        .env("ACPMUX_SOCKET", &socket)
        .env("ACPMUX_IDLE_CHILD_SECS", IDLE_CHILD_SECS)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let stdout = child.stdout.take().unwrap();
    let ready = BufReader::new(stdout)
        .lines()
        .map_while(Result::ok)
        .any(|line| serde_json::from_str::<Value>(&line).is_ok_and(|v| v["ready"] == true));
    if !ready {
        let _ = child.kill();
        panic!("the daemon exited without a readiness line: {:?}", child.wait());
    }
    (Daemon(child), socket)
}

#[test]
fn acpmux_daemon_with_finished_chats_has_no_periodic_wakeups() {
    let scratch = std::env::temp_dir().join(format!(
        "amx-idlechat-{}-{}",
        std::process::id(),
        uuid::Uuid::now_v7().simple()
    ));
    let home = scratch.join("acpmux");
    private_dir(&home);
    let work = scratch.join("work");
    fs::create_dir_all(&work).unwrap();
    let config = json!({
        "harnesses": {"fake": {
            "argv": ["python3", concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py")]
        }},
        "defaultHarness": "fake", "permissionPolicy": "approve-all"
    });
    fs::write(home.join("config.json"), config.to_string()).unwrap();
    let (daemon, socket) = start(&scratch, &home);
    let pid = daemon.0.id();

    // The app's own connection: the session watch and the chat list watch.
    let mut app = Rpc::connect(&socket);
    app.call("initialize", json!({"protocolVersion": 1}));
    app.call("_acpmux/watch", json!({"enabled": true}));
    app.call("_acpmux/chats_watch", json!({"enabled": true}));
    let mut streams = vec![app.drain()];
    // Each chat: made, answered once, then attached as an open chat on screen.
    for i in 0..CHATS {
        let mut rpc = Rpc::connect(&socket);
        rpc.call("initialize", json!({"protocolVersion": 1}));
        let made = rpc.call("session/new", json!({"cwd": work, "mcpServers": []}));
        let id = made["sessionId"].as_str().expect("session/new gave no sessionId").to_owned();
        let ended = rpc.call(
            "session/prompt",
            json!({"sessionId": id, "prompt": [{"type": "text", "text": format!("chat {i}")}]}),
        );
        assert!(ended.get("stopReason").is_some(), "the turn did not end: {ended}");
        rpc.call(
            "_acpmux/attach",
            json!({"sessionId": id, "limit": 400, "maxBytes": 128 * 1024,
                   "kinds": ATTACH_KINDS, "eventStream": true, "visible": i == 0}),
        );
        streams.push(rpc.drain());
    }
    std::thread::sleep(SETTLE);

    let procs = processes(pid, &home);
    let mut marks = vec![procs.iter().map(|(p, _)| usage(*p)).collect::<Vec<_>>()];
    let mut daemon_threads = vec![threads(pid)];
    for _ in 0..WINDOWS {
        std::thread::sleep(WINDOW);
        marks.push(procs.iter().map(|(p, _)| usage(*p)).collect());
        daemon_threads.push(threads(pid));
    }
    let mut report = Vec::new();
    let mut busiest: Option<(u32, Duration)> = None;
    for (at, (p, name)) in procs.iter().enumerate() {
        let windows: Vec<Usage> = marks
            .windows(2)
            .filter_map(|pair| {
                let (a, b) = (pair[0][at]?, pair[1][at]?);
                Some(Usage {
                    cpu: b.cpu.saturating_sub(a.cpu),
                    switches: b.switches.saturating_sub(a.switches),
                })
            })
            .collect();
        if windows.is_empty() {
            continue;
        }
        let mut cpu: Vec<Duration> = windows.iter().map(|w| w.cpu).collect();
        let mut switches: Vec<u64> = windows.iter().map(|w| w.switches).collect();
        cpu.sort_unstable();
        switches.sort_unstable();
        let (cpu, switches) = (cpu[cpu.len() / 2], switches[switches.len() / 2]);
        if cpu > MAX_CPU_PER_WINDOW || switches > MAX_SWITCHES_PER_WINDOW {
            report.push(format!("{name} (pid {p}): median {cpu:?} CPU, {switches} switches per {WINDOW:?}: {windows:?}"));
            if busiest.is_none_or(|(_, top)| cpu > top) {
                busiest = Some((*p, cpu));
            }
        }
    }
    let sampled = busiest.map(|(p, _)| sample_of(p, &scratch)).unwrap_or_default();
    let ran = thread_report(&daemon_threads);
    let periodic = every_window(&daemon_threads);
    if !periodic.is_empty() {
        report.push(format!("daemon: {}", periodic.join("; ")));
    }
    println!("daemon threads that ran, per {WINDOW:?} window:\n{ran}");
    drop(streams);
    drop(daemon);
    let _ = fs::remove_dir_all(&scratch);
    assert!(
        report.is_empty(),
        "an idle acpmux daemon with {CHATS} finished chats woke up ({} processes measured):\n{}\n\
         daemon threads that ran, per {WINDOW:?} window:\n{ran}\n{sampled}",
        procs.len(),
        report.join("\n")
    );
}
