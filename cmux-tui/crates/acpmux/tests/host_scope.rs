//! A restart of the daemon's systemd unit never ends its agent hosts
//! (cmuxterm-hq#3763). The daemon runs as a transient user service with the
//! default `KillMode=control-group`, the unit that ended every agent on
//! huge-blue; the hosts it starts move into their own scopes, so after
//! `systemctl --user restart` the same host and harness pids are alive and
//! the new daemon drives the session again. With `ACPMUX_HOST_SCOPES=0` the
//! same restart ends them, which shows the test can fail.
//!
//! Needs a user systemd manager (a Linux login with linger); without one
//! each test says so and passes.
#![cfg(target_os = "linux")]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/). It keeps
// the user manager's address, no credential: `systemctl --user` and
// `systemd-run --user` find the manager through it.
const HERMETIC: daemon_env::Process =
    daemon_env::Process::stand_in().keep(&["XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS"]);

use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt};

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

/// The user manager answers, and `busctl` and `systemd-run` are installed.
fn user_manager() -> bool {
    let state = Command::new("systemctl").args(["--user", "is-system-running"]).output();
    let running = state.is_ok_and(|o| {
        matches!(String::from_utf8_lossy(&o.stdout).trim(), "running" | "degraded")
    });
    running
        && Command::new("busctl").arg("--version").output().is_ok_and(|o| o.status.success())
        && Command::new("systemd-run").arg("--version").output().is_ok_and(|o| o.status.success())
}

fn scratch(tag: &str) -> PathBuf {
    // Short: socket paths must stay under the macOS limit.
    let home = std::env::temp_dir().join(format!("ahs-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    std::fs::create_dir_all(&home).unwrap();
    std::fs::write(
        home.join("config.json"),
        json!({
            "harnesses": {"fake": {"argv": ["python3", FAKE]}},
            "defaultHarness": "fake",
            "permissionPolicy": "approve-all",
        })
        .to_string(),
    )
    .unwrap();
    home
}

/// A transient user service running the daemon with the hermetic
/// environment; the unit keeps systemd's default `KillMode=control-group`.
struct Unit {
    name: String,
    home: PathBuf,
}

impl Unit {
    fn start(home: &Path, tag: &str, scopes: bool) -> Self {
        let name = format!("acpmux-host-scope-{tag}-{}.service", std::process::id());
        let daemon = daemon_env::command(home, daemon_env::Agents::StandIn, &[]);
        let mut run = Command::new("systemd-run");
        run.args(["--user", "--quiet", "--collect", "--unit", &name])
            .args(["--property", "KillMode=control-group", "--property", "TimeoutStopSec=30"]);
        let mut env: Vec<(String, String)> = daemon
            .get_envs()
            .filter_map(|(k, v)| Some((k.to_str()?.to_owned(), v?.to_str()?.to_owned())))
            .collect();
        env.extend([
            ("ACPMUX_HOME".into(), home.display().to_string()),
            ("ACPMUX_SOCKET".into(), home.join("s.sock").display().to_string()),
            ("ACPMUX_CATALOG_FETCH".into(), "0".into()),
            ("ACPMUX_LOGIN_ENV".into(), "0".into()),
        ]);
        if !scopes {
            env.push(("ACPMUX_HOST_SCOPES".into(), "0".into()));
        }
        for (k, v) in env {
            run.arg(format!("--setenv={k}={v}"));
        }
        run.arg("--").arg(daemon.get_program());
        run.args(["daemon", "run", "--listen", "127.0.0.1:0", "--log", "warn"]);
        let status = run.status().expect("systemd-run");
        assert!(status.success(), "systemd-run {name}: {status}");
        Self { name, home: home.to_owned() }
    }

    fn restart(&self) {
        let status = Command::new("systemctl")
            .args(["--user", "restart", &self.name])
            .status()
            .expect("systemctl restart");
        assert!(status.success(), "restart {}: {status}", self.name);
    }
}

impl Drop for Unit {
    fn drop(&mut self) {
        let _ = Command::new("systemctl").args(["--user", "stop", &self.name]).status();
        let _ = Command::new("systemctl").args(["--user", "reset-failed", &self.name]).status();
        // No daemon can adopt a host of a deleted home: the hosts end (cx-tumi).
        let _ = std::fs::remove_dir_all(&self.home);
    }
}

fn alive(pid: i64) -> bool {
    // SAFETY: signal 0 only checks that the process exists.
    unsafe { libc::kill(pid as i32, 0) == 0 }
}

fn gone_within(pid: i64, within: Duration) -> bool {
    let deadline = Instant::now() + within;
    while alive(pid) {
        if Instant::now() >= deadline {
            return false;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    true
}

fn pids(home: &Path, session: &str) -> (i64, i64) {
    let bytes = std::fs::read(home.join("hosts").join(format!("{session}.json"))).expect("record");
    let record: Value = serde_json::from_slice(&bytes).unwrap();
    (record["host_pid"].as_i64().unwrap(), record["harness_pid"].as_i64().unwrap())
}

fn cgroup(pid: i64) -> String {
    std::fs::read_to_string(format!("/proc/{pid}/cgroup")).unwrap_or_default()
}

struct Rpc {
    lines: tokio::io::Lines<tokio::io::BufReader<tokio::net::unix::OwnedReadHalf>>,
    wr: tokio::net::unix::OwnedWriteHalf,
    next: i64,
}

impl Rpc {
    /// Connects once the unit's daemon listens (test polling, bounded).
    async fn connect(home: &Path) -> Self {
        let deadline = Instant::now() + Duration::from_secs(30);
        let stream = loop {
            match tokio::net::UnixStream::connect(home.join("s.sock")).await {
                Ok(s) => break s,
                Err(e) => assert!(Instant::now() < deadline, "the daemon never listened: {e}"),
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        };
        let (rd, wr) = stream.into_split();
        Self { lines: tokio::io::BufReader::new(rd).lines(), wr, next: 0 }
    }

    async fn call(&mut self, method: &str, params: Value) -> Value {
        self.next += 1;
        let id = self.next;
        let line = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        self.wr.write_all(format!("{line}\n").as_bytes()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.lines.next_line())
                .await
                .expect("daemon answered in time")
                .unwrap()
                .expect("daemon closed the socket");
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                assert!(v.get("error").is_none(), "{method} failed: {v}");
                return v["result"].clone();
            }
        }
    }

    async fn prompt(&mut self, session: &str, text: &str) -> Value {
        self.call(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": text}]}),
        )
        .await
    }
}

/// Starts the unit's daemon, a session with one finished turn, and returns
/// the unit, the session and its host and harness pids.
async fn session_under_unit(tag: &str, scopes: bool) -> (Unit, String, i64, i64) {
    let home = scratch(tag);
    let unit = Unit::start(&home, tag, scopes);
    let mut rpc = Rpc::connect(&home).await;
    let created = rpc
        .call(
            "session/new",
            json!({"cwd": home, "mcpServers": [], "_meta": {"acpmux": {"harness": "fake"}}}),
        )
        .await;
    let session = created["sessionId"].as_str().expect("session id").to_owned();
    rpc.prompt(&session, "hi").await;
    let (host, harness) = pids(&home, &session);
    (unit, session, host, harness)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_unit_restart_keeps_the_agent_hosts_and_the_new_daemon_reattaches() {
    if !user_manager() {
        eprintln!("no user systemd manager here: skipped");
        return;
    }
    let (unit, session, host, harness) = session_under_unit("keep", true).await;
    let scope = format!("/acpmuxhosts.slice/acpmux-agent-host-{host}.scope");
    assert!(cgroup(host).trim_end().ends_with(&scope), "host not in its scope: {}", cgroup(host));
    assert!(
        cgroup(harness).trim_end().ends_with(&scope),
        "the harness started outside the host's scope: {}",
        cgroup(harness)
    );

    unit.restart();

    assert!(alive(host) && alive(harness), "the restart ended host {host} or harness {harness}");
    let mut rpc = Rpc::connect(&unit.home).await;
    let reply = rpc.prompt(&session, "again").await;
    assert_eq!(reply["stopReason"], "end_turn", "{reply}");
    assert_eq!(pids(&unit.home, &session), (host, harness), "the session got a new host");
    assert!(alive(host) && alive(harness));
    drop(rpc);
    drop(unit);
    assert!(gone_within(host, Duration::from_secs(10)), "host {host} outlived its deleted home");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn without_scopes_the_same_restart_ends_the_agent_hosts() {
    if !user_manager() {
        eprintln!("no user systemd manager here: skipped");
        return;
    }
    let (unit, _session, host, harness) = session_under_unit("ctl", false).await;
    assert!(cgroup(host).trim_end().ends_with(&format!("/{}", unit.name)), "{}", cgroup(host));
    unit.restart();
    assert!(gone_within(host, Duration::from_secs(10)), "host {host} survived without a scope");
    assert!(gone_within(harness, Duration::from_secs(10)));
}
