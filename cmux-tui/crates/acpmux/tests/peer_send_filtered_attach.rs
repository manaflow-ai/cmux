//! A send to a peer's chat after another client here attached it with a `kinds` filter (the
//! app's tool-call watch): the link's one subscription at the peer streams only those kinds, and
//! a prompt keeps it as it is. The send's own attach goes to the peer and widens it again, or the
//! agent's reply would never reach the sender (review of #38305, P1).
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::peer_auth::PeerAuth;
use acpmux::server::{Origin, WsAuth, bind_ws, serve_connection_with, serve_ws_with};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock};
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

fn home() -> &'static Path {
    static HOME: OnceLock<PathBuf> = OnceLock::new();
    HOME.get_or_init(|| {
        let home =
            std::env::temp_dir().join(format!("acpmux-filtered-attach-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        acpmux::config::set_home_override(home.clone());
        home
    })
}

fn hub() -> Arc<Hub> {
    home();
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE], "family": "codex"}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all"
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
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
    /// The reply to `m`, and the agent text streamed before it.
    async fn call_text(&mut self, m: &str, params: Value) -> (Value, String) {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, m, params).to_line()).await.unwrap();
        let mut text = String::new();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                .await
                .unwrap()
                .unwrap();
            let value: Value = serde_json::from_str(&line).unwrap();
            if value.get("id") == Some(&json!(id)) {
                return (value, text);
            }
            if let Some(chunk) =
                value.pointer("/params/update/content/text").and_then(Value::as_str)
            {
                text.push_str(chunk);
            }
        }
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        self.call_text(m, params).await.0
    }
}

#[tokio::test]
async fn a_send_after_a_filtered_attachment_hears_the_agents_reply() {
    // B runs the chat; A mirrors B as a peer.
    let b = hub();
    let dir = std::env::temp_dir().join(format!("filtered-attach-peer-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let auth = PeerAuth::create(&dir).unwrap();
    let token = std::fs::read_to_string(acpmux::server::peer_auth::token_path(&dir)).unwrap();
    let l = bind_ws("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    let ws_auth = WsAuth { local_app: None, peer: Some(Arc::new(auth)) };
    tokio::spawn(serve_ws_with(b.clone(), l, "tok".into(), ws_auth));
    let mut cb = client(&b);
    let made = cb
        .call(
            method::SESSION_NEW,
            json!({"cwd": std::env::temp_dir(), "mcpServers": [],
                   "_meta": {"acpmux": {"name": "watched"}}}),
        )
        .await;
    assert!(made["result"]["sessionId"].is_string(), "{made}");
    let a = hub();
    a.add_peer("b", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), Some(token), true)
        .await
        .unwrap();

    // The app watches the chat's tool calls only: the link attaches it with that filter.
    let mut app = client(&a);
    let watch = json!({"sessionId": "b/watched", "limit": 0, "eventStream": true,
                       "kinds": ["tool_call"]});
    let watched = app.call(method::MUX_ATTACH, watch).await;
    assert!(watched.get("error").is_none(), "{watched}");

    // `acpmux send`: it reads the chat's info from the row, subscribes (`limit: 0`), then
    // prompts.
    let mut send = client(&a);
    let info = send.call(method::MUX_INFO, json!({"sessionId": "b/watched", "row": true})).await;
    assert!(info.get("error").is_none(), "{info}");
    let sub = json!({"sessionId": "b/watched", "limit": 0});
    let subscribed = send.call(method::MUX_ATTACH, sub).await;
    assert!(subscribed.get("error").is_none(), "{subscribed}");
    let prompt = json!({"sessionId": "b/watched", "prompt": [{"type": "text", "text": "hello"}]});
    let (reply, text) = send.call_text(method::SESSION_PROMPT, prompt).await;
    assert!(reply.get("error").is_none(), "{reply}");
    assert!(text.contains("hello"), "the agent's reply never reached the send: {text:?} {reply}");
}
