//! An idle acpmux daemon does not wake for writes under its chat roots that change no chat
//! (lead order, 2026-11-12; found by lane idle). The chat index watches every chat root, and
//! the roots include `~/.codex` (CODEX_HOME) and `~/.claude/projects`. On the owner's Mac about
//! 170 agents write there all the time: each Codex agent writes `logs_2.sqlite-wal` several
//! times a second, each Claude Code subagent appends to its own transcript and writes tool
//! results. None of those files is a chat the index reads. Here a daemon with its own HOME
//! idles while a writer makes 20 such writes a second; the daemon's context switches and CPU
//! are counted over quiet windows, as `daemon_idle_chats.rs` counts them.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// The daemon this test starts runs no agent.
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use serde_json::{Value, json};
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

/// Writes per second into files no chat is read from.
const WRITES_PER_SECOND: u64 = 20;
/// After the chat index's first scan: one-shot start work ends.
const SETTLE: Duration = Duration::from_secs(8);
/// Window over which wakeups are counted, and how many (the median is judged).
const WINDOW: Duration = Duration::from_secs(12);
const WINDOWS: u32 = 3;
/// Context switches the writes may add to the daemon's median window, over its median window
/// with no writes: `daemon_idle_chats.rs`'s bound. The windows with no writes come first, so the
/// daemon's own timers (lane idle's work) are not counted as the writes' cost.
const MAX_SWITCHES_PER_WINDOW: u64 = 5;

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

fn call(socket: &Path, method: &str, params: Value) -> Value {
    let s = UnixStream::connect(socket).expect("connect to the daemon socket");
    s.set_read_timeout(Some(Duration::from_secs(30))).unwrap();
    let mut writer = s.try_clone().unwrap();
    let mut reader = BufReader::new(s);
    for (id, (m, p)) in
        [("initialize", json!({"protocolVersion": 1})), (method, params)].into_iter().enumerate()
    {
        let line = json!({"jsonrpc": "2.0", "id": id, "method": m, "params": p});
        writer.write_all(format!("{line}\n").as_bytes()).unwrap();
        loop {
            let mut text = String::new();
            assert!(reader.read_line(&mut text).unwrap() > 0, "the daemon closed the socket");
            let Ok(v) = serde_json::from_str::<Value>(&text) else { continue };
            if v.get("id") == Some(&json!(id)) {
                assert!(v.get("error").is_none(), "{m} failed: {v}");
                if m == method {
                    return v["result"].clone();
                }
                break;
            }
        }
    }
    unreachable!()
}

fn line(path: &Path, text: &str) {
    let mut file = fs::OpenOptions::new().create(true).append(true).open(path).unwrap();
    writeln!(file, "{text}").unwrap();
}

/// A HOME with a Codex home and a Claude Code projects folder, each holding one chat the
/// index lists, and the files that agents keep writing that hold no chat.
fn chat_home(home: &Path) -> Noise {
    let codex = home.join(".codex");
    let day = codex.join("sessions/2026/11/12");
    fs::create_dir_all(&day).unwrap();
    let meta = json!({"timestamp": "2026-11-12T00:00:00Z", "type": "session_meta",
        "payload": {"id": "0199c0de-0000-7000-8000-000000000001", "cwd": "/work/a",
                    "timestamp": "2026-11-12T00:00:00Z"}});
    let asked = json!({"timestamp": "2026-11-12T00:00:01Z", "type": "event_msg",
        "payload": {"type": "user_message", "message": "hello"}});
    let rollout =
        day.join("rollout-2026-11-12T00-00-00-0199c0de-0000-7000-8000-000000000001.jsonl");
    line(&rollout, &meta.to_string());
    line(&rollout, &asked.to_string());
    let project = home.join(".claude/projects/-work-a");
    let session = "0199c0de-0000-7000-8000-000000000002";
    fs::create_dir_all(project.join(session).join("subagents")).unwrap();
    fs::create_dir_all(project.join(session).join("tool-results")).unwrap();
    let user = json!({"type": "user", "sessionId": session, "cwd": "/work/a",
        "timestamp": "2026-11-12T00:00:00Z", "message": {"role": "user", "content": "hello"}});
    line(&project.join(format!("{session}.jsonl")), &user.to_string());
    fs::create_dir_all(codex.join("log")).unwrap();
    fs::create_dir_all(codex.join("shell_snapshots")).unwrap();
    Noise {
        codex: vec![
            codex.join("logs_2.sqlite-wal"),
            codex.join("logs_2.sqlite"),
            codex.join("goals_1.sqlite-wal"),
            codex.join("history.jsonl"),
            codex.join("log/codex-tui.log"),
            codex.join("shell_snapshots/snapshot.sh"),
        ],
        claude: vec![
            project.join(session).join("subagents/agent-a1b2c3.jsonl"),
            project.join(session).join("subagents/agent-a1b2c3.meta.json"),
            project.join(session).join("tool-results/toolu_01.txt"),
        ],
    }
}

/// The files agents keep writing that hold no chat.
struct Noise {
    /// Under CODEX_HOME, outside its session folders.
    codex: Vec<PathBuf>,
    /// Under a Claude Code project: a subagent's transcript and a tool's result.
    claude: Vec<PathBuf>,
}

/// What one run measured while a writer wrote `pick(noise)`.
struct Measured {
    writes: u64,
    /// The windows with no writes, and their median.
    quiet: Vec<Usage>,
    quiet_median: u64,
    windows: Vec<Usage>,
    median_switches: u64,
    ran: String,
    periodic: Vec<String>,
    marks: Vec<Vec<(u64, String, Duration)>>,
    cache_rewritten: bool,
}

impl Measured {
    /// Whether a thread named `name` ran in any window.
    fn thread_ran(&self, name: &str) -> bool {
        self.marks.windows(2).any(|pair| {
            pair[1].iter().any(|(h, n, t)| {
                n == name
                    && pair[0].iter().find(|(k, _, _)| k == h).is_none_or(|(_, _, was)| t > was)
            })
        })
    }
}

fn measure(pick: fn(Noise) -> Vec<PathBuf>) -> Measured {
    let scratch = std::env::temp_dir().join(format!(
        "amx-idleroots-{}-{}",
        std::process::id(),
        uuid::Uuid::now_v7().simple()
    ));
    let acpmux = scratch.join("acpmux");
    private_dir(&acpmux);
    let home = daemon_env::home(&scratch);
    let noisy = pick(chat_home(&home));
    // A socket path stays short (SUN_LEN): not under the long scratch path.
    let short = PathBuf::from(format!("/tmp/amx-ir-{}", std::process::id()));
    private_dir(&short);
    let socket = short.join("s.sock");
    let mut child = daemon_env::command(&scratch, daemon_env::Agents::StandIn, &[])
        .args(["daemon", "run", "--ready-fd", "1", "--log", "warn"])
        .env("ACPMUX_HOME", &acpmux)
        .env("ACPMUX_SOCKET", &socket)
        .env("ACPMUX_LOGIN_ENV", "0")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let stdout = child.stdout.take().unwrap();
    let mut lines = BufReader::new(stdout).lines();
    let ready = lines
        .by_ref()
        .map_while(Result::ok)
        .any(|line| serde_json::from_str::<Value>(&line).is_ok_and(|v| v["ready"] == true));
    std::thread::spawn(move || lines.for_each(drop));
    let daemon = Daemon(child);
    assert!(ready, "the daemon became ready");
    let pid = daemon.0.id();
    // The index has scanned both roots: the two chats are listed.
    let mut listed = Value::Null;
    for _ in 0..100 {
        listed = call(&socket, "_acpmux/chats", json!({}));
        if listed["ready"] == true && listed["chats"].as_array().is_some_and(|c| c.len() == 2) {
            break;
        }
        std::thread::sleep(Duration::from_millis(200));
    }
    let roots = call(&socket, "_acpmux/chat_roots", json!({}));
    assert_eq!(
        listed["chats"].as_array().map(Vec::len),
        Some(2),
        "both chats listed: {listed}\nroots: {roots}"
    );
    let cache = acpmux.join("chat-index/v1.json");
    std::thread::sleep(SETTLE);
    // The daemon with no writes: what it does on its own.
    let mut quiet_marks = vec![usage(pid)];
    let mut quiet_threads = vec![threads(pid)];
    for _ in 0..WINDOWS {
        std::thread::sleep(WINDOW);
        quiet_marks.push(usage(pid));
        quiet_threads.push(threads(pid));
    }
    let cache_before = fs::metadata(&cache).and_then(|m| m.modified()).ok();

    let stop = Arc::new(AtomicBool::new(false));
    let writer = {
        let stop = stop.clone();
        std::thread::spawn(move || {
            let mut n = 0u64;
            while !stop.load(Ordering::Relaxed) {
                let path = &noisy[(n as usize) % noisy.len()];
                line(path, &format!("write {n} {}", "x".repeat(200)));
                n += 1;
                std::thread::sleep(Duration::from_millis(1000 / WRITES_PER_SECOND));
            }
            n
        })
    };
    std::thread::sleep(Duration::from_secs(2));
    let mut marks = vec![usage(pid)];
    let mut daemon_threads = vec![threads(pid)];
    for _ in 0..WINDOWS {
        std::thread::sleep(WINDOW);
        marks.push(usage(pid));
        daemon_threads.push(threads(pid));
    }
    stop.store(true, Ordering::Relaxed);
    let writes = writer.join().unwrap();
    let cache_after = fs::metadata(&cache).and_then(|m| m.modified()).ok();
    let spans = |marks: &[Option<Usage>]| -> Vec<Usage> {
        marks
            .windows(2)
            .filter_map(|pair| {
                let (a, b) = (pair[0]?, pair[1]?);
                Some(Usage {
                    cpu: b.cpu.saturating_sub(a.cpu),
                    switches: b.switches.saturating_sub(a.switches),
                })
            })
            .collect()
    };
    let median = |windows: &[Usage]| {
        let mut switches: Vec<u64> = windows.iter().map(|w| w.switches).collect();
        switches.sort_unstable();
        switches.get(switches.len() / 2).copied().unwrap_or(0)
    };
    let quiet = spans(&quiet_marks);
    let quiet_median = median(&quiet);
    let quiet_periodic = every_window(&quiet_threads);
    let windows = spans(&marks);
    let ran = thread_report(&daemon_threads);
    // A thread that runs in every window with no writes too is the daemon's own timer.
    let periodic: Vec<String> = every_window(&daemon_threads)
        .into_iter()
        .filter(|found| !quiet_periodic.contains(found))
        .collect();
    let median_switches = median(&windows);
    println!(
        "no writes: daemon per {WINDOW:?} window: {quiet:?}; on its own every window: \
         {quiet_periodic:?}\nthreads that ran:\n{}\n\
         {writes} writes; daemon per {WINDOW:?} window: {windows:?}; index cache rewritten: {}\n\
         daemon threads that ran:\n{ran}",
        thread_report(&quiet_threads),
        cache_before != cache_after
    );
    drop(daemon);
    let _ = fs::remove_dir_all(&scratch);
    let _ = fs::remove_dir_all(&short);
    Measured {
        writes,
        quiet,
        quiet_median,
        windows,
        median_switches,
        ran,
        periodic,
        marks: daemon_threads,
        cache_rewritten: cache_before != cache_after,
    }
}

/// CODEX_HOME's own logs, databases and history, and its other folders: no chat is read from
/// them, and the daemon does not wake for them at all.
#[test]
fn an_idle_daemon_does_not_wake_for_writes_to_codex_files_that_hold_no_chat() {
    let _ = &HERMETIC;
    let m = measure(|noise| noise.codex);
    assert!(
        m.median_switches <= m.quiet_median + MAX_SWITCHES_PER_WINDOW
            && m.periodic.is_empty()
            && !m.cache_rewritten,
        "an idle daemon woke for {} writes to Codex files that hold no chat: median {} switches \
         per {WINDOW:?} window {:?}, against {} with no writes {:?}; {}\n\
         daemon threads that ran:\n{}",
        m.writes,
        m.median_switches,
        m.windows,
        m.quiet_median,
        m.quiet,
        m.periodic.join("; "),
        m.ran
    );
}

/// A Claude Code subagent's transcript and a tool's result sit inside the project folder the
/// index watches whole (thousands of transcripts: no watch per file), so the file-system
/// events reach the daemon; they end in the watch's callback. Nothing is handed to the chat
/// watch thread and the index is not touched.
#[test]
fn writes_under_a_claude_project_that_hold_no_chat_end_in_the_watch_callback() {
    let _ = &HERMETIC;
    let m = measure(|noise| noise.claude);
    assert!(
        !m.thread_ran("acpmux-chat-watch") && !m.cache_rewritten,
        "{} writes to Claude Code files that hold no chat reached the chat watch thread \
         ({:?} per {WINDOW:?} window)\ndaemon threads that ran:\n{}",
        m.writes,
        m.windows,
        m.ran
    );
}
