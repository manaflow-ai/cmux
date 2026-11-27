//! A peer chat no client here ever opened opens on its copy at once while its peer is down: the
//! daemon read it ahead once a client here opened a peer chat (`hub/peer_snapshot/warm.rs`).
//! Leo, 2026-10-30, on a remote machine's chat that opened on "peer_unreachable: ...
//! (reconnecting, ...)": "AND IT DID IN FACT LOAD BUT TOOK 30+ FUCKING SECONDS".
//!
//! Two hubs: B serves WebSocket and runs the chats, A mirrors B through a relay the test cuts.

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
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::sync::mpsc;
use tokio::task::JoinHandle;

fn config(store: StoreMode) -> Config {
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
    cfg.store.mode = store;
    cfg.permission_policy = PermissionPolicy::Ask;
    cfg
}

struct C {
    tx: mpsc::Sender<String>,
    rx: mpsc::Receiver<String>,
    next: i64,
}

impl C {
    /// The whole response to `m`: its error with its data, or its result.
    async fn raw(&mut self, m: &str, p: Value) -> Value {
        self.next += 1;
        let id = self.next;
        self.tx.send(Message::request(id, m, p).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(20), self.rx.recv())
                .await
                .expect("timeout")
                .expect("closed");
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return v;
            }
        }
    }

    async fn call(&mut self, m: &str, p: Value) -> Value {
        let v = self.raw(m, p).await;
        assert!(v.get("error").is_none(), "{m}: {v}");
        v["result"].clone()
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
    let init = c.call(method::INITIALIZE, hello).await;
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

/// A TCP relay to `port` whose every connection the test can cut at once (the peer goes down).
struct Relay {
    port: u16,
    tasks: Arc<Mutex<Vec<JoinHandle<()>>>>,
}

impl Relay {
    async fn to(port: u16) -> Self {
        let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let relay_port = l.local_addr().unwrap().port();
        let tasks: Arc<Mutex<Vec<JoinHandle<()>>>> = Arc::default();
        let kept = tasks.clone();
        let accept = tokio::spawn(async move {
            while let Ok((mut client, _)) = l.accept().await {
                let Ok(mut server) = tokio::net::TcpStream::connect(("127.0.0.1", port)).await
                else {
                    continue;
                };
                let pipe = tokio::spawn(async move {
                    let _ = tokio::io::copy_bidirectional(&mut client, &mut server).await;
                });
                kept.lock().unwrap().push(pipe);
            }
        });
        tasks.lock().unwrap().push(accept);
        Self { port: relay_port, tasks }
    }

    fn cut(&self) {
        for task in self.tasks.lock().unwrap().drain(..) {
            task.abort();
        }
    }
}

fn text_of(reply: &Value) -> String {
    reply["events"].as_array().map_or(String::new(), |events| {
        events.iter().map(|e| e["msg"].to_string()).collect::<Vec<_>>().join("\n")
    })
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_peer_chat_never_opened_here_opens_on_its_copy_at_once_while_its_peer_is_down() {
    let _ = HERMETIC;
    // B runs two chats; one of them answers a prompt before A ever links.
    let b = Hub::new(
        config(StoreMode::Memory),
        acpmux::store::open(&config(StoreMode::Memory).store, std::path::Path::new("/nonexistent"))
            .unwrap(),
    );
    let home = tempfile::tempdir().unwrap();
    let auth = PeerAuth::create(&home.path().join("b")).unwrap();
    let peer_token =
        std::fs::read_to_string(acpmux::server::peer_auth::token_path(&home.path().join("b")))
            .unwrap();
    let l = bind_ws("127.0.0.1:0").await.unwrap();
    let b_port = l.local_addr().unwrap().port();
    let ws = WsAuth { local_app: None, peer: Some(Arc::new(auth)) };
    tokio::spawn(serve_ws_with(b.clone(), l, "tok".into(), ws));
    let mut cb = client(b.clone()).await;
    let mut ids = vec![];
    for name in ["opened", "never-opened"] {
        let new = json!({"cwd": std::env::temp_dir(), "mcpServers": [],
                         "_meta": {"acpmux": {"name": name}}});
        ids.push(cb.call(method::SESSION_NEW, new).await["sessionId"].as_str().unwrap().to_owned());
    }
    let prompt = json!({"sessionId": ids[1],
                        "prompt": [{"type": "text", "text": "the lane's last report"}]});
    assert_eq!(cb.call(method::SESSION_PROMPT, prompt).await["stopReason"], "end_turn");

    // A keeps its copies on disk, and mirrors B through the relay.
    let a_dir = home.path().join("a");
    std::fs::create_dir_all(&a_dir).unwrap();
    let a_cfg = config(StoreMode::Local);
    let a = Hub::new(a_cfg.clone(), acpmux::store::open(&a_cfg.store, &a_dir).unwrap());
    let relay = Relay::to(b_port).await;
    a.add_peer(
        "b",
        &format!("ws://127.0.0.1:{}", relay.port),
        Some("tok".into()),
        Some(peer_token),
        true,
    )
    .await
    .unwrap();
    let mut ca = client(a.clone()).await;
    // The person opens another chat of B here: B's chats are read ahead from now on.
    ca.call(method::MUX_ATTACH, json!({"session": "b/opened", "limit": 0})).await;
    let copy = json!({"sessionId": "b/never-opened"});
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        let got = ca.call("_acpmux/peer_snapshot", copy.clone()).await;
        if text_of(&got).contains("the lane's last report") {
            break;
        }
        assert!(Instant::now() < deadline, "no copy of a chat never opened here: {got}");
        tokio::time::sleep(Duration::from_millis(100)).await;
    }

    // B goes down: its chat cannot be attached, and opens on its copy at once.
    relay.cut();
    let deadline = Instant::now() + Duration::from_secs(20);
    while a.peers()[0]["connected"] == true {
        assert!(Instant::now() < deadline, "the link never dropped: {:?}", a.peers());
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let open = Instant::now();
    let got = ca.call("_acpmux/peer_snapshot", copy.clone()).await;
    let elapsed = open.elapsed();
    let attach =
        ca.raw(method::MUX_ATTACH, json!({"session": "b/never-opened", "limit": 400})).await;
    assert_eq!(attach["error"]["data"]["reason"], "peer_unreachable", "{attach}");
    let records = got["events"].as_array().map_or(0, Vec::len);
    eprintln!("open-to-content with the peer down: {} ms ({records} records)", elapsed.as_millis());
    assert!(text_of(&got).contains("echo: the lane's last report"), "{got}");
    assert_eq!(got["stale"], true);
    assert!(elapsed < Duration::from_secs(1), "open-to-content {elapsed:?}");
}
