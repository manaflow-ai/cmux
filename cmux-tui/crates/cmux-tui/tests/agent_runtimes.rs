//! `agent.runtime.list` on a real headless daemon (RFC #20149 phase 1): an
//! agent started in a cmux terminal is verified to that terminal, the same
//! agent started outside cmux is unattributed, and arguments come back
//! redacted.
#![cfg(any(target_os = "linux", target_os = "macos"))]

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_tui_core::platform::transport;
use serde_json::{Value, json};

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
    fn start() -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir =
            PathBuf::from("/tmp").join(format!("cmux-runtimes-{}-{stamp}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let socket = dir.join("mux.sock");
        let child = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
            .args(["--headless", "--socket"])
            .arg(&socket)
            .arg("--state")
            .arg(dir.join("state"))
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
        Self { child, socket, dir }
    }

    fn line(&self, request: &Value) -> BufReader<Box<dyn transport::Stream>> {
        let stream = transport::connect(&self.socket).unwrap();
        let mut writer = stream.try_clone_box().unwrap();
        writeln!(writer, "{request}").unwrap();
        BufReader::new(stream)
    }

    fn raw(&self, request: Value) -> Value {
        let mut line = String::new();
        self.line(&request).read_line(&mut line).unwrap();
        let reply: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(reply["ok"], true, "{request} failed: {reply}");
        reply["data"].clone()
    }

    fn runtimes(&self) -> Value {
        let request = json!({"protocol": "cmux.protocol/2", "type": "request", "id": "1",
                             "operation": "agent.runtime.list",
                             "params": {"machine": "current", "session": "current"}});
        let mut reader = self.line(&request);
        let mut line = String::new();
        loop {
            line.clear();
            assert!(reader.read_line(&mut line).unwrap() > 0, "connection closed");
            let reply: Value = serde_json::from_str(line.trim()).unwrap();
            if reply["id"] == "1" {
                assert_eq!(reply["ok"], true, "{reply}");
                return reply["result"].clone();
            }
        }
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        // End the terminal (and its host) before the daemon goes.
        let mut line = String::new();
        let request = json!({"cmd": "list-workspaces"});
        if self.line(&request).read_line(&mut line).is_ok()
            && let Ok(reply) = serde_json::from_str::<Value>(&line)
        {
            for workspace in reply["data"]["workspaces"].as_array().into_iter().flatten() {
                let close = json!({"cmd": "close-workspace", "key": workspace["key"],
                                   "end_terminals": true});
                let _ = self.line(&close).read_line(&mut String::new());
            }
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = fs::remove_dir_all(&self.dir);
    }
}

fn runtime_with_pid(inventory: &Value, pid: u64) -> Option<Value> {
    inventory["runtimes"].as_array()?.iter().find(|runtime| runtime["pid"] == pid).cloned()
}

#[test]
fn cmux_next_agent_runtimes_attribute_a_terminal_agent_and_not_an_outside_one() {
    let daemon = Daemon::start();
    // A stand-in agent: `sleep` under the name the Codex adapter knows.
    let codex = daemon.dir.join("codex");
    fs::copy("/bin/sleep", &codex).unwrap();

    let created = daemon.raw(json!({
        "cmd": "run",
        "argv": ["/bin/sh", "-c", format!("{} 60; :", codex.display())],
        "new_workspace": true,
        "name": "runtimes",
    }));
    assert!(created["surface"].is_u64(), "{created}");
    let mut outside = Command::new(&codex).arg("60").spawn().unwrap();
    // macOS reports /tmp as /private/tmp, so match the unique directory.
    let own = format!("{}/codex", daemon.dir.file_name().unwrap().to_string_lossy());

    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    let (inventory, inside) = loop {
        let inventory = daemon.runtimes();
        // The host may run real agents too; only this test's copy counts.
        let inside = inventory["runtimes"].as_array().into_iter().flatten().find(|runtime| {
            runtime["pid"] != u64::from(outside.id())
                && runtime["executable_path"].as_str().is_some_and(|path| path.ends_with(&own))
        });
        if let Some(inside) = inside.cloned()
            && runtime_with_pid(&inventory, u64::from(outside.id())).is_some()
        {
            break (inventory, inside);
        }
        assert!(Instant::now() < deadline, "the stand-in agents never appeared: {inventory}");
        std::thread::sleep(Duration::from_millis(50));
    };

    assert!(inventory["session_id"].as_str().is_some_and(|id| id.starts_with("session_")));
    assert!(inventory["scanned_processes"].as_u64().is_some_and(|count| count > 0));
    assert_eq!(inside["role"], "cli", "{inside}");
    assert_eq!(inside["attribution"]["status"], "verified", "{inside}");
    assert_eq!(inside["attribution"]["source"], "terminal_process_tree", "{inside}");
    let terminal = inside["attribution"]["terminal_id"].as_str().unwrap_or_default();
    assert!(terminal.starts_with("term_"), "{inside}");
    assert_eq!(inside["args"], json!(["codex", "<redacted>"]), "{inside}");
    assert_eq!(inside["can_stop_safely"], false);
    assert!(
        inside["id"]
            .as_str()
            .is_some_and(|id| id.starts_with(&format!("local:{}:", inside["pid"]))),
        "{inside}"
    );

    let outside_runtime = runtime_with_pid(&inventory, u64::from(outside.id())).unwrap();
    assert_eq!(outside_runtime["attribution"]["status"], "unattributed", "{outside_runtime}");
    assert_eq!(outside_runtime["attribution"]["terminal_id"], Value::Null);

    let _ = outside.kill();
    let _ = outside.wait();
}
