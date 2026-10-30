//! ACP's `session/resume` of a peer's chat: this daemon answers it itself once the client is
//! subscribed and the link attached, and never sends it on the link. A peer on an older build
//! replays the whole chat for a resume, as for a load, and the replay would reach the client
//! through the link: the capability `initialize` advertises would not hold (Codex review of
//! #27795).

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, HarnessProfile, PermissionPolicy, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::peer_auth::PeerAuth;
use acpmux::server::{WsAuth, bind_ws, serve_connection, serve_ws_with};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const PERSON_KEY: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

async fn hub() -> Arc<Hub> {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let profile = HarnessProfile {
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
    };
    let mut cfg = Config {
        harnesses: BTreeMap::from([("fake".to_owned(), profile)]),
        default_harness: Some("fake".into()),
        ..Default::default()
    };
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
    /// The answer to `m`, and the `session/update` notices that came before it.
    async fn call(&mut self, m: &str, p: Value) -> (Value, Vec<Value>) {
        self.next += 1;
        let id = self.next;
        self.tx.send(Message::request(id, m, p).to_line()).await.unwrap();
        let mut updates = Vec::new();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(20), self.rx.recv())
                .await
                .expect("timeout")
                .expect("closed");
            match Message::parse(&line).unwrap() {
                Message::Response { id: rid, result, error } if rid == id => {
                    assert!(error.is_none(), "{m}: {error:?}");
                    return (result.unwrap_or(Value::Null), updates);
                }
                Message::Notification { method: got, params } if got == method::SESSION_UPDATE => {
                    updates.push(params.unwrap_or(Value::Null));
                }
                _ => {}
            }
        }
    }

    async fn wait_update(&mut self, pred: impl Fn(&Value) -> bool) -> Value {
        loop {
            let line = tokio::time::timeout(Duration::from_secs(20), self.rx.recv())
                .await
                .expect("timeout")
                .expect("closed");
            if let Message::Notification { method: got, params } = Message::parse(&line).unwrap() {
                let p = params.unwrap_or(Value::Null);
                if got == method::SESSION_UPDATE && pred(&p) {
                    return p;
                }
            }
        }
    }
}

/// A connection that stands for the person at `h`'s app (`hub/person.rs`).
async fn client(h: Arc<Hub>) -> C {
    let _ = h.person.install_spawn_key(PERSON_KEY);
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(h, in_rx, out_tx));
    let mut c = C { tx: in_tx, rx: out_rx, next: 0 };
    let hello = json!({"protocolVersion": 1, "clientInfo": {"name": "t"}});
    let (init, _) = c.call(method::INITIALIZE, hello).await;
    let challenge = &init["_meta"]["acpmux"]["personChallenge"];
    let proof = acpmux::hub::person::person_proof(
        PERSON_KEY,
        acpmux::hub::person::TRANSPORT_UNIX,
        challenge["nonce"].as_str().unwrap(),
        challenge["connection"].as_str().unwrap(),
    )
    .unwrap();
    c.call("_acpmux/person_prove", json!({"proof": proof})).await;
    c
}

#[tokio::test]
async fn resuming_a_peers_chat_replays_nothing_and_is_not_sent_to_the_peer() {
    // B owns the chat and serves WebSocket with a peer token; A mirrors B.
    let b = hub().await;
    let home = std::env::temp_dir().join(format!("apsr-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    let auth = PeerAuth::create(&home).unwrap();
    let token = std::fs::read_to_string(acpmux::server::peer_auth::token_path(&home)).unwrap();
    let l = bind_ws("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    let ws_auth = WsAuth { local_app: None, peer: Some(Arc::new(auth)) };
    tokio::spawn(serve_ws_with(b.clone(), l, "tok".into(), ws_auth));
    let mut cb = client(b.clone()).await;
    let new = json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"name": "far"}}});
    let (s, _) = cb.call(method::SESSION_NEW, new).await;
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let before = json!({"sessionId": id, "prompt": [{"type": "text", "text": "before"}]});
    cb.call(method::SESSION_PROMPT, before).await;

    let a = hub().await;
    a.add_peer("b", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), Some(token), true)
        .await
        .unwrap();
    let mut ca = client(a.clone()).await;
    let resume = json!({"sessionId": "b/far", "cwd": std::env::temp_dir(), "mcpServers": []});
    let (r, updates) = ca.call(method::SESSION_RESUME, resume).await;
    assert!(updates.is_empty(), "session/resume replayed the peer's chat: {updates:?}");
    // A's own answer: B's would carry the chat's modes and summary, so B was never asked and a
    // B on any build replays nothing here.
    assert_eq!(r, json!({"peer": "b"}));

    // Subscribed: the next turn on B reaches the resumed client, live.
    let after = json!({"sessionId": id, "prompt": [{"type": "text", "text": "after"}]});
    cb.call(method::SESSION_PROMPT, after).await;
    let live = ca
        .wait_update(|p| {
            p["update"]["sessionUpdate"] == "agent_message_chunk"
                && p["update"]["content"]["text"] == "echo: after"
        })
        .await;
    assert_ne!(live["_meta"]["acpmux"]["replay"], true, "{live}");
    let _ = std::fs::remove_dir_all(&home);
}
