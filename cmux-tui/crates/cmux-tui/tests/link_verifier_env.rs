//! G3 and G4 of the link-token go-live gates (cloud-client-contract.md 1.7)
//! on a real headless daemon started with `CMUX_LINK_TOKEN_VERIFIER` set:
//! the daemon logs its verifier mode once, and no child (the terminal host
//! and the terminal's process) inherits the variable.
#![cfg(unix)]

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_tui_core::platform::transport;

const VARIABLE: &str = "CMUX_LINK_TOKEN_VERIFIER";

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
    dir: PathBuf,
}

impl Daemon {
    fn start(name: &str, verifier: &str) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir =
            PathBuf::from("/tmp").join(format!("cmux-lve-{name}-{}-{stamp}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let socket = dir.join("mux.sock");
        let stderr = fs::File::create(dir.join("stderr.log")).unwrap();
        let child = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
            .args(["--headless", "--socket"])
            .arg(&socket)
            .arg("--state")
            .arg(dir.join("state"))
            .env("CMUX_TUI_CONFIG", dir.join("config.json"))
            .env(VARIABLE, verifier)
            .stdout(Stdio::null())
            .stderr(stderr)
            .spawn()
            .unwrap();
        let deadline = Instant::now() + test_timeout(Duration::from_secs(15));
        while transport::connect(&socket).is_err() {
            assert!(Instant::now() < deadline, "daemon did not create {}", socket.display());
            std::thread::sleep(Duration::from_millis(25));
        }
        Self { child, socket, dir }
    }

    fn stderr(&self) -> String {
        fs::read_to_string(self.dir.join("stderr.log")).unwrap_or_default()
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let tree = request(&self.socket, &serde_json::json!({"cmd": "list-workspaces"}));
        for workspace in
            tree.iter().flat_map(|tree| tree["data"]["workspaces"].as_array()).flatten()
        {
            let _ = request(
                &self.socket,
                &serde_json::json!({
                    "cmd": "close-workspace",
                    "key": workspace["key"],
                    "end_terminals": true,
                }),
            );
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = fs::remove_dir_all(&self.dir);
    }
}

fn request(path: &Path, value: &serde_json::Value) -> Option<serde_json::Value> {
    let stream = transport::connect(path).ok()?;
    let mut writer = stream.try_clone_box().ok()?;
    let mut reader = BufReader::new(stream);
    writeln!(writer, "{value}").ok()?;
    let mut line = String::new();
    reader.read_line(&mut line).ok()?;
    serde_json::from_str(&line).ok()
}

/// The `cmux link: token verifier mode` lines, once the first one is there.
fn mode_lines(daemon: &Daemon) -> Vec<String> {
    let read = || -> Vec<String> {
        daemon
            .stderr()
            .lines()
            .filter(|line| line.starts_with("cmux link: token verifier mode "))
            .map(str::to_string)
            .collect()
    };
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    while read().is_empty() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(25));
    }
    read()
}

/// RED (G4): a terminal's process and its terminal host never see the
/// variable the daemon was started with. The daemon removes it from its own
/// environment before any thread starts, so every spawn path is covered.
#[test]
fn no_terminal_or_terminal_host_inherits_the_verifier_variable() {
    let daemon = Daemon::start("child", "control_plane");
    let out = daemon.dir.join("env.out");
    let script = format!("env > {0}.tmp; mv {0}.tmp {0}; sleep 30", out.display());
    let created = request(
        &daemon.socket,
        &serde_json::json!({
            "cmd": "run",
            "argv": ["/bin/sh", "-c", script],
            "new_workspace": true,
            "name": "verifier-env",
        }),
    )
    .expect("the daemon answers run");
    assert_eq!(created["ok"], true, "{created}");
    let deadline = Instant::now() + test_timeout(Duration::from_secs(15));
    let env = loop {
        if let Ok(env) = fs::read_to_string(&out) {
            break env;
        }
        assert!(Instant::now() < deadline, "the terminal never wrote {}", out.display());
        std::thread::sleep(Duration::from_millis(25));
    };
    assert!(env.contains("PATH="), "the terminal env looks empty: {env}");
    assert!(!env.contains(VARIABLE), "the terminal inherited {VARIABLE}:\n{env}");
    // The terminal host's own environment (Linux: its initial environ).
    #[cfg(target_os = "linux")]
    {
        let surface = created["data"]["surface"].as_u64().expect("run returns the surface");
        let resources = request(
            &daemon.socket,
            &serde_json::json!({"cmd": "terminal-resources", "surfaces": [surface]}),
        )
        .unwrap();
        let host = resources["data"]["terminals"][0]["host"]["pid"].as_u64().expect("host pid");
        let environ = fs::read(format!("/proc/{host}/environ")).unwrap();
        let environ = String::from_utf8_lossy(&environ);
        assert!(environ.contains("PATH="), "the host environ looks empty");
        assert!(!environ.contains(VARIABLE), "the terminal host inherited {VARIABLE}");
    }
}

/// RED (G3): the daemon logs its verifier mode exactly once at start, with
/// the reason and never the raw value.
#[test]
fn the_daemon_logs_its_verifier_mode_once_without_the_value() {
    let daemon = Daemon::start("log", "hunter2-not-a-mode");
    // Another request after start: the line stays single.
    let _ = request(&daemon.socket, &serde_json::json!({"cmd": "identify"}));
    let lines = mode_lines(&daemon);
    assert_eq!(lines.len(), 1, "stderr:\n{}", daemon.stderr());
    assert!(lines[0].contains("mode deny_all"), "{}", lines[0]);
    assert!(lines[0].contains("unrecognized value"), "{}", lines[0]);
    assert!(!daemon.stderr().contains("hunter2"), "the raw value was logged");
    drop(daemon);
    let control = Daemon::start("logcp", "control_plane");
    let lines = mode_lines(&control);
    assert_eq!(lines.len(), 1, "stderr:\n{}", control.stderr());
    assert!(lines[0].contains("mode control_plane: refused at start"), "{}", lines[0]);
}
