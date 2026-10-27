//! Durable agent sessions (plans/cmux-next/durable-sessions.md): with agent
//! hosts on, killing or upgrading the acpmux daemon mid-turn neither stops
//! the agent nor loses its output, and a permission prompt shown before the
//! restart is still answerable after the new daemon adopts the host.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
#[path = "durable_agents/queue_edit_parts.rs"]
mod queue_edit_parts;
#[path = "durable_agents/queue_restore.rs"]
mod queue_restore;
#[path = "durable_agents/restart_reattach.rs"]
mod restart_reattach;
#[path = "durable_agents/stalled_turn.rs"]
mod stalled_turn;
// This process runs stand-in agents (the fake agents under tests/). The restart harness's sizes
// and budget (`restart_reattach.rs`) are test-runner knobs that hold no credential.
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in().keep(&[
    "ACPMUX_REATTACH_LIVE",
    "ACPMUX_REATTACH_IDLE",
    "ACPMUX_REATTACH_CLOSED",
    "ACPMUX_REATTACH_RECORDS",
    "ACPMUX_REATTACH_SCAN_DELAY_MS",
    "ACPMUX_REATTACH_BUDGET_MS",
    "ACPMUX_REATTACH_OPEN_BUDGET_MS",
]);

use serde_json::{Value, json};
use std::io::{BufRead, BufReader};
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt};

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const FAKE_CLAUDE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");

struct Daemon {
    child: Option<Child>,
    home: PathBuf,
    socket: PathBuf,
    /// Extra daemon environment (the idle harness period).
    env: Vec<(String, String)>,
    /// The person key each start passes on `--person-key-fd 3`, as the app's launcher does.
    key: Option<String>,
}

impl Daemon {
    fn new(tag: &str, policy: &str) -> Self {
        Self::with_env(tag, policy, &[])
    }

    fn with_env(tag: &str, policy: &str, env: &[(&str, &str)]) -> Self {
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
        let env = env.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect();
        let mut daemon = Self { child: None, home, socket, env, key: None };
        daemon.start();
        daemon
    }

    /// A daemon whose fake agent steers as Claude Code does (`FAKE_CLAUDE_STEER`).
    fn claude_steering(tag: &str) -> Self {
        let mut daemon = Self::with_env(tag, "approve-all", &[]);
        daemon.sigterm();
        std::fs::write(
            daemon.home.join("config.json"),
            json!({"harnesses": {"fake": {"argv": ["/usr/bin/env", "FAKE_CLAUDE_STEER=1", "python3", FAKE]}}, "defaultHarness": "fake", "permissionPolicy": "approve-all"}).to_string(),
        )
        .unwrap();
        daemon.start();
        daemon
    }

    /// A daemon whose default harness is `cmux`, the model router's profile:
    /// Claude Code (claude-stdio, fake_claude.py) under a name that is not `claude*`,
    /// with `env` on top. Its "fg-shell" waits two minutes for Ctrl-B, past any restart.
    fn claude_router(tag: &str, env: &[(&str, &str)]) -> Self {
        let mut daemon = Self::with_env(tag, "approve-all", &[]);
        daemon.sigterm();
        let claude_home = daemon.home.join("claude");
        std::fs::create_dir_all(&claude_home).unwrap();
        let mut harness_env =
            json!({"CLAUDE_CONFIG_DIR": claude_home, "FAKE_CLAUDE_FG_WAIT_S": "120"});
        for (k, v) in env {
            harness_env[*k] = json!(v);
        }
        std::fs::write(
            daemon.home.join("config.json"),
            json!({"harnesses": {"cmux": {"argv": ["python3", FAKE_CLAUDE], "kind": "claude-stdio", "env": harness_env}}, "defaultHarness": "cmux", "permissionPolicy": "approve-all"}).to_string(),
        )
        .unwrap();
        daemon.start();
        daemon
    }

    /// A daemon that gets `key` on `--person-key-fd` at each start.
    fn keyed(tag: &str, policy: &str, key: &str) -> Self {
        let mut daemon = Self::with_env(tag, policy, &[]);
        daemon.sigterm();
        daemon.key = Some(key.to_owned());
        daemon.start();
        daemon
    }

    fn start(&mut self) {
        assert!(self.child.is_none());
        let mut command = daemon_env::command(&self.home, daemon_env::Agents::StandIn, &[]);
        command
            .args(["daemon", "run", "--listen", "127.0.0.1:0", "--ready-fd", "1", "--log", "warn"])
            .env("ACPMUX_HOME", &self.home)
            .env("ACPMUX_SOCKET", &self.socket)
            // No catalog fetch: a test never reaches the network, and the fetch's
            // warning (a catalog server 404) came on stdout before the ready line.
            .env("ACPMUX_CATALOG_FETCH", "0")
            .env("ACPMUX_LOGIN_ENV", "0")
            .envs(self.env.iter().map(|(k, v)| (k, v)))
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit());
        let mut fds = [-1i32; 2];
        if let Some(key) = &self.key {
            command.args(["--person-key-fd", "3"]);
            // SAFETY: a fresh pipe; both ends are owned here.
            assert_eq!(unsafe { libc::pipe(fds.as_mut_ptr()) }, 0);
            let line = format!("{key}\n");
            // SAFETY: the write end is open; the line fits the pipe buffer.
            let n = unsafe { libc::write(fds[1], line.as_ptr().cast(), line.len()) };
            assert_eq!(n as usize, line.len());
            // SAFETY: closing our own write end.
            unsafe { libc::close(fds[1]) };
            let read_end = fds[0];
            // SAFETY: only dup2 between fork and exec (async-signal-safe).
            unsafe {
                command.pre_exec(move || {
                    if libc::dup2(read_end, 3) < 0 {
                        return Err(std::io::Error::last_os_error());
                    }
                    Ok(())
                });
            }
        }
        let mut child = command.spawn().expect("start daemon");
        if fds[0] >= 0 {
            // SAFETY: the child has its own copy on fd 3.
            unsafe { libc::close(fds[0]) };
        }
        // The ready line, after any log line the daemon printed first (a catalog refresh warning).
        let mut stdout = BufReader::new(child.stdout.take().unwrap());
        let mut ready = String::new();
        while stdout.read_line(&mut ready).unwrap() > 0 && !ready.contains("\"ready\":true") {
            ready.clear();
        }
        assert!(ready.contains("\"ready\":true"), "daemon not ready");
        // The socket it bound: a short alias when the configured path is past
        // the Unix limit (a long TMPDIR).
        if let Some(bound) = serde_json::from_str::<Value>(&ready)
            .ok()
            .and_then(|v| v["socket"].as_str().map(PathBuf::from))
        {
            self.socket = bound;
        }
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
        let v = self.reply(method, params).await;
        assert!(v.get("error").is_none(), "{method} failed: {v}");
        v["result"].clone()
    }

    /// The whole reply (result or error).
    async fn reply(&mut self, method: &str, params: Value) -> Value {
        let id = self.send(method, params).await;
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.lines.next_line())
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

/// A daemon whose turns stall after 300 ms (`stalledTurnMs`) runs `mode: GATE` (fake_agent.py)
/// until `ready` logs, is killed and started again, and adopts the turn: the chat's summary
/// 600 ms after that, with the daemon, the chat and the gate that ends the turn.
async fn adopted_after(
    tag: &str,
    mode: &str,
    ready: impl Fn(&Value) -> bool,
) -> (Daemon, String, PathBuf, Value) {
    let mut daemon = Daemon::new(tag, "approve-all");
    daemon.sigterm();
    std::fs::write(
        daemon.home.join("config.json"),
        json!({"harnesses": {"fake": {"argv": ["python3", FAKE]}}, "defaultHarness": "fake", "permissionPolicy": "approve-all", "stalledTurnMs": 300}).to_string(),
    )
    .unwrap();
    daemon.start();
    let session = new_session(&daemon).await;
    let gate = daemon.home.join("gate");
    make_fifo(&gate);
    let mut client = daemon.rpc().await;
    client
        .send(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": format!("{mode}: {}", gate.display())}]}),
        )
        .await;
    daemon.wait_event(&session, "the running tool call", ready);

    daemon.sigkill();
    drop(client);
    daemon.start();
    until_turn_restored(&daemon, &session).await;
    tokio::time::sleep(Duration::from_millis(600)).await;
    let all = daemon.rpc().await.call("_acpmux/sessions", json!({})).await;
    let entry = all["sessions"]
        .as_array()
        .and_then(|all| all.iter().find(|s| s["sessionId"] == session))
        .cloned()
        .unwrap_or(Value::Null);
    (daemon, session, gate, entry)
}

/// Opens `gate` and waits for the turn to complete.
fn ends_its_turn(daemon: &Daemon, session: &str, gate: &Path) {
    std::fs::write(gate, b"go").unwrap();
    let result = daemon.wait_event(session, "turn_result", |e| e["kind"] == "turn_result");
    assert_eq!(result["msg"]["status"], "completed", "{result}");
}

/// Goal 8 (`lane.stalledSince`, hub/activity.rs): a tool call still running across a daemon
/// restart is still in flight once the next daemon adopts its host, so the turn waiting on it
/// does not read as stalled. The adopting daemon rebuilt the turn with no tool calls in flight.
#[tokio::test]
async fn a_tool_call_running_across_a_restart_keeps_its_turn_from_stalling() {
    let (daemon, session, gate, entry) =
        adopted_after("stall-up", "work-gate", |e| e["kind"] == "tool_call").await;
    assert_eq!(entry["lane"]["state"], "working", "{entry}");
    assert!(entry["lane"]["stalledSince"].is_null(), "its tool call still runs: {entry}");
    assert_eq!(entry["turn"]["activity"], "Run cargo test", "its tool call, from the log: {entry}");
    ends_its_turn(&daemon, &session, &gate);
}

/// A subagent's tool call is not its parent turn's: rebuilt after a restart, the parent turn
/// still stalls while only its subagent's tool call runs, and does not take its activity. The
/// log's own subagents say whose an update is, not the update's `_meta`: a tool call of the
/// turn's own that names a subagent there is still the turn's.
#[tokio::test]
async fn a_subagents_tool_call_across_a_restart_is_not_its_parent_turns() {
    let (daemon, session, gate, entry) = adopted_after("stall-sub", "child-gate", |e| {
        e["kind"] == "tool_call" && e["msg"].pointer("/params/_meta/acpmux/subagent").is_some()
    })
    .await;
    assert!(entry["lane"]["stalledSince"].is_u64(), "only its subagent's call runs: {entry}");
    assert!(entry["turn"]["activity"].is_null(), "the subagent's activity: {entry}");
    ends_its_turn(&daemon, &session, &gate);

    let (daemon, session, gate, entry) =
        adopted_after("stall-meta", "meta-gate", |e| e["kind"] == "tool_call").await;
    assert!(entry["lane"]["stalledSince"].is_null(), "its own call runs: {entry}");
    assert_eq!(entry["turn"]["activity"], "Own build", "{entry}");
    ends_its_turn(&daemon, &session, &gate);
}

/// An update restarts acpmux while a turn runs that took a steer (the Chief's `tell`). Claude
/// Code answers a steer "steered" at once and the turn runs on. The adopting daemon must keep
/// the turn open until the turn's own prompt is answered; it settled the turn on the steer's
/// answer instead, so every steered subagent read as finished after the 2026-10-19 nightly
/// update while it kept working (update-keeps-sessions.md).
#[tokio::test]
async fn a_steered_turn_stays_open_across_an_update_restart_until_the_agent_ends_it() {
    let mut daemon = Daemon::claude_steering("steer-up");
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
    let mut steerer = daemon.rpc().await;
    let steered = steerer
        .call(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": "a tell"}], "_meta": {"acpmux": {"steer": true}}}),
        )
        .await;
    assert_eq!(steered["stopReason"], "steered", "{steered}");
    let turn_id = daemon.wait_event(&session, "turn_started", |e| e["kind"] == "turn_started")["msg"]
        ["turnId"]
        .clone();
    let harness_pid = daemon.host_record(&session)["harness_pid"].as_i64().unwrap();

    daemon.sigterm();
    drop((client, steerer));
    daemon.start();
    daemon.wait_event(&session, "host_adopted", |e| e["kind"] == "host_adopted");
    assert!(alive(harness_pid), "the agent died with the update restart");
    std::fs::write(&gate, b"go").unwrap();
    daemon.wait_event(&session, "turn_result", |e| e["kind"] == "turn_result");
    let events = daemon.events(&session);
    let after_gate = events.iter().find(|e| chunk(e, "after-gate")).map(|e| e["seq"].as_u64());
    let results: Vec<&Value> = events
        .iter()
        .filter(|e| e["kind"] == "turn_result" && e["msg"]["turnId"] == turn_id)
        .collect();
    assert_eq!(results.len(), 1, "the turn settled more than once: {results:#?}");
    assert_eq!(
        results[0]["msg"]["stopReason"], "end_turn",
        "settled on the steer's answer: {:#?}",
        results[0]
    );
    assert!(
        after_gate.flatten().is_some_and(|g| results[0]["seq"].as_u64().unwrap() > g),
        "the turn settled before the agent ended it: {events:#?}"
    );
}

/// An update restart adopts a running Claude chat without initializing its agent again, so the
/// agent's `steering` capability came back false: every prompt sent into its turns then stopped
/// the turn ("Sent now · stopped the turn") instead of steering, and the composer's hint flipped
/// to "⌘↵ to interrupt" (Leo, 2026-10-20: seven live claude-sr2 chats read steering=false).
#[tokio::test]
async fn an_adopted_chat_still_steers_after_an_update_restart() {
    let mut daemon = Daemon::claude_steering("steer-adopt");
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

    daemon.sigterm();
    drop(client);
    daemon.start();
    daemon.wait_event(&session, "host_adopted", |e| e["kind"] == "host_adopted");
    let mut rpc = daemon.rpc().await;
    let listed = rpc.call("session/list", json!({})).await;
    let entry = listed["sessions"]
        .as_array()
        .and_then(|all| all.iter().find(|s| s["sessionId"] == session.as_str()))
        .cloned()
        .unwrap_or(Value::Null);
    let steering = &entry["_meta"]["acpmux"]["steering"];
    assert_eq!(steering, true, "the adopted chat lost its steering: {entry}");
    let steered = rpc
        .call(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": "a tell"}], "_meta": {"acpmux": {"steer": true}}}),
        )
        .await;
    assert_eq!(steered["stopReason"], "steered", "the steer stopped the adopted turn: {steered}");
    std::fs::write(&gate, b"go").unwrap();
    daemon.wait_event(&session, "turn_result", |e| e["kind"] == "turn_result");
}

/// A chat saved by a build that did not keep `steering` (cc5bd5f68, the daemon that adopted every
/// open chat three times on 2026-10-20) and adopted since never initializes its agent again, so it
/// read steering=false for good: all 57 open chats then stopped their turn for every prompt sent
/// into it (agent-message-steer). A chat whose saved agent is Claude Code's adapter steers: that
/// adapter always does.
#[tokio::test]
async fn a_claude_chat_saved_without_steering_steers_once_adopted() {
    let mut daemon = Daemon::claude_steering("steer-unsaved");
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

    daemon.sigterm();
    drop(client);
    // The chat as the older build saved it: Claude Code's adapter, no `steering`.
    let path = daemon.home.join("sessions").join(&session).join("session.json");
    let mut meta: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    meta.as_object_mut().unwrap().remove("steering");
    meta["agentInfo"] = json!({"name": "claude-stdio", "title": "Claude Code"});
    std::fs::write(&path, serde_json::to_vec_pretty(&meta).unwrap()).unwrap();
    daemon.start();
    daemon.wait_event(&session, "host_adopted", |e| e["kind"] == "host_adopted");

    let mut rpc = daemon.rpc().await;
    let listed = rpc.call("session/list", json!({})).await;
    let entry = listed["sessions"]
        .as_array()
        .and_then(|all| all.iter().find(|s| s["sessionId"] == session.as_str()))
        .cloned()
        .unwrap_or(Value::Null);
    assert_eq!(
        entry["_meta"]["acpmux"]["steering"], true,
        "the adopted chat does not steer: {entry}"
    );
    let steered = rpc
        .call(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": "a tell"}], "_meta": {"acpmux": {"steer": true}}}),
        )
        .await;
    assert_eq!(steered["stopReason"], "steered", "the prompt stopped the adopted turn: {steered}");
    std::fs::write(&gate, b"go").unwrap();
    daemon.wait_event(&session, "turn_result", |e| e["kind"] == "turn_result");
}

/// An update restart adopts a running Claude Code chat's host without starting its agent again,
/// so Ctrl-B goes by what the adopted host runs, not by the chat's saved `agentInfo` (a build that
/// never saved it, or a crash before it did): its summary says `backgroundsWork` and Ctrl-B moves
/// the turn's foreground shell. It read false, so Ctrl-B and subagent Stop were hidden and
/// `_acpmux/process/background` refused until the chat's next fresh start.
#[tokio::test]
async fn an_adopted_claude_chat_still_moves_its_work_after_an_update_restart() {
    let mut daemon = Daemon::claude_router("bg-adopt", &[]);
    let session = new_session(&daemon).await;
    let mut client = daemon.rpc().await;
    client
        .send(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": "fg-shell"}]}),
        )
        .await;
    daemon.wait_event(&session, "the foreground shell", |e| {
        e["msg"]["params"]["update"]["toolCallId"] == "toolu_fg"
    });

    daemon.sigterm();
    drop(client);
    let path = daemon.home.join("sessions").join(&session).join("session.json");
    let mut meta: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    meta.as_object_mut().unwrap().remove("agentInfo");
    std::fs::write(&path, serde_json::to_vec_pretty(&meta).unwrap()).unwrap();
    daemon.start();
    daemon.wait_event(&session, "host_adopted", |e| e["kind"] == "host_adopted");
    until_turn_restored(&daemon, &session).await;

    let mut rpc = daemon.rpc().await;
    let listed = rpc.call("session/list", json!({})).await;
    let entry = listed["sessions"]
        .as_array()
        .and_then(|all| all.iter().find(|s| s["sessionId"] == session.as_str()))
        .cloned()
        .unwrap_or(Value::Null);
    assert_eq!(
        entry["_meta"]["acpmux"]["backgroundsWork"], true,
        "the adopted chat hides Ctrl-B: {entry}"
    );
    let moved = rpc.call("_acpmux/process/background", json!({"sessionId": session})).await;
    assert_eq!(moved, json!({"backgrounded": true}));
    daemon.wait_event(&session, "turn_result", |e| e["kind"] == "turn_result");
}

/// A fresh folder holding the fifo `gate` that fake_claude's backlog waits on (`flood`).
fn flood_gate_dir(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("amd-{tag}-gate-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    make_fifo(&dir.join("gate"));
    dir
}

/// Opens `gate` and waits (test polling) until the agent streamed its backlog: with the daemon
/// down, the agent's host holds every entry for the next one.
fn flood_while_down(gate: &Path) {
    std::fs::write(gate, b"go").unwrap();
    let done = gate.with_extension("done");
    let deadline = Instant::now() + Duration::from_secs(30);
    while !done.exists() {
        assert!(Instant::now() < deadline, "the agent never streamed its backlog");
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// Waits until the adopted chat holds its turn again (`_acpmux/sessions` `turn`, which only
/// the running daemon sets).
/// The daemon logs `host_adopted` before it restores the turn in flight (`hub/hosts.rs`
/// `recover_work`), so a Ctrl-B right after that record can find no turn and move nothing.
async fn until_turn_restored(daemon: &Daemon, session: &str) {
    let mut rpc = daemon.rpc().await;
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        let all = rpc.call("_acpmux/sessions", json!({})).await;
        let entry = all["sessions"]
            .as_array()
            .and_then(|all| all.iter().find(|s| s["sessionId"] == session))
            .cloned()
            .unwrap_or(Value::Null);
        if !entry["turn"].is_null() {
            return;
        }
        assert!(Instant::now() < deadline, "the adopted turn never ran again: {entry}");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

/// The chat's `backgroundsWork` (`session/list`).
async fn backgrounds_work(daemon: &Daemon, session: &str) -> Value {
    let listed = daemon.rpc().await.call("session/list", json!({})).await;
    let entry = listed["sessions"]
        .as_array()
        .and_then(|all| all.iter().find(|s| s["sessionId"] == session))
        .cloned()
        .unwrap_or(Value::Null);
    entry["_meta"]["acpmux"]["backgroundsWork"].clone()
}

/// A Claude Code host that streamed a long backlog while no daemon ran: the next daemon adopts it
/// at once, still moves its work, and does not wait out the host's state query behind the replay.
/// Asked before the session read the replay, the query's answer sat behind 8,000 entries nothing
/// drained: adoption waited the query's 5 s budget, and the chat read `backgroundsWork` false.
#[tokio::test]
async fn a_claude_host_with_a_long_backlog_is_adopted_at_once_and_still_moves_its_work() {
    let gate_dir = flood_gate_dir("bg-flood");
    let gate = gate_dir.join("gate");
    let gate_env = gate.to_string_lossy().into_owned();
    let mut daemon = Daemon::claude_router("bg-flood", &[("FAKE_CLAUDE_FLOOD_GATE", &gate_env)]);
    let session = new_session(&daemon).await;
    let mut client = daemon.rpc().await;
    client
        .send(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": "fg-shell"}]}),
        )
        .await;
    daemon.wait_event(&session, "the foreground shell", |e| {
        e["msg"]["params"]["update"]["toolCallId"] == "toolu_fg"
    });

    daemon.sigterm();
    drop(client);
    flood_while_down(&gate);
    let started = Instant::now();
    daemon.start();
    daemon.wait_event(&session, "host_adopted", |e| e["kind"] == "host_adopted");
    let adopted = started.elapsed();
    assert!(adopted < Duration::from_secs(4), "adoption took {adopted:?}");
    until_turn_restored(&daemon, &session).await;
    assert_eq!(backgrounds_work(&daemon, &session).await, true, "the adopted chat hides Ctrl-B");
    let mut rpc = daemon.rpc().await;
    let moved = rpc.call("_acpmux/process/background", json!({"sessionId": session})).await;
    assert_eq!(moved, json!({"backgrounded": true}));
    daemon.wait_event(&session, "turn_result", |e| e["kind"] == "turn_result");
    let _ = std::fs::remove_dir_all(&gate_dir);
}

/// A prompt that finds an adopted Claude Code chat's link lost reaches its host again
/// (`ensure_child` -> `readopt`, which returns the reattached agent before any start) and the chat
/// still moves its work. The host was adopted behind a long backlog, whose state query waited out
/// its budget, so the chat read `backgroundsWork` false from adoption on, and the reattach kept it.
#[tokio::test]
async fn a_reattached_claude_host_still_moves_its_work() {
    let gate_dir = flood_gate_dir("bg-reattach");
    let gate = gate_dir.join("gate");
    let gate_env = gate.to_string_lossy().into_owned();
    let mut daemon = Daemon::claude_router("bg-reattach", &[("FAKE_CLAUDE_FLOOD_GATE", &gate_env)]);
    let session = new_session(&daemon).await;
    let mut client = daemon.rpc().await;
    client
        .send(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": "flood"}]}),
        )
        .await;
    daemon.wait_event(&session, "before-flood chunk", |e| chunk(e, "before-flood"));
    daemon.sigterm();
    drop(client);
    flood_while_down(&gate);
    daemon.start();
    daemon.wait_event(&session, "host_adopted", |e| e["kind"] == "host_adopted");
    daemon.wait_event(&session, "the backlog's turn_result", |e| e["kind"] == "turn_result");

    // Another owner takes the host over, which closes the daemon's link.
    let record: acpmux::agent_host::HostRecord =
        serde_json::from_value(daemon.host_record(&session)).unwrap();
    let harness_pid = record.harness_pid;
    match acpmux::agent_host::link::connect(record, 0).await.expect("take over") {
        acpmux::agent_host::link::Connect::Ready(link, _) => drop(link),
        _ => panic!("the host refused a same-build owner"),
    }
    // Let the daemon's reader see the closed link (a test-only fixed wait).
    tokio::time::sleep(Duration::from_millis(300)).await;
    let mut client = daemon.rpc().await;
    client
        .send(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": "fg-shell"}]}),
        )
        .await;
    daemon.wait_event(&session, "the foreground shell", |e| {
        e["msg"]["params"]["update"]["toolCallId"] == "toolu_fg"
    });
    // The same agent, reached again: no second host started.
    let starts = daemon.events(&session).iter().filter(|e| e["kind"] == "host_started").count();
    assert_eq!(starts, 1, "the prompt started a new agent instead of reattaching");
    let now: acpmux::agent_host::HostRecord =
        serde_json::from_value(daemon.host_record(&session)).unwrap();
    assert_eq!(now.harness_pid, harness_pid, "a second agent replaced the live one");
    assert_eq!(backgrounds_work(&daemon, &session).await, true, "the reattached chat hides Ctrl-B");
    let mut rpc = daemon.rpc().await;
    let moved = rpc.call("_acpmux/process/background", json!({"sessionId": session})).await;
    assert_eq!(moved, json!({"backgrounded": true}));
    let _ = std::fs::remove_dir_all(&gate_dir);
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
    // The adopted prompt is pending again once the new run records its new
    // nonce (`permission_reissued`); an answer before that finds no prompt.
    daemon.wait_event(&session, "permission_reissued", |e| {
        e["kind"] == "permission_reissued" && e["msg"]["permissionId"] == json!(permission_id)
    });
    let mut rpc = daemon.rpc().await;
    // A deny: this plain socket client is not the person (`hub/person.rs`),
    // and the answer still reaches the adopted agent.
    rpc.call(
        "_acpmux/permission_respond",
        json!({"sessionId": session, "permissionId": permission_id, "optionId": "no"}),
    )
    .await;
    daemon.wait_event(&session, "the agent's answer", |e| chunk(e, "chose no"));
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
    assert!(
        gone_within(harness_pid, Duration::from_secs(10)),
        "the agent outlived Quit Everything"
    );
    assert!(
        gone_within(host_pid, Duration::from_secs(10)),
        "the agent host outlived Quit Everything"
    );
    let results: Vec<Value> =
        daemon.events(&session).into_iter().filter(|e| e["kind"] == "turn_result").collect();
    assert_eq!(results.len(), 1, "one result for the cancelled turn: {results:#?}");
    assert_eq!(results[0]["msg"]["status"], "cancelled", "{results:#?}");
    assert_eq!(results[0]["msg"]["detail"], "quit", "{results:#?}");

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
    assert_eq!(
        daemon.events(&session).iter().filter(|e| e["kind"] == "turn_result").count(),
        1,
        "the restart settled the cancelled turn again"
    );
}

/// `acpmux daemon shutdown` as the CLI runs it, against this daemon.
fn cli_shutdown(daemon: &Daemon, extra: &[&str]) -> std::process::Output {
    daemon_env::acpmux(&daemon.home)
        .args(["daemon", "shutdown"])
        .args(extra)
        .env("ACPMUX_HOME", &daemon.home)
        .env("ACPMUX_SOCKET", &daemon.socket)
        .output()
        .expect("run acpmux daemon shutdown")
}

/// `acpmux daemon shutdown --end-agents` does what its help says: it stops
/// the daemon and every agent process, hosted agents and their hosts
/// included. On cmux-lawrence (2026-10-06) it reported success against the
/// brain's acpmux and left the "rollback-throwaway" session's agent host
/// running.
#[tokio::test]
async fn the_cli_shutdown_with_end_agents_ends_every_agent_and_its_host() {
    let mut daemon = Daemon::new("clis", "approve-all");
    let (_session, host, client) = gated_turn(&daemon).await;
    let out = cli_shutdown(&daemon, &["--end-agents"]);
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    daemon.wait_exit();
    drop(client);
    assert!(
        gone_within(host["harness_pid"].as_i64().unwrap(), Duration::from_secs(10)),
        "the agent outlived acpmux daemon shutdown"
    );
    assert!(
        gone_within(host["host_pid"].as_i64().unwrap(), Duration::from_secs(10)),
        "the agent host outlived acpmux daemon shutdown"
    );
}

/// A harness helper that moved into its own session (setsid) is out of reach
/// of the harness group signal; `acpmux daemon shutdown --end-agents` still
/// ends it.
#[tokio::test]
async fn the_cli_shutdown_ends_a_harness_child_that_left_its_group() {
    let helper_file = std::env::temp_dir().join(format!("amd-sid-{}", std::process::id()));
    let _ = std::fs::remove_file(&helper_file);
    let mut daemon = Daemon::with_env(
        "clisid",
        "approve-all",
        &[("FAKE_SETSID_CHILD", helper_file.to_str().unwrap())],
    );
    let (_session, host, client) = gated_turn(&daemon).await;
    // The helper of this session's harness (a model probe's harness starts
    // one too, in its own file).
    let helper_path = format!("{}.{}", helper_file.display(), host["harness_pid"]);
    let helper: i64 = std::fs::read_to_string(&helper_path).unwrap().trim().parse().unwrap();
    let _ = std::fs::remove_file(&helper_path);
    let out = cli_shutdown(&daemon, &["--end-agents"]);
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    daemon.wait_exit();
    drop(client);
    let gone = gone_within(helper, Duration::from_secs(10));
    if !gone {
        // SAFETY: this test's agent started the helper; end it before failing.
        unsafe { libc::kill(helper as i32, libc::SIGKILL) };
    }
    assert!(gone, "a harness child that left its group outlived acpmux daemon shutdown");
}

/// cx-qryd0 (hq-6d 2026-10-15): a plain `acpmux daemon shutdown` is a
/// restart stop, as the `_acpmux/shutdown` RPC without endAgents: the hosted
/// agent keeps running and the next daemon adopts it. (It ended every agent
/// before, and a proof's clean start ended another job's live agent on a
/// shared machine, cx-ao1gb.)
#[tokio::test]
async fn a_plain_cli_shutdown_keeps_hosted_agents_for_the_next_daemon() {
    let mut daemon = Daemon::new("cliplain", "approve-all");
    let (session, host, client) = gated_turn(&daemon).await;
    let out = cli_shutdown(&daemon, &[]);
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    daemon.wait_exit();
    drop(client);
    let harness = host["harness_pid"].as_i64().unwrap();
    assert!(alive(harness), "a plain shutdown ended the agent");
    // The next daemon adopts it.
    daemon.start();
    daemon.wait_event(&session, "host_adopted", |e| e["kind"] == "host_adopted");
    assert!(alive(harness), "the agent did not survive the restart");
    // This test started it: end it (and the daemon) explicitly.
    let out = cli_shutdown(&daemon, &["--end-agents"]);
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    daemon.wait_exit();
    assert!(gone_within(harness, Duration::from_secs(10)), "--end-agents left the agent running");
}

/// What the agent of `session` has in its environment as `name`
/// (the fake agent's `env:` prompt).
async fn agent_env(daemon: &Daemon, session: &str, name: &str) -> String {
    let prefix = format!("{name}=");
    let values = || -> Vec<String> {
        daemon
            .events(session)
            .iter()
            .filter_map(|e| e["msg"]["params"]["update"]["content"]["text"].as_str())
            .filter_map(|t| t.strip_prefix(&prefix).map(str::to_owned))
            .collect()
    };
    let before = values().len();
    let mut rpc = daemon.rpc().await;
    rpc.call(
        "session/prompt",
        json!({"sessionId": session, "prompt": [{"type": "text", "text": format!("env: {name}")}]}),
    )
    .await;
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        if let Some(value) = values().get(before) {
            return value.clone();
        }
        assert!(Instant::now() < deadline, "the agent never said {name}");
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// A connection that presents `token` as session `session`'s caller token,
/// as the cmux-subsessions server and the acpmux CLI inside it do, and its
/// reply to `_acpmux/subsession/list`.
async fn list_as(daemon: &Daemon, session: &str, token: &str) -> Value {
    let mut caller = daemon.rpc().await;
    caller
        .call(
            "initialize",
            json!({"protocolVersion": 1,
                   "_meta": {"acpmux": {"callerSession": {"sessionId": session, "token": token}}}}),
        )
        .await;
    caller.reply("_acpmux/subsession/list", json!({})).await
}

/// An app update restarts acpmux; the adopted agent and its MCP servers
/// (cmux-subsessions, cmux) keep the caller token the previous daemon gave
/// them. The new daemon must still know the session by it: on 2026-10-20 a
/// coordinator lost control of its ten sub-sessions after the nightly update,
/// because every sub-session tool was refused with that token.
#[tokio::test]
async fn an_adopted_agent_keeps_its_caller_token_across_an_update_restart() {
    let mut daemon = Daemon::new("callerup", "approve-all");
    let session = new_session(&daemon).await;
    let token = agent_env(&daemon, &session, "ACPMUX_SESSION_TOKEN").await;
    assert_eq!(token.len(), 64, "the agent has no caller token: {token:?}");
    let before = list_as(&daemon, &session, &token).await;
    assert!(before.get("error").is_none(), "the token did not prove its session: {before}");
    let harness = daemon.host_record(&session)["harness_pid"].as_i64().unwrap();

    daemon.sigterm();
    daemon.start();
    daemon.wait_event(&session, "host_adopted", |e| e["kind"] == "host_adopted");
    assert!(alive(harness), "the agent died with the update restart");
    let after = list_as(&daemon, &session, &token).await;
    assert!(
        after.get("error").is_none(),
        "the adopted agent's caller token no longer proves its session: {after}"
    );
    // The token is the session's alone.
    let other = new_session(&daemon).await;
    let borrowed = list_as(&daemon, &other, &token).await;
    assert!(borrowed.get("error").is_some(), "one session's token proved another: {borrowed}");
    // A new agent process has this run's token; the earlier one stops counting.
    let out = daemon_env::acpmux(&daemon.home)
        .args(["session", "restart", &session])
        .env("ACPMUX_HOME", &daemon.home)
        .env("ACPMUX_SOCKET", &daemon.socket)
        .output()
        .expect("run acpmux session restart");
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    let fresh = agent_env(&daemon, &session, "ACPMUX_SESSION_TOKEN").await;
    assert_ne!(fresh, token, "the restarted agent kept the earlier run's token");
    let stale = list_as(&daemon, &session, &token).await;
    assert!(stale.get("error").is_some(), "the replaced agent's token still proves it: {stale}");
    let current = list_as(&daemon, &session, &fresh).await;
    assert!(current.get("error").is_none(), "the restarted agent's token: {current}");
}

/// A caller token the daemon cannot prove (a host of an older build kept an
/// earlier daemon run's token) is refused with what to do about it, not
/// only "connect with that session's caller token".
#[tokio::test]
async fn an_unproven_caller_token_is_refused_with_how_to_get_a_new_one() {
    let daemon = Daemon::new("callerbad", "approve-all");
    let session = new_session(&daemon).await;
    let refused = list_as(&daemon, &session, &"0".repeat(64)).await;
    let error = &refused["error"];
    assert_eq!(error["data"]["reason"], "subsessions.caller_not_proven", "{refused}");
    // A session this daemon does not have gets no restart advice.
    let unknown = list_as(&daemon, "no-such-session", &"0".repeat(64)).await;
    assert_eq!(unknown["error"]["data"]["reason"], "subsessions.caller_required", "{unknown}");
    let message = error["message"].as_str().unwrap_or_default();
    assert!(
        message.contains(&format!("acpmux session restart {session}")),
        "the refusal does not say how to get a new token: {message}"
    );
    // What it says works: the agent restarts, with a token that proves it.
    let harness = daemon.host_record(&session)["harness_pid"].as_i64().unwrap();
    let out = daemon_env::acpmux(&daemon.home)
        .args(["session", "restart", &session])
        .env("ACPMUX_HOME", &daemon.home)
        .env("ACPMUX_SOCKET", &daemon.socket)
        .output()
        .expect("run acpmux session restart");
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    assert_eq!(String::from_utf8_lossy(&out.stdout).trim(), "restarted");
    let token = agent_env(&daemon, &session, "ACPMUX_SESSION_TOKEN").await;
    let restarted = daemon.host_record(&session)["harness_pid"].as_i64().unwrap();
    assert_ne!(restarted, harness, "the agent process did not restart");
    let listed = list_as(&daemon, &session, &token).await;
    assert!(listed.get("error").is_none(), "the restarted agent's token: {listed}");
}

/// A host of an older build records no caller token, so after an update
/// restart its agent cannot prove its session and loses its sub-session
/// tools. The daemon restarts that agent (same conversation) once its turn
/// ends, never during it; an agent whose host kept its token runs on.
#[tokio::test]
async fn an_adopted_agent_without_a_recorded_token_restarts_after_its_turn() {
    let mut daemon = Daemon::new("callerold", "approve-all");
    let kept = new_session(&daemon).await;
    let kept_token = agent_env(&daemon, &kept, "ACPMUX_SESSION_TOKEN").await;
    let kept_harness = daemon.host_record(&kept)["harness_pid"].as_i64().unwrap();
    let (session, host, client) = gated_turn(&daemon).await;
    let token = recorded_token(&daemon, &session);
    let harness = host["harness_pid"].as_i64().unwrap();

    daemon.sigterm();
    drop(client);
    // What an older host's record looks like: no caller token.
    let mut record = host.clone();
    assert!(record.as_object_mut().unwrap().remove("caller_token").is_some());
    let path = daemon.home.join("hosts").join(format!("{session}.json"));
    std::fs::write(&path, record.to_string()).unwrap();
    daemon.start();
    daemon.wait_event(&session, "host_adopted", |e| e["kind"] == "host_adopted");
    daemon.wait_event(&kept, "host_adopted", |e| e["kind"] == "host_adopted");
    std::thread::sleep(Duration::from_millis(500));
    assert!(alive(harness), "the agent was restarted mid-turn");

    std::fs::write(daemon.home.join(format!("gate-{session}")), b"go").unwrap();
    daemon.wait_event(&session, "after-gate chunk", |e| chunk(e, "after-gate"));
    assert!(
        gone_within(harness, Duration::from_secs(10)),
        "the agent without a known caller token was not restarted after its turn"
    );
    let fresh = agent_env(&daemon, &session, "ACPMUX_SESSION_TOKEN").await;
    assert_ne!(Some(fresh.as_str()), token.as_deref(), "it kept the earlier run's token");
    let listed = list_as(&daemon, &session, &fresh).await;
    assert!(listed.get("error").is_none(), "the restarted agent's token: {listed}");
    assert!(alive(kept_harness), "an agent with a known token was restarted");
    let listed = list_as(&daemon, &kept, &kept_token).await;
    assert!(listed.get("error").is_none(), "the kept agent's token: {listed}");
}

/// The caller token a host recorded for its agent, if any.
fn recorded_token(daemon: &Daemon, session: &str) -> Option<String> {
    daemon.host_record(session)["caller_token"].as_str().map(str::to_owned)
}

/// `--keep-agents` stays accepted (a no-op now) for callers that may run an
/// older CLI: hosted agents keep running for the next daemon to adopt.
#[tokio::test]
async fn the_cli_shutdown_with_keep_agents_leaves_hosted_agents_running() {
    let mut daemon = Daemon::new("clik", "approve-all");
    let (_session, host, client) = gated_turn(&daemon).await;
    let out = cli_shutdown(&daemon, &["--keep-agents"]);
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    daemon.wait_exit();
    drop(client);
    let harness = host["harness_pid"].as_i64().unwrap();
    assert!(alive(harness), "--keep-agents ended the agent");
    // This test started it: end it now that the check is done.
    // SAFETY: the host's own pid from its record; ends this test's agent.
    unsafe { libc::kill(host["host_pid"].as_i64().unwrap() as i32, libc::SIGTERM) };
    assert!(gone_within(harness, Duration::from_secs(10)));
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
        !daemon.events(&session).iter().any(|e| e["kind"] == "turn_result"),
        "a plain shutdown settled the turn"
    );
}

/// Quit Everything keeps the Home Chief: `keepSessions` names sessions whose
/// hosted agents detach and keep running while every other agent ends.
#[tokio::test]
async fn shutdown_with_end_agents_keeps_the_named_sessions_running() {
    let mut daemon = Daemon::new("keepn", "approve-all");
    let (chief, chief_host, chief_client) = gated_turn(&daemon).await;
    let (other, other_host, other_client) = gated_turn(&daemon).await;

    let reply = daemon
        .rpc()
        .await
        .call("_acpmux/shutdown", json!({"endAgents": true, "keepSessions": [chief]}))
        .await;
    assert_eq!(reply["keptSessions"], 1, "{reply}");
    daemon.wait_exit();
    drop((chief_client, other_client));
    assert!(alive(chief_host["harness_pid"].as_i64().unwrap()), "the kept session's agent ended");
    assert!(
        gone_within(other_host["harness_pid"].as_i64().unwrap(), Duration::from_secs(10)),
        "the other agent outlived Quit Everything"
    );
    assert!(
        !daemon.events(&chief).iter().any(|e| e["kind"] == "turn_result"),
        "the kept session's turn was settled"
    );
    assert!(
        daemon
            .events(&other)
            .iter()
            .any(|e| e["kind"] == "turn_result" && e["msg"]["detail"] == "quit")
    );
}

/// The idle harness exit (one second here) terminates an unused hosted
/// session's agent and its host, and the session resumes on its next
/// prompt; a turn or a permission prompt that an adopted host's recovery
/// rebuilt after a daemon restart is in use, never idle.
const IDLE_1S: &[(&str, &str)] = &[("ACPMUX_IDLE_CHILD_SECS", "1")];

#[tokio::test]
async fn an_idle_hosted_agent_is_terminated_and_the_session_resumes() {
    let daemon = Daemon::with_env("idle", "approve-all", IDLE_1S);
    let session = new_session(&daemon).await;
    let harness_pid = daemon.host_record(&session)["harness_pid"].as_i64().unwrap();
    assert!(gone_within(harness_pid, Duration::from_secs(20)), "the idle agent kept running");
    let mut rpc = daemon.rpc().await;
    let reply = rpc
        .call(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": "after idle"}]}),
        )
        .await;
    assert_eq!(reply["stopReason"], "end_turn", "{reply}");
    let events = daemon.events(&session);
    assert!(events.iter().any(|e| e["kind"] == "resumed"), "the session did not resume");
}

#[tokio::test]
async fn an_adopted_open_turn_is_not_idle() {
    let mut daemon = Daemon::with_env("idleturn", "approve-all", IDLE_1S);
    let (session, host, client) = gated_turn(&daemon).await;
    let harness_pid = host["harness_pid"].as_i64().unwrap();
    daemon.sigkill();
    drop(client);
    daemon.start();
    daemon.wait_event(&session, "host_adopted", |e| e["kind"] == "host_adopted");
    // No client attached, and three idle periods pass with the turn open.
    std::thread::sleep(Duration::from_secs(3));
    assert!(alive(harness_pid), "the reaper ended an agent with an adopted open turn");
    std::fs::write(daemon.home.join(format!("gate-{session}")), b"go").unwrap();
    let result = daemon.wait_event(&session, "turn_result", |e| e["kind"] == "turn_result");
    assert_eq!(result["msg"]["status"], "completed", "{result}");
}

#[tokio::test]
async fn a_recovered_permission_prompt_is_not_idle() {
    let mut daemon = Daemon::with_env("idleperm", "ask", IDLE_1S);
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
    daemon.sigterm();
    drop(client);
    daemon.start();
    daemon.wait_event(&session, "host_adopted", |e| e["kind"] == "host_adopted");
    std::thread::sleep(Duration::from_secs(3));
    assert!(alive(harness_pid), "the reaper ended an agent with a recovered permission prompt");
    let mut rpc = daemon.rpc().await;
    rpc.call(
        "_acpmux/permission_respond",
        json!({"sessionId": session, "permissionId": permission_id, "optionId": "no"}),
    )
    .await;
    let result = daemon.wait_event(&session, "turn_result", |e| e["kind"] == "turn_result");
    assert_eq!(result["msg"]["status"], "completed", "{result}");
}

/// A live host whose link this daemon lost (another owner took the host over
/// and left) must not lock its session: the next prompt reattaches to the
/// same agent instead of failing with "cannot be reached".
#[tokio::test]
async fn a_live_host_with_a_lost_link_is_reattached_not_locked() {
    let daemon = Daemon::new("lost", "approve-all");
    let session = new_session(&daemon).await;
    let mut rpc = daemon.rpc().await;
    let prompt = json!({"sessionId": session, "prompt": [{"type": "text", "text": "hello"}]});
    assert_eq!(rpc.call("session/prompt", prompt.clone()).await["stopReason"], "end_turn");
    let record: acpmux::agent_host::HostRecord =
        serde_json::from_value(daemon.host_record(&session)).unwrap();
    let harness_pid = record.harness_pid.expect("harness pid") as i64;

    // Another owner takes the host over, which closes the daemon's link.
    match acpmux::agent_host::link::connect(record, 0).await.expect("take over") {
        acpmux::agent_host::link::Connect::Ready(link, _) => drop(link),
        _ => panic!("the host refused a same-build owner"),
    }
    // Let the daemon's reader see the closed link (a test-only fixed wait).
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(alive(harness_pid), "the takeover ended the agent");

    let mut rpc = daemon.rpc().await;
    let id = rpc.send("session/prompt", prompt).await;
    let reply = loop {
        let line = tokio::time::timeout(Duration::from_secs(30), rpc.lines.next_line())
            .await
            .expect("daemon answered in time")
            .unwrap()
            .expect("daemon closed the socket");
        let v: Value = serde_json::from_str(&line).unwrap();
        if v.get("id") == Some(&json!(id)) {
            break v;
        }
    };
    assert_eq!(reply["result"]["stopReason"], "end_turn", "the session is locked: {reply}");
    assert!(alive(harness_pid), "a second agent replaced the live one");
}

/// An idle hosted session whose link this daemon lost (another owner took
/// the host over and left) still ends at the idle exit: the reaper ends the
/// unadopted host with its nonce proof instead of sending Terminate over
/// the dead link and leaving the harness running.
#[tokio::test]
async fn an_idle_hosted_agent_with_a_lost_link_is_ended() {
    let daemon = Daemon::with_env("idlelost", "approve-all", &[("ACPMUX_IDLE_CHILD_SECS", "2")]);
    let session = new_session(&daemon).await;
    let record: acpmux::agent_host::HostRecord =
        serde_json::from_value(daemon.host_record(&session)).unwrap();
    let harness_pid = record.harness_pid.expect("harness pid") as i64;
    // Another owner takes the host over, which closes the daemon's link.
    match acpmux::agent_host::link::connect(record, 0).await.expect("take over") {
        acpmux::agent_host::link::Connect::Ready(link, _) => drop(link),
        _ => panic!("the host refused a same-build owner"),
    }
    assert!(gone_within(harness_pid, Duration::from_secs(20)), "the idle agent kept running");
}

/// A reattach after a lost link is activity: its `host_reattached` record
/// and the prompt restart the idle period, so the reaper does not end the
/// reattached agent at the deadline the session had before the link was lost.
#[tokio::test]
async fn a_reattached_host_restarts_the_idle_period() {
    const IDLE_2S: &[(&str, &str)] = &[("ACPMUX_IDLE_CHILD_SECS", "2")];
    let daemon = Daemon::with_env("reidle", "approve-all", IDLE_2S);
    let session = new_session(&daemon).await;
    let prompt = json!({"sessionId": session, "prompt": [{"type": "text", "text": "hello"}]});
    let mut rpc = daemon.rpc().await;
    assert_eq!(rpc.call("session/prompt", prompt.clone()).await["stopReason"], "end_turn");
    drop(rpc);
    let first_activity = std::time::Instant::now();
    let record: acpmux::agent_host::HostRecord =
        serde_json::from_value(daemon.host_record(&session)).unwrap();
    let harness_pid = record.harness_pid.expect("harness pid") as i64;
    match acpmux::agent_host::link::connect(record, 0).await.expect("take over") {
        acpmux::agent_host::link::Connect::Ready(link, _) => drop(link),
        _ => panic!("the host refused a same-build owner"),
    }
    // Test-only fixed waits: well inside the first idle period.
    tokio::time::sleep(Duration::from_millis(1200)).await;
    let mut rpc = daemon.rpc().await;
    assert_eq!(rpc.call("session/prompt", prompt).await["stopReason"], "end_turn");
    drop(rpc);
    assert!(
        daemon.events(&session).iter().any(|e| e["kind"] == "host_reattached"),
        "the lost link was not reattached"
    );
    // Past the deadline the session had before the reattach.
    let past_first_deadline = Duration::from_millis(2600).saturating_sub(first_activity.elapsed());
    tokio::time::sleep(past_first_deadline).await;
    assert!(alive(harness_pid), "the reaper ended the agent at its pre-reattach deadline");
    // The reaper still ends it once the new idle period passes.
    assert!(
        gone_within(harness_pid, Duration::from_secs(20)),
        "the reattached agent was never reaped"
    );
}

/// The person's decision proof (`hub/person.rs` decision_proof, cx-0q7o),
/// written out so the test states the wire contract.
fn decision_proof(key: &str, parts: [&str; 5]) -> String {
    use cmux_local_auth::frontend_proof::{hex, hmac_sha256, unhex};
    let key = unhex::<32>(key).unwrap();
    let mut message = b"acpmux-person-decision-v1".to_vec();
    for part in parts {
        message.push(0);
        message.extend_from_slice(part.as_bytes());
    }
    hex(&hmac_sha256(&key, &message))
}

/// cx-0q7o: a prompt the next daemon adopts gets a new decision nonce under
/// the new daemon run. The new nonce and instance are in the log (which the
/// daemon turns into `_acpmux/permission_pending`) and in `_acpmux/info`, a
/// proof made for the old daemon run proves nothing, and a proof for the new
/// one lets a relayed allow reach the adopted agent.
#[tokio::test]
async fn an_adopted_prompt_gets_a_new_decision_nonce_that_a_relayed_allow_can_use() {
    const KEY: &str = "5c0e1f2a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6";
    let mut daemon = Daemon::keyed("perm-key", "ask", KEY);
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
    let pid = asked["msg"]["permissionId"].as_str().unwrap().to_owned();
    let old_nonce = asked["msg"]["decisionNonce"].as_str().expect("a decision nonce").to_owned();
    let old_instance = asked["msg"]["personInstance"].as_str().expect("an instance").to_owned();

    daemon.sigterm();
    drop(client);
    daemon.start();
    daemon.wait_event(&session, "host_adopted", |e| e["kind"] == "host_adopted");
    let again = daemon.wait_event(&session, "permission_reissued", |e| {
        e["kind"] == "permission_reissued" && e["msg"]["permissionId"] == json!(pid)
    });
    let nonce = again["msg"]["decisionNonce"].as_str().expect("a new nonce").to_owned();
    let instance = again["msg"]["personInstance"].as_str().expect("the new run").to_owned();
    assert_ne!(nonce, old_nonce);
    assert_ne!(instance, old_instance);

    let mut relay = daemon.rpc().await;
    let info = relay.call("_acpmux/info", json!({"sessionId": session})).await;
    let listed =
        info["pending"].as_array().unwrap().iter().find(|p| p["permissionId"] == json!(pid));
    let listed = listed.expect("the adopted prompt is listed");
    assert_eq!(listed["decisionNonce"], json!(nonce), "{info}");
    assert_eq!(listed["personInstance"], json!(instance), "{info}");

    let respond = |nonce: &str, proof: &str| {
        json!({"sessionId": session, "permissionId": pid, "optionId": "yes",
               "_meta": {"acpmux": {"decisionNonce": nonce, "personDecision": proof}}})
    };
    let stale = decision_proof(KEY, [&old_instance, &session, &pid, "yes", &old_nonce]);
    let r = relay.reply("_acpmux/permission_respond", respond(&old_nonce, &stale)).await;
    assert_eq!(r["error"]["data"]["reason"], "permission.person_required", "{r}");
    let good = decision_proof(KEY, [&instance, &session, &pid, "yes", &nonce]);
    relay.call("_acpmux/permission_respond", respond(&nonce, &good)).await;
    daemon.wait_event(&session, "the agent's answer", |e| chunk(e, "chose yes"));
}

/// As `gated_turn`, without a host record (none with agent hosts off); returns the gate too.
async fn gated_turn_without_host(daemon: &Daemon) -> (String, PathBuf, Rpc) {
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
    (session, gate, client)
}

/// Queues two prompts behind a gated turn, stops the daemon with `stop`,
/// starts it again and checks the queue came back in order, waits for the
/// turn ahead, then runs: a client that resends a queued prompt id gets its
/// real outcome, not `interrupted`. `held`: the agent outlives the daemon, so
/// its turn holds the queue after the restart; a lost agent's queue may start
/// before the attach.
async fn queue_survives_restart(daemon: &mut Daemon, stop: fn(&mut Daemon), held: bool) {
    let (session, gate, mut client) = gated_turn_without_host(daemon).await;
    for (id, text) in [("q-1", "first queued"), ("q-2", "second queued")] {
        client
            .send(
                "session/prompt",
                json!({"sessionId": session, "prompt": [{"type": "text", "text": text}], "_meta": {"acpmux": {"promptId": id}}}),
            )
            .await;
        daemon.wait_event(&session, "queued record", |e| {
            e["kind"] == "queued" && e["msg"]["promptId"] == id
        });
    }

    stop(daemon);
    drop(client);
    // Nothing queued left the queue before the daemon stopped.
    let left = daemon.events(&session).into_iter().filter(|e| {
        matches!(e["kind"].as_str(), Some("dequeued" | "user_message"))
            && e["msg"]["promptId"].as_str().is_some_and(|id| id.starts_with("q-"))
    });
    assert_eq!(left.count(), 0, "a queued prompt left the queue as the daemon stopped");
    daemon.start();

    let mut rpc = daemon.rpc().await;
    let attached = rpc.call("_acpmux/attach", json!({"sessionId": session, "limit": 0})).await;
    let queue: Vec<&str> = attached["session"]["queue"]
        .as_array()
        .expect("queue in the attach reply")
        .iter()
        .filter_map(|q| q["promptId"].as_str())
        .collect();
    if held {
        assert_eq!(queue, ["q-1", "q-2"], "the queue did not survive the restart: {attached:#}");
        assert_eq!(attached["session"]["queued"], 2, "{attached:#}");
    } else {
        // The lost turn's continuation goes first (`restart_resume.rs`), then the queue.
        let queue: Vec<&str> = queue.into_iter().skip_while(|id| id.contains("~resume-")).collect();
        assert!(["q-1", "q-2"].ends_with(&queue), "the queue came back out of order: {attached:#}");
    }

    let mut resend = daemon.rpc().await;
    let resent = resend
        .send(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": "first queued"}], "_meta": {"acpmux": {"promptId": "q-1", "resend": true}}}),
        )
        .await;
    // A hosted agent still waits on the gate; a lost one ignores it.
    let _ = std::fs::OpenOptions::new()
        .write(true)
        .custom_flags(libc::O_NONBLOCK)
        .open(&gate)
        .and_then(|mut f| std::io::Write::write_all(&mut f, b"go"));

    let reply = loop {
        let line = tokio::time::timeout(Duration::from_secs(30), resend.lines.next_line())
            .await
            .expect("the resent prompt answered in time")
            .unwrap()
            .expect("daemon closed the socket");
        let v: Value = serde_json::from_str(&line).unwrap();
        if v.get("id") == Some(&json!(resent)) {
            break v;
        }
    };
    assert_eq!(reply["result"]["stopReason"], "end_turn", "{reply:#}");

    daemon.wait_event(&session, "the second queued prompt's answer", |e| {
        chunk(e, "echo: second queued")
    });
    let events = daemon.events(&session);
    let order: Vec<&str> = events
        .iter()
        .filter(|e| e["kind"] == "user_message")
        .filter_map(|e| e["msg"]["promptId"].as_str())
        .filter(|id| id.starts_with("q-"))
        .collect();
    assert_eq!(order, ["q-1", "q-2"], "queued prompts ran out of order or twice");
    assert_eq!(events.iter().filter(|e| chunk(e, "echo: first queued")).count(), 1);
}

#[tokio::test]
async fn queued_prompts_survive_a_daemon_crash() {
    let mut daemon = Daemon::new("qcrash", "approve-all");
    queue_survives_restart(&mut daemon, Daemon::sigkill, true).await;
}

#[tokio::test]
async fn queued_prompts_survive_an_update_restart() {
    let mut daemon = Daemon::new("qterm", "approve-all");
    queue_survives_restart(&mut daemon, Daemon::sigterm, true).await;
}

/// A reboot ends the agent with the daemon: the turn in flight is lost, but
/// the prompts queued behind it still run on a new agent.
#[tokio::test]
async fn queued_prompts_survive_when_the_agent_does_not() {
    let mut daemon = Daemon::with_env("qlost", "approve-all", &[("ACPMUX_AGENT_HOSTS", "0")]);
    queue_survives_restart(&mut daemon, Daemon::sigkill, false).await;
}

/// A stop that ends the agent with the daemon (SIGTERM with agent hosts off, as Quit Everything
/// ends agents): the turn ends, and the queued prompts behind it wait for the next daemon instead
/// of starting into a daemon that refuses them.
#[tokio::test]
async fn queued_prompts_survive_a_quit_that_ends_the_agent() {
    let mut daemon = Daemon::with_env("qquit", "approve-all", &[("ACPMUX_AGENT_HOSTS", "0")]);
    queue_survives_restart(&mut daemon, Daemon::sigterm, false).await;
}

/// Two image blocks, and their attachment ids.
fn shots() -> Vec<(Value, String)> {
    use base64::Engine;
    [b"first shot".as_slice(), b"second shot".as_slice()]
        .iter()
        .enumerate()
        .map(|(i, bytes)| {
            let data = base64::engine::general_purpose::STANDARD.encode(bytes);
            let block = json!({"type": "image", "mimeType": "image/png", "data": data, "name": format!("shot{i}.png")});
            let id: String =
                <sha2::Sha256 as sha2::Digest>::digest(bytes).iter().map(|b| format!("{b:02x}")).collect();
            (block, id)
        })
        .collect()
}

/// Queues a prompt with two images behind a gated turn, edits it with `edit` (`queue_edit`
/// `update` params) if given, restarts the daemon for an update, and checks the queue that comes
/// back: its row names the images `kept` (indexes into the two), reads them back, and the agent
/// gets them after `text` when the prompt runs.
async fn queued_images_survive_restart(
    name: &str,
    edit: Option<Value>,
    text: &str,
    kept: &[usize],
) {
    let mut daemon = Daemon::new(name, "approve-all");
    let (session, gate, mut client) = gated_turn_without_host(&daemon).await;
    let shots = shots();
    client
        .send(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": "two shots"}, shots[0].0, shots[1].0], "_meta": {"acpmux": {"promptId": "q-img"}}}),
        )
        .await;
    daemon.wait_event(&session, "queued record", |e| {
        e["kind"] == "queued" && e["msg"]["promptId"] == "q-img"
    });
    if let Some(edit) = edit {
        let mut rpc = daemon.rpc().await;
        let mut params = json!({"sessionId": session, "promptId": "q-img", "op": "update"});
        params.as_object_mut().unwrap().extend(edit.as_object().unwrap().clone());
        let edited = rpc.call("_acpmux/queue_edit", params).await;
        assert_eq!(edited["ok"], true, "{edited}");
        drop(rpc);
    }

    daemon.sigterm();
    drop(client);
    daemon.start();

    let mut rpc = daemon.rpc().await;
    let attached = rpc.call("_acpmux/attach", json!({"sessionId": session, "limit": 0})).await;
    let names: Vec<Value> = kept
        .iter()
        .map(
            |&i| json!({"id": shots[i].1, "mimeType": "image/png", "name": format!("shot{i}.png")}),
        )
        .collect();
    assert_eq!(attached["session"]["queue"][0]["prompt"], text, "{attached:#}");
    assert_eq!(attached["session"]["queue"][0]["images"], json!(names), "{attached:#}");
    for &i in kept {
        let read =
            rpc.call("_acpmux/attachment", json!({"sessionId": session, "id": shots[i].1})).await;
        assert_eq!(read["data"], shots[i].0["data"], "{read}");
    }

    let _ = std::fs::OpenOptions::new()
        .write(true)
        .custom_flags(libc::O_NONBLOCK)
        .open(&gate)
        .and_then(|mut f| std::io::Write::write_all(&mut f, b"go"));
    let images: String = kept.iter().map(|&i| format!(" image:{}", shots[i].1)).collect();
    let echo = format!("echo: {text}{images}");
    daemon.wait_event(&session, "the queued prompt's answer", |e| chunk(e, &echo));
}

/// A queued prompt's images come back with the queue after an update restart (Leo, 2026-10-21):
/// its row lists them and reads them back, and the agent gets them when it runs.
#[tokio::test]
async fn a_queued_prompts_images_survive_an_update_restart() {
    queued_images_survive_restart("qimg", None, "two shots", &[0, 1]).await;
}

/// An edited queued prompt comes back after an update restart with the images its edit kept:
/// a text edit keeps both, and an edit that names one keeps that one.
#[tokio::test]
async fn an_edited_queued_prompts_images_survive_an_update_restart() {
    let text = Some(json!({"text": "two shots, edited"}));
    queued_images_survive_restart("qimg-text", text, "two shots, edited", &[0, 1]).await;
    let second = shots()[1].1.clone();
    let one = Some(json!({"text": "the second shot", "images": [second]}));
    queued_images_survive_restart("qimg-one", one, "the second shot", &[1]).await;
}

/// A queue reordered and edited (`_acpmux/queue_edit`) comes back that way after a crash.
#[tokio::test]
async fn queue_ops_edits_survive_a_daemon_crash() {
    let mut daemon = Daemon::new("qedit", "approve-all");
    let (session, gate, mut client) = gated_turn_without_host(&daemon).await;
    for (id, text) in [("q-1", "one"), ("q-2", "two")] {
        client
            .send(
                "session/prompt",
                json!({"sessionId": session, "prompt": [{"type": "text", "text": text}], "_meta": {"acpmux": {"promptId": id}}}),
            )
            .await;
        daemon.wait_event(&session, "queued record", |e| {
            e["kind"] == "queued" && e["msg"]["promptId"] == id
        });
    }
    let mut rpc = daemon.rpc().await;
    let edit = |op: &str, id: &str, extra: Value| {
        let mut p = json!({"sessionId": session, "promptId": id, "op": op});
        p.as_object_mut().unwrap().extend(extra.as_object().unwrap().clone());
        p
    };
    rpc.call("_acpmux/queue_edit", edit("move", "q-2", json!({"index": 0}))).await;
    rpc.call("_acpmux/queue_edit", edit("update", "q-1", json!({"text": "one edited"}))).await;

    daemon.sigkill();
    drop((client, rpc));
    daemon.start();

    let mut rpc = daemon.rpc().await;
    let attached = rpc.call("_acpmux/attach", json!({"sessionId": session, "limit": 0})).await;
    let queue = attached["session"]["queue"].as_array().expect("queue").clone();
    let ids: Vec<&str> = queue.iter().filter_map(|q| q["promptId"].as_str()).collect();
    assert_eq!(ids, ["q-2", "q-1"], "the order did not survive: {attached:#}");
    assert_eq!(queue[1]["prompt"], "one edited", "the edit did not survive: {attached:#}");
    std::fs::write(&gate, b"go").unwrap();
    daemon.wait_event(&session, "the edited prompt's answer", |e| chunk(e, "echo: one edited"));
    let events = daemon.events(&session);
    let order: Vec<&str> = events
        .iter()
        .filter(|e| e["kind"] == "user_message")
        .filter_map(|e| e["msg"]["promptId"].as_str())
        .filter(|id| id.starts_with("q-"))
        .collect();
    assert_eq!(order, ["q-2", "q-1"]);
}

/// A queued prompt that left the queue for its turn (`dequeued`) when the daemon died, before
/// its turn started, runs once after the restart: a client that resends it gets its real
/// outcome, not `interrupted`. `ACPMUX_TEST_EXIT_AFTER_DEQUEUE` stops the first daemon there.
#[tokio::test]
async fn a_dequeued_prompt_survives_a_daemon_crash() {
    let seam = [("ACPMUX_TEST_EXIT_AFTER_DEQUEUE", "1")];
    let mut daemon = Daemon::with_env("qdeq", "approve-all", &seam);
    let (session, gate, mut client) = gated_turn_without_host(&daemon).await;
    client
        .send(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": "after the gate"}], "_meta": {"acpmux": {"promptId": "q-1"}}}),
        )
        .await;
    daemon.wait_event(&session, "queued record", |e| {
        e["kind"] == "queued" && e["msg"]["promptId"] == "q-1"
    });
    // The gated turn ends, q-1 leaves the queue for its turn, and the daemon stops there.
    std::fs::write(&gate, b"go").unwrap();
    daemon.wait_exit();
    drop(client);
    let of_q1 = |events: &[Value], kind: &str| {
        events.iter().filter(|e| e["kind"] == kind && e["msg"]["promptId"] == "q-1").count()
    };
    let events = daemon.events(&session);
    assert_eq!(of_q1(&events, "dequeued"), 1, "q-1 never left the queue: {events:#?}");
    assert_eq!(of_q1(&events, "turn_started"), 0, "q-1's turn started before the stop");

    daemon.env.clear();
    daemon.start();
    let mut resend = daemon.rpc().await;
    let resent = resend
        .send(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": "after the gate"}], "_meta": {"acpmux": {"promptId": "q-1", "resend": true}}}),
        )
        .await;
    let reply = loop {
        let line = tokio::time::timeout(Duration::from_secs(30), resend.lines.next_line())
            .await
            .expect("the resent prompt answered in time")
            .unwrap()
            .expect("daemon closed the socket");
        let v: Value = serde_json::from_str(&line).unwrap();
        if v.get("id") == Some(&json!(resent)) {
            break v;
        }
    };
    assert_eq!(reply["result"]["stopReason"], "end_turn", "q-1 never ran: {reply:#}");
    daemon.wait_event(&session, "q-1's answer", |e| chunk(e, "echo: after the gate"));
    let events = daemon.events(&session);
    assert_eq!(events.iter().filter(|e| chunk(e, "echo: after the gate")).count(), 1);
    assert_eq!(of_q1(&events, "turn_started"), 1, "q-1 ran more than once");
}

/// A restarted daemon whose chat-log load fails still answers. `_acpmux/attach` and prompts wait
/// for that load (#22916); a load that panicked never said it was done, so they waited forever.
/// `ACPMUX_TEST_PANIC_IN_LOAD_LOGS` makes the second daemon's load panic.
#[tokio::test]
async fn attach_and_prompts_survive_a_failed_log_load() {
    let mut daemon = Daemon::new("lpanic", "approve-all");
    let session = new_session(&daemon).await;
    daemon.sigterm();
    daemon.env = vec![("ACPMUX_TEST_PANIC_IN_LOAD_LOGS".into(), "1".into())];
    daemon.start();

    let mut rpc = daemon.rpc().await;
    // `Rpc::reply` waits 30 s at most: a hang fails here.
    let attached = rpc.call("_acpmux/attach", json!({"sessionId": session, "limit": 0})).await;
    assert!(
        attached["session"]["queue"].is_array(),
        "attach answered without the session: {attached:#}"
    );
    let answered = rpc
        .call("session/prompt", json!({"sessionId": session, "prompt": [{"type": "text", "text": "after the failed load"}]}))
        .await;
    assert_eq!(answered["stopReason"], "end_turn", "the prompt did not run: {answered:#}");
    daemon.wait_event(&session, "the prompt's answer", |e| chunk(e, "echo: after the failed load"));
}

/// A message's provenance (`_meta.acpmux.provenance`, cx-55d27) stays with its queued prompt
/// across a daemon crash: the rebuilt prompt's `user_message` still names the agent that sent it.
#[tokio::test]
async fn a_queued_prompt_keeps_its_provenance_across_a_daemon_crash() {
    let mut daemon = Daemon::new("qprov", "approve-all");
    let (session, gate, mut client) = gated_turn_without_host(&daemon).await;
    let provenance = json!({"kind": "agent_message", "from": "acp:sender-1", "to": format!("acp:{session}"),
                            "msgId": "msg-1", "threadId": "thread-1"});
    client
        .send(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": "from builder"}],
                   "_meta": {"acpmux": {"promptId": "q-prov", "provenance": provenance}}}),
        )
        .await;
    let queued = daemon.wait_event(&session, "queued record", |e| {
        e["kind"] == "queued" && e["msg"]["promptId"] == "q-prov"
    });
    assert_eq!(queued["msg"]["_meta"]["provenance"], provenance, "{queued:#}");

    daemon.sigkill();
    drop(client);
    daemon.start();
    let mut rpc = daemon.rpc().await;
    let attached = rpc.call("_acpmux/attach", json!({"sessionId": session, "limit": 0})).await;
    assert_eq!(attached["session"]["queued"], 1, "the queue did not survive: {attached:#}");
    std::fs::write(&gate, b"go").unwrap();
    let ran = daemon.wait_event(&session, "the rebuilt prompt's user_message", |e| {
        e["kind"] == "user_message" && e["msg"]["promptId"] == "q-prov"
    });
    assert_eq!(ran["msg"]["_meta"]["provenance"], provenance, "{ran:#}");
}

/// A narrower policy set on a chat whose agent runs in a host the restarted daemon has not
/// reached yet moves that agent out of full access. Its host is running, so the chat is not
/// stopped: saving the mode for the next start never reached the agent, because reaching the
/// host again (`readopt`) replays nothing, and the agent kept `bypassPermissions`.
#[tokio::test]
async fn a_narrower_policy_reaches_an_agent_whose_host_is_not_adopted_yet() {
    let mut daemon = Daemon::new("polhost", "approve-all");
    daemon.sigterm();
    let control_log = daemon.home.join("control.log");
    std::fs::write(
        daemon.home.join("config.json"),
        json!({"harnesses": {"cmux": {"argv": ["python3", FAKE_CLAUDE], "kind": "claude-stdio", "env": {"FAKE_CLAUDE_CONTROL_LOG": control_log}}}, "defaultHarness": "cmux", "permissionPolicy": "approve-all", "defaultPermissionMode": "fullAccess"}).to_string(),
    )
    .unwrap();
    daemon.start();
    let session = new_session(&daemon).await;
    let mut rpc = daemon.rpc().await;
    let reply = rpc
        .call(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": "hi"}]}),
        )
        .await;
    assert_eq!(reply["stopReason"], "end_turn", "{reply}");
    let harness = daemon.host_record(&session)["harness_pid"].as_i64().unwrap();

    daemon.sigterm();
    drop(rpc);
    assert!(alive(harness), "the agent did not outlive the daemon");
    let meta: Value = serde_json::from_slice(
        &std::fs::read(daemon.home.join("sessions").join(&session).join("session.json")).unwrap(),
    )
    .unwrap();
    assert_eq!(meta["modes"]["currentModeId"], "bypassPermissions", "{meta:#}");
    let _ = std::fs::remove_file(&control_log);
    // The host is adopted only after the chat logs load: the policy comes before that.
    daemon.env = vec![("ACPMUX_TEST_DELAY_LOAD_LOGS_MS".into(), "3000".into())];
    daemon.start();
    let mut rpc = daemon.rpc().await;
    rpc.call("_acpmux/set_policy", json!({"sessionId": session, "policy": "ask"})).await;
    let reply = rpc
        .call(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": "hi"}]}),
        )
        .await;
    assert_eq!(reply["stopReason"], "end_turn", "{reply}");
    assert!(alive(harness), "a second agent replaced the hosted one");
    let sent = std::fs::read_to_string(&control_log).unwrap_or_default();
    assert!(
        sent.lines().any(|l| l == "set_permission_mode"),
        "the hosted agent was never moved out of full access: {sent:?}"
    );
}

/// `_acpmux/info` with `waitLogs: false` answers while a restarted daemon still reads the chat
/// logs, and says so (`logsLoading`). The app daemon's callers give info 2 s (cmux-tui-core
/// `agent_message_acpmux.rs`, `agent_session_link.rs`) and read only what the session list
/// holds; a large log store takes longer to read. Without the flag info still waits for the
/// chat's log (#22916), which it reads itself instead of waiting for every other chat's
/// (`hub/log_load.rs`). `ACPMUX_TEST_DELAY_LOAD_LOGS_MS` holds the second daemon's log load.
#[tokio::test]
async fn info_answers_while_the_chat_logs_load() {
    const HOLD: Duration = Duration::from_secs(6);
    let mut daemon = Daemon::new("ilogs", "approve-all");
    let session = new_session(&daemon).await;
    daemon.sigterm();
    daemon.env = vec![("ACPMUX_TEST_DELAY_LOAD_LOGS_MS".into(), HOLD.as_millis().to_string())];
    let started = Instant::now();
    daemon.start();

    let mut rpc = daemon.rpc().await;
    let early = tokio::time::timeout(
        Duration::from_secs(2),
        rpc.call("_acpmux/info", json!({"sessionId": session, "waitLogs": false})),
    )
    .await
    .expect("_acpmux/info {waitLogs: false} answered within 2 s while the logs load");
    assert_eq!(early["sessionId"], session.as_str(), "{early:#}");
    assert_eq!(early["logsLoading"], true, "info did not say the logs are loading: {early:#}");

    let waited = rpc.call("_acpmux/info", json!({"sessionId": session})).await;
    assert!(started.elapsed() < HOLD, "info waited for the whole log load: {waited:#}");
    assert_eq!(waited["logsLoading"], false, "info answered before its log was read: {waited:#}");
}

/// Review 31 of #23322: a switch into full access that MDM's off overtook stops the agent within a
/// bound, also when its host never takes the terminate (its link stopped reading; the debug seam
/// `ACPMUX_TEST_STALL_HOST_TERMINATE`). The host is then ended by its nonce, and the switch answers.
#[tokio::test]
async fn a_full_access_stop_is_bounded_when_the_host_never_takes_the_terminate() {
    const KEY: &str = "7a0e1f2a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6";
    let mut daemon =
        Daemon::with_env("stallterm", "ask", &[("ACPMUX_TEST_STALL_HOST_TERMINATE", "1")]);
    daemon.sigterm();
    daemon.key = Some(KEY.to_owned());
    let fake = json!({"argv": ["python3", FAKE], "env": {"FAKE_PLAN_MODE": "1",
                      "FAKE_FULL_ACCESS": "1", "FAKE_SET_MODE_DELAY_MS": "1500"}});
    let config =
        json!({"harnesses": {"fake": fake}, "defaultHarness": "fake", "permissionPolicy": "ask"});
    std::fs::write(daemon.home.join("config.json"), config.to_string()).unwrap();
    daemon.start();
    let session = new_session(&daemon).await;
    // The person: only they set a mode that does not ask (`hub/person.rs`).
    let mut rpc = daemon.rpc().await;
    let init = rpc.call("initialize", json!({"protocolVersion": 1})).await;
    let challenge = &init["_meta"]["acpmux"]["personChallenge"];
    let proof = acpmux::hub::person::person_proof(
        KEY,
        acpmux::hub::person::TRANSPORT_UNIX,
        challenge["nonce"].as_str().unwrap_or_else(|| panic!("{init}")),
        challenge["connection"].as_str().unwrap(),
    )
    .unwrap();
    let proven = rpc.call("_acpmux/person_prove", json!({"proof": proof})).await;
    assert_eq!(proven["person"], true, "{proven}");
    let prompt = json!({"sessionId": session, "prompt": [{"type": "text", "text": "hi"}]});
    rpc.call("session/prompt", prompt).await;
    rpc.call("session/set_mode", json!({"sessionId": session, "modeId": "build"})).await;
    let harness_pid = daemon.host_record(&session)["harness_pid"].as_i64().unwrap();

    // The switch passes both checks, then waits 1.5 s on the harness; the push lands then.
    let switch = tokio::spawn(async move {
        rpc.reply("session/set_mode", json!({"sessionId": session, "modeId": "full-access"})).await
    });
    tokio::time::sleep(Duration::from_millis(400)).await;
    let off = json!({"enabled": true, "discovery": false, "roots": [], "managedRoots": [],
                     "allowFullAccess": false, "allowFullAccessManaged": true});
    let pushed = daemon.rpc().await.call("_acpmux/chat_settings", off).await;
    assert_eq!(pushed["applied"], true, "{pushed}");
    let r = tokio::time::timeout(Duration::from_secs(20), switch)
        .await
        .expect("the stop waited on a host that never takes the terminate")
        .unwrap();
    assert_eq!(r["error"]["data"]["reason"], "full_access_off", "{r}");
    assert!(
        gone_within(harness_pid, Duration::from_secs(10)),
        "the full-access agent ran on after its host ignored the terminate"
    );
}

/// MDM's off as a push recorded it in start-mode.json, for the next daemon to load.
fn record_mdm_off(daemon: &Daemon) {
    let state = daemon.home.join("start-mode.json");
    let mut recorded: Value = std::fs::read(&state)
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_else(|| json!({}));
    recorded["fullAccessManaged"] = json!(false);
    std::fs::write(&state, recorded.to_string()).unwrap();
}

/// The settings push that turns full access off as MDM forces it.
fn mdm_off_push() -> Value {
    json!({"enabled": true, "discovery": false, "roots": [], "managedRoots": [],
           "allowFullAccess": false, "allowFullAccessManaged": true})
}

/// A daemon whose profile pins full access (`--yolo`), with `env`, and one chat that ran a turn
/// on it, stopped with its host left running: the daemon, the chat and its host record.
async fn left_pinned(tag: &str, env: &[(&str, &str)]) -> (Daemon, String, Value) {
    let mut daemon = Daemon::with_env(tag, "ask", env);
    daemon.sigterm();
    let config = json!({"harnesses": {"fake": {"argv": ["python3", FAKE, "--yolo"]}},
                        "defaultHarness": "fake", "permissionPolicy": "ask"});
    std::fs::write(daemon.home.join("config.json"), config.to_string()).unwrap();
    daemon.start();
    let session = new_session(&daemon).await;
    let prompt = json!({"sessionId": session, "prompt": [{"type": "text", "text": "hi"}]});
    let mut rpc = daemon.rpc().await;
    rpc.call("session/prompt", prompt).await;
    let host = daemon.host_record(&session);
    daemon.sigterm();
    drop(rpc);
    assert!(alive(host["harness_pid"].as_i64().unwrap()), "SIGTERM ended the agent");
    (daemon, session, host)
}

/// #23322 (claude-sr2: "an MDM-managed value is an upper bound the user can't override"): a host
/// a restart left running in full access (its profile pins `--yolo`) is not reached again when the
/// next daemon starts with MDM forcing `sessions.allowFullAccess` off (start-mode.json, as a push
/// recorded it): its agent ends and the chat is refused.
#[tokio::test]
async fn a_retained_full_access_host_ends_once_mdm_turns_full_access_off() {
    let (mut daemon, session, host) = left_pinned("mdmoff", &[]).await;
    let harness_pid = host["harness_pid"].as_i64().unwrap();
    record_mdm_off(&daemon);
    daemon.start();
    // Ended at start, before any prompt: startup adoption never resumes it.
    assert!(
        gone_within(harness_pid, Duration::from_secs(10)),
        "the next daemon adopted the full-access agent under the managed off"
    );
    let mut rpc = daemon.rpc().await;
    let prompt = json!({"sessionId": session, "prompt": [{"type": "text", "text": "hi"}]});
    let r = rpc.reply("session/prompt", prompt).await;
    assert_eq!(r["error"]["data"]["reason"], "full_access_off", "{r}");
}

/// #23322 review: the same, for a host whose record this build cannot read (another record
/// version): it is not adopted, and under the managed off it ends too (its nonce proves it).
#[tokio::test]
async fn an_unadoptable_full_access_host_ends_once_mdm_turns_full_access_off() {
    let (mut daemon, session, host) = left_pinned("mdmoffbad", &[]).await;
    let record = daemon.home.join("hosts").join(format!("{session}.json"));
    let mut unreadable: Value = serde_json::from_slice(&std::fs::read(&record).unwrap()).unwrap();
    unreadable["record_version"] = json!(99);
    std::fs::write(&record, unreadable.to_string()).unwrap();
    record_mdm_off(&daemon);
    daemon.start();
    assert!(
        gone_within(host["harness_pid"].as_i64().unwrap(), Duration::from_secs(10)),
        "the unadoptable full-access agent ran on under the managed off"
    );
}

/// Review 44 of #23322: the argv a start runs is on disk before its agent starts. A chat whose
/// agent ended starts again, for a model pick, on a profile a config reload pinned to `--yolo`;
/// the daemon dies while that agent initializes. Under MDM's off the next daemon ends that host
/// instead of adopting it on the argv the chat was created with. A cold start's folder check
/// (`revive_folder`) saves the chat too, but only when its git read answers within 2 s.
#[tokio::test]
async fn a_host_a_daemon_left_while_it_started_ends_under_mdm_off_by_the_argv_it_ran() {
    let mut daemon = Daemon::new("mdmspawn", "ask");
    let session = new_session(&daemon).await;
    let first = daemon.host_record(&session);
    let mut rpc = daemon.rpc().await;
    // The profile is pinned to full access now; its agent takes 4 s to initialize.
    let pinned =
        json!({"argv": ["python3", FAKE, "--yolo"], "env": {"FAKE_INIT_DELAY_MS": "4000"}});
    let config =
        json!({"harnesses": {"fake": pinned}, "defaultHarness": "fake", "permissionPolicy": "ask"});
    std::fs::write(daemon.home.join("config.json"), config.to_string()).unwrap();
    rpc.call("_acpmux/reload_config", json!({})).await;
    // The first agent ends on its own, under a live daemon.
    for pid in [first["harness_pid"].as_i64(), first["host_pid"].as_i64()].into_iter().flatten() {
        // SAFETY: process groups this test's daemon created (its host record).
        unsafe { libc::killpg(pid as i32, libc::SIGKILL) };
        assert!(gone_within(pid, Duration::from_secs(10)), "the first agent did not end");
    }
    tokio::time::sleep(Duration::from_millis(500)).await;
    // A start no prompt asks for (a model pick), so no turn bookkeeping saves the chat first.
    rpc.send("session/set_model", json!({"sessionId": session, "modelId": "m2"})).await;
    // The new host runs; the daemon dies before the agent answers initialize.
    let record = daemon.home.join("hosts").join(format!("{session}.json"));
    let deadline = Instant::now() + Duration::from_secs(3);
    let started = loop {
        let host: Option<Value> =
            std::fs::read(&record).ok().and_then(|b| serde_json::from_slice(&b).ok());
        // The second agent's record: the first one's may still be on disk.
        if let Some(host) =
            host.filter(|h| h["harness_pid"].is_i64() && h["harness_pid"] != first["harness_pid"])
        {
            break host;
        }
        assert!(Instant::now() < deadline, "the second agent never started");
        tokio::time::sleep(Duration::from_millis(50)).await;
    };
    let harness_pid = started["harness_pid"].as_i64().unwrap();
    daemon.sigkill();
    drop(rpc);
    assert!(alive(harness_pid), "the daemon's death ended the agent");
    // What the next daemon reads: the argv that agent runs.
    let saved = daemon.home.join("sessions").join(&session).join("session.json");
    let meta: Value = serde_json::from_slice(&std::fs::read(&saved).unwrap()).unwrap();
    assert!(
        meta["spawnArgv"].as_array().is_some_and(|a| a.iter().any(|v| v == "--yolo")),
        "the argv the agent runs was not saved before it started: {}",
        meta["spawnArgv"]
    );

    record_mdm_off(&daemon);
    daemon.start();
    assert!(
        gone_within(harness_pid, Duration::from_secs(10)),
        "the next daemon adopted the --yolo agent on the argv its chat was created with"
    );
}

/// Review 51 of #23322: a host a restart left in full access whose end by its nonce fails (the
/// debug seam `ACPMUX_TEST_HOST_END_FAILS`) is never reached again under MDM's off. What says it
/// runs in full access stays, and each prompt is refused while that host may still run.
#[tokio::test]
async fn a_full_access_host_whose_end_failed_is_never_reached_under_mdm_off() {
    let env = [("ACPMUX_TEST_HOST_END_FAILS", "1")];
    let (mut daemon, session, host) = left_pinned("mdmendfail", &env).await;
    record_mdm_off(&daemon);
    daemon.start();
    let mut rpc = daemon.rpc().await;
    let prompt = json!({"sessionId": session, "prompt": [{"type": "text", "text": "hi"}]});
    for attempt in 0..2 {
        let r = rpc.reply("session/prompt", prompt.clone()).await;
        assert_eq!(
            r["error"]["data"]["reason"], "full_access_off",
            "attempt {attempt}: a full-access agent whose end failed was reached again: {r}"
        );
    }
    assert!(alive(host["harness_pid"].as_i64().unwrap()), "the seam did not keep the host running");
    for pid in [host["harness_pid"].as_i64(), host["host_pid"].as_i64()].into_iter().flatten() {
        // SAFETY: process groups this test's daemon created (its host record).
        unsafe { libc::killpg(pid as i32, libc::SIGKILL) };
    }
}

/// Review 66 of #23322: an end that cannot read the host records (the debug seam
/// `ACPMUX_TEST_HOST_RECORDS_FAIL_FILE`) has not proven the host gone, so what says it runs in
/// full access stays and the next off push ends it. The harness moved its mode option to full
/// access, which an end that counts as done scrubs.
#[tokio::test]
async fn an_end_that_could_not_read_the_host_records_is_tried_again() {
    let flag = std::env::temp_dir().join(format!("amd-recfail-{}", std::process::id()));
    let flag_env = flag.to_string_lossy().into_owned();
    let env = [
        ("ACPMUX_TEST_STALL_HOST_TERMINATE", "1"),
        ("ACPMUX_TEST_HOST_RECORDS_FAIL_FILE", flag_env.as_str()),
    ];
    let mut daemon = Daemon::with_env("mdmrecfail", "ask", &env);
    daemon.sigterm();
    let fake = json!({"argv": ["python3", FAKE], "env": {"FAKE_MODE_OPTION": "1"}});
    let config =
        json!({"harnesses": {"fake": fake}, "defaultHarness": "fake", "permissionPolicy": "ask"});
    std::fs::write(daemon.home.join("config.json"), config.to_string()).unwrap();
    daemon.start();
    let session = new_session(&daemon).await;
    let mut rpc = daemon.rpc().await;
    let moved = json!({"sessionId": session,
                       "prompt": [{"type": "text", "text": "set-mode-option: full-access"}]});
    rpc.call("session/prompt", moved).await;
    let harness_pid = daemon.host_record(&session)["harness_pid"].as_i64().unwrap();
    std::fs::write(&flag, "").unwrap();
    let pushed = rpc.call("_acpmux/chat_settings", mdm_off_push()).await;
    assert_eq!(pushed["applied"], true, "{pushed}");
    std::fs::remove_file(&flag).unwrap();
    assert!(alive(harness_pid), "the seams did not keep the first end from working");
    let pushed = rpc.call("_acpmux/chat_settings", mdm_off_push()).await;
    assert_eq!(pushed["applied"], true, "{pushed}");
    assert!(
        gone_within(harness_pid, Duration::from_secs(10)),
        "an end that could not read the host records counted the host as gone"
    );
}

/// Review 1 of #26034: an agent MDM's off ended was ended on purpose: its chat is idle, not
/// disconnected, and its next prompt starts an agent under the bound.
#[tokio::test]
async fn a_chat_whose_agent_mdm_ended_is_idle() {
    let mut daemon = Daemon::new("mdmidle", "ask");
    daemon.sigterm();
    let config = json!({"harnesses": {"fake": {"argv": ["python3", FAKE, "--yolo"]}},
                        "defaultHarness": "fake", "permissionPolicy": "ask"});
    std::fs::write(daemon.home.join("config.json"), config.to_string()).unwrap();
    daemon.start();
    let session = new_session(&daemon).await;
    let mut rpc = daemon.rpc().await;
    let prompt = json!({"sessionId": session, "prompt": [{"type": "text", "text": "hi"}]});
    rpc.call("session/prompt", prompt).await;
    let harness_pid = daemon.host_record(&session)["harness_pid"].as_i64().unwrap();
    let pushed = rpc.call("_acpmux/chat_settings", mdm_off_push()).await;
    assert_eq!(pushed["applied"], true, "{pushed}");
    assert!(gone_within(harness_pid, Duration::from_secs(10)), "MDM's off did not end the agent");
    // The agent's exit is read after the push returns.
    tokio::time::sleep(Duration::from_millis(1000)).await;
    let summary = rpc.call("_acpmux/sessions", json!({})).await;
    let entry = summary["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|s| s["sessionId"] == session.as_str())
        .cloned()
        .expect("the chat is kept");
    assert_eq!(entry["status"], "idle", "{entry}");
}

/// Review 2 of #26034: a turn in progress when MDM's off ends its agent ends as a stop's does: no
/// continuation runs, and the chat is left idle, not disconnected.
#[tokio::test]
async fn a_turn_mdm_ended_leaves_its_chat_idle() {
    let mut daemon = Daemon::new("mdmturnidle", "ask");
    daemon.sigterm();
    let config = json!({"harnesses": {"fake": {"argv": ["python3", FAKE, "--yolo"]}},
                        "defaultHarness": "fake", "permissionPolicy": "ask"});
    std::fs::write(daemon.home.join("config.json"), config.to_string()).unwrap();
    daemon.start();
    let session = new_session(&daemon).await;
    let mut rpc = daemon.rpc().await;
    let mut turn = daemon.rpc().await;
    let held = json!({"sessionId": session,
                      "prompt": [{"type": "text", "text": "hang"}]});
    let prompt = tokio::spawn(async move { turn.reply("session/prompt", held).await });
    tokio::time::sleep(Duration::from_millis(1500)).await;
    let harness_pid = daemon.host_record(&session)["harness_pid"].as_i64().unwrap();
    let pushed = rpc.call("_acpmux/chat_settings", mdm_off_push()).await;
    assert_eq!(pushed["applied"], true, "{pushed}");
    assert!(gone_within(harness_pid, Duration::from_secs(10)), "MDM's off did not end the agent");
    let answered = tokio::time::timeout(Duration::from_secs(15), prompt).await;
    assert!(answered.is_ok(), "the turn waited on after MDM ended its agent");
    // A continuation of the cut turn would have started by now.
    tokio::time::sleep(Duration::from_millis(3000)).await;
    let summary = rpc.call("_acpmux/sessions", json!({})).await;
    let entry = summary["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|s| s["sessionId"] == session.as_str())
        .cloned()
        .expect("the chat is kept");
    assert_eq!(entry["status"], "idle", "{entry}");
}

/// The chat's status in the daemon's session list.
async fn status_of(daemon: &Daemon, session: &str) -> Value {
    let mut rpc = daemon.rpc().await;
    let summary = rpc.call("_acpmux/sessions", json!({})).await;
    let entry = summary["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|s| s["sessionId"] == session)
        .cloned()
        .expect("the chat is kept");
    entry["status"].clone()
}

/// Review 3 of #26034: a turn MDM's off cut is not run again on the chat's fallback profile, as
/// a stopped one is not.
#[tokio::test]
async fn a_turn_mdm_ended_is_not_failed_over() {
    let mut daemon = Daemon::new("mdmnofailover", "ask");
    daemon.sigterm();
    let fake = json!({"argv": ["python3", FAKE, "--yolo"], "fallback": "fake-pool"});
    let config = json!({"harnesses": {"fake": fake, "fake-pool": {"argv": ["python3", FAKE]}},
                        "defaultHarness": "fake", "permissionPolicy": "ask"});
    std::fs::write(daemon.home.join("config.json"), config.to_string()).unwrap();
    daemon.start();
    let session = new_session(&daemon).await;
    let mut rpc = daemon.rpc().await;
    let mut turn = daemon.rpc().await;
    let held = json!({"sessionId": session,
                      "prompt": [{"type": "text", "text": "hang"}]});
    let prompt = tokio::spawn(async move { turn.reply("session/prompt", held).await });
    tokio::time::sleep(Duration::from_millis(1500)).await;
    let harness_pid = daemon.host_record(&session)["harness_pid"].as_i64().unwrap();
    let pushed = rpc.call("_acpmux/chat_settings", mdm_off_push()).await;
    assert_eq!(pushed["applied"], true, "{pushed}");
    assert!(gone_within(harness_pid, Duration::from_secs(10)), "MDM's off did not end the agent");
    let answered = tokio::time::timeout(Duration::from_secs(15), prompt).await;
    let failovers: Vec<Value> =
        daemon.events(&session).into_iter().filter(|e| e["kind"] == "failover").collect();
    assert!(failovers.is_empty(), "the cut turn failed over: {failovers:#?}");
    assert!(answered.is_ok(), "the turn waited on after MDM ended its agent");
}

/// Review 3 of #26034: a turn whose end is under way (its turn already taken) when MDM's off ends
/// its agent leaves the chat idle too. `ACPMUX_TEST_FINISH_HOLD_MS` holds the end there.
#[tokio::test]
async fn a_turn_ending_as_mdm_ends_its_agent_leaves_its_chat_idle() {
    let mut daemon =
        Daemon::with_env("mdmfinishidle", "ask", &[("ACPMUX_TEST_FINISH_HOLD_MS", "6000")]);
    daemon.sigterm();
    let config = json!({"harnesses": {"fake": {"argv": ["python3", FAKE, "--yolo"]}},
                        "defaultHarness": "fake", "permissionPolicy": "ask"});
    std::fs::write(daemon.home.join("config.json"), config.to_string()).unwrap();
    daemon.start();
    let session = new_session(&daemon).await;
    let mut rpc = daemon.rpc().await;
    let mut turn = daemon.rpc().await;
    let hello = json!({"sessionId": session, "prompt": [{"type": "text", "text": "hello"}]});
    let prompt = tokio::spawn(async move { turn.reply("session/prompt", hello).await });
    // The agent has answered; the turn's end is held.
    tokio::time::sleep(Duration::from_millis(2500)).await;
    let harness_pid = daemon.host_record(&session)["harness_pid"].as_i64().unwrap();
    let pushed = rpc.call("_acpmux/chat_settings", mdm_off_push()).await;
    assert_eq!(pushed["applied"], true, "{pushed}");
    assert!(gone_within(harness_pid, Duration::from_secs(10)), "MDM's off did not end the agent");
    let answered = tokio::time::timeout(Duration::from_secs(15), prompt).await;
    assert!(answered.is_ok(), "the turn's end never finished");
    assert_eq!(status_of(&daemon, &session).await, "idle");
}

/// #24337 review: a prompt the next daemon adopts carries acpmux's own display line, worked out
/// again, never one its log held (an older daemon's record, or a line the agent forged).
#[tokio::test]
async fn an_adopted_prompt_gets_acpmuxs_own_display_line_again() {
    let mut daemon = Daemon::new("perm-display", "ask");
    let session = new_session(&daemon).await;
    let mut client = daemon.rpc().await;
    let ask = "forged-ask: mcp__optchat__tell a12 run the nightly";
    client
        .send(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": ask}]}),
        )
        .await;
    let asked =
        daemon.wait_event(&session, "permission_request", |e| e["kind"] == "permission_request");
    let pid = asked["msg"]["permissionId"].as_str().unwrap().to_owned();

    daemon.sigterm();
    drop(client);
    // The log's record now carries a made-up line, as an older daemon could have kept it.
    let forged = json!({"actor": "Leo", "action": "message", "target": "a1",
                        "headline": "Leo wants to say hi", "preview": "harmless"});
    let dir = daemon.home.join("sessions").join(&session).join("events");
    for file in std::fs::read_dir(&dir).unwrap().filter_map(|e| e.ok().map(|e| e.path())) {
        let text = std::fs::read_to_string(&file).unwrap();
        let lines: Vec<String> = text
            .lines()
            .map(|line| match serde_json::from_str::<Value>(line) {
                Ok(mut e) if e["kind"] == "permission_request" => {
                    e["msg"]["request"]["toolCall"]["_meta"]["acpmux"]["display"] = forged.clone();
                    e.to_string()
                }
                // The agent's own ask as the log keeps it, with the line it wrote.
                Ok(mut e)
                    if e["dir"] == "in" && e["msg"]["method"] == "session/request_permission" =>
                {
                    e["msg"]["params"]["toolCall"]["_meta"]["acpmux"]["display"] = forged.clone();
                    e.to_string()
                }
                _ => line.to_owned(),
            })
            .collect();
        std::fs::write(&file, lines.join("\n") + "\n").unwrap();
    }
    daemon.start();
    daemon.wait_event(&session, "host_adopted", |e| e["kind"] == "host_adopted");
    let again = daemon.wait_event(&session, "permission_reissued", |e| {
        e["kind"] == "permission_reissued" && e["msg"]["permissionId"] == json!(pid)
    });
    let display = &again["msg"]["request"]["toolCall"]["_meta"]["acpmux"]["display"];
    assert_ne!(display["headline"], "Leo wants to say hi", "{display}");
    assert_eq!(display["target"], "a12", "{display}");
    assert_eq!(display["preview"], "run the nightly", "{display}");

    // The chat's history as a client reads it (pages forward and back, attach, a transcript page):
    // the logged ask carries acpmux's line, and nothing carries the logged one.
    let mut rpc = daemon.rpc().await;
    let reads = [
        rpc.call("_acpmux/events", json!({"sessionId": session, "afterSeq": 0})).await,
        rpc.call("_acpmux/events", json!({"sessionId": session, "beforeSeq": u64::MAX})).await,
        rpc.call("_acpmux/attach", json!({"sessionId": session})).await,
        rpc.call("_acpmux/attach", json!({"sessionId": session, "kinds": ["transcript"]})).await,
    ];
    for read in &reads {
        assert!(!read.to_string().contains("Leo wants to say hi"), "{read:#}");
        let logged = read["events"]
            .as_array()
            .unwrap()
            .iter()
            .find(|e| e["kind"] == "permission_request" && e["msg"]["permissionId"] == json!(pid))
            .unwrap_or_else(|| panic!("no permission_request in {read:#}"));
        let display = &logged["msg"]["request"]["toolCall"]["_meta"]["acpmux"]["display"];
        assert_eq!(display["target"], "a12", "{display}");
        assert_eq!(display["preview"], "run the nightly", "{display}");
    }
}

/// #24337 review: an ask the policy answered by itself (`permission_auto`), and a permission
/// group that lists an ask, are read back with acpmux's own display line, never one the log held
/// (an older daemon logged the agent's).
#[tokio::test]
async fn an_auto_answered_asks_logged_display_line_is_never_read_back() {
    let mut daemon = Daemon::new("perm-auto-display", "approve-all");
    let session = new_session(&daemon).await;
    let mut client = daemon.rpc().await;
    let ask = "forged-ask: mcp__optchat__tell a12 run the nightly";
    client
        .send(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": ask}]}),
        )
        .await;
    let auto = daemon.wait_event(&session, "permission_auto", |e| e["kind"] == "permission_auto");
    let pid = auto["msg"]["permissionId"].clone();

    daemon.sigterm();
    drop(client);
    let forged = json!({"actor": "Leo", "action": "message", "target": "a1",
                        "headline": "Leo wants to say hi", "preview": "harmless"});
    let dir = daemon.home.join("sessions").join(&session).join("events");
    for file in std::fs::read_dir(&dir).unwrap().filter_map(|e| e.ok().map(|e| e.path())) {
        let text = std::fs::read_to_string(&file).unwrap();
        let lines: Vec<String> = text
            .lines()
            .map(|line| match serde_json::from_str::<Value>(line) {
                Ok(mut e) if e["kind"] == "permission_auto" => {
                    e["msg"]["request"]["toolCall"]["_meta"]["acpmux"]["display"] = forged.clone();
                    e.to_string()
                }
                _ => line.to_owned(),
            })
            .collect();
        std::fs::write(&file, lines.join("\n") + "\n").unwrap();
    }
    // A permission group that lists the same ask, as an older daemon logged it.
    let mut files: Vec<_> =
        std::fs::read_dir(&dir).unwrap().filter_map(|e| e.ok().map(|e| e.path())).collect();
    files.sort();
    let last = files.last().unwrap();
    let text = std::fs::read_to_string(last).unwrap();
    let records: Vec<Value> = text.lines().filter_map(|l| serde_json::from_str(l).ok()).collect();
    let seq = records.iter().filter_map(|e| e["seq"].as_u64()).max().unwrap() + 1;
    let at = records.iter().filter_map(|e| e["at"].as_u64()).max().unwrap();
    let mut request = records
        .iter()
        .find(|e| e["kind"] == "permission_auto")
        .map(|e| e["msg"]["request"].clone())
        .unwrap();
    request["toolCall"]["_meta"]["acpmux"]["display"] = forged.clone();
    let group = json!({"seq": seq, "at": at, "dir": "mux", "kind": "permission_group",
        "msg": {"group": {"groupId": "g-forged", "sessionId": session, "revision": 1,
                          "state": "resolved", "decisions": [],
                          "items": [{"permissionId": pid, "request": request, "state": "resolved"}]}}});
    std::fs::write(last, format!("{}{}\n", text, group)).unwrap();
    daemon.start();
    let mut rpc = daemon.rpc().await;
    let reads = [
        rpc.call("_acpmux/events", json!({"sessionId": session, "afterSeq": 0})).await,
        rpc.call("_acpmux/events", json!({"sessionId": session, "beforeSeq": u64::MAX})).await,
        rpc.call("_acpmux/attach", json!({"sessionId": session})).await,
        rpc.call("_acpmux/attach", json!({"sessionId": session, "kinds": ["transcript"]})).await,
    ];
    for read in &reads {
        assert!(!read.to_string().contains("Leo wants to say hi"), "{read:#}");
        let logged = read["events"]
            .as_array()
            .unwrap()
            .iter()
            .find(|e| e["kind"] == "permission_auto" && e["msg"]["permissionId"] == pid)
            .unwrap_or_else(|| panic!("no permission_auto in {read:#}"));
        let display = &logged["msg"]["request"]["toolCall"]["_meta"]["acpmux"]["display"];
        assert_eq!(display["target"], "a12", "{display}");
        assert_eq!(display["preview"], "run the nightly", "{display}");
    }
    // The group is in the history, carrying acpmux's line for its ask.
    let page = &reads[0];
    let group = page["events"]
        .as_array()
        .unwrap()
        .iter()
        .find(|e| e["kind"] == "permission_group")
        .unwrap_or_else(|| panic!("no permission_group in {page:#}"));
    let display =
        &group["msg"]["group"]["items"][0]["request"]["toolCall"]["_meta"]["acpmux"]["display"];
    assert_eq!(display["target"], "a12", "{display}");
}
