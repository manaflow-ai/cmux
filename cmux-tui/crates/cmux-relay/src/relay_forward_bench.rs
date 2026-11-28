//! The relay's per-frame cost at fleet scale, and a model check of the cached circuit route.
//!
//! Bench: `cargo test -p cmux-relay --release forward_bench -- --ignored --nocapture`.
//! It fills the relay with 1,100 registered daemons (one per workspace) and `CHATS` ready
//! circuits, then every circuit's client sends `FRAMES` binary frames at once, the way 20
//! concurrent chats stream through one relay. Each frame's forward is timed. `locked` is a
//! lookup under the relay-wide lock per frame (what every frame paid before the cached route);
//! `cached` is the circuit loop's path. Budget: cached p95 at 20 and 200 chats.

use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::AtomicUsize;
use std::time::{Duration, Instant};

use axum::body::Bytes;
use cmux_remote_protocol::{CircuitId, LaneToken, RelayRole};
use tokio::sync::{mpsc, watch};

use super::{
    Attachment, CachedRoute, Circuit, CircuitRoute, ControlRegistration, Outbound, OutboundSender,
    Peer, Relay, RelayError,
};
use crate::config::RelayConfig;

const WORKSPACES: usize = 1_100;
const FRAMES: usize = 4_000;
const FRAME_BYTES: usize = 1_024;

struct Fleet {
    relay: Relay,
    circuits: Vec<(CircuitId, Peer, Peer)>,
    receivers: Vec<(mpsc::Receiver<Outbound>, mpsc::Receiver<Outbound>)>,
    /// Kept so no peer's shutdown channel closes while the fleet runs.
    _shutdowns: Vec<watch::Receiver<Option<super::CloseNotice>>>,
}

fn peer(
    id: u64,
    frames: usize,
) -> (Peer, mpsc::Receiver<Outbound>, watch::Receiver<Option<super::CloseNotice>>) {
    let (sender, receiver) = mpsc::channel(frames.max(1));
    let (shutdown, shutdown_receiver) = watch::channel(None);
    let peer = Peer {
        id,
        outbound: OutboundSender {
            sender,
            queued_bytes: Arc::new(AtomicUsize::new(0)),
            maximum_queue_bytes: usize::MAX / 2,
        },
        shutdown,
    };
    (peer, receiver, shutdown_receiver)
}

async fn fleet(chats: usize, queue_frames: usize) -> Fleet {
    let relay = Relay::new(RelayConfig { allow_open: true, ..RelayConfig::default() }).unwrap();
    let mut circuits = Vec::new();
    let mut receivers = Vec::new();
    let mut shutdowns = Vec::new();
    let mut next_id = 1u64;
    {
        let mut state = relay.inner.state.lock().await;
        let now = Instant::now();
        for workspace in 0..WORKSPACES {
            let slot = format!("workspace-{workspace:04}");
            let (daemon, _rx, shutdown) = peer(next_id, 1);
            shutdowns.push(shutdown);
            next_id += 1;
            state.attachments.insert(daemon.id, Attachment::Control { slot: slot.clone() });
            state.controls.insert(
                slot,
                ControlRegistration {
                    peer: daemon,
                    provider_ticket: String::new(),
                    deadline: now + Duration::from_secs(3_600),
                    provider_expiry: None,
                    provider_expires_at_unix: None,
                },
            );
        }
        for chat in 0..chats {
            let slot = format!("workspace-{:04}", chat % WORKSPACES);
            let id = CircuitId(format!("circuit-{chat:05}-{}", uuid::Uuid::new_v4()));
            let (client, client_rx, client_shutdown) = peer(next_id, queue_frames);
            let (daemon, daemon_rx, daemon_shutdown) = peer(next_id + 1, queue_frames);
            next_id += 2;
            shutdowns.extend([client_shutdown, daemon_shutdown]);
            state.attachments.insert(
                client.id,
                Attachment::Circuit { circuit: id.clone(), role: RelayRole::Client },
            );
            state.attachments.insert(
                daemon.id,
                Attachment::Circuit { circuit: id.clone(), role: RelayRole::Daemon },
            );
            state.circuits.insert(
                id.clone(),
                Circuit {
                    slot,
                    lane: LaneToken("lane".into()),
                    generation: 1,
                    client_join_ticket: String::new(),
                    daemon_join_ticket: String::new(),
                    created_at: now,
                    route: Arc::new(CircuitRoute::new(now)),
                    client: Some(client.clone()),
                    daemon: Some(daemon.clone()),
                    ready: true,
                },
            );
            circuits.push((id, client, daemon));
            receivers.push((client_rx, daemon_rx));
        }
    }
    Fleet { relay, circuits, receivers, _shutdowns: shutdowns }
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum Mode {
    Locked,
    Cached,
}

fn percentile(sorted: &[u64], p: f64) -> u64 {
    sorted[((sorted.len() as f64 - 1.0) * p).round() as usize]
}

struct Run {
    p50: u64,
    p95: u64,
    p99: u64,
    frames_per_second: f64,
}

async fn run(chats: usize, mode: Mode) -> Run {
    // Each queue holds a sender's whole burst: a full queue ends the circuit (as in production),
    // and the bench measures the relay's cost per frame, not how fast the drainers keep up.
    let Fleet { relay, circuits, receivers, _shutdowns } = fleet(chats, FRAMES).await;
    let drainers = receivers
        .into_iter()
        .map(|(mut client, mut daemon)| {
            tokio::spawn(async move {
                let mut received = 0usize;
                loop {
                    tokio::select! {
                        frame = daemon.recv() => match frame {
                            Some(_) => received += 1,
                            None => return received,
                        },
                        frame = client.recv() => if frame.is_none() { return received },
                    }
                }
            })
        })
        .collect::<Vec<_>>();
    // The relay's one-second sweep runs as in production.
    let cleanup = relay.spawn_cleanup();
    let payload = Bytes::from(vec![7u8; FRAME_BYTES]);
    let start = Instant::now();
    let senders = circuits
        .iter()
        .map(|(id, client, _)| {
            let relay = relay.clone();
            let id = id.clone();
            let sender = client.id;
            let payload = payload.clone();
            tokio::spawn(async move {
                let mut cached = None;
                let mut timings = Vec::with_capacity(FRAMES);
                for _ in 0..FRAMES {
                    let started = Instant::now();
                    let result = match mode {
                        Mode::Locked => relay.forward(sender, &id, payload.clone()).await,
                        Mode::Cached => {
                            relay.forward_cached(&mut cached, sender, &id, payload.clone()).await
                        }
                    };
                    if let Err(error) = result {
                        panic!("forward failed: {}", error.code);
                    }
                    timings.push(started.elapsed().as_nanos() as u64);
                }
                timings
            })
        })
        .collect::<Vec<_>>();
    let mut timings = Vec::with_capacity(chats * FRAMES);
    for sender in senders {
        timings.extend(sender.await.unwrap());
    }
    let elapsed = start.elapsed();
    cleanup.abort();
    drop(circuits);
    relay.inner.state.lock().await.circuits.clear();
    relay.inner.state.lock().await.controls.clear();
    drop(relay);
    for drainer in drainers {
        drainer.abort();
    }
    timings.sort_unstable();
    Run {
        p50: percentile(&timings, 0.50),
        p95: percentile(&timings, 0.95),
        p99: percentile(&timings, 0.99),
        frames_per_second: timings.len() as f64 / elapsed.as_secs_f64(),
    }
}

/// Budget for the cached path's per-frame p95 (ns) on a CI-class host.
const CACHED_P95_BUDGET_NS: u64 = 20_000;

#[test]
#[ignore = "bench: run with --release -- --ignored --nocapture"]
fn forward_bench() {
    let runtime =
        tokio::runtime::Builder::new_multi_thread().worker_threads(8).enable_all().build().unwrap();
    runtime.block_on(async {
        let mut rows = Vec::new();
        for chats in [20, 200] {
            for mode in [Mode::Locked, Mode::Cached] {
                let run = run(chats, mode).await;
                println!(
                    "FORWARD_BENCH {{\"workspaces\":{WORKSPACES},\"chats\":{chats},\"mode\":\"{mode:?}\",\
                     \"p50_ns\":{},\"p95_ns\":{},\"p99_ns\":{},\"frames_per_s\":{:.0}}}",
                    run.p50, run.p95, run.p99, run.frames_per_second
                );
                rows.push((chats, mode, run));
            }
        }
        for (chats, mode, run) in &rows {
            if *mode == Mode::Cached {
                assert!(
                    run.p95 <= CACHED_P95_BUDGET_NS,
                    "cached forward p95 {} ns at {chats} chats is over the {CACHED_P95_BUDGET_NS} ns budget",
                    run.p95
                );
            }
        }
    });
}

/// Model check: the cached route (new) against a locked lookup per frame (the oracle) on seeded
/// random sequences of frames, terminations, disconnects and sweeps. Both relays must answer
/// every frame alike (delivered, or the same refusal code) and deliver the same frames.
#[test]
fn cached_route_matches_locked_lookup_on_random_sequences() {
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    runtime.block_on(async {
        for seed in 1..=64u64 {
            check_sequence(seed).await;
        }
    });
}

struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }

    fn below(&mut self, n: usize) -> usize {
        (self.next() % n as u64) as usize
    }
}

fn delivered(receiver: &mut mpsc::Receiver<Outbound>) -> Vec<Bytes> {
    let mut frames = Vec::new();
    while let Ok(message) = receiver.try_recv() {
        if let Outbound::Binary(frame) = message {
            frames.push(frame.bytes.clone());
        }
    }
    frames
}

async fn check_sequence(seed: u64) {
    const CIRCUITS: usize = 6;
    let mut rng = Rng(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1);
    let mut oracle = fleet(CIRCUITS, 4_096).await;
    let mut cached = fleet(CIRCUITS, 4_096).await;
    // Each socket loop's cache, one per (circuit, role), as `run_circuit` holds one.
    let mut caches: HashMap<(usize, bool), Option<CachedRoute>> = HashMap::new();
    for step in 0..400 {
        let index = rng.below(CIRCUITS);
        let from_daemon = rng.below(2) == 1;
        let op = rng.below(100);
        let payload = Bytes::from(format!("{seed}:{step}"));
        if op < 85 {
            let (id, client, daemon) = &oracle.circuits[index];
            let sender = if from_daemon { daemon.id } else { client.id };
            let expected =
                oracle.relay.forward(sender, id, payload.clone()).await.err().map(|e| e.code);
            let (id, client, daemon) = &cached.circuits[index];
            let sender = if from_daemon { daemon.id } else { client.id };
            let cache = caches.entry((index, from_daemon)).or_default();
            let actual =
                cached.relay.forward_cached(cache, sender, id, payload).await.err().map(|e| e.code);
            assert_eq!(actual, expected, "seed {seed} step {step}: frame answer differs");
        } else if op < 92 {
            for fleet in [&oracle, &cached] {
                let id = fleet.circuits[index].0.clone();
                fleet.relay.terminate_circuit(&id, RelayError::policy("test", "test", true)).await;
            }
        } else if op < 98 {
            for fleet in [&oracle, &cached] {
                let (_, client, daemon) = &fleet.circuits[index];
                fleet.relay.disconnect(if from_daemon { daemon.id } else { client.id }).await;
            }
        } else {
            let idle = oracle.relay.inner.config.idle_timeout;
            let later = Instant::now() + idle + Duration::from_secs(1);
            oracle.relay.cleanup_expired(later).await;
            cached.relay.cleanup_expired(later).await;
        }
    }
    for index in 0..CIRCUITS {
        let (oracle_client, oracle_daemon) = &mut oracle.receivers[index];
        let (cached_client, cached_daemon) = &mut cached.receivers[index];
        assert_eq!(
            delivered(cached_client),
            delivered(oracle_client),
            "seed {seed}: client frames"
        );
        assert_eq!(
            delivered(cached_daemon),
            delivered(oracle_daemon),
            "seed {seed}: daemon frames"
        );
    }
    let oracle_left = oracle.relay.inner.state.lock().await.circuits.len();
    let cached_left = cached.relay.inner.state.lock().await.circuits.len();
    assert_eq!(cached_left, oracle_left, "seed {seed}: circuits left");
}

/// A frame on the cached path still counts as activity for the idle sweep.
#[tokio::test]
async fn cached_frames_keep_a_circuit_out_of_the_idle_sweep() {
    let fleet = fleet(1, 64).await;
    let (id, client, _) = &fleet.circuits[0];
    let mut cache = None;
    fleet.relay.forward_cached(&mut cache, client.id, id, Bytes::from_static(b"a")).await.unwrap();
    assert!(cache.is_some(), "the first frame fills the cache");
    tokio::time::sleep(Duration::from_millis(30)).await;
    let before = Instant::now();
    fleet.relay.forward_cached(&mut cache, client.id, id, Bytes::from_static(b"b")).await.unwrap();
    let idle = fleet.relay.inner.config.idle_timeout;
    // Idle measured from the first frame has passed; from the cached second frame it has not.
    fleet.relay.cleanup_expired(before + idle - Duration::from_millis(10)).await;
    assert_eq!(fleet.relay.inner.state.lock().await.circuits.len(), 1);
    fleet.relay.cleanup_expired(before + idle + Duration::from_millis(10)).await;
    assert_eq!(fleet.relay.inner.state.lock().await.circuits.len(), 0);
}
