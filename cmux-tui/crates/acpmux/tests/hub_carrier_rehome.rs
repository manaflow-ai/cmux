//! Relay re-homing end to end (`src/hub_carrier_rehome.rs`): B serves its slot on relay 1, A
//! echoes bytes to B over the carrier, then relay 1 dies (every connection cut, new ones
//! refused). With a platform that names a second relay, B registers there once its registration
//! has been down `rehome_after`, and A's next dial follows it; the test measures the gap from
//! the kill to the first echo. With an older platform (one relay), nothing moves: no echo comes
//! while relay 1 is down, and the first comes once it is back (today's behavior).
//!
//! Both relays are cmux's native one (`cmux-relay`) in process, each behind a TCP proxy the test
//! can cut. B's "WebSocket listener" is a TCP echo server: the carrier bridges bytes to it.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::hub_carrier::{CarrierAnswer, HubCarrier, Tickets, Timings};
use base64::Engine;
use serde_json::json;
use std::net::SocketAddr;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::watch;

/// A TCP proxy in front of one relay that can cut every connection and refuse new ones.
struct Proxy {
    port: u16,
    cut: watch::Sender<u64>,
    paused: Arc<AtomicBool>,
}

impl Proxy {
    async fn start(target: SocketAddr) -> Self {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let (cut, _) = watch::channel(0u64);
        let paused = Arc::new(AtomicBool::new(false));
        let proxy = Self { port, cut, paused };
        let (cut, paused) = (proxy.cut.clone(), proxy.paused.clone());
        tokio::spawn(async move {
            while let Ok((inbound, _)) = listener.accept().await {
                if paused.load(Ordering::SeqCst) {
                    drop(inbound);
                    continue;
                }
                let Ok(outbound) = tokio::net::TcpStream::connect(target).await else { continue };
                let mut cut = cut.subscribe();
                tokio::spawn(async move {
                    let (mut ir, mut iw) = inbound.into_split();
                    let (mut or, mut ow) = outbound.into_split();
                    tokio::select! {
                        _ = tokio::io::copy(&mut ir, &mut ow) => {}
                        _ = tokio::io::copy(&mut or, &mut iw) => {}
                        _ = cut.changed() => {}
                    }
                });
            }
        });
        proxy
    }

    fn kill(&self) {
        self.paused.store(true, Ordering::SeqCst);
        self.cut.send_modify(|n| *n += 1);
    }

    fn revive(&self) {
        self.paused.store(false, Ordering::SeqCst);
    }

    fn route(&self) -> String {
        format!("relay+ws://127.0.0.1:{}", self.port)
    }
}

async fn relay() -> Proxy {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let relay = cmux_relay::Relay::new(cmux_relay::RelayConfig {
        allow_open: true,
        ..cmux_relay::RelayConfig::default()
    })
    .unwrap();
    let (listener, router) = relay.server_parts(listener);
    tokio::spawn(async move {
        let _ = axum::serve(listener, router).await;
    });
    Proxy::start(address).await
}

/// The platform's answers: `relay` plus, from a newer platform, the others in `relays`.
struct TwoRelayTickets {
    relay: String,
    relays: Vec<String>,
    peers: Vec<String>,
}

#[async_trait::async_trait]
impl Tickets for TwoRelayTickets {
    async fn register(&self) -> Result<CarrierAnswer, String> {
        Ok(serde_json::from_value(json!({
            "relay": self.relay, "relays": self.relays, "slot": "own-machine-slot-b",
            "ticket": "open-register", "expires_at": 0, "peers": self.peers,
        }))
        .unwrap())
    }

    async fn connect(&self, peer: &str) -> Result<CarrierAnswer, String> {
        if !self.peers.iter().any(|k| k == peer) {
            return Err("machine.not_found".into());
        }
        Ok(serde_json::from_value(json!({
            "relay": self.relay, "relays": self.relays, "slot": "own-machine-slot-b",
            "ticket": "open-connect", "expires_at": 0, "peer_key": peer,
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

async fn echo_server() -> SocketAddr {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    tokio::spawn(async move {
        while let Ok((mut socket, _)) = listener.accept().await {
            tokio::spawn(async move {
                let (mut r, mut w) = socket.split();
                let _ = tokio::io::copy(&mut r, &mut w).await;
            });
        }
    });
    address
}

/// One dial and one echo of a few bytes, bounded by `within`.
async fn echo_once(a: &HubCarrier, b: &str, within: Duration) -> Result<(), String> {
    tokio::time::timeout(within, async {
        let mut stream = a.dial(b).await?;
        stream.write_all(b"ping\n").await.map_err(|e| e.to_string())?;
        let mut got = [0u8; 5];
        stream.read_exact(&mut got).await.map_err(|e| e.to_string())?;
        if &got == b"ping\n" { Ok(()) } else { Err("echo differs".into()) }
    })
    .await
    .map_err(|_| "echo timed out".to_owned())?
}

/// Echoes until one comes back, up to `budget`; the time to the first, or None.
async fn first_echo(a: &HubCarrier, b: &str, budget: Duration) -> Option<Duration> {
    let started = Instant::now();
    while started.elapsed() < budget {
        if echo_once(a, b, Duration::from_secs(3)).await.is_ok() {
            return Some(started.elapsed());
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    None
}

struct Pair {
    a: Arc<HubCarrier>,
    b: Arc<HubCarrier>,
    b_key: String,
    _serving: acpmux::hub_carrier::HubServe,
}

async fn pair(relay: &str, relays: &[String]) -> Pair {
    let (key_a, key_b) = (random_key(), random_key());
    let timings = Timings {
        control: Duration::from_secs(3),
        handshake: Duration::from_secs(3),
        peer_join: Duration::from_secs(2),
        ..Timings::default()
    };
    let b = HubCarrier::new(
        Arc::new(TwoRelayTickets {
            relay: relay.to_owned(),
            relays: relays.to_vec(),
            peers: vec![public(&key_a)],
        }),
        key_b,
        timings,
    );
    let serving = b.serve(echo_server().await);
    let a = HubCarrier::new(
        Arc::new(TwoRelayTickets {
            relay: relay.to_owned(),
            relays: relays.to_vec(),
            peers: vec![public(&key_b)],
        }),
        key_a,
        timings,
    );
    a.set_route("b", &public(&key_b));
    Pair { a, b, b_key: public(&key_b), _serving: serving }
}

async fn until_serving(b: &HubCarrier, relay: &str, budget: Duration) {
    let started = Instant::now();
    while b.serving_relay().as_deref() != Some(relay) {
        assert!(started.elapsed() < budget, "B never served on {relay}: {:?}", b.serving_relay());
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn hub_carrier_a_dead_relay_moves_the_host_and_its_dialers_to_the_next() {
    let _ = HERMETIC;
    let (one, two) = (relay().await, relay().await);
    let p = pair(&one.route(), &[two.route()]).await;
    until_serving(&p.b, &one.route(), Duration::from_secs(15)).await;
    echo_once(&p.a, &p.b_key, Duration::from_secs(10)).await.expect("first echo on relay 1");
    assert_eq!(p.a.relay_of(&p.b_key).as_deref(), Some(one.route().as_str()));

    one.kill();
    let gap = first_echo(&p.a, &p.b_key, Duration::from_secs(30)).await;
    let gap = gap.expect("no echo within 30 s of relay 1 dying");
    assert_eq!(p.b.serving_relay().as_deref(), Some(two.route().as_str()), "B moved to relay 2");
    assert_eq!(p.a.relay_of(&p.b_key).as_deref(), Some(two.route().as_str()), "A followed");
    assert!(p.b.stats().rehomes.load(Ordering::Relaxed) >= 1);
    eprintln!("relay-failover after: relay kill to first echo {} ms", gap.as_millis());
    // Bounded by rehome_after (3 s) plus one registration and one dial, with room for a loaded CI host.
    assert!(gap < Duration::from_secs(12), "the move took {gap:?}");

    // Relay 1 comes back: B stays where it is, and dials keep working.
    one.revive();
    echo_once(&p.a, &p.b_key, Duration::from_secs(10)).await.expect("echo after relay 1 revived");
    assert_eq!(p.b.serving_relay().as_deref(), Some(two.route().as_str()));
}

/// An older platform names one relay: the host stays on it, no echo comes while it is down, and
/// the first comes back once it returns. The before number for the failover cell.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn hub_carrier_with_one_relay_named_nothing_moves() {
    let _ = HERMETIC;
    let one = relay().await;
    let p = pair(&one.route(), &[]).await;
    until_serving(&p.b, &one.route(), Duration::from_secs(15)).await;
    echo_once(&p.a, &p.b_key, Duration::from_secs(10)).await.expect("first echo on relay 1");

    one.kill();
    let down = Duration::from_secs(8);
    let killed = Instant::now();
    assert_eq!(first_echo(&p.a, &p.b_key, down).await, None, "an echo came over a dead relay");
    assert_eq!(p.b.stats().rehomes.load(Ordering::Relaxed), 0);
    one.revive();
    let back = first_echo(&p.a, &p.b_key, Duration::from_secs(60)).await;
    let back = back.expect("no echo after relay 1 came back");
    eprintln!(
        "relay-failover before: no echo for the {} s relay 1 was down; first echo {} ms after it \
         returned ({} ms after the kill)",
        down.as_secs(),
        back.as_millis(),
        killed.elapsed().as_millis()
    );
    assert_eq!(p.b.serving_relay().as_deref(), Some(one.route().as_str()));
}

/// The platform's answers with one placed relay (RFD 0060 Weft move 4): `placed` carries that
/// relay's own ticket for the same slot.
struct PlacedTickets {
    relay: String,
    placed: String,
    peers: Vec<String>,
}

#[async_trait::async_trait]
impl Tickets for PlacedTickets {
    async fn register(&self) -> Result<CarrierAnswer, String> {
        Ok(serde_json::from_value(json!({
            "relay": self.relay, "slot": "own-machine-slot-b", "ticket": "open-register",
            "expires_at": 0, "peers": self.peers,
            "placed": [{"relay": self.placed, "ticket": "placed-register"}],
        }))
        .unwrap())
    }

    async fn connect(&self, peer: &str) -> Result<CarrierAnswer, String> {
        if !self.peers.iter().any(|k| k == peer) {
            return Err("machine.not_found".into());
        }
        Ok(serde_json::from_value(json!({
            "relay": self.relay, "slot": "own-machine-slot-b", "ticket": "open-connect",
            "expires_at": 0, "peer_key": peer,
            "placed": [{"relay": self.placed, "ticket": "placed-connect"}],
        }))
        .unwrap())
    }
}

/// A host registers on the nearest placed relay beside the platform's relay, and a dialer goes
/// over the placed one once it has measured it: with the platform's relay dead and only one
/// relay named (no re-homing), the echo still comes, over the placed relay.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn hub_carrier_registers_on_and_dials_the_nearest_placed_relay() {
    let _ = HERMETIC;
    let (platform, placed) = (relay().await, relay().await);
    let (key_a, key_b) = (random_key(), random_key());
    let timings = Timings {
        control: Duration::from_secs(3),
        handshake: Duration::from_secs(3),
        peer_join: Duration::from_secs(2),
        ..Timings::default()
    };
    let tickets = |peer: &[u8; 32]| PlacedTickets {
        relay: platform.route(),
        placed: placed.route(),
        peers: vec![public(peer)],
    };
    let b = HubCarrier::new(Arc::new(tickets(&key_a)), key_b, timings);
    let _serving = b.serve(echo_server().await);
    let a = HubCarrier::new(Arc::new(tickets(&key_b)), key_a, timings);
    let b_key = public(&key_b);
    until_serving(&b, &platform.route(), Duration::from_secs(15)).await;

    // The first dial goes the platform's way while the placed relay is measured behind it (a
    // probe of at most 1 s); A keeps that one circuit open, so later dials ride it.
    echo_once(&a, &b_key, Duration::from_secs(10)).await.expect("first echo");
    assert_eq!(a.relay_of(&b_key).as_deref(), Some(platform.route().as_str()));
    tokio::time::sleep(Duration::from_secs(2)).await;

    // The platform's relay dies, and A's kept circuit with it. B stays registered on it (one
    // relay named, nothing re-homes); A's next circuit goes over the measured placed relay.
    platform.kill();
    let gap = first_echo(&a, &b_key, Duration::from_secs(15)).await;
    let gap = gap.expect("no echo over the placed relay after the platform's relay died");
    assert_eq!(a.relay_of(&b_key).as_deref(), Some(placed.route().as_str()));
    eprintln!("placed relay: platform relay kill to first echo {} ms", gap.as_millis());
    assert_eq!(b.stats().rehomes.load(Ordering::Relaxed), 0);
}
