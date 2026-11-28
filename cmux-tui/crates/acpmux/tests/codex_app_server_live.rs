//! Codex through `codex app-server`, bridged in process (cmux-codex-acp):
//! behavior at the daemon's ACP socket against a real app-server.
//!
//! Needs a codex binary and a CODEX_HOME that reaches a model:
//!
//! ```text
//! ACPMUX_CODEX_LIVE=/path/to/codex CODEX_HOME=/path/to/home \
//!   cargo test -p acpmux --test codex_app_server_live -- --test-threads 3
//! ```
//!
//! Without ACPMUX_CODEX_LIVE each test says so and passes (CI has no model).
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// Live by design (only with ACPMUX_CODEX_LIVE): the real codex it names and
// the CODEX_HOME that reaches a model are kept; nothing else of the host.
const HERMETIC: daemon_env::Process =
    daemon_env::Process::stand_in().keep(&["ACPMUX_CODEX_LIVE", "CODEX_HOME"]);

use serde_json::{Value, json};
use std::io::{BufRead, BufReader};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt};

const TURN: Duration = Duration::from_secs(480);
/// The person key the daemon gets on `--person-key-fd 3`, as from the app:
/// Codex modes do not ask before every action, so only the person may pick one.
const KEY: &str = "5e1f0c2a9b8d7e6f5a4b3c2d1e0f9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f";

/// The app's answer to a connection's person challenge (`hub/person.rs`).
fn person_proof(nonce: &str, connection: &str) -> String {
    use cmux_local_auth::frontend_proof::{hex, hmac_sha256, unhex};
    let key = unhex::<32>(KEY).expect("hex key");
    let mut message = b"acpmux-person-v1\0unix\0".to_vec();
    message.extend_from_slice(nonce.as_bytes());
    message.push(0);
    message.extend_from_slice(connection.as_bytes());
    hex(&hmac_sha256(&key, &message))
}

struct Daemon {
    child: Option<Child>,
    home: PathBuf,
    socket: PathBuf,
    project: PathBuf,
    /// Agents run as direct children (`ACPMUX_AGENT_HOSTS=0`), not hosts.
    direct: bool,
}

impl Daemon {
    fn new(tag: &str, policy: &str) -> Option<Self> {
        Self::with(tag, policy, false)
    }

    fn with(tag: &str, policy: &str, direct: bool) -> Option<Self> {
        let Ok(codex) = std::env::var("ACPMUX_CODEX_LIVE") else {
            eprintln!("{tag}: ACPMUX_CODEX_LIVE is not set; no live codex run");
            return None;
        };
        let codex_home = std::env::var("CODEX_HOME").expect("CODEX_HOME with model access");
        // Short: socket paths must stay under the macOS limit.
        let home = std::env::temp_dir().join(format!("acx-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        let project = home.join("p");
        std::fs::create_dir_all(&project).unwrap();
        let _ = Command::new("git").args(["init", "-q"]).current_dir(&project).status();
        std::fs::write(
            home.join("config.json"),
            json!({
                "harnesses": {"codex-app-server": {"argv": [codex, "app-server"], "env": {"CODEX_HOME": codex_home}}},
                "defaultHarness": "codex-app-server",
                "permissionPolicy": policy,
            })
            .to_string(),
        )
        .unwrap();
        let socket = home.join("s.sock");
        let mut d = Self { child: None, home, socket, project, direct };
        d.start();
        Some(d)
    }

    fn start(&mut self) {
        let mut fds = [-1i32; 2];
        // SAFETY: a fresh pipe; both ends are owned here.
        assert_eq!(unsafe { libc::pipe(fds.as_mut_ptr()) }, 0);
        let line = format!("{KEY}\n");
        // SAFETY: the write end is open; the line fits the pipe buffer.
        let n = unsafe { libc::write(fds[1], line.as_ptr().cast(), line.len()) };
        assert_eq!(n as usize, line.len());
        // SAFETY: closing our own write end.
        unsafe { libc::close(fds[1]) };
        let read_end = fds[0];
        // Live by design: the real codex named by ACPMUX_CODEX_LIVE (an absolute
        // path in the harness argv), its own directory (an npm install keeps its
        // node there) right after the tool links, before the system directories.
        // That directory can hold other agent CLIs: only codex is probed.
        let codex = std::env::var("ACPMUX_CODEX_LIVE").expect("ACPMUX_CODEX_LIVE");
        assert!(Path::new(&codex).is_absolute(), "ACPMUX_CODEX_LIVE must be absolute");
        let codex_dir = Path::new(&codex).parent().expect("codex directory").to_owned();
        let path = format!(
            "{}:{}:/usr/bin:/bin:/usr/sbin:/sbin",
            daemon_env::tool_dir(&[]).display(),
            codex_dir.display()
        );
        let mut command = daemon_env::command(&self.home, daemon_env::Agents::StandIn, &[]);
        command.env("PATH", path).env("ACPMUX_PROBE_HARNESSES", "codex-app-server");
        // SAFETY: only dup2 between fork and exec (async-signal-safe).
        unsafe {
            command.pre_exec(move || {
                if libc::dup2(read_end, 3) < 0 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
        let mut child = command
            .args(["daemon", "run", "--listen", "127.0.0.1:0", "--ready-fd", "1", "--log", "warn"])
            .args(["--person-key-fd", "3"])
            .env("ACPMUX_HOME", &self.home)
            .env("ACPMUX_SOCKET", &self.socket)
            .env("ACPMUX_AGENT_HOSTS", if self.direct { "0" } else { "1" })
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .expect("start daemon");
        // SAFETY: the child has its own copy on fd 3.
        unsafe { libc::close(read_end) };
        let mut stdout = BufReader::new(child.stdout.take().unwrap());
        let mut ready = String::new();
        while stdout.read_line(&mut ready).unwrap() > 0 && !ready.contains("\"ready\":true") {
            ready.clear();
        }
        assert!(ready.contains("\"ready\":true"), "daemon not ready");
        if let Some(bound) = serde_json::from_str::<Value>(&ready)
            .ok()
            .and_then(|v| v["socket"].as_str().map(PathBuf::from))
        {
            self.socket = bound;
        }
        self.child = Some(child);
    }

    /// An update stops the daemon with SIGTERM: agents are handed off.
    fn sigterm(&mut self) {
        let mut child = self.child.take().unwrap();
        // SAFETY: signalling this test's own child process.
        assert_eq!(unsafe { libc::kill(child.id() as i32, libc::SIGTERM) }, 0);
        assert!(child.wait().unwrap().success(), "daemon exited badly on SIGTERM");
    }

    async fn rpc(&self) -> Rpc {
        Rpc::connect(&self.socket).await
    }

    /// A connection that proved it is the person (the app's own).
    async fn person(&self) -> Rpc {
        let mut c = Rpc::connect(&self.socket).await;
        let init =
            c.call("initialize", json!({"protocolVersion": 1}), Duration::from_secs(30)).await;
        let challenge = &init["_meta"]["acpmux"]["personChallenge"];
        let proof = person_proof(
            challenge["nonce"].as_str().expect("nonce"),
            challenge["connection"].as_str().expect("connection"),
        );
        c.call("_acpmux/person_prove", json!({"proof": proof}), Duration::from_secs(30)).await;
        c
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
        let deadline = Instant::now() + TURN;
        loop {
            if let Some(e) = self.events(session).into_iter().find(|e| pred(e)) {
                return e;
            }
            assert!(Instant::now() < deadline, "no {what} in the log");
            std::thread::sleep(Duration::from_millis(100));
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

    async fn notify(&mut self, method: &str, params: Value) {
        let line = json!({"jsonrpc": "2.0", "method": method, "params": params});
        self.wr.write_all(format!("{line}\n").as_bytes()).await.unwrap();
    }

    async fn wait(&mut self, id: i64, within: Duration) -> Value {
        loop {
            let line = tokio::time::timeout(within, self.lines.next_line())
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

    async fn call(&mut self, method: &str, params: Value, within: Duration) -> Value {
        let id = self.send(method, params).await;
        let v = self.wait(id, within).await;
        assert!(v.get("error").is_none(), "{method} failed: {v}");
        v["result"].clone()
    }
}

async fn new_session(d: &Daemon) -> String {
    created_session(d).await["sessionId"].as_str().expect("session id").to_owned()
}

async fn created_session(d: &Daemon) -> Value {
    d.rpc().await.call("session/new", json!({"cwd": d.project, "mcpServers": []}), TURN).await
}

async fn prompt(d: &Daemon, session: &str, text: &str) -> Value {
    d.rpc()
        .await
        .call(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": text}]}),
            TURN,
        )
        .await
}

async fn set_mode(d: &Daemon, session: &str, mode: &str) {
    d.person()
        .await
        .call(
            "session/set_mode",
            json!({"sessionId": session, "modeId": mode}),
            Duration::from_secs(30),
        )
        .await;
}

/// The agent text the session log recorded after record `from`, own
/// session only (not a subagent's).
fn text(events: &[Value], from: usize) -> String {
    events[from..]
        .iter()
        .filter(|e| e["kind"] == "agent_message_chunk")
        .filter(|e| e["msg"]["params"]["_meta"]["acpmux"]["subagent"].is_null())
        .filter_map(|e| e["msg"]["params"]["update"]["content"]["text"].as_str())
        .collect()
}

fn update(e: &Value) -> &Value {
    &e["msg"]["params"]["update"]
}

#[tokio::test(flavor = "multi_thread")]
async fn a_multi_turn_codex_session_streams_and_remembers() {
    let Some(d) = Daemon::new("multi", "approve-all") else { return };
    let s = new_session(&d).await;
    let host = d.host_record(&s);
    assert!(host["harness_pid"].as_i64().is_some(), "no hosted app-server: {host}");
    let r = prompt(&d, &s, "Reply with exactly the word: pineapple").await;
    assert_eq!(r["stopReason"], "end_turn", "{r}");
    let events = d.events(&s);
    assert!(text(&events, 0).to_lowercase().contains("pineapple"));
    assert!(events.iter().any(|e| e["kind"] == "usage_update"), "no usage_update");
    let from = events.len();
    let r =
        prompt(&d, &s, "Which word did you reply with before? Reply with only that word.").await;
    assert_eq!(r["stopReason"], "end_turn", "{r}");
    assert!(text(&d.events(&s), from).to_lowercase().contains("pineapple"));
    // One app-server served both turns.
    assert_eq!(d.host_record(&s)["harness_pid"], host["harness_pid"]);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_command_goes_through_the_permission_policy() {
    let Some(d) = Daemon::new("exec", "approve-all") else { return };
    std::fs::write(d.project.join("note.txt"), "marker-4242\n").unwrap();
    let s = new_session(&d).await;
    set_mode(&d, &s, "ask").await;
    let r = prompt(&d, &s, "Run the shell command `cat note.txt` and reply with its output.").await;
    assert_eq!(r["stopReason"], "end_turn", "{r}");
    let events = d.events(&s);
    let asked = events
        .iter()
        .find(|e| e["kind"] == "session/request_permission")
        .expect("a permission request in ask mode");
    let call = &asked["msg"]["params"]["toolCall"];
    assert!(matches!(call["kind"].as_str(), Some("execute" | "read")), "{call}");
    let done = events
        .iter()
        .find(|e| {
            update(e)["sessionUpdate"] == "tool_call_update"
                && update(e)["status"] == "completed"
                && update(e)["toolCallId"] == call["toolCallId"]
        })
        .expect("the command's completion");
    assert!(update(done)["content"].to_string().contains("marker-4242"));
    assert!(text(&events, 0).contains("marker-4242"));
}

#[tokio::test(flavor = "multi_thread")]
async fn a_patch_asks_with_before_and_after() {
    let Some(d) = Daemon::new("patch", "approve-all") else { return };
    std::fs::write(d.project.join("greet.txt"), "hello\n").unwrap();
    let s = new_session(&d).await;
    set_mode(&d, &s, "ask").await;
    let r = prompt(
        &d,
        &s,
        "Use apply_patch to change greet.txt so its only line is goodbye instead of hello. Do not run shell commands.",
    )
    .await;
    assert_eq!(r["stopReason"], "end_turn", "{r}");
    let events = d.events(&s);
    let asked = events
        .iter()
        .find(|e| {
            e["kind"] == "session/request_permission"
                && e["msg"]["params"]["toolCall"]["kind"] == "edit"
        })
        .expect("an edit approval");
    let diff = &asked["msg"]["params"]["toolCall"]["content"][0];
    assert_eq!(diff["type"], "diff", "{asked}");
    assert_eq!(diff["oldText"], "hello\n");
    assert!(diff["newText"].as_str().unwrap_or("").contains("goodbye"));
    assert!(std::fs::read_to_string(d.project.join("greet.txt")).unwrap().contains("goodbye"));
}

#[tokio::test(flavor = "multi_thread")]
async fn cancel_ends_a_running_codex_turn() {
    let Some(d) = Daemon::new("cancel", "approve-all") else { return };
    let s = new_session(&d).await;
    set_mode(&d, &s, "agent-full-access").await;
    let mut client = d.rpc().await;
    let id = client
        .send(
            "session/prompt",
            json!({"sessionId": s, "prompt": [{"type": "text", "text": "Run the shell command `sleep 120` and then reply done."}]}),
        )
        .await;
    d.wait_event(&s, "the running command", |e| {
        update(e)["sessionUpdate"] == "tool_call" && update(e)["kind"] == "execute"
    });
    let t0 = Instant::now();
    d.rpc().await.notify("session/cancel", json!({"sessionId": s})).await;
    let r = client.wait(id, Duration::from_secs(60)).await;
    assert_eq!(r["result"]["stopReason"], "cancelled", "{r}");
    assert!(t0.elapsed() < Duration::from_secs(30), "cancel took {:?}", t0.elapsed());
    let r = prompt(&d, &s, "Reply with exactly: ready").await;
    assert_eq!(r["stopReason"], "end_turn", "{r}");
}

#[tokio::test(flavor = "multi_thread")]
async fn two_codex_subagents_are_attributed_to_their_own_sessions() {
    let Some(d) = Daemon::new("subs", "approve-all") else { return };
    let s = new_session(&d).await;
    set_mode(&d, &s, "agent-full-access").await;
    let r = prompt(
        &d,
        &s,
        "Spawn two sub-agents in parallel with your agent tools. The first must reply with exactly the word alpha, the second with exactly the word beta. Wait for both, then reply with their two answers.",
    )
    .await;
    assert_eq!(r["stopReason"], "end_turn", "{r}");
    let events = d.events(&s);
    let mut children: Vec<String> = events
        .iter()
        .flat_map(|e| {
            e["msg"]["params"]["_meta"]["acpmux"]["subagents"]
                .as_array()
                .cloned()
                .unwrap_or_default()
        })
        .filter_map(|sub| sub["id"].as_str().map(str::to_owned))
        .collect();
    children.sort();
    children.dedup();
    assert_eq!(children.len(), 2, "subagents: {children:?}");
    let mut words = String::new();
    for child in &children {
        let said: String = events
            .iter()
            .filter(|e| e["kind"] == "agent_message_chunk")
            .filter(|e| e["msg"]["params"]["_meta"]["acpmux"]["subagent"] == child.as_str())
            .filter_map(|e| update(e)["content"]["text"].as_str())
            .collect();
        assert!(!said.is_empty(), "subagent {child} has no attributed message");
        words.push_str(&said.to_lowercase());
        assert!(
            events.iter().any(|e| {
                e["msg"]["params"]["_meta"]["acpmux"]["subagents"].as_array().is_some_and(|a| {
                    a.iter().any(|x| x["id"] == child.as_str() && x["state"] == "completed")
                })
            }),
            "subagent {child} never completed"
        );
    }
    assert!(words.contains("alpha") && words.contains("beta"), "{words}");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_codex_session_continues_after_a_daemon_restart() {
    let Some(mut d) = Daemon::new("restart", "approve-all") else { return };
    let s = new_session(&d).await;
    let r = prompt(&d, &s, "Remember the code word walrus. Reply with exactly: ok").await;
    assert_eq!(r["stopReason"], "end_turn", "{r}");
    let harness = d.host_record(&s)["harness_pid"].clone();
    d.sigterm();
    d.start();
    d.wait_event(&s, "host_adopted", |e| e["kind"] == "host_adopted");
    let from = d.events(&s).len();
    let r = prompt(&d, &s, "What was the code word? Reply with only the word.").await;
    assert_eq!(r["stopReason"], "end_turn", "{r}");
    assert!(text(&d.events(&s), from).to_lowercase().contains("walrus"));
    assert_eq!(d.host_record(&s)["harness_pid"], harness, "the app-server was replaced");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_model_switch_applies_to_the_next_codex_turn() {
    let Some(d) = Daemon::new("model", "approve-all") else { return };
    let created = created_session(&d).await;
    let s = created["sessionId"].as_str().unwrap().to_owned();
    let r = prompt(&d, &s, "Reply with exactly: one").await;
    assert_eq!(r["stopReason"], "end_turn", "{r}");
    // The newest options: the model list may arrive after session/new.
    let options = d
        .events(&s)
        .iter()
        .rev()
        .find_map(|e| {
            (update(e)["sessionUpdate"] == "config_option_update")
                .then(|| update(e)["configOptions"].clone())
        })
        .unwrap_or_else(|| created["configOptions"].clone());
    let model = options.as_array().unwrap().iter().find(|o| o["id"] == "model").unwrap().clone();
    let current = model["currentValue"].as_str().unwrap().to_owned();
    let other = model["options"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|o| o["value"].as_str())
        .find(|v| *v != current)
        .expect("a second model")
        .to_owned();
    d.rpc()
        .await
        .call(
            "session/set_config_option",
            json!({"sessionId": s, "configId": "model", "value": other}),
            Duration::from_secs(30),
        )
        .await;
    let r = prompt(&d, &s, "Reply with exactly: two").await;
    assert_eq!(r["stopReason"], "end_turn", "{r}");
    // The app-server's own record of the second turn names the new model:
    // the rollout under CODEX_HOME that holds this test's unique marker.
    let marker = format!("model-switch-{s}");
    let r = prompt(&d, &s, &format!("Reply with exactly: {marker}")).await;
    assert_eq!(r["stopReason"], "end_turn", "{r}");
    let home = PathBuf::from(std::env::var("CODEX_HOME").unwrap()).join("sessions");
    let rollout = rollouts(&home)
        .into_iter()
        .find(|p| std::fs::read_to_string(p).unwrap_or_default().contains(&marker))
        .expect("the session's rollout");
    let last = std::fs::read_to_string(&rollout)
        .unwrap()
        .lines()
        .rev()
        .filter_map(|l| serde_json::from_str::<Value>(l).ok())
        .filter(|v| v["type"] == "turn_context")
        .find_map(|v| v["payload"]["model"].as_str().map(str::to_owned));
    assert_eq!(last.as_deref(), Some(other.as_str()));
}

/// Every rollout file under `dir`, newest first.
fn rollouts(dir: &Path) -> Vec<PathBuf> {
    let mut found = Vec::new();
    let mut stack = vec![dir.to_path_buf()];
    while let Some(d) = stack.pop() {
        for e in std::fs::read_dir(&d).into_iter().flatten().flatten() {
            let p = e.path();
            if p.is_dir() {
                stack.push(p);
            } else if p.extension().is_some_and(|x| x == "jsonl") {
                found.push(p);
            }
        }
    }
    found.sort_by_key(|p| std::cmp::Reverse(std::fs::metadata(p).and_then(|m| m.modified()).ok()));
    found
}

#[tokio::test(flavor = "multi_thread")]
async fn a_direct_child_codex_session_runs_turns_and_takes_a_mode() {
    let Some(d) = Daemon::with("direct", "approve-all", true) else { return };
    let s = new_session(&d).await;
    assert!(!d.home.join("hosts").join(format!("{s}.json")).exists(), "a host ran the agent");
    set_mode(&d, &s, "read-only").await;
    let r = prompt(&d, &s, "Reply with exactly the word: kiwi").await;
    assert_eq!(r["stopReason"], "end_turn", "{r}");
    assert!(text(&d.events(&s), 0).to_lowercase().contains("kiwi"));
    assert!(
        d.events(&s).iter().any(|e| update(e)["sessionUpdate"] == "current_mode_update"
            && update(e)["currentModeId"] == "read-only"),
        "no current_mode_update"
    );
}
