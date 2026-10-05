//! Two hubs: B serves WebSocket, A mirrors B as a peer. Everything for B's
//! sessions is driven through A's protocol handler.

use acpmux::config::{Config, HarnessProfile, PermissionPolicy, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::peer_auth::PeerAuth;
use acpmux::server::{WsAuth, bind_ws, listen_ws, serve_connection, serve_ws_with};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

fn config(policy: PermissionPolicy) -> Config {
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
    cfg.permission_policy = policy;
    cfg
}

async fn hub(cfg: Config) -> Arc<Hub> {
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
    async fn wait(&mut self, m: &str, pred: impl Fn(&Value) -> bool) -> Value {
        loop {
            let line = tokio::time::timeout(Duration::from_secs(20), self.rx.recv())
                .await
                .expect("timeout")
                .expect("closed");
            if let Message::Notification { method: got, params } = Message::parse(&line).unwrap() {
                let p = params.unwrap_or(Value::Null);
                if got == m && pred(&p) {
                    return p;
                }
            }
        }
    }
}

async fn client(h: Arc<Hub>) -> C {
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(h, in_rx, out_tx));
    let mut c = C { tx: in_tx, rx: out_rx, next: 0 };
    c.call(method::INITIALIZE, json!({"protocolVersion": 1, "clientInfo": {"name": "t"}}))
        .await
        .unwrap();
    c
}

/// B's WebSocket listener with a peer token (`server/peer_auth.rs`);
/// returns its port and the token, which A gets as `peerToken`.
async fn listen_with_peer_token(b: Arc<Hub>, tag: &str) -> (u16, String) {
    let home = std::env::temp_dir().join(format!("api-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    let auth = PeerAuth::create(&home).unwrap();
    let token = std::fs::read_to_string(acpmux::server::peer_auth::token_path(&home)).unwrap();
    let l = bind_ws("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    let auth = WsAuth { local_app: None, peer: Some(Arc::new(auth)) };
    tokio::spawn(serve_ws_with(b, l, "tok".into(), auth));
    (port, token)
}

fn free_port() -> u16 {
    std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port()
}

#[tokio::test]
async fn peer_sessions_are_listed_prompted_and_permission_routed() {
    // B: serves WebSocket with a token, owns the agent.
    let b = hub(config(PermissionPolicy::Ask)).await;
    let (port, peer_token) = listen_with_peer_token(b.clone(), "routed").await;
    let mut cb = client(b.clone()).await;
    let s = cb.call(method::SESSION_NEW, json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"name": "remote-one"}}})).await.unwrap();
    let remote_id = s["sessionId"].as_str().unwrap().to_owned();

    // A: mirrors B.
    let a = hub(config(PermissionPolicy::Ask)).await;
    // `wait`: add_peer answers once the first connect settled, with B's
    // sessions already listed on A.
    a.add_peer("b", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), Some(peer_token), true)
        .await
        .unwrap();
    // B serves A as a peer, not as a Web client.
    assert_eq!(a.peers()[0]["servedAs"], "peer", "{:?}", a.peers());
    let mut ca = client(a.clone()).await;
    let v = ca.call(method::MUX_SESSIONS, json!({})).await.unwrap();
    assert!(
        v["sessions"].as_array().unwrap().iter().any(|x| x["name"] == "b/remote-one"),
        "peer session not listed after add_peer settled: {v}"
    );

    // Prompt through A by the prefixed name; the reply streams to A's client.
    ca.call(method::MUX_ATTACH, json!({"session": "b/remote-one", "limit": 0})).await.unwrap();
    let r = ca
        .call(
            method::SESSION_PROMPT,
            json!({"sessionId": "b/remote-one", "prompt": [{"type": "text", "text": "via a"}]}),
        )
        .await
        .unwrap();
    assert_eq!(r["stopReason"], "end_turn");
    assert_eq!(r["peer"], "b");
    let info = ca.call(method::MUX_INFO, json!({"session": remote_id.clone()})).await.unwrap();
    assert_eq!(info["preview"], "echo: via a");

    // Permission raised on B is answered from A.
    ca.next += 1;
    let pid = ca.next;
    ca.tx
        .send(
            Message::request(
                pid,
                method::SESSION_PROMPT,
                json!({"sessionId": remote_id, "prompt": [{"type": "text", "text": "ask: rm"}]}),
            )
            .to_line(),
        )
        .await
        .unwrap();
    let pending = ca.wait(method::MUX_PERMISSION_PENDING, |p| p["sessionId"] == remote_id).await;
    let perm = pending["permissionId"].as_str().unwrap().to_owned();
    ca.call(
        method::MUX_PERMISSION_RESPOND,
        json!({"sessionId": remote_id, "permissionId": perm, "optionId": "yes"}),
    )
    .await
    .unwrap();
    let end = ca
        .wait(method::MUX_EVENT, |p| p["kind"] == "turn_end" && p["sessionId"] == remote_id)
        .await;
    assert_eq!(end["msg"]["stopReason"], "end_turn");

    // Watchers on A get session_changed for the remote session.
    ca.call(method::MUX_WATCH, json!({})).await.unwrap();
    ca.next += 1;
    let pid = ca.next;
    ca.tx
        .send(
            Message::request(
                pid,
                method::SESSION_PROMPT,
                json!({"sessionId": remote_id, "prompt": [{"type": "text", "text": "z"}]}),
            )
            .to_line(),
        )
        .await
        .unwrap();
    let changed = ca
        .wait(method::MUX_SESSION_CHANGED, |p| {
            p["session"]["sessionId"] == remote_id && p["kind"] == "turn_end"
        })
        .await;
    assert_eq!(changed["peer"], "b");
    assert_eq!(changed["session"]["name"], "b/remote-one");

    // A's status names the peer.
    let st = ca.call(method::MUX_STATUS, json!({})).await.unwrap();
    assert_eq!(st["peers"][0]["name"], "b");
    assert_eq!(st["peers"][0]["connected"], true);
}

#[tokio::test]
async fn watchers_learn_peer_sessions_that_arrive_after_their_snapshot() {
    let b = hub(config(PermissionPolicy::Ask)).await;
    let port = free_port();
    tokio::spawn(listen_ws(b.clone(), format!("127.0.0.1:{port}"), "tok".into()));
    let mut cb = client(b.clone()).await;
    let s = cb
        .call(
            method::SESSION_NEW,
            json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"name": "late"}}}),
        )
        .await
        .unwrap();
    let remote_id = s["sessionId"].as_str().unwrap().to_owned();

    // A client watches A before A knows about B, as a TUI does when it
    // starts the daemon and the ssh tunnel is still opening.
    let a = hub(config(PermissionPolicy::Ask)).await;
    let mut ca = client(a.clone()).await;
    ca.call(method::MUX_WATCH, json!({"enabled": true})).await.unwrap();
    let v = ca.call(method::MUX_SESSIONS, json!({})).await.unwrap();
    assert!(v["sessions"].as_array().unwrap().is_empty());
    a.add_peer("b", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), None, false)
        .await
        .unwrap();
    let changed =
        ca.wait(method::MUX_SESSION_CHANGED, |p| p["session"]["sessionId"] == remote_id).await;
    assert_eq!(changed["peer"], "b");
    assert_eq!(changed["session"]["name"], "b/late");

    // Removing the session on B tells A's watcher it is gone.
    cb.call(method::SESSION_DELETE, json!({"sessionId": remote_id.clone()})).await.unwrap();
    ca.wait(method::MUX_SESSION_CHANGED, |p| {
        p["session"]["sessionId"] == remote_id && p["kind"] == "purged"
    })
    .await;
}

#[tokio::test]
async fn waiting_peer_add_answers_after_a_failed_first_attempt() {
    let a = hub(config(PermissionPolicy::Ask)).await;
    // Nothing listens on this port: the first attempt fails at once.
    let port = free_port();
    let started = std::time::Instant::now();
    a.add_peer("gone", &format!("ws://127.0.0.1:{port}"), None, None, true).await.unwrap();
    assert!(started.elapsed() < Duration::from_secs(15), "{:?}", started.elapsed());
    let peers = a.peers();
    assert_eq!(peers[0]["connected"], false);
    assert!(peers[0]["error"].is_string(), "{peers:?}");
}
