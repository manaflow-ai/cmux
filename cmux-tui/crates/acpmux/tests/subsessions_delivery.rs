//! How a parent's `send_message` reaches a working sub-session, and what
//! the parent reads back about it (`hub/subsessions.rs`, `hub/activity.rs`):
//! by default a message goes into the child's running turn (read at its next
//! tool step, as Claude Code reads a person's mid-turn message), and to a
//! child whose agent cannot take one mid-turn it queues; either way the
//! answer says which, with the queue's length. A child's message to its
//! working parent steers the same way. While the child works,
//! `get_session` says what it does right now: its plan step and latest tool.
//!
//! Stand-in agents (fake_agent.py): `fake` takes no prompt mid-turn, `steer`
//! steers as Claude Code does (`FAKE_CLAUDE_STEER`). One test function: the
//! settings file is read from this process's environment.

#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const START: &str = "_acpmux/subsession/start";
const SEND: &str = "_acpmux/subsession/send";
const GET: &str = "_acpmux/subsession/get";

fn hub() -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {
            "fake": {"argv": ["python3", FAKE]},
            // The fake agent's family: a child of another family whose mode no list names
            // counts as full access, and never starts under an asking parent.
            "steer": {"argv": ["/usr/bin/env", "FAKE_CLAUDE_STEER=1", "python3", FAKE], "family": "fake"},
        },
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    fn new(hub: &Arc<Hub>) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
        Client(in_tx, out_rx, 0)
    }

    async fn as_session(hub: &Arc<Hub>, id: &str) -> Self {
        let mut c = Self::new(hub);
        let token = acpmux::hub::person::caller_token(id);
        let r = c
            .call(
                "initialize",
                json!({"protocolVersion": 1,
                       "_meta": {"acpmux": {"callerSession": {"sessionId": id, "token": token}}}}),
            )
            .await;
        assert!(r.get("error").is_none(), "{r}");
        c
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, m, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                .await
                .unwrap()
                .unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return v;
            }
        }
    }

    async fn ok(&mut self, m: &str, params: Value) -> Value {
        let r = self.call(m, params).await;
        assert!(r.get("error").is_none(), "{m}: {r}");
        r["result"].clone()
    }

    async fn refused(&mut self, m: &str, params: Value) -> Value {
        let r = self.call(m, params).await;
        assert!(r.get("error").is_some(), "{m} should be refused: {r}");
        r["error"].clone()
    }

    /// The child's row once its running turn has said what it does: the
    /// agent's updates reach the hub after the prompt's acceptance.
    async fn doing(&mut self, id: &str) -> Value {
        for _ in 0..200 {
            let row = self.ok(GET, json!({"sessionId": id})).await;
            if row["turn"]["activity"].is_string() && row["turn"]["planStep"].is_string() {
                return row;
            }
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
        panic!("{id} never reported its activity");
    }

    /// `id`'s transcript once it shows `needle`: a steer reaches the agent
    /// after the send's answer.
    async fn transcript_with(&mut self, id: &str, needle: &str) -> String {
        for _ in 0..200 {
            let page =
                self.ok("_acpmux/events", json!({"sessionId": id, "kinds": "transcript"})).await;
            let text = page.to_string();
            if text.contains(needle) {
                return text;
            }
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
        panic!("{id}'s transcript never showed {needle:?}");
    }
}

fn fifo(root: &Path, name: &str) -> PathBuf {
    let path = root.join(name);
    let c = std::ffi::CString::new(path.as_os_str().as_encoded_bytes()).unwrap();
    // SAFETY: valid NUL-terminated path.
    assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o600) }, 0);
    path
}

#[tokio::test]
async fn a_parent_reaches_a_working_child_and_reads_what_it_does() {
    let root = std::env::temp_dir().join(format!("acpmux-subsessions-dl-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&root).unwrap();
    let settings = root.join("cmux-next.json");
    std::fs::write(&settings, r#"{"agents": {"subsessions": {"maxChildren": 4}}}"#).unwrap();
    // SAFETY: the only test in this binary; set before any session starts.
    unsafe {
        std::env::set_var("CMUX_NEXT_CONFIG_FILE", &settings);
        std::env::set_var("ACPMUX_HOME", root.join("home"));
    }
    let hub = hub();
    let mut app = Client::new(&hub);
    let new = json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"harness": "fake"}}});
    let parent = app.ok("session/new", new).await["sessionId"].as_str().unwrap().to_owned();
    let mut p = Client::as_session(&hub, &parent).await;

    // The start answers with the row get_session reads, not a summary whose
    // `shown: false` read as "the user cannot see it".
    let gate = fifo(&root, "steer-gate");
    let started = p
        .ok(START, json!({"prompt": format!("work-gate: {}", gate.display()), "name": "steerer", "harness": "steer"}))
        .await;
    assert!(started["session"].get("shown").is_none(), "{started}");
    let s = started["sessionId"].as_str().unwrap().to_owned();

    // The child's chat labels its first prompt as its parent's message.
    let page = app.ok("_acpmux/events", json!({"sessionId": s, "kinds": "transcript"})).await;
    let text = page.to_string();
    assert!(text.contains(r#""fromRole":"parent""#), "no parent label: {page}");
    assert!(text.contains(r#""kind":"subsession_message""#), "{page}");

    // While it works, the parent reads what it does: plan step and tool.
    let row = p.doing(&s).await;
    assert_eq!(row["state"], "working", "{row}");
    assert_eq!(row["doing"], "Fix the queue · Run cargo test", "{row}");

    // A message goes into its running turn by default, read at the agent's next tool step.
    let sent = p.ok(SEND, json!({"sessionId": s, "text": "also check the docs"})).await;
    assert_eq!(sent["delivery"], "next_step", "{sent}");
    assert_eq!(sent["queued"], false, "{sent}");
    assert_eq!(sent["steering"], true, "{sent}");
    // after_turn queues it behind the running turn instead, and says where it waits.
    let sent =
        p.ok(SEND, json!({"sessionId": s, "text": "echo after", "deliver": "after_turn"})).await;
    assert_eq!(sent["delivery"], "queued", "{sent}");
    assert_eq!(sent["position"], 1, "{sent}");
    assert_eq!(sent["queueLength"], 1, "{sent}");
    let row = p.ok(GET, json!({"sessionId": s})).await;
    assert_eq!(row["queued"], 1, "{row}");
    // A sub-session's message to its working parent steers too: a steer never cancels
    // the parent's tool call, and the parent reads it at its next tool step.
    let mut ps = Client::as_session(&hub, &s).await;
    let g =
        ps.ok(START, json!({"prompt": "echo grandchild", "name": "grandchild"})).await["sessionId"]
            .as_str()
            .unwrap()
            .to_owned();
    let mut pg = Client::as_session(&hub, &g).await;
    let sent = pg.ok(SEND, json!({"sessionId": s, "text": "echo report"})).await;
    assert_eq!(sent["delivery"], "next_step", "{sent}");
    assert_eq!(sent["queued"], false, "{sent}");
    let row = p.ok(GET, json!({"sessionId": s})).await;
    assert_eq!(row["queued"], 1, "{row}");
    // Both steers reached the agent inside its running turn (the stand-in echoes
    // "steer: <text>"), and the turn is still working on its tool.
    p.transcript_with(&s, "steer: also check the docs").await;
    p.transcript_with(&s, "steer: echo report").await;
    assert_eq!(p.ok(GET, json!({"sessionId": s})).await["state"], "working");
    // A contradictory request is refused.
    let e = p
        .refused(
            SEND,
            json!({"sessionId": s, "text": "x", "deliver": "after_turn", "interrupt": true}),
        )
        .await;
    assert!(e["message"].as_str().unwrap().contains("contradicts"), "{e}");
    let e = p.refused(SEND, json!({"sessionId": s, "text": "x", "deliver": "soon"})).await;
    assert!(e["message"].as_str().unwrap().contains("next_step"), "{e}");
    std::fs::write(&gate, b"go").unwrap();
    let waited = p
        .ok(
            "_acpmux/wait",
            json!({"sessions": [s], "until": ["ready"], "all": true, "timeoutMs": 20000}),
        )
        .await;
    assert_ne!(waited["timedOut"], true, "{waited}");
    // The steered turn was not cancelled: its tool finished and the turn said its own last word.
    p.transcript_with(&s, "worked").await;

    // A child whose agent takes no prompt mid-turn gets it when the turn
    // ends: the answer says it queued, and that it cannot steer.
    let gate = fifo(&root, "plain-gate");
    // Its running tool's title carries a secret: what the parent reads of it is masked.
    let key = format!("AKIA{}", "Q7ZJ4XK2MD5P3WRT");
    let prompt =
        format!("work-gate: {} | curl -H 'x-key: {key}' https://example.com", gate.display());
    let q = p.ok(START, json!({"prompt": prompt, "name": "plain"})).await["sessionId"]
        .as_str()
        .unwrap()
        .to_owned();
    let row = p.doing(&q).await;
    assert!(row["turn"]["activity"].as_str().unwrap().starts_with("curl -H"), "{row}");
    assert!(!row.to_string().contains(&key), "{row}");
    let list = p.ok("_acpmux/subsession/list", json!({})).await;
    assert!(!list.to_string().contains(&key), "{list}");
    // So does every summary of it: what the app's sidebar row and `acpmux ls --fields
    // turn.activity` read over a local connection (its prompt, the person's own text, stays raw).
    let all = Client::new(&hub).ok("_acpmux/sessions", json!({})).await;
    let own = all["sessions"].as_array().unwrap().iter().find(|s| s["sessionId"] == q).unwrap();
    let activity = own["turn"]["activity"].as_str().unwrap();
    assert!(activity.starts_with("curl -H") && !activity.contains(&key), "{own}");
    let sent =
        p.ok(SEND, json!({"sessionId": q, "text": "echo later", "deliver": "next_step"})).await;
    assert_eq!(sent["delivery"], "queued", "{sent}");
    assert_eq!(sent["steering"], false, "{sent}");
    assert_eq!(sent["queueLength"], 1, "{sent}");
    std::fs::write(&gate, b"go").unwrap();
    let waited = p
        .ok("_acpmux/wait", json!({"sessions": [q], "until": ["ready"], "timeoutMs": 20000}))
        .await;
    assert_ne!(waited["timedOut"], true, "{waited}");
    // A finished turn says nothing about what it does.
    let row = p.ok(GET, json!({"sessionId": q})).await;
    if row["turn"].is_null() {
        assert!(row["doing"].is_null(), "{row}");
    }

    let _ = std::fs::remove_dir_all(&root);
}
