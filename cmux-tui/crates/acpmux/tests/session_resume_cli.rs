//! `acpmux session resume NAME`: an agent or a script resumes the prompts a failed turn held,
//! without the person. Held queues sat silent until someone pressed Resume in the app
//! (coord-deputy held 121 agent messages after one "agent process closed", 2026-10-21).
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt};

struct Rpc {
    lines: tokio::io::Lines<tokio::io::BufReader<tokio::net::unix::OwnedReadHalf>>,
    wr: tokio::net::unix::OwnedWriteHalf,
    next: i64,
}

impl Rpc {
    async fn connect(path: &Path) -> Self {
        let s = tokio::net::UnixStream::connect(path).await.expect("connect to daemon socket");
        let (rd, wr) = s.into_split();
        let mut rpc = Self { lines: tokio::io::BufReader::new(rd).lines(), wr, next: 0 };
        let hello = json!({"protocolVersion": 1, "clientInfo": {"name": "session-resume-cli"}});
        rpc.call("initialize", hello).await;
        rpc
    }

    /// Sends a request without waiting for its answer (a prompt answers when its turn ends).
    async fn send(&mut self, method: &str, params: Value) {
        self.next += 1;
        let line = json!({"jsonrpc": "2.0", "id": self.next, "method": method, "params": params});
        self.wr.write_all(format!("{line}\n").as_bytes()).await.expect("send");
    }

    async fn next_line(&mut self) -> Value {
        let line = tokio::time::timeout(Duration::from_secs(30), self.lines.next_line())
            .await
            .expect("daemon answered in time")
            .expect("read")
            .expect("daemon closed the socket");
        serde_json::from_str(&line).expect("json line")
    }

    async fn call(&mut self, method: &str, params: Value) -> Value {
        self.send(method, params).await;
        let id = self.next;
        loop {
            let v = self.next_line().await;
            if v.get("id") == Some(&json!(id)) {
                assert!(v.get("error").is_none(), "{method} failed: {v}");
                return v["result"].clone();
            }
        }
    }

    /// Waits for a notification `method` whose params match.
    async fn wait_for(&mut self, method: &str, matches: impl Fn(&Value) -> bool) {
        loop {
            let v = self.next_line().await;
            if v["method"] == method && matches(&v["params"]) {
                return;
            }
        }
    }
}

/// A daemon in its own home, with the test agent as harness `fake`; killed on drop.
struct Daemon {
    home: PathBuf,
    socket: PathBuf,
    child: std::process::Child,
}

impl Daemon {
    async fn start(tag: &str) -> Self {
        // Short, under /tmp: the socket path must stay under the macOS limit.
        let home = PathBuf::from("/tmp").join(format!("amx-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        std::fs::create_dir_all(&home).expect("home");
        let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
        let config = json!({"harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake", "permissionPolicy": "approve-all"});
        std::fs::write(home.join("config.json"), config.to_string()).expect("config");
        let socket = home.join("s.sock");
        let child = daemon_env::command(&home, daemon_env::Agents::StandIn, &[])
            .args(["daemon", "run", "--log", "warn"])
            .env("ACPMUX_HOME", &home)
            .env("ACPMUX_SOCKET", &socket)
            // No agent hosts: a host outlives its daemon, and this test kills only the daemon.
            .env("ACPMUX_AGENT_HOSTS", "0")
            .env("ACPMUX_LOGIN_ENV", "0")
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .expect("spawn daemon");
        let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
        while tokio::net::UnixStream::connect(&socket).await.is_err() {
            assert!(tokio::time::Instant::now() < deadline, "daemon {tag} never listened");
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        Self { home, socket, child }
    }

    /// Runs `acpmux --json session resume <session>` as an agent would (no person proof).
    async fn resume(&self, session: &str) -> (bool, Value, String) {
        let out = daemon_env::tokio_command(&self.home, daemon_env::Agents::Deny)
            .args(["--json", "session", "resume", session])
            .env("ACPMUX_HOME", &self.home)
            .env("ACPMUX_SOCKET", &self.socket)
            .output()
            .await
            .expect("run acpmux session resume");
        let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
        let stderr = String::from_utf8_lossy(&out.stderr).into_owned();
        let v = serde_json::from_str(stdout.trim()).unwrap_or(Value::Null);
        (out.status.success(), v, format!("{stdout}{stderr}"))
    }
}

impl Daemon {
    /// Runs `acpmux --json retry <session>` as an agent would.
    async fn retry(&self, session: &str) -> (bool, Value, String) {
        let out = daemon_env::tokio_command(&self.home, daemon_env::Agents::Deny)
            .args(["--json", "retry", session])
            .env("ACPMUX_HOME", &self.home)
            .env("ACPMUX_SOCKET", &self.socket)
            .output()
            .await
            .expect("run acpmux retry");
        let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
        let stderr = String::from_utf8_lossy(&out.stderr).into_owned();
        let v = serde_json::from_str(stdout.trim()).unwrap_or(Value::Null);
        (out.status.success(), v, format!("{stdout}{stderr}"))
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = std::fs::remove_dir_all(&self.home);
    }
}

fn text_prompt(id: &str, prompt_id: &str, text: &str) -> Value {
    json!({"sessionId": id, "prompt": [{"type": "text", "text": text}], "_meta": {"acpmux": {"promptId": prompt_id}}})
}

/// Polls `_acpmux/info` until `done` holds, for at most 15 s.
async fn info_until(rpc: &mut Rpc, id: &str, done: impl Fn(&Value) -> bool) -> Value {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(15);
    loop {
        let info = rpc.call("_acpmux/info", json!({"sessionId": id})).await;
        if done(&info) {
            return info;
        }
        assert!(tokio::time::Instant::now() < deadline, "never settled: {info}");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

#[tokio::test]
async fn session_resume_runs_the_prompts_a_failed_turn_held() {
    let daemon = Daemon::start("rsm").await;
    let mut rpc = Rpc::connect(&daemon.socket).await;
    let made = rpc.call("session/new", json!({"cwd": daemon.home, "mcpServers": []})).await;
    let id = made["sessionId"].as_str().expect("session id").to_owned();

    // Nothing is held yet: resume says so and changes nothing.
    let (ok, v, out) = daemon.resume(&id).await;
    assert!(ok, "{out}");
    assert_eq!(v["resumed"], false, "{out}");

    // A turn runs; behind it a prompt that fails, and one more.
    rpc.send("session/prompt", text_prompt(&id, "p-turn", "until-cancel")).await;
    rpc.wait_for("session/update", |p| p["update"]["content"]["text"] == "running").await;
    for (prompt_id, text) in [("p-f", "fail-streamed: boom"), ("p-a", "a")] {
        rpc.send("session/prompt", text_prompt(&id, prompt_id, text)).await;
        rpc.wait_for("_acpmux/prompt_accepted", |p| {
            p["promptId"] == prompt_id && p["queued"] == true
        })
        .await;
    }
    rpc.send("session/cancel", json!({"sessionId": id})).await;
    let held = info_until(&mut rpc, &id, |i| i["queuePaused"] == true && i["turn"].is_null()).await;
    assert_eq!(held["queue"][0]["promptId"], "p-a", "{held}");
    assert_eq!(held["queue"][0]["held"], true, "{held}");

    // An agent resumes it from the CLI: the held prompt runs.
    let (ok, v, out) = daemon.resume(&id).await;
    assert!(ok, "{out}");
    assert_eq!(v["resumed"], true, "{out}");
    assert_eq!(v["sessionId"], id.as_str(), "{out}");
    rpc.wait_for("session/update", |p| p["update"]["content"]["text"] == "echo: a").await;
    let after = info_until(&mut rpc, &id, |i| i["queuePaused"] == false).await;
    assert_eq!(after["queuePaused"], false, "{after}");
}

/// `acpmux retry NAME`: the failed last turn goes again in the same session, as its next attempt
/// (`hub/auto_resume/retry_turn.rs`); once it ran, nothing is left to retry.
#[tokio::test]
async fn retry_sends_a_failed_turn_again_from_the_cli() {
    let daemon = Daemon::start("rty").await;
    let mut rpc = Rpc::connect(&daemon.socket).await;
    let made = rpc.call("session/new", json!({"cwd": daemon.home, "mcpServers": []})).await;
    let id = made["sessionId"].as_str().expect("session id").to_owned();
    let (ok, _, out) = daemon.retry(&id).await;
    assert!(!ok && out.contains("retry.nothing_failed"), "{out}");

    rpc.send("session/prompt", text_prompt(&id, "p-f", "fail-once: again")).await;
    info_until(&mut rpc, &id, |i| i["lastTurn"]["status"] == "failed").await;
    let (ok, v, out) = daemon.retry(&id).await;
    assert!(ok, "{out}");
    assert_eq!(v["promptId"], "p-f~resume-1", "{out}");
    assert_eq!(v["kind"], "turn", "{out}");
    rpc.wait_for("session/update", |p| p["update"]["content"]["text"] == "echo: again").await;
    info_until(&mut rpc, &id, |i| i["lastTurn"]["status"] == "completed").await;
    let (ok, _, out) = daemon.retry(&id).await;
    assert!(!ok && out.contains("retry.nothing_failed"), "{out}");
}
