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
                std::thread::spawn(move || serve(stream));
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

fn serve(stream: UnixStream) {
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
            json!({"id": request["id"], "ok": true, "data": {
                "app": "cmux-tui",
                "protocol": 12,
                "version": "0.1.0",
                "build_commit": OLD_COMMIT,
                "pid": std::process::id(),
                "session": "main",
                "generation": "e5b73f7f-d219-4800-a38d-524708c86447",
                "lifecycle_ready": true,
                "capabilities": ["workspace-registry-v1", "session-journal-v1"]
            }})
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
