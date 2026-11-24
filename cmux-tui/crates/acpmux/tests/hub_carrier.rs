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
use acpmux::hub_carrier::{
    CarrierAnswer, CircuitLane, CircuitService, HubCarrier, Tickets, Timings,
};
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
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt};
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

impl C {
    /// A request whose answer nobody waits for (a turn that runs until it is stopped).
    async fn send(&mut self, m: &str, p: Value) {
        self.next += 1;
        self.tx.send(Message::request(self.next, m, p).to_line()).await.unwrap();
    }

    /// Reads until a notification `m` whose params satisfy `pred`.
    async fn wait_for(&mut self, m: &str, pred: impl Fn(&Value) -> bool) {
        loop {
            let line = tokio::time::timeout(Duration::from_secs(20), self.rx.recv())
                .await
                .unwrap_or_else(|_| panic!("no {m} within 20 s"))
                .expect("closed");
            if let Ok(Message::Notification { method, params }) = Message::parse(&line)
                && method == m
                && params.as_ref().is_some_and(&pred)
            {
                return;
            }
        }
    }
}

/// Every record of a session's log, page after page.
async fn all_events(c: &mut C, id: &str) -> Vec<Value> {
    let mut out: Vec<Value> = Vec::new();
    loop {
        let after = out.last().and_then(|e| e["seq"].as_u64()).unwrap_or(0);
        let page = c
            .call(method::MUX_EVENTS, json!({"sessionId": id, "afterSeq": after, "limit": 5000}))
            .await;
        out.extend(page["events"].as_array().cloned().unwrap_or_default());
        if page["hasMore"] != true {
            return out;
        }
    }
}

/// The first 16 characters of each `user_message` of `events`.
fn user_texts(events: &[Value]) -> Vec<String> {
    events
        .iter()
        .filter(|e| e["kind"] == "user_message")
        .filter_map(|e| e["msg"]["text"].as_str().map(|t| t.chars().take(16).collect()))
        .collect()
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
    let fast = Timings {
        control: Duration::from_secs(5),
        handshake: Duration::from_secs(5),
        ..Timings::default()
    };
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
    a.hub_carrier.set(carrier_a.clone());
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
    assert_eq!(answer.as_ref().unwrap()["stopReason"], "end_turn");
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
    let fast = Timings {
        control: Duration::from_secs(5),
        handshake: Duration::from_secs(5),
        ..Timings::default()
    };
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

/// A dial to a machine whose carrier is not serving (nothing registered its slot) fails at
/// once with a message that names that and the fix, not after the caller's own timeout.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn hub_carrier_a_dial_to_a_machine_whose_carrier_is_off_says_so_fast() {
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
    let (key_a, key_b) = (random_key(), random_key());
    let dialer = HubCarrier::new(
        Arc::new(FixedTickets {
            relay: format!("relay+ws://{relay_address}"),
            peers: vec![public(&key_b)],
            asked: AtomicU64::new(0),
        }),
        key_a,
        Timings { peer_join: Duration::from_millis(800), ..Timings::default() },
    );
    // B never serves: even a failed open counts as a dial attempt.
    let links = acpmux::gauges::links();
    let kept_before = links.hub_kept_dials.load(Ordering::Relaxed);
    let started = std::time::Instant::now();
    let said =
        match dialer.dial_service(&public(&key_b), CircuitService::CmuxTui { port: 7781 }).await {
            Ok(_) => panic!("a dial reached a machine whose carrier is off"),
            Err(said) => said,
        };
    assert!(started.elapsed() < Duration::from_secs(5), "the dial waited {:?}", started.elapsed());
    assert!(said.contains("hub carrier is off"), "{said}");
    assert!(said.contains("carrier.not_serving"), "{said}");
    assert!(links.hub_kept_dials.load(Ordering::Relaxed) > kept_before);
    // The hub's own 404 (`machine.not_found`: FixedTickets knows no such machine) ends at once
    // too, on its own terminal reason: it is no relay wait at all.
    let started = std::time::Instant::now();
    let unknown = public(&random_key());
    let said = match dialer.dial_service(&unknown, CircuitService::CmuxTui { port: 7781 }).await {
        Ok(_) => panic!("a dial reached a machine the hub does not know"),
        Err(said) => said,
    };
    assert!(started.elapsed() < Duration::from_secs(2), "the dial waited {:?}", started.elapsed());
    assert!(said.ends_with("(machine.not_joined)"), "{said}");
    // The hub scopes the ticket to the caller's team: the words name it, not the far carrier.
    assert!(said.contains("another of your teams"), "{said}");

    // An acpmux dial asks for a kept circuit first (and goes plain only to a machine that keeps
    // none or takes no acpmux streams): whichever it tried, the failed attempt counts.
    let dials = || {
        links.hub_plain_dials.load(Ordering::Relaxed) + links.hub_kept_dials.load(Ordering::Relaxed)
    };
    let dials_before = dials();
    assert!(dialer.dial(&unknown).await.is_err());
    assert!(dials() > dials_before);
}

/// The node key is WireGuard's static key and the carrier's Noise static key; the acpmux owner
/// allows that only while both protocols hash with BLAKE2s (`hub_carrier.rs` condition 1).
#[test]
fn hub_carrier_noise_hash_is_wireguards_blake2s() {
    use acpmux::hub_carrier::{NOISE_PROTOCOL, WIREGUARD_NOISE_PROTOCOL};
    use blake2::Digest;
    let hash = |name: &str| name.rsplit('_').next().unwrap().to_owned();
    assert_eq!(hash(NOISE_PROTOCOL), "BLAKE2s", "{NOISE_PROTOCOL}");
    assert_eq!(hash(NOISE_PROTOCOL), hash(WIREGUARD_NOISE_PROTOCOL));
    assert!(NOISE_PROTOCOL.starts_with("Noise_XX_25519_"), "{NOISE_PROTOCOL}");
    // WireGuard's chaining key is BLAKE2s(CONSTRUCTION) (boringtun `INITIAL_CHAIN_KEY`, the
    // WireGuard paper): the name above is the one WireGuard really hashes, with BLAKE2s.
    let initial_chain_key: [u8; 32] = [
        96, 226, 109, 174, 243, 39, 239, 192, 46, 195, 53, 226, 160, 37, 210, 208, 22, 235, 66, 6,
        248, 114, 119, 245, 45, 56, 209, 152, 139, 120, 205, 54,
    ];
    let digest = blake2::Blake2s256::digest(WIREGUARD_NOISE_PROTOCOL.as_bytes());
    assert_eq!(digest.as_slice(), initial_chain_key);
}

/// A replaced node key stops the carrier: its registration ends and it dials no more
/// (`hub_carrier.rs` condition 3).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn hub_carrier_a_replaced_node_key_stops_the_carrier() {
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
    let current = Arc::new(AtomicBool::new(true));
    let check = current.clone();
    let key = random_key();
    let carrier = HubCarrier::with_key_check(
        Arc::new(FixedTickets {
            relay: route,
            peers: vec![public(&key)],
            asked: AtomicU64::new(0),
        }),
        key,
        Timings { key_check: Duration::from_millis(50), ..Timings::default() },
        Arc::new(move |_: &[u8; 32]| check.load(Ordering::SeqCst)),
    );
    let serving = carrier.serve("127.0.0.1:9".parse().unwrap());
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(!serving.is_finished(), "the carrier serves while its key is the machine's");
    current.store(false, Ordering::SeqCst);
    tokio::time::timeout(Duration::from_secs(5), async {
        while !serving.is_finished() {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .expect("the carrier kept serving with a replaced key");
    let refused = carrier.dial(&public(&key)).await.unwrap_err();
    assert!(refused.contains("replaced"), "{refused}");
}

/// The carrier's own half of a rotation: it takes the new key with the key file in one step
/// ([`HubCarrier::rekey`]), keeps serving and registers its slot again under that key. A peer
/// is handed the new key here; peers learning a rotated key by themselves needs the platform
/// to resolve a machine by id, so `machine_tunnel.rs` refuses a rotation while this carrier's
/// registration lets any machine in (`machine.rotate_strands_peers`).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn hub_carrier_a_rotated_node_key_keeps_the_slot_under_the_new_key() {
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
    let reached = Arc::new(AtomicU64::new(0));
    let seen = reached.clone();
    tokio::spawn(async move {
        while let Ok(_conn) = target.accept().await {
            seen.fetch_add(1, Ordering::SeqCst);
        }
    });
    let (key_a, old, new) = (random_key(), random_key(), random_key());
    let timings = Timings {
        control: Duration::from_secs(5),
        handshake: Duration::from_secs(5),
        key_check: Duration::from_millis(50),
        ..Timings::default()
    };
    // The machine's node key file, as B's key check reads it.
    let file = Arc::new(std::sync::Mutex::new(public(&old)));
    let check = file.clone();
    let tickets_b = Arc::new(FixedTickets {
        relay: route.clone(),
        peers: vec![public(&key_a)],
        asked: AtomicU64::new(0),
    });
    let carrier_b = HubCarrier::with_key_check(
        tickets_b.clone(),
        old,
        timings,
        Arc::new(move |key: &[u8; 32]| {
            *check.lock().unwrap() == base64::engine::general_purpose::STANDARD.encode(key)
        }),
    );
    let serving = carrier_b.serve(target_address);
    let carrier_a = HubCarrier::new(
        Arc::new(FixedTickets {
            relay: route,
            peers: vec![public(&old), public(&new)],
            asked: AtomicU64::new(0),
        }),
        key_a,
        timings,
    );
    async fn reach(a: &HubCarrier, daemon: &str) -> Result<(), String> {
        let mut last = String::new();
        for _ in 0..40 {
            match a.dial(daemon).await {
                Ok(_) => return Ok(()),
                Err(e) => last = e,
            }
            tokio::time::sleep(Duration::from_millis(250)).await;
        }
        Err(last)
    }
    reach(&carrier_a, &public(&old)).await.expect("A reaches B under its first key");
    // What a rekey reads to refuse stranding A: the machines B's registration lets in.
    assert_eq!(carrier_b.registered_peers(), vec![public(&key_a)]);
    let registered = tickets_b.asked.load(Ordering::SeqCst);

    // The rekey: the file and the carrier take the new key together.
    let written = file.clone();
    let rotated = carrier_b.rekey(new, || {
        *written.lock().unwrap() = public(&new);
        Ok::<_, ()>(())
    });
    assert!(rotated.is_ok());
    assert_eq!(carrier_b.public_key(), public(&new));
    assert!(carrier_b.key_current(), "the rotated key is the machine's");
    // Several key checks later B still serves, and it registered its slot again.
    tokio::time::sleep(Duration::from_millis(400)).await;
    assert!(!serving.is_finished(), "a rotation stopped the carrier");
    assert!(tickets_b.asked.load(Ordering::SeqCst) > registered, "B never registered again");
    let before = reached.load(Ordering::SeqCst);
    reach(&carrier_a, &public(&new)).await.expect("A reaches B under its new key");
    assert!(reached.load(Ordering::SeqCst) > before, "the circuit never reached B's listener");
    assert!(carrier_a.dial(&public(&old)).await.is_err(), "B still answers as its old key");

    // A failed write changes nothing: the carrier keeps the key the file has.
    let refused = carrier_b.rekey(random_key(), || Err::<(), _>("no write"));
    assert_eq!(refused, Err("no write"));
    assert_eq!(carrier_b.public_key(), public(&new));
    assert!(carrier_b.key_current());
}

/// What the tampering relay does to the next record A sends once armed.
#[derive(Clone, Copy, Debug)]
enum Tamper {
    /// Sends the record twice.
    Duplicate,
    /// Holds the record and sends it after the one that follows.
    Reorder,
}

/// A relay in the middle that replays or reorders A's ciphertext: a TCP proxy that parses the
/// WebSocket frames A's circuit sends the relay and, once armed, duplicates or swaps whole
/// binary frames verbatim (each is one Noise record on a `relay+ws` circuit).
struct TamperProxy {
    port: u16,
    armed: Arc<std::sync::Mutex<Option<Tamper>>>,
}

impl TamperProxy {
    async fn start(target: SocketAddr) -> Self {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let armed = Arc::new(std::sync::Mutex::new(None));
        let shared = armed.clone();
        tokio::spawn(async move {
            while let Ok((inbound, _)) = listener.accept().await {
                let Ok(outbound) = tokio::net::TcpStream::connect(target).await else { continue };
                let armed = shared.clone();
                tokio::spawn(async move {
                    let (mut ir, mut iw) = inbound.into_split();
                    let (or, mut ow) = outbound.into_split();
                    let mut or = or;
                    let up = tamper_upstream(&mut ir, &mut ow, &armed);
                    let down = tokio::io::copy(&mut or, &mut iw);
                    tokio::select! {
                        _ = up => {}
                        _ = down => {}
                    }
                });
            }
        });
        Self { port, armed }
    }

    fn arm(&self, tamper: Tamper) {
        *self.armed.lock().unwrap() = Some(tamper);
    }
}

/// One whole WebSocket frame a client sent: its opcode, its unmasked payload and its bytes.
fn next_frame(buf: &[u8]) -> Option<(u8, Vec<u8>, usize)> {
    if buf.len() < 2 {
        return None;
    }
    let opcode = buf[0] & 0x0f;
    let masked = buf[1] & 0x80 != 0;
    let (len, mut at) = match buf[1] & 0x7f {
        126 if buf.len() >= 4 => (u16::from_be_bytes([buf[2], buf[3]]) as usize, 4),
        127 if buf.len() >= 10 => (u64::from_be_bytes(buf[2..10].try_into().unwrap()) as usize, 10),
        126 | 127 => return None,
        n => (n as usize, 2),
    };
    let mask = if masked {
        let key: [u8; 4] = buf.get(at..at + 4)?.try_into().unwrap();
        at += 4;
        Some(key)
    } else {
        None
    };
    let payload = buf.get(at..at + len)?;
    let payload = match mask {
        Some(key) => payload.iter().enumerate().map(|(i, b)| b ^ key[i % 4]).collect(),
        None => payload.to_vec(),
    };
    Some((opcode, payload, at + len))
}

async fn tamper_upstream(
    from: &mut tokio::net::tcp::OwnedReadHalf,
    to: &mut tokio::net::tcp::OwnedWriteHalf,
    armed: &std::sync::Mutex<Option<Tamper>>,
) {
    let mut buf = Vec::new();
    let mut chunk = vec![0u8; 16 * 1024];
    // Before the HTTP upgrade completes the bytes pass as they are.
    let mut upgraded = false;
    // Only A's circuit (the connection that joins a circuit as its client) is tampered.
    let mut dialer = None;
    let mut held: Option<Vec<u8>> = None;
    loop {
        let n = match from.read(&mut chunk).await {
            Ok(0) | Err(_) => return,
            Ok(n) => n,
        };
        buf.extend_from_slice(&chunk[..n]);
        if !upgraded {
            let Some(end) = buf.windows(4).position(|w| w == b"\r\n\r\n") else { continue };
            if to.write_all(&buf[..end + 4]).await.is_err() {
                return;
            }
            buf.drain(..end + 4);
            upgraded = true;
        }
        while let Some((opcode, payload, size)) = next_frame(&buf) {
            let frame: Vec<u8> = buf.drain(..size).collect();
            if opcode == 1 && dialer.is_none() {
                let control = String::from_utf8_lossy(&payload);
                dialer = Some(control.contains("\"join\"") && control.contains("\"client\""));
            }
            let mut out = vec![frame.clone()];
            if opcode == 2 && dialer == Some(true) {
                if let Some(first) = held.take() {
                    out = vec![frame.clone(), first];
                } else {
                    match armed.lock().unwrap().take() {
                        Some(Tamper::Duplicate) => out = vec![frame.clone(), frame.clone()],
                        Some(Tamper::Reorder) => {
                            held = Some(frame.clone());
                            out = vec![];
                        }
                        None => {}
                    }
                }
            }
            for frame in out {
                if to.write_all(&frame).await.is_err() {
                    return;
                }
            }
        }
    }
}

/// A relay replaying or reordering A's records ends the stream at B's first check, and what A
/// sent reaches B's service at most once (the stateless Noise transport's receive nonce must
/// be the next one, `SecureLink::receive`).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn hub_carrier_a_replayed_or_reordered_record_closes_the_stream() {
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
    let proxy = TamperProxy::start(relay_address).await;
    let route = format!("relay+ws://127.0.0.1:{}", proxy.port);

    // B's service: answers an `upgrade` line, then counts every request line it runs.
    let service = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let service_address = service.local_addr().unwrap();
    let ran: Arc<std::sync::Mutex<Vec<String>>> = Arc::default();
    let log = ran.clone();
    tokio::spawn(async move {
        while let Ok((conn, _)) = service.accept().await {
            let log = log.clone();
            tokio::spawn(async move {
                let (read, mut write) = conn.into_split();
                let mut lines = tokio::io::BufReader::new(read).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    if line == "upgrade" {
                        let _ = write.write_all(b"switched\n").await;
                    } else {
                        log.lock().unwrap().push(line);
                    }
                }
            });
        }
    });

    let (key_a, key_b) = (random_key(), random_key());
    let fast = Timings {
        control: Duration::from_secs(5),
        handshake: Duration::from_secs(5),
        ..Timings::default()
    };
    let carrier_b = HubCarrier::new(
        Arc::new(FixedTickets {
            relay: route.clone(),
            peers: vec![public(&key_a)],
            asked: AtomicU64::new(0),
        }),
        key_b,
        fast,
    );
    let _serving = carrier_b.serve(service_address);
    let carrier_a = HubCarrier::new(
        Arc::new(FixedTickets {
            relay: route,
            peers: vec![public(&key_b)],
            asked: AtomicU64::new(0),
        }),
        key_a,
        fast,
    );

    for (tamper, sent) in [(Tamper::Duplicate, 1), (Tamper::Reorder, 2)] {
        ran.lock().unwrap().clear();
        // B registers in the background: dial until it answers.
        let mut stream = None;
        for _ in 0..40 {
            if let Ok(s) = carrier_a.dial(&public(&key_b)).await {
                stream = Some(s);
                break;
            }
            tokio::time::sleep(Duration::from_millis(250)).await;
        }
        let stream = stream.expect("A never reached B over the relay");
        let (read, mut write) = tokio::io::split(stream);
        let mut lines = tokio::io::BufReader::new(read).lines();
        write.write_all(b"upgrade\n").await.unwrap();
        let switched = tokio::time::timeout(Duration::from_secs(10), lines.next_line()).await;
        assert_eq!(switched.unwrap().unwrap().as_deref(), Some("switched"), "{tamper:?}");

        proxy.arm(tamper);
        for n in 0..sent {
            // Separate writes, apart in time, so each line is its own record.
            let _ = write.write_all(format!("request {n}\n").as_bytes()).await;
            tokio::time::sleep(Duration::from_millis(150)).await;
        }
        // The stream ends: B closed the link at the bad record.
        let end = tokio::time::timeout(Duration::from_secs(10), lines.next_line())
            .await
            .unwrap_or_else(|_| panic!("{tamper:?}: the stream stayed open"));
        assert!(!matches!(end, Ok(Some(_))), "{tamper:?}: {end:?}");
        tokio::time::sleep(Duration::from_millis(200)).await;
        let ran = ran.lock().unwrap().clone();
        match tamper {
            Tamper::Duplicate => assert_eq!(ran, vec!["request 0"], "the request ran twice"),
            // B refuses the record that arrived first, `request 1`: nothing ran out of order.
            Tamper::Reorder => assert!(ran.is_empty(), "a reordered request ran: {ran:?}"),
        }
    }
}

/// What machine B lets a circuit reach of its cmux-tui remote daemon, as its owner's
/// `remoteDaemon` and consent decide (`cmux_tui_service::ConfiguredGate` in a daemon).
struct TestGate {
    daemon: std::sync::Mutex<SocketAddr>,
    granted: AtomicBool,
}

#[async_trait::async_trait]
impl acpmux::hub_carrier::CmuxTuiGate for TestGate {
    async fn admit(&self, port: u16) -> Result<SocketAddr, acpmux::hub_carrier::ServiceRefusal> {
        let control = if self.granted.load(Ordering::SeqCst) { "granted" } else { "none" };
        let consent = json!({"consentRequired": true, "consent": {"control": control}});
        let daemon = self.daemon.lock().unwrap().to_string();
        acpmux::cmux_tui_service::admit(Some(daemon.as_str()), &consent, port)
    }
}

/// B: a cmux remote daemon on loopback behind its hub carrier; A: an acpmux daemon whose unix
/// socket pipes to B (`_acpmux/remote.pipe`), the relay between them in process.
struct PipeFixture {
    auth: Arc<cmux_remote::identity::AuthDatabase>,
    accepted: tokio::sync::mpsc::Receiver<Arc<cmux_remote::daemon::ServerConnection>>,
    daemon: SocketAddr,
    dialer: Arc<cmux_remote::provider::MachinePipeDialer>,
    socket: std::path::PathBuf,
    gate: Arc<TestGate>,
    carrier_a: Arc<HubCarrier>,
    carrier_b: Arc<HubCarrier>,
    _serving: acpmux::hub_carrier::HubServe,
    _dirs: (tempfile::TempDir, tempfile::TempDir),
}

async fn pipe_fixture() -> PipeFixture {
    use cmux_remote::daemon::{RemoteDaemon, serve_direct_websocket};
    use cmux_remote::identity::AuthDatabase;
    use cmux_remote::session::SessionLimits;

    let relay_listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let relay_address = relay_listener.local_addr().unwrap();
    let relay = cmux_relay::Relay::new(cmux_relay::RelayConfig {
        allow_open: true,
        // Each remote connection opens a circuit a lane (4); the numbers test connects 20 times.
        max_allocations_per_second_per_slot: 1_000,
        ..cmux_relay::RelayConfig::default()
    })
    .unwrap();
    let (relay_listener, router) = relay.server_parts(relay_listener);
    tokio::spawn(async move {
        let _ = axum::serve(relay_listener, router).await;
    });
    let route = format!("relay+ws://{relay_address}");

    let state = tempfile::tempdir().unwrap();
    let auth = AuthDatabase::load_or_create(state.path(), "machine-b", false).unwrap();
    let (daemon, accepted) = RemoteDaemon::new(auth.clone(), SessionLimits::default());
    let server = serve_direct_websocket(daemon, "127.0.0.1:0".parse().unwrap(), 65_535, false)
        .await
        .unwrap();
    let daemon_address = server.local_addr();
    // The listener lives as long as the test's runtime.
    std::mem::forget(server);
    let (key_a, key_b) = (random_key(), random_key());
    let fast = Timings {
        control: Duration::from_secs(5),
        handshake: Duration::from_secs(5),
        ..Timings::default()
    };
    let carrier_b = HubCarrier::new(
        Arc::new(FixedTickets {
            relay: route.clone(),
            peers: vec![public(&key_a)],
            asked: AtomicU64::new(0),
        }),
        key_b,
        fast,
    );
    let gate = Arc::new(TestGate {
        daemon: std::sync::Mutex::new(daemon_address),
        granted: AtomicBool::new(false),
    });
    carrier_b.set_cmux_tui_gate(gate.clone());
    // B's acpmux listener: a circuit reaches it first, and one naming cmux-tui leaves it unused.
    let acpmux_b = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let acpmux_b_address = acpmux_b.local_addr().unwrap();
    tokio::spawn(async move { while acpmux_b.accept().await.is_ok() {} });
    let serving = carrier_b.serve(acpmux_b_address);

    let a = hub();
    let carrier_a = HubCarrier::new(
        Arc::new(FixedTickets {
            relay: route,
            peers: vec![public(&key_b)],
            asked: AtomicU64::new(0),
        }),
        key_a,
        fast,
    );
    carrier_a.set_route("mac", &public(&key_b));
    a.hub_carrier.set(carrier_a.clone());
    let home = tempfile::tempdir().unwrap();
    let socket = home.path().join("acpmux.sock");
    let listener = acpmux::server::bind_unix(&socket).await.unwrap();
    tokio::spawn(acpmux::server::serve_unix(a, listener));
    // B serves once its slot is registered; until then a dial finds no one. Its gate's first
    // answer (no consent yet) is the sign that it serves.
    let mut last = String::new();
    let mut serves = false;
    for _ in 0..80 {
        let service = CircuitService::CmuxTui { port: daemon_address.port() };
        match carrier_a.dial_service(&public(&key_b), service).await {
            Err(e) if e.contains("consent_required") => {
                serves = true;
                break;
            }
            Err(e) => last = e,
            Ok(_) => panic!("a circuit reached B before its owner granted control"),
        }
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
    assert!(serves, "B never served: {last}");
    let dialer =
        Arc::new(cmux_remote::provider::MachinePipeDialer::new(socket.clone(), "mac".into()));
    PipeFixture {
        auth,
        accepted,
        daemon: daemon_address,
        dialer,
        socket,
        gate,
        carrier_a,
        carrier_b,
        _serving: serving,
        _dirs: (state, home),
    }
}

/// The `_acpmux/remote.pipe` reply line says where the open's time went, so NOW's weft probe
/// splits first byte by step: a dial after the kept circuit is open is one stream (`kept`), and
/// a new circuit names its ticket, relay, join, Noise and answer steps.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn hub_carrier_the_pipe_reply_reports_where_the_dial_went() {
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt};

    let _ = HERMETIC;
    let fixture = pipe_fixture().await;
    fixture.gate.granted.store(true, Ordering::SeqCst);
    let port = fixture.daemon.port();
    let mut dials = Vec::new();
    for _ in 0..2 {
        let stream = tokio::net::UnixStream::connect(&fixture.socket).await.unwrap();
        let (read, mut write) = stream.into_split();
        let line = json!({"jsonrpc": "2.0", "id": 1, "method": "_acpmux/remote.pipe",
                          "params": {"machine": "mac", "port": port}});
        write.write_all(format!("{line}\n").as_bytes()).await.unwrap();
        let mut reply = String::new();
        tokio::time::timeout(
            Duration::from_secs(20),
            tokio::io::BufReader::new(read).read_line(&mut reply),
        )
        .await
        .unwrap()
        .unwrap();
        let reply: serde_json::Value = serde_json::from_str(&reply).unwrap();
        assert_eq!(reply["result"]["via"], "hub", "{reply}");
        dials.push(reply["result"]["dial"].clone());
    }
    let first = &dials[0];
    match first["circuit"].as_str() {
        Some("new") => {
            for step in ["ticket", "relay", "peer_join", "noise", "answer", "total"] {
                assert!(first["ms"][step].is_number(), "{step} missing: {first}");
            }
        }
        Some("kept") => assert!(first["ms"]["stream"].is_number(), "{first}"),
        _ => panic!("the reply names no dial: {first}"),
    }
    assert_eq!(dials[1]["circuit"], "kept", "the second dial rode the kept circuit: {dials:?}");
    assert!(dials[1]["ms"]["stream"].is_number(), "{dials:?}");
    assert_eq!(fixture.carrier_a.kept_circuits(&fixture.carrier_b.public_key()), 1);
}

/// One `_acpmux/remote.pipe` open through the fixture's socket: the reply line's `result`.
async fn pipe_reply(fixture: &PipeFixture) -> serde_json::Value {
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt};

    let stream = tokio::net::UnixStream::connect(&fixture.socket).await.unwrap();
    let (read, mut write) = stream.into_split();
    let line = json!({"jsonrpc": "2.0", "id": 1, "method": "_acpmux/remote.pipe",
                      "params": {"machine": "mac", "port": fixture.daemon.port()}});
    write.write_all(format!("{line}\n").as_bytes()).await.unwrap();
    let mut reply = String::new();
    tokio::time::timeout(
        Duration::from_secs(20),
        tokio::io::BufReader::new(read).read_line(&mut reply),
    )
    .await
    .unwrap()
    .unwrap();
    let reply: serde_json::Value = serde_json::from_str(&reply).unwrap();
    reply["result"].clone()
}

/// Weft move 2: with B listening for direct circuits and A knowing B's private address, a pipe
/// dial skips the relay (`via: direct`) and the next one rides the kept direct circuit.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn hub_carrier_a_pipe_between_private_machines_goes_direct() {
    let _ = HERMETIC;
    let fixture = pipe_fixture().await;
    fixture.gate.granted.store(true, Ordering::SeqCst);
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let direct = listener.local_addr().unwrap();
    let _serving = fixture.carrier_b.serve_direct(listener);
    let b = fixture.carrier_b.public_key();
    fixture.carrier_a.set_direct_route(&b, direct);
    let first = pipe_reply(&fixture).await;
    assert_eq!(first["via"], "direct", "{first}");
    assert_eq!(first["dial"]["path"], "direct", "{first}");
    let second = pipe_reply(&fixture).await;
    assert_eq!(second["via"], "direct", "{second}");
    assert_eq!(second["dial"]["circuit"], "kept", "{second}");
    assert_eq!(fixture.carrier_a.kept_direct_circuits(&b), 1);
}

/// A direct address nobody listens on costs one refused connect: the dial takes the relay
/// (`via: hub`) and holds B off the direct path, so the next dial goes straight to the relay.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn hub_carrier_a_closed_direct_port_falls_back_to_the_relay() {
    let _ = HERMETIC;
    let fixture = pipe_fixture().await;
    fixture.gate.granted.store(true, Ordering::SeqCst);
    let closed = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = closed.local_addr().unwrap();
    drop(closed);
    let b = fixture.carrier_b.public_key();
    fixture.carrier_a.set_direct_route(&b, address);
    for _ in 0..2 {
        let reply = pipe_reply(&fixture).await;
        assert_eq!(reply["via"], "hub", "{reply}");
        assert_eq!(reply["dial"]["path"], "hub", "{reply}");
    }
    assert_eq!(fixture.carrier_a.kept_direct_circuits(&b), 0);
}

/// One remote-protocol connection to B's daemon through the pipe: with `invitation`, a new
/// device the owner approves; without, `identity` as an enrolled device.
async fn connect_through_pipe(
    fixture: &PipeFixture,
    identity: &cmux_remote::crypto::StaticIdentity,
    invitation: bool,
) -> Arc<cmux_remote::connection::ClientConnection> {
    connect_over(fixture, identity, invitation, fixture.dialer.clone()).await
}

/// [`connect_through_pipe`] over `dialer`: the pipe, or plain TCP to compare against.
async fn connect_over(
    fixture: &PipeFixture,
    identity: &cmux_remote::crypto::StaticIdentity,
    invitation: bool,
    dialer: Arc<dyn cmux_remote::provider::Dialer>,
) -> Arc<cmux_remote::connection::ClientConnection> {
    use cmux_remote::connection::{ClientConnection, ClientConnectionConfig, ReconnectPolicy};
    use cmux_remote::crypto::ClientAuthMode;
    use cmux_remote::provider::{ConnectRequest, DirectWebSocketProvider, TransportProvider};
    use cmux_remote::session::SessionLimits;
    use cmux_remote_protocol::{LanePolicy, SessionId};

    let endpoint = url::Url::parse(&format!("ws://{}/v1/link", fixture.daemon)).unwrap();
    let auth = if invitation {
        let invitation =
            fixture.auth.create_invitation(Duration::from_secs(60), vec![]).await.unwrap();
        let auth = fixture.auth.clone();
        tokio::spawn(async move {
            let pending = auth.wait_for_pending(Duration::from_secs(20)).await.unwrap();
            auth.approve(&pending[0].invitation_id).await.unwrap();
        });
        ClientAuthMode::Invitation {
            id: invitation.id.clone(),
            secret: zeroize::Zeroizing::new(invitation.secret_bytes().unwrap()),
        }
    } else {
        ClientAuthMode::Enrolled
    };
    let mut session = [0u8; 16];
    getrandom::fill(&mut session).unwrap();
    let session = SessionId(session);
    let group = DirectWebSocketProvider::with_dialer(65_535, dialer)
        .connect(ConnectRequest {
            endpoint,
            session,
            lane_policy: LanePolicy::Isolated,
            routing: Default::default(),
        })
        .await
        .unwrap();
    tokio::time::timeout(
        Duration::from_secs(30),
        ClientConnection::connect(
            group,
            ClientConnectionConfig {
                identity: identity.clone(),
                expected_daemon: Some(fixture.auth.identity().public_key()),
                auth,
                device_name: "lane-vm".into(),
                session,
                lane_policy: LanePolicy::Isolated,
                limits: SessionLimits::default(),
                reconnect: ReconnectPolicy::default(),
            },
        ),
    )
    .await
    .expect("connect through the pipe timed out")
    .unwrap()
}

/// `cmux remote exec|cp|connect --via-machine` end to end: a cmux remote daemon on B's
/// loopback, reached from A only through A's acpmux socket and the hub carrier's relay, with the
/// remote protocol's own enrollment and Noise inside. B refuses until its owner grants control,
/// and never reaches a port it did not name.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn hub_carrier_a_machine_reaches_another_machines_remote_daemon_through_the_pipe() {
    use cmux_remote::provider::Dialer;
    use cmux_remote_protocol::{FrameFlags, Lane};

    let _ = HERMETIC;
    let mut fixture = pipe_fixture().await;
    let port = fixture.daemon.port();
    let refused =
        tokio::time::timeout(Duration::from_secs(20), fixture.dialer.dial("127.0.0.1", port))
            .await
            .unwrap()
            .err()
            .expect("no consent, no daemon");
    assert!(refused.to_string().contains("consent_required"), "{refused}");
    fixture.gate.granted.store(true, Ordering::SeqCst);
    let refused = fixture.dialer.dial("127.0.0.1", 22).await.err().expect("not the named port");
    assert!(refused.to_string().contains("service.port"), "{refused}");

    let identity = cmux_remote::crypto::StaticIdentity::generate().unwrap();
    let client = connect_through_pipe(&fixture, &identity, true).await;
    let daemon_client = tokio::time::timeout(Duration::from_secs(10), fixture.accepted.recv())
        .await
        .unwrap()
        .unwrap();
    client
        .send(Lane::Interactive, 1, bytes::Bytes::from_static(b"keys"), FrameFlags::empty())
        .await
        .unwrap();
    assert_eq!(daemon_client.receive().await.unwrap().unwrap().payload, b"keys".as_slice());
    let screen = vec![0x5a; 16_000];
    daemon_client
        .send(Lane::Bulk, 2, bytes::Bytes::from(screen.clone()), FrameFlags::empty())
        .await
        .unwrap();
    assert_eq!(client.receive().await.unwrap().unwrap().payload, screen.as_slice());
    // One pipe carries every lane (`MachinePipeDialer::parallel_links`), and it is a stream on
    // the kept circuit to B: the refusals before it rode that circuit too, so no plain circuit.
    let a = fixture.carrier_a.stats();
    assert!(fixture.carrier_b.stats().accepted.load(Ordering::Relaxed) >= 1);
    assert!(a.kept_opens.load(Ordering::Relaxed) >= 1);
    assert_eq!(a.kept_circuits.load(Ordering::Relaxed), 1);
    assert_eq!(a.dials.load(Ordering::Relaxed), 0);
}

/// `future`'s output, or a panic naming `what` after 30 s: a stalled numbers run fails, not hangs.
async fn within<T>(what: &str, future: impl std::future::Future<Output = T>) -> T {
    tokio::time::timeout(Duration::from_secs(30), future)
        .await
        .unwrap_or_else(|_| panic!("{what} stalled for 30 s"))
}

fn percentile(samples: &mut [Duration], p: f64) -> Duration {
    samples.sort();
    samples[((samples.len() - 1) as f64 * p).round() as usize]
}

/// Connect and throughput numbers of the relayed pipe on loopback (run on demand:
/// `cargo test -p acpmux --features hub-carrier --test hub_carrier pipe_numbers -- --ignored
/// --nocapture`). The relay is in process, so they measure the carrier's own cost, not a network.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "numbers on demand"]
async fn hub_carrier_pipe_numbers() {
    use cmux_remote_protocol::{FrameFlags, Lane};

    let _ = HERMETIC;
    let mut fixture = pipe_fixture().await;
    fixture.gate.granted.store(true, Ordering::SeqCst);
    let identity = cmux_remote::crypto::StaticIdentity::generate().unwrap();
    let enrolled = connect_through_pipe(&fixture, &identity, true).await;
    let _ = within("the enrolling connect", fixture.accepted.recv()).await.unwrap();
    let _ = enrolled.close().await;
    let mut connects = Vec::new();
    for _ in 0..20 {
        let started = std::time::Instant::now();
        let client = connect_through_pipe(&fixture, &identity, false).await;
        connects.push(started.elapsed());
        let _ = within("a connect", fixture.accepted.recv()).await.unwrap();
        let _ = client.close().await;
    }
    let client = connect_through_pipe(&fixture, &identity, false).await;
    let daemon_client = within("the echo connect", fixture.accepted.recv()).await.unwrap();
    let mut echoes = Vec::new();
    for i in 0..20u64 {
        let started = std::time::Instant::now();
        client
            .send(Lane::Interactive, i, bytes::Bytes::from_static(b"k"), FrameFlags::empty())
            .await
            .unwrap();
        let frame = within("an echo", daemon_client.receive()).await.unwrap().unwrap();
        daemon_client.send(Lane::Interactive, i, frame.payload, FrameFlags::empty()).await.unwrap();
        let _ = within("an echo back", client.receive()).await.unwrap().unwrap();
        echoes.push(started.elapsed());
    }
    eprintln!(
        "PIPE-NUMBERS relayed connect_ms p50={:.1} p95={:.1} n=20; echo_ms p50={:.2} p95={:.2} n=20",
        percentile(&mut connects, 0.5).as_secs_f64() * 1e3,
        percentile(&mut connects, 0.95).as_secs_f64() * 1e3,
        percentile(&mut echoes, 0.5).as_secs_f64() * 1e3,
        percentile(&mut echoes, 0.95).as_secs_f64() * 1e3,
    );
    let total: usize = 64 << 20;
    let elapsed = bulk_down(&client, &daemon_client, total, true).await.unwrap();
    eprintln!(
        "PIPE-NUMBERS relayed down_mibs={:.1} ({} MiB, every frame checked)",
        (total as f64 / (1 << 20) as f64) / elapsed.as_secs_f64(),
        total >> 20,
    );
}

/// What machine B lets a session circuit reach: its consent, decided as a daemon decides it
/// (`session_service::decide`), and its own cmux-tui session socket. Counts the asks it records.
struct TestSessionGate {
    consent: std::sync::Mutex<Value>,
    socket: std::path::PathBuf,
    asks: std::sync::Mutex<Vec<String>>,
}

#[async_trait::async_trait]
impl acpmux::hub_carrier::SessionGate for TestSessionGate {
    async fn admit(
        &self,
        from: &str,
    ) -> Result<std::path::PathBuf, acpmux::hub_carrier::ServiceRefusal> {
        use acpmux::session_service::{Decision, decide, session_socket};
        let consent = self.consent.lock().unwrap().clone();
        match decide(&consent, Some("user-1"), false) {
            Decision::Admit => session_socket(Some(&self.socket)),
            Decision::Refuse { refusal, ask } => {
                if ask {
                    self.asks.lock().unwrap().push(from.to_owned());
                }
                Err(refusal)
            }
        }
    }
}

fn session_consent(signed_in: &str, answered: bool) -> Value {
    let mut consent = json!({"screen": "none", "control": "none", "signedInMachines": signed_in});
    if answered {
        consent["signedInMachinesAnsweredAt"] = json!("1");
        consent["signedInMachinesUser"] = json!("user-1");
    }
    json!({"consentRequired": true, "consent": consent})
}

/// New Workspace on a joined Mac, at the carrier: A dials B naming the cmux-tui session service.
/// With nothing granted B refuses with the reason and records its one ask (naming A's key); after
/// Not now it refuses with no new ask; after the one-click grant A's bytes reach B's own
/// cmux-tui session socket and its answers come back. An acpmux circuit to B is not changed.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn hub_carrier_a_cmux_tui_session_circuit_needs_the_signed_in_machines_grant() {
    use acpmux::hub_carrier::CircuitService;

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

    // B's own cmux-tui session socket: it answers each line with "tui: LINE".
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("tui.sock");
    let listener = tokio::net::UnixListener::bind(&socket).unwrap();
    tokio::spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            tokio::spawn(async move {
                let (read, mut write) = stream.into_split();
                let mut lines = tokio::io::BufReader::new(read).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    if write.write_all(format!("tui: {line}\n").as_bytes()).await.is_err() {
                        return;
                    }
                }
            });
        }
    });

    let (key_a, key_b) = (random_key(), random_key());
    let fast = Timings {
        control: Duration::from_secs(5),
        handshake: Duration::from_secs(5),
        ..Timings::default()
    };
    let carrier_b = HubCarrier::new(
        Arc::new(FixedTickets {
            relay: route.clone(),
            peers: vec![public(&key_a)],
            asked: AtomicU64::new(0),
        }),
        key_b,
        fast,
    );
    let gate = Arc::new(TestSessionGate {
        consent: std::sync::Mutex::new(session_consent("none", false)),
        socket: socket.clone(),
        asks: Default::default(),
    });
    carrier_b.set_session_gate(gate.clone());
    let nothing = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap();
    let _serving = carrier_b.serve(nothing);
    let carrier_a = HubCarrier::new(
        Arc::new(FixedTickets {
            relay: route,
            peers: vec![public(&key_b)],
            asked: AtomicU64::new(0),
        }),
        key_a,
        fast,
    );
    let b = public(&key_b);

    // Nothing granted: refused with the reason, and the one ask names A. B's registration may
    // still be on its way, so the first dial goes again until B answers.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    let refused = loop {
        match carrier_a.dial_service(&b, CircuitService::CmuxTuiSession).await {
            Ok(_) => panic!("a session circuit was admitted with nothing granted"),
            Err(e) if e.contains("consent_required") => break e,
            Err(e) => {
                assert!(tokio::time::Instant::now() < deadline, "B never answered: {e}");
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
        }
    };
    assert!(refused.contains("allow workspaces"), "{refused}");
    assert_eq!(*gate.asks.lock().unwrap(), vec![public(&key_a)], "one ask, naming A");

    // Not now: refused, and no new ask.
    *gate.consent.lock().unwrap() = session_consent("none", true);
    let refused = carrier_a.dial_service(&b, CircuitService::CmuxTuiSession).await.unwrap_err();
    assert!(refused.contains("consent_declined"), "{refused}");
    assert_eq!(gate.asks.lock().unwrap().len(), 1, "asked once");

    // Control from elsewhere alone admits no workspace.
    *gate.consent.lock().unwrap() =
        json!({"consentRequired": true, "consent": {"control": "granted"}});
    assert!(carrier_a.dial_service(&b, CircuitService::CmuxTuiSession).await.is_err());

    // The one-click grant: A reaches B's session socket.
    *gate.consent.lock().unwrap() = session_consent("granted", true);
    let mut circuit = carrier_a.dial_service(&b, CircuitService::CmuxTuiSession).await.unwrap();
    circuit.write_all(b"workspace.create\n").await.unwrap();
    let mut answer = vec![0u8; "tui: workspace.create\n".len()];
    tokio::time::timeout(Duration::from_secs(10), circuit.read_exact(&mut answer))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(answer, b"tui: workspace.create\n");

    // Revoked on B: the next circuit is refused again.
    *gate.consent.lock().unwrap() = session_consent("none", true);
    assert!(carrier_a.dial_service(&b, CircuitService::CmuxTuiSession).await.is_err());

    // B with its socket gone: refused by name, never a hang.
    *gate.consent.lock().unwrap() = session_consent("granted", true);
    drop(dir);
    let refused = carrier_a.dial_service(&b, CircuitService::CmuxTuiSession).await.unwrap_err();
    assert!(refused.contains("service.unreachable"), "{refused}");
}

struct TestCallGate {
    consent: std::sync::Mutex<Value>,
    asks: std::sync::Mutex<Vec<String>>,
}

#[async_trait::async_trait]
impl acpmux::hub_carrier::MachineCallGate for TestCallGate {
    async fn open(
        &self,
        from: &str,
    ) -> Result<acpmux::hub_carrier::HubStream, acpmux::hub_carrier::ServiceRefusal> {
        use acpmux::machine_call_service::{decide, serve};
        let consent = self.consent.lock().unwrap().clone();
        if let Err((refusal, ask)) = decide(&consent, Some("user-1")) {
            if ask {
                self.asks.lock().unwrap().push(from.to_owned());
            }
            return Err(refusal);
        }
        let (near, far) = tokio::io::duplex(64 * 1024);
        let from = from.to_owned();
        tokio::spawn(serve(far, move |method, params| {
            let from = from.clone();
            async move { Ok(json!({"ran": method, "for": from, "params": params})) }
        }));
        Ok(near)
    }
}

/// An agent on one machine using Computer Use on another, at the carrier: A dials B naming the
/// machine-call service. With nothing granted B refuses with the reason and records its one ask
/// (naming A's key); after the person's grant B's daemon answers A's call in process, told which
/// machine asked by the handshake, not by the request; a method the service does not list is
/// refused; revoked, the next circuit is refused again. A machine with no gate serves none.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn hub_carrier_a_machine_call_circuit_needs_the_signed_in_machines_grant() {
    use acpmux::hub_carrier::CircuitService;
    use acpmux::machine_call_service::{COMPUTER_USE_CALL, ask};

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

    let (key_a, key_b) = (random_key(), random_key());
    let fast = Timings {
        control: Duration::from_secs(5),
        handshake: Duration::from_secs(5),
        ..Timings::default()
    };
    let carrier_b = HubCarrier::new(
        Arc::new(FixedTickets {
            relay: route.clone(),
            peers: vec![public(&key_a)],
            asked: AtomicU64::new(0),
        }),
        key_b,
        fast,
    );
    let nothing = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap();
    let _serving = carrier_b.serve(nothing);
    let carrier_a = HubCarrier::new(
        Arc::new(FixedTickets {
            relay: route,
            peers: vec![public(&key_b)],
            asked: AtomicU64::new(0),
        }),
        key_a,
        fast,
    );
    let b = public(&key_b);

    // No gate on B yet: refused by name. B's registration may still be on its way, so the
    // first dial goes again until B answers.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    loop {
        match carrier_a.dial_service(&b, CircuitService::MachineCall).await {
            Ok(_) => panic!("a machine-call circuit was admitted with no gate"),
            Err(e) if e.contains("service.off") => break,
            Err(e) => {
                assert!(tokio::time::Instant::now() < deadline, "B never answered: {e}");
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
        }
    }

    // Nothing granted: refused with the reason, and the one ask names A.
    let gate = Arc::new(TestCallGate {
        consent: std::sync::Mutex::new(session_consent("none", false)),
        asks: Default::default(),
    });
    carrier_b.set_machine_call_gate(gate.clone());
    let refused = carrier_a.dial_service(&b, CircuitService::MachineCall).await.unwrap_err();
    assert!(refused.contains("consent_required"), "{refused}");
    assert!(refused.contains("allow control"), "{refused}");
    assert_eq!(*gate.asks.lock().unwrap(), vec![public(&key_a)], "one ask, naming A");

    // Not now: refused, and no new ask. Control from elsewhere alone admits nothing.
    *gate.consent.lock().unwrap() = session_consent("none", true);
    let refused = carrier_a.dial_service(&b, CircuitService::MachineCall).await.unwrap_err();
    assert!(refused.contains("consent_declined"), "{refused}");
    assert_eq!(gate.asks.lock().unwrap().len(), 1, "asked once");
    *gate.consent.lock().unwrap() =
        json!({"consentRequired": true, "consent": {"control": "granted"}});
    assert!(carrier_a.dial_service(&b, CircuitService::MachineCall).await.is_err());

    // The grant: B's daemon answers A's call, and knows A by its proven key.
    *gate.consent.lock().unwrap() = session_consent("granted", true);
    let circuit = carrier_a.dial_service(&b, CircuitService::MachineCall).await.unwrap();
    let answer = ask(
        circuit,
        COMPUTER_USE_CALL,
        json!({"name": "screenshot", "for": "someone else"}),
        Duration::from_secs(10),
    )
    .await
    .unwrap();
    assert_eq!(answer["ran"], COMPUTER_USE_CALL);
    assert_eq!(answer["for"], public(&key_a));
    assert_eq!(answer["params"]["name"], "screenshot");

    // A method the service does not list is refused, whatever it carries.
    let circuit = carrier_a.dial_service(&b, CircuitService::MachineCall).await.unwrap();
    let error = ask(circuit, "exec", json!({"argv": ["sh"]}), Duration::from_secs(10))
        .await
        .unwrap_err()
        .expect("a refusal");
    assert_eq!(error.code, -32601);

    // Revoked on B: the next circuit is refused again.
    *gate.consent.lock().unwrap() = session_consent("none", true);
    assert!(carrier_a.dial_service(&b, CircuitService::MachineCall).await.is_err());
}

/// A carrier with no session gate (an older daemon's, or a machine that serves none) refuses a
/// session circuit by name.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn hub_carrier_a_session_circuit_to_a_machine_with_no_session_gate_is_refused() {
    use acpmux::hub_carrier::CircuitService;

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
    let (key_a, key_b) = (random_key(), random_key());
    let fast = Timings {
        control: Duration::from_secs(5),
        handshake: Duration::from_secs(5),
        ..Timings::default()
    };
    let carrier_b = HubCarrier::new(
        Arc::new(FixedTickets {
            relay: route.clone(),
            peers: vec![public(&key_a)],
            asked: AtomicU64::new(0),
        }),
        key_b,
        fast,
    );
    let nothing = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap();
    let _serving = carrier_b.serve(nothing);
    let carrier_a = HubCarrier::new(
        Arc::new(FixedTickets {
            relay: route,
            peers: vec![public(&key_b)],
            asked: AtomicU64::new(0),
        }),
        key_a,
        fast,
    );
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    loop {
        match carrier_a.dial_service(&public(&key_b), CircuitService::CmuxTuiSession).await {
            Ok(_) => panic!("admitted with no gate"),
            Err(e) if e.contains("service.off") => break,
            Err(e) => {
                assert!(tokio::time::Instant::now() < deadline, "B never answered: {e}");
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
        }
    }
}

/// [`C::call`], answering the error instead of failing on one.
async fn call_result(c: &mut C, m: &str, p: Value) -> Result<Value, Value> {
    c.next += 1;
    let id = c.next;
    c.tx.send(Message::request(id, m, p).to_line()).await.unwrap();
    loop {
        let line = tokio::time::timeout(Duration::from_secs(30), c.rx.recv())
            .await
            .expect("timeout")
            .expect("closed");
        if let Message::Response { id: rid, result, error } = Message::parse(&line).unwrap()
            && rid == id
        {
            return match error {
                Some(error) => Err(serde_json::to_value(error).unwrap()),
                None => Ok(result.unwrap_or(Value::Null)),
            };
        }
    }
}

/// The boundary of cut 1: a machine the hub lists for this person (what signing in, a pair code
/// or a join line makes) is offered to the app as a workspace target over the hub path, with a
/// local unix route. New Workspace's first ask (the probe) is refused while the person there has
/// not allowed it, which records that machine's one ask; a connection to the route then reaches
/// nothing. After the one-click grant there, the probe passes and the route carries the app's
/// bytes to that machine's own cmux-tui session socket and back.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn hub_carrier_a_signed_in_machine_is_a_workspace_target_after_its_one_click_grant() {
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

    // Machine B: its own cmux-tui session socket answers each line with "tui: LINE".
    let dir = tempfile::tempdir().unwrap();
    let tui = dir.path().join("tui.sock");
    let listener = tokio::net::UnixListener::bind(&tui).unwrap();
    tokio::spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            tokio::spawn(async move {
                let (read, mut write) = stream.into_split();
                let mut lines = tokio::io::BufReader::new(read).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    if write.write_all(format!("tui: {line}\n").as_bytes()).await.is_err() {
                        return;
                    }
                }
            });
        }
    });
    let (key_a, key_b) = (random_key(), random_key());
    let fast = Timings {
        control: Duration::from_secs(5),
        handshake: Duration::from_secs(5),
        ..Timings::default()
    };
    let carrier_b = HubCarrier::new(
        Arc::new(FixedTickets {
            relay: route.clone(),
            peers: vec![public(&key_a)],
            asked: AtomicU64::new(0),
        }),
        key_b,
        fast,
    );
    let gate = Arc::new(TestSessionGate {
        consent: std::sync::Mutex::new(session_consent("none", false)),
        socket: tui.clone(),
        asks: Default::default(),
    });
    carrier_b.set_session_gate(gate.clone());
    let nothing = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap();
    let _serving = carrier_b.serve(nothing);

    // Machine A: the app's acpmux, its carrier, and the hub's book listing B for this person.
    let a = hub();
    let carrier_a = HubCarrier::new(
        Arc::new(FixedTickets {
            relay: route,
            peers: vec![public(&key_b)],
            asked: AtomicU64::new(0),
        }),
        key_a,
        fast,
    );
    a.hub_carrier.set(carrier_a);
    let b = public(&key_b);
    a.set_mesh_book_machines(BTreeMap::from([(b.clone(), "machine-b".to_owned())]));
    let mut app = client(a.clone()).await;

    // Offered as a workspace target over the hub path, with a local route.
    let routes = app.call(method::MUX_MACHINE_ROUTES, json!({})).await;
    let machines = routes["machines"].as_array().unwrap();
    assert_eq!(machines.len(), 1, "{routes}");
    let target = &machines[0];
    assert_eq!(target["host"], "machine-b");
    assert_eq!(target["daemonId"], b.as_str());
    assert_eq!(target["via"], "hub");
    assert_eq!(target["route"], "unix", "{target}");
    let socket = std::path::PathBuf::from(target["socket"].as_str().unwrap());
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(&socket).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "the route is the user's own");
    }

    // New Workspace's first ask: refused with the reason, and B records its one ask, naming A.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    let refused = loop {
        let refused =
            call_result(&mut app, method::MUX_MACHINE_ROUTE_PROBE, json!({"daemonId": b}))
                .await
                .expect_err("no grant, no workspace");
        if refused["data"]["reason"] == "consent_required" {
            break refused;
        }
        assert!(tokio::time::Instant::now() < deadline, "B never answered: {refused}");
        tokio::time::sleep(Duration::from_millis(100)).await;
    };
    assert!(refused["message"].as_str().unwrap().contains("allow workspaces"), "{refused}");
    assert_eq!(*gate.asks.lock().unwrap(), vec![public(&key_a)]);
    let routes = app.call(method::MUX_MACHINE_ROUTES, json!({})).await;
    assert_eq!(routes["machines"][0]["state"], "refused");
    assert_eq!(routes["machines"][0]["refusal"]["reason"], "consent_required");
    // A connection to the route reaches nothing while refused: it is closed.
    let mut stream = tokio::net::UnixStream::connect(&socket).await.unwrap();
    let _ = stream.write_all(b"workspace.create\n").await;
    let mut buf = [0u8; 16];
    let read = tokio::time::timeout(Duration::from_secs(20), stream.read(&mut buf)).await.unwrap();
    assert!(matches!(read, Ok(0) | Err(_)), "the refused route carried bytes");

    // The one-click grant on B: the probe passes and the route reaches B's session socket.
    *gate.consent.lock().unwrap() = session_consent("granted", true);
    let ok = app.call(method::MUX_MACHINE_ROUTE_PROBE, json!({"daemonId": b})).await;
    assert_eq!(ok["ok"], true);
    let routes = app.call(method::MUX_MACHINE_ROUTES, json!({})).await;
    assert_eq!(routes["machines"][0]["state"], "ready");
    let mut stream = tokio::net::UnixStream::connect(&socket).await.unwrap();
    stream.write_all(b"workspace.create\n").await.unwrap();
    let mut answer = vec![0u8; "tui: workspace.create\n".len()];
    tokio::time::timeout(Duration::from_secs(20), stream.read_exact(&mut answer))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(answer, b"tui: workspace.create\n");

    // B leaves the book: its route goes, and a probe is refused by name.
    a.set_mesh_book_machines(BTreeMap::new());
    let routes = app.call(method::MUX_MACHINE_ROUTES, json!({})).await;
    assert!(routes["machines"].as_array().unwrap().is_empty());
    assert!(!socket.exists(), "the route's socket is removed");
    let refused = call_result(&mut app, method::MUX_MACHINE_ROUTE_PROBE, json!({"daemonId": b}))
        .await
        .unwrap_err();
    assert_eq!(refused["data"]["reason"], "machine.unlisted");
}

/// Frame `i` of a bulk transfer: its index in every byte, so a lost, repeated or reordered frame
/// shows.
fn bulk_frame(i: u64, len: usize) -> bytes::Bytes {
    bytes::Bytes::from(vec![(i % 251) as u8; len])
}

/// Send `total` bytes in 32 KiB bulk frames from `daemon_client` to `client` on one stream and
/// check each arrives whole and in order. Ok with the time it took; Err with where it stalled.
async fn bulk_down(
    client: &Arc<cmux_remote::connection::ClientConnection>,
    daemon_client: &Arc<cmux_remote::daemon::ServerConnection>,
    total: usize,
    daemon_reads: bool,
) -> Result<Duration, String> {
    use cmux_remote_protocol::{FrameFlags, Lane};
    const FRAME: usize = 32 * 1024;
    let frames = (total / FRAME) as u64;
    // The daemon reads while it sends, as a served connection always does (its service
    // multiplexer): acknowledgements are applied as it reads, and only they open its delivery
    // window. A sender that never reads stalls at each full window until a reconnect.
    let reader = {
        let daemon_client = daemon_client.clone();
        tokio::spawn(async move {
            while daemon_reads && matches!(daemon_client.receive().await, Ok(Some(_))) {}
        })
    };
    let started = std::time::Instant::now();
    let sender = {
        let daemon_client = daemon_client.clone();
        tokio::spawn(async move {
            for i in 0..frames {
                daemon_client
                    .send(Lane::Bulk, 2, bulk_frame(i, FRAME), FrameFlags::empty())
                    .await
                    .map_err(|e| format!("send {i}: {e}"))?;
            }
            Ok::<_, String>(())
        })
    };
    for i in 0..frames {
        let frame = match tokio::time::timeout(Duration::from_secs(20), client.receive()).await {
            Ok(Ok(Some(frame))) => frame,
            Ok(other) => return Err(format!("frame {i} of {frames}: {other:?}")),
            Err(_) => {
                return Err(format!(
                    "frame {i} of {frames} stalled for 20 s ({:?} in)",
                    started.elapsed()
                ));
            }
        };
        if frame.payload != bulk_frame(i, FRAME) {
            return Err(format!(
                "frame {i} of {frames} is not the one sent: lane {:?} stream {} sequence {} \
                 generation {} len {} first byte {:?} (expected {})",
                frame.lane,
                frame.stream,
                frame.sequence,
                frame.generation,
                frame.payload.len(),
                frame.payload.first(),
                i % 251,
            ));
        }
    }
    let elapsed = started.elapsed();
    sender.await.map_err(|e| e.to_string())??;
    reader.abort();
    Ok(elapsed)
}

/// A `cp` through the pipe: 16 MiB from the far machine's daemon arrives byte for byte, and in
/// bounded time (loopback with the relay in process: seconds, not minutes).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn hub_carrier_the_pipe_carries_16_mib_whole_and_in_time() {
    let _ = HERMETIC;
    let mut fixture = pipe_fixture().await;
    fixture.gate.granted.store(true, Ordering::SeqCst);
    let identity = cmux_remote::crypto::StaticIdentity::generate().unwrap();
    let client = connect_through_pipe(&fixture, &identity, true).await;
    let daemon_client = within("the connect", fixture.accepted.recv()).await.unwrap();
    let elapsed = bulk_down(&client, &daemon_client, 16 << 20, true).await.unwrap();
    assert!(elapsed < Duration::from_secs(60), "16 MiB took {elapsed:?}");
}

/// Where a bulk transfer's time goes, layer by layer (run on demand, `--ignored --nocapture`):
/// the remote protocol over plain TCP, raw bytes through the carrier, raw bytes through the
/// pipe, and the remote protocol through the pipe.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "diagnosis on demand"]
async fn hub_carrier_pipe_bulk_layers() {
    use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
    let _ = HERMETIC;
    const TOTAL: usize = 16 << 20;
    let mut fixture = pipe_fixture().await;
    fixture.gate.granted.store(true, Ordering::SeqCst);
    let identity = cmux_remote::crypto::StaticIdentity::generate().unwrap();

    let tcp = Arc::new(cmux_remote::provider::OsTcpDialer);
    let client = connect_over(&fixture, &identity, true, tcp.clone()).await;
    let daemon_client = within("the tcp connect", fixture.accepted.recv()).await.unwrap();
    let result = bulk_down(&client, &daemon_client, TOTAL, true).await;
    eprintln!("LAYER remote-over-tcp {result:?} generation {}", client.snapshot().await.generation);
    let _ = client.close().await;

    // A server that sends TOTAL bytes and closes.
    let blast = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let blast_address = blast.local_addr().unwrap();
    tokio::spawn(async move {
        while let Ok((mut stream, _)) = blast.accept().await {
            tokio::spawn(async move {
                let chunk = vec![0x5au8; 64 * 1024];
                for _ in 0..TOTAL / chunk.len() {
                    if stream.write_all(&chunk).await.is_err() {
                        return;
                    }
                }
                let _ = stream.shutdown().await;
            });
        }
    });
    *fixture.gate.daemon.lock().unwrap() = blast_address;
    async fn drain(mut stream: impl tokio::io::AsyncRead + Unpin) -> Result<Duration, String> {
        let started = std::time::Instant::now();
        let mut buf = vec![0u8; 64 * 1024];
        let mut got = 0usize;
        loop {
            match tokio::time::timeout(Duration::from_secs(20), stream.read(&mut buf)).await {
                Ok(Ok(0)) => break,
                Ok(Ok(n)) => got += n,
                Ok(Err(e)) => return Err(format!("{e} after {got}")),
                Err(_) => return Err(format!("stalled after {got} bytes")),
            }
        }
        if got != TOTAL {
            return Err(format!("{got} bytes of {TOTAL}"));
        }
        Ok(started.elapsed())
    }
    let mac = fixture.carrier_a.route("mac").unwrap();
    let service = CircuitService::CmuxTui { port: blast_address.port() };
    let circuit = fixture.carrier_a.dial_service(&mac, service).await.unwrap();
    eprintln!("LAYER raw-carrier {:?}", drain(circuit).await);
    {
        use cmux_remote::provider::Dialer;
        let piped = fixture.dialer.dial("127.0.0.1", blast_address.port()).await.unwrap();
        eprintln!("LAYER raw-pipe {:?}", drain(piped).await);
    }
    *fixture.gate.daemon.lock().unwrap() = fixture.daemon;

    let client = connect_through_pipe(&fixture, &identity, false).await;
    let daemon_client = within("the pipe connect", fixture.accepted.recv()).await.unwrap();
    let result = bulk_down(&client, &daemon_client, TOTAL, true).await;
    eprintln!(
        "LAYER remote-over-pipe {result:?} generation {}",
        client.snapshot().await.generation
    );
}

/// A frame sent while the session reconnects is sent, not dropped. A daemon that sends without
/// reading never applies its acknowledgements, so each full delivery window ends in a liveness
/// reconnect; the frame a send held across one went missing and the next took its sequence
/// (frame 7 of 32 arrived as 8 before the fix), here over plain TCP and through the pipe alike.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn hub_carrier_no_bulk_frame_is_lost_across_a_reconnect() {
    let _ = HERMETIC;
    let mut fixture = pipe_fixture().await;
    fixture.gate.granted.store(true, Ordering::SeqCst);
    let identity = cmux_remote::crypto::StaticIdentity::generate().unwrap();
    let tcp = Arc::new(cmux_remote::provider::OsTcpDialer);
    let client = connect_over(&fixture, &identity, true, tcp).await;
    let daemon_client = within("the connect", fixture.accepted.recv()).await.unwrap();
    bulk_down(&client, &daemon_client, 1 << 20, false).await.unwrap();
    assert!(client.snapshot().await.generation > 1, "the transfer never crossed a reconnect");
}

/// A joined machine whose config.json has no `websocket` (a Mac's plain `acpmux daemon start`
/// under launchd) still runs its hub carrier, bridged to the daemon's own loopback listener, and
/// its start says so in the log. A Mac's daemon.log said "mesh relay: on" and nothing at all
/// about the carrier, so nobody could tell whether it ran.
#[test]
fn hub_carrier_a_joined_daemon_with_no_websocket_config_runs_it_on_loopback_and_logs_it() {
    use std::io::BufRead;
    use std::time::Instant;
    // Short: the socket path must stay under the macOS limit.
    let dir = std::env::temp_dir().join(format!("amx-hc-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).unwrap();
    }
    // Joined with the machine credential, and no `websocket` key at all. The hub is a closed
    // port: the carrier's ticket requests fail and it keeps retrying, as with the platform down.
    let config = json!({"meshRelay": {"url": "http://127.0.0.1:9", "credential": "join"}});
    std::fs::write(dir.join("config.json"), config.to_string()).unwrap();
    let mut child = daemon_env::command(&dir, daemon_env::Agents::Deny, &[])
        .args(["daemon", "run", "--memory", "--log", "info"])
        .env("ACPMUX_HOME", &dir)
        .env("ACPMUX_SOCKET", dir.join("s.sock"))
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
        .unwrap();
    let (tx, rx) = std::sync::mpsc::channel::<String>();
    let stdout = child.stdout.take().unwrap();
    std::thread::spawn(move || {
        for line in std::io::BufReader::new(stdout).lines().map_while(Result::ok) {
            if tx.send(line).is_err() {
                break;
            }
        }
    });
    let deadline = Instant::now() + Duration::from_secs(60);
    let mut seen = Vec::new();
    let carrier = loop {
        let left = deadline.saturating_duration_since(Instant::now());
        match rx.recv_timeout(left) {
            Ok(line) if line.contains("hub carrier") => break Some(line),
            Ok(line) => seen.push(line),
            Err(_) => break None,
        }
    };
    let _ = child.kill();
    let _ = child.wait();
    let _ = std::fs::remove_dir_all(&dir);
    let line = carrier.unwrap_or_else(|| {
        panic!("the start logged nothing about the hub carrier:\n{}", seen.join("\n"))
    });
    assert!(line.contains("hub carrier: on"), "the carrier is off: {line}");
    assert!(line.contains("127.0.0.1:"), "the carrier is not on the loopback listener: {line}");
}

/// How long A takes from adding peer `b` to its link being connected, with `url` as b's
/// configured URL and the hub carrier's relay as the other path; the relay is fresh each run.
async fn time_to_connected(url: &str) -> Duration {
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
    let home = tempfile::tempdir().unwrap();
    let auth = PeerAuth::create(home.path()).unwrap();
    let peer_token =
        std::fs::read_to_string(acpmux::server::peer_auth::token_path(home.path())).unwrap();
    let b = hub();
    let l = bind_ws("127.0.0.1:0").await.unwrap();
    let b_ws = l.local_addr().unwrap();
    let ws_auth = WsAuth { local_app: None, peer: Some(Arc::new(auth)) };
    tokio::spawn(serve_ws_with(b.clone(), l, "tok".into(), ws_auth));
    let (key_a, key_b) = (random_key(), random_key());
    let fast = Timings {
        control: Duration::from_secs(5),
        handshake: Duration::from_secs(5),
        ..Timings::default()
    };
    let tickets_b = Arc::new(FixedTickets {
        relay: route.clone(),
        peers: vec![public(&key_a)],
        asked: AtomicU64::new(0),
    });
    let carrier_b = HubCarrier::new(tickets_b, key_b, fast);
    let _serving = carrier_b.serve(b_ws);
    // B's slot is registered before A dials, as for a machine that has been up a while.
    tokio::time::sleep(Duration::from_millis(300)).await;
    let a = hub();
    let tickets_a = Arc::new(FixedTickets {
        relay: route.clone(),
        peers: vec![public(&key_b)],
        asked: AtomicU64::new(0),
    });
    let carrier_a = HubCarrier::new(tickets_a, key_a, fast);
    carrier_a.set_route("b", &public(&key_b));
    a.hub_carrier.set(carrier_a);
    let started = tokio::time::Instant::now();
    a.add_peer("b", url, Some("tok".into()), Some(peer_token), false).await.unwrap();
    while state_of(&a).await != "connected" {
        assert!(started.elapsed() < Duration::from_secs(30), "peer b never connected over {url}");
        tokio::time::sleep(Duration::from_millis(2)).await;
    }
    let took = started.elapsed();
    let _ = a.remove_peer("b").await;
    took
}

/// Relay first: a peer with a hub route dials the relay at once, beside its configured path,
/// so a black-holed direct endpoint (TCP accepted, nothing answers: a punch that failed, a
/// WireGuard endpoint behind a firewall that drops) costs no more first-byte time than the
/// relay open itself. Before, the relay was dialed one stagger (250 ms) after the dead path.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn hub_carrier_a_black_holed_direct_path_costs_no_more_than_the_relay_open() {
    let _ = HERMETIC;
    // Accepts nothing: a connect lands in the backlog and the WebSocket upgrade never answers.
    let hole = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let holed = format!("ws://{}", hole.local_addr().unwrap());
    // Refuses at once: the relay is the only path from the first moment.
    let refused = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap();
    let refused = format!("ws://{refused}");
    let mut relay_only = Vec::new();
    let mut black_holed = Vec::new();
    for _ in 0..3 {
        relay_only.push(time_to_connected(&refused).await);
        black_holed.push(time_to_connected(&holed).await);
    }
    relay_only.sort();
    black_holed.sort();
    let (relay_only, black_holed) = (relay_only[1], black_holed[1]);
    eprintln!(
        "relay first: median time to connected {} ms relay only (direct refused), {} ms with \
         a black-holed direct path",
        relay_only.as_millis(),
        black_holed.as_millis()
    );
    // Before relay first the black hole added the 250 ms stagger; within noise of nothing now.
    assert!(
        black_holed < relay_only + Duration::from_millis(150),
        "a black-holed direct path delayed the relay: {black_holed:?} vs {relay_only:?}"
    );
    drop(hole);
}

/// A hub move's pages over the carrier (`transfer_service.rs`, `hub/transfer_pull.rs`): machine A
/// moves a chat to B (`to.hub` is B's key). B dials A naming the transfer service and reads the
/// bundle; C, another of the person's machines, is refused while A's hub book does not list it,
/// and reads no page of B's move once it does; a machine with no transfer gate refuses by name.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn hub_carrier_a_moves_pages_reach_only_the_machine_it_moves_to() {
    use acpmux::hub::transfer_pull::PageSource;
    use acpmux::transfer_service::{CircuitPages, ConfiguredTransferGate};

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
    let (key_a, key_b, key_c, key_d) = (random_key(), random_key(), random_key(), random_key());
    let (a_key, b_key, c_key, d_key) =
        (public(&key_a), public(&key_b), public(&key_c), public(&key_d));
    let fast = Timings {
        control: Duration::from_secs(5),
        handshake: Duration::from_secs(5),
        ..Timings::default()
    };
    let carrier = |key: [u8; 32], peers: Vec<String>| {
        HubCarrier::new(
            Arc::new(FixedTickets { relay: route.clone(), peers, asked: AtomicU64::new(0) }),
            key,
            fast,
        )
    };

    // A, with a chat moving to B.
    let a = hub();
    let mut ca = client(a.clone()).await;
    let dir = tempfile::tempdir().unwrap();
    let s = ca.call(method::SESSION_NEW, json!({"cwd": dir.path(), "mcpServers": []})).await;
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let hi = json!({"sessionId": id, "prompt": [{"type": "text", "text": "hi"}]});
    ca.call(method::SESSION_PROMPT, hi).await;
    let begin = ca
        .call(
            "_acpmux/transfer_begin",
            json!({"sessionId": id, "gatesQueueApproval": true,
                   "to": {"hub": b_key, "host": "machine-b"}}),
        )
        .await;
    let read = json!({"transferId": begin["transferId"], "path": "session.json", "offset": 0,
                      "limit": 4096, "epoch": begin["epoch"]});

    let carrier_a = carrier(key_a, vec![b_key.clone(), c_key.clone()]);
    carrier_a.set_transfer_gate(Arc::new(ConfiguredTransferGate::new(&a)));
    a.set_mesh_book_machines(BTreeMap::from([(b_key.clone(), "machine-b".to_owned())]));
    let nothing = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap();
    let _serving = carrier_a.serve(nothing);
    let carrier_b = carrier(key_b, vec![a_key.clone(), d_key.clone()]);
    let carrier_c = carrier(key_c, vec![a_key.clone()]);

    // B reads its move's pages, A's registration perhaps still on its way.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    let stream = loop {
        match carrier_b.dial_service(&a_key, CircuitService::TransferSource).await {
            Ok(stream) => break stream,
            Err(e) => {
                assert!(tokio::time::Instant::now() < deadline, "A never answered: {e}");
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
        }
    };
    let mut pages = CircuitPages::new(stream);
    let page = pages.call("read", read.clone()).await.unwrap();
    assert!(page["data"].as_str().is_some_and(|d| !d.is_empty()), "{page}");
    assert!(page["next"].as_u64().is_some_and(|n| n > 0), "{page}");
    let renewed = pages
        .call("renew", json!({"transferId": begin["transferId"], "epoch": begin["epoch"]}))
        .await;
    assert!(renewed.is_ok(), "{renewed:?}");
    // Nothing else runs on the circuit.
    let commit = json!({"sessionId": id, "transferId": begin["transferId"]});
    assert!(pages.call("commit", commit).await.is_err());

    // C: not in A's book, refused at the hello; in it, refused each page of B's move.
    let refused = carrier_c.dial_service(&a_key, CircuitService::TransferSource).await.unwrap_err();
    assert!(refused.contains("machine.unlisted"), "{refused}");
    a.set_mesh_book_machines(BTreeMap::from([
        (b_key.clone(), "machine-b".to_owned()),
        (c_key.clone(), "machine-c".to_owned()),
    ]));
    let stream = carrier_c.dial_service(&a_key, CircuitService::TransferSource).await.unwrap();
    let refused = CircuitPages::new(stream).call("read", read.clone()).await.unwrap_err();
    assert!(refused.message.contains("not_yours"), "{}", refused.message);

    // A machine that serves no move pages refuses by name.
    let carrier_d = carrier(key_d, vec![b_key.clone()]);
    let _serving_d = carrier_d.serve(nothing);
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    loop {
        match carrier_b.dial_service(&d_key, CircuitService::TransferSource).await {
            Ok(_) => panic!("admitted with no transfer gate"),
            Err(e) if e.contains("service.off") => break,
            Err(e) => {
                assert!(tokio::time::Instant::now() < deadline, "D never answered: {e}");
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
        }
    }
}

/// A whole hub move over the relay (`hub/transfer_pull.rs`, `transfer_service.rs`): A begins the
/// move of a chat with a few MiB of history to B (`to.hub` is B's key); B takes op `move` through
/// its control hook as the hub delivers it, dials A through the relay with its own
/// [`CarrierDial`] (the daemon's, not a stand-in), pulls every page, imports the chat under its
/// own guard and answers; A commits. The chat then runs on B with its whole history once: the
/// cut turn's continuation, then the prompt queued on A before the move. A ran nothing after
/// the move began. No connection between A and B but the relay's.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn hub_carrier_a_chat_moves_whole_over_the_relay_and_runs_on_the_target() {
    let whole = move_over_relay(false).await;
    assert!(whole.pages >= 3, "{whole:?}");
}

/// The same move, pre-copied (`hub/transfer_hub_precopy.rs`): B stages the history over the
/// relay before the freeze, and only the log's tail crosses it inside the freeze. The harness
/// is [`move_over_relay`]'s, run both ways. The chat's history lands once and the queued prompt
/// runs once, as in the whole move.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn hub_carrier_a_pre_copied_chat_moves_only_its_tail_inside_the_freeze() {
    let whole = move_over_relay(false).await;
    let copied = move_over_relay(true).await;
    eprintln!(
        "hub move freeze, whole vs pre-copied: bundle {} B vs {} B, pages paged inside the freeze \
         {} ({} B, {} ms) vs {} ({} B, {} ms), freeze {} ms vs {} ms (pre-copy before it: {} ms)",
        whole.bundle,
        copied.bundle,
        whole.pages,
        whole.page_bytes,
        whole.pages_ms,
        copied.pages,
        copied.page_bytes,
        copied.pages_ms,
        whole.freeze_ms,
        copied.freeze_ms,
        copied.staging_ms
    );
    assert!(whole.bundle > 1 << 20, "{whole:?}");
    // Measured about 200x smaller; 5x leaves room for a busy runner without hiding a regression
    // to a whole move.
    assert!(copied.bundle * 5 < whole.bundle, "the freeze's bundle is the tail: {copied:?}");
    assert!(copied.page_bytes * 5 < whole.page_bytes, "{copied:?} vs {whole:?}");
    assert!(copied.pages < whole.pages, "{copied:?} vs {whole:?}");
    assert!(copied.carried_in_freeze * 5 < whole.carried_in_freeze, "{copied:?} vs {whole:?}");
    // A loose wall-clock bound (measured 132 ms): a freeze that waits on a timeout fails here.
    assert!(copied.freeze_ms < 5_000, "the pre-copied freeze took {} ms", copied.freeze_ms);
    // The history crossed the relay once, before the freeze.
    assert!(copied.staged_carried >= whole.bundle / 2, "{copied:?} vs {whole:?}");
}

/// What one move over the relay measured, from its freeze (the begin) to its commit.
#[derive(Debug)]
struct MoveRun {
    bundle: u64,
    pages: u64,
    page_bytes: u64,
    pages_ms: u64,
    freeze_ms: u128,
    carried_in_freeze: u64,
    staged_carried: u64,
    staging_ms: u128,
}

async fn move_over_relay(precopy: bool) -> MoveRun {
    use acpmux::mesh::InMessage;
    use acpmux::mesh_http::MeshControlFrom;
    use acpmux::server::mesh_relay::{ControlHook as _, MeshControlHook};
    use acpmux::transfer_service::{CarrierDial, ConfiguredTransferGate};

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
    let proxy = Proxy::start(relay_address).await;
    let route = format!("relay+ws://127.0.0.1:{}", proxy.port);
    let (key_a, key_b) = (random_key(), random_key());
    let (a_key, b_key) = (public(&key_a), public(&key_b));
    let fast = Timings {
        control: Duration::from_secs(5),
        handshake: Duration::from_secs(5),
        ..Timings::default()
    };
    let carrier = |key: [u8; 32], peers: Vec<String>| {
        HubCarrier::new(
            Arc::new(FixedTickets { relay: route.clone(), peers, asked: AtomicU64::new(0) }),
            key,
            fast,
        )
    };
    // A guarded receive takes only a plain agent session id (`transfer_guard.rs`).
    let plain_ids = || {
        let mut cfg = config();
        for profile in cfg.harnesses.values_mut() {
            profile.env.insert("FAKE_SESSION_PREFIX".into(), "fake-session-".into());
        }
        let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
        Hub::new(cfg, store)
    };

    // A serves its moves' pages on its relay slot, to the machines its hub book lists.
    let a = plain_ids();
    let carrier_a = carrier(key_a, vec![b_key.clone()]);
    carrier_a.set_transfer_gate(Arc::new(ConfiguredTransferGate::new(&a)));
    a.set_mesh_book_machines(BTreeMap::from([(b_key.clone(), "machine-b".to_owned())]));
    let nothing = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap();
    let _serving = carrier_a.serve(nothing);
    // B: its carrier and dial as `hub_carrier::start_configured` sets them, one webRoot.
    let b = plain_ids();
    let home = dirs::home_dir().expect("a home directory");
    let root = home.join(format!("acpmux-hub-relay-move-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&root).unwrap();
    let root = std::fs::canonicalize(&root).unwrap();
    let root_text = root.to_string_lossy().into_owned();
    {
        let mut cfg = b.config.write().await;
        cfg.web_roots = vec![root_text.clone()];
        // A chat under the guard's `peer` control runs only in a mode that asks (`resolve.rs`).
        cfg.web_asking_modes.insert("fake".into(), vec!["normal".into()]);
    }
    b.hub_carrier.set(carrier(key_b, vec![a_key.clone()]));
    b.set_transfer_dial(Arc::new(CarrierDial::new(&b)));
    let ledger = tempfile::tempdir().unwrap();
    let hook = MeshControlHook::new(
        vec![MeshControlFrom {
            daemon_id: String::new(),
            same_user: true,
            ops: vec!["move".into()],
        }],
        Some(ledger.path().join("mesh-controls.json")),
    )
    .with_own_user(Arc::new(|| Some("user-1".to_owned())));

    // A chat on A with history past one page (1 MiB) of the pull.
    let mut ca = client(a.clone()).await;
    let s =
        ca.call(method::SESSION_NEW, json!({"cwd": std::env::temp_dir(), "mcpServers": []})).await;
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let filler = "x".repeat(32 << 10);
    for n in 0..40 {
        let text = format!("turn {n} {filler}");
        ca.call(
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": text}]}),
        )
        .await;
    }
    // A turn running and a prompt queued behind it: the move stops the turn and carries the queue.
    let prompt = |prompt_id: &str, text: &str| {
        json!({"sessionId": id, "prompt": [{"type": "text", "text": text}],
               "_meta": {"acpmux": {"promptId": prompt_id}}})
    };
    ca.send(method::SESSION_PROMPT, prompt("p-turn", "until-cancel")).await;
    ca.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "running").await;
    ca.send(method::SESSION_PROMPT, prompt("p-after", "after the move")).await;
    ca.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-after" && p["queued"] == true)
        .await;

    let control = |message_id: &str, body: &Value| -> InMessage {
        serde_json::from_value(json!({
            "messageId": message_id, "kind": "control", "op": "move", "mode": "now",
            "to": {"daemonId": b_key},
            "from": {"daemonId": a_key, "user": "user-1", "host": "machine-a"},
            "body": body.to_string(),
        }))
        .unwrap()
    };
    // Pre-copy: A prepares the history for B and B stages it over the relay, the chat running.
    let (mut begin_params, mut stage_id) = (Value::Null, None);
    let (staging_started, staged_before) =
        (tokio::time::Instant::now(), proxy.bytes.load(Ordering::SeqCst));
    if precopy {
        let prepared = ca
            .call("_acpmux/transfer_hub", json!({"sessionId": id, "prepare": {"daemon": b_key}}))
            .await;
        let body = json!({"version": 1, "sessionId": id, "stage": {"manifest": prepared}});
        let stage = control("m-relay-stage", &body);
        let ack = within("B's stage over the relay", hook.control(&b, &stage)).await;
        let ack = serde_json::to_value(ack.expect("an answer within the hook's wait")).unwrap();
        assert_eq!(ack["state"], "delivered", "{ack}");
        let staged: Value = serde_json::from_str(ack["result"].as_str().unwrap()).unwrap();
        stage_id = staged["stageId"].as_str().map(str::to_owned);
        assert!(stage_id.is_some(), "{staged}");
        begin_params =
            json!({"prepareId": prepared["prepareId"], "afterSeq": prepared["afterSeq"]});
    }
    let staging_ms = if precopy { staging_started.elapsed().as_millis() } else { 0 };
    let staged_carried =
        if precopy { proxy.bytes.load(Ordering::SeqCst) - staged_before } else { 0 };
    let started = tokio::time::Instant::now();
    let mut begin_request = json!({"sessionId": id, "interrupt": true, "gatesQueueApproval": true,
                                   "to": {"hub": b_key, "host": "machine-b"}});
    if let Some(extra) = begin_params.as_object() {
        begin_request.as_object_mut().unwrap().extend(extra.clone());
    }
    let begin = ca.call("_acpmux/transfer_begin", begin_request).await;
    assert_eq!(begin.get("prefix").is_some(), precopy, "{begin}");
    let began = started.elapsed();
    let bundle: u64 = begin["files"]
        .as_array()
        .map(|files| files.iter().filter_map(|f| f["size"].as_u64()).sum())
        .unwrap_or(0);
    assert!(precopy || bundle > 1 << 20, "the history spans more than one page: {begin}");
    let mut body = json!({"version": 1, "transferId": begin["transferId"], "sessionId": id,
                          "manifest": begin, "folder": {"cwd": root_text}});
    if let Some(stage_id) = &stage_id {
        body["stageId"] = json!(stage_id);
    }
    let message = control("m-relay-1", &body);
    let carried_before = proxy.bytes.load(Ordering::SeqCst);
    let pull_started = tokio::time::Instant::now();
    let ack = within("B's pull over the relay", hook.control(&b, &message)).await;
    let pulled = pull_started.elapsed();
    let carried = proxy.bytes.load(Ordering::SeqCst) - carried_before;
    let ack = serde_json::to_value(ack.expect("an answer within the hook's wait")).unwrap();
    assert_eq!(ack["state"], "delivered", "{ack}");
    let moved: Value = serde_json::from_str(ack["result"].as_str().unwrap()).unwrap();
    assert_eq!(moved["sessionId"], id.as_str(), "{moved}");
    assert_eq!(moved["cwd"], root_text.as_str(), "{moved}");
    // Every page crossed the relay: what it carried is at least the bundle.
    assert!(carried >= bundle, "the relay carried {carried} B of a {bundle} B bundle");
    let moved_timings = moved["timings"].clone();
    let commit_started = tokio::time::Instant::now();
    let to = json!({"host": "machine-b", "via": "hub", "sessionId": id, "cwd": moved["cwd"]});
    let committed = ca
        .call(
            "_acpmux/transfer_commit",
            json!({"sessionId": id, "transferId": begin["transferId"], "to": to, "epoch": begin["epoch"]}),
        )
        .await;
    let commit = commit_started.elapsed();
    assert_eq!(committed["committed"], true, "{committed}");
    let split = &moved["timings"];
    let freeze = started.elapsed();
    // Loose (measured 319 ms whole, 132 ms pre-copied): a stalled page or timeout fails here.
    assert!(freeze < Duration::from_secs(10), "the freeze took {freeze:?}");
    eprintln!(
        "hub move over the relay{}: bundle {bundle} B, relay carried {carried} B, begin {} ms, \
         pull+import {} ms (circuit open {} ms, {} pages {} ms, import {} ms), commit {} ms, \
         freeze {} ms",
        if precopy { " (pre-copied)" } else { "" },
        began.as_millis(),
        pulled.as_millis(),
        split["dialMs"],
        split["pages"],
        split["pagesMs"],
        split["finishMs"],
        commit.as_millis(),
        started.elapsed().as_millis()
    );

    // The chat runs on B, with its history: the queued prompt runs there, once.
    let mut cb = client(b.clone()).await;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    let events = loop {
        let events = all_events(&mut cb, &id).await;
        let users = user_texts(&events);
        if users.last().is_some_and(|t| t == "after the move") {
            break events;
        }
        assert!(
            tokio::time::Instant::now() < deadline,
            "the moved queue never ran on B: {users:?}"
        );
        tokio::time::sleep(Duration::from_millis(100)).await;
    };
    let users = user_texts(&events);
    // The history once, the cut turn, its continuation (acpmux's, ahead of the queue), then
    // the person's queued prompt, once.
    assert!(users[0].starts_with("turn 0 "), "{users:?}");
    assert_eq!(users[40], "until-cancel", "{users:?}");
    assert_eq!(users.len(), 43, "{users:?}");
    assert_eq!(users[41], "This chat moved ", "{users:?}");
    assert_eq!(users[42], "after the move", "{users:?}");
    let landed = events
        .iter()
        .filter(|e| e["kind"] == "transferred_in")
        .map(|e| e["msg"].clone())
        .collect::<Vec<_>>();
    assert_eq!(landed.len(), 1, "{landed:?}");
    assert_eq!(landed[0]["from"]["via"], "hub", "{landed:?}");
    assert_eq!(landed[0]["from"]["daemonId"], a_key.as_str(), "{landed:?}");
    let left = ca.call(method::MUX_INFO, json!({"sessionId": id})).await;
    assert_eq!(left["status"], "closed", "{left}");
    let _ = std::fs::remove_dir_all(&root);
    MoveRun {
        bundle,
        pages: moved_timings["pages"].as_u64().unwrap_or(0),
        page_bytes: moved_timings["pageBytes"].as_u64().unwrap_or(0),
        pages_ms: moved_timings["pagesMs"].as_u64().unwrap_or(0),
        freeze_ms: freeze.as_millis(),
        carried_in_freeze: carried,
        staged_carried,
        staging_ms,
    }
}

// ---- One kept, multiplexed circuit per machine pair (`src/hub_carrier_mux.rs`). ----

/// A TCP proxy that holds every chunk `delay` in each direction (latency, not a rate limit), as
/// a relay a continent away would, and can cut every connection through it.
struct DelayProxy {
    port: u16,
    cut: watch::Sender<u64>,
}

impl DelayProxy {
    async fn start(target: SocketAddr, delay: Duration) -> Self {
        Self::start_with(target, delay, None).await
    }

    /// [`Self::start`], each connection carrying at most `rate` bytes a second each way (one
    /// TCP's share of a thin link: what queues in it waits its turn).
    async fn start_with(target: SocketAddr, delay: Duration, rate: Option<u64>) -> Self {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let (cut, _) = watch::channel(0u64);
        let cuts = cut.clone();
        tokio::spawn(async move {
            while let Ok((inbound, _)) = listener.accept().await {
                let Ok(outbound) = tokio::net::TcpStream::connect(target).await else { continue };
                let _ = inbound.set_nodelay(true);
                let _ = outbound.set_nodelay(true);
                let mut cut = cuts.subscribe();
                tokio::spawn(async move {
                    let (ir, iw) = inbound.into_split();
                    let (or, ow) = outbound.into_split();
                    tokio::select! {
                        _ = delayed(ir, ow, delay, rate) => {}
                        _ = delayed(or, iw, delay, rate) => {}
                        _ = cut.changed() => {}
                    }
                });
            }
        });
        Self { port, cut }
    }

    fn cut(&self) {
        self.cut.send_modify(|n| *n += 1);
    }
}

async fn delayed(
    mut from: tokio::net::tcp::OwnedReadHalf,
    mut to: tokio::net::tcp::OwnedWriteHalf,
    delay: Duration,
    rate: Option<u64>,
) {
    let (tx, mut rx) = mpsc::unbounded_channel::<(tokio::time::Instant, Vec<u8>)>();
    let read = async move {
        let mut buf = vec![0u8; 64 * 1024];
        loop {
            match from.read(&mut buf).await {
                Ok(0) | Err(_) => return,
                Ok(n) => {
                    if tx.send((tokio::time::Instant::now() + delay, buf[..n].to_vec())).is_err() {
                        return;
                    }
                }
            }
        }
    };
    let write = async move {
        while let Some((at, bytes)) = rx.recv().await {
            tokio::time::sleep_until(at).await;
            if to.write_all(&bytes).await.is_err() {
                return;
            }
            if let Some(rate) = rate {
                tokio::time::sleep(Duration::from_secs_f64(bytes.len() as f64 / rate as f64)).await;
            }
        }
    };
    tokio::join!(read, write);
}

const BANNER: &[u8] = b"SSH-2.0-standin\r\n";

/// A stand-in for the far machine's sshd: a banner first, then it echoes what it reads until the
/// dialer closes its side, then closes. A first line `bulk N` gets N bytes instead of echoes.
async fn standin_sshd() -> SocketAddr {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    tokio::spawn(async move {
        while let Ok((socket, _)) = listener.accept().await {
            tokio::spawn(async move {
                let (mut read, mut write) = socket.into_split();
                if write.write_all(BANNER).await.is_err() {
                    return;
                }
                let mut buf = vec![0u8; 16 * 1024];
                let mut first = true;
                loop {
                    let n = match read.read(&mut buf).await {
                        Ok(0) | Err(_) => break,
                        Ok(n) => n,
                    };
                    if first && buf[..n].starts_with(b"bulk ") {
                        let text = String::from_utf8_lossy(&buf[5..n]).trim().to_owned();
                        let total: usize = text.parse().unwrap();
                        let block = vec![0x42u8; 64 * 1024];
                        let mut left = total;
                        while left > 0 {
                            let take = left.min(block.len());
                            if write.write_all(&block[..take]).await.is_err() {
                                return;
                            }
                            left -= take;
                        }
                        break;
                    }
                    first = false;
                    if write.write_all(&buf[..n]).await.is_err() {
                        return;
                    }
                }
                let _ = write.shutdown().await;
            });
        }
    });
    address
}

struct KeptFixture {
    a: Arc<HubCarrier>,
    /// A's node key and relay route, for an A started again with the same key (a restart).
    a_key: [u8; 32],
    a_route: String,
    timings: Timings,
    b: Arc<HubCarrier>,
    b_key: String,
    sshd_port: u16,
    gate: Arc<TestGate>,
    proxy: DelayProxy,
    _serving: acpmux::hub_carrier::HubServe,
}

impl KeptFixture {
    fn service(&self) -> CircuitService {
        CircuitService::CmuxTui { port: self.sshd_port }
    }

    async fn dial(&self) -> Result<acpmux::hub_carrier::HubStream, String> {
        self.a.dial_service(&self.b_key, self.service()).await
    }

    /// A dial, its banner read: the time `carrier-pipe health` measures.
    async fn dial_to_banner(&self) -> acpmux::hub_carrier::HubStream {
        let mut stream = within("a dial", self.dial()).await.unwrap();
        let mut banner = vec![0u8; BANNER.len()];
        within("the banner", stream.read_exact(&mut banner)).await.unwrap();
        assert_eq!(banner, BANNER);
        stream
    }

    /// A new carrier on A's key and route: A's acpmux after a restart.
    fn restarted_a(&self) -> Arc<HubCarrier> {
        HubCarrier::new(
            Arc::new(FixedTickets {
                relay: self.a_route.clone(),
                peers: vec![self.b_key.clone()],
                asked: AtomicU64::new(0),
            }),
            self.a_key,
            self.timings,
        )
    }

    fn kept_circuits(&self) -> u64 {
        self.a.stats().kept_circuits.load(Ordering::Relaxed)
    }

    fn kept_opens(&self) -> u64 {
        self.a.stats().kept_opens.load(Ordering::Relaxed)
    }

    fn plain_dials(&self) -> u64 {
        self.a.stats().dials.load(Ordering::Relaxed)
    }
}

/// A dials B's stand-in sshd over the in-process relay, A's leg `delay` away each way. Returns once B
/// serves (its gate's refusal came back), with control not granted yet unless `granted`.
async fn kept_fixture(delay: Duration, b_keeps_circuits: bool, granted: bool) -> KeptFixture {
    kept_fixture_with(delay, None, b_keeps_circuits, granted).await
}

/// [`kept_fixture`], A's leg carrying at most `rate` bytes a second per connection.
async fn kept_fixture_with(
    delay: Duration,
    rate: Option<u64>,
    b_keeps_circuits: bool,
    granted: bool,
) -> KeptFixture {
    let relay_listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let relay_address = relay_listener.local_addr().unwrap();
    let relay = cmux_relay::Relay::new(cmux_relay::RelayConfig {
        allow_open: true,
        max_allocations_per_second_per_slot: 1_000,
        ..cmux_relay::RelayConfig::default()
    })
    .unwrap();
    let (relay_listener, router) = relay.server_parts(relay_listener);
    tokio::spawn(async move {
        let _ = axum::serve(relay_listener, router).await;
    });
    // Only A's leg runs through the proxy: a cut drops A's circuits, not B's registration.
    let proxy = DelayProxy::start_with(relay_address, delay, rate).await;
    let route = format!("relay+ws://127.0.0.1:{}", proxy.port);
    let direct = format!("relay+ws://{relay_address}");
    let sshd = standin_sshd().await;
    let (key_a, key_b) = (random_key(), random_key());
    let fast = Timings {
        control: Duration::from_secs(5),
        handshake: Duration::from_secs(5),
        ..Timings::default()
    };
    let b = HubCarrier::new(
        Arc::new(FixedTickets {
            relay: direct,
            peers: vec![public(&key_a)],
            asked: AtomicU64::new(0),
        }),
        key_b,
        fast,
    );
    b.serve_kept_circuits(b_keeps_circuits);
    let gate =
        Arc::new(TestGate { daemon: std::sync::Mutex::new(sshd), granted: AtomicBool::new(false) });
    b.set_cmux_tui_gate(gate.clone());
    let acpmux_b = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let acpmux_b_address = acpmux_b.local_addr().unwrap();
    // B's acpmux listener echoes, so a test can carry bytes over an acpmux link.
    tokio::spawn(async move {
        while let Ok((socket, _)) = acpmux_b.accept().await {
            tokio::spawn(async move {
                let (mut read, mut write) = socket.into_split();
                let _ = tokio::io::copy(&mut read, &mut write).await;
            });
        }
    });
    let serving = b.serve(acpmux_b_address);
    let a = HubCarrier::new(
        Arc::new(FixedTickets {
            relay: route.clone(),
            peers: vec![public(&key_b)],
            asked: AtomicU64::new(0),
        }),
        key_a,
        fast,
    );
    let fixture = KeptFixture {
        a,
        a_key: key_a,
        a_route: route,
        timings: fast,
        b,
        b_key: public(&key_b),
        sshd_port: sshd.port(),
        gate,
        proxy,
        _serving: serving,
    };
    let mut last = String::new();
    let mut serves = false;
    for _ in 0..80 {
        match fixture.dial().await {
            Err(e) if e.contains("consent_required") => {
                serves = true;
                break;
            }
            Err(e) => last = e,
            Ok(_) => panic!("a stream reached B before its owner granted control"),
        }
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
    assert!(serves, "B never served: {last}");
    fixture.gate.granted.store(granted, Ordering::SeqCst);
    fixture
}

/// RFD 0039 cut 5 (H13): a pair keeps two circuits, so a cheap read never waits behind bulk in one
/// circuit's TCP. A's leg carries 2 MiB/s per connection; 4 bulk transfers of 8 MiB each run on
/// the bulk circuit, read as they come, while a cheap echo on the cheap circuit answers in under
/// 200 ms (durability F18's bound). The same echo on the bulk circuit, behind the bulk streams'
/// windows, is printed beside it.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn hub_carrier_a_cheap_read_never_waits_behind_four_bulk_transfers() {
    let _ = HERMETIC;
    let fixture = kept_fixture_with(Duration::ZERO, Some(2 << 20), true, true).await;
    let mut bulks = Vec::new();
    for _ in 0..4 {
        let mut bulk = fixture.dial_to_banner().await;
        bulk.write_all(b"bulk 8388608\n").await.unwrap();
        bulks.push(tokio::spawn(async move {
            let mut got = Vec::new();
            let _ = bulk.read_to_end(&mut got).await;
            got.len()
        }));
    }
    let open_cheap = || async {
        let mut stream = within(
            "a cheap dial",
            fixture.a.dial_service_on(&fixture.b_key, fixture.service(), CircuitLane::Cheap),
        )
        .await
        .unwrap();
        let mut banner = vec![0u8; BANNER.len()];
        within("the cheap banner", stream.read_exact(&mut banner)).await.unwrap();
        stream
    };
    let mut cheap = open_cheap().await;
    assert_eq!(fixture.a.kept_circuits(&fixture.b_key), 2, "one cheap circuit, one bulk");
    // Let the bulk streams fill their windows first.
    tokio::time::sleep(Duration::from_millis(500)).await;
    let mut worst = Duration::ZERO;
    for n in 0..10 {
        let started = std::time::Instant::now();
        echo(&mut cheap, format!("cheap {n}\n").as_bytes()).await;
        worst = worst.max(started.elapsed());
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let mut behind = fixture.dial_to_banner().await;
    let started = std::time::Instant::now();
    echo(&mut behind, b"behind bulk\n").await;
    let behind = started.elapsed();
    eprintln!(
        "H13: cheap read during 4 bulk transfers: worst {worst:?} on the cheap circuit, {behind:?} on the bulk one"
    );
    assert!(worst < Duration::from_millis(200), "a cheap read took {worst:?}");
    for bulk in bulks {
        assert_eq!(within("a bulk transfer", bulk).await.unwrap(), 8 << 20);
    }
}

/// Echo `text` through `stream` and read it back.
async fn echo(stream: &mut acpmux::hub_carrier::HubStream, text: &[u8]) {
    stream.write_all(text).await.unwrap();
    let mut back = vec![0u8; text.len()];
    within("an echo", stream.read_exact(&mut back)).await.unwrap();
    assert_eq!(back, text);
}

/// The first named-service dial opens one kept circuit; every later dial to that machine is a
/// stream on it, refusals included. Streams carry bytes on their own: one closing its side ends
/// only itself, and one whose reader stalls on 4 MiB does not hold up another.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn hub_carrier_later_dials_to_a_machine_ride_its_kept_circuit_as_streams() {
    let _ = HERMETIC;
    let fixture = kept_fixture(Duration::ZERO, true, true).await;
    // The readiness refusals rode it already: one circuit, no plain ones.
    assert_eq!(fixture.kept_circuits(), 1);
    assert_eq!(fixture.plain_dials(), 0);
    let opens = fixture.kept_opens();

    let mut first = fixture.dial_to_banner().await;
    let mut second = fixture.dial_to_banner().await;
    echo(&mut first, b"one\n").await;
    echo(&mut second, b"two\n").await;
    assert_eq!(fixture.a.kept_streams(&fixture.b_key), Some(2));
    // `gauges.links` counts them, both ends of each (other tests in this process add theirs).
    let links = acpmux::gauges::links().status();
    assert!(links["keptStreamsOpen"].as_u64().unwrap() >= 4, "{links}");
    assert!(links["hubKeptOpen"].as_u64().unwrap() >= 2, "{links}");
    assert!(links["hubKeptDials"].as_u64().unwrap() >= 1, "{links}");
    assert!(links["keptStreamOpens"].as_u64().unwrap() >= opens + 2, "{links}");

    // A half close: the far side reads the end, closes, and the stream ends; the other lives on.
    first.shutdown().await.unwrap();
    let mut rest = Vec::new();
    within("the first stream's end", first.read_to_end(&mut rest)).await.unwrap();
    assert!(rest.is_empty(), "{rest:?}");
    echo(&mut second, b"still\n").await;

    // A stalled reader: 4 MiB the dialer does not read yet, while another stream echoes.
    let mut bulk = fixture.dial_to_banner().await;
    bulk.write_all(b"bulk 4194304\n").await.unwrap();
    tokio::time::sleep(Duration::from_millis(300)).await;
    let started = std::time::Instant::now();
    echo(&mut second, b"not held up\n").await;
    assert!(started.elapsed() < Duration::from_secs(2), "{:?}", started.elapsed());
    let mut got = Vec::new();
    within("the bulk stream", bulk.read_to_end(&mut got)).await.unwrap();
    assert_eq!(got.len(), 4 << 20);
    assert!(got.iter().all(|b| *b == 0x42));

    // A refusal comes back over the kept circuit too, and the circuit stays.
    fixture.gate.granted.store(false, Ordering::SeqCst);
    let refused = fixture.dial().await.err().expect("no consent, no stream");
    assert!(refused.contains("consent_required"), "{refused}");
    fixture.gate.granted.store(true, Ordering::SeqCst);
    let _again = fixture.dial_to_banner().await;

    assert_eq!(fixture.kept_circuits(), 1, "every dial rode the one circuit");
    assert_eq!(fixture.plain_dials(), 0);
    assert_eq!(fixture.kept_opens() - opens, 4);
}

/// RFD 0127 cut 3: health is link liveness plus a 1-RTT echo. With a kept circuit open, the link's
/// age is a local read, and an echo is one stream open and one round trip through the real path;
/// a machine that keeps no circuits answers it on a plain one.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn hub_carrier_health_is_link_age_and_a_one_round_trip_echo() {
    let _ = HERMETIC;
    let fixture = kept_fixture(Duration::ZERO, true, true).await;
    let age = fixture.a.link_age(&fixture.b_key).expect("the readiness dials left a kept circuit");
    assert!(age < Duration::from_secs(30), "{age:?}");
    let started = std::time::Instant::now();
    assert!(fixture.a.link_age(&fixture.b_key).is_some());
    assert!(started.elapsed() < Duration::from_millis(5), "a local read: {:?}", started.elapsed());

    let circuits = fixture.kept_circuits();
    let report = within("an echo", fixture.a.echo(&fixture.b_key)).await.unwrap();
    eprintln!("echo on a kept circuit: open {:?}, round trip {:?}", report.open, report.round_trip);
    assert_eq!(fixture.kept_circuits(), circuits, "the echo rode the open circuit");
    assert_eq!(fixture.plain_dials(), 0);

    let plain = kept_fixture(Duration::ZERO, false, true).await;
    let report = within("a plain echo", plain.a.echo(&plain.b_key)).await.unwrap();
    eprintln!(
        "echo on a plain circuit: open {:?}, round trip {:?}",
        report.open, report.round_trip
    );
}

/// One circuit per host pair: the acpmux peer link and its hub probe (two acpmux dials) ride
/// the kept circuit as streams beside the cmux-tui ones, and no plain circuit opens.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn hub_carrier_acpmux_links_ride_the_kept_circuit_as_streams() {
    let _ = HERMETIC;
    let fixture = kept_fixture(Duration::ZERO, true, true).await;
    let mut link = within("the peer link", fixture.a.dial(&fixture.b_key)).await.unwrap();
    let mut probe = within("the hub probe", fixture.a.dial(&fixture.b_key)).await.unwrap();
    echo(&mut link, b"link\n").await;
    echo(&mut probe, b"probe\n").await;
    let _tui = fixture.dial_to_banner().await;
    assert_eq!(fixture.kept_circuits(), 1, "the links rode the one cheap circuit");
    assert_eq!(fixture.plain_dials(), 0, "no plain circuit beside it");
    assert_eq!(fixture.a.kept_circuits(&fixture.b_key), 1);
    assert_eq!(fixture.a.kept_streams(&fixture.b_key), Some(3));
}

/// A new dialer and an old machine: B refuses acpmux streams `service.unknown` as a daemon from
/// before them does, so A's acpmux dial goes plain (and keeps going plain without asking again),
/// while its cmux-tui dials still ride the kept circuit.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn hub_carrier_an_acpmux_dial_to_an_old_machine_goes_plain() {
    let _ = HERMETIC;
    let fixture = kept_fixture(Duration::ZERO, true, true).await;
    fixture.b.acpmux_streams(false);
    let mut link = within("the peer link", fixture.a.dial(&fixture.b_key)).await.unwrap();
    echo(&mut link, b"old b\n").await;
    assert_eq!(fixture.plain_dials(), 1);
    let opens = fixture.kept_opens();
    let mut again = within("a redial", fixture.a.dial(&fixture.b_key)).await.unwrap();
    echo(&mut again, b"again\n").await;
    assert_eq!(fixture.plain_dials(), 2);
    assert_eq!(fixture.kept_opens(), opens, "an old machine is not asked again");
    let _tui = fixture.dial_to_banner().await;
    assert_eq!(fixture.plain_dials(), 2, "cmux-tui still rides the kept circuit");
}

/// A new dialer and a machine that keeps no circuits at all: the acpmux dial goes plain.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn hub_carrier_an_acpmux_dial_to_a_machine_with_no_kept_circuits_goes_plain() {
    let _ = HERMETIC;
    let fixture = kept_fixture(Duration::ZERO, false, true).await;
    let plain = fixture.plain_dials();
    let mut link = within("the peer link", fixture.a.dial(&fixture.b_key)).await.unwrap();
    echo(&mut link, b"no kept\n").await;
    assert_eq!(fixture.plain_dials(), plain + 1);
    assert_eq!(fixture.a.kept_circuits(&fixture.b_key), 0);
}

/// An old dialer and a new machine: A dials acpmux plain with no hello, as before acpmux
/// streams, and B's listener still answers it.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn hub_carrier_an_old_dialer_still_reaches_a_new_machines_acpmux() {
    let _ = HERMETIC;
    let fixture = kept_fixture(Duration::ZERO, true, true).await;
    fixture.a.acpmux_streams(false);
    let mut link = within("the peer link", fixture.a.dial(&fixture.b_key)).await.unwrap();
    echo(&mut link, b"old a\n").await;
    assert_eq!(fixture.plain_dials(), 1);
}

/// Twenty dials at once to a machine with no kept circuit open one circuit between them, not
/// twenty, and each gets its own stream.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn hub_carrier_twenty_dials_at_once_share_one_new_kept_circuit() {
    let _ = HERMETIC;
    let fixture = Arc::new(kept_fixture(Duration::from_millis(5), true, true).await);
    assert!(fixture.a.cut_kept(&fixture.b_key).await);
    let before = fixture.kept_circuits();
    let dials: Vec<_> = (0..20)
        .map(|i| {
            let fixture = fixture.clone();
            tokio::spawn(async move {
                let mut stream = fixture.dial_to_banner().await;
                echo(&mut stream, format!("dial {i}\n").as_bytes()).await;
                stream
            })
        })
        .collect();
    let mut streams = Vec::new();
    for dial in dials {
        streams.push(dial.await.unwrap());
    }
    assert_eq!(fixture.kept_circuits() - before, 1);
    assert_eq!(fixture.a.kept_streams(&fixture.b_key), Some(20));
    assert_eq!(fixture.plain_dials(), 0);
}

/// A kept circuit cut under its streams (the relay drops every connection) ends them, and the
/// next dial opens a new kept circuit at once and works: no error reaches the dialer.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn hub_carrier_a_kept_circuit_cut_under_its_streams_is_opened_again_by_the_next_dial() {
    let _ = HERMETIC;
    let fixture = kept_fixture(Duration::ZERO, true, true).await;
    let mut live = fixture.dial_to_banner().await;
    echo(&mut live, b"before\n").await;
    let before = fixture.kept_circuits();

    fixture.proxy.cut();
    // The stream ends (its read sees the end or an error), soon, by the cut itself.
    let mut buf = [0u8; 16];
    let ended = within("the cut stream's end", live.read(&mut buf)).await;
    assert!(matches!(ended, Ok(0) | Err(_)), "{ended:?}");

    let started = std::time::Instant::now();
    let mut next = fixture.dial_to_banner().await;
    echo(&mut next, b"after\n").await;
    assert!(started.elapsed() < Duration::from_secs(5), "{:?}", started.elapsed());
    assert_eq!(fixture.kept_circuits() - before, 1, "one new kept circuit");

    // Cut by this side (`cut_kept`) the same way.
    assert!(fixture.a.cut_kept(&fixture.b_key).await);
    let ended = within("the cut stream's end", next.read(&mut buf)).await;
    assert!(matches!(ended, Ok(0) | Err(_)), "{ended:?}");
    let _third = fixture.dial_to_banner().await;
    assert_eq!(fixture.kept_circuits() - before, 2);
    assert_eq!(fixture.plain_dials(), 0);
}

/// A machine whose acpmux keeps no circuits (it answers the `mux` hello `service.unknown`, as
/// one that predates them does) gets a plain circuit per dial, as before, with no error.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn hub_carrier_a_machine_that_keeps_no_circuits_gets_a_plain_circuit_per_dial() {
    let _ = HERMETIC;
    let fixture = kept_fixture(Duration::ZERO, false, true).await;
    let plain = fixture.plain_dials();
    let mut one = fixture.dial_to_banner().await;
    let mut two = fixture.dial_to_banner().await;
    echo(&mut one, b"one\n").await;
    echo(&mut two, b"two\n").await;
    assert_eq!(fixture.kept_circuits(), 0);
    assert_eq!(fixture.plain_dials() - plain, 2);
    assert_eq!(fixture.a.kept_streams(&fixture.b_key), None);
    let _ = &fixture.b;
}

/// Cold, warm and twenty-at-once dial numbers with the dialer 25 ms from the relay each way (run on demand:
/// `cargo test -p acpmux --features hub-carrier --test hub_carrier kept_circuit_numbers --
/// --ignored --nocapture`). A dial is timed to the far sshd's banner, as `carrier-pipe health`.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "numbers on demand"]
async fn hub_carrier_kept_circuit_numbers() {
    let _ = HERMETIC;
    let delay = Duration::from_millis(25);
    let fixture = Arc::new(kept_fixture(delay, true, true).await);
    let ms = |d: Duration| d.as_secs_f64() * 1e3;
    let mut cold = Vec::new();
    for _ in 0..10 {
        fixture.a.cut_kept(&fixture.b_key).await;
        let started = std::time::Instant::now();
        let _stream = fixture.dial_to_banner().await;
        cold.push(started.elapsed());
    }
    let mut warm = Vec::new();
    for _ in 0..20 {
        let started = std::time::Instant::now();
        let _stream = fixture.dial_to_banner().await;
        warm.push(started.elapsed());
    }
    let parallel = |fixture: Arc<KeptFixture>| async move {
        let started = std::time::Instant::now();
        let dials: Vec<_> = (0..20)
            .map(|_| {
                let fixture = fixture.clone();
                tokio::spawn(async move {
                    let started = std::time::Instant::now();
                    let stream = fixture.dial_to_banner().await;
                    (started.elapsed(), stream)
                })
            })
            .collect();
        let mut each = Vec::new();
        let mut keep = Vec::new();
        for dial in dials {
            let (took, stream) = dial.await.unwrap();
            each.push(took);
            keep.push(stream);
        }
        (started.elapsed(), each)
    };
    let (warm_wall, mut warm_each) = parallel(fixture.clone()).await;
    fixture.a.cut_kept(&fixture.b_key).await;
    let (cold_wall, mut cold_each) = parallel(fixture.clone()).await;
    // The plain path, for the same harness: B keeps no circuits.
    let plain_fixture = Arc::new(kept_fixture(delay, false, true).await);
    let mut plain = Vec::new();
    for _ in 0..10 {
        let started = std::time::Instant::now();
        let _stream = plain_fixture.dial_to_banner().await;
        plain.push(started.elapsed());
    }
    let (plain_wall, mut plain_each) = parallel(plain_fixture.clone()).await;
    eprintln!(
        "KEPT-NUMBERS rtt=50ms plain p50={:.1} p95={:.1} n=10; kept cold p50={:.1} p95={:.1} n=10; \
         kept warm p50={:.1} p95={:.1} n=20",
        ms(percentile(&mut plain, 0.5)),
        ms(percentile(&mut plain, 0.95)),
        ms(percentile(&mut cold, 0.5)),
        ms(percentile(&mut cold, 0.95)),
        ms(percentile(&mut warm, 0.5)),
        ms(percentile(&mut warm, 0.95)),
    );
    eprintln!(
        "KEPT-NUMBERS Duress: 20 parallel plain wall={:.1} p95={:.1}; kept from cold wall={:.1} \
         p95={:.1}; kept warm wall={:.1} p95={:.1}",
        ms(plain_wall),
        ms(percentile(&mut plain_each, 0.95)),
        ms(cold_wall),
        ms(percentile(&mut cold_each, 0.95)),
        ms(warm_wall),
        ms(percentile(&mut warm_each, 0.95)),
    );
}

#[path = "hub_carrier_cases/held_ssh.rs"]
mod held_ssh;

#[path = "hub_carrier/move_out.rs"]
mod move_out;
