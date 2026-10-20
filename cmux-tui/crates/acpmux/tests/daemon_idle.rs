//! An idle acpmux daemon must not wake up (plans/cmux-next/idle-wakeups.md,
//! resource-efficiency-DESIGN.md): no agent, no request, no chat written, so
//! no periodic tick, poll or timed re-check. Every cmux app keeps one daemon
//! (and each tagged dev build its own) for hours, so a 1 Hz wake costs every
//! Mac all day. The daemon serves a chat root of real size (2000 chats) and
//! keeps the app's watch stream open, as the app does.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process starts no agent.
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use serde_json::{Value, json};
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
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

#[derive(Clone, Copy, Debug)]
struct Usage {
    cpu: Duration,
    switches: u64,
    /// macOS package idle plus interrupt wakeups; 0 elsewhere. Read only
    /// through `Debug`, in a failure message.
    #[allow(dead_code)]
    wakeups: u64,
}

#[cfg(target_os = "macos")]
fn usage(pid: u32) -> Usage {
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
    Usage {
        cpu: Duration::from_nanos(nanos as u64),
        switches: task.csw.max(0) as u64,
        wakeups: rusage.pkg_idle_wkups + rusage.interrupt_wkups,
    }
}

#[cfg(target_os = "linux")]
fn usage(pid: u32) -> Usage {
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
        .filter_map(|task| fs::read_to_string(task.path().join("status")).ok())
        .flat_map(|status| {
            status
                .lines()
                .filter(|line| line.contains("ctxt_switches:"))
                .filter_map(|line| line.split_whitespace().nth(1)?.parse::<u64>().ok())
                .collect::<Vec<_>>()
        })
        .sum();
    Usage { cpu: Duration::from_millis(ticks * 1000 / hz), switches, wakeups: 0 }
}

fn delta(before: Usage, after: Usage) -> Usage {
    Usage {
        cpu: after.cpu.saturating_sub(before.cpu),
        switches: after.switches.saturating_sub(before.switches),
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

#[test]
fn acpmux_daemon_idle_has_no_periodic_wakeups() {
    let dir = scratch("daemon");
    write_chats(&daemon_env::home(&dir));
    let socket = dir.join("s.sock");
    let mut child = daemon_env::acpmux(&dir)
        .args(["daemon", "run", "--memory", "--ready-fd", "1", "--log", "warn"])
        .env("ACPMUX_HOME", &dir)
        .env("ACPMUX_SOCKET", &socket)
        .env("ACPMUX_LOGIN_ENV", "0")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::inherit())
        .spawn()
        .unwrap();
    let pid = child.id();
    let stdout = child.stdout.take().unwrap();
    let ready = BufReader::new(stdout)
        .lines()
        .map_while(Result::ok)
        .find_map(|line| serde_json::from_str::<Value>(&line).ok().filter(|v| v["ready"] == true));
    if ready.is_none() {
        let _ = child.kill();
        panic!("the daemon exited without a readiness line: {:?}", child.wait());
    }
    // The app's connection: a watch stream it keeps open for its whole life.
    let mut stream = UnixStream::connect(&socket).unwrap();
    let call = json!({"jsonrpc":"2.0","id":1,"method":"_acpmux/watch","params":{"enabled":true}});
    stream.write_all(format!("{call}\n").as_bytes()).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(30))).unwrap();
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    loop {
        let mut line = String::new();
        assert!(reader.read_line(&mut line).unwrap() > 0, "the daemon closed the watch stream");
        if serde_json::from_str::<Value>(&line).ok().is_some_and(|v| v["id"] == 1) {
            break;
        }
    }
    std::thread::sleep(SETTLE);

    let processes: Vec<(String, u32)> = std::iter::once(("daemon".to_string(), pid))
        .chain(children(pid).into_iter().map(|child| (format!("child {child}"), child)))
        .collect();
    let mut marks = vec![processes.iter().map(|(_, pid)| usage(*pid)).collect::<Vec<Usage>>()];
    for _ in 0..WINDOWS {
        std::thread::sleep(WINDOW);
        marks.push(processes.iter().map(|(_, pid)| usage(*pid)).collect());
    }
    let mut failures = Vec::new();
    for (at, (name, _)) in processes.iter().enumerate() {
        let windows: Vec<Usage> =
            marks.windows(2).map(|pair| delta(pair[0][at], pair[1][at])).collect();
        if woke(&windows) {
            failures.push(format!("{name}: {windows:?}"));
        }
    }
    let _ = child.kill();
    let _ = child.wait();
    drop(reader);
    let _ = fs::remove_dir_all(&dir);
    assert!(
        failures.is_empty(),
        "an idle acpmux daemon woke up (per {WINDOW:?} window): {failures:#?}"
    );
}
