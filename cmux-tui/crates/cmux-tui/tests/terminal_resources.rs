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
