//! A restart of the daemon's systemd unit never ends its agent hosts
//! (cmuxterm-hq#3763). The daemon runs as a transient user service with the
//! default `KillMode=control-group`, the unit that ended every agent on
//! huge-blue; the hosts it starts move into their own scopes (harnesses
//! already had theirs, `session_scope.rs`, but a host ends its harness when
//! it gets SIGTERM), so after
//! `systemctl --user restart` the same host and harness pids are alive and
//! the new daemon drives the session again. Pooled hosts move too: a taken
//! one survives like any other, and an untaken one still ends with its
//! daemon (it never relied on the unit), also when the daemon is SIGKILLed.
//! With `ACPMUX_HOST_SCOPES=0` the same restart ends them, which shows the
//! test can fail.
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
    let running = state
        .is_ok_and(|o| matches!(String::from_utf8_lossy(&o.stdout).trim(), "running" | "degraded"));
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
            "harnesses": {"fake": {"argv": ["python3", FAKE]}, "fakeb": {"argv": ["python3", FAKE]}},
            "defaultHarness": "fake",
            "permissionPolicy": "approve-all",
            "pool": {"debounceMs": 0},
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
        run.args(["--user", "--quiet", "--collect", "--unit", &name]).args([
            "--property",
            "KillMode=control-group",
            "--property",
            "TimeoutStopSec=30",
        ]);
        let mut env: Vec<(String, String)> = daemon
            .get_envs()
            .filter_map(|(k, v)| Some((k.to_str()?.to_owned(), v?.to_str()?.to_owned())))
            .collect();
        env.extend([
            ("ACPMUX_HOME".into(), home.display().to_string()),
            ("ACPMUX_SOCKET".into(), home.join("s.sock").display().to_string()),
            ("ACPMUX_CATALOG_FETCH".into(), "0".into()),
            ("ACPMUX_LOGIN_ENV".into(), "0".into()),
            // No session scope, so the test never sets the limits of the
            // user's real `acpmuxsessions.slice` (`session_scope.rs`).
            ("ACPMUX_SESSION_MEMORY_MB".into(), "0".into()),
            ("ACPMUX_SESSION_MEMORY_HIGH_MB".into(), "0".into()),
            ("ACPMUX_SESSION_TASKS_MAX".into(), "0".into()),
            ("ACPMUX_SESSION_CPU_WEIGHT".into(), "0".into()),
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
        // `--collect`: the stopped unit is unloaded, failed or not.
        // A unit whose daemon a test killed is already gone.
        let _ = Command::new("systemctl")
            .args(["--user", "stop", &self.name])
            .stderr(std::process::Stdio::null())
            .status();
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

    async fn new_session(&mut self, home: &Path, harness: &str) -> String {
        let created = self
            .call(
                "session/new",
                json!({"cwd": home, "mcpServers": [], "_meta": {"acpmux": {"harness": harness}}}),
            )
            .await;
        created["sessionId"].as_str().expect("session id").to_owned()
    }

    /// Prewarms `harness` and waits (test polling) until the pool holds it ready.
    async fn pool_ready(&mut self, home: &Path, harness: &str) {
        let warmed = self
            .call("_acpmux/prewarm", json!({"harness": harness, "cwd": home, "wait": true}))
            .await;
        assert_eq!(warmed["accepted"], true, "{warmed}");
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            let status = self.call("_acpmux/status", json!({})).await;
            let ready = status["pool"]["entries"]
                .as_array()
                .unwrap()
                .iter()
                .any(|e| e["harness"] == harness && e["state"] == "ready");
            if ready {
                return;
            }
            assert!(Instant::now() < deadline, "{harness} never pooled: {status}");
            tokio::time::sleep(Duration::from_millis(50)).await;
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
    let session = rpc.new_session(&home, "fake").await;
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
    assert!(in_own_scope(host), "host not in its scope: {}", cgroup(host));
    // The harness is in the host's scope, or in its session's own scope
    // (`session_scope.rs`); never in the daemon's unit.
    assert!(
        !cgroup(harness).contains(&format!("/{}", unit.name)),
        "the harness started in the daemon's unit: {}",
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

/// Whether `pid` is in its own host scope (`acpmux-agent-host-<pid>-<tag>.scope`).
fn in_own_scope(pid: i64) -> bool {
    let line = cgroup(pid);
    let prefix = format!("/acpmuxhosts.slice/acpmux-agent-host-{pid}-");
    line.lines()
        .any(|l| l.starts_with("0::") && l.contains(&prefix) && l.trim_end().ends_with(".scope"))
}

fn pool_host(home: &Path) -> i64 {
    let dir = home.join("hosts").join("pool");
    let found = std::fs::read_dir(&dir)
        .unwrap()
        .filter_map(|e| e.ok().map(|e| e.path()))
        .find(|p| p.extension().and_then(|e| e.to_str()) == Some("json"))
        .expect("a pooled host record");
    let record: Value = serde_json::from_slice(&std::fs::read(found).unwrap()).unwrap();
    record["host_pid"].as_i64().unwrap()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn pooled_hosts_move_a_taken_one_survives_and_an_untaken_one_ends_with_its_daemon() {
    if !user_manager() {
        eprintln!("no user systemd manager here: skipped");
        return;
    }
    let home = scratch("pool");
    let unit = Unit::start(&home, "pool", true);
    let mut rpc = Rpc::connect(&home).await;
    rpc.pool_ready(&home, "fakeb").await;
    let waiting = pool_host(&home);
    assert!(in_own_scope(waiting), "pooled host not in its scope: {}", cgroup(waiting));
    let taken = rpc.new_session(&home, "fakeb").await;
    let (host, harness) = pids(&home, &taken);
    assert_eq!(host, waiting, "the session did not take the pooled host");
    assert!(
        !cgroup(harness).contains(&format!("/{}", unit.name)),
        "the taken host's harness stayed in the daemon's unit: {}",
        cgroup(harness)
    );
    rpc.pool_ready(&home, "fakeb").await;
    let untaken = pool_host(&home);
    assert!(in_own_scope(untaken), "pooled host not in its scope: {}", cgroup(untaken));
    drop(rpc);

    unit.restart();

    assert!(
        gone_within(untaken, Duration::from_secs(10)),
        "untaken pooled host {untaken} survived"
    );
    assert!(alive(host) && alive(harness), "the restart ended the taken host or its harness");
    let mut rpc = Rpc::connect(&unit.home).await;
    let reply = rpc.prompt(&taken, "again").await;
    assert_eq!(reply["stopReason"], "end_turn", "{reply}");
    assert_eq!(pids(&unit.home, &taken), (host, harness), "the session got a new host");
    drop(rpc);
    drop(unit);
    assert!(gone_within(host, Duration::from_secs(10)), "host {host} outlived its deleted home");
}

/// SIGKILL to the daemon (no shutdown path, no unit stop): the untaken pooled
/// host in its own scope ends once its controller is gone, and systemd starts
/// no new daemon (the unit has no `Restart=`) to sweep it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_untaken_pooled_host_ends_when_its_daemon_is_killed() {
    if !user_manager() {
        eprintln!("no user systemd manager here: skipped");
        return;
    }
    let home = scratch("kill");
    let unit = Unit::start(&home, "kill", true);
    let mut rpc = Rpc::connect(&home).await;
    rpc.pool_ready(&home, "fakeb").await;
    let pooled = pool_host(&home);
    assert!(in_own_scope(pooled), "pooled host not in its scope: {}", cgroup(pooled));
    drop(rpc);
    let killed = Command::new("systemctl")
        .args(["--user", "kill", "--kill-whom=main", "--signal=SIGKILL", &unit.name])
        .status()
        .expect("systemctl kill");
    assert!(killed.success(), "kill {}: {killed}", unit.name);
    assert!(
        gone_within(pooled, Duration::from_secs(10)),
        "pooled host {pooled} outlived its daemon"
    );
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
