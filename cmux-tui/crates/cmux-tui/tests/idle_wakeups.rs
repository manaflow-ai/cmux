//! An idle daemon must not wake up (plans/cmux-next/idle-wakeups.md): no
//! polling loops, no periodic ticks, no timed waits that only re-check a
//! flag. Every thread of the daemon and of each terminal host blocks until
//! an event (a client request, terminal output, a signal, a real deadline).
//!
//! Each test starts a headless daemon with terminals running `cat`, keeps
//! the streams the cmux app keeps open (an event subscription and a terminal
//! attach; every stream the app keeps in one case), lets it settle, and then
//! counts context switches and CPU time of the daemon and of every process
//! that holds a terminal (a terminal host each, or the one holder) over
//! quiet windows. The cases (plans/cmux-next/chrome-parity/p14-energy.md,
//! D9): one terminal, the holder model, 20 terminals, every app stream, and
//! a journal hook, all on the same thresholds.
#![cfg(unix)]

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_tui_core::platform::transport;

/// Quiet window over which wakeups are counted.
const WINDOW: Duration = Duration::from_secs(10);
/// Consecutive windows measured; a process is judged by its median window, so
/// a one-off event (one window) passes and a periodic wake (every window) fails.
const WINDOWS: u32 = 3;
/// Time after setup for one-shot work (first render, journal flushes) to end.
const SETTLE: Duration = Duration::from_secs(3);
/// Context switches allowed per process in its median window. Any periodic
/// wake of 1 Hz or faster gives at least 10 in every window; a stray one-shot
/// event (a late journal fsync, a deadline set during setup, one write below a
/// watched folder) gives a few in one window.
const MAX_SWITCHES_PER_WINDOW: u64 = 5;
/// CPU allowed per process in its median window: 0.5% of one core.
const MAX_CPU_PER_WINDOW: Duration = Duration::from_millis(50);

struct Daemon {
    child: Child,
    socket: PathBuf,
    state: PathBuf,
    dir: PathBuf,
    /// Processes that hold this daemon's terminals (hosts or the holder),
    /// ended at drop: a holder outlives its daemon on purpose.
    helpers: Vec<u32>,
}

impl Daemon {
    fn start(name: &str) -> Self {
        Self::start_with(name, Path::new("cmux-next.json"), &[])
    }

    /// `settings` is relative to the test's folder; its folders are created
    /// only when the file is at the top.
    fn start_with_settings(name: &str, settings: &Path) -> Self {
        Self::start_with(name, settings, &[])
    }

    /// Terminals on the install's one holder process
    /// (terminal-host-model-DESIGN.md) instead of a host process each.
    fn start_holder(name: &str) -> Self {
        Self::start_with(
            name,
            Path::new("cmux-next.json"),
            &[("CMUX_TUI_TERMINAL_HOST_MODEL", "holder")],
        )
    }

    fn start_with(name: &str, settings: &Path, env: &[(&str, &str)]) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir =
            PathBuf::from("/tmp").join(format!("cmux-idle-{name}-{}-{stamp}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let socket = dir.join("mux.sock");
        let state = dir.join("state");
        let config = dir.join("config.json");
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
            .envs(env.iter().copied())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(15);
        while transport::connect(&socket).is_err() {
            assert!(Instant::now() < deadline, "daemon did not create {}", socket.display());
            std::thread::sleep(Duration::from_millis(25));
        }
        Self { child, socket, state, dir, helpers: Vec::new() }
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
        // After the daemon, so it cannot start a new holder.
        for pid in self.helpers.iter().filter(|pid| process_exists(**pid)) {
            // SAFETY: the pid was the parent of one of this daemon's terminals.
            unsafe { libc::kill(*pid as libc::pid_t, libc::SIGKILL) };
        }
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
    open_stream_after(path, &[value])
}

/// Sends `requests` in order on one connection, each after the reply to the
/// one before (a handshake, then the stream request), then keeps it open.
fn open_stream_after(path: &Path, requests: &[serde_json::Value]) -> OpenStream {
    let stream = transport::connect(path).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    for value in requests {
        let id = value["id"].clone();
        writeln!(writer, "{value}").unwrap();
        loop {
            let mut line = String::new();
            assert!(reader.read_line(&mut line).unwrap() > 0, "stream closed before its reply");
            let message: serde_json::Value = serde_json::from_str(&line).unwrap();
            if message["id"] == id {
                assert_eq!(message["ok"], true, "stream request {value} failed: {message}");
                break;
            }
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
    assert_idle(&mut Daemon::start("daemon"), || {});
}

/// On the holder model one holder process keeps every terminal's master in
/// one poll set; it is judged with the daemon and must sleep in that poll.
#[test]
fn cmux_next_daemon_idle_holder_mode() {
    let mut daemon = Daemon::start_holder("holder");
    assert_idle_session(&mut daemon, Session::ONE_TERMINAL, || {});
    assert!(daemon.host_pids().is_empty(), "the holder model started a terminal host");
    assert!(!daemon.helpers.is_empty(), "no holder process held the terminal");
}

/// Twenty idle terminals cost no more wakeups than one: nothing in the
/// daemon or a host walks the terminals on a timer.
#[test]
fn cmux_next_daemon_idle_twenty_terminals() {
    assert_idle_session(
        &mut Daemon::start("twenty"),
        Session { terminals: 20, ..Session::ONE_TERMINAL },
        || {},
    );
}

/// Every stream the app keeps open over twenty terminals (see
/// [`open_app_streams`]) waits for an event and never on a timer.
#[test]
fn cmux_next_daemon_idle_all_app_streams() {
    assert_idle_session(
        &mut Daemon::start("streams"),
        Session { terminals: 20, all_app_streams: true, ..Session::ONE_TERMINAL },
        || {},
    );
}

/// A daemon-rendered browser tab (`new-browser-tab`, as the terminal UI and
/// the phone lane open one, or a restored one) while no cmux-browser
/// provider is attached: the app renders its own tabs in WebKit and
/// registers no provider, so this tab waits for a CDP target that never
/// comes. Its bootstrap thread must sleep until a provider registers or the
/// tab closes; a 250 ms re-check of its cancel flag woke the daemon 4 times
/// a second (41-43 context switches per 10 s window on Linux).
#[test]
fn cmux_next_daemon_idle_unprovided_browser_tab() {
    assert_idle_session(
        &mut Daemon::start("unprovided"),
        Session { unprovided_browser_tab: true, ..Session::ONE_TERMINAL },
        || {},
    );
}

/// A journal hook (session.journal.hook.put) that already ran once: its
/// dispatcher and delivery workers then wait for the next journal record.
#[test]
fn cmux_next_daemon_idle_with_hook_plugin() {
    assert_idle_session(
        &mut Daemon::start("hook"),
        Session { hook: true, ..Session::ONE_TERMINAL },
        || {},
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
    let mut daemon =
        Daemon::start_with_settings("ancestor", Path::new("config/cmux/cmux-next.json"));
    let busy = daemon.dir.join("busy/deep/er");
    fs::create_dir_all(&busy).unwrap();
    assert_idle(&mut daemon, move || {
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
}

/// What the idle session holds when the windows start.
#[derive(Clone, Copy)]
struct Session {
    /// Terminals running `cat`, one workspace each.
    terminals: usize,
    /// Every stream the app keeps (see [`open_app_streams`]) instead of the
    /// event subscription and one attach of the visible terminal.
    all_app_streams: bool,
    /// A daemon-rendered browser tab no provider takes, with a viewer
    /// attached (see [`open_unprovided_browser_tab`]).
    unprovided_browser_tab: bool,
    /// A journal plugin (a producer and a hook on its records, see
    /// [`install_hook_plugin`]) whose hook ran once before settling.
    hook: bool,
}

impl Session {
    const ONE_TERMINAL: Self =
        Self { terminals: 1, all_app_streams: false, unprovided_browser_tab: false, hook: false };
}

struct Terminal {
    surface: u64,
}

fn assert_idle(daemon: &mut Daemon, during: impl FnOnce() + Send + 'static) {
    assert_idle_session(daemon, Session::ONE_TERMINAL, during);
}

/// Sets up `session`, settles, then runs `during` across the quiet windows
/// and fails when the daemon or a process holding a terminal woke up (see
/// [`woke`]).
fn assert_idle_session(
    daemon: &mut Daemon,
    session: Session,
    during: impl FnOnce() + Send + 'static,
) {
    let hook_ran = session.hook.then(|| install_hook_plugin(daemon));
    let terminals: Vec<Terminal> = (0..session.terminals)
        .map(|index| {
            let created = request(
                &daemon.socket,
                serde_json::json!({
                    "id": 1,
                    "cmd": "run",
                    "argv": ["/bin/cat"],
                    "new_workspace": true,
                    "name": format!("idle-{index}"),
                }),
            )
            .expect("run /bin/cat");
            assert!(created["terminal_id"].is_string(), "{created}");
            Terminal { surface: created["surface"].as_u64().expect("the terminal's surface") }
        })
        .collect();
    let mut streams = if session.all_app_streams {
        open_app_streams(daemon, &terminals)
    } else {
        // An event subscription and one attach per visible terminal.
        let visible = terminals.first().expect("a terminal").surface;
        vec![
            open_stream(&daemon.socket, serde_json::json!({"id": 3, "cmd": "subscribe"})),
            open_stream(
                &daemon.socket,
                serde_json::json!({"id": 4, "cmd": "attach-surface", "surface": visible, "cols": 80, "rows": 24}),
            ),
        ]
    };
    if session.unprovided_browser_tab {
        streams.push(open_unprovided_browser_tab(daemon, &terminals));
    }
    if let Some(marker) = hook_ran {
        let deadline = Instant::now() + Duration::from_secs(20);
        while fs::metadata(&marker).map(|meta| meta.len()).unwrap_or(0) == 0 {
            assert!(Instant::now() < deadline, "the journal hook never ran");
            std::thread::sleep(Duration::from_millis(25));
        }
    }

    let daemon_pid = daemon.child.id();
    let deadline = Instant::now() + Duration::from_secs(20);
    let holders = loop {
        let mut holders = daemon.host_pids();
        if let Some(parents) = terminal_parents(&daemon.socket, &terminals) {
            for parent in parents {
                if !holders.contains(&parent) {
                    holders.push(parent);
                }
            }
            holders.retain(|pid| *pid != daemon_pid);
            if !holders.is_empty() {
                break holders;
            }
        }
        assert!(Instant::now() < deadline, "no process holds the terminals");
        std::thread::sleep(Duration::from_millis(25));
    };
    let hosts = daemon.host_pids();
    // Only the holder: a host ends with its terminal at drop, and its pid
    // may be reused by then.
    daemon.helpers = holders.iter().copied().filter(|pid| !hosts.contains(pid)).collect();
    std::thread::sleep(SETTLE);

    let processes: Vec<(String, u32)> = std::iter::once(("daemon".to_string(), daemon_pid))
        .chain(holders.iter().map(|pid| {
            let kind = if hosts.contains(pid) { "terminal host" } else { "holder" };
            (format!("{kind} {pid}"), *pid)
        }))
        .collect();
    let mut marks = vec![processes.iter().map(|(_, pid)| usage(*pid)).collect::<Vec<Usage>>()];
    let started = Instant::now();
    let activity = std::thread::spawn(during);
    for _ in 0..WINDOWS {
        std::thread::sleep(WINDOW);
        marks.push(processes.iter().map(|(_, pid)| usage(*pid)).collect());
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
    assert!(failures.is_empty(), "idle processes woke up:\n{}", failures.join("\n"));
}

/// The streams the app keeps open on its local daemon:
/// - its main connection's subscription with tree deltas (`HandshakeLines`),
///   which also carries the sidebar's and the notifications' changes;
/// - a page relay that hears its page's events (`PageRelayHandshake`; the
///   history page, the one page-router.json gives events);
/// - one attach per terminal;
/// - a browser tab the app renders itself (WebKit,
///   `new-frontend-browser-tab`), which has no daemon stream.
///
/// The app opens no daemon-rendered browser tab and registers no browser
/// provider; [`cmux_next_daemon_idle_unprovided_browser_tab`] covers that
/// tab apart.
///
/// A notification is posted first, so the notifications list is not empty.
/// Not here: the OSC 52 clipboard-read broker (`TerminalClipboardReadService`),
/// which the daemon grants only to the verified app's frontend.
fn open_app_streams(daemon: &Daemon, terminals: &[Terminal]) -> Vec<OpenStream> {
    let first = terminals.first().expect("a terminal").surface;
    request(
        &daemon.socket,
        serde_json::json!({
            "id": 10,
            "cmd": "notify",
            "title": "idle",
            "body": "a notification the app lists",
            "surface": first,
        }),
    )
    .expect("notify");
    let pane = pane_of(&daemon.socket, first).expect("the first terminal's pane");
    request(
        &daemon.socket,
        serde_json::json!({
            "id": 13,
            "cmd": "new-frontend-browser-tab",
            "url": "about:blank",
            "engine": "webkit",
            "pane": pane,
        }),
    )
    .expect("new-frontend-browser-tab");

    let mut streams = vec![
        open_stream(
            &daemon.socket,
            serde_json::json!({"id": 12, "cmd": "subscribe", "tree_events": "deltas"}),
        ),
        open_stream_after(
            &daemon.socket,
            &[
                serde_json::json!({"id": 14, "cmd": "client-hello", "role": "page_relay", "page": "history"}),
                serde_json::json!({"id": 15, "cmd": "subscribe", "tree_events": "coarse"}),
            ],
        ),
    ];
    streams.extend(terminals.iter().map(|terminal| {
        open_stream(
            &daemon.socket,
            serde_json::json!({"id": 18, "cmd": "attach-surface", "surface": terminal.surface, "cols": 80, "rows": 24}),
        )
    }));
    streams
}

/// Opens a daemon-rendered browser tab beside the first terminal and
/// attaches a viewer to it, as the terminal UI does. No provider is
/// attached, so the tab stays `starting` and no frame ever streams.
fn open_unprovided_browser_tab(daemon: &Daemon, terminals: &[Terminal]) -> OpenStream {
    let first = terminals.first().expect("a terminal").surface;
    let pane = pane_of(&daemon.socket, first).expect("the first terminal's pane");
    let browser = request(
        &daemon.socket,
        serde_json::json!({"id": 11, "cmd": "new-browser-tab", "url": "about:blank", "pane": pane}),
    )
    .expect("new-browser-tab")["surface"]
        .as_u64()
        .expect("the browser tab's surface");
    // A browser attach needs the pointer-frame capability. Unsized: a sized
    // attach first waits for a browser engine to take the size, and no
    // provider is here to take it.
    open_stream_after(
        &daemon.socket,
        &[
            serde_json::json!({
                "id": 16,
                "cmd": "set-client-info",
                "name": "idle-test",
                "capabilities": ["browser-pointer-frame-guard-v1"],
            }),
            serde_json::json!({"id": 17, "cmd": "attach-surface", "surface": browser}),
        ],
    )
}

/// The pane that shows `surface`.
fn pane_of(socket: &Path, surface: u64) -> Option<serde_json::Value> {
    let tree = request(socket, serde_json::json!({"id": 19, "cmd": "list-workspaces"}))?;
    tree["workspaces"]
        .as_array()
        .into_iter()
        .flatten()
        .flat_map(|workspace| workspace["screens"].as_array().into_iter().flatten())
        .flat_map(|screen| screen["panes"].as_array().into_iter().flatten())
        .find(|pane| {
            pane["tabs"]
                .as_array()
                .into_iter()
                .flatten()
                .any(|tab| tab["surface"].as_u64() == Some(surface))
        })
        .map(|pane| pane["id"].clone())
}

/// The parent of every terminal's process (its terminal host, or the
/// holder), once every terminal has one.
fn terminal_parents(socket: &Path, terminals: &[Terminal]) -> Option<Vec<u32>> {
    let surfaces: Vec<u64> = terminals.iter().map(|terminal| terminal.surface).collect();
    let resources = request(
        socket,
        serde_json::json!({"id": 20, "cmd": "terminal-resources", "surfaces": surfaces}),
    )?;
    let pids: Vec<u32> = resources["terminals"]
        .as_array()?
        .iter()
        .filter_map(|terminal| u32::try_from(terminal["pid"].as_u64()?).ok())
        .collect();
    if pids.len() < terminals.len() {
        return None;
    }
    let mut parents: Vec<u32> = pids.into_iter().filter_map(parent_of).collect();
    parents.sort_unstable();
    parents.dedup();
    (!parents.is_empty()).then_some(parents)
}

fn parent_of(pid: u32) -> Option<u32> {
    let out = Command::new("ps").args(["-o", "ppid=", "-p", &pid.to_string()]).output().ok()?;
    String::from_utf8_lossy(&out.stdout).trim().parse().ok().filter(|parent| *parent > 1)
}

/// Installs a journal plugin as a user's would: a producer of
/// `plugin.idle.*` records and a hook on them whose command appends each
/// delivered record to a file. Appends one record and returns that file.
fn install_hook_plugin(daemon: &Daemon) -> PathBuf {
    let marker = daemon.dir.join("hook-ran");
    put_manifest(
        &daemon.socket,
        "session.journal.producer.put",
        serde_json::json!({
            "producer_id": "idle",
            "namespace": "plugin.idle",
            "manifest_version": 1,
            "max_sensitivity": "metadata",
            "permissions": ["journal.append.plugin.idle"],
            "events": [{
                "kind": "plugin.idle.ping",
                "schema_version": 1,
                "class": "observation",
                "replay": "advisory",
                "sensitivity": "metadata",
                "payload_schema": {"type": "object", "additionalProperties": false},
            }],
        }),
    );
    put_manifest(
        &daemon.socket,
        "session.journal.hook.put",
        serde_json::json!({
            "hook_id": "idle_hook",
            "manifest_version": 1,
            "filter": {"kinds": ["plugin.idle.*"]},
            // The hook runs with an empty environment: no PATH.
            "exec": {
                "argv": ["/bin/sh", "-c", "/bin/cat >> \"$0\"", marker],
                "timeout_ms": 5000,
                "max_parallel": 1,
            },
            "delivery": {"start": "tail", "retry": {"max_attempts": 1, "backoff_ms": 0}},
            "permissions": ["journal.read"],
        }),
    );
    let event = serde_json::json!({
        "producer_id": "idle",
        "manifest_version": 1,
        "kind": "plugin.idle.ping",
        "schema_version": 1,
        "payload": {},
    });
    resource_call(
        &daemon.socket,
        "session.journal.append",
        serde_json::json!({"machine": "current", "session": "current", "event": event}),
    );
    marker
}

/// A `cmux.protocol/2` put of `manifest` in the current session.
fn put_manifest(socket: &Path, operation: &str, manifest: serde_json::Value) {
    resource_call(
        socket,
        operation,
        serde_json::json!({"machine": "current", "session": "current", "manifest": manifest}),
    );
}

fn resource_call(socket: &Path, operation: &str, params: serde_json::Value) {
    let call = serde_json::json!({
        "protocol": "cmux.protocol/2",
        "type": "request",
        "id": operation,
        "operation": operation,
        "idempotency_key": format!("idle-{operation}"),
        "params": params,
    });
    let stream = transport::connect(socket).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    writeln!(writer, "{call}").unwrap();
    let mut reader = BufReader::new(stream);
    loop {
        let mut line = String::new();
        assert!(reader.read_line(&mut line).unwrap() > 0, "the daemon closed before its reply");
        let reply: serde_json::Value = serde_json::from_str(&line).unwrap();
        if reply["id"] == call["id"] {
            assert_eq!(reply["ok"], true, "{operation} failed: {reply}");
            return;
        }
    }
}
