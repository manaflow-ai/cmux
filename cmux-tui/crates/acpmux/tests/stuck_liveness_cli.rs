//! The public CLI reads the same stuck liveness fields as the daemon list.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use serde_json::{Value, json};
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output, Stdio};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt};

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

struct Rpc {
    lines: tokio::io::Lines<tokio::io::BufReader<tokio::net::unix::OwnedReadHalf>>,
    wr: tokio::net::unix::OwnedWriteHalf,
    next: i64,
}

impl Rpc {
    async fn connect(path: &Path) -> Self {
        let stream = tokio::net::UnixStream::connect(path).await.expect("connect daemon");
        let (rd, wr) = stream.into_split();
        let mut rpc = Self { lines: tokio::io::BufReader::new(rd).lines(), wr, next: 0 };
        rpc.call("initialize", json!({"protocolVersion": 1, "clientInfo": {"name": "stuck-cli"}}))
            .await
            .unwrap();
        rpc
    }

    async fn call(&mut self, method: &str, params: Value) -> Result<Value, Value> {
        self.next += 1;
        let id = self.next;
        let line = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        self.wr.write_all(format!("{line}\n").as_bytes()).await.expect("write rpc");
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.lines.next_line())
                .await
                .expect("rpc timeout")
                .expect("rpc read")
                .expect("daemon closed");
            let value: Value = serde_json::from_str(&line).expect("rpc json");
            if value["id"] == id {
                return if value["error"].is_object() {
                    Err(value["error"].clone())
                } else {
                    Ok(value["result"].clone())
                };
            }
        }
    }
}

struct Daemon {
    root: PathBuf,
    child: Option<Child>,
}

impl Daemon {
    fn start() -> Self {
        let root = std::env::temp_dir().join(format!("stuck-cli-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        for dir in ["home", "amx", "work"] {
            std::fs::create_dir_all(root.join(dir)).unwrap();
        }
        let root = std::fs::canonicalize(&root).unwrap();
        std::fs::write(
            root.join("amx/config.json"),
            json!({
                "harnesses": {"fake": {"argv": ["python3", FAKE]}},
                "defaultHarness": "fake",
                "permissionPolicy": "approve-all",
                "autoResumeDelaysMs": [20, 20, 60_000]
            })
            .to_string(),
        )
        .unwrap();
        let mut child = Self { root, child: None };
        let mut process = child.command();
        let mut running = process
            .args(["daemon", "run", "--memory", "--ready-fd", "1", "--log", "warn"])
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .expect("spawn daemon");
        let mut ready = BufReader::new(running.stdout.take().unwrap());
        let mut line = String::new();
        loop {
            line.clear();
            assert!(ready.read_line(&mut line).unwrap() > 0, "daemon exited before ready");
            if line.contains("\"ready\":true") {
                break;
            }
        }
        child.child = Some(running);
        child
    }

    fn command(&self) -> Command {
        let mut command = daemon_env::command(&self.root, daemon_env::Agents::StandIn, &[]);
        command
            .current_dir(self.root.join("work"))
            .env("ACPMUX_HOME", self.root.join("amx"))
            .env("ACPMUX_SOCKET", self.root.join("s.sock"))
            .env("ACPMUX_LOGIN_ENV", "0")
            .env("ACPMUX_REGISTRY_FETCH", "0")
            .env("ACPMUX_HEALTH_FETCH", "0")
            .env("ACPMUX_PROBE_HARNESSES", "fake")
            .env_remove("ACPMUX_SESSION_ID")
            .stdin(Stdio::null());
        command
    }

    fn run(&self, args: &[&str]) -> Output {
        self.command().args(args).output().expect("run acpmux")
    }

    fn json(&self, args: &[&str]) -> Value {
        let output = self.run(args);
        assert!(output.status.success(), "{}: {}", args.join(" "), text(&output));
        serde_json::from_slice(&output.stdout).unwrap_or_else(|e| panic!("{e}: {}", text(&output)))
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = self.run(&["daemon", "shutdown", "--end-agents"]);
            let _ = child.kill();
            let _ = child.wait();
        }
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

fn text(output: &Output) -> String {
    format!(
        "{} {}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    )
}

#[tokio::test]
async fn ls_and_session_info_report_stuck_then_clear_after_success() {
    let daemon = Daemon::start();
    let mut rpc = Rpc::connect(&daemon.root.join("s.sock")).await;
    let created = rpc
        .call("session/new", json!({"cwd": daemon.root.join("work"), "mcpServers": []}))
        .await
        .unwrap();
    let id = created["sessionId"].as_str().unwrap().to_owned();
    let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": "cap-fail-three: build it"}], "_meta": {"acpmux": {"promptId": "p-stuck-cli"}}});
    assert!(rpc.call("session/prompt", prompt).await.is_err());

    let mut stuck = Value::Null;
    for _ in 0..400 {
        let list = daemon.json(&["--json", "ls"]);
        let Some(entry) = list["sessions"]
            .as_array()
            .and_then(|rows| rows.iter().find(|row| row["sessionId"] == id))
        else {
            continue;
        };
        if entry["state"] == "stuck" {
            stuck = entry.clone();
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert_eq!(stuck["state"], "stuck", "{stuck}");
    assert_eq!(stuck["stuckReason"], "harness_unavailable", "{stuck}");
    assert!(stuck["stuckSince"].as_u64().is_some(), "{stuck}");
    assert!(stuck["stuckError"].as_str().is_some(), "{stuck}");

    let daemon_status = daemon.json(&["--json", "daemon", "status"]);
    let status_row = daemon_status["stuckSessions"]
        .as_array()
        .and_then(|rows| rows.iter().find(|row| row["sessionId"] == id))
        .unwrap_or_else(|| panic!("daemon status omitted stuck session: {daemon_status}"));
    assert_eq!(status_row["state"], "stuck", "{daemon_status}");
    assert_eq!(status_row["stuckReason"], "harness_unavailable", "{daemon_status}");

    let info = daemon.json(&["--json", "session", "info", &id]);
    assert_eq!(info["state"], "stuck", "{info}");
    assert_eq!(info["stuckReason"], "harness_unavailable", "{info}");
    assert_eq!(info["stuckSince"], stuck["stuckSince"], "{info}");

    assert!(
        rpc.call(
            "session/prompt",
            json!({"sessionId": id, "prompt": [{"type": "text", "text": "recovered"}]})
        )
        .await
        .is_ok()
    );
    let recovered = daemon.json(&["--json", "session", "info", &id]);
    assert_ne!(recovered["state"], "stuck", "{recovered}");
    assert!(recovered["stuckReason"].is_null(), "{recovered}");
    assert!(recovered["stuckSince"].is_null(), "{recovered}");
    assert!(recovered["stuckError"].is_null(), "{recovered}");
    let daemon_status = daemon.json(&["--json", "daemon", "status"]);
    assert!(
        daemon_status["stuckSessions"].as_array().is_some_and(Vec::is_empty),
        "{daemon_status}"
    );
}
