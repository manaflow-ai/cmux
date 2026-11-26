//! RFD 0140: synced pins and drafts across two live daemons linked one way, as a Mac links a VM:
//! B adds A as a peer and A never adds B. An edit on A after the link is up reaches B's replica
//! live (A tells the peer daemons linked to it, `_acpmux/sync/changed`, and each pulls), and a
//! cleared draft crosses as a delete. Before, A had exchanged with nobody, so B learned A's later
//! edits only at its next reconnect (`scripts/two_daemon_sync.py` measured it: never in 8 s).

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
use std::time::{Duration, Instant};
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
}

/// The person key these hubs hold (`hub/person.rs`): each client stands for
/// the person at that machine's app.
const PERSON_KEY: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

async fn client(h: Arc<Hub>) -> C {
    let _ = h.person.install_spawn_key(PERSON_KEY);
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(h, in_rx, out_tx));
    let mut c = C { tx: in_tx, rx: out_rx, next: 0 };
    let hello = json!({"protocolVersion": 1, "clientInfo": {"name": "t"}});
    let init = c.call(method::INITIALIZE, hello).await.unwrap();
    // The app's proof of the key for this connection's challenge (`hub/person.rs`).
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

/// Wait until `b`'s replica holds `want` at `key` (`Some(None)`: a delete), or fail at 5 s.
async fn converges(b: &Hub, key: &str, want: Option<Option<Value>>, what: &str) -> Duration {
    let t0 = Instant::now();
    loop {
        let got = b.synced().written(key);
        if got == want {
            return t0.elapsed();
        }
        assert!(t0.elapsed() < Duration::from_secs(5), "{what}: B holds {got:?} at {key}, not {want:?}");
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
}

#[tokio::test]
async fn edits_on_the_linked_daemon_reach_the_one_that_linked_it_live() {
    // A: the VM, which owns the chat and serves the link.
    let a = hub(config(PermissionPolicy::Ask)).await;
    let (port, peer_token) = listen_with_peer_token(a.clone(), "synced-one-way").await;
    let mut ca = client(a.clone()).await;
    let s = ca
        .call(method::SESSION_NEW, json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"name": "sync-check"}}}))
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let (pin, draft) = (format!("pin/{id}"), format!("draft/{id}"));

    // Offline: pinned and drafted on A before B links to it.
    ca.call(method::MUX_PIN, json!({"sessionId": id, "pinned": true})).await.unwrap();
    ca.call("_acpmux/draft_set", json!({"sessionId": id, "text": "offline draft"})).await.unwrap();

    // B: the Mac, which adds A; A adds nobody.
    let b = hub(config(PermissionPolicy::Ask)).await;
    b.add_peer("a", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), Some(peer_token), true)
        .await
        .unwrap();
    converges(&b, &pin, Some(Some(json!(true))), "offline pin at link-up").await;
    converges(&b, &draft, Some(Some(json!("offline draft"))), "offline draft at link-up").await;

    // Live: unpinned and drafted again on A with the link up.
    ca.call(method::MUX_PIN, json!({"sessionId": id, "pinned": false})).await.unwrap();
    ca.call("_acpmux/draft_set", json!({"sessionId": id, "text": "live draft"})).await.unwrap();
    converges(&b, &pin, Some(Some(json!(false))), "live unpin on A").await;
    converges(&b, &draft, Some(Some(json!("live draft"))), "live draft on A").await;

    // A cleared draft crosses as a delete, not a stale text left on B.
    ca.call("_acpmux/draft_set", json!({"sessionId": id, "text": ""})).await.unwrap();
    converges(&b, &draft, Some(None), "cleared draft on A").await;

    // Many edits in a row on A: B ends at the last one (pokes coalesce, none is lost).
    for i in 0..50 {
        ca.call("_acpmux/draft_set", json!({"sessionId": id, "text": format!("burst {i}")})).await.unwrap();
    }
    converges(&b, &draft, Some(Some(json!("burst 49"))), "the last of 50 drafts on A").await;
}
