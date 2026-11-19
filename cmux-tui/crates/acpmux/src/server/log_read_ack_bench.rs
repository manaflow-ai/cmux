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

use super::Origin;
use super::ack_latency_bench::Client;
use crate::config::{Config, StoreMode};
use crate::god_fixture::{self, Shape};
use crate::rpc::method;
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

/// One home: the cheap request's latencies while [`READERS`] whole-log reads run, and one line.
async fn measure(shape: Shape) -> f64 {
    let dir = tempfile::tempdir().unwrap();
    let (hub, id, bytes) = home(dir.path(), &shape);
    let history = json!({"sessionId": id});
    // One read first, alone: the page cache holds the log, and its time is printed.
    let alone = Client::on(&hub, Origin::Local).await;
    let started = Instant::now();
    let (reply, _) = alone.call(method::MUX_HISTORY, history.clone()).await;
    assert!(reply.get("error").is_none(), "{reply}");
    let read_ms = started.elapsed().as_secs_f64() * 1000.0;
    let probe = Client::on(&hub, Origin::Local).await;
    let reading = Arc::new(AtomicBool::new(true));
    let reads = Arc::new(AtomicUsize::new(0));
    let mut readers = Vec::new();
    for _ in 0..READERS {
        let client = Client::on(&hub, Origin::Local).await;
        let (reading, reads, history) = (reading.clone(), reads.clone(), history.clone());
        readers.push(tokio::spawn(async move {
            while reading.load(Ordering::SeqCst) {
                let (reply, _) = client.call(method::MUX_HISTORY, history.clone()).await;
                assert!(reply.get("error").is_none(), "{reply}");
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
    for reader in readers {
        reader.await.unwrap();
    }
    latencies.sort_unstable();
    let p95 = quantile(&latencies, 0.95);
    println!(
        "LOG-READ-ACK home={} workers={WORKERS} readers={READERS} log_bytes={bytes} \
         messages={} history_alone_ms={read_ms:.0} reads={} window_s={window:.1} p50={:.2} \
         p95={p95:.2} max={:.2} n={}",
        shape.name,
        shape.god_messages,
        reads.load(Ordering::SeqCst),
        quantile(&latencies, 0.5),
        quantile(&latencies, 1.0),
        latencies.len(),
    );
    p95
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "bench: run with --ignored --nocapture"]
async fn log_read_ack_bench() {
    let small = measure(Shape::small()).await;
    let god = measure(Shape::god_from_env()).await;
    println!("LOG-READ-ACK god_p95/small_p95={:.2}", god / small.max(0.001));
}
