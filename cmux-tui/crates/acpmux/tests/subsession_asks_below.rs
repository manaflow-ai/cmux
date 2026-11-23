//! A sub-session's ask reaches its parent chat (cmuxterm-hq#7794 #7): while the child waits on
//! the person, the parent's row reads `input`, and the person's answer sent to the parent for
//! the child's ask (`_acpmux/permission_respond` naming the parent, as the parent's page sends
//! it) answers the child, whose agent continues. The parent's agent cannot answer it that way:
//! the answer is checked as one sent to the child (`server/requests.rs` `route_ask_below`).
//!
//! Stand-in agents (fake_agent.py).

#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{ConnAuth, Origin, serve_connection_authed, serve_connection_with};
use serde_json::{Value, json};
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const KEY: &str = "5e1f0c2a9b8d7e6f5a4b3c2d1e0f9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f";

fn hub() -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE]}},
        "defaultHarness": "fake",
        "permissionPolicy": "ask",
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

    /// The app's agent pane: a LocalApp connection that proved this launch's person key
    /// (`hub/person.rs`), as the pane that draws the parent chat does.
    async fn app(hub: &Arc<Hub>) -> Self {
        hub.person.enroll(KEY, true).unwrap();
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_authed(
            hub.clone(),
            in_rx,
            out_tx,
            Origin::LocalApp,
            ConnAuth::LocalApp,
        ));
        let mut c = Client(in_tx, out_rx, 0);
        let r = c.call("initialize", json!({"protocolVersion": 1})).await;
        let challenge = &r["result"]["_meta"]["acpmux"]["personChallenge"];
        let proof = acpmux::hub::person::person_proof(
            KEY,
            acpmux::hub::person::TRANSPORT_APP,
            challenge["nonce"].as_str().unwrap_or_else(|| panic!("{r}")),
            challenge["connection"].as_str().unwrap(),
        )
        .unwrap();
        let r = c.call("_acpmux/person_prove", json!({"proof": proof})).await;
        assert!(r.get("error").is_none(), "{r}");
        c
    }

    /// The connection an agent's tools open: `initialize` with its caller token.
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
}

#[tokio::test]
async fn a_childs_ask_shows_on_its_parent_and_the_persons_answer_there_answers_the_child() {
    let hub = hub();
    let mut app = Client::new(&hub);
    let new = json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"harness": "fake"}}});
    let parent = app.ok("session/new", new).await["sessionId"].as_str().unwrap().to_owned();
    let mut p = Client::as_session(&hub, &parent).await;

    // The parent's agent starts a sub-session that asks to run a command.
    let child =
        p.ok("_acpmux/subsession/start", json!({"prompt": "ask: make test"})).await["sessionId"]
            .as_str()
            .unwrap()
            .to_owned();
    let w = app
        .ok(
            "_acpmux/wait",
            json!({"sessions": [child], "until": ["permission"], "timeoutMs": 20000}),
        )
        .await;
    assert_eq!(w["timedOut"], false, "{w}");
    let pid = hub
        .events(&child, 0, 1000)
        .unwrap()
        .into_iter()
        .rfind(|e| e.kind == "permission_request")
        .expect("the child's permission_request")
        .msg["permissionId"]
        .as_str()
        .unwrap()
        .to_owned();

    // The parent's row says the person is needed, and how many asks below wait.
    let info = app.ok("_acpmux/info", json!({"sessionId": parent})).await;
    let summary = if info["summary"].is_object() { &info["summary"] } else { &info };
    assert_eq!(summary["subsessionsWaiting"], 1, "{summary}");
    assert_eq!(summary["indicator"], "input", "{summary}");

    // The parent's agent cannot allow its child's ask through the parent: the answer is the
    // child's, held to the child's rules (only the person allows).
    let r = p
        .call(
            "_acpmux/permission_respond",
            json!({"sessionId": parent, "permissionId": pid, "optionId": "yes"}),
        )
        .await;
    assert!(r.get("error").is_some(), "the agent allowed its child's ask: {r}");

    // The person's answer, sent to the parent by the app's pane as its page sends it, answers
    // the child.
    let mut pane = Client::app(&hub).await;
    pane.ok(
        "_acpmux/permission_respond",
        json!({"sessionId": parent, "permissionId": pid, "optionId": "yes"}),
    )
    .await;
    let w = app
        .ok("_acpmux/wait", json!({"sessions": [child], "until": ["ready"], "timeoutMs": 20000}))
        .await;
    assert_eq!(w["timedOut"], false, "{w}");
    let decision = hub
        .events(&child, 0, 1000)
        .unwrap()
        .into_iter()
        .rfind(|e| e.kind == "permission_decision")
        .expect("the child's permission_decision");
    assert_eq!(decision.msg["permissionId"], pid.as_str(), "{:?}", decision.msg);
    let reply = hub
        .events(&child, 0, 1000)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind == "agent_message_chunk")
        .filter_map(|e| {
            e.msg.pointer("/params/update/content/text").and_then(Value::as_str).map(str::to_owned)
        })
        .collect::<String>();
    assert!(reply.contains("chose yes"), "the child did not continue: {reply}");

    // Answered: the parent no longer reads input for it.
    let info = app.ok("_acpmux/info", json!({"sessionId": parent})).await;
    let summary = if info["summary"].is_object() { &info["summary"] } else { &info };
    assert_eq!(summary["subsessionsWaiting"], 0, "{summary}");
    assert_ne!(summary["indicator"], "input", "{summary}");

    // An id pending nowhere below stays the parent's own answer, refused as before.
    let r = app
        .call(
            "_acpmux/permission_respond",
            json!({"sessionId": parent, "permissionId": "no-such-ask", "optionId": "yes"}),
        )
        .await;
    assert!(r.get("error").is_some(), "{r}");
    hub.shutdown_all().await;
}
