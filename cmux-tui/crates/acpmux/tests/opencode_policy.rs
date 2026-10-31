//! An OpenCode chat whose permission policy is narrower than approve-all (its
//! own, or deny-all as the daemon default) starts its agent with
//! `OPENCODE_CONFIG_CONTENT` asking before every tool (`"permission": {"*":
//! "ask"}`), so each tool call reaches acpmux's policy as a
//! `session/request_permission` (`hub/policy_mode.rs`). A config the profile
//! already passes keeps everything but its `permission`; one that is not JSON
//! is kept as it is. An approve-all chat, and a chat on another harness, get
//! nothing. A policy narrowed on a live chat restarts its agent between turns,
//! in the same conversation, with the config.
//!
//! Direct children of an in-process hub, with the stand-in agent
//! (fake_agent.py `env:`). Agent hosts and the session pool: `session_pool.rs`.

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
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const KEY: &str = "OPENCODE_CONFIG_CONTENT";
/// The config a profile passes: a model of its own, and rules that never ask.
const OWN: &str = r#"{"model":"own/model","permission":{"*":"allow","bash":"allow"}}"#;

fn hub(default_policy: &str) -> Arc<Hub> {
    let oc = |env: Value| json!({"argv": ["python3", FAKE], "family": "opencode", "env": env});
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {
            "oc": oc(json!({})),
            "oc-own": oc(json!({KEY: OWN})),
            "oc-bad": oc(json!({KEY: "not json"})),
            "fake": {"argv": ["python3", FAKE], "family": "fake"},
        },
        "defaultHarness": "oc",
        "permissionPolicy": default_policy,
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

fn client(hub: &Arc<Hub>) -> Client {
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
    Client(in_tx, out_rx, 0)
}

impl Client {
    /// The reply to one request, and the agent text streamed before it.
    async fn call_text(&mut self, m: &str, params: Value) -> (Value, String) {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, m, params).to_line()).await.unwrap();
        let mut text = String::new();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                .await
                .expect("an answer in time")
                .expect("the connection stays open");
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return (v, text);
            }
            if let Some(t) = v.pointer("/params/update/content/text").and_then(Value::as_str) {
                text.push_str(t);
            }
        }
    }

    async fn ok(&mut self, m: &str, params: Value) -> Value {
        let (reply, _) = self.call_text(m, params).await;
        assert!(reply.get("error").is_none(), "{m}: {reply}");
        reply["result"].clone()
    }

    /// A new chat on `harness`, with its own `policy` when given.
    async fn chat(&mut self, harness: &str, policy: Option<&str>) -> String {
        let mut meta = json!({"harness": harness});
        if let Some(p) = policy {
            meta["policy"] = json!(p);
        }
        let params =
            json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": meta}});
        let created = self.ok("session/new", params).await;
        created["sessionId"].as_str().expect("a session id").to_owned()
    }

    /// The `OPENCODE_CONFIG_CONTENT` the chat's agent runs with, as it reports it.
    async fn config_of(&mut self, session: &str) -> String {
        let prompt = json!({"sessionId": session, "prompt": [{"type": "text", "text": format!("env: {KEY}")}]});
        let (reply, text) = self.call_text("session/prompt", prompt).await;
        assert!(reply.get("error").is_none(), "{reply}");
        text.strip_prefix(&format!("{KEY}="))
            .unwrap_or_else(|| panic!("the agent's answer names {KEY}: {text:?}"))
            .to_owned()
    }
}

fn parsed(config: &str) -> Value {
    serde_json::from_str(config).unwrap_or_else(|e| panic!("{config:?} is JSON: {e}"))
}

#[tokio::test]
async fn opencode_policy_a_narrower_policy_asks_opencode_to_ask_for_every_tool() {
    let hub = hub("approve-all");
    let mut c = client(&hub);
    for policy in ["ask", "approve-reads", "approve-edits", "deny-all"] {
        let chat = c.chat("oc", Some(policy)).await;
        assert_eq!(
            parsed(&c.config_of(&chat).await),
            json!({"permission": {"*": "ask"}}),
            "{policy}"
        );
    }
    // approve-all, its own or the default's: OpenCode's own settings, untouched.
    for policy in [Some("approve-all"), None] {
        let chat = c.chat("oc", policy).await;
        assert_eq!(c.config_of(&chat).await, "", "{policy:?}");
    }
    // Another harness never gets OpenCode's config.
    let chat = c.chat("fake", Some("approve-reads")).await;
    assert_eq!(c.config_of(&chat).await, "");
}

#[tokio::test]
async fn opencode_policy_deny_all_as_the_default_asks_opencode_to_ask() {
    let hub = hub("deny-all");
    let mut c = client(&hub);
    let chat = c.chat("oc", None).await;
    assert_eq!(parsed(&c.config_of(&chat).await), json!({"permission": {"*": "ask"}}));
}

#[tokio::test]
async fn opencode_policy_a_profile_config_is_merged_not_clobbered() {
    let hub = hub("approve-all");
    let mut c = client(&hub);
    let chat = c.chat("oc-own", Some("approve-reads")).await;
    assert_eq!(
        parsed(&c.config_of(&chat).await),
        json!({"model": "own/model", "permission": {"*": "ask"}}),
        "the profile's model stays; only its permission is replaced"
    );
    let chat = c.chat("oc-own", Some("approve-all")).await;
    assert_eq!(c.config_of(&chat).await, OWN, "approve-all changes nothing");
    // A config that is not JSON is kept as it is (and the chat says the policy may not hold).
    let chat = c.chat("oc-bad", Some("approve-reads")).await;
    assert_eq!(c.config_of(&chat).await, "not json");
}

#[tokio::test]
async fn opencode_policy_narrowed_on_a_live_chat_restarts_its_agent_asking() {
    let hub = hub("approve-all");
    let mut c = client(&hub);
    let chat = c.chat("oc", None).await;
    assert_eq!(c.config_of(&chat).await, "", "an approve-all chat starts with nothing");
    c.ok("_acpmux/set_policy", json!({"sessionId": chat, "policy": "ask"})).await;
    assert_eq!(
        parsed(&c.config_of(&chat).await),
        json!({"permission": {"*": "ask"}}),
        "the agent started again with the config"
    );
    // Narrowed further: the agent already asks, and keeps the config.
    c.ok("_acpmux/set_policy", json!({"sessionId": chat, "policy": "deny-all"})).await;
    assert_eq!(parsed(&c.config_of(&chat).await), json!({"permission": {"*": "ask"}}));
}
