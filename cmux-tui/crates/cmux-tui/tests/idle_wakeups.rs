//! An idle daemon must not wake up (plans/cmux-next/idle-wakeups.md): no
//! polling loops, no periodic ticks, no timed waits that only re-check a
//! flag. Every thread of the daemon and of each terminal host blocks until
//! an event (a client request, terminal output, a signal, a real deadline).
//!
//! The test starts a headless daemon with one terminal running `cat`, keeps
//! the streams the cmux app keeps open (an event subscription and a terminal
//! attach), lets it settle, and then counts context switches and CPU time of
//! the daemon and the terminal host over a quiet window. It also follows each
//! daemon thread across the windows: a thread that runs in every window wakes
//! on a timer, however cheap each wake is (issue 23087: an idle owner retried
//! a missing acpmux every 10 s and ran journal maintenance every 30 s for
//! good). acpmux is not running for these daemons, as on most machines, and
//! journal maintenance runs at a test interval of half a second.
#![cfg(unix)]

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_tui_core::platform::transport;

/// Quiet window over which wakeups are counted. Longer than the 10 s retry
/// cap of the daemon's reconnect loops, so a thread on such a loop runs in
/// every window.
const WINDOW: Duration = Duration::from_secs(12);
/// Consecutive windows measured; a process is judged by its median window, so
/// a one-off event (one window) passes and a periodic wake (every window) fails.
const WINDOWS: u32 = 3;
/// Time after setup for one-shot work (first render, journal flushes) to end.
const SETTLE: Duration = Duration::from_secs(3);
/// Context switches allowed per process in its median window. Any periodic
/// wake of 1 Hz or faster gives at least 12 in every window; a stray one-shot
/// event (a late journal fsync, a deadline set during setup, one write below a
/// watched folder) gives a few in one window.
const MAX_SWITCHES_PER_WINDOW: u64 = 5;
/// CPU allowed per process in its median window: about 0.4% of one core.
const MAX_CPU_PER_WINDOW: Duration = Duration::from_millis(50);
/// The journal maintenance interval of these daemons (debug builds read it):
/// a worker that ticks on its interval while nothing changed runs in every
/// window.
const MAINTENANCE_INTERVAL_MS: &str = "500";

struct Daemon {
    child: Child,
    socket: PathBuf,
    state: PathBuf,
    dir: PathBuf,
    acpmux: PathBuf,
}

impl Daemon {
    fn start(name: &str) -> Self {
        Self::start_with_settings(name, Path::new("cmux-next.json"))
    }

    /// `settings` is relative to the test's folder; its folders are created
    /// only when the file is at the top.
    fn start_with_settings(name: &str, settings: &Path) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir =
            PathBuf::from("/tmp").join(format!("cmux-idle-{name}-{}-{stamp}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let socket = dir.join("mux.sock");
        let state = dir.join("state");
        let config = dir.join("config.json");
        // This daemon's own acpmux socket, which nothing serves until a test
        // binds it (never the machine's acpmux).
        let acpmux = dir.join("acpmux").join("acpmux.sock");
        // The daemon's own settings file exists, as on a configured machine: its
        // watcher must not wake on the daemon's own reads of it (a Linux inotify
        // open event once fed a reload loop of ~40k reloads/s).
        let settings = dir.join(settings);
        if settings.parent() == Some(dir.as_path()) {
            fs::write(&settings, "{}\n").unwrap();
        }
        let child = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
            .args(["--headless", "--socket"])
            .arg(&socket)
            .arg("--state")
            .arg(&state)
            .env("CMUX_TUI_CONFIG", &config)
            .env("CMUX_NEXT_CONFIG_FILE", &settings)
            .env("ACPMUX_SOCKET", &acpmux)
            .env("CMUX_TUI_TEST_JOURNAL_MAINTENANCE_INTERVAL_MS", MAINTENANCE_INTERVAL_MS)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(15);
        while transport::connect(&socket).is_err() {
            assert!(Instant::now() < deadline, "daemon did not create {}", socket.display());
            std::thread::sleep(Duration::from_millis(25));
        }
        Self { child, socket, state, dir, acpmux }
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

/// Each thread of `pid` by id: its name and a counter that grows whenever the
/// thread runs (context switches on Linux, CPU time in nanoseconds on macOS,
/// which has no per-thread switch count).
#[cfg(target_os = "linux")]
fn thread_activity(pid: u32) -> std::collections::HashMap<u64, (String, u64)> {
    fs::read_dir(format!("/proc/{pid}/task"))
        .unwrap()
        .filter_map(Result::ok)
        .filter_map(|task| {
            let tid = task.file_name().to_str()?.parse::<u64>().ok()?;
            let name = fs::read_to_string(task.path().join("comm")).ok()?.trim().to_string();
            let switches = fs::read_to_string(task.path().join("status"))
                .ok()?
                .lines()
                .filter(|line| line.contains("ctxt_switches:"))
                .filter_map(|line| line.split_whitespace().nth(1)?.parse::<u64>().ok())
                .sum();
            Some((tid, (name, switches)))
        })
        .collect()
}

#[cfg(target_os = "macos")]
fn thread_activity(pid: u32) -> std::collections::HashMap<u64, (String, u64)> {
    use std::os::raw::{c_char, c_int, c_void};

    #[repr(C)]
    struct ThreadInfo {
        user_time: u64,
        system_time: u64,
        cpu_usage: i32,
        policy: i32,
        run_state: i32,
        flags: i32,
        sleep_time: i32,
        current_priority: i32,
        priority: i32,
        max_priority: i32,
        name: [c_char; 64],
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
    const PROC_PIDLISTTHREADS: c_int = 6;
    const PROC_PIDTHREADINFO: c_int = 5;

    let mut handles = vec![0_u64; 4096];
    let size = (handles.len() * size_of::<u64>()) as c_int;
    // SAFETY: the buffer holds `size` bytes of thread handles.
    let filled = unsafe {
        proc_pidinfo(pid as c_int, PROC_PIDLISTTHREADS, 0, handles.as_mut_ptr().cast(), size)
    };
    handles.truncate(usize::try_from(filled).unwrap_or(0) / size_of::<u64>());
    handles
        .into_iter()
        .filter_map(|handle| {
            // SAFETY: zeroed is a valid ThreadInfo (integers and a C string).
            let mut info: ThreadInfo = unsafe { std::mem::zeroed() };
            let size = size_of::<ThreadInfo>() as c_int;
            // SAFETY: the buffer matches the PROC_PIDTHREADINFO layout and size.
            let read = unsafe {
                proc_pidinfo(pid as c_int, PROC_PIDTHREADINFO, handle, (&raw mut info).cast(), size)
            };
            (read == size).then(|| {
                // SAFETY: the kernel NUL-terminates the thread name.
                let name = unsafe { std::ffi::CStr::from_ptr(info.name.as_ptr()) };
                (handle, (name.to_string_lossy().into_owned(), info.user_time + info.system_time))
            })
        })
        .collect()
}

/// Threads of the daemon that ran in every window: a timer wakes them, not
/// an event, however little each wake costs. A one-off event (a late journal
/// fsync, a deadline set during setup) runs a thread in one window.
fn periodic_threads(marks: &[std::collections::HashMap<u64, (String, u64)>]) -> Vec<String> {
    let Some(first) = marks.first() else { return Vec::new() };
    let mut periodic: Vec<String> = first
        .iter()
        .filter(|(id, _)| {
            marks.windows(2).all(|pair| match (pair[0].get(id), pair[1].get(id)) {
                (Some((_, before)), Some((_, after))) => after > before,
                _ => false,
            })
        })
        .map(|(id, (name, _))| format!("{name} (thread {id})"))
        .collect();
    periodic.sort();
    periodic
}

/// Whether a process woke up over the measured windows: its median window
/// (switches and CPU taken separately) is over the limit.
fn woke(windows: &[Usage]) -> bool {
    let mut switches: Vec<u64> = windows.iter().map(|used| used.switches).collect();
    let mut cpu: Vec<Duration> = windows.iter().map(|used| used.cpu).collect();
    switches.sort_unstable();
    cpu.sort_unstable();
    switches[switches.len() / 2] > MAX_SWITCHES_PER_WINDOW
        || cpu[cpu.len() / 2] > MAX_CPU_PER_WINDOW
}

#[test]
fn cmux_next_idle_verdict_ignores_a_one_off_burst_but_not_a_periodic_wake() {
    let window =
        |switches, cpu_ms| Usage { cpu: Duration::from_millis(cpu_ms), switches, wakeups: 0 };
    // A stray event in one window (a late fsync, one write below a watched folder): 6 switches.
    assert!(!woke(&[window(1, 1), window(6, 2), window(0, 0)]));
    // The 0789ec3f class: 2 to 130 switches a second, in every window.
    assert!(woke(&[window(20, 1), window(25, 1), window(21, 1)]));
    assert!(woke(&[window(1300, 30), window(1250, 28), window(1310, 31)]));
    // A periodic wake that starts during the measurement still fails.
    assert!(woke(&[window(0, 0), window(12, 1), window(11, 1)]));
    // So does steady CPU use.
    assert!(woke(&[window(2, 60), window(2, 70), window(1, 65)]));
}

#[test]
fn cmux_next_daemon_idle_has_no_periodic_wakeups() {
    let daemon = Daemon::start("daemon");
    // acpmux's folder is there from an earlier run; only its socket is not.
    fs::create_dir_all(daemon.acpmux.parent().unwrap()).unwrap();
    assert_idle(&daemon, || {});
    // The daemon waited for acpmux without retrying on a timer; it still
    // reaches acpmux as soon as acpmux binds its socket.
    assert_follows_acpmux_when_it_appears(&daemon);
}

/// Binds the daemon's acpmux socket the way acpmux does (creating its folder
/// first when it is missing) and expects the daemon's agent chat watch to
/// connect and start its watch at once, not at a later retry (those were up
/// to 10 s apart).
fn assert_follows_acpmux_when_it_appears(daemon: &Daemon) {
    let directory = daemon.acpmux.parent().unwrap();
    fs::create_dir_all(directory).unwrap();
    let listener = std::os::unix::net::UnixListener::bind(&daemon.acpmux).unwrap();
    listener.set_nonblocking(true).unwrap();
    let bound = Instant::now();
    let deadline = bound + Duration::from_secs(3);
    let stream = loop {
        match listener.accept() {
            Ok((stream, _)) => break stream,
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                assert!(
                    Instant::now() < deadline,
                    "the daemon did not connect to acpmux within 3 s of its socket appearing"
                );
                std::thread::sleep(Duration::from_millis(20));
            }
            Err(error) => panic!("accept on the acpmux socket: {error}"),
        }
    };
    stream.set_nonblocking(false).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    let mut reader = BufReader::new(stream);
    let mut first = String::new();
    reader.read_line(&mut first).unwrap();
    let initialize: serde_json::Value = serde_json::from_str(&first).unwrap();
    assert_eq!(initialize["method"], "initialize", "{first}");
    assert_eq!(initialize["params"]["clientInfo"]["name"], "cmux-tui-agent-chat-notices");
    let mut second = String::new();
    reader.read_line(&mut second).unwrap();
    let watch: serde_json::Value = serde_json::from_str(&second).unwrap();
    assert_eq!(watch["method"], "_acpmux/watch", "{second}");
    let _ = writeln!(
        std::io::stderr(),
        "acpmux socket bound: the daemon connected after {:?}",
        bound.elapsed()
    );
}

/// Before the first save the settings folder does not exist, so the daemon
/// watches its nearest existing ancestor (the home folder or ~/.config for a
/// real install; /Library while /Library/Managed Preferences is missing on
/// every unmanaged Mac). Writes anywhere below that ancestor must not wake
/// the daemon: only the missing folder appearing matters (on macOS, an
/// FSEvents watch of /Library woke it for every write under /Library, 2-130
/// context switches/s on busy CI minis).
#[test]
fn cmux_next_daemon_idle_ignores_writes_below_a_missing_settings_folder() {
    let daemon = Daemon::start_with_settings("ancestor", Path::new("config/cmux/cmux-next.json"));
    let busy = daemon.dir.join("busy/deep/er");
    fs::create_dir_all(&busy).unwrap();
    assert_idle(&daemon, move || {
        // About 20 writes a second through the windows, in a folder beside
        // the missing one.
        let end = Instant::now() + WINDOW * WINDOWS - Duration::from_millis(100);
        let mut round = 0u64;
        while Instant::now() < end {
            fs::write(busy.join(format!("file-{}", round % 8)), round.to_string()).unwrap();
            round += 1;
            std::thread::sleep(Duration::from_millis(50));
        }
    });
    assert!(!daemon.dir.join("config").exists(), "the daemon created the settings folder");
    // acpmux has never run here: its folder appears with its socket.
    assert!(!daemon.acpmux.parent().unwrap().exists());
    assert_follows_acpmux_when_it_appears(&daemon);
}

/// Starts a terminal, keeps the app's streams open, settles, then runs
/// `during` across the quiet windows and fails when the daemon or a terminal
/// host woke up (see [`woke`]).
fn assert_idle(daemon: &Daemon, during: impl FnOnce() + Send + 'static) {
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
    let daemon_pid = daemon.child.id();
    let mut marks = vec![processes.iter().map(|(_, pid)| usage(*pid)).collect::<Vec<Usage>>()];
    let mut threads = vec![thread_activity(daemon_pid)];
    let started = Instant::now();
    let activity = std::thread::spawn(during);
    for _ in 0..WINDOWS {
        std::thread::sleep(WINDOW);
        marks.push(processes.iter().map(|(_, pid)| usage(*pid)).collect());
        threads.push(thread_activity(daemon_pid));
    }
    activity.join().unwrap();
    assert!(
        started.elapsed() < WINDOW * WINDOWS + Duration::from_secs(2),
        "the activity outlived the windows"
    );

    let mut failures = Vec::new();
    for (index, (name, _)) in processes.iter().enumerate() {
        let windows: Vec<Usage> =
            marks.windows(2).map(|pair| delta(pair[0][index], pair[1][index])).collect();
        let line = format!(
            "idle {name}: {} ({WINDOWS} windows of {WINDOW:?})",
            windows
                .iter()
                .map(|used| format!(
                    "cpu {:.1} ms, {} context switches, {} wakeups",
                    used.cpu.as_secs_f64() * 1000.0,
                    used.switches,
                    used.wakeups
                ))
                .collect::<Vec<_>>()
                .join(" | "),
        );
        // Not captured by libtest, so CI logs carry the numbers on success too.
        let _ = writeln!(std::io::stderr(), "{line}");
        if woke(&windows) {
            failures.push(line);
        }
    }
    let periodic = periodic_threads(&threads);
    if !periodic.is_empty() {
        failures.push(format!(
            "daemon threads that ran in each of the {WINDOWS} windows of {WINDOW:?}: {}",
            periodic.join(", ")
        ));
    }
    assert!(failures.is_empty(), "idle processes woke up:\n{}", failures.join("\n"));
}
