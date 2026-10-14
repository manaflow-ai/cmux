//! A harness helper that left the harness's process group (setsid, Node's
//! `detached: true`) ends with the harness when acpmux ends a direct agent:
//! the model probe at each daemon start, config reload and `models
//! --refresh`, and a session's agent when agent hosts are off (cx-n3uid).
//! The group signal does not reach such a helper, and once the harness is
//! gone it runs on with parent pid 1. Real binaries, a temporary home.
#![cfg(unix)]

use serde_json::{Value, json};
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt};

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

/// A daemon home whose harness `fake` starts a setsid helper on each
/// `session/new` and writes its pid to `<home>/helper.<harness pid>`.
fn scratch(tag: &str) -> PathBuf {
    // Short: socket paths must stay under the macOS limit.
    let home = std::env::temp_dir().join(format!("ahh-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    std::fs::create_dir_all(&home).unwrap();
    let helper = home.join("helper");
    std::fs::write(
        home.join("config.json"),
        json!({
            "harnesses": {"fake": {"argv": ["python3", FAKE], "env": {"FAKE_SETSID_CHILD": helper}}},
            "defaultHarness": "fake",
            "permissionPolicy": "approve-all",
        })
        .to_string(),
    )
    .unwrap();
    home
}

/// A daemon with direct agents (no agent hosts); `probe`: the
/// `ACPMUX_PROBE_HARNESSES` list (None: every harness is probed).
fn start_daemon(home: &Path, probe: Option<&str>) -> Child {
    let mut command = Command::new(env!("CARGO_BIN_EXE_acpmux"));
    command
        .args(["daemon", "run", "--listen", "127.0.0.1:0", "--ready-fd", "1", "--log", "warn"])
        .env("ACPMUX_HOME", home)
        .env("ACPMUX_SOCKET", home.join("s.sock"))
        // No catalog fetch: a test never reaches the network.
        .env("ACPMUX_CATALOG_FETCH", "0")
        .env("ACPMUX_AGENT_HOSTS", "0")
        .env("ACPMUX_LOGIN_ENV", "0")
        .env_remove("ACPMUX_LOCAL_ROUTER")
        .env_remove("XPC_SERVICE_NAME")
        .env_remove("ACPMUX_IDLE_CHILD_SECS")
        .env_remove("ACPMUX_PROBE_HARNESSES")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit());
    if let Some(names) = probe {
        command.env("ACPMUX_PROBE_HARNESSES", names);
    }
    let mut child = command.spawn().expect("start daemon");
    let mut ready = String::new();
    BufReader::new(child.stdout.take().unwrap()).read_line(&mut ready).unwrap();
    if !ready.contains("\"ready\":true") {
        let _ = child.kill();
        let _ = child.wait();
        panic!("daemon not ready: {ready}");
    }
    child
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

/// Every helper pid the fake harnesses of `home` reported, by harness pid.
fn helpers(home: &Path) -> Vec<(String, i64)> {
    std::fs::read_dir(home)
        .unwrap()
        .filter_map(|e| e.ok())
        .filter_map(|e| {
            let name = e.file_name().to_string_lossy().into_owned();
            let harness = name.strip_prefix("helper.")?;
            if harness.ends_with(".tmp") {
                return None;
            }
            let pid = std::fs::read_to_string(e.path()).ok()?.trim().parse().ok()?;
            Some((harness.to_owned(), pid))
        })
        .collect()
}

/// Asserts each helper of `found` is gone within 10 s; one still running
/// is ended here (this test's fake started it) before the test fails.
fn assert_all_gone(found: &[(String, i64)], what: &str) {
    let left: Vec<_> =
        found.iter().filter(|(_, pid)| !gone_within(*pid, Duration::from_secs(10))).collect();
    for (_, pid) in &left {
        // SAFETY: the exact helper pid a fake harness of this test reported.
        unsafe { libc::kill(*pid as i32, libc::SIGKILL) };
    }
    assert!(left.is_empty(), "{what}: helpers (harness pid, helper pid) still running: {left:?}");
}

struct Rpc {
    lines: tokio::io::Lines<tokio::io::BufReader<tokio::net::unix::OwnedReadHalf>>,
    wr: tokio::net::unix::OwnedWriteHalf,
    next: i64,
}

impl Rpc {
    async fn connect(home: &Path) -> Self {
        let s = tokio::net::UnixStream::connect(home.join("s.sock")).await.unwrap();
        let (rd, wr) = s.into_split();
        Self { lines: tokio::io::BufReader::new(rd).lines(), wr, next: 0 }
    }

    async fn call(&mut self, method: &str, params: Value) -> Value {
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
                assert!(v.get("error").is_none(), "{method} failed: {v}");
                return v["result"].clone();
            }
        }
    }
}

/// `models --refresh` probes every ACP harness again and answers once the
/// probes ended; no session exists, so every helper is a probe's.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_model_probe_ends_the_helper_its_harness_moved_out_of_its_group() {
    let home = scratch("probe");
    let mut daemon = start_daemon(&home, None);
    let mut rpc = Rpc::connect(&home).await;
    rpc.call("_acpmux/models", json!({"refresh": true})).await;
    let found = helpers(&home);
    assert!(!found.is_empty(), "no model probe started the fake harness");
    assert_all_gone(&found, "a model probe ended its harness");
    drop(rpc);
    let _ = daemon.kill();
    let _ = daemon.wait();
    let _ = std::fs::remove_dir_all(&home);
}

/// A session's direct agent (agent hosts off) that acpmux stops takes its
/// moved-out helper with it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn stopping_a_direct_agent_ends_the_helper_its_harness_moved_out_of_its_group() {
    let home = scratch("kill");
    // No model probe: the only harness is the session's.
    let mut daemon = start_daemon(&home, Some("none"));
    let mut rpc = Rpc::connect(&home).await;
    let created = rpc.call("session/new", json!({"cwd": home, "mcpServers": []})).await;
    let session = created["sessionId"].as_str().expect("session id").to_owned();
    let found = helpers(&home);
    assert_eq!(found.len(), 1, "the session's harness reports one helper: {found:?}");
    assert!(alive(found[0].1), "the helper runs while the agent runs");
    rpc.call("_acpmux/kill", json!({"sessionId": session})).await;
    assert_all_gone(&found, "acpmux stopped the session's agent");
    drop(rpc);
    let _ = daemon.kill();
    let _ = daemon.wait();
    let _ = std::fs::remove_dir_all(&home);
}
