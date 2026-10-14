//! Agent hosts never outlive every daemon that could adopt them (cx-tumi):
//! a kept host whose home was deleted ends, and a pooled host nobody took
//! ends with its daemon, while a host a session took stays for the next
//! daemon. Real binaries, a temporary home. cmux-lawrence-2 had 79 hosts
//! with parent pid 1, most in deleted test homes.
#![cfg(unix)]

use serde_json::{Value, json};
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt};

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

fn scratch(tag: &str) -> PathBuf {
    // Short: socket paths must stay under the macOS limit.
    let home = std::env::temp_dir().join(format!("ahl-{tag}-{}", std::process::id()));
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

fn start_daemon(home: &Path) -> Child {
    let mut child = Command::new(env!("CARGO_BIN_EXE_acpmux"))
        .args(["daemon", "run", "--listen", "127.0.0.1:0", "--ready-fd", "1", "--log", "warn"])
        .env("ACPMUX_HOME", home)
        .env("ACPMUX_SOCKET", home.join("s.sock"))
        // No catalog fetch: a test never reaches the network, and the fetch's
        // warning (a catalog server 404) came on stdout before the ready line.
        .env("ACPMUX_CATALOG_FETCH", "0")
        .env_remove("ACPMUX_AGENT_HOSTS")
        .env("ACPMUX_LOGIN_ENV", "0")
        .env_remove("ACPMUX_LOCAL_ROUTER")
        .env_remove("XPC_SERVICE_NAME")
        .env_remove("ACPMUX_IDLE_CHILD_SECS")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .expect("start daemon");
    let mut ready = String::new();
    BufReader::new(child.stdout.take().unwrap()).read_line(&mut ready).unwrap();
    if !ready.contains("\"ready\":true") {
        let _ = child.kill();
        let _ = child.wait();
        panic!("daemon not ready: {ready}");
    }
    child
}

/// SIGKILL: the daemon gets no chance to end or hand off anything.
fn sigkill(mut child: Child) {
    child.kill().unwrap();
    child.wait().unwrap();
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

fn record(dir: &Path, session: &str) -> Value {
    let bytes = std::fs::read(dir.join(format!("{session}.json"))).expect("host record");
    serde_json::from_slice(&bytes).unwrap()
}

fn pids(record: &Value) -> (i64, i64) {
    (record["host_pid"].as_i64().unwrap(), record["harness_pid"].as_i64().unwrap())
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
}

fn pool_session(home: &Path) -> String {
    let dir = home.join("hosts").join("pool");
    let found = std::fs::read_dir(&dir)
        .unwrap()
        .filter_map(|e| e.ok().map(|e| e.path()))
        .find(|p| p.extension().and_then(|e| e.to_str()) == Some("json"))
        .expect("a pooled host record");
    found.file_stem().unwrap().to_string_lossy().into_owned()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_kept_host_ends_when_its_home_is_deleted() {
    let home = scratch("del");
    let daemon = start_daemon(&home);
    let mut rpc = Rpc::connect(&home).await;
    let session = rpc.new_session(&home, "fake").await;
    rpc.call(
        "session/prompt",
        json!({"sessionId": session, "prompt": [{"type": "text", "text": "hi"}]}),
    )
    .await;
    let (host, harness) = pids(&record(&home.join("hosts"), &session));
    drop(rpc);
    sigkill(daemon);
    // Durable: the host waits for the next daemon.
    assert!(alive(host) && alive(harness), "the kept host ended with its daemon");
    // A test or tag run deletes its home: no daemon can ever adopt it now.
    std::fs::remove_dir_all(&home).unwrap();
    assert!(gone_within(host, Duration::from_secs(10)), "host {host} outlived its deleted home");
    assert!(gone_within(harness, Duration::from_secs(10)), "harness {harness} outlived its host");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_pooled_host_ends_with_its_daemon_and_a_taken_one_stays() {
    let home = scratch("pool");
    let daemon = start_daemon(&home);
    let mut rpc = Rpc::connect(&home).await;
    // One pooled host taken by a session (promoted), then one left in the pool.
    rpc.pool_ready(&home, "fakeb").await;
    let taken = rpc.new_session(&home, "fakeb").await;
    let (taken_host, _) = pids(&record(&home.join("hosts"), &taken));
    rpc.pool_ready(&home, "fakeb").await;
    let pooled = pool_session(&home);
    let (pooled_host, pooled_harness) = pids(&record(&home.join("hosts").join("pool"), &pooled));
    drop(rpc);
    sigkill(daemon);
    assert!(
        gone_within(pooled_host, Duration::from_secs(10)),
        "pooled host {pooled_host} outlived its daemon"
    );
    assert!(gone_within(pooled_harness, Duration::from_secs(10)));
    assert!(alive(taken_host), "the taken session's host must wait for the next daemon");
    std::fs::remove_dir_all(&home).unwrap();
    assert!(gone_within(taken_host, Duration::from_secs(10)), "taken host outlived its home");
}
