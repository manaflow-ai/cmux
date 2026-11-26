//! An agent that signs in with an API key at the handshake (Antigravity's `agy acp`): the hub
//! calls `authenticate` with `gemini-api-key` when the launch has `GEMINI_API_KEY`
//! (`acp_key_auth.rs`), so the chat starts; with no key, or for Gemini CLI, it asks nothing.

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

fn hub(family: &str, key: &str) -> Arc<Hub> {
    let env = json!({"FAKE_REQUIRE_KEY_AUTH": "1", "GEMINI_API_KEY": key});
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE], "family": family, "env": env}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all"
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    fn open(hub: &Arc<Hub>) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
        Self(in_tx, out_rx, 0)
    }

    /// The reply to `method`: its result, or its error.
    async fn ask(&mut self, method: &str, params: Value) -> Value {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, method, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                .await
                .expect("timed out")
                .expect("connection closed");
            let value: Value = serde_json::from_str(&line).unwrap();
            if value.get("id") == Some(&json!(id)) {
                return value;
            }
        }
    }

    /// Whether a chat starts and answers a prompt.
    async fn chat_runs(&mut self) -> Result<(), Value> {
        let new = json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"harness": "fake"}}});
        let new = self.ask("session/new", new).await;
        if new.get("error").is_some() {
            return Err(new);
        }
        let session = new["result"]["sessionId"].as_str().unwrap().to_owned();
        let prompt = json!({"sessionId": session, "prompt": [{"type": "text", "text": "hi"}]});
        let reply = self.ask("session/prompt", prompt).await;
        if reply.get("error").is_some() {
            return Err(reply);
        }
        Ok(())
    }
}

#[tokio::test]
async fn a_key_signs_the_agent_in_before_its_session() {
    let hub = hub("antigravity", "fake-key");
    let mut c = Client::open(&hub);
    c.chat_runs().await.expect("the chat on a key did not start");
}

#[tokio::test]
async fn no_key_asks_no_sign_in() {
    let hub = hub("antigravity", "");
    let mut c = Client::open(&hub);
    let err = c.chat_runs().await.expect_err("the agent started with no sign-in");
    assert!(err.to_string().contains("Authentication required"), "{err}");
}

#[tokio::test]
async fn gemini_cli_is_not_signed_in_for() {
    let hub = hub("gemini", "fake-key");
    let mut c = Client::open(&hub);
    c.chat_runs().await.expect_err("acpmux signed Gemini CLI in");
}
