//! The local router (`acpmux router serve`) lives exactly as long as a
//! process that may use it: the daemon or a kept agent host. `acpmux daemon
//! shutdown` with no kept agent stops it before the daemon exits, a daemon
//! killed with SIGKILL takes it along, and after `daemon shutdown
//! --keep-agents` the next daemon adopts it, so the kept agent's model calls
//! still go through. Real binaries, real sockets, a temporary home.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt};

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

fn scratch(tag: &str) -> PathBuf {
    // Short: the socket paths must stay under the macOS limit.
    let dir = std::env::temp_dir().join(format!("amx-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(
        dir.join("config.json"),
        json!({"harnesses": {"fake": {"argv": ["python3", FAKE]}}, "defaultHarness": "fake", "permissionPolicy": "approve-all"}).to_string(),
    )
    .unwrap();
    dir
}

/// A daemon in `dir` with the local router on; returns after its readiness line.
fn start_daemon(dir: &Path) -> Child {
    let mut child = daemon_env::command(dir, daemon_env::Agents::StandIn, &[])
        .args(["daemon", "run", "--listen", "127.0.0.1:0", "--ready-fd", "1", "--log", "warn"])
        .env("ACPMUX_HOME", dir)
        .env("ACPMUX_SOCKET", dir.join("s.sock"))
        .env("ACPMUX_LOCAL_ROUTER", "1")
        .env("ACPMUX_LOGIN_ENV", "0")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let stdout = child.stdout.take().unwrap();
    for line in BufReader::new(stdout).lines() {
        let line = line.unwrap();
        if serde_json::from_str::<Value>(&line).is_ok_and(|v| v["ready"] == true) {
            return child;
        }
    }
    let _ = child.kill();
    let _ = child.wait();
    panic!("daemon exited without a readiness line");
}

/// `acpmux daemon shutdown` as the CLI runs it, against the daemon in `dir`.
fn cli_shutdown(dir: &Path, extra: &[&str]) {
    let out = daemon_env::acpmux(dir)
        .args(["daemon", "shutdown"])
        .args(extra)
        .env("ACPMUX_HOME", dir)
        .env("ACPMUX_SOCKET", dir.join("s.sock"))
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
}

/// One admin request to the router in `dir`.
fn ask_router(dir: &Path, request: Value) -> Value {
    let mut stream = UnixStream::connect(dir.join("router").join("router.sock")).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    stream.write_all(format!("{request}\n").as_bytes()).unwrap();
    let mut line = String::new();
    BufReader::new(stream).read_line(&mut line).unwrap();
    serde_json::from_str(&line).unwrap()
}

/// The router's pid from its admin socket (it starts after the daemon is
/// ready), and an idle admin connection that reads EOF when the router
/// process is gone.
fn router(dir: &Path) -> (i32, UnixStream) {
    let socket = dir.join("router").join("router.sock");
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        if let Ok(mut stream) = UnixStream::connect(&socket) {
            stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
            stream.write_all(b"{\"op\":\"status\"}\n").unwrap();
            let mut line = String::new();
            BufReader::new(stream.try_clone().unwrap()).read_line(&mut line).unwrap();
            let status: Value = serde_json::from_str(&line).unwrap();
            let pid = i32::try_from(status["pid"].as_u64().expect("status names the pid")).unwrap();
            return (pid, stream);
        }
        assert!(Instant::now() < deadline, "the daemon started no router");
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn alive(pid: i32) -> bool {
    // SAFETY: signal 0 only checks that the process exists.
    unsafe { libc::kill(pid, 0) == 0 }
}

fn gone_within(pid: i32, within: Duration) -> bool {
    let deadline = Instant::now() + within;
    while alive(pid) {
        if Instant::now() >= deadline {
            return false;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    true
}

fn wait_exit(child: &mut Child, within: Duration) {
    let deadline = Instant::now() + within;
    while child.try_wait().unwrap().is_none() {
        assert!(Instant::now() < deadline, "daemon still running");
        std::thread::sleep(Duration::from_millis(20));
    }
}

struct Rpc {
    lines: tokio::io::Lines<tokio::io::BufReader<tokio::net::unix::OwnedReadHalf>>,
    wr: tokio::net::unix::OwnedWriteHalf,
    next: i64,
}

impl Rpc {
    async fn connect(dir: &Path) -> Self {
        let s = tokio::net::UnixStream::connect(dir.join("s.sock")).await.unwrap();
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

    /// Prompts `session` and returns the last agent text of the session.
    async fn prompt(&mut self, session: &str, text: &str) -> String {
        self.call(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": text}]}),
        )
        .await;
        let events = self
            .call("_acpmux/events", json!({"sessionId": session, "kinds": ["agent_message_chunk"]}))
            .await;
        events["events"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|e| e.pointer("/msg/params/update/content/text").and_then(Value::as_str))
            .next_back()
            .unwrap_or_default()
            .to_owned()
    }
}

#[test]
fn daemon_shutdown_stops_its_router_before_it_exits() {
    let dir = scratch("rtst");
    let mut daemon = start_daemon(&dir);
    let (pid, _held) = router(&dir);
    assert!(alive(pid));
    cli_shutdown(&dir, &["--end-agents"]);
    wait_exit(&mut daemon, Duration::from_secs(15));
    // The daemon reaps the router it started before it exits: the pid is
    // gone now, with no wait (a leaked router would live on with parent pid 1).
    assert!(!alive(pid), "router pid {pid} outlived `acpmux daemon shutdown`");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn router_exits_when_its_daemon_is_killed() {
    let dir = scratch("rkil");
    let mut daemon = start_daemon(&dir);
    let (pid, mut held) = router(&dir);
    assert!(alive(pid));
    // SIGKILL: no shutdown path runs; only the owner FIFO can stop the router.
    daemon.kill().unwrap();
    daemon.wait().unwrap();
    held.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    let mut rest = Vec::new();
    held.read_to_end(&mut rest).expect("the router closed its admin connection in time");
    // EOF: the router process closed its sockets. Its new parent reaps it.
    assert!(
        gone_within(pid, Duration::from_secs(5)),
        "router pid {pid} outlived its killed daemon"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_kept_agent_keeps_its_router_and_the_next_daemon_adopts_it() {
    let dir = scratch("radp");
    let mut first = start_daemon(&dir);
    let (router_pid, _held) = router(&dir);
    let port = ask_router(&dir, json!({"op": "status"}))["port"].as_u64().unwrap();
    // The key a harness holds (a route mints one at spawn).
    let minted = ask_router(
        &dir,
        json!({"op": "mint_key", "scope": {"harness": "fake", "session": "kept", "surfaces": [], "families": ["open_ai_chat"], "expires_at": 0}}),
    );
    let key = minted["key"].as_str().expect("a minted key").to_owned();
    let mut rpc = Rpc::connect(&dir).await;
    let created = rpc.call("session/new", json!({"cwd": dir, "mcpServers": []})).await;
    let session = created["sessionId"].as_str().unwrap().to_owned();
    assert_eq!(rpc.prompt(&session, "hello").await, "echo: hello");
    let record = std::fs::read(dir.join("hosts").join(format!("{session}.json"))).unwrap();
    let record: Value = serde_json::from_slice(&record).unwrap();
    let host_pid = i32::try_from(record["host_pid"].as_i64().unwrap()).unwrap();
    drop(rpc);

    // A restart that keeps the agent: its host holds the router.
    let call = format!("http: http://127.0.0.1:{port}/v1/chat/completions {key}");
    cli_shutdown(&dir, &["--keep-agents"]);
    wait_exit(&mut first, Duration::from_secs(15));
    assert!(alive(host_pid), "--keep-agents ended the agent host");
    assert!(alive(router_pid), "the router stopped while a kept agent still uses it");

    // The next daemon adopts the same router: one router, the same port and keys.
    let mut second = start_daemon(&dir);
    assert_eq!(ask_router(&dir, json!({"op": "status"}))["pid"], json!(router_pid));
    let mut rpc = Rpc::connect(&dir).await;
    let reply = rpc.prompt(&session, &call).await;
    // The relay checked the kept agent's key and answered; with no hosted
    // upstream signed in (the test has no https upstream) that answer is
    // `router.no_upstream`, never 401 (an unknown key) or a refused connection.
    assert!(reply.starts_with("HTTP 503") && reply.contains("router.no_upstream"), "{reply}");
    assert_eq!(ask_router(&dir, json!({"op": "status"}))["pid"], json!(router_pid));
    drop(rpc);

    // Ending every agent ends the router too.
    cli_shutdown(&dir, &["--end-agents"]);
    wait_exit(&mut second, Duration::from_secs(15));
    assert!(gone_within(host_pid, Duration::from_secs(10)), "the agent host outlived the shutdown");
    assert!(gone_within(router_pid, Duration::from_secs(10)), "the router outlived its last agent");
    let _ = std::fs::remove_dir_all(&dir);
}
