//! The build-session kill switch (cx-9ettq), through the real daemon binary
//! and its unix socket: with `ACPMUX_AGENT_LAUNCH=deny` or
//! `CMUX_AGENTS_DISABLED=1`, `session/new` fails with the launch-disabled
//! error, model probes and prewarms start nothing, and no harness process
//! ever runs (the harness command writes a marker file before anything else,
//! and the daemon's own records show no session, live agent or agent host).
#![cfg(unix)]

use serde_json::{Value, json};
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};
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
        Self { lines: tokio::io::BufReader::new(rd).lines(), wr, next: 0 }
    }

    /// The whole response: `result` or `error`.
    async fn send(&mut self, method: &str, params: Value) -> Value {
        self.next += 1;
        let id = self.next;
        let line = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        self.wr.write_all(format!("{line}\n").as_bytes()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(90), self.lines.next_line())
                .await
                .expect("daemon answered in time")
                .unwrap()
                .expect("daemon closed the socket");
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return v;
            }
        }
    }

    async fn call(&mut self, method: &str, params: Value) -> Value {
        let v = self.send(method, params).await;
        assert!(v.get("error").is_none(), "{method} failed: {v}");
        v["result"].clone()
    }
}

fn scratch(tag: &str) -> PathBuf {
    // Short: the socket path must stay under the macOS limit.
    let dir = std::env::temp_dir().join(format!("amx-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

struct Daemon {
    child: std::process::Child,
    dir: PathBuf,
    socket: PathBuf,
    marker: PathBuf,
}

impl Daemon {
    /// The daemon with `switch` set (none: launches allowed), once ready.
    /// `memory`: no store on disk, so no agent hosts (they outlive the daemon).
    async fn start(tag: &str, switch: Option<(&str, &str)>, memory: bool) -> Self {
        let dir = scratch(tag);
        let marker = dir.join("harness-started");
        let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
        // Any start of the harness (a session or a model probe) leaves the marker.
        let argv = json!([
            "/bin/sh",
            "-c",
            "echo started >>\"$1\"; shift; exec python3 \"$@\"",
            "sh",
            marker,
            fake
        ]);
        std::fs::write(
        dir.join("config.json"),
        json!({"harnesses": {"fake": {"argv": argv}}, "defaultHarness": "fake", "permissionPolicy": "approve-all"}).to_string(),
    )
    .unwrap();
        let socket = dir.join("s.sock");
        let mut cmd = std::process::Command::new(env!("CARGO_BIN_EXE_acpmux"));
        cmd.args(["daemon", "run", "--ready-fd", "1", "--log", "warn"]);
        if memory {
            cmd.arg("--memory");
        }
        cmd.env("ACPMUX_HOME", &dir)
            .env("ACPMUX_SOCKET", &socket)
            .env("ACPMUX_LOGIN_ENV", "0")
            // No network fetches from a test daemon.
            .env("ACPMUX_REGISTRY_FETCH", "0")
            .env("ACPMUX_HEALTH_FETCH", "0")
            // Only the fake harness: never the developer's own claude or codex
            // from PATH or ~/.acpmux, with their credentials.
            .env("ACPMUX_PROBE_HARNESSES", "fake")
            .env("HOME", &dir)
            .env_remove("ACPMUX_AGENT_LAUNCH")
            .env_remove("CMUX_AGENTS_DISABLED");
        if let Some((key, value)) = switch {
            cmd.env(key, value);
        }
        let mut child = cmd
            .env_remove("XPC_SERVICE_NAME")
            .env_remove("CLAUDECODE")
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null())
            .spawn()
            .unwrap();
        let stdout = child.stdout.take().unwrap();
        let ready = tokio::task::spawn_blocking(move || {
            for line in BufReader::new(stdout).lines() {
                let line = line.unwrap();
                if serde_json::from_str::<Value>(&line).is_ok_and(|v| v["ready"] == true) {
                    return;
                }
            }
            panic!("daemon exited without a readiness line");
        });
        tokio::time::timeout(Duration::from_secs(20), ready).await.unwrap().unwrap();
        Self { child, dir, socket, marker }
    }

    async fn stop(mut self) {
        unsafe {
            libc::kill(self.child.id() as i32, libc::SIGTERM);
        }
        let stop = Instant::now();
        while self.child.try_wait().unwrap().is_none() {
            assert!(stop.elapsed() < Duration::from_secs(8), "daemon still running after SIGTERM");
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

/// Starts the daemon with `switch` set and a store on disk (agent hosts on,
/// as in the app), runs every check, and stops it.
async fn denied_daemon_starts_no_agent(tag: &str, switch: (&str, &str)) {
    let daemon = Daemon::start(tag, Some(switch), false).await;
    let (dir, marker) = (&daemon.dir, &daemon.marker);
    let mut rpc = Rpc::connect(&daemon.socket).await;
    assert_eq!(rpc.call("_acpmux/status", json!({})).await["agentLaunch"], "deny");

    // session/new: the launch-disabled error, not retryable.
    let reply = rpc
        .send(
            "session/new",
            json!({"cwd": dir, "mcpServers": [], "_meta": {"acpmux": {"name": "denied"}}}),
        )
        .await;
    let error = &reply["error"];
    assert_eq!(error["message"], "agent launch is disabled in this build session", "{reply}");
    assert_eq!(error["code"], -32010, "{reply}");
    assert_eq!(error["data"]["reason"], "agent_launch_disabled", "{reply}");
    assert_eq!(error["data"]["retryable"], false, "{reply}");

    // A refreshed model list waits for every probe; a probe would start the harness.
    rpc.call("_acpmux/models", json!({"refresh": true})).await;
    // A prewarm hint is refused, never queued.
    let prewarm =
        rpc.call("_acpmux/prewarm", json!({"harness": "fake", "cwd": dir, "wait": true})).await;
    assert_eq!(prewarm["accepted"], false, "{prewarm}");
    assert_eq!(prewarm["reason"], "agent launch is disabled in this build session", "{prewarm}");

    // The daemon's own records: no session, no live agent, no agent host.
    let status = rpc.call("_acpmux/status", json!({})).await;
    assert_eq!(status["sessions"], 0, "{status}");
    assert_eq!(status["liveAgents"], 0, "{status}");
    let hosts: Vec<_> = std::fs::read_dir(dir.join("hosts"))
        .map(|d| d.filter_map(Result::ok).map(|e| e.file_name()).collect())
        .unwrap_or_default();
    assert!(hosts.is_empty(), "agent host records: {hosts:?}");
    // And the harness command never ran at all.
    assert!(!marker.exists(), "the harness started: {:?}", std::fs::read_to_string(marker));
    daemon.stop().await;
}

/// The control: the same daemon and harness without the switch starts the
/// harness (the marker appears), so the checks above can fail.
#[tokio::test]
async fn without_the_switch_the_harness_starts() {
    let daemon = Daemon::start("allow", None, true).await;
    let mut rpc = Rpc::connect(&daemon.socket).await;
    assert_eq!(rpc.call("_acpmux/status", json!({})).await["agentLaunch"], "allow");
    rpc.call(
        "session/new",
        json!({"cwd": daemon.dir, "mcpServers": [], "_meta": {"acpmux": {"name": "allowed"}}}),
    )
    .await;
    assert!(daemon.marker.exists(), "the harness never started");
    daemon.stop().await;
}

#[tokio::test]
async fn agent_launch_deny_starts_no_agent() {
    denied_daemon_starts_no_agent("deny", ("ACPMUX_AGENT_LAUNCH", "deny")).await;
}

#[tokio::test]
async fn cmux_agents_disabled_starts_no_agent() {
    denied_daemon_starts_no_agent("off", ("CMUX_AGENTS_DISABLED", "1")).await;
}
