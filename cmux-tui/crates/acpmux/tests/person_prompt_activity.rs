//! The Cloud activity report's `last_person_prompt_at` (`hub/person_prompt_at.rs`): a person's
//! prompt into a chat sets it; another agent's message and a send from inside a session do not.

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, HarnessProfile, PermissionPolicy, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::{Origin, serve_connection, serve_connection_with};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

fn hub() -> Arc<Hub> {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut agents = BTreeMap::new();
    agents.insert(
        "fake".to_owned(),
        HarnessProfile {
            kind: Default::default(),
            argv: vec!["python3".into(), fake.into()],
            env: BTreeMap::new(),
            description: None,
            fallback: None,
            family: None,
            models: vec![],
            model: None,
            effort: None,
            policy: None,
        },
    );
    let mut cfg =
        Config { harnesses: agents, default_harness: Some("fake".into()), ..Default::default() };
    cfg.store.mode = StoreMode::Memory;
    cfg.permission_policy = PermissionPolicy::ApproveAll;
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

struct C {
    tx: mpsc::Sender<String>,
    rx: mpsc::Receiver<String>,
    next: i64,
}

impl C {
    async fn new(h: Arc<Hub>) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(h, in_rx, out_tx, Origin::Local));
        let mut c = C { tx: in_tx, rx: out_rx, next: 0 };
        c.call(method::INITIALIZE, json!({"protocolVersion": 1, "clientInfo": {"name": "t"}}))
            .await
            .unwrap();
        c
    }

    /// The connection a session's own tools open: `initialize` with its caller token.
    async fn as_session(h: Arc<Hub>, id: &str) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection(h, in_rx, out_tx));
        let mut c = C { tx: in_tx, rx: out_rx, next: 0 };
        let token = acpmux::hub::person::caller_token(id);
        c.call(
            method::INITIALIZE,
            json!({"protocolVersion": 1,
                   "_meta": {"acpmux": {"callerSession": {"sessionId": id, "token": token}}}}),
        )
        .await
        .unwrap();
        c
    }

    async fn call(&mut self, m: &str, p: Value) -> Result<Value, String> {
        self.next += 1;
        let id = self.next;
        self.tx.send(Message::request(id, m, p).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(20), self.rx.recv())
                .await
                .expect("timeout")
                .expect("closed");
            if let Ok(Message::Response { id: rid, result, error }) = Message::parse(&line)
                && rid == id
            {
                return match error {
                    Some(e) => Err(e.message),
                    None => Ok(result.unwrap_or(Value::Null)),
                };
            }
        }
    }

    async fn new_session(&mut self, name: &str) -> String {
        self.call(
            method::SESSION_NEW,
            json!({"cwd": std::env::temp_dir(), "mcpServers": [],
                   "_meta": {"acpmux": {"name": name}}}),
        )
        .await
        .unwrap()["sessionId"]
            .as_str()
            .unwrap()
            .to_owned()
    }
}

fn prompt(session: &str, text: &str) -> Value {
    json!({"sessionId": session, "prompt": [{"type": "text", "text": text}]})
}

#[tokio::test]
async fn a_persons_prompt_sets_the_time_and_an_agents_send_does_not() {
    let h = hub();
    let mut person = C::new(h.clone()).await;
    let sender = person.new_session("prompt-sender").await;
    let receiver = person.new_session("prompt-receiver").await;
    assert_eq!(h.last_person_prompt_at(), None, "no prompt yet");

    // Another agent's message (its provenance) is not a person's prompt.
    let mut message = prompt(&receiver, "from an agent");
    message["_meta"] = json!({"acpmux": {"provenance": {
        "kind": "agent_message", "from": format!("acp:{sender}"), "fromName": "prompt-sender",
        "to": format!("acp:{receiver}"), "msgId": "m-1", "threadId": "t-1"}}});
    let _ = person.call(method::SESSION_PROMPT, message).await;
    assert_eq!(h.last_person_prompt_at(), None, "an agent's message");

    // A send from inside a session (its caller token) is that session's agent, not a person.
    let mut agent = C::as_session(h.clone(), &sender).await;
    let _ = agent.call(method::SESSION_PROMPT, prompt(&receiver, "from inside a session")).await;
    assert_eq!(h.last_person_prompt_at(), None, "a send from inside a session");

    // The person's own prompt sets it, at about now.
    let before = acpmux::store::now_ms();
    person.call(method::SESSION_PROMPT, prompt(&receiver, "hello")).await.unwrap();
    let at = h.last_person_prompt_at().expect("a person's prompt sets it");
    assert!(at >= before && at <= acpmux::store::now_ms(), "{at} vs {before}");

    // A later agent's message leaves it where the person's prompt put it.
    let _ = agent.call(method::SESSION_PROMPT, prompt(&receiver, "again from inside")).await;
    assert_eq!(h.last_person_prompt_at(), Some(at));
}
