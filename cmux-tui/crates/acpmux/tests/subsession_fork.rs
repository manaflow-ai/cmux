//! `start_session` with `fork: true` (`hub/subsessions.rs`): an agent forks its own chat, as the
//! person's Fork Conversation does. The fork has the chat's history and its `parentId` and
//! `forkSeq` (the chat shows it was forked), it is the agent's sub-session (`startedBy`, its
//! short name) that runs the prompt, and a fork that names its own harness, model, effort,
//! folder or worktree is refused before anything starts.
//!
//! Stand-in agents (fake_agent.py). One test function: the settings file is read from this
//! process's environment.

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
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const START: &str = "_acpmux/subsession/start";

fn hub() -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE]}},
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

    /// The connection an agent's tools open: `initialize` with its caller token.
    async fn as_session(hub: &Arc<Hub>, id: &str) -> Self {
        let mut c = Self::new(hub);
        let token = acpmux::hub::person::caller_token(id);
        c.ok(
            "initialize",
            json!({"protocolVersion": 1,
                   "_meta": {"acpmux": {"callerSession": {"sessionId": id, "token": token}}}}),
        )
        .await;
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
async fn an_agent_forks_its_own_chat_as_its_sub_session() {
    let root =
        std::env::temp_dir().join(format!("acpmux-subsession-fork-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&root).unwrap();
    let settings = root.join("cmux-next.json");
    std::fs::write(&settings, "{}").unwrap();
    // SAFETY: the only test in this binary; set before any session starts.
    unsafe {
        std::env::set_var("CMUX_NEXT_CONFIG_FILE", &settings);
        std::env::set_var("ACPMUX_HOME", root.join("home"));
        std::env::set_var("FLEET_REGISTRY", root.join("fleet-registry.json"));
    }
    std::fs::write(root.join("fleet-registry.json"), r#"{"machines": {}}"#).unwrap();
    let hub = hub();
    let mut app = Client::new(&hub);
    let new = json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"harness": "fake"}}});
    let chat = app.ok("session/new", new).await["sessionId"].as_str().unwrap().to_owned();
    app.ok(
        "session/prompt",
        json!({"sessionId": chat, "prompt": [{"type": "text", "text": "echo the plan"}]}),
    )
    .await;

    let mut agent = Client::as_session(&hub, &chat).await;
    // A fork runs the chat's own harness, model and folder: naming one is refused, and
    // nothing starts.
    for own in [
        json!({"harness": "fake"}),
        json!({"model": "m"}),
        json!({"effort": "high"}),
        json!({"cwd": std::env::temp_dir()}),
        json!({"worktree": true}),
    ] {
        let mut params = json!({"prompt": "echo other", "fork": true});
        params.as_object_mut().unwrap().extend(own.as_object().unwrap().clone());
        let r = agent.call(START, params).await;
        let message = r["error"]["message"].as_str().unwrap_or_default();
        assert!(message.contains("a fork runs your harness"), "{own}: {r}");
    }
    assert_eq!(hub.sessions().len(), 1);

    let started = agent
        .ok(START, json!({"prompt": "echo you are the fork", "name": "Branch", "fork": true}))
        .await;
    assert_eq!(started["shortName"], "branch", "{started}");
    assert_eq!(started["depth"], 1, "{started}");
    let fork = started["sessionId"].as_str().unwrap().to_owned();
    assert_ne!(fork, chat);

    // A fork of the chat: its parent and the point it was forked at, and the chat's history.
    let meta = hub.resolve(&fork).unwrap().meta();
    assert_eq!(meta.parent_id.as_deref(), Some(chat.as_str()));
    assert!(meta.fork_seq.is_some_and(|seq| seq > 0), "{:?}", meta.fork_seq);
    // And the agent's sub-session.
    let link = meta.subsession.clone().expect("a sub-session link");
    assert_eq!(link.started_by, chat);
    assert_eq!(link.short_name, "branch");
    assert!(meta.name.ends_with("/branch"), "{}", meta.name);

    agent
        .ok("_acpmux/wait", json!({"sessions": [fork], "until": ["ready"], "timeoutMs": 20000}))
        .await;
    let texts: Vec<String> = hub
        .events(&fork, 0, 1000)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind == "user_message")
        .map(|e| e.msg.to_string())
        .collect();
    assert!(texts.iter().any(|t| t.contains("echo the plan")), "{texts:?}");
    assert!(texts.iter().any(|t| t.contains("echo you are the fork")), "{texts:?}");
    let got = agent.ok("_acpmux/subsession/get", json!({"sessionId": fork})).await;
    assert_eq!(got["lastReply"], "echo: echo you are the fork", "{got}");
    let list = agent.ok("_acpmux/subsession/list", json!({})).await;
    assert_eq!(list["sessions"].as_array().unwrap().len(), 1, "{list}");
}
