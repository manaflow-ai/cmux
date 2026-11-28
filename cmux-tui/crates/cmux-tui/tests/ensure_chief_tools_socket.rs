//! `server ensure` started with CMUX_TUI_CHIEF_TOOLS_SOCKET starts an owner
//! that reaches the Chief brain (2026-10-09 live check: the app starts its
//! Chief owner through `server ensure` with the variable set, but the
//! client takes it out of its own environment at start, so the owner it
//! spawned answered every chief.engine.get with not_configured).
//! A real owner process; a fake brain tools socket answers one line.

#![cfg(unix)]

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::process::Command;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

struct Fixture {
    dir: PathBuf,
    socket: PathBuf,
    session: String,
}

impl Fixture {
    fn new() -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir = PathBuf::from("/tmp").join(format!("cmux-ct-{}-{stamp}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
        Self { socket: dir.join("mux.sock"), session: "ensure-chief-tools".into(), dir }
    }

    fn command(&self, action: &str) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
        command
            .args(["server", action, "--json", "--session", &self.session, "--socket"])
            .arg(&self.socket)
            .env("CMUX_TUI_STATE_DIR", self.dir.join("state"))
            .env("CMUX_TUI_CONFIG", self.dir.join("config.json"));
        command
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = self.command("stop").output();
        let _ = fs::remove_dir_all(&self.dir);
    }
}

/// A brain tools socket that answers each engine line with `report`.
fn fake_brain(path: PathBuf, report: Value) {
    let listener = UnixListener::bind(&path).unwrap();
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let mut line = String::new();
            let mut reader = BufReader::new(&stream);
            if reader.read_line(&mut line).is_ok() {
                let _ = (&stream).write_all(format!("{report}\n").as_bytes());
            }
        }
    });
}

#[test]
fn an_owner_ensured_with_the_tools_socket_answers_chief_engine_get() {
    let fixture = Fixture::new();
    let tools = fixture.dir.join("tools.sock");
    let report = json!({"engine": {"harness": "codex", "model": "gpt-6-sol", "effort": "medium"},
                        "choice": {"harness": "codex"}, "last_turn": null, "recent": []});
    fake_brain(tools.clone(), report);
    let ensured =
        fixture.command("ensure").env("CMUX_TUI_CHIEF_TOOLS_SOCKET", &tools).output().unwrap();
    assert!(ensured.status.success(), "{}", String::from_utf8_lossy(&ensured.stderr));

    let stream = UnixStream::connect(&fixture.socket).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(12))).unwrap();
    let mut reader = BufReader::new(stream);
    let request = json!({"protocol": "cmux.protocol/2", "type": "request", "id": "1",
                         "operation": "chief.engine.get",
                         "params": {"machine": "current", "session": "current"}});
    writeln!(reader.get_mut(), "{request}").unwrap();
    let mut line = String::new();
    while reader.read_line(&mut line).unwrap() > 0 {
        let reply: Value = serde_json::from_str(line.trim()).unwrap();
        if reply["id"] == "1" {
            assert_eq!(reply["result"]["engine"]["harness"], "codex", "{reply}");
            return;
        }
        line.clear();
    }
    panic!("the owner closed the connection without answering");
}
