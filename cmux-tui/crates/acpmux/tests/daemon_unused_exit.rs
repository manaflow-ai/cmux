//! A daemon nobody uses stops (`daemon/unused_exit.rs`): one on a home of its own (a test's,
//! a tagged build's) with no client, agent, turn or background task for its grace stops
//! normally; a client, a running agent or the shared home keeps it.
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

/// The grace these tests give (`ACPMUX_UNUSED_EXIT_SECS`).
const GRACE_SECS: u64 = 2;
/// Long past the grace: a daemon that should stop has stopped by then.
const PAST_GRACE: Duration = Duration::from_secs(GRACE_SECS * 3);

fn scratch(tag: &str) -> PathBuf {
    // Short: the socket path must stay under the macOS limit.
    let dir = std::env::temp_dir().join(format!("amx-ux-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

async fn ready_daemon(dir: &Path, home: &Path, socket: &Path) -> std::process::Child {
    ready_daemon_with(dir, home, socket, &[]).await
}

async fn ready_daemon_with(
    dir: &Path,
    home: &Path,
    socket: &Path,
    env: &[(&str, &str)],
) -> std::process::Child {
    std::fs::create_dir_all(home).unwrap();
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    std::fs::write(
        home.join("config.json"),
        json!({"harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake", "permissionPolicy": "approve-all"}).to_string(),
    )
    .unwrap();
    let mut child = daemon_env::command(dir, daemon_env::Agents::StandIn, &[])
        .args(["daemon", "run", "--listen", "127.0.0.1:0", "--ready-fd", "1"])
        .args(["--log", "warn"])
        .env("ACPMUX_HOME", home)
        .env("ACPMUX_SOCKET", socket)
        .env("ACPMUX_LOGIN_ENV", "0")
        .env("ACPMUX_UNUSED_EXIT_SECS", GRACE_SECS.to_string())
        // A harness stays up while it is unused: only the daemon's own rule is under test.
        .env("ACPMUX_IDLE_CHILD_SECS", "0")
        .envs(env.iter().copied())
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::inherit())
        .spawn()
        .unwrap();
    let stdout = child.stdout.take().unwrap();
    let ready = tokio::task::spawn_blocking(move || {
        BufReader::new(stdout).lines().map_while(Result::ok).find_map(|line| {
            serde_json::from_str::<Value>(&line).ok().filter(|v| v["ready"] == true)
        })
    });
    let ready = tokio::time::timeout(Duration::from_secs(20), ready).await.unwrap().unwrap();
    if ready.is_none() {
        let _ = child.kill();
        panic!("the daemon exited without a readiness line: {:?}", child.wait());
    }
    child
}

/// The daemon's exit status within `budget`; None when it still runs then.
async fn exit_within(
    child: &mut std::process::Child,
    budget: Duration,
) -> Option<std::process::ExitStatus> {
    let start = Instant::now();
    while start.elapsed() < budget {
        if let Some(status) = child.try_wait().unwrap() {
            return Some(status);
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    None
}

/// Stops a daemon a test kept running, and reports whether it was still running.
async fn stop(child: &mut std::process::Child) -> bool {
    let running = child.try_wait().unwrap().is_none();
    unsafe {
        libc::kill(child.id() as i32, libc::SIGTERM);
    }
    if exit_within(child, acpmux::daemon::EXIT_BUDGET).await.is_none() {
        let _ = child.kill();
        let _ = child.wait();
    }
    running
}

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
}

/// Leo's Mac, 2026-10-30: daemons from tagged and temporary homes ran for days beside the
/// app's own, with nothing attached ("JUST FUCKING REMOVE THE FUCKING OLD DAMEMONS").
#[tokio::test]
async fn a_daemon_nobody_uses_stops_after_its_grace() {
    let dir = scratch("idle");
    let home = dir.join("h");
    let socket = home.join("s.sock");
    let mut child = ready_daemon(&dir, &home, &socket).await;
    let status = exit_within(&mut child, PAST_GRACE + acpmux::daemon::EXIT_BUDGET).await;
    if status.is_none() {
        stop(&mut child).await;
    }
    let status = status.expect("an unused daemon still ran past its grace");
    assert!(status.success(), "{status:?}");
    assert!(!socket.exists(), "the stopped daemon left its socket");
    let _ = std::fs::remove_dir_all(&dir);
}

/// A connected client keeps the daemon; the grace starts once the last one leaves.
#[tokio::test]
async fn a_client_keeps_it_and_its_leaving_starts_the_grace() {
    let dir = scratch("client");
    let home = dir.join("h");
    let socket = home.join("s.sock");
    let mut child = ready_daemon(&dir, &home, &socket).await;
    let mut rpc = Rpc::connect(&socket).await;
    rpc.call("_acpmux/status", json!({})).await;
    let early = exit_within(&mut child, PAST_GRACE).await;
    if early.is_some() {
        panic!("the daemon stopped with a client connected: {early:?}");
    }
    drop(rpc);
    let status = exit_within(&mut child, PAST_GRACE + acpmux::daemon::EXIT_BUDGET).await;
    if status.is_none() {
        stop(&mut child).await;
    }
    let status = status.expect("the daemon still ran a grace after its last client left");
    assert!(status.success(), "{status:?}");
    let _ = std::fs::remove_dir_all(&dir);
}

/// A daemon still loading (its chat logs, adoption) keeps running past its grace: a queued prompt
/// or cut turn the last daemon left resumes from there. It stops a grace after the load ends.
#[tokio::test]
async fn a_daemon_still_loading_keeps_running() {
    let dir = scratch("load");
    let home = dir.join("h");
    let socket = home.join("s.sock");
    // Debug builds only: holds the chat-log load and adoption this long (`daemon.rs`).
    let held = Duration::from_secs(GRACE_SECS * 3);
    let delay = held.as_millis().to_string();
    let env = [("ACPMUX_TEST_DELAY_LOAD_LOGS_MS", delay.as_str())];
    let mut child = ready_daemon_with(&dir, &home, &socket, &env).await;
    let early = exit_within(&mut child, held - Duration::from_secs(1)).await;
    if early.is_some() {
        panic!("the daemon stopped while it still loaded: {early:?}");
    }
    let status = exit_within(&mut child, PAST_GRACE + acpmux::daemon::EXIT_BUDGET).await;
    if status.is_none() {
        stop(&mut child).await;
    }
    let status = status.expect("the daemon still ran a grace after its load ended");
    assert!(status.success(), "{status:?}");
    let _ = std::fs::remove_dir_all(&dir);
}

/// A running agent keeps the daemon with no client: stopping would end or orphan it.
#[tokio::test]
async fn a_running_agent_keeps_it() {
    let dir = scratch("agent");
    let home = dir.join("h");
    let socket = home.join("s.sock");
    let mut child = ready_daemon(&dir, &home, &socket).await;
    let mut rpc = Rpc::connect(&socket).await;
    let session = rpc
        .call(
            "session/new",
            json!({"cwd": dir, "mcpServers": [], "_meta": {"acpmux": {"name": "kept"}}}),
        )
        .await;
    let id = session["sessionId"].as_str().expect("a session id").to_owned();
    // A turn starts the agent; with no idle exit (`ACPMUX_IDLE_CHILD_SECS=0`) it stays up.
    rpc.call(
        "session/prompt",
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "hi"}]}),
    )
    .await;
    drop(rpc);
    let early = exit_within(&mut child, PAST_GRACE).await;
    let running = stop(&mut child).await;
    assert!(running, "the daemon stopped with a running agent: {early:?}");
    let _ = std::fs::remove_dir_all(&dir);
}

/// The shared home (`~/.acpmux`: NIGHTLY's and the CLI's) never stops for being unused: every
/// command and peer expects it.
#[tokio::test]
async fn the_shared_home_never_stops_for_being_unused() {
    let dir = scratch("shared");
    let home = daemon_env::home(&dir).join(".acpmux");
    let socket = home.join("s.sock");
    let mut child = ready_daemon(&dir, &home, &socket).await;
    let early = exit_within(&mut child, PAST_GRACE).await;
    let running = stop(&mut child).await;
    assert!(running, "the shared home's daemon stopped for being unused: {early:?}");
    let _ = std::fs::remove_dir_all(&dir);
}
