//! A prompt or a wait on a peer's session lasts as long as the peer's turn: the peer's
//! request deadline (`ACPMUX_PEER_REQUEST_SECS`, 600 s by default) never cuts it short, so
//! a turn longer than that no longer fails with `peer NAME timed out` while it still runs
//! (2026-10-21: cosmic-gray's sends to huge-blue lanes). The keepalive still drops a link
//! that stops answering. Two hubs: B serves WebSocket; A mirrors B as a peer.

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

fn config() -> Config {
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
    cfg
}

fn hub() -> Arc<Hub> {
    let cfg = config();
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

struct C {
    tx: mpsc::Sender<String>,
    rx: mpsc::Receiver<String>,
    next: i64,
}

impl C {
    async fn call(&mut self, m: &str, p: Value) -> Result<Value, String> {
        self.next += 1;
        let id = self.next;
        self.tx.send(Message::request(id, m, p).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(20), self.rx.recv())
                .await
                .expect("timeout")
                .expect("closed");
            if let Message::Response { id: rid, result, error } = Message::parse(&line).unwrap()
                && rid == id
            {
                return match error {
                    Some(e) => Err(e.message),
                    None => Ok(result.unwrap_or(Value::Null)),
                };
            }
        }
    }
}

const PERSON_KEY: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

async fn client(h: Arc<Hub>) -> C {
    let _ = h.person.install_spawn_key(PERSON_KEY);
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(h, in_rx, out_tx));
    let mut c = C { tx: in_tx, rx: out_rx, next: 0 };
    let hello = json!({"protocolVersion": 1, "clientInfo": {"name": "t"}});
    let init = c.call(method::INITIALIZE, hello).await.unwrap();
    let challenge = &init["_meta"]["acpmux"]["personChallenge"];
    let proof = acpmux::hub::person::person_proof(
        PERSON_KEY,
        acpmux::hub::person::TRANSPORT_UNIX,
        challenge["nonce"].as_str().unwrap(),
        challenge["connection"].as_str().unwrap(),
    )
    .unwrap();
    c.call("_acpmux/person_prove", json!({"proof": proof})).await.unwrap();
    c
}

async fn until_connected(a: &Hub) {
    let peer = a.peer_by_name("b").expect("peer b");
    let mut settled = peer.settled();
    let wait = async {
        while a.peers().into_iter().next().expect("one peer")["state"] != "connected" {
            settled.changed().await.expect("peer gone");
        }
    };
    tokio::time::timeout(Duration::from_secs(60), wait).await.expect("peer b never connected");
}

#[tokio::test]
async fn a_peer_turn_longer_than_the_request_deadline_still_answers() {
    // A 1 s request deadline and a 1 s ping, set before any peer exists. The fake agent's
    // "mute" turn says nothing for 2 s, then answers.
    // SAFETY: the only test in this binary, before any thread reads them.
    unsafe {
        std::env::set_var("ACPMUX_PEER_REQUEST_SECS", "1");
        std::env::set_var("ACPMUX_PEER_PING_SECS", "1");
    }
    let _ = HERMETIC;
    let b = hub();
    let home = std::env::temp_dir().join(format!("aplt-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    let auth = PeerAuth::create(&home).unwrap();
    let peer_token = std::fs::read_to_string(acpmux::server::peer_auth::token_path(&home)).unwrap();
    let l = bind_ws("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    let ws_auth = WsAuth { local_app: None, peer: Some(Arc::new(auth)) };
    tokio::spawn(serve_ws_with(b.clone(), l, "tok".into(), ws_auth));
    let mut cb = client(b.clone()).await;
    cb.call(
        method::SESSION_NEW,
        json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"name": "lane"}}}),
    )
    .await
    .unwrap();

    let a = hub();
    let url = format!("ws://127.0.0.1:{port}");
    a.add_peer("b", &url, Some("tok".into()), Some(peer_token), true).await.unwrap();
    until_connected(&a).await;

    let mut ca = client(a.clone()).await;
    let prompt = json!({"sessionId": "b/lane", "prompt": [{"type": "text", "text": "mute"}]});
    let answered = ca.call(method::SESSION_PROMPT, prompt).await;
    assert_eq!(
        answered.as_ref().map(|r| r["stopReason"].clone()),
        Ok(json!("end_turn")),
        "the peer's turn outlived the request deadline: {answered:?}"
    );
    let _ = std::fs::remove_dir_all(&home);
}
