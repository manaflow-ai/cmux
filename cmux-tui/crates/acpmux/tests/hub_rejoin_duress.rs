//! A peer link over the hub carrier drops and rejoins, quiet and under duress: how long until the
//! link reads `connected` again and how many dials the relay saw for it. The numbers for the
//! "auto connect" change (cmux#52580: peer links and hub probes ride the pair's one kept hub
//! circuit as streams). Its before is the same binary with `acpmux_streams(false)` on both
//! carriers, the knob #52580 kept for a daemon from before it: acpmux dials go plain, no hello,
//! as every acpmux dial did. Before and after alternate on one runner, quiet and under load.
//!
//! The duress bench (`duress_daemon.rs`) peers over local proxies with hub circuits 0, so it
//! never exercises the hub path; this file is that leg. Two real hubs: B serves a session on
//! loopback WebSocket and on its relay slot (registered straight to the in-process `cmux-relay`),
//! A mirrors B as peer `b` at a dead URL, so the carrier is its only route. Only A's leg runs
//! through a TCP proxy, so a cut drops A's circuits and not B's registration: a peer drop.
//!
//! Each round: wait for `connected`, cut every A-side relay connection and refuse new ones for
//! `HOLD`, then accept again and time until A's link reads `connected`. Counted per round, from
//! the cut until `SETTLE` after the rejoin: TCP connects to the relay (accepted and refused, the
//! dial attempts), A's plain circuits (`stats().dials`) and kept circuit opens. The duress pass
//! runs `ACPMUX_DURESS_CPU_X` (default 10) x cores busy loops, each under `timeout -s KILL`, and
//! a fork storm of four `/bin/true` loops.
//!
//! ```text
//! cmux-ci test -- 'cd cmux-tui && cargo test -p acpmux --release --features hub-carrier \
//!   --test hub_rejoin_duress -- --ignored --nocapture'
//! ```
//!
//! Prints `REJOIN-NUMBERS quiet plain ...`, `quiet kept`, `duress plain` and `duress kept`, and
//! fails a pass whose rejoin p50 is 5 s or more, or that never rejoined: a relay back after a
//! 3 s outage must not leave the link waiting out its backoff (`hub_carrier_relay_up.rs`).
#![cfg(all(target_os = "linux", feature = "hub-carrier"))]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// The hubs' config names the stand-in agent (tests/fake_agent.py); no session runs.
const HERMETIC: daemon_env::Process =
    daemon_env::Process::stand_in().keep(&["ACPMUX_DURESS_CPU_X"]);

use acpmux::config::{Config, HarnessProfile, PermissionPolicy, StoreMode};
use acpmux::hub::Hub;
use acpmux::hub_carrier::{CarrierAnswer, HubCarrier, Tickets, Timings};
use acpmux::server::peer_auth::PeerAuth;
use acpmux::server::{WsAuth, bind_ws, serve_ws_with};
use base64::Engine;
use serde_json::json;
use std::collections::BTreeMap;
use std::net::SocketAddr;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::{Duration, Instant};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::watch;

const ROUNDS: usize = 10;
/// How long the relay refuses A after a cut: long enough for A to notice and start redialing.
const HOLD: Duration = Duration::from_secs(3);
/// After the rejoin, how long late dials (a probe, a second circuit) still count to the round.
const SETTLE: Duration = Duration::from_secs(2);

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

/// A's leg to the relay: counts every TCP connect (accepted or refused) and can cut them all.
struct Proxy {
    port: u16,
    cut: watch::Sender<u64>,
    paused: Arc<AtomicBool>,
    accepted: Arc<AtomicU64>,
    refused: Arc<AtomicU64>,
}

impl Proxy {
    async fn start(target: SocketAddr) -> Self {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let (cut, _) = watch::channel(0u64);
        let proxy = Self {
            port,
            cut,
            paused: Arc::new(AtomicBool::new(false)),
            accepted: Arc::new(AtomicU64::new(0)),
            refused: Arc::new(AtomicU64::new(0)),
        };
        let (cut, paused, accepted, refused) = (
            proxy.cut.clone(),
            proxy.paused.clone(),
            proxy.accepted.clone(),
            proxy.refused.clone(),
        );
        tokio::spawn(async move {
            while let Ok((inbound, _)) = listener.accept().await {
                if paused.load(Ordering::SeqCst) {
                    refused.fetch_add(1, Ordering::SeqCst);
                    drop(inbound);
                    continue;
                }
                let Ok(outbound) = tokio::net::TcpStream::connect(target).await else { continue };
                accepted.fetch_add(1, Ordering::SeqCst);
                let mut cut = cut.subscribe();
                tokio::spawn(async move {
                    let (mut ir, mut iw) = inbound.into_split();
                    let (mut or, mut ow) = outbound.into_split();
                    tokio::select! {
                        _ = copy(&mut ir, &mut ow) => {}
                        _ = copy(&mut or, &mut iw) => {}
                        _ = cut.changed() => {}
                    }
                });
            }
        });
        proxy
    }

    fn cut_and_pause(&self) {
        self.paused.store(true, Ordering::SeqCst);
        self.cut.send_modify(|n| *n += 1);
    }

    fn resume(&self) {
        self.paused.store(false, Ordering::SeqCst);
    }

    fn connects(&self) -> (u64, u64) {
        (self.accepted.load(Ordering::SeqCst), self.refused.load(Ordering::SeqCst))
    }
}

async fn copy(from: &mut tokio::net::tcp::OwnedReadHalf, to: &mut tokio::net::tcp::OwnedWriteHalf) {
    let mut buf = vec![0u8; 16 * 1024];
    loop {
        let n = match from.read(&mut buf).await {
            Ok(0) | Err(_) => return,
            Ok(n) => n,
        };
        if to.write_all(&buf[..n]).await.is_err() {
            return;
        }
    }
}

struct FixedTickets {
    relay: String,
    peers: Vec<String>,
}

#[async_trait::async_trait]
impl Tickets for FixedTickets {
    async fn register(&self) -> Result<CarrierAnswer, String> {
        Ok(serde_json::from_value(json!({
            "relay": self.relay, "slot": "own-machine-slot-b", "ticket": "open-register",
            "expires_at": 0, "peers": self.peers,
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

fn connected(a: &Hub) -> bool {
    a.peers().into_iter().next().is_some_and(|p| p["state"] == "connected")
}

async fn until(a: &Hub, want: bool, budget: Duration) -> Option<Duration> {
    let started = Instant::now();
    while connected(a) != want {
        if started.elapsed() > budget {
            return None;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    Some(started.elapsed())
}

/// The stressors' process group, killed on drop; each also dies by `timeout -s KILL` after 30 min,
/// longer than both duress passes (300 s died mid-pass and left `duress kept` unloaded).
struct Load(Vec<std::process::Child>);

impl Load {
    fn start() -> Self {
        let cores = std::thread::available_parallelism().map_or(4, |n| n.get());
        let x: usize =
            std::env::var("ACPMUX_DURESS_CPU_X").ok().and_then(|v| v.parse().ok()).unwrap_or(10);
        let spawn = |script: &str| {
            std::process::Command::new("timeout")
                .args(["-s", "KILL", "1800", "sh", "-c", script])
                .stdin(std::process::Stdio::null())
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .spawn()
                .unwrap()
        };
        let mut children: Vec<_> = (0..cores * x).map(|_| spawn("while :; do :; done")).collect();
        children.extend((0..4).map(|_| spawn("while :; do /bin/true; done")));
        Self(children)
    }
}

impl Drop for Load {
    fn drop(&mut self) {
        for child in &mut self.0 {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

fn load1() -> String {
    std::fs::read_to_string("/proc/loadavg")
        .ok()
        .and_then(|s| s.split_whitespace().next().map(str::to_owned))
        .unwrap_or_default()
}

fn ms(d: Duration) -> f64 {
    d.as_secs_f64() * 1e3
}

fn pct(samples: &mut [Duration], p: f64) -> f64 {
    samples.sort();
    if samples.is_empty() {
        return f64::NAN;
    }
    let i = ((samples.len() as f64 - 1.0) * p).round() as usize;
    ms(samples[i])
}

struct Pair {
    a: Arc<Hub>,
    carrier_a: Arc<HubCarrier>,
    proxy: Proxy,
    _b: Arc<Hub>,
    _serving: acpmux::hub_carrier::HubServe,
    _home: tempfile::TempDir,
}

async fn pair(acpmux_streams: bool) -> Pair {
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
    let proxy = Proxy::start(relay_address).await;

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
    // B registers straight to the relay: a cut on A's leg is A's drop, not B's.
    let carrier_b = HubCarrier::new(
        Arc::new(FixedTickets {
            relay: format!("relay+ws://{relay_address}"),
            peers: vec![public(&key_a)],
        }),
        key_b,
        fast,
    );
    carrier_b.acpmux_streams(acpmux_streams);
    let serving = carrier_b.serve(b_ws);

    let a = hub();
    let carrier_a = HubCarrier::new(
        Arc::new(FixedTickets {
            relay: format!("relay+ws://127.0.0.1:{}", proxy.port),
            peers: vec![public(&key_b)],
        }),
        key_a,
        fast,
    );
    carrier_a.acpmux_streams(acpmux_streams);
    carrier_a.set_route("b", &public(&key_b));
    a.hub_carrier.set(carrier_a.clone());
    let dead = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap();
    a.add_peer("b", &format!("ws://{dead}"), Some("tok".into()), Some(peer_token), false)
        .await
        .unwrap();
    assert!(until(&a, true, Duration::from_secs(60)).await.is_some(), "A never reached B");
    Pair { a, carrier_a, proxy, _b: b, _serving: serving, _home: home }
}

/// `ACPMUX_REJOIN_TRACE=N`: print the peer row on every change after the relay is back, first N
/// rounds of each pass.
fn trace_rounds() -> usize {
    std::env::var("ACPMUX_REJOIN_TRACE").ok().and_then(|v| v.parse().ok()).unwrap_or(0)
}

/// `ACPMUX_REJOIN_PASSES=quiet-kept,duress-kept`: only those passes (all four when unset).
fn runs(label: &str) -> bool {
    std::env::var("ACPMUX_REJOIN_PASSES")
        .map_or(true, |v| v.split(',').any(|p| p.trim() == label.replace(' ', "-")))
}

async fn rounds(label: &'static str, p: &Pair) {
    let stats = p.carrier_a.stats();
    let mut noticed = Vec::new();
    let mut rejoin = Vec::new();
    let mut never = 0;
    let (mut accepted, mut refused, mut plain, mut kept) = (Vec::new(), Vec::new(), 0u64, 0u64);
    let started = Instant::now();
    for round in 0..ROUNDS {
        assert!(until(&p.a, true, Duration::from_secs(60)).await.is_some(), "not connected");
        tokio::time::sleep(Duration::from_millis(500)).await;
        let (a0, r0) = p.proxy.connects();
        let plain0 = stats.dials.load(Ordering::Relaxed);
        let kept0 = stats.kept_opens.load(Ordering::Relaxed);
        p.proxy.cut_and_pause();
        match until(&p.a, false, Duration::from_secs(30)).await {
            Some(d) => noticed.push(d),
            None => panic!("{label}: A never noticed the cut"),
        }
        let left = HOLD.saturating_sub(noticed.last().copied().unwrap_or_default());
        tokio::time::sleep(left).await;
        p.proxy.resume();
        let tracing = trace_rounds() > round;
        let watcher = tracing.then(|| {
            let a = p.a.clone();
            tokio::spawn(async move {
                let back = Instant::now();
                let mut last = String::new();
                loop {
                    let row = a.peers().into_iter().next().unwrap_or_default();
                    let now = row.to_string();
                    if now != last {
                        eprintln!(
                            "REJOIN-TRACE {label} round {round} +{:.0}ms {now}",
                            ms(back.elapsed())
                        );
                        last = now;
                    }
                    tokio::time::sleep(Duration::from_millis(50)).await;
                }
            })
        });
        let rejoined = until(&p.a, true, Duration::from_secs(60)).await;
        if let Some(w) = watcher {
            w.abort();
        }
        match rejoined {
            Some(d) => rejoin.push(d),
            None => never += 1,
        }
        tokio::time::sleep(SETTLE).await;
        let (a1, r1) = p.proxy.connects();
        accepted.push(a1 - a0);
        refused.push(r1 - r0);
        plain += stats.dials.load(Ordering::Relaxed) - plain0;
        kept += stats.kept_opens.load(Ordering::Relaxed) - kept0;
    }
    let n = ROUNDS as f64;
    let sum = |v: &[u64]| v.iter().sum::<u64>();
    eprintln!(
        "REJOIN-NUMBERS {label}: {ROUNDS} drops held {}s; rejoin after the relay is back \
         p50={:.0}ms p95={:.0}ms max={:.0}ms never={never}; drop noticed p50={:.0}ms; relay \
         connects per rejoin {:.1} (accepted {:.1} max {}, refused while down {:.1} max {}); \
         plain circuits per rejoin {:.1}; kept circuit opens per rejoin {:.1}; load1 {} on {} \
         cores; {:.0}s",
        HOLD.as_secs(),
        pct(&mut rejoin.clone(), 0.5),
        pct(&mut rejoin.clone(), 0.95),
        pct(&mut rejoin, 1.0),
        pct(&mut noticed, 0.5),
        (sum(&accepted) + sum(&refused)) as f64 / n,
        sum(&accepted) as f64 / n,
        accepted.iter().max().unwrap_or(&0),
        sum(&refused) as f64 / n,
        refused.iter().max().unwrap_or(&0),
        plain as f64 / n,
        kept as f64 / n,
        load1(),
        std::thread::available_parallelism().map_or(0, |n| n.get()),
        started.elapsed().as_secs_f64(),
    );
    let p50 = pct(&mut rejoin.clone(), 0.5);
    assert!(
        never == 0 && p50 < 5_000.0,
        "{label}: rejoin p50 {p50:.0}ms, never rejoined {never} of {ROUNDS}"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "numbers on demand"]
async fn hub_rejoin_numbers() {
    let _ = HERMETIC;
    if std::env::var_os("RUST_LOG").is_some() {
        let _ = tracing_subscriber::fmt()
            .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
            .with_writer(std::io::stderr)
            .try_init();
    }
    for kept in [false, true] {
        let label = if kept { "quiet kept" } else { "quiet plain" };
        if runs(label) {
            rounds(label, &pair(kept).await).await;
        }
    }
    if !runs("duress plain") && !runs("duress kept") {
        return;
    }
    let load = Load::start();
    tokio::time::sleep(Duration::from_secs(5)).await;
    for kept in [false, true] {
        let label = if kept { "duress kept" } else { "duress plain" };
        if runs(label) {
            rounds(label, &pair(kept).await).await;
        }
    }
    drop(load);
}
