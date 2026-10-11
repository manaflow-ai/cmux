//! Per-session env on `session/new` and `session/fork` (`_meta.acpmux.env`,
//! cx-ebm.40): the Chief gives each subagent CMUX_WORKSPACE_ID of its own
//! workspace, which a shared preset cannot. Only the unix socket may set it,
//! only allowlisted keys, small values; it reaches the harness, is recorded in
//! the session (and its summary), and a fork does not inherit it unless the
//! fork request sets it again.

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const WS: &str = "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D";

fn hub() -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE]}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all",
        "presets": {"sub": {"harness": "fake", "env": {"CMUX_WORKSPACE_ID": "from-preset", "OTHER": "kept"}}},
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

fn client(hub: &Arc<Hub>, origin: Origin) -> Client {
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
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
            let line = tokio::time::timeout(Duration::from_secs(20), self.1.recv())
                .await
                .unwrap()
                .unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return (v, text);
            }
            if let Some(t) = v.pointer("/params/update/content/text").and_then(Value::as_str) {
                text.push_str(t);
            }
        }
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        self.call_text(m, params).await.0
    }

    async fn env_of(&mut self, session: &str, name: &str) -> String {
        let prompt = json!({"sessionId": session, "prompt": [{"type": "text", "text": format!("env: {name}")}]});
        let (reply, text) = self.call_text("session/prompt", prompt).await;
        assert!(reply.get("error").is_none(), "{reply}");
        text
    }
}

fn new_params(meta: Value) -> Value {
    json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": meta}})
}

fn reason(reply: &Value) -> String {
    reply.pointer("/error/data/reason").and_then(Value::as_str).unwrap_or_default().to_owned()
}

#[tokio::test]
async fn the_unix_socket_sets_a_workspace_id_that_reaches_the_harness_over_the_preset() {
    let hub = hub();
    let mut local = client(&hub, Origin::Local);
    let reply = local
        .call("session/new", new_params(json!({"preset": "sub", "env": {"CMUX_WORKSPACE_ID": WS}})))
        .await;
    assert!(reply.get("error").is_none(), "{reply}");
    let id = reply["result"]["sessionId"].as_str().unwrap().to_owned();
    assert_eq!(local.env_of(&id, "CMUX_WORKSPACE_ID").await, format!("CMUX_WORKSPACE_ID={WS}"));
    assert_eq!(local.env_of(&id, "OTHER").await, "OTHER=kept", "the rest of the preset env stays");
    // Recorded in the session: its summary names it.
    let info = local.call("_acpmux/info", json!({"sessionId": id})).await;
    assert_eq!(info.pointer("/result/sessionEnv/CMUX_WORKSPACE_ID"), Some(&json!(WS)), "{info}");
}

#[tokio::test]
async fn only_the_unix_socket_may_set_session_env() {
    let hub = hub();
    for origin in [Origin::LocalApp, Origin::Web, Origin::Peer] {
        let mut c = client(&hub, origin);
        let reply =
            c.call("session/new", new_params(json!({"env": {"CMUX_WORKSPACE_ID": WS}}))).await;
        assert_eq!(reason(&reply), "env.origin_refused", "{origin:?}: {reply}");
    }
}

#[tokio::test]
async fn keys_off_the_allowlist_and_bad_values_are_refused() {
    let hub = hub();
    let mut local = client(&hub, Origin::Local);
    for key in ["PATH", "DYLD_INSERT_LIBRARIES", "CMUX_TUI_SOCKET", "HOME", "ANTHROPIC_BASE_URL"] {
        let reply = local.call("session/new", new_params(json!({"env": {key: "x"}}))).await;
        assert_eq!(reason(&reply), "env.key_refused", "{key}: {reply}");
        assert!(reply.to_string().contains(key), "the refusal names {key}: {reply}");
    }
    for bad in
        [json!("a".repeat(257)), json!("not-a-workspace"), json!(format!("{WS}\n")), json!(7)]
    {
        let reply =
            local.call("session/new", new_params(json!({"env": {"CMUX_WORKSPACE_ID": bad}}))).await;
        assert_eq!(reason(&reply), "env.value_refused", "{bad}: {reply}");
    }
    let reply = local.call("session/new", new_params(json!({"env": "CMUX_WORKSPACE_ID"}))).await;
    assert_eq!(reason(&reply), "env.value_refused", "{reply}");
}

#[tokio::test]
async fn a_fork_inherits_no_session_env_unless_it_sets_it_again() {
    let hub = hub();
    let mut local = client(&hub, Origin::Local);
    let reply = local
        .call("session/new", new_params(json!({"preset": "sub", "env": {"CMUX_WORKSPACE_ID": WS}})))
        .await;
    let id = reply["result"]["sessionId"].as_str().unwrap().to_owned();
    local.env_of(&id, "OTHER").await;
    let plain = local.call("session/fork", json!({"sessionId": id, "mcpServers": []})).await;
    assert!(plain.get("error").is_none(), "{plain}");
    let fork = plain["result"]["sessionId"].as_str().unwrap().to_owned();
    assert_eq!(
        local.env_of(&fork, "CMUX_WORKSPACE_ID").await,
        "CMUX_WORKSPACE_ID=from-preset",
        "the fork runs with the preset's value, not the parent's session env"
    );
    let other = "11111111-2222-4333-8444-555555555555";
    let again = local
        .call(
            "session/fork",
            json!({"sessionId": id, "mcpServers": [], "_meta": {"acpmux": {"env": {"CMUX_WORKSPACE_ID": other}}}}),
        )
        .await;
    assert!(again.get("error").is_none(), "{again}");
    let fork2 = again["result"]["sessionId"].as_str().unwrap().to_owned();
    assert_eq!(
        local.env_of(&fork2, "CMUX_WORKSPACE_ID").await,
        format!("CMUX_WORKSPACE_ID={other}")
    );
}

#[tokio::test]
async fn only_the_unix_socket_reads_a_session_env() {
    let hub = hub();
    let mut local = client(&hub, Origin::Local);
    let reply = local
        .call("session/new", new_params(json!({"preset": "sub", "env": {"CMUX_WORKSPACE_ID": WS}})))
        .await;
    let id = reply["result"]["sessionId"].as_str().unwrap().to_owned();
    assert!(!reply.to_string().contains(WS), "the session/new summary never carries it: {reply}");
    let info = local.call("_acpmux/info", json!({"sessionId": id})).await;
    assert_eq!(info.pointer("/result/sessionEnv/CMUX_WORKSPACE_ID"), Some(&json!(WS)), "{info}");
    let mut web = client(&hub, Origin::Web);
    for (m, p) in [("_acpmux/info", json!({"sessionId": id})), ("_acpmux/sessions", json!({}))] {
        let reply = web.call(m, p).await;
        let text = reply.to_string();
        assert!(
            !text.contains("sessionEnv") && !text.contains(WS),
            "Web {m} carried the session env: {text}"
        );
    }
}
