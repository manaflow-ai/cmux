//! A cheap request's latency while whole-log reads run on other connections, on a small home and
//! a god home (`god_fixture`, `ACPMUX_GOD_SCALE` shrinks it). Leo, 2026-11-12: "even if a chat is
//! long, there should be no percievable difference". `_acpmux/history` reads a chat's whole log
//! (its kinds are not indexed): each of [`READERS`] connections asks for it again as soon as it is
//! answered, while one more connection asks `_acpmux/defaults` every [`EVERY`]. The runtime has
//! [`WORKERS`] workers, as many as the readers: a read that holds its worker leaves the cheap
//! request nothing to run on. The god p95 must be at most 1.2x the small one's.
//!
//! Only this crate's API from before the fix is used, so the same file measures both sides:
//! `cargo test -p acpmux --release --lib log_read_ack_bench -- --ignored --nocapture`.

use super::Client;
use crate::config::{Config, StoreMode};
use crate::god_fixture::{self, Shape};
use crate::rpc::method;
use crate::server::Origin;
use serde_json::json;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::time::{Duration, Instant};

/// The runtime's workers (the `#[tokio::test]` below says it again).
const WORKERS: usize = 4;
/// Connections that each keep one `_acpmux/history` of the big chat in flight.
const READERS: usize = WORKERS;
/// Cheap requests measured per home.
const SAMPLES: usize = 60;
/// The pause between two cheap requests.
const EVERY: Duration = Duration::from_millis(20);

/// A hub on a store in `dir` holding one chat of `shape`'s big chat size: its id and log bytes.
fn home(dir: &std::path::Path, shape: &Shape) -> (Arc<crate::hub::Hub>, String, u64) {
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Local;
    let store = crate::store::open(&cfg.store, dir).unwrap();
    let id = god_fixture::chat_id(0);
    let (bytes, last_seq) =
        god_fixture::append_log(store.as_ref(), &id, shape.god_messages, shape.god_bytes).unwrap();
    let agent = god_fixture::agent_session_id(0);
    let meta = god_fixture::session_meta(&id, shape.name, "/tmp", &agent, last_seq, 1);
    store.save(&serde_json::from_value(meta).unwrap()).unwrap();
    store.flush().unwrap();
    (crate::hub::Hub::new(cfg, store), id, bytes)
}

fn quantile(sorted: &[Duration], q: f64) -> f64 {
    let at = ((sorted.len() as f64 - 1.0) * q).round() as usize;
    sorted.get(at).copied().unwrap_or_default().as_secs_f64() * 1000.0
}

/// A home of `shape` in its own folder, and one history read of its big chat timed alone (the
/// page cache then holds the log).
struct Bench {
    _dir: tempfile::TempDir,
    shape: Shape,
    hub: Arc<crate::hub::Hub>,
    id: String,
    bytes: u64,
    alone: Duration,
}

async fn open(shape: Shape) -> Bench {
    let dir = tempfile::tempdir().unwrap();
    let (hub, id, bytes) = home(dir.path(), &shape);
    let client = Client::on(&hub, Origin::Local).await;
    let started = Instant::now();
    let (reply, _) = client.call(method::MUX_HISTORY, json!({"sessionId": id})).await;
    assert!(reply.get("error").is_none(), "{reply}");
    let alone = started.elapsed();
    Bench { _dir: dir, shape, hub, id, bytes, alone }
}

/// What each reader keeps in flight while the cheap request is measured.
#[derive(Clone, Copy)]
enum Load {
    /// `_acpmux/history` of the big chat on its own connection, as a client asks it.
    Wire,
    /// The same `Hub::history` on the blocking pool, awaited: no worker hands its core off.
    Pool,
    /// `qos::off_worker` of a sleep this long: the handoff alone, no log read and no lock.
    Sleep(Duration),
}

/// What [`run`] saw: the cheap request's latencies (sorted), the reads done and the window.
struct Seen {
    latencies: Vec<Duration>,
    reads: usize,
    window: f64,
}

/// The cheap request's latencies on `bench`'s hub while `readers` readers keep `load` going.
async fn run(bench: &Bench, load: Load, readers: usize) -> Seen {
    let probe = Client::on(&bench.hub, Origin::Local).await;
    let reading = Arc::new(AtomicBool::new(true));
    let reads = Arc::new(AtomicUsize::new(0));
    let mut tasks = Vec::new();
    for _ in 0..readers {
        let (reading, reads) = (reading.clone(), reads.clone());
        let (hub, id) = (bench.hub.clone(), bench.id.clone());
        let client = match load {
            Load::Wire => Some(Client::on(&hub, Origin::Local).await),
            _ => None,
        };
        tasks.push(tokio::spawn(async move {
            while reading.load(Ordering::SeqCst) {
                match load {
                    Load::Wire => {
                        let history = json!({"sessionId": id});
                        let client = client.as_ref().unwrap();
                        let (reply, _) = client.call(method::MUX_HISTORY, history).await;
                        assert!(reply.get("error").is_none(), "{reply}");
                    }
                    Load::Pool => {
                        let (hub, id) = (hub.clone(), id.clone());
                        tokio::task::spawn_blocking(move || {
                            let s = hub.resolve(&id).unwrap();
                            hub.history(&s, 20)
                        })
                        .await
                        .unwrap();
                    }
                    Load::Sleep(d) => crate::qos::off_worker(|| std::thread::sleep(d)),
                }
                reads.fetch_add(1, Ordering::SeqCst);
            }
        }));
    }
    // Every reader's first read has begun.
    tokio::time::sleep(Duration::from_millis(50)).await;
    let mut latencies = Vec::with_capacity(SAMPLES);
    let measured = Instant::now();
    while latencies.len() < SAMPLES {
        let asked = Instant::now();
        let (reply, _) = probe.call(method::MUX_DEFAULTS, json!({})).await;
        assert!(reply.get("error").is_none(), "{reply}");
        latencies.push(asked.elapsed());
        tokio::time::sleep(EVERY).await;
    }
    let window = measured.elapsed().as_secs_f64();
    reading.store(false, Ordering::SeqCst);
    for task in tasks {
        task.await.unwrap();
    }
    latencies.sort_unstable();
    Seen { latencies, reads: reads.load(Ordering::SeqCst), window }
}

/// One home: the cheap request's latencies while [`READERS`] whole-log reads run, and one line.
async fn measure(bench: &Bench) -> f64 {
    let seen = run(bench, Load::Wire, READERS).await;
    let p95 = quantile(&seen.latencies, 0.95);
    println!(
        "LOG-READ-ACK home={} workers={WORKERS} readers={READERS} log_bytes={} \
         messages={} history_alone_ms={:.0} reads={} window_s={:.1} p50={:.2} \
         p95={p95:.2} max={:.2} n={}",
        bench.shape.name,
        bench.bytes,
        bench.shape.god_messages,
        bench.alone.as_secs_f64() * 1000.0,
        seen.reads,
        seen.window,
        quantile(&seen.latencies, 0.5),
        quantile(&seen.latencies, 1.0),
        seen.latencies.len(),
    );
    p95
}

/// A control row: what the cheap request waits for on `bench` under `load` from `readers`.
async fn control(row: &str, bench: &Bench, load: Load, readers: usize) {
    let seen = run(bench, load, readers).await;
    println!(
        "LOG-READ-ACK-CTRL row={row} home={} readers={readers} reads={} window_s={:.1} \
         p50={:.2} p95={:.2} max={:.2} n={}",
        bench.shape.name,
        seen.reads,
        seen.window,
        quantile(&seen.latencies, 0.5),
        quantile(&seen.latencies, 0.95),
        quantile(&seen.latencies, 1.0),
        seen.latencies.len(),
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "bench: run with --ignored --nocapture"]
async fn log_read_ack_bench() {
    let small = open(Shape::small()).await;
    let god = open(Shape::god_from_env()).await;
    let small_p95 = measure(&small).await;
    let god_p95 = measure(&god).await;
    println!("LOG-READ-ACK god_p95/small_p95={:.2}", god_p95 / small_p95.max(0.001));
    // What the god rows wait for: the worker handoff alone (as long as one god read, on the small
    // home), the reads with no handoff (the blocking pool), and the reads by 1 and 8 readers.
    control("small-handoff-sleep", &small, Load::Sleep(god.alone), READERS).await;
    control("god-blocking-pool", &god, Load::Pool, READERS).await;
    control("god-wire-1", &god, Load::Wire, 1).await;
    control("god-wire-8", &god, Load::Wire, 8).await;
    // No reader at all: a daemon whose workers sit parked between requests. And the handoff at a
    // small read's length (1 ms), so the workers wake about as often as on the small home.
    control("small-idle", &small, Load::Wire, 0).await;
    control("god-idle", &god, Load::Wire, 0).await;
    let short = Load::Sleep(Duration::from_millis(1));
    control("small-handoff-sleep-1ms", &small, short, READERS).await;
}
