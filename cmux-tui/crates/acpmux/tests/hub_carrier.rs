//! The hub carrier end to end (`src/hub_carrier.rs`): two hubs, B serving WebSocket on loopback
//! and A mirroring B as peer `b` whose only working route is the relay. A session's turn streams
//! over the carrier, the relay drops every connection mid-turn, the turn ends while it is down,
//! and once the relay is back A's link reconnects over the carrier and the `afterSeq` replay
//! brings the events it missed, each exactly once, with the prompt's answer.
//!
//! The relay is cmux's native one (`cmux-relay`) in process, behind a TCP proxy the test can cut
//! and that counts the bytes and connections the platform would carry.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, HarnessProfile, PermissionPolicy, StoreMode};
use acpmux::hub::Hub;
use acpmux::hub_carrier::{CarrierAnswer, HubCarrier, Tickets, Timings};
use acpmux::rpc::{Message, method};
use acpmux::server::peer_auth::PeerAuth;
use acpmux::server::{WsAuth, bind_ws, serve_connection, serve_ws_with};
use base64::Engine;
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::net::SocketAddr;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::{mpsc, watch};

const PERSON_KEY: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

fn config() -> Config {
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
    async fn call(&mut self, m: &str, p: Value) -> Value {
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
                assert!(error.is_none(), "{m}: {error:?}");
                return result.unwrap_or(Value::Null);
            }
        }
    }
}

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

/// A TCP proxy in front of the relay: it counts what crosses it and can cut every connection.
struct Proxy {
    port: u16,
    cut: watch::Sender<u64>,
    paused: Arc<AtomicBool>,
    bytes: Arc<AtomicU64>,
    connections: Arc<AtomicU64>,
}

impl Proxy {
    async fn start(target: SocketAddr) -> Self {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let (cut, _) = watch::channel(0u64);
        let paused = Arc::new(AtomicBool::new(false));
        let bytes = Arc::new(AtomicU64::new(0));
        let connections = Arc::new(AtomicU64::new(0));
        let proxy = Self { port, cut, paused, bytes, connections };
        let (cut, paused, bytes, connections) = (
            proxy.cut.clone(),
            proxy.paused.clone(),
            proxy.bytes.clone(),
            proxy.connections.clone(),
        );
        tokio::spawn(async move {
            while let Ok((inbound, _)) = listener.accept().await {
                if paused.load(Ordering::SeqCst) {
                    drop(inbound);
                    continue;
                }
                let Ok(outbound) = tokio::net::TcpStream::connect(target).await else { continue };
                connections.fetch_add(1, Ordering::SeqCst);
                let mut cut = cut.subscribe();
                let bytes = bytes.clone();
                tokio::spawn(async move {
                    let (mut ir, mut iw) = inbound.into_split();
                    let (mut or, mut ow) = outbound.into_split();
                    let up = copy(&mut ir, &mut ow, &bytes);
                    let down = copy(&mut or, &mut iw, &bytes);
                    tokio::select! {
                        _ = up => {}
                        _ = down => {}
                        _ = cut.changed() => {}
                    }
                });
            }
        });
        proxy
    }

    /// Every connection through the relay ends, and new ones are refused until `resume`.
    fn cut_and_pause(&self) {
        self.paused.store(true, Ordering::SeqCst);
        self.cut.send_modify(|n| *n += 1);
    }

    fn resume(&self) {
        self.paused.store(false, Ordering::SeqCst);
    }
}

async fn copy(
    from: &mut tokio::net::tcp::OwnedReadHalf,
    to: &mut tokio::net::tcp::OwnedWriteHalf,
    bytes: &AtomicU64,
) {
    let mut buf = vec![0u8; 16 * 1024];
    loop {
        let n = match from.read(&mut buf).await {
            Ok(0) | Err(_) => return,
            Ok(n) => n,
        };
        if to.write_all(&buf[..n]).await.is_err() {
            return;
        }
        bytes.fetch_add(n as u64, Ordering::Relaxed);
    }
}

/// The platform's answers for one slot, as `POST /v1/mesh/carrier` gives them.
struct FixedTickets {
    relay: String,
    /// The keys B lets in (Register), or the key A pins (Connect).
    peers: Vec<String>,
    asked: AtomicU64,
}

#[async_trait::async_trait]
impl Tickets for FixedTickets {
    async fn register(&self) -> Result<CarrierAnswer, String> {
        self.asked.fetch_add(1, Ordering::Relaxed);
        Ok(serde_json::from_value(json!({
            "relay": self.relay, "slot": "own-machine-slot-b", "ticket": "open-register",
            "expires_at": 0, "peers": self.peers,
        }))
        .unwrap())
    }

    async fn connect(&self, peer: &str) -> Result<CarrierAnswer, String> {
        self.asked.fetch_add(1, Ordering::Relaxed);
        if !self.peers.iter().any(|k| k == peer) {
            return Err("machine.not_found".into());
        }
        Ok(serde_json::from_value(json!({
            "relay": self.relay, "slot": "own-machine-slot-b", "ticket": "open-connect",
            "expires_at": 0, "peer_key": peer,
        }))
        .unwrap())
    }
}

fn random_key() -> [u8; 32] {
    let mut key = [0u8; 32];
    getrandom::fill(&mut key).unwrap();
    key
}

fn public(key: &[u8; 32]) -> String {
    let secret = x25519_dalek::StaticSecret::from(*key);
    base64::engine::general_purpose::STANDARD
        .encode(x25519_dalek::PublicKey::from(&secret).as_bytes())
}

async fn state_of(a: &Hub) -> String {
    a.peers()
        .into_iter()
        .next()
        .map(|p| p["state"].as_str().unwrap_or("").to_owned())
        .unwrap_or_default()
}

async fn until_state(a: &Hub, want: bool, budget: Duration) {
    let deadline = tokio::time::Instant::now() + budget;
    while (state_of(a).await == "connected") != want {
        assert!(tokio::time::Instant::now() < deadline, "peer b never became connected={want}");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn hub_carrier_a_turn_streams_over_the_relay_and_survives_a_relay_reconnect() {
    let _ = HERMETIC;
    // The relay, open (tickets are the platform's tests), behind the proxy.
    let relay_listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let relay_address = relay_listener.local_addr().unwrap();
    let relay = cmux_relay::Relay::new(cmux_relay::RelayConfig {
        allow_open: true,
        ..cmux_relay::RelayConfig::default()
    })
    .unwrap();
    let (relay_listener, router) = relay.server_parts(relay_listener);
    tokio::spawn(async move {
        let _ = axum::serve(relay_listener, router).await;
    });
    let proxy = Proxy::start(relay_address).await;
    let route = format!("relay+ws://127.0.0.1:{}", proxy.port);

    // B: a session `lane`, served on loopback WebSocket and on its relay slot.
    let home = tempfile::tempdir().unwrap();
    let auth = PeerAuth::create(home.path()).unwrap();
    let peer_token =
        std::fs::read_to_string(acpmux::server::peer_auth::token_path(home.path())).unwrap();
    let b = hub();
    let l = bind_ws("127.0.0.1:0").await.unwrap();
    let b_ws = l.local_addr().unwrap();
    let ws_auth = WsAuth { local_app: None, peer: Some(Arc::new(auth)) };
    tokio::spawn(serve_ws_with(b.clone(), l, "tok".into(), ws_auth));
    let mut cb = client(b.clone()).await;
    cb.call(
        method::SESSION_NEW,
        json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"name": "lane"}}}),
    )
    .await;
    let (key_a, key_b) = (random_key(), random_key());
    let fast = Timings { control: Duration::from_secs(5), handshake: Duration::from_secs(5) };
    let tickets_b = Arc::new(FixedTickets {
        relay: route.clone(),
        peers: vec![public(&key_a)],
        asked: AtomicU64::new(0),
    });
    let carrier_b = HubCarrier::new(tickets_b, key_b, fast);
    let _serving = carrier_b.serve(b_ws);

    // A: peer `b` at a URL nothing listens on; the hub carrier is its only way there.
    let a = hub();
    let tickets_a = Arc::new(FixedTickets {
        relay: route.clone(),
        peers: vec![public(&key_b)],
        asked: AtomicU64::new(0),
    });
    let carrier_a = HubCarrier::new(tickets_a.clone(), key_a, fast);
    carrier_a.set_route("b", &public(&key_b));
    assert!(a.hub_carrier.set(carrier_a.clone()));
    let dead = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap();
    a.add_peer("b", &format!("ws://{dead}"), Some("tok".into()), Some(peer_token), false)
        .await
        .unwrap();
    until_state(&a, true, Duration::from_secs(30)).await;
    assert!(carrier_a.stats().dials.load(Ordering::Relaxed) >= 1, "A dialed over the carrier");
    assert!(carrier_b.stats().accepted.load(Ordering::Relaxed) >= 1, "B took the circuit");
    let connected_bytes = proxy.bytes.load(Ordering::Relaxed);

    // A turn on B's session from A: it streams "before-gate", then waits on the gate.
    let gate = home.path().join("gate");
    assert!(std::process::Command::new("mkfifo").arg(&gate).status().unwrap().success());
    let mut ca = client(a.clone()).await;
    let prompt = json!({"sessionId": "b/lane",
        "prompt": [{"type": "text", "text": format!("gate: {}", gate.display())}]});
    ca.tx.send(Message::request(99, method::SESSION_PROMPT, prompt).to_line()).await.unwrap();
    let mut before = 0;
    let mut after = 0;
    let mut answer = None;
    let read = |line: &str, before: &mut i32, after: &mut i32, answer: &mut Option<Value>| {
        if line.contains("before-gate") {
            *before += 1;
        }
        if line.contains("after-gate") {
            *after += 1;
        }
        if let Ok(Message::Response { id, result, error }) = Message::parse(line)
            && id == 99i64
        {
            assert!(error.is_none(), "the prompt failed: {error:?}");
            *answer = result;
        }
    };
    tokio::time::timeout(Duration::from_secs(20), async {
        while before == 0 {
            let line = ca.rx.recv().await.expect("A's client closed");
            read(&line, &mut before, &mut after, &mut answer);
        }
    })
    .await
    .expect("the turn never streamed over the carrier");

    // The relay drops every connection mid-turn; the turn ends while it is down.
    proxy.cut_and_pause();
    until_state(&a, false, Duration::from_secs(15)).await;
    let gate_path = gate.clone();
    tokio::task::spawn_blocking(move || std::fs::write(gate_path, b"go\n")).await.unwrap().unwrap();
    // B's own client sees the turn end, so it ended before A could hear of it.
    tokio::time::timeout(Duration::from_secs(20), async {
        loop {
            let line = cb.rx.recv().await.expect("B's client closed");
            if line.contains("after-gate") {
                return;
            }
        }
    })
    .await
    .expect("B's turn never ended");
    tokio::time::sleep(Duration::from_millis(300)).await;
    let dials_before = carrier_a.stats().dials.load(Ordering::Relaxed);
    proxy.resume();

    // A reconnects over the carrier and replays what it missed, once, with the prompt's answer.
    tokio::time::timeout(Duration::from_secs(45), async {
        while answer.is_none() || after == 0 {
            let line = ca.rx.recv().await.expect("A's client closed");
            read(&line, &mut before, &mut after, &mut answer);
        }
    })
    .await
    .expect("the missed events never arrived after the relay came back");
    assert_eq!(answer.unwrap()["stopReason"], "end_turn");
    assert!(
        carrier_a.stats().dials.load(Ordering::Relaxed) > dials_before,
        "redialed over the carrier"
    );
    until_state(&a, true, Duration::from_secs(5)).await;
    // Nothing more arrives late: each event came exactly once.
    let _ = tokio::time::timeout(Duration::from_millis(500), async {
        while let Some(line) = ca.rx.recv().await {
            read(&line, &mut before, &mut after, &mut answer);
        }
    })
    .await;
    assert_eq!((before, after), (1, 1), "an event was lost or doubled across the reconnect");

    // What the platform carried, for the PR's load estimate.
    eprintln!(
        "hub carrier load: {} relay connections, {} bytes through the relay ({} to connect), \
         {} carrier records, A sent {} B received {} plaintext bytes, {} ticket asks by A",
        proxy.connections.load(Ordering::Relaxed),
        proxy.bytes.load(Ordering::Relaxed),
        connected_bytes,
        carrier_a.stats().records.load(Ordering::Relaxed),
        carrier_a.stats().sent.load(Ordering::Relaxed),
        carrier_a.stats().received.load(Ordering::Relaxed),
        tickets_a.asked.load(Ordering::Relaxed),
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn hub_carrier_a_machine_the_platform_does_not_name_is_refused_in_the_handshake() {
    let _ = HERMETIC;
    let relay_listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let relay_address = relay_listener.local_addr().unwrap();
    let relay = cmux_relay::Relay::new(cmux_relay::RelayConfig {
        allow_open: true,
        ..cmux_relay::RelayConfig::default()
    })
    .unwrap();
    let (relay_listener, router) = relay.server_parts(relay_listener);
    tokio::spawn(async move {
        let _ = axum::serve(relay_listener, router).await;
    });
    let route = format!("relay+ws://{relay_address}");
    let target = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let target_address = target.local_addr().unwrap();
    let reached = Arc::new(AtomicBool::new(false));
    let seen = reached.clone();
    tokio::spawn(async move {
        while let Ok(_conn) = target.accept().await {
            seen.store(true, Ordering::SeqCst);
        }
    });
    let (key_b, key_stranger) = (random_key(), random_key());
    let fast = Timings { control: Duration::from_secs(5), handshake: Duration::from_secs(5) };
    // B lets in no one: the platform named no other machine of its person.
    let carrier_b = HubCarrier::new(
        Arc::new(FixedTickets { relay: route.clone(), peers: vec![], asked: AtomicU64::new(0) }),
        key_b,
        fast,
    );
    let _serving = carrier_b.serve(target_address);
    let stranger = HubCarrier::new(
        Arc::new(FixedTickets {
            relay: route,
            peers: vec![public(&key_b)],
            asked: AtomicU64::new(0),
        }),
        key_stranger,
        fast,
    );
    // B registers in the background: ask until its handshake answers.
    let mut refused = String::new();
    for _ in 0..40 {
        match stranger.dial(&public(&key_b)).await {
            Ok(_) => panic!("a machine B does not let in got a stream"),
            Err(e) if e.contains("not one of this person's machines") => {
                refused = e;
                break;
            }
            Err(e) => {
                refused = e;
                tokio::time::sleep(Duration::from_millis(250)).await;
            }
        }
    }
    assert!(refused.contains("not one of this person's machines"), "{refused}");
    assert!(!reached.load(Ordering::SeqCst), "a refused circuit reached B's listener");
}
