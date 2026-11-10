//! `_acpmux/review_queue` across peers (`server/review_queue.rs`): A and B list each other; a
//! read on either lists the other's asks once, tagged with its `host`, and never loops. An
//! answer on B lands in B's audit trail (`_acpmux/audit`), not A's.

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
    cfg.permission_policy = PermissionPolicy::Ask;
    cfg
}

async fn hub() -> Arc<Hub> {
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

const PERSON_KEY: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

/// A unix socket client proven as the person (`hub/person.rs`).
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

/// `h`'s WebSocket listener with a peer token: its port and the token.
async fn listen(h: Arc<Hub>, tag: &str) -> (u16, String) {
    let home = std::env::temp_dir().join(format!("rq-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    let auth = PeerAuth::create(&home).unwrap();
    let token = std::fs::read_to_string(acpmux::server::peer_auth::token_path(&home)).unwrap();
    let l = bind_ws("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    let auth = WsAuth { local_app: None, peer: Some(Arc::new(auth)) };
    tokio::spawn(serve_ws_with(h, l, "tok".into(), auth));
    (port, token)
}

/// A WebSocket server that answers every request with `{}`: a daemon without a queue.
async fn queueless_peer() -> u16 {
    use futures_util::{SinkExt, StreamExt};
    use tokio_tungstenite::tungstenite::Message as Ws;
    let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    tokio::spawn(async move {
        while let Ok((tcp, _)) = l.accept().await {
            let Ok(ws) = tokio_tungstenite::accept_async(tcp).await else { continue };
            tokio::spawn(async move {
                let (mut sink, mut source) = ws.split();
                while let Some(Ok(Ws::Text(text))) = source.next().await {
                    let Ok(Message::Request { id, method: m, .. }) = Message::parse(&text) else {
                        continue;
                    };
                    let result = match m.as_str() {
                        method::INITIALIZE => json!({"protocolVersion": 1, "_meta": {"acpmux": {
                            "version": "0", "build": "old", "origin": "peer",
                            "personInstance": "old-run"}}}),
                        _ => json!({}),
                    };
                    let reply = Message::ok(id, result).to_line();
                    if sink.send(Ws::Text(reply.trim_end().to_owned().into())).await.is_err() {
                        return;
                    }
                }
            });
        }
    });
    port
}

fn items(v: &Value) -> Vec<Value> {
    v["items"].as_array().cloned().unwrap_or_default()
}

#[tokio::test]
async fn mutual_peers_list_each_others_asks_once_and_answers_reach_the_owners_audit() {
    let a = hub().await;
    let b = hub().await;
    let (a_port, a_token) = listen(a.clone(), "a").await;
    let (b_port, b_token) = listen(b.clone(), "b").await;
    a.add_peer("b", &format!("ws://127.0.0.1:{b_port}"), Some("tok".into()), Some(b_token), true)
        .await
        .unwrap();
    b.add_peer("a", &format!("ws://127.0.0.1:{a_port}"), Some("tok".into()), Some(a_token), true)
        .await
        .unwrap();
    let mut ca = client(a.clone()).await;
    let mut cb = client(b.clone()).await;

    let s = cb
        .call(method::SESSION_NEW, json!({"cwd": std::env::temp_dir(), "mcpServers": []}))
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    cb.call(method::MUX_ATTACH, json!({"session": id.clone(), "limit": 0})).await.unwrap();
    cb.next += 1;
    let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": "ask: rm"}]});
    cb.tx.send(Message::request(cb.next, method::SESSION_PROMPT, prompt).to_line()).await.unwrap();
    let pending = cb.wait(method::MUX_PERMISSION_PENDING, |p| p["sessionId"] == id).await;
    let perm = pending["permissionId"].as_str().unwrap().to_owned();

    // On B the ask is local; on A it is B's, once.
    let on_b = cb.call(method::MUX_REVIEW_QUEUE, json!({})).await.unwrap();
    let mine = items(&on_b);
    assert_eq!(mine.len(), 1, "{on_b}");
    assert_eq!(mine[0]["id"], format!("acpmux:{perm}"));
    assert_eq!(mine[0]["kind"], "approval");
    assert_eq!(mine[0].get("host"), None, "{on_b}");
    assert_eq!(on_b.get("peersOmitted"), None, "{on_b}");
    let on_a = ca.call(method::MUX_REVIEW_QUEUE, json!({})).await.unwrap();
    let theirs = items(&on_a);
    assert_eq!(theirs.len(), 1, "{on_a}");
    assert_eq!(theirs[0]["host"], "b");
    assert_eq!(theirs[0]["sessionId"], id);
    assert_eq!(theirs[0]["permissionId"], perm);
    assert!(theirs[0]["options"].as_array().is_some_and(|o| !o.is_empty()), "{on_a}");
    assert_eq!(on_a.get("peersOmitted"), None, "{on_a}");
    // `localOnly` keeps the peers out.
    let local = ca.call(method::MUX_REVIEW_QUEUE, json!({"localOnly": true})).await.unwrap();
    assert!(items(&local).is_empty(), "{local}");

    // B's person denies it on B: B's trail has the entry, A's has none, and it leaves both queues.
    let option = pending["request"]["options"]
        .as_array()
        .unwrap()
        .iter()
        .find(|o| o["kind"] == "reject_once")
        .map(|o| o["optionId"].clone())
        .unwrap();
    cb.call(
        method::MUX_PERMISSION_RESPOND,
        json!({"sessionId": id, "permissionId": perm, "optionId": option}),
    )
    .await
    .unwrap();
    let mut entries = vec![];
    for _ in 0..100 {
        let audit = cb.call(method::MUX_AUDIT, json!({"verify": true})).await.unwrap();
        entries = audit["entries"].as_array().cloned().unwrap_or_default();
        if !entries.is_empty() {
            assert_eq!(audit["verify"]["ok"], true, "{audit}");
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert_eq!(entries.len(), 1, "{entries:?}");
    assert_eq!(entries[0]["permissionId"], perm);
    assert_eq!(entries[0]["decision"]["kind"], "deny");
    assert_eq!(entries[0]["sessionId"], id);
    let a_audit = ca.call(method::MUX_AUDIT, json!({})).await.unwrap();
    assert_eq!(a_audit["entries"], json!([]), "{a_audit}");
    let on_a = ca.call(method::MUX_REVIEW_QUEUE, json!({})).await.unwrap();
    assert!(items(&on_a).is_empty(), "{on_a}");
}

#[tokio::test]
async fn a_peer_without_a_queue_is_named_as_omitted() {
    let a = hub().await;
    let old = queueless_peer().await;
    a.add_peer("old", &format!("ws://127.0.0.1:{old}"), Some("tok".into()), None, true)
        .await
        .unwrap();
    let mut ca = client(a.clone()).await;
    let v = ca.call(method::MUX_REVIEW_QUEUE, json!({})).await.unwrap();
    assert_eq!(v["peersOmitted"], json!(["old"]), "{v}");
    assert!(v["now"].as_u64().is_some(), "{v}");
}
