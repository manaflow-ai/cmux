//! The build-session kill switch (cx-9ettq), through the real daemon binary
//! and its unix socket: with `ACPMUX_AGENT_LAUNCH=deny` or
//! `CMUX_AGENTS_DISABLED=1`, `session/new` fails with the launch-disabled
//! error, model probes and prewarms start nothing, and no harness process
//! ever runs (the harness command writes a marker file before anything else,
//! and the daemon's own records show no session, live agent or agent host).
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

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
    /// Written by any start of the `fake` harness.
    marker: PathBuf,
    /// Written by any start of the `other` harness.
    other_marker: PathBuf,
}

/// A harness command that appends to `marker` before it runs the fake agent.
fn marked_argv(marker: &Path) -> Value {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    json!([
        "/bin/sh",
        "-c",
        "echo started >>\"$1\"; shift; exec python3 \"$@\"",
        "sh",
        marker,
        fake
    ])
}

impl Daemon {
    /// The daemon with `switch` set (none: launches allowed), once ready.
    /// `memory`: no store on disk, so no agent hosts (they outlive the daemon).
    async fn start(tag: &str, switch: Option<(&str, &str)>, memory: bool) -> Self {
        let dir = scratch(tag);
        let marker = dir.join("harness-started");
        let other_marker = dir.join("other-started");
        // Any start of a harness (a session or a model probe) leaves its marker.
        let harnesses = json!({
            "fake": {"argv": marked_argv(&marker)},
            "other": {"argv": marked_argv(&other_marker)},
        });
        std::fs::write(
            dir.join("config.json"),
            json!({"harnesses": harnesses, "defaultHarness": "fake", "permissionPolicy": "approve-all"})
                .to_string(),
        )
        .unwrap();
        let socket = dir.join("s.sock");
        // Launches allowed unless `switch` turns them off; the bare PATH holds
        // no real agent either way.
        let mut cmd = daemon_env::command(&dir, daemon_env::Agents::StandIn, &[]);
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
            .env("ACPMUX_PROBE_HARNESSES", "fake");
        if let Some((key, value)) = switch {
            cmd.env(key, value);
        }
        let mut child = cmd
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
        Self { child, dir, socket, marker, other_marker }
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
    assert!(!daemon.other_marker.exists(), "the other harness started");
    daemon.stop().await;
}

/// `ACPMUX_AGENT_LAUNCH=only:fake` (a perf bench's replay agent): a session,
/// prewarm or probe that names another harness is refused as under `deny`
/// and that harness never runs; the listed harness starts.
#[tokio::test]
async fn an_only_list_starts_the_named_harness_alone() {
    let daemon = Daemon::start("only", Some(("ACPMUX_AGENT_LAUNCH", "only:fake")), false).await;
    let dir = &daemon.dir;
    let mut rpc = Rpc::connect(&daemon.socket).await;
    assert_eq!(rpc.call("_acpmux/status", json!({})).await["agentLaunch"], "only");

    let reply = rpc
        .send(
            "session/new",
            json!({"cwd": dir, "mcpServers": [], "_meta": {"acpmux": {"name": "o", "harness": "other"}}}),
        )
        .await;
    assert_eq!(reply["error"]["code"], -32010, "{reply}");
    assert_eq!(reply["error"]["data"]["reason"], "agent_launch_disabled", "{reply}");
    let prewarm =
        rpc.call("_acpmux/prewarm", json!({"harness": "other", "cwd": dir, "wait": true})).await;
    assert_eq!(prewarm["accepted"], false, "{prewarm}");
    rpc.call("_acpmux/models", json!({"refresh": true})).await;
    assert!(!daemon.other_marker.exists(), "the other harness started");

    // The listed harness (the default here) starts.
    rpc.call(
        "session/new",
        json!({"cwd": dir, "mcpServers": [], "_meta": {"acpmux": {"name": "f", "harness": "fake"}}}),
    )
    .await;
    assert!(daemon.marker.exists(), "the listed harness never started");
    assert!(!daemon.other_marker.exists(), "the other harness started");
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
