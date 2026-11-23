//! A CLI newer than the session's daemon (cmux-ad i3): the daemon of an older
//! build does not know an operation the CLI sends and refuses its envelope as
//! "invalid request envelope". The CLI must say instead which daemon it met,
//! that it is older than this cmux, and the command that upgrades it while
//! every terminal is kept (`cmux daemon restart`). It must never print the
//! daemon's bare envelope refusal.
//!
//! The fake daemon answers as the VM daemon of 2026-10-25 does (cmux 0.1.0,
//! main 316d139f): `identify` with its build, every raw command with `ok`,
//! and every `cmux.protocol/2` request with the envelope refusal of that build.
//! A stale CLI that meets a NEWER daemon must not offer the restart: from
//! the stale CLI it would downgrade the daemon.

#![cfg(unix)]

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

const OLD_COMMIT: &str = "316d139feaf89d9ab7c99dc9cffdce59309bef93";

struct OldDaemon {
    dir: PathBuf,
    socket: PathBuf,
}

impl OldDaemon {
    fn start(name: &str) -> Self {
        Self::start_as(name, None)
    }

    /// A daemon that reports `build_time` (a build newer than any CLI when
    /// it is far in the future); `None` reports none, as 316d139f does.
    fn start_as(name: &str, build_time: Option<u64>) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir =
            PathBuf::from("/tmp").join(format!("cmux-old-{name}-{}-{stamp}", std::process::id()));
        fs::create_dir_all(dir.join("home")).unwrap();
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
        let socket = dir.join("old.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(stream) = stream else { return };
                std::thread::spawn(move || serve(stream, build_time));
            }
        });
        Self { dir, socket }
    }

    fn cli(&self, args: &[&str]) -> Output {
        Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
            .arg("--socket")
            .arg(&self.socket)
            .args(args)
            .env("HOME", self.dir.join("home"))
            .env("CFFIXED_USER_HOME", self.dir.join("home"))
            .env("XDG_RUNTIME_DIR", &self.dir)
            .env("CMUX_TUI_STATE_DIR", self.dir.join("state"))
            .env_remove("CMUX_TUI_SOCKET")
            .env_remove("CMUX_TUI_TERMINAL_ID")
            .env_remove("CMUX_TUI_SESSION")
            .env_remove("ACPMUX_SESSION_ID")
            .output()
            .unwrap()
    }
}

impl Drop for OldDaemon {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.dir);
    }
}

fn serve(stream: UnixStream, build_time: Option<u64>) {
    let mut writer = stream.try_clone().unwrap();
    for line in BufReader::new(stream).lines() {
        let Ok(line) = line else { return };
        let Ok(request) = serde_json::from_str::<Value>(&line) else { return };
        let reply = if request.get("protocol").is_some() {
            json!({
                "protocol": "cmux.protocol/2",
                "type": "response",
                "id": request["id"],
                "ok": false,
                "error": {
                    "code": "validation.invalid",
                    "message": "invalid request envelope",
                    "details": {"reason": "invalid request envelope"},
                    "retryable": false
                }
            })
        } else if request["cmd"] == "identify" {
            let mut reply = json!({"id": request["id"], "ok": true, "data": {
                "app": "cmux-tui",
                "protocol": 12,
                "version": "0.1.0",
                "build_commit": OLD_COMMIT,
                "pid": std::process::id(),
                "session": "main",
                "generation": "e5b73f7f-d219-4800-a38d-524708c86447",
                "lifecycle_ready": true,
                "capabilities": ["workspace-registry-v1", "session-journal-v1"]
            }});
            if let Some(time) = build_time {
                reply["data"]["build_time"] = json!(time);
            }
            reply
        } else {
            json!({"id": request["id"], "ok": true, "data": {}})
        };
        if writeln!(writer, "{reply}").and_then(|()| writer.flush()).is_err() {
            return;
        }
    }
}

fn text(output: &Output) -> String {
    format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    )
}

fn assert_names_the_older_daemon(output: &Output, operation: &str, socket: &Path) {
    let printed = text(output);
    assert!(!output.status.success(), "succeeded against an old daemon: {printed}");
    assert!(!printed.contains("invalid request envelope"), "bare envelope refusal: {printed}");
    assert!(
        printed.contains("daemon 0.1.0 (316d139f) is older than this cmux"),
        "no daemon version: {printed}"
    );
    assert!(printed.contains(operation), "no operation: {printed}");
    assert!(printed.contains("daemon restart"), "no restart fix: {printed}");
    assert!(printed.contains(&socket.display().to_string()), "fix names no socket: {printed}");
    assert!(printed.contains("terminals are kept"), "no promise to keep terminals: {printed}");
}

#[test]
fn daemon_upgrade_agent_message_names_the_older_daemon_and_the_restart() {
    let daemon = OldDaemon::start("message");
    let output = daemon.cli(&["agent", "message", "term_00000000000000000000000000000008", "hi"]);
    assert_names_the_older_daemon(&output, "agent.message.send", &daemon.socket);
}

#[test]
fn daemon_upgrade_json_request_to_an_older_daemon_reports_daemon_outdated() {
    let daemon = OldDaemon::start("json");
    let output = daemon.cli(&["--json", "workspace", "list"]);
    assert_names_the_older_daemon(&output, "workspace.list", &daemon.socket);
    let line = String::from_utf8_lossy(&output.stderr);
    let line = line.lines().rfind(|line| line.starts_with('{')).unwrap_or_default().to_owned();
    let error: Value = serde_json::from_str(&line).unwrap_or_else(|_| panic!("no JSON: {line}"));
    assert_eq!(error["code"], "daemon.outdated", "{error}");
    assert_eq!(error["details"]["daemon_build"], OLD_COMMIT, "{error}");
    assert_eq!(error["details"]["action"], "restart_daemon", "{error}");
}

#[test]
fn daemon_upgrade_a_newer_daemon_says_this_cli_is_stale_and_offers_no_restart() {
    // 2096-10-02: newer than the commit of any CLI under test.
    let daemon = OldDaemon::start_as("newer", Some(4_000_000_000));
    let output = daemon.cli(&["--json", "workspace", "list"]);
    let printed = text(&output);
    assert!(!output.status.success(), "succeeded against a refusing daemon: {printed}");
    assert!(!printed.contains("invalid request envelope"), "bare envelope refusal: {printed}");
    assert!(!printed.contains("daemon restart"), "restart from a stale CLI: {printed}");
    assert!(printed.contains("is newer than this cmux"), "no newer daemon: {printed}");
    let line = String::from_utf8_lossy(&output.stderr);
    let line = line.lines().rfind(|line| line.starts_with('{')).unwrap_or_default().to_owned();
    let error: Value = serde_json::from_str(&line).unwrap_or_else(|_| panic!("no JSON: {line}"));
    assert_eq!(error["code"], "cli.outdated", "{error}");
    assert_eq!(error["details"]["action"], "use_daemon_cli", "{error}");
}

#[test]
fn daemon_upgrade_an_mcp_tool_call_names_the_older_daemon_and_the_restart() {
    let daemon = OldDaemon::start("mcp");
    let config = daemon.dir.join("cmux-next.json");
    fs::write(&config, r#"{"mcp": {"enabled": true}}"#).unwrap();
    let mut child = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .arg("--socket")
        .arg(&daemon.socket)
        .args(["--app-socket", daemon.dir.join("no-app.sock").to_str().unwrap()])
        .args(["mcp", "serve"])
        .env("HOME", daemon.dir.join("home"))
        .env("CFFIXED_USER_HOME", daemon.dir.join("home"))
        .env("XDG_RUNTIME_DIR", &daemon.dir)
        .env("CMUX_NEXT_CONFIG_FILE", &config)
        .env("CMUX_TUI_STATE_DIR", daemon.dir.join("state"))
        .env_remove("CMUX_TUI_SOCKET")
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .env_remove("CMUX_TUI_SESSION")
        .env_remove("CMUX_MUX_SOCKET")
        .env_remove("CMUX_AGENT_SESSION")
        .env_remove("ACPMUX_SESSION_ID")
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    for message in [
        json!({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2025-06-18", "capabilities": {},
            "clientInfo": {"name": "older-daemon", "version": "1"}}}),
        json!({"jsonrpc": "2.0", "method": "notifications/initialized"}),
        json!({"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {
            "name": "workspace_list", "arguments": {}}}),
    ] {
        writeln!(stdin, "{message}").unwrap();
    }
    drop(stdin);
    let output = child.wait_with_output().unwrap();
    let stderr = String::from_utf8_lossy(&output.stderr).into_owned();
    let answer = String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter_map(|line| serde_json::from_str::<Value>(line).ok())
        .find(|message| message["id"] == 2)
        .unwrap_or_else(|| panic!("no tools/call answer; stderr: {stderr}"))
        .to_string();
    assert!(!answer.contains("invalid request envelope"), "bare envelope refusal: {answer}");
    assert!(answer.contains("daemon.outdated"), "no daemon.outdated: {answer}");
    assert!(answer.contains("is older than this cmux"), "no daemon version: {answer}");
    assert!(answer.contains("daemon restart"), "no restart fix: {answer}");
}
