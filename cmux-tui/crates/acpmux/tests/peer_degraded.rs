//! A peer that stops answering (huge-blue at load 97, its daemon's threads
//! stuck in the kernel) is dropped by the keepalive, shown `reconnecting`
//! with its sessions kept as stale, refused as `peer_unreachable`, and
//! picked up again once it answers. Two hubs: B serves WebSocket behind a
//! relay that can stall; A mirrors B as a peer.

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
use tokio::sync::{mpsc, watch};

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

/// A TCP relay in front of `port` that stops moving bytes, both ways and
/// for new connections too, while `stalled` is true: the connection stays
/// open, as to a host whose daemon is wedged.
async fn stalling_relay(port: u16, stalled: watch::Receiver<bool>) -> u16 {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    async fn pipe(
        mut from: tokio::net::tcp::OwnedReadHalf,
        mut to: tokio::net::tcp::OwnedWriteHalf,
        mut stalled: watch::Receiver<bool>,
    ) {
        let mut buf = vec![0u8; 64 * 1024];
        loop {
            if stalled.wait_for(|s| !*s).await.is_err() {
                return;
            }
            let Ok(n) = from.read(&mut buf).await else { return };
            if n == 0 {
                return;
            }
            if stalled.wait_for(|s| !*s).await.is_err() || to.write_all(&buf[..n]).await.is_err() {
                return;
            }
        }
    }
    let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let relay_port = l.local_addr().unwrap().port();
    tokio::spawn(async move {
        while let Ok((client, _)) = l.accept().await {
            let Ok(server) = tokio::net::TcpStream::connect(("127.0.0.1", port)).await else {
                continue;
            };
            let (cr, cw) = client.into_split();
            let (sr, sw) = server.into_split();
            tokio::spawn(pipe(sr, cw, stalled.clone()));
            tokio::spawn(pipe(cr, sw, stalled.clone()));
        }
    });
    relay_port
}

/// Wait (bounded) for the next settled connect attempts until A's peer `b`
/// is in `state`.
async fn until_state(a: &Hub, state: &str) -> Value {
    let peer = a.peer_by_name("b").expect("peer b");
    let mut settled = peer.settled();
    let wait = async {
        loop {
            let row = a.peers().into_iter().next().expect("one peer");
            if row["state"] == state {
                return row;
            }
            settled.changed().await.expect("peer gone");
        }
    };
    tokio::time::timeout(Duration::from_secs(60), wait).await.unwrap_or_else(|_| {
        panic!("peer b never reached {state}: {:?}", a.peers());
    })
}

#[tokio::test]
async fn a_stalled_peer_is_kept_as_stale_refused_clearly_and_picked_up_again() {
    // A 1 s ping (4 s silence budget) and a 2 s connect deadline, so the
    // test does not wait out the real ones. Set before any peer exists.
    // SAFETY: the only test in this binary, before any thread reads them.
    unsafe {
        std::env::set_var("ACPMUX_PEER_PING_SECS", "1");
        std::env::set_var("ACPMUX_PEER_TIMEOUT_SECS", "2");
    }
    let _ = HERMETIC;
    let b = hub();
    let home = std::env::temp_dir().join(format!("apd-{}", std::process::id()));
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

    let (stall, stalled) = watch::channel(false);
    let relay = stalling_relay(port, stalled).await;
    let a = hub();
    let url = format!("ws://127.0.0.1:{relay}");
    a.add_peer("b", &url, Some("tok".into()), Some(peer_token), true).await.unwrap();
    let up = until_state(&a, "connected").await;
    assert_eq!(up["connected"], true);
    let listed = a.remote_sessions();
    assert_eq!(listed.len(), 1, "{listed:?}");
    assert_eq!(listed[0]["stale"], false);

    let mut changes = a.subscribe();
    // B stops answering: the keepalive drops the link within its budget.
    stall.send_replace(true);
    let down = until_state(&a, "reconnecting").await;
    assert_eq!(down["connected"], false);
    assert!(down["lastSeen"].is_u64(), "{down}");
    let error = down["error"].as_str().unwrap_or_default();
    assert!(error.contains("stopped"), "the keepalive dropped it: {down}");
    // Link failure is immediate; rows only become stale after the reconnect grace.
    tokio::time::timeout(Duration::from_secs(15), async {
        loop {
            let event = changes.recv().await.unwrap();
            if event.remote.is_some_and(|row| row.summary["status"] == "unreachable") {
                break;
            }
        }
    })
    .await
    .expect("a continuous outage must mark its rows stale");
    let kept = a.remote_sessions();
    assert_eq!(kept.len(), 1, "kept, not dropped: {kept:?}");
    assert_eq!(kept[0]["stale"], true);
    assert_eq!(kept[0]["status"], "unreachable");
    assert_eq!(kept[0]["peerState"], "reconnecting");

    let mut ca = client(a.clone()).await;
    let prompt = json!({"sessionId": "b/lane", "prompt": [{"type": "text", "text": "hi"}]});
    let refused = ca.call(method::SESSION_PROMPT, prompt).await.unwrap_err();
    assert!(refused.starts_with("peer_unreachable: b (reconnecting, last seen "), "{refused}");

    // B answers again: the next attempt picks it up and the rows are fresh.
    stall.send_replace(false);
    until_state(&a, "connected").await;
    let fresh = a.remote_sessions();
    assert_eq!(fresh.len(), 1, "{fresh:?}");
    assert_eq!(fresh[0]["stale"], false, "{fresh:?}");
    let _ = std::fs::remove_dir_all(&home);
}
