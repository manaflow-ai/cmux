//! An idle daemon must not wake up (plans/cmux-next/idle-wakeups.md): no
//! polling loops, no periodic ticks, no timed waits that only re-check a
//! flag. Every thread of the daemon and of each terminal host blocks until
//! an event (a client request, terminal output, a signal, a real deadline).
//!
//! The test starts a headless daemon with one terminal running `cat`, keeps
//! the streams the cmux app keeps open (an event subscription and a terminal
//! attach), lets it settle, and then counts context switches and CPU time of
//! the daemon and the terminal host over a quiet window.
#![cfg(unix)]

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_tui_core::platform::transport;

/// Quiet window over which wakeups are counted.
const WINDOW: Duration = Duration::from_secs(10);
/// Time after setup for one-shot work (first render, journal flushes) to end.
const SETTLE: Duration = Duration::from_secs(3);
/// Context switches allowed per process in the window. Any periodic wake of
/// 1 Hz or faster gives at least 10; a stray one-shot event (a late journal
/// fsync, a deadline set during setup) gives one or two.
const MAX_SWITCHES_PER_WINDOW: u64 = 5;
/// CPU allowed per process in the window: 0.5% of one core.
const MAX_CPU_PER_WINDOW: Duration = Duration::from_millis(50);

struct Daemon {
    child: Child,
    socket: PathBuf,
    state: PathBuf,
    dir: PathBuf,
}

impl Daemon {
    fn start(name: &str) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir =
            PathBuf::from("/tmp").join(format!("cmux-idle-{name}-{}-{stamp}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let socket = dir.join("mux.sock");
        let state = dir.join("state");
        let config = dir.join("config.json");
        let child = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
            .args(["--headless", "--socket"])
            .arg(&socket)
            .arg("--state")
            .arg(&state)
            .env("CMUX_TUI_CONFIG", &config)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(15);
        while transport::connect(&socket).is_err() {
            assert!(Instant::now() < deadline, "daemon did not create {}", socket.display());
            std::thread::sleep(Duration::from_millis(25));
        }
        Self { child, socket, state, dir }
    }

    fn host_pids(&self) -> Vec<u32> {
        let root = cmux_tui_core::terminal_host_runtime::terminal_host_root(&self.state, "main");
        fs::read_dir(root)
            .ok()
            .into_iter()
            .flatten()
            .filter_map(Result::ok)
            .filter_map(|entry| fs::read(entry.path()).ok())
            .filter_map(|bytes| serde_json::from_slice::<serde_json::Value>(&bytes).ok())
            .filter_map(|record| record["host_pid"].as_u64())
            .filter_map(|pid| u32::try_from(pid).ok())
            .collect()
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let hosts = self.host_pids();
        let _ = request(&self.socket, serde_json::json!({"id": 900, "cmd": "list-workspaces"}))
            .map(|tree| {
                for workspace in tree["workspaces"].as_array().into_iter().flatten() {
                    let _ = request(
                        &self.socket,
                        serde_json::json!({
                            "id": 901,
                            "cmd": "close-workspace",
                            "key": workspace["key"],
                            "end_terminals": true,
                        }),
                    );
                }
            });
        let deadline = Instant::now() + Duration::from_secs(10);
        while hosts.iter().any(|pid| process_exists(*pid)) && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(25));
        }
        for pid in hosts.iter().filter(|pid| process_exists(**pid)) {
            // SAFETY: the pid came from this test's own host records.
            unsafe { libc::kill(*pid as libc::pid_t, libc::SIGKILL) };
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = fs::remove_dir_all(&self.dir);
    }
}

fn process_exists(pid: u32) -> bool {
    // SAFETY: signal zero only checks for existence.
    unsafe { libc::kill(pid as libc::pid_t, 0) == 0 }
}

fn request(path: &Path, value: serde_json::Value) -> Option<serde_json::Value> {
    let stream = transport::connect(path).ok()?;
    let mut writer = stream.try_clone_box().ok()?;
    let mut reader = BufReader::new(stream);
    writeln!(writer, "{value}").ok()?;
    let mut line = String::new();
    reader.read_line(&mut line).ok()?;
    let response: serde_json::Value = serde_json::from_str(&line).ok()?;
    (response["ok"] == true).then(|| response["data"].clone())
}

/// A long-lived stream like the app's: sends one request, reads its reply,
/// then keeps the connection open and drains events on a thread.
struct OpenStream {
    _writer: Box<dyn transport::Stream>,
    _reader: std::thread::JoinHandle<()>,
}

fn open_stream(path: &Path, value: serde_json::Value) -> OpenStream {
    let stream = transport::connect(path).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let id = value["id"].clone();
    writeln!(writer, "{value}").unwrap();
    let mut reader = BufReader::new(stream);
    loop {
        let mut line = String::new();
        assert!(reader.read_line(&mut line).unwrap() > 0, "stream closed before its reply");
        let message: serde_json::Value = serde_json::from_str(&line).unwrap();
        if message["id"] == id {
            assert_eq!(message["ok"], true, "stream request failed: {message}");
            break;
        }
    }
    let drain = std::thread::spawn(move || {
        let mut line = String::new();
        while reader.read_line(&mut line).map(|n| n > 0).unwrap_or(false) {
            line.clear();
        }
    });
    OpenStream { _writer: writer, _reader: drain }
}

#[derive(Clone, Copy, Debug)]
struct Usage {
    cpu: Duration,
    switches: u64,
    /// macOS package idle plus interrupt wakeups; 0 elsewhere.
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

/// Per-thread counters also count threads that exit during the window as
/// lost switches on Linux, so a thread that ends reads as fewer switches;
/// that can only make the test more lenient, never flaky.
fn delta(before: Usage, after: Usage) -> Usage {
    Usage {
        cpu: after.cpu.saturating_sub(before.cpu),
        switches: after.switches.saturating_sub(before.switches),
        wakeups: after.wakeups.saturating_sub(before.wakeups),
    }
}

#[test]
fn cmux_next_daemon_idle_has_no_periodic_wakeups() {
    let daemon = Daemon::start("daemon");
    let created = request(
        &daemon.socket,
        serde_json::json!({
            "id": 1,
            "cmd": "run",
            "argv": ["/bin/cat"],
            "new_workspace": true,
            "name": "idle",
        }),
    )
    .expect("run /bin/cat");
    assert!(created["terminal_id"].is_string(), "{created}");
    let tree = request(&daemon.socket, serde_json::json!({"id": 2, "cmd": "list-workspaces"}))
        .expect("list-workspaces");
    let surface = tree["workspaces"]
        .as_array()
        .into_iter()
        .flatten()
        .flat_map(|workspace| workspace["screens"].as_array().into_iter().flatten())
        .flat_map(|screen| screen["panes"].as_array().into_iter().flatten())
        .flat_map(|pane| pane["tabs"].as_array().into_iter().flatten())
        .find_map(|tab| tab["surface"].as_u64())
        .expect("the terminal's surface");
    // The app keeps an event subscription and one attach per visible terminal.
    let _events = open_stream(&daemon.socket, serde_json::json!({"id": 3, "cmd": "subscribe"}));
    let _attach = open_stream(
        &daemon.socket,
        serde_json::json!({"id": 4, "cmd": "attach-surface", "surface": surface, "cols": 80, "rows": 24}),
    );

    let deadline = Instant::now() + Duration::from_secs(10);
    let hosts = loop {
        let hosts = daemon.host_pids();
        if !hosts.is_empty() {
            break hosts;
        }
        assert!(Instant::now() < deadline, "no terminal host record appeared");
        std::thread::sleep(Duration::from_millis(25));
    };
    std::thread::sleep(SETTLE);

    let processes: Vec<(String, u32)> = std::iter::once(("daemon".to_string(), daemon.child.id()))
        .chain(hosts.iter().map(|pid| (format!("terminal host {pid}"), *pid)))
        .collect();
    let before: Vec<Usage> = processes.iter().map(|(_, pid)| usage(*pid)).collect();
    std::thread::sleep(WINDOW);
    let after: Vec<Usage> = processes.iter().map(|(_, pid)| usage(*pid)).collect();

    let mut failures = Vec::new();
    for ((name, _), (before, after)) in processes.iter().zip(before.into_iter().zip(after)) {
        let used = delta(before, after);
        let line = format!(
            "idle {name}: cpu {:.1} ms, {} context switches, {} wakeups in {:?} ({:.2}/s)",
            used.cpu.as_secs_f64() * 1000.0,
            used.switches,
            used.wakeups,
            WINDOW,
            used.switches as f64 / WINDOW.as_secs_f64(),
        );
        // Not captured by libtest, so CI logs carry the numbers on success too.
        let _ = writeln!(std::io::stderr(), "{line}");
        if used.switches > MAX_SWITCHES_PER_WINDOW || used.cpu > MAX_CPU_PER_WINDOW {
            failures.push(line);
        }
    }
    assert!(failures.is_empty(), "idle processes woke up:\n{}", failures.join("\n"));
}
