//! A workspace move while the app's New Workspace is still creating the
//! first terminal (cx-95uaf), over a real daemon socket. The app creates a
//! workspace, then its first terminal with a reserved terminal id
//! (`create-terminal` with `terminal_id`, the receipted path), and places
//! the listed workspace with `move-workspace` while that create runs. The
//! created terminal is inserted before it is bound to a pane; the move
//! rebuilt the resource indexes from the placed tabs only and dropped the
//! unplaced terminal's tab identity. The terminal was then placed with no
//! durable identity, its create failed ("tab slot N has no durable
//! identity"), and every later projection (close-workspace too) failed the
//! same way. The daemon holds that one create in the window
//! (`CMUX_TUI_TEST_CREATE_BIND_GATE`, debug builds) until the move is done.

#![cfg(unix)]

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

fn temp_dir(name: &str) -> PathBuf {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    PathBuf::from("/tmp").join(format!("cmux-{name}-{}-{stamp}", std::process::id()))
}

/// A headless daemon on its own socket and state folder.
struct Daemon {
    child: Child,
    socket: PathBuf,
    dir: PathBuf,
}

impl Daemon {
    fn start(env: &[(&str, &str)]) -> Self {
        let dir = temp_dir("new-ws-identity");
        fs::create_dir_all(&dir).unwrap();
        let socket = dir.join("mux.sock");
        let child = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
            .args(["--headless", "--socket"])
            .arg(&socket)
            .arg("--state")
            .arg(dir.join("state"))
            .env("CMUX_TUI_CONFIG", dir.join("config.json"))
            .env_remove("SSH_CONNECTION")
            .env_remove("SSH_CLIENT")
            .env_remove("SSH_TTY")
            .envs(env.iter().copied())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(15);
        while UnixStream::connect(&socket).is_err() {
            assert!(Instant::now() < deadline, "daemon did not create {}", socket.display());
            std::thread::sleep(Duration::from_millis(25));
        }
        Self { child, socket, dir }
    }

    /// `cmux --json <args>` against this daemon; its JSON result.
    fn cli(&self, args: &[&str]) -> Value {
        let output = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
            .arg("--json")
            .arg("--socket")
            .arg(&self.socket)
            .args(args)
            .env("LC_ALL", "C")
            .env_remove("CMUX_TUI_SOCKET")
            .env_remove("CMUX_TUI_TERMINAL_ID")
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "cmux {args:?} failed: {}{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        serde_json::from_slice(&output.stdout).unwrap()
    }

    fn workspace_id_named(&self, name: &str) -> String {
        self.cli(&["workspace", "list"])
            .as_array()
            .unwrap()
            .iter()
            .find(|workspace| workspace["name"] == name)
            .and_then(|workspace| workspace["id"].as_str())
            .unwrap_or_else(|| panic!("no workspace named {name}"))
            .to_string()
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        // Terminal hosts outlive the daemon: the test closes its workspaces
        // (and their terminals) through the daemon first. This ends only the
        // daemon process the test started.
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = fs::remove_dir_all(&self.dir);
    }
}

fn send_checked(socket: &Path, request: Value) -> Option<Value> {
    let stream = UnixStream::connect(socket).ok()?;
    stream.set_read_timeout(Some(Duration::from_secs(30))).ok()?;
    let mut writer = stream.try_clone().ok()?;
    let mut reader = BufReader::new(stream);
    writeln!(writer, "{request}").ok()?;
    let mut line = String::new();
    reader.read_line(&mut line).ok()?;
    serde_json::from_str(&line).ok()
}

/// One raw request on a new connection (one client); the whole response.
fn send(socket: &Path, request: Value) -> Value {
    send_checked(socket, request.clone()).unwrap_or_else(|| panic!("no answer to {request}"))
}

fn ok(daemon: &Daemon, request: Value) -> Value {
    let response = send(&daemon.socket, request.clone());
    assert_eq!(response["ok"], true, "{request} failed: {response}");
    response["data"].clone()
}
fn uuid(seed: u64) -> String {
    format!("00000000-0000-4000-8000-{seed:012x}")
}

/// What the app sends for New Workspace, named `ws<seed>`: `create-workspace`
/// with its key.
fn app_create_workspace(socket: &Path, seed: u64) -> String {
    let key = uuid(seed);
    let created = send(
        socket,
        json!({"id": 1, "cmd": "create-workspace", "key": key, "name": format!("ws{seed}"),
               "origin": "user", "mutation_id": uuid(seed + 100)}),
    );
    assert_eq!(created["ok"], true, "create-workspace {key} failed: {created}");
    key
}

/// Then its first terminal, with a reserved id, a mutation id and the
/// placement environment; the terminal's response.
fn app_create_terminal(socket: &Path, seed: u64) -> Value {
    let key = uuid(seed);
    // Unique per test process: terminal hosts outlive a failed run.
    let terminal_id = format!("{:08x}00004000800{seed:013x}", std::process::id());
    send(
        socket,
        json!({"id": 2, "cmd": "create-terminal", "key": key, "argv": ["/bin/cat"],
               "terminal_id": terminal_id, "origin": "user", "mutation_id": uuid(seed + 200),
               "env": {"CMUX_WORKSPACE_ID": key, "CMUX_SURFACE_ID": terminal_id}}),
    )
}

fn app_new_workspace(daemon: &Daemon, seed: u64) -> String {
    let key = app_create_workspace(&daemon.socket, seed);
    let terminal = app_create_terminal(&daemon.socket, seed);
    assert_eq!(terminal["ok"], true, "create in ws{seed} failed: {terminal}");
    key
}

fn rename(daemon: &Daemon, workspace: &str, name: &str) {
    daemon.cli(&["workspace", workspace, "rename", name]);
}

#[test]
fn a_workspace_move_during_new_workspace_keeps_tab_identity_and_closes_cleanly() {
    let gate = temp_dir("create-bind-gate");
    fs::create_dir_all(&gate).unwrap();
    let gated = uuid(2);
    let daemon = Daemon::start(&[
        ("CMUX_TUI_TEST_CREATE_BIND_GATE", gate.to_str().unwrap()),
        ("CMUX_TUI_TEST_CREATE_BIND_GATE_KEY", gated.as_str()),
    ]);
    // The action-parity sequence: rename the current workspace, New
    // Workspace, rename the new (current) one, New Workspace again.
    let launch = app_new_workspace(&daemon, 0);
    rename(&daemon, &daemon.workspace_id_named("ws0"), "alpha");
    let first = app_new_workspace(&daemon, 1);
    rename(&daemon, &daemon.workspace_id_named("ws1"), "beta");

    let second = app_create_workspace(&daemon.socket, 2);
    let socket = daemon.socket.clone();
    let create = std::thread::spawn(move || app_create_terminal(&socket, 2));
    let deadline = Instant::now() + Duration::from_secs(10);
    while !gate.join("entered").exists() {
        assert!(Instant::now() < deadline, "the create never reached its binding");
        std::thread::sleep(Duration::from_millis(10));
    }
    // The app places the listed workspace while its first terminal is
    // still being created.
    ok(&daemon, json!({"id": 3, "cmd": "move-workspace", "key": first, "index": 0}));
    fs::write(gate.join("release"), b"").unwrap();
    let terminal = create.join().unwrap();
    assert_eq!(terminal["ok"], true, "create-terminal after the move failed: {terminal}");

    // No slot was left without identity: a later create and every close
    // still commit.
    let third = app_new_workspace(&daemon, 3);
    for key in [&launch, &first, &second, &third] {
        ok(&daemon, json!({"id": 9, "cmd": "close-workspace", "key": key}));
    }
    let _ = fs::remove_dir_all(&gate);
}
