//! Threads of a headless daemon must not grow with its terminals (perf100
//! tui lane). One Chief daemon had 1743 threads on 2026-10-20: four per
//! terminal (`surface-<id>-host`, `-host-frames`, `-frames`,
//! `terminal-host-reaper`) and one per browser surface. The render frame
//! producer and the host reaper are shared now, so each terminal costs at
//! most its two host-stream threads.
//!
//! The test starts a headless daemon, opens `TERMINALS` terminals running
//! `cat` with the app's streams (an event subscription and an attach per
//! terminal), checks that every terminal renders its output, counts the
//! daemon's threads, then ends the terminals and checks that every terminal
//! host is reaped (gone, not a zombie) and the threads return.
#![cfg(unix)]

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_tui_core::platform::transport;

const TERMINALS: usize = 24;
/// Threads each terminal may add to the daemon. Today: the host stream
/// reader and its demultiplexer. Before perf100: 4.
const MAX_THREADS_PER_TERMINAL: f64 = 2.25;
/// Threads each attach connection (the app opens one per visible terminal)
/// may add. Measured before any change; lower it when the connection
/// threads are shared.
const MAX_THREADS_PER_ATTACH: f64 = 8.0;

fn test_timeout(timeout: Duration) -> Duration {
    let scale = std::env::var("CMUX_TEST_TIMEOUT_SCALE")
        .ok()
        .and_then(|value| value.parse::<u32>().ok())
        .unwrap_or(1)
        .clamp(1, 16);
    timeout.saturating_mul(scale)
}

struct Daemon {
    child: Child,
    socket: PathBuf,
    state: PathBuf,
    dir: PathBuf,
}

impl Daemon {
    fn start(name: &str) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir = PathBuf::from("/tmp")
            .join(format!("cmux-threads-{name}-{}-{stamp}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let socket = dir.join("mux.sock");
        let state = dir.join("state");
        let settings = dir.join("cmux-next.json");
        fs::write(&settings, "{}\n").unwrap();
        let child = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
            .args(["--headless", "--socket"])
            .arg(&socket)
            .arg("--state")
            .arg(&state)
            .env("CMUX_TUI_CONFIG", dir.join("config.json"))
            .env("CMUX_NEXT_CONFIG_FILE", &settings)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let deadline = Instant::now() + test_timeout(Duration::from_secs(15));
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
        for pid in self.host_pids().into_iter().filter(|pid| process_exists(*pid)) {
            // SAFETY: the pid came from this test's own host records.
            unsafe { libc::kill(pid as libc::pid_t, libc::SIGKILL) };
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = fs::remove_dir_all(&self.dir);
    }
}

/// True while the process exists, a zombie included.
fn process_exists(pid: u32) -> bool {
    // SAFETY: signal zero only checks for existence.
    unsafe { libc::kill(pid as libc::pid_t, 0) == 0 }
}

fn request(path: &Path, value: serde_json::Value) -> serde_json::Value {
    let stream = transport::connect(path).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    writeln!(writer, "{value}").unwrap();
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    let response: serde_json::Value = serde_json::from_str(&line).unwrap();
    assert_eq!(response["ok"], true, "{value} failed: {response}");
    response["data"].clone()
}

#[cfg(target_os = "macos")]
fn thread_count(pid: u32) -> usize {
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
    unsafe extern "C" {
        fn proc_pidinfo(
            pid: c_int,
            flavor: c_int,
            arg: u64,
            buffer: *mut c_void,
            size: c_int,
        ) -> c_int;
    }
    const PROC_PIDTASKINFO: c_int = 4;
    let mut task = TaskInfo::default();
    let size = size_of::<TaskInfo>() as c_int;
    // SAFETY: the buffer matches the flavor's C layout and size.
    let read =
        unsafe { proc_pidinfo(pid as c_int, PROC_PIDTASKINFO, 0, (&raw mut task).cast(), size) };
    assert_eq!(read, size, "proc_pidinfo({pid})");
    task.threadnum.max(0) as usize
}

#[cfg(not(target_os = "macos"))]
fn thread_count(pid: u32) -> usize {
    fs::read_dir(format!("/proc/{pid}/task")).unwrap().count()
}

/// Thread names with digits folded (`surface-N-host`), counted; Linux only.
fn thread_names(pid: u32) -> String {
    let mut counts = std::collections::BTreeMap::<String, usize>::new();
    for task in fs::read_dir(format!("/proc/{pid}/task")).into_iter().flatten().flatten() {
        let name = fs::read_to_string(task.path().join("comm")).unwrap_or_default();
        let folded: String = name
            .trim()
            .chars()
            .map(|c| if c.is_ascii_digit() { 'N' } else { c })
            .collect::<String>()
            .replace("NN", "N");
        *counts.entry(folded).or_default() += 1;
    }
    counts.iter().map(|(name, count)| format!("{count} {name}")).collect::<Vec<_>>().join(", ")
}

/// Threads that belong to terminals and connections: shared-executor
/// workers (`serial-lanes`) follow the work in flight and exit 10 s after
/// it, so they are left out on Linux, where names are readable. Elsewhere
/// the count waits them out. Short-lived helpers (the cell-pixel fanout
/// pool exits 250 ms after its last job) are left out by taking the fewest
/// seen over the window.
fn settled_thread_count(pid: u32) -> usize {
    #[cfg(target_os = "linux")]
    let (window, count) = (Duration::from_secs(1), || {
        fs::read_dir(format!("/proc/{pid}/task"))
            .into_iter()
            .flatten()
            .flatten()
            .filter(|task| {
                fs::read_to_string(task.path().join("comm"))
                    .is_ok_and(|name| name.trim() != "serial-lanes")
            })
            .count()
    });
    #[cfg(not(target_os = "linux"))]
    let (window, count) = (Duration::from_secs(11), || thread_count(pid));
    let deadline = Instant::now() + window;
    let mut fewest = count();
    while Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(50));
        fewest = fewest.min(count());
    }
    fewest
}

fn surfaces(socket: &Path) -> Vec<u64> {
    let tree = request(socket, serde_json::json!({"id": 2, "cmd": "list-workspaces"}));
    tree["workspaces"]
        .as_array()
        .into_iter()
        .flatten()
        .flat_map(|workspace| workspace["screens"].as_array().into_iter().flatten())
        .flat_map(|screen| screen["panes"].as_array().into_iter().flatten())
        .flat_map(|pane| pane["tabs"].as_array().into_iter().flatten())
        .filter_map(|tab| tab["surface"].as_u64())
        .collect()
}

/// A stream like the app's (an attach or the event subscription): the
/// reply, then every later line, with base64 output decoded into the text.
struct Attach {
    writer: Box<dyn transport::Stream>,
    lines: std::sync::mpsc::Receiver<String>,
}

fn attach(socket: &Path, surface: u64) -> Attach {
    open_stream(
        socket,
        serde_json::json!({"id": 4, "cmd": "attach-surface", "surface": surface, "cols": 80, "rows": 24}),
    )
}

fn open_stream(socket: &Path, body: serde_json::Value) -> Attach {
    use base64::Engine as _;

    let stream = transport::connect(socket).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    writeln!(writer, "{body}").unwrap();
    let (tx, lines) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let mut reader = BufReader::new(stream);
        let mut line = String::new();
        while reader.read_line(&mut line).map(|n| n > 0).unwrap_or(false) {
            let mut text = std::mem::take(&mut line);
            if let Ok(event) = serde_json::from_str::<serde_json::Value>(&text)
                && let Some(data) = event["data"].as_str()
                && let Ok(bytes) = base64::engine::general_purpose::STANDARD.decode(data)
            {
                text.push_str(&String::from_utf8_lossy(&bytes));
            }
            if tx.send(text).is_err() {
                return;
            }
        }
    });
    Attach { writer, lines }
}

impl Attach {
    /// Waits until a line of the stream contains `needle`.
    fn wait_for(&self, needle: &str, timeout: Duration) -> bool {
        let deadline = Instant::now() + timeout;
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            match self.lines.recv_timeout(left) {
                Ok(line) if line.contains(needle) => return true,
                Ok(_) => {}
                Err(_) => return false,
            }
        }
    }
}

#[test]
fn cmux_next_daemon_threads_do_not_grow_per_terminal() {
    let daemon = Daemon::start("flat");
    let pid = daemon.child.id();
    // The first terminal starts the daemon's shared workers (host reaper,
    // serial lanes, journal); measure growth from there.
    request(
        &daemon.socket,
        serde_json::json!({"id": 1, "cmd": "run", "argv": ["/bin/cat"], "new_workspace": true, "name": "t0"}),
    );
    let first = surfaces(&daemon.socket);
    assert_eq!(first.len(), 1, "{first:?}");
    let first_attach = attach(&daemon.socket, first[0]);
    assert!(
        first_attach.wait_for("\"ok\":true", test_timeout(Duration::from_secs(10))),
        "attach to the first terminal failed"
    );
    // The app's event subscription.
    let events = open_stream(&daemon.socket, serde_json::json!({"id": 3, "cmd": "subscribe"}));
    let _ = events.wait_for("\"ok\":true", test_timeout(Duration::from_secs(10)));
    let baseline = settled_thread_count(pid);

    for index in 1..TERMINALS {
        request(
            &daemon.socket,
            serde_json::json!({
                "id": 10 + index,
                "cmd": "run",
                "argv": ["/bin/cat"],
                "new_workspace": true,
                "name": format!("t{index}"),
            }),
        );
    }
    let all = surfaces(&daemon.socket);
    assert_eq!(all.len(), TERMINALS, "{all:?}");
    let unattached = settled_thread_count(pid);
    let names_unattached = thread_names(pid);
    let mut attaches = Vec::new();
    for surface in &all[1..] {
        attaches.push((*surface, attach(&daemon.socket, *surface)));
    }
    // Every terminal still renders: type a marker into each and see it
    // echoed back on its attach stream.
    for (surface, stream) in &mut attaches {
        let marker = format!("perf100-marker-{surface}");
        let payload = serde_json::json!({
            "id": 40,
            "cmd": "send",
            "surface": *surface,
            "text": format!("{marker}\n"),
        });
        request(&daemon.socket, payload);
        assert!(
            stream.wait_for(&marker, test_timeout(Duration::from_secs(10))),
            "terminal {surface} did not render {marker}"
        );
        let _ = &stream.writer;
    }

    let hosts = daemon.host_pids();
    assert_eq!(hosts.len(), TERMINALS, "one terminal host per terminal: {hosts:?}");
    let loaded = settled_thread_count(pid);
    let per_terminal = (unattached as f64 - baseline as f64) / (TERMINALS - 1) as f64;
    let per_attach = (loaded as f64 - unattached as f64) / (TERMINALS - 1) as f64;
    let _ = writeln!(
        std::io::stderr(),
        "daemon threads: {baseline} with one attached terminal, {unattached} with {TERMINALS} \
         ({per_terminal:.2} per terminal), {loaded} with all attached ({per_attach:.2} per attach)\n\
         unattached: {names_unattached}\nattached: {}",
        thread_names(pid)
    );
    assert!(
        per_terminal <= MAX_THREADS_PER_TERMINAL,
        "daemon threads grew by {per_terminal:.2} per terminal ({baseline} -> {unattached}); budget {MAX_THREADS_PER_TERMINAL}"
    );
    assert!(
        per_attach <= MAX_THREADS_PER_ATTACH,
        "daemon threads grew by {per_attach:.2} per attach stream ({unattached} -> {loaded}); budget {MAX_THREADS_PER_ATTACH}"
    );

    // End every terminal: each host exits and the daemon reaps it.
    drop(attaches);
    drop(first_attach);
    drop(events);
    let tree = request(&daemon.socket, serde_json::json!({"id": 90, "cmd": "list-workspaces"}));
    for workspace in tree["workspaces"].as_array().into_iter().flatten() {
        request(
            &daemon.socket,
            serde_json::json!({
                "id": 91,
                "cmd": "close-workspace",
                "key": workspace["key"],
                "end_terminals": true,
            }),
        );
    }
    let deadline = Instant::now() + test_timeout(Duration::from_secs(20));
    loop {
        let left: Vec<u32> = hosts.iter().copied().filter(|pid| process_exists(*pid)).collect();
        if left.is_empty() {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "terminal hosts not reaped (still present or zombies): {left:?}"
        );
        std::thread::sleep(Duration::from_millis(25));
    }
    let deadline = Instant::now() + test_timeout(Duration::from_secs(20));
    loop {
        let now = thread_count(pid);
        if now as f64 <= baseline as f64 + MAX_THREADS_PER_TERMINAL {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "daemon threads did not return after the terminals ended: {now} (baseline {baseline})"
        );
        std::thread::sleep(Duration::from_millis(50));
    }
}
