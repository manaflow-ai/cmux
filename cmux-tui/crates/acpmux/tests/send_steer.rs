//! An agent's `acpmux send` steers into a running turn by default, and one that waits for its
//! reply answers with the reply of the turn it went into (`cli/steer_reply.rs`). Leo,
//! 2026-10-25: "I don't know why these things are queued up." He saw "11 more queued" over the
//! composer: every agent send that waited for its reply queued behind the turn.
//!
//! The daemon is a hub in this process on a unix socket; each send is the `acpmux` binary. The
//! person's turn waits on a FIFO gate (`tests/fake_agent.py` "gate:"), so each test decides when
//! it ends.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::client::Client;
use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::method;
use serde_json::{Value, json};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Output;
use std::sync::Arc;
use std::time::Duration;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

/// A session whose agent steers as Claude Code does (`steering`) or does not steer, with a turn
/// of the person's running in it behind a gate.
struct Busy {
    hub: Arc<Hub>,
    id: String,
    gate: PathBuf,
    socket: PathBuf,
    scratch: PathBuf,
    person: Arc<Client>,
}

impl Drop for Busy {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.socket);
        let _ = std::fs::remove_dir_all(&self.scratch);
    }
}

async fn busy(steering: bool) -> Busy {
    let env = if steering { json!({"FAKE_CLAUDE_STEER": "1"}) } else { json!({}) };
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE], "env": env}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    // The queue path before the inbox (`hub/inbox.rs`), which these tests cover.
    cfg.agent_inbox = Some(false);
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let tag =
        format!("{}-{}", std::process::id(), &uuid::Uuid::now_v7().simple().to_string()[20..]);
    // `/tmp`, not the temp dir: a worker's can be too long for a socket path.
    let socket = PathBuf::from("/tmp").join(format!("acpmux-steer-{tag}.sock"));
    let listener = acpmux::server::bind_unix(&socket).await.unwrap();
    tokio::spawn(acpmux::server::serve_unix(hub.clone(), listener));
    let scratch = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join(format!("steer-{tag}"));
    std::fs::create_dir_all(daemon_env::home(&scratch)).unwrap();
    let person = Client::connect(&socket).await.unwrap();
    let new = json!({"cwd": std::env::temp_dir(), "mcpServers": []});
    let id = person.request(method::SESSION_NEW, new).await.unwrap()["sessionId"]
        .as_str()
        .unwrap()
        .to_owned();
    let gate = scratch.join("gate");
    let c = std::ffi::CString::new(gate.as_os_str().as_encoded_bytes()).unwrap();
    // SAFETY: a valid NUL-terminated path.
    assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o600) }, 0);
    let b = Busy { hub, id, gate, socket, scratch, person };
    b.run_gated().await;
    b
}

impl Busy {
    /// The person's turn behind the gate, as the app sends it, once its agent is in it.
    async fn run_gated(&self) {
        let pid = prompt_id();
        let text = format!("gate: {}", self.gate.display());
        let prompt = json!({"sessionId": self.id, "prompt": [{"type": "text", "text": text}], "_meta": {"acpmux": {"promptId": pid}}});
        let person = self.person.clone();
        tokio::spawn(async move { person.request(method::SESSION_PROMPT, prompt).await });
        let turn = self.record("user_message", &pid).await["turnId"].as_str().unwrap().to_owned();
        self.agent_said_in(&turn, "before-gate").await;
    }

    fn open_gate(&self) {
        let mut gate = std::fs::OpenOptions::new().write(true).open(&self.gate).unwrap();
        gate.write_all(b"go").unwrap();
    }

    /// `acpmux ARGS` against this daemon, as the person's terminal runs it.
    fn send(&self, args: &[&str]) -> tokio::process::Command {
        let mut cmd = daemon_env::tokio_command(&self.scratch, daemon_env::Agents::Deny);
        cmd.arg("--json").args(args).env("ACPMUX_SOCKET", &self.socket).kill_on_drop(true);
        cmd
    }

    /// The record `kind` of prompt `prompt_id`, within 30 s.
    async fn record(&self, kind: &str, prompt_id: &str) -> Value {
        for _ in 0..600 {
            let events = self.hub.events(&self.id, 0, 1000).unwrap();
            if let Some(e) =
                events.iter().find(|e| e.kind == kind && e.msg["promptId"] == prompt_id)
            {
                return e.msg.clone();
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        panic!("no {kind} record for {prompt_id}");
    }

    /// The agent wrote `text` into the chat, within 30 s.
    async fn agent_said(&self, text: &str) {
        self.agent_said_in("", text).await;
    }

    /// The agent wrote `text` into the chat after turn `turn` started (any turn for ""), within
    /// 30 s.
    async fn agent_said_in(&self, turn: &str, text: &str) {
        for _ in 0..600 {
            let events = self.hub.events(&self.id, 0, 1000).unwrap();
            let start = events.iter().position(|e| {
                turn.is_empty() || (e.kind == "user_message" && e.msg["turnId"] == turn)
            });
            let said =
                |e: &acpmux::store::EventRecord| e.dir == "in" && e.msg.to_string().contains(text);
            if start.is_some_and(|at| events[at..].iter().any(said)) {
                return;
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        panic!("the agent never said {text:?}");
    }

    fn queued(&self, prompt_id: &str) -> bool {
        let events = self.hub.events(&self.id, 0, 1000).unwrap();
        events.iter().any(|e| e.kind == "queued" && e.msg["promptId"] == prompt_id)
    }
}

fn prompt_id() -> String {
    uuid::Uuid::now_v7().to_string()
}

async fn done(send: tokio::task::JoinHandle<std::io::Result<Output>>) -> (Value, Output) {
    let out = tokio::time::timeout(Duration::from_secs(60), send).await.unwrap().unwrap().unwrap();
    let stdout = String::from_utf8_lossy(&out.stdout);
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(out.status.success(), "send failed: {stdout} {stderr}");
    (serde_json::from_str(&stdout).unwrap_or(Value::Null), out)
}

/// An agent's send that waits steers into the running turn, stays waiting after the agent read
/// it, and answers with that turn's final reply.
#[tokio::test]
async fn an_agents_waiting_send_steers_and_answers_with_the_turns_final_reply() {
    let b = busy(true).await;
    let pid = prompt_id();
    let mut cmd = b.send(&["send", "--from", "lane-a", "--prompt-id", &pid, &b.id, "rebase first"]);
    let send = tokio::spawn(async move { cmd.output().await });
    let sent = b.record("user_message", &pid).await;
    assert_eq!(sent["steer"], true, "into the running turn, not the queue: {sent}");
    b.agent_said("steer: rebase first").await;
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert!(!send.is_finished(), "the send answered before the turn it steered into ended");
    b.open_gate();
    let (reply, _) = done(send).await;
    assert_eq!(reply["stopReason"], "end_turn", "{reply}");
    let text = reply["reply"].as_str().unwrap_or_default();
    assert!(text.contains("after-gate"), "the turn's final reply, got {reply}");
    assert!(!b.queued(&pid));
    // The same send again (a resend after a lost connection) is answered by the first run's
    // `steered`, after the turn ended: it answers with that turn's end from the log at once.
    let mut again =
        b.send(&["send", "--from", "lane-a", "--prompt-id", &pid, &b.id, "rebase first"]);
    let (resent, _) = done(tokio::spawn(async move { again.output().await })).await;
    assert_eq!(resent["stopReason"], "end_turn", "{resent}");
    assert_eq!(resent["reply"], reply["reply"], "{resent}");
}

/// The streaming send (no `--json`, no `--quiet`) waits for the turn's end the same way and
/// prints its reply, and an agent running in an acpmux session (its caller token) needs no
/// `--from`.
#[tokio::test]
async fn an_agent_in_a_session_steers_and_its_stream_waits_for_the_turns_end() {
    let b = busy(true).await;
    let new = json!({"cwd": std::env::temp_dir(), "mcpServers": []});
    let lane = b.person.request(method::SESSION_NEW, new).await.unwrap()["sessionId"]
        .as_str()
        .unwrap()
        .to_owned();
    let pid = prompt_id();
    let mut cmd = daemon_env::tokio_command(&b.scratch, daemon_env::Agents::Deny);
    cmd.args(["send", "--prompt-id", &pid, &b.id, "rebase first"])
        .env("ACPMUX_SOCKET", &b.socket)
        .env("ACPMUX_SESSION_ID", &lane)
        .env("ACPMUX_SESSION_TOKEN", acpmux::hub::person::caller_token(&lane))
        .env("ACPMUX_SESSION_TOKEN_SOCKET", &b.socket)
        .kill_on_drop(true);
    let send = tokio::spawn(async move { cmd.output().await });
    assert_eq!(b.record("user_message", &pid).await["steer"], true);
    b.agent_said("steer: rebase first").await;
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert!(!send.is_finished(), "the send answered before the turn it steered into ended");
    b.open_gate();
    let (_, out) = done(send).await;
    assert!(String::from_utf8_lossy(&out.stdout).contains("steer: rebase first"));
    // A resend after the turn ended streams nothing of it: the reply comes from the log.
    let mut again = daemon_env::tokio_command(&b.scratch, daemon_env::Agents::Deny);
    again
        .args(["send", "--prompt-id", &pid, &b.id, "rebase first"])
        .env("ACPMUX_SOCKET", &b.socket)
        .env("ACPMUX_SESSION_ID", &lane)
        .env("ACPMUX_SESSION_TOKEN", acpmux::hub::person::caller_token(&lane))
        .env("ACPMUX_SESSION_TOKEN_SOCKET", &b.socket)
        .kill_on_drop(true);
    let (_, out) = done(tokio::spawn(async move { again.output().await })).await;
    let printed = String::from_utf8_lossy(&out.stdout);
    assert!(printed.contains("after-gate"), "the turn's reply, got {printed}");
}

/// An agent that does not steer gets it after the turn, as before. Its `queued` record, the
/// session's queue and the composers view name the sender (`fromAgent`), so the chat draws it as
/// a received message.
#[tokio::test]
async fn to_an_agent_that_does_not_steer_an_agents_send_queues_named() {
    let b = busy(false).await;
    let pid = prompt_id();
    let mut cmd = b.send(&["send", "--from", "lane-a", "--prompt-id", &pid, &b.id, "rebase first"]);
    let send = tokio::spawn(async move { cmd.output().await });
    assert_eq!(b.record("queued", &pid).await["fromAgent"], "lane-a");
    let session = b.hub.resolve(&b.id).unwrap();
    let summary = b.hub.session_summary(&session);
    assert_eq!(summary["queue"][0]["fromAgent"], "lane-a", "{summary}");
    assert_eq!(b.hub.composers_view(&session)["queue"][0]["fromAgent"], "lane-a");
    b.open_gate();
    let (reply, _) = done(send).await;
    let text = reply["reply"].as_str().unwrap_or_default();
    assert!(text.contains("rebase first"), "its own turn's reply, got {reply}");
}

/// `--no-steer` queues an agent's send behind a turn that could take it; the person's send that
/// waits queues there too, unnamed.
#[tokio::test]
async fn a_no_steer_send_and_the_persons_waiting_send_queue() {
    let b = busy(true).await;
    let pid = prompt_id();
    let args =
        ["send", "--from", "lane-a", "--no-steer", "--prompt-id", &pid, &b.id, "rebase first"];
    let mut cmd = b.send(&args);
    let send = tokio::spawn(async move { cmd.output().await });
    assert_eq!(b.record("queued", &pid).await["fromAgent"], "lane-a");
    b.open_gate();
    let (reply, _) = done(send).await;
    let text = reply["reply"].as_str().unwrap_or_default();
    assert!(text.contains("rebase first"), "its own turn's reply, got {reply}");
    b.run_gated().await;
    let mine = prompt_id();
    let mut cmd = b.send(&["send", "--prompt-id", &mine, &b.id, "mine"]);
    let send = tokio::spawn(async move { cmd.output().await });
    assert!(b.record("queued", &mine).await.get("fromAgent").is_none());
    let summary = b.hub.session_summary(&b.hub.resolve(&b.id).unwrap());
    assert_eq!(summary["queue"][0]["fromAgent"], Value::Null, "{summary}");
    b.open_gate();
    let (reply, _) = done(send).await;
    assert!(reply["reply"].as_str().unwrap_or_default().contains("mine"), "{reply}");
}

/// A send's `--timeout` that passes while it waits for the turn it steered into leaves that turn
/// running: it is another prompt's.
#[tokio::test]
async fn a_steered_sends_timeout_leaves_the_turn_it_went_into_running() {
    let b = busy(true).await;
    let pid = prompt_id();
    let args = ["send", "--from", "lane-a", "--timeout", "2", "--prompt-id", &pid, &b.id, "rebase"];
    let out = tokio::time::timeout(Duration::from_secs(60), b.send(&args).output())
        .await
        .unwrap()
        .unwrap();
    let all =
        format!("{}{}", String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr));
    assert_eq!(out.status.code(), Some(3), "a timeout: {all}");
    assert!(all.contains("runs on"), "{all}");
    let turn = b.hub.resolve(&b.id).unwrap().turn().expect("the person's turn still runs");
    let events = b.hub.events(&b.id, 0, 1000).unwrap();
    let ended = events.iter().any(|e| e.kind == "turn_end" || e.kind == "turn_error");
    assert!(!ended, "nothing ended");
    b.open_gate();
    assert_eq!(b.record("turn_result", &turn.prompt_id).await["status"], "completed");
}
