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

/// A rekey (`machine_tunnel.rs`) rotates the node key under a serving carrier: the carrier
/// takes the new key with the key file in one step ([`HubCarrier::rekey`]), keeps serving and
/// registers its slot again, and a peer that pins the new key reaches it over the relay.
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
