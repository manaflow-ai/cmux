//! `terminal-resources` on a real headless daemon: each terminal reports its
//! shell, the shell's descendants, and the `__terminal-host` that owns the
//! PTY, read from the operating system when the request arrives.
#![cfg(unix)]

use std::collections::HashSet;
use std::fs;
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
            .join(format!("cmux-resources-{name}-{}-{stamp}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let socket = dir.join("mux.sock");
        let state = dir.join("state");
        let child = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
            .args(["--headless", "--socket"])
            .arg(&socket)
            .arg("--state")
            .arg(&state)
            .env("CMUX_TUI_CONFIG", dir.join("config.json"))
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
        let hosts = self.host_pids();
        let tree = try_request(&self.socket, &serde_json::json!({"cmd": "list-workspaces"}));
        for workspace in
            tree.iter().flat_map(|tree| tree["data"]["workspaces"].as_array()).flatten()
        {
            let _ = try_request(
                &self.socket,
                &serde_json::json!({
                    "cmd": "close-workspace",
                    "key": workspace["key"],
                    "end_terminals": true,
                }),
            );
        }
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

/// One request on a fresh connection; the whole response, or `None` when the
/// daemon cannot be reached. Never panics, so teardown can use it.
fn try_request(path: &Path, value: &serde_json::Value) -> Option<serde_json::Value> {
    let stream = transport::connect(path).ok()?;
    let mut writer = stream.try_clone_box().ok()?;
    let mut reader = BufReader::new(stream);
    writeln!(writer, "{value}").ok()?;
    let mut line = String::new();
    reader.read_line(&mut line).ok()?;
    serde_json::from_str(&line).ok()
}

fn request(path: &Path, value: serde_json::Value) -> Option<serde_json::Value> {
    let response = try_request(path, &value)?;
    assert_eq!(response["ok"], true, "{value} failed: {response}");
    Some(response["data"].clone())
}

fn sleep_children(terminal: &serde_json::Value) -> Vec<serde_json::Value> {
    terminal["processes"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|process| process["name"] == "sleep")
        .cloned()
        .collect()
}

#[test]
fn cmux_next_terminal_resources_reports_shell_and_children() {
    let daemon = Daemon::start("tree");
    let identify = request(&daemon.socket, serde_json::json!({"cmd": "identify"})).unwrap();
    assert!(
        identify["capabilities"]
            .as_array()
            .is_some_and(|caps| caps.iter().any(|cap| cap == "terminal-resources-v1")),
        "identify lacks terminal-resources-v1: {identify}"
    );

    let created = request(
        &daemon.socket,
        serde_json::json!({
            "cmd": "run",
            "argv": ["/bin/sh", "-c", "sleep 60 & sleep 60 & wait"],
            "new_workspace": true,
            "name": "resources",
        }),
    )
    .expect("run the process tree");
    let surface = created["surface"].as_u64().expect("run returns the surface");
    let unknown = surface + 100_000;

    // The two background sleeps start shortly after the shell.
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    let (data, terminal) = loop {
        let data = request(
            &daemon.socket,
            serde_json::json!({"cmd": "terminal-resources", "surfaces": [surface, unknown]}),
        )
        .unwrap();
        let terminal = data["terminals"][0].clone();
        if sleep_children(&terminal).len() == 2 {
            break (data, terminal);
        }
        assert!(Instant::now() < deadline, "the sleeps never appeared: {data}");
        std::thread::sleep(Duration::from_millis(50));
    };

    assert!(data["sampled_at_ns"].as_u64().is_some_and(|ns| ns > 0), "{data}");
    assert_eq!(data["missing"], serde_json::json!([unknown]), "{data}");
    assert_eq!(data["terminals"].as_array().map(Vec::len), Some(1), "{data}");
    assert_eq!(terminal["surface"], surface);
    assert_eq!(terminal["terminal_id"], created["terminal_id"], "{terminal}");
    assert_eq!(terminal["truncated"], false);

    let shell = terminal["pid"].as_u64().expect("shell pid");
    let processes = terminal["processes"].as_array().unwrap();
    assert_eq!(processes[0]["pid"], shell, "the shell is listed first: {terminal}");
    let mut seen = HashSet::new();
    for process in processes {
        let pid = process["pid"].as_u64().unwrap();
        assert!(seen.insert(pid), "pid {pid} listed twice: {terminal}");
        assert!(process["ppid"].is_u64(), "{process}");
        assert!(process["name"].as_str().is_some_and(|name| !name.is_empty()), "{process}");
        assert!(process["cpu_ns"].is_u64(), "{process}");
        assert!(process["memory_bytes"].as_u64().is_some_and(|bytes| bytes > 0), "{process}");
    }
    for sleep in sleep_children(&terminal) {
        assert_eq!(sleep["ppid"], shell, "each sleep is a child of the shell: {terminal}");
    }

    // The shell runs under its terminal host, not under the daemon.
    let hosts = daemon.host_pids();
    assert_eq!(hosts.len(), 1, "one terminal host record: {hosts:?}");
    let host = &terminal["host"];
    assert_eq!(host["pid"], hosts[0], "host: {terminal}");
    assert_eq!(processes[0]["ppid"], hosts[0], "the shell's parent is its host: {terminal}");
    assert_ne!(host["pid"], daemon.child.id());
    assert!(host["cpu_ns"].is_u64(), "{host}");
    assert!(host["memory_bytes"].as_u64().is_some_and(|bytes| bytes > 0), "{host}");

    // Without `surfaces`, every PTY surface is reported and nothing is missing.
    let all = request(&daemon.socket, serde_json::json!({"cmd": "terminal-resources"})).unwrap();
    assert_eq!(all["missing"], serde_json::json!([]), "{all}");
    let surfaces: Vec<u64> = all["terminals"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|terminal| terminal["surface"].as_u64())
        .collect();
    assert!(surfaces.contains(&surface), "{all}");
    assert!(all["sampled_at_ns"].as_u64() >= data["sampled_at_ns"].as_u64(), "{all}");
}

/// A terminal host runs in its own session with the open-file limit the
/// daemon started with, and inherits nothing from the daemon: every daemon
/// descriptor above stdio is close-on-exec (hosts start with posix_spawn,
/// which keeps each descriptor that is not), and no host descriptor names a
/// daemon file (registry database, daemon state outside the host records).
#[test]
fn cmux_next_terminal_host_owns_its_session_limit_and_descriptors() {
    let daemon = Daemon::start("spawn");
    let created = request(
        &daemon.socket,
        serde_json::json!({
            "cmd": "run",
            "argv": ["/bin/sh", "-c", "sleep 60"],
            "new_workspace": true,
            "name": "spawn",
        }),
    )
    .expect("run a terminal");
    assert!(created["terminal_id"].is_string(), "{created}");
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    let host = loop {
        if let [host] = daemon.host_pids()[..] {
            break host;
        }
        assert!(Instant::now() < deadline, "no terminal host record");
        std::thread::sleep(Duration::from_millis(25));
    };
    let daemon_pid = daemon.child.id();
    // SAFETY: getsid takes a pid and no pointers.
    let (host_session, daemon_session) =
        unsafe { (libc::getsid(host as libc::pid_t), libc::getsid(daemon_pid as libc::pid_t)) };
    assert_eq!(host_session, host as libc::pid_t, "the host leads its own session");
    assert_ne!(host_session, daemon_session, "the host left the daemon's session");

    #[cfg(target_os = "linux")]
    {
        let mut ours = libc::rlimit { rlim_cur: 0, rlim_max: 0 };
        // SAFETY: `ours` is valid writable storage for one rlimit.
        assert_eq!(unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &raw mut ours) }, 0);
        let limits = fs::read_to_string(format!("/proc/{host}/limits")).unwrap();
        let soft = limits
            .lines()
            .find(|line| line.starts_with("Max open files"))
            .and_then(|line| line.split_whitespace().nth(3))
            .and_then(|soft| soft.parse::<u64>().ok())
            .unwrap_or_else(|| panic!("no open-file limit for host {host}: {limits}"));
        assert_eq!(soft, ours.rlim_cur, "the host has the limit the daemon started with");

        let fds = |pid: u32| {
            fs::read_dir(format!("/proc/{pid}/fd"))
                .unwrap()
                .filter_map(Result::ok)
                .filter_map(|entry| entry.file_name().to_str()?.parse::<u32>().ok())
                .filter(|fd| *fd > 2)
                .collect::<Vec<_>>()
        };
        // Descriptors this test process lets children inherit (a runner's
        // pipe, a jobserver) reach the daemon by inheritance; the daemon
        // did not open them. Every descriptor the daemon opens must be
        // close-on-exec.
        let inherited = fds(std::process::id())
            .into_iter()
            .filter(|fd| {
                fs::read_to_string(format!("/proc/self/fdinfo/{fd}")).is_ok_and(|info| {
                    info.lines()
                        .find_map(|line| line.strip_prefix("flags:"))
                        .and_then(|flags| u64::from_str_radix(flags.trim(), 8).ok())
                        .is_some_and(|flags| flags & libc::O_CLOEXEC as u64 == 0)
                })
            })
            .collect::<HashSet<_>>();
        for fd in fds(daemon_pid).into_iter().filter(|fd| !inherited.contains(fd)) {
            let Ok(info) = fs::read_to_string(format!("/proc/{daemon_pid}/fdinfo/{fd}")) else {
                continue; // closed meanwhile
            };
            let flags = info
                .lines()
                .find_map(|line| line.strip_prefix("flags:"))
                .and_then(|flags| u64::from_str_radix(flags.trim(), 8).ok())
                .unwrap_or_else(|| panic!("no flags for daemon fd {fd}: {info}"));
            let target = fs::read_link(format!("/proc/{daemon_pid}/fd/{fd}")).unwrap_or_default();
            assert_ne!(
                flags & libc::O_CLOEXEC as u64,
                0,
                "daemon fd {fd} ({}) is not close-on-exec; a spawned host would inherit it",
                target.display()
            );
        }
        let state = fs::canonicalize(&daemon.state).unwrap_or_else(|_| daemon.state.clone());
        for fd in fds(host) {
            let Ok(target) = fs::read_link(format!("/proc/{host}/fd/{fd}")) else { continue };
            let text = target.to_string_lossy();
            let database =
                text.contains("sqlite") || text.ends_with("-wal") || text.ends_with("-shm");
            let daemon_state = target.starts_with(&state) && !text.contains("terminal-hosts");
            assert!(
                !database && !daemon_state,
                "host fd {fd} names a daemon file: {}",
                target.display()
            );
        }
    }
}

/// A standby terminal host (started ahead of a terminal, waiting on its
/// bootstrap pipe) exits when its daemon dies: no other process holds the
/// write end of that pipe.
#[cfg(target_os = "linux")]
#[test]
fn cmux_next_standby_terminal_host_exits_with_its_daemon() {
    let mut daemon = Daemon::start("standby");
    request(
        &daemon.socket,
        serde_json::json!({
            "cmd": "run",
            "argv": ["/bin/sh", "-c", "sleep 60"],
            "new_workspace": true,
            "name": "standby",
        }),
    )
    .expect("run a terminal");
    // The first new tab makes the daemon keep a spare host (R81).
    request(&daemon.socket, serde_json::json!({"cmd": "new-tab", "cols": 80, "rows": 24}))
        .expect("open a new tab");
    let daemon_pid = daemon.child.id();
    let children = |parent: u32| {
        fs::read_dir("/proc")
            .unwrap()
            .filter_map(Result::ok)
            .filter_map(|entry| entry.file_name().to_str()?.parse::<u32>().ok())
            .filter(|pid| {
                fs::read_to_string(format!("/proc/{pid}/stat")).is_ok_and(|stat| {
                    stat.rsplit_once(") ")
                        .and_then(|(_, rest)| rest.split_whitespace().nth(1))
                        .is_some_and(|ppid| ppid == parent.to_string())
                })
            })
            .filter(|pid| {
                fs::read(format!("/proc/{pid}/cmdline")).is_ok_and(|cmdline| {
                    cmdline.split(|b| *b == 0).any(|arg| arg == b"--bootstrap-stdio")
                })
            })
            .collect::<Vec<_>>()
    };
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    let standby = loop {
        let hosts = daemon.host_pids();
        let spare =
            children(daemon_pid).into_iter().filter(|pid| !hosts.contains(pid)).collect::<Vec<_>>();
        if !spare.is_empty() {
            break spare;
        }
        assert!(Instant::now() < deadline, "the daemon started no standby host");
        std::thread::sleep(Duration::from_millis(25));
    };
    daemon.child.kill().unwrap();
    daemon.child.wait().unwrap();
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    while standby.iter().any(|pid| process_exists(*pid)) {
        assert!(
            Instant::now() < deadline,
            "standby hosts {standby:?} outlived their daemon: another process holds their bootstrap pipe"
        );
        std::thread::sleep(Duration::from_millis(25));
    }
}
