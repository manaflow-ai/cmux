//! Durable agent sessions (plans/cmux-next/durable-sessions.md): with agent
//! hosts on, killing or upgrading the acpmux daemon mid-turn neither stops
//! the agent nor loses its output, and a permission prompt shown before the
//! restart is still answerable after the new daemon adopts the host.
#![cfg(unix)]

use serde_json::{Value, json};
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt};

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

struct Daemon {
    child: Option<Child>,
    home: PathBuf,
    socket: PathBuf,
}

impl Daemon {
    fn new(tag: &str, policy: &str) -> Self {
        // Short: socket paths must stay under the macOS limit.
        let home = std::env::temp_dir().join(format!("amd-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        std::fs::create_dir_all(&home).unwrap();
        std::fs::write(
            home.join("config.json"),
            json!({"harnesses": {"fake": {"argv": ["python3", FAKE]}}, "defaultHarness": "fake", "permissionPolicy": policy}).to_string(),
        )
        .unwrap();
        let socket = home.join("s.sock");
        let mut daemon = Self { child: None, home, socket };
        daemon.start();
        daemon
    }

    fn start(&mut self) {
        assert!(self.child.is_none());
        let mut child = Command::new(env!("CARGO_BIN_EXE_acpmux"))
            .args(["daemon", "run", "--listen", "127.0.0.1:0", "--ready-fd", "1", "--log", "warn"])
            .env("ACPMUX_HOME", &self.home)
            .env("ACPMUX_SOCKET", &self.socket)
            .env_remove("ACPMUX_AGENT_HOSTS")
            .env_remove("ACPMUX_LOGIN_ENV")
            .env_remove("XPC_SERVICE_NAME")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .expect("start daemon");
        let mut ready = String::new();
        BufReader::new(child.stdout.take().unwrap()).read_line(&mut ready).unwrap();
        assert!(ready.contains("\"ready\":true"), "daemon not ready: {ready}");
        self.child = Some(child);
    }

    /// The daemon dies without any chance to clean up (a crash).
    fn sigkill(&mut self) {
        let mut child = self.child.take().unwrap();
        child.kill().unwrap();
        child.wait().unwrap();
    }

    /// The daemon is stopped the way an update or the supervisor stops it.
    fn sigterm(&mut self) {
        let mut child = self.child.take().unwrap();
        // SAFETY: signalling this test's own child process.
        assert_eq!(unsafe { libc::kill(child.id() as i32, libc::SIGTERM) }, 0);
        let status = child.wait().unwrap();
        assert!(status.success(), "daemon exited badly on SIGTERM: {status}");
    }

    /// The daemon stopped by itself (`_acpmux/shutdown`).
    fn wait_exit(&mut self) {
        let mut child = self.child.take().unwrap();
        let status = child.wait().unwrap();
        assert!(status.success(), "daemon exited badly after _acpmux/shutdown: {status}");
    }

    async fn rpc(&self) -> Rpc {
        Rpc::connect(&self.socket).await
    }

    fn events(&self, session: &str) -> Vec<Value> {
        let dir = self.home.join("sessions").join(session).join("events");
        let mut files: Vec<PathBuf> = std::fs::read_dir(&dir)
            .map(|d| d.filter_map(|e| e.ok().map(|e| e.path())).collect())
            .unwrap_or_default();
        files.sort();
        files
            .iter()
            .flat_map(|f| {
                std::fs::read_to_string(f)
                    .unwrap_or_default()
                    .lines()
                    .map(str::to_owned)
                    .collect::<Vec<_>>()
            })
            .filter_map(|l| serde_json::from_str(&l).ok())
            .collect()
    }

    /// Waits (test polling) until the session log has a record `pred` accepts.
    fn wait_event(&self, session: &str, what: &str, pred: impl Fn(&Value) -> bool) -> Value {
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            if let Some(e) = self.events(session).into_iter().find(|e| pred(e)) {
                return e;
            }
            assert!(Instant::now() < deadline, "no {what} in the log: {:#?}", self.events(session));
            std::thread::sleep(Duration::from_millis(50));
        }
    }

    fn host_record(&self, session: &str) -> Value {
        let path = self.home.join("hosts").join(format!("{session}.json"));
        serde_json::from_slice(&std::fs::read(&path).expect("host record")).unwrap()
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
        // End every host this test started.
        if let Ok(dir) = std::fs::read_dir(self.home.join("hosts")) {
            for path in dir.filter_map(|e| e.ok().map(|e| e.path())) {
                if path.extension().and_then(|e| e.to_str()) != Some("json") {
                    continue;
                }
                if let Ok(r) =
                    serde_json::from_slice::<Value>(&std::fs::read(&path).unwrap_or_default())
                {
                    for pid in
                        [r["harness_pid"].as_i64(), r["host_pid"].as_i64()].into_iter().flatten()
                    {
                        // SAFETY: process groups this test's daemon created.
                        unsafe { libc::killpg(pid as i32, libc::SIGKILL) };
                    }
                }
            }
        }
        let _ = std::fs::remove_dir_all(&self.home);
    }
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

    async fn send(&mut self, method: &str, params: Value) -> i64 {
        self.next += 1;
        let line = json!({"jsonrpc": "2.0", "id": self.next, "method": method, "params": params});
        self.wr.write_all(format!("{line}\n").as_bytes()).await.unwrap();
        self.next
    }

    async fn call(&mut self, method: &str, params: Value) -> Value {
        let id = self.send(method, params).await;
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

fn make_fifo(path: &Path) {
    let c = std::ffi::CString::new(path.as_os_str().as_encoded_bytes()).unwrap();
    // SAFETY: valid NUL-terminated path.
    assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o600) }, 0);
}

fn alive(pid: i64) -> bool {
    // SAFETY: signal 0 only checks existence.
    unsafe { libc::kill(pid as i32, 0) == 0 }
}

/// Whether `pid` is gone within `within` (an ended process group needs a
/// moment to be reaped by launchd once its host exits).
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

fn chunk(e: &Value, text: &str) -> bool {
    e["msg"]["params"]["update"]["sessionUpdate"] == "agent_message_chunk"
        && e["msg"]["params"]["update"]["content"]["text"] == text
}

async fn new_session(daemon: &Daemon) -> String {
    let mut rpc = daemon.rpc().await;
    let created = rpc.call("session/new", json!({"cwd": daemon.home, "mcpServers": []})).await;
    created["sessionId"].as_str().expect("session id").to_owned()
}

#[tokio::test]
async fn agent_turn_survives_a_daemon_crash_and_completes_after_adoption() {
    let mut daemon = Daemon::new("crash", "approve-all");
    let session = new_session(&daemon).await;
    let gate = daemon.home.join("gate");
    make_fifo(&gate);
    let mut client = daemon.rpc().await;
    client
        .send(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": format!("gate: {}", gate.display())}]}),
        )
        .await;
    daemon.wait_event(&session, "before-gate chunk", |e| chunk(e, "before-gate"));
    let host = daemon.host_record(&session);
    let harness_pid = host["harness_pid"].as_i64().unwrap();

    daemon.sigkill();
    drop(client);
    assert!(alive(harness_pid), "the agent died with the daemon");
    // The agent finishes its turn while no daemon runs.
    std::fs::write(&gate, b"go").unwrap();

    daemon.start();
    let result = daemon.wait_event(&session, "turn_result", |e| e["kind"] == "turn_result");
    assert_eq!(result["msg"]["status"], "completed", "{result}");
    let events = daemon.events(&session);
    assert!(events.iter().any(|e| e["kind"] == "host_adopted"), "no host_adopted record");
    assert_eq!(events.iter().filter(|e| chunk(e, "before-gate")).count(), 1, "repeated output");
    assert_eq!(
        events.iter().filter(|e| chunk(e, "after-gate")).count(),
        1,
        "output produced while no daemon ran was lost or repeated"
    );
    assert!(
        !events.iter().any(|e| e["msg"]["detail"] == "outcome_unknown"),
        "the adopted turn was marked lost"
    );

    // The adopted agent keeps working, with fresh request ids.
    let mut rpc = daemon.rpc().await;
    let reply = rpc
        .call(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": "hello again"}]}),
        )
        .await;
    assert_eq!(reply["stopReason"], "end_turn", "{reply}");
    assert!(alive(harness_pid), "a second agent replaced the adopted one");
}

#[tokio::test]
async fn permission_prompt_survives_a_daemon_upgrade_restart_and_reaches_the_agent() {
    let mut daemon = Daemon::new("perm", "ask");
    let session = new_session(&daemon).await;
    let mut client = daemon.rpc().await;
    client
        .send(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": "ask: deploy"}]}),
        )
        .await;
    let asked =
        daemon.wait_event(&session, "permission_request", |e| e["kind"] == "permission_request");
    let permission_id = asked["msg"]["permissionId"].as_str().unwrap().to_owned();
    let harness_pid = daemon.host_record(&session)["harness_pid"].as_i64().unwrap();

    // An update stops the daemon with SIGTERM: agents are handed off, not
    // ended, and the prompt is not cancelled.
    daemon.sigterm();
    drop(client);
    assert!(alive(harness_pid), "SIGTERM ended the agent");
    assert!(
        !daemon.events(&session).iter().any(|e| e["kind"] == "permission_decision"),
        "SIGTERM answered the permission prompt"
    );

    daemon.start();
    daemon.wait_event(&session, "host_adopted", |e| e["kind"] == "host_adopted");
    let mut rpc = daemon.rpc().await;
    rpc.call(
        "_acpmux/permission_respond",
        json!({"sessionId": session, "permissionId": permission_id, "optionId": "yes"}),
    )
    .await;
    daemon.wait_event(&session, "the agent's answer", |e| chunk(e, "chose yes"));
    let result = daemon.wait_event(&session, "turn_result", |e| e["kind"] == "turn_result");
    assert_eq!(result["msg"]["status"], "completed", "{:#}", json!(daemon.events(&session)));
}

/// Starts a turn that waits on a FIFO; returns the session and its host record.
async fn gated_turn(daemon: &Daemon) -> (String, Value, Rpc) {
    let session = new_session(daemon).await;
    let gate = daemon.home.join(format!("gate-{session}"));
    make_fifo(&gate);
    let mut client = daemon.rpc().await;
    client
        .send(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": format!("gate: {}", gate.display())}]}),
        )
        .await;
    daemon.wait_event(&session, "before-gate chunk", |e| chunk(e, "before-gate"));
    let host = daemon.host_record(&session);
    (session, host, client)
}

/// "Quit Everything" in the app (plans/cmux-next/quit-persistence.md 4.3):
/// `_acpmux/shutdown {endAgents: true}` ends every hosted agent and its host,
/// records the turn in progress as cancelled, and the next daemon adopts
/// nothing.
#[tokio::test]
async fn shutdown_with_end_agents_ends_hosted_agents_and_records_the_cancelled_turn() {
    let mut daemon = Daemon::new("endq", "approve-all");
    let (session, host, client) = gated_turn(&daemon).await;
    let harness_pid = host["harness_pid"].as_i64().unwrap();
    let host_pid = host["host_pid"].as_i64().unwrap();

    let reply = daemon.rpc().await.call("_acpmux/shutdown", json!({"endAgents": true})).await;
    assert_eq!(reply["endAgents"], true, "{reply}");
    daemon.wait_exit();
    drop(client);
    assert!(gone_within(harness_pid, Duration::from_secs(10)), "the agent outlived Quit Everything");
    assert!(gone_within(host_pid, Duration::from_secs(10)), "the agent host outlived Quit Everything");
    let cancelled = daemon
        .events(&session)
        .into_iter()
        .find(|e| e["kind"] == "turn_cancelled")
        .unwrap_or_else(|| panic!("no turn_cancelled record: {:#?}", daemon.events(&session)));
    assert_eq!(cancelled["msg"]["reason"], "quit", "{cancelled}");

    daemon.start();
    let summary = daemon.rpc().await.call("_acpmux/sessions", json!({})).await;
    let entry = summary["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|s| s["sessionId"] == session.as_str())
        .cloned()
        .expect("the session is kept, resumable");
    assert_eq!(entry["status"], "idle", "{entry}");
    assert!(
        !daemon.events(&session).iter().any(|e| e["kind"] == "host_adopted"),
        "a host survived Quit Everything and was adopted"
    );
}

/// "Keep Sessions Running" and every other shutdown leave hosted agents
/// running mid-turn for the next daemon.
#[tokio::test]
async fn shutdown_without_end_agents_keeps_hosted_agents_running() {
    let mut daemon = Daemon::new("keepq", "approve-all");
    let (session, host, client) = gated_turn(&daemon).await;
    let harness_pid = host["harness_pid"].as_i64().unwrap();

    let reply = daemon.rpc().await.call("_acpmux/shutdown", json!({})).await;
    assert_ne!(reply["endAgents"], true, "{reply}");
    daemon.wait_exit();
    drop(client);
    assert!(alive(harness_pid), "a plain shutdown ended the agent");
    assert!(
        !daemon.events(&session).iter().any(|e| e["kind"] == "turn_cancelled"),
        "a plain shutdown cancelled the turn"
    );
}
