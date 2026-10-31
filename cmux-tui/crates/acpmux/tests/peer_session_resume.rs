//! ACP's `session/resume` of a peer's chat: forwarded only to a peer that lists `sessionResume`,
//! whose resume replays no history. A peer on an older build replays the whole chat for a
//! resume, as for a load, and the replay would reach the client through the link: the
//! capability `initialize` advertises would not hold (Codex review of #27795). Such a resume is
//! refused here and never sent.

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, HarnessProfile, PermissionPolicy, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::peer_auth::PeerAuth;
use acpmux::server::{WsAuth, bind_ws, serve_connection, serve_ws_with};
use futures::{SinkExt, StreamExt};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::Message as Ws;

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
    // A peer refuses a forwarded resume of a chat that does not ask (`remote_guard.rs`).
    cfg.permission_policy = PermissionPolicy::Ask;
    cfg.web_asking_modes.insert("fake".into(), vec!["normal".into()]);
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
        let (reply, updates) = self.raw(m, p).await;
        assert!(reply.get("error").is_none(), "{m}: {reply}");
        (reply["result"].clone(), updates)
    }

    /// The whole response to `m` (its result or its error), and the updates before it.
    async fn raw(&mut self, m: &str, p: Value) -> (Value, Vec<Value>) {
        self.next += 1;
        let id = self.next;
        self.tx.send(Message::request(id, m, p).to_line()).await.unwrap();
        let mut updates = Vec::new();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(20), self.rx.recv())
                .await
                .expect("timeout")
                .expect("closed");
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return (v, updates);
            }
            if v["method"] == method::SESSION_UPDATE {
                updates.push(v["params"].clone());
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
async fn resuming_a_peers_chat_is_forwarded_and_replays_nothing() {
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
    // B's answer, as for a resume of its own chat.
    assert_eq!(r["peer"], "b", "{r}");
    assert_eq!(r["modes"]["currentModeId"], "normal", "{r}");
    assert_eq!(r["_meta"]["acpmux"]["name"], "far", "{r}");

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

#[tokio::test]
async fn a_resume_is_never_sent_to_a_peer_whose_resume_replays() {
    // An older peer: it lists no `sessionResume`, and its resume would replay the chat.
    let resumes = Arc::new(AtomicUsize::new(0));
    let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    let counted = resumes.clone();
    tokio::spawn(async move {
        while let Ok((tcp, _)) = l.accept().await {
            let Ok(mut ws) = tokio_tungstenite::accept_async(tcp).await else { continue };
            let counted = counted.clone();
            tokio::spawn(async move {
                while let Some(Ok(Ws::Text(text))) = ws.next().await {
                    let Ok(Message::Request { id, method: m, .. }) = Message::parse(&text) else {
                        continue;
                    };
                    let result = match m.as_str() {
                        method::INITIALIZE => json!({"protocolVersion": 1, "_meta": {"acpmux": {
                            "build": "older", "origin": "peer", "features": ["trustGate"]}}}),
                        method::MUX_WATCH => json!({"sessions": [{"sessionId": "old-1"}]}),
                        method::SESSION_RESUME | method::SESSION_LOAD => {
                            counted.fetch_add(1, Ordering::SeqCst);
                            json!({})
                        }
                        _ => json!({}),
                    };
                    let reply = Message::ok(id, result).to_line();
                    if ws.send(Ws::Text(reply.trim_end().to_owned().into())).await.is_err() {
                        return;
                    }
                }
            });
        }
    });
    let a = hub().await;
    a.add_peer("old", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), None, true)
        .await
        .unwrap();
    let mut ca = client(a.clone()).await;
    let resume = json!({"sessionId": "old-1", "cwd": std::env::temp_dir(), "mcpServers": []});
    let (reply, _) = ca.raw(method::SESSION_RESUME, resume).await;
    assert_eq!(reply["error"]["data"]["reason"], "sessionResume.unsupported", "{reply}");
    assert!(reply["error"]["message"].as_str().unwrap().contains("acpmux host update old"));
    assert_eq!(resumes.load(Ordering::SeqCst), 0);
    // A load, which replays by design, still goes to it.
    let load = json!({"sessionId": "old-1", "cwd": std::env::temp_dir(), "mcpServers": []});
    let (reply, _) = ca.raw(method::SESSION_LOAD, load).await;
    assert!(reply.get("error").is_none(), "{reply}");
    assert_eq!(resumes.load(Ordering::SeqCst), 1);
}
